// ─────────────────────────────────────────────────────────────────────────────
// nitro_server — Nitro bridge surface (transport types only).
//
// Nothing in this file is exported from `package:nitro_server`. Every type is
// `Raw*`-prefixed and belongs to the wire, not to users; the hand-written
// public API in `lib/src/api/` is the only supported surface.
//
// THREE INVARIANTS LIVE HERE. Breaking any of them produces data corruption
// that only shows up under concurrency. They are the same three as
// `nitro_http`, because the failure modes are identical.
//
// 1. STREAMS ARE MODULE-GLOBAL BROADCAST, NOT PER-INSTANCE.
//    The generated C++ bridge keeps a file-level static port registry per
//    stream *name* and ignores the instance id when registering. Therefore
//    `incomingRequests`, `bodyChunks` and `serverEvents` must have EXACTLY ONE
//    internal subscriber each, held by `ServerRunner`, which demultiplexes on
//    the `requestId` tag. A second subscription anywhere duplicates delivery
//    and double-frees zero-copy payloads.
//
// 2. ERRORS RIDE INSIDE THE RESULT RECORD, NOT AS EXCEPTIONS.
//    `@NitroResult` cannot combine with `@nitroNativeAsync` (validator E015),
//    and the bare native-async failure path can only post `kNull`. So every
//    fallible call returns a `RawServerStatus` envelope — `errorKind`,
//    `errorMessage`, `boundPort`. `errorKind == none` means the call
//    succeeded. `HybridException` is reserved for programming errors (bad
//    instance key, malformed blob).
//
// 3. PARAMETER MEMORY DIES WHEN THE CALL RETURNS.
//    Nitro releases the parameter arena as soon as the registering call
//    returns. The bridge MUST deep-copy the config blob, the route pattern and
//    the response body synchronously.
//
// There are no callbacks in this spec, on purpose: function-typed parameters
// are backed by one `NativeCallable` slot per (method, parameter), so two
// concurrent connections would clobber each other's callback. Request
// dispatch travels on the `incomingRequests`/`bodyChunks` streams instead, and
// the handler answers with `respond`, addressed by `requestId`. The native
// connection thread blocks on a per-request condition variable — never on a
// shared bridge lock — until `respond` arrives or the route's own timeout
// fires. That is the whole deadlock story: the Dart isolate never blocks, and
// no two connections ever wait on the same primitive.
// ─────────────────────────────────────────────────────────────────────────────

import 'package:nitro/nitro.dart';

part 'nitro_server.g.dart';

// ── Enumerations ─────────────────────────────────────────────────────────────

@HybridEnum()
enum RawServerMethod {
  get,
  head,
  post,
  put,
  delete,
  patch,
  options,
  trace,
  all,
  custom,
}

/// Deliberately fine-grained: each case maps to exactly one Dart exception
/// type or one field on it, so the mapping table in `raw_mapping.dart` is
/// total and exhaustively testable.
@HybridEnum()
enum RawServerErrorKind {
  none,
  alreadyRunning,
  notRunning,
  bindFailed,
  tlsError,
  routeNotFound,
  handlerTimeout,
  requestTooLarge,
  responseTooLarge,
  io,
  badRequest,
  unknown,
}

/// Chunk kinds for the `bodyChunks` stream. Mirrors `nitro_http`'s `RawChunk`:
/// no `String` fields on the hot path, error text rides in the payload.
@HybridEnum()
enum RawBodyKind { data, end, error }

@HybridEnum()
enum RawServerEventKind {
  started,
  stopped,
  handlerTimeout,
  clientError,
  notice,
}

// ── Configuration records ────────────────────────────────────────────────────
//
// Fields are non-nullable with sentinel conventions (`-1` = inherit from the
// server default, `''` = unset). A nullable primitive inside a record costs a
// tag byte and an extra branch in the C++ reader, for no benefit at this
// layer.

/// Headers travel as an ordered list of pairs, never a `Map`. A map would lose
/// duplicate headers and header order, both of which HTTP servers must echo.
@HybridRecord()
class RawHeader {
  final String name;
  final String value;

  const RawHeader({required this.name, required this.value});
}

/// Heads posted in one message. One per head when the isolate keeps up;
/// under load the engine combines the heads that arrived while the previous
/// post was in flight.
@HybridRecord()
class RawIncomingBatch {
  final List<RawIncomingRequest> requests;

  const RawIncomingBatch({this.requests = const []});
}

/// A route parameter captured from a `:param` segment, e.g. `:id` → `42`.
@HybridRecord()
class RawRouteParam {
  final String name;
  final String value;

  const RawRouteParam({required this.name, required this.value});
}

/// TLS identity. All four fields empty means plain HTTP. PEM strings win over
/// file paths when both are set; mixing a cert from one source with a key
/// from the other is a `tlsError`.
@HybridRecord()
class RawTlsConfig {
  final String certPem;
  final String keyPem;
  final String certFile;
  final String keyFile;

  const RawTlsConfig({
    this.certPem = '',
    this.keyPem = '',
    this.certFile = '',
    this.keyFile = '',
  });
}

@HybridRecord()
class RawServerConfig {
  final String host;
  final int port;
  final int backlog;
  final int maxBodyBytes;
  final int defaultTimeoutMs;

  /// Idle deadline between pipelined requests on one connection. `0`
  /// disables keep-alive: every response closes (v1 behavior).
  final int keepAliveTimeoutMs;

  /// Requests served per connection before a forced close. `<= 0` means
  /// unbounded (the idle timeout still applies).
  final int maxRequestsPerConn;

  /// Cap of the auto-scaling worker pool. `<= 0` means `max(64, 4 × cores)`.
  /// Accepted-but-unclaimed connections queue up to `backlog`; beyond that
  /// the engine refuses immediately instead of starving the accept loop.
  final int workerThreads;

  /// Live connections the engine accepts at once; further accepts are
  /// closed at the door. `<= 0` means unlimited.
  final int maxConnections;

  /// Live connections per peer address; further accepts from that address
  /// are closed at the door. `<= 0` means unlimited.
  final int maxConnectionsPerIp;

  /// Deadline for a new connection's first request head (slow-loris guard).
  /// `<= 0` means the keep-alive idle timeout applies instead.
  final int headerTimeoutMs;

  /// Deadline for a socket write that makes no progress (a peer that stops
  /// reading); the connection is dropped past it. `<= 0` means 30 s.
  final int writeTimeoutMs;

  /// Unsent bytes a WebSocket session may hold before the engine closes it
  /// with 1009. `<= 0` means 1 MiB.
  final int wsMaxBufferBytes;

  /// Negotiate `permessage-deflate` (RFC 7692) when a client offers it.
  final bool wsCompression;
  final RawTlsConfig tls;

  const RawServerConfig({
    this.host = '127.0.0.1',
    this.port = 0,
    this.backlog = 128,
    this.maxBodyBytes = 10485760,
    this.defaultTimeoutMs = 30000,
    this.keepAliveTimeoutMs = 5000,
    this.maxRequestsPerConn = 100,
    this.workerThreads = 0,
    this.maxConnections = 0,
    this.maxConnectionsPerIp = 0,
    this.headerTimeoutMs = 0,
    this.writeTimeoutMs = 30000,
    this.wsMaxBufferBytes = 1048576,
    this.wsCompression = true,
    this.tls = const RawTlsConfig(),
  });
}

/// A route registration. `pattern` uses `:param` segments
/// (`/users/:id`) and an optional trailing `*` wildcard. `timeoutMs` is the
/// per-route handler deadline; `-1` inherits `RawServerConfig.defaultTimeoutMs`.
/// `isWebSocket` marks WebSocket routes: the engine performs the RFC 6455
/// handshake itself and hands the socket to the frame loop — `timeoutMs`
/// then bounds nothing (handshakes never park). `streamBody` makes the
/// engine emit the head before the body (never the inline small-body
/// form), so the runner can dispatch immediately and stream chunks to the
/// handler as they arrive.
@HybridRecord()
class RawRouteConfig {
  final RawServerMethod method;
  final String customMethod;
  final String pattern;
  final int timeoutMs;
  final bool isWebSocket;
  final bool streamBody;

  /// Per-route request body cap; `-1` inherits `RawServerConfig.maxBodyBytes`.
  final int maxBodyBytes;

  /// WebSocket subprotocols the route accepts, comma-separated in
  /// preference order; empty accepts any handshake without selecting one.
  final String wsProtocols;

  const RawRouteConfig({
    this.method = RawServerMethod.get,
    this.customMethod = '',
    required this.pattern,
    this.timeoutMs = -1,
    this.isWebSocket = false,
    this.streamBody = false,
    this.maxBodyBytes = -1,
    this.wsProtocols = '',
  });
}

/// The fallible-call envelope (invariant 2). `boundPort` carries the OS-assigned
/// port out of `start()` when the config asked for port 0.
@HybridRecord()
class RawServerStatus {
  final RawServerErrorKind errorKind;
  final String errorMessage;
  final int boundPort;

  const RawServerStatus({
    this.errorKind = RawServerErrorKind.none,
    this.errorMessage = '',
    this.boundPort = 0,
  });
}

/// One accepted request: head only. The body, if any, follows on `bodyChunks`
/// tagged with the same `requestId`. `params` holds the `:param` captures from
/// the matched route, `routePattern` the pattern that matched.
///
/// `packedHeaders` carries every header as `name\u0000value` pairs joined by
/// `\u0000` (empty when there are none): one string to decode per request
/// instead of two per header, unpacked by the runner on first access.
@HybridRecord()
class RawIncomingRequest {
  final int requestId;
  final RawServerMethod method;
  final String customMethod;
  final String path;
  final String query;
  final String packedHeaders;
  final int contentLength;
  final bool hasBody;
  final bool bodyComplete;
  final String routePattern;
  final List<RawRouteParam> params;

  const RawIncomingRequest({
    required this.requestId,
    this.method = RawServerMethod.get,
    this.customMethod = '',
    required this.path,
    this.query = '',
    this.packedHeaders = '',
    this.contentLength = 0,
    this.hasBody = false,
    this.bodyComplete = false,
    this.routePattern = '',
    this.params = const [],
  });
}

@HybridRecord()
class RawServerEvent {
  final int kind;
  final int requestId;
  final String message;

  const RawServerEvent({
    required this.kind,
    this.requestId = 0,
    this.message = '',
  });
}

// ── Zero-copy stream structs ─────────────────────────────────────────────────
//
// The hot path: potentially thousands per second. They carry NO String fields —
// each would cost a `strdup` per emit — so error text rides in the byte payload
// with a discriminating `kind`.

@HybridStruct(zeroCopy: ['bytes'])
class RawBodyChunk {
  /// data: body bytes · end: empty · error: UTF-8 message.
  final Uint8List bytes;
  final int requestId;

  /// [RawBodyKind] index.
  final int kind;

  /// error: [RawServerErrorKind] index · end: 0.
  final int aux;

  const RawBodyChunk({
    required this.bytes,
    required this.requestId,
    required this.kind,
    required this.aux,
  });
}

/// One decoded WebSocket event on `wsMessages`. `opcode` is 1 (text),
/// 2 (binary) or 8 (close); pings never surface (the engine auto-pongs).
/// `code` rides the close code on opcode 8, else 0. `payload` is the
/// reassembled message bytes (UTF-8 for text), empty on close without a
/// reason. Carries NO route fields — session open travels on
/// `incomingRequests` with the handshake's pattern and params instead.
@HybridStruct(zeroCopy: ['payload'])
class RawWsMessage {
  /// Reassembled message bytes · close: optional UTF-8 reason.
  final Uint8List payload;
  final int connectionId;

  /// 1 = text · 2 = binary · 8 = close.
  final int kind;

  /// Close code on kind 8; on kinds 1 and 2, `1` when the payload is a
  /// raw-deflate stream (`permessage-deflate`, no context takeover).
  final int aux;

  const RawWsMessage({
    required this.payload,
    required this.connectionId,
    required this.kind,
    required this.aux,
  });
}

// ── The module ───────────────────────────────────────────────────────────────
//
// ONE spec class, because each `*.native.dart` spec produces its own shared
// library — two spec files could not share an accept loop, a router or a
// pending-request table without cross-dylib symbol wiring on five platforms.
// Role separation therefore rides on the multi-instance factory key:
//
//   'engine'      process-wide singleton: capabilities, global reset
//   's:<id>'      one server: accept loop, router, pending-request table
//
// `cSymbolPrefix` pins the C namespace to `nitro_server_` even though the class
// is `NitroServerNative`, so the public API is free to use `NitroServer`.

@NitroModule(
  ios: AppleNativeImpl.cpp,
  macos: AppleNativeImpl.cpp,
  android: AndroidNativeImpl.cpp,
  // Generic `NativeImpl.cpp` (not the platform-specific markers) keeps Windows
  // and Linux sharing the single `src/HybridNitroServer.cpp` translation unit
  // rather than each getting its own copy to drift apart.
  windows: NativeImpl.cpp,
  linux: NativeImpl.cpp,
  cSymbolPrefix: 'nitro_server',
  lib: 'nitro_server',
)
abstract class NitroServerNative extends HybridObject {
  /// Process-wide singleton: capability queries, global reset.
  static final NitroServerNative engine = _NitroServerNativeImpl('engine');

  /// Role-typed instance. Keys: `engine` | `s:<serverId>`.
  static NitroServerNative forKey(String key) => _NitroServerNativeImpl(key);

  // ── Capabilities (valid on any instance) ───────────────────────────────────

  /// e.g. `nitro_server/0.0.1 http/1.1 threads`.
  String engineVersion();

  bool supportsTls();

  /// Hot-restart recovery: stop every server, join every thread, drop every
  /// pending request. The Dart layer calls this once at startup.
  void resetNative();

  // ── Server role: 's:<serverId>' ────────────────────────────────────────────

  /// Synchronous by design — there is no reason to make users `await` a server
  /// constructor when configuration is a sub-microsecond FFI call.
  void configureServer(RawServerConfig config);

  RawServerStatus registerRoute(RawRouteConfig route);

  /// [method] is the uppercase token (`GET`, `POST`, …) or `*` for
  /// `RawServerMethod.all`. String-typed (not the enum) so custom-method
  /// routes round-trip their token.
  RawServerStatus unregisterRoute(String method, String pattern);

  /// Registers a route whose answer is fixed: the engine serves [status],
  /// [headers] and [body] entirely on its own thread and never crosses into
  /// Dart — so a static route runs at raw engine throughput. [method] is the
  /// uppercase token (`GET`, `POST`, …) or `*`, matching [unregisterRoute].
  /// The engine frames `Content-Length` and `Connection` itself (any set in
  /// [headers] are ignored); HEAD is answered headers-only. Replaces any route
  /// already at (method, pattern).
  RawServerStatus registerStaticRoute(
    String method,
    String pattern,
    int status,
    List<RawHeader> headers,
    @zeroCopy Uint8List body,
  );

  /// Binds and starts the accept loop. `boundPort` in the returned status is
  /// the actual port (== config port unless the config asked for 0).
  RawServerStatus start();

  void stop();

  /// Graceful shutdown, phase one: closes the listening socket and marks
  /// every following answer `Connection: close`, while requests already
  /// accepted keep being served. Poll [inFlightRequests] until it reaches
  /// zero (or a deadline passes), then call [stop].
  void beginDrain();

  /// Requests dispatched but not yet fully answered on the wire.
  int inFlightRequests();

  /// Connections accepted and not yet closed (queued, idle or serving).
  /// During a drain the engine closes idle ones itself, so this converges
  /// on the in-flight count.
  int liveConnections();

  /// Answers a pending request with [length] bytes of the file at [path]
  /// starting at [offset] (`length` `< 0` means to the end). The status
  /// line and [headers] go out from the calling thread; the file bytes are
  /// sent by the native worker (`sendfile` where the platform has it), so
  /// they never cross into Dart. A file that cannot be opened answers 404.
  /// Same no-op rules as [respond] for unknown or answered ids.
  void respondFile(
    int requestId,
    int status,
    List<RawHeader> headers,
    String path,
    int offset,
    int length,
  );

  /// Answers a pending request. Fire-and-forget: the connection thread is
  /// parked on its own condition variable and wakes when this lands. Answering
  /// an unknown or already-answered `requestId` is a no-op, never an error —
  /// the timeout path may have answered first.
  void respond(
    int requestId,
    int status,
    List<RawHeader> headers,
    @zeroCopy Uint8List body,
  );

  /// Zero-copy payload release, in one sub-microsecond call.
  ///
  /// [ackedChunks] is the cumulative number of `bodyChunks` the runner has
  /// copied out of native memory for [requestId]. It exists because
  /// `nitro_server_release_RawBodyChunk` frees only the struct shell: the
  /// zero-copy payload stays native-owned with no other completion signal.
  /// Native frees every payload with sequence `< ackedChunks`, so the ack is
  /// what makes the zero-copy path leak-free *and* use-after-free-free.
  /// Passing a value the runner has not actually copied is memory corruption.
  /// (Same protocol as `nitro_http`'s `grantCredit` ack half.)
  void ackBody(int requestId, int ackedChunks);

  // ── Chunked response streams ─────────────────────────────────────────────
  //
  // One-shot `respond` cannot emit an unbounded body, so stream responses
  // split the answer in two: `startStream` sends status + headers with
  // `Transfer-Encoding: chunked` and parks the connection thread;
  // `sendStreamChunk` appends one chunk per call, `last: true` writes the
  // terminal `0`-chunk and completes the request (keep-alive evaluated as
  // usual). Calls for unknown, completed, timed-out or dead ids are no-ops —
  // the route timeout may win before the first byte, exactly like `respond`.
  // Empty non-terminal chunks are skipped (a `0`-chunk would terminate the
  // body); the terminal call always completes, even with an empty payload.

  /// Starts a chunked response. Fire-and-forget, same terms as `respond`.
  void startStream(int requestId, int status, List<RawHeader> headers);

  /// Sends one stream chunk. Fire-and-forget; `last` completes the stream.
  void sendStreamChunk(int requestId, @zeroCopy Uint8List chunk, bool last);

  // ── WebSocket sessions ───────────────────────────────────────────────────
  //
  // The engine owns the RFC 6455 handshake and the frame loop. Once a
  // handshake upgrades, the connection leaves HTTP mode: Dart receives
  // decoded messages on `wsMessages` (addressed by `connectionId`, which is
  // the upgraded request's id) and answers with `wsSend`; `wsClose`
  // completes the closing handshake. Session teardown (peer close, send
  // failure, stop()) always ends with an opcode-8 message so Dart can reap
  // deterministically. Unknown or reaped ids are no-ops everywhere.

  /// Sends one message frame; `binary` selects opcode 2 over opcode 1 and
  /// `compressed` marks a `permessage-deflate` payload (RSV1). Writes as
  /// much as the socket takes on the calling thread and queues the rest;
  /// returns the bytes still queued after this call (`0` = on the wire),
  /// or `-1` for an unknown or closing session. Server frames are never
  /// masked (RFC 6455 §5.3). A queue past `wsMaxBufferBytes` closes the
  /// session with 1009.
  int wsSend(
    int connectionId,
    @zeroCopy Uint8List payload,
    bool binary,
    bool compressed,
  );

  /// Completes the closing handshake with [code] and reaps the session.
  void wsClose(int connectionId, int code);

  // ── Module-global streams — EXACTLY ONE internal subscriber each ───────────
  //
  // See invariant 1 in the file header. `Backpressure.block` is forbidden here:
  // it blocks the emitting thread, which is a connection thread parked with a
  // client on the other end of the socket, and stalling it stalls that client.
  // `bufferDrop` provably never drops a head or an event because heads and
  // events are small and bounded per request; body bytes backpressure through
  // the TCP window instead, since a connection thread that cannot emit simply
  // stops reading.

  @NitroStream(backpressure: Backpressure.bufferDrop)
  Stream<RawIncomingBatch> get incomingRequests;

  @NitroStream(backpressure: Backpressure.bufferDrop)
  Stream<RawBodyChunk> get bodyChunks;

  @NitroStream(backpressure: Backpressure.bufferDrop)
  Stream<RawServerEvent> get serverEvents;

  @NitroStream(backpressure: Backpressure.bufferDrop)
  Stream<RawWsMessage> get wsMessages;
}
