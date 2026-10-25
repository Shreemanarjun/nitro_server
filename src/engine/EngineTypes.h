// ─────────────────────────────────────────────────────────────────────────────
// EngineTypes — transport-independent engine types shared by the reactor, the
// bridge and the parser: the bound-server config, the fallible-call result, a
// parsed request head, and the dispatch sink (Emitter). These outlived the
// thread-per-connection ServerInstance that once housed them.
// ─────────────────────────────────────────────────────────────────────────────
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "Common.h"

namespace nitroserver {

struct ServerConfig {
  std::string host = "127.0.0.1";
  int64_t port = 0;
  int64_t backlog = 128;
  int64_t maxBodyBytes = 10 * 1024 * 1024;
  int64_t defaultTimeoutMs = 30000;
  int64_t keepAliveTimeoutMs = 5000;
  // Write `Keep-Alive: timeout=N` next to `Connection: keep-alive` (RFC 9112
  // makes it optional; HTTP/1.1 connections persist without it).
  bool keepAliveHeader = true;
  int64_t maxRequestsPerConn = 100;
  /// libuv event-loop count / worker cap (engine-specific). `<= 0`: auto.
  int64_t workerThreads = 0;
  int64_t maxConnections = 0;       // <= 0: unlimited.
  int64_t maxConnectionsPerIp = 0;  // <= 0: unlimited.
  int64_t headerTimeoutMs = 0;      // <= 0: the idle timeout applies.
  int64_t writeTimeoutMs = 30000;   // <= 0: 30 s.
  int64_t wsMaxBufferBytes = 1 << 20;  // <= 0: 1 MiB.
  // Unsent bytes a streaming response (SSE / chunked) may queue before the
  // connection is dropped (a reader that fell behind). <= 0: unlimited.
  int64_t streamMaxBufferBytes = 4 << 20;
  // A streaming response with no chunk written for this long (and nothing
  // queued) is closed: the handler stopped feeding it. <= 0: never.
  int64_t streamIdleTimeoutMs = 300000;
  // Request-body bytes one HTTP/2 session may hold across its streams at
  // once (a stream reserves its declared Content-Length, else its body cap;
  // over the budget a new stream is answered 503). <= 0: unlimited.
  int64_t maxBufferedBodyBytes = 64 << 20;
  bool wsCompression = true;
  // Stall window for a request body in progress (head parsed, bytes still
  // arriving, refreshed on every read): 408 + close past it. <= 0: the
  // keep-alive idle timeout applies.
  int64_t bodyTimeoutMs = 0;
  // WebSocket liveness: a session quiet for half this is pinged; one quiet for
  // all of it (no pong, no frame) is closed 1001. <= 0: off.
  int64_t wsIdleTimeoutMs = 60000;
  // Hard lifetime of any connection: past it an idle one is closed, a busy
  // HTTP/1.1 one closes after its answer, a WebSocket is closed 1001 and an
  // h2 session gets GOAWAY. <= 0: unbounded.
  int64_t maxConnectionAgeMs = 0;
  // Requests dispatched and not yet answered, across every connection and
  // protocol; a request past the budget is answered 503 (Retry-After: 1)
  // without reaching a handler. <= 0: unlimited.
  int64_t maxInFlightRequests = 0;
  // Negotiate HTTP/2 (ALPN `h2` over TLS, and the h2c prior-knowledge preface)
  // when the engine was built with it. Default on; a server can turn it off to
  // force HTTP/1.1 without rebuilding. Ignored in a non-HTTP/2 build.
  bool http2 = true;
  bool tlsRequested = false;
  // TLS identity (see RawTlsConfig). PEM strings win over file paths.
  std::string tlsCertPem;
  std::string tlsKeyPem;
  std::string tlsCertFile;
  std::string tlsKeyFile;
  // TLS policy (applies whenever tlsRequested): lowest protocol version
  // accepted (12 or 13), an OpenSSL cipher list for TLS 1.2 and cipher suites
  // for TLS 1.3 (empty: library defaults), and client-certificate trust
  // anchors — set either and every handshake must present a certificate
  // chaining to them (mutual TLS); a connection without one is refused.
  int64_t tlsMinVersion = 12;
  std::string tlsCiphers;
  std::string tlsCipherSuites;
  std::string tlsClientCaPem;
  std::string tlsClientCaFile;
  // HAProxy PROXY protocol (v1 text / v2 binary) expected first on every
  // accepted connection: the address it names replaces the socket peer as the
  // client address (handlers, rate limits, logs); a connection that does not
  // start with a valid header is closed. For a listener reachable only through
  // the proxy that sends it.
  bool proxyProtocol = false;
};

struct StatusResult {
  ErrorKind kind = ErrorKind::None;
  std::string message;
  int64_t boundPort = 0;
};

/// One parsed request head. Views never escape the parse (see WsCodec): the
/// fields that outlive it are owning strings.
struct ParsedHead {
  Method method = Method::Get;
  std::string customMethod;
  std::string target;
  std::string version;
  std::vector<Header> headers;
  bool ok = false;
  // Request line names an HTTP version this server does not speak (answer
  // 505 rather than 400).
  bool badVersion = false;
};

/// Parses one request head; `headEnd` is the offset of its `\r\n\r\n`.
/// Exposed for the fuzz target; the engine calls the same parser.
ParsedHead parseRequestHead(const std::string& raw, size_t headEnd);

/// Sink for request dispatch. Production code posts into the Nitro streams;
/// tests record calls. Payloads passed to emitBodyData are malloc-owned and
/// transfer to the sink, which must have tracked them first.
class Emitter {
 public:
  virtual ~Emitter() = default;
  virtual void emitHead(int64_t requestId, Method method,
                        const std::string& customMethod, const std::string& path,
                        const std::string& query,
                        const std::vector<Header>& headers,
                        int64_t contentLength, bool hasBody, bool bodyComplete,
                        const std::string& routePattern,
                        const std::vector<RouteParam>& params,
                        const std::string& clientIp) = 0;
  virtual void emitBodyData(int64_t requestId, uint8_t* payload, size_t n) = 0;
  virtual void emitBodyEnd(int64_t requestId) = 0;
  /// Terminal error chunk. [payload] is malloc-owned and already tracked in
  /// the request's payload log; the sink must emit it with kind=error so the
  /// runner's cumulative ack releases it. May be null (empty message).
  virtual void emitBodyError(int64_t requestId, uint8_t* payload, size_t n,
                             ErrorKind kind) = 0;
  /// One decoded WebSocket event. [payload] is malloc-owned and tracked in
  /// the connection's payload log (freed by the runner's cumulative ack on
  /// the connection id); [opcode] is 1/2/8, [code] the close code on 8.
  virtual void emitWsMessage(int64_t connectionId, uint8_t* payload, size_t n,
                             int opcode, int code) = 0;
  virtual void emitEvent(ServerEventKind kind, int64_t requestId,
                         const std::string& message) = 0;
};

}  // namespace nitroserver
