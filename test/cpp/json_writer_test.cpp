// Tests the native JSON writer API: framing, escaping and number output.
#include <cstdint>
#include <cstring>
#include <string>

#include "gtest/gtest.h"

#include "../../src/engine/JsonWriter.h"

namespace jw = nitroserver::jw;

namespace {

std::string out(void* w) {
  return std::string(reinterpret_cast<const char*>(jw::bytes(w)),
                     (size_t)jw::length(w));
}
void key(void* w, const char* k) {
  jw::key(w, reinterpret_cast<const uint8_t*>(k), (int32_t)strlen(k));
}
void str(void* w, const char* s) {
  jw::writeString(w, reinterpret_cast<const uint8_t*>(s), (int32_t)strlen(s));
}
void raw(void* w, const char* r) {
  jw::writeRaw(w, reinterpret_cast<const uint8_t*>(r), (int32_t)strlen(r));
}

}  // namespace

TEST(JsonWriter, ObjectFramesCommasAndTypes) {
  void* w = jw::create();
  jw::beginObject(w);
  key(w, "id"); jw::writeInt(w, 42);
  key(w, "name"); str(w, "nitro");
  key(w, "ok"); jw::writeBool(w, 1);
  key(w, "no"); jw::writeBool(w, 0);
  key(w, "nil"); jw::writeNull(w);
  key(w, "score"); raw(w, "1.5");
  jw::endObject(w);
  EXPECT_EQ(out(w),
            "{\"id\":42,\"name\":\"nitro\",\"ok\":true,\"no\":false,"
            "\"nil\":null,\"score\":1.5}");
  jw::destroy(w);
}

TEST(JsonWriter, NestedArraysAndObjects) {
  void* w = jw::create();
  jw::beginArray(w);
  jw::beginObject(w);
  key(w, "tags");
  jw::beginArray(w);
  str(w, "a"); str(w, "b");
  jw::endArray(w);
  jw::endObject(w);
  jw::writeInt(w, 7);
  jw::endArray(w);
  EXPECT_EQ(out(w), "[{\"tags\":[\"a\",\"b\"]},7]");
  jw::destroy(w);
}

TEST(JsonWriter, EscapesStringsAndKeys) {
  void* w = jw::create();
  jw::beginObject(w);
  key(w, "a\"b");  // a key needing an escape
  str(w, "quote:\" back:\\ tab:\t nl:\n ctrl:\x01 keep:é");
  jw::endObject(w);
  EXPECT_EQ(out(w),
            "{\"a\\\"b\":\"quote:\\\" back:\\\\ tab:\\t nl:\\n "
            "ctrl:\\u0001 keep:\xC3\xA9\"}");
  jw::destroy(w);
}

TEST(JsonWriter, IntEdgeCasesAndReset) {
  void* w = jw::create();
  jw::beginArray(w);
  jw::writeInt(w, 0);
  jw::writeInt(w, -1);
  jw::writeInt(w, 9223372036854775807LL);   // INT64_MAX
  jw::writeInt(w, -9223372036854775807LL - 1);  // INT64_MIN
  jw::endArray(w);
  EXPECT_EQ(out(w),
            "[0,-1,9223372036854775807,-9223372036854775808]");
  jw::reset(w);
  jw::beginArray(w);
  jw::endArray(w);
  EXPECT_EQ(out(w), "[]");
  jw::destroy(w);
}

TEST(JsonWriter, DoubleFormatsLikeDart) {
  // Byte-identical to Dart's double.toString() across every rendering branch:
  // whole numbers get ".0", fixed vs exponential switches at the -6/21 decimal
  // exponent, negatives and signed zero carry the sign. (Dart's exact fuzz
  // check lives in test/json_writer_test.dart.)
  struct Case { double v; const char* want; };
  const Case cases[] = {
    {0.0, "0.0"}, {-0.0, "-0.0"}, {1.5, "1.5"}, {3.0, "3.0"},
    {298.5, "298.5"}, {100.0, "100.0"}, {-2.25, "-2.25"}, {0.0001, "0.0001"},
    {1e-6, "0.000001"}, {1e-7, "1e-7"}, {1e20, "100000000000000000000.0"},
    {1e21, "1e+21"}, {1234.5, "1234.5"}, {-1e21, "-1e+21"},
  };
  void* w = jw::create();
  for (const auto& c : cases) {
    jw::reset(w);
    jw::writeDouble(w, c.v);
    EXPECT_EQ(out(w), c.want) << "value " << c.v;
  }
  jw::destroy(w);
}

TEST(JsonWriter, EmitTemplateInterleavesSegmentsAndColumns) {
  // [ seg0 col0[i] seg1 col1[i] seg2 ] per row — an int column then a double
  // column, byte-identical to building each record token by token.
  const char* s0 = "{\"id\":";
  const char* s1 = ",\"score\":";
  const char* s2 = "}";
  const uint8_t* segs[] = {reinterpret_cast<const uint8_t*>(s0),
                           reinterpret_cast<const uint8_t*>(s1),
                           reinterpret_cast<const uint8_t*>(s2)};
  const int32_t lens[] = {(int32_t)strlen(s0), (int32_t)strlen(s1),
                          (int32_t)strlen(s2)};
  const uint8_t types[] = {0, 1};  // int64 column, double column
  const int64_t ids[] = {0, 1, 2};
  const double scores[] = {0.0, 1.5, 3.0};
  const void* data[] = {ids, scores};
  void* w = jw::create();
  jw::emitTemplate(w, 3, 2, segs, lens, types, data);
  EXPECT_EQ(out(w),
            "[{\"id\":0,\"score\":0.0},{\"id\":1,\"score\":1.5},"
            "{\"id\":2,\"score\":3.0}]");
  // Framed like any value: a preceding value gets a separating comma. A
  // single-column template ("{\"n\":<int>}") shows the k=1 path.
  const char* t0 = "{\"n\":";
  const char* t1 = "}";
  const uint8_t* segs1[] = {reinterpret_cast<const uint8_t*>(t0),
                            reinterpret_cast<const uint8_t*>(t1)};
  const int32_t lens1[] = {(int32_t)strlen(t0), (int32_t)strlen(t1)};
  const uint8_t types1[] = {0};
  const int64_t ns[] = {5, 6};
  const void* data1[] = {ns};
  jw::reset(w);
  jw::beginArray(w);
  jw::writeInt(w, 9);
  jw::emitTemplate(w, 2, 1, segs1, lens1, types1, data1);
  jw::endArray(w);
  EXPECT_EQ(out(w), "[9,[{\"n\":5},{\"n\":6}]]");
  jw::destroy(w);
}

TEST(JsonWriter, AllocScratchRoundTrips) {
  // The Dart wrapper copies key/string bytes into scratch from jw_alloc.
  uint8_t* p = jw::alloc(4);
  ASSERT_NE(p, nullptr);
  const char* s = "name";
  for (int i = 0; i < 4; i++) p[i] = (uint8_t)s[i];
  void* w = jw::create();
  jw::beginObject(w);
  jw::key(w, p, 4);
  jw::writeInt(w, 1);
  jw::endObject(w);
  EXPECT_EQ(out(w), "{\"name\":1}");
  jw::destroy(w);
  jw::freeBuffer(p);
}

#include <charconv>
#include <cmath>
#include <random>

#include "../../src/engine/Dtoa.h"

// The iOS < 16.3 fallback must pick the same digits as std::to_chars (the
// formatter every other platform uses), or JSON output would differ by device.
// Compares significand digits and exponent across edge cases and 200k random
// doubles spanning the whole exponent range.
TEST(JsonWriter, PortableDtoaMatchesToChars) {
  auto parts = [](const char* s, int n, std::string* digits, int* exp) {
    digits->clear();
    int i = 0;
    for (; i < n && s[i] != 'e'; i++)
      if (s[i] != '.') digits->push_back(s[i]);
    *exp = std::atoi(s + i + 1);
  };
  auto check = [&](double v) {
    char a[40], b[40];
    const auto r =
        std::to_chars(a, a + sizeof a - 1, v, std::chars_format::scientific);
    *r.ptr = '\0';  // to_chars does not terminate; atoi below needs it
    const int bn = nitroserver::sciShortestPortable(b, sizeof b, v);
    std::string da, db;
    int ea = 0, eb = 0;
    parts(a, (int)(r.ptr - a), &da, &ea);
    parts(b, bn, &db, &eb);
    ASSERT_EQ(da, db) << "value " << v;
    ASSERT_EQ(ea, eb) << "value " << v;
  };
  for (double v : {1.0, 1.5, 0.1, 0.2, 0.3, 1e-7, 1e21, 123456789.0, 5e-324,
                   2.2250738585072014e-308, 1.7976931348623157e308,
                   0.1 + 0.2, 9007199254740993.0, 298.5, 1e23, 4.35})
    check(v);
  std::mt19937_64 rng(42);
  for (int i = 0; i < 200000; i++) {
    double v;
    uint64_t bits = rng();
    std::memcpy(&v, &bits, sizeof v);
    v = std::fabs(v);
    if (!std::isfinite(v) || v == 0.0) continue;
    check(v);
  }
  for (int i = 0; i < 1000; i++) check(i * 1.5);
}
