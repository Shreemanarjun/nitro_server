/// Built-in middleware.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show GZipCodec, InternetAddress, stdout;
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
    // An inbound id is reflected only when it is a bounded opaque token:
    // anything else (a CR/LF, a space, 4 KB of junk) is replaced, so the
    // header can never carry a client's bytes back into the response head.
    final id = (incoming != null && _isSafeRequestId(incoming))
        ? incoming
        : gen();
    final response = await next(request);
    // Handler-set value wins (any casing); otherwise stamp ours. Case-
    // insensitive so a handler's `X-Request-Id` isn't duplicated under
    // `x-request-id`.
    return _headerValue(response.headers, name) != null
        ? response
        : response.withHeader(name, id);
  };
}

var _idCounter = 0;

/// `[A-Za-z0-9._:-]{1,128}` — enough for UUIDs, ULIDs, trace ids and the
/// generated form; nothing that could shape a header or a log line.
bool _isSafeRequestId(String id) {
  if (id.isEmpty || id.length > 128) return false;
  for (final c in id.codeUnits) {
    final ok =
        (c >= 0x30 && c <= 0x39) || // 0-9
        (c >= 0x41 && c <= 0x5a) || // A-Z
        (c >= 0x61 && c <= 0x7a) || // a-z
        c == 0x2e ||
        c == 0x5f ||
        c == 0x3a ||
        c == 0x2d; // . _ : -
    if (!ok) return false;
  }
  return true;
}

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
/// The `errors` list is capped at [maxErrors] entries (a body of ten thousand
/// bad elements does not come back as ten thousand lines); the last entry
/// then says how many were omitted. Decoding itself is bounded by the route's
/// `maxBodyBytes` — `dart:convert`'s parser is iterative, so nesting depth
/// cannot exhaust the stack.
///
/// ```dart
/// await server.post('/users', createUser, middleware: [validateJsonBody(user)]);
/// ```
Middleware validateJsonBody(ApiSchema schema, {int maxErrors = 100}) {
  if (maxErrors <= 0) {
    throw ArgumentError.value(maxErrors, 'maxErrors', 'must be positive');
  }
  return (request, next) async {
    Object? decoded;
    try {
      decoded = request.json();
    } on FormatException {
      return ResponseContext.problem(title: 'Invalid JSON body');
    }
    var errors = schema.validate(decoded);
    if (errors.isNotEmpty) {
      if (errors.length > maxErrors) {
        final omitted = errors.length - maxErrors;
        errors = [
          ...errors.take(maxErrors),
          '… $omitted more error(s) omitted',
        ];
      }
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
  // RFC 6454 / Fetch: browsers reject `Access-Control-Allow-Origin: *` with
  // credentials, and a reflected wildcard would be an open credentialed
  // cross-origin door — refuse the combination at construction.
  if (allowOrigin == '*' && allowCredentials) {
    throw ArgumentError(
      'cors(): allowCredentials requires an explicit allowOrigin, not "*"',
    );
  }
  final policy = <String, String>{
    'access-control-allow-origin': allowOrigin,
    'access-control-allow-methods': allowMethods,
    'access-control-allow-headers': allowHeaders,
    if (allowCredentials) 'access-control-allow-credentials': 'true',
    if (maxAge != null && maxAge > Duration.zero)
      'access-control-max-age': '${maxAge.inSeconds}',
  };
  return (request, next) async {
    // A CORS preflight is an OPTIONS carrying Access-Control-Request-Method;
    // answer only those inline. A plain OPTIONS (a user-registered route, or a
    // non-CORS probe) must fall through to `next` — else cors() shadows every
    // OPTIONS/all route on the server.
    if (request.method == HttpMethod.options &&
        request.header('access-control-request-method') != null) {
      return ResponseContext(status: 204, headers: policy);
    }
    final response = await next(request);
    // copyWith (not a fresh ResponseContext) so a streaming / SSE / file
    // answer keeps its body and any set-cookies; handler headers win.
    return response.copyWith(headers: {...policy, ...response.headers});
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
  cookies: response.cookies, // else compression drops the handler's set-cookies
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
/// The client key comes from [keyExtractor]; the default is the socket peer
/// (`clientIp`). Behind a reverse proxy pass [trustedProxies] — the proxy
/// addresses (or CIDRs) you control — and the key becomes the nearest hop in
/// `X-Forwarded-For` that is *not* a trusted proxy (then `X-Real-IP`), so a
/// direct client cannot rotate forwarded headers to mint fresh buckets. Pass
/// a [keyExtractor] for a key you trust instead (an API key, a session id).
///
/// Counts live in [store] and reset each [window]. The default
/// [InMemoryRateLimitStore] is **per isolate**, so with `isolates > 1` the
/// effective limit is `maxRequests × isolates`; it holds at most
/// [maxKeys] active keys (expired ones are evicted first, then the soonest-
/// to-expire), so spoofed-key floods are bounded in memory. For a limit
/// shared across isolates or hosts, pass a [RateLimitStore] backed by a
/// shared counter (Redis, a coordinator isolate, …).
///
/// `ponytail: fixed window (a burst can straddle two windows for up to 2x over
/// a window boundary); switch to a token bucket if smooth pacing matters.`
Middleware rateLimit({
  required int maxRequests,
  Duration window = const Duration(minutes: 1),
  String Function(RequestContext request)? keyExtractor,
  ResponseContext Function(Duration retryAfter)? onLimit,
  RateLimitStore? store,
  List<String> trustedProxies = const [],
  int maxKeys = 100000,
}) {
  if (maxRequests <= 0) {
    throw ArgumentError.value(maxRequests, 'maxRequests', 'must be positive');
  }
  final backing = store ?? InMemoryRateLimitStore(maxKeys: maxKeys);
  final trusted = [for (final p in trustedProxies) _Cidr.parse(p)];
  final keyOf =
      keyExtractor ?? (request) => _clientKeyBehindProxies(request, trusted);
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

/// The default per-isolate, in-memory fixed-window store, bounded to
/// [maxKeys] active keys: expired keys go first, then — still full — the
/// tenth of the keys soonest to expire, so a flood of never-repeated keys
/// costs a bounded amount of memory and cannot reset the counts of the
/// clients actually being limited.
class InMemoryRateLimitStore implements RateLimitStore {
  InMemoryRateLimitStore({this.maxKeys = 100000}) {
    if (maxKeys <= 0) {
      throw ArgumentError.value(maxKeys, 'maxKeys', 'must be positive');
    }
  }

  /// Upper bound on active keys held at once.
  final int maxKeys;

  final _windows = <String, RateLimitHit>{};

  /// Active keys held right now.
  int get size => _windows.length;

  @override
  RateLimitHit hit(String key, Duration window) {
    final now = DateTime.now();
    final current = _windows[key];
    if (current != null && now.isBefore(current.resetAt)) {
      return _windows[key] = RateLimitHit(
        count: current.count + 1,
        resetAt: current.resetAt,
      );
    }
    if (current == null && _windows.length >= maxKeys) _evict(now);
    return _windows[key] = RateLimitHit(count: 1, resetAt: now.add(window));
  }

  void _evict(DateTime now) {
    _windows.removeWhere((_, other) => !now.isBefore(other.resetAt));
    if (_windows.length < maxKeys) return;
    final soonest = _windows.entries.toList()
      ..sort((a, b) => a.value.resetAt.compareTo(b.value.resetAt));
    final drop = (soonest.length ~/ 10).clamp(1, soonest.length);
    for (var i = 0; i < drop; i++) {
      _windows.remove(soonest[i].key);
    }
  }
}

/// Default rate-limit key: the socket peer, unless the peer is one of
/// [trustedProxies], in which case the nearest untrusted hop of
/// `X-Forwarded-For` (walking right to left past trusted hops), then
/// `X-Real-IP`, then the peer. Headers are only believed from a trusted
/// proxy and only when they parse as IP addresses. `*` (one shared bucket)
/// when there is no peer address at all.
/// `::ffff:a.b.c.d` (an IPv4 peer seen through a dual-stack listener) as the
/// IPv4 address it is, so v4 CIDRs and keys match it.
InternetAddress _unmap(InternetAddress ip) {
  final raw = ip.rawAddress;
  if (raw.length != 16) return ip;
  for (var i = 0; i < 10; i++) {
    if (raw[i] != 0) return ip;
  }
  if (raw[10] != 0xff || raw[11] != 0xff) return ip;
  return InternetAddress.fromRawAddress(raw.sublist(12));
}

String _clientKeyBehindProxies(
  RequestContext request,
  List<_Cidr> trustedProxies,
) {
  final peer = request.clientIp;
  final parsed = InternetAddress.tryParse(peer);
  if (parsed == null) return '*';
  final peerIp = _unmap(parsed);
  if (!trustedProxies.any((c) => c.contains(peerIp))) return peerIp.address;
  final fwd = request.header('x-forwarded-for');
  if (fwd != null && fwd.isNotEmpty) {
    final hops = fwd.split(',').reversed;
    for (final raw in hops) {
      final parsedHop = InternetAddress.tryParse(raw.trim());
      if (parsedHop == null) break; // garbage: stop believing the chain
      final hop = _unmap(parsedHop);
      if (!trustedProxies.any((c) => c.contains(hop))) return hop.address;
    }
  }
  final real = InternetAddress.tryParse(
    request.header('x-real-ip')?.trim() ?? '',
  );
  if (real != null) return _unmap(real).address;
  return peerIp.address;
}

/// An IPv4/IPv6 address or `addr/prefix` network, for [rateLimit]'s
/// `trustedProxies`.
class _Cidr {
  _Cidr(this.address, this.prefix);

  final InternetAddress address;
  final int prefix;

  static _Cidr parse(String spec) {
    final slash = spec.indexOf('/');
    final addr = InternetAddress.tryParse(
      slash < 0 ? spec.trim() : spec.substring(0, slash).trim(),
    );
    if (addr == null) {
      throw ArgumentError.value(spec, 'trustedProxies', 'not an IP or CIDR');
    }
    final bits = addr.rawAddress.length * 8;
    final prefix = slash < 0 ? bits : int.tryParse(spec.substring(slash + 1));
    if (prefix == null || prefix < 0 || prefix > bits) {
      throw ArgumentError.value(spec, 'trustedProxies', 'bad prefix length');
    }
    return _Cidr(addr, prefix);
  }

  bool contains(InternetAddress ip) {
    final a = _unmap(address).rawAddress, b = _unmap(ip).rawAddress;
    if (a.length != b.length) return false;
    var remaining = prefix;
    for (var i = 0; i < a.length && remaining > 0; i++) {
      final take = remaining >= 8 ? 8 : remaining;
      final mask = (0xff << (8 - take)) & 0xff;
      if ((a[i] & mask) != (b[i] & mask)) return false;
      remaining -= take;
    }
    return true;
  }
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

/// Admits a request only when its `Origin` header names one of [allowed]
/// (`scheme://host[:port]`, compared case-insensitively) — the WebSocket
/// origin policy of RFC 6455 §10.2, for `ws(middleware: [...])` (a rejection
/// closes the socket `4403`) and for HTTP routes alike. A request without an
/// `Origin` header is refused unless [allowMissing] is true (non-browser
/// clients send none). [allowed] must not be empty.
Middleware originPolicy(List<String> allowed, {bool allowMissing = false}) {
  if (allowed.isEmpty) {
    throw ArgumentError.value(allowed, 'allowed', 'must name an origin');
  }
  final set = {for (final o in allowed) _normalizeOrigin(o)};
  return (request, next) {
    final origin = request.header('origin');
    if (origin == null) {
      return allowMissing ? next(request) : _forbiddenOrigin();
    }
    return set.contains(_normalizeOrigin(origin))
        ? next(request)
        : _forbiddenOrigin();
  };
}

String _normalizeOrigin(String origin) {
  final t = origin.trim().toLowerCase();
  return t.endsWith('/') ? t.substring(0, t.length - 1) : t;
}

ResponseContext _forbiddenOrigin() =>
    ResponseContext.text('origin not allowed', status: 403);

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
