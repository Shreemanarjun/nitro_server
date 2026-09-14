// ─────────────────────────────────────────────────────────────────────────────
// nitro_server — the bridge implementation.
//
// This file is deliberately thin. It does exactly four things:
//
//   1. Registers a typed factory so each Dart-side instance key produces its
//      own C++ object with a `shared_ptr<ServerInstance>` (`engine` / `s:<id>`).
//   2. Binds a `BridgeEmitter` that posts request dispatch into the
//      instance-partitioned Nitro streams. The engine never touches the
//      generated class; it goes through `Emitter` instead, which also keeps
//      the engine unit-testable without Dart.
//   3. Deep-copies every parameter before returning. Nitro releases the
//      parameter arena the instant a registering call returns, so retaining a
//      `NitroCppBuffer` or a `@zeroCopy` pointer past that point reads freed
//      memory. This is the single most dangerous contract in the plugin.
//   4. Delegates.
//
// On Apple platforms CocoaPods and SwiftPM glob `Classes/` / `Sources/`, which
// forward here, and the `#include` at the bottom pulls in the whole engine as
// one unity translation unit. The CMake platforms define
// NITRO_SERVER_ENGINE_SEPARATE_TUS and compile each engine source individually.
// ─────────────────────────────────────────────────────────────────────────────

#include "../lib/src/generated/cpp/nitro_server.native.g.h"

#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "engine/Common.h"
#include "engine/EngineRegistry.h"
#include "engine/ServerInstance.h"
#include "engine/Wire.h"

namespace {

using namespace nitroserver;

RawServerStatus toStatus(const StatusResult& r) {
  RawServerStatus s;
  s.errorKind = static_cast<RawServerErrorKind>(r.kind);
  s.errorMessage = r.message;
  s.boundPort = r.boundPort;
  return s;
}

class BridgeEmitter final : public Emitter {
 public:
  explicit BridgeEmitter(HybridNitroServerNative* bridge) : bridge_(bridge) {}

  void emitHead(int64_t requestId, Method method,
                const std::string& customMethod, const std::string& path,
                const std::string& query, const std::vector<Header>& headers,
                int64_t contentLength, bool hasBody, bool bodyComplete,
                const std::string& routePattern,
                const std::vector<RouteParam>& params) override {
    RawIncomingRequest req;
    req.requestId = requestId;
    req.method = static_cast<RawServerMethod>(method);
    req.customMethod = customMethod;
    req.path = path;
    req.query = query;
    for (const auto& h : headers) {
      RawHeader rh;
      rh.name = h.name;
      rh.value = h.value;
      req.headers.push_back(std::move(rh));
    }
    req.contentLength = contentLength;
    req.hasBody = hasBody;
    req.bodyComplete = bodyComplete;
    req.routePattern = routePattern;
    for (const auto& p : params) {
      RawRouteParam rp;
      rp.name = p.name;
      rp.value = p.value;
      req.params.push_back(std::move(rp));
    }
    bridge_->emit_incomingRequests(req.toNativeBuffer());
  }

  void emitBodyData(int64_t requestId, uint8_t* payload, size_t n) override {
    RawBodyChunk chunk;
    chunk.bytes = payload;
    chunk.bytesLength = (int64_t)n;
    chunk.requestId = requestId;
    chunk.kind = (int64_t)BodyKind::Data;
    chunk.aux = 0;
    bridge_->emit_bodyChunks(chunk);
  }

  void emitBodyEnd(int64_t requestId) override {
    RawBodyChunk chunk;
    chunk.bytes = nullptr;
    chunk.bytesLength = 0;
    chunk.requestId = requestId;
    chunk.kind = (int64_t)BodyKind::End;
    chunk.aux = 0;
    bridge_->emit_bodyChunks(chunk);
  }

  void emitBodyError(int64_t requestId, uint8_t* payload, size_t n,
                     ErrorKind kind) override {
    // Tracked by ServerInstance before this call, so the runner's cumulative
    // ack frees it — no leak, no race. The end marker follows immediately.
    RawBodyChunk chunk;
    chunk.bytes = payload;
    chunk.bytesLength = (int64_t)n;
    chunk.requestId = requestId;
    chunk.kind = (int64_t)BodyKind::Error;
    chunk.aux = (int64_t)kind;
    bridge_->emit_bodyChunks(chunk);
  }

  void emitWsMessage(int64_t connectionId, uint8_t* payload, size_t n,
                     int opcode, int code) override {
    // Same ownership as body chunks: tracked by ServerInstance, freed by
    // the runner's cumulative ackBody(connectionId, …).
    RawWsMessage msg;
    msg.payload = payload;
    msg.payloadLength = (int64_t)n;
    msg.connectionId = connectionId;
    msg.kind = opcode;
    msg.aux = code;
    bridge_->emit_wsMessages(msg);
  }

  void emitEvent(ServerEventKind kind, int64_t requestId,
                 const std::string& message) override {
    RawServerEvent ev;
    ev.kind = (int64_t)kind;
    ev.requestId = requestId;
    ev.message = message;
    bridge_->emit_serverEvents(ev.toNativeBuffer());
  }

 private:
  HybridNitroServerNative* bridge_;
};

class HybridNitroServerImpl final : public HybridNitroServerNative {
 public:
  explicit HybridNitroServerImpl(const std::string& key)
      : emitter_(this), server_(EngineRegistry::resolve(key, &emitter_)) {}

  // The bridge object owns the sink: unbind it before the sink dies. Dart
  // stops the server before its bridge objects go away, so no request is
  // mid-flight on this sink by then.
  ~HybridNitroServerImpl() override { server_->removeEmitter(&emitter_); }

  // ── Capabilities ───────────────────────────────────────────────────────────

  std::string engineVersion() override {
    return "nitro_server/0.0.1 http/1.1 threads";
  }

  bool supportsTls() override { return false; }

  void resetNative() override { EngineRegistry::resetAll(); }

  // ── Server role ────────────────────────────────────────────────────────────

  void configureServer(NitroCppBuffer config) override {
    const RawServerConfig raw = RawServerConfig::fromNative(config);
    ServerConfig cfg;
    cfg.host = raw.host;
    cfg.port = raw.port;
    cfg.backlog = raw.backlog;
    cfg.maxBodyBytes = raw.maxBodyBytes;
    cfg.defaultTimeoutMs = raw.defaultTimeoutMs;
    cfg.keepAliveTimeoutMs = raw.keepAliveTimeoutMs;
    cfg.maxRequestsPerConn = raw.maxRequestsPerConn;
    cfg.workerThreads = raw.workerThreads;
    cfg.maxConnections = raw.maxConnections;
    cfg.maxConnectionsPerIp = raw.maxConnectionsPerIp;
    cfg.headerTimeoutMs = raw.headerTimeoutMs;
    cfg.writeTimeoutMs = raw.writeTimeoutMs;
    cfg.wsMaxBufferBytes = raw.wsMaxBufferBytes;
    cfg.wsCompression = raw.wsCompression;
    cfg.tlsRequested = !raw.tls.certPem.empty() || !raw.tls.keyPem.empty() ||
                       !raw.tls.certFile.empty() || !raw.tls.keyFile.empty();
    server_->configure(cfg);
  }

  NitroCppBuffer registerRoute(NitroCppBuffer route) override {
    const RawRouteConfig raw = RawRouteConfig::fromNative(route);
    return toStatus(server_->registerRoute(
        static_cast<Method>(raw.method), raw.customMethod, raw.pattern,
        raw.timeoutMs, raw.isWebSocket, raw.streamBody,
        raw.maxBodyBytes)).toNativeBuffer();
  }

  NitroCppBuffer unregisterRoute(const std::string& method,
                                 const std::string& pattern) override {
    std::string custom;
    const Method m = parseUnregisterMethod(method, custom);
    return toStatus(server_->unregisterRoute(m, custom, pattern))
        .toNativeBuffer();
  }

  NitroCppBuffer start() override {
    return toStatus(server_->start()).toNativeBuffer();
  }

  void stop() override { server_->stop(); }

  void beginDrain() override { server_->beginDrain(); }

  int64_t inFlightRequests() override { return server_->inFlightRequests(); }

  int64_t liveConnections() override { return server_->liveConnections(); }

  void respondFile(int64_t requestId, int64_t status, NitroCppBuffer headers,
                   const std::string& path, int64_t offset,
                   int64_t length) override {
    std::vector<Header> hs;
    try {
      hs = decodeHeaderList(headers);
    } catch (...) {
      return;  // Malformed blob: drop rather than crash the connection.
    }
    server_->respondFile(requestId, status, hs, path, offset, length);
  }

  void respond(int64_t requestId, int64_t status, NitroCppBuffer headers,
               const uint8_t* body, size_t body_length) override {
    // Deep-copy under the call: `headers` and `body` die with the arena.
    // `headers` is an indexed argument list — see Wire.h.
    std::vector<Header> hs;
    try {
      hs = decodeHeaderList(headers);
    } catch (...) {
      return;  // Malformed blob: drop rather than crash the connection.
    }
    server_->respond(requestId, status, hs, body, body_length);
  }

  void ackBody(int64_t requestId, int64_t ackedChunks) override {
    server_->ackBody(requestId, ackedChunks);
  }

  void startStream(int64_t requestId, int64_t status,
                   NitroCppBuffer headers) override {
    // Same indexed-argument-list decoding as respond (see Wire.h).
    std::vector<Header> hs;
    try {
      hs = decodeHeaderList(headers);
    } catch (...) {
      return;  // Malformed blob: drop rather than crash the connection.
    }
    server_->startStream(requestId, status, hs);
  }

  void sendStreamChunk(int64_t requestId, const uint8_t* chunk,
                       size_t chunk_length, bool last) override {
    // Deep-copy happens in the engine call: the arena dies on return.
    server_->sendStreamChunk(requestId, chunk, chunk_length, last);
  }

  int64_t wsSend(int64_t connectionId, const uint8_t* payload,
                 size_t payload_length, bool binary, bool compressed) override {
    // Whatever the socket does not take right now is copied into the
    // session's queue inside the call: nothing outlives the arena.
    return server_->wsSend(connectionId, payload, payload_length, binary,
                           compressed);
  }

  void wsClose(int64_t connectionId, int64_t code) override {
    server_->wsClose(connectionId, (int)code);
  }

 private:
  BridgeEmitter emitter_;
  std::shared_ptr<ServerInstance> server_;
};

}  // namespace

// Typed factory: one C++ object per Dart instance key.
#if defined(_WIN32)
namespace {
struct _AutoRegister {
  _AutoRegister() {
    nitro_server_register_factory_typed(
        [](const std::string& key) -> std::shared_ptr<HybridNitroServerNative> {
          return std::make_shared<HybridNitroServerImpl>(key);
        });
  }
};
_AutoRegister _auto_register_instance;
}  // namespace
#else
__attribute__((constructor)) static void nitro_server_auto_register() {
  nitro_server_register_factory_typed(
      [](const std::string& key) -> std::shared_ptr<HybridNitroServerNative> {
        return std::make_shared<HybridNitroServerImpl>(key);
      });
}
#endif

// Apple unity build: CocoaPods/SwiftPM compile this single TU.
#if !defined(NITRO_SERVER_ENGINE_SEPARATE_TUS)
#include "engine/EngineUnity.cpp"
#endif
