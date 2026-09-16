// ─────────────────────────────────────────────────────────────────────────────
// Native Brotli codec helpers. Brotli beats gzip on ratio for text (and Go's
// standard library ships no brotli), but Dart's dart:io has no brotli binding,
// so the engine links libbrotli and the NitroServerNative HybridObject exposes
// it (brotliEncode / brotliDecode / supportsBrotli) for the compress()
// middleware.
//
// Optional, exactly like TLS/libuv: when libbrotli is not found at build time
// NITRO_SERVER_BROTLI is undefined and every helper degrades — available()
// returns false and the codecs return {nullptr, 0}, so the middleware falls
// back to gzip and nothing else changes.
//
// Each returned buffer is malloc'd and transferred to the caller (the bridge
// hands it to Dart and frees it with free()), so nothing here is retained.
// ─────────────────────────────────────────────────────────────────────────────
#include "Brotli.h"

#include <cstdlib>

#ifdef NITRO_SERVER_BROTLI
#include <brotli/decode.h>
#include <brotli/encode.h>
#endif

namespace nitro_brotli {

bool available() {
#ifdef NITRO_SERVER_BROTLI
  return true;
#else
  return false;
#endif
}

Bytes encode(const uint8_t* in, size_t len, int quality) {
#ifdef NITRO_SERVER_BROTLI
  size_t cap = BrotliEncoderMaxCompressedSize(len);
  if (cap == 0) cap = len + 1024;  // 0 means "too small to bound" — pad it
  auto* out = static_cast<uint8_t*>(std::malloc(cap));
  if (out == nullptr) return {nullptr, 0};
  size_t encoded = cap;
  const BROTLI_BOOL ok =
      BrotliEncoderCompress(quality, BROTLI_DEFAULT_WINDOW, BROTLI_MODE_TEXT,
                            len, in, &encoded, out);
  if (!ok) {
    std::free(out);
    return {nullptr, 0};
  }
  return {out, encoded};
#else
  (void)in; (void)len; (void)quality;
  return {nullptr, 0};
#endif
}

Bytes decode(const uint8_t* in, size_t len) {
#ifdef NITRO_SERVER_BROTLI
  size_t cap = len * 4 + 64;
  for (int attempt = 0; attempt < 12; attempt++) {
    auto* out = static_cast<uint8_t*>(std::malloc(cap));
    if (out == nullptr) return {nullptr, 0};
    size_t decoded = cap;
    if (BrotliDecoderDecompress(len, in, &decoded, out) ==
        BROTLI_DECODER_RESULT_SUCCESS) {
      return {out, decoded};
    }
    std::free(out);
    cap *= 2;  // buffer too small (or a transient error): try a larger one
  }
  return {nullptr, 0};
#else
  (void)in; (void)len;
  return {nullptr, 0};
#endif
}

}  // namespace nitro_brotli
