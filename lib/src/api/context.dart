/// Request/response types for route handlers.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'http_method.dart';
import 'json_writer.dart';
import 'multipart.dart';

/// The lowest TLS protocol version a server accepts.
enum TlsVersion { v12, v13 }

/// Identity and policy for server TLS. An empty identity means plain HTTP; a
/// certificate set requires a build with TLS support, otherwise `start()`
/// throws [ServerTlsException].
///
/// Policy: [minVersion] (default TLS 1.2), [ciphers] (an OpenSSL cipher list
/// for TLS 1.2) and [cipherSuites] (TLS 1.3 suites) narrow what is
/// negotiated — empty keeps OpenSSL's defaults. Mutual TLS: set [clientCaPem]
/// or [clientCaFile] (trust anchors) and every client must present a
/// certificate chaining to them; a connection without one is refused at the
/// handshake. A policy value OpenSSL rejects (an unknown cipher) fails `bind`
/// with [ServerTlsException] rather than the first client.
class TlsConfig {
  const TlsConfig({
    this.certPem = '',
    this.keyPem = '',
    this.certFile = '',
    this.keyFile = '',
    this.minVersion = TlsVersion.v12,
    this.ciphers = '',
    this.cipherSuites = '',
    this.clientCaPem = '',
    this.clientCaFile = '',
  });

  final String certPem;
  final String keyPem;
  final String certFile;
  final String keyFile;
  final TlsVersion minVersion;
  final String ciphers;
  final String cipherSuites;
  final String clientCaPem;
  final String clientCaFile;

  bool get enabled =>
      certPem.isNotEmpty ||
      keyPem.isNotEmpty ||
      certFile.isNotEmpty ||
      keyFile.isNotEmpty;

  /// Whether clients must present a certificate.
  bool get mutual => clientCaPem.isNotEmpty || clientCaFile.isNotEmpty;

  TlsConfig copyWith({
    String? certPem,
    String? keyPem,
    String? certFile,
    String? keyFile,
    TlsVersion? minVersion,
    String? ciphers,
    String? cipherSuites,
    String? clientCaPem,
    String? clientCaFile,
  }) => TlsConfig(
    certPem: certPem ?? this.certPem,
    keyPem: keyPem ?? this.keyPem,
    certFile: certFile ?? this.certFile,
    keyFile: keyFile ?? this.keyFile,
    minVersion: minVersion ?? this.minVersion,
    ciphers: ciphers ?? this.ciphers,
    cipherSuites: cipherSuites ?? this.cipherSuites,
    clientCaPem: clientCaPem ?? this.clientCaPem,
    clientCaFile: clientCaFile ?? this.clientCaFile,
  );
}

/// The highest HTTP version a server negotiates (see [ServerConfig.protocol]).
/// Each level includes the ones below it: HTTP/1.1 is always served, and a
/// higher value *additionally* offers that version, with older clients falling
/// back. A level beyond what the engine was built with is capped to the built-in
/// maximum.
enum HttpProtocol {
  /// HTTP/1.1 only (plus WebSocket). No `h2`/`h3` negotiation.
  http1,

  /// Up to HTTP/2 — negotiate `h2` over TLS (ALPN) or h2c prior-knowledge, and
  /// fall back to HTTP/1.1. The default. Needs the engine built with HTTP/2.
  http2,

  /// Up to HTTP/3 (QUIC). Not yet implemented — currently behaves as [http2]
  ///; reserved so configs are forward-compatible.
  http3,
}

/// Tuning for one bound server.
class ServerConfig {
  /// [host] is an IPv4 literal (`'127.0.0.1'`), the wildcard `'0.0.0.0'`,
  /// or an IPv6 literal (`'::1'`, or `'::'` for dual-stack: one socket
  /// serving both v4-mapped and v6 clients).
  const ServerConfig({
    this.host = '127.0.0.1',
    this.port = 0,
    this.backlog = 128,
    this.maxBodyBytes = 10 * 1024 * 1024,
    this.defaultTimeout = const Duration(seconds: 30),
    this.keepAliveTimeout = const Duration(seconds: 5),
    this.maxRequestsPerConnection = 100,
    this.workerThreads = 0,
    this.isolates = 1,
    this.maxConnections = 0,
    this.maxConnectionsPerIp = 0,
    this.headerTimeout = Duration.zero,
    this.writeTimeout = const Duration(seconds: 30),
    this.wsMaxBufferBytes = 1024 * 1024,
    this.wsCompression = true,
    this.protocol = HttpProtocol.http2,
    this.responseTiming = true,
    this.tls = const TlsConfig(),
    this.exposeErrorDetails = false,
    this.bodyTimeout = Duration.zero,
    this.wsIdleTimeout = const Duration(seconds: 60),
    this.maxConnectionAge = Duration.zero,
    this.maxInFlightRequests = 0,
    this.proxyProtocol = false,
    this.streamIdleTimeout = const Duration(minutes: 5),
    this.streamMaxBufferBytes = 4 * 1024 * 1024,
    this.maxBufferedBodyBytes = 64 * 1024 * 1024,
  });

  final String host;
  final int port;
  final int backlog;
  final int maxBodyBytes;
  final Duration defaultTimeout;

  /// Idle deadline between requests on one keep-alive connection.
  /// [Duration.zero] disables keep-alive: every response closes.
  final Duration keepAliveTimeout;

  /// Requests served per connection before a forced close. `0` means
  /// unbounded (the idle timeout still applies).
  final int maxRequestsPerConnection;

  /// Caps the number of libuv event-loop threads the engine runs. `0` (the
  /// default) runs one loop per CPU core, which a handful of threads use to
  /// serve thousands of keep-alive connections. A positive value below the core
  /// count runs fewer loops (useful to bound resource use on a big box); at or
  /// above the core count it stays one per core, since extra loops only
  /// oversubscribe.
  final int workerThreads;

  /// Isolates available to run handlers. `1` (default) runs every handler on
  /// the calling isolate; `0` is auto — it scales to the core count when a
  /// `setup` is passed to [NitroServer.bind] (so a CPU-bound handler can fan
  /// out across cores), and stays at 1 without one (so a zero-config server
  /// still binds rather than failing). Above 1, routes are registered by that
  /// `setup`, which must be **sendable** to each isolate — use a top-level or
  /// static function (always sendable); a closure works only if it captures
  /// nothing mutable. The handlers the `setup` registers may be closures: they
  /// are built fresh inside each isolate when the `setup` runs there, so only
  /// the `setup` itself must be sendable.
  ///
  /// The engine deals requests across only as many of these isolates as help:
  /// it keeps light handlers on one (it already does the I/O on every core) and
  /// fans a CPU-bound handler out across all. So extra isolates are headroom for
  /// heavy handlers, never a tax on light ones — set it to the core count and
  /// let the engine decide.
  final int isolates;

  /// Live connections accepted at once; further ones are closed at the
  /// door, before a worker is spent on them. `0` means unlimited.
  final int maxConnections;

  /// Live connections per peer address; further ones from that address are
  /// closed at the door. `0` means unlimited.
  final int maxConnectionsPerIp;

  /// Deadline for a new connection's first request head, the slow-loris
  /// guard. [Duration.zero] means the keep-alive idle timeout applies.
  final Duration headerTimeout;

  /// How long a socket write may make no progress (a peer that stops
  /// reading) before the connection is dropped. Bounds every response,
  /// file and WebSocket send.
  final Duration writeTimeout;

  /// Unsent bytes a WebSocket session may hold before the engine closes it
  /// with 1009; `WsSession.bufferedBytes` reports the current level.
  final int wsMaxBufferBytes;

  /// Negotiate `permessage-deflate` when a WebSocket client offers it.
  final bool wsCompression;

  /// Highest HTTP version this server negotiates, in one knob. HTTP/1.1 (and
  /// WebSocket) is always served; a higher setting *additionally* offers that
  /// version — [HttpProtocol.http2] negotiates `h2` over TLS (ALPN) or h2c and
  /// falls back to HTTP/1.1 for older clients. Defaults to
  /// [HttpProtocol.http2]; set [HttpProtocol.http1] to force HTTP/1.1 without
  /// rebuilding the engine. Requires the engine built with support for the
  /// version (e.g. `-DNITRO_SERVER_HTTP2=ON`); otherwise it caps at what was
  /// built in.
  final HttpProtocol protocol;

  /// Add a `Server-Timing: app;dur=<ms>` header to every handler answer —
  /// the time from dispatch to answer, which browsers surface in DevTools
  /// (Network → Timing) and any client can read. On by default; set `false`
  /// to shave one small string per response off the hot path when you are
  /// chasing peak throughput. Answers the engine serves itself (static files,
  /// a rejected oversized body) carry no app timing.
  final bool responseTiming;
  final TlsConfig tls;

  /// Whether the default 500 answer names the thrown error. Off, a throwing
  /// handler answers a generic `internal server error` body and the error is
  /// reported on [NitroServer.events] instead — exception text can carry
  /// paths, SQL, tokens or internal state. Turn on for local development only.
  final bool exposeErrorDetails;

  /// Stall window for a request body still arriving (head parsed, bytes
  /// trickling in; restarts on every read): past it the engine answers `408`
  /// and closes. Applies to buffered, streamed (`streamBody`) and HTTP/2
  /// uploads alike. [Duration.zero] means [keepAliveTimeout] is the window.
  final Duration bodyTimeout;

  /// WebSocket liveness: a session quiet for half this is pinged by the
  /// engine; one still silent at the full window (no pong, no frame) is
  /// closed `1001` and a `clientError` event is emitted. [Duration.zero]
  /// disables (a dead peer then holds its connection until the OS notices).
  final Duration wsIdleTimeout;

  /// Hard lifetime of a connection (load-balancer rebalancing, leak
  /// bounding): past it an idle connection closes, a busy HTTP/1.1 one closes
  /// after its answer, a WebSocket is closed `1001`, an HTTP/2 session gets
  /// `GOAWAY` and ends once its streams finish. [Duration.zero] = unbounded.
  final Duration maxConnectionAge;

  /// Global budget of requests dispatched and not yet answered, across every
  /// connection and protocol. Past it the engine answers `503` with
  /// `Retry-After: 1` without reaching a handler. `0` = unlimited.
  ///
  /// Memory is bounded per connection, not by this knob: an HTTP/1.1
  /// connection holds at most one request body ([maxBodyBytes], or the
  /// route's own cap) plus a 64 KiB parse buffer; an HTTP/2 session holds at
  /// most [maxBufferedBodyBytes] of request bodies across its streams; on the
  /// write side a WebSocket queues at most [wsMaxBufferBytes] and a streaming
  /// response at most [streamMaxBufferBytes]. Multiply by [maxConnections]
  /// (set it: `0` is unlimited) for the server-wide bound.
  final int maxInFlightRequests;

  /// A streaming response (SSE, chunked, file) that writes nothing for this
  /// long — and has nothing queued — is closed: the handler stopped feeding
  /// it. A live stream must send something (an SSE `: ping` comment will do)
  /// more often than this. `Duration.zero` disables. Default 5 minutes.
  final Duration streamIdleTimeout;

  /// Unsent bytes a streaming response may queue when its reader falls
  /// behind; past it the connection is dropped and the handler's later
  /// chunks are discarded (the WebSocket equivalent is [wsMaxBufferBytes]).
  /// `0` = unlimited. Default 4 MiB.
  final int streamMaxBufferBytes;

  /// Request-body bytes one HTTP/2 session may hold across its concurrent
  /// streams. A stream reserves its declared `Content-Length` (or its body
  /// cap when undeclared) on its HEADERS frame; one that would exceed the
  /// budget is answered `503` (`Retry-After: 1`), one larger than the whole
  /// budget `413`. Must be at least [maxBodyBytes]; a route whose own cap is
  /// larger than the budget answers `413` to bodies over the budget, so raise
  /// this alongside such a route. `0` = unlimited. Default 64 MiB.
  final int maxBufferedBodyBytes;

  /// Expect a HAProxy PROXY protocol header (v1 text or v2 binary) first on
  /// every accepted connection, ahead of TLS and HTTP/2 alike. The source
  /// address it names becomes [RequestContext.clientIp] (so `rateLimit`,
  /// `accessLog` and handlers see the real client behind an L4 balancer); a
  /// connection without a valid header is closed and a `clientError` event
  /// is emitted. Turn it on only for a listener reachable solely through the
  /// proxy that sends it — a direct client could otherwise name any address.
  final bool proxyProtocol;

  /// Checks every range constraint and throws [ArgumentError] on the first
  /// violation. `bind` calls it, so a bad value fails loudly in AOT builds
  /// too (an `assert` would be compiled out, and a negative [maxBodyBytes]
  /// used to mean "no cap"). Call it yourself to validate early.
  void validate() {
    void check(bool ok, String message) {
      if (!ok) throw ArgumentError('ServerConfig: $message');
    }

    check(port >= 0 && port <= 65535, 'port out of range: $port');
    check(backlog > 0, 'backlog must be positive');
    check(maxBodyBytes > 0, 'maxBodyBytes must be positive');
    check(isolates >= 0, 'isolates must be non-negative');
    check(workerThreads >= 0, 'workerThreads must be non-negative');
    check(maxConnections >= 0, 'maxConnections must be non-negative');
    check(maxConnectionsPerIp >= 0, 'maxConnectionsPerIp must be non-negative');
    check(
      maxRequestsPerConnection >= 0,
      'maxRequestsPerConnection must be non-negative',
    );
    check(wsMaxBufferBytes > 0, 'wsMaxBufferBytes must be positive');
    check(
      streamMaxBufferBytes >= 0,
      'streamMaxBufferBytes must be non-negative',
    );
    check(
      maxBufferedBodyBytes >= 0,
      'maxBufferedBodyBytes must be non-negative',
    );
    check(
      maxBufferedBodyBytes == 0 || maxBufferedBodyBytes >= maxBodyBytes,
      'maxBufferedBodyBytes must be at least maxBodyBytes',
    );
    check(
      !streamIdleTimeout.isNegative,
      'streamIdleTimeout must not be negative',
    );
    check(!defaultTimeout.isNegative, 'defaultTimeout must not be negative');
    check(
      !keepAliveTimeout.isNegative,
      'keepAliveTimeout must not be negative',
    );
    check(!headerTimeout.isNegative, 'headerTimeout must not be negative');
    check(!writeTimeout.isNegative, 'writeTimeout must not be negative');
    check(!bodyTimeout.isNegative, 'bodyTimeout must not be negative');
    check(!wsIdleTimeout.isNegative, 'wsIdleTimeout must not be negative');
    check(
      !maxConnectionAge.isNegative,
      'maxConnectionAge must not be negative',
    );
    check(maxInFlightRequests >= 0, 'maxInFlightRequests must be non-negative');
    check(
      tls.enabled || !tls.mutual,
      'client certificates (clientCaPem/clientCaFile) need a server '
      'certificate',
    );
  }

  /// A copy with any of [host], [port], [backlog], [maxBodyBytes],
  /// [defaultTimeout], [keepAliveTimeout], [maxRequestsPerConnection],
  /// [workerThreads], [isolates], [maxConnections], [maxConnectionsPerIp],
  /// [headerTimeout], [writeTimeout], [wsMaxBufferBytes], [wsCompression],
  /// [responseTiming] or [tls] replaced.
  ServerConfig copyWith({
    String? host,
    int? port,
    int? backlog,
    int? maxBodyBytes,
    Duration? defaultTimeout,
    Duration? keepAliveTimeout,
    int? maxRequestsPerConnection,
    int? workerThreads,
    int? isolates,
    int? maxConnections,
    int? maxConnectionsPerIp,
    Duration? headerTimeout,
    Duration? writeTimeout,
    int? wsMaxBufferBytes,
    bool? wsCompression,
    HttpProtocol? protocol,
    bool? responseTiming,
    TlsConfig? tls,
    bool? exposeErrorDetails,
    Duration? bodyTimeout,
    Duration? wsIdleTimeout,
    Duration? maxConnectionAge,
    int? maxInFlightRequests,
    bool? proxyProtocol,
    Duration? streamIdleTimeout,
    int? streamMaxBufferBytes,
    int? maxBufferedBodyBytes,
  }) {
    return ServerConfig(
      host: host ?? this.host,
      port: port ?? this.port,
      backlog: backlog ?? this.backlog,
      maxBodyBytes: maxBodyBytes ?? this.maxBodyBytes,
      defaultTimeout: defaultTimeout ?? this.defaultTimeout,
      keepAliveTimeout: keepAliveTimeout ?? this.keepAliveTimeout,
      maxRequestsPerConnection:
          maxRequestsPerConnection ?? this.maxRequestsPerConnection,
      workerThreads: workerThreads ?? this.workerThreads,
      isolates: isolates ?? this.isolates,
      maxConnections: maxConnections ?? this.maxConnections,
      maxConnectionsPerIp: maxConnectionsPerIp ?? this.maxConnectionsPerIp,
      headerTimeout: headerTimeout ?? this.headerTimeout,
      writeTimeout: writeTimeout ?? this.writeTimeout,
      wsMaxBufferBytes: wsMaxBufferBytes ?? this.wsMaxBufferBytes,
      wsCompression: wsCompression ?? this.wsCompression,
      protocol: protocol ?? this.protocol,
      responseTiming: responseTiming ?? this.responseTiming,
      tls: tls ?? this.tls,
      exposeErrorDetails: exposeErrorDetails ?? this.exposeErrorDetails,
      bodyTimeout: bodyTimeout ?? this.bodyTimeout,
      wsIdleTimeout: wsIdleTimeout ?? this.wsIdleTimeout,
      maxConnectionAge: maxConnectionAge ?? this.maxConnectionAge,
      maxInFlightRequests: maxInFlightRequests ?? this.maxInFlightRequests,
      proxyProtocol: proxyProtocol ?? this.proxyProtocol,
      streamIdleTimeout: streamIdleTimeout ?? this.streamIdleTimeout,
      streamMaxBufferBytes: streamMaxBufferBytes ?? this.streamMaxBufferBytes,
      maxBufferedBodyBytes: maxBufferedBodyBytes ?? this.maxBufferedBodyBytes,
    );
  }

  /// Reads config from [environment] (pass `Platform.environment`), overlaid on
  /// [base]. Only the variables present are applied, so unset ones keep
  /// [base]'s value. A value that does not parse (`PORT=abc`) throws a
  /// [FormatException] rather than being silently ignored:
  ///
  /// `HOST`, `PORT`, `BACKLOG`, `ISOLATES`, `WORKER_THREADS`, `MAX_BODY_BYTES`,
  /// `MAX_CONNECTIONS`, `MAX_CONNECTIONS_PER_IP`, `MAX_REQUESTS_PER_CONNECTION`,
  /// `KEEP_ALIVE_TIMEOUT_MS`, `DEFAULT_TIMEOUT_MS`, `HEADER_TIMEOUT_MS`,
  /// `WRITE_TIMEOUT_MS`, `BODY_TIMEOUT_MS`, `WS_IDLE_TIMEOUT_MS`,
  /// `MAX_CONNECTION_AGE_MS`, `MAX_IN_FLIGHT_REQUESTS`, `WS_MAX_BUFFER_BYTES`,
  /// `WS_COMPRESSION`, `RESPONSE_TIMING`, `EXPOSE_ERROR_DETAILS`
  /// (`true`/`false`/`1`/`0`),
  /// `PROXY_PROTOCOL`, `HTTP_PROTOCOL` (`http1`/`http2`), and TLS as
  /// `TLS_CERT_FILE` + `TLS_KEY_FILE` or `TLS_CERT_PEM` + `TLS_KEY_PEM`, with
  /// policy `TLS_MIN_VERSION` (`1.2`/`1.3`), `TLS_CIPHERS`, `TLS_CIPHER_SUITES`
  /// and mutual TLS via `TLS_CLIENT_CA_FILE` or `TLS_CLIENT_CA_PEM`.
  ///
  /// ```dart
  /// final server = await NitroServer.bind(
  ///   ServerConfig.fromEnv(Platform.environment),
  ///   setup,
  /// );
  /// ```
  factory ServerConfig.fromEnv(
    Map<String, String> environment, {
    ServerConfig base = const ServerConfig(),
  }) {
    String? raw(String key) {
      final v = environment[key];
      return v == null || v.isEmpty ? null : v;
    }

    int? asInt(String key) {
      final v = raw(key);
      if (v == null) return null;
      return int.tryParse(v) ??
          (throw FormatException('$key must be an integer, got "$v"'));
    }

    Duration? asMs(String key) {
      final v = asInt(key);
      return v == null ? null : Duration(milliseconds: v);
    }

    bool? asBool(String key) {
      final v = raw(key)?.toLowerCase();
      if (v == null) return null;
      return switch (v) {
        'true' || '1' || 'yes' || 'on' => true,
        'false' || '0' || 'no' || 'off' => false,
        _ => throw FormatException('$key must be a boolean, got "$v"'),
      };
    }

    HttpProtocol? asProtocol(String key) {
      final v = raw(key);
      if (v == null) return null;
      return switch (v.toLowerCase().replaceAll('.', '')) {
        'http1' || 'http11' || '1' || '11' => HttpProtocol.http1,
        'http2' || 'h2' || '2' => HttpProtocol.http2,
        'http3' || 'h3' || '3' => HttpProtocol.http3,
        _ => throw FormatException('$key must be http1/http2/http3, got "$v"'),
      };
    }

    TlsConfig? tls;
    final certFile = raw('TLS_CERT_FILE'), keyFile = raw('TLS_KEY_FILE');
    final certPem = raw('TLS_CERT_PEM'), keyPem = raw('TLS_KEY_PEM');
    if (certFile != null || keyFile != null) {
      if (certFile == null || keyFile == null) {
        throw const FormatException(
          'TLS_CERT_FILE and TLS_KEY_FILE must be set together',
        );
      }
      tls = TlsConfig(certFile: certFile, keyFile: keyFile);
    } else if (certPem != null || keyPem != null) {
      if (certPem == null || keyPem == null) {
        throw const FormatException(
          'TLS_CERT_PEM and TLS_KEY_PEM must be set together',
        );
      }
      tls = TlsConfig(certPem: certPem, keyPem: keyPem);
    }
    TlsVersion? minVersion;
    if (raw('TLS_MIN_VERSION') case final v?) {
      minVersion = switch (v.replaceAll('.', '').toLowerCase()) {
        '12' || 'tls12' || 'tlsv12' => TlsVersion.v12,
        '13' || 'tls13' || 'tlsv13' => TlsVersion.v13,
        _ => throw FormatException(
          'TLS_MIN_VERSION must be 1.2 or 1.3, got "$v"',
        ),
      };
    }
    final policy = <String, String?>{
      'ciphers': raw('TLS_CIPHERS'),
      'cipherSuites': raw('TLS_CIPHER_SUITES'),
      'clientCaFile': raw('TLS_CLIENT_CA_FILE'),
      'clientCaPem': raw('TLS_CLIENT_CA_PEM'),
    };
    if (minVersion != null || policy.values.any((v) => v != null)) {
      tls = (tls ?? base.tls).copyWith(
        minVersion: minVersion,
        ciphers: policy['ciphers'],
        cipherSuites: policy['cipherSuites'],
        clientCaFile: policy['clientCaFile'],
        clientCaPem: policy['clientCaPem'],
      );
    }

    return base.copyWith(
      host: raw('HOST'),
      port: asInt('PORT'),
      backlog: asInt('BACKLOG'),
      isolates: asInt('ISOLATES'),
      workerThreads: asInt('WORKER_THREADS'),
      maxBodyBytes: asInt('MAX_BODY_BYTES'),
      maxConnections: asInt('MAX_CONNECTIONS'),
      maxConnectionsPerIp: asInt('MAX_CONNECTIONS_PER_IP'),
      maxRequestsPerConnection: asInt('MAX_REQUESTS_PER_CONNECTION'),
      keepAliveTimeout: asMs('KEEP_ALIVE_TIMEOUT_MS'),
      defaultTimeout: asMs('DEFAULT_TIMEOUT_MS'),
      headerTimeout: asMs('HEADER_TIMEOUT_MS'),
      writeTimeout: asMs('WRITE_TIMEOUT_MS'),
      bodyTimeout: asMs('BODY_TIMEOUT_MS'),
      wsIdleTimeout: asMs('WS_IDLE_TIMEOUT_MS'),
      maxConnectionAge: asMs('MAX_CONNECTION_AGE_MS'),
      maxInFlightRequests: asInt('MAX_IN_FLIGHT_REQUESTS'),
      wsMaxBufferBytes: asInt('WS_MAX_BUFFER_BYTES'),
      streamIdleTimeout: asMs('STREAM_IDLE_TIMEOUT_MS'),
      streamMaxBufferBytes: asInt('STREAM_MAX_BUFFER_BYTES'),
      maxBufferedBodyBytes: asInt('MAX_BUFFERED_BODY_BYTES'),
      wsCompression: asBool('WS_COMPRESSION'),
      responseTiming: asBool('RESPONSE_TIMING'),
      exposeErrorDetails: asBool('EXPOSE_ERROR_DETAILS'),
      proxyProtocol: asBool('PROXY_PROTOCOL'),
      protocol: asProtocol('HTTP_PROTOCOL'),
      tls: tls,
    );
  }
}

/// Wraps a [RequestHandler]: logging, auth, CORS, compression — anything that
/// should run around many routes without editing each one.
///
/// ```dart
/// await server.use((request, next) async {
///   final started = DateTime.now();
///   try {
///     return await next(request);
///   } finally {
///     print('${request.path} took ${DateTime.now().difference(started)}');
///   }
/// });
/// ```
typedef Middleware =
    FutureOr<ResponseContext> Function(
      RequestContext request,
      RequestHandler next,
    );

/// One accepted request, delivered to a [RequestHandler].
class RequestContext {
  /// [_queryParameters] defaults to the parse of [query].
  RequestContext({
    required this.method,
    required this.customMethod,
    required this.path,
    required this.query,
    this._queryParameters,
    required Map<String, List<String>> this._headers,
    required this.params,
    required this.routePattern,
    required this.body,
    this.bodyStream,
    this.clientIp = '',
  }) : _packedHeaders = null;

  /// The runner's form: headers arrive packed (`name\u0000value` pairs
  /// joined by `\u0000`) and unpack on first use of [headers].
  RequestContext.packed({
    required this.method,
    required this.customMethod,
    required this.path,
    required this.query,
    required String this._packedHeaders,
    required this.params,
    required this.routePattern,
    required this.body,
    this.bodyStream,
    this.clientIp = '',
  }) : _headers = null,
       _queryParameters = null;

  final HttpMethod method;
  final String customMethod;
  final String path;
  final String query;
  final Map<String, String>? _queryParameters;
  final Map<String, List<String>>? _headers;
  final String? _packedHeaders;

  /// Query parameters, parsed from [query] on first access. Repeated keys
  /// collapse to the last value — use [queryParametersAll] to keep every value.
  late final Map<String, String> queryParameters =
      _queryParameters ?? _parseQuery(query);

  /// Malformed percent-encoding (`%zz`, a truncated `%E`) keeps the raw
  /// text instead of throwing: a client's bad escape is its own problem,
  /// never a 500 on this side.
  static Map<String, String> _parseQuery(String query) {
    if (query.isEmpty) return const {};
    try {
      return Uri.splitQueryString(query);
    } on ArgumentError {
      return {
        for (final e in _parseQueryAll(query).entries) e.key: e.value.last,
      };
    }
  }

  static String _decodeLenient(String component) {
    try {
      return Uri.decodeQueryComponent(component);
    } on ArgumentError {
      return component;
    }
  }

  /// Every query parameter value by name, repeats preserved (`?tag=a&tag=b` →
  /// `{'tag': ['a', 'b']}`); parsed from [query] on first access.
  late final Map<String, List<String>> queryParametersAll = _parseQueryAll(
    query,
  );

  static Map<String, List<String>> _parseQueryAll(String query) {
    if (query.isEmpty) return const {};
    final out = <String, List<String>>{};
    for (final pair in query.split('&')) {
      if (pair.isEmpty) continue;
      final eq = pair.indexOf('=');
      final key = eq == -1 ? pair : pair.substring(0, eq);
      final value = eq == -1 ? '' : pair.substring(eq + 1);
      (out[_decodeLenient(key)] ??= []).add(_decodeLenient(value));
    }
    return out;
  }

  /// Headers by lowercase name, unpacked on first access. A map passed to the
  /// plain constructor is lowercased here too, so [header] finds mixed-case
  /// keys (the `.packed` path already lowercases via [unpackHeaders]).
  late final Map<String, List<String>> headers = _headers == null
      ? unpackHeaders(_packedHeaders!)
      : {for (final e in _headers.entries) e.key.toLowerCase(): e.value};
  final Map<String, String> params;
  final String routePattern;

  /// The peer's IP (`127.0.0.1`, `::1`, …) as the engine read it off the
  /// socket, or empty when unavailable (the in-memory test client, or a
  /// platform that could not resolve it). This is the direct peer; behind a
  /// reverse proxy it is the proxy's address, so prefer `X-Forwarded-For`
  /// there.
  final String clientIp;

  /// The assembled body. Empty on a route registered with `streamBody`,
  /// where the bytes arrive on [bodyStream] instead.
  final Uint8List body;

  /// The body as it arrives, for routes registered with `streamBody: true`;
  /// null everywhere else. The handler runs as soon as the head is in, and
  /// the stream ends when the last byte has been read (or errors when the
  /// upload was cut short or exceeded `maxBodyBytes`).
  final Stream<Uint8List>? bodyStream;

  /// First value of [name], or null. Header names are lowercase.
  String? header(String name) {
    final values = headers[name.toLowerCase()];
    return values == null || values.isEmpty ? null : values.first;
  }

  /// First value of the query parameter [name], or null.
  String? queryParam(String name) => queryParameters[name];

  /// Every value of the query parameter [name], in order; empty when absent.
  List<String> queryParamAll(String name) =>
      queryParametersAll[name] ?? const [];

  /// The `:param` capture [name], or null when the route has no such segment.
  String? param(String name) => params[name];

  /// The body decoded as UTF-8 text.
  String text() => utf8.decode(body);

  /// Request cookies from the `cookie` header, by name. Values are returned
  /// as sent (cookie values are not percent-decoded by the protocol).
  Map<String, String> get cookies {
    final raw = header('cookie');
    if (raw == null || raw.isEmpty) return const {};
    final out = <String, String>{};
    for (final pair in raw.split(';')) {
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      out[pair.substring(0, eq).trim()] = pair.substring(eq + 1).trim();
    }
    return out;
  }

  /// The `multipart/form-data` parts of the body, in order. Throws
  /// [FormatException] when the request is not multipart, the body is
  /// malformed, or a limit is crossed ([maxParts] parts,
  /// [maxPartHeaderBytes] per part's headers — see [parseMultipart]).
  /// Fields have no [MultipartPart.filename]; uploads do.
  List<MultipartPart> multipart({
    int maxParts = 1000,
    int maxPartHeaderBytes = 8 * 1024,
  }) {
    final type = header('content-type');
    if (type == null) throw const FormatException('no content-type header');
    return parseMultipart(
      body,
      type,
      maxParts: maxParts,
      maxPartHeaderBytes: maxPartHeaderBytes,
    );
  }

  /// The body decoded as JSON. Untyped by nature; prefer [jsonMap], [jsonList]
  /// or [jsonAs] to get a checked type back. Decodes the UTF-8 bytes straight to
  /// JSON in one pass (see [_jsonFromUtf8]) — no intermediate `String`, ~1.3–1.4x
  /// faster than `jsonDecode(text())`; a malformed body throws [FormatException]
  /// exactly as before.
  dynamic json() => _jsonFromUtf8.convert(body);

  /// The body decoded as a JSON object. Throws [FormatException] when the
  /// body is valid JSON but not an object (e.g. an array or a string).
  Map<String, Object?> jsonMap() => jsonAs<Map<String, Object?>>();

  /// The body decoded as a JSON array. Throws [FormatException] when the
  /// body is valid JSON but not an array.
  List<Object?> jsonList() => jsonAs<List<Object?>>();

  /// The body decoded as JSON and checked to be a [T]: a typed alternative
  /// to [json] that fails loudly at the boundary instead of deep inside a
  /// handler. Throws [FormatException] on a type mismatch (malformed JSON
  /// throws the decoder's own [FormatException]).
  T jsonAs<T>() {
    final decoded = _jsonFromUtf8.convert(body);
    if (decoded is T) return decoded;
    throw FormatException(
      'expected JSON $T, got ${decoded.runtimeType}',
      text(),
    );
  }
}

/// UTF-8 bytes → JSON in a single pass, skipping the intermediate `String` that
/// `jsonDecode(utf8.decode(bytes))` allocates and re-scans. Built once (the
/// fused converter is stateless) and shared by every [RequestContext].
final Converter<List<int>, dynamic> _jsonFromUtf8 = const Utf8Decoder().fuse(
  const JsonDecoder(),
);

/// Default [ResponseContext.streamBufferSize] for the `stream`/`sse` factories:
/// coalesce events up to 64 KiB per event-loop turn into one bridge crossing.
/// Large enough to collapse a burst of tiny SSE events, small enough to bound a
/// single crossing; the turn-boundary flush keeps paced feeds real-time.
const int _defaultStreamBufferSize = 64 * 1024;

/// The answer a [RequestHandler] returns. One value or a byte stream: the
/// handler resolves one [ResponseContext] and the runner answers exactly
/// once — either a single body ([body]) or chunked transfer-encoding
/// ([bodyStream]). The two are mutually exclusive.
class ResponseContext {
  const ResponseContext({
    this.status = 200,
    this.headers = const {},
    this.body,
    this.bodyWriter,
    this.bodyStream,
    this.streamBufferSize = 0,
    this.filePath,
    this.fileOffset = 0,
    this.fileLength = -1,
    this.cookies = const [],
  }) : assert(status >= 100 && status <= 599, 'status out of range: $status'),
       assert(
         (body == null ? 0 : 1) +
                 (bodyWriter == null ? 0 : 1) +
                 (bodyStream == null ? 0 : 1) +
                 (filePath == null ? 0 : 1) <=
             1,
         'body, bodyWriter, bodyStream and filePath are mutually exclusive',
       ),
       assert(streamBufferSize >= 0, 'streamBufferSize < 0: $streamBufferSize'),
       assert(fileOffset >= 0, 'fileOffset < 0: $fileOffset');

  final int status;
  final Map<String, String> headers;
  final Uint8List? body;

  /// A [JsonWriter] whose native buffer IS the response body (win ③): the
  /// answerer sends it straight from native memory, and the runner disposes it
  /// after the (synchronous) respond — no `toBytes()` copy. Mutually exclusive
  /// with [body]/[bodyStream]/[filePath]. Falls back to [toBytes] on the slow
  /// (generated) answer path via [bodyBytes].
  ///
  /// Typed `Object?`, not `JsonWriter?`: a `Finalizable`-typed field in this
  /// const-constructor class trips a CFE incremental-compile bug (a spurious
  /// "const constructor can't have a body" surfaces across test files). Read it
  /// back with [bodyWriterOrNull].
  final Object? bodyWriter;

  /// The [bodyWriter] as a [JsonWriter] (see that field for why it is `Object?`).
  JsonWriter? get bodyWriterOrNull => bodyWriter as JsonWriter?;

  /// Cookies to set, each sent as its own `set-cookie` header (a header
  /// map cannot hold several).
  final List<SetCookie> cookies;

  /// A file to send as the body (see [ResponseContext.file]). The engine
  /// sends it from a native worker with `sendfile`, so the bytes never
  /// enter the Dart heap. Null for every other answer.
  final String? filePath;

  /// First byte of [filePath] to send.
  final int fileOffset;

  /// Bytes of [filePath] to send from [fileOffset]; `-1` means to the end.
  final int fileLength;

  /// Chunked body source. Null for one-shot answers. Empty chunks are
  /// skipped on the wire (a `0`-chunk would terminate the body); closing
  /// the stream — or a stream error — terminates it, so errors truncate
  /// rather than hang. The route timeout bounds time-to-first-byte only.
  final Stream<Uint8List>? bodyStream;

  /// Coalesces stream events into fewer wire chunks: events accumulate until
  /// [streamBufferSize] bytes are pending OR the event-loop turn ends,
  /// whichever comes first, then cross the bridge as one chunk; the remainder
  /// flushes when the stream ends. The turn-boundary flush means buffering
  /// never stalls a paced feed — each event still reaches the client on its
  /// own turn — so it is safe for real-time SSE, while a burst (e.g.
  /// `Stream.fromIterable`) collapses into one crossing instead of paying a
  /// native call per tiny event. The [ResponseContext.stream]/[sse] factories
  /// default to coalescing ([_defaultStreamBufferSize]); zero forwards every
  /// event immediately (strict per-event, no turn-coalescing) for feeds that
  /// must put each event on the wire the instant it is produced.
  final int streamBufferSize;

  /// True when this answer streams ([bodyStream] != null).
  bool get isStream => bodyStream != null;

  /// This answer with header [name] set to [value] (replacing any existing
  /// value). Keeps the body, stream, file and cookies intact.
  ResponseContext withHeader(String name, String value) =>
      copyWith(headers: {...headers, name: value});

  /// This answer with [cookie] added to its `Set-Cookie` list. Keeps the
  /// body, stream, writer and file intact.
  ResponseContext withCookie(SetCookie cookie) =>
      copyWith(cookies: [...cookies, cookie]);

  /// A copy with [status] and/or [headers] replaced, carrying over every
  /// body-bearing field — the one-shot [body], the [bodyStream] and its
  /// [streamBufferSize], the [filePath] and its range — plus [cookies].
  /// Middleware that only augments headers (CORS, security headers) MUST use
  /// this: rebuilding via the constructor and copying just `body` silently
  /// drops a streaming, SSE or file answer (and any set-cookies), so the
  /// response goes out empty. See [withHeader] for a single header.
  ResponseContext copyWith({
    int? status,
    Map<String, String>? headers,
    List<SetCookie>? cookies,
  }) => ResponseContext(
    status: status ?? this.status,
    headers: headers ?? this.headers,
    body: body,
    bodyWriter: bodyWriter,
    bodyStream: bodyStream,
    streamBufferSize: streamBufferSize,
    filePath: filePath,
    fileOffset: fileOffset,
    fileLength: fileLength,
    cookies: cookies ?? this.cookies,
  );

  /// True when this answer is a file ([filePath] != null).
  bool get isFile => filePath != null;

  /// Answers with the bytes of the file at [path], read and written by the
  /// engine on the connection's loop thread in 256 KiB chunks, each read only
  /// once the previous write has drained — the file never crosses into Dart,
  /// a slow reader holds one chunk, and a file larger than memory is fine
  /// (over HTTP/2 the range is buffered per stream, see doc/http2.md). A
  /// missing or unreadable path, or anything that is not a regular file (a
  /// directory, a FIFO), answers 404. [offset] and [length]
  /// select a byte range (`length` `-1` means to the end); the caller sets
  /// the matching status and `content-range` — [staticFiles] does all of
  /// that for a directory.
  factory ResponseContext.file(
    String path, {
    int status = 200,
    Map<String, String> headers = const {},
    String contentType = 'application/octet-stream',
    int offset = 0,
    int length = -1,
  }) {
    return ResponseContext(
      status: status,
      headers: {'content-type': contentType, ...headers},
      filePath: path,
      fileOffset: offset,
      fileLength: length,
    );
  }

  factory ResponseContext.text(
    String text, {
    int status = 200,
    Map<String, String> headers = const {},
    String contentType = 'text/plain; charset=utf-8',
  }) {
    // UTF-8, not `text.codeUnits` (UTF-16): non-ASCII text such as emoji must
    // survive the wire. (`utf8.encode` returns the bytes directly, no extra
    // copy on either side of this call.)
    final encoded = utf8.encode(text);
    return ResponseContext(
      status: status,
      headers: {'content-type': contentType, ...headers},
      body: encoded,
    );
  }

  factory ResponseContext.json(
    String encoded, {
    int status = 200,
    Map<String, String> headers = const {},
  }) {
    return ResponseContext.text(
      encoded,
      status: status,
      headers: headers,
      contentType: 'application/json; charset=utf-8',
    );
  }

  /// Encodes [data] with `jsonEncode` and answers it as JSON. Prefer this
  /// over [json] with a hand-encoded string: one call, no forgotten
  /// `jsonEncode`, same bytes on the wire.
  factory ResponseContext.jsonMap(
    Map<String, Object?> data, {
    int status = 200,
    Map<String, String> headers = const {},
  }) {
    return ResponseContext.jsonBody(data, status: status, headers: headers);
  }

  /// Serializes a JSON response with a native [JsonWriter], driven by [build].
  /// On large payloads this is ~2.5x faster than [jsonBody] (which goes through
  /// dart:convert): the bytes are built in a C++ buffer and cross into Dart
  /// once. Prefer it for hot JSON handlers; [jsonBody] is simpler for one-offs.
  ///
  /// ```dart
  /// ResponseContext.jsonWriter((w) {
  ///   w..beginObject()..key('id')..writeInt(42)..endObject();
  /// });
  /// ```
  factory ResponseContext.jsonWriter(
    void Function(JsonWriter writer) build, {
    int status = 200,
    Map<String, String> headers = const {},
  }) {
    final w = JsonWriter.checkout();
    try {
      build(w);
    } catch (_) {
      w.release();
      rethrow;
    }
    // Hand the live writer to the runner (win ③): the answerer sends its native
    // buffer straight to the engine and disposes it after respond — no toBytes()
    // copy. The NativeFinalizer frees it if the response is never answered.
    return ResponseContext(
      status: status,
      headers: {'content-type': 'application/json; charset=utf-8', ...headers},
      bodyWriter: w,
    );
  }

  /// Encodes any JSON-encodable [data] (maps, lists, nested values) and
  /// answers it as JSON. The general form of [jsonMap].
  ///
  /// Encodes straight to UTF-8 bytes in a single pass with [JsonUtf8Encoder],
  /// skipping the intermediate String that `jsonEncode` + `utf8.encode` would
  /// allocate and re-scan — ~1.8x faster on large payloads, byte-identical on
  /// the wire. Prefer this over [json] with a hand-encoded string.
  factory ResponseContext.jsonBody(
    Object data, {
    int status = 200,
    Map<String, String> headers = const {},
  }) {
    // JsonUtf8Encoder.convert always returns a Uint8List (a byte view over its
    // encoded output); the cast keeps it zero-copy and avoids a dead branch.
    final bytes = JsonUtf8Encoder().convert(data) as Uint8List;
    return ResponseContext(
      status: status,
      headers: {'content-type': 'application/json; charset=utf-8', ...headers},
      body: bytes,
    );
  }

  /// An [RFC 7807](https://www.rfc-editor.org/rfc/rfc7807) `problem+json` error
  /// — the standard machine-readable error body. [title] is a short summary,
  /// [status] the HTTP code (default 400); [type] is a URI identifying the
  /// problem kind (default `about:blank`), [detail] a human explanation,
  /// [instance] a URI for this occurrence. [extensions] adds custom members.
  ///
  /// ```dart
  /// return ResponseContext.problem(
  ///   title: 'Invalid body', status: 422, detail: 'name is required',
  /// );
  /// ```
  factory ResponseContext.problem({
    required String title,
    int status = 400,
    String type = 'about:blank',
    String? detail,
    String? instance,
    Map<String, Object?> extensions = const {},
    Map<String, String> headers = const {},
  }) {
    final body = <String, Object?>{
      'type': type,
      'title': title,
      'status': status,
      'detail': ?detail,
      'instance': ?instance,
      ...extensions,
    };
    final bytes = JsonUtf8Encoder().convert(body) as Uint8List;
    return ResponseContext(
      status: status,
      headers: {
        'content-type': 'application/problem+json; charset=utf-8',
        ...headers,
      },
      body: bytes,
    );
  }

  /// Answers a redirect to [url] with an empty body. [status] must be one of
  /// the redirect codes (301, 302, 303, 307, 308); the default is 302.
  factory ResponseContext.redirect(String url, {int status = 302}) {
    assert(
      status == 301 ||
          status == 302 ||
          status == 303 ||
          status == 307 ||
          status == 308,
      'redirect status must be 301/302/303/307/308, got $status',
    );
    return ResponseContext(status: status, headers: {'location': url});
  }

  /// Answers an HTML page.
  factory ResponseContext.html(
    String html, {
    int status = 200,
    Map<String, String> headers = const {},
  }) {
    return ResponseContext.text(
      html,
      status: status,
      headers: headers,
      contentType: 'text/html; charset=utf-8',
    );
  }

  factory ResponseContext.bytes(
    Uint8List body, {
    int status = 200,
    Map<String, String> headers = const {},
    String contentType = 'application/octet-stream',
  }) {
    return ResponseContext(
      status: status,
      headers: {'content-type': contentType, ...headers},
      body: body,
    );
  }

  /// Answers a chunked (`Transfer-Encoding: chunked`) stream. Each event is
  /// one chunk; the stream's end — clean or by error — terminates the body.
  /// Framing headers (`content-length`, `transfer-encoding`, `connection`)
  /// are engine-owned and ignored if passed.
  ///
  /// [bufferSize] coalesces tiny events into fewer bridge crossings (see
  /// [streamBufferSize]) — it defaults to coalescing because each event
  /// otherwise pays a full native call, which dominates under load. Buffering
  /// is turn-safe: a burst collapses into one crossing while a paced feed
  /// still flushes on its own event-loop turn (never stalling). Pass
  /// `bufferSize: 0` for strict per-event delivery when the consumer must see
  /// every event the instant it is produced.
  ///
  /// ```dart
  /// await server.get('/events', (_) async {
  ///   return ResponseContext.stream(
  ///     Stream.periodic(
  ///       const Duration(milliseconds: 100),
  ///       (i) => utf8.encode('data: $i\n\n'),
  ///     ).take(10),
  ///     contentType: 'text/event-stream',
  ///   );
  /// });
  /// ```
  factory ResponseContext.stream(
    Stream<Uint8List> data, {
    int status = 200,
    Map<String, String> headers = const {},
    String contentType = 'application/octet-stream',
    int bufferSize = _defaultStreamBufferSize,
  }) {
    return ResponseContext(
      status: status,
      headers: {'content-type': contentType, ...headers},
      bodyStream: data,
      streamBufferSize: bufferSize,
    );
  }

  /// Server-Sent Events (`text/event-stream`): each [SseEvent] is encoded and
  /// streamed to the client as it arrives (unbuffered, so events are not
  /// delayed). Sets `cache-control: no-cache`.
  ///
  /// ```dart
  /// await server.get('/events', (_) => ResponseContext.sse(
  ///   Stream.periodic(const Duration(seconds: 1), (i) => SseEvent('tick $i')),
  /// ));
  /// ```
  ///
  /// [bufferSize] coalesces events emitted in the same event-loop turn into
  /// one bridge crossing (see [streamBufferSize]); it defaults to coalescing
  /// — turn-safe, so a paced feed still flushes each event on its own turn.
  /// Pass `bufferSize: 0` for strict per-event delivery.
  factory ResponseContext.sse(
    Stream<SseEvent> events, {
    Map<String, String> headers = const {},
    int bufferSize = _defaultStreamBufferSize,
  }) {
    return ResponseContext(
      headers: {
        'content-type': 'text/event-stream; charset=utf-8',
        'cache-control': 'no-cache',
        ...headers,
      },
      bodyStream: events.map(
        (e) => Uint8List.fromList(utf8.encode(e.encode())),
      ),
      streamBufferSize: bufferSize,
    );
  }

  /// The bytes placed on the wire (empty for a null body). The empty body is
  /// one shared instance — treat it as immutable. A [bodyWriter] is copied out
  /// here only for the slow (generated) answer path; the fast answerer reads
  /// the writer's native buffer directly (win ③).
  Uint8List get bodyBytes => body ?? bodyWriterOrNull?.toBytes() ?? _emptyBody;

  static final Uint8List _emptyBody = Uint8List(0);
}

/// One Server-Sent Event (see [ResponseContext.sse]). [data] is the payload
/// (multi-line data is split into one `data:` line each); [event], [id] and
/// [retry] are the optional SSE fields.
class SseEvent {
  const SseEvent(this.data, {this.event, this.id, this.retry});

  final String data;
  final String? event;
  final String? id;
  final Duration? retry;

  /// The wire form: optional `event:`/`id:`/`retry:` lines, one `data:` line
  /// per line of [data], terminated by a blank line.
  String encode() {
    final b = StringBuffer();
    // Strip CR/LF from the single-line fields: an embedded newline would inject
    // extra SSE fields or end the event early (field injection). `data` is
    // split per line below, so it is safe — split on every SSE line terminator
    // (\r\n, \r, \n), not just \n.
    final ev = event?.replaceAll(_crlf, '');
    final eid = id?.replaceAll(_crlf, '');
    if (ev != null) b.write('event: $ev\n');
    if (eid != null) b.write('id: $eid\n');
    if (retry != null) b.write('retry: ${retry!.inMilliseconds}\n');
    for (final line in data.split(_sseLineBreak)) {
      b.write('data: $line\n');
    }
    b.write('\n');
    return b.toString();
  }

  static final _crlf = RegExp(r'[\r\n]');
  static final _sseLineBreak = RegExp(r'\r\n|\r|\n');
}

/// Answers one request. Sync or async: a handler returning a
/// [ResponseContext] directly skips an event-loop turn — the runner invokes
/// it through `Future.sync`, so a synchronously-throwing handler still ends
/// as a 500. The route timeout bounds it: a handler that outlives its
/// deadline loses — the client already got a 408 and the late value is
/// dropped, never sent twice.
typedef RequestHandler =
    FutureOr<ResponseContext> Function(RequestContext request);

/// Answers a request no route matched. Sync or async; throwing falls back to
/// an empty 404 — a custom page must never wedge dispatch.
typedef NotFoundHandler =
    FutureOr<ResponseContext> Function(RequestContext request);

/// Answers a request whose handler threw. Sync or async; throwing falls back
/// to the default 500 text body.
typedef ErrorHandler =
    FutureOr<ResponseContext> Function(Object error, RequestContext request);

/// Inverse of the runner's header packing: `name\u0000value` pairs joined
/// by `\u0000` become a map by lowercase name, values in arrival order.
Map<String, List<String>> unpackHeaders(String packed) {
  if (packed.isEmpty) return const {};
  final out = <String, List<String>>{};
  var start = 0;
  while (start <= packed.length) {
    final nameEnd = packed.indexOf('\u0000', start);
    if (nameEnd < 0) break;
    var valueEnd = packed.indexOf('\u0000', nameEnd + 1);
    if (valueEnd < 0) valueEnd = packed.length;
    (out[_lowerHeaderName(packed.substring(start, nameEnd))] ??= []).add(
      packed.substring(nameEnd + 1, valueEnd),
    );
    start = valueEnd + 1;
  }
  return out;
}

/// Lowercases a header name, fast-pathing the already-lowercase case.
String _lowerHeaderName(String name) {
  for (var i = 0; i < name.length; i++) {
    final unit = name.codeUnitAt(i);
    if (unit >= 0x41 && unit <= 0x5A) return name.toLowerCase();
  }
  return name;
}

/// `SameSite` policy of a [SetCookie].
enum SameSite { strict, lax, none }

/// One `set-cookie` header, built from typed attributes.
class SetCookie {
  const SetCookie(
    this.name,
    this.value, {
    this.maxAge,
    this.expires,
    this.domain,
    this.path = '/',
    this.secure = false,
    this.httpOnly = false,
    this.sameSite,
  });

  final String name;
  final String value;
  final Duration? maxAge;
  final DateTime? expires;
  final String? domain;
  final String path;
  final bool secure;
  final bool httpOnly;
  final SameSite? sameSite;

  /// The header value, e.g. `id=42; Path=/; Max-Age=3600; HttpOnly`.
  /// Why this cookie cannot go on the wire, or null when it can: the name
  /// must be an HTTP token, the value cookie-octets (no control bytes,
  /// whitespace, `"`, `,`, `;` or `\`), and the domain/path attributes free
  /// of control bytes and `;` (RFC 6265 §4.1.1). A violating cookie would let
  /// attacker-influenced data split the response or inject attributes; the
  /// runner refuses such an answer with a 500 and a `handlerError` event.
  String? get validationError {
    if (name.isEmpty) return 'empty cookie name';
    for (final c in name.codeUnits) {
      final token =
          (c >= 0x30 && c <= 0x39) ||
          (c >= 0x41 && c <= 0x5a) ||
          (c >= 0x61 && c <= 0x7a) ||
          c == 0x21 ||
          (c >= 0x23 && c <= 0x27) ||
          c == 0x2a ||
          c == 0x2b ||
          c == 0x2d ||
          c == 0x2e ||
          c == 0x5e ||
          c == 0x5f ||
          c == 0x60 ||
          c == 0x7c ||
          c == 0x7e;
      if (!token) return 'cookie name "$name" is not a token';
    }
    for (final c in value.codeUnits) {
      final octet =
          c == 0x21 ||
          (c >= 0x23 && c <= 0x2b) ||
          (c >= 0x2d && c <= 0x3a) ||
          (c >= 0x3c && c <= 0x5b) ||
          (c >= 0x5d && c <= 0x7e);
      if (!octet) {
        return 'cookie "$name" value has a byte that is not a cookie-octet';
      }
    }
    for (final attr in [domain, path]) {
      if (attr == null) {
        continue;
      }
      for (final c in attr.codeUnits) {
        if (c < 0x20 || c == 0x7f || c == 0x3b) {
          return 'cookie "$name" attribute has a control byte or ";"';
        }
      }
    }
    return null;
  }

  String toHeaderValue() {
    final out = StringBuffer('$name=$value');
    if (expires case final expires?) {
      out.write('; Expires=${_httpDate(expires)}');
    }
    if (maxAge case final maxAge?) out.write('; Max-Age=${maxAge.inSeconds}');
    if (domain case final domain?) out.write('; Domain=$domain');
    out.write('; Path=$path');
    if (secure) out.write('; Secure');
    if (httpOnly) out.write('; HttpOnly');
    if (sameSite case final sameSite?) {
      out.write('; SameSite=${_sameSiteNames[sameSite]}');
    }
    return out.toString();
  }

  static const _sameSiteNames = {
    SameSite.strict: 'Strict',
    SameSite.lax: 'Lax',
    SameSite.none: 'None',
  };

  @override
  String toString() => 'SetCookie(${toHeaderValue()})';
}

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// RFC 9110 IMF-fixdate, e.g. `Sun, 06 Nov 1994 08:49:37 GMT`.
String _httpDate(DateTime time) {
  final utc = time.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${_weekdays[utc.weekday - 1]}, ${two(utc.day)} '
      '${_months[utc.month - 1]} ${utc.year} '
      '${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)} GMT';
}

/// RFC 9110 IMF-fixdate formatting, shared with [staticFiles].
String httpDate(DateTime time) => _httpDate(time);
