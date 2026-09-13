// PendingTable tests: the ack protocol is the use-after-free boundary, so
// every lifetime interleaving here is load-bearing.
#include <gtest/gtest.h>

#include <chrono>
#include <cstdlib>
#include <mutex>
#include <thread>

#include "engine/PendingTable.h"

using namespace nitroserver;

namespace {

TEST(PendingTableTest, FindMissingIsNull) {
  PendingTable t;
  EXPECT_EQ(t.find(1), nullptr);
}

TEST(PendingTableTest, RespondWakesTheWaiter) {
  PendingTable t;
  auto req = t.create(1);
  bool woke = false;
  std::thread waiter([&] {
    std::unique_lock<std::mutex> lk(req->mutex);
    req->cv.wait(lk, [&] { return req->answered; });
    woke = true;
  });
  // Let the waiter park.
  std::this_thread::sleep_for(std::chrono::milliseconds(20));
  {
    std::lock_guard<std::mutex> lk(req->mutex);
    req->answered = true;
    req->cv.notify_one();
  }
  waiter.join();
  EXPECT_TRUE(woke);
}

TEST(PendingTableTest, AckFreesInOrder) {
  PendingTable t;
  t.create(1);
  uint8_t* a = (uint8_t*)std::malloc(4);
  uint8_t* b = (uint8_t*)std::malloc(4);
  EXPECT_EQ(t.pendingPayloadsForTesting(1), 0u);
  t.trackPayload(1, a);
  t.trackPayload(1, b);
  EXPECT_EQ(t.pendingPayloadsForTesting(1), 2u);
  t.ack(1, 1);
  EXPECT_EQ(t.pendingPayloadsForTesting(1), 1u);
  t.ack(1, 2);
  EXPECT_EQ(t.pendingPayloadsForTesting(1), 0u);
}

TEST(PendingTableTest, AckIsIdempotentAndMonotonic) {
  PendingTable t;
  t.create(1);
  t.trackPayload(1, (uint8_t*)std::malloc(4));
  t.ack(1, 1);
  t.ack(1, 1);  // Must not double-free.
  t.ack(1, 0);  // Backwards acks are ignored.
  EXPECT_EQ(t.pendingPayloadsForTesting(1), 0u);
}

TEST(PendingTableTest, AckAfterEraseIsANoOp) {
  PendingTable t;
  t.create(1);
  t.trackPayload(1, (uint8_t*)std::malloc(4));
  t.erase(1);  // Entry gone, payload orphaned — NOT freed (Dart may decode).
  // Fully ack the orphan: the log is reaped without touching freed memory.
  t.ack(1, 1);
  t.ack(1, 1);  // Unknown log: no-op.
  EXPECT_EQ(t.pendingPayloadsForTesting(1), 0u);
}

TEST(PendingTableTest, EraseWithFullyAckedLogReapsImmediately) {
  PendingTable t;
  t.create(1);
  t.trackPayload(1, (uint8_t*)std::malloc(4));
  t.ack(1, 1);
  t.erase(1);
  EXPECT_EQ(t.pendingPayloadsForTesting(1), 0u);
}

TEST(PendingTableTest, AbortAllAnswersParkedAndFreesPayloads) {
  PendingTable t;
  auto req = t.create(1);
  t.trackPayload(1, (uint8_t*)std::malloc(4));
  bool woke = false;
  std::thread waiter([&] {
    std::unique_lock<std::mutex> lk(req->mutex);
    req->cv.wait(lk, [&] { return req->answered; });
    woke = req->status == 503;
  });
  std::this_thread::sleep_for(std::chrono::milliseconds(20));
  t.abortAll();
  waiter.join();
  EXPECT_TRUE(woke);
  EXPECT_EQ(t.find(1), nullptr);
  EXPECT_EQ(t.pendingPayloadsForTesting(1), 0u);
}

}  // namespace
