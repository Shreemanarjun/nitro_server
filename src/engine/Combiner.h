// Flat combining for cross-thread posts: many producers, one poster at a
// time. A producer enqueues its item and, if no one is posting, drains the
// queue itself; otherwise the current poster picks the item up on its next
// pass. Under load a burst of producers costs one post per pass instead of
// one contended post each. With no contention an item is posted at once.
#pragma once

#include <mutex>
#include <utility>
#include <vector>

namespace nitroserver {

template <typename T>
class Combiner {
 public:
  /// Enqueues [item] and posts pending items via `post(std::vector<T>&)`
  /// while this thread holds the poster lock. `post` runs on one thread at
  /// a time; every submitted item is posted exactly once.
  template <typename Post>
  void submit(T item, Post&& post) {
    {
      std::lock_guard<std::mutex> lk(queueMutex_);
      queue_.push_back(std::move(item));
    }
    for (;;) {
      if (!posterMutex_.try_lock()) return;  // the holder re-checks after unlock
      std::vector<T> local;
      {
        std::lock_guard<std::mutex> lk(queueMutex_);
        local.swap(queue_);
      }
      if (!local.empty()) post(local);
      posterMutex_.unlock();
      // An item pushed while we held the lock, whose producer saw try_lock
      // fail, would otherwise strand: re-check and take another pass.
      std::lock_guard<std::mutex> lk(queueMutex_);
      if (queue_.empty()) return;
    }
  }

 private:
  std::mutex queueMutex_;
  std::mutex posterMutex_;
  std::vector<T> queue_;
};

}  // namespace nitroserver
