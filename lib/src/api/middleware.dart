/// Built-in middleware.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show GZipCodec, stdout;
import 'dart:typed_data';

import '../internal/ansi.dart';
import 'brotli.dart';
import 'context.dart';
import 'http_method.dart';
import 'schema.dart';

/// One colourful, aligned line per answered request — method, status, latency
/// (microseconds under 1ms, else ms), path and client IP:
///
/// ```text
/// GET    200    843µs  /users/42   127.0.0.1
/// POST   201   1.21ms  /users      127.0.0.1
/// GET    404    312µs  /missing    127.0.0.1
/// ```
///
/// Method and status are tinted by kind/class, the latency is dimmed. [sink]
/// defaults to `print` — pass a real logger in production (the line is
/// formatted before the call, so any `void Function(String)` works). [color]
/// defaults to whether stdout is a TTY, so piped/CI output stays plain; force
/// it either way for a custom sink.
///
/// Pass [json] `true` for one structured JSON object per line instead — ready
/// to ship to a log aggregator:
///
/// ```json
/// {"method":"GET","status":200,"latency_us":843,"path":"/users/42","ip":"127.0.0.1"}
/// ```
Middleware accessLog({
  void Function(String line)? sink,
  bool? color,
  bool json = false,
}) {
  final log =
      // ignore: avoid_print
      sink ?? print;
  final on = !json && (color ?? stdout.supportsAnsiEscapes);
  String format(String method, int status, int micros, String path, String ip) {
    if (json) {
      return jsonEncode({
        'method': method,
        'status': status,
        'latency_us': micros,
        'path': path,
        if (ip.isNotEmpty) 'ip': ip,
      });
    }
    final m = ansi(method.padRight(6), methodHue(method), on: on);
    final s = ansi(status.toString().padRight(3), statusHue(status), on: on);
    final t = ansi(formatLatency(micros).padLeft(8), '2', on: on);
    final tail = ip.isEmpty ? '' : '  ${ansi(ip, '2', on: on)}';
    return '$m $s $t  $path$tail';
  }

  return (request, next) async {
    final stopwatch = Stopwatch()..start();
    final method = request.method == HttpMethod.custom
        ? request.customMethod
        : request.method.token;
    try {
      final response = await next(request);
      stopwatch.stop();
      log(
        format(
          method,
          response.status,
          stopwatch.elapsedMicroseconds,
          request.path,
          request.clientIp,
        ),
      );
      return response;
    } catch (_) {
      stopwatch.stop();
      log(
        format(
          method,
          500,
          stopwatch.elapsedMicroseconds,
          request.path,
          request.clientIp,
        ),
      );
      rethrow;
    }
  };
}

/// Ensures every answer carries an `X-Request-Id` for correlation: echoes the
/// client's `X-Request-Id` (or `X-Correlation-Id`) when present, else generates
/// one. Handlers read it from the request header; clients and logs read it off
/// the response. Put it outermost so every downstream answer is stamped.
///
/// ```dart
/// await server.use(requestId());
/// ```
Middleware requestId({
  String headerName = 'x-request-id',
  String Function()? generator,
}) {
  final gen = generator ?? _randomId;
  final name = headerName.toLowerCase();
  return (request, next) async {
    final incoming = request.header(name) ?? request.header('x-correlation-id');
    final id = (incoming != null && incoming.isNotEmpty) ? incoming : gen();
    final response = await next(request);
    // Handler-set value wins; otherwise stamp ours.
    return response.headers.containsKey(name)
        ? response
        : response.withHeader(name, id);
  };
}

var _idCounter = 0;

/// A compact, collision-resistant-enough request id for correlation (not a
/// security token): time-seeded base-36 + a per-isolate counter.
String _randomId() {
  final n = DateTime.now().microsecondsSinceEpoch;
  final c = _idCounter = (_idCounter + 1) & 0xffffff;
  return '${n.toRadixString(36)}${c.toRadixString(36).padLeft(2, '0')}';
}

/// Validates the JSON request body against [schema] before the handler runs —
/// the same [ApiSchema] you document the body with, so the contract and the
/// check never drift. A malformed body answers `400`, a schema violation `422`
/// (both `application/problem+json`, the errors under an `errors` member); a
/// valid body passes through. Use on body-bearing routes (not `streamBody`).
///
/// ```dart
/// await server.post('/users', createUser, middleware: [validateJsonBody(user)]);
/// ```
Middleware validateJsonBody(ApiSchema schema) {
  return (request, next) async {
    Object? decoded;
    try {
      decoded = request.json();
    } on FormatException {
      return ResponseContext.problem(title: 'Invalid JSON body');
    }
    final errors = schema.validate(decoded);
    if (errors.isNotEmpty) {
      return ResponseContext.problem(
        title: 'Request body failed validation',
        status: 422,
        extensions: {'errors': errors},
      );
    }
    return next(request);
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

/// Fixed-window request rate limit, keyed per client. A request over the limit
/// is answered `429` with a `Retry-After` header and the route never runs.
///
/// ```dart
/// await server.use(rateLimit(maxRequests: 100)); // 100/min per client
/// ```
///
/// The client key comes from [keyExtractor]; the default reads the first hop of
/// `X-Forwarded-For`, then `X-Real-IP`, then the peer's `clientIp` — so it keys
/// per client with or without a proxy. Pass a [keyExtractor] for a key you
/// trust instead (an API key, a session id).
///
/// Counts live in [store] and reset each [window]. The default
/// [InMemoryRateLimitStore] is **per isolate**, so with `isolates > 1` the
/// effective limit is `maxRequests × isolates`. For a limit shared across
/// isolates or hosts, pass a [RateLimitStore] backed by a shared counter
/// (Redis, a coordinator isolate, …).
///
/// `ponytail: fixed window (a burst can straddle two windows for up to 2x over
/// a window boundary); switch to a token bucket if smooth pacing matters.`
Middleware rateLimit({
  required int maxRequests,
  Duration window = const Duration(minutes: 1),
  String Function(RequestContext request)? keyExtractor,
  ResponseContext Function(Duration retryAfter)? onLimit,
  RateLimitStore? store,
}) {
  assert(maxRequests > 0, 'maxRequests must be positive');
  final backing = store ?? InMemoryRateLimitStore();
  final keyOf = keyExtractor ?? _clientKey;
  return (request, next) async {
    final hit = await backing.hit(keyOf(request), window);
    if (hit.count > maxRequests) {
      final retryAfter = hit.resetAt.difference(DateTime.now());
      final seconds = retryAfter.inSeconds + 1;
      if (onLimit != null) return onLimit(retryAfter);
      return ResponseContext(
        status: 429,
        headers: {
          'content-type': 'text/plain; charset=utf-8',
          'retry-after': '$seconds',
        },
        body: _bytes('rate limit exceeded'),
      );
    }
    return next(request);
  };
}

/// One hit recorded against a rate-limit key: the running [count] in the
/// current window and when that window [resetAt].
class RateLimitHit {
  const RateLimitHit({required this.count, required this.resetAt});
  final int count;
  final DateTime resetAt;
}

/// Backing store for [rateLimit]. [hit] records one request for [key] in a
/// window of [window] and returns the running count (post-increment) and reset
/// time — it must be atomic per key. Implement it over a shared counter for a
/// limit that spans isolates or hosts; the default is [InMemoryRateLimitStore].
abstract interface class RateLimitStore {
  FutureOr<RateLimitHit> hit(String key, Duration window);
}

/// The default per-isolate, in-memory fixed-window store. Expired keys are
/// evicted lazily, so memory tracks *active* keys per window, not total seen.
class InMemoryRateLimitStore implements RateLimitStore {
  final _windows = <String, RateLimitHit>{};

  @override
  RateLimitHit hit(String key, Duration window) {
    final now = DateTime.now();
    final current = _windows[key];
    if (current == null || !now.isBefore(current.resetAt)) {
      _windows.removeWhere((_, other) => !now.isBefore(other.resetAt));
      return _windows[key] = RateLimitHit(count: 1, resetAt: now.add(window));
    }
    return _windows[key] = RateLimitHit(
      count: current.count + 1,
      resetAt: current.resetAt,
    );
  }
}

/// Default rate-limit key: first hop of `X-Forwarded-For`, then `X-Real-IP`,
/// then the socket peer `clientIp`, then a single shared bucket (`*`).
String _clientKey(RequestContext request) {
  final fwd = request.header('x-forwarded-for');
  if (fwd != null && fwd.isNotEmpty) return fwd.split(',').first.trim();
  final real = request.header('x-real-ip');
  if (real != null && real.isNotEmpty) return real.trim();
  return request.clientIp.isNotEmpty ? request.clientIp : '*';
}

/// HTTP Bearer-token auth: requires `Authorization: Bearer <token>` and calls
/// [verify] with the token. A missing or rejected token is answered `401` with
/// a `WWW-Authenticate: Bearer` challenge and the route never runs.
///
/// ```dart
/// await server.use(bearerAuth((token) => token == mySecret));
/// ```
Middleware bearerAuth(
  FutureOr<bool> Function(String token) verify, {
  String realm = 'api',
}) {
  return (request, next) async {
    final auth = request.header('authorization');
    const prefix = 'Bearer ';
    if (auth != null &&
        auth.length > prefix.length &&
        auth.substring(0, prefix.length).toLowerCase() ==
            prefix.toLowerCase()) {
      final token = auth.substring(prefix.length).trim();
      if (token.isNotEmpty && await verify(token)) return next(request);
    }
    return _unauthorized('Bearer realm="$realm"');
  };
}

/// API-key auth: requires a non-empty [headerName] header and calls [verify]
/// with its value. A missing or rejected key is answered `401`.
///
/// ```dart
/// await server.use(apiKeyAuth((key) => validKeys.contains(key)));
/// ```
Middleware apiKeyAuth(
  FutureOr<bool> Function(String key) verify, {
  String headerName = 'x-api-key',
}) {
  final name = headerName.toLowerCase();
  return (request, next) async {
    final key = request.header(name);
    if (key != null && key.isNotEmpty && await verify(key)) {
      return next(request);
    }
    return ResponseContext(
      status: 401,
      headers: {'content-type': 'text/plain; charset=utf-8'},
      body: _bytes('unauthorized'),
    );
  };
}

/// HTTP Basic auth: requires `Authorization: Basic <base64(user:pass)>` and
/// calls [verify] with the decoded credentials. A missing, malformed or
/// rejected credential is answered `401` with a `WWW-Authenticate: Basic`
/// challenge and the route never runs.
///
/// ```dart
/// await server.use(basicAuth((user, pass) => user == 'admin' && pass == pw));
/// ```
Middleware basicAuth(
  FutureOr<bool> Function(String user, String password) verify, {
  String realm = 'api',
}) {
  final challenge = 'Basic realm="$realm"';
  return (request, next) async {
    final auth = request.header('authorization');
    const prefix = 'Basic ';
    if (auth != null &&
        auth.length > prefix.length &&
        auth.substring(0, prefix.length).toLowerCase() ==
            prefix.toLowerCase()) {
      final decoded = _decodeBasic(auth.substring(prefix.length).trim());
      if (decoded != null && await verify(decoded.$1, decoded.$2)) {
        return next(request);
      }
    }
    return _unauthorized(challenge);
  };
}

/// Decodes a Basic credential (`base64(user:password)`) into `(user, password)`,
/// or null when the base64 or the `user:password` shape is malformed.
(String, String)? _decodeBasic(String encoded) {
  final String text;
  try {
    text = utf8.decode(base64.decode(encoded));
  } on FormatException {
    return null;
  }
  final colon = text.indexOf(':');
  if (colon < 0) return null;
  return (text.substring(0, colon), text.substring(colon + 1));
}

ResponseContext _unauthorized(String challenge) => ResponseContext(
  status: 401,
  headers: {
    'content-type': 'text/plain; charset=utf-8',
    'www-authenticate': challenge,
  },
  body: _bytes('unauthorized'),
);

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));
