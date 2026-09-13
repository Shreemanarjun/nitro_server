#include "ServerInstance.h"

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cstring>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#pragma comment(lib, "ws2_32.lib")
using socklen_t = int;
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
#endif

namespace nitroserver {
namespace {

#ifdef _WIN32
using Fd = SOCKET;
constexpr Fd kBadFd = INVALID_SOCKET;
int closeFd(Fd fd) { return closesocket(fd); }
void shutdownRdwr(Fd fd) { shutdown(fd, SD_BOTH); }
bool wouldBlock() {
  return WSAGetLastError() == WSAEWOULDBLOCK;
}
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
#else
using Fd = int;
constexpr Fd kBadFd = -1;
int closeFd(Fd fd) { return ::close(fd); }
void shutdownRdwr(Fd fd) { ::shutdown(fd, SHUT_RDWR); }
void ensureSockets() {}
#endif

constexpr size_t kMaxHeadBytes = 64 * 1024;
constexpr size_t kBodyEmitBytes = 32 * 1024;

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

bool readHead(Fd fd, std::string& out) {
  char buf[4096];
  while (out.size() < kMaxHeadBytes) {
#ifdef _WIN32
    int n = recv(fd, buf, sizeof(buf), 0);
#else
    ssize_t n = recv(fd, buf, sizeof(buf), 0);
#endif
    if (n <= 0) return false;
    out.append(buf, (size_t)n);
    if (out.find("\r\n\r\n") != std::string::npos) return true;
  }
  return false;
}

struct ParsedHead {
  Method method = Method::Get;
  std::string customMethod;
  std::string target;
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
  size_t pos = lineEnd + 2;
  while (pos < head.size()) {
    size_t eol = head.find("\r\n", pos);
    if (eol == std::string::npos) break;
    if (eol == pos) break;
    const std::string line = head.substr(pos, eol - pos);
    size_t colon = line.find(':');
    if (colon == std::string::npos) return p;
    p.headers.push_back(
        {trim(line.substr(0, colon)), trim(line.substr(colon + 1))});
    pos = eol + 2;
  }
  p.ok = true;
  return p;
}

const Header* findHeader(const std::vector<Header>& hs, const char* name) {
  const std::string want = lower(name);
  for (const auto& h : hs)
    if (lower(h.name) == want) return &h;
  return nullptr;
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
  {
    std::lock_guard<std::mutex> lk(acceptMutex_);
    auto self = shared_from_this();
    acceptThread_ = std::thread([self]() { self->acceptLoop(); });
  }
  lockedEmitter()->emitEvent(ServerEventKind::Started, 0,
                     "listening on port " + std::to_string(boundPort_.load()));
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
  // Wake every parked connection with 503 so no thread outlives the stop by
  // more than a socket write. Threads hold a shared_ptr to this, so joining
  // is unnecessary and would risk hanging the Dart isolate on a slow handler.
  pending_.abortAll();
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

void ServerInstance::acceptLoop() {
  while (running_.load()) {
    sockaddr_in peer{};
    socklen_t len = sizeof(peer);
    Fd fd = accept((Fd)listenFd_, (sockaddr*)&peer, &len);
    if (fd == kBadFd) {
      if (running_.load())
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
      continue;
    }
    inFlight_++;
    auto self = shared_from_this();
    std::thread([self, fd]() {
      self->handleConnection((int)fd);
      self->inFlight_--;
    }).detach();
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

void ServerInstance::handleConnection(int fd) {
  const Fd sock = (Fd)fd;
  std::string raw;
  if (!readHead(sock, raw)) {
    closeFd(sock);
    return;
  }
  const size_t headEnd = raw.find("\r\n\r\n");
  size_t bodyStart = headEnd + 4;
  ParsedHead head = parseHead(raw, headEnd);
  if (!head.ok) {
    answerDirectly(fd, Method::Get, 400, "bad request");
    closeFd(sock);
    return;
  }

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
    // Drain nothing: close fast. The client already sent (or is sending) the
    // body; RST on close is the standard price of a 404 and keeps the bridge
    // free of bookkeeping for unrouted traffic.
    answerDirectly(fd, head.method, 404, "not found");
    closeFd(sock);
    return;
  }

  const int64_t timeoutMs =
      m.route.timeoutMs >= 0 ? m.route.timeoutMs : cfg.defaultTimeoutMs;
  const int64_t requestId = nextRequestId();
  auto req = pending_.create(requestId);

  // 100-continue handshake before the client sends a body.
  if (const Header* expect = findHeader(head.headers, "expect")) {
    if (lower(expect->value).find("100-continue") != std::string::npos) {
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
    if (lower(te->value).find("chunked") != std::string::npos) chunked = true;
  }
  if (contentLength < 0) {
    answerDirectly(fd, head.method, 400, "bad content-length");
    pending_.erase(requestId);
    closeFd(sock);
    return;
  }
  const bool hasBody = chunked || contentLength > 0;
  if (!chunked && contentLength > cfg.maxBodyBytes) {
    emitTerminalError(requestId, "request body exceeds maxBodyBytes",
                      ErrorKind::RequestTooLarge);
    answerDirectly(fd, head.method, 413, "content too large");
    pending_.erase(requestId);
    closeFd(sock);
    return;
  }

  lockedEmitter()->emitHead(requestId, head.method, head.customMethod, path, query,
                    head.headers, chunked ? -1 : contentLength, hasBody,
                    m.route.pattern, m.params);

  // Stream the body. Already-buffered bytes first, then the socket.
  int64_t remaining = contentLength;
  size_t buffered = raw.size() - bodyStart;
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
      lockedEmitter()->emitBodyData(requestId, payload, take);
      off += take;
    }
  };

  if (chunked) {
    // De-chunk: parse hex sizes out of the buffered + streamed bytes.
    std::string stream = raw.substr(bodyStart);
    size_t pos = 0;
    bool done = false;
    auto fill = [&](size_t need) -> bool {
      while (stream.size() - pos < need) {
        char buf[4096];
#ifdef _WIN32
        int n = recv(sock, buf, sizeof(buf), 0);
#else
        ssize_t n = recv(sock, buf, sizeof(buf), 0);
#endif
        if (n <= 0) return false;
        stream.append(buf, (size_t)n);
        if (stream.size() > (size_t)cfg.maxBodyBytes + 1024) return false;
      }
      return true;
    };
    while (!done) {
      size_t eol = std::string::npos;
      while (true) {
        eol = stream.find("\r\n", pos);
        if (eol != std::string::npos) break;
        if (!fill((stream.size() - pos) + 1)) break;
      }
      if (eol == std::string::npos) break;
      long chunkSize = strtol(stream.c_str() + pos, nullptr, 16);
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
      emitBytes((const uint8_t*)stream.data() + pos, (size_t)chunkSize);
      received += chunkSize;
      pos += (size_t)chunkSize + 2;  // Skip trailing CRLF.
    }
    if (!done && !tooLarge) {
      emitTerminalError(requestId, "truncated chunked body",
                        ErrorKind::BadRequest);
      answerDirectly(fd, head.method, 400, "truncated body");
      pending_.erase(requestId);
      closeFd(sock);
      return;
    }
  } else if (hasBody) {
    if (buffered > 0) {
      const size_t take = (size_t)std::min<int64_t>((int64_t)buffered, remaining);
      emitBytes((const uint8_t*)raw.data() + bodyStart, take);
      remaining -= (int64_t)take;
      received += (int64_t)take;
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
      closeFd(sock);
      return;
    }
  }

  if (tooLarge) {
    emitTerminalError(requestId, "request body exceeds maxBodyBytes",
                      ErrorKind::RequestTooLarge);
    answerDirectly(fd, head.method, 413, "content too large");
    pending_.erase(requestId);
    closeFd(sock);
    return;
  }
  lockedEmitter()->emitBodyEnd(requestId);

  // Park until Dart answers or the ROUTE's timeout fires. Per-request mutex:
  // concurrent connections never touch each other here.
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
                       "handler exceeded " + std::to_string(timeoutMs) + "ms");
  }

  std::string head_out = "HTTP/1.1 " + std::to_string(req->status) + " " +
                         reasonPhrase(req->status) + "\r\n";
  for (const auto& h : req->headers) {
    if (lower(h.name) == "content-length") continue;  // We are authoritative.
    head_out += h.name + ": " + h.value + "\r\n";
  }
  head_out += "Content-Length: " + std::to_string(req->body.size()) +
              "\r\nConnection: close\r\n\r\n";
  sendAll(fd, (const uint8_t*)head_out.data(), head_out.size());
  if (head.method != Method::Head && !req->body.empty())
    sendAll(fd, req->body.data(), req->body.size());

  pending_.erase(requestId);
  closeFd(sock);
}

}  // namespace nitroserver
