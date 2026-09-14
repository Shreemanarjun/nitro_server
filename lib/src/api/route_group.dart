/// Route groups: a shared path prefix for a bundle of routes.
library;

import 'context.dart';
import 'http_method.dart';
import 'server.dart';

/// A path-prefixed view of a [NitroServer].
///
/// ```dart
/// final api = server.group('/api');
/// await api.get('/users', listUsers);      // serves GET /api/users
/// await api.post('/users', createUser);    // serves POST /api/users
/// final v2 = api.group('/v2');             // serves under /api/v2/…
/// ```
///
/// Groups only prefix patterns: middleware stays server-global (see
/// [NitroServer.use]).
class RouteGroup {
  /// Creates a group over [server] with [prefix]. Prefer [NitroServer.group]
  /// (and [group] for nesting) over calling this directly.
  RouteGroup({required this.server, required String prefix})
      : _prefix = _normalize(prefix);

  /// The server this group registers on. Middleware added here is
  /// server-global (see [NitroServer.use]).
  final NitroServer server;
  final String _prefix;

  /// The normalized prefix (`''` for the root group).
  String get prefix => _prefix;

  /// A nested group: [prefix] is appended to this group's prefix.
  RouteGroup group(String prefix) =>
      RouteGroup(server: server, prefix: '$_prefix$prefix');

  /// Registers [handler] for [method] + the prefixed [pattern].
  Future<void> route(
    HttpMethod method,
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
    String customMethod = '',
  }) =>
      server.route(
        method,
        '$_prefix$pattern',
        handler,
        timeout: timeout,
        customMethod: customMethod,
      );

  /// Removes a prefixed registration.
  Future<void> unroute(
    HttpMethod method,
    String pattern, {
    String customMethod = '',
  }) =>
      server.unroute(method, '$_prefix$pattern', customMethod: customMethod);

  Future<void> get(
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
  }) =>
      route(HttpMethod.get, pattern, handler, timeout: timeout);

  Future<void> head(
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
  }) =>
      route(HttpMethod.head, pattern, handler, timeout: timeout);

  Future<void> post(
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
  }) =>
      route(HttpMethod.post, pattern, handler, timeout: timeout);

  Future<void> put(
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
  }) =>
      route(HttpMethod.put, pattern, handler, timeout: timeout);

  Future<void> delete(
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
  }) =>
      route(HttpMethod.delete, pattern, handler, timeout: timeout);

  Future<void> patch(
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
  }) =>
      route(HttpMethod.patch, pattern, handler, timeout: timeout);

  Future<void> options(
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
  }) =>
      route(HttpMethod.options, pattern, handler, timeout: timeout);

  /// Matches every method under the prefixed [pattern].
  Future<void> all(
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
  }) =>
      route(HttpMethod.all, pattern, handler, timeout: timeout);

  /// Normalizes a group prefix: must be `/'-rooted; a single `'/'` (or a
  /// trailing slash) collapses so joining never produces `'//users'`.
  static String _normalize(String prefix) {
    if (!prefix.startsWith('/')) {
      throw ArgumentError.value(
        prefix,
        'prefix',
        'group prefixes are /-rooted (e.g. /api)',
      );
    }
    if (prefix.length > 1 && prefix.endsWith('/')) {
      return prefix.substring(0, prefix.length - 1);
    }
    return prefix == '/' ? '' : prefix;
  }
}
