// Tests the native JSON writer's C ABI: framing, escaping and number output.
#include <cstdint>
#include <cstring>
#include <string>

#include "gtest/gtest.h"

extern "C" {
void* nitro_server_jw_new();
void nitro_server_jw_free(void*);
void nitro_server_jw_reset(void*);
uint8_t* nitro_server_jw_alloc(int32_t);
void nitro_server_jw_free_buf(void*);
void nitro_server_jw_begin_object(void*);
void nitro_server_jw_end_object(void*);
void nitro_server_jw_begin_array(void*);
void nitro_server_jw_end_array(void*);
void nitro_server_jw_key(void*, const uint8_t*, int32_t);
void nitro_server_jw_int(void*, int64_t);
void nitro_server_jw_double(void*, double);
void nitro_server_jw_string(void*, const uint8_t*, int32_t);
void nitro_server_jw_bool(void*, int32_t);
void nitro_server_jw_null(void*);
void nitro_server_jw_raw(void*, const uint8_t*, int32_t);
void nitro_server_jw_emit_template(void*, int32_t, int32_t, const uint8_t* const*,
                                   const int32_t*, const uint8_t*,
                                   const void* const*);
const uint8_t* nitro_server_jw_bytes(void*);
int32_t nitro_server_jw_len(void*);
}

namespace {

std::string out(void* w) {
  return std::string(reinterpret_cast<const char*>(nitro_server_jw_bytes(w)),
                     (size_t)nitro_server_jw_len(w));
}
void key(void* w, const char* k) {
  nitro_server_jw_key(w, reinterpret_cast<const uint8_t*>(k), (int32_t)strlen(k));
}
void str(void* w, const char* s) {
  nitro_server_jw_string(w, reinterpret_cast<const uint8_t*>(s), (int32_t)strlen(s));
}
void raw(void* w, const char* r) {
  nitro_server_jw_raw(w, reinterpret_cast<const uint8_t*>(r), (int32_t)strlen(r));
}

}  // namespace

TEST(JsonWriter, ObjectFramesCommasAndTypes) {
  void* w = nitro_server_jw_new();
  nitro_server_jw_begin_object(w);
  key(w, "id"); nitro_server_jw_int(w, 42);
  key(w, "name"); str(w, "nitro");
  key(w, "ok"); nitro_server_jw_bool(w, 1);
  key(w, "no"); nitro_server_jw_bool(w, 0);
  key(w, "nil"); nitro_server_jw_null(w);
  key(w, "score"); raw(w, "1.5");
  nitro_server_jw_end_object(w);
  EXPECT_EQ(out(w),
            "{\"id\":42,\"name\":\"nitro\",\"ok\":true,\"no\":false,"
            "\"nil\":null,\"score\":1.5}");
  nitro_server_jw_free(w);
}

TEST(JsonWriter, NestedArraysAndObjects) {
  void* w = nitro_server_jw_new();
  nitro_server_jw_begin_array(w);
  nitro_server_jw_begin_object(w);
  key(w, "tags");
  nitro_server_jw_begin_array(w);
  str(w, "a"); str(w, "b");
  nitro_server_jw_end_array(w);
  nitro_server_jw_end_object(w);
  nitro_server_jw_int(w, 7);
  nitro_server_jw_end_array(w);
  EXPECT_EQ(out(w), "[{\"tags\":[\"a\",\"b\"]},7]");
  nitro_server_jw_free(w);
}

TEST(JsonWriter, EscapesStringsAndKeys) {
  void* w = nitro_server_jw_new();
  nitro_server_jw_begin_object(w);
  key(w, "a\"b");  // a key needing an escape
  str(w, "quote:\" back:\\ tab:\t nl:\n ctrl:\x01 keep:é");
  nitro_server_jw_end_object(w);
  EXPECT_EQ(out(w),
            "{\"a\\\"b\":\"quote:\\\" back:\\\\ tab:\\t nl:\\n "
            "ctrl:\\u0001 keep:\xC3\xA9\"}");
  nitro_server_jw_free(w);
}

TEST(JsonWriter, IntEdgeCasesAndReset) {
  void* w = nitro_server_jw_new();
  nitro_server_jw_begin_array(w);
  nitro_server_jw_int(w, 0);
  nitro_server_jw_int(w, -1);
  nitro_server_jw_int(w, 9223372036854775807LL);   // INT64_MAX
  nitro_server_jw_int(w, -9223372036854775807LL - 1);  // INT64_MIN
  nitro_server_jw_end_array(w);
  EXPECT_EQ(out(w),
            "[0,-1,9223372036854775807,-9223372036854775808]");
  nitro_server_jw_reset(w);
  nitro_server_jw_begin_array(w);
  nitro_server_jw_end_array(w);
  EXPECT_EQ(out(w), "[]");
  nitro_server_jw_free(w);
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
  void* w = nitro_server_jw_new();
  for (const auto& c : cases) {
    nitro_server_jw_reset(w);
    nitro_server_jw_double(w, c.v);
    EXPECT_EQ(out(w), c.want) << "value " << c.v;
  }
  nitro_server_jw_free(w);
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
  void* w = nitro_server_jw_new();
  nitro_server_jw_emit_template(w, 3, 2, segs, lens, types, data);
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
  nitro_server_jw_reset(w);
  nitro_server_jw_begin_array(w);
  nitro_server_jw_int(w, 9);
  nitro_server_jw_emit_template(w, 2, 1, segs1, lens1, types1, data1);
  nitro_server_jw_end_array(w);
  EXPECT_EQ(out(w), "[9,[{\"n\":5},{\"n\":6}]]");
  nitro_server_jw_free(w);
}

TEST(JsonWriter, AllocScratchRoundTrips) {
  // The Dart wrapper copies key/string bytes into scratch from jw_alloc.
  uint8_t* p = nitro_server_jw_alloc(4);
  ASSERT_NE(p, nullptr);
  const char* s = "name";
  for (int i = 0; i < 4; i++) p[i] = (uint8_t)s[i];
  void* w = nitro_server_jw_new();
  nitro_server_jw_begin_object(w);
  nitro_server_jw_key(w, p, 4);
  nitro_server_jw_int(w, 1);
  nitro_server_jw_end_object(w);
  EXPECT_EQ(out(w), "{\"name\":1}");
  nitro_server_jw_free(w);
  nitro_server_jw_free_buf(p);
}
