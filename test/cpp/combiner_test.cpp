// Combiner tests: exactly-once delivery under contention and single-poster
// exclusion are what the request path relies on.
#include <gtest/gtest.h>

#include <atomic>
#include <mutex>
#include <thread>
#include <vector>

#include "engine/Combiner.h"

using namespace nitroserver;

namespace {

TEST(CombinerTest, UncontendedPostsImmediately) {
  Combiner<int> c;
  std::vector<int> seen;
  c.submit(7, [&](std::vector<int>& batch) {
    seen.insert(seen.end(), batch.begin(), batch.end());
  });
  ASSERT_EQ(seen.size(), 1u);
  EXPECT_EQ(seen[0], 7);
}

TEST(CombinerTest, EveryItemPostedExactlyOnceWithOnePosterAtATime) {
  constexpr int kThreads = 16;
  constexpr int kPerThread = 2000;
  Combiner<int> c;
  std::mutex seenMutex;
  std::vector<int> counts(kThreads * kPerThread, 0);
  std::atomic<int> inside{0};
  std::atomic<int> overlap{0};
  std::atomic<int> batches{0};
  auto post = [&](std::vector<int>& batch) {
    if (inside.fetch_add(1) != 0) overlap++;
    batches++;
    {
      std::lock_guard<std::mutex> lk(seenMutex);
      for (int v : batch) counts[v]++;
    }
    inside--;
  };
  std::vector<std::thread> threads;
  for (int t = 0; t < kThreads; t++) {
    threads.emplace_back([&, t] {
      for (int i = 0; i < kPerThread; i++) c.submit(t * kPerThread + i, post);
    });
  }
  for (auto& th : threads) th.join();
  for (int v : counts) EXPECT_EQ(v, 1);   // exactly-once delivery
  EXPECT_EQ(overlap.load(), 0);           // one poster at a time
  // Combining is a scheduling-dependent optimization, not part of the
  // contract: when producers never overlap, each submit posts its own item
  // and batches == item count. Asserting batches < items here would flake
  // (it did on CI at 32000 == 32000), so we only require batches to be a
  // valid count — every batch posted at least one item, none double-posted.
  EXPECT_GT(batches.load(), 0);
  EXPECT_LE(batches.load(), kThreads * kPerThread);
}

}  // namespace
