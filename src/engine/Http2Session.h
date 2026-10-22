#pragma once
#ifdef NITRO_SERVER_HTTP2
// One HTTP/2 connection: the h2 analogue of UvReactor's HTTP/1.1 request path.
// Inbound frames become Emitter::emitHead/emitBodyData/emitBodyEnd; the Dart
// answer path (respond) becomes nghttp2_submit_response2. Bytes move through
// two std::function seams (feed() in, a WriteSink out) so the class is
// socket-agnostic and testable with no sockets (see test/cpp/http2_session_test).
//
// Gated entirely on NITRO_SERVER_HTTP2: a default build never includes
// <nghttp2/nghttp2.h> nor compiles any of this.
//
// MSVC has no POSIX `ssize_t`, and nghttp2's v1 API (which this session uses)
// is typed in terms of it — as is this file's own readBody/mem_send/mem_recv.
// Define it before the nghttp2 include, reusing libuv's `_SSIZE_T_DEFINED`
// sentinel (uv/win.h sets the same one) so a TU that sees both headers gets no
// C2371 redefinition. SSIZE_T is intptr_t-wide (64-bit on x64), matching libuv.
#if defined(_WIN32) && !defined(_SSIZE_T_DEFINED)
#include <BaseTsd.h>
typedef SSIZE_T ssize_t;
#define _SSIZE_T_DEFINED
#endif
#include <nghttp2/nghttp2.h>

#include <cstdint>
#include <chrono>
#include <functional>
#include <string>
#include <unordered_map>
#include <vector>

#include "EngineTypes.h"
#include "ProtocolSession.h"
#include "Router.h"

namespace nitroserver {

/// One HTTP/2 connection — the nghttp2-backed [ProtocolSession]. Not thread-safe:
/// every call happens on the owning reactor's loop thread, the same contract as
/// UvReactor's per-connection state.
class Http2Session final : public ProtocolSession {
 public:
  /// Allocates the request id passed to the Emitter. Reactor integration injects
  /// the reactor's shared counter so ids are unique across every connection; the
  /// default (empty) uses a per-session counter, correct for a lone session.
  using IdAllocator = std::function<int64_t()>;
  using Clock = std::chrono::steady_clock;
  /// Admission check run before a complete request is dispatched; false
  /// answers it `503` (the reactor's global in-flight budget).
  using Admit = std::function<bool()>;

  /// [maxBodyBytes] caps a request body (`<= 0` means unlimited); an over-cap
  /// upload is refused `413` before the handler runs, the h2 analogue of the
  /// HTTP/1.1 cap — a route's own `maxBodyBytes` overrides it once the HEADERS
  /// frame has routed the stream. [allocId] — see IdAllocator.
  /// [defaultTimeoutMs] is the handler deadline a route without its own
  /// inherits (`<= 0`: none); see [sweep]. [admit] — see Admit. [bodyBudget]
  /// caps the request-body bytes held across streams (`<= 0`: unlimited): a
  /// stream over the remaining budget is answered 503, one larger than the
  /// whole budget 413.
  Http2Session(Emitter* emitter, const Router& router, WriteSink sink,
               std::string clientIp, int64_t maxBodyBytes = -1,
               IdAllocator allocId = {}, int64_t defaultTimeoutMs = 0,
               Admit admit = {}, int64_t bodyBudget = 0);
  ~Http2Session();
  Http2Session(const Http2Session&) = delete;
  Http2Session& operator=(const Http2Session&) = delete;

  /// Feed inbound bytes. Runs recv callbacks synchronously, then flushes
  /// outbound frames. Returns false on a fatal session error (caller closes).
  bool feed(const uint8_t* data, size_t len) override;

  /// The Dart answer path. [requestId] maps back to the h2 stream; [body] is
  /// moved into per-stream state that lives until the data provider hits EOF.
  /// A no-op if the stream was already closed/reset, or after [stop].
  void respond(int64_t requestId, int status, const std::vector<Header>& headers,
               std::string body) override;

  /// Marks the session shutting down: [feed] and [respond] become no-ops. The
  /// reactor calls this on drain/teardown so a late answer (or stray inbound
  /// bytes) arriving in the stop window can never drive a half-dead session —
  /// the liveness guard the standalone class can own without seeing `running_`.
  void stop() override { stopped_ = true; }

  /// Drain nghttp2's outbound queue to the sink. Called by feed()/respond();
  /// exposed so the reactor can pump after a blocked socket drains.
  void pump() override;

  bool wantRead() const override;   // nghttp2_session_want_read
  bool wantWrite() const override;  // nghttp2_session_want_write

  /// True while any request stream is still open — emitted to a handler but not
  /// yet fully answered. The reactor must not tear a connection down in this
  /// window: between a request completing and its async respond() landing,
  /// nghttp2 can transiently report neither want-read nor want-write, and
  /// closing then drops the in-flight response (seen as an h2c reset under load
  /// on a fast peer). Streams are erased in onStreamClose, after END_STREAM.
  bool hasOpenStreams() const { return !streams_.empty(); }

  /// Graceful shutdown (RFC 9113 §6.8): sends GOAWAY naming the last stream
  /// this side processed, so the peer opens no more and in-flight streams
  /// finish; once they have, [wantRead]/[wantWrite] both turn false and the
  /// reactor closes the connection. Idempotent. Loop thread, never from inside
  /// an nghttp2 callback.
  void goAway();
  bool goAwaySent() const { return goawaySent_; }

  /// Deadline sweep, called by the reactor's timer (loop thread, outside any
  /// callback). A dispatched stream whose handler has missed its deadline is
  /// answered `408` and its request id returned, so the reactor can retire
  /// the id (a late respond() is then a no-op) and report the timeout. A
  /// stream still receiving its body with no DATA for [bodyStallMs] (`<= 0`:
  /// never) is answered `408` as well (not returned: never dispatched).
  std::vector<int64_t> sweep(Clock::time_point now, int64_t bodyStallMs);

 private:
  struct Stream {
    int64_t requestId = 0;
    Method method = Method::Get;
    std::string customMethod;
    std::string path;
    std::string query;
    std::string scheme;
    std::string authority;
    std::vector<Header> headers;
    int64_t contentLength = -1;
    bool rejected = false;  // answered by the engine (413/405/408/503): no emit
    bool matched = false;   // router result, taken on the HEADERS frame
    std::string pattern;    // matched route pattern ("" when unmatched)
    std::vector<RouteParam> params;
    int64_t maxBody = -1;   // effective body cap (route's, else the session's)
    int64_t reserved = 0;   // body bytes reserved from the session's budget
    int64_t timeoutMs = 0;  // handler deadline once dispatched (<= 0: none)
    bool emitted = false;   // handed to the emitter (request id allocated)
    bool hasDeadline = false;
    Clock::time_point deadline;      // valid while emitted && hasDeadline
    Clock::time_point lastProgress;  // last HEADERS/DATA byte (body stall)
    std::string body;       // accumulated request body (POST)
    std::string respBody;   // response body; outlives respond() until read EOF
    size_t respOff = 0;
    std::vector<nghttp2_nv> nva;       // scratch for submit_response2
    std::vector<std::string> nvStore;  // backing bytes for nva
  };

  // C trampolines: `this` arrives as user_data (the server_new 3rd arg).
  static int onBeginHeaders(nghttp2_session*, const nghttp2_frame*, void*);
  static int onHeader(nghttp2_session*, const nghttp2_frame*, const uint8_t*,
                      size_t, const uint8_t*, size_t, uint8_t, void*);
  static int onDataChunk(nghttp2_session*, uint8_t, int32_t, const uint8_t*,
                         size_t, void*);
  static int onFrameRecv(nghttp2_session*, const nghttp2_frame*, void*);
  static int onStreamClose(nghttp2_session*, int32_t, uint32_t, void*);
  // v1 (ssize_t) data-source callback: available in every nghttp2 version,
  // unlike the nghttp2_ssize `*2` forms (absent before ~1.61). See the .cpp.
  static ssize_t readBody(nghttp2_session*, int32_t, uint8_t*, size_t, uint32_t*,
                          nghttp2_data_source*, void*);

  Stream* streamFor(int32_t streamId);
  void emitComplete(Stream* st, int32_t streamId);
  // Answer [status] from the engine (no handler) and mark the stream rejected
  // so nothing is emitted or buffered for it. Only queues the frame: the
  // caller pumps (feed()'s epilogue, or sweep()).
  void rejectStream(int32_t streamId, Stream* st, int status,
                    const std::vector<Header>& extra = {});

  Emitter* emitter_;
  const Router& router_;
  WriteSink sink_;
  std::string clientIp_;
  int64_t maxBodyBytes_ = -1;  // request body cap; <= 0 = unlimited
  IdAllocator allocId_;        // empty => use the per-session nextId_
  int64_t defaultTimeoutMs_ = 0;
  Admit admit_;                // empty => always admit
  // Request-body budget across the session's streams (<= 0: unlimited): a
  // stream reserves its declared Content-Length — its body cap when
  // undeclared — on its HEADERS frame and releases it when it closes. The
  // session therefore never holds more than bodyBudget_ of request bodies.
  int64_t bodyBudget_ = 0;
  int64_t reserved_ = 0;
  bool goawaySent_ = false;
  bool stopped_ = false;       // set by stop(): feed/respond become no-ops
  nghttp2_session* sess_ = nullptr;
  int64_t nextId_ = 1;  // fallback id source when allocId_ is empty
  // streams_ owns the Stream objects (session_del does not fire on_stream_close
  // for open streams, so the destructor frees whatever remains here).
  std::unordered_map<int32_t, Stream*> streams_;      // h2 stream id -> state
  std::unordered_map<int64_t, int32_t> reqToStream_;  // requestId -> h2 stream id
};

}  // namespace nitroserver
#endif  // NITRO_SERVER_HTTP2
