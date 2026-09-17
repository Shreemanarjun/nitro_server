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

/// Form-decodes one URL-encoded token: `+` → space, `%XX` → byte, everything
/// else verbatim. A stray `%` with no two hex digits behind it is kept as-is
/// (lenient, never over-reads).
inline std::string formDecode(const char* s, size_t n) {
  auto hex = [](char c) -> int {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
  };
  std::string out;
  out.reserve(n);
  for (size_t i = 0; i < n; i++) {
    if (s[i] == '+') {
      out.push_back(' ');
    } else if (s[i] == '%' && i + 2 < n) {
      const int hi = hex(s[i + 1]), lo = hex(s[i + 2]);
      if (hi >= 0 && lo >= 0) {
        out.push_back((char)((hi << 4) | lo));
        i += 2;
      } else {
        out.push_back('%');
      }
    } else {
      out.push_back(s[i]);
    }
  }
  return out;
}

/// The form-decoded value of the first `key=value` in `query` (a `k=v&k2=v2`
/// string), or empty if `key` is absent. Keys are compared raw (rarely
/// encoded); only the value is decoded.
inline std::string queryGet(const std::string& query, const std::string& key) {
  size_t i = 0;
  while (i < query.size()) {
    size_t amp = query.find('&', i);
    if (amp == std::string::npos) amp = query.size();
    size_t eq = query.find('=', i);
    if (eq != std::string::npos && eq < amp) {
      if (query.compare(i, eq - i, key) == 0) {
        return formDecode(query.data() + eq + 1, amp - eq - 1);
      }
    } else if (amp - i == key.size() && query.compare(i, amp - i, key) == 0) {
      return "";  // bare `key` with no `=`
    }
    i = amp + 1;
  }
  return "";
}

/// Builds the response body from `segments`: literals verbatim, Param slots
/// from `params` (the captured `:name`s) and Query slots from `query`, each
/// escaped per slot. A missing value contributes an empty string (`""` when
/// JsonString), never a partial or dangling token.
inline std::string assembleTemplateBody(
    const std::vector<TemplateSegment>& segments,
    const std::vector<RouteParam>& params, const std::string& query) {
  std::string out;
  for (const auto& seg : segments) {
    if (seg.kind == TemplateSegment::Kind::Literal) {
      out += seg.text;
      continue;
    }
    std::string value;  // owns query results; empty for a missing field
    if (seg.kind == TemplateSegment::Kind::Query) {
      value = queryGet(query, seg.text);
    } else {  // Param
      for (const auto& p : params) {
        if (p.name == seg.text) {
          value = p.value;
          break;
        }
      }
    }
    if (seg.escape == TemplateSegment::Escape::JsonString) {
      jsonEscapeQuoted(out, value);
    } else {
      out += value;
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
    seg.kind = kind == 1   ? TemplateSegment::Kind::Param
               : kind == 2 ? TemplateSegment::Kind::Query
                           : TemplateSegment::Kind::Literal;
    seg.escape = escape == 1 ? TemplateSegment::Escape::JsonString : TemplateSegment::Escape::Raw;
    seg.text.assign((const char*)buf + off, textLen);
    off += textLen;
    out.push_back(std::move(seg));
  }
  return out;
}

}  // namespace nitroserver
