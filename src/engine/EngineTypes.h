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
  int64_t maxRequestsPerConn = 100;
  /// libuv event-loop count / worker cap (engine-specific). `<= 0`: auto.
  int64_t workerThreads = 0;
  int64_t maxConnections = 0;       // <= 0: unlimited.
  int64_t maxConnectionsPerIp = 0;  // <= 0: unlimited.
  int64_t headerTimeoutMs = 0;      // <= 0: the idle timeout applies.
  int64_t writeTimeoutMs = 30000;   // <= 0: 30 s.
  int64_t wsMaxBufferBytes = 1 << 20;  // <= 0: 1 MiB.
  bool wsCompression = true;
  bool tlsRequested = false;
  // TLS identity (see RawTlsConfig). PEM strings win over file paths.
  std::string tlsCertPem;
  std::string tlsKeyPem;
  std::string tlsCertFile;
  std::string tlsKeyFile;
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
                        const std::vector<RouteParam>& params) = 0;
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
