#include "UvReactor.h"

#ifdef NITRO_SERVER_LIBUV

#ifdef _WIN32
// Winsock has no SO_REUSEPORT, so the multi-listener model doesn't apply here;
// on Windows the reactor binds a single libuv listener (see start()). These
// headers cover the address helpers (inet_pton / htons / sockaddr_*), which
// Winsock provides the same way.
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>
#endif

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <set>

#include "WsCodec.h"

#ifdef NITRO_SERVER_TLS
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/ssl.h>
#endif

namespace nitroserver {
namespace {

using Clock = std::chrono::steady_clock;

// App-level port exclusivity: SO_REUSEPORT (needed so a reactor's loops share
// one port) also lets a *second* server bind the same port, which callers do
// not expect. This registry rejects that at start().
std::mutex& boundPortsMutex() {
  static std::mutex m;
  return m;
}
std::set<int>& boundPorts() {
  static std::set<int> s;
  return s;
}

// Fills [ss] for [host]:[port]; returns the address family. A host that is
// neither a v4 nor v6 literal falls back to IPv4 loopback.
int uvBuildAddr(const std::string& host, int port, sockaddr_storage& ss,
                socklen_t& len) {
  std::memset(&ss, 0, sizeof(ss));
  in6_addr a6;
  if (inet_pton(AF_INET6, host.c_str(), &a6) == 1) {
    auto* s = reinterpret_cast<sockaddr_in6*>(&ss);
    s->sin6_family = AF_INET6;
    s->sin6_addr = a6;
    s->sin6_port = htons((uint16_t)port);
    len = sizeof(sockaddr_in6);
    return AF_INET6;
  }
  in_addr a4;
  if (inet_pton(AF_INET, host.c_str(), &a4) != 1)
    return -1;  // neither an IPv4 nor an IPv6 literal → caller reports BindFailed
  auto* s = reinterpret_cast<sockaddr_in*>(&ss);
  s->sin_family = AF_INET;
  s->sin_addr = a4;
  s->sin_port = htons((uint16_t)port);
  len = sizeof(sockaddr_in);
  return AF_INET;
}

int uvPortOf(const sockaddr_storage& ss) {
  return ss.ss_family == AF_INET6
             ? ntohs(reinterpret_cast<const sockaddr_in6*>(&ss)->sin6_port)
             : ntohs(reinterpret_cast<const sockaddr_in*>(&ss)->sin_port);
}

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

// A WebSocket upgrade attempt: Upgrade: websocket + Connection: upgrade.
bool uvIsWebSocketUpgrade(const ParsedHead& head) {
  const Header* up = uvFindHeader(head.headers, "upgrade");
  const Header* cn = uvFindHeader(head.headers, "connection");
  if (!up || !cn) return false;
  auto icontains = [](const std::string& s, const char* needle) {
    std::string ls = s;
    for (char& ch : ls)
      if (ch >= 'A' && ch <= 'Z') ch += 32;
    return ls.find(needle) != std::string::npos;
  };
  return icontains(up->value, "websocket") && icontains(cn->value, "upgrade");
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

// A short text/plain error answer (Connection: close), with a body.
std::string uvErrorResponse(int64_t status, const char* msg,
                            const std::vector<Header>& extra = {}) {
  std::vector<Header> h = extra;
  h.push_back({"Content-Type", "text/plain"});
  std::string out = uvBuildHead(status, h, (int64_t)std::strlen(msg), false, 0);
  out.append(msg);
  return out;
}

std::string uvTrim(const std::string& s) {
  size_t a = 0, b = s.size();
  while (a < b && (s[a] == ' ' || s[a] == '\t')) a++;
  while (b > a && (s[b - 1] == ' ' || s[b - 1] == '\t')) b--;
  return s.substr(a, b - a);
}

// Request-smuggling defense (RFC 9112 §6.1/§6.3.3/§3.2): reject conflicting or
// duplicated Content-Length, Content-Length with Transfer-Encoding, and a
// missing or duplicated Host on HTTP/1.1. Returns the reason, or null when OK.
const char* uvFramingError(const ParsedHead& head) {
  const std::string* cl = nullptr;
  bool hasTe = false, hasHost = false, dupHost = false, dupCl = false;
  for (const auto& h : head.headers) {
    if (uvIequals(h.name, "content-length")) {
      if (cl && uvTrim(*cl) != uvTrim(h.value)) return "conflicting content-length";
      if (cl) dupCl = true;
      cl = &h.value;
    } else if (uvIequals(h.name, "transfer-encoding")) {
      hasTe = true;
    } else if (uvIequals(h.name, "host")) {
      dupHost = dupHost || hasHost;
      hasHost = true;
    }
  }
  if (dupCl) return "duplicate content-length";
  if (cl && hasTe) return "content-length with transfer-encoding";
  // A non-numeric Content-Length is unparseable framing.
  if (cl) {
    char* end = nullptr;
    const long long v = std::strtoll(cl->c_str(), &end, 10);
    if (end == cl->c_str() || *end != '\0' || v < 0) return "bad content-length";
  }
  if (head.version == "HTTP/1.1") {
    if (!hasHost) return "missing host header";
    if (dupHost) return "duplicate host header";
  }
  return nullptr;
}

// Decodes a chunked request body from [buf] starting at [start].
// Returns: 1 complete (out = body, end = offset past the terminating CRLF),
// 0 incomplete (need more bytes), -1 malformed or over [maxBody].
// Returns 1 complete, 0 need more, -1 malformed (→400), -2 over the cap
// (→413). The cap is enforced on both the declared chunk size and the raw
// bytes buffered while waiting, so an ever-growing size line can't stall.
int decodeChunked(const std::string& buf, size_t start, int64_t maxBody,
                  std::string& out, size_t& end) {
  size_t pos = start;
  out.clear();
  // Slack over the cap for chunk framing (size lines, CRLFs, a trailer).
  const auto overCap = [&]() {
    return (int64_t)(buf.size() - start) > maxBody + 1024;
  };
  while (true) {
    const size_t eol = buf.find("\r\n", pos);
    if (eol == std::string::npos)  // size line not fully buffered
      return overCap() ? -2 : 0;
    char* endp = nullptr;
    const long sz = std::strtol(buf.c_str() + pos, &endp, 16);
    if (endp == buf.c_str() + pos || sz < 0) return -1;  // malformed size
    pos = eol + 2;
    if (sz == 0) {  // terminal chunk: consume trailers to the blank line
      size_t t = pos;
      while (true) {
        const size_t e2 = buf.find("\r\n", t);
        if (e2 == std::string::npos) return overCap() ? -2 : 0;
        if (e2 == t) {
          end = t + 2;
          return 1;
        }
        t = e2 + 2;  // skip one trailer line
      }
    }
    if ((int64_t)out.size() + sz > maxBody) return -2;  // declared over the cap
    if (buf.size() < pos + (size_t)sz + 2)  // data + CRLF not in yet
      return overCap() ? -2 : 0;
    out.append(buf, pos, (size_t)sz);
    pos += (size_t)sz + 2;
  }
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
  bool counted = false;    // admitted: liveConns_ (+ per-IP) incremented for it
  std::string peerIp;      // remote IP, for the per-IP cap (empty = not counted)
  int64_t served = 0;  // completed requests (header vs keep-alive timeout)
  int64_t reqIdInFlight = -1;  // dispatched handler awaiting respond (for 408)
  bool continueSent = false;   // sent 100 Continue for the current request
  // streamBody: the head dispatched, body bytes streamed as they arrive.
  bool streamingBody = false;
  bool streamChunked = false;  // body is chunked (decode incrementally)
  int64_t streamReqId = 0;
  Emitter* streamEmitter = nullptr;
  int64_t bodyRemaining = 0;    // Content-Length bytes still to stream
  int64_t chunkRemaining = 0;   // bytes left in the current chunk (chunked)
  bool chunkNeedCrlf = false;   // consume the CRLF after a chunk's data next
  int64_t writePending = 0;     // bytes queued to the socket, not yet written
  std::chrono::steady_clock::time_point writeStartedAt;  // oldest pending write
  std::chrono::steady_clock::time_point lastActive;   // idle-timeout anchor
  std::chrono::steady_clock::time_point reqDeadline;  // valid while busy+handler
  bool hasDeadline = false;
  // WebSocket state (set after a successful upgrade).
  bool ws = false;
  Emitter* wsEmitter = nullptr;  // the sink this session's messages go to
  std::string wsMsg;      // reassembly buffer for a fragmented message
  int wsMsgOpcode = -1;   // opcode being reassembled; -1 = no message in flight
  bool wsMsgCompressed = false;  // the message's first frame had RSV1 (deflate)
  bool wsClosing = false;  // a close frame was sent; drop further frames
  bool deflate = false;    // permessage-deflate negotiated on this session
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

StatusResult UvReactor::registerRoute(Method method,
                                      const std::string& customMethod,
                                      const std::string& pattern,
                                      int64_t timeoutMs, bool isWebSocket,
                                      bool streamBody, int64_t maxBodyBytes,
                                      const std::string& wsProtocols) {
  RouteEntry e;
  e.method = method;
  e.customMethod = customMethod;
  e.pattern = pattern;
  e.timeoutMs = timeoutMs;
  e.isWebSocket = isWebSocket;
  e.streamBody = streamBody;
  e.maxBodyBytes = maxBodyBytes;
  for (size_t b = 0; b <= wsProtocols.size();) {  // comma-separated, trimmed
    size_t c = wsProtocols.find(',', b);
    if (c == std::string::npos) c = wsProtocols.size();
    size_t s = b, en = c;
    while (s < en && wsProtocols[s] == ' ') s++;
    while (en > s && wsProtocols[en - 1] == ' ') en--;
    if (en > s) e.wsProtocols.emplace_back(wsProtocols.substr(s, en - s));
    b = c + 1;
  }
  return registerRoute(e);
}

StatusResult UvReactor::registerStaticRoute(
    Method method, const std::string& customMethod, const std::string& pattern,
    int64_t status, const std::vector<Header>& headers, const uint8_t* body,
    size_t bodyLen) {
  RouteEntry e;
  e.method = method;
  e.customMethod = customMethod;
  e.pattern = pattern;
  auto sr = std::make_shared<StaticResponse>();
  sr->status = status;
  sr->headers = headers;
  if (body && bodyLen) sr->body.assign((const char*)body, bodyLen);
  e.staticResponse = std::move(sr);
  return registerStaticRoute(e);
}

StatusResult UvReactor::unregisterRoute(Method method,
                                        const std::string& customMethod,
                                        const std::string& pattern) {
  if (!router_.remove(method, customMethod, pattern))
    return {ErrorKind::RouteNotFound, "no such route: " + pattern, 0};
  return {};
}

void UvReactor::setEmitter(Emitter* e) {
  std::lock_guard<std::mutex> lk(emitterMutex_);
  emitters_.clear();
  if (e) emitters_.push_back(e);
}

void UvReactor::addEmitter(Emitter* e) {
  std::lock_guard<std::mutex> lk(emitterMutex_);
  for (Emitter* x : emitters_)
    if (x == e) return;
  emitters_.push_back(e);
}

void UvReactor::removeEmitter(Emitter* e) {
  std::lock_guard<std::mutex> lk(emitterMutex_);
  emitters_.erase(std::remove(emitters_.begin(), emitters_.end(), e),
                  emitters_.end());
}

size_t UvReactor::emitterCountForTesting() {
  std::lock_guard<std::mutex> lk(emitterMutex_);
  return emitters_.size();
}

Emitter* UvReactor::nextEmitter() {
  std::lock_guard<std::mutex> lk(emitterMutex_);
  if (emitters_.empty()) return nullptr;
  const uint64_t i = emitterRr_.fetch_add(1);
  return emitters_[i % emitters_.size()];
}

void UvReactor::broadcastEvent(ServerEventKind kind, int64_t requestId,
                               const std::string& message) {
  std::lock_guard<std::mutex> lk(emitterMutex_);
  for (Emitter* e : emitters_) e->emitEvent(kind, requestId, message);
}

// Read on the caller's thread (fine — not a loop thread), answer like a body.
void UvReactor::respondFile(int64_t id, int64_t status,
                            const std::vector<Header>& headers,
                            const std::string& path, int64_t offset,
                            int64_t length) {
  FILE* f = std::fopen(path.c_str(), "rb");
  if (!f) {
    static const char msg[] = "not found";
    std::vector<Header> h{{"Content-Type", "text/plain"}};
    respond(id, 404, h, (const uint8_t*)msg, sizeof(msg) - 1);
    return;
  }
  std::fseek(f, 0, SEEK_END);
  const long size = std::ftell(f);
  if (offset < 0) offset = 0;
  if (offset > size) {  // a range that starts past the end has no bytes → 404
    std::fclose(f);
    static const char msg[] = "not found";
    std::vector<Header> h{{"Content-Type", "text/plain"}};
    respond(id, 404, h, (const uint8_t*)msg, sizeof(msg) - 1);
    return;
  }
  const long end = length < 0 ? size : std::min<long>(size, offset + length);
  const long n = end > offset ? end - offset : 0;
  std::string body((size_t)n, '\0');
  std::fseek(f, offset, SEEK_SET);
  if (n > 0 && std::fread(&body[0], 1, (size_t)n, f) != (size_t)n) body.clear();
  std::fclose(f);
  respond(id, status, headers, (const uint8_t*)body.data(), body.size());
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
  const int backlog = cfg_.backlog > 0 ? (int)cfg_.backlog : 128;

  // Reserve a fixed port up front so a second server on it fails (SO_REUSEPORT
  // would otherwise let both bind). Port 0 is reserved after the OS assigns it.
  if (cfg_.port != 0) {
    std::lock_guard<std::mutex> lk(boundPortsMutex());
    if (!boundPorts().insert((int)cfg_.port).second) {
      running_.store(false);
      return {ErrorKind::BindFailed, "port already in use", 0};
    }
    reservedPort_ = (int)cfg_.port;
  }

#ifndef _WIN32
  auto releaseAndFail = [&](std::vector<int>& fds,
                            const char* msg) -> StatusResult {
    for (int fd : fds) close(fd);
    if (reservedPort_ != 0) {
      std::lock_guard<std::mutex> lk(boundPortsMutex());
      boundPorts().erase(reservedPort_);
      reservedPort_ = 0;
    }
    running_.store(false);
    return {ErrorKind::BindFailed, msg, 0};
  };
#endif

#ifdef _WIN32
  // Windows has no SO_REUSEPORT, so the "N listeners sharing one port" model
  // doesn't apply: bind a single libuv listener on one loop. libuv (IOCP)
  // initializes Winsock and owns the accept socket, so there is no raw socket
  // to open. Loses the per-core listener fan-out, but is correct and keeps the
  // rest of the reactor (per-conn handling, TLS, WebSocket) unchanged.
  (void)n;
  {
    auto lp = std::make_unique<Loop>();
    lp->owner = this;
    uv_loop_init(&lp->loop);
    lp->async.data = lp.get();
    uv_async_init(&lp->loop, &lp->async, &UvReactor::onAsync);
    lp->sweep.data = lp.get();
    uv_timer_init(&lp->loop, &lp->sweep);
    uv_timer_start(&lp->sweep, &UvReactor::onSweep, 100, 100);
    lp->server.data = lp.get();
    uv_tcp_init(&lp->loop, &lp->server);
    auto winFail = [&](const char* msg) -> StatusResult {
      uv_close((uv_handle_t*)&lp->server, nullptr);
      uv_close((uv_handle_t*)&lp->async, nullptr);
      uv_close((uv_handle_t*)&lp->sweep, nullptr);
      uv_run(&lp->loop, UV_RUN_DEFAULT);
      uv_loop_close(&lp->loop);
      if (reservedPort_ != 0) {
        std::lock_guard<std::mutex> lk(boundPortsMutex());
        boundPorts().erase(reservedPort_);
        reservedPort_ = 0;
      }
      running_.store(false);
      return {ErrorKind::BindFailed, msg, 0};
    };
    sockaddr_storage ss;
    socklen_t sslen;
    if (uvBuildAddr(cfg_.host, (int)cfg_.port, ss, sslen) < 0)
      return winFail("invalid host");
    if (uv_tcp_bind(&lp->server, (const sockaddr*)&ss, 0) != 0)
      return winFail("bind failed");
    sockaddr_storage bound{};
    int bl = (int)sizeof(bound);
    uv_tcp_getsockname(&lp->server, (sockaddr*)&bound, &bl);
    boundPort_.store(uvPortOf(bound));
    cfg_.port = boundPort_.load();
    if (reservedPort_ == 0) {
      std::lock_guard<std::mutex> lk(boundPortsMutex());
      boundPorts().insert((int)boundPort_.load());
      reservedPort_ = (int)boundPort_.load();
    }
    if (uv_listen((uv_stream_t*)&lp->server, backlog, &UvReactor::onConnection) != 0)
      return winFail("listen failed");
    loops_.push_back(std::move(lp));
  }
#else
  // Phase one: bind every listener socket. A failure here cleans up with no
  // libuv resources yet created.
  std::vector<int> fds;
  for (int i = 0; i < n; i++) {
    sockaddr_storage ss;
    socklen_t sslen;
    const int family = uvBuildAddr(cfg_.host, (int)cfg_.port, ss, sslen);
    if (family < 0) return releaseAndFail(fds, "invalid host");
    int fd = socket(family, SOCK_STREAM, 0);
    if (fd < 0) return releaseAndFail(fds, "socket failed");
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one));
    if (bind(fd, (sockaddr*)&ss, sslen) != 0) {
      close(fd);
      return releaseAndFail(fds, "bind failed");
    }
    if (i == 0) {  // read the OS-assigned port; pin it for the rest
      sockaddr_storage bound;
      socklen_t bl = sizeof(bound);
      getsockname(fd, (sockaddr*)&bound, &bl);
      boundPort_.store(uvPortOf(bound));
      cfg_.port = boundPort_.load();
      if (reservedPort_ == 0) {
        std::lock_guard<std::mutex> lk(boundPortsMutex());
        boundPorts().insert((int)boundPort_.load());
        reservedPort_ = (int)boundPort_.load();
      }
    }
    if (listen(fd, backlog) != 0) {
      close(fd);
      return releaseAndFail(fds, "listen failed");
    }
    fds.push_back(fd);
  }

  // Phase two: one libuv loop per bound socket, then run each on its thread.
  for (int i = 0; i < n; i++) {
    auto lp = std::make_unique<Loop>();
    lp->owner = this;
    uv_loop_init(&lp->loop);
    lp->async.data = lp.get();
    uv_async_init(&lp->loop, &lp->async, &UvReactor::onAsync);
    lp->sweep.data = lp.get();
    uv_timer_init(&lp->loop, &lp->sweep);
    uv_timer_start(&lp->sweep, &UvReactor::onSweep, 100, 100);
    lp->fd = fds[i];
    lp->server.data = lp.get();
    uv_tcp_init(&lp->loop, &lp->server);
    uv_tcp_open(&lp->server, fds[i]);
    uv_listen((uv_stream_t*)&lp->server, backlog, &UvReactor::onConnection);
    loops_.push_back(std::move(lp));
  }
#endif  // _WIN32
  for (auto& lp : loops_) {
    Loop* raw = lp.get();
    raw->thread = std::thread([this, raw] { runLoop(raw); });
  }
  return {ErrorKind::None, "", boundPort_.load()};  // Dart reads the bound port
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
  // Peer IP, for the per-IP cap.
  std::string peerIp;
  {
    sockaddr_storage ss;
    int nl = (int)sizeof(ss);
    if (uv_tcp_getpeername(&c->handle, (sockaddr*)&ss, &nl) == 0) {
      char ip[64] = {0};
      if (ss.ss_family == AF_INET6)
        uv_ip6_name(reinterpret_cast<const sockaddr_in6*>(&ss), ip, sizeof(ip));
      else
        uv_ip4_name(reinterpret_cast<const sockaddr_in*>(&ss), ip, sizeof(ip));
      peerIp = ip;
    }
  }
  // Admit or refuse: over the global cap, while draining, or over the per-IP
  // cap, accept then close so the backlog drains instead of wedging. Counting
  // happens here (guarded — accepts land on every loop thread) and is released
  // in onCloseConn iff `counted`, so every refuse path stays symmetric.
  const int64_t maxConn = self->cfg_.maxConnections;
  const int64_t maxPerIp = self->cfg_.maxConnectionsPerIp;
  bool refuse = self->draining_.load() ||
                (maxConn > 0 && self->liveConns_.load() >= maxConn);
  if (!refuse && maxPerIp > 0 && !peerIp.empty()) {
    std::lock_guard<std::mutex> lk(self->ipMutex_);
    if (self->ipCounts_[peerIp] >= maxPerIp) {
      refuse = true;
    } else {
      self->ipCounts_[peerIp] += 1;
      c->peerIp = peerIp;  // marks the per-IP slot to release on close
    }
  }
  if (refuse) {
    c->closing = true;
    uv_close((uv_handle_t*)&c->handle, &UvReactor::onCloseConn);
    return;
  }
  c->counted = true;
  self->liveConns_.fetch_add(1);
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
  uv_read_start((uv_stream_t*)&c->handle, &UvReactor::allocCb,
                &UvReactor::readCb);
}

void UvReactor::allocCb(uv_handle_t* h, size_t suggested, uv_buf_t* b) {
  (void)h;
  static thread_local std::vector<char> scratch;
  if (scratch.size() < suggested) scratch.resize(suggested < 65536 ? 65536 : suggested);
  *b = uv_buf_init(scratch.data(), (unsigned)scratch.size());
}

// Release a connection's admission accounting (global + per-IP). Idempotent:
// clears the markers so a later onCloseConn won't double-release. Called early
// when a peer half-closes, and again at teardown.
void UvReactor::releaseAdmission(Conn* c) {
  if (c->counted) {
    liveConns_.fetch_sub(1);
    c->counted = false;
  }
  if (!c->peerIp.empty()) {
    std::lock_guard<std::mutex> lk(ipMutex_);
    auto it = ipCounts_.find(c->peerIp);
    if (it != ipCounts_.end() && --it->second <= 0) ipCounts_.erase(it);
    c->peerIp.clear();
  }
}

void UvReactor::onCloseConn(uv_handle_t* h) {
  Conn* c = (Conn*)h;
  if (c->lp) {
    UvReactor* self = c->lp->owner;
    c->lp->conns.erase(c->id);
    self->releaseAdmission(c);  // global + per-IP (no-op if already released)
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
    // A head buffered with an incomplete body at EOF is a truncated request:
    // answer 400 before closing (plaintext only; TLS just closes).
    bool tls = false;
#ifdef NITRO_SERVER_TLS
    tls = c->ssl != nullptr;
#endif
    if (!c->busy && !c->ws && !c->closing && !tls &&
        c->buf.find("\r\n\r\n") != std::string::npos) {
      c->lp->owner->writeAnswer(c, uvBuildHead(400, {}, 0, false, 0), false, true);
      return;
    }
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
  if (c->streamingBody) {
    if (c->streamChunked) c->lp->owner->emitStreamChunked(c);
    else c->lp->owner->emitStreamBytes(c);
  } else if (c->ws) {
    c->lp->owner->wsProcess(c);
  } else {
    c->lp->owner->processConn(c);
  }
}

// Loop thread: stream buffered body bytes to a streamBody handler, ending the
// stream when the Content-Length is exhausted.
void UvReactor::emitStreamBytes(Conn* c) {
  const size_t avail =
      std::min<size_t>(c->buf.size(), (size_t)c->bodyRemaining);
  if (avail > 0 && c->streamEmitter) {
    auto* payload = (uint8_t*)std::malloc(avail);
    if (payload) {
      std::memcpy(payload, c->buf.data(), avail);
      pending_.trackPayload(c->streamReqId, payload);
      c->streamEmitter->emitBodyData(c->streamReqId, payload, avail);
    }
    c->buf.erase(0, avail);
    c->bodyRemaining -= (int64_t)avail;
  }
  if (c->bodyRemaining == 0) {
    if (c->streamEmitter) c->streamEmitter->emitBodyEnd(c->streamReqId);
    c->streamingBody = false;  // stays busy until respond() lands
  }
}

// Loop thread: incrementally decode a chunked streamBody upload, streaming
// partial chunk data as it arrives (a chunk may be larger than one read) and
// ending on the terminal 0-chunk. chunkRemaining/chunkNeedCrlf persist across
// reads.
void UvReactor::emitStreamChunked(Conn* c) {
  std::string out;
  bool done = false, malformed = false;
  while (true) {
    if (c->chunkNeedCrlf) {  // trailing CRLF after a chunk's data
      if (c->buf.size() < 2) break;
      c->buf.erase(0, 2);
      c->chunkNeedCrlf = false;
    }
    if (c->chunkRemaining == 0) {  // read the next size line
      const size_t eol = c->buf.find("\r\n");
      if (eol == std::string::npos) break;
      char* endp = nullptr;
      const long sz = std::strtol(c->buf.c_str(), &endp, 16);
      if (endp == c->buf.c_str() || sz < 0) { malformed = true; break; }
      if (sz == 0) {  // terminal: consume the size line + trailers to a blank line
        size_t t = eol + 2;
        bool ok = false;
        while (true) {
          const size_t e2 = c->buf.find("\r\n", t);
          if (e2 == std::string::npos) break;
          if (e2 == t) { c->buf.erase(0, t + 2); ok = true; break; }
          t = e2 + 2;
        }
        if (ok) done = true;
        break;
      }
      c->buf.erase(0, eol + 2);  // consume the size line
      c->chunkRemaining = sz;
    }
    if (c->chunkRemaining > 0) {  // stream whatever chunk data is buffered
      const size_t take =
          std::min<size_t>(c->buf.size(), (size_t)c->chunkRemaining);
      if (take == 0) break;
      out.append(c->buf, 0, take);
      c->buf.erase(0, take);
      c->chunkRemaining -= (int64_t)take;
      if (c->chunkRemaining == 0) c->chunkNeedCrlf = true;
    }
  }
  if (malformed) {
    c->streamingBody = false;
    c->closing = true;
    if (!uv_is_closing((uv_handle_t*)&c->handle))
      uv_close((uv_handle_t*)&c->handle, &UvReactor::onCloseConn);
    return;
  }
  if (!out.empty() && c->streamEmitter) {
    auto* payload = (uint8_t*)std::malloc(out.size());
    if (payload) {
      std::memcpy(payload, out.data(), out.size());
      pending_.trackPayload(c->streamReqId, payload);
      c->streamEmitter->emitBodyData(c->streamReqId, payload, out.size());
    }
  }
  if (done) {
    if (c->streamEmitter) c->streamEmitter->emitBodyEnd(c->streamReqId);
    c->streamingBody = false;
  }
}

// Loop thread: dispatch complete buffered requests until one is in flight.
void UvReactor::processConn(Conn* c) {
  if (c->streamingBody) return;  // a streamBody upload owns the buffer
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
    if (uvFramingError(head)) {  // request-smuggling / bad framing → 400, close
      writeAnswer(c, uvBuildHead(400, {}, 0, false, 0), false, true);
      return;
    }
    // Body: Content-Length or Transfer-Encoding: chunked. Either is read whole
    // into the connection buffer, then emitted (head → chunk → end).
    int64_t clen = 0;
    if (const Header* cl = uvFindHeader(head.headers, "content-length"))
      clen = std::strtoll(cl->value.c_str(), nullptr, 10);
    bool chunked = false;
    if (const Header* te = uvFindHeader(head.headers, "transfer-encoding"))
      if (te->value.find("chunked") != std::string::npos) chunked = true;
    if (clen < 0) {  // malformed Content-Length
      writeAnswer(c, uvBuildHead(400, {}, 0, false, 0), false, true);
      return;
    }
    // Route match up front: the body cap is per-route (falling back to the
    // server cap), so the route must be known before the body is read.
    std::string path = head.target;
    std::string query;
    {
      const size_t q = path.find('?');
      if (q != std::string::npos) { query = path.substr(q + 1); path = path.substr(0, q); }
      if (path.empty()) path = "/";
    }
    const MatchResult m = match(head.method, head.customMethod, path);
    const int64_t serverMax = cfg_.maxBodyBytes > 0 ? cfg_.maxBodyBytes : (10 << 20);
    const int64_t maxBody = (m.matched && m.route.maxBodyBytes >= 0)
                                ? m.route.maxBodyBytes
                                : serverMax;
    if (!chunked && clen > maxBody) {  // over the cap: refuse before buffering
      writeAnswer(c, uvBuildHead(413, {}, 0, false, 0), false, true);
      return;
    }
    // 100-continue: the client waits for it before sending the body.
    if ((clen > 0 || chunked) && !c->continueSent) {
      if (const Header* ex = uvFindHeader(head.headers, "expect")) {
        if (ex->value.find("100-continue") != std::string::npos ||
            ex->value.find("100-Continue") != std::string::npos) {
          writeRaw(c, "HTTP/1.1 100 Continue\r\n\r\n");
        }
      }
      c->continueSent = true;
    }

    // streamBody route: dispatch the head now and stream the body (Content-
    // Length or chunked) to the handler as it arrives.
    if (clen > 0 || chunked) {
      if (m.matched && m.route.streamBody &&
          !(m.route.maxBodyBytes >= 0 && clen > m.route.maxBodyBytes)) {
        const int64_t reqId = nextReqId_.fetch_add(1);
        int loopIdx = 0;
        for (size_t i = 0; i < loops_.size(); i++)
          if (loops_[i].get() == c->lp) { loopIdx = (int)i; break; }
        const bool ka = uvClientWantsKeepAlive(head) &&
                        cfg_.keepAliveTimeoutMs > 0 && !draining_.load() &&
                        (cfg_.maxRequestsPerConn <= 0 ||
                         c->served + 1 < cfg_.maxRequestsPerConn);
        {
          std::lock_guard<std::mutex> lk(reqMutex_);
          reqLoc_[reqId] = {loopIdx, c->id, head.method == Method::Head, ka};
        }
        c->busy = true;
        c->reqIdInFlight = reqId;
        const int64_t timeoutMs =
            m.route.timeoutMs >= 0 ? m.route.timeoutMs : cfg_.defaultTimeoutMs;
        if (timeoutMs > 0) {
          c->reqDeadline = Clock::now() + std::chrono::milliseconds(timeoutMs);
          c->hasDeadline = true;
        }
        Emitter* em = nextEmitter();
        if (em)
          em->emitHead(reqId, head.method, head.customMethod, path, query,
                       head.headers, clen, /*hasBody=*/true,
                       /*bodyComplete=*/false, m.route.pattern, m.params);
        c->streamingBody = true;
        c->streamChunked = chunked;
        c->streamReqId = reqId;
        c->streamEmitter = em;
        c->bodyRemaining = chunked ? 0 : clen;
        c->buf.erase(0, headEnd + 4);  // drop the head; the rest is body
        c->lastActive = Clock::now();
        if (chunked) emitStreamChunked(c); else emitStreamBytes(c);
        return;
      }
    }

    std::string bodyBytes;
    size_t reqEnd;
    if (chunked) {
      size_t end = 0;
      const int r = decodeChunked(c->buf, headEnd + 4, maxBody, bodyBytes, end);
      if (r == 0) return;  // await the rest of the chunked body
      if (r == -1) {       // malformed framing
        writeAnswer(c, uvBuildHead(400, {}, 0, false, 0), false, true);
        return;
      }
      if (r == -2) {       // body (or its framing) over the cap
        writeAnswer(c, uvBuildHead(413, {}, 0, false, 0), false, true);
        return;
      }
      reqEnd = end;
      clen = (int64_t)bodyBytes.size();  // the head reports the decoded length
    } else {
      reqEnd = headEnd + 4 + (size_t)clen;
      if (c->buf.size() < reqEnd) return;  // await the rest of the body
      if (clen > 0) bodyBytes = c->buf.substr(headEnd + 4, (size_t)clen);
    }

    const bool underBudget =
        cfg_.maxRequestsPerConn <= 0 || c->served + 1 < cfg_.maxRequestsPerConn;
    const bool keepAlive = uvClientWantsKeepAlive(head) &&
                           cfg_.keepAliveTimeoutMs > 0 && !draining_.load() &&
                           underBudget;
    const int64_t kaSecs = (cfg_.keepAliveTimeoutMs + 999) / 1000;
    c->buf.erase(0, reqEnd);  // consume this request
    c->lastActive = Clock::now();

    const bool wsUpgrade = uvIsWebSocketUpgrade(head);
    if (!m.matched) {
      // A handshake-shaped request with no route is refused honestly (426),
      // not a misleading 404.
      if (wsUpgrade) {
        writeAnswer(c, uvErrorResponse(426, "websocket not supported", {{"Sec-WebSocket-Version", "13"}}), false, true);
      } else {
        writeAnswer(c, uvBuildHead(404, {}, 0, keepAlive, kaSecs), keepAlive, true);
      }
      continue;
    }
    if (m.route.isWebSocket) {
      // A non-upgrade request on a WS route is 426, not dispatched to the
      // handshake (which would misreport a missing key as 400).
      if (!wsUpgrade) {
        writeAnswer(c, uvErrorResponse(426, "websocket not supported",
                                       {{"Sec-WebSocket-Version", "13"}}),
                    false, true);
        continue;
      }
      // An upgrade must carry no body and no trailing bytes: pipelined or
      // smuggled data after the handshake head is a framing error (400).
      if (!bodyBytes.empty() || !c->buf.empty()) {
        writeAnswer(c, uvBuildHead(400, {}, 0, false, 0), false, true);
        return;
      }
      wsHandshake(c, head, m, path, query);
      return;  // upgraded (or refused + closed); never serves HTTP again
    }
    // A WS upgrade aimed at a plain HTTP route: refuse with 426, never dispatch.
    if (wsUpgrade) {
      writeAnswer(c, uvErrorResponse(426, "websocket not supported",
                                     {{"Sec-WebSocket-Version", "13"}}),
                  false, true);
      continue;
    }
    if (m.route.staticResponse) {
      const StaticResponse& sr = *m.route.staticResponse;
      // A fixed route has no reader for a request body: if one came with the
      // request, answer then close so the read bytes can't confuse framing.
      const bool ka = keepAlive && bodyBytes.empty();
      std::string out = uvBuildHead(sr.status, sr.headers,
                                  (int64_t)sr.body.size(), ka, kaSecs);
      if (head.method != Method::Head) out.append(sr.body);
      writeAnswer(c, std::move(out), ka, true);
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
    if (Emitter* em = nextEmitter()) {
      const bool hasBody = clen > 0;
      // Head first (bodyComplete=false when a body follows), then the body as
      // one chunk, then the end marker — the runner accumulates until end,
      // robust to head/chunk stream ordering. (No inline "chunk-then-complete-
      // head" form: it races the two streams and can dispatch an empty body.)
      em->emitHead(reqId, head.method, head.customMethod, path, query,
                   head.headers, clen, hasBody, /*bodyComplete=*/!hasBody,
                   m.route.pattern, m.params);
      if (hasBody) {
        auto* payload = (uint8_t*)std::malloc(bodyBytes.size());
        if (payload) {
          std::memcpy(payload, bodyBytes.data(), bodyBytes.size());
          pending_.trackPayload(reqId, payload);
          em->emitBodyData(reqId, payload, bodyBytes.size());
        }
        em->emitBodyEnd(reqId);
      }
    }
    return;  // wait for respond()
  }
}

// Loop thread: write bytes; when it lands, resume/close only if `finish`.
void UvReactor::writeAnswer(Conn* c, std::string bytes, bool keepAlive,
                            bool finish) {
  c->busy = true;
  std::string* payload;
#ifdef NITRO_SERVER_TLS
  if (c->ssl) {
    // Encrypt the plaintext. SSL_MODE_ENABLE_PARTIAL_WRITE means SSL_write can
    // return after a single record (~16 KiB), so loop until it is all in; the
    // memory write-BIO is unbounded, so the ciphertext then drains in full.
    size_t off = 0;
    while (off < bytes.size()) {
      const int w = SSL_write(c->ssl, bytes.data() + off, (int)(bytes.size() - off));
      if (w <= 0) break;
      off += (size_t)w;
    }
    payload = new std::string(tlsDrain(c));
  } else
#endif
  {
    payload = new std::string(std::move(bytes));
  }
  if (c->writePending == 0) c->writeStartedAt = Clock::now();
  c->writePending += (int64_t)payload->size();
  auto* req = new uv_write_t;
  req->data = new WriteCtx{c, payload, keepAlive, finish};
  uv_buf_t buf = uv_buf_init((char*)payload->data(), (unsigned)payload->size());
  uv_write(req, (uv_stream_t*)&c->handle, &buf, 1, &UvReactor::onWrite);
  // A WebSocket session that outruns its reader past the buffer cap is closed
  // with 1009 (message too big / backpressure).
  if (c->ws && !c->wsClosing && cfg_.wsMaxBufferBytes > 0 &&
      c->writePending > cfg_.wsMaxBufferBytes) {
    wsCloseConn(c, 1009);
  }
}

// Loop thread: write bytes without changing request state (finish=false).
void UvReactor::writeRaw(Conn* c, std::string bytes) {
#ifdef NITRO_SERVER_TLS
  if (c->ssl) {
    size_t off = 0;  // partial-write mode: loop until all plaintext is in
    while (off < bytes.size()) {
      const int w = SSL_write(c->ssl, bytes.data() + off, (int)(bytes.size() - off));
      if (w <= 0) break;
      off += (size_t)w;
    }
    bytes = tlsDrain(c);
  }
#endif
  if (bytes.empty()) return;
  auto* payload = new std::string(std::move(bytes));
  if (c->writePending == 0) c->writeStartedAt = Clock::now();
  c->writePending += (int64_t)payload->size();
  auto* req = new uv_write_t;
  req->data = new WriteCtx{c, payload, true, /*finish=*/false};
  uv_buf_t buf = uv_buf_init((char*)payload->data(), (unsigned)payload->size());
  uv_write(req, (uv_stream_t*)&c->handle, &buf, 1, &UvReactor::onWrite);
}

void UvReactor::onWrite(uv_write_t* req, int status) {
  auto* ctx = (WriteCtx*)req->data;
  Conn* c = ctx->c;
  const bool keepAlive = ctx->keepAlive;
  const bool finish = ctx->finish;
  c->writePending -= (int64_t)ctx->payload->size();
  if (c->writePending < 0) c->writePending = 0;
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
  c->continueSent = false;
  c->lastActive = Clock::now();
  if (!keepAlive || c->closing) {
    c->closing = true;
    if (!uv_is_closing((uv_handle_t*)&c->handle))
      uv_close((uv_handle_t*)&c->handle, &UvReactor::onCloseConn);
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
  // Coalesce consecutive entries for the same connection into one write: a
  // stream that bursts N chunks between loop wakes then costs one uv_write
  // (and one send syscall), not N. Merging stops at — and includes — the
  // entry that finishes the response, so keep-alive framing is unchanged.
  for (size_t i = 0; i < batch.size();) {
    const int64_t cid = batch[i].connId;
    std::string merged = std::move(batch[i].bytes);
    bool keepAlive = batch[i].keepAlive;
    bool finish = batch[i].finish;
    size_t j = i + 1;
    while (!finish && j < batch.size() && batch[j].connId == cid) {
      merged.append(batch[j].bytes);
      keepAlive = batch[j].keepAlive;
      finish = batch[j].finish;
      ++j;
    }
    i = j;
    auto it = lp->conns.find(cid);
    if (it == lp->conns.end()) continue;  // closed before the answer landed
    Conn* c = it->second;
    if (c->closing) continue;
    lp->owner->writeAnswer(c, std::move(merged), keepAlive, finish);
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
  const int64_t writeMs =
      self->cfg_.writeTimeoutMs > 0 ? self->cfg_.writeTimeoutMs : 30000;
  for (auto& kv : lp->conns) {
    Conn* c = kv.second;
    if (c->closing) continue;
    // A peer that stopped reading: its write has been pending too long.
    if (c->writePending > 0 &&
        now - c->writeStartedAt >= std::chrono::milliseconds(writeMs)) {
      c->closing = true;
      self->broadcastEvent(ServerEventKind::ClientError, c->id,
                           "write timed out");
      if (!uv_is_closing((uv_handle_t*)&c->handle))
        uv_close((uv_handle_t*)&c->handle, &UvReactor::onCloseConn);
      continue;
    }
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
    const int64_t reqId = c->reqIdInFlight;
    if (self->lookupReq(reqId, loc, /*erase=*/true)) {
      c->hasDeadline = false;
      c->reqIdInFlight = -1;
      self->writeAnswer(c, uvBuildHead(408, {}, 0, false, 0), false, true);
      self->broadcastEvent(ServerEventKind::HandlerTimeout, reqId,
                           "handler timed out");
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
  // Tell the runner the session closed with [code] so session.closeCode
  // resolves (a server-initiated 1002/1009 as well as a client close echo).
  if (c->wsEmitter) c->wsEmitter->emitWsMessage(c->id, nullptr, 0, ws::kClose, code);
  const int wire = code == 1005 ? 1000 : code;  // 1005 is not a wire code
  uint8_t cc[2] = {(uint8_t)((wire >> 8) & 0xff), (uint8_t)(wire & 0xff)};
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
    writeAnswer(c, uvErrorResponse(426, "websocket not supported", {{"Sec-WebSocket-Version", "13"}}), false, true);
    return;
  }
  // Subprotocol negotiation: pick the first the route accepts that the client
  // offered. A client that offers protocols none of which overlap is refused
  // with 400; a client that offers none upgrades unselected (no header back).
  std::string protocol;
  if (!m.route.wsProtocols.empty()) {
    const Header* offer = uvFindHeader(head.headers, "sec-websocket-protocol");
    if (offer && !uvTrim(offer->value).empty()) {
      for (const std::string& want : m.route.wsProtocols) {
        // The offer is comma-separated; match on a trimmed token.
        size_t b = 0;
        while (b <= offer->value.size() && protocol.empty()) {
          size_t comma = offer->value.find(',', b);
          if (comma == std::string::npos) comma = offer->value.size();
          std::string tok = uvTrim(offer->value.substr(b, comma - b));
          if (tok == want) protocol = want;
          b = comma + 1;
        }
        if (!protocol.empty()) break;
      }
      if (protocol.empty()) {  // offered, but nothing the route accepts
        writeAnswer(c, uvBuildHead(400, {}, 0, false, 0), false, true);
        return;
      }
    }
  }
  // permessage-deflate (no context takeover): the Dart runner does the actual
  // deflate/inflate; the engine only negotiates it and moves the RSV1 bit.
  const Header* ext = uvFindHeader(head.headers, "sec-websocket-extensions");
  c->deflate = cfg_.wsCompression && ext &&
               ext->value.find("permessage-deflate") != std::string::npos;
  const std::string accept = ws::acceptKey(key->value);
  std::string shake =
      "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
      "Connection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n";
  if (c->deflate)
    shake += "Sec-WebSocket-Extensions: permessage-deflate; "
             "server_no_context_takeover; client_no_context_takeover\r\n";
  if (!protocol.empty())
    shake += "Sec-WebSocket-Protocol: " + protocol + "\r\n";
  shake += "\r\n";
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
  // pattern, params, query and headers. The whole session stays on this sink.
  c->wsEmitter = nextEmitter();
  if (c->wsEmitter) {
    c->wsEmitter->emitHead(c->id, head.method, head.customMethod, path, query,
                           head.headers, 0, false, true, m.route.pattern,
                           m.params);
  }
  wsProcess(c);  // handle any frames already buffered
}

// Loop thread: decode buffered WebSocket frames, reassemble, dispatch.
void UvReactor::wsProcess(Conn* c) {
  while (!c->closing && !c->wsClosing) {
    if (c->buf.size() < 2) return;  // header incomplete
    const uint8_t b0 = (uint8_t)c->buf[0];
    const int opcode = b0 & 0x0f;
    // RSV1 is a valid data-frame bit when permessage-deflate is negotiated.
    const bool badRsv = c->deflate ? ((b0 & 0x30) != 0) : ((b0 & 0x70) != 0);
    const bool badOp = opcode != 0 && opcode != 1 && opcode != 2 &&
                       opcode != 8 && opcode != 9 && opcode != 0xA;
    const bool masked = (c->buf[1] & 0x80) != 0;
    if (badRsv || badOp || !masked) {  // client frames MUST be masked
      wsCloseConn(c, 1002);
      return;
    }
    ws::FrameHeader h;
    if (!ws::parseHeader((const uint8_t*)c->buf.data(), c->buf.size(), h,
                         /*allowRsv1=*/c->deflate))
      return;  // header not fully buffered yet
    // A data frame whose declared length alone exceeds the message cap is
    // judged here, before waiting for a payload that may never arrive.
    const int64_t maxMsg = cfg_.maxBodyBytes > 0 ? cfg_.maxBodyBytes : (10 << 20);
    if (!ws::isControl(h.opcode) && (int64_t)h.length > maxMsg) {
      wsCloseConn(c, 1009);
      return;
    }
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
      wsCloseConn(c, code);  // emits the close to the runner + echoes the frame
      return;
    }
    // Data frame or continuation: reassemble across fragments (RFC 6455 §5.4).
    if (h.opcode == ws::kText || h.opcode == ws::kBinary) {
      if (c->wsMsgOpcode >= 0) {  // a new message before the previous one's FIN
        wsCloseConn(c, 1002);
        return;
      }
      c->wsMsgOpcode = h.opcode;
      c->wsMsgCompressed = h.rsv1;  // deflate marker rides on the first frame
      c->wsMsg = std::move(payload);
    } else {  // continuation
      if (c->wsMsgOpcode < 0) {  // a continuation with nothing to continue
        wsCloseConn(c, 1002);
        return;
      }
      c->wsMsg.append(payload);
    }
    if ((int64_t)c->wsMsg.size() > maxMsg) {  // fragments summing past the cap
      wsCloseConn(c, 1009);
      return;
    }
    if (h.fin) {
      // Compressed text is validated after the runner inflates it, not here.
      if (c->wsMsgOpcode == ws::kText && !c->wsMsgCompressed &&
          !ws::validUtf8((const uint8_t*)c->wsMsg.data(), c->wsMsg.size())) {
        wsCloseConn(c, 1007);
        return;
      }
      auto* buf = (uint8_t*)std::malloc(c->wsMsg.size() ? c->wsMsg.size() : 1);
      if (buf) {
        if (!c->wsMsg.empty()) std::memcpy(buf, c->wsMsg.data(), c->wsMsg.size());
        pending_.trackPayload(c->id, buf);
        if (c->wsEmitter)
          c->wsEmitter->emitWsMessage(c->id, buf, c->wsMsg.size(),
                                      c->wsMsgOpcode, c->wsMsgCompressed ? 1 : 0);
      }
      c->wsMsg.clear();
      c->wsMsgOpcode = -1;  // ready for the next message
      c->wsMsgCompressed = false;
    }
  }
}

int64_t UvReactor::wsSend(int64_t connId, const uint8_t* payload, size_t n,
                          bool binary, bool compressed) {
  int loopIdx;
  {
    std::lock_guard<std::mutex> lk(reqMutex_);
    auto it = wsConnLoop_.find(connId);
    if (it == wsConnLoop_.end()) return -1;
    loopIdx = it->second;
  }
  std::vector<uint8_t> frame;
  ws::encodeFrame(binary ? ws::kBinary : ws::kText, payload, n, true, frame);
  if (compressed) frame[0] |= 0x40;  // RSV1: the runner already deflated
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
    const int e = (r == 1) ? 0 : SSL_get_error(c->ssl, r);
    tlsRawWrite(c, tlsDrain(c));  // ServerHello / handshake flight
    if (r != 1) {
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
  if (c->streamingBody) {
    if (c->streamChunked) emitStreamChunked(c); else emitStreamBytes(c);
  } else if (c->ws) {
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
  if (reservedPort_ != 0) {
    std::lock_guard<std::mutex> lk(boundPortsMutex());
    boundPorts().erase(reservedPort_);
    reservedPort_ = 0;
  }
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
