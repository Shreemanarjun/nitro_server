/// In-memory test client: drive a real [ServerRunner] (real dispatch,
/// middleware, error mapping) with no sockets and no native library.
///
/// ```dart
/// import 'package:nitro_server/testing.dart';
///
/// final client = await NitroTestClient.start();
/// await client.server.get('/users/:id', (request) async {
///   return ResponseContext.text('user ${request.param('id')}');
/// });
/// final response = await client.get('/users/42');
/// expect(response.status, 200);
/// expect(response.text(), 'user 42');
/// await client.close();
/// ```
///
/// Faithful to production where it matters (routing precedence, middleware
/// order, handler/error answers) and honestly divergent where no engine
/// exists:
///
/// * No sockets: no keep-alive, no `maxRequestsPerConnection`, no ports.
///   `server.port` stays `0`.
/// * No route timeouts: the deadline wait lives in the C++ connection
///   thread, so slow handlers simply resolve late here instead of 408ing.
/// * `maxBodyBytes` is unenforced: bodies arrive whole, never 413.
/// * Unrouted paths answer `404 "not found"` directly, exactly like the
///   engine — the runner's `notFoundHandler` does not run for them in
///   production either (the engine answers before dispatch).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'nitro_server.dart';
import 'src/internal/raw_mapping.dart';
import 'src/internal/server_runner.dart';
import 'src/nitro_server.native.dart';

/// One answered test request.
class NitroTestResponse {
  NitroTestResponse({
    required this.status,
    required this.headers,
    required this.body,
  });

  final int status;

  /// Response headers, last value winning on duplicates.
  final Map<String, String> headers;
  final Uint8List body;

  /// The body decoded as UTF-8 text.
  String text() => utf8.decode(body);

  /// The body decoded as JSON.
  dynamic json() => jsonDecode(text());
}

/// Drives [server] without sockets. Create with [start], register routes on
/// [server] exactly as in production, then issue requests.
class NitroTestClient {
  NitroTestClient._(this._runner, this._native)
      // ignore: invalid_use_of_visible_for_testing_member
      : server = NitroServer.forRunnerForTesting(_runner) {
    _runner.ensureListeningForTesting();
  }

  /// Starts a client over a fresh in-memory engine. No native library, no
  /// ports, no background threads beyond the runner's streams.
  static Future<NitroTestClient> start() async {
    final native = _InMemoryNative();
    final runner = ServerRunner(native);
    return NitroTestClient._(runner, native);
  }

  final ServerRunner _runner;
  final _InMemoryNative _native;

  /// The server under test. Register routes, middleware, groups and fallback
  /// handlers here — the same calls production makes.
  late final NitroServer server;

  var _nextId = 0;

  Future<NitroTestResponse> _drive(
    HttpMethod method,
    String target, {
    String customMethod = '',
    Object? body,
    Map<String, String>? headers,
  }) async {
    final token = method == HttpMethod.custom
        ? customMethod.toUpperCase()
        : method.token;
    if (method == HttpMethod.custom && token.isEmpty) {
      throw ArgumentError.value(
        customMethod,
        'customMethod',
        'HttpMethod.custom needs an explicit token',
      );
    }
    var path = target;
    var query = '';
    final q = target.indexOf('?');
    if (q != -1) {
      path = target.substring(0, q);
      query = target.substring(q + 1);
    }
    if (path.isEmpty) path = '/';

    final match = _native.matchRoute(token, path);
    if (match == null) {
      // Engine-consistent: unrouted paths never reach dispatch. The engine
      // answers `404 "not found"` itself, so the runner's `notFoundHandler`
      // does not run for them in production either.
      return NitroTestResponse(
        status: 404,
        headers: {'content-type': 'text/plain'},
        body: Uint8List.fromList(utf8.encode('not found')),
      );
    }

    final bodyBytes = _encodeBody(body);
    final requestId = ++_nextId;
    final (rawMethod, rawCustom) = rawMethodOf(method, token);
    _native.heads.add(
      RawIncomingRequest(
        requestId: requestId,
        method: rawMethod,
        customMethod: rawCustom,
        path: path,
        query: query,
        headers: [
          for (final entry in (headers ?? const {}).entries)
            RawHeader(name: entry.key, value: entry.value),
        ],
        contentLength: bodyBytes.length,
        hasBody: bodyBytes.isNotEmpty,
        routePattern: match.pattern,
        params: [
          for (final entry in match.params.entries)
            RawRouteParam(name: entry.key, value: entry.value),
        ],
      ),
    );
    if (bodyBytes.isNotEmpty) {
      _native.chunks.add(
        RawBodyChunk(
          bytes: bodyBytes,
          requestId: requestId,
          kind: RawBodyKind.data.index,
          aux: 0,
        ),
      );
      _native.chunks.add(
        RawBodyChunk(
          bytes: Uint8List(0),
          requestId: requestId,
          kind: RawBodyKind.end.index,
          aux: 0,
        ),
      );
    }
    for (var i = 0; i < 1000; i++) {
      final answered = _native.answered[requestId];
      if (answered != null) return answered;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    throw StateError('test client timed out waiting for response to $target');
  }

  static Uint8List _encodeBody(Object? body) {
    if (body == null) return Uint8List(0);
    if (body is Uint8List) return body;
    if (body is List<int>) return Uint8List.fromList(body);
    if (body is String) return Uint8List.fromList(utf8.encode(body));
    if (body is Map) {
      return Uint8List.fromList(utf8.encode(jsonEncode(body)));
    }
    throw ArgumentError.value(
      body,
      'body',
      'want String, List<int>, Uint8List or Map (JSON)',
    );
  }

  /// Issues a GET request.
  Future<NitroTestResponse> get(String path, {Map<String, String>? headers}) =>
      request(HttpMethod.get, path, headers: headers);

  /// Issues a HEAD request.
  Future<NitroTestResponse> head(String path, {Map<String, String>? headers}) =>
      request(HttpMethod.head, path, headers: headers);

  /// Issues a POST request with an optional body.
  Future<NitroTestResponse> post(
    String path, {
    Object? body,
    Map<String, String>? headers,
  }) =>
      request(HttpMethod.post, path, body: body, headers: headers);

  /// Issues a PUT request with an optional body.
  Future<NitroTestResponse> put(
    String path, {
    Object? body,
    Map<String, String>? headers,
  }) =>
      request(HttpMethod.put, path, body: body, headers: headers);

  /// Issues a DELETE request.
  Future<NitroTestResponse> delete(
    String path, {
    Object? body,
    Map<String, String>? headers,
  }) =>
      request(HttpMethod.delete, path, body: body, headers: headers);

  /// Issues a PATCH request with an optional body.
  Future<NitroTestResponse> patch(
    String path, {
    Object? body,
    Map<String, String>? headers,
  }) =>
      request(HttpMethod.patch, path, body: body, headers: headers);

  /// Issues an OPTIONS request.
  Future<NitroTestResponse> options(
    String path, {
    Map<String, String>? headers,
  }) =>
      request(HttpMethod.options, path, headers: headers);

  /// Issues a request with an explicit [method].
  Future<NitroTestResponse> request(
    HttpMethod method,
    String path, {
    String customMethod = '',
    Object? body,
    Map<String, String>? headers,
  }) =>
      _drive(
        method,
        path,
        customMethod: customMethod,
        body: body,
        headers: headers,
      );

  /// Shuts the runner down. Idempotent, like [NitroServer.close].
  Future<void> close() => _runner.close();
}

/// A matched route: the registered pattern plus `:param` captures.
class _RouteMatch {
  _RouteMatch(this.pattern, this.params);

  final String pattern;
  final Map<String, String> params;
}

/// The in-memory half of the FFI boundary: records registrations, matches
/// requests with engine precedence (static > `:param` > trailing `*`,
/// method-specific > `all`), and serves as the runner's stream source and
/// `respond` sink.
class _InMemoryNative extends NitroServerNative {
  final heads = StreamController<RawIncomingRequest>.broadcast();
  final chunks = StreamController<RawBodyChunk>.broadcast();
  final events = StreamController<RawServerEvent>.broadcast();

  final routes = <RawRouteConfig>[];
  final answered = <int, NitroTestResponse>{};

  @override
  Stream<RawIncomingRequest> get incomingRequests => heads.stream;

  @override
  Stream<RawBodyChunk> get bodyChunks => chunks.stream;

  @override
  Stream<RawServerEvent> get serverEvents => events.stream;

  @override
  String engineVersion() => 'nitro_server-test/0.0.1 in-memory';

  @override
  bool supportsTls() => false;

  @override
  void resetNative() {}

  @override
  void configureServer(RawServerConfig config) {}

  @override
  RawServerStatus registerRoute(RawRouteConfig route) {
    routes.add(route);
    return const RawServerStatus(errorKind: RawServerErrorKind.none);
  }

  @override
  RawServerStatus unregisterRoute(String method, String pattern) {
    final index = routes.indexWhere(
      (r) => _routeToken(r) == method.toUpperCase() && r.pattern == pattern,
    );
    if (index == -1) {
      return RawServerStatus(
        errorKind: RawServerErrorKind.routeNotFound,
        errorMessage: 'no such route: $pattern',
      );
    }
    routes.removeAt(index);
    return const RawServerStatus(errorKind: RawServerErrorKind.none);
  }

  @override
  RawServerStatus start() {
    return const RawServerStatus(errorKind: RawServerErrorKind.none);
  }

  @override
  void stop() {}

  @override
  void respond(
    int requestId,
    int status,
    List<RawHeader> headers,
    Uint8List body,
  ) {
    answered[requestId] = NitroTestResponse(
      status: status,
      headers: {for (final h in headers) h.name: h.value},
      body: Uint8List.fromList(body),
    );
  }

  @override
  void ackBody(int requestId, int ackedChunks) {}

  static String _routeToken(RawRouteConfig route) {
    if (route.method == RawServerMethod.custom) return route.customMethod;
    if (route.method == RawServerMethod.all) return '*';
    return route.method.name.toUpperCase();
  }

  /// Best matching registration for [methodToken] + [path], or null when the
  /// engine would answer 404 directly. Precedence mirrors `Router::match`.
  _RouteMatch? matchRoute(String methodToken, String path) {
    final pathSegs = _split(path);
    _RouteMatch? best;
    var bestSpec = -1;
    var bestMethod = -1;
    for (final route in routes) {
      final routeToken = _routeToken(route);
      final int methodScore;
      if (routeToken == methodToken) {
        methodScore = 1;
      } else if (routeToken == '*' &&
          methodToken != '*' &&
          !_isCustomToken(methodToken)) {
        // `all` is the fallback for concrete methods only — custom tokens
        // never fall back, mirroring pickEntry's allowAll.
        methodScore = 0;
      } else {
        continue;
      }
      final scored = _matchPath(route.pattern, pathSegs);
      if (scored == null) continue;
      if (scored.$1 > bestSpec ||
          (scored.$1 == bestSpec && methodScore > bestMethod)) {
        best = _RouteMatch(route.pattern, scored.$2);
        bestSpec = scored.$1;
        bestMethod = methodScore;
      }
    }
    return best;
  }

  /// Whether [token] is a custom-method token rather than a known verb or `*`.
  static bool _isCustomToken(String token) {
    switch (token) {
      case 'GET':
      case 'HEAD':
      case 'POST':
      case 'PUT':
      case 'DELETE':
      case 'PATCH':
      case 'OPTIONS':
      case 'TRACE':
      case '*':
        return false;
      default:
        return true;
    }
  }

  /// (specificity, params) when [pattern] matches [pathSegs], else null.
  static (int, Map<String, String>)? _matchPath(
    String pattern,
    List<String> pathSegs,
  ) {
    final patternSegs = _split(pattern);
    final wildcard =
        patternSegs.isNotEmpty && patternSegs.last == '*';
    final prefix = wildcard
        ? patternSegs.sublist(0, patternSegs.length - 1)
        : patternSegs;
    if (wildcard) {
      if (pathSegs.length < prefix.length) return null;
    } else {
      if (pathSegs.length != prefix.length) return null;
    }
    var spec = 0;
    final params = <String, String>{};
    for (var i = 0; i < prefix.length; i++) {
      final p = prefix[i];
      if (p.startsWith(':')) {
        params[p.substring(1)] = pathSegs[i];
        spec += 1;
      } else if (p == pathSegs[i]) {
        spec += 2;
      } else {
        return null;
      }
    }
    return (spec, params);
  }

  static List<String> _split(String path) {
    return [
      for (final seg in path.split('/'))
        if (seg.isNotEmpty) seg,
    ];
  }
}
