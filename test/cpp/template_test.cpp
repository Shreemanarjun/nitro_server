// Template tests: the per-request body assembler and its registration-blob
// decoder are fed request- and caller-influenced bytes, so escaping and bounds
// checks get their own suite (the fuzz target drives decodeTemplateBlob too).
#include <gtest/gtest.h>

#include <cstring>
#include <string>
#include <vector>

#include "engine/Template.h"

using namespace nitroserver;

namespace {

// Packs segments the way encodeTemplateBlob (Dart) does:
// [u32 count] then per seg [u8 kind][u8 escape][u32 len][text].
std::vector<uint8_t> pack(
    const std::vector<std::tuple<uint8_t, uint8_t, std::string>>& segs) {
  std::vector<uint8_t> b;
  auto u32 = [&](uint32_t v) {
    for (int i = 0; i < 4; i++) b.push_back((uint8_t)(v >> (8 * i)));
  };
  u32((uint32_t)segs.size());
  for (const auto& [kind, esc, text] : segs) {
    b.push_back(kind);
    b.push_back(esc);
    u32((uint32_t)text.size());
    b.insert(b.end(), text.begin(), text.end());
  }
  return b;
}

TEST(TemplateTest, JsonEscapeHandlesSpecials) {
  std::string out;
  jsonEscapeQuoted(out, std::string("a\"b\\c\n\t\x01"));
  EXPECT_EQ(out, "\"a\\\"b\\\\c\\n\\t\\u0001\"");
}

TEST(TemplateTest, JsonEscapePassesUtf8Through) {
  std::string out;
  jsonEscapeQuoted(out, std::string("café — ☕"));  // multi-byte bytes ≥ 0x20
  EXPECT_EQ(out, "\"café — ☕\"");
}

TEST(TemplateTest, AssemblesLiteralsAndParams) {
  std::vector<TemplateSegment> segs = {
      {TemplateSegment::Kind::Literal, TemplateSegment::Escape::Raw, "{\"id\":"},
      {TemplateSegment::Kind::Param, TemplateSegment::Escape::JsonString, "id"},
      {TemplateSegment::Kind::Literal, TemplateSegment::Escape::Raw, "}"},
  };
  std::vector<RouteParam> params = {{"id", "42"}};
  EXPECT_EQ(assembleTemplateBody(segs, params, ""), "{\"id\":\"42\"}");
}

TEST(TemplateTest, QuerySlotsFormDecode) {
  std::vector<TemplateSegment> segs = {
      {TemplateSegment::Kind::Query, TemplateSegment::Escape::JsonString, "q"},
      {TemplateSegment::Kind::Literal, TemplateSegment::Escape::Raw, "|"},
      {TemplateSegment::Kind::Query, TemplateSegment::Escape::Raw, "n"},
  };
  // q = "a b" (form-decoded from a+b), n missing -> empty raw.
  EXPECT_EQ(assembleTemplateBody(segs, {}, "q=a+b&x=1"), "\"a b\"|");
  EXPECT_EQ(assembleTemplateBody(segs, {}, "n=5"), "\"\"|5");
}

TEST(TemplateTest, QueryGetDecodesValueAndHandlesEdges) {
  EXPECT_EQ(queryGet("a=1&b=two", "b"), "two");
  EXPECT_EQ(queryGet("q=hello%20world", "q"), "hello world");
  EXPECT_EQ(queryGet("q=a+b", "q"), "a b");
  EXPECT_EQ(queryGet("a=1", "missing"), "");
  EXPECT_EQ(queryGet("", "x"), "");
  EXPECT_EQ(queryGet("flag&a=1", "flag"), "");   // bare key
  EXPECT_EQ(queryGet("q=%zz", "q"), "%zz");       // bad %-escape kept verbatim
  EXPECT_EQ(queryGet("q=%f", "q"), "%f");          // truncated %-escape kept
}

TEST(TemplateTest, EscapesParamValuesSoInjectionCannotBreakOut) {
  std::vector<TemplateSegment> segs = {
      {TemplateSegment::Kind::Param, TemplateSegment::Escape::JsonString, "q"},
  };
  // A value with a quote + brace must stay inside its JSON string.
  std::vector<RouteParam> params = {{"q", "\",\"admin\":true}"}};
  EXPECT_EQ(assembleTemplateBody(segs, params, ""),
            "\"\\\",\\\"admin\\\":true}\"");
}

TEST(TemplateTest, RawEscapeEmitsVerbatimAndMissingParamIsEmpty) {
  std::vector<TemplateSegment> segs = {
      {TemplateSegment::Kind::Param, TemplateSegment::Escape::Raw, "n"},
      {TemplateSegment::Kind::Literal, TemplateSegment::Escape::Raw, "|"},
      {TemplateSegment::Kind::Param, TemplateSegment::Escape::JsonString, "gone"},
  };
  std::vector<RouteParam> params = {{"n", "7"}};  // "gone" not captured
  EXPECT_EQ(assembleTemplateBody(segs, params, ""), "7|\"\"");
}

TEST(TemplateTest, BlobRoundTrips) {
  const auto bytes = pack({{0, 0, "lit"}, {1, 1, "id"}});
  const auto segs = decodeTemplateBlob(bytes.data(), bytes.size());
  ASSERT_EQ(segs.size(), 2u);
  EXPECT_EQ(segs[0].kind, TemplateSegment::Kind::Literal);
  EXPECT_EQ(segs[0].text, "lit");
  EXPECT_EQ(segs[1].kind, TemplateSegment::Kind::Param);
  EXPECT_EQ(segs[1].escape, TemplateSegment::Escape::JsonString);
  EXPECT_EQ(segs[1].text, "id");
}

TEST(TemplateTest, EmptyBlobDecodesEmpty) {
  const auto bytes = pack({});
  EXPECT_TRUE(decodeTemplateBlob(bytes.data(), bytes.size()).empty());
}

TEST(TemplateTest, TruncatedTextThrows) {
  auto bytes = pack({{0, 0, "hello"}});
  bytes.resize(bytes.size() - 2);  // chop the text short of its declared length
  EXPECT_THROW(decodeTemplateBlob(bytes.data(), bytes.size()),
               std::runtime_error);
}

TEST(TemplateTest, AbsurdCountThrows) {
  std::vector<uint8_t> bytes(4);
  uint32_t huge = 0x7fffffff;
  memcpy(bytes.data(), &huge, 4);
  EXPECT_THROW(decodeTemplateBlob(bytes.data(), bytes.size()),
               std::runtime_error);
}

TEST(TemplateTest, LengthOverflowThrows) {
  // count 1, kind/esc, then a textLen near UINT32_MAX with no bytes behind it.
  std::vector<uint8_t> bytes = {1, 0, 0, 0, 0, 0};  // count=1, kind=0, esc=0
  uint32_t len = 0xffffffff;
  bytes.insert(bytes.end(), (uint8_t*)&len, (uint8_t*)&len + 4);
  EXPECT_THROW(decodeTemplateBlob(bytes.data(), bytes.size()),
               std::runtime_error);
}

}  // namespace
