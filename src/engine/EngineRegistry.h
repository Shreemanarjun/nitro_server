// ─────────────────────────────────────────────────────────────────────────────
// EngineRegistry — instance-key → ServerInstance.
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

#include "ServerInstance.h"

namespace nitroserver {

class EngineRegistry {
 public:
  /// Resolves (creating on demand) the server for [key]. The `engine` key
  /// returns a shared unbound instance used only for capabilities/reset.
  static std::shared_ptr<ServerInstance> resolve(const std::string& key,
                                                 Emitter* emitter);

  /// Stops every server and drops every instance. Hot-restart recovery.
  static void resetAll();

 private:
  static std::mutex& mutex();
  static std::unordered_map<std::string, std::shared_ptr<ServerInstance>>&
  instances();
};

}  // namespace nitroserver
