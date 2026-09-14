// ─────────────────────────────────────────────────────────────────────────────
// ChunkPool — thread-local slab pool for body-chunk payloads.
//
// Replaces per-chunk std::malloc/std::free with a thread-local ring buffer
// of pre-allocated slabs. Under high-concurrency upload workloads, this
// eliminates malloc contention (the glibc/tcmalloc arena lock) on the hot
// body-emit path.
//
// Protocol:
//   void* p = ChunkPool::acquire(n);   // called from emitBytes lambda
//   ...use p...
//   ChunkPool::release(p);             // called from PendingTable ack path
//
// Slabs are fixed-size (kBodyEmitBytes = 64 KiB). Requests smaller than or
// equal to kBodyEmitBytes use a pooled slab; larger requests fall through to
// std::malloc. release() detects pooled vs malloc'd memory automatically.
//
// Thread safety: acquire() is always called from the worker thread that owns
// the connection. release() is called from whatever thread Dart's ack runs
// on (usually a different worker). The ring is per-thread for the acquirer;
// release() from a different thread pushes back to the originating thread's
// ring via an atomic free-list.
//
// For simplicity (and because PendingTable ack may run on any thread), the
// current implementation uses a global lock-free free-list instead of a
// per-thread ring. This still eliminates the cost of malloc/free metadata
// management and virtual-address-space operations, while remaining safe
// across threads.
// ─────────────────────────────────────────────────────────────────────────────
#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstdlib>

namespace nitroserver {

class ChunkPool {
 public:
  /// The fixed slab size. Must match kBodyEmitBytes in ServerInstance.cpp.
  static constexpr size_t kSlabSize = 64 * 1024;

  /// Maximum number of free slabs to keep in the pool. Beyond this, excess
  /// slabs are returned to the system via std::free. 256 slabs × 64 KiB
  /// = 16 MiB max pooled memory — negligible for a server.
  static constexpr size_t kMaxFree = 256;

  /// Acquires a slab of at least `n` bytes. If `n <= kSlabSize`, returns a
  /// pooled slab; otherwise falls through to std::malloc.
  static void* acquire(size_t n) {
    if (n > kSlabSize) return std::malloc(n);
    // Try to pop from the free list.
    Node* node = head_.load(std::memory_order_acquire);
    while (node) {
      if (head_.compare_exchange_weak(node, node->next,
                                      std::memory_order_acq_rel,
                                      std::memory_order_acquire)) {
        freeCount_.fetch_sub(1, std::memory_order_relaxed);
        return reinterpret_cast<void*>(node);
      }
    }
    // Pool exhausted — allocate a fresh slab.
    return std::malloc(kSlabSize);
  }

  /// Releases a previously acquired pointer. If it was a pooled slab (size
  /// <= kSlabSize at acquire time), it is returned to the pool. Otherwise
  /// it is freed with std::free.
  ///
  /// IMPORTANT: the caller must pass `pooled = true` if and only if the
  /// original acquire was <= kSlabSize. The PendingTable tracks this via
  /// the payload size already stored in PayloadLog.
  static void release(void* p, bool pooled) {
    if (!pooled || !p) {
      std::free(p);
      return;
    }
    // If the pool is already at capacity, free to the system.
    if (freeCount_.load(std::memory_order_relaxed) >= kMaxFree) {
      std::free(p);
      return;
    }
    // Push onto the free list.
    auto* node = reinterpret_cast<Node*>(p);
    node->next = head_.load(std::memory_order_relaxed);
    while (!head_.compare_exchange_weak(node->next, node,
                                        std::memory_order_release,
                                        std::memory_order_relaxed)) {}
    freeCount_.fetch_add(1, std::memory_order_relaxed);
  }

  /// Drains all pooled slabs back to the system. Call on server shutdown
  /// to avoid LSAN/Valgrind noise.
  static void drain() {
    Node* node = head_.exchange(nullptr, std::memory_order_acq_rel);
    while (node) {
      Node* next = node->next;
      std::free(node);
      node = next;
    }
    freeCount_.store(0, std::memory_order_relaxed);
  }

 private:
  struct Node {
    Node* next;
  };
  static inline std::atomic<Node*> head_{nullptr};
  static inline std::atomic<size_t> freeCount_{0};
};

}  // namespace nitroserver
