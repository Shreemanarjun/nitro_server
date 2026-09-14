/// Built-in middleware.
library;

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
