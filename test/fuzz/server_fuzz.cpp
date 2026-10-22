// libFuzzer target: every input is one client's bytes to a live engine, so
// the parser, body framing, limits, 100-continue, the WebSocket handshake
// and frame loop all see it. Slower than head_fuzz; wider.
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <condition_variable>
#include <cstdint>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "engine/UvReactor.h"

using namespace nitroserver;

namespace {

/// Answers every head with 200 and acks every payload, both from its own
/// thread the way the Dart runner does (never inside the emit call).
class FuzzEmitter final : public Emitter {
 public:
  explicit FuzzEmitter(std::shared_ptr<UvReactor> server)
      : server_(std::move(server)), pump_([this] { pump(); }) {}
  ~FuzzEmitter() override {
    stop_ = true;
    cv_.notify_all();
    pump_.join();
  }

  void emitHead(int64_t requestId, Method, const std::string&,
                const std::string&, const std::string&,
                const std::vector<Header>&, int64_t, bool, bool,
                const std::string& routePattern,
                const std::vector<RouteParam>&,
                const std::string&) override {
    if (routePattern == "/ws") return;  // frames arrive via emitWsMessage
    push({Job::Respond, requestId});
  }
  void emitBodyData(int64_t id, uint8_t*, size_t) override {
    push({Job::Ack, id});
  }
  void emitBodyEnd(int64_t) override {}
  void emitBodyError(int64_t id, uint8_t* payload, size_t,
                     ErrorKind) override {
    if (payload) push({Job::Ack, id});
  }
  void emitWsMessage(int64_t id, uint8_t*, size_t, int, int) override {
    push({Job::Ack, id});
  }
  void emitEvent(ServerEventKind, int64_t, const std::string&) override {}

 private:
  struct Job {
    enum Kind { Respond, Ack } kind;
    int64_t id;
  };
  void push(Job j) {
    std::lock_guard<std::mutex> lk(m_);
    jobs_.push_back(j);
    cv_.notify_one();
  }
  void pump() {
    std::unique_lock<std::mutex> lk(m_);
    while (!stop_) {
      cv_.wait(lk, [&] { return stop_ || !jobs_.empty(); });
      while (!jobs_.empty()) {
        const Job j = jobs_.front();
        jobs_.pop_front();
        lk.unlock();
        if (j.kind == Job::Respond) {
          server_->respond(j.id, 200, {{"Content-Type", "text/plain"}},
                           (const uint8_t*)"ok", 2);
        } else {
          server_->ackBody(j.id, ++acked_[j.id]);
        }
        lk.lock();
      }
    }
  }

  std::shared_ptr<UvReactor> server_;
  std::mutex m_;
  std::condition_variable cv_;
  std::deque<Job> jobs_;
  std::map<int64_t, int64_t> acked_;
  bool stop_ = false;
  std::thread pump_;
};

struct Harness {
  std::shared_ptr<UvReactor> server = std::make_shared<UvReactor>();
  std::unique_ptr<FuzzEmitter> emitter;
  int port = 0;

  Harness() {
    emitter = std::make_unique<FuzzEmitter>(server);
    server->setEmitter(emitter.get());
    ServerConfig cfg;
    cfg.port = 0;
    cfg.defaultTimeoutMs = 200;
    cfg.keepAliveTimeoutMs = 20;
    cfg.headerTimeoutMs = 20;
    cfg.writeTimeoutMs = 200;
    cfg.maxBodyBytes = 1 << 16;
    server->configure(cfg);
    server->registerRoute(Method::Get, "", "/hello", -1);
    server->registerRoute(Method::Post, "", "/echo", -1);
    server->registerRoute(Method::Put, "", "/stream", -1, false, true);
    server->registerRoute(Method::Post, "", "/small", -1, false, false, 8);
    server->registerRoute(Method::Get, "", "/ws", -1, true, false, -1, "json");
    server->start();
    port = (int)server->boundPort();
  }
  ~Harness() {
    server->stop();
    emitter.reset();
  }
};

}  // namespace

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t n) {
  static Harness h;
  const int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return 0;
  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_port = htons((uint16_t)h.port);
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (connect(fd, (sockaddr*)&addr, sizeof(addr)) != 0) {
    close(fd);
    return 0;
  }
#ifdef SO_NOSIGPIPE
  const int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
  timeval tv{0, 5000};
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
  // Two writes so the engine also sees split heads and partial bodies.
  const size_t half = n / 2;
  (void)!send(fd, data, half, 0);
  (void)!send(fd, data + half, n - half, 0);
  char buf[4096];
  while (recv(fd, buf, sizeof(buf), 0) > 0) {
  }
  close(fd);
  return 0;
}
