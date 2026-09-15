// ServerInstance tests over real loopback sockets with a recording emitter.
// No Dart involved: a pump thread answers every request the way the Dart
// runner would, so these exercise parse → route → emit → wait → respond →
// serialize end to end.
#include <gtest/gtest.h>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <atomic>
#include <algorithm>
#include <cctype>
#include <cerrno>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <thread>

#include "engine/ServerInstance.h"

#ifdef NITRO_SERVER_TLS
#include <openssl/err.h>
#include <openssl/ssl.h>

#include "tls_test_cert.h"
#endif

using namespace nitroserver;

namespace {

int connectTo(int port) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_port = htons((uint16_t)port);
  inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);
  if (connect(fd, (sockaddr*)&addr, sizeof(addr)) != 0) {
    close(fd);
    return -1;
  }
  return fd;
}

/// Connects over IPv6 loopback. Returns -1 when IPv6 is unavailable, so
/// callers can GTEST_SKIP instead of failing where v6 does not exist.
int connectToV6(int port, const char* host = "::1") {
  int fd = socket(AF_INET6, SOCK_STREAM, 0);
  if (fd < 0) return -1;
  sockaddr_in6 addr{};
  addr.sin6_family = AF_INET6;
  addr.sin6_port = htons((uint16_t)port);
  if (inet_pton(AF_INET6, host, &addr.sin6_addr) != 1) {
    close(fd);
    return -1;
  }
  if (connect(fd, (sockaddr*)&addr, sizeof(addr)) != 0) {
    close(fd);
    return -1;
  }
  return fd;
}

std::string readAll(int fd) {
  std::string out;
  char buf[4096];
  ssize_t n;
  while ((n = recv(fd, buf, sizeof(buf), 0)) > 0) out.append(buf, (size_t)n);
  return out;
}

void sendStr(int fd, const std::string& s) {
  size_t sent = 0;
  while (sent < s.size()) {
    ssize_t n = send(fd, s.data() + sent, s.size() - sent, 0);
    if (n <= 0) break;
    sent += (size_t)n;
  }
}

/// Receives exactly [n] bytes (false on EOF/error). Tests control both ends,
// so blocking is fine.
bool recvAll(int fd, uint8_t* dst, size_t n) {
  size_t got = 0;
  while (got < n) {
    ssize_t r = recv(fd, (char*)dst + got, n - got, 0);
    if (r <= 0) return false;
    got += (size_t)r;
  }
  return true;
}

/// Reads until the end of the HTTP head (`\r\n\r\n`).
std::string readHttpHead(int fd) {
  std::string out;
  char buf[1024];
  while (out.find("\r\n\r\n") == std::string::npos) {
    ssize_t n = recv(fd, buf, sizeof(buf), 0);
    if (n <= 0) break;
    out.append(buf, (size_t)n);
  }
  return out;
}

void sendWsHandshake(int fd, const std::string& path,
                     const std::string& key = "dGhlIHNhbXBsZSBub25jZQ==",
                     const std::string& version = "13") {
  sendStr(fd, "GET " + path + " HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n"
              "Connection: Upgrade\r\nSec-WebSocket-Key: " +
              key + "\r\nSec-WebSocket-Version: " + version + "\r\n\r\n");
}

/// Sends one client frame. Clients MUST mask: pass masked=false only to
/// prove the server drops unmasked frames.
void sendWsFrame(int fd, int opcode, const std::string& payload,
                 bool fin = true, bool masked = true) {
  std::string out;
  out.push_back((char)((fin ? 0x80 : 0x00) | opcode));
  const size_t n = payload.size();
  const uint8_t maskBit = masked ? 0x80 : 0x00;
  if (n < 126) {
    out.push_back((char)(maskBit | n));
  } else if (n <= 0xffff) {
    out.push_back((char)(maskBit | 126));
    out.push_back((char)((n >> 8) & 0xff));
    out.push_back((char)(n & 0xff));
  } else {
    out.push_back((char)(maskBit | 127));
    for (int i = 7; i >= 0; i--) out.push_back((char)((n >> (8 * i)) & 0xff));
  }
  if (masked) {
    const char key[4] = {0x11, 0x22, 0x33, 0x44};
    out.append(key, 4);
    for (size_t i = 0; i < n; i++) out.push_back(payload[i] ^ key[i % 4]);
  } else {
    out.append(payload);
  }
  sendStr(fd, out);
}

/// Reads one server frame into [payload]. Returns the opcode, or -1 on EOF.
int readWsFrame(int fd, std::string& payload, bool* fin = nullptr) {
  uint8_t hdr[2];
  if (!recvAll(fd, hdr, 2)) return -1;
  if (fin != nullptr) *fin = (hdr[0] & 0x80) != 0;
  const int opcode = hdr[0] & 0x0f;
  uint64_t len = hdr[1] & 0x7f;
  if (len == 126) {
    uint8_t ext[2];
    if (!recvAll(fd, ext, 2)) return -1;
    len = ((uint64_t)ext[0] << 8) | ext[1];
  } else if (len == 127) {
    uint8_t ext[8];
    if (!recvAll(fd, ext, 8)) return -1;
    len = 0;
    for (int i = 0; i < 8; i++) len = (len << 8) | ext[i];
  }
  if (hdr[1] & 0x80) {  // Servers never mask; drain defensively.
    uint8_t mask[4];
    if (!recvAll(fd, mask, 4)) return -1;
  }
  payload.assign(len, '\0');
  if (len > 0 && !recvAll(fd, (uint8_t*)payload.data(), (size_t)len)) {
    return -1;
  }
  return opcode;
}

int statusOf(const std::string& response) {
  // "HTTP/1.1 200 OK\r\n..."
  const size_t sp = response.find(' ');
  if (sp == std::string::npos) return -1;
  return std::stoi(response.substr(sp + 1, 3));
}

std::string bodyOf(const std::string& response) {
  const size_t sep = response.find("\r\n\r\n");
  if (sep == std::string::npos) return "";
  return response.substr(sep + 4);
}

/// De-chunks a `Transfer-Encoding: chunked` body; pass bodyOf(response).
std::string dechunk(const std::string& chunked) {
  std::string out;
  size_t pos = 0;
  while (pos < chunked.size()) {
    const size_t eol = chunked.find("\r\n", pos);
    if (eol == std::string::npos) break;
    const long n = strtol(chunked.c_str() + pos, nullptr, 16);
    if (n <= 0) break;
    out.append(chunked.substr(eol + 2, (size_t)n));
    pos = eol + 2 + (size_t)n + 2;
  }
  return out;
}

/// Case-insensitive response header lookup; returns the trimmed value or "".
std::string headerOf(const std::string& response, const std::string& name) {
  const size_t sep = response.find("\r\n\r\n");
  const std::string head =
      sep == std::string::npos ? response : response.substr(0, sep);
  size_t pos = head.find("\r\n");
  if (pos == std::string::npos) return "";
  pos += 2;
  while (pos < head.size()) {
    const size_t eol = head.find("\r\n", pos);
    const std::string line =
        eol == std::string::npos ? head.substr(pos) : head.substr(pos, eol - pos);
    const size_t colon = line.find(':');
    if (colon != std::string::npos) {
      std::string key = line.substr(0, colon);
      std::transform(key.begin(), key.end(), key.begin(),
                     [](unsigned char c) { return (char)std::tolower(c); });
      if (key == name) {
        const std::string value = line.substr(colon + 1);
        const size_t b = value.find_first_not_of(" \t");
        if (b == std::string::npos) return "";
        const size_t e = value.find_last_not_of(" \t");
        return value.substr(b, e - b + 1);
      }
    }
    if (eol == std::string::npos) break;
    pos = eol + 2;
  }
  return "";
}

/// Records dispatch; a pump loop (the test's stand-in for the Dart runner)
/// answers everything queued. Payloads are never acked here — stop()'s
/// abortAll reaps them, exactly like a runner that goes away.
class RecordingEmitter : public Emitter {
 public:
  using Answer = std::function<std::pair<int, std::string>(
      Method, const std::string& path, const std::string& body)>;

  struct Seen {
    int64_t requestId = 0;
    Method method = Method::Get;
    std::string path;
    std::string query;
    std::string routePattern;
    std::vector<RouteParam> params;
    std::vector<Header> headers;
    std::string body;
  };

  /// One decoded WebSocket event.
  struct WsSeen {
    int64_t connectionId = 0;
    int opcode = 0;
    int code = 0;
    std::string payload;
  };

  struct Job {
    int64_t requestId;
    int status;
    std::string body;
  };

  explicit RecordingEmitter(Answer answer) : answer_(std::move(answer)) {}

  void emitHead(int64_t requestId, Method method,
                const std::string& /*customMethod*/, const std::string& path,
                const std::string& query, const std::vector<Header>& headers,
                int64_t, bool hasBody, bool bodyComplete,
                const std::string& routePattern,
                const std::vector<RouteParam>& params) override {
    std::lock_guard<std::mutex> lk(mutex_);
    Seen& s = partial_[requestId];
    s.requestId = requestId;
    s.method = method;
    s.path = path;
    s.query = query;
    s.routePattern = routePattern;
    s.params = params;
    s.headers = headers;
    if (!hasBody || bodyComplete) {
      auto [status, body] = answer_(method, path, s.body);
      jobs_.push_back({requestId, status, body});
      seen_.push_back(s);
      partial_.erase(requestId);
    }
  }

  void emitBodyData(int64_t requestId, uint8_t* payload, size_t n) override {
    std::lock_guard<std::mutex> lk(mutex_);
    // Chunks may precede their head (small bodies are emitted before the
    // completing head; the ports carry no cross-ordering): park them on
    // the partial entry, exactly like the Dart runner's early-chunk buffer.
    partial_[requestId].body.append((const char*)payload, n);
  }

  void emitBodyEnd(int64_t requestId) override {
    std::lock_guard<std::mutex> lk(mutex_);
    auto it = partial_.find(requestId);
    if (it == partial_.end()) return;
    Seen s = it->second;
    partial_.erase(it);
    auto [status, body] = answer_(s.method, s.path, s.body);
    jobs_.push_back({requestId, status, body});
    seen_.push_back(s);
  }

  void emitBodyError(int64_t requestId, uint8_t*,
                     size_t, ErrorKind) override {
    std::lock_guard<std::mutex> lk(mutex_);
    // Terminal for the body: drop the partial so no answer is queued. The
    // engine already answered directly.
    partial_.erase(requestId);
  }

  void emitWsMessage(int64_t connectionId, uint8_t* payload, size_t n,
                     int opcode, int code) override {
    // Payloads stay engine-tracked until stop()'s abortAll reaps them,
    // exactly like unacked body payloads (see Fixture).
    std::lock_guard<std::mutex> lk(mutex_);
    WsSeen s;
    s.connectionId = connectionId;
    s.opcode = opcode;
    s.code = code;
    if (payload != nullptr && n > 0) s.payload.assign((const char*)payload, n);
    wsSeen_.push_back(s);
  }

  void emitEvent(ServerEventKind kind, int64_t requestId,
                 const std::string& message) override {
    std::lock_guard<std::mutex> lk(mutex_);
    events_.push_back({(int64_t)kind, requestId, message});
  }

  bool takeJob(Job& out) {
    std::lock_guard<std::mutex> lk(mutex_);
    if (jobs_.empty()) return false;
    out = jobs_.front();
    jobs_.pop_front();
    return true;
  }

  std::vector<Seen> seen() {
    std::lock_guard<std::mutex> lk(mutex_);
    return seen_;
  }

  std::vector<WsSeen> wsSeen() {
    std::lock_guard<std::mutex> lk(mutex_);
    return wsSeen_;
  }

  std::vector<std::tuple<int64_t, int64_t, std::string>> events() {
    std::lock_guard<std::mutex> lk(mutex_);
    return events_;
  }

 private:
  Answer answer_;
  std::mutex mutex_;
  std::map<int64_t, Seen> partial_;
  std::vector<Seen> seen_;
  std::vector<WsSeen> wsSeen_;
  std::deque<Job> jobs_;
  std::vector<std::tuple<int64_t, int64_t, std::string>> events_;
};

struct Fixture {
  RecordingEmitter emitter;
  std::shared_ptr<ServerInstance> server;
  std::thread pump;
  std::atomic<bool> pumping{true};

  explicit Fixture(RecordingEmitter::Answer answer)
      : emitter(std::move(answer)),
        server(std::make_shared<ServerInstance>()) {
    server->setEmitter(&emitter);
    pump = std::thread([this] {
      while (pumping.load()) {
        RecordingEmitter::Job job{0, 0, ""};
        if (emitter.takeJob(job)) {
          std::vector<uint8_t> bytes(job.body.begin(), job.body.end());
          server->respond(job.requestId, job.status,
                          {{"Content-Type", "text/plain"}}, bytes.data(),
                          bytes.size());
        } else {
          std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
      }
    });
  }

  ~Fixture() {
    pumping.store(false);
    if (pump.joinable()) pump.join();
    server->stop();
  }

  int64_t startOnEphemeral() {
    ServerConfig cfg;
    cfg.port = 0;
    cfg.defaultTimeoutMs = 5000;
    server->configure(cfg);
    StatusResult r = server->start();
    EXPECT_EQ((int64_t)r.kind, (int64_t)ErrorKind::None);
    return server->boundPort();
  }

  bool waitForSeen(size_t n, int64_t timeoutMs = 5000) {
    const auto end =
        std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs);
    while (emitter.seen().size() < n) {
      if (std::chrono::steady_clock::now() > end) return false;
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    return true;
  }

  bool waitForWsSeen(size_t n, int64_t timeoutMs = 5000) {
    const auto end =
        std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs);
    while (emitter.wsSeen().size() < n) {
      if (std::chrono::steady_clock::now() > end) return false;
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    return true;
  }
};

TEST(ServerTest, ServesARegisteredRoute) {
  Fixture f([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "hello");
  });
  EXPECT_TRUE(f.server
                  ->registerRoute(Method::Get, "", "/hello", -1)
                  .kind == ErrorKind::None);
  const int64_t port = f.startOnEphemeral();
  ASSERT_GT(port, 0);

  const int fd = connectTo((int)port);
  ASSERT_GE(fd, 0);
  sendStr(fd, "GET /hello HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
  const std::string res = readAll(fd);
  close(fd);

  EXPECT_EQ(statusOf(res), 200);
  EXPECT_EQ(bodyOf(res), "hello");
  EXPECT_TRUE(f.waitForSeen(1));
  EXPECT_EQ(f.emitter.seen()[0].path, "/hello");
}

TEST(ServerTest, UnroutedPathIs404WithoutDispatch) {
  Fixture f([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "unreachable");
  });
  const int64_t port = f.startOnEphemeral();

  const int fd = connectTo((int)port);
  ASSERT_GE(fd, 0);
  sendStr(fd, "GET /nope HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
  EXPECT_EQ(statusOf(readAll(fd)), 404);
  close(fd);

  std::this_thread::sleep_for(std::chrono::milliseconds(50));
  EXPECT_TRUE(f.emitter.seen().empty());
}

TEST(ServerTest, MalformedRequestIs400) {
  Fixture f([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "unreachable");
  });
  const int64_t port = f.startOnEphemeral();

  const int fd = connectTo((int)port);
  ASSERT_GE(fd, 0);
  sendStr(fd, "GARBAGE\r\n\r\n");
  EXPECT_EQ(statusOf(readAll(fd)), 400);
  close(fd);
}

TEST(ServerTest, ParamsReachTheEmitter) {
  Fixture f([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "ok");
  });
  EXPECT_EQ(f.server->registerRoute(Method::Get, "", "/users/:id", -1).kind,
            ErrorKind::None);
  const int64_t port = f.startOnEphemeral();

  const int fd = connectTo((int)port);
  ASSERT_GE(fd, 0);
  sendStr(fd,
          "GET /users/42?verbose=true HTTP/1.1\r\nHost: x\r\n"
          "Connection: close\r\n\r\n");
  EXPECT_EQ(statusOf(readAll(fd)), 200);
  close(fd);

  ASSERT_TRUE(f.waitForSeen(1));
  const auto seen = f.emitter.seen()[0];
  EXPECT_EQ(seen.routePattern, "/users/:id");
  ASSERT_EQ(seen.params.size(), 1u);
  EXPECT_EQ(seen.params[0].name, "id");
  EXPECT_EQ(seen.params[0].value, "42");
  EXPECT_EQ(seen.query, "verbose=true");
}

// ── Last-header regression ───────────────────────────────────────────────────
// The head slice passed to parseHead ends BEFORE the terminal CRLF of the last
// header line, so that line carries no line ending. A parser that required one
// silently dropped it — which hid a trailing `Connection: close` (keeping dead
// connections alive until the idle timeout) and a trailing `Content-Length`
// (losing the body entirely).

TEST(ServerTest, LastHeaderWithoutTrailingCrlfIsParsed) {
  Fixture f([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "ok");
  });
  EXPECT_EQ(f.server->registerRoute(Method::Get, "", "/hello", -1).kind,
            ErrorKind::None);
  const int64_t port = f.startOnEphemeral();

  const int fd = connectTo((int)port);
  ASSERT_GE(fd, 0);
  sendStr(fd,
          "GET /hello HTTP/1.1\r\nHost: x\r\nConnection: close\r\n"
          "X-Last: yes\r\n\r\n");
  EXPECT_EQ(statusOf(readAll(fd)), 200);
  close(fd);

  ASSERT_TRUE(f.waitForSeen(1));
  const auto seen = f.emitter.seen();
  ASSERT_FALSE(seen.empty());
  bool sawLast = false;
  for (const auto& h : seen[0].headers) {
    if (h.name == "X-Last" && h.value == "yes") sawLast = true;
  }
  EXPECT_TRUE(sawLast);
}

TEST(ServerTest, LastHeaderContentLengthIsParsed) {
  Fixture f([](Method, const std::string&, const std::string& body) {
    return std::make_pair(200, "n=" + std::to_string(body.size()));
  });
  EXPECT_EQ(f.server->registerRoute(Method::Post, "", "/echo", -1).kind,
            ErrorKind::None);
  const int64_t port = f.startOnEphemeral();

  const int fd = connectTo((int)port);
  ASSERT_GE(fd, 0);
  sendStr(fd,
          "POST /echo HTTP/1.1\r\nHost: x\r\nConnection: close\r\n"
          "Content-Length: 5\r\n\r\nhello");
  const std::string res = readAll(fd);
  close(fd);

  EXPECT_EQ(statusOf(res), 200);
  EXPECT_EQ(bodyOf(res), "n=5");
  ASSERT_TRUE(f.waitForSeen(1));
  EXPECT_EQ(f.emitter.seen()[0].body, "hello");
}

TEST(ServerTest, LastHeaderConnectionCloseClosesTheConnection) {
  Fixture f([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "ok");
  });
  EXPECT_EQ(f.server->registerRoute(Method::Get, "", "/hello", -1).kind,
            ErrorKind::None);
  const int64_t port = f.startOnEphemeral();

  const int fd = connectTo((int)port);
  ASSERT_GE(fd, 0);
  sendStr(fd,
          "GET /hello HTTP/1.1\r\nHost: x\r\nX-Last: yes\r\n"
          "Connection: close\r\n\r\n");
  const std::string res = readAll(fd);
  close(fd);

  EXPECT_EQ(statusOf(res), 200);
  EXPECT_EQ(headerOf(res, "connection"), "close");
}

TEST(ServerTest, PostBodyIsStreamedToTheEmitter) {
  Fixture f([](Method, const std::string&, const std::string& body) {
    return std::make_pair(200, "n=" + std::to_string(body.size()));
  });
  EXPECT_EQ(f.server->registerRoute(Method::Post, "", "/echo", -1).kind,
            ErrorKind::None);
  const int64_t port = f.startOnEphemeral();

  const std::string payload(100000, 'a');
  const int fd = connectTo((int)port);
  ASSERT_GE(fd, 0);
  sendStr(fd, "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: " +
                  std::to_string(payload.size()) +
                  "\r\nConnection: close\r\n\r\n" + payload);
  const std::string res = readAll(fd);
  close(fd);

  EXPECT_EQ(statusOf(res), 200);
  EXPECT_EQ(bodyOf(res), "n=100000");
  ASSERT_TRUE(f.waitForSeen(1));
  EXPECT_EQ(f.emitter.seen()[0].body.size(), 100000u);
}

TEST(ServerTest, OversizeBodyIs413WithoutDispatch) {
  Fixture f([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "unreachable");
  });
  ServerConfig cfg;
  cfg.port = 0;
  cfg.maxBodyBytes = 100;
  f.server->configure(cfg);
  EXPECT_EQ(f.server->registerRoute(Method::Post, "", "/up", -1).kind,
            ErrorKind::None);
  ASSERT_EQ((int64_t)f.server->start().kind, (int64_t)ErrorKind::None);
  const int64_t port = f.server->boundPort();

  const std::string payload(1000, 'b');
  const int fd = connectTo((int)port);
  ASSERT_GE(fd, 0);
  sendStr(fd, "POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: " +
                  std::to_string(payload.size()) +
                  "\r\nConnection: close\r\n\r\n" + payload);
  EXPECT_EQ(statusOf(readAll(fd)), 413);
  close(fd);

  std::this_thread::sleep_for(std::chrono::milliseconds(50));
  EXPECT_TRUE(f.emitter.seen().empty());
}

TEST(ServerTest, RouteTimeoutAnswers408AndEmitsEvent) {
  // No pump answers here: create the server without the answering pump by
  // registering a route with a tiny timeout and never responding.
  RecordingEmitter emitter([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "too late");
  });
  auto server = std::make_shared<ServerInstance>();
  server->setEmitter(&emitter);
  EXPECT_EQ(server->registerRoute(Method::Get, "", "/slow", 150).kind,
            ErrorKind::None);
  ServerConfig cfg;
  cfg.port = 0;
  server->configure(cfg);
  ASSERT_EQ((int64_t)server->start().kind, (int64_t)ErrorKind::None);
  const int64_t port = server->boundPort();

  const int fd = connectTo((int)port);
  ASSERT_GE(fd, 0);
  sendStr(fd, "GET /slow HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
  const std::string res = readAll(fd);
  close(fd);

  EXPECT_EQ(statusOf(res), 408);
  // The timeout event arrived.
  bool found = false;
  for (int i = 0; i < 200 && !found; i++) {
    for (const auto& e : emitter.events()) {
      if (std::get<0>(e) == (int64_t)ServerEventKind::HandlerTimeout) {
        found = true;
        break;
      }
    }
    if (!found) std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  EXPECT_TRUE(found);

  // A late respond is a no-op, never a second answer or a crash.
  server->respond(1, 200, {}, nullptr, 0);
  server->stop();
}

TEST(ServerTest, ConcurrentConnectionsDoNotDeadlock) {
  Fixture f([](Method, const std::string& path, const std::string&) {
    return std::make_pair(200, "got " + path);
  });
  EXPECT_EQ(f.server->registerRoute(Method::Get, "", "/u/:id", -1).kind,
            ErrorKind::None);
  const int64_t port = f.startOnEphemeral();

  constexpr int kConns = 32;
  std::vector<std::string> results(kConns);
  std::vector<std::thread> clients;
  for (int i = 0; i < kConns; i++) {
    clients.emplace_back([&, i] {
      const int fd = connectTo((int)port);
      if (fd < 0) {
        results[i] = "CONNECT-FAIL";
        return;
      }
      sendStr(fd, "GET /u/" + std::to_string(i) +
                      " HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
      results[i] = readAll(fd);
      close(fd);
    });
  }
  for (auto& t : clients) t.join();

  for (int i = 0; i < kConns; i++) {
    EXPECT_EQ(statusOf(results[i]), 200) << "connection " << i;
    EXPECT_EQ(bodyOf(results[i]), "got /u/" + std::to_string(i))
        << "connection " << i;
  }
}

TEST(ServerTest, WorkerPoolGrowsForParkedConnections) {
  // No pump: every request parks on its worker for the route timeout, so
  // more parked connections than the floor must make the pool grow.
  RecordingEmitter emitter([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "never");
  });
  auto server = std::make_shared<ServerInstance>();
  server->setEmitter(&emitter);
  EXPECT_EQ(server->registerRoute(Method::Get, "", "/park", 30000).kind,
            ErrorKind::None);
  ServerConfig cfg;
  cfg.port = 0;
  cfg.workerThreads = 48;  // The cap.
  server->configure(cfg);
  ASSERT_EQ((int64_t)server->start().kind, (int64_t)ErrorKind::None);
  const size_t floor = server->workersForTesting();
  EXPECT_GE(floor, 1u);
  EXPECT_LE(floor, 48u);

  constexpr int kConns = 40;
  std::vector<int> fds;
  for (int i = 0; i < kConns; i++) {
    const int fd = connectTo((int)server->boundPort());
    ASSERT_GE(fd, 0);
    sendStr(fd, "GET /park HTTP/1.1\r\nHost: x\r\n\r\n");
    fds.push_back(fd);
  }
  // Every connection dispatched (so every one holds a worker).
  bool all = false;
  for (int i = 0; i < 1000 && !all; i++) {
    all = emitter.seen().size() >= (size_t)kConns;
    if (!all) std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  EXPECT_TRUE(all);
  EXPECT_GE(server->workersForTesting(), (size_t)kConns);
  EXPECT_LE(server->workersForTesting(), 48u);
  server->stop();  // Wakes every parked worker with a 503 and reaps.
  for (int fd : fds) close(fd);
  EXPECT_EQ(server->workersForTesting(), 0u);
}

TEST(ServerTest, RequestsAreDealtRoundRobinAcrossEmitters) {
  // Two runners behind one server: heads alternate, and each request's
  // answer still lands (the pump answers through the shared server).
  RecordingEmitter a([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "a");
  });
  RecordingEmitter b([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "b");
  });
  auto server = std::make_shared<ServerInstance>();
  server->addEmitter(&a);
  server->addEmitter(&b);
  server->addEmitter(&b);  // Duplicate binds are ignored.
  EXPECT_EQ(server->emitterCountForTesting(), 2u);
  EXPECT_EQ(server->registerRoute(Method::Get, "", "/rr", -1).kind,
            ErrorKind::None);
  ServerConfig cfg;
  cfg.port = 0;
  server->configure(cfg);
  ASSERT_EQ((int64_t)server->start().kind, (int64_t)ErrorKind::None);
  std::atomic<bool> pumping{true};
  std::thread pump([&] {
    while (pumping.load()) {
      RecordingEmitter::Job job{0, 0, ""};
      bool got = a.takeJob(job) || b.takeJob(job);
      if (got) {
        std::vector<uint8_t> bytes(job.body.begin(), job.body.end());
        server->respond(job.requestId, job.status, {}, bytes.data(),
                        bytes.size());
      } else {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
      }
    }
  });
  std::string bodies;
  for (int i = 0; i < 6; i++) {
    const int fd = connectTo((int)server->boundPort());
    ASSERT_GE(fd, 0);
    sendStr(fd, "GET /rr HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    bodies += bodyOf(readAll(fd));
    close(fd);
  }
  pumping.store(false);
  pump.join();
  EXPECT_EQ(a.seen().size(), 3u);
  EXPECT_EQ(b.seen().size(), 3u);
  EXPECT_TRUE(bodies == "ababab" || bodies == "bababa") << bodies;
  server->removeEmitter(&a);
  EXPECT_EQ(server->emitterCountForTesting(), 1u);
  server->stop();
}

TEST(ServerTest, MaxConnectionsRefusesAtTheDoor) {
  RecordingEmitter emitter([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "never");
  });
  auto server = std::make_shared<ServerInstance>();
  server->setEmitter(&emitter);
  EXPECT_EQ(server->registerRoute(Method::Get, "", "/park", 30000).kind,
            ErrorKind::None);
  ServerConfig cfg;
  cfg.port = 0;
  cfg.maxConnections = 2;
  server->configure(cfg);
  ASSERT_EQ((int64_t)server->start().kind, (int64_t)ErrorKind::None);
  const int port = (int)server->boundPort();
  // Two parked connections fill the cap; the third is closed unanswered.
  const int a = connectTo(port), b = connectTo(port);
  ASSERT_GE(a, 0);
  ASSERT_GE(b, 0);
  sendStr(a, "GET /park HTTP/1.1\r\nHost: x\r\n\r\n");
  sendStr(b, "GET /park HTTP/1.1\r\nHost: x\r\n\r\n");
  std::this_thread::sleep_for(std::chrono::milliseconds(50));
  const int c = connectTo(port);
  ASSERT_GE(c, 0);
  sendStr(c, "GET /park HTTP/1.1\r\nHost: x\r\n\r\n");
  EXPECT_EQ(readAll(c), "");  // EOF: refused, no bytes.
  close(c);
  std::this_thread::sleep_for(std::chrono::milliseconds(50));
  EXPECT_EQ(emitter.seen().size(), 2u);
  server->stop();
  close(a);
  close(b);
}

TEST(ServerTest, MaxConnectionsPerIpRefusesTheSamePeer) {
  RecordingEmitter emitter([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "never");
  });
  auto server = std::make_shared<ServerInstance>();
  server->setEmitter(&emitter);
  EXPECT_EQ(server->registerRoute(Method::Get, "", "/park", 30000).kind,
            ErrorKind::None);
  ServerConfig cfg;
  cfg.port = 0;
  cfg.maxConnectionsPerIp = 1;
  server->configure(cfg);
  ASSERT_EQ((int64_t)server->start().kind, (int64_t)ErrorKind::None);
  const int port = (int)server->boundPort();
  const int a = connectTo(port);
  ASSERT_GE(a, 0);
  sendStr(a, "GET /park HTTP/1.1\r\nHost: x\r\n\r\n");
  std::this_thread::sleep_for(std::chrono::milliseconds(50));
  const int b = connectTo(port);
  ASSERT_GE(b, 0);
  sendStr(b, "GET /park HTTP/1.1\r\nHost: x\r\n\r\n");
  EXPECT_EQ(readAll(b), "");
  close(b);
  // Closing the first frees the slot for the next.
  close(a);
  std::this_thread::sleep_for(std::chrono::milliseconds(100));
  const int c = connectTo(port);
  ASSERT_GE(c, 0);
  sendStr(c, "GET /park HTTP/1.1\r\nHost: x\r\n\r\n");
  std::this_thread::sleep_for(std::chrono::milliseconds(50));
  EXPECT_EQ(emitter.seen().size(), 2u);
  server->stop();
  close(c);
}

TEST(ServerTest, HeaderTimeoutClosesASilentConnection) {
  Fixture f([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "ok");
  });
  ServerConfig cfg;
  cfg.port = 0;
  cfg.headerTimeoutMs = 100;
  cfg.keepAliveTimeoutMs = 5000;
  f.server->configure(cfg);
  ASSERT_EQ((int64_t)f.server->start().kind, (int64_t)ErrorKind::None);
  const int fd = connectTo((int)f.server->boundPort());
  ASSERT_GE(fd, 0);
  const auto t0 = std::chrono::steady_clock::now();
  EXPECT_EQ(readAll(fd), "");  // Nothing sent: closed at the deadline.
  const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                      std::chrono::steady_clock::now() - t0)
                      .count();
  EXPECT_GE(ms, 80);
  EXPECT_LT(ms, 2000);
  close(fd);
}

TEST(ServerTest, DrainStopsAcceptingAndClosesAfterAnswers) {
  Fixture f([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "ok");
  });
  EXPECT_EQ(f.server->registerRoute(Method::Get, "", "/x", -1).kind,
            ErrorKind::None);
  const int port = (int)f.startOnEphemeral();
  // A keep-alive connection the engine has already accepted keeps being
  // served through the drain, but its next answer says close. (A
  // connection still in the kernel backlog at drain time is reset with the
  // listener — hence the first exchange before draining.)
  const int fd = connectTo(port);
  ASSERT_GE(fd, 0);
  sendStr(fd, "GET /x HTTP/1.1\r\nHost: x\r\n\r\n");
  const std::string first = readHttpHead(fd);
  EXPECT_EQ(statusOf(first), 200);
  EXPECT_EQ(headerOf(first, "connection"), "keep-alive");
  f.server->beginDrain();
  f.server->beginDrain();  // Idempotent.
  sendStr(fd, "GET /x HTTP/1.1\r\nHost: x\r\n\r\n");
  const std::string res = readAll(fd);
  EXPECT_EQ(statusOf(res), 200);
  EXPECT_EQ(headerOf(res, "connection"), "close");
  close(fd);
  EXPECT_EQ(f.server->inFlightRequests(), 0);
  // New connections are refused.
  EXPECT_LT(connectTo(port), 0);
}

TEST(ServerTest, InFlightRequestsCountsParkedAnswers) {
  RecordingEmitter emitter([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "never");
  });
  auto server = std::make_shared<ServerInstance>();
  server->setEmitter(&emitter);
  EXPECT_EQ(server->registerRoute(Method::Get, "", "/park", 30000).kind,
            ErrorKind::None);
  ServerConfig cfg;
  cfg.port = 0;
  server->configure(cfg);
  ASSERT_EQ((int64_t)server->start().kind, (int64_t)ErrorKind::None);
  const int fd = connectTo((int)server->boundPort());
  ASSERT_GE(fd, 0);
  sendStr(fd, "GET /park HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
  bool seen = false;
  for (int i = 0; i < 200 && !seen; i++) {
    seen = !emitter.seen().empty();
    if (!seen) std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  ASSERT_TRUE(seen);
  EXPECT_EQ(server->inFlightRequests(), 1);
  const int64_t id = emitter.seen()[0].requestId;
  const char* body = "done";
  server->respond(id, 200, {}, (const uint8_t*)body, 4);
  EXPECT_EQ(bodyOf(readAll(fd)), "done");
  close(fd);
  for (int i = 0; i < 200 && server->inFlightRequests() != 0; i++) {
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  EXPECT_EQ(server->inFlightRequests(), 0);
  server->stop();
}

/// Writes [bytes] to a fresh temp file and returns its path.
std::string tempFileWith(const std::string& bytes) {
  char name[] = "/tmp/nitro_server_file_XXXXXX";
  const int fd = mkstemp(name);
  EXPECT_GE(fd, 0);
  EXPECT_EQ(write(fd, bytes.data(), bytes.size()), (ssize_t)bytes.size());
  close(fd);
  return name;
}

TEST(ServerTest, RespondFileSendsBytesRangesAndHeadOnly) {
  RecordingEmitter emitter([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "unused");
  });
  auto server = std::make_shared<ServerInstance>();
  server->setEmitter(&emitter);
  EXPECT_EQ(server->registerRoute(Method::All, "", "/f", -1).kind,
            ErrorKind::None);
  ServerConfig cfg;
  cfg.port = 0;
  server->configure(cfg);
  ASSERT_EQ((int64_t)server->start().kind, (int64_t)ErrorKind::None);
  const int port = (int)server->boundPort();
  // Larger than any socket buffer, so the worker's sendfile loop must
  // handle partial writes.
  std::string content(3 * 1024 * 1024, 'x');
  for (size_t i = 0; i < content.size(); i += 4096) content[i] = 'y';
  const std::string path = tempFileWith(content);

  auto ask = [&](const std::string& method, auto answer) -> std::string {
    const size_t before = emitter.seen().size();
    const int fd = connectTo(port);
    EXPECT_GE(fd, 0);
    sendStr(fd, method + " /f HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    int64_t id = 0;
    for (int i = 0; i < 1000 && id == 0; i++) {
      auto seen = emitter.seen();
      if (seen.size() > before) id = seen.back().requestId;
      if (id == 0) std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    EXPECT_NE(id, 0);
    answer(id);
    const std::string res = readAll(fd);
    close(fd);
    return res;
  };

  // Whole file.
  std::string res = ask("GET", [&](int64_t id) {
    server->respondFile(id, 200, {{"Content-Type", "text/plain"}}, path, 0, -1);
  });
  EXPECT_EQ(statusOf(res), 200);
  EXPECT_EQ(headerOf(res, "content-length"), std::to_string(content.size()));
  EXPECT_EQ(bodyOf(res), content);
  // A range.
  res = ask("GET", [&](int64_t id) {
    server->respondFile(id, 206, {}, path, 4096, 10);
  });
  EXPECT_EQ(statusOf(res), 206);
  EXPECT_EQ(bodyOf(res), content.substr(4096, 10));
  // HEAD: length of the body, no bytes.
  res = ask("HEAD", [&](int64_t id) {
    server->respondFile(id, 200, {}, path, 0, -1);
  });
  EXPECT_EQ(headerOf(res, "content-length"), std::to_string(content.size()));
  EXPECT_EQ(bodyOf(res), "");
  // Missing file: 404, the connection still answers.
  res = ask("GET", [&](int64_t id) {
    server->respondFile(id, 200, {}, path + ".missing", 0, -1);
  });
  EXPECT_EQ(statusOf(res), 404);
  // An offset past the end is a 404 too, never a negative length.
  res = ask("GET", [&](int64_t id) {
    server->respondFile(id, 200, {}, path, (int64_t)content.size() + 1, -1);
  });
  EXPECT_EQ(statusOf(res), 404);
  unlink(path.c_str());
  server->stop();
}

TEST(ServerTest, StreamBodyRouteEmitsHeadBeforeChunks) {
  // Order of emits is what the runner relies on to stream: head (not
  // complete), data, end — never the inline chunk-then-complete-head form.
  struct OrderEmitter : RecordingEmitter {
    using RecordingEmitter::RecordingEmitter;
    std::vector<std::string> order;
    std::mutex m;
    void emitHead(int64_t id, Method method, const std::string& c,
                  const std::string& p, const std::string& q,
                  const std::vector<Header>& h, int64_t cl, bool hasBody,
                  bool complete, const std::string& rp,
                  const std::vector<RouteParam>& params) override {
      { std::lock_guard<std::mutex> lk(m); order.push_back(complete ? "head-complete" : "head"); }
      RecordingEmitter::emitHead(id, method, c, p, q, h, cl, hasBody, complete, rp, params);
    }
    void emitBodyData(int64_t id, uint8_t* payload, size_t n) override {
      { std::lock_guard<std::mutex> lk(m); order.push_back("data"); }
      RecordingEmitter::emitBodyData(id, payload, n);
    }
    void emitBodyEnd(int64_t id) override {
      { std::lock_guard<std::mutex> lk(m); order.push_back("end"); }
      RecordingEmitter::emitBodyEnd(id);
    }
  };
  OrderEmitter emitter([](Method, const std::string&, const std::string& body) {
    return std::make_pair(200, "n=" + std::to_string(body.size()));
  });
  auto server = std::make_shared<ServerInstance>();
  server->setEmitter(&emitter);
  EXPECT_EQ(server->registerRoute(Method::Post, "", "/up", -1, false, true).kind,
            ErrorKind::None);
  ServerConfig cfg;
  cfg.port = 0;
  server->configure(cfg);
  ASSERT_EQ((int64_t)server->start().kind, (int64_t)ErrorKind::None);
  std::atomic<bool> pumping{true};
  std::thread pump([&] {
    while (pumping.load()) {
      RecordingEmitter::Job job{0, 0, ""};
      if (emitter.takeJob(job)) {
        std::vector<uint8_t> bytes(job.body.begin(), job.body.end());
        server->respond(job.requestId, job.status, {}, bytes.data(), bytes.size());
      } else {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
      }
    }
  });
  const int fd = connectTo((int)server->boundPort());
  ASSERT_GE(fd, 0);
  const std::string payload(100, 'b');  // Small: inline without streamBody.
  sendStr(fd, "POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n"
              "Connection: close\r\n\r\n" + payload);
  EXPECT_EQ(bodyOf(readAll(fd)), "n=100");
  close(fd);
  pumping.store(false);
  pump.join();
  std::lock_guard<std::mutex> lk(emitter.m);
  EXPECT_EQ(emitter.order, (std::vector<std::string>{"head", "data", "end"}));
  server->stop();
}

TEST(ServerTest, PerRouteBodyCapOverridesTheServerCap) {
  Fixture f([](Method, const std::string&, const std::string& body) {
    return std::make_pair(200, "n=" + std::to_string(body.size()));
  });
  EXPECT_EQ(f.server->registerRoute(Method::Post, "", "/tiny", -1, false, false, 8).kind,
            ErrorKind::None);
  EXPECT_EQ(f.server->registerRoute(Method::Post, "", "/any", -1).kind,
            ErrorKind::None);
  const int port = (int)f.startOnEphemeral();
  auto post = [&](const std::string& path, size_t n) {
    const int fd = connectTo(port);
    EXPECT_GE(fd, 0);
    sendStr(fd, "POST " + path + " HTTP/1.1\r\nHost: x\r\nContent-Length: " +
                    std::to_string(n) + "\r\nConnection: close\r\n\r\n" +
                    std::string(n, 'a'));
    const std::string res = readAll(fd);
    close(fd);
    return res;
  };
  EXPECT_EQ(statusOf(post("/tiny", 100)), 413);
  EXPECT_EQ(bodyOf(post("/tiny", 8)), "n=8");
  EXPECT_EQ(bodyOf(post("/any", 100)), "n=100");
}

TEST(ServerTest, WriteTimeoutDropsAPeerThatStopsReading) {
  Fixture f([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, std::string(8 * 1024 * 1024, 'z'));
  });
  EXPECT_EQ(f.server->registerRoute(Method::Get, "", "/huge", -1).kind,
            ErrorKind::None);
  ServerConfig cfg;
  cfg.port = 0;
  cfg.writeTimeoutMs = 200;
  f.server->configure(cfg);
  ASSERT_EQ((int64_t)f.server->start().kind, (int64_t)ErrorKind::None);
  const int fd = connectTo((int)f.server->boundPort());
  ASSERT_GE(fd, 0);
  sendStr(fd, "GET /huge HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
  // Read nothing; the worker must give up within the deadline (plus slack).
  const auto t0 = std::chrono::steady_clock::now();
  EXPECT_TRUE(f.server->waitForDrainForTesting(5000));
  const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                      std::chrono::steady_clock::now() - t0)
                      .count();
  EXPECT_LT(ms, 4000);
  close(fd);
}

TEST(ServerTest, DrainSweepsTheKernelBacklog) {
  Fixture f([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "served");
  });
  EXPECT_EQ(f.server->registerRoute(Method::Get, "", "/x", -1).kind,
            ErrorKind::None);
  const int port = (int)f.startOnEphemeral();
  // Connect and drain at once: the handshake completed in the kernel but
  // the accept loop may not have taken it yet. It must not be lost.
  const int fd = connectTo(port);
  ASSERT_GE(fd, 0);
  f.server->beginDrain();
  sendStr(fd, "GET /x HTTP/1.1\r\nHost: x\r\n\r\n");
  const std::string res = readAll(fd);
  EXPECT_EQ(statusOf(res), 200);
  EXPECT_EQ(bodyOf(res), "served");
  EXPECT_EQ(headerOf(res, "connection"), "close");
  close(fd);
  EXPECT_LT(connectTo(port), 0);
}

TEST(ServerTest, WsSendQueuesAndOverflowCloses1009) {
  Fixture f([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "unused");
  });
  EXPECT_EQ(f.server->registerRoute(Method::Get, "", "/ws", -1, true).kind,
            ErrorKind::None);
  ServerConfig cfg;
  cfg.port = 0;
  cfg.wsMaxBufferBytes = 64 * 1024;
  f.server->configure(cfg);
  ASSERT_EQ((int64_t)f.server->start().kind, (int64_t)ErrorKind::None);
  const int fd = connectTo((int)f.server->boundPort());
  ASSERT_GE(fd, 0);
  sendWsHandshake(fd, "/ws");
  EXPECT_NE(readHttpHead(fd).find("101"), std::string::npos);
  ASSERT_TRUE(f.waitForSeen(1));
  const int64_t id = f.emitter.seen()[0].requestId;
  // A small send goes straight out: nothing queued.
  const char* hi = "hi";
  EXPECT_EQ(f.server->wsSend(id, (const uint8_t*)hi, 2, false, false), 0);
  std::string payload;
  EXPECT_EQ(readWsFrame(fd, payload), 0x1);
  EXPECT_EQ(payload, "hi");
  // The peer stops reading: sends fill the socket, then the queue, then
  // the cap trips and the session closes with 1009.
  std::vector<uint8_t> block(16 * 1024, 'q');
  int64_t last = 0;
  for (int i = 0; i < 400 && last >= 0; i++) {
    last = f.server->wsSend(id, block.data(), block.size(), true, false);
  }
  EXPECT_EQ(last, -1);
  ASSERT_TRUE(f.waitForWsSeen(1));
  EXPECT_EQ(f.emitter.wsSeen().back().opcode, 8);
  EXPECT_EQ(f.emitter.wsSeen().back().code, 1009);
  close(fd);
}

TEST(ServerTest, WsDeflateNegotiatedAndRsv1Honoured) {
  Fixture f([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "unused");
  });
  EXPECT_EQ(f.server->registerRoute(Method::Get, "", "/ws", -1, true).kind,
            ErrorKind::None);
  const int port = (int)f.startOnEphemeral();
  const int fd = connectTo(port);
  ASSERT_GE(fd, 0);
  sendStr(fd, "GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n"
              "Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
              "Sec-WebSocket-Version: 13\r\n"
              "Sec-WebSocket-Extensions: permessage-deflate; client_max_window_bits\r\n\r\n");
  const std::string head = readHttpHead(fd);
  EXPECT_NE(head.find("101"), std::string::npos);
  EXPECT_EQ(headerOf(head, "sec-websocket-extensions"),
            "permessage-deflate; server_no_context_takeover; "
            "client_no_context_takeover");
  ASSERT_TRUE(f.waitForSeen(1));
  const int64_t id = f.emitter.seen()[0].requestId;
  // An RSV1 data frame is accepted and surfaces with code 1 (compressed).
  std::string frame;
  frame.push_back((char)(0x80 | 0x40 | 0x1));
  frame.push_back((char)(0x80 | 3));
  const char key[4] = {1, 2, 3, 4};
  frame.append(key, 4);
  const char raw[3] = {'\x01', '\x02', '\x03'};
  for (int i = 0; i < 3; i++) frame.push_back((char)(raw[i] ^ key[i]));
  sendStr(fd, frame);
  ASSERT_TRUE(f.waitForWsSeen(1));
  EXPECT_EQ(f.emitter.wsSeen()[0].opcode, 1);
  EXPECT_EQ(f.emitter.wsSeen()[0].code, 1);
  EXPECT_EQ(f.emitter.wsSeen()[0].payload, std::string(raw, 3));
  // A compressed server send carries RSV1 on the wire.
  const uint8_t packed[2] = {0x4b, 0x04};
  EXPECT_EQ(f.server->wsSend(id, packed, 2, false, true), 0);
  uint8_t hdr[2];
  ASSERT_TRUE(recvAll(fd, hdr, 2));
  EXPECT_EQ(hdr[0], 0x80 | 0x40 | 0x1);
  EXPECT_EQ(hdr[1], 2);
  uint8_t body[2];
  ASSERT_TRUE(recvAll(fd, body, 2));
  close(fd);

  // Without the offer, RSV1 is a protocol error (1002).
  const int fd2 = connectTo(port);
  ASSERT_GE(fd2, 0);
  sendWsHandshake(fd2, "/ws");
  EXPECT_EQ(headerOf(readHttpHead(fd2), "sec-websocket-extensions"), "");
  ASSERT_TRUE(f.waitForSeen(2));
  sendStr(fd2, frame);
  std::string closePayload;
  EXPECT_EQ(readWsFrame(fd2, closePayload), 0x8);
  EXPECT_EQ(closePayload.size(), 2u);
  EXPECT_EQ((((int)(uint8_t)closePayload[0]) << 8) | (uint8_t)closePayload[1], 1002);
  close(fd2);
}

TEST(ServerTest, SecondBindOnSamePortFails) {
  Fixture f([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "x");
  });
  const int64_t port = f.startOnEphemeral();

  auto second = std::make_shared<ServerInstance>();
  RecordingEmitter other([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "x");
  });
  second->setEmitter(&other);
  ServerConfig cfg;
  cfg.port = port;
  second->configure(cfg);
  EXPECT_EQ(second->start().kind, ErrorKind::BindFailed);
  // Defensive: if the platform ever allows the rebind (e.g. a future
  // SO_REUSEPORT), stop the stray server so its threads never outlive the
  // stack-owned emitter and never steal accepts from later tests.
  if (second->running()) second->stop();
}

TEST(ServerTest, TlsConfigIsRefused) {
  auto server = std::make_shared<ServerInstance>();
  RecordingEmitter emitter([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "x");
  });
  server->setEmitter(&emitter);
  ServerConfig cfg;
  cfg.port = 0;
  cfg.tlsRequested = true;
  server->configure(cfg);
  StatusResult r = server->start();
  EXPECT_EQ(r.kind, ErrorKind::TlsError);
}

TEST(ServerTest, InvalidHostIsBindFailed) {
  auto server = std::make_shared<ServerInstance>();
  RecordingEmitter emitter([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "x");
  });
  server->setEmitter(&emitter);
  for (const char* bad : {"not a host", "999.1.1.1", "::zzzz"}) {
    ServerConfig cfg;
    cfg.port = 0;
    cfg.host = bad;
    server->configure(cfg);
    EXPECT_EQ(server->start().kind, ErrorKind::BindFailed) << bad;
  }
}

TEST(ServerTest, Ipv6LoopbackServes) {
  if (connectToV6(1) == -1 && errno != ECONNREFUSED) {
    GTEST_SKIP() << "no IPv6 loopback on this machine";
  }
  Fixture f([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "v6");
  });
  EXPECT_EQ(f.server->registerRoute(Method::Get, "", "/hello", -1).kind,
            ErrorKind::None);
  ServerConfig cfg;
  cfg.port = 0;
  cfg.host = "::1";
  f.server->configure(cfg);
  ASSERT_EQ((int64_t)f.server->start().kind, (int64_t)ErrorKind::None);
  const int64_t port = f.server->boundPort();

  const int fd = connectToV6((int)port);
  ASSERT_GE(fd, 0);
  sendStr(fd, "GET /hello HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
  const std::string res = readAll(fd);
  close(fd);

  EXPECT_EQ(statusOf(res), 200);
  EXPECT_EQ(bodyOf(res), "v6");
}

TEST(ServerTest, DualStackWildcardServesIpv4) {
  if (connectToV6(1) == -1 && errno != ECONNREFUSED) {
    GTEST_SKIP() << "no IPv6 on this machine";
  }
  Fixture f([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "dual");
  });
  EXPECT_EQ(f.server->registerRoute(Method::Get, "", "/hello", -1).kind,
            ErrorKind::None);
  ServerConfig cfg;
  cfg.port = 0;
  cfg.host = "::";
  f.server->configure(cfg);
  ASSERT_EQ((int64_t)f.server->start().kind, (int64_t)ErrorKind::None);
  const int64_t port = f.server->boundPort();

  // A v4 client reaches the v6-any socket via mapped addresses: one socket
  // serves both families.
  const int fd = connectTo((int)port);
  ASSERT_GE(fd, 0);
  sendStr(fd, "GET /hello HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
  EXPECT_EQ(statusOf(readAll(fd)), 200);
  close(fd);
}

TEST(ServerTest, WebSocketHandshakeIs426WithoutDispatch) {
  Fixture f([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "unreachable");
  });
  // Even a matching route must not see the handshake.
  EXPECT_EQ(f.server->registerRoute(Method::Get, "", "/chat", -1).kind,
            ErrorKind::None);
  const int64_t port = f.startOnEphemeral();

  const int fd = connectTo((int)port);
  ASSERT_GE(fd, 0);
  sendStr(fd,
          "GET /chat HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n"
          "Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
          "Sec-WebSocket-Version: 13\r\n\r\n");
  const std::string res = readAll(fd);
  close(fd);

  EXPECT_EQ(statusOf(res), 426);
  EXPECT_EQ(headerOf(res, "sec-websocket-version"), "13");
  EXPECT_EQ(headerOf(res, "connection"), "close");
  std::this_thread::sleep_for(std::chrono::milliseconds(50));
  EXPECT_TRUE(f.emitter.seen().empty());
}

void sendWsHandshakeWithProtocols(int fd, const std::string& offered) {
  sendStr(fd, "GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n"
              "Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
              "Sec-WebSocket-Version: 13\r\n" +
              (offered.empty() ? std::string()
                               : "Sec-WebSocket-Protocol: " + offered + "\r\n") +
              "\r\n");
}

TEST(ServerTest, WsSubprotocolPicksTheRoutesFirstOfferedChoice) {
  Fixture f([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "unused");
  });
  EXPECT_EQ(f.server->registerRoute(Method::Get, "", "/ws", -1, true, false, -1,
                                    " graphql-ws ,json,").kind,
            ErrorKind::None);
  const int64_t port = f.startOnEphemeral();
  const int fd = connectTo((int)port);
  ASSERT_GE(fd, 0);
  sendWsHandshakeWithProtocols(fd, "json , graphql-ws");
  const std::string head = readHttpHead(fd);
  EXPECT_EQ(statusOf(head), 101);
  EXPECT_EQ(headerOf(head, "sec-websocket-protocol"), "graphql-ws");
  close(fd);
}

TEST(ServerTest, WsSubprotocolOfferWithoutOverlapIs400) {
  Fixture f([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "unused");
  });
  EXPECT_EQ(f.server->registerRoute(Method::Get, "", "/ws", -1, true, false, -1,
                                    "json").kind,
            ErrorKind::None);
  const int64_t port = f.startOnEphemeral();
  const int fd = connectTo((int)port);
  ASSERT_GE(fd, 0);
  sendWsHandshakeWithProtocols(fd, "xml");
  EXPECT_EQ(statusOf(readHttpHead(fd)), 400);
  close(fd);
}

TEST(ServerTest, WsSubprotocolAbsentOfferUpgradesUnselected) {
  Fixture f([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "unused");
  });
  EXPECT_EQ(f.server->registerRoute(Method::Get, "", "/ws", -1, true, false, -1,
                                    "json").kind,
            ErrorKind::None);
  const int64_t port = f.startOnEphemeral();
  const int fd = connectTo((int)port);
  ASSERT_GE(fd, 0);
  sendWsHandshakeWithProtocols(fd, "");
  const std::string head = readHttpHead(fd);
  EXPECT_EQ(statusOf(head), 101);
  EXPECT_EQ(head.find("ec-WebSocket-Protocol"), std::string::npos);
  close(fd);
}

TEST(ServerTest, WsHandshakeUpgradesWithRfcVector) {
  Fixture f([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "unused");
  });
  EXPECT_EQ(f.server->registerRoute(Method::Get, "", "/ws", -1, true).kind,
            ErrorKind::None);
  const int64_t port = f.startOnEphemeral();

  const int fd = connectTo((int)port);
  ASSERT_GE(fd, 0);
  // RFC 6455 §1.3 test vector: this key MUST yield this accept.
  sendWsHandshake(fd, "/ws");
  const std::string head = readHttpHead(fd);
  EXPECT_EQ(statusOf(head), 101);
  EXPECT_EQ(headerOf(head, "sec-websocket-accept"),
            "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=");
  EXPECT_EQ(headerOf(head, "upgrade"), "websocket");

  // The session opened through normal dispatch, with pattern and path.
  ASSERT_TRUE(f.waitForSeen(1));
  ASSERT_EQ(f.emitter.seen().size(), 1u);
  EXPECT_EQ(f.emitter.seen()[0].routePattern, "/ws");
  EXPECT_EQ(f.emitter.seen()[0].path, "/ws");
  close(fd);
}

TEST(ServerTest, WsUpgradeCarriesParams) {
  Fixture f([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "unused");
  });
  EXPECT_EQ(f.server->registerRoute(Method::Get, "", "/rooms/:room", -1, true)
                .kind,
            ErrorKind::None);
  const int64_t port = f.startOnEphemeral();

  const int fd = connectTo((int)port);
  ASSERT_GE(fd, 0);
  sendWsHandshake(fd, "/rooms/lobby");
  EXPECT_EQ(statusOf(readHttpHead(fd)), 101);
  ASSERT_TRUE(f.waitForSeen(1));
  ASSERT_EQ(f.emitter.seen().size(), 1u);
  EXPECT_EQ(f.emitter.seen()[0].routePattern, "/rooms/:room");
  ASSERT_EQ(f.emitter.seen()[0].params.size(), 1u);
  EXPECT_EQ(f.emitter.seen()[0].params[0].name, "room");
  EXPECT_EQ(f.emitter.seen()[0].params[0].value, "lobby");
  close(fd);
}

TEST(ServerTest, WsTextMessageDecodedAndCloseEchoed) {
  Fixture f([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "unused");
  });
  EXPECT_EQ(f.server->registerRoute(Method::Get, "", "/ws", -1, true).kind,
            ErrorKind::None);
  const int64_t port = f.startOnEphemeral();

  const int fd = connectTo((int)port);
  ASSERT_GE(fd, 0);
  sendWsHandshake(fd, "/ws");
  EXPECT_EQ(statusOf(readHttpHead(fd)), 101);

  sendWsFrame(fd, 0x1, "hello");
  ASSERT_TRUE(f.waitForWsSeen(1));
  ASSERT_EQ(f.emitter.wsSeen().size(), 1u);
  EXPECT_EQ(f.emitter.wsSeen()[0].opcode, 1);
  EXPECT_EQ(f.emitter.wsSeen()[0].payload, "hello");

  // Client close (code 1000): echoed, then the socket closes, then the
  // terminal opcode-8 lands so Dart reaps deterministically.
  sendWsFrame(fd, 0x8, std::string("\x03\xe8", 2));
  std::string payload;
  EXPECT_EQ(readWsFrame(fd, payload), 0x8);
  EXPECT_EQ(payload, std::string("\x03\xe8", 2));
  EXPECT_EQ(readAll(fd), "");
  close(fd);
  ASSERT_TRUE(f.waitForWsSeen(2));
  EXPECT_EQ(f.emitter.wsSeen()[1].opcode, 8);
  EXPECT_EQ(f.emitter.wsSeen()[1].code, 1000);
}

TEST(ServerTest, WsFragmentsReassemble) {
  Fixture f([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "unused");
  });
  EXPECT_EQ(f.server->registerRoute(Method::Get, "", "/ws", -1, true).kind,
            ErrorKind::None);
  const int64_t port = f.startOnEphemeral();

  const int fd = connectTo((int)port);
  ASSERT_GE(fd, 0);
  sendWsHandshake(fd, "/ws");
  EXPECT_EQ(statusOf(readHttpHead(fd)), 101);

  sendWsFrame(fd, 0x1, "hel", false);
  sendWsFrame(fd, 0x0, "lo", true);
  ASSERT_TRUE(f.waitForWsSeen(1));
  ASSERT_EQ(f.emitter.wsSeen().size(), 1u);
  EXPECT_EQ(f.emitter.wsSeen()[0].opcode, 1);
  EXPECT_EQ(f.emitter.wsSeen()[0].payload, "hello");
  close(fd);
}

TEST(ServerTest, WsPingIsPonged) {
  Fixture f([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "unused");
  });
  EXPECT_EQ(f.server->registerRoute(Method::Get, "", "/ws", -1, true).kind,
            ErrorKind::None);
  const int64_t port = f.startOnEphemeral();

  const int fd = connectTo((int)port);
  ASSERT_GE(fd, 0);
  sendWsHandshake(fd, "/ws");
  EXPECT_EQ(statusOf(readHttpHead(fd)), 101);

  sendWsFrame(fd, 0x9, "xyz");
  std::string payload;
  bool fin = false;
  EXPECT_EQ(readWsFrame(fd, payload, &fin), 0xA);
  EXPECT_TRUE(fin);
  EXPECT_EQ(payload, "xyz");
  // Pings never surface as messages.
  std::this_thread::sleep_for(std::chrono::milliseconds(50));
  EXPECT_TRUE(f.emitter.wsSeen().empty());
  close(fd);
}

TEST(ServerTest, WsUnmaskedFrameDropsTheConnection) {
  Fixture f([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "unused");
  });
  EXPECT_EQ(f.server->registerRoute(Method::Get, "", "/ws", -1, true).kind,
            ErrorKind::None);
  const int64_t port = f.startOnEphemeral();

  const int fd = connectTo((int)port);
  ASSERT_GE(fd, 0);
  sendWsHandshake(fd, "/ws");
  EXPECT_EQ(statusOf(readHttpHead(fd)), 101);

  // RFC 6455 §5.3: clients MUST mask. An unmasked frame is a protocol
  // error — a 1002 close frame goes out, the socket closes, and Dart sees
  // the sent code (never a message).
  sendWsFrame(fd, 0x1, "sneaky", true, false);
  std::string payload;
  EXPECT_EQ(readWsFrame(fd, payload), 0x8);
  ASSERT_EQ(payload.size(), 2u);
  EXPECT_EQ(((int)(uint8_t)payload[0] << 8) | (uint8_t)payload[1], 1002);
  EXPECT_EQ(readAll(fd), "");
  close(fd);
  ASSERT_TRUE(f.waitForWsSeen(1));
  ASSERT_EQ(f.emitter.wsSeen().size(), 1u);
  EXPECT_EQ(f.emitter.wsSeen()[0].opcode, 8);
  EXPECT_EQ(f.emitter.wsSeen()[0].code, 1002);
}

TEST(ServerTest, WsServerSendAndClose) {
  Fixture f([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "unused");
  });
  EXPECT_EQ(f.server->registerRoute(Method::Get, "", "/ws", -1, true).kind,
            ErrorKind::None);
  const int64_t port = f.startOnEphemeral();

  const int fd = connectTo((int)port);
  ASSERT_GE(fd, 0);
  sendWsHandshake(fd, "/ws");
  EXPECT_EQ(statusOf(readHttpHead(fd)), 101);
  ASSERT_TRUE(f.waitForSeen(1));
  const int64_t id = f.emitter.seen()[0].requestId;

  // Server-originated frames are never masked.
  const char* hi = "hi";
  f.server->wsSend(id, (const uint8_t*)hi, 2, false, false);
  std::string payload;
  EXPECT_EQ(readWsFrame(fd, payload), 0x1);
  EXPECT_EQ(payload, "hi");

  f.server->wsClose(id, 1000);
  EXPECT_EQ(readWsFrame(fd, payload), 0x8);
  ASSERT_EQ(payload.size(), 2u);
  EXPECT_EQ(((int)(uint8_t)payload[0] << 8) | (uint8_t)payload[1], 1000);
  EXPECT_EQ(readAll(fd), "");
  close(fd);
}

TEST(ServerTest, WsWrongVersionIs426) {
  Fixture f([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "unused");
  });
  EXPECT_EQ(f.server->registerRoute(Method::Get, "", "/ws", -1, true).kind,
            ErrorKind::None);
  const int64_t port = f.startOnEphemeral();

  const int fd = connectTo((int)port);
  ASSERT_GE(fd, 0);
  sendWsHandshake(fd, "/ws", "dGhlIHNhbXBsZSBub25jZQ==", "12");
  const std::string res = readAll(fd);
  close(fd);

  EXPECT_EQ(statusOf(res), 426);
  EXPECT_EQ(headerOf(res, "sec-websocket-version"), "13");
  EXPECT_TRUE(f.emitter.seen().empty());
}

TEST(ServerTest, WsMissingKeyIs400) {
  Fixture f([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "unused");
  });
  EXPECT_EQ(f.server->registerRoute(Method::Get, "", "/ws", -1, true).kind,
            ErrorKind::None);
  const int64_t port = f.startOnEphemeral();

  const int fd = connectTo((int)port);
  ASSERT_GE(fd, 0);
  sendStr(fd,
          "GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n"
          "Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n\r\n");
  EXPECT_EQ(statusOf(readAll(fd)), 400);
  close(fd);
}

TEST(ServerTest, WsPlainGetOnWsRouteIs426) {
  Fixture f([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "unused");
  });
  EXPECT_EQ(f.server->registerRoute(Method::Get, "", "/ws", -1, true).kind,
            ErrorKind::None);
  const int64_t port = f.startOnEphemeral();

  const int fd = connectTo((int)port);
  ASSERT_GE(fd, 0);
  sendStr(fd, "GET /ws HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
  EXPECT_EQ(statusOf(readAll(fd)), 426);
  close(fd);
  EXPECT_TRUE(f.emitter.seen().empty());
}

TEST(ServerTest, StartStopCyclesLeaveNoResidue) {
  // Leak soak: repeated bind/serve/stop cycles with bodies in flight. LSan
  // renders the verdict at exit — any tracked payload, pending entry or
  // thread resource left behind fails the run.
  //
  // Each cycle runs its own answering pump (the stand-in for the Dart
  // runner): without it every request would park until the 30 s route
  // timeout and the test would take 200 × 30 s instead of milliseconds.
  for (int cycle = 0; cycle < 5; cycle++) {
    RecordingEmitter emitter(
        [](Method, const std::string&, const std::string& body) {
          return std::make_pair(200, "n=" + std::to_string(body.size()));
        });
    auto server = std::make_shared<ServerInstance>();
    server->setEmitter(&emitter);
    EXPECT_EQ(server->registerRoute(Method::Post, "", "/soak", -1).kind,
              ErrorKind::None);
    ServerConfig cfg;
    cfg.port = 0;
    server->configure(cfg);
    ASSERT_EQ((int64_t)server->start().kind, (int64_t)ErrorKind::None);
    const int64_t port = server->boundPort();

    std::atomic<bool> pumping{true};
    std::thread pump([&] {
      while (pumping.load()) {
        RecordingEmitter::Job job{0, 0, ""};
        if (emitter.takeJob(job)) {
          std::vector<uint8_t> bytes(job.body.begin(), job.body.end());
          server->respond(job.requestId, job.status,
                          {{"Content-Type", "text/plain"}}, bytes.data(),
                          bytes.size());
        } else {
          std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
      }
    });

    for (int i = 0; i < 40; i++) {
      const int fd = connectTo((int)port);
      ASSERT_GE(fd, 0) << "cycle " << cycle << " conn " << i;
      const std::string payload(8192, (char)('a' + (i % 26)));
      sendStr(fd, "POST /soak HTTP/1.1\r\nHost: x\r\nContent-Length: " +
                      std::to_string(payload.size()) +
                      "\r\nConnection: close\r\n\r\n" + payload);
      const std::string res = readAll(fd);
      close(fd);
      EXPECT_EQ(statusOf(res), 200) << "cycle " << cycle << " conn " << i;
      EXPECT_EQ(bodyOf(res), "n=8192") << "cycle " << cycle << " conn " << i;
    }
    pumping.store(false);
    pump.join();
    server->stop();
    EXPECT_TRUE(server->waitForDrainForTesting(5000));
  }
}

TEST(ServerTest, StopWakesParkedConnections) {
  RecordingEmitter emitter([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "never");
  });
  auto server = std::make_shared<ServerInstance>();
  server->setEmitter(&emitter);
  // Long timeout, never answered: without the stop-wake this would hang the
  // test for the full 30 s.
  EXPECT_EQ(server->registerRoute(Method::Get, "", "/park", 30000).kind,
            ErrorKind::None);
  ServerConfig cfg;
  cfg.port = 0;
  server->configure(cfg);
  ASSERT_EQ((int64_t)server->start().kind, (int64_t)ErrorKind::None);
  const int64_t port = server->boundPort();

  std::string res;
  std::thread client([&] {
    const int fd = connectTo((int)port);
    if (fd < 0) return;
    sendStr(fd, "GET /park HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    res = readAll(fd);
    close(fd);
  });
  // Let the connection park, then stop: the client must get a 503 promptly.
  std::this_thread::sleep_for(std::chrono::milliseconds(100));
  server->stop();
  client.join();
  EXPECT_EQ(statusOf(res), 503);
}

TEST(ServerTest, ChunkedStreamFramesBodyExactly) {
  RecordingEmitter emitter([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "unused");
  });
  auto server = std::make_shared<ServerInstance>();
  server->setEmitter(&emitter);
  EXPECT_EQ(server->registerRoute(Method::Get, "", "/stream", -1).kind,
            ErrorKind::None);
  ServerConfig cfg;
  cfg.port = 0;
  server->configure(cfg);
  ASSERT_EQ((int64_t)server->start().kind, (int64_t)ErrorKind::None);
  const int64_t port = server->boundPort();

  std::string res;
  std::thread client([&] {
    const int fd = connectTo((int)port);
    if (fd < 0) return;
    sendStr(fd, "GET /stream HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    res = readAll(fd);
    close(fd);
  });

  // Wait for dispatch, then stream like the Dart runner would: headers,
  // three chunks (one empty, which must never hit the wire), terminal.
  int64_t id = 0;
  for (int i = 0; i < 1000 && id == 0; i++) {
    auto seen = emitter.seen();
    if (!seen.empty()) id = seen[0].requestId;
    if (id == 0) std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  ASSERT_NE(id, 0);
  server->startStream(id, 200, {{"Content-Type", "text/plain"}});
  const char* a = "a";
  const char* bb = "bb";
  const char* ccc = "ccc";
  server->sendStreamChunk(id, (const uint8_t*)a, 1, false);
  server->sendStreamChunk(id, nullptr, 0, false);  // Skipped, not terminal.
  server->sendStreamChunk(id, (const uint8_t*)bb, 2, false);
  server->sendStreamChunk(id, (const uint8_t*)ccc, 3, true);
  // Late chunk after the terminal: dropped, never a second terminator.
  server->sendStreamChunk(id, (const uint8_t*)a, 1, true);
  client.join();

  EXPECT_EQ(statusOf(res), 200);
  EXPECT_EQ(headerOf(res, "transfer-encoding"), "chunked");
  EXPECT_EQ(dechunk(bodyOf(res)), "abbccc");
  EXPECT_EQ(res,
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n"
            "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
            "1\r\na\r\n2\r\nbb\r\n3\r\nccc\r\n0\r\n\r\n");
  server->stop();
}

TEST(ServerTest, StreamSurvivesForKeepAlive) {
  RecordingEmitter emitter([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, "unused");
  });
  auto server = std::make_shared<ServerInstance>();
  server->setEmitter(&emitter);
  EXPECT_EQ(server->registerRoute(Method::Get, "", "/s", -1).kind,
            ErrorKind::None);
  ServerConfig cfg;
  cfg.port = 0;
  server->configure(cfg);
  ASSERT_EQ((int64_t)server->start().kind, (int64_t)ErrorKind::None);
  const int64_t port = server->boundPort();

  // One keep-alive connection, two sequential streams: exact framing is
  // what lets the second request parse.
  const int fd = connectTo((int)port);
  ASSERT_GE(fd, 0);
  size_t seenCount = 0;
  for (int round = 0; round < 2; round++) {
    sendStr(fd, "GET /s HTTP/1.1\r\nHost: x\r\n\r\n");
    int64_t id = 0;
    for (int i = 0; i < 1000 && id == 0; i++) {
      auto seen = emitter.seen();
      if (seen.size() > seenCount) id = seen.back().requestId;
      if (id == 0) std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    ASSERT_NE(id, 0);
    seenCount = emitter.seen().size();
    server->startStream(id, 200, {});
    std::string payload = "r" + std::to_string(round);
    server->sendStreamChunk(id, (const uint8_t*)payload.data(), payload.size(),
                            true);
    // Read exactly one framed body: headers + chunks through the terminal.
    std::string got;
    char buf[4096];
    while (got.find("0\r\n\r\n") == std::string::npos) {
      ssize_t n = recv(fd, buf, sizeof(buf), 0);
      ASSERT_GT(n, 0);
      got.append(buf, (size_t)n);
    }
    EXPECT_EQ(dechunk(bodyOf(got)), payload);
    EXPECT_EQ(headerOf(got, "connection"), "keep-alive");
  }
  close(fd);
  server->stop();
}

// ── Error paths and edge behaviours ───────────────────────────────────────

RecordingEmitter::Answer echoAnswer() {
  return [](Method, const std::string&, const std::string& body) {
    return std::make_pair(200, "echo:" + body);
  };
}

int64_t startWith(Fixture& f, ServerConfig cfg) {
  cfg.port = 0;
  f.server->configure(cfg);
  EXPECT_EQ(f.server->start().kind, ErrorKind::None);
  return f.server->boundPort();
}

/// One framed response on a keep-alive connection (head + Content-Length).
std::string readOneResponse(int fd) {
  std::string out = readHttpHead(fd);
  const size_t end = out.find("\r\n\r\n");
  if (end == std::string::npos) return out;
  const size_t need =
      end + 4 + (size_t)atol(headerOf(out, "content-length").c_str());
  char buf[4096];
  while (out.size() < need) {
    const ssize_t n =
        recv(fd, buf, std::min(sizeof(buf), need - out.size()), 0);
    if (n <= 0) break;
    out.append(buf, (size_t)n);
  }
  return out;
}

const char* kWsHandshakeHead =
    "GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n"
    "Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
    "Sec-WebSocket-Version: 13\r\n\r\n";

/// A masked client frame header claiming [length] bytes, with no payload:
/// the engine must judge the length before reading any of it.
void sendWsHeaderOnly(int fd, int opcode, uint64_t length) {
  std::string out;
  out.push_back((char)(0x80 | opcode));
  if (length < 126) {
    out.push_back((char)(0x80 | length));
  } else if (length <= 0xffff) {
    out.push_back((char)(0x80 | 126));
    out.push_back((char)((length >> 8) & 0xff));
    out.push_back((char)(length & 0xff));
  } else {
    out.push_back((char)(0x80 | 127));
    for (int i = 7; i >= 0; i--) out.push_back((char)((length >> (8 * i)) & 0xff));
  }
  out.append("\x01\x02\x03\x04", 4);
  sendStr(fd, out);
}

int wsCloseCode(int fd) {
  std::string payload;
  if (readWsFrame(fd, payload) != 0x8 || payload.size() < 2) return -1;
  return ((uint8_t)payload[0] << 8) | (uint8_t)payload[1];
}

TEST(ServerTest, RouteTableErrorsAndStartTwice) {
  Fixture f(echoAnswer());
  EXPECT_EQ(f.server->registerRoute(Method::Get, "", "hello", -1).kind,
            ErrorKind::BadRequest);
  ASSERT_EQ(f.server->registerRoute(Method::Get, "", "/hello", -1).kind,
            ErrorKind::None);
  EXPECT_EQ(f.server->unregisterRoute(Method::Get, "", "/hello").kind,
            ErrorKind::None);
  EXPECT_EQ(f.server->unregisterRoute(Method::Get, "", "/hello").kind,
            ErrorKind::RouteNotFound);
  const int64_t port = f.startOnEphemeral();
  EXPECT_EQ(f.server->start().kind, ErrorKind::AlreadyRunning);
  const int fd = connectTo((int)port);
  ASSERT_GE(fd, 0);
  sendStr(fd, "GET /hello HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
  EXPECT_EQ(statusOf(readAll(fd)), 404);
  close(fd);
}

TEST(ServerTest, ExplicitPortOnTheIpv4WildcardBinds) {
  const int probe = socket(AF_INET, SOCK_STREAM, 0);
  sockaddr_in a{};
  a.sin_family = AF_INET;
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  ASSERT_EQ(bind(probe, (sockaddr*)&a, sizeof(a)), 0);
  socklen_t len = sizeof(a);
  ASSERT_EQ(getsockname(probe, (sockaddr*)&a, &len), 0);
  const int port = ntohs(a.sin_port);
  close(probe);

  Fixture f(echoAnswer());
  f.server->registerRoute(Method::Get, "", "/hello", -1);
  ServerConfig cfg;
  cfg.port = port;
  cfg.host = "0.0.0.0";
  cfg.defaultTimeoutMs = 5000;
  f.server->configure(cfg);
  ASSERT_EQ(f.server->start().kind, ErrorKind::None);
  EXPECT_EQ(f.server->boundPort(), port);
  EXPECT_EQ(f.server->liveConnections(), 0);
  const int fd = connectTo(port);
  ASSERT_GE(fd, 0);
  sendStr(fd, "GET /hello HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
  EXPECT_EQ(statusOf(readAll(fd)), 200);
  close(fd);
}

TEST(ServerTest, Http10KeepAliveHeaderKeepsTheConnection) {
  Fixture f(echoAnswer());
  f.server->registerRoute(Method::Get, "", "/hello", -1);
  const int64_t port = f.startOnEphemeral();
  const int fd = connectTo((int)port);
  ASSERT_GE(fd, 0);
  for (int i = 0; i < 2; i++) {
    sendStr(fd, "GET /hello HTTP/1.0\r\nHost: x\r\nConnection: keep-alive\r\n\r\n");
    EXPECT_EQ(statusOf(readOneResponse(fd)), 200);
  }
  close(fd);
}

TEST(ServerTest, PipelinedRequestsAreAnsweredInOrder) {
  Fixture f(echoAnswer());
  f.server->registerRoute(Method::Get, "", "/hello", -1);
  const int64_t port = f.startOnEphemeral();
  const int fd = connectTo((int)port);
  ASSERT_GE(fd, 0);
  sendStr(fd,
          "GET /hello HTTP/1.1\r\nHost: x\r\n\r\n"
          "GET /hello HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
  const std::string all = readAll(fd);
  EXPECT_EQ(statusOf(all), 200);
  EXPECT_NE(all.find("HTTP/1.1 200", 20), std::string::npos);
  close(fd);
}

TEST(ServerTest, ExpectContinueGets100BeforeTheBody) {
  Fixture f(echoAnswer());
  f.server->registerRoute(Method::Post, "", "/echo", -1);
  const int64_t port = f.startOnEphemeral();
  const int fd = connectTo((int)port);
  ASSERT_GE(fd, 0);
  sendStr(fd,
          "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n"
          "Expect: 100-continue\r\nConnection: close\r\n\r\n");
  EXPECT_EQ(statusOf(readHttpHead(fd)), 100);
  sendStr(fd, "hello");
  const std::string rest = readAll(fd);
  EXPECT_EQ(statusOf(rest), 200);
  EXPECT_EQ(bodyOf(rest), "echo:hello");
  close(fd);
}

TEST(ServerTest, ChunkedUploadReassemblesAcrossWritesAndTrailers) {
  Fixture f(echoAnswer());
  f.server->registerRoute(Method::Post, "", "/echo", -1);
  const int64_t port = f.startOnEphemeral();
  const int fd = connectTo((int)port);
  ASSERT_GE(fd, 0);
  sendStr(fd,
          "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n"
          "Connection: close\r\n\r\n5\r\nhel");
  std::this_thread::sleep_for(std::chrono::milliseconds(20));
  sendStr(fd, "lo\r\n6\r\n world\r\n0\r\nX-Trailer: 1\r\n\r\n");
  const std::string rest = readAll(fd);
  EXPECT_EQ(statusOf(rest), 200);
  EXPECT_EQ(bodyOf(rest), "echo:hello world");
  ASSERT_EQ(f.emitter.seen().size(), 1u);
  f.server->ackBody(f.emitter.seen()[0].requestId, 2);
  close(fd);
}

TEST(ServerTest, ChunkedUploadOverTheRouteCapIs413) {
  Fixture f(echoAnswer());
  f.server->registerRoute(Method::Post, "", "/small", -1, false, false, 8);
  const int64_t port = f.startOnEphemeral();
  {  // A chunk larger than the cap.
    const int fd = connectTo((int)port);
    ASSERT_GE(fd, 0);
    sendStr(fd,
            "POST /small HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n"
            "Connection: close\r\n\r\n14\r\n01234567890123456789\r\n0\r\n\r\n");
    EXPECT_EQ(statusOf(readAll(fd)), 413);
    close(fd);
  }
  {  // A size line dripped in past the cap: fill()'s recv-side guard trips
     // (a pre-buffered oversize line is instead read as a truncated 400).
    const int fd = connectTo((int)port);
    ASSERT_GE(fd, 0);
    sendStr(fd, "POST /small HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n"
                "Connection: close\r\n\r\n");
    std::this_thread::sleep_for(std::chrono::milliseconds(30));
    sendStr(fd, std::string(4096, 'f'));  // no CRLF: an ever-growing size line
    EXPECT_EQ(statusOf(readAll(fd)), 413);
    close(fd);
  }
}

TEST(ServerTest, RequestSmugglingVectorsAre400) {
  // RFC 9112 §6.1/§6.3.3/§3.2: ambiguous framing is rejected before routing.
  Fixture f(echoAnswer());
  f.server->registerRoute(Method::Post, "", "/echo", -1);
  f.server->registerRoute(Method::Get, "", "/hello", -1);
  const int64_t port = f.startOnEphemeral();
  const char* shapes[] = {
      // Content-Length + Transfer-Encoding.
      "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n"
      "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n0\r\n\r\n",
      // Conflicting duplicate Content-Length.
      "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n"
      "Content-Length: 6\r\nConnection: close\r\n\r\nhello",
      // Equal duplicate Content-Length (still ambiguous).
      "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n"
      "Content-Length: 5\r\nConnection: close\r\n\r\nhello",
      // HTTP/1.1 without Host.
      "GET /hello HTTP/1.1\r\nConnection: close\r\n\r\n",
      // Duplicate Host.
      "GET /hello HTTP/1.1\r\nHost: a\r\nHost: b\r\nConnection: close\r\n\r\n",
  };
  for (const char* shape : shapes) {
    const int fd = connectTo((int)port);
    ASSERT_GE(fd, 0);
    sendStr(fd, shape);
    EXPECT_EQ(statusOf(readAll(fd)), 400) << shape;
    close(fd);
  }
  // HTTP/1.0 without Host is allowed (no §3.2 rule).
  const int fd = connectTo((int)port);
  ASSERT_GE(fd, 0);
  sendStr(fd, "GET /hello HTTP/1.0\r\nConnection: close\r\n\r\n");
  EXPECT_EQ(statusOf(readAll(fd)), 200);
  close(fd);
}

TEST(ServerTest, TruncatedOrMalformedBodiesAre400) {
  Fixture f(echoAnswer());
  f.server->registerRoute(Method::Post, "", "/echo", -1);
  const int64_t port = f.startOnEphemeral();
  const char* shapes[] = {
      "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel",
      "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\nabc",
      "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 200000\r\n\r\nabc",
      "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: abc\r\n\r\n",
  };
  for (const char* shape : shapes) {
    const int fd = connectTo((int)port);
    ASSERT_GE(fd, 0);
    sendStr(fd, shape);
    shutdown(fd, SHUT_WR);
    EXPECT_EQ(statusOf(readAll(fd)), 400) << shape;
    close(fd);
  }
}

TEST(ServerTest, UpgradeOnAnHttpRouteIs426AndBytesAfterAnUpgradeHeadAre400) {
  Fixture f(echoAnswer());
  f.server->registerRoute(Method::Get, "", "/hello", -1);
  f.server->registerRoute(Method::Get, "", "/ws", -1, true);
  const int64_t port = f.startOnEphemeral();
  {
    const int fd = connectTo((int)port);
    ASSERT_GE(fd, 0);
    std::string head = kWsHandshakeHead;
    head.replace(head.find("/ws"), 3, "/hello");
    sendStr(fd, head);
    EXPECT_EQ(statusOf(readHttpHead(fd)), 426);
    close(fd);
  }
  {
    const int fd = connectTo((int)port);
    ASSERT_GE(fd, 0);
    sendStr(fd, std::string(kWsHandshakeHead) + "XX");
    EXPECT_EQ(statusOf(readHttpHead(fd)), 400);
    close(fd);
  }
}

TEST(ServerTest, OversizedHeadClosesWithoutAnAnswer) {
  Fixture f(echoAnswer());
  f.server->registerRoute(Method::Get, "", "/hello", -1);
  const int64_t port = f.startOnEphemeral();
  const int fd = connectTo((int)port);
  ASSERT_GE(fd, 0);
  std::string head = "GET /hello HTTP/1.1\r\nHost: x\r\n";
  while (head.size() < 96 * 1024) head += "X-Pad: " + std::string(1000, 'p') + "\r\n";
  sendStr(fd, head);
  EXPECT_TRUE(readAll(fd).empty());
  close(fd);
}

TEST(ServerTest, KeepAliveIdleTimeoutClosesTheConnection) {
  Fixture f(echoAnswer());
  f.server->registerRoute(Method::Get, "", "/hello", -1);
  ServerConfig cfg;
  cfg.keepAliveTimeoutMs = 150;
  cfg.defaultTimeoutMs = 5000;
  const int64_t port = startWith(f, cfg);
  const int fd = connectTo((int)port);
  ASSERT_GE(fd, 0);
  sendStr(fd, "GET /hello HTTP/1.1\r\nHost: x\r\n\r\n");
  EXPECT_EQ(statusOf(readOneResponse(fd)), 200);
  EXPECT_TRUE(readAll(fd).empty());
  close(fd);
}

TEST(ServerTest, LargeAnswerToASlowReaderIsFlushedByTheWorker) {
  const std::string big(4 * 1024 * 1024, 'b');
  Fixture f([&](Method, const std::string&, const std::string&) {
    return std::make_pair(200, big);
  });
  f.server->registerRoute(Method::Get, "", "/big", -1);
  const int64_t port = f.startOnEphemeral();
  const int fd = connectTo((int)port);
  ASSERT_GE(fd, 0);
  sendStr(fd, "GET /big HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
  std::this_thread::sleep_for(std::chrono::milliseconds(300));
  const std::string all = readAll(fd);
  EXPECT_EQ(statusOf(all), 200);
  EXPECT_EQ(bodyOf(all).size(), big.size());
  close(fd);
}

TEST(ServerTest, WsProtocolErrorsCloseWithTheRightCodes) {
  Fixture f(echoAnswer());
  f.server->registerRoute(Method::Get, "", "/ws", -1, true);
  ServerConfig cfg;
  cfg.maxBodyBytes = 100;  // Also the WebSocket message cap.
  cfg.defaultTimeoutMs = 5000;
  const int64_t port = startWith(f, cfg);
  auto open = [&]() {
    const int fd = connectTo((int)port);
    EXPECT_GE(fd, 0);
    sendStr(fd, kWsHandshakeHead);
    EXPECT_EQ(statusOf(readHttpHead(fd)), 101);
    return fd;
  };
  {  // Continuation with nothing to continue.
    const int fd = open();
    sendWsFrame(fd, 0x0, "x");
    EXPECT_EQ(wsCloseCode(fd), 1002);
    close(fd);
  }
  {  // A new message before the previous one's FIN.
    const int fd = open();
    sendWsFrame(fd, 0x1, "ab", false);
    sendWsFrame(fd, 0x1, "cd");
    EXPECT_EQ(wsCloseCode(fd), 1002);
    close(fd);
  }
  {  // Text that is not UTF-8.
    const int fd = open();
    sendWsFrame(fd, 0x1, "\xff\xfe");
    EXPECT_EQ(wsCloseCode(fd), 1007);
    close(fd);
  }
  {  // 16-bit and 64-bit lengths over the cap, judged at the header.
    const int fd = open();
    sendWsHeaderOnly(fd, 0x2, 200);
    EXPECT_EQ(wsCloseCode(fd), 1009);
    close(fd);
    const int fd2 = open();
    sendWsHeaderOnly(fd2, 0x2, 70000);
    EXPECT_EQ(wsCloseCode(fd2), 1009);
    close(fd2);
  }
  {  // Fragments that add up past the cap.
    const int fd = open();
    sendWsFrame(fd, 0x1, std::string(60, 'a'), false);
    sendWsFrame(fd, 0x0, std::string(60, 'a'));
    EXPECT_EQ(wsCloseCode(fd), 1009);
    close(fd);
  }
}

TEST(ServerTest, WsSendToAPeerThatStoppedReadingFails) {
  Fixture f(echoAnswer());
  f.server->registerRoute(Method::Get, "", "/ws", -1, true);
  ServerConfig cfg;
  cfg.writeTimeoutMs = 100;
  cfg.wsMaxBufferBytes = 64 * 1024 * 1024;
  cfg.defaultTimeoutMs = 5000;
  const int64_t port = startWith(f, cfg);
  const int fd = connectTo((int)port);
  ASSERT_GE(fd, 0);
  sendStr(fd, kWsHandshakeHead);
  ASSERT_EQ(statusOf(readHttpHead(fd)), 101);
  ASSERT_TRUE(f.waitForSeen(1));
  const int64_t id = f.emitter.seen()[0].requestId;
  // Nobody reads: the direct write fills the socket, the queue grows, the
  // worker's flush stalls past writeTimeoutMs and the session fails.
  const std::string msg(256 * 1024, 'm');
  int64_t r = 0;
  const auto end = std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (r >= 0 && std::chrono::steady_clock::now() < end) {
    r = f.server->wsSend(id, (const uint8_t*)msg.data(), msg.size(), true, false);
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  EXPECT_LT(r, 0);
  close(fd);
}

TEST(ServerTest, StreamEndsWithAnEmptyLastChunk) {
  // No Fixture: its pump would answer the request before the stream starts.
  RecordingEmitter emitter(echoAnswer());
  auto server = std::make_shared<ServerInstance>();
  server->setEmitter(&emitter);
  ASSERT_EQ(server->registerRoute(Method::Get, "", "/s", -1).kind, ErrorKind::None);
  ServerConfig cfg;
  cfg.port = 0;
  server->configure(cfg);
  ASSERT_EQ(server->start().kind, ErrorKind::None);
  std::string res;
  std::thread client([&] {
    const int c = connectTo((int)server->boundPort());
    if (c < 0) return;
    sendStr(c, "GET /s HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    res = readAll(c);
    close(c);
  });
  int64_t id = 0;
  for (int i = 0; i < 1000 && id == 0; i++) {
    auto seen = emitter.seen();
    if (!seen.empty()) id = seen[0].requestId;
    if (id == 0) std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  ASSERT_NE(id, 0);
  server->startStream(id, 200, {{"Content-Type", "text/plain"}});
  server->sendStreamChunk(id, (const uint8_t*)"ab", 2, false);
  server->sendStreamChunk(id, nullptr, 0, true);
  client.join();
  EXPECT_EQ(dechunk(bodyOf(res)), "ab");
  server->stop();
}

#ifdef NITRO_SERVER_TLS
// ── TLS ───────────────────────────────────────────────────────────────────

// A blocking OpenSSL client for the tests: connect, handshake, then plain
// SSL_read/SSL_write with a receive timeout so a hung server fails the test
// instead of wedging it.
struct TlsClient {
  SSL_CTX* ctx = nullptr;
  SSL* ssl = nullptr;
  int fd = -1;

  bool open(int port, const char* alpn = nullptr) {
    fd = connectTo(port);
    if (fd < 0) return false;
    timeval tv{5, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    ctx = SSL_CTX_new(TLS_client_method());
    ssl = SSL_new(ctx);
    SSL_set_fd(ssl, fd);
    if (alpn) {
      unsigned char p[32];
      p[0] = (unsigned char)strlen(alpn);
      memcpy(p + 1, alpn, strlen(alpn));
      SSL_set_alpn_protos(ssl, p, (unsigned)strlen(alpn) + 1);
    }
    return SSL_connect(ssl) == 1;
  }
  bool write(const std::string& s) {
    return SSL_write(ssl, s.data(), (int)s.size()) == (int)s.size();
  }
  // Reads one framed HTTP response (head + Content-Length body).
  std::string readResponse() {
    std::string out;
    char buf[4096];
    // Head.
    while (out.find("\r\n\r\n") == std::string::npos) {
      const int n = SSL_read(ssl, buf, sizeof(buf));
      if (n <= 0) return out;
      out.append(buf, (size_t)n);
    }
    const size_t end = out.find("\r\n\r\n");
    const size_t need = end + 4 + (size_t)atol(headerOf(out, "content-length").c_str());
    while (out.size() < need) {
      const int n = SSL_read(ssl, buf, sizeof(buf));
      if (n <= 0) break;
      out.append(buf, (size_t)n);
    }
    return out;
  }
  std::string alpn() {
    const unsigned char* p = nullptr;
    unsigned len = 0;
    SSL_get0_alpn_selected(ssl, &p, &len);
    return p ? std::string((const char*)p, len) : std::string();
  }
  ~TlsClient() {
    if (ssl) {
      SSL_shutdown(ssl);
      SSL_free(ssl);
    }
    if (ctx) SSL_CTX_free(ctx);
    if (fd >= 0) close(fd);
  }
};

int startTls(Fixture& f, const std::string& certPem, const std::string& keyPem) {
  ServerConfig cfg;
  cfg.port = 0;
  cfg.defaultTimeoutMs = 5000;
  cfg.tlsRequested = true;
  cfg.tlsCertPem = certPem;
  cfg.tlsKeyPem = keyPem;
  f.server->configure(cfg);
  EXPECT_EQ(f.server->start().kind, ErrorKind::None);
  return (int)f.server->boundPort();
}

TEST(TlsTest, ServesARequestOverTls) {
  Fixture f(echoAnswer());
  f.server->registerRoute(Method::Get, "", "/hello", -1);
  const int port = startTls(f, nitroserver_test::kTestCertPem,
                            nitroserver_test::kTestKeyPem);
  TlsClient c;
  ASSERT_TRUE(c.open(port, "http/1.1"));
  EXPECT_EQ(c.alpn(), "http/1.1");
  ASSERT_TRUE(c.write("GET /hello HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"));
  const std::string res = c.readResponse();
  EXPECT_EQ(statusOf(res), 200);
  EXPECT_EQ(bodyOf(res), "echo:");
}

TEST(TlsTest, ForcedTls13KeepAliveExchange) {
  // TLS 1.3 with keep-alive stresses the post-handshake read path (where a
  // ticket/key-update makes SSL_read want to write). Tickets are disabled and
  // tlsRead handles the direction, so this must not hang.
  Fixture f(echoAnswer());
  f.server->registerRoute(Method::Get, "", "/hello", -1);
  const int port = startTls(f, nitroserver_test::kTestCertPem,
                            nitroserver_test::kTestKeyPem);
  int fd = connectTo(port);
  ASSERT_GE(fd, 0);
  timeval tv{5, 0};
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
  SSL_CTX* ctx = SSL_CTX_new(TLS_client_method());
  SSL_CTX_set_min_proto_version(ctx, TLS1_3_VERSION);
  SSL_CTX_set_max_proto_version(ctx, TLS1_3_VERSION);
  SSL* ssl = SSL_new(ctx);
  SSL_set_fd(ssl, fd);
  ASSERT_EQ(SSL_connect(ssl), 1);
  EXPECT_STREQ(SSL_get_version(ssl), "TLSv1.3");
  for (int i = 0; i < 3; i++) {
    const std::string req = "GET /hello HTTP/1.1\r\nHost: x\r\n\r\n";
    ASSERT_EQ(SSL_write(ssl, req.data(), (int)req.size()), (int)req.size());
    std::string res;
    char b[2048];
    while (res.find("\r\n\r\n") == std::string::npos) {
      const int n = SSL_read(ssl, b, sizeof(b));
      if (n <= 0) break;
      res.append(b, (size_t)n);
    }
    EXPECT_EQ(statusOf(res), 200) << "request " << i;
  }
  SSL_shutdown(ssl);
  SSL_free(ssl);
  SSL_CTX_free(ctx);
  close(fd);
}

TEST(TlsTest, KeepAliveServesTwoRequestsOnOneTlsConnection) {
  Fixture f(echoAnswer());
  f.server->registerRoute(Method::Get, "", "/hello", -1);
  const int port = startTls(f, nitroserver_test::kTestCertPem,
                            nitroserver_test::kTestKeyPem);
  TlsClient c;
  ASSERT_TRUE(c.open(port));
  for (int i = 0; i < 2; i++) {
    ASSERT_TRUE(c.write("GET /hello HTTP/1.1\r\nHost: x\r\n\r\n"));
    EXPECT_EQ(statusOf(c.readResponse()), 200);
  }
}

TEST(TlsTest, PostBodyEchoesOverTls) {
  Fixture f(echoAnswer());
  f.server->registerRoute(Method::Post, "", "/echo", -1);
  const int port = startTls(f, nitroserver_test::kTestCertPem,
                            nitroserver_test::kTestKeyPem);
  TlsClient c;
  ASSERT_TRUE(c.open(port));
  ASSERT_TRUE(c.write("POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n"
                      "Connection: close\r\n\r\nhello"));
  const std::string res = c.readResponse();
  EXPECT_EQ(statusOf(res), 200);
  EXPECT_EQ(bodyOf(res), "echo:hello");
  ASSERT_TRUE(f.waitForSeen(1));
  f.server->ackBody(f.emitter.seen()[0].requestId, 1);
}

TEST(TlsTest, FileResponseStreamsOverTls) {
  // respondFile uses read+SSL_write under TLS (sendfile cannot traverse it).
  // No pump: the test answers with respondFile once the head is seen.
  RecordingEmitter emitter(echoAnswer());
  auto server = std::make_shared<ServerInstance>();
  server->setEmitter(&emitter);
  ASSERT_EQ(server->registerRoute(Method::Get, "", "/file", -1).kind,
            ErrorKind::None);
  ServerConfig cfg;
  cfg.port = 0;
  cfg.defaultTimeoutMs = 5000;
  cfg.tlsRequested = true;
  cfg.tlsCertPem = nitroserver_test::kTestCertPem;
  cfg.tlsKeyPem = nitroserver_test::kTestKeyPem;
  server->configure(cfg);
  ASSERT_EQ(server->start().kind, ErrorKind::None);
  const int port = (int)server->boundPort();
  const std::string bytes(200000, 'z');
  const std::string path = tempFileWith(bytes);

  std::string res;
  std::thread client([&] {
    TlsClient c;
    if (!c.open(port)) return;
    c.write("GET /file HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    res = c.readResponse();
  });
  int64_t id = 0;
  for (int i = 0; i < 1000 && id == 0; i++) {
    auto seen = emitter.seen();
    if (!seen.empty()) id = seen[0].requestId;
    if (id == 0) std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  ASSERT_NE(id, 0);
  server->respondFile(id, 200, {{"Content-Type", "text/plain"}}, path, 0, -1);
  client.join();
  EXPECT_EQ(statusOf(res), 200);
  EXPECT_EQ(bodyOf(res).size(), bytes.size());
  server->stop();
  ::remove(path.c_str());
}

TEST(TlsTest, WebSocketBothDirectionsOverTls) {
  RecordingEmitter emitter(echoAnswer());
  auto server = std::make_shared<ServerInstance>();
  server->setEmitter(&emitter);
  ASSERT_EQ(server->registerRoute(Method::Get, "", "/ws", -1, true).kind,
            ErrorKind::None);
  ServerConfig cfg;
  cfg.port = 0;
  cfg.defaultTimeoutMs = 5000;
  cfg.tlsRequested = true;
  cfg.tlsCertPem = nitroserver_test::kTestCertPem;
  cfg.tlsKeyPem = nitroserver_test::kTestKeyPem;
  server->configure(cfg);
  ASSERT_EQ(server->start().kind, ErrorKind::None);
  const int port = (int)server->boundPort();

  TlsClient c;
  ASSERT_TRUE(c.open(port));
  ASSERT_TRUE(c.write(kWsHandshakeHead));
  std::string head;
  char b[1024];
  while (head.find("\r\n\r\n") == std::string::npos) {
    const int n = SSL_read(c.ssl, b, sizeof(b));
    if (n <= 0) break;
    head.append(b, (size_t)n);
  }
  ASSERT_EQ(statusOf(head), 101);

  // Client -> server: a masked "hi" text frame decodes on the server.
  const unsigned char frame[] = {0x81, 0x82, 0x00, 0x00, 0x00, 0x00, 'h', 'i'};
  ASSERT_EQ(SSL_write(c.ssl, frame, sizeof(frame)), (int)sizeof(frame));
  int64_t connId = 0;
  for (int i = 0; i < 1000; i++) {
    auto ws = emitter.wsSeen();
    if (!ws.empty() && ws[0].opcode == 0x1) {
      EXPECT_EQ(ws[0].payload, "hi");
      connId = ws[0].connectionId;
      break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  ASSERT_NE(connId, 0);

  // Server -> client: wsSend writes an unmasked frame the client reads.
  const char* msg = "yo";
  server->wsSend(connId, (const uint8_t*)msg, 2, false, false);
  unsigned char rin[8];
  int got = 0;
  while (got < 4) {
    const int n = SSL_read(c.ssl, rin + got, (int)sizeof(rin) - got);
    if (n <= 0) break;
    got += n;
  }
  ASSERT_GE(got, 4);
  EXPECT_EQ(rin[0], 0x81);
  EXPECT_EQ(rin[1], 0x02);
  EXPECT_EQ(rin[2], 'y');
  EXPECT_EQ(rin[3], 'o');
  server->stop();
}

TEST(TlsTest, CertKeyMismatchIsAnError) {
  // A second independent key does not match the cert.
  auto server = std::make_shared<ServerInstance>();
  RecordingEmitter emitter(echoAnswer());
  server->setEmitter(&emitter);
  ServerConfig cfg;
  cfg.port = 0;
  cfg.tlsRequested = true;
  cfg.tlsCertPem = nitroserver_test::kTestCertPem;
  cfg.tlsKeyPem =
      "-----BEGIN PRIVATE KEY-----\nnot a real key\n-----END PRIVATE KEY-----\n";
  server->configure(cfg);
  EXPECT_EQ(server->start().kind, ErrorKind::TlsError);
}

TEST(TlsTest, CertAndKeyLoadFromFiles) {
  const std::string certPath = tempFileWith(nitroserver_test::kTestCertPem);
  const std::string keyPath = tempFileWith(nitroserver_test::kTestKeyPem);
  Fixture f(echoAnswer());
  f.server->registerRoute(Method::Get, "", "/hello", -1);
  ServerConfig cfg;
  cfg.port = 0;
  cfg.defaultTimeoutMs = 5000;
  cfg.tlsRequested = true;
  cfg.tlsCertFile = certPath;
  cfg.tlsKeyFile = keyPath;
  f.server->configure(cfg);
  ASSERT_EQ(f.server->start().kind, ErrorKind::None);
  TlsClient c;
  ASSERT_TRUE(c.open((int)f.server->boundPort()));
  ASSERT_TRUE(c.write("GET /hello HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"));
  EXPECT_EQ(statusOf(c.readResponse()), 200);
  ::remove(certPath.c_str());
  ::remove(keyPath.c_str());
}
#endif  // NITRO_SERVER_TLS


}  // namespace
