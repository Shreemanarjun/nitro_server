#pragma once
// The wire-protocol seam. One ProtocolSession drives one connection's protocol
// state machine, decoupled from the socket by two function seams: inbound bytes
// arrive via feed(), outbound bytes leave through the WriteSink the concrete
// session was constructed with. Requests surface through an Emitter (a
// constructor argument of the concrete session, not part of this interface) and
// are answered via respond().
//
// This is the extension point for additional wire protocols. HTTP/1.1 is handled
// inline by the reactor; HTTP/2 is Http2Session (see Http2Session.h). A future
// HTTP/3 (QUIC) session implements this same interface and slots into the
// reactor unchanged above the Emitter seam — only the byte transport differs
// (QUIC is UDP, so h3 feeds datagrams rather than a TLS bytestream). See
// doc/http3.md. Because everything above the Emitter (routing, middleware,
// handlers, OpenAPI, the Dart runner) is protocol-agnostic, adding a protocol is
// a new ProtocolSession subclass plus its ALPN branch — not a change to the
// request model.
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

#include "Common.h"  // Header

namespace nitroserver {

/// Abstract per-connection protocol session. Not thread-safe: every call runs on
/// the owning reactor's loop thread (the same contract as the HTTP/1.1 path's
/// per-connection state).
class ProtocolSession {
 public:
  /// Outbound byte sink. The buffer passed is valid only for the duration of the
  /// call, so the sink must copy or write it immediately.
  using WriteSink = std::function<void(const uint8_t*, size_t)>;

  virtual ~ProtocolSession() = default;

  /// Feed inbound (already TLS-decrypted) bytes into the protocol. Runs any recv
  /// callbacks synchronously, then flushes outbound frames. Returns false on a
  /// fatal protocol error — the caller closes the connection.
  virtual bool feed(const uint8_t* data, size_t len) = 0;

  /// Answer request [requestId] with [status] + [headers] + [body]. A no-op if
  /// the request is unknown/already closed, or after stop().
  virtual void respond(int64_t requestId, int status,
                       const std::vector<Header>& headers, std::string body) = 0;

  /// Flush any queued outbound frames to the WriteSink. Called after feed() and
  /// respond(); exposed so the reactor can pump once a blocked socket drains.
  virtual void pump() = 0;

  /// Whether the protocol still expects to read, or has bytes queued to write.
  virtual bool wantRead() const = 0;
  virtual bool wantWrite() const = 0;

  /// Mark the session shutting down: feed()/respond() become no-ops, so a late
  /// answer or stray inbound bytes in the drain window cannot drive a half-dead
  /// session. The reactor calls this on drain/teardown.
  virtual void stop() = 0;
};

}  // namespace nitroserver
