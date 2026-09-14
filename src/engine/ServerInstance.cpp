#include "ServerInstance.h"
#include "WsCodec.h"

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <csignal>
#include <string_view>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#pragma comment(lib, "ws2_32.lib")
using socklen_t = int;
using ssize_t = long long;
#else
#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <unistd.h>
#endif

namespace nitroserver {
namespace {

#ifdef _WIN32
using Fd = SOCKET;
constexpr Fd kBadFd = INVALID_SOCKET;
int closeFd(Fd fd) { return closesocket(fd); }
void shutdownRdwr(Fd fd) { shutdown(fd, SD_BOTH); }
void shutdownRead(Fd fd) { shutdown(fd, SD_RECEIVE); }
struct WinsockEnv {
  WinsockEnv() {
    WSADATA d;
    WSAStartup(MAKEWORD(2, 2), &d);
  }
};
void ensureSockets() {
  static WinsockEnv env;
  (void)env;
}
void setNoSigPipe(Fd) {}
void setNonBlocking(Fd fd, bool on) {
  u_long mode = on ? 1 : 0;
  ioctlsocket(fd, FIONBIO, &mode);
}
bool wouldBlock() {
  const int e = WSAGetLastError();
  return e == WSAEWOULDBLOCK || e == WSAEINPROGRESS;
}
/// Polls one socket. Returns the revents (>0), 0 on timeout, <0 on error.
int pollFd(Fd fd, short events, int timeoutMs) {
  WSAPOLLFD p{};
  p.fd = fd;
  p.events = events;
  const int r = WSAPoll(&p, 1, timeoutMs);
  return r > 0 ? p.revents : r;
}
/// Polls the socket AND the worker's wake socket. [outFd]/[outWake] report
/// readiness; returns false on poll error.
bool pollTwo(Fd fd, Fd wake, int timeoutMs, bool& outFd, bool& outWake) {
  WSAPOLLFD p[2]{};
  p[0].fd = fd;
  p[0].events = POLLIN;
  p[1].fd = wake;
  p[1].events = POLLIN;
  const int r = WSAPoll(p, 2, timeoutMs);
  outFd = r > 0 && p[0].revents != 0;
  outWake = r > 0 && p[1].revents != 0;
  return r >= 0;
}
/// Gathers [n] buffers into one non-blocking send. Returns bytes written,
/// 0 when the socket would block, <0 on error.
ssize_t writeSome(Fd fd, const uint8_t* const* bufs, const size_t* lens,
                  int n) {
  WSABUF w[3];
  int m = 0;
  for (int i = 0; i < n; i++) {
    if (lens[i] == 0) continue;
    w[m].buf = (CHAR*)bufs[i];
    w[m].len = (ULONG)lens[i];
    m++;
  }
  if (m == 0) return 0;
  DWORD sent = 0;
  if (WSASend(fd, w, m, &sent, 0, nullptr, nullptr) != 0) {
    return wouldBlock() ? 0 : -1;
  }
  return (ssize_t)sent;
}
/// Loopback socket pair standing in for pipe(): WSAPoll only takes sockets.
bool makeWake(Fd& r, Fd& w) {
  r = w = kBadFd;
  Fd l = socket(AF_INET, SOCK_STREAM, 0);
  if (l == kBadFd) return false;
  sockaddr_in a{};
  a.sin_family = AF_INET;
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  a.sin_port = 0;
  int len = sizeof(a);
  if (bind(l, (sockaddr*)&a, sizeof(a)) != 0 || listen(l, 1) != 0 ||
      getsockname(l, (sockaddr*)&a, &len) != 0) {
    closesocket(l);
    return false;
  }
  w = socket(AF_INET, SOCK_STREAM, 0);
  if (w == kBadFd || connect(w, (sockaddr*)&a, sizeof(a)) != 0) {
    closesocket(l);
    if (w != kBadFd) closesocket(w);
    w = kBadFd;
    return false;
  }
  r = accept(l, nullptr, nullptr);
  closesocket(l);
  if (r == kBadFd) {
    closesocket(w);
    w = kBadFd;
    return false;
  }
  setNonBlocking(r, true);
  setNonBlocking(w, true);
  return true;
}
void closeWake(Fd fd) { closesocket(fd); }
ssize_t recvSome(Fd fd, void* buf, size_t n) {
  return recv(fd, (char*)buf, (int)n, 0);
}
ssize_t peekOne(Fd fd) {
  char b;
  return recv(fd, &b, 1, MSG_PEEK);
}
ssize_t readWake(Fd fd, void* buf, size_t n) {
  return recv(fd, (char*)buf, (int)n, 0);
}
#else
using Fd = int;
constexpr Fd kBadFd = -1;
int closeFd(Fd fd) { return ::close(fd); }
void shutdownRdwr(Fd fd) { ::shutdown(fd, SHUT_RDWR); }
void shutdownRead(Fd fd) { ::shutdown(fd, SHUT_RD); }
void ensureSockets() {
  // A send/writev to a peer that already went away must surface as EPIPE
  // (handled as `sent=false` by the callers), never as a SIGPIPE that kills
  // the whole process. POSIX-only: Windows reports the error synchronously.
  static const bool ignored = [] {
    ::signal(SIGPIPE, SIG_IGN);
    return true;
  }();
  (void)ignored;
}
/// macOS raises SIGPIPE on send/writev regardless of MSG_NOSIGNAL; the
/// per-socket opt-out is SO_NOSIGPIPE. No-op elsewhere.
void setNoSigPipe(Fd fd) {
#ifdef SO_NOSIGPIPE
  int one = 1;
  ::setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#else
  (void)fd;
#endif
}
void setNonBlocking(Fd fd, bool on) {
  const int flags = fcntl(fd, F_GETFL, 0);
  if (flags < 0) return;
  fcntl(fd, F_SETFL, on ? (flags | O_NONBLOCK) : (flags & ~O_NONBLOCK));
}
bool wouldBlock() { return errno == EAGAIN || errno == EWOULDBLOCK; }
int pollFd(Fd fd, short events, int timeoutMs) {
  struct pollfd p{};
  p.fd = fd;
  p.events = events;
  int r;
  do {
    r = poll(&p, 1, timeoutMs);
  } while (r < 0 && errno == EINTR);
  return r > 0 ? p.revents : r;
}
bool pollTwo(Fd fd, Fd wake, int timeoutMs, bool& outFd, bool& outWake) {
  struct pollfd p[2]{};
  p[0].fd = fd;
  p[0].events = POLLIN;
  p[1].fd = wake;
  p[1].events = POLLIN;
  int r;
  do {
    r = poll(p, 2, timeoutMs);
  } while (r < 0 && errno == EINTR);
  outFd = r > 0 && p[0].revents != 0;
  outWake = r > 0 && p[1].revents != 0;
  return r >= 0;
}
#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif
ssize_t writeSome(Fd fd, const uint8_t* const* bufs, const size_t* lens,
                  int n) {
  struct iovec iov[3];
  int m = 0;
  for (int i = 0; i < n; i++) {
    if (lens[i] == 0) continue;
    iov[m].iov_base = (void*)bufs[i];
    iov[m].iov_len = lens[i];
    m++;
  }
  if (m == 0) return 0;
  struct msghdr msg{};
  msg.msg_iov = iov;
  msg.msg_iovlen = m;
  ssize_t r;
  do {
    r = sendmsg(fd, &msg, MSG_DONTWAIT | MSG_NOSIGNAL);
  } while (r < 0 && errno == EINTR);
  if (r < 0) return wouldBlock() ? 0 : -1;
  return r;
}
bool makeWake(Fd& r, Fd& w) {
  int p[2];
  if (pipe(p) != 0) return false;
  r = p[0];
  w = p[1];
  setNonBlocking(r, true);
  setNonBlocking(w, true);
  return true;
}
void closeWake(Fd fd) { ::close(fd); }
ssize_t recvSome(Fd fd, void* buf, size_t n) { return recv(fd, buf, n, 0); }
ssize_t peekOne(Fd fd) {
  char b;
  return recv(fd, &b, 1, MSG_PEEK);
}
ssize_t readWake(Fd fd, void* buf, size_t n) { return ::read(fd, buf, n); }
#endif

/// Wakes a parked worker: one byte, never blocks. A full pipe already holds
/// a pending wake, so a dropped byte changes nothing.
void poke(Fd wakeWrite) {
  if (wakeWrite == kBadFd) return;
  const uint8_t b = 1;
#ifdef _WIN32
  const uint8_t* bufs[1] = {&b};
  const size_t lens[1] = {1};
  writeSome(wakeWrite, bufs, lens, 1);
#else
  ssize_t r;
  do {
    r = ::write(wakeWrite, &b, 1);
  } while (r < 0 && errno == EINTR);
#endif
}

/// Drains every pending wake byte so the pipe reads as quiet again.
void drainWake(Fd wakeRead) {
  uint8_t buf[64];
  while (readWake(wakeRead, buf, sizeof(buf)) > 0) {
  }
}

constexpr size_t kMaxHeadBytes = 64 * 1024;
// 64 KiB per emit: halves malloc + ackBody FFI crossings vs 32 KiB while
// staying well under maxBodyBytes accounting granularity.
constexpr size_t kBodyEmitBytes = 64 * 1024;
// Bodies up to this size are read in full BEFORE the head is emitted, so
// Dart receives one chunk + one complete head instead of head + chunk +
// end marker: two port messages, one head decode.
constexpr size_t kInlineBodyBytes = 64 * 1024;

inline char toLowerAscii(char c) {
  return (c >= 'A' && c <= 'Z') ? (char)(c + ('a' - 'A')) : c;
}

/// Case-insensitive equality without allocating (replaces lower(a)==lower(b)).
inline bool iequals(const std::string& a, const char* b) {
  size_t i = 0;
  for (; i < a.size() && b[i] != '\0'; i++) {
    if (toLowerAscii(a[i]) != toLowerAscii(b[i])) return false;
  }
  return i == a.size() && b[i] == '\0';
}

/// Case-insensitive substring search without allocating.
inline bool icontains(const std::string& hay, const char* needle) {
  size_t nlen = strlen(needle);
  if (nlen == 0) return true;
  if (hay.size() < nlen) return false;
  for (size_t i = 0; i + nlen <= hay.size(); i++) {
    bool hit = true;
    for (size_t j = 0; j < nlen; j++) {
      if (toLowerAscii(hay[i + j]) != toLowerAscii(needle[j])) {
        hit = false;
        break;
      }
    }
    if (hit) return true;
  }
  return false;
}

/// Blocking-style read on a non-blocking socket: waits up to [timeoutMs]
/// for bytes. Returns the byte count, 0 on EOF, <0 on timeout/error.
ssize_t recvWait(Fd fd, void* buf, size_t n, int64_t timeoutMs) {
  while (true) {
    const ssize_t r = recvSome(fd, buf, n);
    if (r > 0) return r;
    if (r == 0) return 0;
    if (!wouldBlock()) return -1;
    const int ev = pollFd(fd, POLLIN, (int)std::min<int64_t>(timeoutMs, INT32_MAX));
    if (ev <= 0) return -1;  // Timeout or poll error.
  }
}

/// Reads until a full head is buffered, honouring the idle deadline
/// (between keep-alive requests, and as the header inactivity bound on the
/// first). Surplus bytes after the head stay in [buf] for the body reader
/// and the next pipelined request. Returns false on EOF, timeout or
/// oversize.
bool readHead(Fd fd, std::string& buf, int64_t idleMs) {
  char tmp[8192];
  while (buf.size() < kMaxHeadBytes) {
    if (buf.find("\r\n\r\n") != std::string::npos) return true;
    const ssize_t n = recvWait(fd, tmp, sizeof(tmp), idleMs);
    if (n <= 0) return false;
    buf.append(tmp, (size_t)n);
  }
  return buf.find("\r\n\r\n") != std::string::npos;
}

/// Trims whitespace off a view without allocating. The caller copies only
/// the survivors into their owning strings.
inline std::string_view trimSv(std::string_view s) {
  const size_t b = s.find_first_not_of(" \t");
  if (b == std::string_view::npos) return {};
  const size_t e = s.find_last_not_of(" \t");
  return s.substr(b, e - b + 1);
}

ParsedHead parseHead(const std::string& raw, size_t headEnd) {
  ParsedHead p;
  // Zero-copy: every slice below is a view into `raw`. Only the fields that
  // outlive the parse (target halves, header names/values, custom method)
  // are copied into owning strings. Views never escape: `carry` may
  // reallocate on later appends, so nothing here may be retained.
  const std::string_view head(raw.data(), headEnd);
  const size_t lineEnd = head.find("\r\n");
  if (lineEnd == std::string_view::npos) return p;
  const std::string_view requestLine = head.substr(0, lineEnd);
  const size_t sp1 = requestLine.find(' ');
  const size_t sp2 = sp1 == std::string_view::npos
                         ? std::string_view::npos
                         : requestLine.find(' ', sp1 + 1);
  if (sp1 == std::string_view::npos || sp2 == std::string_view::npos) return p;
  p.method = parseMethod(requestLine.substr(0, sp1), p.customMethod);
  const std::string_view target = requestLine.substr(sp1 + 1, sp2 - sp1 - 1);
  p.target.assign(target.data(), target.size());
  const std::string_view version = trimSv(requestLine.substr(sp2 + 1));
  p.version.assign(version.data(), version.size());
  // The head slice excludes the terminal \r\n\r\n, so the LAST header line
  // has no line ending — a loop that requires one silently drops it (which
  // used to hide `Connection: close` and a trailing Content-Length).
  size_t pos = lineEnd + 2;
  p.headers.reserve(8);
  while (pos <= head.size()) {
    const size_t eol = head.find("\r\n", pos);
    std::string_view line;
    if (eol == std::string_view::npos) {
      line = head.substr(pos);
      pos = head.size() + 1;
    } else {
      if (eol == pos) break;
      line = head.substr(pos, eol - pos);
      pos = eol + 2;
    }
    if (line.empty()) break;
    const size_t colon = line.find(':');
    if (colon == std::string_view::npos) return p;
    const std::string_view name = trimSv(line.substr(0, colon));
    const std::string_view value = trimSv(line.substr(colon + 1));
    p.headers.push_back({std::string(name), std::string(value)});
  }
  p.ok = true;
  return p;
}

const Header* findHeader(const std::vector<Header>& hs, const char* name) {
  for (const auto& h : hs) {
    if (iequals(h.name, name)) return &h;
  }
  return nullptr;
}

/// HTTP/1.1 keeps alive unless asked to close; 1.0 closes unless asked to
/// keep. Anything else (including a missing version) closes — a client that
/// cannot name its protocol does not get connection reuse.
bool clientWantsKeepAlive(const ParsedHead& head) {
  const bool is11 = head.version == "HTTP/1.1";
  const bool is10 = head.version == "HTTP/1.0";
  if (!is11 && !is10) return false;
  const Header* conn = findHeader(head.headers, "connection");
  if (!conn) return is11;
  if (icontains(conn->value, "close")) return false;
  if (is11) return true;
  return icontains(conn->value, "keep-alive");
}

/// True for an RFC 6455 WebSocket handshake attempt: `Connection` names
/// `upgrade` and `Upgrade` names `websocket` (both case-insensitive).
bool isWebSocketUpgrade(const ParsedHead& head) {
  const Header* conn = findHeader(head.headers, "connection");
  const Header* upgrade = findHeader(head.headers, "upgrade");
  if (!conn || !upgrade) return false;
  return icontains(conn->value, "upgrade") &&
         icontains(upgrade->value, "websocket");
}

/// Appends the decimal digits of [v] without std::to_string's allocation.
inline void appendInt(std::string& out, int64_t v) {
  char buf[24];
  const int n = snprintf(buf, sizeof(buf), "%lld", (long long)v);
  if (n > 0) out.append(buf, (size_t)n);
}

/// Builds the status line + headers for a one-shot or chunked answer. User
/// headers never override the framing (`Content-Length`/`Connection`/
/// `Transfer-Encoding` are authoritative here).
std::string buildHead(int64_t status, const std::vector<Header>& headers,
                      bool chunked, int64_t contentLength, bool keepAlive,
                      int64_t keepAliveSecs) {
  std::string out;
  out.reserve(160);
  out.append("HTTP/1.1 ");
  appendInt(out, status);
  out.push_back(' ');
  out.append(reasonPhrase(status));
  out.append("\r\n");
  for (const auto& h : headers) {
    if (iequals(h.name, "content-length")) continue;
    if (iequals(h.name, "connection")) continue;
    if (chunked && iequals(h.name, "transfer-encoding")) continue;
    out.append(h.name);
    out.append(": ");
    out.append(h.value);
    out.append("\r\n");
  }
  if (chunked) {
    out.append("Transfer-Encoding: chunked\r\n");
  } else {
    out.append("Content-Length: ");
    appendInt(out, contentLength);
    out.append("\r\n");
  }
  if (keepAlive) {
    out.append("Connection: keep-alive\r\nKeep-Alive: timeout=");
    appendInt(out, keepAliveSecs);
    out.append("\r\n\r\n");
  } else {
    out.append("Connection: close\r\n\r\n");
  }
  return out;
}

int64_t msSince(std::chrono::steady_clock::time_point t) {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::steady_clock::now() - t)
      .count();
}

}  // namespace

class NullEmitter final : public Emitter {
 public:
  void emitHead(int64_t, Method, const std::string&, const std::string&,
                const std::string&, const std::vector<Header>&, int64_t, bool,
                bool, const std::string&,
                const std::vector<RouteParam>&) override {}
  void emitBodyData(int64_t, uint8_t* payload, size_t) override {
    // Ownership transferred in: free on drop so the unbound window leaks
    // nothing. (Unreachable in practice — see lockedEmitter.)
    std::free(payload);
  }
  void emitBodyEnd(int64_t) override {}
  void emitBodyError(int64_t, uint8_t* payload, size_t, ErrorKind) override {
    std::free(payload);
  }
  void emitWsMessage(int64_t, uint8_t* payload, size_t, int, int) override {
    std::free(payload);
  }
  void emitEvent(ServerEventKind, int64_t, const std::string&) override {}
};

Emitter* ServerInstance::lockedEmitter() {
  static NullEmitter null;
  std::lock_guard<std::mutex> lk(emitterMutex_);
  return emitter_ ? emitter_ : &null;
}

void ServerInstance::configure(const ServerConfig& config) {
  std::unique_lock lk(configMutex_);
  config_ = config;
}

StatusResult ServerInstance::registerRoute(Method method,
                                           const std::string& customMethod,
                                           const std::string& pattern,
                                           int64_t timeoutMs,
                                           bool isWebSocket) {
  std::unique_lock lk(configMutex_);
  RouteEntry e{method, customMethod, pattern, timeoutMs, isWebSocket};
  if (!router_.add(e)) {
    return {ErrorKind::BadRequest,
            "invalid route pattern (want '/a/:b' with optional trailing '/*'): " +
                pattern,
            0};
  }
  return {};
}

StatusResult ServerInstance::unregisterRoute(Method method,
                                             const std::string& customMethod,
                                             const std::string& pattern) {
  std::unique_lock lk(configMutex_);
  if (!router_.remove(method, customMethod, pattern)) {
    return {ErrorKind::RouteNotFound, "no such route: " + pattern, 0};
  }
  return {};
}

StatusResult ServerInstance::start() {
  ensureSockets();
  ServerConfig cfg;
  {
    std::shared_lock lk(configMutex_);
    cfg = config_;
  }
  if (running_.exchange(true)) {
    // start() on a running server: report the live port, not the config.
    return {ErrorKind::AlreadyRunning, "server is already running",
            boundPort_.load()};
  }
  if (cfg.tlsRequested) {
    running_.store(false);
    return {ErrorKind::TlsError,
            "TLS is not enabled in this build (supportsTls() == false); "
            "pass an empty RawTlsConfig for plain HTTP",
            0};
  }

  // IPv6 when the host is a v6 literal (contains ':'). Binding "::" is
  // dual-stack (IPV6_V6ONLY off), so one socket serves v4-mapped clients too.
  const bool isV6 = cfg.host.find(':') != std::string::npos;
  Fd fd = socket(isV6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0);
  if (fd == kBadFd) {
    running_.store(false);
    return {ErrorKind::BindFailed, "socket() failed", 0};
  }
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, (const char*)&one, sizeof(one));
  // NOTE: no SO_REUSEPORT. REUSEPORT lets a second ServerInstance bind the
  // same port and silently steal half the accepts (which also broke the
  // SecondBindOnSamePortFails test on macOS/Linux). REUSEADDR alone is
  // enough for fast rebind after stop(); accepted sockets never block the
  // listen port.
  if (isV6) {
    int off = 0;
    setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, (const char*)&off, sizeof(off));
  }
  setNoSigPipe(fd);
  sockaddr_storage addr{};
  socklen_t addrLen = 0;
  if (isV6) {
    auto* a6 = (sockaddr_in6*)&addr;
    a6->sin6_family = AF_INET6;
    a6->sin6_port = htons((uint16_t)cfg.port);
    if (cfg.host == "::") {
      a6->sin6_addr = in6addr_any;
    } else if (inet_pton(AF_INET6, cfg.host.c_str(), &a6->sin6_addr) != 1) {
      closeFd(fd);
      running_.store(false);
      return {ErrorKind::BindFailed, "invalid host: " + cfg.host, 0};
    }
    addrLen = sizeof(sockaddr_in6);
  } else {
    auto* a4 = (sockaddr_in*)&addr;
    a4->sin_family = AF_INET;
    a4->sin_port = htons((uint16_t)cfg.port);
    if (cfg.host == "0.0.0.0") {
      a4->sin_addr.s_addr = htonl(INADDR_ANY);
    } else {
      if (inet_pton(AF_INET, cfg.host.c_str(), &a4->sin_addr) != 1) {
        closeFd(fd);
        running_.store(false);
        return {ErrorKind::BindFailed, "invalid host: " + cfg.host, 0};
      }
    }
    addrLen = sizeof(sockaddr_in);
  }
  if (bind(fd, (sockaddr*)&addr, addrLen) != 0 ||
      listen(fd, (int)(cfg.backlog > 0 ? cfg.backlog : 128)) != 0) {
    closeFd(fd);
    running_.store(false);
    return {ErrorKind::BindFailed,
            "bind/listen failed on " + cfg.host + ":" +
                std::to_string(cfg.port),
            0};
  }
  if (cfg.port == 0) {
    sockaddr_storage bound{};
    socklen_t len = sizeof(bound);
    if (getsockname(fd, (sockaddr*)&bound, &len) == 0) {
      boundPort_.store(ntohs(bound.ss_family == AF_INET6
                                 ? ((sockaddr_in6*)&bound)->sin6_port
                                 : ((sockaddr_in*)&bound)->sin_port));
    }
  } else {
    boundPort_.store(cfg.port);
  }
  listenFd_ = (int)fd;

  unsigned workers = cfg.workerThreads > 0 ? (unsigned)cfg.workerThreads : 0;
  if (workers == 0) {
    // A worker is pinned to its connection for the whole handler wait, so
    // fewer workers than live keep-alive connections means connections
    // cycle through the queue between workers (measured: a 14 ms p99 at 32
    // connections on 16 workers). Parked threads are cheap; size the pool
    // for real concurrency.
    // ponytail: thread-per-connection caps out around a few hundred live
    // connections; a poller-driven reactor is the upgrade path.
    const unsigned cores = std::thread::hardware_concurrency();
    workers = std::max(64u, (cores == 0 ? 8u : cores) * 4);
  }
  {
    auto self = shared_from_this();
    std::lock_guard<std::mutex> lk(acceptMutex_);
    acceptThread_ = std::thread([self]() { self->acceptLoop(); });
    workerWakes_.clear();
    workerWakes_.reserve(workers);
    for (unsigned i = 0; i < workers; i++) {
      Fd r, w;
      if (!makeWake(r, w)) break;  // Out of fds: run with fewer workers.
      Wake wake{(int)r, (int)w};
      workerWakes_.push_back(wake);
      workers_.emplace_back([self, wake]() { self->workerLoop(wake); });
    }
  }
  lockedEmitter()->emitEvent(ServerEventKind::Started, 0,
                             "listening on port " +
                                 std::to_string(boundPort_.load()) + " with " +
                                 std::to_string(workers_.size()) + " workers");
  return {ErrorKind::None, "", boundPort_.load()};
}

void ServerInstance::stop() {
  if (!running_.exchange(false)) return;
  if (listenFd_ != -1) {
    shutdownRdwr((Fd)listenFd_);
    closeFd((Fd)listenFd_);
    listenFd_ = -1;
  }
  {
    std::lock_guard<std::mutex> lk(acceptMutex_);
    if (acceptThread_.joinable()) acceptThread_.join();
  }
  // Hand every parked request to its worker as a 503, then wake the
  // workers: the pipe byte lands parked ones, SHUT_RD fails blocked reads
  // fast while leaving the send direction intact so the 503 still goes
  // out (RDWR would make it fail with EPIPE). Each worker closes its own
  // fd on the way out.
  pending_.abortAll();
  {
    std::lock_guard<std::mutex> lk(activeMutex_);
    for (int fd : activeFds_) shutdownRead((Fd)fd);
  }
  for (const Wake& w : workerWakes_) poke((Fd)w.w);
  queueCv_.notify_all();
  for (auto& w : workers_) {
    if (w.joinable()) w.join();
  }
  workers_.clear();
  for (const Wake& w : workerWakes_) {
    closeWake((Fd)w.r);
    closeWake((Fd)w.w);
  }
  workerWakes_.clear();
  {
    std::lock_guard<std::mutex> lk(queueMutex_);
    for (int fd : queue_) closeFd((Fd)fd);
    queue_.clear();
  }
  boundPort_.store(0);
  lockedEmitter()->emitEvent(ServerEventKind::Stopped, 0, "stopped");
}

// ── Direct-write answer path ────────────────────────────────────────────────

void ServerInstance::writeNow(const std::shared_ptr<PendingRequest>& req,
                              const uint8_t* a, size_t an, const uint8_t* b,
                              size_t bn, const uint8_t* c, size_t cn,
                              bool completes) {
  // Caller set `writing` under the lock. Write as much as the socket takes
  // without blocking, then reconcile under the lock.
  const uint8_t* bufs[3] = {a, b, c};
  size_t lens[3] = {an, bn, cn};
  const size_t total = an + bn + cn;
  size_t done = 0;
  bool failed = false;
  while (done < total) {
    const ssize_t r = writeSome((Fd)req->fd, bufs, lens, 3);
    if (r < 0) {
      failed = true;
      break;
    }
    if (r == 0) break;  // Would block: the worker flushes the rest.
    done += (size_t)r;
    size_t left = (size_t)r;
    for (int i = 0; i < 3 && left > 0; i++) {
      const size_t take = std::min(left, lens[i]);
      bufs[i] += take;
      lens[i] -= take;
      left -= take;
    }
  }
  bool wake = false;
  int wakeFd = -1;
  {
    std::lock_guard<std::mutex> lk(req->mutex);
    req->writing = false;
    wakeFd = req->wakeFd;
    if (failed) {
      req->failed = true;
      req->done = true;
      req->doneAt = std::chrono::steady_clock::now();
      wake = true;  // The worker must close.
    } else if (done < total) {
      for (int i = 0; i < 3; i++) {
        if (lens[i] > 0) req->tail.insert(req->tail.end(), bufs[i], bufs[i] + lens[i]);
      }
      if (completes) req->streamDone = true;  // Terminal already queued.
      wake = true;  // The worker flushes the tail.
    } else if (completes) {
      req->done = true;
      req->doneAt = std::chrono::steady_clock::now();
      // Keep-alive answers need no wake: the next request's bytes wake the
      // worker. Closing answers and explicitly waiting workers do.
      wake = !req->keepAlive || req->workerWaiting;
    }
    req->cv.notify_one();
  }
  if (wake) poke((Fd)wakeFd);
}

void ServerInstance::respond(int64_t requestId, int64_t status,
                             const std::vector<Header>& headers,
                             const uint8_t* body, size_t bodyLen) {
  auto req = pending_.find(requestId);
  if (!req) return;  // Unknown or already reaped: no-op by design.
  std::string head;
  {
    std::lock_guard<std::mutex> lk(req->mutex);
    if (req->answered) return;  // The timeout path won: late answer drops.
    req->answered = true;
    req->status = status;
    head = buildHead(status, headers, false, (int64_t)bodyLen,
                     req->keepAlive, req->keepAliveSecs);
    if (req->isHead) bodyLen = 0;
    req->writing = true;
  }
  writeNow(req, (const uint8_t*)head.data(), head.size(), body, bodyLen,
           nullptr, 0, true);
}

void ServerInstance::startStream(int64_t requestId, int64_t status,
                                 const std::vector<Header>& headers) {
  auto req = pending_.find(requestId);
  if (!req) return;  // Unknown or already reaped: no-op by design.
  std::string head;
  bool headOnly = false;
  {
    std::lock_guard<std::mutex> lk(req->mutex);
    if (req->answered || req->streamStarted) return;  // Timeout won / dup.
    req->answered = true;  // Headers are final; the timeout cannot win now.
    req->status = status;
    req->streamStarted = true;
    head = buildHead(status, headers, true, 0, req->keepAlive,
                     req->keepAliveSecs);
    // HEAD answers headers only: the stream is drained by no-op drops and
    // the connection closes (no resumption mid-stream).
    headOnly = req->isHead;
    if (headOnly) {
      req->streamDone = true;
      req->keepAlive = false;
    }
    req->writing = true;
  }
  writeNow(req, (const uint8_t*)head.data(), head.size(), nullptr, 0, nullptr,
           0, headOnly);
}

void ServerInstance::sendStreamChunk(int64_t requestId, const uint8_t* chunk,
                                     size_t n, bool last) {
  auto req = pending_.find(requestId);
  if (!req) return;  // Unknown or already reaped: no-op by design.
  if (chunk == nullptr) n = 0;
  char sizeLine[32];
  int sizeLen = 0;
  static const char kCrlf[] = "\r\n";
  static const char kCrlfEnd[] = "\r\n0\r\n\r\n";
  static const char kEnd[] = "0\r\n\r\n";
  const char* trail;
  size_t trailLen;
  bool wake = false;
  int wakeFd = -1;
  {
    std::lock_guard<std::mutex> lk(req->mutex);
    if (!req->streamStarted || req->streamDone || req->timedOut ||
        req->streamDead || req->done) {
      return;
    }
    // Empty non-terminal chunks are skipped: a `0` chunk would end the body.
    if (n == 0 && !last) return;
    if (n > 0) {
      sizeLen = snprintf(sizeLine, sizeof(sizeLine), "%zx\r\n", n);
      // The terminal marker rides the last data frame: no window in which
      // a flushed tail could look complete without it.
      trail = last ? kCrlfEnd : kCrlf;
      trailLen = last ? 7 : 2;
    } else {
      trail = kEnd;
      trailLen = 5;
    }
    if (last) req->streamDone = true;
    // Chunks are queued for the WORKER, not written here: a stream is many
    // small writes, and each one on the Dart isolate would serialize every
    // other request behind it. The worker drains whatever accumulated in
    // one pass, so bursts coalesce into fewer syscalls for free. One poke
    // wakes it; while it is flushing (or already poked) none is needed.
    wake = !req->flushing && req->tail.empty();
    wakeFd = req->wakeFd;
    if (n > 0) {
      req->tail.insert(req->tail.end(), sizeLine, sizeLine + sizeLen);
      req->tail.insert(req->tail.end(), chunk, chunk + n);
    }
    req->tail.insert(req->tail.end(), trail, trail + trailLen);
  }
  if (wake) poke((Fd)wakeFd);
}

void ServerInstance::ackBody(int64_t requestId, int64_t ackedChunks) {
  pending_.ack(requestId, ackedChunks);
}

bool ServerInstance::waitForDrainForTesting(int64_t timeoutMs) {
  const auto end =
      std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs);
  while (inFlight_.load() != 0) {
    if (std::chrono::steady_clock::now() > end) return false;
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  return true;
}

void ServerInstance::acceptLoop() {
  int64_t maxQueued;
  {
    std::shared_lock lk(configMutex_);
    maxQueued = config_.backlog > 0 ? config_.backlog : 128;
  }
  while (running_.load()) {
    sockaddr_storage peer{};
    socklen_t len = sizeof(peer);
    Fd fd = accept((Fd)listenFd_, (sockaddr*)&peer, &len);
    if (fd == kBadFd) {
      if (running_.load())
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
      continue;
    }
    setNoSigPipe(fd);
    setNonBlocking(fd, true);
    {
      std::lock_guard<std::mutex> lk(queueMutex_);
      if ((int64_t)queue_.size() >= maxQueued) {
        // Refuse fast: a accept loop that outruns its workers must shed load
        // at the door, not queue it until every client times out.
        closeFd(fd);
        continue;
      }
      queue_.push_back((int)fd);
    }
    queueCv_.notify_one();
  }
}

void ServerInstance::workerLoop(Wake wake) {
  while (true) {
    int fd = -1;
    {
      std::unique_lock<std::mutex> lk(queueMutex_);
      queueCv_.wait(lk, [&] { return !queue_.empty() || !running_.load(); });
      if (queue_.empty()) return;  // Stop was requested and nothing is queued.
      fd = queue_.back();
      queue_.pop_back();
    }
    handleConnection(fd, wake);
  }
}

bool ServerInstance::sendAll(int fd, const uint8_t* data, size_t n,
                             int64_t stallMs) {
  size_t sent = 0;
  while (sent < n) {
    const uint8_t* bufs[1] = {data + sent};
    const size_t lens[1] = {n - sent};
    const ssize_t r = writeSome((Fd)fd, bufs, lens, 1);
    if (r < 0) return false;
    if (r == 0) {
      const int ev = pollFd((Fd)fd, POLLOUT, (int)std::min<int64_t>(stallMs, INT32_MAX));
      if (ev <= 0) return false;
      continue;
    }
    sent += (size_t)r;
  }
  return true;
}

void ServerInstance::answerDirectly(int fd, Method method, int64_t status,
                                    const std::string& body,
                                    const std::vector<Header>& extra) {
  std::string head = "HTTP/1.1 " + std::to_string(status) + " " +
                     reasonPhrase(status) +
                     "\r\nContent-Type: text/plain\r\nContent-Length: " +
                     std::to_string(body.size()) + "\r\n";
  for (const auto& h : extra) head += h.name + ": " + h.value + "\r\n";
  head += "Connection: close\r\n\r\n";
  if (method != Method::Head && !body.empty()) head += body;
  sendAll(fd, (const uint8_t*)head.data(), head.size());
}

void ServerInstance::emitTerminalError(int64_t requestId,
                                        const std::string& message,
                                        ErrorKind kind) {
  uint8_t* payload = nullptr;
  if (!message.empty()) {
    payload = (uint8_t*)std::malloc(message.size());
    if (payload) memcpy(payload, message.data(), message.size());
  }
  if (payload) pending_.trackPayload(requestId, payload);
  lockedEmitter()->emitBodyError(requestId, payload, message.size(), kind);
  lockedEmitter()->emitBodyEnd(requestId);
}

bool ServerInstance::yieldToQueued(int fd) {
  // Bytes already waiting: serve them now instead of cycling the fd. This
  // check runs lock-free first so the uncontended hot path (pipelined or
  // coalesced bytes) costs one syscall and no mutex.
  const int ev = pollFd((Fd)fd, POLLIN, 0);
  if (ev > 0) return false;
  {
    std::lock_guard<std::mutex> lk(queueMutex_);
    if (queue_.empty()) return false;
    queue_.push_front(fd);
  }
  queueCv_.notify_one();
  return true;
}

void ServerInstance::handleConnection(int fd, const Wake& wake) {
  const Fd sock = (Fd)fd;
  {
    std::lock_guard<std::mutex> lk(activeMutex_);
    activeFds_.insert(fd);
  }
  inFlight_++;

  ServerConfig cfg;
  {
    std::shared_lock lk(configMutex_);
    cfg = config_;
  }
  int one = 1;
  setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, (const char*)&one, sizeof(one));

  std::string carry;
  int64_t served = 0;
  while (running_.load()) {
    // Starvation guard: when this fd has no buffered bytes but other
    // connections already wait, blocking in the keep-alive read pins a
    // worker while work starves. Yielding parks the fd at the queue front
    // (fair order) and frees this worker; the fd cycles back, unclosed.
    // Skipped when `carry` holds bytes: those were already consumed from
    // the socket, so only serveOne can see them — yielding would orphan
    // them into a hang.
    if (carry.empty() && yieldToQueued(fd)) {
      inFlight_--;
      return;
    }
    if (!serveOne(fd, wake, carry, served, cfg)) break;
    if (cfg.keepAliveTimeoutMs <= 0) break;
    if (cfg.maxRequestsPerConn > 0 && served >= cfg.maxRequestsPerConn) break;
  }

  {
    std::lock_guard<std::mutex> lk(activeMutex_);
    activeFds_.erase(fd);
  }
  closeFd(sock);
  inFlight_--;
}

bool ServerInstance::flushTail(int fd, const std::shared_ptr<PendingRequest>& req,
                               int64_t stallMs) {
  std::vector<uint8_t> chunk;
  while (true) {
    {
      std::lock_guard<std::mutex> lk(req->mutex);
      if (req->tail.empty()) {
        req->flushing = false;
        // Complete once nothing is pending and the answer has no more to
        // say: one-shot answers always, streams after their terminal.
        if (!req->streamStarted || req->streamDone) {
          req->done = true;
          req->doneAt = std::chrono::steady_clock::now();
        }
        return true;
      }
      chunk.swap(req->tail);
      req->tail.clear();
      req->flushing = true;
    }
    if (!sendAll(fd, chunk.data(), chunk.size(), stallMs)) {
      std::lock_guard<std::mutex> lk(req->mutex);
      req->flushing = false;
      req->failed = true;
      req->done = true;
      req->doneAt = std::chrono::steady_clock::now();
      return false;
    }
    chunk.clear();
  }
}

bool ServerInstance::awaitAnswer(int fd, const Wake& wake,
                                 const std::shared_ptr<PendingRequest>& req,
                                 int64_t requestId, int64_t timeoutMs,
                                 const ServerConfig& cfg, Emitter* emitter,
                                 bool inputBuffered) {
  const Fd sock = (Fd)fd;
  const auto start = std::chrono::steady_clock::now();
  const int64_t idleMs =
      cfg.keepAliveTimeoutMs > 0 ? cfg.keepAliveTimeoutMs : 5000;
  // Input already waiting (a pipelined request in `carry`, or bytes that
  // land while the answer is in flight): the socket cannot wake us for it,
  // so the answering thread must — `workerWaiting` asks for that poke.
  bool pendingInput = inputBuffered;
  while (true) {
    // ── Decide under the lock ──────────────────────────────────────────
    bool finished = false;
    bool ownedByWorker = false;
    bool keepAlive = false;
    bool hasTail = false;
    int64_t waitMs = 0;
    {
      std::lock_guard<std::mutex> lk(req->mutex);
      req->workerWaiting = false;
      if (req->done) {
        finished = true;
        keepAlive = req->keepAlive && !req->failed;
      } else if (req->answered && req->workerOwned) {
        ownedByWorker = true;
      } else if (!req->tail.empty() && !req->writing) {
        hasTail = true;
      } else if (req->answered && req->streamStarted && req->streamDead) {
        // stop() killed the stream mid-way: nothing more will come.
        req->done = true;
        req->failed = true;
        finished = true;
      } else if (!req->answered) {
        const int64_t elapsed = msSince(start);
        if (elapsed >= timeoutMs) {
          req->answered = true;
          req->timedOut = true;
          req->workerOwned = true;
          req->status = 408;
          req->headers = {{"Content-Type", "text/plain"}};
          static const char kMsg[] = "handler timeout";
          req->body.assign(kMsg, kMsg + sizeof(kMsg) - 1);
          ownedByWorker = true;
        } else {
          waitMs = std::min<int64_t>(timeoutMs - elapsed, idleMs);
        }
      } else {
        // Answered by Dart, write in flight or tail queued: it wakes us.
        waitMs = idleMs;
      }
      if (!finished && !ownedByWorker && !hasTail && pendingInput) {
        // Bytes (or EOF) arrived while the answer is in flight: nothing to
        // do with them until the wire is clean — ask for an explicit wake.
        req->workerWaiting = true;
      }
    }
    if (finished) return keepAlive;
    if (ownedByWorker) {
      // 408 / 503: serialize and send here, then close (never keep alive).
      std::string head;
      std::vector<uint8_t> body;
      bool isHead;
      {
        std::lock_guard<std::mutex> lk(req->mutex);
        head = buildHead(req->status, req->headers, false,
                         (int64_t)req->body.size(), false, 0);
        body = req->body;
        isHead = req->isHead;
        req->done = true;
        req->doneAt = std::chrono::steady_clock::now();
      }
      if (req->timedOut) {
        emitter->emitEvent(ServerEventKind::HandlerTimeout, requestId,
                           "handler exceeded " + std::to_string(timeoutMs) +
                               "ms");
      }
      if (!isHead && !body.empty()) head.append((const char*)body.data(), body.size());
      sendAll(fd, (const uint8_t*)head.data(), head.size(), idleMs);
      return false;
    }
    if (hasTail) {
      flushTail(fd, req, idleMs);
      continue;
    }
    // ── Park ───────────────────────────────────────────────────────────
    bool fdReady = false, wakeReady = false;
    bool pollOk;
    if (pendingInput) {
      // Level-triggered: the unread bytes would spin us. Wait for the wake
      // pipe only; writeNow pokes it because `workerWaiting` is set.
      const int ev = pollFd((Fd)wake.r, POLLIN,
                            (int)std::min<int64_t>(waitMs, INT32_MAX));
      pollOk = ev >= 0;
      wakeReady = ev > 0;
    } else {
      pollOk = pollTwo(sock, (Fd)wake.r,
                       (int)std::min<int64_t>(waitMs, INT32_MAX), fdReady,
                       wakeReady);
    }
    if (!pollOk) {
      std::lock_guard<std::mutex> lk(req->mutex);
      req->workerWaiting = false;
      req->failed = true;
      req->done = true;
      return false;
    }
    if (wakeReady) drainWake((Fd)wake.r);
    if (fdReady && !pendingInput) {
      // Peek without consuming: the answer may still be in flight, and the
      // bytes belong to the next request. EOF here means the client went
      // away — an unanswered request is abandoned, an in-flight answer
      // finishes (and fails fast) before the close.
      const ssize_t p = peekOne(sock);
      if (p == 0 || (p < 0 && !wouldBlock())) {
        std::lock_guard<std::mutex> lk(req->mutex);
        if (!req->answered) {
          req->answered = true;
          req->workerOwned = true;
          req->done = true;
          req->failed = true;
          return false;
        }
      }
      pendingInput = true;
    }
    if (!fdReady && !wakeReady) {
      // Timeout: either the route deadline (handled above on the next
      // pass) or the idle deadline after a completed keep-alive answer —
      // `done` is checked first on the next pass, and an idle expiry
      // simply falls out as a closed connection below.
      std::lock_guard<std::mutex> lk(req->mutex);
      if (req->done) {
        if (msSince(req->doneAt) >= idleMs) return false;  // Idle: close.
      }
    }
  }
}

bool ServerInstance::serveOne(int fd, const Wake& wake, std::string& carry,
                             int64_t& served, const ServerConfig& cfg) {
  const Fd sock = (Fd)fd;
  const int64_t idleMs =
      cfg.keepAliveTimeoutMs > 0 ? cfg.keepAliveTimeoutMs : 5000;
  if (!readHead(sock, carry, idleMs)) return false;  // EOF, idle, oversize.
  const size_t headEnd = carry.find("\r\n\r\n");
  size_t bodyStart = headEnd + 4;
  ParsedHead head = parseHead(carry, headEnd);
  if (!head.ok) {
    answerDirectly(fd, Method::Get, 400, "bad request");
    return false;
  }
  const bool keepPeer = clientWantsKeepAlive(head) && running_.load();

  std::string path = head.target;
  std::string query;
  const size_t q = path.find('?');
  if (q != std::string::npos) {
    query = path.substr(q + 1);
    path = path.substr(0, q);
  }
  if (path.empty()) path = "/";

  MatchResult m;
  {
    std::shared_lock lk(configMutex_);
    m = router_.match(head.method, head.customMethod, path);
  }
  if (!m.matched) {
    // No route at all: a handshake-shaped request is refused honestly
    // (RFC 6455 §4.2.2) instead of a misleading 404.
    if (isWebSocketUpgrade(head)) {
      answerDirectly(fd, head.method, 426, "websocket not supported",
                     {{"Sec-WebSocket-Version", "13"}});
    } else {
      answerDirectly(fd, head.method, 404, "not found");
    }
    return false;
  }

  // WebSocket routes own their handshake: validate, answer 101 and hand the
  // socket to the frame loop. Anything else on such a route (plain GET,
  // wrong version, missing key) is answered directly — never dispatched.
  if (m.route.isWebSocket) {
    return serveUpgrade(fd, carry, bodyStart, head, m, cfg, path, query);
  }

  // A handshake aimed at a plain HTTP route: refuse honestly (RFC 6455
  // §4.2.2) instead of a misleading 404. After routing, so WS routes above
  // still upgrade — and dispatching an Upgrade would park a worker on a
  // body that never arrives.
  if (isWebSocketUpgrade(head)) {
    answerDirectly(fd, head.method, 426, "websocket not supported",
                   {{"Sec-WebSocket-Version", "13"}});
    return false;
  }

  const int64_t timeoutMs =
      m.route.timeoutMs >= 0 ? m.route.timeoutMs : cfg.defaultTimeoutMs;
  const int64_t requestId = nextRequestId();
  auto req = pending_.create(requestId);
  // Wire state the answering thread needs, fixed before anyone can answer.
  // The max-requests budget is honored in the framing: the final response
  // on a connection must say `close`, not promise a keep-alive it will not
  // deliver. (`served` counts completed requests, so this one is number
  // `served + 1`.)
  const bool underBudget =
      cfg.maxRequestsPerConn <= 0 || served + 1 < cfg.maxRequestsPerConn;
  req->fd = fd;
  req->wakeFd = wake.w;
  req->isHead = head.method == Method::Head;
  req->keepAlive = keepPeer && cfg.keepAliveTimeoutMs > 0 && underBudget;
  req->keepAliveSecs = (cfg.keepAliveTimeoutMs + 999) / 1000;

  // 100-continue handshake before the client sends a body.
  if (const Header* expect = findHeader(head.headers, "expect")) {
    if (icontains(expect->value, "100-continue")) {
      const char* cont = "HTTP/1.1 100 Continue\r\n\r\n";
      sendAll(fd, (const uint8_t*)cont, strlen(cont));
    }
  }

  int64_t contentLength = 0;
  bool chunked = false;
  if (const Header* cl = findHeader(head.headers, "content-length")) {
    char* end = nullptr;
    contentLength = std::strtoll(cl->value.c_str(), &end, 10);
    if (end == cl->value.c_str() || contentLength < 0) contentLength = -1;
  }
  if (const Header* te = findHeader(head.headers, "transfer-encoding")) {
    if (icontains(te->value, "chunked")) chunked = true;
  }
  if (contentLength < 0) {
    answerDirectly(fd, head.method, 400, "bad content-length");
    pending_.erase(requestId);
    return false;
  }
  const bool hasBody = chunked || contentLength > 0;
  if (!chunked && contentLength > cfg.maxBodyBytes) {
    emitTerminalError(requestId, "request body exceeds maxBodyBytes",
                      ErrorKind::RequestTooLarge);
    answerDirectly(fd, head.method, 413, "content too large");
    pending_.erase(requestId);
    return false;
  }

  // Load the emitter once for the entire request lifecycle. The pointer
  // never changes during normal operation (setEmitter is only called on
  // factory resolve before any requests arrive), so this is safe without
  // re-locking per call.
  Emitter* emitter = lockedEmitter();

  // Small bodies (the common POST) are read in full first, so Dart gets one
  // chunk then one COMPLETE head — two port messages and a single head
  // decode instead of head + chunk + end marker.
  const bool inlineBody =
      hasBody && !chunked && (size_t)contentLength <= kInlineBodyBytes;
  if (!inlineBody) {
    emitter->emitHead(requestId, head.method, head.customMethod, path,
                      query, head.headers, chunked ? -1 : contentLength,
                      hasBody, !hasBody, m.route.pattern, m.params);
  }

  // Stream the body. Already-buffered bytes first, then the socket. Anything
  // left in `carry` past the body belongs to the next pipelined request.
  int64_t remaining = contentLength;
  bool tooLarge = false;
  int64_t received = 0;
  auto emitBytes = [&](const uint8_t* data, size_t n) {
    size_t off = 0;
    while (off < n) {
      const size_t take = std::min(kBodyEmitBytes, n - off);
      uint8_t* payload = (uint8_t*)std::malloc(take);
      if (!payload) {
        tooLarge = true;
        return;
      }
      memcpy(payload, data + off, take);
      pending_.trackPayload(requestId, payload);
      emitter->emitBodyData(requestId, payload, take);
      off += take;
    }
  };

  if (chunked) {
    size_t pos = bodyStart;
    bool done = false;
    auto fill = [&](size_t need) -> bool {
      while (carry.size() - pos < need) {
        char buf[8192];
        const ssize_t n = recvWait(sock, buf, sizeof(buf), idleMs);
        if (n <= 0) return false;
        carry.append(buf, (size_t)n);
        if (carry.size() > (size_t)cfg.maxBodyBytes + 1024) return false;
      }
      return true;
    };
    while (!done) {
      size_t eol = std::string::npos;
      while (true) {
        eol = carry.find("\r\n", pos);
        if (eol != std::string::npos) break;
        if (!fill((carry.size() - pos) + 1)) break;
      }
      if (eol == std::string::npos) break;
      long chunkSize = strtol(carry.c_str() + pos, nullptr, 16);
      pos = eol + 2;
      if (chunkSize == 0) {
        // Terminal "0" line consumed — but a chunked body ends with an
        // optional trailer section plus a final CRLF ("0\r\n\r\n" with no
        // trailers). Consume through the terminating empty line so `carry`
        // starts clean for the next pipelined request: leaving even "\r\n"
        // behind makes the next head parse see an empty request line (400).
        // Bounded by fill()'s maxBodyBytes cap, like everything else here.
        bool trailersOk = false;
        while (true) {
          size_t eol2 = std::string::npos;
          while (true) {
            eol2 = carry.find("\r\n", pos);
            if (eol2 != std::string::npos) break;
            if (!fill((carry.size() - pos) + 1)) break;
          }
          if (eol2 == std::string::npos) break;
          if (eol2 == pos) {
            pos += 2;
            trailersOk = true;
            break;
          }
          pos = eol2 + 2;  // Skip one trailer line (values unused).
        }
        done = trailersOk;
        break;
      }
      if (chunkSize < 0 || received + chunkSize > cfg.maxBodyBytes) {
        tooLarge = true;
        break;
      }
      if (!fill((size_t)chunkSize + 2)) break;
      emitBytes((const uint8_t*)carry.data() + pos, (size_t)chunkSize);
      received += chunkSize;
      pos += (size_t)chunkSize + 2;  // Skip trailing CRLF.
    }
    if (!done && !tooLarge) {
      emitTerminalError(requestId, "truncated chunked body",
                        ErrorKind::BadRequest);
      answerDirectly(fd, head.method, 400, "truncated body");
      pending_.erase(requestId);
      return false;
    }
    carry.erase(0, pos);
  } else if (inlineBody) {
    // Pull the whole body into `carry`, then emit it as one chunk.
    while (carry.size() - bodyStart < (size_t)contentLength) {
      char buf[16384];
      const ssize_t n = recvWait(sock, buf, sizeof(buf), idleMs);
      if (n <= 0) {
        emitTerminalError(requestId, "truncated body", ErrorKind::BadRequest);
        answerDirectly(fd, head.method, 400, "truncated body");
        pending_.erase(requestId);
        return false;
      }
      carry.append(buf, (size_t)n);
    }
    emitBytes((const uint8_t*)carry.data() + bodyStart, (size_t)contentLength);
    received = contentLength;
    remaining = 0;
    carry.erase(0, bodyStart + (size_t)contentLength);
  } else if (hasBody) {
    size_t buffered = carry.size() - bodyStart;
    if (buffered > 0) {
      const size_t take =
          (size_t)std::min<int64_t>((int64_t)buffered, remaining);
      emitBytes((const uint8_t*)carry.data() + bodyStart, take);
      remaining -= (int64_t)take;
      received += (int64_t)take;
      bodyStart += take;
    }
    // One 64 KiB read per emit chunk: 16× fewer syscalls than 4 KiB reads
    // on a megabyte upload, and each read lands as exactly one payload.
    static thread_local std::vector<uint8_t> buf(kBodyEmitBytes);
    while (remaining > 0 && !tooLarge) {
      const ssize_t n = recvWait(
          sock, buf.data(), (size_t)std::min<int64_t>((int64_t)buf.size(), remaining),
          idleMs);
      if (n <= 0) break;
      emitBytes(buf.data(), (size_t)n);
      remaining -= n;
      received += n;
    }
    if (remaining != 0 && !tooLarge) {
      emitTerminalError(requestId, "truncated body", ErrorKind::BadRequest);
      answerDirectly(fd, head.method, 400, "truncated body");
      pending_.erase(requestId);
      return false;
    }
    // Reaching here means remaining == 0, so exactly head + contentLength
    // bytes were consumed. Note `bodyStart` already advanced past the
    // buffered share — erasing `bodyStart + contentLength` would count those
    // bytes twice and eat the next pipelined request's head (every
    // keep-alive POST whose body coalesces with its head).
    carry.erase(0, (headEnd + 4) + (size_t)contentLength);
  } else {
    carry.erase(0, bodyStart);
  }

  if (tooLarge) {
    emitTerminalError(requestId, "request body exceeds maxBodyBytes",
                      ErrorKind::RequestTooLarge);
    answerDirectly(fd, head.method, 413, "content too large");
    pending_.erase(requestId);
    return false;
  }
  if (inlineBody) {
    // The chunk is already on its port; this head completes the request.
    emitter->emitHead(requestId, head.method, head.customMethod, path, query,
                      head.headers, contentLength, true, true,
                      m.route.pattern, m.params);
  } else if (hasBody) {
    emitter->emitBodyEnd(requestId);
  }

  // Park until the answer is on the wire, the ROUTE's timeout fires, or
  // stop(). Only a clean cycle keeps alive: the framing past this point is
  // exact, so whatever `carry` holds is the next request, not debris.
  const bool again = awaitAnswer(fd, wake, req, requestId, timeoutMs, cfg,
                                 emitter, !carry.empty());
  pending_.erase(requestId);
  served++;
  return again;
}

// ── WebSocket (RFC 6455) ─────────────────────────────────────────────────

/// Blocking exact read. Returns false on EOF, error or (pre-upgrade only)
/// timeout — the frame loop disables the receive timeout, so a false there
/// means the peer went away or stop() interrupted the read.
bool wsRecvAll(int fd, uint8_t* dst, size_t n) {
  const Fd sock = (Fd)fd;
  size_t got = 0;
  while (got < n) {
    const size_t want = std::min(n - got, (size_t)65536);
#ifdef _WIN32
    const int r = recv(sock, (char*)dst + got, (int)want, 0);
#else
    const ssize_t r = recv(sock, dst + got, want, 0);
#endif
    if (r <= 0) return false;
    got += (size_t)r;
  }
  return true;
}

bool ServerInstance::serveUpgrade(int fd, const std::string& carry,
                                  size_t bodyStart, const ParsedHead& head,
                                  const MatchResult& m, const ServerConfig& cfg,
                                  const std::string& path,
                                  const std::string& query) {
  // Surplus bytes after the head cannot be a handshake (handshakes carry no
  // body) and would desync frame parsing — refuse instead of guessing.
  if (carry.size() != bodyStart) {
    answerDirectly(fd, head.method, 400, "unexpected bytes after upgrade");
    return false;
  }
  if (!isWebSocketUpgrade(head)) {
    answerDirectly(fd, head.method, 426, "websocket upgrade required",
                   {{"Sec-WebSocket-Version", "13"}});
    return false;
  }
  const Header* ver = findHeader(head.headers, "sec-websocket-version");
  if (!ver || trimSv(ver->value) != "13") {
    answerDirectly(fd, head.method, 426, "unsupported websocket version",
                   {{"Sec-WebSocket-Version", "13"}});
    return false;
  }
  const Header* key = findHeader(head.headers, "sec-websocket-key");
  const std::string clientKey =
      key == nullptr ? "" : std::string(trimSv(key->value));
  if (clientKey.empty()) {
    answerDirectly(fd, head.method, 400, "missing sec-websocket-key");
    return false;
  }

  // The frame loop is blocking code: undo the accept-time O_NONBLOCK.
  setNonBlocking((Fd)fd, false);
  const std::string accept = ws::acceptKey(clientKey);
  const std::string shake =
      "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
      "Connection: Upgrade\r\nSec-WebSocket-Accept: " +
      accept + "\r\n\r\n";
  if (!sendAll(fd, (const uint8_t*)shake.data(), shake.size())) return false;

  const int64_t connectionId = nextRequestId();
  {
    std::lock_guard<std::mutex> lk(wsMutex_);
    ws_[connectionId] = WsConn{fd};
  }
  // The session opens through normal head dispatch, so Dart sees the
  // handshake's pattern, params, query and headers like any request.
  lockedEmitter()->emitHead(connectionId, head.method, head.customMethod,
                            path, query, head.headers, 0, false, true,
                            m.route.pattern, m.params);
  wsLoop(fd, connectionId, cfg.maxBodyBytes);
  {
    std::lock_guard<std::mutex> lk(wsMutex_);
    ws_.erase(connectionId);
  }
  pending_.dropPayloads(connectionId);
  return false;  // Upgraded connections never serve HTTP again.
}

bool ServerInstance::wsSendFrame(int fd, int opcode, const uint8_t* payload,
                                 size_t n) {
  std::vector<uint8_t> frame;
  frame.reserve(n + 10);
  ws::encodeFrame(opcode, payload == nullptr ? (const uint8_t*)"" : payload,
                  n, true, frame);
  std::lock_guard<std::mutex> lk(wsSendMutex_);
  return sendAll(fd, frame.data(), frame.size());
}

void ServerInstance::emitWs(int64_t connectionId, int opcode,
                            const uint8_t* data, size_t n, int code) {
  uint8_t* payload = nullptr;
  if (n > 0) {
    payload = (uint8_t*)std::malloc(n);
    if (payload == nullptr) return;  // OOM: drop, the loop still reaps.
    memcpy(payload, data, n);
  }
  pending_.trackPayload(connectionId, payload);
  lockedEmitter()->emitWsMessage(connectionId, payload, n, opcode, code);
}

void ServerInstance::wsSend(int64_t connectionId, const uint8_t* payload,
                            size_t n, bool binary) {
  int fd = -1;
  {
    std::lock_guard<std::mutex> lk(wsMutex_);
    auto it = ws_.find(connectionId);
    if (it == ws_.end()) return;  // Unknown or reaped: no-op by design.
    fd = it->second.fd;
  }
  // Synchronous write under the send mutex: bridge memory is never retained,
  // so no copy is needed. On failure the loop's next read observes the dead
  // peer (or stop() already did) — reap stays single-owned by the loop.
  if (!wsSendFrame(fd, binary ? ws::kBinary : ws::kText, payload, n)) {
    shutdownRdwr((Fd)fd);
  }
}

void ServerInstance::wsClose(int64_t connectionId, int code) {
  int fd = -1;
  {
    std::lock_guard<std::mutex> lk(wsMutex_);
    auto it = ws_.find(connectionId);
    if (it == ws_.end()) return;  // Unknown or reaped: no-op by design.
    fd = it->second.fd;
    ws_.erase(it);
  }
  uint8_t payload[2] = {(uint8_t)((code >> 8) & 0xff), (uint8_t)(code & 0xff)};
  wsSendFrame(fd, ws::kClose, payload, 2);
  // Do not wait for the peer's echo: unblock the loop now so no worker can
  // park on a client that never answers.
  shutdownRdwr((Fd)fd);
}

void ServerInstance::wsLoop(int fd, int64_t connectionId,
                            int64_t maxMessageBytes) {
  const Fd sock = (Fd)fd;
  // Sessions live indefinitely: drop the HTTP idle deadline. stop() still
  // interrupts via shutdown on the (tracked) fd.
#ifdef _WIN32
  DWORD noTimeout = 0;
  setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, (const char*)&noTimeout,
             sizeof(noTimeout));
#else
  struct timeval noTimeout{};
  noTimeout.tv_sec = 0;
  noTimeout.tv_usec = 0;
  setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &noTimeout, sizeof(noTimeout));
#endif

  std::vector<uint8_t> msg;
  int msgOpcode = -1;
  int closeCode = 1006;  // Abnormal closure unless the peer says otherwise.
  bool peerClosed = false;
  bool failed = false;

  auto protocolError = [&](int code) {
    uint8_t payload[2] = {(uint8_t)((code >> 8) & 0xff),
                           (uint8_t)(code & 0xff)};
    wsSendFrame(fd, ws::kClose, payload, 2);
    closeCode = code;  // Dart sees what the peer already holds.
    failed = true;
  };

  std::vector<uint8_t> net;
  net.reserve(8192);
  uint8_t tmp[4096];
  while (!failed && !peerClosed) {
    // Grow the buffer until a full header parses. parseHeader cannot tell
    // "need more" from "malformed", so validate the fixed prefix first:
    // RSV/opcode are decided by the first two bytes alone.
    ws::FrameHeader h;
    bool haveHeader = false;
    // Pipelined frames coalesce in `net`: attempt the parse on buffered
    // bytes BEFORE blocking in recv, or the loop waits for bytes it holds.
    while (!haveHeader && !failed && !peerClosed) {
      if (net.size() >= 2) {
        const uint8_t b0 = net[0];
        const int opcode = b0 & 0x0f;
        if ((b0 & 0x70) || (opcode != 0x0 && opcode != 0x1 &&
                            opcode != 0x2 && opcode != 0x8 &&
                            opcode != 0x9 && opcode != 0xA)) {
          protocolError(1002);
          break;
        }
        // Header length is fixed by the length marker + mask flag: decide
        // on exactly that many bytes, then parse strictly.
        size_t need = 2;
        const uint8_t marker = net[1] & 0x7f;
        if (marker == 126) {
          need = 4;
        } else if (marker == 127) {
          need = 10;
        }
        if (net[1] & 0x80) need += 4;
        if (net.size() >= need) {
          if (ws::parseHeader(net.data(), need, h)) {
            haveHeader = true;
          } else {
            protocolError(1002);  // Complete yet invalid.
          }
          break;
        }
      }
#ifdef _WIN32
      const int r = recv(sock, (char*)tmp, sizeof(tmp), 0);
#else
      const ssize_t r = recv(sock, (char*)tmp, sizeof(tmp), 0);
#endif
      if (r <= 0) {
        failed = true;
        break;
      }
      net.insert(net.end(), tmp, tmp + r);
    }
    if (!haveHeader) break;
    net.erase(net.begin(), net.begin() + (ptrdiff_t)h.headerSize);

    // Clients MUST mask (RFC 6455 §5.3): an unmasked frame is a protocol
    // error, answered before reading its body.
    if (!h.masked) {
      protocolError(1002);
      break;
    }
    // Cap by declared length before buffering the body.
    if (!ws::isControl(h.opcode) &&
        h.length > (uint64_t)maxMessageBytes) {
      protocolError(1009);
      break;
    }
    // The payload may already sit in `net` (coalesced segment): consume
    // buffered bytes first so the socket read cannot block on held bytes —
    // and leave any pipelined frames for the next iteration.
    std::vector<uint8_t> payload;
    payload.reserve((size_t)std::min<uint64_t>(h.length, 65536));
    const size_t buffered =
        std::min(net.size(), (size_t)h.length);
    payload.insert(payload.end(), net.begin(),
                   net.begin() + (ptrdiff_t)buffered);
    net.erase(net.begin(), net.begin() + (ptrdiff_t)buffered);
    payload.resize((size_t)h.length);
    if (h.length > buffered &&
        !wsRecvAll(fd, payload.data() + buffered, (size_t)h.length - buffered)) {
      failed = true;
      break;
    }
    for (size_t i = 0; i < payload.size(); i++) {
      payload[i] ^= h.mask[i % 4];
    }

    if (ws::isControl(h.opcode)) {
      if (h.opcode == ws::kPing) {
        wsSendFrame(fd, ws::kPong, payload.data(), payload.size());
      } else if (h.opcode == ws::kClose) {
        if (payload.size() >= 2) {
          closeCode = ((int)payload[0] << 8) | payload[1];
        } else {
          closeCode = 1000;
        }
        // Echo the close (RFC 6455 §5.5.1) and leave HTTP-forbidden land.
        wsSendFrame(fd, ws::kClose, payload.data(), payload.size());
        peerClosed = true;
      }
      // Pongs and unknown control frames (unreachable: parse rejects them)
      // are ignored.
      continue;
    }

    if (h.opcode == ws::kContinuation) {
      if (msgOpcode < 0) {
        protocolError(1002);
        break;
      }
      msg.insert(msg.end(), payload.begin(), payload.end());
    } else {
      if (msgOpcode >= 0) {
        protocolError(1002);  // New message before the previous FIN.
        break;
      }
      msgOpcode = h.opcode;
      msg = std::move(payload);
    }
    if ((int64_t)msg.size() > maxMessageBytes) {
      protocolError(1009);
      break;
    }
    if (h.fin) {
      if (msgOpcode == ws::kText && !ws::validUtf8(msg.data(), msg.size())) {
        protocolError(1007);
        break;
      }
      emitWs(connectionId, msgOpcode, msg.data(), msg.size(), 0);
      msg.clear();
      msgOpcode = -1;
    }
  }

  // Every exit ends with opcode 8 so Dart reaps deterministically: the peer
  // code on a clean close, the sent code on our protocol errors (the peer
  // already holds the matching frame), 1006 on transport failure.
  emitWs(connectionId, ws::kClose, nullptr, 0, closeCode);
}

}  // namespace nitroserver
