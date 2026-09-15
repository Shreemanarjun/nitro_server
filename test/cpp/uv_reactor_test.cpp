// UvReactor (libuv I/O core) tests — the reactor that replaces the
// thread-per-connection transport. Validates HTTP request/response, the static
// fast path, keep-alive, and the cross-thread respond() handoff over real
// sockets. Compiled only where libuv is present (NITRO_SERVER_LIBUV).
#ifdef NITRO_SERVER_LIBUV

#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <deque>
#include <map>
#include <mutex>
#include <string>
#include <thread>

#include "UvReactor.h"
#include "gtest/gtest.h"

using namespace nitroserver;

namespace {

int connectTo(int port) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  sockaddr_in a{};
  a.sin_family = AF_INET;
  a.sin_port = htons((uint16_t)port);
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (connect(fd, (sockaddr*)&a, sizeof(a)) != 0) {
    close(fd);
    return -1;
  }
  int one = 1;
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
  return fd;
}

void sendStr(int fd, const std::string& s) {
  size_t sent = 0;
  while (sent < s.size()) {
    ssize_t n = send(fd, s.data() + sent, s.size() - sent, 0);
    if (n <= 0) break;
    sent += (size_t)n;
  }
}

std::string readHead(int fd) {
  std::string out;
  char buf[2048];
  while (out.find("\r\n\r\n") == std::string::npos) {
    ssize_t n = recv(fd, buf, sizeof(buf), 0);
    if (n <= 0) break;
    out.append(buf, (size_t)n);
  }
  return out;
}

int statusOf(const std::string& r) {
  const size_t sp = r.find(' ');
  return sp == std::string::npos ? -1 : std::atoi(r.c_str() + sp + 1);
}

std::string headerOf(const std::string& r, const std::string& name) {
  std::string ln = "\r\n" + name + ":";
  size_t p = r.find(ln);
  if (p == std::string::npos) return "";
  p += ln.size();
  while (p < r.size() && r[p] == ' ') p++;
  size_t e = r.find("\r\n", p);
  return r.substr(p, e - p);
}

std::string bodyOf(const std::string& r) {
  size_t p = r.find("\r\n\r\n");
  return p == std::string::npos ? "" : r.substr(p + 4);
}

// Records emitted request ids and answers each with a fixed body from a pump
// thread, standing in for the Dart runner.
class PumpEmitter final : public Emitter {
 public:
  PumpEmitter(UvReactor* r, std::string body) : reactor_(r), body_(std::move(body)) {
    pump_ = std::thread([this] {
      while (running_.load()) {
        int64_t id = -1;
        {
          std::lock_guard<std::mutex> lk(m_);
          if (!ids_.empty()) {
            id = ids_.front();
            ids_.pop_front();
          }
        }
        std::string reply;
        if (id >= 0) {
          std::lock_guard<std::mutex> lk(m_);
          auto it = bodies_.find(id);
          reply = it != bodies_.end() && !it->second.empty() ? it->second : body_;
          bodies_.erase(id);
        }
        if (id >= 0) {
          reactor_->respond(id, 200, {{"Content-Type", "text/plain"}},
                            (const uint8_t*)reply.data(), reply.size());
        } else {
          std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
      }
    });
  }
  ~PumpEmitter() override {
    running_.store(false);
    if (pump_.joinable()) pump_.join();
  }
  void emitHead(int64_t id, Method, const std::string&, const std::string& path,
                const std::string&, const std::vector<Header>&, int64_t, bool,
                bool, const std::string&, const std::vector<RouteParam>&) override {
    std::lock_guard<std::mutex> lk(m_);
    ids_.push_back(id);
    lastPath_ = path;
  }
  // Copy the body for echo; the engine owns the payload (freed on ack/stop).
  void emitBodyData(int64_t id, uint8_t* payload, size_t n) override {
    std::lock_guard<std::mutex> lk(m_);
    bodies_[id].append((const char*)payload, n);
  }
  void emitBodyEnd(int64_t) override {}
  void emitBodyError(int64_t, uint8_t*, size_t, ErrorKind) override {}
  void emitWsMessage(int64_t, uint8_t*, size_t, int, int) override {}
  void emitEvent(ServerEventKind, int64_t, const std::string&) override {}

 private:
  UvReactor* reactor_;
  std::string body_;
  std::thread pump_;
  std::atomic<bool> running_{true};
  std::mutex m_;
  std::deque<int64_t> ids_;
  std::map<int64_t, std::string> bodies_;
  std::string lastPath_;
};

RouteEntry httpRoute(Method m, const std::string& pattern) {
  RouteEntry e;
  e.method = m;
  e.pattern = pattern;
  return e;
}

RouteEntry staticRoute(const std::string& pattern, const std::string& body) {
  RouteEntry e;
  e.method = Method::Get;
  e.pattern = pattern;
  auto sr = std::make_shared<StaticResponse>();
  sr->status = 200;
  sr->headers = {{"Content-Type", "text/plain"}};
  sr->body = body;
  e.staticResponse = sr;
  return e;
}

struct Fixture {
  UvReactor reactor;
  PumpEmitter emitter{&reactor, "handled"};
  int port = 0;
  void start() {
    reactor.setEmitter(&emitter);
    ServerConfig cfg;
    cfg.port = 0;
    cfg.keepAliveTimeoutMs = 5000;
    reactor.configure(cfg);
    ASSERT_EQ((int64_t)reactor.start(2).kind, (int64_t)ErrorKind::None);
    port = (int)reactor.boundPort();
    ASSERT_GT(port, 0);
  }
  ~Fixture() { reactor.stop(); }
};

}  // namespace

TEST(UvReactorTest, StaticRouteServesWithKeepAlive) {
  Fixture f;
  ASSERT_EQ((int64_t)f.reactor.registerStaticRoute(staticRoute("/health", "hello"))
                .kind,
            (int64_t)ErrorKind::None);
  f.start();

  const int fd = connectTo(f.port);
  ASSERT_GE(fd, 0);
  sendStr(fd, "GET /health HTTP/1.1\r\nHost: x\r\n\r\n");
  const std::string r1 = readHead(fd);
  EXPECT_EQ(statusOf(r1), 200);
  EXPECT_EQ(headerOf(r1, "Content-Length"), "5");
  EXPECT_EQ(headerOf(r1, "Connection"), "keep-alive");

  // Second request on the same connection: keep-alive held.
  sendStr(fd, "GET /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
  std::string r2;
  char buf[512];
  ssize_t n;
  while ((n = recv(fd, buf, sizeof(buf), 0)) > 0) r2.append(buf, (size_t)n);
  close(fd);
  EXPECT_EQ(bodyOf(r2), "hello");
  EXPECT_EQ(headerOf(r2, "Connection"), "close");
}

TEST(UvReactorTest, HandlerRouteRoundTripsThroughRespond) {
  Fixture f;
  ASSERT_EQ((int64_t)f.reactor.registerRoute(httpRoute(Method::Get, "/hi")).kind,
            (int64_t)ErrorKind::None);
  f.start();

  const int fd = connectTo(f.port);
  ASSERT_GE(fd, 0);
  sendStr(fd, "GET /hi HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
  std::string r;
  char buf[512];
  ssize_t n;
  while ((n = recv(fd, buf, sizeof(buf), 0)) > 0) r.append(buf, (size_t)n);
  close(fd);
  EXPECT_EQ(statusOf(r), 200);
  EXPECT_EQ(bodyOf(r), "handled");
}

TEST(UvReactorTest, PostBodyReachesTheHandlerAndEchoesBack) {
  Fixture f;
  ASSERT_EQ((int64_t)f.reactor.registerRoute(httpRoute(Method::Post, "/echo")).kind,
            (int64_t)ErrorKind::None);
  f.start();

  const std::string payload = "the quick brown fox";
  const int fd = connectTo(f.port);
  ASSERT_GE(fd, 0);
  sendStr(fd, "POST /echo HTTP/1.1\r\nHost: x\r\nConnection: close\r\n"
              "Content-Length: " + std::to_string(payload.size()) + "\r\n\r\n" +
              payload);
  std::string r;
  char buf[512];
  ssize_t n;
  while ((n = recv(fd, buf, sizeof(buf), 0)) > 0) r.append(buf, (size_t)n);
  close(fd);
  EXPECT_EQ(statusOf(r), 200);
  EXPECT_EQ(bodyOf(r), payload);  // the handler echoed the request body
}

TEST(UvReactorTest, OversizeBodyIs413) {
  Fixture f;
  ServerConfig cfg;
  cfg.port = 0;
  cfg.keepAliveTimeoutMs = 5000;
  cfg.maxBodyBytes = 8;
  f.reactor.configure(cfg);
  ASSERT_EQ((int64_t)f.reactor.registerRoute(httpRoute(Method::Post, "/up")).kind,
            (int64_t)ErrorKind::None);
  // start() is called by Fixture normally, but we reconfigured — start directly.
  ASSERT_EQ((int64_t)f.reactor.start(2).kind, (int64_t)ErrorKind::None);
  f.port = (int)f.reactor.boundPort();
  ASSERT_GT(f.port, 0);
  const int fd = connectTo(f.port);
  ASSERT_GE(fd, 0);
  sendStr(fd, "POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\n");
  EXPECT_EQ(statusOf(readHead(fd)), 413);
  close(fd);
}

TEST(UvReactorTest, UnroutedPathIs404) {
  Fixture f;
  f.start();
  const int fd = connectTo(f.port);
  ASSERT_GE(fd, 0);
  sendStr(fd, "GET /nope HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
  EXPECT_EQ(statusOf(readHead(fd)), 404);
  close(fd);
}

#endif  // NITRO_SERVER_LIBUV
