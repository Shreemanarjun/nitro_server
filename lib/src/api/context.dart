/// Request/response types for route handlers.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'http_method.dart';

/// Identity for server TLS. Empty means plain HTTP; any field set requires a
/// build with TLS support, otherwise `start()` throws [ServerTlsException].
class TlsConfig {
  const TlsConfig({
    this.certPem = '',
    this.keyPem = '',
    this.certFile = '',
    this.keyFile = '',
  });

  final String certPem;
  final String keyPem;
  final String certFile;
  final String keyFile;

  bool get enabled =>
      certPem.isNotEmpty ||
      keyPem.isNotEmpty ||
      certFile.isNotEmpty ||
      keyFile.isNotEmpty;
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
    this.tls = const TlsConfig(),
  })  : assert(port >= 0 && port <= 65535, 'port out of range: $port'),
        assert(backlog > 0, 'backlog must be positive'),
        assert(maxBodyBytes > 0, 'maxBodyBytes must be positive'),
        assert(maxRequestsPerConnection >= 0, 'maxRequestsPerConnection must be non-negative'),
        assert(workerThreads >= 0, 'workerThreads must be non-negative');

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

  /// Native worker threads serving connections. `0` means one per CPU core.
  final int workerThreads;
  final TlsConfig tls;

  /// A copy with any of [host], [port], [backlog], [maxBodyBytes],
  /// [defaultTimeout], [keepAliveTimeout], [maxRequestsPerConnection],
  /// [workerThreads] or [tls] replaced.
  ServerConfig copyWith({
    String? host,
    int? port,
    int? backlog,
    int? maxBodyBytes,
    Duration? defaultTimeout,
    Duration? keepAliveTimeout,
    int? maxRequestsPerConnection,
    int? workerThreads,
    TlsConfig? tls,
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
      tls: tls ?? this.tls,
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
typedef Middleware = FutureOr<ResponseContext> Function(
  RequestContext request,
  RequestHandler next,
);

/// One accepted request, delivered to a [RequestHandler].
class RequestContext {
  const RequestContext({
    required this.method,
    required this.customMethod,
    required this.path,
    required this.query,
    required this.queryParameters,
    required this.headers,
    required this.params,
    required this.routePattern,
    required this.body,
  });

  final HttpMethod method;
  final String customMethod;
  final String path;
  final String query;
  final Map<String, String> queryParameters;
  final Map<String, List<String>> headers;
  final Map<String, String> params;
  final String routePattern;
  final Uint8List body;

  /// First value of [name], or null. Header names are lowercase.
  String? header(String name) {
    final values = headers[name.toLowerCase()];
    return values == null || values.isEmpty ? null : values.first;
  }

  /// First value of the query parameter [name], or null.
  String? queryParam(String name) => queryParameters[name];

  /// The `:param` capture [name], or null when the route has no such segment.
  String? param(String name) => params[name];

  /// The body decoded as UTF-8 text.
  String text() => utf8.decode(body);

  /// The body decoded as JSON (`jsonDecode` of [text]).
  dynamic json() => jsonDecode(text());
}

/// The answer a [RequestHandler] returns. There is no streaming-response half:
/// the handler resolves one value and the runner answers exactly once.
class ResponseContext {
  const ResponseContext({
    this.status = 200,
    this.headers = const {},
    this.body,
  }) : assert(status >= 100 && status <= 599, 'status out of range: $status');

  final int status;
  final Map<String, String> headers;
  final Uint8List? body;

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

  /// Encodes any JSON-encodable [data] (maps, lists, nested values) and
  /// answers it as JSON. The general form of [jsonMap].
  factory ResponseContext.jsonBody(
    Object data, {
    int status = 200,
    Map<String, String> headers = const {},
  }) {
    return ResponseContext.json(
      jsonEncode(data),
      status: status,
      headers: headers,
    );
  }

  /// Answers a redirect to [url] with an empty body. [status] must be one of
  /// the redirect codes (301, 302, 303, 307, 308); the default is 302.
  factory ResponseContext.redirect(String url, {int status = 302}) {
    assert(
      status == 301 || status == 302 || status == 303 || status == 307 ||
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

  /// The bytes placed on the wire (empty for a null body). The empty body is
  /// one shared instance — treat it as immutable.
  Uint8List get bodyBytes => body ?? _emptyBody;

  static final Uint8List _emptyBody = Uint8List(0);
}

/// Answers one request. Sync or async: a handler returning a
/// [ResponseContext] directly skips an event-loop turn — the runner invokes
/// it through `Future.sync`, so a synchronously-throwing handler still ends
/// as a 500. The route timeout bounds it: a handler that outlives its
/// deadline loses — the client already got a 408 and the late value is
/// dropped, never sent twice.
typedef RequestHandler = FutureOr<ResponseContext> Function(
  RequestContext request,
);

/// Answers a request no route matched. Sync or async; throwing falls back to
/// an empty 404 — a custom page must never wedge dispatch.
typedef NotFoundHandler = FutureOr<ResponseContext> Function(
  RequestContext request,
);

/// Answers a request whose handler threw. Sync or async; throwing falls back
/// to the default 500 text body.
typedef ErrorHandler = FutureOr<ResponseContext> Function(
  Object error,
  RequestContext request,
);
