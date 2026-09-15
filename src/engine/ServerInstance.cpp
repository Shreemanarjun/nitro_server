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
#include <fcntl.h>
#include <io.h>
#include <sys/stat.h>
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
#include <sys/stat.h>
#include <sys/uio.h>
#include <unistd.h>
#if defined(__linux__)
#include <sys/sendfile.h>
#endif
#endif

#ifdef NITRO_SERVER_TLS
#include <openssl/err.h>
#include <openssl/ssl.h>
#include <cerrno>
#endif

namespace nitroserver {
namespace {

#ifdef NITRO_SERVER_TLS
// fd -> SSL*. Consulted by recvSome/writeSome so the existing I/O funnels
// transparently carry TLS. All SSL calls for one fd run on its worker
// thread (the Dart isolate hands its answer to the worker for TLS), so an
// SSL object is never touched concurrently; only this map is shared, and it
// is mutated on accept/close. The atomic count gates the plain-HTTP path to
// zero overhead when no TLS connection exists.
struct TlsSockets {
  std::mutex m;
  std::unordered_map<int, SSL*> map;
  std::atomic<int> count{0};
  void add(int fd, SSL* s) {
    std::lock_guard<std::mutex> l(m);
    map[fd] = s;
    count.fetch_add(1, std::memory_order_relaxed);
  }
  SSL* get(int fd) {
    if (count.load(std::memory_order_relaxed) == 0) return nullptr;
    std::lock_guard<std::mutex> l(m);
    auto it = map.find(fd);
    return it == map.end() ? nullptr : it->second;
  }
  SSL* take(int fd) {
    std::lock_guard<std::mutex> l(m);
    auto it = map.find(fd);
    if (it == map.end()) return nullptr;
    SSL* s = it->second;
    map.erase(it);
    count.fetch_sub(1, std::memory_order_relaxed);
    return s;
  }
};
TlsSockets g_tls;

// SSL_read mapped to the recv contract: >0 bytes, 0 clean close, -1 with
// errno EWOULDBLOCK for a retry (the caller polls POLLIN), any other -1 is a
// hard error. WANT_WRITE happens on a non-blocking socket when SSL must send
// before it can return app data (a TLS 1.3 post-handshake message, e.g. a
// session ticket or key update). The caller only knows to poll for reads, so
// wait for writability here and retry — otherwise the read hangs forever.
ssize_t tlsRead(SSL* ssl, void* buf, size_t n) {
  const int fd = SSL_get_fd(ssl);
  for (;;) {
    ERR_clear_error();
    const int r = SSL_read(ssl, buf, (int)std::min<size_t>(n, 0x7fffffff));
    if (r > 0) return r;
    const int e = SSL_get_error(ssl, r);
    if (e == SSL_ERROR_ZERO_RETURN) return 0;
    if (e == SSL_ERROR_WANT_READ) {
      errno = EWOULDBLOCK;
      return -1;
    }
    if (e == SSL_ERROR_WANT_WRITE) {
      struct pollfd p {fd, POLLOUT, 0};
      if (::poll(&p, 1, 5000) <= 0) {
        errno = EWOULDBLOCK;
        return -1;
      }
      continue;
    }
    errno = ECONNRESET;
    return -1;
  }
}

// SSL_write mapped to the writeSome contract: writes one non-empty segment,
// returns bytes written (partial allowed via SSL_MODE_ENABLE_PARTIAL_WRITE),
// 0 when it would block (caller polls POLLOUT and retries), -1 on error.
// WANT_READ during a write (SSL must read before it can send) is handled here
// so the caller — which only polls for writability — does not stall.
ssize_t tlsWrite(SSL* ssl, const uint8_t* const* bufs, const size_t* lens,
                 int n) {
  const int fd = SSL_get_fd(ssl);
  for (int i = 0; i < n; i++) {
    if (lens[i] == 0) continue;
    for (;;) {
      ERR_clear_error();
      const int r = SSL_write(ssl, bufs[i], (int)std::min<size_t>(lens[i], 0x7fffffff));
      if (r > 0) return r;
      const int e = SSL_get_error(ssl, r);
      if (e == SSL_ERROR_WANT_WRITE) return 0;
      if (e == SSL_ERROR_WANT_READ) {
        struct pollfd p {fd, POLLIN, 0};
        if (::poll(&p, 1, 5000) <= 0) return 0;
        continue;
      }
      return -1;
    }
  }
  return 0;
}

// ALPN: offer http/1.1 only (the engine speaks HTTP/1.1). A client that
// insists on something else fails the negotiation, which is correct.
int tlsAlpnSelect(SSL*, const unsigned char** out, unsigned char* outlen,
                  const unsigned char* in, unsigned int inlen, void*) {
  static const unsigned char kProto[] = {8, 'h', 't', 't', 'p', '/', '1', '.', '1'};
  if (SSL_select_next_proto((unsigned char**)out, outlen, kProto, sizeof(kProto),
                            in, inlen) != OPENSSL_NPN_NEGOTIATED) {
    return SSL_TLSEXT_ERR_NOACK;  // No overlap: proceed without ALPN.
  }
  return SSL_TLSEXT_ERR_OK;
}
#endif  // NITRO_SERVER_TLS


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
bool pollTwo(Fd fd, Fd wake, int timeoutMs, bool& outFd, bool& outWake,
             bool wantWrite = false) {
  WSAPOLLFD p[2]{};
  p[0].fd = fd;
  p[0].events = wantWrite ? (POLLIN | POLLOUT) : POLLIN;
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
bool pollTwo(Fd fd, Fd wake, int timeoutMs, bool& outFd, bool& outWake,
             bool wantWrite = false) {
  struct pollfd p[2]{};
  p[0].fd = fd;
  p[0].events = wantWrite ? (POLLIN | POLLOUT) : POLLIN;
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
#ifdef NITRO_SERVER_TLS
  if (SSL* ssl = g_tls.get((int)fd)) return tlsWrite(ssl, bufs, lens, n);
#endif
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
ssize_t recvSome(Fd fd, void* buf, size_t n) {
#ifdef NITRO_SERVER_TLS
  if (SSL* ssl = g_tls.get((int)fd)) return tlsRead(ssl, buf, n);
#endif
  return recv(fd, buf, n, 0);
}
ssize_t peekOne(Fd fd) {
  char b;
  return recv(fd, &b, 1, MSG_PEEK);
}
ssize_t readWake(Fd fd, void* buf, size_t n) { return ::read(fd, buf, n); }
#endif

/// Opens [path] read-only; returns the descriptor and its size, or -1/-1.
int openFileReadOnly(const std::string& path, int64_t& size) {
#ifdef _WIN32
  const int f = _open(path.c_str(), _O_RDONLY | _O_BINARY);
  if (f < 0) return -1;
  struct _stat64 st{};
  if (_fstat64(f, &st) != 0 || (st.st_mode & _S_IFREG) == 0) {
    _close(f);
    return -1;
  }
  size = (int64_t)st.st_size;
  return f;
#else
  const int f = ::open(path.c_str(), O_RDONLY | O_CLOEXEC);
  if (f < 0) return -1;
  struct stat st{};
  if (fstat(f, &st) != 0 || !S_ISREG(st.st_mode)) {
    ::close(f);
    return -1;
  }
  size = (int64_t)st.st_size;
  return f;
#endif
}

void closeFile(int f) {
#ifdef _WIN32
  _close(f);
#else
  ::close(f);
#endif
}

/// Peer address as text (v4 dotted, v6 hex; v4-mapped shows as ::ffff:…).
std::string peerAddress(const sockaddr_storage& peer) {
  char buf[INET6_ADDRSTRLEN] = {0};
  if (peer.ss_family == AF_INET6) {
    inet_ntop(AF_INET6, &((const sockaddr_in6*)&peer)->sin6_addr, buf,
              sizeof(buf));
  } else {
    inet_ntop(AF_INET, &((const sockaddr_in*)&peer)->sin_addr, buf,
              sizeof(buf));
  }
  return buf;
}

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
/// [draining] is checked between slices: an idle connection (no request
/// bytes yet) is closed once a drain begins, after one slice of grace so a
/// request already on its way still lands.
bool readHead(Fd fd, std::string& buf, int64_t idleMs,
              const std::atomic<bool>* draining = nullptr) {
  char tmp[8192];
  static constexpr int64_t kSliceMs = 200;
  int64_t left = idleMs;
  while (buf.size() < kMaxHeadBytes) {
    if (buf.find("\r\n\r\n") != std::string::npos) return true;
    const bool drainingNow = draining != nullptr && draining->load();
    const int64_t slice = drainingNow ? std::min(left, kSliceMs) : left;
    const ssize_t n = recvWait(fd, tmp, sizeof(tmp), slice);
    if (n > 0) {
      buf.append(tmp, (size_t)n);
      continue;
    }
    if (n == 0) return false;  // EOF.
    if (!drainingNow) return false;  // Idle timeout or error.
    // Draining and still nothing: this connection is idle. Close it.
    if (buf.empty()) return false;
    left -= slice;
    if (left <= 0) return false;
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

ParsedHead parseRequestHead(const std::string& raw, size_t headEnd) {
  return parseHead(raw, headEnd);
}

class NullEmitter final : public Emitter {
 public:
  void emitHead(int64_t, Method, const std::string&, const std::string&,
                const std::string&, const std::vector<Header>&, int64_t, bool,
                bool, const std::string&,
                const std::vector<RouteParam>&) override {}
  void emitBodyData(int64_t, uint8_t* payload, size_t) override {
    // Ownership transferred in: free on drop so the unbound window leaks
    // nothing. (Unreachable in practice — see nextEmitter.)
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

Emitter* ServerInstance::nextEmitter() {
  static NullEmitter null;
  std::lock_guard<std::mutex> lk(emitterMutex_);
  if (emitters_.empty()) return &null;
  if (emitters_.size() == 1) return emitters_[0];
  return emitters_[emitterRr_.fetch_add(1, std::memory_order_relaxed) %
                   emitters_.size()];
}

void ServerInstance::broadcastEvent(ServerEventKind kind, int64_t requestId,
                                    const std::string& message) {
  std::vector<Emitter*> sinks;
  {
    std::lock_guard<std::mutex> lk(emitterMutex_);
    sinks = emitters_;
  }
  for (Emitter* e : sinks) e->emitEvent(kind, requestId, message);
}

void ServerInstance::configure(const ServerConfig& config) {
  std::unique_lock lk(configMutex_);
  config_ = config;
}

StatusResult ServerInstance::registerRoute(Method method,
                                           const std::string& customMethod,
                                           const std::string& pattern,
                                           int64_t timeoutMs,
                                           bool isWebSocket, bool streamBody,
                                           int64_t maxBodyBytes,
                                           const std::string& wsProtocols) {
  std::unique_lock lk(configMutex_);
  RouteEntry e{method, customMethod, pattern, timeoutMs, isWebSocket,
               streamBody, maxBodyBytes};
  for (size_t b = 0; b <= wsProtocols.size(); ) {
    size_t c = wsProtocols.find(',', b);
    if (c == std::string::npos) c = wsProtocols.size();
    const std::string_view tok =
        trimSv(std::string_view(wsProtocols).substr(b, c - b));
    if (!tok.empty()) e.wsProtocols.emplace_back(tok);
    b = c + 1;
  }
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

#ifdef NITRO_SERVER_TLS
// Builds the server SSL_CTX from the configured identity. PEM strings win
// over file paths; cert and key may come from different sources as long as
// they match. Returns a TlsError with the OpenSSL reason on any failure.
StatusResult ServerInstance::setupTls(const ServerConfig& cfg) {
  auto fail = [](const std::string& what) -> StatusResult {
    char buf[256] = {0};
    const unsigned long e = ERR_get_error();
    if (e) ERR_error_string_n(e, buf, sizeof(buf));
    return {ErrorKind::TlsError,
            e ? what + ": " + buf : what, 0};
  };
  SSL_CTX* ctx = SSL_CTX_new(TLS_server_method());
  if (!ctx) return fail("SSL_CTX_new failed");
  SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
  SSL_CTX_set_mode(ctx, SSL_MODE_ENABLE_PARTIAL_WRITE |
                            SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER |
                            SSL_MODE_AUTO_RETRY);
  SSL_CTX_set_options(ctx, SSL_OP_NO_RENEGOTIATION | SSL_OP_NO_TICKET);
  // No TLS 1.3 session tickets: they are the main reason a post-handshake
  // SSL_read would need to write, and this server keeps no session cache.
  SSL_CTX_set_num_tickets(ctx, 0);
  SSL_CTX_set_alpn_select_cb(ctx, tlsAlpnSelect, nullptr);

  // Certificate (chain).
  if (!cfg.tlsCertPem.empty()) {
    BIO* bio = BIO_new_mem_buf(cfg.tlsCertPem.data(), (int)cfg.tlsCertPem.size());
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
    while ((ca = PEM_read_bio_X509(bio, nullptr, nullptr, nullptr)) != nullptr) {
      if (SSL_CTX_add0_chain_cert(ctx, ca) != 1) X509_free(ca);
    }
    BIO_free(bio);
  } else if (!cfg.tlsCertFile.empty()) {
    if (SSL_CTX_use_certificate_chain_file(ctx, cfg.tlsCertFile.c_str()) != 1) {
      SSL_CTX_free(ctx);
      return fail("cannot load TLS certificate file");
    }
  } else {
    SSL_CTX_free(ctx);
    return {ErrorKind::TlsError, "TLS requested without a certificate", 0};
  }

  // Private key.
  if (!cfg.tlsKeyPem.empty()) {
    BIO* bio = BIO_new_mem_buf(cfg.tlsKeyPem.data(), (int)cfg.tlsKeyPem.size());
    EVP_PKEY* key = PEM_read_bio_PrivateKey(bio, nullptr, nullptr, nullptr);
    BIO_free(bio);
    if (!key || SSL_CTX_use_PrivateKey(ctx, key) != 1) {
      if (key) EVP_PKEY_free(key);
      SSL_CTX_free(ctx);
      return fail("invalid TLS private key PEM");
    }
    EVP_PKEY_free(key);
  } else if (!cfg.tlsKeyFile.empty()) {
    if (SSL_CTX_use_PrivateKey_file(ctx, cfg.tlsKeyFile.c_str(), SSL_FILETYPE_PEM) != 1) {
      SSL_CTX_free(ctx);
      return fail("cannot load TLS private key file");
    }
  } else {
    SSL_CTX_free(ctx);
    return {ErrorKind::TlsError, "TLS requested without a private key", 0};
  }

  if (SSL_CTX_check_private_key(ctx) != 1) {
    SSL_CTX_free(ctx);
    return {ErrorKind::TlsError, "TLS certificate and private key do not match",
            0};
  }
  if (sslCtx_) SSL_CTX_free((SSL_CTX*)sslCtx_);
  sslCtx_ = ctx;
  return {};
}

// Drives SSL_accept on a non-blocking socket, polling for the direction it
// wants until the handshake completes or [timeoutMs] elapses.
bool ServerInstance::tlsHandshake(int fd, void* sslv, int64_t timeoutMs) {
  SSL* ssl = (SSL*)sslv;
  const int64_t budget = timeoutMs > 0 ? timeoutMs : 10000;
  const auto deadline = std::chrono::steady_clock::now() +
                        std::chrono::milliseconds(budget);
  while (running_.load()) {
    ERR_clear_error();
    const int r = SSL_accept(ssl);
    if (r == 1) return true;
    const int e = SSL_get_error(ssl, r);
    short want;
    if (e == SSL_ERROR_WANT_READ) {
      want = POLLIN;
    } else if (e == SSL_ERROR_WANT_WRITE) {
      want = POLLOUT;
    } else {
      return false;
    }
    const int64_t left = (int64_t)std::chrono::duration_cast<std::chrono::milliseconds>(
        deadline - std::chrono::steady_clock::now()).count();
    if (left <= 0) return false;
    if (pollFd((Fd)fd, want, (int)std::min<int64_t>(left, INT32_MAX)) <= 0) {
      return false;
    }
  }
  return false;
}
#endif  // NITRO_SERVER_TLS

StatusResult ServerInstance::start() {
  ensureSockets();
  ServerConfig cfg;
  {
    std::shared_lock lk(configMutex_);
    cfg = config_;
  }
  draining_.store(false);
  if (running_.exchange(true)) {
    // start() on a running server: report the live port, not the config.
    return {ErrorKind::AlreadyRunning, "server is already running",
            boundPort_.load()};
  }
  if (cfg.tlsRequested) {
#ifndef NITRO_SERVER_TLS
    running_.store(false);
    return {ErrorKind::TlsError,
            "TLS is not enabled in this build (supportsTls() == false); "
            "pass an empty RawTlsConfig for plain HTTP, or rebuild with "
            "OpenSSL available to cmake",
            0};
#else
    const StatusResult tls = setupTls(cfg);
    if (tls.kind != ErrorKind::None) {
      running_.store(false);
      return tls;
    }
#endif
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
  // The accept loop polls, so a drain can sweep the backlog before the
  // listener closes and stop() never waits on a blocked accept.
  setNonBlocking(fd, true);
  listenFd_ = (int)fd;
  {
    Fd r, w;
    if (makeWake(r, w)) acceptWake_ = Wake{(int)r, (int)w};
  }

  // A worker is pinned to its connection for the whole handler wait, so
  // fewer workers than live keep-alive connections means connections cycle
  // through the queue between workers (measured: a 14 ms p99 at 32
  // connections on 16 workers). The pool therefore auto-scales: it starts
  // at one thread per core and grows on demand up to the cap, retiring
  // idle threads above the floor so a quiet server holds few threads.
  // ponytail: thread-per-connection caps out around a few hundred live
  // connections; a poller-driven reactor is the upgrade path.
  const unsigned cores = std::thread::hardware_concurrency();
  const unsigned effectiveCores = cores == 0 ? 8u : cores;
  const unsigned cap = cfg.workerThreads > 0 ? (unsigned)cfg.workerThreads
                                             : std::max(64u, effectiveCores * 4);
  {
    auto self = shared_from_this();
    std::lock_guard<std::mutex> lk(acceptMutex_);
    acceptThread_ = std::thread([self]() { self->acceptLoop(); });
    std::lock_guard<std::mutex> qlk(queueMutex_);
    workerCap_ = cap;
    workerFloor_ = std::min(cap, effectiveCores);
    while (workerCount_ < workerFloor_) {
      if (!spawnWorkerLocked()) break;  // Out of fds: run with fewer.
    }
  }
  broadcastEvent(ServerEventKind::Started, 0,
                 "listening on port " + std::to_string(boundPort_.load()) +
                     " with " + std::to_string(workerFloor_) + " workers (cap " +
                     std::to_string(cap) + ")");
  return {ErrorKind::None, "", boundPort_.load()};
}

void ServerInstance::stop() {
  if (!running_.exchange(false)) return;
  // The accept loop owns the listener fd until it exits: wake it, join it,
  // then close. Closing first would race its poll/accept on the fd.
  joinAcceptLoop();
  if (listenFd_ != -1) {
    closeFd((Fd)listenFd_);
    listenFd_ = -1;
  }
  if (acceptWake_.r != -1) {
    closeFd((Fd)acceptWake_.r);
    closeFd((Fd)acceptWake_.w);
    acceptWake_ = Wake{};
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
  {
    // Workers are detached: poke every parked one, then wait for the count
    // to reach zero (each retires itself and closes its own wake pipe).
    std::unique_lock<std::mutex> lk(queueMutex_);
    for (const Wake& w : workerWakes_) poke((Fd)w.w);
    queueCv_.notify_all();
    workersGoneCv_.wait(lk, [&] { return workerCount_ == 0; });
    for (int fd : queue_) closeFd((Fd)fd);
    queue_.clear();
  }
  {
    std::lock_guard<std::mutex> lk(activeMutex_);
    peerOf_.clear();
    perPeer_.clear();
    liveConnections_.store(0);
  }
  boundPort_.store(0);
  draining_.store(false);
#ifdef NITRO_SERVER_TLS
  // Workers have exited: no SSL object references the context any more.
  if (sslCtx_) {
    SSL_CTX_free((SSL_CTX*)sslCtx_);
    sslCtx_ = nullptr;
  }
#endif
  broadcastEvent(ServerEventKind::Stopped, 0, "stopped");
}

void ServerInstance::beginDrain() {
  if (!running_.load() || draining_.exchange(true)) return;
  // The accept loop notices `draining_`, sweeps whatever the kernel already
  // queued (those clients completed a handshake and would otherwise be
  // reset), then exits; only then does the listener close. Workers keep
  // serving, and every answer from now on says `Connection: close`.
  joinAcceptLoop();
  if (listenFd_ != -1) {
    closeFd((Fd)listenFd_);
    listenFd_ = -1;
  }
}

void ServerInstance::joinAcceptLoop() {
  std::lock_guard<std::mutex> lk(acceptMutex_);
  if (!acceptThread_.joinable()) return;
  if (acceptWake_.w != -1) poke((Fd)acceptWake_.w);
  acceptThread_.join();
}

int64_t ServerInstance::inFlightRequests() { return (int64_t)pending_.size(); }

void ServerInstance::respondFile(int64_t requestId, int64_t status,
                                 const std::vector<Header>& headers,
                                 const std::string& path, int64_t offset,
                                 int64_t length) {
  auto req = pending_.find(requestId);
  if (!req) return;  // Unknown or already reaped: no-op by design.
  int64_t size = -1;
  int file = openFileReadOnly(path, size);
  if (file < 0 || offset < 0 || offset > size) {
    if (file >= 0) closeFile(file);
    static const char kMsg[] = "not found";
    respond(requestId, 404, {{"Content-Type", "text/plain"}},
            (const uint8_t*)kMsg, sizeof(kMsg) - 1);
    return;
  }
  const int64_t remaining =
      length < 0 ? size - offset : std::min<int64_t>(length, size - offset);
  std::string head;
  int wakeFd = -1;
  {
    std::lock_guard<std::mutex> lk(req->mutex);
    if (req->answered) {  // The timeout path won: late answer drops.
      closeFile(file);
      return;
    }
    req->answered = true;
    req->status = status;
    head = buildHead(status, headers, false, remaining, req->keepAlive,
                     req->keepAliveSecs);
    if (req->isHead || remaining == 0) {
      closeFile(file);
      file = -1;
    } else {
      req->fileFd = file;
      req->fileOffset = offset;
      req->fileRemaining = remaining;
    }
    req->writing = true;
    wakeFd = req->wakeFd;
  }
  const bool headOnly = file < 0;
  writeNow(req, (const uint8_t*)head.data(), head.size(), nullptr, 0, nullptr,
           0, headOnly);
  // The worker sends the file body: always wake it for that.
  if (!headOnly) poke((Fd)wakeFd);
}

// ── Direct-write answer path ────────────────────────────────────────────────

void ServerInstance::writeNow(const std::shared_ptr<PendingRequest>& req,
                              const uint8_t* a, size_t an, const uint8_t* b,
                              size_t bn, const uint8_t* c, size_t cn,
                              bool completes) {
#ifdef NITRO_SERVER_TLS
  if (g_tls.get((int)req->fd)) {
    // TLS: the worker owns the SSL object. Hand the whole answer to it via
    // the tail and poke it; the Dart thread never calls SSL_write (an SSL
    // object cannot be used from two threads at once).
    int wakeFd;
    {
      std::lock_guard<std::mutex> lk(req->mutex);
      req->writing = false;
      wakeFd = req->wakeFd;
      const uint8_t* src[3] = {a, b, c};
      const size_t slen[3] = {an, bn, cn};
      for (int i = 0; i < 3; i++) {
        if (slen[i] > 0) req->tail.insert(req->tail.end(), src[i], src[i] + slen[i]);
      }
      if (completes && req->streamStarted) req->streamDone = true;
      req->cv.notify_one();
    }
    poke((Fd)wakeFd);
    return;
  }
#endif
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
  int64_t maxQueued, maxConn, maxPerIp;
  {
    std::shared_lock lk(configMutex_);
    maxQueued = config_.backlog > 0 ? config_.backlog : 128;
    maxConn = config_.maxConnections;
    maxPerIp = config_.maxConnectionsPerIp;
  }
  // Accepts everything the kernel holds right now. Returns false when the
  // listener is gone.
  auto sweep = [&]() -> bool {
    while (true) {
      sockaddr_storage peer{};
      socklen_t len = sizeof(peer);
      Fd fd = accept((Fd)listenFd_, (sockaddr*)&peer, &len);
      if (fd == kBadFd) return wouldBlock();
      setNoSigPipe(fd);
      setNonBlocking(fd, true);
      // Limits at the door: cheaper than any later stage, and the only
      // place a per-peer cap can be enforced before a worker is spent.
      {
        std::lock_guard<std::mutex> lk(activeMutex_);
        const std::string ip = peerAddress(peer);
        const auto it = perPeer_.find(ip);
        const int64_t fromPeer = it == perPeer_.end() ? 0 : it->second;
        if ((maxConn > 0 && liveConnections_.load() >= maxConn) ||
            (maxPerIp > 0 && fromPeer >= maxPerIp)) {
          closeFd(fd);
          continue;
        }
        perPeer_[ip] = fromPeer + 1;
        peerOf_[(int)fd] = ip;
        liveConnections_++;
      }
      {
        std::lock_guard<std::mutex> lk(queueMutex_);
        if ((int64_t)queue_.size() >= maxQueued) {
          // Refuse fast: an accept loop that outruns its workers must shed
          // load at the door, not queue it until every client times out.
          closeFd(fd);
          std::lock_guard<std::mutex> alk(activeMutex_);
          releasePeerLocked((int)fd);
          continue;
        }
        queue_.push_back((int)fd);
        // More waiting than idle hands: grow the pool (bounded by the cap).
        if (queue_.size() > idleWorkers_ && workerCount_ < workerCap_) {
          spawnWorkerLocked();
        }
      }
      queueCv_.notify_one();
    }
  };
  const Fd lfd = (Fd)listenFd_;
  pollfd fds[2] = {{lfd, POLLIN, 0}, {(Fd)acceptWake_.r, POLLIN, 0}};
  while (running_.load() && !draining_.load()) {
    // stop() and beginDrain() poke the wake pipe; the bounded timeout is
    // only a backstop.
    fds[0].revents = fds[1].revents = 0;
    if (::poll(fds, 2, 100) <= 0) continue;
    if (fds[1].revents != 0) drainWake((Fd)acceptWake_.r);
    if (fds[0].revents != 0 && !sweep()) break;
  }
  if (running_.load() && draining_.load()) sweep();  // Nothing queued is lost.
}

bool ServerInstance::spawnWorkerLocked() {
  Fd r, w;
  if (!makeWake(r, w)) return false;
  const Wake wake{(int)r, (int)w};
  workerWakes_.push_back(wake);
  workerCount_++;
  auto self = shared_from_this();
  std::thread([self, wake]() { self->workerLoop(wake); }).detach();
  return true;
}

void ServerInstance::workerLoop(Wake wake) {
  static constexpr auto kIdleRetire = std::chrono::seconds(10);
  while (true) {
    int fd = -1;
    {
      std::unique_lock<std::mutex> lk(queueMutex_);
      idleWorkers_++;
      queueCv_.wait_for(lk, kIdleRetire,
                        [&] { return !queue_.empty() || !running_.load(); });
      idleWorkers_--;
      if (queue_.empty()) {
        // Stopped, or idle past the retire window while above the floor:
        // leave the pool. Otherwise keep waiting (floor threads never go).
        if (running_.load() && workerCount_ <= workerFloor_) continue;
        workerWakes_.erase(
            std::remove_if(workerWakes_.begin(), workerWakes_.end(),
                           [&](const Wake& x) { return x.r == wake.r; }),
            workerWakes_.end());
        closeWake((Fd)wake.r);
        closeWake((Fd)wake.w);
        workerCount_--;
        if (workerCount_ == 0) workersGoneCv_.notify_all();
        return;
      }
      fd = queue_.back();
      queue_.pop_back();
    }
    handleConnection(fd, wake);
  }
}

size_t ServerInstance::workersForTesting() {
  std::lock_guard<std::mutex> lk(queueMutex_);
  return workerCount_;
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

void ServerInstance::emitTerminalError(Emitter* emitter, int64_t requestId,
                                        const std::string& message,
                                        ErrorKind kind) {
  uint8_t* payload = nullptr;
  if (!message.empty()) {
    payload = (uint8_t*)std::malloc(message.size());
    if (payload) memcpy(payload, message.data(), message.size());
  }
  if (payload) pending_.trackPayload(requestId, payload);
  emitter->emitBodyError(requestId, payload, message.size(), kind);
  emitter->emitBodyEnd(requestId);
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
    // A yield IS the under-provisioning signal: live keep-alive connections
    // outnumber workers, and in keep-alive mode no accept will come along
    // to notice. Grow here too (this worker is about to be idle: +1).
    if (queue_.size() > idleWorkers_ + 1 && workerCount_ < workerCap_) {
      spawnWorkerLocked();
    }
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

#ifdef NITRO_SERVER_TLS
  // TLS terminates on this worker: create the session, register it so the
  // I/O funnels use SSL, and complete the handshake before any request is
  // read. All SSL calls for this fd stay on this thread.
  SSL* ssl = nullptr;
  if (sslCtx_) {
    ssl = SSL_new((SSL_CTX*)sslCtx_);
    if (ssl) {
      SSL_set_fd(ssl, fd);
      g_tls.add(fd, ssl);
      // Blocking socket for TLS. OpenSSL then resolves WANT_READ/WANT_WRITE
      // direction changes internally (a TLS 1.3 post-handshake write during a
      // read, say), instead of my code polling one direction and stalling —
      // which some clients (BoringSSL) trigger and others do not. A short
      // recv timeout keeps the caller's poll-driven deadline authoritative;
      // the send timeout bounds a peer that stops reading.
      setNonBlocking(fd, false);
      const int64_t sndMs = cfg.writeTimeoutMs > 0 ? cfg.writeTimeoutMs : 30000;
      timeval rcv{0, 200 * 1000};
      timeval snd{(long)(sndMs / 1000), (int)((sndMs % 1000) * 1000)};
      setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, (const char*)&rcv, sizeof(rcv));
      setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, (const char*)&snd, sizeof(snd));
    }
    const int64_t hsMs = cfg.headerTimeoutMs > 0 ? cfg.headerTimeoutMs
                                                  : (cfg.keepAliveTimeoutMs > 0
                                                         ? cfg.keepAliveTimeoutMs
                                                         : 5000);
    if (!ssl || !tlsHandshake(fd, ssl, hsMs)) {
      if (ssl) {
        g_tls.take(fd);
        SSL_free(ssl);
      }
      {
        std::lock_guard<std::mutex> lk(activeMutex_);
        activeFds_.erase(fd);
        releasePeerLocked(fd);
      }
      closeFd(sock);
      inFlight_--;
      return;
    }
  }
#endif

  std::string carry;
  int64_t served = 0;
  while (running_.load()) {
    // A TLS session's SSL object lives on this worker; yielding the fd to
    // another worker would re-handshake it. TLS connections stay pinned.
    // Starvation guard: when this fd has no buffered bytes but other
    // connections already wait, blocking in the keep-alive read pins a
    // worker while work starves. Yielding parks the fd at the queue front
    // (fair order) and frees this worker; the fd cycles back, unclosed.
    // Skipped when `carry` holds bytes: those were already consumed from
    // the socket, so only serveOne can see them — yielding would orphan
    // them into a hang.
    bool pinned = false;
#ifdef NITRO_SERVER_TLS
    pinned = ssl != nullptr;
#endif
    if (!pinned && carry.empty() && yieldToQueued(fd)) {
      inFlight_--;
      return;
    }
    if (!serveOne(fd, wake, carry, served, cfg)) break;
    if (cfg.keepAliveTimeoutMs <= 0) break;
    if (cfg.maxRequestsPerConn > 0 && served >= cfg.maxRequestsPerConn) break;
  }

#ifdef NITRO_SERVER_TLS
  if (ssl) {
    SSL_shutdown(ssl);
    g_tls.take(fd);
    SSL_free(ssl);
  }
#endif
  {
    std::lock_guard<std::mutex> lk(activeMutex_);
    activeFds_.erase(fd);
    releasePeerLocked(fd);
  }
  closeFd(sock);
  inFlight_--;
}

void ServerInstance::releasePeerLocked(int fd) {
  const auto it = peerOf_.find(fd);
  if (it == peerOf_.end()) return;
  const auto count = perPeer_.find(it->second);
  if (count != perPeer_.end() && --count->second <= 0) perPeer_.erase(count);
  peerOf_.erase(it);
  liveConnections_--;
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
        // say: one-shot answers always, streams after their terminal. A
        // queued file (its head just flushed) is not done — the worker's
        // sendFile pass sends the body and marks it done.
        if ((!req->streamStarted || req->streamDone) && req->fileFd < 0) {
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

bool ServerInstance::sendFile(int fd, const std::shared_ptr<PendingRequest>& req,
                              int64_t stallMs) {
  int file;
  int64_t off, remaining;
  {
    std::lock_guard<std::mutex> lk(req->mutex);
    file = req->fileFd;
    off = req->fileOffset;
    remaining = req->fileRemaining;
    req->flushing = true;
  }
  bool ok = true;
#if defined(NITRO_SERVER_TLS) && !defined(_WIN32)
  const bool tls = g_tls.get((int)fd) != nullptr;
#endif
  while (remaining > 0 && ok) {
#if defined(NITRO_SERVER_TLS) && !defined(_WIN32)
    if (tls) {
      // sendfile cannot traverse the TLS record layer: read a block and
      // SSL_write it (via sendAll -> writeSome -> the TLS route).
      static thread_local std::vector<uint8_t> tbuf(64 * 1024);
      const size_t want = (size_t)std::min<int64_t>((int64_t)tbuf.size(), remaining);
      const ssize_t n = pread(file, tbuf.data(), want, (off_t)off);
      if (n <= 0) {
        ok = false;
        break;
      }
      if (!sendAll(fd, tbuf.data(), (size_t)n, stallMs)) {
        ok = false;
        break;
      }
      off += n;
      remaining -= n;
      continue;
    }
#endif
#if defined(__APPLE__)
    off_t len = (off_t)remaining;
    const int r = ::sendfile(file, fd, (off_t)off, &len, nullptr, 0);
    off += len;
    remaining -= len;
    if (r < 0 && errno == EINTR) continue;
    if (r < 0 && !wouldBlock()) {
      ok = false;
    } else if (remaining > 0 && (r < 0 || len == 0)) {
      if (pollFd((Fd)fd, POLLOUT, (int)std::min<int64_t>(stallMs, INT32_MAX)) <= 0) ok = false;
    }
#elif defined(__linux__)
    off_t o = (off_t)off;
    const ssize_t n = ::sendfile(fd, file, &o, (size_t)std::min<int64_t>(remaining, 1 << 20));
    if (n > 0) {
      off += n;
      remaining -= n;
    } else if (n < 0 && (errno == EINTR)) {
      continue;
    } else if (n < 0 && wouldBlock()) {
      if (pollFd((Fd)fd, POLLOUT, (int)std::min<int64_t>(stallMs, INT32_MAX)) <= 0) ok = false;
    } else {
      ok = false;
    }
#else
    // No sendfile: read a block and send it.
    static thread_local std::vector<uint8_t> buf(64 * 1024);
    const size_t want = (size_t)std::min<int64_t>((int64_t)buf.size(), remaining);
#ifdef _WIN32
    if (_lseeki64(file, off, SEEK_SET) < 0) { ok = false; break; }
    const int n = _read(file, buf.data(), (unsigned)want);
#else
    const ssize_t n = pread(file, buf.data(), want, (off_t)off);
#endif
    if (n <= 0) { ok = false; break; }
    if (!sendAll(fd, buf.data(), (size_t)n, stallMs)) { ok = false; break; }
    off += n;
    remaining -= n;
#endif
  }
  closeFile(file);
  {
    std::lock_guard<std::mutex> lk(req->mutex);
    req->fileFd = -1;
    req->fileRemaining = 0;
    req->flushing = false;
    if (!ok) req->failed = true;
    req->done = true;
    req->doneAt = std::chrono::steady_clock::now();
  }
  return ok;
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
  const int64_t writeMs = cfg.writeTimeoutMs > 0 ? cfg.writeTimeoutMs : 30000;
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
    bool hasFile = false;
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
      } else if (req->fileFd >= 0 && !req->writing) {
        hasFile = true;
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
      if (!finished && !ownedByWorker && !hasTail && !hasFile && pendingInput) {
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
      sendAll(fd, (const uint8_t*)head.data(), head.size(), writeMs);
      return false;
    }
    if (hasTail) {
      if (!flushTail(fd, req, writeMs)) {
        emitter->emitEvent(ServerEventKind::ClientError, requestId,
                           "write timed out or failed");
      }
      continue;
    }
    if (hasFile) {
      if (!sendFile(fd, req, writeMs)) {
        emitter->emitEvent(ServerEventKind::ClientError, requestId,
                           "write timed out or failed");
      }
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
  // A fresh connection gets the header deadline (slow-loris guard); a
  // keep-alive connection between requests gets the idle timeout.
  const int64_t headMs =
      served == 0 && cfg.headerTimeoutMs > 0 ? cfg.headerTimeoutMs : idleMs;
  if (!readHead(sock, carry, headMs, &draining_)) return false;  // EOF, idle.
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
    return serveUpgrade(fd, wake, carry, bodyStart, head, m, cfg, path,
                        query);
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
  const int64_t maxBody =
      m.route.maxBodyBytes >= 0 ? m.route.maxBodyBytes : cfg.maxBodyBytes;
  const int64_t requestId = nextRequestId();
  auto req = pending_.create(requestId);
  // Deal this request to one runner: every message it produces — error
  // chunks included — goes to the sink chosen here.
  Emitter* emitter = nextEmitter();
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
  req->keepAlive = keepPeer && cfg.keepAliveTimeoutMs > 0 && underBudget &&
                   !draining_.load();
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
  if (!chunked && contentLength > maxBody) {
    emitTerminalError(emitter, requestId, "request body exceeds maxBodyBytes",
                      ErrorKind::RequestTooLarge);
    answerDirectly(fd, head.method, 413, "content too large");
    pending_.erase(requestId);
    return false;
  }

  // Small bodies (the common POST) are read in full first, so Dart gets one
  // chunk then one COMPLETE head — two port messages and a single head
  // decode instead of head + chunk + end marker.
  const bool inlineBody = hasBody && !chunked &&
                          (size_t)contentLength <= kInlineBodyBytes &&
                          !m.route.streamBody;
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
        if (carry.size() > (size_t)maxBody + 1024) {
          tooLarge = true;  // Over the cap before the size line said so.
          return false;
        }
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
      if (chunkSize < 0 || received + chunkSize > maxBody) {
        tooLarge = true;
        break;
      }
      if (!fill((size_t)chunkSize + 2)) break;
      emitBytes((const uint8_t*)carry.data() + pos, (size_t)chunkSize);
      received += chunkSize;
      pos += (size_t)chunkSize + 2;  // Skip trailing CRLF.
    }
    if (!done && !tooLarge) {
      emitTerminalError(emitter, requestId, "truncated chunked body",
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
        emitTerminalError(emitter, requestId, "truncated body", ErrorKind::BadRequest);
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
      emitTerminalError(emitter, requestId, "truncated body", ErrorKind::BadRequest);
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
    emitTerminalError(emitter, requestId, "request body exceeds maxBodyBytes",
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

// ── WebSocket (RFC 6455, permessage-deflate RFC 7692) ────────────────────

bool ServerInstance::serveUpgrade(int fd, const Wake& wake,
                                  const std::string& carry, size_t bodyStart,
                                  const ParsedHead& head, const MatchResult& m,
                                  const ServerConfig& cfg,
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
  // Subprotocol: the first of the route's list the client offered. An
  // offer with no overlap is refused; no offer at all upgrades unselected.
  std::string protocol;
  if (!m.route.wsProtocols.empty()) {
    if (const Header* ph = findHeader(head.headers, "sec-websocket-protocol")) {
      const std::string_view list(ph->value);
      auto offers = [&](const std::string& want) {
        for (size_t b = 0; b <= list.size();) {
          size_t c = list.find(',', b);
          if (c == std::string_view::npos) c = list.size();
          if (trimSv(list.substr(b, c - b)) == want) return true;
          b = c + 1;
        }
        return false;
      };
      for (const auto& want : m.route.wsProtocols) {
        if (offers(want)) {
          protocol = want;
          break;
        }
      }
      if (protocol.empty()) {
        answerDirectly(fd, head.method, 400, "no acceptable subprotocol");
        return false;
      }
    }
  }
  // permessage-deflate, no context takeover either way: every message is
  // an independent raw-deflate stream, so neither side keeps a window
  // between messages and the Dart side inflates each one on its own.
  const Header* ext = findHeader(head.headers, "sec-websocket-extensions");
  const bool deflate =
      cfg.wsCompression && ext && icontains(ext->value, "permessage-deflate");

  const std::string accept = ws::acceptKey(clientKey);
  std::string shake =
      "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
      "Connection: Upgrade\r\nSec-WebSocket-Accept: " +
      accept + "\r\n";
  if (deflate) {
    shake += "Sec-WebSocket-Extensions: permessage-deflate; "
             "server_no_context_takeover; client_no_context_takeover\r\n";
  }
  if (!protocol.empty()) shake += "Sec-WebSocket-Protocol: " + protocol + "\r\n";
  shake += "\r\n";
  const int64_t writeMs = cfg.writeTimeoutMs > 0 ? cfg.writeTimeoutMs : 30000;
  if (!sendAll(fd, (const uint8_t*)shake.data(), shake.size(), writeMs)) {
    return false;
  }

  const int64_t connectionId = nextRequestId();
  auto conn = std::make_shared<WsConn>();
  conn->fd = fd;
  conn->emitter = nextEmitter();
  conn->wakeFd = wake.w;
  conn->deflate = deflate;
  conn->maxBuffer = cfg.wsMaxBufferBytes > 0 ? cfg.wsMaxBufferBytes : (1 << 20);
  {
    std::lock_guard<std::mutex> lk(wsMutex_);
    ws_[connectionId] = conn;
  }
  // The session opens through normal head dispatch, so Dart sees the
  // handshake's pattern, params, query and headers like any request.
  conn->emitter->emitHead(connectionId, head.method, head.customMethod, path,
                          query, head.headers, 0, false, true,
                          m.route.pattern, m.params);
  wsLoop(fd, wake, conn, connectionId, cfg.maxBodyBytes, writeMs);
  {
    std::lock_guard<std::mutex> lk(wsMutex_);
    ws_.erase(connectionId);
  }
  pending_.dropPayloads(connectionId);
  return false;  // Upgraded connections never serve HTTP again.
}

int64_t ServerInstance::wsQueueWrite(const std::shared_ptr<WsConn>& conn,
                                     const uint8_t* data, size_t n) {
  std::lock_guard<std::mutex> lk(conn->mutex);
  if (conn->closing || conn->failed || conn->overflow) return -1;
  size_t off = 0;
  if (conn->outbound.empty() && !conn->flushing) {
    // Nothing ahead of these bytes: write what the socket takes right now.
    while (off < n) {
      const uint8_t* bufs[1] = {data + off};
      const size_t lens[1] = {n - off};
      const ssize_t r = writeSome((Fd)conn->fd, bufs, lens, 1);
      if (r < 0) {
        conn->failed = true;
        poke((Fd)conn->wakeFd);
        return -1;
      }
      if (r == 0) break;
      off += (size_t)r;
    }
  }
  if (off < n) {
    if ((int64_t)(conn->outbound.size() + (n - off)) > conn->maxBuffer) {
      conn->overflow = true;  // The loop closes with 1009.
      poke((Fd)conn->wakeFd);
      return -1;
    }
    conn->outbound.append((const char*)data + off, n - off);
    poke((Fd)conn->wakeFd);  // The loop arms POLLOUT and flushes.
  }
  return (int64_t)conn->outbound.size();
}

bool ServerInstance::wsFlush(const std::shared_ptr<WsConn>& conn) {
  std::string chunk;
  {
    std::lock_guard<std::mutex> lk(conn->mutex);
    if (conn->outbound.empty()) return true;
    chunk.swap(conn->outbound);
    conn->flushing = true;
  }
  size_t off = 0;
  bool ok = true;
  while (off < chunk.size()) {
    const uint8_t* bufs[1] = {(const uint8_t*)chunk.data() + off};
    const size_t lens[1] = {chunk.size() - off};
    const ssize_t r = writeSome((Fd)conn->fd, bufs, lens, 1);
    if (r < 0) {
      ok = false;
      break;
    }
    if (r == 0) break;
    off += (size_t)r;
  }
  std::lock_guard<std::mutex> lk(conn->mutex);
  conn->flushing = false;
  if (!ok) {
    conn->failed = true;
    return false;
  }
  // The unsent remainder goes back in front of whatever was queued since.
  if (off < chunk.size()) conn->outbound.insert(0, chunk, off, std::string::npos);
  return true;
}

void ServerInstance::emitWs(Emitter* emitter, int64_t connectionId,
                            int opcode, const uint8_t* data, size_t n,
                            int code) {
  uint8_t* payload = nullptr;
  if (n > 0) {
    payload = (uint8_t*)std::malloc(n);
    if (payload == nullptr) return;  // OOM: drop, the loop still reaps.
    memcpy(payload, data, n);
  }
  pending_.trackPayload(connectionId, payload);
  emitter->emitWsMessage(connectionId, payload, n, opcode, code);
}

int64_t ServerInstance::wsSend(int64_t connectionId, const uint8_t* payload,
                               size_t n, bool binary, bool compressed) {
  std::shared_ptr<WsConn> conn;
  {
    std::lock_guard<std::mutex> lk(wsMutex_);
    auto it = ws_.find(connectionId);
    if (it == ws_.end()) return -1;  // Unknown or reaped: no-op by design.
    conn = it->second;
  }
  std::vector<uint8_t> frame;
  frame.reserve(n + 10);
  ws::encodeFrame(binary ? ws::kBinary : ws::kText,
                  payload == nullptr ? (const uint8_t*)"" : payload, n, true,
                  frame);
  if (compressed && conn->deflate) frame[0] |= 0x40;  // RSV1
  return wsQueueWrite(conn, frame.data(), frame.size());
}

void ServerInstance::wsClose(int64_t connectionId, int code) {
  std::shared_ptr<WsConn> conn;
  {
    std::lock_guard<std::mutex> lk(wsMutex_);
    auto it = ws_.find(connectionId);
    if (it == ws_.end()) return;  // Unknown or reaped: no-op by design.
    conn = it->second;
    ws_.erase(it);
  }
  uint8_t payload[2] = {(uint8_t)((code >> 8) & 0xff), (uint8_t)(code & 0xff)};
  std::vector<uint8_t> frame;
  ws::encodeFrame(ws::kClose, payload, 2, true, frame);
  wsQueueWrite(conn, frame.data(), frame.size());
  {
    std::lock_guard<std::mutex> lk(conn->mutex);
    conn->closing = true;
  }
  // The loop flushes what it can and shuts the socket down: never wait
  // for a peer's echo here, this is the Dart thread.
  poke((Fd)conn->wakeFd);
}

void ServerInstance::wsLoop(int fd, const Wake& wake,
                            const std::shared_ptr<WsConn>& conn,
                            int64_t connectionId, int64_t maxMessageBytes,
                            int64_t writeTimeoutMs) {
  const Fd sock = (Fd)fd;
  std::vector<uint8_t> msg;
  int msgOpcode = -1;
  bool msgCompressed = false;
  int closeCode = 1006;  // Abnormal closure unless the peer says otherwise.
  bool peerClosed = false;
  bool failed = false;

  auto sendControl = [&](int opcode, const uint8_t* p, size_t n) {
    std::vector<uint8_t> frame;
    ws::encodeFrame(opcode, p == nullptr ? (const uint8_t*)"" : p, n, true,
                    frame);
    wsQueueWrite(conn, frame.data(), frame.size());
  };
  auto protocolError = [&](int code) {
    uint8_t p[2] = {(uint8_t)((code >> 8) & 0xff), (uint8_t)(code & 0xff)};
    sendControl(ws::kClose, p, 2);
    closeCode = code;  // Dart sees what the peer already holds.
    failed = true;
  };

  std::vector<uint8_t> net;
  net.reserve(8192);
  uint8_t tmp[16384];
  bool stalled = false;
  std::chrono::steady_clock::time_point stalledSince{};

  while (!failed && !peerClosed) {
    // ── 1. Every complete frame in the buffer ─────────────────────────
    while (!failed && !peerClosed && net.size() >= 2) {
      const uint8_t b0 = net[0];
      const int opcode = b0 & 0x0f;
      size_t need = 2;
      const uint8_t marker = net[1] & 0x7f;
      if (marker == 126) {
        need = 4;
      } else if (marker == 127) {
        need = 10;
      }
      if (net[1] & 0x80) need += 4;
      if (net.size() < need) break;
      ws::FrameHeader h;
      if (!ws::parseHeader(net.data(), need, h, conn->deflate)) {
        protocolError(1002);
        break;
      }
      // Clients MUST mask (RFC 6455 §5.3).
      if (!h.masked) {
        protocolError(1002);
        break;
      }
      if (!ws::isControl(opcode) && h.length > (uint64_t)maxMessageBytes) {
        protocolError(1009);
        break;
      }
      const size_t frameLen = h.headerSize + (size_t)h.length;
      if (net.size() < frameLen) break;  // The rest is still in flight.
      uint8_t* payload = net.data() + h.headerSize;
      for (size_t i = 0; i < h.length; i++) payload[i] ^= h.mask[i % 4];

      if (ws::isControl(h.opcode)) {
        if (h.opcode == ws::kPing) {
          sendControl(ws::kPong, payload, (size_t)h.length);
        } else if (h.opcode == ws::kClose) {
          closeCode = h.length >= 2 ? (((int)payload[0] << 8) | payload[1])
                                    : 1000;
          // Echo the close (RFC 6455 §5.5.1) and leave.
          sendControl(ws::kClose, payload, (size_t)h.length);
          peerClosed = true;
        }
        // Pongs are ignored.
      } else if (h.opcode == ws::kContinuation) {
        if (msgOpcode < 0) {
          protocolError(1002);
          break;
        }
        msg.insert(msg.end(), payload, payload + h.length);
      } else {
        if (msgOpcode >= 0) {
          protocolError(1002);  // New message before the previous FIN.
          break;
        }
        msgOpcode = h.opcode;
        msgCompressed = h.rsv1;
        msg.assign(payload, payload + h.length);
      }
      if (!ws::isControl(h.opcode)) {
        if ((int64_t)msg.size() > maxMessageBytes) {
          protocolError(1009);
          break;
        }
        if (h.fin) {
          // Compressed text is validated after inflating, on the Dart side.
          if (msgOpcode == ws::kText && !msgCompressed &&
              !ws::validUtf8(msg.data(), msg.size())) {
            protocolError(1007);
            break;
          }
          emitWs(conn->emitter, connectionId, msgOpcode, msg.data(),
                 msg.size(), msgCompressed ? 1 : 0);
          msg.clear();
          msgOpcode = -1;
          msgCompressed = false;
        }
      }
      net.erase(net.begin(), net.begin() + (ptrdiff_t)frameLen);
    }
    if (failed || peerClosed) break;

    // ── 2. Queued sends, local close, overflow ────────────────────────
    bool wantWrite, closing, overflow, writeFailed;
    {
      std::lock_guard<std::mutex> lk(conn->mutex);
      wantWrite = !conn->outbound.empty();
      closing = conn->closing;
      overflow = conn->overflow;
      writeFailed = conn->failed;
    }
    if (writeFailed) {
      failed = true;
      break;
    }
    if (overflow) {
      // Drop the backlog the peer never drained; the close frame is small
      // enough to leave directly.
      {
        std::lock_guard<std::mutex> lk(conn->mutex);
        conn->outbound.clear();
        conn->overflow = false;
      }
      protocolError(1009);
      break;
    }
    if (wantWrite) {
      if (!wsFlush(conn)) {
        failed = true;
        break;
      }
      std::lock_guard<std::mutex> lk(conn->mutex);
      wantWrite = !conn->outbound.empty();
    }
    if (closing) {
      closeCode = 1000;
      peerClosed = true;  // Local close: the frame went out (best effort).
      break;
    }
    if (wantWrite) {
      if (!stalled) {
        stalled = true;
        stalledSince = std::chrono::steady_clock::now();
      } else if (msSince(stalledSince) >= writeTimeoutMs) {
        failed = true;  // The peer stopped reading.
        break;
      }
    } else {
      stalled = false;
    }

    // ── 3. Wait for bytes, room to write, or a wake ───────────────────
    bool fdReady = false, wakeReady = false;
    const int timeout =
        wantWrite ? (int)std::min<int64_t>(writeTimeoutMs, INT32_MAX) : -1;
    if (!pollTwo(sock, (Fd)wake.r, timeout, fdReady, wakeReady, wantWrite)) {
      failed = true;
      break;
    }
    if (wakeReady) drainWake((Fd)wake.r);
    if (fdReady) {
      const ssize_t r = recvSome(sock, tmp, sizeof(tmp));
      if (r > 0) {
        net.insert(net.end(), tmp, tmp + r);
      } else if (r == 0 || !wouldBlock()) {
        failed = true;  // EOF or error: the peer (or stop()) went away.
      }
      // r < 0 && EAGAIN: only POLLOUT fired; the flush above handles it.
    }
  }

  // No more sends land after this; push out a queued close frame if the
  // socket takes it, then shut down so the peer sees EOF promptly.
  {
    std::lock_guard<std::mutex> lk(conn->mutex);
    conn->closing = true;
  }
  wsFlush(conn);
  shutdownRdwr(sock);
  // Every exit ends with opcode 8 so Dart reaps deterministically: the peer
  // code on a clean close, the sent code on our protocol errors (the peer
  // already holds the matching frame), 1006 on transport failure.
  emitWs(conn->emitter, connectionId, ws::kClose, nullptr, 0, closeCode);
}

}  // namespace nitroserver
