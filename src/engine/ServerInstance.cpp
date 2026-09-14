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
#else
#include <arpa/inet.h>
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
#endif

constexpr size_t kMaxHeadBytes = 64 * 1024;
// 64 KiB per emit: halves malloc + ackBody FFI crossings vs 32 KiB while
// staying well under maxBodyBytes accounting granularity.
constexpr size_t kBodyEmitBytes = 64 * 1024;

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

/// Reads until a full head is buffered, honouring the per-connection receive
/// timeout (idle deadline between keep-alive requests, header deadline on the
/// first). Surplus bytes after the head stay in [buf] for the body reader and
/// the next pipelined request. Returns false on EOF, timeout or oversize.
bool readHead(Fd fd, std::string& buf) {
  char tmp[4096];
  while (buf.size() < kMaxHeadBytes) {
    if (buf.find("\r\n\r\n") != std::string::npos) return true;
#ifdef _WIN32
    int n = recv(fd, tmp, sizeof(tmp), 0);
#else
    ssize_t n = recv(fd, tmp, sizeof(tmp), 0);
#endif
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
/// The engine speaks plain HTTP/1.1 only, so these never reach routing —
/// serveOne answers 426 directly (see below).
bool isWebSocketUpgrade(const ParsedHead& head) {
  const Header* conn = findHeader(head.headers, "connection");
  const Header* upgrade = findHeader(head.headers, "upgrade");
  if (!conn || !upgrade) return false;
  return icontains(conn->value, "upgrade") &&
         icontains(upgrade->value, "websocket");
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
    // Ownership transferred in: free on drop so the unbound window leaks
    // nothing. (Unreachable in practice — see lockedEmitter.)
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
  std::lock_guard<std::mutex> lk(configMutex_);
  config_ = config;
}

StatusResult ServerInstance::registerRoute(Method method,
                                           const std::string& customMethod,
                                           const std::string& pattern,
                                           int64_t timeoutMs,
                                           bool isWebSocket) {
  std::lock_guard<std::mutex> lk(configMutex_);
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
  std::lock_guard<std::mutex> lk(configMutex_);
  if (!router_.remove(method, customMethod, pattern)) {
    return {ErrorKind::RouteNotFound, "no such route: " + pattern, 0};
  }
  return {};
}

StatusResult ServerInstance::start() {
  ensureSockets();
  ServerConfig cfg;
  {
    std::lock_guard<std::mutex> lk(configMutex_);
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
    // Workers park on Dart's respond, so 1x cores stalls under concurrent
    // slow handlers. 2x cores (min 8) keeps the accept queue draining.
    const unsigned cores = std::thread::hardware_concurrency();
    workers = cores == 0 ? 8 : std::max(8u, cores * 2);
  }
  {
    auto self = shared_from_this();
    std::lock_guard<std::mutex> lk(acceptMutex_);
    acceptThread_ = std::thread([self]() { self->acceptLoop(); });
    for (unsigned i = 0; i < workers; i++) {
      workers_.emplace_back([self]() { self->workerLoop(); });
    }
  }
  lockedEmitter()->emitEvent(ServerEventKind::Started, 0,
                             "listening on port " +
                                 std::to_string(boundPort_.load()) + " with " +
                                 std::to_string(workers) + " workers");
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
  // Wake parked workers with 503, then interrupt idle keep-alive reads.
  // The interrupt is SHUT_RD (not RDWR): a parked worker still has to SEND
  // its 503 after abortAll wakes it, and RDWR would make that send fail with
  // EPIPE so the client sees a reset instead of the 503. SHUT_RD fails the
  // blocked recv fast while leaving the send direction intact; each worker
  // closes its own fd on the way out.
  pending_.abortAll();
  {
    std::lock_guard<std::mutex> lk(activeMutex_);
    for (int fd : activeFds_) shutdownRead((Fd)fd);
  }
  queueCv_.notify_all();
  for (auto& w : workers_) {
    if (w.joinable()) w.join();
  }
  workers_.clear();
  {
    std::lock_guard<std::mutex> lk(queueMutex_);
    for (int fd : queue_) closeFd((Fd)fd);
    queue_.clear();
  }
  boundPort_.store(0);
  lockedEmitter()->emitEvent(ServerEventKind::Stopped, 0, "stopped");
}

void ServerInstance::respond(int64_t requestId, int64_t status,
                             const std::vector<Header>& headers,
                             const uint8_t* body, size_t bodyLen) {
  auto req = pending_.find(requestId);
  if (!req) return;  // Unknown or already reaped: no-op by design.
  std::lock_guard<std::mutex> lk(req->mutex);
  if (req->answered) return;  // The timeout path won: late answer drops.
  req->answered = true;
  req->status = status;
  req->headers = headers;  // Deep copy: bridge memory dies on return.
  // Move the body vector directly when the caller owns it (sendStreamChunk
  // path); for the respond() path the body is a borrowed pointer so we
  // must assign.
  if (body && bodyLen > 0) {
    req->body.assign(body, body + bodyLen);
  } else {
    req->body.clear();
  }
  req->cv.notify_one();
}

void ServerInstance::ackBody(int64_t requestId, int64_t ackedChunks) {
  pending_.ack(requestId, ackedChunks);
}

void ServerInstance::startStream(int64_t requestId, int64_t status,
                                 const std::vector<Header>& headers) {
  auto req = pending_.find(requestId);
  if (!req) return;  // Unknown or already reaped: no-op by design.
  std::lock_guard<std::mutex> lk(req->mutex);
  if (req->answered || req->streamStarted) return;  // Timeout won / duplicate.
  req->answered = true;  // Headers are final; the timeout cannot win now.
  req->status = status;
  req->headers = headers;  // Deep copy: bridge memory dies on return.
  req->streamStarted = true;
  req->cv.notify_one();
}

void ServerInstance::sendStreamChunk(int64_t requestId, const uint8_t* chunk,
                                     size_t n, bool last) {
  auto req = pending_.find(requestId);
  if (!req) return;  // Unknown or already reaped: no-op by design.
  std::vector<uint8_t> copy;
  if (n > 0 && chunk != nullptr) copy.assign(chunk, chunk + n);
  std::lock_guard<std::mutex> lk(req->mutex);
  if (!req->streamStarted || req->streamDone || req->timedOut ||
      req->streamDead) {
    return;
  }
  if (!copy.empty()) req->streamQueue.push_back(std::move(copy));
  if (last) req->streamDone = true;
  req->cv.notify_one();
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
    std::lock_guard<std::mutex> lk(configMutex_);
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

void ServerInstance::workerLoop() {
  while (true) {
    int fd = -1;
    {
      std::unique_lock<std::mutex> lk(queueMutex_);
      queueCv_.wait(lk, [&] { return !queue_.empty() || !running_.load(); });
      if (queue_.empty()) return;  // Stop was requested and nothing is queued.
      fd = queue_.back();
      queue_.pop_back();
    }
    handleConnection(fd);
  }
}

bool ServerInstance::sendAll(int fd, const uint8_t* data, size_t n) {
  size_t sent = 0;
  while (sent < n) {
#ifdef _WIN32
    int r = send((Fd)fd, (const char*)data + sent, (int)(n - sent), 0);
#else
    ssize_t r = send(fd, data + sent, n - sent, MSG_NOSIGNAL);
#endif
    if (r <= 0) return false;
    sent += (size_t)r;
  }
  return true;
}

/// Sends one chunked-body chunk — size line, payload, CRLF — in a single
/// syscall where the platform allows (POSIX writev); small chunks coalesce
/// into one send on Windows, large ones keep the three-send path where the
/// copy would cost more than the syscalls.
bool ServerInstance::sendFrame(int fd, const char* sizeLine, size_t sizeLen,
                               const uint8_t* payload, size_t n) {
#ifdef _WIN32
  static constexpr size_t kCoalesceLimit = 128 * 1024;
  if (sizeLen + n + 2 <= kCoalesceLimit) {
    std::string buf;
    buf.reserve(sizeLen + n + 2);
    buf.append(sizeLine, sizeLen);
    buf.append((const char*)payload, n);
    buf.append("\r\n");
    return sendAll(fd, (const uint8_t*)buf.data(), buf.size());
  }
  return sendAll(fd, (const uint8_t*)sizeLine, sizeLen) &&
         sendAll(fd, payload, n) &&
         sendAll(fd, (const uint8_t*)"\r\n", 2);
#else
  struct iovec iov[3];
  iov[0].iov_base = (void*)sizeLine;
  iov[0].iov_len = sizeLen;
  iov[1].iov_base = (void*)payload;
  iov[1].iov_len = n;
  static const char kCrlf[] = "\r\n";
  iov[2].iov_base = (void*)kCrlf;
  iov[2].iov_len = 2;
  size_t done = 0;
  const size_t total = sizeLen + n + 2;
  int base = 0;
  while (done < total) {
    const ssize_t r = writev(fd, iov + base, 3 - base);
    if (r <= 0) return false;
    done += (size_t)r;
    ssize_t left = r;
    while (base < 3 && left >= (ssize_t)iov[base].iov_len) {
      left -= (ssize_t)iov[base].iov_len;
      base++;
    }
    if (base < 3 && left > 0) {
      iov[base].iov_base = (char*)iov[base].iov_base + left;
      iov[base].iov_len -= (size_t)left;
    }
  }
  return true;
#endif
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
  sendAll(fd, (const uint8_t*)head.data(), head.size());
  if (method != Method::Head && !body.empty())
    sendAll(fd, (const uint8_t*)body.data(), body.size());
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
#ifdef _WIN32
  WSAPOLLFD pfd{};
  pfd.fd = (SOCKET)fd;
  pfd.events = POLLRDNORM | POLLHUP | POLLERR;
  const int r = WSAPoll(&pfd, 1, 0);
  if (r > 0 && (pfd.revents & (POLLRDNORM | POLLHUP | POLLERR)) != 0) {
    return false;
  }
#else
  struct pollfd pfd{};
  pfd.fd = fd;
  pfd.events = POLLIN | POLLHUP | POLLERR;
  const int r = poll(&pfd, 1, 0);
  if (r > 0 && (pfd.revents & (POLLIN | POLLHUP | POLLERR)) != 0) {
    return false;
  }
#endif
  {
    std::lock_guard<std::mutex> lk(queueMutex_);
    if (queue_.empty()) return false;
    queue_.push_front(fd);
  }
  queueCv_.notify_one();
  return true;
}

void ServerInstance::handleConnection(int fd) {
  const Fd sock = (Fd)fd;
  {
    std::lock_guard<std::mutex> lk(activeMutex_);
    activeFds_.insert(fd);
  }
  inFlight_++;

  ServerConfig cfg;
  {
    std::lock_guard<std::mutex> lk(configMutex_);
    cfg = config_;
  }
  // The receive timeout doubles as the keep-alive idle deadline and the
  // first-byte header deadline. Zero disables keep-alive below; the initial
  // read still needs a bound, so floor it at the route default.
  const int64_t idleMs =
      cfg.keepAliveTimeoutMs > 0 ? cfg.keepAliveTimeoutMs : 5000;
#ifdef _WIN32
  DWORD tv = (DWORD)idleMs;
  setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, (const char*)&tv, sizeof(tv));
#else
  struct timeval tv{};
  tv.tv_sec = (time_t)(idleMs / 1000);
  tv.tv_usec = (suseconds_t)((idleMs % 1000) * 1000);
  setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
#endif
  int one = 1;
  setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, (const char*)&one, sizeof(one));

  std::string carry;
  int64_t served = 0;
  while (running_.load()) {
    // Starvation guard: when this fd has no buffered bytes but other
    // connections already wait, blocking in the 5s keep-alive recv pins a
    // worker while work starves — under concurrency every worker ends up
    // parked on an idle connection and nothing progresses until the idle
    // timeouts fire at once. Yielding parks the fd at the queue front
    // (fair order) and frees this worker; the fd cycles back, unclosed.
    // Skipped when `carry` holds bytes: those were already consumed from
    // the socket, so only serveOne can see them — yielding would orphan
    // them into a hang.
    if (carry.empty() && yieldToQueued(fd)) {
      inFlight_--;
      return;
    }
    if (!serveOne(fd, carry, served, cfg)) break;
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

bool ServerInstance::serveOne(int fd, std::string& carry, int64_t& served,
                             const ServerConfig& cfg) {
  const Fd sock = (Fd)fd;
  if (!readHead(sock, carry)) return false;  // EOF, idle timeout, or oversize.
  const size_t headEnd = carry.find("\r\n\r\n");
  size_t bodyStart = headEnd + 4;
  ParsedHead head = parseHead(carry, headEnd);
  if (!head.ok) {
    answerDirectly(fd, Method::Get, 400, "bad request");
    return false;
  }
  const bool keepPeer =
      clientWantsKeepAlive(head) && running_.load();

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
    std::lock_guard<std::mutex> lk(configMutex_);
    m = router_.match(head.method, head.customMethod, path);
  }
  if (!m.matched) {
    // No route at all: a handshake-shaped request is refused honestly
    // (RFC 6455 §4.2.2) instead of a misleading 404. Before routing would
    // be wrong here — there is nothing to route to — so this stays inline.
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
    try {
      contentLength = std::stoll(cl->value);
    } catch (...) {
      contentLength = -1;
    }
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

  emitter->emitHead(requestId, head.method, head.customMethod, path,
                    query, head.headers, chunked ? -1 : contentLength,
                    hasBody, !hasBody, m.route.pattern, m.params);

  // Stream the body. Already-buffered bytes first, then the socket. Anything
  // left in `carry` past the body belongs to the next pipelined request.
  // The sink is loaded once: `lockedEmitter()` takes a mutex, and per-chunk
  // locking showed up on large-upload profiles.
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
        char buf[4096];
#ifdef _WIN32
        int n = recv(sock, buf, sizeof(buf), 0);
#else
        ssize_t n = recv(sock, buf, sizeof(buf), 0);
#endif
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
    char buf[4096];
    while (remaining > 0 && !tooLarge) {
#ifdef _WIN32
      int n = recv(sock, buf, (int)std::min<int64_t>(sizeof(buf), remaining), 0);
#else
      ssize_t n =
          recv(sock, buf, (size_t)std::min<int64_t>(sizeof(buf), remaining), 0);
#endif
      if (n <= 0) break;
      emitBytes((const uint8_t*)buf, (size_t)n);
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
  // Emit body end: for bodyless requests, the head already had bodyComplete=true
  // and Dart dispatched immediately — no end marker needed. For body requests,
  // emit a combined head+complete message instead of a separate end marker:
  // Dart receives it as a second head with bodyComplete=true, merges early
  // chunks, sets complete, and dispatches. This saves one NativePort message
  // and one Dart event-loop turn compared to the old separate end marker.
  if (hasBody) {
    emitter->emitHead(requestId, head.method, head.customMethod, path,
                      query, head.headers, contentLength,
                      true, true, m.route.pattern, m.params);
  }

  // Park until Dart answers or the ROUTE's timeout fires. Per-request mutex:
  // concurrent requests never touch each other here.
  bool expired = false;
  bool stream = false;
  {
    std::unique_lock<std::mutex> lk(req->mutex);
    if (!req->answered) {
      if (req->cv.wait_for(lk, std::chrono::milliseconds(timeoutMs),
                           [&] { return req->answered; })) {
        // Answered while waking: fall through to serialize the answer.
      } else {
        expired = true;
        req->answered = true;
        req->timedOut = true;
        req->status = 408;
        req->headers = {{"Content-Type", "text/plain"}};
        const std::string msg = "handler timeout";
        req->body.assign(msg.begin(), msg.end());
      }
    }
    // Read under the same lock: startStream writes it under this mutex.
    stream = !expired && req->streamStarted;
  }
  if (expired) {
    emitter->emitEvent(ServerEventKind::HandlerTimeout, requestId,
                               "handler exceeded " +
                                   std::to_string(timeoutMs) + "ms");
  }

  // Chunked stream: Dart called startStream before the route timeout, so the
  // deadline only bounded time-to-first-byte. The stream tail owns this
  // request from here (headers, chunks, keep-alive accounting, reaping).
  if (stream) {
    return serveStream(fd, requestId, head.method, req, cfg, served, keepPeer);
  }

  // Only a clean cycle keeps alive: the framing past this point is exact, so
  // whatever `carry` holds is the next request, not debris.
  //
  // The max-requests budget is honored HERE, in the framing — not just in
  // handleConnection's loop break. Answering `Connection: keep-alive` on the
  // last allowed request and then closing anyway tells the client a lie it
  // may wait on; the final response must say `close`. (`served` counts
  // completed requests, so this one is number `served + 1`.)
  const bool underBudget =
      cfg.maxRequestsPerConn <= 0 || served + 1 < cfg.maxRequestsPerConn;
  const bool keepAlive = keepPeer && !expired &&
                         cfg.keepAliveTimeoutMs > 0 && running_.load() &&
                         underBudget;
  std::string head_out = "HTTP/1.1 " + std::to_string(req->status) + " " +
                         reasonPhrase(req->status) + "\r\n";
  for (const auto& h : req->headers) {
    // Allocation-free skip: we are authoritative for framing headers.
    if (iequals(h.name, "content-length")) continue;
    if (iequals(h.name, "connection")) continue;
    head_out += h.name + ": " + h.value + "\r\n";
  }
  head_out += "Content-Length: " + std::to_string(req->body.size()) + "\r\n";
  if (keepAlive) {
    // Round up: a 250 ms deadline must not advertise `timeout=0`.
    head_out += "Connection: keep-alive\r\nKeep-Alive: timeout=" +
                std::to_string((cfg.keepAliveTimeoutMs + 999) / 1000) +
                "\r\n\r\n";
  } else {
    head_out += "Connection: close\r\n\r\n";
  }
  const bool isHead = head.method == Method::Head;
  const bool hasResponseBody = !isHead && !req->body.empty();
  bool sent;
#ifdef _WIN32
  // Small bodies ride in the same send() as the headers: the hello-world case
  // was two syscalls (header ~100 B, body ~12 B). Above 128 KiB the copy
  // costs more than the syscall, so large bodies keep the two-send path.
  static constexpr size_t kCoalesceLimit = 128 * 1024;
  if (hasResponseBody && req->body.size() <= kCoalesceLimit) {
    head_out.append((const char*)req->body.data(), req->body.size());
    sent = sendAll(fd, (const uint8_t*)head_out.data(), head_out.size());
  } else {
    sent = sendAll(fd, (const uint8_t*)head_out.data(), head_out.size());
    if (sent && hasResponseBody)
      sent = sendAll(fd, req->body.data(), req->body.size());
  }
#else
  // POSIX: writev sends headers + body in one syscall with zero copies —
  // strictly better than both the coalesce-copy and the two-send paths.
  if (hasResponseBody) {
    struct iovec iov[2];
    iov[0].iov_base = head_out.data();
    iov[0].iov_len = head_out.size();
    iov[1].iov_base = req->body.data();
    iov[1].iov_len = req->body.size();
    size_t toSend = head_out.size() + req->body.size();
    size_t done = 0;
    sent = true;
    int base = 0;  // first non-empty iov
    while (done < toSend) {
      ssize_t r = writev(fd, iov + base, 2 - base);
      if (r <= 0) {
        sent = false;
        break;
      }
      done += (size_t)r;
      ssize_t left = r;
      while (base < 2 && left >= (ssize_t)iov[base].iov_len) {
        left -= (ssize_t)iov[base].iov_len;
        base++;
      }
      if (base < 2 && left > 0) {
        iov[base].iov_base = (char*)iov[base].iov_base + left;
        iov[base].iov_len -= (size_t)left;
      }
    }
  } else {
    sent = sendAll(fd, (const uint8_t*)head_out.data(), head_out.size());
  }
#endif

  pending_.erase(requestId);
  served++;
  return keepAlive && sent;
}

bool ServerInstance::serveStream(int fd, int64_t requestId, Method method,
                                 const std::shared_ptr<PendingRequest>& req,
                                 const ServerConfig& cfg, int64_t& served,
                                 bool keepPeer) {
  const Fd sock = (Fd)fd;

  // Snapshot headers under lock; the queue protocol owns the rest.
  int64_t status;
  std::vector<Header> headers;
  {
    std::lock_guard<std::mutex> lk(req->mutex);
    status = req->status;
    headers = req->headers;
  }

  // Same budget rule as the one-shot path: the final response must not
  // promise keep-alive on the last allowed request.
  const bool underBudget =
      cfg.maxRequestsPerConn <= 0 || served + 1 < cfg.maxRequestsPerConn;
  const bool keepAlive = keepPeer && cfg.keepAliveTimeoutMs > 0 &&
                         running_.load() && underBudget;
  std::string head_out = "HTTP/1.1 " + std::to_string(status) + " " +
                         reasonPhrase(status) + "\r\n";
  for (const auto& h : headers) {
    // Authoritative framing: user headers never override it.
    if (iequals(h.name, "content-length")) continue;
    if (iequals(h.name, "connection")) continue;
    if (iequals(h.name, "transfer-encoding")) continue;
    head_out += h.name + ": " + h.value + "\r\n";
  }
  head_out += "Transfer-Encoding: chunked\r\n";
  if (keepAlive) {
    head_out += "Connection: keep-alive\r\nKeep-Alive: timeout=" +
                std::to_string(cfg.keepAliveTimeoutMs / 1000) + "\r\n\r\n";
  } else {
    head_out += "Connection: close\r\n\r\n";
  }
  bool sent = sendAll(fd, (const uint8_t*)head_out.data(), head_out.size());

  // HEAD answers headers only: the stream is drained by no-op drops after
  // the reap below, and the connection closes (no resumption mid-stream).
  const bool isHead = method == Method::Head;
  bool done = !sent || isHead;
  bool dead = !sent;
  while (!done && !dead) {
    std::vector<uint8_t> chunk;
    bool terminal = false;
    {
      std::unique_lock<std::mutex> lk(req->mutex);
      req->cv.wait(lk, [&] {
        return !req->streamQueue.empty() || req->streamDone ||
               req->streamDead;
      });
      if (req->streamDead) {
        dead = true;
      } else if (!req->streamQueue.empty()) {
        chunk = std::move(req->streamQueue.front());
        req->streamQueue.pop_front();
      } else if (req->streamDone) {
        terminal = true;
      }
    }
    if (dead) break;
    if (!chunk.empty()) {
      // One syscall per chunk: size line + payload + CRLF ride a single
      // writev (POSIX) instead of three sends. Twenty 8-byte SSE events
      // cost 20 syscalls this way, not 60 — the benchmark's /events case
      // measures exactly this shape.
      char sizeLine[32];
      const int sizeLen =
          snprintf(sizeLine, sizeof(sizeLine), "%zx\r\n", chunk.size());
      if (sizeLen <= 0 || !sendFrame(sock, sizeLine, (size_t)sizeLen,
                                     chunk.data(), chunk.size())) {
        dead = true;
      }
    } else if (terminal) {
      static const char kEnd[] = "0\r\n\r\n";
      if (!sendAll(sock, (const uint8_t*)kEnd, sizeof(kEnd) - 1)) dead = true;
      done = true;
    }
    // Else: spurious wake with an empty queue and no terminal flag — loop
    // re-evaluates the predicate.
  }

  // Mark terminal under lock so late chunks no-op instead of queueing
  // behind a reaped request, then drop the entry like the one-shot path.
  {
    std::lock_guard<std::mutex> lk(req->mutex);
    req->streamQueue.clear();
    req->streamDone = true;
    req->streamDead = true;
  }
  pending_.erase(requestId);
  served++;
  return keepAlive && !dead;
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
