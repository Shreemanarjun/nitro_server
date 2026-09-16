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
void nitro_server_jw_string(void*, const uint8_t*, int32_t);
void nitro_server_jw_bool(void*, int32_t);
void nitro_server_jw_null(void*);
void nitro_server_jw_raw(void*, const uint8_t*, int32_t);
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
