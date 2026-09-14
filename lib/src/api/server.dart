/// The public HTTP server.
library;

import 'package:meta/meta.dart';

import '../internal/instance_keys.dart';
import '../internal/native_attach.dart';
import '../internal/server_runner.dart';
import 'context.dart';
import 'event.dart';
import 'http_method.dart';
import 'route_group.dart';

/// A bound HTTP server backed by the native multithreaded engine.
///
/// Create with [NitroServer.bind], register routes with [route], shut down
/// with [close]. One instance owns one native accept loop; create several for
/// several ports.
///
/// Platform lifecycle (loud, by design):
/// * iOS: start only in the foreground — the OS suspends listener sockets in
///   the background and `bind` will fail there.
/// * Android: call from a foreground service; the engine cannot keep the
///   process alive by itself.
/// * Desktop: no constraints.
class NitroServer {
  NitroServer._(this._runner);

  /// Test seam: builds a facade over an injected runner (fakes) without
  /// touching native code. Never used in production.
  @visibleForTesting
  NitroServer.forRunnerForTesting(this._runner);

  final ServerRunner _runner;

  /// Binds [config.host]:[config.port] and starts accepting. A config port of
  /// 0 asks the OS for a free port — read it back from [port].
  static Future<NitroServer> bind([ServerConfig config = const ServerConfig()]) async {
    ensureNativeAttached();
    final serverId = Ids.nextServer();
    final runner = ServerRunner(attachedNative(serverKey(serverId)));
    final boundPort = runner.start(config);
    final server = NitroServer._(runner);
    server._port = boundPort;
    return server;
  }

  /// [bind] with named-argument sugar over a default [ServerConfig]:
  ///
  /// ```dart
  /// final server = await NitroServer.bindWith(port: 8080, host: '0.0.0.0');
  /// ```
  ///
  /// Any argument left null keeps the default; see [ServerConfig.copyWith]
  /// for the full set.
  static Future<NitroServer> bindWith({
    String? host,
    int? port,
    int? backlog,
    int? maxBodyBytes,
    Duration? defaultTimeout,
    Duration? keepAliveTimeout,
    int? maxRequestsPerConnection,
    int? workerThreads,
    TlsConfig? tls,
  }) {
    return bind(const ServerConfig().copyWith(
      host: host,
      port: port,
      backlog: backlog,
      maxBodyBytes: maxBodyBytes,
      defaultTimeout: defaultTimeout,
      keepAliveTimeout: keepAliveTimeout,
      maxRequestsPerConnection: maxRequestsPerConnection,
      workerThreads: workerThreads,
      tls: tls,
    ));
  }

  int _port = 0;

  /// The actual bound port (== config port unless the config asked for 0).
  int get port => _port;

  /// Engine health and lifecycle observations. Broadcast.
  Stream<ServerEvent> get events => _runner.events;

  /// Registers [handler] for [method] + [pattern]. Returns `this`, so
  /// registrations chain: `await server.get(...)` and
  /// `(await server.get(...)).post(...)` both work.
  ///
  /// Patterns are `/`-rooted with `:param` segments (`/users/:id`) and an
  /// optional trailing `*` wildcard. Static segments win over `:param`, which
  /// wins over `*`. [timeout] bounds the handler; a null timeout inherits
  /// [ServerConfig.defaultTimeout]. [middleware] wraps this route only,
  /// inside the server-global chain (see [use]).
  Future<NitroServer> route(
    HttpMethod method,
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
    String customMethod = '',
    List<Middleware>? middleware,
  }) async {
    _requirePattern(pattern);
    if (method == HttpMethod.custom && customMethod.isEmpty) {
      throw ArgumentError.value(
        customMethod,
        'customMethod',
        'HttpMethod.custom needs an explicit token',
      );
    }
    _runner.addRoute(
      method,
      customMethod.toUpperCase(),
      pattern,
      timeout,
      handler,
      middleware ?? const [],
    );
    return this;
  }

  /// Appends [middleware] to the chain (outermost first). Returns `this` for
  /// chaining. See [Middleware].
  Future<NitroServer> use(Middleware middleware) async {
    _runner.use(middleware);
    return this;
  }

  /// Removes a registration. Unknown routes throw [RouteNotFoundException].
  Future<NitroServer> unroute(
    HttpMethod method,
    String pattern, {
    String customMethod = '',
  }) async {
    _runner.removeRoute(method, customMethod.toUpperCase(), pattern);
    return this;
  }

  /// Shorthands so the common case stays one line:
  ///
  /// ```dart
  /// await server.get('/hello', (_) async => ResponseContext.text('hi'));
  /// ```
  Future<NitroServer> get(
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
    List<Middleware>? middleware,
  }) =>
      route(HttpMethod.get, pattern, handler,
          timeout: timeout, middleware: middleware);

  Future<NitroServer> head(
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
    List<Middleware>? middleware,
  }) =>
      route(HttpMethod.head, pattern, handler,
          timeout: timeout, middleware: middleware);

  Future<NitroServer> post(
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
    List<Middleware>? middleware,
  }) =>
      route(HttpMethod.post, pattern, handler,
          timeout: timeout, middleware: middleware);

  Future<NitroServer> put(
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
    List<Middleware>? middleware,
  }) =>
      route(HttpMethod.put, pattern, handler,
          timeout: timeout, middleware: middleware);

  Future<NitroServer> delete(
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
    List<Middleware>? middleware,
  }) =>
      route(HttpMethod.delete, pattern, handler,
          timeout: timeout, middleware: middleware);

  Future<NitroServer> patch(
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
    List<Middleware>? middleware,
  }) =>
      route(HttpMethod.patch, pattern, handler,
          timeout: timeout, middleware: middleware);

  Future<NitroServer> options(
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
    List<Middleware>? middleware,
  }) =>
      route(HttpMethod.options, pattern, handler,
          timeout: timeout, middleware: middleware);

  /// Matches every method — handy for echo, proxy and fallback routes.
  Future<NitroServer> all(
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
    List<Middleware>? middleware,
  }) =>
      route(HttpMethod.all, pattern, handler,
          timeout: timeout, middleware: middleware);

  /// A path-prefixed view of this server: `server.group('/api').get(...)`
  /// registers `/api/...`. Groups nest; middleware stays server-global.
  RouteGroup group(String prefix) =>
      RouteGroup(server: this, prefix: prefix);

  /// Overrides the answer for unmatched routes (default: empty 404). May be
  /// sync or async; a throwing fallback degrades to the default.
  set notFoundHandler(NotFoundHandler handler) {
    _runner.notFoundHandler = handler;
  }

  /// Overrides the answer for throwing handlers (default: 500 text). May be
  /// sync or async; a throwing fallback degrades to the default.
  set errorHandler(ErrorHandler handler) {
    _runner.errorHandler = handler;
  }

  /// Stops accepting and answers every parked request with 503. Idempotent.
  Future<void> close() => _runner.close();
}

void _requirePattern(String pattern) {
  if (!pattern.startsWith('/')) {
    throw ArgumentError.value(
      pattern,
      'pattern',
      'route patterns are /-rooted (e.g. /users/:id)',
    );
  }
}
