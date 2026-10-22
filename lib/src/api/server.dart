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
import 'controller.dart';
import 'event.dart';
import 'http_method.dart';
import 'metrics.dart';
import 'native_loader.dart';
import 'route_group.dart';
import 'route_registrar.dart';
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
class NitroServer with RouteRegistrar<NitroServer> {
  NitroServer._(this._runner, this._config);

  /// Test seam: builds a facade over an injected runner (fakes) without
  /// touching native code. Never used in production.
  @visibleForTesting
  NitroServer.forRunnerForTesting(this._runner)
    : _config = const ServerConfig();

  final ServerRunner _runner;

  /// The config the server started with, resolved (see [config]).
  ServerConfig _config;

  /// The setup that built this server's routes, kept so [reload] can re-run it.
  ServerSetup? _setup;

  /// Helper isolates dealt a share of this server's requests (empty for a
  /// single-isolate server). Closed with the server.
  List<_Helper> _helpers = const [];

  /// How long the main isolate waits for a helper isolate to start, reload,
  /// report metrics or close before declaring it dead. A helper that misses
  /// the deadline is killed, a `notice` event names it, [helpersHealthy]
  /// turns false (so `serveObservability`'s default readiness answers 503),
  /// and the operation proceeds without it — a wedged helper can never hang
  /// `bind`, `reload`, `aggregatedMetrics` or `close`.
  static Duration helperTimeout = const Duration(seconds: 10);

  /// Helper isolates still alive (0 for a single-isolate server).
  int get helpersAlive => _helpers.where((h) => h.alive).length;

  /// False once any helper isolate has been declared dead (see
  /// [helperTimeout]). The engine stops dealing requests to it; the rest of
  /// the server keeps serving at reduced capacity.
  bool get helpersHealthy => _helpers.every((h) => h.alive);

  /// Live connections the engine currently holds (every protocol).
  int get liveConnections => _runner.liveConnections;

  /// Test seam: this isolate's metrics in the cross-isolate wire form.
  @visibleForTesting
  Map<String, Object?> metricsWireForTesting() => _runner.metricsWire();

  /// Binds [config.host]:[config.port] and starts accepting. A config port of
  /// 0 asks the OS for a free port — read it back from [port].
  ///
  /// [setup] registers routes before the first request can arrive. It is
  /// required for a multi-isolate server (an explicit [ServerConfig.isolates]
  /// above 1), because every isolate must register the same handlers (see
  /// [ServerSetup]). It also unlocks auto: `isolates: 0` scales to the core
  /// count when a [setup] is present, and stays single-isolate without one.
  static Future<NitroServer> bind([
    ServerConfig config = const ServerConfig(),
    ServerSetup? setup,
  ]) async {
    config.validate();
    _ensureNativeLoaded();
    // Auto (`isolates: 0`): scale to the machine so the engine can fan a
    // CPU-bound handler across cores — but ONLY when a `setup` is given, since
    // every isolate must re-register the routes (handler closures can't cross
    // isolates; that is a Dart constraint, not a nitro one). Without a `setup`
    // auto resolves to a single isolate so a zero-config server still binds
    // instead of throwing. An EXPLICIT `isolates > 1` without a `setup` is a
    // caller mistake and still throws.
    final int isolates;
    if (config.isolates == 0) {
      isolates = setup == null ? 1 : _autoIsolates();
    } else {
      isolates = config.isolates;
      if (isolates > 1 && setup == null) {
        throw ArgumentError.value(
          config.isolates,
          'isolates',
          'a multi-isolate server needs a `setup` function: routes must be '
              'registered in every isolate',
        );
      }
    }
    final key = serverKey(Ids.nextServer());
    final runner = ServerRunner(attachedNative(key));
    final server = NitroServer._(runner, config).._setup = setup;
    if (setup != null) await setup(server);
    if (isolates > 1) {
      server._helpers = await _Helper.spawnAll(
        count: isolates - 1,
        key: key,
        setup: setup!,
        dylibPath: loadedNitroServerNativePath,
        wsCompression: config.wsCompression,
        responseTiming: config.responseTiming,
        exposeErrorDetails: config.exposeErrorDetails,
        wsMaxBufferBytes: config.wsMaxBufferBytes,
        detach: runner.detachEmitter,
        notice: runner.emitNotice,
      );
    }
    server._port = runner.start(config);
    server._config = config.copyWith(port: server._port, isolates: isolates);
    return server;
  }

  /// Opens the cmake-built native library so [bind] works in a Dart CLI
  /// program without a manual [loadNitroServerNative] call. On Flutter the
  /// library is bundled and no cmake output exists, so a not-found is ignored
  /// and the already-loaded symbols are used; if attaching then fails the
  /// actionable "build it first" error from the load is raised.
  static void _ensureNativeLoaded() {
    StateError? loadError;
    try {
      loadNitroServerNative();
      // coverage:ignore-start
    } on StateError catch (e) {
      loadError = e; // cmake output absent: Flutter/bundled, or not built yet
    }
    // coverage:ignore-end
    try {
      ensureNativeAttached();
    } catch (_) {
      // coverage:ignore-start
      if (loadError != null) throw loadError;
      rethrow;
      // coverage:ignore-end
    }
  }

  /// Auto size for [ServerConfig.isolates] == 0 (with a `setup`): the full core
  /// count, so a CPU-bound handler can fan out across every core — nitro's own
  /// guidance is "set it to the core count and let the engine decide", and the
  /// engine keeps light handlers on one isolate, so extra isolates are headroom,
  /// not a tax (see [ServerConfig.isolates]). Capped at 32 to stay sane on very
  /// large boxes. Note: inside a cgroup/cpuset-limited container this reports
  /// the host CPU count, not the quota — pin an explicit `isolates` there.
  static int _autoIsolates() => Platform.numberOfProcessors.clamp(1, 32);

  /// [bind] with named-argument sugar over a default [ServerConfig]:
  ///
  /// ```dart
  /// final server = await NitroServer.bindWith(port: 8080, host: '0.0.0.0');
  /// ```
  ///
  /// Any argument left null keeps the default; see [ServerConfig.copyWith]
  /// for the full set. [dylibPath] opens the native library from a non-default
  /// location before binding (otherwise [bind] searches the usual paths).
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
    String? dylibPath,
    ServerSetup? setup,
  }) {
    if (dylibPath != null) loadNitroServerNative(path: dylibPath);
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

  /// The effective configuration this server started with: the [ServerConfig]
  /// passed to [bind], with [ServerConfig.port] and [ServerConfig.isolates]
  /// resolved to the values actually in force (the bound port, and the auto
  /// isolate count when the config asked for 0).
  ServerConfig get config => _config;

  /// The base URL this server answers on: `http`/`https` per
  /// [ServerConfig.tls], the configured [ServerConfig.host] and the bound
  /// [port] (e.g. `http://127.0.0.1:8080`).
  Uri get uri => Uri(
    scheme: _config.tls.enabled ? 'https' : 'http',
    host: _config.host,
    port: _port,
  );

  /// A read-only snapshot of the routes registered on this server — each with
  /// its method, pattern and [RouteKind] (handler, WebSocket or static). Useful
  /// for a health/route-listing endpoint, debugging, or checking what a
  /// [reload] produced. On a multi-isolate server every isolate registers the
  /// same set, so this (the calling isolate's) view represents all of them.
  List<RegisteredRoute> get routes => _runner.routes;

  /// Engine health and lifecycle observations. Broadcast.
  Stream<ServerEvent> get events => _runner.events;

  /// Request counts and latency quantiles per route, for this isolate's
  /// runner (each helper isolate keeps its own). Use [aggregatedMetrics] to sum
  /// across all isolates.
  ServerMetrics get metrics => _runner.metrics;

  /// Metrics summed across every isolate (this one plus all helpers). Counts
  /// and latency histograms add, so aggregate quantiles are as accurate as a
  /// single isolate's — the one view to scrape with `isolates > 1`. With a
  /// single isolate it equals [metrics].
  Future<ServerMetrics> aggregatedMetrics() async {
    final snapshots = <Map<String, Object?>>[_runner.metricsWire()];
    for (final helper in _helpers) {
      if (!helper.alive) continue;
      final snapshot = await helper.collectMetrics();
      if (snapshot != null) snapshots.add(snapshot);
      _noteIfDead(helper, 'aggregatedMetrics');
    }
    return mergeIsolateMetrics(snapshots);
  }

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
  @override
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
  /// [unroute] removes whichever stands. Server-global middleware does not
  /// wrap WS handlers — the engine completes the upgrade before dispatch —
  /// so pass [middleware] (route-local, outermost first; a group's `use` list
  /// prepends) to run a chain against the handshake before [handler]. Reuse
  /// the HTTP middleware unchanged: because the 101 is already on the wire a
  /// short-circuit such as `bearerAuth`'s 401 cannot become an HTTP status —
  /// the socket closes with `4000 + status` (4401, 4403: the app range) or
  /// 1008 for a non-4xx, and [handler] never runs. See [WsHandler].
  ///
  /// [protocols] lists accepted subprotocols in preference order: the
  /// handshake selects the first one the client offers (`Sec-WebSocket-
  /// Protocol`) and exposes it as [WsSession.protocol]; a client that
  /// offers only others is refused with 400. Empty accepts any handshake.
  Future<NitroServer> ws(
    String pattern,
    WsHandler handler, {
    List<String> protocols = const [],
    List<Middleware>? middleware,
  }) async {
    _requirePattern(pattern);
    _runner.addWsRoute(pattern, handler, protocols, middleware ?? const []);
    return this;
  }

  /// A path-prefixed view of this server: `server.group('/api').get(...)`
  /// registers `/api/...`. Groups nest; middleware stays server-global.
  RouteGroup group(String prefix) => RouteGroup(server: this, prefix: prefix);

  /// Mounts a [Controller] — a class that groups related routes behind a
  /// shared prefix and middleware (the Spring `@RestController` idea, without
  /// annotations or codegen). Scopes a [group] to the controller's `prefix`,
  /// applies its `middleware`, then runs [Controller.register]. Returns `this`,
  /// so mounts chain: `await (await server.mount(a)).mount(b)`.
  ///
  /// ```dart
  /// await server.mount(UserController(db));
  /// ```
  Future<NitroServer> mount(Controller controller) async {
    final scoped = group(controller.prefix);
    for (final m in controller.middleware) {
      await scoped.use(m);
    }
    await controller.register(scoped);
    return this;
  }

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

  /// Rebuilds the whole routing surface on the live socket: unregisters every
  /// route, clears middleware and resets the 404/500 fallbacks, then re-runs
  /// [setup] (or the [ServerSetup] this server was bound with). Added, removed,
  /// changed and re-mapped routes all take effect without dropping the port or
  /// open connections — the primitive behind hot reload (see
  /// `package:nitro_server/hot_reload.dart`).
  ///
  /// On a multi-isolate server every helper isolate rebuilds too, re-running
  /// the [ServerSetup] it was bound with. On a multi-isolate server the [setup]
  /// (or the bound one) is re-run on every helper isolate too, so a [setup]
  /// passed here must be sendable across isolates (a top-level or static
  /// function). Throws [StateError] when the server was bound without a
  /// [ServerSetup] and none is passed here — there is nothing to rebuild from.
  ///
  /// The rebuild is transactional: the live routes keep serving while [setup]
  /// registers the new ones, then routes it did not re-register are removed. If
  /// [setup] throws, its partial additions roll back and the previous routes,
  /// middleware and fallbacks stay — a bad reload never blanks the server.
  Future<NitroServer> reload([ServerSetup? setup]) async {
    final rebuild = setup ?? _setup;
    if (rebuild == null) {
      throw StateError(
        'reload() needs a ServerSetup: bind the server with one, or pass one '
        'to reload().',
      );
    }
    _setup = rebuild;
    await _runner.reload(() async => rebuild(this));
    for (final helper in _helpers) {
      if (!helper.alive) continue;
      await helper.reload(rebuild);
      _noteIfDead(helper, 'reload');
    }
    return this;
  }

  /// Reports a helper the last operation found unresponsive (and killed).
  void _noteIfDead(_Helper helper, String during) {
    if (helper.alive || helper.reported) return;
    helper.reported = true;
    _runner.emitNotice(
      'helper isolate ${helper.name} unresponsive during $during '
      '(> ${helperTimeout.inMilliseconds} ms): killed; serving without it',
    );
  }

  final _closed = Completer<void>();

  /// Completes when [close] is called. Lets add-ons release their own resources
  /// when the server stops — `enableHotReload` uses it to stop watching.
  Future<void> get onClose => _closed.future;

  /// Stops the server. Without [drain] it stops now: parked requests get
  /// a 503. With [drain] it first closes the listener, answers everything
  /// already accepted (each answer says `Connection: close`) and waits up
  /// to that long for in-flight requests to finish, then stops. Idempotent.
  Future<void> close({Duration? drain}) async {
    if (!_closed.isCompleted) _closed.complete();
    if (drain != null) await _runner.drain(drain);
    await _runner.close();
    // The engine is stopped: helpers have nothing left to answer.
    final helpers = _helpers;
    _helpers = const [];
    for (final helper in helpers) {
      await helper.close();
    }
  }

  /// Hot-swaps the TLS certificate/key on a running TLS server — zero-downtime
  /// cert rotation. New handshakes use [tls]; connections already open keep
  /// their certificate. Returns true on success; false if the engine was built
  /// without TLS, the server was not started with TLS, or [tls] is invalid.
  ///
  /// ```dart
  /// server.reloadTls(TlsConfig(certPem: newCert, keyPem: newKey));
  /// ```
  bool reloadTls(TlsConfig tls) => _runner.reloadTls(tls);
}

/// One helper isolate: a [ServerRunner] on the same engine key, dealt every
/// n-th request by the engine. Lives until the server closes.
class _Helper {
  _Helper(
    this._control,
    this._replies,
    this._isolate,
    this.name,
    this.emitterId,
    this._detach,
  );

  final SendPort _control;
  final ReceivePort _replies;
  final Isolate _isolate;
  final String name;

  /// The helper's emitter in the engine (see `NitroServerNative.emitterId`).
  final int emitterId;

  /// Drops [emitterId] from the engine's dispatch rotation.
  final bool Function(int emitterId) _detach;

  /// False once a reply missed [NitroServer.helperTimeout]: the isolate was
  /// killed and nothing is sent to it again.
  bool alive = true;

  /// Whether the death has been reported on the server's event stream.
  bool reported = false;

  /// The isolate's uncaught-error port (separate from replies).
  ReceivePort? _errors;

  /// The isolate's exit port: a helper that dies (killed, `Isolate.exit`, a
  /// fatal VM error) is noticed the moment it exits, not on the next reply
  /// that times out — readiness goes red at once.
  ReceivePort? _exits;

  /// Set by [close] before the helper is told to stop, so its orderly exit
  /// is not reported as a death.
  bool _closing = false;

  static Future<List<_Helper>> spawnAll({
    required int count,
    required String key,
    required ServerSetup setup,
    required String? dylibPath,
    required bool wsCompression,
    required bool responseTiming,
    required bool exposeErrorDetails,
    required int wsMaxBufferBytes,
    required bool Function(int emitterId) detach,
    required void Function(String message) notice,
  }) async {
    final helpers = <_Helper>[];
    for (var i = 0; i < count; i++) {
      final replies = ReceivePort();
      // Uncaught errors in the helper (a throwing `setup`, a stray timer)
      // get their own port: on the reply port they would be read as the
      // acknowledgement of whatever was in flight and desynchronise it.
      final errors = ReceivePort();
      final exits = ReceivePort();
      final name = 'nitro_server:$key:${i + 1}';
      final Isolate isolate;
      try {
        isolate = await Isolate.spawn(
          _helperMain,
          _HelperBoot(
            key,
            dylibPath,
            setup,
            replies.sendPort,
            wsCompression,
            responseTiming,
            exposeErrorDetails,
            wsMaxBufferBytes,
          ),
          debugName: name,
          onError: errors.sendPort,
          onExit: exits.sendPort,
        );
      } on ArgumentError catch (e) {
        // The only non-sendable thing in the boot message is `setup`: a
        // multi-isolate `setup` must be SENDABLE to each isolate. A top-level
        // or static function always is — prefer that. A closure crosses only
        // if it captures nothing mutable/non-sendable; one capturing local
        // mutable state (a List, a controller, `this`) can't. The routes the
        // `setup` registers may themselves be closures: they are built fresh
        // inside each isolate, so only `setup` must be sendable.
        //
        // A non-sendable setup throws on the FIRST spawn (the same object is
        // sent to every isolate), so no helper is ever live here — nothing to
        // close but this iteration's `replies` port.
        replies.close();
        errors.close();
        exits.close();
        throw ArgumentError(
          'nitro_server: `setup` must be sendable across isolates for a '
          'multi-isolate server (isolates > 1 or auto `isolates: 0`) — use a '
          'top-level or static function (a closure works only if it captures '
          'nothing mutable). Underlying error: ${e.message}',
        );
      }
      final queue = StreamIterator<Object?>(replies);
      // The first message is `[control port, emitter id]`, sent once routes
      // are registered and streams subscribed — the engine may deal to this
      // helper from that moment on. A helper whose `setup` never returns
      // (wedged) misses [NitroServer.helperTimeout] and is killed: `bind`
      // fails loudly instead of hanging.
      // A `setup` that throws reports on the error port; race it against the
      // hello so `bind` fails with the real error instead of the timeout.
      // One listener for the port's whole life (a ReceivePort cannot be
      // re-listened): before the hello it captures the boot failure, after it
      // every uncaught error is reported as a notice, never read as an ack.
      Object? spawnError;
      var booted = false;
      final firstError = Completer<void>();
      errors.listen((e) {
        if (booted) {
          notice('helper isolate $name uncaught error: $e');
          return;
        }
        spawnError ??= e;
        if (!firstError.isCompleted) firstError.complete();
      });
      final started = await Future.any<bool>([
        queue.moveNext(),
        firstError.future.then((_) => false),
      ]).timeout(NitroServer.helperTimeout, onTimeout: () => false);
      final hello = started ? queue.current : null;
      if (hello is! List || hello.length != 2 || hello[0] is! SendPort) {
        isolate.kill(priority: Isolate.immediate);
        replies.close();
        errors.close();
        exits.close();
        for (final helper in helpers) {
          await helper.close();
        }
        throw StateError(
          'nitro_server: helper isolate ${i + 1} failed to start: '
          '${spawnError ?? (started ? queue.current : 'no reply within '
                        '${NitroServer.helperTimeout.inMilliseconds} ms')}',
        );
      }
      final helper = _Helper(
        hello[0] as SendPort,
        replies,
        isolate,
        name,
        hello[1] as int,
        detach,
      );
      booted = true; // later uncaught errors are notices, never an ack
      helper._errors = errors;
      helper._exits = exits;
      // Death is detected here, not by a reply that never comes: the helper
      // is marked dead, detached from the engine and reported at once, and
      // a reply someone is waiting on fails now (the port closes).
      exits.listen((_) {
        if (helper._closing || !helper.alive) return;
        notice('helper isolate $name exited');
        helper._die();
      });
      helper._queue = queue;
      helpers.add(helper);
    }
    return helpers;
  }

  late final StreamIterator<Object?> _queue;

  /// Waits for the helper's next reply. On [NitroServer.helperTimeout] the
  /// helper is declared dead and killed; returns false. Never throws.
  Future<bool> _reply() async {
    if (!alive) return false;
    final ok = await _queue.moveNext().timeout(
      NitroServer.helperTimeout,
      onTimeout: () => false,
    );
    if (ok) return true;
    _die();
    return false;
  }

  void _die() {
    if (!alive) return;
    alive = false;
    // Order matters: stop the engine dealing to it first, so no request lands
    // on a port that is about to vanish; then kill. Requests already dealt
    // run into their route timeout (408) — the engine retires those itself.
    _detach(emitterId);
    _isolate.kill(priority: Isolate.immediate);
    _replies.close();
    _errors?.close();
    _exits?.close();
  }

  /// Tells the helper to rebuild its routes from [setup], matching the main
  /// isolate's [NitroServer.reload]. [setup] must be sendable across isolates.
  /// A helper that does not confirm in time is killed (see [alive]).
  Future<void> reload(ServerSetup setup) async {
    if (!alive) return;
    _control.send(setup);
    await _reply(); // 'reloaded'
  }

  /// Asks the helper for its metrics as an isolate-portable map; null when
  /// the helper is (or just became) dead.
  Future<Map<String, Object?>?> collectMetrics() async {
    if (!alive) return null;
    _control.send(_HelperBoot.collectSignal);
    if (!await _reply()) return null;
    final reply = _queue.current;
    if (reply is! Map) return null; // never cast a stray message
    return reply.cast<String, Object?>();
  }

  Future<void> close() async {
    if (!alive) return;
    _closing = true; // its exit is expected, not a death
    _control.send(_HelperBoot.closeSignal);
    if (await _reply()) {
      _replies.close(); // 'closed' — the helper's runner is shut.
      _errors?.close();
      _exits?.close();
    }
  }
}

class _HelperBoot {
  const _HelperBoot(
    this.key,
    this.dylibPath,
    this.setup,
    this.reply,
    this.wsCompression,
    this.responseTiming,
    this.exposeErrorDetails,
    this.wsMaxBufferBytes,
  );

  static const closeSignal = 'close';
  static const collectSignal = 'metrics';

  final String key;
  final String? dylibPath;
  final ServerSetup setup;
  final SendPort reply;
  final bool wsCompression;
  final bool responseTiming;
  final bool exposeErrorDetails;
  final int wsMaxBufferBytes;
}

/// Helper isolate entry: same key, own runner, same routes, then wait for
/// the close signal. Never starts or stops the engine — the main isolate
/// owns its lifecycle — but does close its runner so its stream ports and
/// native buffers are released before the isolate exits.
Future<void> _helperMain(_HelperBoot boot) async {
  if (boot.dylibPath != null) loadNitroServerNative(path: boot.dylibPath);
  final runner = ServerRunner(attachedNative(boot.key));
  // The helper's facade only runs setup on the shared engine; its config is
  // never read (the main isolate owns lifecycle and holds the real config).
  final server = NitroServer._(runner, const ServerConfig());
  await boot.setup(server);
  runner.prepareHelper(
    wsCompression: boot.wsCompression,
    responseTiming: boot.responseTiming,
    exposeErrorDetails: boot.exposeErrorDetails,
    wsMaxBufferBytes: boot.wsMaxBufferBytes,
  );
  final control = ReceivePort();
  boot.reply.send([control.sendPort, runner.emitterId]);
  await for (final message in control) {
    if (message == _HelperBoot.closeSignal) break;
    if (message == _HelperBoot.collectSignal) {
      boot.reply.send(runner.metricsWire());
      continue;
    }
    if (message is ServerSetup) {
      // The isolate's code is already hot-reloaded; rebuild the routes from the
      // setup the main isolate sent (transactionally, same as the main runner).
      await runner.reload(() async => message(server));
      boot.reply.send('reloaded');
    }
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
