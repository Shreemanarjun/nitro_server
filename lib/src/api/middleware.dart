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
