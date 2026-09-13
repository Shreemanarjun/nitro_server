// ─────────────────────────────────────────────────────────────────────────────
// Wire — decode helpers the generated codecs do not cover.
//
// A `List<@HybridRecord>` ARGUMENT (e.g. `respond`'s headers) uses the indexed
// layout `[4B count][int64 offset × count][item payloads…]`, where offsets are
// measured from the payload start (first item at 4 + 8 * count). This is NOT
// the layout of a record FIELD, which the generated codec reads sequentially
// as `[4B count][items]`. (Same split as nitro_http's Wire.)
// ─────────────────────────────────────────────────────────────────────────────
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "../../lib/src/generated/cpp/nitro_server.native.g.h"
#include "Common.h"

namespace nitroserver {

/// Decodes an indexed `List<RawHeader>` argument. Throws std::runtime_error
/// on underflow; every field lands in a std::string, so the result owns its
/// bytes and survives the parameter arena (invariant 3).
inline std::vector<Header> decodeHeaderList(NitroCppBuffer buf) {
  NitroRecordReader r(buf);
  const int32_t n = r.readInt32();
  if (n < 0 || n > 1024) throw std::runtime_error("Wire: bad header count");
  for (int32_t i = 0; i < n; i++) r.readInt();  // Skip the offset table.
  std::vector<Header> out;
  out.reserve((size_t)n);
  for (int32_t i = 0; i < n; i++) {
    Header h;
    h.name = r.readString();
    h.value = r.readString();
    out.push_back(std::move(h));
  }
  return out;
}

/// Parses an unregisterRoute method token: `*` → All, otherwise the uppercase
/// HTTP token (unknown tokens → Custom, mirroring parseMethod).
inline Method parseUnregisterMethod(const std::string& token,
                                    std::string& customOut) {
  if (token == "*") return Method::All;
  return parseMethod(token, customOut);
}

}  // namespace nitroserver
