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

/// A fixed answer the engine serves entirely on its own thread — the request
/// never crosses to Dart. Held behind a shared_ptr on the RouteEntry so a
/// per-request MatchResult copy is one refcount bump, not a body copy.
struct StaticResponse {
  int64_t status = 200;
  std::vector<Header> headers;  // Content-Length/Connection are engine-framed.
  std::string body;             // raw bytes (HEAD strips them, keeps the length)
};

/// One piece of a templated body. A Literal contributes its bytes verbatim; a
/// Param substitutes the captured `:name` path parameter and a Query the
/// `?name=` query value (form-decoded), each escaped per `escape`.
struct TemplateSegment {
  enum class Kind : uint8_t { Literal = 0, Param = 1, Query = 2 };
  enum class Escape : uint8_t { Raw = 0, JsonString = 1 };
  Kind kind = Kind::Literal;
  Escape escape = Escape::Raw;  // ignored for Literal
  std::string text;  // Literal: the bytes; Param/Query: the field name
};

/// A body the engine assembles per request from `segments` + the request's
/// captured path params, then serves entirely on its own thread — no Dart hop.
/// Like StaticResponse but with request-derived slots. Behind a shared_ptr so a
/// MatchResult copy is a refcount bump, not a segment-vector copy.
struct TemplateResponse {
  int64_t status = 200;
  std::vector<Header> headers;  // Content-Length/Connection are engine-framed.
  std::vector<TemplateSegment> segments;
};

struct RouteEntry {
  Method method = Method::Get;
  std::string customMethod;
  std::string pattern;
  int64_t timeoutMs = -1;  // -1 = inherit the server default.
  bool isWebSocket = false;  // RFC 6455 route: handshake upgrades in-engine.
  bool streamBody = false;   // Head first, then chunks: never the inline form.
  int64_t maxBodyBytes = -1;  // -1 = inherit the server cap.
  std::vector<std::string> wsProtocols;  // Accepted subprotocols, preferred first.
  // Non-null marks a static route: the engine answers it directly and never
  // dispatches. Copying a RouteEntry copies the pointer, never the bytes.
  std::shared_ptr<const StaticResponse> staticResponse;
  // Non-null marks a template route: the engine assembles the body from the
  // request's params and answers directly, still never dispatching to Dart.
  std::shared_ptr<const TemplateResponse> templateResponse;
};

struct MatchResult {
  bool matched = false;
  // Points into the router trie (stable while serving — routes register at
  // setup, never mid-request), so a match is a pointer store, not a per-request
  // copy of the RouteEntry's strings, vectors and shared_ptr refcounts. Only
  // dereference when `matched`.
  const RouteEntry* route = nullptr;
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
  /// [split] into a caller-owned buffer (cleared first), so the hot path can
  /// reuse a thread_local vector instead of allocating one per match.
  static void splitInto(std::string_view path,
                        std::vector<std::string_view>& segs);
  static bool validPattern(const std::string& pattern);

  const Node* findNode(const std::vector<std::string_view>& segs) const;
  Node* findNodeMut(const std::vector<std::string_view>& segs);

  Node root_;
  size_t size_ = 0;
};

}  // namespace nitroserver
