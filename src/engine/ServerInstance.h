// ─────────────────────────────────────────────────────────────────────────────
// ServerInstance — one bound server: config, router, accept loop, workers.
//
// Transport: one worker thread per live connection (bounded pool), blocking
// reads via poll()+recv on non-blocking sockets, and a DIRECT-WRITE answer
// path: the thread that answers — Dart's `respond`, or the worker on
// timeout/stop — serializes the response and writes it to the socket itself.
// The worker never copies the response and never needs a wake to send it.
//
// Concurrency contract (mirrors the spec header):
//   worker: parse → route → emit head → stream body → park in poll() on the
//     socket + its own wake pipe until the answer is on the wire, the
//     ROUTE's timeout fires, or stop().
//   Dart isolate: never blocks. `respond` writes non-blocking; whatever the
//     socket buffer cannot take right now is queued as `tail` and the worker
//     is woken (one pipe byte) to flush it.
// No two requests ever wait on the same primitive, and the Dart thread never
// waits at all — that is the whole deadlock story.
//
// Keep-alive: a connection serves up to maxRequestsPerConn requests back to
// back, gated by the idle timeout. Only clean request/response cycles stay
// alive — any error, timeout or truncated body closes, because resuming a
// connection whose framing is in doubt is how desync bugs are born.
// ─────────────────────────────────────────────────────────────────────────────
#pragma once

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <memory>
#include <mutex>
#include <set>
#include <shared_mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include "Common.h"
#include "PendingTable.h"
#include "Router.h"

namespace nitroserver {

struct ServerConfig {
  std::string host = "127.0.0.1";
  int64_t port = 0;
  int64_t backlog = 128;
  int64_t maxBodyBytes = 10 * 1024 * 1024;
  int64_t defaultTimeoutMs = 30000;
  int64_t keepAliveTimeoutMs = 5000;
  int64_t maxRequestsPerConn = 100;
  /// Cap on the worker pool. The pool starts at min(cores, cap) threads
  /// and grows on demand up to the cap (self-limiting to the live connection
  /// count); idle workers above the floor retire after 10 s. The cap is what
  /// bounds concurrency: with more live keep-alive connections than the cap,
  /// the surplus queue and throughput dips. `<= 0` means max(512, 32 × cores).
  int64_t workerThreads = 0;
  int64_t maxConnections = 0;      // <= 0: unlimited.
  int64_t maxConnectionsPerIp = 0;  // <= 0: unlimited.
  int64_t headerTimeoutMs = 0;      // <= 0: the idle timeout applies.
  int64_t writeTimeoutMs = 30000;   // <= 0: 30 s.
  int64_t wsMaxBufferBytes = 1 << 20;  // <= 0: 1 MiB.
  bool wsCompression = true;
  bool tlsRequested = false;
  // TLS identity (see RawTlsConfig). PEM strings win over file paths.
  std::string tlsCertPem;
  std::string tlsKeyPem;
  std::string tlsCertFile;
  std::string tlsKeyFile;
};

struct StatusResult {
  ErrorKind kind = ErrorKind::None;
  std::string message;
  int64_t boundPort = 0;
};

/// One parsed request head. Views never escape the parse (see WsCodec): the
/// fields that outlive it are owning strings.
struct ParsedHead {
  Method method = Method::Get;
  std::string customMethod;
  std::string target;
  std::string version;
  std::vector<Header> headers;
  bool ok = false;
};

/// Parses one request head; `headEnd` is the offset of its `\r\n\r\n`.
/// Exposed for the fuzz target; the engine calls the same parser.
ParsedHead parseRequestHead(const std::string& raw, size_t headEnd);

/// Sink for request dispatch. Production code posts into the Nitro streams;
/// tests record calls. Payloads passed to emitBodyData are malloc-owned and
/// transfer to the sink, which must have tracked them first.
class Emitter {
 public:
  virtual ~Emitter() = default;
  virtual void emitHead(int64_t requestId, Method method,
                        const std::string& customMethod, const std::string& path,
                        const std::string& query,
                        const std::vector<Header>& headers,
                        int64_t contentLength, bool hasBody,
                        bool bodyComplete,
                        const std::string& routePattern,
                        const std::vector<RouteParam>& params) = 0;
  virtual void emitBodyData(int64_t requestId, uint8_t* payload, size_t n) = 0;
  virtual void emitBodyEnd(int64_t requestId) = 0;
  /// Terminal error chunk. [payload] is malloc-owned and already tracked in
  /// the request's payload log; the sink must emit it with kind=error so the
  /// runner's cumulative ack releases it. May be null (empty message).
  virtual void emitBodyError(int64_t requestId, uint8_t* payload, size_t n,
                             ErrorKind kind) = 0;
  /// One decoded WebSocket event. [payload] is malloc-owned and tracked in
  /// the connection's payload log (freed by the runner's cumulative ack on
  /// the connection id); [opcode] is 1/2/8, [code] the close code on 8.
  virtual void emitWsMessage(int64_t connectionId, uint8_t* payload, size_t n,
                             int opcode, int code) = 0;
  virtual void emitEvent(ServerEventKind kind, int64_t requestId,
                         const std::string& message) = 0;
};

class ServerInstance : public std::enable_shared_from_this<ServerInstance> {
 public:
  ServerInstance() = default;

  /// Replaces every dispatch sink with [emitter] (tests, single runner).
  void setEmitter(Emitter* emitter) {
    std::lock_guard<std::mutex> lk(emitterMutex_);
    emitters_.clear();
    if (emitter) emitters_.push_back(emitter);
  }

  /// Adds a dispatch sink. One per Dart runner: with several isolates
  /// behind one server, requests are dealt round-robin across the sinks
  /// and every message of a request (head, chunks, end, events) goes to
  /// the sink that got its head. Adding an already-bound sink is a no-op.
  void addEmitter(Emitter* emitter) {
    std::lock_guard<std::mutex> lk(emitterMutex_);
    for (Emitter* e : emitters_) {
      if (e == emitter) return;
    }
    emitters_.push_back(emitter);
  }

  /// Drops a sink (its bridge object is going away). Requests that already
  /// captured it finish on it; callers stop the server first.
  void removeEmitter(Emitter* emitter) {
    std::lock_guard<std::mutex> lk(emitterMutex_);
    emitters_.erase(std::remove(emitters_.begin(), emitters_.end(), emitter),
                    emitters_.end());
  }

  /// Number of bound sinks. Test seam.
  size_t emitterCountForTesting() {
    std::lock_guard<std::mutex> lk(emitterMutex_);
    return emitters_.size();
  }

  void configure(const ServerConfig& config);
  StatusResult registerRoute(Method method, const std::string& customMethod,
                             const std::string& pattern, int64_t timeoutMs,
                             bool isWebSocket = false, bool streamBody = false,
                             int64_t maxBodyBytes = -1,
                             const std::string& wsProtocols = "");
  StatusResult unregisterRoute(Method method, const std::string& customMethod,
                               const std::string& pattern);
  /// Registers a route whose answer is fixed: the engine serves [status],
  /// [headers] and [body] itself and never dispatches to a runner. Replaces
  /// any route (handler or static) already at (method, pattern).
  StatusResult registerStaticRoute(Method method,
                                   const std::string& customMethod,
                                   const std::string& pattern, int64_t status,
                                   const std::vector<Header>& headers,
                                   const uint8_t* body, size_t bodyLen);
  StatusResult start();
  void stop();

  /// Graceful shutdown, phase one: no more accepts, every later answer says
  /// `Connection: close`, in-flight requests finish. Idempotent.
  void beginDrain();

  /// Requests dispatched and not yet fully answered.
  int64_t inFlightRequests();

  /// Accepted connections not yet closed.
  int64_t liveConnections() { return liveConnections_.load(); }

  /// Answers with a file: head from the caller's thread, bytes by the
  /// worker (`sendfile` on POSIX). `length < 0` means to the end. A file
  /// that cannot be opened answers 404.
  void respondFile(int64_t requestId, int64_t status,
                   const std::vector<Header>& headers, const std::string& path,
                   int64_t offset, int64_t length);

  /// Serializes and writes the answer on the CALLER's thread (non-blocking;
  /// the remainder, if any, is flushed by the worker). Bridge memory is
  /// never retained. Unknown/already-answered ids are no-ops.
  void respond(int64_t requestId, int64_t status,
               const std::vector<Header>& headers, const uint8_t* body,
               size_t bodyLen);
  /// Starts a chunked response: writes status/headers with
  /// `Transfer-Encoding: chunked` on the caller's thread. Unknown or
  /// already-answered (timeout won) ids are no-ops, so the route timeout
  /// bounds time-to-first-byte.
  void startStream(int64_t requestId, int64_t status,
                   const std::vector<Header>& headers);
  /// Writes one chunk frame on the caller's thread; `last` appends the
  /// terminal chunk and completes the request. Chunks for unknown,
  /// incomplete or dead streams are no-ops.
  void sendStreamChunk(int64_t requestId, const uint8_t* chunk, size_t n,
                       bool last);
  void ackBody(int64_t requestId, int64_t ackedChunks);

  // ── WebSocket sessions ─────────────────────────────────────────────────
  //
  // The connection id is the upgraded request's id. A send writes what the
  // socket takes right now on the calling thread and queues the rest for
  // the session's loop thread, so bridge memory is never retained and the
  // Dart isolate never blocks on a slow peer. Unknown or reaped ids are
  // no-ops.

  /// Sends one message frame (`binary` selects opcode 2 over 1;
  /// `compressed` sets RSV1). Returns the bytes still queued, or -1.
  int64_t wsSend(int64_t connectionId, const uint8_t* payload, size_t n,
                 bool binary, bool compressed);
  /// Queues a close frame, then the loop shuts the socket down and reaps.
  void wsClose(int64_t connectionId, int code);

  bool running() const { return running_.load(); }
  int64_t boundPort() const { return boundPort_.load(); }

  /// Test seam: blocks until no connection is active (or timeout).
  bool waitForDrainForTesting(int64_t timeoutMs);

  /// Test seam: live worker threads right now (the pool auto-scales).
  size_t workersForTesting();

 private:
  /// A worker's wake pipe: the answering thread writes one byte to [w] when
  /// the parked worker must act (flush a tail, close, or serve a queued
  /// pipelined request); the worker drains [r] on every wake.
  struct Wake {
    int r = -1;
    int w = -1;
  };

  /// One iteration of a connection: exactly one request/response cycle.
  /// Returns true when the connection may serve another request.
  /// [cfg] is a snapshot taken once per keep-alive cycle to avoid
  /// re-locking configMutex_ on every request.
  bool serveOne(int fd, const Wake& wake, std::string& carry, int64_t& served,
                const ServerConfig& cfg);

  /// The park: waits in poll() until the answer is fully on the wire (Dart
  /// wrote it, or the worker flushed the tail), the route timeout fires
  /// (408, worker-owned) or stop() handed the worker a 503. Returns true
  /// when the connection may serve another request.
  bool awaitAnswer(int fd, const Wake& wake,
                   const std::shared_ptr<PendingRequest>& req,
                   int64_t requestId, int64_t timeoutMs,
                   const ServerConfig& cfg, Emitter* emitter,
                   bool inputBuffered);

  /// Drains `req->tail` to the socket from the worker (blocking via poll).
  /// Returns false on failure. Marks `done` when nothing is left and the
  /// answer is complete.
  bool flushTail(int fd, const std::shared_ptr<PendingRequest>& req,
                 int64_t stallMs);

  /// Sends the queued file body (`req->fileFd`) from the worker, then marks
  /// the answer done. Returns false on failure.
  bool sendFile(int fd, const std::shared_ptr<PendingRequest>& req,
                int64_t stallMs);

  /// Non-blocking write from the answering thread: writes as much as the
  /// socket takes, queues the rest as `tail` and wakes the worker. Must be
  /// called with `req->writing == true` set under the lock by the caller.
  void writeNow(const std::shared_ptr<PendingRequest>& req,
                const uint8_t* a, size_t an, const uint8_t* b, size_t bn,
                const uint8_t* c, size_t cn, bool completes);

  struct WsConn;

  /// Upgrades a matched WebSocket route: validates the RFC 6455 handshake,
  /// negotiates permessage-deflate, answers 101 and runs the frame loop
  /// until close/error/stop. Always returns false — upgraded connections
  /// never serve HTTP again.
  bool serveUpgrade(int fd, const Wake& wake, const std::string& carry,
                    size_t bodyStart, const ParsedHead& head,
                    const MatchResult& m, const ServerConfig& cfg,
                    const std::string& path, const std::string& query);

  /// The frame loop on a non-blocking socket: parses complete frames from
  /// its buffer, emits messages, answers pings, flushes queued sends and
  /// enforces the write deadline. Ends with an opcode-8 emit (peer code,
  /// 1009 on overflow, 1006 on failure).
  void wsLoop(int fd, const Wake& wake, const std::shared_ptr<WsConn>& conn,
              int64_t connectionId, int64_t maxMessageBytes,
              int64_t writeTimeoutMs);

  /// Writes [n] bytes now if nothing is queued and the socket takes them,
  /// queues the rest and pokes the loop. Any thread. Returns the queue
  /// size after the call, or -1 (closing, failed, or over the cap).
  int64_t wsQueueWrite(const std::shared_ptr<WsConn>& conn,
                       const uint8_t* data, size_t n);

  /// Loop thread: drains the queue as far as the socket allows. False on a
  /// write error.
  bool wsFlush(const std::shared_ptr<WsConn>& conn);

  /// Tracks a malloc-owned WS payload and emits it (freed by the runner's
  /// cumulative ack on the connection id, or by stop()/loop-exit reap).
  void emitWs(Emitter* emitter, int64_t connectionId, int opcode,
              const uint8_t* data, size_t n, int code);

  void acceptLoop();
  void joinAcceptLoop();
#ifdef NITRO_SERVER_TLS
  StatusResult setupTls(const ServerConfig& config);
  bool tlsHandshake(int fd, void* ssl, int64_t timeoutMs);
#endif
  void workerLoop(Wake wake);
  void handleConnection(int fd, const Wake& wake);
  /// Drops the per-peer accounting of a closed fd (caller holds activeMutex_).
  void releasePeerLocked(int fd);
  /// Adds one detached worker (caller holds queueMutex_). Returns false
  /// when no wake pipe could be made.
  bool spawnWorkerLocked();
  /// Parks [fd] at the FRONT of the fd queue (fair: workers pop from the
  /// back) when its socket holds no bytes but queued connections wait.
  /// Returns false when this fd already has data (serve it now) or nothing
  /// is queued (blocking here harms nobody). Never closes: keep-alive and
  /// non-idempotent methods survive a yield untouched.
  bool yieldToQueued(int fd);
  /// Blocking-style write on a non-blocking socket: polls for writability
  /// between partial sends, giving up after [stallMs] without progress.
  static bool sendAll(int fd, const uint8_t* data, size_t n,
                      int64_t stallMs = 30000);

  /// Fast error path. Always closes: errors never keep alive (see header).
  /// [extra] headers ride ahead of the framing headers (e.g.
  /// `Sec-WebSocket-Version` on a 426).
  void answerDirectly(int fd, Method method, int64_t status,
                      const std::string& body,
                      const std::vector<Header>& extra = {});

  /// Serves a static route's fixed answer on the worker thread, framed for
  /// keep-alive like a normal response. A request that carries a body forces
  /// `Connection: close` (a fixed route has no reader for it). Returns whether
  /// the connection may keep serving — i.e. the write succeeded, keep-alive is
  /// in force, and no body was left unread. [carry]'s head bytes are consumed;
  /// [served] is incremented.
  bool answerStatic(int fd, const ParsedHead& head, const StaticResponse& sr,
                    bool keepPeer, int64_t& served, const ServerConfig& cfg,
                    std::string& carry, size_t bodyStart);

  /// Deals the next request's sink: round-robin over the bound sinks, or a
  /// dropping null sink when none is bound. Every message of one request
  /// goes to the sink captured here.
  Emitter* nextEmitter();

  /// Lifecycle events go to every bound sink.
  void broadcastEvent(ServerEventKind kind, int64_t requestId,
                      const std::string& message);

  /// Emits an error chunk (tracked, so the runner's ack frees it) followed by
  /// the end marker for a request whose body will never complete.
  void emitTerminalError(Emitter* emitter, int64_t requestId,
                         const std::string& message, ErrorKind kind);

  std::vector<Emitter*> emitters_;
  std::atomic<uint64_t> emitterRr_{0};
  std::mutex emitterMutex_;
  mutable std::shared_mutex configMutex_;
  ServerConfig config_;
  Router router_;

  std::atomic<bool> running_{false};
  std::atomic<bool> draining_{false};
  std::atomic<int64_t> boundPort_{0};
#ifdef NITRO_SERVER_TLS
  void* sslCtx_ = nullptr;  // SSL_CTX*; opaque here to keep OpenSSL out of the header.
#endif
  int listenFd_ = -1;
  std::thread acceptThread_;
  Wake acceptWake_;
  std::mutex acceptMutex_;

  // Worker pool: bounded queue, auto-scaling detached workers. The accept
  // loop spawns a worker when it queues an fd and none is idle (up to the
  // cap); a worker idle for 10 s retires if the pool is above its floor.
  // The queue bound is the listen backlog — beyond it the engine refuses
  // fast rather than letting the accept loop outrun the workers.
  // All pool state below is guarded by queueMutex_.
  std::mutex queueMutex_;
  std::condition_variable queueCv_;
  std::condition_variable workersGoneCv_;  // stop() waits for count == 0
  std::deque<int> queue_;
  std::vector<Wake> workerWakes_;  // live workers: stop() pokes each
  unsigned workerCount_ = 0;
  unsigned idleWorkers_ = 0;
  unsigned workerFloor_ = 0;
  unsigned workerCap_ = 0;

  // Live connections, so stop() can wake idle keep-alive reads, plus the
  // per-peer counts behind maxConnectionsPerIp. `liveConnections_` counts
  // accepted fds (queued or served) for maxConnections.
  std::mutex activeMutex_;
  std::set<int> activeFds_;
  std::unordered_map<int, std::string> peerOf_;
  std::unordered_map<std::string, int64_t> perPeer_;
  std::atomic<int64_t> liveConnections_{0};

  // Live WebSocket connections by connection id. Entries are erased on
  // loop exit and on wsClose; either order is safe (erase is idempotent).
  // Every field past `emitter` is guarded by `mutex`.
  struct WsConn {
    int fd = -1;
    Emitter* emitter = nullptr;  // the runner that owns the session
    int wakeFd = -1;             // the loop's wake pipe (write end)
    bool deflate = false;        // permessage-deflate negotiated
    int64_t maxBuffer = 0;
    std::mutex mutex;
    std::string outbound;   // queued bytes, in order
    bool flushing = false;  // the loop holds a chunk of `outbound` mid-write
    bool closing = false;   // local close queued: flush, then shut down
    bool overflow = false;  // queue exceeded maxBuffer: close with 1009
    bool failed = false;    // a write failed: drop
  };
  std::mutex wsMutex_;
  std::unordered_map<int64_t, std::shared_ptr<WsConn>> ws_;

  PendingTable pending_;
  std::atomic<int64_t> inFlight_{0};
};

/// Process-global request id source: unique across every server instance.
inline int64_t nextRequestId() {
  static std::atomic<int64_t> counter{0};
  return ++counter;
}

}  // namespace nitroserver
