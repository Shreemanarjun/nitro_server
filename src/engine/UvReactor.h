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
// This is the engine: HTTP/1.1 request/response, keep-alive, the static fast
// path, request bodies (Content-Length + chunked), streaming responses,
// WebSocket (permessage-deflate) and TLS all run here, wired to the bridge.
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
#include "DispatchController.h"  // adaptive dispatch-width policy
#include "EngineTypes.h"     // Emitter, ServerConfig, StatusResult, ParsedHead
#include "PendingTable.h"    // payload lifecycle (trackPayload / ack)
#include "Router.h"

namespace nitroserver {

class UvReactor {
 public:
  UvReactor() = default;
  ~UvReactor();

  /// Dispatch sinks — one per Dart isolate. Requests are dealt round-robin
  /// across them; every message of a request goes to the sink that got its head.
  void setEmitter(Emitter* e);
  void addEmitter(Emitter* e);
  void removeEmitter(Emitter* e);
  size_t emitterCountForTesting();
  // Number of event loops (threads) the server started with. Test seam for the
  // workerThreads loop-count cap.
  size_t loopCountForTesting() const { return loops_.size(); }
  // Pin the dispatch width and freeze the adaptive controller, so a test can
  // exercise the raw emitter round-robin (0 = deal across every emitter).
  void setDispatchWidthForTesting(size_t w) {
    dispatchWidth_.store(w, std::memory_order_relaxed);
    ctlEnabled_.store(false, std::memory_order_relaxed);
  }

  void configure(const ServerConfig& cfg) { cfg_ = cfg; }
  StatusResult registerRoute(const RouteEntry& e);
  StatusResult registerStaticRoute(const RouteEntry& e);
  // Bridge-shaped overloads called straight from HybridNitroServer.cpp.
  StatusResult registerRoute(Method method, const std::string& customMethod,
                             const std::string& pattern, int64_t timeoutMs,
                             bool isWebSocket = false, bool streamBody = false,
                             int64_t maxBodyBytes = -1,
                             const std::string& wsProtocols = "");
  StatusResult registerStaticRoute(Method method,
                                   const std::string& customMethod,
                                   const std::string& pattern, int64_t status,
                                   const std::vector<Header>& headers,
                                   const uint8_t* body, size_t bodyLen);
  StatusResult unregisterRoute(Method method, const std::string& customMethod,
                               const std::string& pattern);
  /// Answers [id] with [length] bytes of the file at [path] from [offset]
  /// (`length < 0` = to the end). Read on the calling thread, then written like
  /// a normal response. A file that cannot be opened answers 404.
  void respondFile(int64_t id, int64_t status, const std::vector<Header>& headers,
                   const std::string& path, int64_t offset, int64_t length);

  /// Binds cfg_.port on `loops` threads (default: CPU cores) and starts
  /// serving. boundPort() is valid after this returns None.
  StatusResult start(int loops = 0);
  void stop();
  /// Hot-swaps the TLS certificate/key on a running TLS server: builds a new
  /// SSL_CTX and atomically replaces the live one, so new handshakes use the
  /// new cert while existing connections keep theirs. Fails on a non-TLS build
  /// or a server not started with TLS. Zero-downtime cert rotation.
  StatusResult reloadTls(const std::string& certPem, const std::string& keyPem,
                         const std::string& certFile,
                         const std::string& keyFile);
  /// Graceful shutdown phase one: stop accepting, mark later answers
  /// `Connection: close`; in-flight requests finish. Poll inFlightRequests().
  void beginDrain();
  int64_t boundPort() const { return boundPort_.load(); }
  int64_t liveConnections() const { return liveConns_.load(); }
  /// Handler requests dispatched but not yet answered.
  int64_t inFlightRequests();

  /// Answers request [id] from any thread. No-op if the connection is gone.
  void respond(int64_t id, int64_t status, const std::vector<Header>& headers,
               const uint8_t* body, size_t bodyLen);

  /// Releases body-chunk payloads with sequence < [ackedChunks] (the runner's
  /// cumulative ack). Frees native memory; safe from any thread.
  void ackBody(int64_t id, int64_t ackedChunks) { pending_.ack(id, ackedChunks); }

  /// Sends one WebSocket message (binary or text) on [connId]. Cross-thread.
  /// Returns 0 (no backpressure accounting yet); -1 if the connection is gone.
  int64_t wsSend(int64_t connId, const uint8_t* payload, size_t n, bool binary,
                 bool compressed);
  /// Sends a close frame on [connId] and closes it. Cross-thread.
  void wsClose(int64_t connId, int code);

  /// Starts a chunked response (Transfer-Encoding: chunked). Cross-thread.
  void startStream(int64_t id, int64_t status, const std::vector<Header>& headers);
  /// Writes one chunk frame; [last] appends the terminal chunk and finishes
  /// the request. Cross-thread. An empty non-terminal chunk is skipped.
  void sendStreamChunk(int64_t id, const uint8_t* chunk, size_t n, bool last);

 private:
  struct Conn;
  struct Loop {
    uv_loop_t loop{};
    uv_async_t async{};
    uv_tcp_t server{};
    uv_timer_t sweep{};  // periodic idle/request-deadline sweep (loop thread)
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
      bool finish;  // true = last write of the answer (resume/close after)
      // HTTP/2: when set, onAsync routes this to the connection's Http2Session
      // (respond on the loop thread) instead of writing HTTP/1.1 bytes. `bytes`
      // carries the response body; the head fields ride alongside.
      bool isH2 = false;
      int64_t h2ReqId = 0;
      int h2Status = 0;
      std::vector<Header> h2Headers;
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
    bool finish;  // resume reading / close once this write lands
  };

  // Where a request lives, for respond() to route the answer to its loop.
  struct ReqLoc {
    int loopIdx;
    int64_t connId;
    bool isHead;
    bool keepAlive;
    bool isH2 = false;  // answer routes to the conn's Http2Session, not raw write
  };

  static void onConnection(uv_stream_t* server, int status);
  static void onAsync(uv_async_t* async);
  static void onSweep(uv_timer_t* timer);  // idle/deadline sweep (loop thread)
  static void allocCb(uv_handle_t* h, size_t suggested, uv_buf_t* b);
  static void readCb(uv_stream_t* s, ssize_t nread, const uv_buf_t* b);
  static void onWrite(uv_write_t* req, int status);
  static void onCloseConn(uv_handle_t* h);
  // Release a connection's admission accounting (liveConns_ + per-IP). Idempotent.
  void releaseAdmission(Conn* c);
  void runLoop(Loop* lp);
  void processConn(Conn* c);            // parse + dispatch complete requests
  void emitStreamBytes(Conn* c);        // stream a Content-Length streamBody
  void emitStreamChunked(Conn* c);      // stream a chunked streamBody
  void abortStreamTooLarge(Conn* c);    // chunked upload over the body cap: 413
#ifdef NITRO_SERVER_HTTP2
  void createH2Session(Conn* c);        // attach an Http2Session (loop thread)
  bool feedH2(Conn* c);                 // feed buffered bytes to the session
  int loopIndexOf(const Conn* c) const; // this conn's loop index, for reqLoc
#endif
  void wsProcess(Conn* c);              // decode WebSocket frames (loop thread)
  void wsCloseConn(Conn* c, int code);  // send a close frame + close (loop thread)
#ifdef NITRO_SERVER_TLS
  // TLS over libuv via OpenSSL memory BIOs: ciphertext moves on the socket,
  // plaintext through SSL_read/SSL_write. All on the connection's loop thread.
  StatusResult setupTls();              // build sslCtx_ from cfg_ (once, at start)
  // Build a fresh SSL_CTX from PEM/file material; shared by setupTls/reloadTls.
  // Returns the ctx in [*out] on success, else a TlsError StatusResult.
  StatusResult buildSslCtx(const std::string& certPem, const std::string& keyPem,
                           const std::string& certFile,
                           const std::string& keyFile, void** out);
  bool tlsInit(Conn* c);                // new SSL + memory BIOs for [c]
  void tlsOnRead(Conn* c, const char* data, size_t n);  // decrypt + drive
  std::string tlsDrain(Conn* c);        // pull ciphertext out of the write BIO
  void tlsRawWrite(Conn* c, std::string cipher);        // fire-and-forget write
#endif
  // Loop thread: perform the RFC 6455 handshake, switch [c] to WebSocket mode.
  void wsHandshake(Conn* c, const ParsedHead& head, const MatchResult& m,
                   const std::string& path, const std::string& query);
  // Loop thread: write bytes; when done, resume reading / close iff `finish`.
  void writeAnswer(Conn* c, std::string bytes, bool keepAlive, bool finish);
  // Loop thread: write bytes now without touching request state (100-continue,
  // TLS handshake flights). TLS-aware.
  void writeRaw(Conn* c, std::string bytes);
  // Any thread: hand [bytes] to [loc]'s loop for writing (async wake).
  void pushWrite(const ReqLoc& loc, std::string bytes, bool finish);
  // Any thread: look up request [id]; erases the reqLoc when [erase].
  bool lookupReq(int64_t id, ReqLoc& out, bool erase);
  MatchResult match(Method m, const std::string& custom,
                    const std::string& path) const;
  Emitter* nextEmitter();  // round-robin pick, or null when none bound
  void broadcastEvent(ServerEventKind kind, int64_t requestId,
                      const std::string& message);  // to every sink

  std::mutex emitterMutex_;
  std::vector<Emitter*> emitters_;
  std::atomic<uint64_t> emitterRr_{0};
  // Active dispatch width: heads deal round-robin over the first N emitters
  // only (0 = all). Lets a controller concentrate light handlers on one
  // isolate (others parked, ~0 CPU) and fan CPU-bound handlers out across all.
  std::atomic<size_t> dispatchWidth_{0};

  // Adaptive dispatch: on loop[0]'s sweep, feed the controller this tick's
  // answer count and backlog and publish the width it picks to dispatchWidth_.
  void runDispatchController();
  DispatchController dispatch_;
  std::atomic<int64_t> completions_{0};  // handler answers, bumped in respond
  int64_t ctlLastCompletions_ = 0;       // last value, for the per-tick delta
  // false when NITRO_DISPATCH / the test seam pins the width; read on the sweep
  // thread, written from start() and (in tests) another thread, so atomic.
  std::atomic<bool> ctlEnabled_{true};
  ServerConfig cfg_;
  Router router_;                        // writer: registration; reader: match
  std::atomic<int64_t> boundPort_{0};
  int reservedPort_ = 0;  // app-level port claim, released on stop()
  std::atomic<int64_t> liveConns_{0};
  // One id space for both HTTP request ids and connection ids. They key the
  // same maps downstream — PendingTable (payload logs) here, and the Dart
  // runner's `_pending` map (a WebSocket open is emitted as a head keyed by
  // its connection id). Drawing both from one counter makes every id globally
  // unique, so a connection id can never collide with a request id. Separate
  // counters both starting at 1 caused HTTP requests to be dropped whenever a
  // request id swept past a live WebSocket connection id, and risked a
  // double-free when their PendingTable payload logs aliased.
  std::atomic<int64_t> nextId_{1};
  std::atomic<bool> running_{false};
  std::atomic<bool> draining_{false};
  // SSL_CTX*; opaque here to keep OpenSSL out of the header. Atomic: loop
  // threads read it per accept while reloadTls() may swap it from another.
  std::atomic<void*> sslCtx_{nullptr};
  std::vector<std::unique_ptr<Loop>> loops_;
  PendingTable pending_;  // body-chunk payload logs (freed on ack / stop)

  // reqId -> where to send the answer. Guarded (respond is cross-thread).
  std::mutex reqMutex_;
  std::unordered_map<int64_t, ReqLoc> reqLoc_;
#ifdef NITRO_SERVER_HTTP2
  // h2 has no chunked framing: a streamed response (startStream + chunks) is
  // buffered per request and sent as one DATA body on the terminal chunk.
  // ponytail: buffers the whole streamed body — true per-frame h2 DATA
  // streaming is the documented long-tail. Guarded by reqMutex_.
  struct H2StreamAccum {
    int status = 0;
    std::vector<Header> headers;
    std::string body;
  };
  std::unordered_map<int64_t, H2StreamAccum> h2StreamAccum_;
#endif
  // WebSocket connId -> loop index, for cross-thread wsSend/wsClose routing.
  std::unordered_map<int64_t, int> wsConnLoop_;
  // Live connections per remote IP, for maxConnectionsPerIp. Accepts land on
  // every loop thread, so this shared map is guarded by its own mutex.
  std::mutex ipMutex_;
  std::unordered_map<std::string, int64_t> ipCounts_;
};

}  // namespace nitroserver

#endif  // NITRO_SERVER_LIBUV
