// Wire tests: the indexed argument layout is the one encoding the generated
// record codecs do NOT cover, so it gets its own suite.
#include <gtest/gtest.h>

#include <cstring>

#include "engine/Wire.h"

using namespace nitroserver;

namespace {

// Encodes [headers] the way Dart's RecordWriter.encodeIndexedList does:
// [4B count][int64 offset × count][items], offsets from payload start.
std::vector<uint8_t> encodeIndexed(
    const std::vector<std::pair<std::string, std::string>>& headers) {
  NitroRecordWriter out;
  out.writeInt32((int32_t)headers.size());
  int64_t offset = 4 + 8 * (int64_t)headers.size();
  std::vector<std::vector<uint8_t>> items;
  for (const auto& h : headers) {
    NitroRecordWriter item;
    item.writeString(h.first);
    item.writeString(h.second);
    NitroCppBuffer payload = item.toBuffer();
    items.emplace_back(payload.data, payload.data + payload.size);
  }
  for (const auto& item : items) {
    out.writeInt(offset);
    offset += (int64_t)item.size();
  }
  for (const auto& item : items) out.writeBytes(item.data(), item.size());
  return std::move(out._buf);
}

TEST(WireTest, DecodesIndexedHeaderList) {
  const auto bytes = encodeIndexed({{"Content-Type", "text/plain"},
                                    {"X-Token", "abc"},
                                    {"X-Token", "def"}});
  NitroCppBuffer buf{bytes.data(), bytes.size()};
  const auto headers = decodeHeaderList(buf);
  ASSERT_EQ(headers.size(), 3u);
  EXPECT_EQ(headers[0].name, "Content-Type");
  EXPECT_EQ(headers[0].value, "text/plain");
  EXPECT_EQ(headers[1].name, "X-Token");
  EXPECT_EQ(headers[2].value, "def");
}

TEST(WireTest, EmptyListDecodesEmpty) {
  const auto bytes = encodeIndexed({});
  NitroCppBuffer buf{bytes.data(), bytes.size()};
  EXPECT_TRUE(decodeHeaderList(buf).empty());
}

TEST(WireTest, TruncatedBufferThrows) {
  const auto bytes = encodeIndexed({{"A", "B"}});
  // Claim 5 headers but carry 1: the reader must throw, never over-read.
  std::vector<uint8_t> evil = bytes;
  int32_t five = 5;
  memcpy(evil.data(), &five, 4);
  NitroCppBuffer buf{evil.data(), evil.size()};
  EXPECT_THROW(decodeHeaderList(buf), std::runtime_error);
}

TEST(WireTest, AbsurdCountThrows) {
  std::vector<uint8_t> bytes(4);
  int32_t huge = 1000000;
  memcpy(bytes.data(), &huge, 4);
  NitroCppBuffer buf{bytes.data(), bytes.size()};
  EXPECT_THROW(decodeHeaderList(buf), std::runtime_error);
}

}  // namespace
