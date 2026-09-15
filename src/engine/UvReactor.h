// ─────────────────────────────────────────────────────────────────────────────
// UvReactor — libuv event-loop I/O core (replacement for ServerInstance's
// thread-per-connection transport). N loops, one per worker thread, each with a
// SO_REUSEPORT listener; the kernel load-balances accepts. Connection state is
// heap-owned and driven by read events, so a handful of threads serve thousands
// of keep-alive connections flat (the thread-per-connection pool dips past a
// few hundred). Transport-only: it reuses Common.h, Router, and the Emitter
// dispatch unchanged (see Common.h's note).
//
// Answer path: a handler's `respond` runs on the Dart isolate thread, never the
// loop thread. It enqueues the serialized answer and wakes the connection's
// loop with uv_async_send; the loop writes it. Connections are addressed by a
// monotonic id looked up on the loop thread, so a respond that races a close is
// dropped, never a use-after-free.
//
// Stage: HTTP/1.1 request/response + keep-alive + static fast path. Bodies,
// streaming, WebSocket and TLS migrate next; until parity it is built and
// tested alongside the live ServerInstance, not wired to the bridge.
// ─────────────────────────────────────────────────────────────────────────────
#pragma once

#ifdef NITRO_SERVER_LIBUV

#include <uv.h>

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include "Common.h"
#include "PendingTable.h"    // payload lifecycle (trackPayload / ack)
#include "Router.h"
#include "ServerInstance.h"  // Emitter, ServerConfig, StatusResult

namespace nitroserver {

class UvReactor {
 public:
  UvReactor() = default;
  ~UvReactor();

  void setEmitter(Emitter* e) { emitter_ = e; }
  void configure(const ServerConfig& cfg) { cfg_ = cfg; }
  StatusResult registerRoute(const RouteEntry& e);
  StatusResult registerStaticRoute(const RouteEntry& e);

  /// Binds cfg_.port on `loops` threads (default: CPU cores) and starts
  /// serving. boundPort() is valid after this returns None.
  StatusResult start(int loops = 0);
  void stop();
  int64_t boundPort() const { return boundPort_.load(); }
  int64_t liveConnections() const { return liveConns_.load(); }

  /// Answers request [id] from any thread. No-op if the connection is gone.
  void respond(int64_t id, int64_t status, const std::vector<Header>& headers,
               const uint8_t* body, size_t bodyLen);

  /// Releases body-chunk payloads with sequence < [ackedChunks] (the runner's
  /// cumulative ack). Frees native memory; safe from any thread.
  void ackBody(int64_t id, int64_t ackedChunks) { pending_.ack(id, ackedChunks); }

 private:
  struct Conn;
  struct Loop {
    uv_loop_t loop{};
    uv_async_t async{};
    uv_tcp_t server{};
    int fd = -1;
    std::thread thread;
    // Loop-thread-owned: live connections by id.
    std::unordered_map<int64_t, Conn*> conns;
    // Cross-thread inbox: answers waiting to be written on this loop.
    std::mutex qMutex;
    struct Pending {
      int64_t connId;
      std::string bytes;
      bool keepAlive;
    };
    std::vector<Pending> queue;
    bool stopping = false;  // set cross-thread; acted on by onAsync (loop thread)
    UvReactor* owner = nullptr;
  };

  // Carries a write's payload (kept alive until completion) + its conn.
  struct WriteCtx {
    Conn* c;
    std::string* payload;
    bool keepAlive;
  };

  // Where a request lives, for respond() to route the answer to its loop.
  struct ReqLoc {
    int loopIdx;
    int64_t connId;
    bool isHead;
    bool keepAlive;
  };

  static void onConnection(uv_stream_t* server, int status);
  static void onAsync(uv_async_t* async);
  static void allocCb(uv_handle_t* h, size_t suggested, uv_buf_t* b);
  static void readCb(uv_stream_t* s, ssize_t nread, const uv_buf_t* b);
  static void onWrite(uv_write_t* req, int status);
  static void onCloseConn(uv_handle_t* h);
  void runLoop(Loop* lp);
  void processConn(Conn* c);            // parse + dispatch complete requests
  void writeAnswer(Conn* c, std::string bytes, bool keepAlive);  // loop thread
  MatchResult match(Method m, const std::string& custom,
                    const std::string& path) const;

  Emitter* emitter_ = nullptr;
  ServerConfig cfg_;
  Router router_;                        // writer: registration; reader: match
  std::atomic<int64_t> boundPort_{0};
  std::atomic<int64_t> liveConns_{0};
  std::atomic<int64_t> nextReqId_{1};
  std::atomic<int64_t> nextConnId_{1};
  std::atomic<bool> running_{false};
  std::vector<std::unique_ptr<Loop>> loops_;
  PendingTable pending_;  // body-chunk payload logs (freed on ack / stop)

  // reqId -> where to send the answer. Guarded (respond is cross-thread).
  std::mutex reqMutex_;
  std::unordered_map<int64_t, ReqLoc> reqLoc_;
};

}  // namespace nitroserver

#endif  // NITRO_SERVER_LIBUV
