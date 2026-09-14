#include "ServerInstance.h"

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cstring>
#include <csignal>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#pragma comment(lib, "ws2_32.lib")
using socklen_t = int;
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
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

std::string lower(std::string s) {
  std::transform(s.begin(), s.end(), s.begin(),
                 [](unsigned char c) { return (char)std::tolower(c); });
  return s;
}

std::string trim(const std::string& s) {
  size_t b = s.find_first_not_of(" \t");
  if (b == std::string::npos) return "";
  size_t e = s.find_last_not_of(" \t");
  return s.substr(b, e - b + 1);
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

struct ParsedHead {
  Method method = Method::Get;
  std::string customMethod;
  std::string target;
  std::string version;
  std::vector<Header> headers;
  bool ok = false;
};

ParsedHead parseHead(const std::string& raw, size_t headEnd) {
  ParsedHead p;
  const std::string head = raw.substr(0, headEnd);
  size_t lineEnd = head.find("\r\n");
  if (lineEnd == std::string::npos) return p;
  const std::string requestLine = head.substr(0, lineEnd);
  size_t sp1 = requestLine.find(' ');
  size_t sp2 = sp1 == std::string::npos
                   ? std::string::npos
                   : requestLine.find(' ', sp1 + 1);
  if (sp1 == std::string::npos || sp2 == std::string::npos) return p;
  p.method = parseMethod(requestLine.substr(0, sp1), p.customMethod);
  p.target = requestLine.substr(sp1 + 1, sp2 - sp1 - 1);
  p.version = trim(requestLine.substr(sp2 + 1));
  // The head slice excludes the terminal \r\n\r\n, so the LAST header line
  // has no line ending — a loop that requires one silently drops it (which
  // used to hide `Connection: close` and a trailing Content-Length).
  size_t pos = lineEnd + 2;
  while (pos <= head.size()) {
    size_t eol = head.find("\r\n", pos);
    std::string line;
    if (eol == std::string::npos) {
      line = head.substr(pos);
      pos = head.size() + 1;
    } else {
      if (eol == pos) break;
      line = head.substr(pos, eol - pos);
      pos = eol + 2;
    }
    if (line.empty()) break;
    size_t colon = line.find(':');
    if (colon == std::string::npos) return p;
    p.headers.push_back(
        {trim(line.substr(0, colon)), trim(line.substr(colon + 1))});
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

}  // namespace

class NullEmitter final : public Emitter {
 public:
  void emitHead(int64_t, Method, const std::string&, const std::string&,
                const std::string&, const std::vector<Header>&, int64_t, bool,
                const std::string&, const std::vector<RouteParam>&) override {}
  void emitBodyData(int64_t, uint8_t* payload, size_t) override {
    // Ownership transferred in: free on drop so the unbound window leaks
    // nothing. (Unreachable in practice — see lockedEmitter.)
    std::free(payload);
  }
  void emitBodyEnd(int64_t) override {}
  void emitBodyError(int64_t, uint8_t* payload, size_t, ErrorKind) override {
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
                                           int64_t timeoutMs) {
  std::lock_guard<std::mutex> lk(configMutex_);
  RouteEntry e{method, customMethod, pattern, timeoutMs};
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

  Fd fd = socket(AF_INET, SOCK_STREAM, 0);
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
  setNoSigPipe(fd);
  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_port = htons((uint16_t)cfg.port);
  if (cfg.host == "0.0.0.0") {
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
  } else {
    if (inet_pton(AF_INET, cfg.host.c_str(), &addr.sin_addr) != 1) {
      closeFd(fd);
      running_.store(false);
      return {ErrorKind::BindFailed, "invalid host: " + cfg.host, 0};
    }
  }
  if (bind(fd, (sockaddr*)&addr, sizeof(addr)) != 0 ||
      listen(fd, (int)(cfg.backlog > 0 ? cfg.backlog : 128)) != 0) {
    closeFd(fd);
    running_.store(false);
    return {ErrorKind::BindFailed,
            "bind/listen failed on " + cfg.host + ":" +
                std::to_string(cfg.port),
            0};
  }
  if (cfg.port == 0) {
    sockaddr_in bound{};
    socklen_t len = sizeof(bound);
    if (getsockname(fd, (sockaddr*)&bound, &len) == 0) {
      boundPort_.store(ntohs(bound.sin_port));
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
  req->body.assign(body ? body : nullptr, body ? body + bodyLen : nullptr);
  req->cv.notify_one();
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
    std::lock_guard<std::mutex> lk(configMutex_);
    maxQueued = config_.backlog > 0 ? config_.backlog : 128;
  }
  while (running_.load()) {
    sockaddr_in peer{};
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

void ServerInstance::answerDirectly(int fd, Method method, int64_t status,
                                    const std::string& body) {
  std::string head = "HTTP/1.1 " + std::to_string(status) + " " +
                     reasonPhrase(status) +
                     "\r\nContent-Type: text/plain\r\nContent-Length: " +
                     std::to_string(body.size()) +
                     "\r\nConnection: close\r\n\r\n";
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
    if (!serveOne(fd, carry, served)) break;
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

bool ServerInstance::serveOne(int fd, std::string& carry, int64_t& served) {
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
  ServerConfig cfg;
  {
    std::lock_guard<std::mutex> lk(configMutex_);
    cfg = config_;
    m = router_.match(head.method, head.customMethod, path);
  }
  if (!m.matched) {
    answerDirectly(fd, head.method, 404, "not found");
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

  lockedEmitter()->emitHead(requestId, head.method, head.customMethod, path,
                            query, head.headers, chunked ? -1 : contentLength,
                            hasBody, m.route.pattern, m.params);

  // Stream the body. Already-buffered bytes first, then the socket. Anything
  // left in `carry` past the body belongs to the next pipelined request.
  // The sink is loaded once: `lockedEmitter()` takes a mutex, and per-chunk
  // locking showed up on large-upload profiles.
  Emitter* emitter = lockedEmitter();
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
        done = true;
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
    carry.erase(0, bodyStart + (size_t)(contentLength - remaining));
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
  lockedEmitter()->emitBodyEnd(requestId);

  // Park until Dart answers or the ROUTE's timeout fires. Per-request mutex:
  // concurrent requests never touch each other here.
  bool expired = false;
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
  }
  if (expired) {
    lockedEmitter()->emitEvent(ServerEventKind::HandlerTimeout, requestId,
                               "handler exceeded " +
                                   std::to_string(timeoutMs) + "ms");
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

}  // namespace nitroserver
