// libFuzzer target: the WebSocket frame-header parser, with and without a
// negotiated permessage-deflate (RSV1 admitted).
#include <cstddef>
#include <cstdint>

#include "engine/WsCodec.h"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t n) {
  nitroserver::ws::FrameHeader h;
  (void)nitroserver::ws::parseHeader(data, n, h, false);
  (void)nitroserver::ws::parseHeader(data, n, h, true);
  return 0;
}
