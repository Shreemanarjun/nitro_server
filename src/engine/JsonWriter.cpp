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

#include "../nitro.h"  // NITRO_EXPORT

namespace {

// A growable byte buffer with an ensure-once fast path: the hot token writers
// (writeEscaped, writeInt) reserve their worst-case size in one bounds check,
// then fill through a raw cursor — no per-byte capacity check. malloc/realloc
// (not std::vector) so growth never value-initializes the new bytes.
struct NitroJsonWriter {
  uint8_t* data = nullptr;
  size_t len = 0;
  size_t cap = 0;
  bool needComma = false;
  ~NitroJsonWriter() { std::free(data); }

  void grow(size_t need) {  // out-of-line: the cold path
    size_t nc = cap ? cap * 2 : 256;
    while (nc < need) nc *= 2;
    data = static_cast<uint8_t*>(std::realloc(data, nc));
    cap = nc;
  }
  inline void ensure(size_t extra) {
    if (len + extra > cap) grow(len + extra);
  }
};

inline void put(NitroJsonWriter* w, uint8_t b) {
  w->ensure(1);
  w->data[w->len++] = b;
}
inline void putN(NitroJsonWriter* w, const char* s, int n) {
  w->ensure(static_cast<size_t>(n));
  std::memcpy(w->data + w->len, s, static_cast<size_t>(n));
  w->len += static_cast<size_t>(n);
}
inline void sep(NitroJsonWriter* w) { if (w->needComma) put(w, ','); }

inline void writeInt(NitroJsonWriter* w, int64_t v) {
  if (v == 0) { put(w, '0'); return; }
  uint8_t tmp[24];
  int n = 0;
  const bool neg = v < 0;
  uint64_t x = neg ? ~static_cast<uint64_t>(v) + 1 : static_cast<uint64_t>(v);
  while (x) { tmp[n++] = static_cast<uint8_t>('0' + x % 10); x /= 10; }
  w->ensure(static_cast<size_t>(n) + 1);  // digits + optional '-'
  uint8_t* d = w->data + w->len;
  if (neg) *d++ = '-';
  while (n) *d++ = tmp[--n];
  w->len = static_cast<size_t>(d - w->data);
}

inline void writeEscaped(NitroJsonWriter* w, const uint8_t* s, int n) {
  static const char kHex[] = "0123456789abcdef";
  w->ensure(static_cast<size_t>(n) * 6 + 2);  // worst case: every byte -> \u00XX
  uint8_t* d = w->data + w->len;
  *d++ = '"';
  for (int i = 0; i < n; i++) {
    const uint8_t c = s[i];
    switch (c) {
      case '"': *d++ = '\\'; *d++ = '"'; break;
      case '\\': *d++ = '\\'; *d++ = '\\'; break;
      case '\b': *d++ = '\\'; *d++ = 'b'; break;
      case '\f': *d++ = '\\'; *d++ = 'f'; break;
      case '\n': *d++ = '\\'; *d++ = 'n'; break;
      case '\r': *d++ = '\\'; *d++ = 'r'; break;
      case '\t': *d++ = '\\'; *d++ = 't'; break;
      default:
        if (c < 0x20) {
          *d++ = '\\'; *d++ = 'u'; *d++ = '0'; *d++ = '0';
          *d++ = kHex[c >> 4]; *d++ = kHex[c & 0xf];
        } else {
          *d++ = c;
        }
    }
  }
  *d++ = '"';
  w->len = static_cast<size_t>(d - w->data);
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

  // Widest output is the fixed whole-number branch: sign + up to 21 digits +
  // ".0". Reserve once so the per-char puts below never re-grow. (The
  // exponential branch's writeInt reserves its own tail.)
  w->ensure(40);
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
  w->grow(256);  // allocate up front so data is never null
  return w;
}
NITRO_EXPORT void nitro_server_jw_free(void* p) { delete cast(p); }
NITRO_EXPORT void nitro_server_jw_reset(void* p) {
  auto* w = cast(p);
  w->len = 0;  // keep the allocation; reuse across requests
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
  auto* w = cast(p); sep(w); putN(w, reinterpret_cast<const char*>(r), n);
  w->needComma = true;
}
// Emit a JSON array of `n` records built from a fixed template, in one FFI
// call — the engine runs the whole loop, so a hot handler pays no per-token
// Dart method call or FFI crossing (the residual cost once the JSON is the
// only work left). Each record interleaves `k` constant segments with `k`
// numeric columns: seg[0] col[0][row] seg[1] col[1][row] ... seg[k-1]
// col[k-1][row] seg[k]. So `segPtrs`/`segLens` have k+1 entries and there are
// k columns; `colTypes[c]` is 0 for an int64 column, 1 for a double column,
// and `colData[c]` points at that column's n-element array. Framed like any
// other value (leading comma if needed).
NITRO_EXPORT void nitro_server_jw_emit_template(
    void* p, int32_t n, int32_t k,
    const uint8_t* const* segPtrs, const int32_t* segLens,
    const uint8_t* colTypes, const void* const* colData) {
  auto* w = cast(p);
  sep(w);
  put(w, '[');
  for (int32_t row = 0; row < n; row++) {
    if (row) put(w, ',');
    for (int32_t c = 0; c < k; c++) {
      putN(w, reinterpret_cast<const char*>(segPtrs[c]), segLens[c]);
      if (colTypes[c] == 0)
        writeInt(w, static_cast<const int64_t*>(colData[c])[row]);
      else
        writeDouble(w, static_cast<const double*>(colData[c])[row]);
    }
    putN(w, reinterpret_cast<const char*>(segPtrs[k]), segLens[k]);
  }
  put(w, ']');
  w->needComma = true;
}
NITRO_EXPORT const uint8_t* nitro_server_jw_bytes(void* p) {
  return cast(p)->data;
}
NITRO_EXPORT int32_t nitro_server_jw_len(void* p) {
  return static_cast<int32_t>(cast(p)->len);
}

}  // extern "C"
