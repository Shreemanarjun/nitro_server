// Self-contained HTTP/2 round-trip: an in-process nghttp2 CLIENT session drives
// the server Http2Session through mem_send2/mem_recv2 byte buffers — no sockets,
// no threads (nghttp2_session is not thread-safe). The whole file is gated on
// NITRO_SERVER_HTTP2, so a default build compiles it to nothing.
#ifdef NITRO_SERVER_HTTP2
#include "Http2Session.h"

#include <gtest/gtest.h>
#include <nghttp2/nghttp2.h>

#include <cstdlib>
#include <cstring>
#include <string>
#include <unordered_set>
#include <vector>

#include "Common.h"
#include "EngineTypes.h"
#include "Router.h"

// v1 (ssize_t) nghttp2 API for cross-version portability (see Http2Session.cpp);
// 1.69+ marks it deprecated, so silence that warning for this test TU.
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"

using namespace nitroserver;

namespace {

#define MAKE_NV(NAME, VALUE)                                                 \
  {                                                                          \
    (uint8_t*)(NAME), (uint8_t*)(VALUE), sizeof(NAME) - 1, sizeof(VALUE) - 1, \
        NGHTTP2_NV_FLAG_NONE                                                 \
  }

// Minimal recording Emitter: captures one request's head + body and produces an
// answer the drive loop feeds back through Http2Session::respond. Malloc-owned
// payloads (emitBodyData/Error/WsMessage) are freed here, honoring the transfer
// contract in EngineTypes.h.
class RecordEmitter : public Emitter {
 public:
  using Answer = std::pair<int, std::string> (*)(Method, const std::string& path,
                                                 const std::string& body);
  struct Seen {
    int64_t requestId = 0;
    Method method = Method::Get;
    std::string path, query, routePattern, body, clientIp;
  };
  struct Job {
    int64_t requestId;
    int status;
    std::string body;
  };

  explicit RecordEmitter(Answer answer) : answer_(answer) {}

  void emitHead(int64_t id, Method method, const std::string&,
                const std::string& path, const std::string& query,
                const std::vector<Header>&, int64_t, bool hasBody,
                bool bodyComplete, const std::string& routePattern,
                const std::vector<RouteParam>&,
                const std::string& clientIp) override {
    Seen& s = partial_[id];
    s.requestId = id;
    s.method = method;
    s.path = path;
    s.query = query;
    s.routePattern = routePattern;
    s.clientIp = clientIp;
    // Mirror the Dart runner (server_runner _onHead): dispatch the instant the
    // head reports the body complete. If the session wrongly sends
    // bodyComplete=true for a POST, this finalizes with an EMPTY body and the
    // later emitBodyData is dropped — so the body assertion fails. That is the
    // regression guard for the bodyComplete contract.
    if (!hasBody || bodyComplete) finalize(id);
  }
  void emitBodyData(int64_t id, uint8_t* payload, size_t n) override {
    if (!completed_.count(id)) {
      partial_[id].body.append(reinterpret_cast<const char*>(payload), n);
    }
    std::free(payload);
  }
  void emitBodyEnd(int64_t id) override {
    if (!completed_.count(id)) finalize(id);
  }
  void emitBodyError(int64_t, uint8_t* payload, size_t, ErrorKind) override {
    std::free(payload);
  }
  void emitWsMessage(int64_t, uint8_t* payload, size_t, int, int) override {
    std::free(payload);
  }
  void emitEvent(ServerEventKind, int64_t, const std::string&) override {}

  const std::vector<Seen>& seen() const { return seen_; }
  bool takeJob(Job& out) {
    if (jobs_.empty()) return false;
    out = jobs_.front();
    jobs_.erase(jobs_.begin());
    return true;
  }

 private:
  void finalize(int64_t id) {
    auto it = partial_.find(id);
    if (it == partial_.end()) return;
    Seen s = it->second;
    partial_.erase(it);
    completed_.insert(id);
    auto [status, body] = answer_(s.method, s.path, s.body);
    jobs_.push_back({id, status, body});
    seen_.push_back(std::move(s));
  }

  Answer answer_;
  std::unordered_map<int64_t, Seen> partial_;
  std::unordered_set<int64_t> completed_;
  std::vector<Seen> seen_;
  std::vector<Job> jobs_;
};

// Client side: record the response :status + body and stream completion.
struct ClientState {
  int status = 0;
  std::string body;
  bool closed = false;
  const std::string* reqBody = nullptr;  // POST upload source
  size_t reqOff = 0;
};

int clientOnHeader(nghttp2_session*, const nghttp2_frame*, const uint8_t* name,
                   size_t namelen, const uint8_t* value, size_t valuelen,
                   uint8_t, void* ud) {
  if (namelen == 7 && std::memcmp(name, ":status", 7) == 0) {
    static_cast<ClientState*>(ud)->status =
        std::atoi(std::string(reinterpret_cast<const char*>(value), valuelen)
                      .c_str());
  }
  return 0;
}
int clientOnData(nghttp2_session*, uint8_t, int32_t, const uint8_t* data,
                 size_t len, void* ud) {
  static_cast<ClientState*>(ud)->body.append(
      reinterpret_cast<const char*>(data), len);
  return 0;
}
int clientOnClose(nghttp2_session*, int32_t, uint32_t, void* ud) {
  static_cast<ClientState*>(ud)->closed = true;
  return 0;
}
ssize_t clientReadReq(nghttp2_session*, int32_t, uint8_t* buf, size_t len,
                            uint32_t* flags, nghttp2_data_source* src, void*) {
  auto* c = static_cast<ClientState*>(src->ptr);
  const size_t n = std::min(len, c->reqBody->size() - c->reqOff);
  std::memcpy(buf, c->reqBody->data() + c->reqOff, n);
  c->reqOff += n;
  if (c->reqOff == c->reqBody->size()) *flags |= NGHTTP2_DATA_FLAG_EOF;
  return static_cast<ssize_t>(n);
}

nghttp2_session* makeClient(ClientState* st) {
  nghttp2_session_callbacks* cbs = nullptr;
  nghttp2_session_callbacks_new(&cbs);
  nghttp2_session_callbacks_set_on_header_callback(cbs, clientOnHeader);
  nghttp2_session_callbacks_set_on_data_chunk_recv_callback(cbs, clientOnData);
  nghttp2_session_callbacks_set_on_stream_close_callback(cbs, clientOnClose);
  nghttp2_session* s = nullptr;
  EXPECT_EQ(nghttp2_session_client_new(&s, cbs, st), 0);
  nghttp2_session_callbacks_del(cbs);
  // The client connection preface is the 24-byte magic followed by a mandatory
  // SETTINGS frame; without it the server rejects the request as a protocol error.
  const nghttp2_settings_entry iv[] = {
      {NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE, 65535}};
  nghttp2_submit_settings(s, NGHTTP2_FLAG_NONE, iv, 1);
  return s;
}

// Pump client<->server until both are quiescent. A 1000-round guard turns a
// non-converging bug into a FAIL rather than a hang.
void drive(nghttp2_session* client, Http2Session& server,
           std::string& fromServer, RecordEmitter& em, ClientState& cs) {
  for (int guard = 0; guard < 1000; ++guard) {
    bool moved = false;
    const uint8_t* out = nullptr;
    for (ssize_t n; (n = nghttp2_session_mem_send(client, &out)) > 0;) {
      EXPECT_TRUE(server.feed(out, static_cast<size_t>(n)));
      moved = true;
    }
    RecordEmitter::Job job{};
    while (em.takeJob(job)) {
      server.respond(job.requestId, job.status,
                     {{"content-type", "text/plain"}}, job.body);
      moved = true;
    }
    if (!fromServer.empty()) {
      const ssize_t r = nghttp2_session_mem_recv(
          client, reinterpret_cast<const uint8_t*>(fromServer.data()),
          fromServer.size());
      EXPECT_EQ(r, static_cast<ssize_t>(fromServer.size()));
      fromServer.clear();
      moved = true;
    }
    if (!moved) return;  // nothing left to exchange
  }
  FAIL() << "drive loop did not quiesce";
}

Router routerWith(Method method, const std::string& pattern) {
  Router r;
  RouteEntry e;
  e.method = method;
  e.pattern = pattern;
  EXPECT_TRUE(r.add(e));
  return r;
}

}  // namespace

TEST(Http2SessionTest, ServesAGet) {
  RecordEmitter em([](Method, const std::string& path, const std::string&) {
    return std::make_pair(200, std::string("hello:") + path);
  });
  const Router router = routerWith(Method::Get, "/hello");
  std::string fromServer;
  Http2Session server(
      &em, router,
      [&](const uint8_t* d, size_t n) {
        fromServer.append(reinterpret_cast<const char*>(d), n);
      },
      "1.2.3.4");

  ClientState cs;
  nghttp2_session* client = makeClient(&cs);
  const nghttp2_nv nv[] = {MAKE_NV(":method", "GET"), MAKE_NV(":scheme", "http"),
                           MAKE_NV(":authority", "x"),
                           MAKE_NV(":path", "/hello?q=1")};
  ASSERT_GT(nghttp2_submit_request(client, nullptr, nv, 4, nullptr, &cs), 0);

  drive(client, server, fromServer, em, cs);

  ASSERT_EQ(em.seen().size(), 1u);
  EXPECT_EQ(em.seen()[0].method, Method::Get);
  EXPECT_EQ(em.seen()[0].path, "/hello");
  EXPECT_EQ(em.seen()[0].query, "q=1");
  EXPECT_EQ(em.seen()[0].routePattern, "/hello");
  EXPECT_EQ(em.seen()[0].clientIp, "1.2.3.4");
  EXPECT_EQ(cs.status, 200);
  EXPECT_EQ(cs.body, "hello:/hello");
  nghttp2_session_del(client);
}

TEST(Http2SessionTest, StreamsAPostBodyToTheEmitter) {
  RecordEmitter em([](Method, const std::string&, const std::string& body) {
    return std::make_pair(201, "n=" + std::to_string(body.size()));
  });
  const Router router = routerWith(Method::Post, "/echo");
  std::string fromServer;
  Http2Session server(
      &em, router,
      [&](const uint8_t* d, size_t n) {
        fromServer.append(reinterpret_cast<const char*>(d), n);
      },
      "9.9.9.9");

  const std::string reqBody = "ping-pong";  // must outlive the drive loop
  ClientState cs;
  cs.reqBody = &reqBody;
  nghttp2_session* client = makeClient(&cs);
  const nghttp2_nv nv[] = {MAKE_NV(":method", "POST"),
                           MAKE_NV(":scheme", "http"),
                           MAKE_NV(":authority", "x"), MAKE_NV(":path", "/echo")};
  nghttp2_data_provider dp{};
  dp.source.ptr = &cs;
  dp.read_callback = clientReadReq;
  ASSERT_GT(nghttp2_submit_request(client, nullptr, nv, 4, &dp, &cs), 0);

  drive(client, server, fromServer, em, cs);

  ASSERT_EQ(em.seen().size(), 1u);
  EXPECT_EQ(em.seen()[0].method, Method::Post);
  EXPECT_EQ(em.seen()[0].body, "ping-pong");
  EXPECT_EQ(cs.status, 201);
  EXPECT_EQ(cs.body, "n=9");
  nghttp2_session_del(client);
}

// Adversarial-review guard (N1): a response larger than the flow-control window
// is left deferred in nghttp2; a peer RST_STREAM then closes the stream while the
// data provider still references the per-stream state. Freeing that state in
// on_stream_close is the idiomatic nghttp2 pattern — this proves it is not a UAF
// (run under ASan). Also exercises the deferred-body path the other tests skip.
TEST(Http2SessionTest, ResetMidResponseIsCleanUnderAsan) {
  RecordEmitter em([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, std::string(100000, 'x'));  // >> the 64KiB window
  });
  const Router router = routerWith(Method::Get, "/big");
  std::string fromServer;
  Http2Session server(
      &em, router,
      [&](const uint8_t* d, size_t n) {
        fromServer.append(reinterpret_cast<const char*>(d), n);
      },
      "1.2.3.4");

  ClientState cs;
  nghttp2_session* client = makeClient(&cs);
  const nghttp2_nv nv[] = {MAKE_NV(":method", "GET"), MAKE_NV(":scheme", "http"),
                           MAKE_NV(":authority", "x"), MAKE_NV(":path", "/big")};
  const int32_t sid =
      nghttp2_submit_request(client, nullptr, nv, 4, nullptr, &cs);
  ASSERT_GT(sid, 0);

  const uint8_t* out = nullptr;
  // Round 1: request in, response out — the body partially flushes, the rest
  // stays deferred server-side (window-limited).
  for (ssize_t n; (n = nghttp2_session_mem_send(client, &out)) > 0;) {
    ASSERT_TRUE(server.feed(out, static_cast<size_t>(n)));
  }
  RecordEmitter::Job job{};
  while (em.takeJob(job)) {
    server.respond(job.requestId, job.status, {{"content-type", "text/plain"}},
                   job.body);
  }
  ASSERT_EQ(em.seen().size(), 1u);  // request dispatched
  // The client cancels the stream while the server still holds a deferred body.
  ASSERT_EQ(
      nghttp2_submit_rst_stream(client, NGHTTP2_FLAG_NONE, sid, NGHTTP2_CANCEL),
      0);
  // Pump a few more rounds: the RST reaches the server and frees the stream
  // while its data provider is outstanding. A UAF would trip ASan here.
  for (int i = 0; i < 20; ++i) {
    for (ssize_t n; (n = nghttp2_session_mem_send(client, &out)) > 0;) {
      server.feed(out, static_cast<size_t>(n));
    }
    if (!fromServer.empty()) {
      nghttp2_session_mem_recv(
          client, reinterpret_cast<const uint8_t*>(fromServer.data()),
          fromServer.size());
      fromServer.clear();
    }
  }
  nghttp2_session_del(client);  // reached here = no UAF/abort
}

#endif  // NITRO_SERVER_HTTP2
