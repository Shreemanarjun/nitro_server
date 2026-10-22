// libFuzzer target: the request-head parser, the first thing untrusted
// bytes reach. Build and run via tool/fuzz.sh.
#include <cstddef>
#include <cstdint>
#include <string>

#include "engine/EngineTypes.h"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t n) {
  const std::string raw((const char*)data, n);
  const size_t end = raw.find("\r\n\r\n");
  if (end == std::string::npos) return 0;
  (void)nitroserver::parseRequestHead(raw, end);
  return 0;
}
