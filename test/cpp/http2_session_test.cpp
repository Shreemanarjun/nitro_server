// Self-contained HTTP/2 round-trip: an in-process nghttp2 CLIENT session drives
// the server Http2Session through mem_send2/mem_recv2 byte buffers — no sockets,
// no threads (nghttp2_session is not thread-safe). The whole file is gated on
// NITRO_SERVER_HTTP2, so a default build compiles it to nothing.
#ifdef NITRO_SERVER_HTTP2
#include "Http2Session.h"

#include <gtest/gtest.h>
#include <nghttp2/nghttp2.h>

#include <cstdlib>
#include <chrono>
#include <cstring>
#include <string>
#include <thread>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <utility>
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
    std::string path, query, routePattern, body, clientIp, customMethod;
    int64_t contentLength = -1;
    std::vector<Header> headers;
  };
  struct Job {
    int64_t requestId;
    int status;
    std::string body;
  };

  explicit RecordEmitter(Answer answer) : answer_(answer) {}

  void emitHead(int64_t id, Method method, const std::string& customMethod,
                const std::string& path, const std::string& query,
                const std::vector<Header>& headers, int64_t contentLength,
                bool hasBody, bool bodyComplete, const std::string& routePattern,
                const std::vector<RouteParam>&,
                const std::string& clientIp) override {
    Seen& s = partial_[id];
    s.requestId = id;
    s.method = method;
    s.customMethod = customMethod;
    s.path = path;
    s.query = query;
    s.routePattern = routePattern;
    s.clientIp = clientIp;
    s.contentLength = contentLength;
    s.headers = headers;
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

// Client side: record each response stream's :status, headers, body and
// completion, keyed by stream id so one session can carry concurrent requests.
struct ClientResp {
  int status = 0;
  std::string body;
  bool closed = false;
  std::vector<std::pair<std::string, std::string>> headers;  // non-:status
};
struct ClientState {
  std::unordered_map<int32_t, ClientResp> resp;
  const std::string* reqBody = nullptr;  // POST upload source
  size_t reqOff = 0;
  ClientResp& operator[](int32_t sid) { return resp[sid]; }
};

int clientOnHeader(nghttp2_session*, const nghttp2_frame* frame,
                   const uint8_t* name, size_t namelen, const uint8_t* value,
                   size_t valuelen, uint8_t, void* ud) {
  auto& r = (*static_cast<ClientState*>(ud))[frame->hd.stream_id];
  const std::string_view n(reinterpret_cast<const char*>(name), namelen);
  const std::string_view v(reinterpret_cast<const char*>(value), valuelen);
  if (n == ":status") {
    r.status = std::atoi(std::string(v).c_str());
  } else {
    r.headers.emplace_back(std::string(n), std::string(v));
  }
  return 0;
}
int clientOnData(nghttp2_session*, uint8_t, int32_t streamId,
                 const uint8_t* data, size_t len, void* ud) {
  (*static_cast<ClientState*>(ud))[streamId].body.append(
      reinterpret_cast<const char*>(data), len);
  return 0;
}
int clientOnClose(nghttp2_session*, int32_t streamId, uint32_t, void* ud) {
  (*static_cast<ClientState*>(ud))[streamId].closed = true;
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

Router routerWith2(Method m1, const std::string& p1, Method m2,
                   const std::string& p2) {
  Router r;
  RouteEntry a;
  a.method = m1;
  a.pattern = p1;
  EXPECT_TRUE(r.add(a));
  RouteEntry b;
  b.method = m2;
  b.pattern = p2;
  EXPECT_TRUE(r.add(b));
  return r;
}

// Submit a POST whose body streams from *cs.reqBody, with an explicit nv set so
// a test can add (or omit) content-length. Returns the request stream id.
int32_t submitPost(nghttp2_session* client, ClientState* cs,
                   const nghttp2_nv* nv, size_t nvlen) {
  nghttp2_data_provider dp{};
  dp.source.ptr = cs;
  dp.read_callback = clientReadReq;
  return nghttp2_submit_request(client, nullptr, nv, nvlen, &dp, cs);
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
  const int32_t sid =
      nghttp2_submit_request(client, nullptr, nv, 4, nullptr, &cs);
  ASSERT_GT(sid, 0);

  drive(client, server, fromServer, em, cs);

  ASSERT_EQ(em.seen().size(), 1u);
  EXPECT_EQ(em.seen()[0].method, Method::Get);
  EXPECT_EQ(em.seen()[0].path, "/hello");
  EXPECT_EQ(em.seen()[0].query, "q=1");
  EXPECT_EQ(em.seen()[0].routePattern, "/hello");
  EXPECT_EQ(em.seen()[0].clientIp, "1.2.3.4");
  EXPECT_EQ(cs[sid].status, 200);
  EXPECT_EQ(cs[sid].body, "hello:/hello");
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
  const int32_t sid = nghttp2_submit_request(client, nullptr, nv, 4, &dp, &cs);
  ASSERT_GT(sid, 0);

  drive(client, server, fromServer, em, cs);

  ASSERT_EQ(em.seen().size(), 1u);
  EXPECT_EQ(em.seen()[0].method, Method::Post);
  EXPECT_EQ(em.seen()[0].body, "ping-pong");
  EXPECT_EQ(cs[sid].status, 201);
  EXPECT_EQ(cs[sid].body, "n=9");
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

// --- Body cap (security blocker, now enforced in-unit) ----------------------

TEST(Http2SessionTest, RejectsBodyOverTheCapMidStream) {
  RecordEmitter em([](Method, const std::string&, const std::string& b) {
    return std::make_pair(200, "n=" + std::to_string(b.size()));
  });
  const Router router = routerWith(Method::Post, "/up");
  std::string fromServer;
  Http2Session server(
      &em, router,
      [&](const uint8_t* d, size_t n) {
        fromServer.append(reinterpret_cast<const char*>(d), n);
      },
      "1.2.3.4", /*maxBodyBytes=*/8);

  const std::string reqBody(20, 'z');  // 20 bytes > 8-byte cap, no content-length
  ClientState cs;
  cs.reqBody = &reqBody;
  nghttp2_session* client = makeClient(&cs);
  const nghttp2_nv nv[] = {MAKE_NV(":method", "POST"),
                           MAKE_NV(":scheme", "http"),
                           MAKE_NV(":authority", "x"), MAKE_NV(":path", "/up")};
  const int32_t sid = submitPost(client, &cs, nv, 4);
  ASSERT_GT(sid, 0);

  drive(client, server, fromServer, em, cs);

  EXPECT_TRUE(em.seen().empty());    // handler never ran
  EXPECT_EQ(cs[sid].status, 413);    // client told it was too large
  nghttp2_session_del(client);
}

TEST(Http2SessionTest, RejectsBodyOverDeclaredContentLength) {
  RecordEmitter em([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, std::string("ok"));
  });
  const Router router = routerWith(Method::Post, "/up");
  std::string fromServer;
  Http2Session server(
      &em, router,
      [&](const uint8_t* d, size_t n) {
        fromServer.append(reinterpret_cast<const char*>(d), n);
      },
      "1.2.3.4", /*maxBodyBytes=*/8);

  const std::string reqBody(20, 'z');
  ClientState cs;
  cs.reqBody = &reqBody;
  nghttp2_session* client = makeClient(&cs);
  const nghttp2_nv nv[] = {
      MAKE_NV(":method", "POST"), MAKE_NV(":scheme", "http"),
      MAKE_NV(":authority", "x"), MAKE_NV(":path", "/up"),
      MAKE_NV("content-length", "20")};  // declared > cap: refuse up front
  const int32_t sid = submitPost(client, &cs, nv, 5);
  ASSERT_GT(sid, 0);

  drive(client, server, fromServer, em, cs);

  EXPECT_TRUE(em.seen().empty());
  EXPECT_EQ(cs[sid].status, 413);
  nghttp2_session_del(client);
}

TEST(Http2SessionTest, AllowsBodyUnderTheCap) {
  RecordEmitter em([](Method, const std::string&, const std::string& b) {
    return std::make_pair(200, "n=" + std::to_string(b.size()));
  });
  const Router router = routerWith(Method::Post, "/up");
  std::string fromServer;
  Http2Session server(
      &em, router,
      [&](const uint8_t* d, size_t n) {
        fromServer.append(reinterpret_cast<const char*>(d), n);
      },
      "1.2.3.4", /*maxBodyBytes=*/1000);

  const std::string reqBody = "small";
  ClientState cs;
  cs.reqBody = &reqBody;
  nghttp2_session* client = makeClient(&cs);
  const nghttp2_nv nv[] = {MAKE_NV(":method", "POST"),
                           MAKE_NV(":scheme", "http"),
                           MAKE_NV(":authority", "x"), MAKE_NV(":path", "/up")};
  const int32_t sid = submitPost(client, &cs, nv, 4);
  ASSERT_GT(sid, 0);

  drive(client, server, fromServer, em, cs);

  ASSERT_EQ(em.seen().size(), 1u);
  EXPECT_EQ(em.seen()[0].body, "small");
  EXPECT_EQ(cs[sid].status, 200);
  EXPECT_EQ(cs[sid].body, "n=5");
  nghttp2_session_del(client);
}

// --- Injected id allocator (no cross-connection collision) ------------------

TEST(Http2SessionTest, InjectedIdAllocatorIsUsedAcrossSessions) {
  int64_t counter = 1000;
  Http2Session::IdAllocator shared = [&counter]() { return ++counter; };
  const Router router = routerWith(Method::Get, "/x");

  auto runOne = [&](std::string clientIp) -> int64_t {
    RecordEmitter em([](Method, const std::string&, const std::string&) {
      return std::make_pair(200, std::string("ok"));
    });
    std::string fromServer;
    Http2Session server(
        &em, router,
        [&](const uint8_t* d, size_t n) {
          fromServer.append(reinterpret_cast<const char*>(d), n);
        },
        std::move(clientIp), -1, shared);
    ClientState cs;
    nghttp2_session* client = makeClient(&cs);
    const nghttp2_nv nv[] = {MAKE_NV(":method", "GET"),
                             MAKE_NV(":scheme", "http"),
                             MAKE_NV(":authority", "x"), MAKE_NV(":path", "/x")};
    nghttp2_submit_request(client, nullptr, nv, 4, nullptr, &cs);
    drive(client, server, fromServer, em, cs);
    EXPECT_EQ(em.seen().size(), 1u);
    const int64_t id = em.seen().empty() ? -1 : em.seen()[0].requestId;
    nghttp2_session_del(client);
    return id;
  };

  const int64_t a = runOne("1.1.1.1");
  const int64_t b = runOne("2.2.2.2");
  EXPECT_EQ(a, 1001);  // the shared allocator, not a per-session 1
  EXPECT_EQ(b, 1002);
  EXPECT_NE(a, b);  // no collision across sessions
}

// --- Liveness: respond after stop() is a no-op ------------------------------

TEST(Http2SessionTest, RespondAfterStopIsANoOp) {
  RecordEmitter em([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, std::string("late"));
  });
  const Router router = routerWith(Method::Get, "/x");
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
                           MAKE_NV(":authority", "x"), MAKE_NV(":path", "/x")};
  const int32_t sid =
      nghttp2_submit_request(client, nullptr, nv, 4, nullptr, &cs);
  ASSERT_GT(sid, 0);

  // Feed the request so it is emitted + a job queued, but do not answer yet.
  const uint8_t* out = nullptr;
  for (ssize_t n; (n = nghttp2_session_mem_send(client, &out)) > 0;) {
    server.feed(out, static_cast<size_t>(n));
  }
  ASSERT_EQ(em.seen().size(), 1u);

  server.stop();  // session draining

  RecordEmitter::Job job{};
  ASSERT_TRUE(em.takeJob(job));
  server.respond(job.requestId, 200, {}, "late");  // must be ignored
  EXPECT_FALSE(server.feed(out, 0));                // feed after stop is false

  // Pump anything the client has; it must not have received a response.
  if (!fromServer.empty()) {
    nghttp2_session_mem_recv(
        client, reinterpret_cast<const uint8_t*>(fromServer.data()),
        fromServer.size());
  }
  EXPECT_EQ(cs[sid].status, 0);  // no answer delivered
  nghttp2_session_del(client);
}

// --- Multiplexing: two concurrent streams on one session -------------------

TEST(Http2SessionTest, MultiplexesConcurrentStreams) {
  RecordEmitter em([](Method, const std::string& path, const std::string&) {
    return std::make_pair(200, "ans:" + path);
  });
  const Router router = routerWith2(Method::Get, "/a", Method::Get, "/b");
  std::string fromServer;
  Http2Session server(
      &em, router,
      [&](const uint8_t* d, size_t n) {
        fromServer.append(reinterpret_cast<const char*>(d), n);
      },
      "1.2.3.4");

  ClientState cs;
  nghttp2_session* client = makeClient(&cs);
  const nghttp2_nv nvA[] = {MAKE_NV(":method", "GET"), MAKE_NV(":scheme", "http"),
                            MAKE_NV(":authority", "x"), MAKE_NV(":path", "/a")};
  const nghttp2_nv nvB[] = {MAKE_NV(":method", "GET"), MAKE_NV(":scheme", "http"),
                            MAKE_NV(":authority", "x"), MAKE_NV(":path", "/b")};
  const int32_t sa = nghttp2_submit_request(client, nullptr, nvA, 4, nullptr, &cs);
  const int32_t sb = nghttp2_submit_request(client, nullptr, nvB, 4, nullptr, &cs);
  ASSERT_GT(sa, 0);
  ASSERT_GT(sb, 0);
  ASSERT_NE(sa, sb);

  drive(client, server, fromServer, em, cs);

  EXPECT_EQ(em.seen().size(), 2u);  // both requests dispatched on one connection
  EXPECT_EQ(cs[sa].status, 200);
  EXPECT_EQ(cs[sa].body, "ans:/a");
  EXPECT_EQ(cs[sb].status, 200);
  EXPECT_EQ(cs[sb].body, "ans:/b");
  nghttp2_session_del(client);
}

// --- respond() to an unknown request id is ignored --------------------------

TEST(Http2SessionTest, RespondToUnknownRequestIsIgnored) {
  RecordEmitter em([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, std::string("ok"));
  });
  const Router router = routerWith(Method::Get, "/x");
  std::string fromServer;
  Http2Session server(
      &em, router,
      [&](const uint8_t* d, size_t n) {
        fromServer.append(reinterpret_cast<const char*>(d), n);
      },
      "1.2.3.4");
  server.respond(999999, 200, {}, "nobody");  // no such stream: no crash, no-op
  EXPECT_TRUE(fromServer.empty());
}

// --- Response headers echoed; empty body closes the stream ------------------

TEST(Http2SessionTest, SendsResponseHeadersAndEmptyBody) {
  RecordEmitter em([](Method, const std::string&, const std::string&) {
    return std::make_pair(204, std::string{});  // no body
  });
  const Router router = routerWith(Method::Get, "/x");
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
                           MAKE_NV(":authority", "x"), MAKE_NV(":path", "/x")};
  const int32_t sid =
      nghttp2_submit_request(client, nullptr, nv, 4, nullptr, &cs);
  ASSERT_GT(sid, 0);

  // Drive, answering with a custom header via respond()'s headers argument.
  for (int guard = 0; guard < 1000; ++guard) {
    bool moved = false;
    const uint8_t* out = nullptr;
    for (ssize_t n; (n = nghttp2_session_mem_send(client, &out)) > 0;) {
      server.feed(out, static_cast<size_t>(n));
      moved = true;
    }
    RecordEmitter::Job job{};
    while (em.takeJob(job)) {
      server.respond(job.requestId, job.status, {{"x-custom", "yes"}}, job.body);
      moved = true;
    }
    if (!fromServer.empty()) {
      nghttp2_session_mem_recv(
          client, reinterpret_cast<const uint8_t*>(fromServer.data()),
          fromServer.size());
      fromServer.clear();
      moved = true;
    }
    if (!moved) break;
  }

  EXPECT_EQ(cs[sid].status, 204);
  EXPECT_TRUE(cs[sid].body.empty());
  EXPECT_TRUE(cs[sid].closed);
  bool sawHeader = false;
  for (const auto& h : cs[sid].headers) {
    if (h.first == "x-custom" && h.second == "yes") sawHeader = true;
  }
  EXPECT_TRUE(sawHeader);
  nghttp2_session_del(client);
}

// --- content-length: absent -> unknown (-1), body still delivered -----------
// (A malformed content-length is rejected by nghttp2 itself before our code
// runs, so the `from_chars` guard is defense-in-depth we can't drive through a
// conforming client; the observable, testable contract is the -1 default.)

TEST(Http2SessionTest, AbsentContentLengthIsUnknown) {
  RecordEmitter em([](Method, const std::string&, const std::string& b) {
    return std::make_pair(200, "n=" + std::to_string(b.size()));
  });
  const Router router = routerWith(Method::Post, "/up");
  std::string fromServer;
  Http2Session server(
      &em, router,
      [&](const uint8_t* d, size_t n) {
        fromServer.append(reinterpret_cast<const char*>(d), n);
      },
      "1.2.3.4");

  const std::string reqBody = "hi";  // no content-length header sent
  ClientState cs;
  cs.reqBody = &reqBody;
  nghttp2_session* client = makeClient(&cs);
  const nghttp2_nv nv[] = {MAKE_NV(":method", "POST"),
                           MAKE_NV(":scheme", "http"),
                           MAKE_NV(":authority", "x"), MAKE_NV(":path", "/up")};
  const int32_t sid = submitPost(client, &cs, nv, 4);
  ASSERT_GT(sid, 0);

  drive(client, server, fromServer, em, cs);

  ASSERT_EQ(em.seen().size(), 1u);
  EXPECT_EQ(em.seen()[0].contentLength, -1);  // absent => unknown, not trusted
  EXPECT_EQ(em.seen()[0].body, "hi");
  EXPECT_EQ(cs[sid].status, 200);
  nghttp2_session_del(client);
}

// --- Custom (non-standard) method forwarded verbatim ------------------------

TEST(Http2SessionTest, CustomMethodIsForwarded) {
  RecordEmitter em([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, std::string("ok"));
  });
  Router router;
  RouteEntry e;
  e.method = Method::Custom;
  e.customMethod = "PURGE";
  e.pattern = "/x";
  ASSERT_TRUE(router.add(e));
  std::string fromServer;
  Http2Session server(
      &em, router,
      [&](const uint8_t* d, size_t n) {
        fromServer.append(reinterpret_cast<const char*>(d), n);
      },
      "1.2.3.4");

  ClientState cs;
  nghttp2_session* client = makeClient(&cs);
  const nghttp2_nv nv[] = {MAKE_NV(":method", "PURGE"),
                           MAKE_NV(":scheme", "http"),
                           MAKE_NV(":authority", "x"), MAKE_NV(":path", "/x")};
  const int32_t sid =
      nghttp2_submit_request(client, nullptr, nv, 4, nullptr, &cs);
  ASSERT_GT(sid, 0);

  drive(client, server, fromServer, em, cs);

  ASSERT_EQ(em.seen().size(), 1u);
  EXPECT_EQ(em.seen()[0].method, Method::Custom);
  EXPECT_EQ(em.seen()[0].customMethod, "PURGE");
  EXPECT_EQ(cs[sid].status, 200);
  nghttp2_session_del(client);
}

// --- HEAD carries the headers a GET would but no body (RFC 9110 §9.3.2) -----

TEST(Http2SessionTest, HeadResponseHasNoBody) {
  RecordEmitter em([](Method, const std::string&, const std::string&) {
    return std::make_pair(200, std::string("would-be-body"));  // stripped for HEAD
  });
  const Router router = routerWith(Method::Get, "/x");  // HEAD falls back to GET
  std::string fromServer;
  Http2Session server(
      &em, router,
      [&](const uint8_t* d, size_t n) {
        fromServer.append(reinterpret_cast<const char*>(d), n);
      },
      "1.2.3.4");

  ClientState cs;
  nghttp2_session* client = makeClient(&cs);
  const nghttp2_nv nv[] = {MAKE_NV(":method", "HEAD"), MAKE_NV(":scheme", "http"),
                           MAKE_NV(":authority", "x"), MAKE_NV(":path", "/x")};
  const int32_t sid =
      nghttp2_submit_request(client, nullptr, nv, 4, nullptr, &cs);
  ASSERT_GT(sid, 0);

  drive(client, server, fromServer, em, cs);

  ASSERT_EQ(em.seen().size(), 1u);
  EXPECT_EQ(em.seen()[0].method, Method::Head);
  EXPECT_EQ(em.seen()[0].routePattern, "/x");  // matched the GET route
  EXPECT_EQ(cs[sid].status, 200);
  EXPECT_TRUE(cs[sid].body.empty());  // no body bytes on a HEAD response
  EXPECT_TRUE(cs[sid].closed);
  nghttp2_session_del(client);
}



// ── Production-audit P1: h2 deadlines, per-route caps, admission, 405 ───────

namespace {
// Pump only client->server and server->client bytes, never answering jobs:
// what a handler that has gone quiet looks like to the session.
void driveWithoutAnswering(nghttp2_session* client, Http2Session& server,
                           std::string& fromServer) {
  for (int guard = 0; guard < 1000; ++guard) {
    bool moved = false;
    const uint8_t* out = nullptr;
    for (ssize_t n; (n = nghttp2_session_mem_send(client, &out)) > 0;) {
      EXPECT_TRUE(server.feed(out, static_cast<size_t>(n)));
      moved = true;
    }
    if (!fromServer.empty()) {
      nghttp2_session_mem_recv(client, reinterpret_cast<const uint8_t*>(fromServer.data()),
                               fromServer.size());
      fromServer.clear();
      moved = true;
    }
    if (!moved) return;
  }
}

std::pair<int, std::string> okAnswer(Method, const std::string& p, const std::string&) {
  return {200, "ok:" + p};
}
}  // namespace

TEST(Http2SessionTest, RouteTimeoutAnswers408AndRetiresTheRequest) {
  RecordEmitter em(okAnswer);
  Router r;
  RouteEntry e;
  e.method = Method::Get;
  e.pattern = "/slow";
  e.timeoutMs = 30;
  ASSERT_TRUE(r.add(e));
  std::string fromServer;
  Http2Session server(&em, r, [&](const uint8_t* d, size_t n) {
    fromServer.append(reinterpret_cast<const char*>(d), n);
  }, "127.0.0.1", -1, {}, /*defaultTimeoutMs=*/5000);
  ClientState cs;
  nghttp2_session* client = makeClient(&cs);
  const nghttp2_nv nv[] = {MAKE_NV(":method", "GET"), MAKE_NV(":scheme", "http"),
                           MAKE_NV(":authority", "x"), MAKE_NV(":path", "/slow")};
  const int32_t sid = nghttp2_submit_request(client, nullptr, nv, 4, nullptr, &cs);
  driveWithoutAnswering(client, server, fromServer);
  ASSERT_EQ(em.seen().size(), 1u);  // dispatched, handler never answers
  // Before the deadline: nothing expires.
  EXPECT_TRUE(server.sweep(Http2Session::Clock::now(), 0).empty());
  std::this_thread::sleep_for(std::chrono::milliseconds(60));
  const std::vector<int64_t> expired = server.sweep(Http2Session::Clock::now(), 0);
  ASSERT_EQ(expired.size(), 1u);
  EXPECT_EQ(expired[0], em.seen()[0].requestId);
  driveWithoutAnswering(client, server, fromServer);
  EXPECT_EQ(cs[sid].status, 408);
  EXPECT_TRUE(cs[sid].closed);
  // The late answer is a no-op (the id was retired).
  RecordEmitter::Job job{};
  ASSERT_TRUE(em.takeJob(job));
  server.respond(job.requestId, 200, {}, "late");
  driveWithoutAnswering(client, server, fromServer);
  EXPECT_EQ(cs[sid].status, 408);
  nghttp2_session_del(client);
}

TEST(Http2SessionTest, DefaultTimeoutAppliesToRoutesWithoutTheirOwn) {
  RecordEmitter em(okAnswer);
  const Router r = routerWith(Method::Get, "/x");
  std::string fromServer;
  Http2Session server(&em, r, [&](const uint8_t* d, size_t n) {
    fromServer.append(reinterpret_cast<const char*>(d), n);
  }, "127.0.0.1", -1, {}, /*defaultTimeoutMs=*/20);
  ClientState cs;
  nghttp2_session* client = makeClient(&cs);
  const nghttp2_nv nv[] = {MAKE_NV(":method", "GET"), MAKE_NV(":scheme", "http"),
                           MAKE_NV(":authority", "x"), MAKE_NV(":path", "/x")};
  const int32_t sid = nghttp2_submit_request(client, nullptr, nv, 4, nullptr, &cs);
  driveWithoutAnswering(client, server, fromServer);
  std::this_thread::sleep_for(std::chrono::milliseconds(40));
  EXPECT_EQ(server.sweep(Http2Session::Clock::now(), 0).size(), 1u);
  driveWithoutAnswering(client, server, fromServer);
  EXPECT_EQ(cs[sid].status, 408);
  nghttp2_session_del(client);
}

TEST(Http2SessionTest, BodyStallIs408BeforeDispatch) {
  RecordEmitter em(okAnswer);
  const Router r = routerWith(Method::Post, "/up");
  std::string fromServer;
  Http2Session server(&em, r, [&](const uint8_t* d, size_t n) {
    fromServer.append(reinterpret_cast<const char*>(d), n);
  }, "127.0.0.1");
  ClientState cs;
  nghttp2_session* client = makeClient(&cs);
  // A POST whose body never arrives: HEADERS without END_STREAM, no DATA.
  const nghttp2_nv nv[] = {MAKE_NV(":method", "POST"), MAKE_NV(":scheme", "http"),
                           MAKE_NV(":authority", "x"), MAKE_NV(":path", "/up"),
                           MAKE_NV("content-length", "100")};
  const std::string never;  // never read: the provider is only consulted if asked
  cs.reqBody = &never;
  nghttp2_data_provider dp{};
  dp.source.ptr = &cs;
  dp.read_callback = [](nghttp2_session*, int32_t, uint8_t*, size_t, uint32_t*,
                        nghttp2_data_source*, void*) -> ssize_t {
    return NGHTTP2_ERR_DEFERRED;  // the upload stalls
  };
  const int32_t sid = nghttp2_submit_request(client, nullptr, nv, 5, &dp, &cs);
  driveWithoutAnswering(client, server, fromServer);
  EXPECT_TRUE(em.seen().empty());
  std::this_thread::sleep_for(std::chrono::milliseconds(30));
  EXPECT_TRUE(server.sweep(Http2Session::Clock::now(), /*bodyStallMs=*/20).empty());
  driveWithoutAnswering(client, server, fromServer);
  EXPECT_EQ(cs[sid].status, 408);
  EXPECT_TRUE(em.seen().empty());  // never dispatched
  nghttp2_session_del(client);
}

TEST(Http2SessionTest, PerRouteBodyCapOverridesTheSessionCap) {
  RecordEmitter em(okAnswer);
  Router r;
  RouteEntry e;
  e.method = Method::Post;
  e.pattern = "/small";
  e.maxBodyBytes = 4;
  ASSERT_TRUE(r.add(e));
  RouteEntry big;
  big.method = Method::Post;
  big.pattern = "/big";
  big.maxBodyBytes = 1 << 20;
  ASSERT_TRUE(r.add(big));
  std::string fromServer;
  Http2Session server(&em, r, [&](const uint8_t* d, size_t n) {
    fromServer.append(reinterpret_cast<const char*>(d), n);
  }, "127.0.0.1", /*maxBodyBytes=*/16);
  ClientState cs;
  nghttp2_session* client = makeClient(&cs);
  const std::string body = "0123456789";  // 10 bytes: under 16, over 4
  cs.reqBody = &body;
  const nghttp2_nv small[] = {MAKE_NV(":method", "POST"), MAKE_NV(":scheme", "http"),
                              MAKE_NV(":authority", "x"), MAKE_NV(":path", "/small")};
  const int32_t s1 = submitPost(client, &cs, small, 4);
  drive(client, server, fromServer, em, cs);
  EXPECT_EQ(cs[s1].status, 413);  // the route's own cap wins
  cs.reqOff = 0;
  const nghttp2_nv large[] = {MAKE_NV(":method", "POST"), MAKE_NV(":scheme", "http"),
                              MAKE_NV(":authority", "x"), MAKE_NV(":path", "/big")};
  const int32_t s2 = submitPost(client, &cs, large, 4);
  drive(client, server, fromServer, em, cs);
  EXPECT_EQ(cs[s2].status, 200);  // a route may raise the cap too
  nghttp2_session_del(client);
}

TEST(Http2SessionTest, AdmissionFalseIs503WithoutDispatch) {
  RecordEmitter em(okAnswer);
  const Router r = routerWith(Method::Get, "/x");
  std::string fromServer;
  bool admit = false;
  Http2Session server(&em, r, [&](const uint8_t* d, size_t n) {
    fromServer.append(reinterpret_cast<const char*>(d), n);
  }, "127.0.0.1", -1, {}, 0, [&]() { return admit; });
  ClientState cs;
  nghttp2_session* client = makeClient(&cs);
  const nghttp2_nv nv[] = {MAKE_NV(":method", "GET"), MAKE_NV(":scheme", "http"),
                           MAKE_NV(":authority", "x"), MAKE_NV(":path", "/x")};
  const int32_t s1 = nghttp2_submit_request(client, nullptr, nv, 4, nullptr, &cs);
  drive(client, server, fromServer, em, cs);
  EXPECT_EQ(cs[s1].status, 503);
  bool retry = false;
  for (const auto& h : cs[s1].headers)
    if (h.first == "retry-after" && h.second == "1") retry = true;
  EXPECT_TRUE(retry);
  EXPECT_TRUE(em.seen().empty());
  admit = true;
  const int32_t s2 = nghttp2_submit_request(client, nullptr, nv, 4, nullptr, &cs);
  drive(client, server, fromServer, em, cs);
  EXPECT_EQ(cs[s2].status, 200);
  nghttp2_session_del(client);
}

TEST(Http2SessionTest, MethodMismatchIs405WithAllow) {
  RecordEmitter em(okAnswer);
  const Router r = routerWith2(Method::Get, "/x", Method::Put, "/x");
  std::string fromServer;
  Http2Session server(&em, r, [&](const uint8_t* d, size_t n) {
    fromServer.append(reinterpret_cast<const char*>(d), n);
  }, "127.0.0.1");
  ClientState cs;
  nghttp2_session* client = makeClient(&cs);
  const nghttp2_nv nv[] = {MAKE_NV(":method", "DELETE"), MAKE_NV(":scheme", "http"),
                           MAKE_NV(":authority", "x"), MAKE_NV(":path", "/x")};
  const int32_t sid = nghttp2_submit_request(client, nullptr, nv, 4, nullptr, &cs);
  drive(client, server, fromServer, em, cs);
  EXPECT_EQ(cs[sid].status, 405);
  std::string allow;
  for (const auto& h : cs[sid].headers)
    if (h.first == "allow") allow = h.second;
  EXPECT_EQ(allow, "GET, HEAD, PUT");
  EXPECT_TRUE(em.seen().empty());
  // An unregistered path still reaches the runner (its not-found handler).
  const nghttp2_nv miss[] = {MAKE_NV(":method", "GET"), MAKE_NV(":scheme", "http"),
                             MAKE_NV(":authority", "x"), MAKE_NV(":path", "/nope")};
  nghttp2_submit_request(client, nullptr, miss, 4, nullptr, &cs);
  drive(client, server, fromServer, em, cs);
  EXPECT_EQ(em.seen().size(), 1u);
  EXPECT_EQ(em.seen()[0].routePattern, "");
  nghttp2_session_del(client);
}

TEST(Http2SessionTest, GoawayIsIdempotentAndFinishesWhenQuiet) {
  RecordEmitter em(okAnswer);
  const Router r = routerWith(Method::Get, "/x");
  std::string fromServer;
  Http2Session server(&em, r, [&](const uint8_t* d, size_t n) {
    fromServer.append(reinterpret_cast<const char*>(d), n);
  }, "127.0.0.1");
  ClientState cs;
  nghttp2_session* client = makeClient(&cs);
  const nghttp2_nv nv[] = {MAKE_NV(":method", "GET"), MAKE_NV(":scheme", "http"),
                           MAKE_NV(":authority", "x"), MAKE_NV(":path", "/x")};
  const int32_t sid = nghttp2_submit_request(client, nullptr, nv, 4, nullptr, &cs);
  drive(client, server, fromServer, em, cs);
  EXPECT_EQ(cs[sid].status, 200);
  EXPECT_FALSE(server.goAwaySent());
  server.goAway();
  server.goAway();  // idempotent
  EXPECT_TRUE(server.goAwaySent());
  drive(client, server, fromServer, em, cs);
  // No open streams after GOAWAY: the session is finished.
  EXPECT_FALSE(server.hasOpenStreams());
  EXPECT_FALSE(server.wantRead());
  EXPECT_FALSE(server.wantWrite());
  nghttp2_session_del(client);
}
// --- Second re-audit: a session-wide request-body budget --------------------

static Http2Session budgeted(RecordEmitter& em, const Router& r,
                             std::string& fromServer, int64_t maxBody,
                             int64_t budget) {
  return Http2Session(
      &em, r,
      [&fromServer](const uint8_t* d, size_t n) {
        fromServer.append(reinterpret_cast<const char*>(d), n);
      },
      "1.2.3.4", maxBody, {}, 0, {}, budget);
}

TEST(Http2SessionTest, BodyBudgetRefusesAStreamOverTheRemainder) {
  RecordEmitter em([](Method, const std::string&, const std::string& b) {
    return std::make_pair(200, "n=" + std::to_string(b.size()));
  });
  const Router router = routerWith(Method::Post, "/up");
  std::string fromServer;
  Http2Session server = budgeted(em, router, fromServer, /*maxBody=*/1000,
                                 /*budget=*/100);
  const std::string reqBody(60, 'z');
  ClientState cs;
  cs.reqBody = &reqBody;
  nghttp2_session* client = makeClient(&cs);
  const nghttp2_nv nv[] = {
      MAKE_NV(":method", "POST"), MAKE_NV(":scheme", "http"),
      MAKE_NV(":authority", "x"), MAKE_NV(":path", "/up"),
      MAKE_NV("content-length", "60")};
  // Two 60-byte uploads at once: 120 > 100, so the second is refused with
  // 503 + retry-after while the first is still open.
  const int32_t s1 = submitPost(client, &cs, nv, 5);
  const int32_t s2 = submitPost(client, &cs, nv, 5);
  ASSERT_GT(s1, 0);
  ASSERT_GT(s2, 0);
  drive(client, server, fromServer, em, cs);
  EXPECT_EQ(cs[s1].status, 200);
  EXPECT_EQ(cs[s1].body, "n=60");
  EXPECT_EQ(cs[s2].status, 503);
  bool retry = false;
  for (const auto& h : cs[s2].headers)
    if (h.first == "retry-after" && h.second == "1") retry = true;
  EXPECT_TRUE(retry);
  ASSERT_EQ(em.seen().size(), 1u);
  // Both streams are closed: the budget is whole again, a third upload fits.
  cs.reqOff = 0;  // the harness shares one upload cursor across streams
  const int32_t s3 = submitPost(client, &cs, nv, 5);
  drive(client, server, fromServer, em, cs);
  EXPECT_EQ(cs[s3].status, 200);
  EXPECT_EQ(em.seen().size(), 2u);
  nghttp2_session_del(client);
}

TEST(Http2SessionTest, BodyBudgetRefuses413WhatCanNeverFit) {
  RecordEmitter em(okAnswer);
  const Router router = routerWith(Method::Post, "/up");
  std::string fromServer;
  Http2Session server = budgeted(em, router, fromServer, /*maxBody=*/1000,
                                 /*budget=*/100);
  ClientState cs;
  const std::string reqBody(10, 'z');
  cs.reqBody = &reqBody;
  nghttp2_session* client = makeClient(&cs);
  // Declared larger than the whole budget: 413 up front, nothing buffered.
  const nghttp2_nv big[] = {
      MAKE_NV(":method", "POST"), MAKE_NV(":scheme", "http"),
      MAKE_NV(":authority", "x"), MAKE_NV(":path", "/up"),
      MAKE_NV("content-length", "200")};
  const int32_t s1 = submitPost(client, &cs, big, 5);
  drive(client, server, fromServer, em, cs);
  EXPECT_EQ(cs[s1].status, 413);
  // Undeclared length reserves the body cap (1000 > 100): also 413 — the
  // budget must be at least the cap for such a route to accept uploads.
  cs.reqOff = 0;
  const nghttp2_nv undeclared[] = {
      MAKE_NV(":method", "POST"), MAKE_NV(":scheme", "http"),
      MAKE_NV(":authority", "x"), MAKE_NV(":path", "/up")};
  const int32_t s2 = submitPost(client, &cs, undeclared, 4);
  drive(client, server, fromServer, em, cs);
  EXPECT_EQ(cs[s2].status, 413);
  // A bodyless request reserves nothing and is unaffected.
  const Router getRouter = routerWith(Method::Get, "/x");
  std::string fs2;
  Http2Session getServer = budgeted(em, getRouter, fs2, 1000, 100);
  ClientState cs2;
  nghttp2_session* c2 = makeClient(&cs2);
  const nghttp2_nv nv[] = {MAKE_NV(":method", "GET"), MAKE_NV(":scheme", "http"),
                           MAKE_NV(":authority", "x"), MAKE_NV(":path", "/x")};
  const int32_t g = nghttp2_submit_request(c2, nullptr, nv, 4, nullptr, &cs2);
  drive(c2, getServer, fs2, em, cs2);
  EXPECT_EQ(cs2[g].status, 200);
  EXPECT_TRUE(em.seen().empty() || em.seen().size() == 1u);
  nghttp2_session_del(client);
  nghttp2_session_del(c2);
}
#endif  // NITRO_SERVER_HTTP2
