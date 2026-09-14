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
#include <cstring>
#include <deque>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <thread>

#include "engine/ServerInstance.h"

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
  f.server->wsSend(id, (const uint8_t*)hi, 2, false);
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

}  // namespace
