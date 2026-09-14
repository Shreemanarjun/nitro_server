#include "Router.h"

#include <string_view>

namespace nitroserver {

std::string Router::methodKey(Method m, const std::string& custom) {
  if (m == Method::Custom) return "C:" + custom;
  if (m == Method::All) return "A";
  return "M:" + std::to_string(static_cast<int64_t>(m));
}

std::vector<std::string_view> Router::split(std::string_view path) {
  std::vector<std::string_view> segs;
  size_t i = 0;
  while (i < path.size()) {
    while (i < path.size() && path[i] == '/') i++;
    const size_t start = i;
    while (i < path.size() && path[i] != '/') i++;
    if (i > start) segs.push_back(path.substr(start, i - start));
  }
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

const Router::Node* Router::findNode(const std::vector<std::string_view>& segs) const {
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

Router::Node* Router::findNodeMut(const std::vector<std::string_view>& segs) {
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

  struct Frame {
    const Node* node;
    size_t idx;
    int parent;
    bool hasParam;
    std::string paramName;
    std::string paramValue;
    int specificity;
  };

  // Thread-local reusable buffers: zero heap allocations on the hot path
  // after the first call per thread. clear() doesn't free memory.
  thread_local std::vector<Frame> arena;
  thread_local std::vector<int> stack;
  arena.clear();
  stack.clear();

  const RouteEntry* best = nullptr;
  int bestFrame = -1;
  int bestSpec = -1;
  bool bestIsAll = true;

  arena.push_back({&root_, 0, -1, false, {}, {}, 0});
  stack.push_back(0);
  while (!stack.empty()) {
    const int id = stack.back();
    stack.pop_back();
    const Node* node = arena[(size_t)id].node;
    const size_t idx = arena[(size_t)id].idx;
    const int spec = arena[(size_t)id].specificity;

    if (idx == segs.size()) {
      consider(pick(node), id, spec, best, bestFrame, bestSpec, bestIsAll);
      if (node->wildcard) {
        consider(pick(node->wildcard.get()), id, spec, best,
                 bestFrame, bestSpec, bestIsAll);
      }
      continue;
    }

    const std::string_view seg = segs[idx];
    if (node->wildcard) {
      consider(pick(node->wildcard.get()), id, spec, best,
               bestFrame, bestSpec, bestIsAll);
    }
    const bool hasParam = (node->param != nullptr);
    auto sit = node->statik.find(seg);
    const bool hasStatic = (sit != node->statik.end());
    if (hasParam && hasStatic) {
      const bool hasP = !node->paramName.empty();
      arena.push_back({node->param.get(), idx + 1, id, hasP,
                       hasP ? node->paramName : std::string(),
                       hasP ? std::string(seg.data(), seg.size()) : std::string(),
                       spec + 1});
      stack.push_back((int)arena.size() - 1);
      arena.push_back({sit->second.get(), idx + 1, id, false, {}, {},
                       spec + 2});
      stack.push_back((int)arena.size() - 1);
    } else if (hasParam) {
      const bool hasP = !node->paramName.empty();
      arena.push_back({node->param.get(), idx + 1, id, hasP,
                       hasP ? node->paramName : std::string(),
                       hasP ? std::string(seg.data(), seg.size()) : std::string(),
                       spec + 1});
      stack.push_back((int)arena.size() - 1);
    } else if (hasStatic) {
      arena.push_back({sit->second.get(), idx + 1, id, false, {}, {},
                       spec + 2});
      stack.push_back((int)arena.size() - 1);
    }
  }

  if (best) {
    out.matched = true;
    out.route = *best;
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
