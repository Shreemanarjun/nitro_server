// Unit tests for the engine's small pieces: method/status tables, the
// registry, router edge lookups, stream abort, and the WebSocket codec.
#include <gtest/gtest.h>

#include <initializer_list>
#include <string>
#include <vector>

#include "engine/Common.h"
#include "engine/EngineRegistry.h"
#include "engine/PendingTable.h"
#include "engine/Router.h"
#include "engine/WsCodec.h"

using namespace nitroserver;

namespace {

class NullEmitter final : public Emitter {
 public:
  void emitHead(int64_t, Method, const std::string&, const std::string&,
                const std::string&, const std::vector<Header>&, int64_t, bool,
                bool, const std::string&,
                const std::vector<RouteParam>&) override {}
  void emitBodyData(int64_t, uint8_t*, size_t) override {}
  void emitBodyEnd(int64_t) override {}
  void emitBodyError(int64_t, uint8_t*, size_t, ErrorKind) override {}
  void emitWsMessage(int64_t, uint8_t*, size_t, int, int) override {}
  void emitEvent(ServerEventKind, int64_t, const std::string&) override {}
};

TEST(CommonTest, ParsesEveryMethodTokenAndKeepsCustomOnes) {
  std::string custom;
  EXPECT_EQ(parseMethod("PUT", custom), Method::Put);
  EXPECT_EQ(parseMethod("DELETE", custom), Method::Delete);
  EXPECT_EQ(parseMethod("PATCH", custom), Method::Patch);
  EXPECT_EQ(parseMethod("OPTIONS", custom), Method::Options);
  EXPECT_EQ(parseMethod("TRACE", custom), Method::Trace);
  EXPECT_EQ(parseMethod("PURGE", custom), Method::Custom);
  EXPECT_EQ(custom, "PURGE");
}

TEST(CommonTest, ReasonPhrasesForEveryEmittedStatus) {
  EXPECT_STREQ(reasonPhrase(201), "Created");
  EXPECT_STREQ(reasonPhrase(204), "No Content");
  EXPECT_STREQ(reasonPhrase(405), "Method Not Allowed");
  EXPECT_STREQ(reasonPhrase(500), "Internal Server Error");
  EXPECT_STREQ(reasonPhrase(999), "Unknown");
}

TEST(RegistryTest, ResolveSharesOneInstancePerKeyUntilReset) {
  NullEmitter a, b;
  auto s1 = EngineRegistry::resolve("units-key", &a);
  auto s2 = EngineRegistry::resolve("units-key", &b);
  EXPECT_EQ(s1, s2);
  EXPECT_EQ(s1->emitterCountForTesting(), 2u);
  EngineRegistry::resetAll();
  auto s3 = EngineRegistry::resolve("units-key", &a);
  EXPECT_NE(s1, s3);
  EngineRegistry::resetAll();
}

TEST(RouterTest, RemoveMissesWhenTheWildcardOrParamNodeIsAbsent) {
  Router r;
  EXPECT_FALSE(r.remove(Method::Get, "", "/files/*"));
  EXPECT_FALSE(r.remove(Method::Get, "", "/users/:id"));
  RouteEntry e;
  e.pattern = "/users/:id";
  ASSERT_TRUE(r.add(e));
  EXPECT_FALSE(r.remove(Method::Get, "", "/users/:id/*"));
  EXPECT_TRUE(r.remove(Method::Get, "", "/users/:id"));
}

TEST(PendingTableTest, AbortAllMarksAnOpenStreamDead) {
  PendingTable t;
  auto req = t.create(9);
  {
    std::lock_guard<std::mutex> lk(req->mutex);
    req->answered = true;
    req->streamStarted = true;
  }
  t.abortAll();
  std::lock_guard<std::mutex> lk(req->mutex);
  EXPECT_TRUE(req->streamDead);
}

TEST(WsCodecTest, ParsesExtendedLengthsAndRejectsShortOrOversizedHeaders) {
  ws::FrameHeader h;
  const uint8_t s16[] = {0x82, 0x7e, 0x01, 0x00};
  EXPECT_TRUE(ws::parseHeader(s16, 4, h));
  EXPECT_EQ(h.length, 256u);
  EXPECT_EQ(h.headerSize, 4u);
  EXPECT_FALSE(ws::parseHeader(s16, 3, h));
  const uint8_t s64[] = {0x82, 0x7f, 0, 0, 0, 0, 0, 1, 0, 0};
  EXPECT_TRUE(ws::parseHeader(s64, 10, h));
  EXPECT_EQ(h.length, 65536u);
  EXPECT_FALSE(ws::parseHeader(s64, 9, h));
  const uint8_t huge[] = {0x82, 0x7f, 0x80, 0, 0, 0, 0, 0, 0, 0};
  EXPECT_FALSE(ws::parseHeader(huge, 10, h));
  const uint8_t badOpcode[] = {0x83, 0x00};
  EXPECT_FALSE(ws::parseHeader(badOpcode, 2, h));
}

TEST(WsCodecTest, EncodesA64BitLength) {
  std::vector<uint8_t> payload(70000, 'x');
  std::vector<uint8_t> out;
  ws::encodeFrame(0x2, payload.data(), payload.size(), true, out);
  ASSERT_EQ(out.size(), 10u + 70000u);
  EXPECT_EQ(out[1], 127);
  EXPECT_EQ(out[7], 0x01);  // 70000 = 0x011170, big-endian in bytes 2..9
  EXPECT_EQ(out[8], 0x11);
  EXPECT_EQ(out[9], 0x70);
}

TEST(WsCodecTest, Utf8ValidationCoversEveryShape) {
  auto ok = [](std::initializer_list<uint8_t> bytes) {
    std::vector<uint8_t> v(bytes);
    return ws::validUtf8(v.data(), v.size());
  };
  EXPECT_TRUE(ok({'a'}));
  EXPECT_TRUE(ok({0xc3, 0xa9}));              // U+00E9
  EXPECT_FALSE(ok({0xc1, 0x81}));             // overlong 2-byte
  EXPECT_TRUE(ok({0xe2, 0x82, 0xac}));        // U+20AC
  EXPECT_FALSE(ok({0xe0, 0x80, 0x80}));       // overlong 3-byte
  EXPECT_FALSE(ok({0xed, 0xa0, 0x80}));       // UTF-16 surrogate
  EXPECT_TRUE(ok({0xf0, 0x9f, 0x98, 0x80}));  // U+1F600
  EXPECT_FALSE(ok({0xf0, 0x80, 0x80, 0x80})); // overlong 4-byte
  EXPECT_FALSE(ok({0xf5, 0x80, 0x80, 0x80})); // beyond U+10FFFF
  EXPECT_FALSE(ok({0xff}));                   // invalid lead byte
  EXPECT_FALSE(ok({0xe2, 0x82}));             // truncated sequence
  EXPECT_FALSE(ok({0xe2, 0x41, 0x41}));       // bad continuation byte
}

}  // namespace
