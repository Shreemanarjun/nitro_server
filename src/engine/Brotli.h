// Internal Brotli codec helpers (see Brotli.cpp), called by the
// NitroServerNative HybridObject's brotliEncode / brotliDecode / supportsBrotli
// methods — the engine side of the compress() middleware's `br` path.
//
// Optional, exactly like TLS: when the engine is built without libbrotli,
// available() is false and encode/decode return {nullptr, 0}, so the middleware
// falls back to gzip.
#pragma once

#include <cstddef>
#include <cstdint>

namespace nitro_brotli {

/// Whether the engine was built with libbrotli.
bool available();

/// A heap buffer transferred to the caller: free() `data` to release it.
/// `{nullptr, 0}` means failure (or brotli not built in).
struct Bytes {
  uint8_t* data;
  size_t size;
};

/// Brotli-encodes [in]/[len] at [quality] (0–11) in text mode.
Bytes encode(const uint8_t* in, size_t len, int quality);

/// Brotli-decodes [in]/[len] (the inverse of [encode]).
Bytes decode(const uint8_t* in, size_t len);

}  // namespace nitro_brotli
