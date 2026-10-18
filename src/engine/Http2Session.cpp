#ifdef NITRO_SERVER_HTTP2
#include "Http2Session.h"

#include <charconv>
#include <cstdlib>
#include <cstring>
#include <string_view>
#include <utility>

#include "Common.h"  // parseMethod

// Use the v1 (ssize_t) nghttp2 API throughout: the ssize_t `*2` forms
// (mem_recv2/mem_send2/submit_response2/data_provider2) do not exist before
// ~1.61, and distros ship older (Ubuntu 24.04 = 1.59). The v1 forms work on
// every version; 1.69+ marks them deprecated, so silence that one warning for
// this translation unit rather than fork the code by version.
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"

namespace nitroserver {

// No C++ exception may cross a C callback — each trampoline is noexcept by shape
// (only non-throwing ops) and returns an nghttp2 error code on trouble.

Http2Session::Http2Session(Emitter* emitter, const Router& router, WriteSink sink,
                           std::string clientIp)
    : emitter_(emitter),
      router_(router),
      sink_(std::move(sink)),
      clientIp_(std::move(clientIp)) {
  nghttp2_session_callbacks* cbs = nullptr;
  nghttp2_session_callbacks_new(&cbs);
  nghttp2_session_callbacks_set_on_begin_headers_callback(cbs, onBeginHeaders);
  nghttp2_session_callbacks_set_on_header_callback(cbs, onHeader);
  nghttp2_session_callbacks_set_on_data_chunk_recv_callback(cbs, onDataChunk);
  nghttp2_session_callbacks_set_on_frame_recv_callback(cbs, onFrameRecv);
  nghttp2_session_callbacks_set_on_stream_close_callback(cbs, onStreamClose);
  nghttp2_session_server_new(&sess_, cbs, this);
  nghttp2_session_callbacks_del(cbs);  // copied into the session; safe to free now
  // The server connection preface is a SETTINGS frame; queue it so the first
  // pump() emits it ahead of any response. MAX_HEADER_LIST_SIZE caps the
  // decompressed header block so nghttp2 rejects a HEADERS/CONTINUATION flood
  // (HPACK bomb) before it buffers unbounded into a stream.
  const nghttp2_settings_entry iv[] = {
      {NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS, 128},
      {NGHTTP2_SETTINGS_MAX_HEADER_LIST_SIZE, 32768}};
  nghttp2_submit_settings(sess_, NGHTTP2_FLAG_NONE, iv, 2);
}

Http2Session::~Http2Session() {
  for (auto& kv : streams_) delete kv.second;  // free streams still open at close
  if (sess_) nghttp2_session_del(sess_);
}

Http2Session::Stream* Http2Session::streamFor(int32_t streamId) {
  auto it = streams_.find(streamId);
  return it == streams_.end() ? nullptr : it->second;
}

int Http2Session::onBeginHeaders(nghttp2_session*, const nghttp2_frame* frame,
                                 void* user) {
  // A new request stream (not trailers, which arrive as HCAT_HEADERS).
  if (frame->hd.type != NGHTTP2_HEADERS ||
      frame->headers.cat != NGHTTP2_HCAT_REQUEST) {
    return 0;
  }
  auto* self = static_cast<Http2Session*>(user);
  self->streams_[frame->hd.stream_id] = new Stream{};
  return 0;
}

int Http2Session::onHeader(nghttp2_session*, const nghttp2_frame* frame,
                           const uint8_t* name, size_t namelen,
                           const uint8_t* value, size_t valuelen, uint8_t,
                           void* user) {
  auto* self = static_cast<Http2Session*>(user);
  // Only request headers build the head; trailing HEADERS (HCAT_HEADERS) after
  // the body must not be folded into st->headers as if they were request fields.
  if (frame->headers.cat != NGHTTP2_HCAT_REQUEST) return 0;
  Stream* st = self->streamFor(frame->hd.stream_id);
  if (!st) return 0;
  const std::string_view n(reinterpret_cast<const char*>(name), namelen);
  const std::string_view v(reinterpret_cast<const char*>(value), valuelen);
  if (n == ":method") {
    st->method = parseMethod(v, st->customMethod);
  } else if (n == ":path") {
    // Split the target into path and query (nghttp2 validated it is non-empty).
    const size_t q = v.find('?');
    if (q == std::string_view::npos) {
      st->path.assign(v);
    } else {
      st->path.assign(v.substr(0, q));
      st->query.assign(v.substr(q + 1));
    }
  } else if (n == ":scheme") {
    st->scheme.assign(v);
  } else if (n == ":authority") {
    st->authority.assign(v);
  } else {
    if (n == "content-length") {
      // Validate: a non-negative integer consuming the whole value. Anything
      // else (negative, overflow, trailing garbage) is left as -1 = unknown,
      // so an attacker-chosen int64 never reaches a handler that trusts it.
      long long cl = 0;
      const char* begin = v.data();
      const char* end = begin + v.size();
      const auto res = std::from_chars(begin, end, cl);
      st->contentLength =
          (res.ec == std::errc{} && res.ptr == end && cl >= 0) ? cl : -1;
    }
    st->headers.push_back({std::string(n), std::string(v)});
  }
  return 0;
}

int Http2Session::onDataChunk(nghttp2_session*, uint8_t, int32_t streamId,
                              const uint8_t* data, size_t len, void* user) {
  auto* self = static_cast<Http2Session*>(user);
  if (Stream* st = self->streamFor(streamId)) {
    st->body.append(reinterpret_cast<const char*>(data), len);
  }
  return 0;
}

// Emit a complete request to the sink. All body bytes have arrived (END_STREAM),
// so we hand the whole request over synchronously with bodyComplete=true.
// ponytail: buffers the full POST body before a single emitBodyData — fine for
// routing, not for streaming uploads. To stream, move emitHead to the HEADERS
// frame (bodyComplete=false) and emit per onDataChunk; emitBodyEnd on last DATA.
void Http2Session::emitComplete(Stream* st, int32_t streamId) {
  st->requestId = nextId_++;
  reqToStream_[st->requestId] = streamId;
  const MatchResult m = router_.match(st->method, st->customMethod, st->path);
  const bool hasBody = !st->body.empty();
  // bodyComplete MUST be !hasBody: the runner dispatches the handler the moment
  // it sees bodyComplete (server_runner _onHead), so for a POST it must stay
  // false until the body chunk + emitBodyEnd land — matching the HTTP/1.1
  // inline path (UvReactor.cpp). Passing true here drops the request body.
  emitter_->emitHead(st->requestId, st->method, st->customMethod, st->path,
                     st->query, st->headers, st->contentLength, hasBody,
                     /*bodyComplete=*/!hasBody, m.matched ? m.route->pattern : "",
                     m.params, clientIp_);
  if (hasBody) {
    auto* payload = static_cast<uint8_t*>(std::malloc(st->body.size()));
    if (payload) {
      std::memcpy(payload, st->body.data(), st->body.size());
      emitter_->emitBodyData(st->requestId, payload, st->body.size());
    }
  }
  emitter_->emitBodyEnd(st->requestId);
}

int Http2Session::onFrameRecv(nghttp2_session*, const nghttp2_frame* frame,
                              void* user) {
  // Request complete when END_STREAM lands on the HEADERS (bodyless GET) or the
  // final DATA (POST). nghttp2 has already enforced pseudo-header validity.
  if ((frame->hd.type == NGHTTP2_HEADERS || frame->hd.type == NGHTTP2_DATA) &&
      (frame->hd.flags & NGHTTP2_FLAG_END_STREAM)) {
    auto* self = static_cast<Http2Session*>(user);
    if (Stream* st = self->streamFor(frame->hd.stream_id)) {
      self->emitComplete(st, frame->hd.stream_id);
    }
  }
  return 0;
}

int Http2Session::onStreamClose(nghttp2_session*, int32_t streamId, uint32_t,
                                void* user) {
  auto* self = static_cast<Http2Session*>(user);
  auto it = self->streams_.find(streamId);
  if (it == self->streams_.end()) return 0;
  self->reqToStream_.erase(it->second->requestId);
  delete it->second;
  self->streams_.erase(it);
  return 0;
}

ssize_t Http2Session::readBody(nghttp2_session*, int32_t, uint8_t* buf,
                                     size_t length, uint32_t* data_flags,
                                     nghttp2_data_source* source, void*) {
  auto* st = static_cast<Stream*>(source->ptr);
  const size_t n = std::min(length, st->respBody.size() - st->respOff);
  std::memcpy(buf, st->respBody.data() + st->respOff, n);
  st->respOff += n;
  if (st->respOff == st->respBody.size()) *data_flags |= NGHTTP2_DATA_FLAG_EOF;
  return static_cast<ssize_t>(n);
}

void Http2Session::respond(int64_t requestId, int status,
                           const std::vector<Header>& headers,
                           std::string body) {
  const auto it = reqToStream_.find(requestId);
  if (it == reqToStream_.end()) return;  // stream already closed/reset
  const int32_t streamId = it->second;
  Stream* st = streamFor(streamId);
  if (!st) return;
  st->respBody = std::move(body);
  st->respOff = 0;

  // Build the nghttp2_nv array: :status first, then regular headers. The
  // backing strings live in nvStore, reserved up front so .data() pointers
  // captured into nva never dangle through the push_back loop. submit_response2
  // with flags=0 copies every name/value immediately, so nva/nvStore may die
  // right after the call — only respBody must persist (it does, on Stream).
  st->nva.clear();
  st->nvStore.clear();
  st->nvStore.reserve(1 + headers.size() * 2);
  st->nva.reserve(1 + headers.size());
  st->nvStore.push_back(std::to_string(status));
  static const char kStatus[] = ":status";
  st->nva.push_back({reinterpret_cast<uint8_t*>(const_cast<char*>(kStatus)),
                     reinterpret_cast<uint8_t*>(st->nvStore.back().data()),
                     sizeof(kStatus) - 1, st->nvStore.back().size(),
                     NGHTTP2_NV_FLAG_NONE});
  for (const auto& h : headers) {
    st->nvStore.push_back(h.name);
    st->nvStore.push_back(h.value);
    std::string& nm = st->nvStore[st->nvStore.size() - 2];
    std::string& vl = st->nvStore[st->nvStore.size() - 1];
    st->nva.push_back({reinterpret_cast<uint8_t*>(nm.data()),
                       reinterpret_cast<uint8_t*>(vl.data()), nm.size(),
                       vl.size(), NGHTTP2_NV_FLAG_NONE});
  }
  nghttp2_data_provider prd{};
  const bool hasBody = !st->respBody.empty();
  if (hasBody) {
    prd.source.ptr = st;
    prd.read_callback = readBody;
  }
  nghttp2_submit_response(sess_, streamId, st->nva.data(), st->nva.size(),
                           hasBody ? &prd : nullptr);
  pump();
}

void Http2Session::pump() {
  const uint8_t* out = nullptr;
  for (ssize_t n; (n = nghttp2_session_mem_send(sess_, &out)) > 0;) {
    // The buffer is valid only until the next mem_send2, so the sink must copy
    // or write it now (the reactor's write path does).
    sink_(out, static_cast<size_t>(n));
  }
}

bool Http2Session::feed(const uint8_t* data, size_t len) {
  const ssize_t rv = nghttp2_session_mem_recv(sess_, data, len);
  if (rv < 0) return false;  // fatal: caller tears the connection down
  pump();
  return true;
}

bool Http2Session::wantRead() const {
  return nghttp2_session_want_read(sess_) != 0;
}

bool Http2Session::wantWrite() const {
  return nghttp2_session_want_write(sess_) != 0;
}

}  // namespace nitroserver
#endif  // NITRO_SERVER_HTTP2
