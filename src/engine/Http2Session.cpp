#ifdef NITRO_SERVER_HTTP2
#include "Http2Session.h"

#include <charconv>
#include <cstdlib>
#include <cstring>
#include <string_view>
#include <utility>

#include "Common.h"  // parseMethod
#include "WsCodec.h"  // validUtf8

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
                           std::string clientIp, int64_t maxBodyBytes,
                           IdAllocator allocId, int64_t defaultTimeoutMs,
                           Admit admit, int64_t bodyBudget)
    : emitter_(emitter),
      router_(router),
      sink_(std::move(sink)),
      clientIp_(std::move(clientIp)),
      maxBodyBytes_(maxBodyBytes),
      allocId_(std::move(allocId)),
      defaultTimeoutMs_(defaultTimeoutMs),
      admit_(std::move(admit)),
      bodyBudget_(bodyBudget) {
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
  auto* st = new Stream{};
  st->maxBody = self->maxBodyBytes_;
  st->lastProgress = Clock::now();
  self->streams_[frame->hd.stream_id] = st;
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
  if (!st || st->rejected) return 0;
  const std::string_view n(reinterpret_cast<const char*>(name), namelen);
  const std::string_view v(reinterpret_cast<const char*>(value), valuelen);
  // Same rule as HTTP/1.1: values reach Dart as strings, so a value that is
  // not valid UTF-8 (or a non-ASCII name) is refused 400 here, not stranded.
  if (!ws::validUtf8(value, valuelen)) {
    self->rejectStream(frame->hd.stream_id, st, 400);
    return 0;
  }
  for (size_t i = 0; i < namelen; i++) {
    if (name[i] >= 0x80) {
      self->rejectStream(frame->hd.stream_id, st, 400);
      return 0;
    }
  }
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
  Stream* st = self->streamFor(streamId);
  if (!st || st->rejected) return 0;  // already refused: stop buffering (bound)
  st->lastProgress = Clock::now();
  // Enforce the body cap as it accrues — catches a chunked upload or a client
  // that under-declared content-length. Refuse before the handler ever runs.
  if (st->maxBody > 0 &&
      static_cast<int64_t>(st->body.size() + len) > st->maxBody) {
    self->rejectStream(streamId, st, 413);
    return 0;
  }
  st->body.append(reinterpret_cast<const char*>(data), len);
  return 0;
}

// Emit a complete request to the sink. All body bytes have arrived (END_STREAM),
// so we hand the whole request over synchronously with bodyComplete=true.
// ponytail: buffers the full POST body before a single emitBodyData — fine for
// routing, not for streaming uploads. To stream, move emitHead to the HEADERS
// frame (bodyComplete=false) and emit per onDataChunk; emitBodyEnd on last DATA.
void Http2Session::emitComplete(Stream* st, int32_t streamId) {
  // Engine-answered cases first, before an id or a handler is involved: the
  // global in-flight budget (503), and a path that exists for other methods
  // (405 + Allow, RFC 9110 §15.5.6) — an unregistered path still goes to the
  // runner's not-found handler.
  if (admit_ && !admit_()) {
    rejectStream(streamId, st, 503, {{"retry-after", "1"}});
    return;
  }
  if (!st->matched) {
    const std::vector<std::string> allowed = router_.allowedMethods(st->path);
    if (!allowed.empty()) {
      std::string allow;
      for (const auto& m : allowed) allow += (allow.empty() ? "" : ", ") + m;
      rejectStream(streamId, st, 405, {{"allow", allow}});
      return;
    }
  }
  st->requestId = allocId_ ? allocId_() : nextId_++;
  reqToStream_[st->requestId] = streamId;
  st->emitted = true;
  if (st->timeoutMs > 0) {
    st->deadline = Clock::now() + std::chrono::milliseconds(st->timeoutMs);
    st->hasDeadline = true;
  }
  const bool hasBody = !st->body.empty();
  // bodyComplete MUST be !hasBody: the runner dispatches the handler the moment
  // it sees bodyComplete (server_runner _onHead), so for a POST it must stay
  // false until the body chunk + emitBodyEnd land — matching the HTTP/1.1
  // inline path (UvReactor.cpp). Passing true here drops the request body.
  emitter_->emitHead(st->requestId, st->method, st->customMethod, st->path,
                     st->query, st->headers, st->contentLength, hasBody,
                     /*bodyComplete=*/!hasBody, st->pattern, st->params,
                     clientIp_);
  if (hasBody) {
    auto* payload = static_cast<uint8_t*>(std::malloc(st->body.size()));
    if (payload) {
      std::memcpy(payload, st->body.data(), st->body.size());
      emitter_->emitBodyData(st->requestId, payload, st->body.size());
    }
    st->body.clear();  // handed over: do not hold a second copy until close
    st->body.shrink_to_fit();
  }
  emitter_->emitBodyEnd(st->requestId);
}

int Http2Session::onFrameRecv(nghttp2_session*, const nghttp2_frame* frame,
                              void* user) {
  auto* self = static_cast<Http2Session*>(user);
  // The header block is complete: route now, so the route's own body cap and
  // handler deadline apply to the stream from here on. A declared body over
  // the cap is refused on the HEADERS frame, before the body arrives (parity
  // with the HTTP/1.1 "413 before buffering" path).
  if (frame->hd.type == NGHTTP2_HEADERS &&
      frame->headers.cat == NGHTTP2_HCAT_REQUEST) {
    if (Stream* st = self->streamFor(frame->hd.stream_id)) {
      st->lastProgress = Clock::now();
      const MatchResult m =
          self->router_.match(st->method, st->customMethod, st->path);
      st->matched = m.matched;
      st->timeoutMs = self->defaultTimeoutMs_;
      if (m.matched) {
        st->pattern = m.route->pattern;
        st->params = m.params;
        if (m.route->maxBodyBytes >= 0) st->maxBody = m.route->maxBodyBytes;
        if (m.route->timeoutMs >= 0) st->timeoutMs = m.route->timeoutMs;
      }
      if (!st->rejected && st->maxBody > 0 && st->contentLength > st->maxBody) {
        self->rejectStream(frame->hd.stream_id, st, 413);
      }
      // Session body budget: reserve what this stream may buffer (declared
      // length, else its cap) before any DATA lands. Nothing reserved for a
      // bodyless request. An uncapped, undeclared body cannot be budgeted:
      // it is refused (413) unless the budget is off.
      if (!st->rejected && self->bodyBudget_ > 0) {
        const bool bodyless = (frame->hd.flags & NGHTTP2_FLAG_END_STREAM) != 0;
        const int64_t want = bodyless                ? 0
                             : st->contentLength >= 0 ? st->contentLength
                             : st->maxBody > 0        ? st->maxBody
                                                      : self->bodyBudget_ + 1;
        if (want > self->bodyBudget_) {
          self->rejectStream(frame->hd.stream_id, st, 413);
        } else if (self->reserved_ + want > self->bodyBudget_) {
          self->rejectStream(frame->hd.stream_id, st, 503,
                             {{"retry-after", "1"}});
        } else {
          st->reserved = want;
          self->reserved_ += want;
        }
      }
    }
  }
  // Request complete when END_STREAM lands on the HEADERS (bodyless GET) or the
  // final DATA (POST). nghttp2 has already enforced pseudo-header validity.
  if ((frame->hd.type == NGHTTP2_HEADERS || frame->hd.type == NGHTTP2_DATA) &&
      (frame->hd.flags & NGHTTP2_FLAG_END_STREAM)) {
    if (Stream* st = self->streamFor(frame->hd.stream_id)) {
      if (!st->rejected) self->emitComplete(st, frame->hd.stream_id);
    }
  }
  return 0;
}

// Answer [status] straight from the engine: no handler is (or will be)
// involved, so drop anything buffered and mark the stream so END_STREAM does
// not dispatch it. Only queue the frame here — feed()'s epilogue (or sweep())
// pumps it; mem_send must not be called re-entrantly from a recv callback.
void Http2Session::rejectStream(int32_t streamId, Stream* st, int status,
                                const std::vector<Header>& extra) {
  st->rejected = true;
  st->body.clear();
  st->body.shrink_to_fit();
  st->nvStore.clear();
  st->nva.clear();
  st->nvStore.reserve(1 + extra.size() * 2);
  st->nva.reserve(1 + extra.size());
  st->nvStore.push_back(std::to_string(status));
  static const char kStatus[] = ":status";
  st->nva.push_back({reinterpret_cast<uint8_t*>(const_cast<char*>(kStatus)),
                     reinterpret_cast<uint8_t*>(st->nvStore.back().data()),
                     sizeof(kStatus) - 1, st->nvStore.back().size(),
                     NGHTTP2_NV_FLAG_NONE});
  for (const auto& h : extra) {
    st->nvStore.push_back(h.name);
    st->nvStore.push_back(h.value);
    std::string& nm = st->nvStore[st->nvStore.size() - 2];
    std::string& vl = st->nvStore[st->nvStore.size() - 1];
    st->nva.push_back({reinterpret_cast<uint8_t*>(nm.data()),
                       reinterpret_cast<uint8_t*>(vl.data()), nm.size(),
                       vl.size(), NGHTTP2_NV_FLAG_NONE});
  }
  nghttp2_submit_response(sess_, streamId, st->nva.data(), st->nva.size(),
                          nullptr);
}

void Http2Session::goAway() {
  if (goawaySent_ || stopped_) return;
  goawaySent_ = true;
  nghttp2_submit_goaway(sess_, NGHTTP2_FLAG_NONE,
                        nghttp2_session_get_last_proc_stream_id(sess_),
                        NGHTTP2_NO_ERROR, nullptr, 0);
  pump();
}

std::vector<int64_t> Http2Session::sweep(Clock::time_point now,
                                         int64_t bodyStallMs) {
  std::vector<int64_t> expired;
  if (stopped_) return expired;
  bool queued = false;
  for (auto& kv : streams_) {
    Stream* st = kv.second;
    if (st->rejected) continue;
    if (st->emitted) {
      if (st->hasDeadline && now >= st->deadline) {
        expired.push_back(st->requestId);
        reqToStream_.erase(st->requestId);  // a late respond() is a no-op
        rejectStream(kv.first, st, 408);
        queued = true;
      }
    } else if (bodyStallMs > 0 &&
               now - st->lastProgress >= std::chrono::milliseconds(bodyStallMs)) {
      rejectStream(kv.first, st, 408);  // body stopped arriving
      queued = true;
    }
  }
  if (queued) pump();
  return expired;
}

int Http2Session::onStreamClose(nghttp2_session*, int32_t streamId, uint32_t,
                                void* user) {
  auto* self = static_cast<Http2Session*>(user);
  auto it = self->streams_.find(streamId);
  if (it == self->streams_.end()) return 0;
  self->reserved_ -= it->second->reserved;  // give the budget back
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
  if (stopped_) return;  // draining/torn down: a late answer is a no-op
  const auto it = reqToStream_.find(requestId);
  if (it == reqToStream_.end()) return;  // stream already closed/reset
  const int32_t streamId = it->second;
  Stream* st = streamFor(streamId);
  if (!st) return;
  // A HEAD response carries the same headers a GET would but no body bytes
  // (RFC 9110 §9.3.2), matching the HTTP/1.1 path's HEAD handling.
  const bool isHead = st->method == Method::Head;
  const bool bodyless = status == 204 || status == 304 || (status >= 100 && status < 200);
  st->respBody = (isHead || bodyless) ? std::string{} : std::move(body);
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
  if (stopped_) return false;  // draining/torn down: ignore stray inbound bytes
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
