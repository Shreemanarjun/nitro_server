/// Request/response types for route handlers.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'http_method.dart';
import 'multipart.dart';

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
    this.isolates = 1,
    this.maxConnections = 0,
    this.maxConnectionsPerIp = 0,
    this.headerTimeout = Duration.zero,
    this.writeTimeout = const Duration(seconds: 30),
    this.wsMaxBufferBytes = 1024 * 1024,
    this.wsCompression = true,
    this.tls = const TlsConfig(),
  }) : assert(port >= 0 && port <= 65535, 'port out of range: $port'),
       assert(wsMaxBufferBytes > 0, 'wsMaxBufferBytes must be positive'),
       assert(isolates >= 0, 'isolates must be non-negative'),
       assert(maxConnections >= 0, 'maxConnections must be non-negative'),
       assert(
         maxConnectionsPerIp >= 0,
         'maxConnectionsPerIp must be non-negative',
       ),
       assert(backlog > 0, 'backlog must be positive'),
       assert(maxBodyBytes > 0, 'maxBodyBytes must be positive'),
       assert(
         maxRequestsPerConnection >= 0,
         'maxRequestsPerConnection must be non-negative',
       ),
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

  /// Cap on the native worker pool. The pool starts at one thread per CPU
  /// core and grows on demand up to this cap (idle threads above the floor
  /// retire after 10 s). `0` means `max(64, 4 × cores)`.
  final int workerThreads;

  /// Dart isolates running handlers behind this server. `1` (default) runs
  /// everything on the calling isolate. Above 1, requests are dealt
  /// round-robin across that many isolates — the only way past a single
  /// isolate's throughput ceiling — and routes must be registered by the
  /// `setup` function passed to [NitroServer.bind], which runs once per
  /// isolate. `0` picks a size from the CPU count (half the cores, 1–8).
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
  final TlsConfig tls;

  /// A copy with any of [host], [port], [backlog], [maxBodyBytes],
  /// [defaultTimeout], [keepAliveTimeout], [maxRequestsPerConnection],
  /// [workerThreads], [isolates], [maxConnections], [maxConnectionsPerIp],
  /// [headerTimeout], [writeTimeout], [wsMaxBufferBytes], [wsCompression]
  /// or [tls] replaced.
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
      isolates: isolates ?? this.isolates,
      maxConnections: maxConnections ?? this.maxConnections,
      maxConnectionsPerIp: maxConnectionsPerIp ?? this.maxConnectionsPerIp,
      headerTimeout: headerTimeout ?? this.headerTimeout,
      writeTimeout: writeTimeout ?? this.writeTimeout,
      wsMaxBufferBytes: wsMaxBufferBytes ?? this.wsMaxBufferBytes,
      wsCompression: wsCompression ?? this.wsCompression,
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
typedef Middleware =
    FutureOr<ResponseContext> Function(
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
    this.bodyStream,
  });

  final HttpMethod method;
  final String customMethod;
  final String path;
  final String query;
  final Map<String, String> queryParameters;
  final Map<String, List<String>> headers;
  final Map<String, String> params;
  final String routePattern;

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
  /// [FormatException] when the request is not multipart or the body is
  /// malformed. Fields have no [MultipartPart.filename]; uploads do.
  List<MultipartPart> multipart() {
    final type = header('content-type');
    if (type == null) throw const FormatException('no content-type header');
    return parseMultipart(body, type);
  }

  /// The body decoded as JSON (`jsonDecode` of [text]). Untyped by nature;
  /// prefer [jsonMap], [jsonList] or [jsonAs] to get a checked type back.
  dynamic json() => jsonDecode(text());

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
    final decoded = jsonDecode(text());
    if (decoded is T) return decoded;
    throw FormatException(
      'expected JSON $T, got ${decoded.runtimeType}',
      text(),
    );
  }
}

/// The answer a [RequestHandler] returns. One value or a byte stream: the
/// handler resolves one [ResponseContext] and the runner answers exactly
/// once — either a single body ([body]) or chunked transfer-encoding
/// ([bodyStream]). The two are mutually exclusive.
class ResponseContext {
  const ResponseContext({
    this.status = 200,
    this.headers = const {},
    this.body,
    this.bodyStream,
    this.streamBufferSize = 0,
    this.filePath,
    this.fileOffset = 0,
    this.fileLength = -1,
    this.cookies = const [],
  }) : assert(status >= 100 && status <= 599, 'status out of range: $status'),
       assert(
         (body == null ? 0 : 1) +
                 (bodyStream == null ? 0 : 1) +
                 (filePath == null ? 0 : 1) <=
             1,
         'body, bodyStream and filePath are mutually exclusive',
       ),
       assert(streamBufferSize >= 0, 'streamBufferSize < 0: $streamBufferSize'),
       assert(fileOffset >= 0, 'fileOffset < 0: $fileOffset');

  final int status;
  final Map<String, String> headers;
  final Uint8List? body;

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
  /// [streamBufferSize] bytes are pending, then cross the bridge as one
  /// chunk; the remainder flushes when the stream ends. Zero (the default)
  /// forwards every event immediately — the right choice for real-time
  /// feeds (SSE), where delaying bytes to fill a buffer breaks semantics.
  /// Set it for throughput-oriented streams whose events are tiny: twenty
  /// 8-byte SSE events cost twenty bridge crossings unbuffered, one
  /// buffered. Batching delays bytes until the buffer fills or the stream
  /// ends — never use it when the consumer waits on each event.
  final int streamBufferSize;

  /// True when this answer streams ([bodyStream] != null).
  bool get isStream => bodyStream != null;

  /// This answer plus [cookie] (see [cookies]).
  ResponseContext withCookie(SetCookie cookie) => ResponseContext(
    status: status,
    headers: headers,
    body: body,
    bodyStream: bodyStream,
    streamBufferSize: streamBufferSize,
    filePath: filePath,
    fileOffset: fileOffset,
    fileLength: fileLength,
    cookies: [...cookies, cookie],
  );

  /// True when this answer is a file ([filePath] != null).
  bool get isFile => filePath != null;

  /// Answers with the bytes of the file at [path], sent by the native
  /// worker (`sendfile` on macOS and Linux) — the file never crosses into
  /// Dart. A missing or unreadable file answers 404. [offset] and [length]
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
  /// Pass [bufferSize] to coalesce tiny events into fewer bridge crossings
  /// (see [streamBufferSize]); leave it zero for real-time feeds.
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
    int bufferSize = 0,
  }) {
    return ResponseContext(
      status: status,
      headers: {'content-type': contentType, ...headers},
      bodyStream: data,
      streamBufferSize: bufferSize,
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
