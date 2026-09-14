// ─────────────────────────────────────────────────────────────────────────────
// ServerInstance — one bound server: config, router, accept loop, workers.
//
// Transport note: this is a minimal multithreaded blocking-IO HTTP/1.1
// transport with the same shape as oat++'s HttpConnectionHandler (accept →
// dispatch each connection to a worker thread → block the worker until the
// handler answers). The Router, PendingTable and the emit/respond/ack
// protocol above this file are transport-independent; swapping this
// translation unit for an oat++-backed one keeps them untouched.
//
// Concurrency contract (mirrors the spec header):
//   worker: parse → route → emit head → stream body → park on the request's
//     OWN condition variable until respond() or the ROUTE's timeout.
//   Dart isolate: never blocks; answers with respond(requestId, ...).
// No two requests ever wait on the same primitive, and the Dart thread never
// waits at all — that is the whole deadlock story.
//
// Keep-alive: a connection serves up to maxRequestsPerConn requests back to
// back, gated by the idle timeout. Only clean request/response cycles stay
// alive — any error, timeout or truncated body closes, because resuming a
// connection whose framing is in doubt is how desync bugs are born.
// ─────────────────────────────────────────────────────────────────────────────
#pragma once

#include <atomic>
#include <chrono>
#include <cstdint>
#include <memory>
#include <mutex>
#include <set>
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
  int64_t workerThreads = 0;  // <= 0 means one per CPU core.
  bool tlsRequested = false;
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

  /// (Re)binds the dispatch sink. Re-bound on every factory resolve: Dart
  /// caches impls per key, but a disposed-and-recreated instance must emit on
  /// the NEW bridge object, which owns the new stream-port registration.
  void setEmitter(Emitter* emitter) {
    std::lock_guard<std::mutex> lk(emitterMutex_);
    emitter_ = emitter;
  }

  void configure(const ServerConfig& config);
  StatusResult registerRoute(Method method, const std::string& customMethod,
                             const std::string& pattern, int64_t timeoutMs,
                             bool isWebSocket = false);
  StatusResult unregisterRoute(Method method, const std::string& customMethod,
                               const std::string& pattern);
  StatusResult start();
  void stop();

  /// Deep-copies headers/body synchronously (bridge memory dies on return)
  /// and wakes the parked worker. Unknown/already-answered ids are no-ops.
  void respond(int64_t requestId, int64_t status,
               const std::vector<Header>& headers, const uint8_t* body,
               size_t bodyLen);
  /// Starts a chunked response: finalizes status/headers and wakes the
  /// parked worker, which sends them with `Transfer-Encoding: chunked` and
  /// parks again for chunks. Unknown/already-answered (timeout won) ids are
  /// no-ops, so the route timeout bounds time-to-first-byte.
  void startStream(int64_t requestId, int64_t status,
                   const std::vector<Header>& headers);
  /// Queues one stream chunk (deep-copied synchronously); `last` completes
  /// the stream. Chunks for unknown/incomplete/dead streams are no-ops.
  void sendStreamChunk(int64_t requestId, const uint8_t* chunk, size_t n,
                       bool last);
  void ackBody(int64_t requestId, int64_t ackedChunks);

  // ── WebSocket sessions ─────────────────────────────────────────────────
  //
  // The connection id is the upgraded request's id. Sends are synchronous
  // socket writes under [wsSendMutex_], so bridge memory is never retained.
  // Unknown or reaped ids are no-ops.

  /// Sends one message frame (`binary` selects opcode 2 over 1).
  void wsSend(int64_t connectionId, const uint8_t* payload, size_t n,
              bool binary);
  /// Sends a close frame, shuts the socket down and reaps the session.
  void wsClose(int64_t connectionId, int code);

  bool running() const { return running_.load(); }
  int64_t boundPort() const { return boundPort_.load(); }

  /// Test seam: blocks until no connection is active (or timeout).
  bool waitForDrainForTesting(int64_t timeoutMs);

 private:
  /// One iteration of a connection: exactly one request/response cycle.
  /// Returns true when the connection may serve another request.
  bool serveOne(int fd, std::string& carry, int64_t& served);

  /// The chunked tail of serveOne: sends stream headers, then forwards
  /// queued chunks until the terminal marker, a send failure, or stop().
  /// [served] counts this request on every exit. Returns true when the
  /// connection may serve another request.
  bool serveStream(int fd, int64_t requestId, Method method,
                   const std::shared_ptr<PendingRequest>& req,
                   const ServerConfig& cfg, int64_t& served, bool keepPeer);

  /// Upgrades a matched WebSocket route: validates the RFC 6455 handshake,
  /// answers 101 and runs the frame loop until close/error/stop. Always
  /// returns false — upgraded connections never serve HTTP again.
  bool serveUpgrade(int fd, const std::string& carry, size_t bodyStart,
                    const ParsedHead& head, const MatchResult& m,
                    const ServerConfig& cfg, const std::string& path,
                    const std::string& query);

  /// The frame loop: reads client frames, emits decoded messages, auto-pongs.
  /// Ends with an opcode-8 emit (peer code, or 1006 on failure) and reaps.
  void wsLoop(int fd, int64_t connectionId, int64_t maxMessageBytes);

  /// Sends one server frame under [wsSendMutex_]. Synchronous: bridge memory
  /// is never retained, so no copy is needed.
  bool wsSendFrame(int fd, int opcode, const uint8_t* payload, size_t n);

  /// Tracks a malloc-owned WS payload and emits it (freed by the runner's
  /// cumulative ack on the connection id, or by stop()/loop-exit reap).
  void emitWs(int64_t connectionId, int opcode, const uint8_t* data, size_t n,
              int code);

  void acceptLoop();
  void workerLoop();
  void handleConnection(int fd);
  /// Parks [fd] at the FRONT of the fd queue (fair: workers pop from the
  /// back) when its socket holds no bytes but queued connections wait.
  /// Returns false when this fd already has data (serve it now) or nothing
  /// is queued (blocking here harms nobody). Never closes: keep-alive and
  /// non-idempotent methods survive a yield untouched.
  bool yieldToQueued(int fd);
  static bool sendAll(int fd, const uint8_t* data, size_t n);
  /// One chunked-body chunk per call (see serveStream): size line +
  /// payload + CRLF in a single syscall where the platform allows.
  static bool sendFrame(int fd, const char* sizeLine, size_t sizeLen,
                        const uint8_t* payload, size_t n);

  /// Fast error path. Always closes: errors never keep alive (see header).
  /// [extra] headers ride ahead of the framing headers (e.g.
  /// `Sec-WebSocket-Version` on a 426).
  void answerDirectly(int fd, Method method, int64_t status,
                      const std::string& body,
                      const std::vector<Header>& extra = {});

  /// Loads the sink under lock, falling back to a dropping null sink when
  /// unbound. The single-subscriber invariant guarantees a real sink from
  /// the first subscribe, which always precedes start().
  Emitter* lockedEmitter();

  /// Emits an error chunk (tracked, so the runner's ack frees it) followed by
  /// the end marker for a request whose body will never complete.
  void emitTerminalError(int64_t requestId, const std::string& message,
                         ErrorKind kind);

  Emitter* emitter_ = nullptr;
  std::mutex emitterMutex_;
  std::mutex configMutex_;
  ServerConfig config_;
  Router router_;

  std::atomic<bool> running_{false};
  std::atomic<int64_t> boundPort_{0};
  int listenFd_ = -1;
  std::thread acceptThread_;
  std::mutex acceptMutex_;

  // Worker pool: bounded queue, fixed workers. The queue bound is the
  // listen backlog — beyond it the engine refuses fast rather than letting
  // the accept loop outrun the workers.
  std::vector<std::thread> workers_;
  std::mutex queueMutex_;
  std::condition_variable queueCv_;
  std::vector<int> queue_;

  // Live connections, so stop() can wake idle keep-alive reads.
  std::mutex activeMutex_;
  std::set<int> activeFds_;

  // Live WebSocket connections by connection id. Entries are erased on
  // loop exit and on wsClose; either order is safe (erase is idempotent).
  struct WsConn {
    int fd = -1;
  };
  std::mutex wsMutex_;
  std::unordered_map<int64_t, WsConn> ws_;
  // Serializes every socket write that races the frame loop: wsSend/wsClose
  // from the Dart thread against the loop's own pongs and close echoes.
  std::mutex wsSendMutex_;

  PendingTable pending_;
  std::atomic<int64_t> inFlight_{0};
};

/// Process-global request id source: unique across every server instance.
inline int64_t nextRequestId() {
  static std::atomic<int64_t> counter{0};
  return ++counter;
}

}  // namespace nitroserver
