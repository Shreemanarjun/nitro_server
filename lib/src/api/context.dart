/// Request/response types for route handlers.
library;

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
  const ServerConfig({
    this.host = '127.0.0.1',
    this.port = 0,
    this.backlog = 128,
    this.maxBodyBytes = 10 * 1024 * 1024,
    this.defaultTimeout = const Duration(seconds: 30),
    this.tls = const TlsConfig(),
  })  : assert(port >= 0 && port <= 65535, 'port out of range: $port'),
        assert(backlog > 0, 'backlog must be positive'),
        assert(maxBodyBytes > 0, 'maxBodyBytes must be positive');

  final String host;
  final int port;
  final int backlog;
  final int maxBodyBytes;
  final Duration defaultTimeout;
  final TlsConfig tls;
}

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

  /// The `:param` capture [name], or null when the route has no such segment.
  String? param(String name) => params[name];
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
    return ResponseContext(
      status: status,
      headers: {'content-type': contentType, ...headers},
      body: Uint8List.fromList(text.codeUnits),
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

  /// The bytes placed on the wire (empty for a null body).
  Uint8List get bodyBytes => body ?? Uint8List(0);
}

/// Answers one request. May be async; the route timeout bounds it — a handler
/// that outlives its deadline loses: the client already got a 408 and the
/// late value is dropped, never sent twice.
typedef RequestHandler = Future<ResponseContext> Function(
  RequestContext request,
);
