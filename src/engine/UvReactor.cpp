#include "UvReactor.h"

#ifdef NITRO_SERVER_LIBUV

#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>

#include <chrono>
#include <cstring>

#include "WsCodec.h"

#ifdef NITRO_SERVER_TLS
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/ssl.h>
#endif

namespace nitroserver {
namespace {

using Clock = std::chrono::steady_clock;

#ifdef NITRO_SERVER_TLS
// ALPN: prefer http/1.1 when the client offers it; otherwise no selection.
int reactorAlpnSelect(SSL*, const unsigned char** out, unsigned char* outlen,
                      const unsigned char* in, unsigned int inlen, void*) {
  static const unsigned char h11[] = {8, 'h', 't', 't', 'p', '/', '1', '.', '1'};
  if (SSL_select_next_proto((unsigned char**)out, outlen, h11, sizeof(h11), in,
                            inlen) == OPENSSL_NPN_NEGOTIATED) {
    return SSL_TLSEXT_ERR_OK;
  }
  return SSL_TLSEXT_ERR_NOACK;
}
#endif

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
  int64_t served = 0;  // completed requests (header vs keep-alive timeout)
  int64_t reqIdInFlight = -1;  // dispatched handler awaiting respond (for 408)
  std::chrono::steady_clock::time_point lastActive;   // idle-timeout anchor
  std::chrono::steady_clock::time_point reqDeadline;  // valid while busy+handler
  bool hasDeadline = false;
  // WebSocket state (set after a successful upgrade).
  bool ws = false;
  std::string wsMsg;      // reassembly buffer for a fragmented message
  int wsMsgOpcode = 0;    // opcode of the message being reassembled
  bool wsClosing = false;  // a close frame was sent; drop further frames
#ifdef NITRO_SERVER_TLS
  SSL* ssl = nullptr;        // null on a plaintext connection
  BIO* rbio = nullptr;       // ciphertext in  (socket → SSL)
  BIO* wbio = nullptr;       // ciphertext out (SSL → socket)
  bool tlsHandshakeDone = false;
#endif
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
#ifdef NITRO_SERVER_TLS
  if (cfg_.tlsRequested) {
    const StatusResult r = setupTls();
    if (r.kind != ErrorKind::None) {
      running_.store(false);
      return r;
    }
  }
#endif
  unsigned cores = std::thread::hardware_concurrency();
  int n = loops > 0 ? loops : (cores == 0 ? 4 : (int)cores);
  boundPort_.store(cfg_.port);

  for (int i = 0; i < n; i++) {
    auto lp = std::make_unique<Loop>();
    lp->owner = this;
    uv_loop_init(&lp->loop);
    lp->async.data = lp.get();
    uv_async_init(&lp->loop, &lp->async, &UvReactor::onAsync);
    lp->sweep.data = lp.get();
    uv_timer_init(&lp->loop, &lp->sweep);
    uv_timer_start(&lp->sweep, &UvReactor::onSweep, 100, 100);  // every 100ms

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
  UvReactor* self = lp->owner;
  Conn* c = new Conn();
  c->lp = lp;
  c->id = self->nextConnId_.fetch_add(1);
  c->handle.data = c;
  uv_tcp_init(&lp->loop, &c->handle);
  if (uv_accept(server, (uv_stream_t*)&c->handle) != 0) {
    uv_close((uv_handle_t*)&c->handle, &UvReactor::onCloseConn);
    return;
  }
  // Refuse over the connection cap (or while draining): accept then close so
  // the backlog drains instead of wedging.
  const int64_t maxConn = self->cfg_.maxConnections;
  if (self->draining_.load() ||
      (maxConn > 0 && self->liveConns_.load() >= maxConn)) {
    c->closing = true;
    uv_close((uv_handle_t*)&c->handle, &UvReactor::onCloseConn);
    return;
  }
  uv_tcp_nodelay(&c->handle, 1);
  c->lastActive = Clock::now();
#ifdef NITRO_SERVER_TLS
  if (self->sslCtx_ && !self->tlsInit(c)) {
    c->closing = true;
    uv_close((uv_handle_t*)&c->handle, &UvReactor::onCloseConn);
    return;
  }
#endif
  lp->conns[c->id] = c;
  self->liveConns_.fetch_add(1);
  uv_read_start((uv_stream_t*)&c->handle, &UvReactor::allocCb,
                &UvReactor::readCb);
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
    UvReactor* self = c->lp->owner;
    c->lp->conns.erase(c->id);
    self->liveConns_.fetch_sub(1);
    if (c->ws) {
      {
        std::lock_guard<std::mutex> lk(self->reqMutex_);
        self->wsConnLoop_.erase(c->id);
      }
      self->pending_.dropPayloads(c->id);  // free un-acked WS message payloads
    }
  }
#ifdef NITRO_SERVER_TLS
  if (c->ssl) SSL_free(c->ssl);  // frees the attached rbio + wbio too
#endif
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
#ifdef NITRO_SERVER_TLS
  if (c->ssl) {
    c->lp->owner->tlsOnRead(c, b->base, (size_t)nread);  // decrypts + processes
    return;
  }
#endif
  c->buf.append(b->base, (size_t)nread);
  if (c->ws) {
    c->lp->owner->wsProcess(c);
  } else {
    c->lp->owner->processConn(c);
  }
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
      writeAnswer(c, uvBuildHead(400, {}, 0, false, 0), false, true);
      return;
    }
    // Body: Content-Length is read whole into the connection buffer, then
    // emitted as one inline chunk (the common POST). Chunked and true streaming
    // uploads migrate in a later stage.
    int64_t clen = 0;
    if (const Header* cl = uvFindHeader(head.headers, "content-length"))
      clen = std::strtoll(cl->value.c_str(), nullptr, 10);
    if (clen < 0) {  // malformed Content-Length
      writeAnswer(c, uvBuildHead(400, {}, 0, false, 0), false, true);
      return;
    }
    const int64_t maxBody = cfg_.maxBodyBytes > 0 ? cfg_.maxBodyBytes : (10 << 20);
    if (clen > maxBody) {  // over the cap: refuse before buffering the rest
      writeAnswer(c, uvBuildHead(413, {}, 0, false, 0), false, true);
      return;
    }
    const size_t reqEnd = headEnd + 4 + (size_t)clen;
    if (c->buf.size() < reqEnd) return;  // await the rest of the body

    std::string path = head.target;
    std::string query;
    const size_t q = path.find('?');
    if (q != std::string::npos) { query = path.substr(q + 1); path = path.substr(0, q); }
    if (path.empty()) path = "/";

    const bool keepAlive = uvClientWantsKeepAlive(head) &&
                           cfg_.keepAliveTimeoutMs > 0 && !draining_.load();
    const int64_t kaSecs = (cfg_.keepAliveTimeoutMs + 999) / 1000;
    MatchResult m = match(head.method, head.customMethod, path);
    // Capture the body before consuming the request from the buffer.
    std::string bodyBytes = clen > 0 ? c->buf.substr(headEnd + 4, (size_t)clen)
                                     : std::string();
    c->buf.erase(0, reqEnd);  // consume this request
    c->lastActive = Clock::now();

    if (!m.matched) {
      writeAnswer(c, uvBuildHead(404, {}, 0, keepAlive, kaSecs), keepAlive, true);
      continue;
    }
    if (m.route.isWebSocket) {
      wsHandshake(c, head, m, path, query);
      return;  // upgraded (or refused + closed); never serves HTTP again
    }
    if (m.route.staticResponse) {
      const StaticResponse& sr = *m.route.staticResponse;
      std::string out = uvBuildHead(sr.status, sr.headers,
                                  (int64_t)sr.body.size(), keepAlive, kaSecs);
      if (head.method != Method::Head) out.append(sr.body);
      writeAnswer(c, std::move(out), keepAlive, true);
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
    c->reqIdInFlight = reqId;
    {
      const int64_t timeoutMs =
          m.route.timeoutMs >= 0 ? m.route.timeoutMs : cfg_.defaultTimeoutMs;
      if (timeoutMs > 0) {
        c->reqDeadline = Clock::now() + std::chrono::milliseconds(timeoutMs);
        c->hasDeadline = true;
      }
    }
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

// Loop thread: write bytes; when it lands, resume/close only if `finish`.
void UvReactor::writeAnswer(Conn* c, std::string bytes, bool keepAlive,
                            bool finish) {
  c->busy = true;
#ifdef NITRO_SERVER_TLS
  if (c->ssl) {
    // Encrypt the plaintext; the memory write-BIO is unbounded, so SSL_write
    // consumes it all and the ciphertext is what goes on the wire.
    if (!bytes.empty()) SSL_write(c->ssl, bytes.data(), (int)bytes.size());
    auto* payload = new std::string(tlsDrain(c));
    auto* req = new uv_write_t;
    req->data = new WriteCtx{c, payload, keepAlive, finish};
    uv_buf_t buf = uv_buf_init((char*)payload->data(), (unsigned)payload->size());
    uv_write(req, (uv_stream_t*)&c->handle, &buf, 1, &UvReactor::onWrite);
    return;
  }
#endif
  auto* payload = new std::string(std::move(bytes));
  auto* req = new uv_write_t;
  req->data = new WriteCtx{c, payload, keepAlive, finish};
  uv_buf_t buf = uv_buf_init((char*)payload->data(), (unsigned)payload->size());
  uv_write(req, (uv_stream_t*)&c->handle, &buf, 1, &UvReactor::onWrite);
}

void UvReactor::onWrite(uv_write_t* req, int status) {
  auto* ctx = (WriteCtx*)req->data;
  Conn* c = ctx->c;
  const bool keepAlive = ctx->keepAlive;
  const bool finish = ctx->finish;
  delete ctx->payload;
  delete ctx;
  delete req;
  if (status < 0) {
    if (!uv_is_closing((uv_handle_t*)&c->handle)) {
      c->closing = true;
      uv_close((uv_handle_t*)&c->handle, &UvReactor::onCloseConn);
    }
    return;
  }
  if (!finish) return;  // a chunked stream continues; stay busy for the rest
  c->served++;
  c->hasDeadline = false;
  c->reqIdInFlight = -1;
  c->lastActive = Clock::now();
  if (!keepAlive || c->closing) {
    if (!uv_is_closing((uv_handle_t*)&c->handle)) {
      c->closing = true;
      uv_close((uv_handle_t*)&c->handle, &UvReactor::onCloseConn);
    }
    return;
  }
  c->busy = false;
  c->lp->owner->processConn(c);  // any pipelined request buffered already
}

bool UvReactor::lookupReq(int64_t id, ReqLoc& out, bool erase) {
  std::lock_guard<std::mutex> lk(reqMutex_);
  auto it = reqLoc_.find(id);
  if (it == reqLoc_.end()) return false;
  out = it->second;
  if (erase) reqLoc_.erase(it);
  return true;
}

void UvReactor::pushWrite(const ReqLoc& loc, std::string bytes, bool finish) {
  Loop* lp = loops_[loc.loopIdx].get();
  {
    std::lock_guard<std::mutex> lk(lp->qMutex);
    lp->queue.push_back({loc.connId, std::move(bytes), loc.keepAlive, finish});
  }
  uv_async_send(&lp->async);
}

// Any thread: build the whole answer and hand it to the connection's loop.
void UvReactor::respond(int64_t id, int64_t status,
                        const std::vector<Header>& headers, const uint8_t* body,
                        size_t bodyLen) {
  ReqLoc loc;
  if (!lookupReq(id, loc, /*erase=*/true)) return;  // unknown/already answered
  const int64_t kaSecs = (cfg_.keepAliveTimeoutMs + 999) / 1000;
  std::string out = uvBuildHead(status, headers, (int64_t)bodyLen, loc.keepAlive,
                                kaSecs);
  if (!loc.isHead && body && bodyLen) out.append((const char*)body, bodyLen);
  pushWrite(loc, std::move(out), /*finish=*/true);
}

// Any thread: chunked response head (Transfer-Encoding: chunked). The reqLoc
// stays until the terminal chunk (see sendStreamChunk).
void UvReactor::startStream(int64_t id, int64_t status,
                            const std::vector<Header>& headers) {
  ReqLoc loc;
  if (!lookupReq(id, loc, /*erase=*/false)) return;
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
    if (uvIequals(h.name, "transfer-encoding")) continue;
    out.append(h.name);
    out.append(": ");
    out.append(h.value);
    out.append("\r\n");
  }
  out.append("Transfer-Encoding: chunked\r\n");
  const int64_t kaSecs = (cfg_.keepAliveTimeoutMs + 999) / 1000;
  if (loc.keepAlive) {
    out.append("Connection: keep-alive\r\nKeep-Alive: timeout=");
    out.append(std::to_string(kaSecs));
    out.append("\r\n\r\n");
  } else {
    out.append("Connection: close\r\n\r\n");
  }
  // HEAD: headers only; the terminal chunk finishes it with no body.
  pushWrite(loc, std::move(out), /*finish=*/loc.isHead);
  if (loc.isHead) lookupReq(id, loc, /*erase=*/true);
}

// Any thread: one chunk frame; `last` appends the terminal chunk and finishes.
void UvReactor::sendStreamChunk(int64_t id, const uint8_t* chunk, size_t n,
                                bool last) {
  if (chunk == nullptr) n = 0;
  if (n == 0 && !last) return;  // empty non-terminal chunk: nothing to send
  ReqLoc loc;
  if (!lookupReq(id, loc, /*erase=*/last)) return;
  std::string out;
  if (n > 0) {
    char sz[32];
    int m = std::snprintf(sz, sizeof(sz), "%zx\r\n", n);
    out.append(sz, (size_t)m);
    out.append((const char*)chunk, n);
    out.append("\r\n");
  }
  if (last) out.append("0\r\n\r\n");
  pushWrite(loc, std::move(out), /*finish=*/last);
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
    lp->owner->writeAnswer(c, std::move(p.bytes), p.keepAlive, p.finish);
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
    if (!uv_is_closing((uv_handle_t*)&lp->sweep))
      uv_close((uv_handle_t*)&lp->sweep, nullptr);
    // uv_run returns once every handle's close callback has fired.
  }
}

// Loop thread: close idle keep-alive connections and time out slow handlers.
void UvReactor::onSweep(uv_timer_t* timer) {
  Loop* lp = (Loop*)timer->data;
  UvReactor* self = lp->owner;
  const auto now = Clock::now();
  std::vector<Conn*> idle;
  std::vector<int64_t> timedOut;  // reqIds whose handler missed its deadline
  for (auto& kv : lp->conns) {
    Conn* c = kv.second;
    if (c->closing) continue;
    if (c->busy) {
      if (c->hasDeadline && now >= c->reqDeadline && c->reqIdInFlight >= 0)
        timedOut.push_back(c->id);
    } else {
      const int64_t idleMs =
          (c->served == 0 && self->cfg_.headerTimeoutMs > 0)
              ? self->cfg_.headerTimeoutMs
              : self->cfg_.keepAliveTimeoutMs;
      if (idleMs > 0 &&
          now - c->lastActive >= std::chrono::milliseconds(idleMs))
        idle.push_back(c);
    }
  }
  for (Conn* c : idle) {
    c->closing = true;
    if (!uv_is_closing((uv_handle_t*)&c->handle))
      uv_close((uv_handle_t*)&c->handle, &UvReactor::onCloseConn);
  }
  for (int64_t connId : timedOut) {
    auto it = lp->conns.find(connId);
    if (it == lp->conns.end()) continue;
    Conn* c = it->second;
    ReqLoc loc;
    // Drop the reqLoc so the handler's late respond is a no-op, then 408+close.
    if (self->lookupReq(c->reqIdInFlight, loc, /*erase=*/true)) {
      c->hasDeadline = false;
      c->reqIdInFlight = -1;
      self->writeAnswer(c, uvBuildHead(408, {}, 0, false, 0), false, true);
    }
  }
}

// Stop accepting (onConnection refuses while draining) and mark later answers
// close (processConn's keepAlive checks draining_). In-flight requests finish;
// stop() reaps idle keep-alive connections.
void UvReactor::beginDrain() { draining_.store(true); }

int64_t UvReactor::inFlightRequests() {
  std::lock_guard<std::mutex> lk(reqMutex_);
  return (int64_t)reqLoc_.size();
}

// ── WebSocket ────────────────────────────────────────────────────────────────

// Loop thread: send a close frame with [code], then close the connection.
void UvReactor::wsCloseConn(Conn* c, int code) {
  if (c->wsClosing) return;
  c->wsClosing = true;
  {
    std::lock_guard<std::mutex> lk(reqMutex_);
    wsConnLoop_.erase(c->id);
  }
  uint8_t cc[2] = {(uint8_t)((code >> 8) & 0xff), (uint8_t)(code & 0xff)};
  std::vector<uint8_t> frame;
  ws::encodeFrame(ws::kClose, cc, 2, true, frame);
  writeAnswer(c, std::string(frame.begin(), frame.end()), /*keepAlive=*/false,
              /*finish=*/true);  // closes once the frame lands
}

// Loop thread: validate the RFC 6455 upgrade, answer 101, switch to WS mode.
void UvReactor::wsHandshake(Conn* c, const ParsedHead& head,
                            const MatchResult& m, const std::string& path,
                            const std::string& query) {
  const Header* key = uvFindHeader(head.headers, "sec-websocket-key");
  const Header* ver = uvFindHeader(head.headers, "sec-websocket-version");
  if (!key || key->value.empty()) {
    writeAnswer(c, uvBuildHead(400, {}, 0, false, 0), false, true);
    return;
  }
  if (!ver || ver->value.find("13") == std::string::npos) {
    writeAnswer(c, uvBuildHead(426, {{"Sec-WebSocket-Version", "13"}}, 0, false, 0),
                false, true);
    return;
  }
  const std::string accept = ws::acceptKey(key->value);
  std::string shake =
      "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
      "Connection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n";
  writeAnswer(c, std::move(shake), true, /*finish=*/false);  // stay open
  c->ws = true;
  int loopIdx = 0;
  for (size_t i = 0; i < loops_.size(); i++)
    if (loops_[i].get() == c->lp) { loopIdx = (int)i; break; }
  {
    std::lock_guard<std::mutex> lk(reqMutex_);
    wsConnLoop_[c->id] = loopIdx;
  }
  // Session open dispatches like any request head, carrying the handshake's
  // pattern, params, query and headers.
  if (emitter_) {
    emitter_->emitHead(c->id, head.method, head.customMethod, path, query,
                       head.headers, 0, false, true, m.route.pattern, m.params);
  }
  wsProcess(c);  // handle any frames already buffered
}

// Loop thread: decode buffered WebSocket frames, reassemble, dispatch.
void UvReactor::wsProcess(Conn* c) {
  while (!c->closing && !c->wsClosing) {
    if (c->buf.size() < 2) return;  // header incomplete
    const uint8_t b0 = (uint8_t)c->buf[0];
    const int opcode = b0 & 0x0f;
    const bool badRsv = (b0 & 0x70) != 0;  // no extensions negotiated
    const bool badOp = opcode != 0 && opcode != 1 && opcode != 2 &&
                       opcode != 8 && opcode != 9 && opcode != 0xA;
    const bool masked = (c->buf[1] & 0x80) != 0;
    if (badRsv || badOp || !masked) {  // client frames MUST be masked
      wsCloseConn(c, 1002);
      return;
    }
    ws::FrameHeader h;
    if (!ws::parseHeader((const uint8_t*)c->buf.data(), c->buf.size(), h))
      return;  // header not fully buffered yet
    if (c->buf.size() < h.headerSize + h.length) return;  // payload incomplete
    // Unmask the payload in place into a local buffer.
    std::string payload(c->buf.data() + h.headerSize, (size_t)h.length);
    for (size_t i = 0; i < payload.size(); i++)
      payload[i] = (char)((uint8_t)payload[i] ^ h.mask[i & 3]);
    c->buf.erase(0, h.headerSize + (size_t)h.length);

    if (h.opcode == ws::kPing) {
      std::vector<uint8_t> frame;
      ws::encodeFrame(ws::kPong, (const uint8_t*)payload.data(), payload.size(),
                      true, frame);
      writeAnswer(c, std::string(frame.begin(), frame.end()), true, false);
      continue;
    }
    if (h.opcode == ws::kPong) continue;
    if (h.opcode == ws::kClose) {
      int code = 1005;
      if (payload.size() >= 2)
        code = ((uint8_t)payload[0] << 8) | (uint8_t)payload[1];
      if (emitter_) emitter_->emitWsMessage(c->id, nullptr, 0, ws::kClose, code);
      wsCloseConn(c, code == 1005 ? 1000 : code);
      return;
    }
    // Data frame: reassemble across fragments.
    if (h.opcode == ws::kText || h.opcode == ws::kBinary) {
      c->wsMsgOpcode = h.opcode;
      c->wsMsg = std::move(payload);
    } else {  // continuation
      c->wsMsg.append(payload);
    }
    if (h.fin) {
      auto* buf = (uint8_t*)std::malloc(c->wsMsg.size() ? c->wsMsg.size() : 1);
      if (buf) {
        if (!c->wsMsg.empty()) std::memcpy(buf, c->wsMsg.data(), c->wsMsg.size());
        pending_.trackPayload(c->id, buf);
        if (emitter_)
          emitter_->emitWsMessage(c->id, buf, c->wsMsg.size(), c->wsMsgOpcode, 0);
      }
      c->wsMsg.clear();
    }
  }
}

int64_t UvReactor::wsSend(int64_t connId, const uint8_t* payload, size_t n,
                          bool binary, bool compressed) {
  (void)compressed;  // permessage-deflate not negotiated yet
  int loopIdx;
  {
    std::lock_guard<std::mutex> lk(reqMutex_);
    auto it = wsConnLoop_.find(connId);
    if (it == wsConnLoop_.end()) return -1;
    loopIdx = it->second;
  }
  std::vector<uint8_t> frame;
  ws::encodeFrame(binary ? ws::kBinary : ws::kText, payload, n, true, frame);
  Loop* lp = loops_[(size_t)loopIdx].get();
  {
    std::lock_guard<std::mutex> lk(lp->qMutex);
    lp->queue.push_back({connId, std::string(frame.begin(), frame.end()), true,
                         false});
  }
  uv_async_send(&lp->async);
  return 0;
}

void UvReactor::wsClose(int64_t connId, int code) {
  int loopIdx;
  {
    std::lock_guard<std::mutex> lk(reqMutex_);
    auto it = wsConnLoop_.find(connId);
    if (it == wsConnLoop_.end()) return;
    loopIdx = it->second;
    wsConnLoop_.erase(it);
  }
  uint8_t cc[2] = {(uint8_t)((code >> 8) & 0xff), (uint8_t)(code & 0xff)};
  std::vector<uint8_t> frame;
  ws::encodeFrame(ws::kClose, cc, 2, true, frame);
  Loop* lp = loops_[(size_t)loopIdx].get();
  {
    std::lock_guard<std::mutex> lk(lp->qMutex);
    lp->queue.push_back({connId, std::string(frame.begin(), frame.end()), false,
                         true});  // finish=true, keepAlive=false → close after
  }
  uv_async_send(&lp->async);
}

#ifdef NITRO_SERVER_TLS
// ── TLS over libuv (OpenSSL memory BIOs) ─────────────────────────────────────

StatusResult UvReactor::setupTls() {
  auto fail = [](const std::string& what) -> StatusResult {
    char buf[256] = {0};
    const unsigned long e = ERR_get_error();
    if (e) ERR_error_string_n(e, buf, sizeof(buf));
    return {ErrorKind::TlsError, e ? what + ": " + buf : what, 0};
  };
  SSL_CTX* ctx = SSL_CTX_new(TLS_server_method());
  if (!ctx) return fail("SSL_CTX_new failed");
  SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
  SSL_CTX_set_mode(ctx, SSL_MODE_ENABLE_PARTIAL_WRITE |
                            SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER |
                            SSL_MODE_AUTO_RETRY);
  SSL_CTX_set_options(ctx, SSL_OP_NO_RENEGOTIATION | SSL_OP_NO_TICKET);
  SSL_CTX_set_num_tickets(ctx, 0);
  SSL_CTX_set_alpn_select_cb(ctx, reactorAlpnSelect, nullptr);

  if (!cfg_.tlsCertPem.empty()) {
    BIO* bio = BIO_new_mem_buf(cfg_.tlsCertPem.data(), (int)cfg_.tlsCertPem.size());
    X509* leaf = PEM_read_bio_X509_AUX(bio, nullptr, nullptr, nullptr);
    if (!leaf || SSL_CTX_use_certificate(ctx, leaf) != 1) {
      if (leaf) X509_free(leaf);
      BIO_free(bio);
      SSL_CTX_free(ctx);
      return fail("invalid TLS certificate PEM");
    }
    X509_free(leaf);
    SSL_CTX_clear_chain_certs(ctx);
    X509* ca;
    while ((ca = PEM_read_bio_X509(bio, nullptr, nullptr, nullptr)) != nullptr)
      if (SSL_CTX_add0_chain_cert(ctx, ca) != 1) X509_free(ca);
    BIO_free(bio);
  } else if (!cfg_.tlsCertFile.empty()) {
    if (SSL_CTX_use_certificate_chain_file(ctx, cfg_.tlsCertFile.c_str()) != 1) {
      SSL_CTX_free(ctx);
      return fail("cannot load TLS certificate file");
    }
  } else {
    SSL_CTX_free(ctx);
    return {ErrorKind::TlsError, "TLS requested without a certificate", 0};
  }

  if (!cfg_.tlsKeyPem.empty()) {
    BIO* bio = BIO_new_mem_buf(cfg_.tlsKeyPem.data(), (int)cfg_.tlsKeyPem.size());
    EVP_PKEY* key = PEM_read_bio_PrivateKey(bio, nullptr, nullptr, nullptr);
    BIO_free(bio);
    if (!key || SSL_CTX_use_PrivateKey(ctx, key) != 1) {
      if (key) EVP_PKEY_free(key);
      SSL_CTX_free(ctx);
      return fail("invalid TLS private key PEM");
    }
    EVP_PKEY_free(key);
  } else if (!cfg_.tlsKeyFile.empty()) {
    if (SSL_CTX_use_PrivateKey_file(ctx, cfg_.tlsKeyFile.c_str(),
                                    SSL_FILETYPE_PEM) != 1) {
      SSL_CTX_free(ctx);
      return fail("cannot load TLS private key file");
    }
  } else {
    SSL_CTX_free(ctx);
    return {ErrorKind::TlsError, "TLS requested without a private key", 0};
  }
  if (SSL_CTX_check_private_key(ctx) != 1) {
    SSL_CTX_free(ctx);
    return {ErrorKind::TlsError, "certificate and private key do not match", 0};
  }
  sslCtx_ = ctx;
  return {};
}

bool UvReactor::tlsInit(Conn* c) {
  c->ssl = SSL_new((SSL_CTX*)sslCtx_);
  if (!c->ssl) return false;
  c->rbio = BIO_new(BIO_s_mem());
  c->wbio = BIO_new(BIO_s_mem());
  if (!c->rbio || !c->wbio) {
    SSL_free(c->ssl);  // frees any BIO already attached
    c->ssl = nullptr;
    return false;
  }
  SSL_set_bio(c->ssl, c->rbio, c->wbio);  // SSL owns the BIOs now
  SSL_set_accept_state(c->ssl);
  return true;
}

std::string UvReactor::tlsDrain(Conn* c) {
  std::string out;
  char b[16384];
  int r;
  while ((r = BIO_read(c->wbio, b, sizeof(b))) > 0) out.append(b, (size_t)r);
  return out;
}

void UvReactor::tlsRawWrite(Conn* c, std::string cipher) {
  if (cipher.empty()) return;
  auto* payload = new std::string(std::move(cipher));
  auto* req = new uv_write_t;
  req->data = new WriteCtx{c, payload, true, /*finish=*/false};
  uv_buf_t buf = uv_buf_init((char*)payload->data(), (unsigned)payload->size());
  uv_write(req, (uv_stream_t*)&c->handle, &buf, 1, &UvReactor::onWrite);
}

// Loop thread: feed ciphertext into the SSL engine, drive the handshake, then
// decrypt application data into the plaintext buffer and process it.
void UvReactor::tlsOnRead(Conn* c, const char* data, size_t n) {
  BIO_write(c->rbio, data, (int)n);
  if (!c->tlsHandshakeDone) {
    const int r = SSL_accept(c->ssl);
    tlsRawWrite(c, tlsDrain(c));  // ServerHello / handshake flight
    if (r != 1) {
      const int e = SSL_get_error(c->ssl, r);
      if (e != SSL_ERROR_WANT_READ && e != SSL_ERROR_WANT_WRITE) {
        c->closing = true;
        if (!uv_is_closing((uv_handle_t*)&c->handle))
          uv_close((uv_handle_t*)&c->handle, &UvReactor::onCloseConn);
      }
      return;  // handshake needs more bytes
    }
    c->tlsHandshakeDone = true;
  }
  char plain[16384];
  int r;
  while ((r = SSL_read(c->ssl, plain, sizeof(plain))) > 0)
    c->buf.append(plain, (size_t)r);
  tlsRawWrite(c, tlsDrain(c));  // anything SSL_read produced
  if (c->ws) {
    wsProcess(c);
  } else {
    processConn(c);
  }
}
#endif  // NITRO_SERVER_TLS

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
#ifdef NITRO_SERVER_TLS
  if (sslCtx_) {
    SSL_CTX_free((SSL_CTX*)sslCtx_);
    sslCtx_ = nullptr;
  }
#endif
}

}  // namespace nitroserver

#endif  // NITRO_SERVER_LIBUV
