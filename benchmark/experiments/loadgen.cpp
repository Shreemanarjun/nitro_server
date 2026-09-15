// Raw keep-alive load generator: hammers host:port with N connections for T
// seconds, one request in flight per connection (request-response). Prints
// completed req/s. Used to sum throughput across independent server processes.
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <thread>
#include <vector>
int main(int argc, char** argv) {
  const int port = argc > 1 ? atoi(argv[1]) : 8080;
  const int conns = argc > 2 ? atoi(argv[2]) : 64;
  const int secs = argc > 3 ? atoi(argv[3]) : 5;
  std::atomic<long> total{0};
  std::atomic<bool> stop{false};
  char req[128]; snprintf(req, sizeof(req), "GET %s HTTP/1.1\r\nHost: x\r\n\r\n", argc > 4 ? argv[4] : "/hello");
  const size_t reqLen = strlen(req);
  std::vector<std::thread> ts;
  for (int c = 0; c < conns; c++) {
    ts.emplace_back([&] {
      int fd = socket(AF_INET, SOCK_STREAM, 0);
      sockaddr_in a{}; a.sin_family = AF_INET; a.sin_port = htons(port);
      a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
      if (connect(fd, (sockaddr*)&a, sizeof(a)) != 0) { close(fd); return; }
      int one = 1; setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
      char buf[1024]; long n = 0;
      while (!stop.load()) {
        if (send(fd, req, reqLen, 0) != (ssize_t)reqLen) break;
        size_t got = 0; bool ok = false;
        while (got < sizeof(buf)) {
          ssize_t r = recv(fd, buf + got, sizeof(buf) - got, 0);
          if (r <= 0) break;
          got += r;
          if (memmem(buf, got, "\r\n\r\n", 4)) { ok = true; break; }
        }
        if (!ok) break;
        n++;
      }
      close(fd);
      total.fetch_add(n);
    });
  }
  auto t0 = std::chrono::steady_clock::now();
  std::this_thread::sleep_for(std::chrono::seconds(secs));
  stop.store(true);
  for (auto& t : ts) t.join();
  double dt = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  printf("%.0f\n", total.load() / dt);
  return 0;
}
