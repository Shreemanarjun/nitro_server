// Tests the internal Brotli helpers (src/engine/Brotli.cpp): the availability
// flag and an encode/decode round-trip. Skips the round-trip when the engine
// was built without libbrotli (nitro_brotli::available() == false), the same
// graceful path the middleware takes. The HybridObject wrapper that calls these
// is covered end-to-end from Dart in test/brotli_test.dart.
#include <cstdlib>
#include <cstring>
#include <string>

#include "engine/Brotli.h"
#include "gtest/gtest.h"

TEST(Brotli, RoundTripsAndShrinksText) {
  if (!nitro_brotli::available()) {
    GTEST_SKIP() << "engine built without brotli";
  }
  std::string in;
  for (int i = 0; i < 500; i++) {
    in += "the quick brown fox jumps over the lazy dog " + std::to_string(i);
  }
  const nitro_brotli::Bytes c = nitro_brotli::encode(
      reinterpret_cast<const uint8_t*>(in.data()), in.size(), 5);
  ASSERT_NE(c.data, nullptr);
  EXPECT_GT(c.size, 0u);
  EXPECT_LT(c.size, in.size());  // compressible text must shrink

  const nitro_brotli::Bytes d = nitro_brotli::decode(c.data, c.size);
  ASSERT_NE(d.data, nullptr);
  ASSERT_EQ(d.size, in.size());
  EXPECT_EQ(0, memcmp(d.data, in.data(), d.size));

  std::free(c.data);
  std::free(d.data);
}
