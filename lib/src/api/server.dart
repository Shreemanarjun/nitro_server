/// The public HTTP server.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:meta/meta.dart';

import '../internal/instance_keys.dart';
import '../internal/native_attach.dart';
import '../internal/server_runner.dart';
import 'context.dart';
import 'event.dart';
import 'http_method.dart';
import 'metrics.dart';
import 'native_loader.dart';
import 'route_group.dart';
import 'ws.dart';

/// Registers routes and middleware on a freshly bound server. With
/// [ServerConfig.isolates] above 1 it runs once per isolate (the calling
/// one first), so it must be a top-level or static function — or a closure
/// capturing only values an isolate can receive — and everything the server
/// serves must be registered inside it.
typedef ServerSetup = FutureOr<void> Function(NitroServer server);

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

  /// Helper isolates dealt a share of this server's requests (empty for a
  /// single-isolate server). Closed with the server.
  List<_Helper> _helpers = const [];

  /// Binds [config.host]:[config.port] and starts accepting. A config port of
  /// 0 asks the OS for a free port — read it back from [port].
  ///
  /// [setup] registers routes before the first request can arrive; it is
  /// required when [ServerConfig.isolates] is not 1, because every isolate
  /// behind the server must register the same handlers (see [ServerSetup]).
  static Future<NitroServer> bind([
    ServerConfig config = const ServerConfig(),
    ServerSetup? setup,
  ]) async {
    ensureNativeAttached();
    final isolates = config.isolates == 0 ? _autoIsolates() : config.isolates;
    if (isolates > 1 && setup == null) {
      throw ArgumentError.value(
        config.isolates,
        'isolates',
        'a multi-isolate server needs a `setup` function: routes must be '
            'registered in every isolate',
      );
    }
    final key = serverKey(Ids.nextServer());
    final runner = ServerRunner(attachedNative(key));
    final server = NitroServer._(runner);
    if (setup != null) await setup(server);
    if (isolates > 1) {
      server._helpers = await _Helper.spawnAll(
        count: isolates - 1,
        key: key,
        setup: setup!,
        dylibPath: loadedNitroServerNativePath,
      );
    }
    server._port = runner.start(config);
    return server;
  }

  /// Auto size for [ServerConfig.isolates] == 0: half the cores, so the
  /// native workers and the client side keep the rest, clamped to 1–8.
  static int _autoIsolates() => (Platform.numberOfProcessors ~/ 2).clamp(1, 8);

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
    int? isolates,
    TlsConfig? tls,
    ServerSetup? setup,
  }) {
    return bind(
      const ServerConfig().copyWith(
        host: host,
        port: port,
        backlog: backlog,
        maxBodyBytes: maxBodyBytes,
        defaultTimeout: defaultTimeout,
        keepAliveTimeout: keepAliveTimeout,
        maxRequestsPerConnection: maxRequestsPerConnection,
        workerThreads: workerThreads,
        isolates: isolates,
        tls: tls,
      ),
      setup,
    );
  }

  /// Number of isolates running handlers for this server (1 + helpers).
  int get isolates => 1 + _helpers.length;

  int _port = 0;

  /// The actual bound port (== config port unless the config asked for 0).
  int get port => _port;

  /// Engine health and lifecycle observations. Broadcast.
  Stream<ServerEvent> get events => _runner.events;

  /// Request counts and latency quantiles per route, for this isolate's
  /// runner (each helper isolate keeps its own).
  ServerMetrics get metrics => _runner.metrics;

  /// Registers [handler] for [method] + [pattern]. Returns `this`, so
  /// registrations chain: `await server.get(...)` and
  /// `(await server.get(...)).post(...)` both work.
  ///
  /// Patterns are `/`-rooted with `:param` segments (`/users/:id`) and an
  /// optional trailing `*` wildcard. Static segments win over `:param`, which
  /// wins over `*`. [timeout] bounds the handler; a null timeout inherits
  /// [ServerConfig.defaultTimeout]. [middleware] wraps this route only,
  /// inside the server-global chain (see [use]). With [streamBody] the
  /// handler runs as soon as the head is in and reads the body from
  /// [RequestContext.bodyStream] — for uploads too large to assemble.
  /// [maxBodyBytes] caps this route's request body; null inherits
  /// [ServerConfig.maxBodyBytes].
  Future<NitroServer> route(
    HttpMethod method,
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
    String customMethod = '',
    List<Middleware>? middleware,
    bool streamBody = false,
    int? maxBodyBytes,
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
      streamBody,
      maxBodyBytes,
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
  }) => route(
    HttpMethod.get,
    pattern,
    handler,
    timeout: timeout,
    middleware: middleware,
  );

  Future<NitroServer> head(
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
    List<Middleware>? middleware,
  }) => route(
    HttpMethod.head,
    pattern,
    handler,
    timeout: timeout,
    middleware: middleware,
  );

  Future<NitroServer> post(
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
    List<Middleware>? middleware,
    bool streamBody = false,
    int? maxBodyBytes,
  }) => route(
    HttpMethod.post,
    pattern,
    handler,
    timeout: timeout,
    middleware: middleware,
    streamBody: streamBody,
    maxBodyBytes: maxBodyBytes,
  );

  Future<NitroServer> put(
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
    List<Middleware>? middleware,
    bool streamBody = false,
    int? maxBodyBytes,
  }) => route(
    HttpMethod.put,
    pattern,
    handler,
    timeout: timeout,
    middleware: middleware,
    streamBody: streamBody,
    maxBodyBytes: maxBodyBytes,
  );

  Future<NitroServer> delete(
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
    List<Middleware>? middleware,
  }) => route(
    HttpMethod.delete,
    pattern,
    handler,
    timeout: timeout,
    middleware: middleware,
  );

  Future<NitroServer> patch(
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
    List<Middleware>? middleware,
    bool streamBody = false,
    int? maxBodyBytes,
  }) => route(
    HttpMethod.patch,
    pattern,
    handler,
    timeout: timeout,
    middleware: middleware,
    streamBody: streamBody,
    maxBodyBytes: maxBodyBytes,
  );

  Future<NitroServer> options(
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
    List<Middleware>? middleware,
  }) => route(
    HttpMethod.options,
    pattern,
    handler,
    timeout: timeout,
    middleware: middleware,
  );

  /// Matches every method — handy for echo, proxy and fallback routes.
  Future<NitroServer> all(
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
    List<Middleware>? middleware,
  }) => route(
    HttpMethod.all,
    pattern,
    handler,
    timeout: timeout,
    middleware: middleware,
  );

  /// Registers a route whose response is fixed and served entirely by the
  /// engine: the request never crosses into Dart, so it answers at raw engine
  /// throughput. Ideal for health checks, static assets, and pre-rendered or
  /// cached bodies.
  ///
  /// [body] is the exact response bytes. [contentType], when given, sets
  /// `Content-Type`; [headers] add any others. The engine frames
  /// `Content-Length` and keep-alive `Connection` itself, and answers a `HEAD`
  /// on a GET route headers-only. [method] defaults to GET (the common case);
  /// pass another verb — or [HttpMethod.custom] with [customMethod] — for a
  /// fixed answer on it. Registering replaces any handler, WebSocket, or
  /// static route already at (method, pattern).
  ///
  /// There is no handler, so route [middleware], [timeout] and the error /
  /// not-found fallbacks never apply. A request that carries a body closes the
  /// connection after the answer (a fixed route has no reader for it). To
  /// change the body, register again (or [unroute] and re-add). Returns `this`
  /// for chaining.
  Future<NitroServer> staticRoute(
    HttpMethod method,
    String pattern,
    List<int> body, {
    int status = 200,
    String? contentType,
    Map<String, String> headers = const {},
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
    _runner.addStaticRoute(
      method,
      customMethod.toUpperCase(),
      pattern,
      status,
      {'content-type': ?contentType, ...headers},
      body,
    );
    return this;
  }

  /// GET shorthand for [staticRoute]: `server.getStatic('/health', bytes)`.
  Future<NitroServer> getStatic(
    String pattern,
    List<int> body, {
    int status = 200,
    String? contentType,
    Map<String, String> headers = const {},
  }) => staticRoute(
    HttpMethod.get,
    pattern,
    body,
    status: status,
    contentType: contentType,
    headers: headers,
  );

  /// Registers a WebSocket route (RFC 6455). Matching handshakes upgrade
  /// in-engine and [handler] receives the live session; anything else on
  /// the pattern (plain requests, bad handshakes) is answered 426/400 and
  /// never dispatched. Returns `this` for chaining.
  ///
  /// A pattern holds either a WS or an HTTP route: registering one evicts
  /// the other (the engine keeps a single entry per method + pattern), and
  /// [unroute] removes whichever stands. Global middleware does not wrap
  /// WS handlers — the socket leaves HTTP mode before dispatch could run
  /// it; see [WsHandler] for the auth pattern.
  ///
  /// [protocols] lists accepted subprotocols in preference order: the
  /// handshake selects the first one the client offers (`Sec-WebSocket-
  /// Protocol`) and exposes it as [WsSession.protocol]; a client that
  /// offers only others is refused with 400. Empty accepts any handshake.
  Future<NitroServer> ws(
    String pattern,
    WsHandler handler, {
    List<String> protocols = const [],
  }) async {
    _requirePattern(pattern);
    _runner.addWsRoute(pattern, handler, protocols);
    return this;
  }

  /// A path-prefixed view of this server: `server.group('/api').get(...)`
  /// registers `/api/...`. Groups nest; middleware stays server-global.
  RouteGroup group(String prefix) => RouteGroup(server: this, prefix: prefix);

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

  /// Stops the server. Without [drain] it stops now: parked requests get
  /// a 503. With [drain] it first closes the listener, answers everything
  /// already accepted (each answer says `Connection: close`) and waits up
  /// to that long for in-flight requests to finish, then stops. Idempotent.
  Future<void> close({Duration? drain}) async {
    if (drain != null) await _runner.drain(drain);
    await _runner.close();
    // The engine is stopped: helpers have nothing left to answer.
    final helpers = _helpers;
    _helpers = const [];
    for (final helper in helpers) {
      await helper.close();
    }
  }
}

/// One helper isolate: a [ServerRunner] on the same engine key, dealt every
/// n-th request by the engine. Lives until the server closes.
class _Helper {
  _Helper(this._control, this._replies);

  final SendPort _control;
  final ReceivePort _replies;

  static Future<List<_Helper>> spawnAll({
    required int count,
    required String key,
    required ServerSetup setup,
    required String? dylibPath,
  }) async {
    final helpers = <_Helper>[];
    for (var i = 0; i < count; i++) {
      final replies = ReceivePort();
      // Uncaught errors in the helper (a throwing `setup`) land on the same
      // port, so a failure surfaces here instead of hanging `bind`.
      await Isolate.spawn(
        _helperMain,
        _HelperBoot(key, dylibPath, setup, replies.sendPort),
        debugName: 'nitro_server:$key:${i + 1}',
        onError: replies.sendPort,
      );
      final queue = StreamIterator<Object?>(replies);
      // The first message is the control port, sent once routes are
      // registered and streams subscribed — the engine may deal to this
      // helper from that moment on.
      if (!await queue.moveNext() || queue.current is! SendPort) {
        replies.close();
        for (final helper in helpers) {
          await helper.close();
        }
        throw StateError(
          'nitro_server: helper isolate ${i + 1} failed to start: '
          '${queue.current}',
        );
      }
      final helper = _Helper(queue.current as SendPort, replies);
      helper._queue = queue;
      helpers.add(helper);
    }
    return helpers;
  }

  late final StreamIterator<Object?> _queue;

  Future<void> close() async {
    _control.send(_HelperBoot.closeSignal);
    await _queue.moveNext(); // 'closed' — the helper's runner is shut.
    _replies.close();
  }
}

class _HelperBoot {
  const _HelperBoot(this.key, this.dylibPath, this.setup, this.reply);

  static const closeSignal = 'close';

  final String key;
  final String? dylibPath;
  final ServerSetup setup;
  final SendPort reply;
}

/// Helper isolate entry: same key, own runner, same routes, then wait for
/// the close signal. Never starts or stops the engine — the main isolate
/// owns its lifecycle — but does close its runner so its stream ports and
/// native buffers are released before the isolate exits.
Future<void> _helperMain(_HelperBoot boot) async {
  if (boot.dylibPath != null) loadNitroServerNative(path: boot.dylibPath);
  final runner = ServerRunner(attachedNative(boot.key));
  final server = NitroServer._(runner);
  await boot.setup(server);
  runner.prepareHelper();
  final control = ReceivePort();
  boot.reply.send(control.sendPort);
  await for (final message in control) {
    if (message == _HelperBoot.closeSignal) break;
  }
  control.close();
  await runner.close();
  boot.reply.send('closed');
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
