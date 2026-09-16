/// Built-in middleware.
library;

import 'dart:io' show GZipCodec;
import 'dart:typed_data';

import 'brotli.dart';
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

/// Response compression, negotiated per request: applies when the client's
/// `Accept-Encoding` lists a coding this can produce, the answer is a one-shot
/// body of at least [minBytes] with a compressible `content-type` (text, JSON,
/// JavaScript, XML, SVG, WASM by default; [contentTypes] overrides, matched by
/// prefix) and no `content-encoding` yet. Streams and file answers pass through
/// untouched. Compressed answers carry the chosen `content-encoding` and
/// `vary: accept-encoding`.
///
/// Prefers **brotli** (`br`) when the client accepts it and the engine was
/// built with libbrotli ([brotliAvailable]) — brotli beats gzip on ratio for
/// text, and Go's standard library ships no brotli — otherwise **gzip**. Both
/// codecs are native (brotli via the engine, gzip via `dart:io`'s system zlib),
/// run on the isolate: cheap for the bodies this applies to, and far less than
/// the bytes saved on the wire.
///
/// [level] (1–9) is the gzip level. The default is 1 — for live response
/// compression that is the right trade: on structured text (JSON, HTML) zlib
/// level 1 runs ~2–3x faster than the level-6 default for a sub-percent larger
/// output, because levels 1–3 use zlib's fast `deflate_fast` and 4+ the slow
/// lazy match. Measured on an 11.6 KB JSON body: L1 17 us / 9.4%, L6 48 us /
/// 9.5%. Raise it toward 9 when the response is cached and ratio matters more
/// than per-request CPU (nginx and Cloudflare likewise default on-the-fly
/// compression to a low level). [brotliQuality] (0–11) is the same trade for
/// brotli; the default is 4, a fast quality suited to on-the-fly compression —
/// on the same 11.6 KB JSON body brotli q4 is 52 us for a 7.4% ratio against
/// gzip L1's 22 us / 13.6% (roughly half the bytes for ~2.4x the CPU). Avoid
/// q11 for live responses — it is ~100x slower for a fraction of a percent.
Middleware compress({
  int minBytes = 1024,
  int level = 1,
  int brotliQuality = 4,
  Set<String> contentTypes = _compressibleTypes,
}) {
  final codec = GZipCodec(level: level);
  final canBrotli = brotliAvailable();
  return (request, next) async {
    final response = await next(request);
    final body = response.body;
    if (body == null || body.length < minBytes) return response;
    final headers = response.headers;
    if (_headerValue(headers, 'content-encoding') != null) return response;
    final type = _headerValue(headers, 'content-type') ?? '';
    if (!contentTypes.any(type.toLowerCase().startsWith)) return response;
    final accept = request.header('accept-encoding') ?? '';
    // Brotli first (better ratio), then gzip.
    if (canBrotli && _acceptsCoding(accept, 'br')) {
      return _reencoded(
        response,
        headers,
        'br',
        brotliCompress(body, brotliQuality),
      );
    }
    if (_acceptsCoding(accept, 'gzip')) {
      return _reencoded(
        response,
        headers,
        'gzip',
        Uint8List.fromList(codec.encode(body)),
      );
    }
    return response;
  };
}

/// Rebuilds [response] with a compressed [body] and the encoding headers.
ResponseContext _reencoded(
  ResponseContext response,
  Map<String, String> headers,
  String coding,
  Uint8List body,
) => ResponseContext(
  status: response.status,
  headers: {...headers, 'content-encoding': coding, 'vary': 'accept-encoding'},
  body: body,
);

/// True when [accept] (an `Accept-Encoding` value) lists [coding] as a coding
/// token, case-insensitively, ignoring any `;q=` weight — so `br` matches the
/// coding, never a fragment of another token.
bool _acceptsCoding(String accept, String coding) {
  for (final part in accept.split(',')) {
    if (part.split(';').first.trim().toLowerCase() == coding) return true;
  }
  return false;
}

/// Case-insensitive lookup in a response header map.
String? _headerValue(Map<String, String> headers, String name) {
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == name) return entry.value;
  }
  return null;
}
