// libuv reactor spike: N event loops (one per thread) over SO_REUSEPORT
// listeners, each serving a fixed keep-alive "hello" response — the shape a
// libuv-backed nitro engine would take for the getStatic/engine-served path.
// Measures libuv's ceiling vs Go net/http and nitro's thread-per-connection.
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
#include <uv.h>

static const char RESP[] =
    "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n"
    "Connection: keep-alive\r\n\r\nhello";
static const size_t RESP_LEN = sizeof(RESP) - 1;

typedef struct {
  uv_tcp_t handle;
  char buf[16384];
  size_t len;
} conn_t;

typedef struct {
  uv_write_t req;
  uv_buf_t buf;
} write_req_t;

static void on_close(uv_handle_t* h) { free(h); }

static void on_write2(uv_write_t* req, int status) {
  write_req_t* wr = (write_req_t*)req;
  free(wr->buf.base);  // batched payload
  free(wr);
  (void)status;
}

static void alloc_cb(uv_handle_t* h, size_t suggested, uv_buf_t* b) {
  conn_t* c = (conn_t*)h;
  *b = uv_buf_init(c->buf + c->len, sizeof(c->buf) - c->len);
  (void)suggested;
}

static void read_cb(uv_stream_t* s, ssize_t nread, const uv_buf_t* b) {
  conn_t* c = (conn_t*)s;
  (void)b;
  if (nread < 0) {
    uv_close((uv_handle_t*)s, on_close);
    return;
  }
  if (nread == 0) return;
  c->len += (size_t)nread;
  // Count complete requests (…\r\n\r\n), consume them from the buffer.
  int reqs = 0;
  size_t scan = 0;
  char* p;
  while ((p = memmem(c->buf + scan, c->len - scan, "\r\n\r\n", 4)) != NULL) {
    reqs++;
    scan = (size_t)(p - c->buf) + 4;
  }
  if (reqs == 0) {
    if (c->len == sizeof(c->buf)) uv_close((uv_handle_t*)s, on_close);  // oversized
    return;
  }
  // Leftover partial request (if any) shifts to the front.
  memmove(c->buf, c->buf + scan, c->len - scan);
  c->len -= scan;
  // One write carrying `reqs` responses back to back.
  write_req_t* wr = (write_req_t*)malloc(sizeof(write_req_t));
  char* out = (char*)malloc(RESP_LEN * (size_t)reqs);
  for (int i = 0; i < reqs; i++) memcpy(out + i * RESP_LEN, RESP, RESP_LEN);
  wr->buf = uv_buf_init(out, (unsigned)(RESP_LEN * (size_t)reqs));
  uv_write((uv_write_t*)wr, s, &wr->buf, 1, on_write2);
}

static void on_connection(uv_stream_t* server, int status) {
  if (status < 0) return;
  conn_t* c = (conn_t*)malloc(sizeof(conn_t));
  c->len = 0;
  uv_tcp_init(server->loop, &c->handle);
  if (uv_accept(server, (uv_stream_t*)&c->handle) == 0) {
    uv_tcp_nodelay(&c->handle, 1);
    uv_read_start((uv_stream_t*)&c->handle, alloc_cb, read_cb);
  } else {
    uv_close((uv_handle_t*)&c->handle, on_close);
  }
}

static int g_port;

static void* worker(void* arg) {
  (void)arg;
  uv_loop_t loop;
  uv_loop_init(&loop);
  // Own SO_REUSEPORT socket per loop; the kernel load-balances accepts.
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
  setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one));
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_port = htons((uint16_t)g_port);
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (bind(fd, (struct sockaddr*)&addr, sizeof(addr)) != 0) {
    perror("bind");
    return NULL;
  }
  listen(fd, 1024);
  uv_tcp_t* server = (uv_tcp_t*)malloc(sizeof(uv_tcp_t));
  uv_tcp_init(&loop, server);
  uv_tcp_open(server, fd);
  uv_listen((uv_stream_t*)server, 1024, on_connection);
  uv_run(&loop, UV_RUN_DEFAULT);
  return NULL;
}

int main(int argc, char** argv) {
  g_port = argc > 1 ? atoi(argv[1]) : 8100;
  int nthreads = argc > 2 ? atoi(argv[2]) : 4;
  printf("LISTENING %d threads=%d\n", g_port, nthreads);
  fflush(stdout);
  pthread_t th[64];
  for (int i = 0; i < nthreads; i++) pthread_create(&th[i], NULL, worker, NULL);
  for (int i = 0; i < nthreads; i++) pthread_join(th[i], NULL);
  return 0;
}
