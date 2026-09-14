// ─────────────────────────────────────────────────────────────────────────────
// PendingTable — one entry per in-flight request.
//
// The connection thread parks on the entry's condition variable; Dart's
// `respond` (or the route timeout) wakes it. Each entry has its OWN mutex,
// so connections never serialize on a shared bridge lock — this is the
// per-thread-semaphore requirement from the implementation plan, realized
// per-request rather than per-thread, which is strictly finer-grained.
//
// Zero-copy payload logs: every body-chunk payload handed to `emit_bodyChunks`
// stays malloc-owned here until Dart's cumulative `ackBody` releases it.
// The log OUTLIVES the request entry on purpose: the timeout path can finish
// and reap a request while Dart still has queued port messages referencing
// its payloads. Freeing on ack (never on completion) is what makes the path
// both leak-free and use-after-free-free — same protocol as nitro_http's
// ChunkArena. Orphaned logs are reaped by stop()/resetNative().
// ─────────────────────────────────────────────────────────────────────────────
#pragma once

#include <condition_variable>
#include <cstdint>
#include <cstdlib>
#include <deque>
#include <mutex>
#include <unordered_map>
#include <vector>

#include "Common.h"

namespace nitroserver {

struct PendingRequest {
  std::mutex mutex;
  std::condition_variable cv;
  bool answered = false;
  bool timedOut = false;
  int64_t status = 500;
  std::vector<Header> headers;
  std::vector<uint8_t> body;

  // Chunked response streams (E7). `answered` doubles as "headers final":
  // startStream sets it, so the route timeout can only win before the first
  // byte — afterwards the stream phase is unbounded and ends with the
  // terminal chunk, a send failure, or stop().
  bool streamStarted = false;
  bool streamDone = false;
  bool streamDead = false;
  std::deque<std::vector<uint8_t>> streamQueue;
};

struct PayloadLog {
  std::vector<std::pair<int64_t, uint8_t*>> payloads;
  int64_t nextSeq = 0;
  int64_t acked = 0;
  /// True once the request entry is gone; the log is removed as soon as
  /// acked catches up with nextSeq.
  bool orphaned = false;
};

/// Thread-safe registry of in-flight requests, keyed by request id.
class PendingTable {
 public:
  std::shared_ptr<PendingRequest> create(int64_t requestId) {
    auto req = std::make_shared<PendingRequest>();
    std::lock_guard<std::mutex> lk(mutex_);
    table_[requestId] = req;
    return req;
  }

  std::shared_ptr<PendingRequest> find(int64_t requestId) {
    std::lock_guard<std::mutex> lk(mutex_);
    auto it = table_.find(requestId);
    return it == table_.end() ? nullptr : it->second;
  }

  /// Drops the request entry. Un-acked payloads survive as an orphaned log
  /// until Dart acks them (see above).
  void erase(int64_t requestId) {
    std::lock_guard<std::mutex> lk(mutex_);
    table_.erase(requestId);
    auto it = payloads_.find(requestId);
    if (it == payloads_.end()) return;
    it->second.orphaned = true;
    if (it->second.acked == it->second.nextSeq) {
      for (auto& p : it->second.payloads) std::free(p.second);
      payloads_.erase(it);
    }
  }

  /// Frees every tracked payload for [requestId] and drops the log. Used
  /// for connection-scoped logs (WebSocket) that no table entry reaps.
  /// Later acks for the id are defined no-ops (see [ack]).
  void dropPayloads(int64_t requestId) {
    std::lock_guard<std::mutex> lk(mutex_);
    auto it = payloads_.find(requestId);
    if (it == payloads_.end()) return;
    for (auto& p : it->second.payloads) std::free(p.second);
    payloads_.erase(it);
  }

  /// Logs a malloc-owned payload, returning its sequence number. The payload
  /// MUST be tracked before the corresponding emit posts, so a later ack can
  /// never reference an untracked sequence.
  int64_t trackPayload(int64_t requestId, uint8_t* ptr) {
    std::lock_guard<std::mutex> lk(mutex_);
    PayloadLog& log = payloads_[requestId];
    const int64_t seq = log.nextSeq++;
    log.payloads.emplace_back(seq, ptr);
    return seq;
  }

  /// Frees every payload with sequence < ackedUpTo. Acks for unknown or fully
  /// reaped logs are no-ops: they reference memory already freed.
  void ack(int64_t requestId, int64_t ackedUpTo) {
    std::lock_guard<std::mutex> lk(mutex_);
    auto it = payloads_.find(requestId);
    if (it == payloads_.end()) return;
    PayloadLog& log = it->second;
    if (ackedUpTo <= log.acked) return;
    log.acked = ackedUpTo;
    auto pit = log.payloads.begin();
    while (pit != log.payloads.end()) {
      if (pit->first < log.acked) {
        std::free(pit->second);
        pit = log.payloads.erase(pit);
      } else {
        ++pit;
      }
    }
    if (log.orphaned && log.acked == log.nextSeq) payloads_.erase(it);
  }

  /// Wakes every parked connection with a 503, then drops all entries and
  /// frees every payload log. Called by stop().
  ///
  /// Safety: connection threads hold their own shared_ptr to the request, so
  /// waking then erasing cannot destroy an object a thread is parked on. Late
  /// `respond`/`ack` calls find nothing and are defined no-ops. Dart-side
  /// decodes are serialized with this on the isolate thread (both arrive as
  /// FFI calls or stream events on the same thread), so no decode can
  /// straddle the free.
  ///
  /// Streaming requests already sent their headers, so a 503 is unframable:
  /// they are marked dead instead, which fails their next chunk wait and
  /// closes the connection.
  void abortAll() {
    std::lock_guard<std::mutex> lk(mutex_);
    for (auto& kv : table_) {
      auto& req = kv.second;
      std::lock_guard<std::mutex> rlk(req->mutex);
      if (!req->answered) {
        req->answered = true;
        req->status = 503;
        req->headers = {{"Content-Type", "text/plain"}};
        static const char kMsg[] = "server stopped";
        req->body.assign(kMsg, kMsg + sizeof(kMsg) - 1);
        req->cv.notify_one();
      } else if (req->streamStarted && !req->streamDone && !req->streamDead) {
        req->streamDead = true;
        req->cv.notify_one();
      }
    }
    table_.clear();
    for (auto& kv : payloads_)
      for (auto& p : kv.second.payloads) std::free(p.second);
    payloads_.clear();
  }

  void clear() {
    std::lock_guard<std::mutex> lk(mutex_);
    table_.clear();
    for (auto& kv : payloads_)
      for (auto& p : kv.second.payloads) std::free(p.second);
    payloads_.clear();
  }

  /// Test seam.
  size_t pendingPayloadsForTesting(int64_t requestId) {
    std::lock_guard<std::mutex> lk(mutex_);
    auto it = payloads_.find(requestId);
    return it == payloads_.end() ? 0 : it->second.payloads.size();
  }

 private:
  std::mutex mutex_;
  std::unordered_map<int64_t, std::shared_ptr<PendingRequest>> table_;
  std::unordered_map<int64_t, PayloadLog> payloads_;
};

}  // namespace nitroserver
