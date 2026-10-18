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
#include <nghttp2/nghttp2.h>

#include <cstdint>
#include <functional>
#include <string>
#include <unordered_map>
#include <vector>

#include "EngineTypes.h"
#include "Router.h"

namespace nitroserver {

/// One HTTP/2 connection. Not thread-safe: every call happens on the owning
/// reactor's loop thread, the same contract as UvReactor's per-connection state.
class Http2Session {
 public:
  using WriteSink = std::function<void(const uint8_t*, size_t)>;

  Http2Session(Emitter* emitter, const Router& router, WriteSink sink,
               std::string clientIp);
  ~Http2Session();
  Http2Session(const Http2Session&) = delete;
  Http2Session& operator=(const Http2Session&) = delete;

  /// Feed inbound bytes. Runs recv callbacks synchronously, then flushes
  /// outbound frames. Returns false on a fatal session error (caller closes).
  bool feed(const uint8_t* data, size_t len);

  /// The Dart answer path. [requestId] maps back to the h2 stream; [body] is
  /// moved into per-stream state that lives until the data provider hits EOF.
  /// A no-op if the stream was already closed/reset.
  ///
  /// Precondition (reactor integration): the caller must ensure the owning
  /// connection is still live before dispatching here — this class cannot see
  /// the reactor's `running_`/drain state, so a late answer arriving after the
  /// session is torn down must be filtered at the reactor boundary.
  void respond(int64_t requestId, int status, const std::vector<Header>& headers,
               std::string body);

  /// Drain nghttp2's outbound queue to the sink. Called by feed()/respond();
  /// exposed so the reactor can pump after a blocked socket drains.
  void pump();

  bool wantRead() const;   // nghttp2_session_want_read
  bool wantWrite() const;  // nghttp2_session_want_write

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
    std::string body;      // accumulated request body (POST)
    std::string respBody;  // response body; outlives respond() until read EOF
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

  Emitter* emitter_;
  const Router& router_;
  WriteSink sink_;
  std::string clientIp_;
  nghttp2_session* sess_ = nullptr;
  // Per-session request ids, fine standalone. Reactor integration MUST inject
  // the reactor's shared id allocator instead (UvReactor uses one atomic for
  // all conn+request ids) — otherwise ids collide across connections and an
  // answer routes to the wrong one. See docs/http2.md "Remaining" §4.
  int64_t nextId_ = 1;
  // streams_ owns the Stream objects (session_del does not fire on_stream_close
  // for open streams, so the destructor frees whatever remains here).
  std::unordered_map<int32_t, Stream*> streams_;      // h2 stream id -> state
  std::unordered_map<int64_t, int32_t> reqToStream_;  // requestId -> h2 stream id
};

}  // namespace nitroserver
#endif  // NITRO_SERVER_HTTP2
