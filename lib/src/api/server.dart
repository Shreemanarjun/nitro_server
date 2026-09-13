/// The public HTTP server.
library;

import 'package:meta/meta.dart';

import '../internal/instance_keys.dart';
import '../internal/native_attach.dart';
import '../internal/server_runner.dart';
import 'context.dart';
import 'event.dart';
import 'http_method.dart';

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

  int _port = 0;

  /// The actual bound port (== config port unless the config asked for 0).
  int get port => _port;

  /// Engine health and lifecycle observations. Broadcast.
  Stream<ServerEvent> get events => _runner.events;

  /// Registers [handler] for [method] + [pattern].
  ///
  /// Patterns are `/`-rooted with `:param` segments (`/users/:id`) and an
  /// optional trailing `*` wildcard. Static segments win over `:param`, which
  /// wins over `*`. [timeout] bounds the handler; `-1`… no — pass an explicit
  /// duration or leave the server default: a null timeout inherits
  /// [ServerConfig.defaultTimeout].
  Future<void> route(
    HttpMethod method,
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
    String customMethod = '',
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
    );
  }

  /// Appends [middleware] to the chain (outermost first). See [Middleware].
  Future<void> use(Middleware middleware) async {
    _runner.use(middleware);
  }

  /// Removes a registration. Unknown routes throw [RouteNotFoundException].
  Future<void> unroute(
    HttpMethod method,
    String pattern, {
    String customMethod = '',
  }) async {
    _runner.removeRoute(method, customMethod.toUpperCase(), pattern);
  }

  /// Shorthands so the common case stays one line:
  ///
  /// ```dart
  /// await server.get('/hello', (_) async => ResponseContext.text('hi'));
  /// ```
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

  /// Matches every method — handy for echo, proxy and fallback routes.
  Future<void> all(
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
  }) =>
      route(HttpMethod.all, pattern, handler, timeout: timeout);

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
