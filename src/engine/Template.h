// ─────────────────────────────────────────────────────────────────────────────
// Template — engine-assembled response bodies.
//
// A template route answers on the reactor thread like a static route, but its
// body is `segments` interleaving literal bytes with `:param` values captured
// from the request path. The engine fills the slots and frames the response —
// Dart is never involved, so a template route runs at static-route throughput
// while still varying per request.
//
// Slots only ever land in the BODY (never a header), so there is no
// header-splitting surface; a `JsonString` slot is escaped so a value with `"`,
// `\` or control bytes cannot break out of its JSON string. `decodeTemplateBlob`
// is fed attacker-influenced bytes at registration and is bounds-checked
// throughout (see the fuzz target).
//
// Blob wire format (little-endian, self-defined — NOT a nitro record list):
//   [u32 count]  then count × ( [u8 kind][u8 escape][u32 len][len bytes text] )
// ─────────────────────────────────────────────────────────────────────────────
#pragma once

#include <cstdint>
#include <cstring>
#include <stdexcept>
#include <string>
#include <vector>

#include "Common.h"
#include "Router.h"

namespace nitroserver {

/// Appends `v` to `out` as a quoted, escaped JSON string. Same escape table as
/// JsonWriter::writeEscaped: `"` `\` and the C0 controls, `\b\f\n\r\t` by name,
/// the rest as `\u00XX`. Everything ≥ 0x20 (incl. UTF-8 continuation bytes)
/// passes through, so already-valid UTF-8 stays intact.
inline void jsonEscapeQuoted(std::string& out, const std::string& v) {
  static const char kHex[] = "0123456789abcdef";
  out.push_back('"');
  for (unsigned char c : v) {
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\b': out += "\\b"; break;
      case '\f': out += "\\f"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (c < 0x20) {
          out += "\\u00";
          out.push_back(kHex[c >> 4]);
          out.push_back(kHex[c & 0xf]);
        } else {
          out.push_back((char)c);
        }
    }
  }
  out.push_back('"');
}

/// Builds the response body from `segments`: literals verbatim, params looked
/// up in `params` (linear — a route captures a handful) and escaped per slot.
/// A param with no captured value contributes an empty string (`""` when
/// JsonString), never a partial or dangling token.
inline std::string assembleTemplateBody(
    const std::vector<TemplateSegment>& segments,
    const std::vector<RouteParam>& params) {
  std::string out;
  for (const auto& seg : segments) {
    if (seg.kind == TemplateSegment::Kind::Literal) {
      out += seg.text;
      continue;
    }
    // Param: find the captured value by name.
    const std::string* val = nullptr;
    for (const auto& p : params) {
      if (p.name == seg.text) {
        val = &p.value;
        break;
      }
    }
    static const std::string kEmpty;
    const std::string& v = val ? *val : kEmpty;
    if (seg.escape == TemplateSegment::Escape::JsonString) {
      jsonEscapeQuoted(out, v);
    } else {
      out += v;
    }
  }
  return out;
}

/// Decodes the registration blob into segments. Bounds-checked throughout;
/// throws std::runtime_error on any underflow or an implausible count/length so
/// a malformed blob is a clean registration error, never a read past the end.
inline std::vector<TemplateSegment> decodeTemplateBlob(const uint8_t* buf,
                                                       size_t len) {
  auto need = [&](size_t off, size_t n) {
    if (off + n > len || off + n < off) throw std::runtime_error("Template: truncated blob");
  };
  auto u32 = [&](size_t off) -> uint32_t {
    need(off, 4);
    uint32_t v;
    std::memcpy(&v, buf + off, 4);  // wire is little-endian; hosts we target are LE
    return v;
  };
  size_t off = 0;
  const uint32_t count = u32(off);
  off += 4;
  if (count > 100000) throw std::runtime_error("Template: implausible segment count");
  std::vector<TemplateSegment> out;
  out.reserve(count);
  for (uint32_t i = 0; i < count; i++) {
    need(off, 2);
    const uint8_t kind = buf[off];
    const uint8_t escape = buf[off + 1];
    off += 2;
    const uint32_t textLen = u32(off);
    off += 4;
    need(off, textLen);
    TemplateSegment seg;
    seg.kind = kind == 1 ? TemplateSegment::Kind::Param : TemplateSegment::Kind::Literal;
    seg.escape = escape == 1 ? TemplateSegment::Escape::JsonString : TemplateSegment::Escape::Raw;
    seg.text.assign((const char*)buf + off, textLen);
    off += textLen;
    out.push_back(std::move(seg));
  }
  return out;
}

}  // namespace nitroserver
