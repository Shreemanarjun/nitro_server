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

  /// [maxBodyBytes] caps a request body (`<= 0` means unlimited); an over-cap
  /// upload is refused `413` before the handler runs, the h2 analogue of the
  /// HTTP/1.1 cap. [allocId] — see IdAllocator.
  Http2Session(Emitter* emitter, const Router& router, WriteSink sink,
               std::string clientIp, int64_t maxBodyBytes = -1,
               IdAllocator allocId = {});
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
    bool rejected = false;  // over the body cap: 413 sent, do not emit/buffer
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
  void rejectOversize(int32_t streamId, Stream* st);  // 413 + mark rejected

  Emitter* emitter_;
  const Router& router_;
  WriteSink sink_;
  std::string clientIp_;
  int64_t maxBodyBytes_ = -1;  // request body cap; <= 0 = unlimited
  IdAllocator allocId_;        // empty => use the per-session nextId_
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
