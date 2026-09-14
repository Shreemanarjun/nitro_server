/// Route groups: a shared path prefix for a bundle of routes.
library;

import 'context.dart';
import 'http_method.dart';
import 'server.dart';
import 'ws.dart';

/// A path-prefixed view of a [NitroServer].
///
/// ```dart
/// final api = server.group('/api');
/// await api.get('/users', listUsers);      // serves GET /api/users
/// await api.post('/users', createUser);    // serves POST /api/users
/// final v2 = api.group('/v2');             // serves under /api/v2/…
/// ```
///
/// Groups prefix patterns and scope middleware: [RouteGroup.use] wraps the
/// routes registered through this group (inside the server-global chain,
/// see [NitroServer.use]); per-route `middleware:` sits innermost.
class RouteGroup {
  /// Creates a group over [server] with [prefix]. Prefer [NitroServer.group]
  /// (and [group] for nesting) over calling this directly.
  RouteGroup({required this.server, required String prefix})
      : _prefix = _normalize(prefix);

  /// The server this group registers on.
  final NitroServer server;
  final String _prefix;
  final _middleware = <Middleware>[];

  /// The normalized prefix (`''` for the root group).
  String get prefix => _prefix;

  /// A nested group: [prefix] is appended to this group's prefix.
  RouteGroup group(String prefix) =>
      RouteGroup(server: server, prefix: '$_prefix$prefix');

  /// Group-scoped middleware: wraps every route registered through this
  /// group, inside the server-global chain (see [NitroServer.use]) and
  /// outside any per-route [Middleware] passed to [route]. Returns `this`
  /// for chaining.
  ///
  /// The list is captured when a route is registered, so call `use` BEFORE
  /// registering the routes it should wrap (unlike [NitroServer.use], which
  /// is retroactive across the whole server).
  Future<RouteGroup> use(Middleware middleware) async {
    _middleware.add(middleware);
    return this;
  }

  /// Registers [handler] for [method] + the prefixed [pattern]. Returns
  /// `this`, so registrations chain.
  Future<RouteGroup> route(
    HttpMethod method,
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
    String customMethod = '',
    List<Middleware>? middleware,
  }) async {
    await server.route(
      method,
      '$_prefix$pattern',
      handler,
      timeout: timeout,
      customMethod: customMethod,
      middleware: [..._middleware, ...?middleware],
    );
    return this;
  }

  /// Removes a prefixed registration.
  Future<RouteGroup> unroute(
    HttpMethod method,
    String pattern, {
    String customMethod = '',
  }) async {
    await server.unroute(method, '$_prefix$pattern', customMethod: customMethod);
    return this;
  }

  Future<RouteGroup> get(
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
    List<Middleware>? middleware,
  }) =>
      route(HttpMethod.get, pattern, handler,
          timeout: timeout, middleware: middleware);

  Future<RouteGroup> head(
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
    List<Middleware>? middleware,
  }) =>
      route(HttpMethod.head, pattern, handler,
          timeout: timeout, middleware: middleware);

  Future<RouteGroup> post(
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
    List<Middleware>? middleware,
  }) =>
      route(HttpMethod.post, pattern, handler,
          timeout: timeout, middleware: middleware);

  Future<RouteGroup> put(
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
    List<Middleware>? middleware,
  }) =>
      route(HttpMethod.put, pattern, handler,
          timeout: timeout, middleware: middleware);

  Future<RouteGroup> delete(
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
    List<Middleware>? middleware,
  }) =>
      route(HttpMethod.delete, pattern, handler,
          timeout: timeout, middleware: middleware);

  Future<RouteGroup> patch(
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
    List<Middleware>? middleware,
  }) =>
      route(HttpMethod.patch, pattern, handler,
          timeout: timeout, middleware: middleware);

  Future<RouteGroup> options(
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
    List<Middleware>? middleware,
  }) =>
      route(HttpMethod.options, pattern, handler,
          timeout: timeout, middleware: middleware);

  /// Matches every method under the prefixed [pattern].
  Future<RouteGroup> all(
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
    List<Middleware>? middleware,
  }) =>
      route(HttpMethod.all, pattern, handler,
          timeout: timeout, middleware: middleware);

  /// Registers a WebSocket route under the prefixed [pattern].
  /// See [NitroServer.ws]. Returns `this`, so registrations chain.
  Future<RouteGroup> ws(String pattern, WsHandler handler) async {
    await server.ws('$_prefix$pattern', handler);
    return this;
  }

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
