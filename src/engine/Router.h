// ─────────────────────────────────────────────────────────────────────────────
// Router — segment trie with `:param` captures and a trailing `*` wildcard.
//
// Precedence at every level: static segment beats `:param` beats `*`.
// A route registered for Method::All matches any method. Method-specific
// routes beat All-routes at the same pattern (registered in separate tries).
// ─────────────────────────────────────────────────────────────────────────────
#pragma once

#include <functional>
#include <map>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

#include "Common.h"

namespace nitroserver {

struct RouteEntry {
  Method method = Method::Get;
  std::string customMethod;
  std::string pattern;
  int64_t timeoutMs = -1;  // -1 = inherit the server default.
  bool isWebSocket = false;  // RFC 6455 route: handshake upgrades in-engine.
};

struct MatchResult {
  bool matched = false;
  RouteEntry route;
  std::vector<RouteParam> params;
};

class Router {
 public:
  Router() = default;

  /// Registers [route]. Re-registering the same (method, pattern) replaces
  /// the timeout. Returns false when the pattern is malformed.
  bool add(const RouteEntry& route);

  /// Removes (method, pattern). Returns false when nothing was registered.
  bool remove(Method method, const std::string& customMethod,
              const std::string& pattern);

  /// Looks up (method, path). Static > param > wildcard, method-specific
  /// routes take precedence over All-routes at the same pattern.
  MatchResult match(Method method, const std::string& customMethod,
                    const std::string& path) const;

  /// Test seam: number of registered routes.
  size_t size() const { return size_; }

 private:
  struct Node {
    // Transparent comparator: lookups take string_views with no allocation.
    std::map<std::string, std::unique_ptr<Node>, std::less<>> statik;
    std::unique_ptr<Node> param;
    std::string paramName;
    std::unique_ptr<Node> wildcard;
    // One entry per method that terminates here (plus custom tokens).
    std::map<std::string, RouteEntry> entries;
  };

  static std::string methodKey(Method m, const std::string& custom);
  /// Splits on '/' dropping empties. Views into [path] — the caller keeps
  /// it alive for the whole match/add/remove.
  static std::vector<std::string_view> split(std::string_view path);
  static bool validPattern(const std::string& pattern);

  const Node* findNode(const std::vector<std::string_view>& segs) const;
  Node* findNodeMut(const std::vector<std::string_view>& segs);
  static const RouteEntry* pickEntry(const Node* node, Method method,
                                     const std::string& custom);

  Node root_;
  size_t size_ = 0;
};

}  // namespace nitroserver
