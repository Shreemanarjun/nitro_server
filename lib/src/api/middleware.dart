/// Built-in middleware.
library;

import 'dart:io' show GZipCodec;
import 'dart:typed_data';

import 'context.dart';
import 'http_method.dart';

/// Apache-style access log, one line per answered request:
///
/// ```text
/// 127.0.0.1 "GET /users/42" 200 3ms
/// ```
///
/// [sink] defaults to `print` — fine for development, but pass a real logger
/// in production (the line is formatted before the call, so any
/// `void Function(String)` works).
Middleware accessLog({void Function(String line)? sink}) {
  final log =
      // ignore: avoid_print
      sink ?? ((line) => print(line));
  return (request, next) async {
    final stopwatch = Stopwatch()..start();
    try {
      final response = await next(request);
      stopwatch.stop();
      final method = request.method == HttpMethod.custom
          ? request.customMethod
          : request.method.token;
      log(
        '"$method ${request.path}" ${response.status} '
        '${stopwatch.elapsed.inMilliseconds}ms',
      );
      return response;
    } catch (error) {
      stopwatch.stop();
      log('"${request.path}" 500 ${stopwatch.elapsed.inMilliseconds}ms');
      rethrow;
    }
  };
}

/// Cross-origin resource sharing: answers preflight `OPTIONS` requests with
/// the given policy (204, no handler call) and stamps the CORS headers on
/// every other response. Handler-set headers win on collision, so a route
/// can refine the policy per response.
///
/// ```dart
/// await server.use(cors(allowOrigin: 'https://example.com'));
/// ```
Middleware cors({
  String allowOrigin = '*',
  String allowMethods = 'GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS',
  String allowHeaders = '*',
  bool allowCredentials = false,
  Duration? maxAge = const Duration(days: 1),
}) {
  final policy = <String, String>{
    'access-control-allow-origin': allowOrigin,
    'access-control-allow-methods': allowMethods,
    'access-control-allow-headers': allowHeaders,
    if (allowCredentials) 'access-control-allow-credentials': 'true',
    if (maxAge != null && maxAge > Duration.zero)
      'access-control-max-age': '${maxAge.inSeconds}',
  };
  return (request, next) async {
    if (request.method == HttpMethod.options) {
      // Preflight: the policy IS the answer; the route never runs.
      return ResponseContext(status: 204, headers: policy);
    }
    final response = await next(request);
    return ResponseContext(
      status: response.status,
      headers: {...policy, ...response.headers},
      body: response.body,
    );
  };
}

/// Content types worth compressing: text and the structured-text formats.
/// Images, video and archives are already compressed.
const _compressibleTypes = {
  'text/',
  'application/json',
  'application/javascript',
  'application/xml',
  'application/xhtml+xml',
  'application/rss+xml',
  'application/atom+xml',
  'application/wasm',
  'image/svg+xml',
};

/// gzip response compression, negotiated per request: applies when the
/// client sends `Accept-Encoding: gzip`, the answer is a one-shot body of
/// at least [minBytes] with a compressible `content-type` (text, JSON,
/// JavaScript, XML, SVG, WASM by default; [contentTypes] overrides, matched
/// by prefix) and no `content-encoding` yet. Streams and file answers pass
/// through untouched. Compressed answers carry `content-encoding: gzip`
/// and `vary: accept-encoding`.
///
/// The codec is `dart:io`'s zlib (system zlib under the hood), run on the
/// isolate: cheap for the bodies this applies to, and still far less than the
/// bytes it saves on the wire.
///
/// [level] (1–9) trades CPU for ratio. The default is 1 — for live response
/// compression that is the right trade: on structured text (JSON, HTML) zlib
/// level 1 runs ~2–3x faster than the level-6 default for a sub-percent larger
/// output, because levels 1–3 use zlib's fast `deflate_fast` and 4+ the slow
/// lazy match. Measured on an 11.6 KB JSON body: L1 17 us / 9.4%, L6 48 us /
/// 9.5%. Raise it toward 9 when the response is cached and ratio matters more
/// than per-request CPU (nginx and Cloudflare likewise default on-the-fly
/// compression to a low level).
Middleware compress({
  int minBytes = 1024,
  int level = 1,
  Set<String> contentTypes = _compressibleTypes,
}) {
  final codec = GZipCodec(level: level);
  return (request, next) async {
    final response = await next(request);
    final body = response.body;
    if (body == null || body.length < minBytes) return response;
    final accept = request.header('accept-encoding') ?? '';
    if (!accept.toLowerCase().contains('gzip')) return response;
    final headers = response.headers;
    final type = _headerValue(headers, 'content-type') ?? '';
    if (_headerValue(headers, 'content-encoding') != null) return response;
    if (!contentTypes.any(type.toLowerCase().startsWith)) return response;
    final encoded = Uint8List.fromList(codec.encode(body));
    return ResponseContext(
      status: response.status,
      headers: {
        ...headers,
        'content-encoding': 'gzip',
        'vary': 'accept-encoding',
      },
      body: encoded,
    );
  };
}

/// Case-insensitive lookup in a response header map.
String? _headerValue(Map<String, String> headers, String name) {
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == name) return entry.value;
  }
  return null;
}
