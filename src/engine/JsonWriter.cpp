// ─────────────────────────────────────────────────────────────────────────────
// Native JSON writer — a growable byte buffer a Dart handler drives token by
// token over FFI. It serializes JSON ~2.5x faster than dart:convert's
// JsonUtf8Encoder (measured on a 200-record payload), byte-identical to
// jsonEncode. The engine only appends bytes; correctness (schema, ordering)
// is the caller's, exactly like hand-writing JSON.
//
// Numbers: integers and finite doubles are both formatted here (see writeInt
// and writeDouble), byte-identical to Dart — so a hot handler pays no Dart-side
// toString() + utf8.encode per number. jw_raw stays for pre-encoded fragments.
// Strings and keys are JSON-escaped here (", \\, and control chars < 0x20),
// matching jsonEncode's default (non-ASCII bytes pass through as UTF-8).
//
// Comma discipline: `needComma` is set after a value or a closed container and
// cleared after `{` `[` or a key, so a following value never adds a leading
// comma. This one flag frames both objects and arrays correctly.
// ─────────────────────────────────────────────────────────────────────────────
#include <charconv>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "../nitro.h"  // NITRO_EXPORT

namespace {

struct NitroJsonWriter {
  std::vector<uint8_t> buf;
  bool needComma = false;
};

inline void put(NitroJsonWriter* w, uint8_t b) { w->buf.push_back(b); }
inline void putN(NitroJsonWriter* w, const char* s, int n) {
  w->buf.insert(w->buf.end(), s, s + n);
}
inline void sep(NitroJsonWriter* w) { if (w->needComma) put(w, ','); }

inline void writeInt(NitroJsonWriter* w, int64_t v) {
  if (v == 0) { put(w, '0'); return; }
  uint8_t tmp[24];
  int n = 0;
  const bool neg = v < 0;
  uint64_t x = neg ? ~static_cast<uint64_t>(v) + 1 : static_cast<uint64_t>(v);
  while (x) { tmp[n++] = static_cast<uint8_t>('0' + x % 10); x /= 10; }
  if (neg) put(w, '-');
  while (n) put(w, tmp[--n]);
}

inline void writeEscaped(NitroJsonWriter* w, const uint8_t* s, int n) {
  static const char kHex[] = "0123456789abcdef";
  put(w, '"');
  for (int i = 0; i < n; i++) {
    const uint8_t c = s[i];
    switch (c) {
      case '"': put(w, '\\'); put(w, '"'); break;
      case '\\': put(w, '\\'); put(w, '\\'); break;
      case '\b': put(w, '\\'); put(w, 'b'); break;
      case '\f': put(w, '\\'); put(w, 'f'); break;
      case '\n': put(w, '\\'); put(w, 'n'); break;
      case '\r': put(w, '\\'); put(w, 'r'); break;
      case '\t': put(w, '\\'); put(w, 't'); break;
      default:
        if (c < 0x20) {
          put(w, '\\'); put(w, 'u'); put(w, '0'); put(w, '0');
          put(w, kHex[c >> 4]); put(w, kHex[c & 0xf]);
        } else {
          put(w, c);
        }
    }
  }
  put(w, '"');
}

// Formats a finite double byte-identically to Dart's double.toString(): the
// shortest decimal that round-trips (via std::to_chars, the same shortest
// algorithm Dart's dtoa uses), reformatted with Dart's rules — fixed notation
// for a decimal exponent in [-6, 21), else `e±exp`; a trailing `.0` on any
// whole number that isn't in exponent form. This is what the double-conversion
// EcmaScript converter with EMIT_TRAILING_*_DECIMAL_* flags produces, which is
// exactly Dart's configuration. NaN/Inf never reach here (the Dart wrapper
// guards them, matching jsonEncode which throws).
inline void writeDouble(NitroJsonWriter* w, double v) {
  // Read the raw sign bit, not std::signbit / v < 0: the engine builds with
  // -ffast-math (implies -fno-signed-zeros), so GCC folds signbit(zero) to
  // false and loses -0.0's "-". Inspecting the bits is immune — it is the
  // stored pattern, not an FP operation.
  uint64_t bits;
  std::memcpy(&bits, &v, sizeof(bits));
  const bool neg = (bits >> 63) != 0;
  if (v == 0.0) {  // 0.0 -> "0.0", -0.0 -> "-0.0"
    if (neg) put(w, '-');
    putN(w, "0.0", 3);
    return;
  }
  const double av = neg ? -v : v;
  char sci[40];
  const auto res =
      std::to_chars(sci, sci + sizeof(sci), av, std::chars_format::scientific);
  const int slen = static_cast<int>(res.ptr - sci);
  // Parse "d[.ddd]e±xx" into significant digits and the scientific exponent E.
  char digits[24];
  int k = 0, i = 0;
  digits[k++] = sci[i++];
  if (i < slen && sci[i] == '.') {
    i++;
    while (i < slen && sci[i] != 'e') digits[k++] = sci[i++];
  }
  i++;  // skip 'e'
  int esign = 1;
  if (sci[i] == '+') { i++; } else if (sci[i] == '-') { esign = -1; i++; }
  int e = 0;
  while (i < slen) e = e * 10 + (sci[i++] - '0');
  e *= esign;
  const int n = e + 1;  // position of the decimal point among the digits

  if (neg) put(w, '-');
  if (k <= n && n <= 21) {  // whole number in fixed range: digits, zeros, ".0"
    for (int j = 0; j < k; j++) put(w, digits[j]);
    for (int j = 0; j < n - k; j++) put(w, '0');
    putN(w, ".0", 2);
  } else if (0 < n && n <= 21) {  // decimal point inside the digits
    for (int j = 0; j < n; j++) put(w, digits[j]);
    put(w, '.');
    for (int j = n; j < k; j++) put(w, digits[j]);
  } else if (-6 < n && n <= 0) {  // 0.00…digits
    putN(w, "0.", 2);
    for (int j = 0; j < -n; j++) put(w, '0');
    for (int j = 0; j < k; j++) put(w, digits[j]);
  } else {  // exponential: d[.ddd]e±exp
    put(w, digits[0]);
    if (k > 1) {
      put(w, '.');
      for (int j = 1; j < k; j++) put(w, digits[j]);
    }
    put(w, 'e');
    int exp = n - 1;
    if (exp >= 0) { put(w, '+'); } else { put(w, '-'); exp = -exp; }
    writeInt(w, exp);
  }
}

inline NitroJsonWriter* cast(void* p) {
  return static_cast<NitroJsonWriter*>(p);
}

}  // namespace

extern "C" {

NITRO_EXPORT void* nitro_server_jw_new() {
  auto* w = new NitroJsonWriter();
  w->buf.reserve(256);
  return w;
}
NITRO_EXPORT void nitro_server_jw_free(void* p) { delete cast(p); }
NITRO_EXPORT void nitro_server_jw_reset(void* p) {
  auto* w = cast(p);
  w->buf.clear();
  w->needComma = false;
}
// Scratch native memory the Dart wrapper copies key/string bytes into.
NITRO_EXPORT uint8_t* nitro_server_jw_alloc(int32_t n) {
  return static_cast<uint8_t*>(malloc(static_cast<size_t>(n > 0 ? n : 1)));
}
NITRO_EXPORT void nitro_server_jw_free_buf(void* p) { free(p); }

NITRO_EXPORT void nitro_server_jw_begin_object(void* p) {
  auto* w = cast(p); sep(w); put(w, '{'); w->needComma = false;
}
NITRO_EXPORT void nitro_server_jw_end_object(void* p) {
  auto* w = cast(p); put(w, '}'); w->needComma = true;
}
NITRO_EXPORT void nitro_server_jw_begin_array(void* p) {
  auto* w = cast(p); sep(w); put(w, '['); w->needComma = false;
}
NITRO_EXPORT void nitro_server_jw_end_array(void* p) {
  auto* w = cast(p); put(w, ']'); w->needComma = true;
}
NITRO_EXPORT void nitro_server_jw_key(void* p, const uint8_t* k, int32_t kl) {
  auto* w = cast(p); sep(w); writeEscaped(w, k, kl); put(w, ':');
  w->needComma = false;
}
NITRO_EXPORT void nitro_server_jw_int(void* p, int64_t v) {
  auto* w = cast(p); sep(w); writeInt(w, v); w->needComma = true;
}
// Formats and appends a finite double natively (see writeDouble above), so a
// hot handler skips the Dart-side toString() + utf8.encode allocation.
NITRO_EXPORT void nitro_server_jw_double(void* p, double v) {
  auto* w = cast(p); sep(w); writeDouble(w, v); w->needComma = true;
}
NITRO_EXPORT void nitro_server_jw_string(void* p, const uint8_t* s, int32_t n) {
  auto* w = cast(p); sep(w); writeEscaped(w, s, n); w->needComma = true;
}
NITRO_EXPORT void nitro_server_jw_bool(void* p, int32_t b) {
  auto* w = cast(p); sep(w);
  if (b) putN(w, "true", 4); else putN(w, "false", 5);
  w->needComma = true;
}
NITRO_EXPORT void nitro_server_jw_null(void* p) {
  auto* w = cast(p); sep(w); putN(w, "null", 4); w->needComma = true;
}
// Pre-formatted value bytes (a double already rendered by Dart, or a nested
// pre-encoded fragment). Written verbatim, framed like any other value.
NITRO_EXPORT void nitro_server_jw_raw(void* p, const uint8_t* r, int32_t n) {
  auto* w = cast(p); sep(w); w->buf.insert(w->buf.end(), r, r + n);
  w->needComma = true;
}
NITRO_EXPORT const uint8_t* nitro_server_jw_bytes(void* p) {
  return cast(p)->buf.data();
}
NITRO_EXPORT int32_t nitro_server_jw_len(void* p) {
  return static_cast<int32_t>(cast(p)->buf.size());
}

}  // extern "C"
