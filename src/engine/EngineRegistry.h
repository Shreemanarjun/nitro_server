// ─────────────────────────────────────────────────────────────────────────────
// EngineRegistry — instance-key → Engine (the libuv reactor).
//
// One spec class produces one shared library, so roles ride on the key the
// C++ factory parses: `engine` (capabilities / global reset) and `s:<id>`
// (one bound server each). Mirrors nitro_http's EngineRegistry.
// ─────────────────────────────────────────────────────────────────────────────
#pragma once

#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>

#include "UvReactor.h"  // the engine: a libuv event-loop reactor

namespace nitroserver {

// The bound-server engine. Since 2026, a libuv reactor (UvReactor) — the
// thread-per-connection ServerInstance it replaced is gone.
using Engine = UvReactor;

class EngineRegistry {
 public:
  /// Resolves (creating on demand) the server for [key] and binds [emitter]
  /// as one of its sinks: several Dart isolates resolving the same key share
  /// one server and split its requests. The `engine` key returns a shared
  /// unbound instance used only for capabilities/reset.
  static std::shared_ptr<Engine> resolve(const std::string& key,
                                         Emitter* emitter);

  /// Stops every server and drops every instance. Hot-restart recovery.
  static void resetAll();

 private:
  static std::mutex& mutex();
  static std::unordered_map<std::string, std::shared_ptr<Engine>>& instances();
};

}  // namespace nitroserver
