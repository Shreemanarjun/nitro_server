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
  auto consider = [&](const RouteEntry* e, const std::vector<RouteParam>& ps,
                      int spec, const RouteEntry*& best,
                      std::vector<RouteParam>& bestParams, int& bestSpec,
                      bool& bestIsAll) {
    if (!e) return;
    const bool isAll = (e->method == Method::All);
    if (spec > bestSpec || (spec == bestSpec && bestIsAll && !isAll)) {
      best = e;
      bestParams = ps;
      bestSpec = spec;
      bestIsAll = isAll;
    }
  };

  // Depth-first search with static > param > wildcard precedence. The first
  // hit in that order wins; an All-route only counts when no method-specific
  // route matched anywhere at equal-or-better specificity.
  struct Frame {
    const Node* node;
    size_t idx;
    std::vector<RouteParam> params;
    int specificity;  // higher = more specific.
  };
  // Specificity of a candidate is compared across the whole search, so a
  // static match deeper in one branch beats a param match in another.
  const RouteEntry* best = nullptr;
  std::vector<RouteParam> bestParams;
  int bestSpec = -1;
  bool bestIsAll = true;

  std::vector<Frame> stack;
  stack.reserve(segs.size() + 1);
  stack.push_back({&root_, 0, {}, 0});
  while (!stack.empty()) {
    Frame fr = std::move(stack.back());
    stack.pop_back();
    const Node* node = fr.node;

    if (fr.idx == segs.size()) {
      consider(pick(node), fr.params, fr.specificity, best, bestParams,
               bestSpec, bestIsAll);
      // A trailing wildcard also matches the empty remainder.
      if (node->wildcard) {
        consider(pick(node->wildcard.get()), fr.params, fr.specificity, best,
                 bestParams, bestSpec, bestIsAll);
      }
      continue;
    }

    const std::string& seg = segs[fr.idx];
    // Push in reverse precedence so static pops first.
    if (node->wildcard) {
      // Wildcard consumes the rest of the path.
      consider(pick(node->wildcard.get()), fr.params, fr.specificity, best,
               bestParams, bestSpec, bestIsAll);
    }
    const bool hasParam = (node->param != nullptr);
    auto sit = node->statik.find(seg);
    const bool hasStatic = (sit != node->statik.end());
    if (hasParam && hasStatic) {
      // Two children: move into one, copy into the other. Static pops first
      // so it gets the moved vector.
      Frame paramFr{node->param.get(), fr.idx + 1, fr.params,
                    fr.specificity + 1};
      paramFr.params.push_back({node->paramName, seg});
      stack.push_back(std::move(paramFr));
      stack.push_back({sit->second.get(), fr.idx + 1, std::move(fr.params),
                       fr.specificity + 2});
    } else if (hasParam) {
      fr.params.push_back({node->paramName, seg});
      stack.push_back({node->param.get(), fr.idx + 1, std::move(fr.params),
                       fr.specificity + 1});
    } else if (hasStatic) {
      stack.push_back({sit->second.get(), fr.idx + 1, std::move(fr.params),
                       fr.specificity + 2});
    }
  }

  if (best) {
    out.matched = true;
    out.route = *best;
    out.params = std::move(bestParams);
  }
  return out;
}

}  // namespace nitroserver
