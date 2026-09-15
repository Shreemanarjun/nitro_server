#include "UvReactor.h"

#ifdef NITRO_SERVER_LIBUV

#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cstring>

namespace nitroserver {
namespace {

// ── Small HTTP helpers (self-contained; the live engine keeps its own copies
// until the reactor replaces it, at which point these are the survivors). ─────

const Header* uvFindHeader(const std::vector<Header>& hs, const char* name) {
  for (const auto& h : hs) {
    if (h.name.size() == std::strlen(name)) {
      bool eq = true;
      for (size_t i = 0; i < h.name.size(); i++) {
        char a = h.name[i], b = name[i];
        if (a >= 'A' && a <= 'Z') a += 32;
        if (b >= 'A' && b <= 'Z') b += 32;
        if (a != b) { eq = false; break; }
      }
      if (eq) return &h;
    }
  }
  return nullptr;
}

bool uvIequals(const std::string& a, const char* b) {
  if (a.size() != std::strlen(b)) return false;
  for (size_t i = 0; i < a.size(); i++) {
    char x = a[i], y = b[i];
    if (x >= 'A' && x <= 'Z') x += 32;
    if (y >= 'A' && y <= 'Z') y += 32;
    if (x != y) return false;
  }
  return true;
}

// Response head with engine framing (Content-Length + Connection); caller
// headers minus content-length/connection ride ahead.
std::string uvBuildHead(int64_t status, const std::vector<Header>& headers,
                      int64_t contentLength, bool keepAlive,
                      int64_t keepAliveSecs) {
  std::string out;
  out.reserve(160);
  out.append("HTTP/1.1 ");
  out.append(std::to_string(status));
  out.push_back(' ');
  out.append(reasonPhrase(status));
  out.append("\r\n");
  for (const auto& h : headers) {
    if (uvIequals(h.name, "content-length")) continue;
    if (uvIequals(h.name, "connection")) continue;
    out.append(h.name);
    out.append(": ");
    out.append(h.value);
    out.append("\r\n");
  }
  out.append("Content-Length: ");
  out.append(std::to_string(contentLength));
  out.append("\r\n");
  if (keepAlive) {
    out.append("Connection: keep-alive\r\nKeep-Alive: timeout=");
    out.append(std::to_string(keepAliveSecs));
    out.append("\r\n\r\n");
  } else {
    out.append("Connection: close\r\n\r\n");
  }
  return out;
}

// HTTP/1.1 keeps alive unless the client said close; HTTP/1.0 only on request.
bool uvClientWantsKeepAlive(const ParsedHead& head) {
  const Header* conn = uvFindHeader(head.headers, "connection");
  const bool http10 = head.version == "HTTP/1.0";
  if (conn) {
    if (conn->value.find("close") != std::string::npos ||
        conn->value.find("Close") != std::string::npos)
      return false;
    if (conn->value.find("keep-alive") != std::string::npos ||
        conn->value.find("Keep-Alive") != std::string::npos)
      return true;
  }
  return !http10;
}

}  // namespace

// ── Per-connection state (heap-owned; loop thread owns it) ───────────────────
struct UvReactor::Conn {
  uv_tcp_t handle{};
  Loop* lp = nullptr;
  int64_t id = 0;
  std::string buf;   // accumulated request bytes
  bool busy = false;  // a request is awaiting its answer (ordered per conn)
  bool closing = false;
};

UvReactor::~UvReactor() { stop(); }

StatusResult UvReactor::registerRoute(const RouteEntry& e) {
  if (!router_.add(e)) return {ErrorKind::BadRequest, "invalid route", 0};
  return {};
}

StatusResult UvReactor::registerStaticRoute(const RouteEntry& e) {
  if (!router_.add(e)) return {ErrorKind::BadRequest, "invalid route", 0};
  return {};
}

MatchResult UvReactor::match(Method m, const std::string& custom,
                             const std::string& path) const {
  return router_.match(m, custom, path);
}

StatusResult UvReactor::start(int loops) {
  if (running_.exchange(true)) return {ErrorKind::AlreadyRunning, "running", 0};
  unsigned cores = std::thread::hardware_concurrency();
  int n = loops > 0 ? loops : (cores == 0 ? 4 : (int)cores);
  boundPort_.store(cfg_.port);

  for (int i = 0; i < n; i++) {
    auto lp = std::make_unique<Loop>();
    lp->owner = this;
    uv_loop_init(&lp->loop);
    lp->async.data = lp.get();
    uv_async_init(&lp->loop, &lp->async, &UvReactor::onAsync);

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one));
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)cfg_.port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (sockaddr*)&addr, sizeof(addr)) != 0) {
      close(fd);
      running_.store(false);
      return {ErrorKind::BindFailed, "bind failed", 0};
    }
    // Read back the OS-assigned port from the first socket (port 0 case).
    if (i == 0) {
      sockaddr_in bound{};
      socklen_t bl = sizeof(bound);
      getsockname(fd, (sockaddr*)&bound, &bl);
      boundPort_.store(ntohs(bound.sin_port));
      cfg_.port = boundPort_.load();  // pin so later loops bind the same port
    }
    listen(fd, cfg_.backlog > 0 ? (int)cfg_.backlog : 128);
    lp->fd = fd;
    lp->server.data = lp.get();
    uv_tcp_init(&lp->loop, &lp->server);
    uv_tcp_open(&lp->server, fd);
    uv_listen((uv_stream_t*)&lp->server, cfg_.backlog > 0 ? (int)cfg_.backlog : 128,
              &UvReactor::onConnection);
    loops_.push_back(std::move(lp));
  }
  for (auto& lp : loops_) {
    Loop* raw = lp.get();
    raw->thread = std::thread([this, raw] { runLoop(raw); });
  }
  return {};
}

void UvReactor::runLoop(Loop* lp) { uv_run(&lp->loop, UV_RUN_DEFAULT); }

void UvReactor::onConnection(uv_stream_t* server, int status) {
  if (status < 0) return;
  Loop* lp = (Loop*)server->data;
  Conn* c = new Conn();
  c->lp = lp;
  c->id = lp->owner->nextConnId_.fetch_add(1);
  c->handle.data = c;
  uv_tcp_init(&lp->loop, &c->handle);
  if (uv_accept(server, (uv_stream_t*)&c->handle) == 0) {
    uv_tcp_nodelay(&c->handle, 1);
    lp->conns[c->id] = c;
    lp->owner->liveConns_.fetch_add(1);
    uv_read_start((uv_stream_t*)&c->handle, &UvReactor::allocCb,
                  &UvReactor::readCb);
  } else {
    uv_close((uv_handle_t*)&c->handle, &UvReactor::onCloseConn);
  }
}

void UvReactor::allocCb(uv_handle_t* h, size_t suggested, uv_buf_t* b) {
  (void)h;
  static thread_local std::vector<char> scratch;
  if (scratch.size() < suggested) scratch.resize(suggested < 65536 ? 65536 : suggested);
  *b = uv_buf_init(scratch.data(), (unsigned)scratch.size());
}

void UvReactor::onCloseConn(uv_handle_t* h) {
  Conn* c = (Conn*)h;
  if (c->lp) {
    c->lp->conns.erase(c->id);
    c->lp->owner->liveConns_.fetch_sub(1);
  }
  delete c;
}

void UvReactor::readCb(uv_stream_t* s, ssize_t nread, const uv_buf_t* b) {
  Conn* c = (Conn*)s;
  if (nread < 0) {
    c->closing = true;
    uv_close((uv_handle_t*)s, &UvReactor::onCloseConn);
    return;
  }
  if (nread == 0) return;
  c->buf.append(b->base, (size_t)nread);
  c->lp->owner->processConn(c);
}

// Loop thread: dispatch complete buffered requests until one is in flight.
void UvReactor::processConn(Conn* c) {
  while (!c->busy && !c->closing) {
    const size_t headEnd = c->buf.find("\r\n\r\n");
    if (headEnd == std::string::npos) {
      if (c->buf.size() > 64 * 1024) {  // header flood
        c->closing = true;
        uv_close((uv_handle_t*)&c->handle, &UvReactor::onCloseConn);
      }
      return;
    }
    ParsedHead head = parseRequestHead(c->buf, headEnd);
    if (!head.ok) {
      writeAnswer(c, uvBuildHead(400, {}, 0, false, 0), false);
      return;
    }
    // Body: Content-Length is read whole into the connection buffer, then
    // emitted as one inline chunk (the common POST). Chunked and true streaming
    // uploads migrate in a later stage.
    int64_t clen = 0;
    if (const Header* cl = uvFindHeader(head.headers, "content-length"))
      clen = std::strtoll(cl->value.c_str(), nullptr, 10);
    if (clen < 0) {  // malformed Content-Length
      writeAnswer(c, uvBuildHead(400, {}, 0, false, 0), false);
      return;
    }
    const int64_t maxBody = cfg_.maxBodyBytes > 0 ? cfg_.maxBodyBytes : (10 << 20);
    if (clen > maxBody) {  // over the cap: refuse before buffering the rest
      writeAnswer(c, uvBuildHead(413, {}, 0, false, 0), false);
      return;
    }
    const size_t reqEnd = headEnd + 4 + (size_t)clen;
    if (c->buf.size() < reqEnd) return;  // await the rest of the body

    std::string path = head.target;
    std::string query;
    const size_t q = path.find('?');
    if (q != std::string::npos) { query = path.substr(q + 1); path = path.substr(0, q); }
    if (path.empty()) path = "/";

    const bool keepAlive = uvClientWantsKeepAlive(head) && cfg_.keepAliveTimeoutMs > 0;
    const int64_t kaSecs = (cfg_.keepAliveTimeoutMs + 999) / 1000;
    MatchResult m = match(head.method, head.customMethod, path);
    // Capture the body before consuming the request from the buffer.
    std::string bodyBytes = clen > 0 ? c->buf.substr(headEnd + 4, (size_t)clen)
                                     : std::string();
    c->buf.erase(0, reqEnd);  // consume this request

    if (!m.matched) {
      writeAnswer(c, uvBuildHead(404, {}, 0, keepAlive, kaSecs), keepAlive);
      continue;
    }
    if (m.route.staticResponse) {
      const StaticResponse& sr = *m.route.staticResponse;
      std::string out = uvBuildHead(sr.status, sr.headers,
                                  (int64_t)sr.body.size(), keepAlive, kaSecs);
      if (head.method != Method::Head) out.append(sr.body);
      writeAnswer(c, std::move(out), keepAlive);
      continue;
    }
    // Handler route: dispatch to Dart, one in flight, answered via respond().
    const int64_t reqId = nextReqId_.fetch_add(1);
    int loopIdx = 0;
    for (size_t i = 0; i < loops_.size(); i++)
      if (loops_[i].get() == c->lp) { loopIdx = (int)i; break; }
    {
      std::lock_guard<std::mutex> lk(reqMutex_);
      reqLoc_[reqId] = {loopIdx, c->id, head.method == Method::Head, keepAlive};
    }
    c->busy = true;
    if (emitter_) {
      const bool hasBody = !bodyBytes.empty();
      if (hasBody) {
        // Inline body: the chunk is tracked and emitted first, then the
        // complete head — the runner assembles them (chunks may precede heads).
        auto* payload = (uint8_t*)std::malloc(bodyBytes.size());
        if (payload) {
          std::memcpy(payload, bodyBytes.data(), bodyBytes.size());
          pending_.trackPayload(reqId, payload);
          emitter_->emitBodyData(reqId, payload, bodyBytes.size());
        }
      }
      emitter_->emitHead(reqId, head.method, head.customMethod, path, query,
                         head.headers, clen, hasBody, true, m.route.pattern,
                         m.params);
    }
    return;  // wait for respond()
  }
}

// Loop thread: write an answer and, when it lands, resume or close.
void UvReactor::writeAnswer(Conn* c, std::string bytes, bool keepAlive) {
  c->busy = true;
  auto* payload = new std::string(std::move(bytes));
  auto* req = new uv_write_t;
  req->data = new WriteCtx{c, payload, keepAlive};
  uv_buf_t buf = uv_buf_init((char*)payload->data(), (unsigned)payload->size());
  uv_write(req, (uv_stream_t*)&c->handle, &buf, 1, &UvReactor::onWrite);
}

void UvReactor::onWrite(uv_write_t* req, int status) {
  auto* ctx = (WriteCtx*)req->data;
  Conn* c = ctx->c;
  const bool keepAlive = ctx->keepAlive;
  delete ctx->payload;
  delete ctx;
  delete req;
  if (status < 0 || !keepAlive || c->closing) {
    if (!uv_is_closing((uv_handle_t*)&c->handle)) {
      c->closing = true;
      uv_close((uv_handle_t*)&c->handle, &UvReactor::onCloseConn);
    }
    return;
  }
  c->busy = false;
  c->lp->owner->processConn(c);  // any pipelined request buffered already
}

// Any thread: enqueue the answer and wake the connection's loop.
void UvReactor::respond(int64_t id, int64_t status,
                        const std::vector<Header>& headers, const uint8_t* body,
                        size_t bodyLen) {
  ReqLoc loc;
  {
    std::lock_guard<std::mutex> lk(reqMutex_);
    auto it = reqLoc_.find(id);
    if (it == reqLoc_.end()) return;  // unknown/already answered
    loc = it->second;
    reqLoc_.erase(it);
  }
  const int64_t kaSecs = (cfg_.keepAliveTimeoutMs + 999) / 1000;
  std::string out = uvBuildHead(status, headers, (int64_t)bodyLen, loc.keepAlive,
                              kaSecs);
  if (!loc.isHead && body && bodyLen) out.append((const char*)body, bodyLen);
  Loop* lp = loops_[loc.loopIdx].get();
  {
    std::lock_guard<std::mutex> lk(lp->qMutex);
    lp->queue.push_back({loc.connId, std::move(out), loc.keepAlive});
  }
  uv_async_send(&lp->async);
}

// Loop thread: drain queued answers, writing each to its (still-live) conn.
// When `stopping`, close every handle on this loop so uv_run returns cleanly.
void UvReactor::onAsync(uv_async_t* async) {
  Loop* lp = (Loop*)async->data;
  std::vector<Loop::Pending> batch;
  bool stopping;
  {
    std::lock_guard<std::mutex> lk(lp->qMutex);
    batch.swap(lp->queue);
    stopping = lp->stopping;
  }
  for (auto& p : batch) {
    auto it = lp->conns.find(p.connId);
    if (it == lp->conns.end()) continue;  // closed before the answer landed
    Conn* c = it->second;
    if (c->closing) continue;
    lp->owner->writeAnswer(c, std::move(p.bytes), p.keepAlive);
  }
  if (stopping) {
    if (!uv_is_closing((uv_handle_t*)&lp->server))
      uv_close((uv_handle_t*)&lp->server, nullptr);
    // Snapshot conns first: onCloseConn erases from the map.
    std::vector<Conn*> cs;
    cs.reserve(lp->conns.size());
    for (auto& kv : lp->conns) cs.push_back(kv.second);
    for (Conn* c : cs) {
      if (!uv_is_closing((uv_handle_t*)&c->handle)) {
        c->closing = true;
        uv_close((uv_handle_t*)&c->handle, &UvReactor::onCloseConn);
      }
    }
    if (!uv_is_closing((uv_handle_t*)&lp->async))
      uv_close((uv_handle_t*)&lp->async, nullptr);
    // uv_run returns once every handle's close callback has fired.
  }
}

void UvReactor::stop() {
  if (!running_.exchange(false)) return;
  for (auto& lp : loops_) {
    {
      std::lock_guard<std::mutex> lk(lp->qMutex);
      lp->stopping = true;
    }
    uv_async_send(&lp->async);  // wakes the loop; onAsync closes handles
  }
  for (auto& lp : loops_) {
    if (lp->thread.joinable()) lp->thread.join();
    uv_loop_close(&lp->loop);
  }
  loops_.clear();
  // Loop threads are gone; free any body-chunk payloads the runner never
  // acked (frees leak-free in production, where ackBody would have).
  pending_.abortAll();
}

}  // namespace nitroserver

#endif  // NITRO_SERVER_LIBUV
