#include "EngineRegistry.h"

namespace nitroserver {

std::mutex& EngineRegistry::mutex() {
  static std::mutex m;
  return m;
}

std::unordered_map<std::string, std::shared_ptr<Engine>>&
EngineRegistry::instances() {
  static std::unordered_map<std::string, std::shared_ptr<Engine>> map;
  return map;
}

std::shared_ptr<Engine> EngineRegistry::resolve(const std::string& key,
                                                        Emitter* emitter) {
  std::lock_guard<std::mutex> lk(mutex());
  auto& map = instances();
  auto it = map.find(key);
  if (it != map.end()) {
    it->second->addEmitter(emitter);
    return it->second;
  }
  auto inst = std::make_shared<Engine>();
  inst->addEmitter(emitter);
  map.emplace(key, inst);
  return inst;
}

void EngineRegistry::resetAll() {
  std::lock_guard<std::mutex> lk(mutex());
  for (auto& kv : instances()) kv.second->stop();
  instances().clear();
}

}  // namespace nitroserver
