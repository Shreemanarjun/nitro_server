#include "Router.h"

namespace nitroserver {

std::string Router::methodKey(Method m, const std::string& custom) {
  if (m == Method::Custom) return "C:" + custom;
  if (m == Method::All) return "A";
  return "M:" + std::to_string(static_cast<int64_t>(m));
}

std::vector<std::string> Router::split(const std::string& path) {
  std::vector<std::string> segs;
  std::string cur;
  for (char c : path) {
    if (c == '/') {
      if (!cur.empty()) {
        segs.push_back(cur);
        cur.clear();
      }
    } else {
      cur.push_back(c);
    }
  }
  if (!cur.empty()) segs.push_back(cur);
  return segs;
}

bool Router::validPattern(const std::string& pattern) {
  if (pattern.empty() || pattern[0] != '/') return false;
  auto segs = split(pattern);
  for (size_t i = 0; i < segs.size(); i++) {
    const auto& s = segs[i];
    if (s.empty() || s == ":") return false;
    if (s[0] == ':' && s.size() == 1) return false;
    if (s.find('*') != std::string::npos) {
      // A wildcard is only legal as the whole last segment.
      if (s != "*" || i != segs.size() - 1) return false;
    }
  }
  return true;
}

bool Router::add(const RouteEntry& route) {
  if (!validPattern(route.pattern)) return false;
  auto segs = split(route.pattern);
  Node* node = &root_;
  for (size_t i = 0; i < segs.size(); i++) {
    const auto& s = segs[i];
    if (s == "*") {
      if (!node->wildcard) node->wildcard = std::make_unique<Node>();
      node = node->wildcard.get();
    } else if (s[0] == ':') {
      if (!node->param) {
        node->param = std::make_unique<Node>();
        node->paramName = s.substr(1);
      }
      node = node->param.get();
    } else {
      auto it = node->statik.find(s);
      if (it == node->statik.end()) {
        auto fresh = std::make_unique<Node>();
        Node* child = fresh.get();
        node->statik.emplace(s, std::move(fresh));
        node = child;
      } else {
        node = it->second.get();
      }
    }
  }
  const std::string key = methodKey(route.method, route.customMethod);
  if (node->entries.find(key) == node->entries.end()) size_++;
  node->entries[key] = route;
  return true;
}

bool Router::remove(Method method, const std::string& customMethod,
                    const std::string& pattern) {
  Node* node = findNodeMut(split(pattern));
  if (!node) return false;
  const std::string key = methodKey(method, customMethod);
  auto it = node->entries.find(key);
  if (it == node->entries.end()) return false;
  node->entries.erase(it);
  size_--;
  return true;
}

const Router::Node* Router::findNode(const std::vector<std::string>& segs) const {
  const Node* node = &root_;
  for (const auto& s : segs) {
    if (s == "*") {
      if (!node->wildcard) return nullptr;
      node = node->wildcard.get();
    } else if (!s.empty() && s[0] == ':') {
      if (!node->param) return nullptr;
      node = node->param.get();
    } else {
      auto it = node->statik.find(s);
      if (it == node->statik.end()) return nullptr;
      node = it->second.get();
    }
  }
  return node;
}

Router::Node* Router::findNodeMut(const std::vector<std::string>& segs) {
  return const_cast<Node*>(const_cast<const Router*>(this)->findNode(segs));
}

const RouteEntry* Router::pickEntry(const Node* node, Method method,
                                    const std::string& custom) {
  if (!node) return nullptr;
  auto it = node->entries.find(methodKey(method, custom));
  if (it != node->entries.end()) return &it->second;
  if (method != Method::All && method != Method::Custom) {
    auto all = node->entries.find(methodKey(Method::All, ""));
    if (all != node->entries.end()) return &all->second;
  }
  return nullptr;
}

MatchResult Router::match(Method method, const std::string& customMethod,
                          const std::string& path) const {
  MatchResult out;
  const auto segs = split(path);

  // Method keys computed once per request (not per visited node): the old
  // pickEntry built a fresh std::string on every node visit.
  const std::string mkey = methodKey(method, customMethod);
  const std::string akey = methodKey(Method::All, "");
  const bool allowAll =
      (method != Method::All && method != Method::Custom);
  auto pick = [&](const Node* node) -> const RouteEntry* {
    if (!node) return nullptr;
    auto it = node->entries.find(mkey);
    if (it != node->entries.end()) return &it->second;
    if (allowAll) {
      auto all = node->entries.find(akey);
      if (all != node->entries.end()) return &all->second;
    }
    return nullptr;
  };
  auto consider = [&](const RouteEntry* e, int frameId, int spec,
                       const RouteEntry*& best, int& bestFrame,
                       int& bestSpec, bool& bestIsAll) {
    if (!e) return;
    const bool isAll = (e->method == Method::All);
    if (spec > bestSpec || (spec == bestSpec && bestIsAll && !isAll)) {
      best = e;
      bestFrame = frameId;
      bestSpec = spec;
      bestIsAll = isAll;
    }
  };

  // Depth-first search with static > param > wildcard precedence. The first
  // hit in that order wins; an All-route only counts when no method-specific
  // route matched anywhere at equal-or-better specificity.
  //
  // Frames are parent-linked (not param-vector-carrying): each frame holds
  // only the single :param it captured on entry, plus its parent's arena
  // index. Branching therefore moves two small structs instead of copying a
  // params vector per frame; the winning chain is walked once at the end.
  struct Frame {
    const Node* node;
    size_t idx;
    int parent;  // arena index, -1 for the root.
    bool hasParam;
    std::string paramName;
    std::string paramValue;
    int specificity;  // higher = more specific.
  };
  // Specificity of a candidate is compared across the whole search, so a
  // static match deeper in one branch beats a param match in another.
  const RouteEntry* best = nullptr;
  int bestFrame = -1;
  int bestSpec = -1;
  bool bestIsAll = true;

  std::vector<Frame> arena;
  arena.reserve(2 * (segs.size() + 1));
  std::vector<int> stack;
  stack.reserve(2 * (segs.size() + 1));
  arena.push_back({&root_, 0, -1, false, {}, {}, 0});
  stack.push_back(0);
  auto pushChild = [&](const Node* node, size_t idx, int parent,
                       const std::string& paramName, const std::string& seg,
                       int specificity) {
    const bool hasParam = !paramName.empty();
    arena.push_back({node, idx, parent, hasParam, paramName,
                     hasParam ? seg : std::string(), specificity});
    stack.push_back((int)arena.size() - 1);
  };
  while (!stack.empty()) {
    const int id = stack.back();
    stack.pop_back();
    // Hoisted: pushChild appends to arena (may reallocate), so nothing may
    // hold a reference into it across a push.
    const Node* node = arena[(size_t)id].node;
    const size_t idx = arena[(size_t)id].idx;
    const int spec = arena[(size_t)id].specificity;

    if (idx == segs.size()) {
      consider(pick(node), id, spec, best, bestFrame, bestSpec,
               bestIsAll);
      // A trailing wildcard also matches the empty remainder.
      if (node->wildcard) {
        consider(pick(node->wildcard.get()), id, spec, best,
                 bestFrame, bestSpec, bestIsAll);
      }
      continue;
    }

    const std::string& seg = segs[idx];
    // Push in reverse precedence so static pops first.
    if (node->wildcard) {
      // Wildcard consumes the rest of the path.
      consider(pick(node->wildcard.get()), id, spec, best,
               bestFrame, bestSpec, bestIsAll);
    }
    const bool hasParam = (node->param != nullptr);
    auto sit = node->statik.find(seg);
    const bool hasStatic = (sit != node->statik.end());
    if (hasParam && hasStatic) {
      // Two children: static pops first. No vector is copied either way —
      // each child links back to this frame.
      pushChild(node->param.get(), idx + 1, id, node->paramName, seg,
                spec + 1);
      pushChild(sit->second.get(), idx + 1, id, {}, seg,
                spec + 2);
    } else if (hasParam) {
      pushChild(node->param.get(), idx + 1, id, node->paramName, seg,
                spec + 1);
    } else if (hasStatic) {
      pushChild(sit->second.get(), idx + 1, id, {}, seg,
                spec + 2);
    }
  }

  if (best) {
    out.matched = true;
    out.route = *best;
    // Walk the winning chain once, deepest first, then reverse.
    std::vector<RouteParam> ps;
    for (int id = bestFrame; id > 0; id = arena[(size_t)id].parent) {
      const Frame& fr = arena[(size_t)id];
      if (fr.hasParam) ps.push_back({fr.paramName, fr.paramValue});
    }
    out.params.assign(ps.rbegin(), ps.rend());
  }
  return out;
}

}  // namespace nitroserver
