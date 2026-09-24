/// Request dispatch: the single subscriber behind every server instance.
///
/// Mirrors `nitro_http`'s `RequestRunner`: the generated streams are
/// per-instance with exactly one subscriber each, and this object is it. It
/// demultiplexes on `requestId`, reassembles bodies, runs the registered
/// handler, and answers exactly once with `respond`.
///
/// Lifetime notes:
/// * Body-chunk payloads are `asTypedList` VIEWS into native memory. Every
///   chunk is copied synchronously in its stream handler and THEN acked — the
///   ack is what frees native memory, so acking an uncopied chunk is memory
///   corruption (same protocol as `nitro_http`).
/// * Chunks may arrive before their head (separate ports, no cross-ordering),
///   so early chunks park in [_early] until the head lands.
/// * A handler that completes after its route timeout already answered loses:
///   the native `respond` is a defined no-op for answered ids.
/// * [close] stops the server and cancels the subscriptions. The native
///   instance itself is intentionally NOT disposed: connection threads hold
///   the engine alive and may still reference the bridge — see the spec
///   header. Bridge objects are process-lifetime and tiny.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../api/context.dart';
import '../api/event.dart';
import '../api/http_method.dart';
import '../api/metrics.dart';
import '../api/ws.dart';
import '../nitro_server.native.dart';
import 'fast_calls.dart';
import 'raw_mapping.dart';

/// Wire token for a route registration: the custom token for custom methods,
/// the enum token otherwise (`*` for all-method routes).
String _tokenOf(HttpMethod method, String customToken) =>
    method == HttpMethod.custom ? customToken : method.token;

/// One registered route: the user handler plus the same handler pre-wrapped
/// by the middleware chains. [routeComposer] composes the route-local (and
/// group) middleware around the handler; [piped] is the route-composed
/// handler wrapped by the server-global chain on top — request flow is
/// global → group/route-local → handler. Both are computed at registration
/// and refreshed on every `use()`, so dispatch never composes per request.
class _RouteEntry {
  _RouteEntry(this.handler, this.routeComposer, this.piped, this.streamBody);

  final RequestHandler handler;
  final HandlerComposer routeComposer;
  RequestHandler piped;

  /// Dispatch on the head and stream the body to the handler.
  final bool streamBody;
}

/// The middleware chain as a handler transformer: composes every registered
/// middleware (outermost first) around the handler it is given. The identity
/// transform — no middleware — returns the handler untouched.
typedef HandlerComposer = RequestHandler Function(RequestHandler handler);

class _Pending {
  _Pending(this.head);

  final RawIncomingRequest head;
  final BytesBuilder body = BytesBuilder(copy: false);
  String? error;
  bool complete = false;
  bool dispatched = false;

  /// Runner clock reading at dispatch, for the latency metric.
  int startedUs = 0;

  /// Set once a `streamBody` handler is running: chunks go here instead of
  /// [body], and are acked as they are copied rather than at completion.
  StreamController<Uint8List>? stream;

  /// Metrics bucket, resolved once at dispatch so `_record` need not repeat
  /// the route lookup on the answer path.
  String? metricsPattern;
}

/// The engine's handshake choice, recomputed for the session: the first of
/// [accepted] that the client [offered] (comma-separated), else null.
String? selectWsProtocol(String? offered, List<String> accepted) {
  if (offered == null || accepted.isEmpty) return null;
  final offers = {for (final p in offered.split(',')) p.trim()};
  for (final want in accepted) {
    if (offers.contains(want)) return want;
  }
  return null;
}

/// Shared empty body for head-only requests: every GET without a body would
/// otherwise allocate its own zero-length buffer on dispatch.
final Uint8List _emptyBody = Uint8List(0);

class ServerRunner {
  ServerRunner(this._native);

  /// Identity transform: no middleware, the handler runs as registered.
  static RequestHandler _identity(RequestHandler handler) => handler;

  /// Composes [middlewares] (first = outermost) into one handler transformer.
  /// The empty list is the identity — no closures allocated.
  static HandlerComposer _composeAll(List<Middleware> middlewares) {
    if (middlewares.isEmpty) return _identity;
    var compose = _identity;
    for (final middleware in middlewares.reversed) {
      final next = compose;
      compose = (handler) =>
          (request) => middleware(request, next(handler));
    }
    return compose;
  }

  final NitroServerNative _native;

  /// Leaf-call answer path over the real engine (see [FastCalls]); null
  /// when the native side is a fake, in which case the generated bindings
  /// answer. Bound on [start], released on [close].
  FastCalls? _fast;
  final _pending = <int, _Pending>{};

  /// Per-route metrics, keyed by pattern (`*unmatched*` for not-found).
  final _metrics = <String, MetricsAccumulator>{};
  final _clock = Stopwatch()..start();
  int _answered = 0;
  int _errors = 0;

  /// A snapshot of the counters and latency quantiles so far.
  ServerMetrics get metrics => ServerMetrics(
    requests: _answered,
    errors: _errors,
    inFlight: _pending.length,
    byRoute: {
      for (final entry in _metrics.entries) entry.key: entry.value.snapshot(),
    },
  );

  /// Recently answered request ids, insertion-ordered and bounded.
  ///
  /// A duplicate head for an id that already dispatched must never dispatch
  /// again — the engine assigns each id once, so a repeat is a stale resend.
  /// The in-flight [_pending] entry alone cannot guarantee that: stream
  /// delivery can land the duplicate *after* the answer removed the entry
  /// (broadcast delivery runs queued continuations first), so the guard has
  /// to outlive the request. Unbounded growth is not an option (ids are
  /// process-monotonic), hence the same 1024-entry bound as [_boundEarly]:
  /// duplicates arrive back-to-back, never a thousand requests later.
  final _completed = <int>{};
  final _early = <int, List<Uint8List>>{};
  final _earlyErrors = <int, String>{};
  final _earlyComplete = <int>{};

  /// Cumulative ack count per request. Every copied chunk (data or error) is
  /// acked the moment it is copied — including chunks that arrive before
  /// their head — so native memory is freed promptly and exactly once.
  final _acked = <int, int>{};

  /// Handler table, two levels: method token → pattern → route entry. A flat
  /// `'$token $pattern'` key costs a string allocation on every request;
  /// this lookup allocates nothing.
  final _routes = <String, Map<String, _RouteEntry>>{};
  final _middlewares = <Middleware>[];

  /// The composed middleware chain (identity while no middleware is
  /// registered). Rebuilt on every `use()`; every route entry's [piped]
  /// handler is refreshed in the same step.
  HandlerComposer _compose = _identity;
  final _events = StreamController<ServerEvent>.broadcast();

  /// Live outbound stream subscriptions by request id. Cancelled on [close]
  /// so a shutdown server stops forwarding into a dead engine.
  final _outbound = <int, StreamSubscription<Uint8List>>{};

  /// WebSocket routes by pattern. Disjoint from [_routes] for GET: the
  /// engine holds a single entry per (method, pattern), so registering one
  /// side evicts the other here too (see [addRoute]/[addWsRoute]).
  final _wsHandlers = <String, ({WsHandler handler, List<String> protocols})>{};

  /// Live WebSocket sessions by connection id.
  final _wsSessions = <int, _WsSessionImpl>{};

  /// Every WebSocket connection id ever opened (test seam backing).
  final _wsOpened = <int>{};

  /// Frames that reached [_onWsMessage] before their session opened. The open
  /// event ([_dispatchWs]) and message events ([_onWsMessage]) ride separate
  /// bridge streams with no cross-ordering — the same property that lets HTTP
  /// body chunks precede their head (see [_early]) — so a client's first frame
  /// can beat its open. Parked here (already copied and acked) and replayed on
  /// open; a frame for an id in [_wsOpened] is instead a post-close stale and
  /// is dropped. Bounded like [_boundEarly].
  final _wsEarly = <int, List<({int kind, int aux, Uint8List bytes})>>{};

  /// Answers unmatched requests. Defaults to an empty 404.
  NotFoundHandler _notFoundHandler = (_) => const ResponseContext(status: 404);

  /// Answers requests whose handler threw. Defaults to a 500 text body.
  ErrorHandler _errorHandler = (error, _) =>
      ResponseContext.text('handler error: $error', status: 500);

  /// Overrides the 404 answer. A throwing handler falls back to empty 404.
  ///
  /// Ensures the engine subscription: configuring a fallback without any
  /// route registered must still dispatch (broadcast streams drop events
  /// with no listener, so a head emitted before the first `addRoute`/`start`
  /// would otherwise vanish).
  set notFoundHandler(NotFoundHandler handler) {
    _ensureListening();
    _notFoundHandler = handler;
  }

  /// Overrides the 500 answer. A throwing handler falls back to the default.
  ///
  /// Ensures the engine subscription, same as [notFoundHandler].
  set errorHandler(ErrorHandler handler) {
    _ensureListening();
    _errorHandler = handler;
  }

  StreamSubscription<RawIncomingRequest>? _heads;
  StreamSubscription<RawBodyChunk>? _chunks;
  StreamSubscription<RawServerEvent>? _serverEvents;
  StreamSubscription<RawWsMessage>? _wsMessages;
  bool _listening = false;
  bool _closed = false;

  /// The re-broadcast engine events (lifecycle, timeouts, client errors).
  Stream<ServerEvent> get events => _events.stream;

  /// Test seam: ids with an unfinished request.
  Set<int> get pendingIdsForTesting => {..._pending.keys};

  /// Test seam: ids with a live WebSocket session.
  Set<int> get wsSessionIdsForTesting => {..._wsSessions.keys};

  /// Test seam: every WebSocket connection id ever opened (sessions remove
  /// themselves on close, so liveness alone cannot prove an open happened).
  Set<int> get wsOpenedIdsForTesting => {..._wsOpened};

  /// Test seam: total frames parked awaiting their session's open.
  int get wsEarlyFrameCountForTesting =>
      _wsEarly.values.fold(0, (sum, list) => sum + list.length);

  /// Test seam: subscribes the engine streams without touching native state,
  /// mirroring what `addRoute`/`start` do in production. Needed by tests that
  /// drive requests against a runner with no routes and no `start()` — the
  /// fake's broadcast streams drop a head emitted before any subscriber, and
  /// in production a request can never arrive before `start()` subscribed.
  void ensureListeningForTesting() => _ensureListening();

  /// Marks [requestId] answered: drops the in-flight entry, records the
  /// id so a stale duplicate head can never dispatch again, and sends the
  /// deferred cumulative body ack (one FFI crossing instead of one per chunk).
  void _complete(int requestId) {
    // A streaming handler that answered early: nothing more can be read.
    _pending[requestId]?.stream?.close();
    _pending.remove(requestId);
    _completed.add(requestId);
    if (_completed.length > 1024) _completed.remove(_completed.first);
    // Flush the deferred body ack: one cumulative ackBody call per request
    // instead of one per 64 KiB body chunk. The native side frees all
    // payloads with seq < ackedUpTo, so a single cumulative ack is safe.
    final acked = _acked.remove(requestId);
    if (acked != null && acked > 0) {
      _native.ackBody(requestId, acked);
    }
  }

  void _ensureListening() {
    if (_listening) return;
    _listening = true;
    _heads = _native.incomingRequests.listen(_onHead, onError: (_) {});
    _chunks = _native.bodyChunks.listen(_onChunk, onError: (_) {});
    _serverEvents = _native.serverEvents.listen(_onEvent, onError: (_) {});
    _wsMessages = _native.wsMessages.listen(_onWsMessage, onError: (_) {});
  }

  // ── Route table ────────────────────────────────────────────────────────────

  void addRoute(
    HttpMethod method,
    String customToken,
    String pattern,
    Duration? timeout,
    RequestHandler handler, [
    List<Middleware> middleware = const [],
    bool streamBody = false,
    int? maxBodyBytes,
  ]) {
    _ensureListening();
    final (rawMethod, rawCustom) = rawMethodOf(method, customToken);
    final status = _native.registerRoute(
      RawRouteConfig(
        method: rawMethod,
        customMethod: rawCustom,
        pattern: pattern,
        // -1 inherits the server default (see RawRouteConfig).
        timeoutMs: timeout?.inMilliseconds ?? -1,
        streamBody: streamBody,
        maxBodyBytes: maxBodyBytes ?? -1,
      ),
    );
    throwIfFailed(status, operation: 'registerRoute($pattern)');
    // Route-local middleware sits inside the global chain: the entry's
    // `piped` is global(routeLocal(handler)), matching use()'s refresh.
    final routeComposer = _composeAll(middleware);
    final entry = _RouteEntry(
      handler,
      routeComposer,
      _compose(routeComposer(handler)),
      streamBody,
    );
    final token = _tokenOf(method, customToken);
    (_routes[token] ??= {})[pattern] = entry;
    // Single-entry mirror of the engine table (see addWsRoute).
    if (token == 'GET') _wsHandlers.remove(pattern);
  }

  /// Appends [middleware] to the chain. Order is registration order: the
  /// first `use` is the outermost wrapper. Applies to routes registered
  /// before AND after — the chain is resolved at dispatch, not at
  /// registration. Re-composes every route entry here, once, so dispatch
  /// stays a plain call through [HandlerComposer] output.
  void use(Middleware middleware) {
    _ensureListening();
    _middlewares.add(middleware);
    _recompose();
  }

  /// Rebuilds [_compose] from [_middlewares] and refreshes every route's
  /// piped handler. Registration order is outermost-first: iterating the
  /// reversed list nests each earlier middleware around the later ones.
  void _recompose() {
    _compose = _composeAll(_middlewares);
    for (final byPattern in _routes.values) {
      for (final entry in byPattern.values) {
        entry.piped = _compose(entry.routeComposer(entry.handler));
      }
    }
  }

  void removeRoute(HttpMethod method, String customToken, String pattern) {
    final status = _native.unregisterRoute(
      _tokenOf(method, customToken),
      pattern,
    );
    throwIfFailed(status, operation: 'unregisterRoute($pattern)');
    _routes[_tokenOf(method, customToken)]?.remove(pattern);
    // The engine holds one entry per (method, pattern) whatever its kind:
    // removing a GET route removes a WS route on the same pattern too.
    if (method == HttpMethod.get) _wsHandlers.remove(pattern);
  }

  /// Registers a static route: the engine answers [status]/[headers]/[body]
  /// entirely on its own thread and never emits a head to this isolate, so no
  /// Dart handler is stored. Evicts any handler or WS route at the same
  /// pattern, mirroring the engine's single entry per (method, pattern).
  void addStaticRoute(
    HttpMethod method,
    String customToken,
    String pattern,
    int status,
    Map<String, String> headers,
    List<int> body,
  ) {
    _ensureListening();
    final token = _tokenOf(method, customToken);
    final result = _native.registerStaticRoute(token, pattern, status, [
      for (final e in headers.entries) RawHeader(name: e.key, value: e.value),
    ], body is Uint8List ? body : Uint8List.fromList(body));
    throwIfFailed(result, operation: 'registerStaticRoute($pattern)');
    _routes[token]?.remove(pattern);
    if (method == HttpMethod.get) _wsHandlers.remove(pattern);
  }

  /// Registers a WebSocket route: matching handshakes upgrade in-engine and
  /// [handler] receives the live session. Evicts a GET HTTP route on the
  /// same pattern (and vice versa in [addRoute]) — the engine holds a
  /// single entry per (method, pattern).
  void addWsRoute(
    String pattern,
    WsHandler handler, [
    List<String> protocols = const [],
  ]) {
    _ensureListening();
    final status = _native.registerRoute(
      RawRouteConfig(
        method: RawServerMethod.get,
        customMethod: '',
        pattern: pattern,
        timeoutMs: -1,
        isWebSocket: true,
        wsProtocols: protocols.join(','),
      ),
    );
    throwIfFailed(status, operation: 'registerRoute($pattern)');
    _routes['GET']?.remove(pattern);
    _wsHandlers[pattern] = (handler: handler, protocols: protocols);
  }

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  /// Whether the engine negotiates permessage-deflate (mirrors the config
  /// the engine was started with; helpers inherit it via [prepareHelper]).
  bool _wsCompression = true;

  int start(ServerConfig config) {
    _ensureListening();
    _fast ??= _bindFast();
    _wsCompression = config.wsCompression;
    _native.configureServer(
      RawServerConfig(
        host: config.host,
        port: config.port,
        backlog: config.backlog,
        maxBodyBytes: config.maxBodyBytes,
        defaultTimeoutMs: config.defaultTimeout.inMilliseconds,
        keepAliveTimeoutMs: config.keepAliveTimeout.inMilliseconds,
        maxRequestsPerConn: config.maxRequestsPerConnection,
        workerThreads: config.workerThreads,
        maxConnections: config.maxConnections,
        maxConnectionsPerIp: config.maxConnectionsPerIp,
        headerTimeoutMs: config.headerTimeout.inMilliseconds,
        writeTimeoutMs: config.writeTimeout.inMilliseconds,
        wsMaxBufferBytes: config.wsMaxBufferBytes,
        wsCompression: config.wsCompression,
        tls: RawTlsConfig(
          certPem: config.tls.certPem,
          keyPem: config.tls.keyPem,
          certFile: config.tls.certFile,
          keyFile: config.tls.keyFile,
        ),
      ),
    );
    final status = _native.start();
    return throwIfFailed(status, operation: 'start');
  }

  void stop() {
    _native.stop();
  }

  /// Graceful shutdown: stops accepting, marks every further answer
  /// `Connection: close`, and waits until no request is in flight or
  /// [deadline] passes. The caller then closes.
  Future<void> drain(Duration deadline) async {
    if (_closed) return;
    try {
      _native.beginDrain();
    } catch (_) {
      return; // Never started: nothing to drain.
    }
    // The engine closes idle connections itself once draining, so the live
    // count converges on the requests still being answered.
    final end = DateTime.now().add(deadline);
    while ((_native.inFlightRequests() > 0 || _native.liveConnections() > 0) &&
        DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// Readies a runner that will not call [start] — a helper isolate behind
  /// a server another isolate started: subscribe the streams and bind the
  /// fast path, so the first dealt request finds everything in place.
  void prepareHelper({bool wsCompression = true}) {
    _ensureListening();
    _fast ??= _bindFast();
    _wsCompression = wsCompression;
  }

  /// The fast path needs a real engine instance behind [_native]; a fake
  /// (tests) has none, and the generated bindings serve instead.
  FastCalls? _bindFast() {
    try {
      return FastCalls.bind(_native);
    } catch (_) {
      return null;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      _native.stop();
    } catch (_) {
      // Stopping a never-started server is a no-op, not an error.
    }
    for (final sub in _outbound.values) {
      await sub.cancel();
    }
    _outbound.clear();
    for (final session in _wsSessions.values) {
      session._shutdown();
    }
    _wsSessions.clear();
    _wsEarly.clear();
    await _heads?.cancel();
    await _chunks?.cancel();
    await _serverEvents?.cancel();
    await _wsMessages?.cancel();
    _listening = false;
    _fast?.dispose();
    _fast = null;
    await _events.close();
  }

  // ── Dispatch ───────────────────────────────────────────────────────────────

  /// Copies a chunk payload out of native memory. The ack is deferred until
  /// [_complete] to batch all body chunks into a single FFI crossing instead
  /// of one ackBody call per chunk.
  Uint8List _copyChunk(int requestId, Uint8List view) {
    final copy = Uint8List.fromList(view);
    _acked[requestId] = (_acked[requestId] ?? 0) + 1;
    return copy;
  }

  void _onHead(RawIncomingRequest head) {
    if (_closed) return;
    final requestId = head.requestId;
    if (_completed.contains(requestId)) return;
    // The engine emits one head per request (a small body's chunk precedes
    // its complete head; a large body's head precedes its chunks and end
    // marker). A second head for a live id is a stale resend: ignore it.
    if (_pending.containsKey(requestId)) return;
    final pending = _pending[requestId] = _Pending(head);
    final early = _early.remove(requestId);
    if (early != null) {
      for (final bytes in early) {
        pending.body.add(bytes);
      }
    }
    final earlyError = _earlyErrors.remove(requestId);
    if (earlyError != null) pending.error = earlyError;
    if (!head.hasBody ||
        head.bodyComplete ||
        _earlyComplete.remove(requestId)) {
      pending.complete = true;
      _dispatch(pending);
    } else if (_entryFor(head)?.streamBody ?? false) {
      // Head first, body later: the handler runs now and reads the body
      // from a stream. Bytes that beat the head go out first.
      final controller = StreamController<Uint8List>();
      pending.stream = controller;
      if (pending.body.isNotEmpty) controller.add(pending.body.takeBytes());
      _ackNow(requestId);
      _dispatch(pending);
    }
  }

  /// The registered entry a head resolves to: the method-specific
  /// registration, else the GET registration for a HEAD (the engine strips
  /// the body), else the `*` fallback, else null.
  _RouteEntry? _entryFor(RawIncomingRequest head) {
    final (method, custom) = httpMethodOf(head.method, head.customMethod);
    final pattern = head.routePattern;
    final byMethod = _routes[_tokenOf(method, custom)]?[pattern];
    if (byMethod != null) return byMethod;
    if (method == HttpMethod.head) {
      final get = _routes['GET']?[pattern];
      if (get != null) return get;
    }
    return _routes['*']?[pattern];
  }

  /// Streaming bodies release native memory chunk by chunk: a long upload
  /// must not hold every payload until the handler finishes.
  void _ackNow(int requestId) {
    final acked = _acked[requestId];
    if (acked != null && acked > 0) _native.ackBody(requestId, acked);
  }

  void _onChunk(RawBodyChunk chunk) {
    if (_closed) return;
    final kind = RawBodyKind.values[chunk.kind];
    switch (kind) {
      case RawBodyKind.data:
        // Already completed? Drop and ack immediately — the payload is
        // a stale straggler that will never be dispatched.
        if (_completed.contains(chunk.requestId)) {
          _native.ackBody(chunk.requestId, 1);
          return;
        }
        // Copy out of native memory. Ack is deferred to [_complete] to
        // batch all body chunks into one FFI crossing.
        final copy = _copyChunk(chunk.requestId, chunk.bytes);
        final pending = _pending[chunk.requestId];
        if (pending == null) {
          (_early[chunk.requestId] ??= []).add(copy);
          _boundEarly();
        } else if (pending.stream case final stream?) {
          stream.add(copy);
          _ackNow(chunk.requestId);
        } else if (!pending.complete) {
          pending.body.add(copy);
        }
      case RawBodyKind.error:
        final message = String.fromCharCodes(chunk.bytes);
        _copyChunk(chunk.requestId, chunk.bytes);
        final pending = _pending[chunk.requestId];
        if (pending == null) {
          _earlyErrors[chunk.requestId] = message;
          _boundEarly();
        } else if (pending.stream case final stream?) {
          // The engine already answered (413/400): the handler's stream
          // fails and its answer, if any, is a no-op.
          stream.addError(StateError(message));
          _ackNow(chunk.requestId);
        } else if (!pending.complete) {
          pending.error = message;
        }
      case RawBodyKind.end:
        // Large bodies (above the engine's inline threshold) and chunked
        // uploads end with this marker; small bodies complete via their
        // head instead (see _onHead).
        final pending = _pending[chunk.requestId];
        if (pending == null) {
          _earlyComplete.add(chunk.requestId);
          _boundEarly();
        } else if (pending.stream case final stream?) {
          pending.complete = true;
          stream.close();
        } else if (!pending.complete) {
          pending.complete = true;
          _dispatch(pending);
        }
    }
  }

  /// Orphan chunks belong to requests answered directly by the engine (413,
  /// truncated body) that never produce a head. Without a bound they would
  /// accumulate once per rejected upload; 1024 parked requests is already
  /// deeper than any real backlog.
  void _boundEarly() {
    while (_early.length + _earlyErrors.length + _earlyComplete.length > 1024) {
      if (_early.isNotEmpty) {
        _early.remove(_early.keys.first);
      } else if (_earlyErrors.isNotEmpty) {
        _earlyErrors.remove(_earlyErrors.keys.first);
      } else {
        _earlyComplete.remove(_earlyComplete.first);
      }
    }
  }

  void _onEvent(RawServerEvent event) {
    if (_closed) return;
    _events.add(
      ServerEvent(
        kind: ServerEventKind.values[event.kind],
        requestId: event.requestId,
        message: event.message,
      ),
    );
  }

  void _dispatch(_Pending pending) {
    if (pending.dispatched) return;
    pending.dispatched = true;
    pending.startedUs = _clock.elapsedMicroseconds;
    final head = pending.head;
    if (pending.error != null) {
      // The engine already answered directly (413, truncated body) and
      // reaped the request. Running the handler would answer into the void —
      // `respond` would no-op — so drop it here instead.
      _complete(head.requestId);
      return;
    }
    final (method, custom) = httpMethodOf(head.method, head.customMethod);
    // Method-specific registrations win, HEAD falls back to GET, and
    // `HttpMethod.all` (`*`) is the last resort — mirroring the native
    // router's precedence. Two-level lookup: no key string is built.
    final entry = _entryFor(head);
    // Resolve the metrics bucket here, where the match is already known, so
    // the answer path (`_record`) does not repeat the route lookup.
    pending.metricsPattern =
        head.routePattern.isEmpty ||
            (entry == null && !_wsHandlers.containsKey(head.routePattern))
        ? '*unmatched*'
        : head.routePattern;
    // The context is built before the branch: both the handler and the
    // not-found fallback receive it.
    final context = RequestContext.packed(
      method: method,
      customMethod: custom,
      path: head.path,
      query: head.query,
      packedHeaders: head.packedHeaders,
      // Paramless routes (the common GET hot path) share one empty map.
      params: head.params.isEmpty
          ? const {}
          : {for (final p in head.params) p.name: p.value},
      routePattern: head.routePattern,
      // GET-style heads carry no body: share one empty buffer instead of
      // allocating per request.
      body: pending.body.isEmpty ? _emptyBody : pending.body.toBytes(),
      bodyStream: pending.stream?.stream,
    );
    if (entry == null) {
      final ws = _wsHandlers[head.routePattern];
      if (ws != null) {
        _dispatchWs(head.requestId, context, ws.handler, ws.protocols);
        return;
      }
      _guardedNotFound(context).then((response) {
        _deliver(head.requestId, response);
      });
      return;
    }
    // The middleware chain was composed into `piped` at registration (or at
    // the last `use()`): dispatch is a single call through it — no fold, no
    // per-request closure allocation.
    final piped = entry.piped;
    // A handler that returns its response directly is answered inline: no
    // Future, no microtask, no event-loop turn. Async handlers continue in
    // `then`; a throw either way lands on the (guarded) error page.
    final FutureOr<ResponseContext> result;
    try {
      result = piped(context);
    } catch (error) {
      _guardedError(error, context).then((response) {
        _deliver(head.requestId, response);
      });
      return;
    }
    if (result is ResponseContext) {
      _deliver(head.requestId, result);
      return;
    }
    result.then(
      (response) {
        _deliver(head.requestId, response);
      },
      onError: (Object error) {
        _guardedError(error, context).then((response) {
          _deliver(head.requestId, response);
        });
      },
    );
  }

  /// Delivers one handler answer: one-shot bodies go out with exactly-once
  /// `respond`; stream bodies open a chunked stream instead. Fallbacks share
  /// this path, so a custom error page may stream too.
  void _deliver(int requestId, ResponseContext response) {
    _record(requestId, response.status);
    if (response.bodyStream != null) {
      _answerStream(requestId, response);
    } else if (response.filePath case final path?) {
      _answerFile(requestId, response, path);
      _complete(requestId);
    } else {
      _answer(requestId, response);
      _complete(requestId);
    }
  }

  /// Counts one answer against its route (dispatch to answer, in µs).
  void _record(int requestId, int status) {
    final pending = _pending[requestId];
    if (pending == null) return;
    final pattern = pending.metricsPattern ?? '*unmatched*';
    final acc = _metrics[pattern] ??= MetricsAccumulator(pattern);
    acc.record(_clock.elapsedMicroseconds - pending.startedUs, status);
    _answered++;
    if (status >= 500) _errors++;
  }

  /// A file answer: the engine writes the head now and sends the bytes
  /// from a native worker. Rare enough to ride the generated binding.
  void _answerFile(int requestId, ResponseContext response, String path) {
    if (_closed) return;
    try {
      _native.respondFile(
        requestId,
        response.status,
        _rawHeaders(response),
        path,
        response.fileOffset,
        response.fileLength,
      );
    } catch (_) {
      // Already answered (timeout won) or the server went away.
    }
  }

  /// Runs the not-found fallback. A throwing fallback degrades to an empty
  /// 404 rather than wedging dispatch.
  Future<ResponseContext> _guardedNotFound(RequestContext context) async {
    try {
      return await _notFoundHandler(context);
    } catch (_) {
      return const ResponseContext(status: 404);
    }
  }

  /// Runs the error fallback. A throwing fallback degrades to the default
  /// 500 text body.
  Future<ResponseContext> _guardedError(
    Object error,
    RequestContext context,
  ) async {
    try {
      return await _errorHandler(error, context);
    } catch (_) {
      return ResponseContext.text('handler error: $error', status: 500);
    }
  }

  void _answer(int requestId, ResponseContext response) {
    if (_closed) return;
    try {
      final fast = _fast;
      if (fast != null) {
        fast.respond(
          requestId,
          response.status,
          response.headers,
          response.bodyBytes,
          _setCookies(response),
        );
      } else {
        _native.respond(
          requestId,
          response.status,
          _rawHeaders(response),
          response.bodyBytes,
        );
      }
    } catch (_) {
      // The request was already answered (timeout won) or the server went
      // away mid-flight. Exactly-once is the engine's job; Dart never retries.
    }
  }

  /// Headerless answers (the common small-response case) share one canonical
  /// empty list instead of allocating a fresh growable one. Cookies ride as
  /// one `set-cookie` header each.
  static List<RawHeader> _rawHeaders(ResponseContext response) {
    if (response.headers.isEmpty && response.cookies.isEmpty) {
      return const <RawHeader>[];
    }
    return [
      for (final entry in response.headers.entries)
        RawHeader(name: entry.key, value: entry.value),
      for (final cookie in response.cookies)
        RawHeader(name: 'set-cookie', value: cookie.toHeaderValue()),
    ];
  }

  static List<String> _setCookies(ResponseContext response) =>
      response.cookies.isEmpty
      ? const []
      : [for (final c in response.cookies) c.toHeaderValue()];

  /// Opens a chunked stream and forwards the body into it. Completion —
  /// clean end or stream error — sends the terminal chunk and marks the id
  /// answered, so a stale duplicate head can never dispatch again. A stream
  /// error truncates rather than hangs: the client sees a clean terminator
  /// after the bytes so far.
  void _answerStream(int requestId, ResponseContext response) {
    if (_closed) return;
    try {
      final fast = _fast;
      if (fast != null) {
        fast.startStream(
          requestId,
          response.status,
          response.headers,
          _setCookies(response),
        );
      } else {
        _native.startStream(requestId, response.status, _rawHeaders(response));
      }
    } catch (_) {
      // The timeout won before the first byte (or the server went away):
      // drop the stream unopened and mark the id answered.
      return _complete(requestId);
    }
    // A positive [streamBufferSize] coalesces events into fewer bridge
    // crossings; zero forwards every event immediately (real-time feeds).
    final bufferSize = response.streamBufferSize;
    final BytesBuilder? pending = bufferSize > 0
        ? BytesBuilder(copy: false)
        : null;
    void send(Uint8List bytes) {
      if (_closed || bytes.isEmpty) return;
      _sendChunk(requestId, bytes, false);
    }

    void onEvent(Uint8List chunk) {
      if (chunk.isEmpty) return;
      final acc = pending;
      if (acc == null) {
        send(chunk);
        return;
      }
      acc.add(chunk);
      if (acc.length >= bufferSize) {
        final bytes = acc.toBytes();
        acc.clear();
        send(bytes);
      }
    }

    void onEnd() {
      // Flush the remainder before the terminal chunk: bytes already
      // accepted must reach the client even when the stream errors.
      final acc = pending;
      if (acc != null && acc.isNotEmpty) {
        final rest = acc.toBytes();
        acc.clear();
        send(rest);
      }
      _finishStream(requestId);
    }

    late final StreamSubscription<Uint8List> sub;
    sub = response.bodyStream!.listen(
      onEvent,
      onError: (_) => onEnd(),
      onDone: onEnd,
      cancelOnError: true,
    );
    _outbound[requestId] = sub;
  }

  /// One chunk into the engine, fast path first. Failures are the engine's
  /// no-op cases (dead stream, timeout won): never an error for the handler.
  void _sendChunk(int requestId, Uint8List bytes, bool last) {
    try {
      final fast = _fast;
      if (fast != null) {
        fast.sendStreamChunk(requestId, bytes, last);
      } else {
        _native.sendStreamChunk(requestId, bytes, last);
      }
    } catch (_) {}
  }

  void _finishStream(int requestId) {
    final sub = _outbound.remove(requestId);
    if (!_closed) _sendChunk(requestId, _emptyBody, true);
    _complete(requestId);
    sub?.cancel();
  }

  // ── WebSocket sessions ───────────────────────────────────────────────────

  /// Opens the session for an upgraded head and invokes its handler.
  /// Returning (or throwing) closes the session — `await for`-then-return
  /// is the whole read loop. A missing handler (unregister race) refuses
  /// with 1001 instead of leaving a ghost socket.
  void _dispatchWs(
    int connectionId,
    RequestContext handshake,
    WsHandler handler,
    List<String> protocols,
  ) {
    final offered =
        handshake
            .header('sec-websocket-extensions')
            ?.contains('permessage-deflate') ??
        false;
    final session = _WsSessionImpl(
      connectionId,
      handshake,
      _native,
      _wsCompression && offered,
      selectWsProtocol(handshake.header('sec-websocket-protocol'), protocols),
      () {
        _wsSessions.remove(connectionId);
      },
    );
    _wsSessions[connectionId] = session;
    _wsOpened.add(connectionId);
    // Replay any frames that beat the open (buffered in the stream controller
    // until the handler subscribes), in arrival order, before live frames.
    final parked = _wsEarly.remove(connectionId);
    if (parked != null) {
      for (final m in parked) {
        if (session._done) break; // a replayed close already finished it
        _deliverWs(session, m.kind, m.aux, m.bytes);
      }
    }
    Future<void>.sync(() => handler(session)).then(
      (_) => session._closeLocal(1000),
      onError: (_) => session._closeLocal(1011),
    );
  }

  void _onWsMessage(RawWsMessage message) {
    if (_closed) return;
    // Copy FIRST then ack immediately: WS payloads have no _complete path
    // so deferred acks would leak native memory.
    final copy = Uint8List.fromList(message.payload);
    _native.ackBody(message.connectionId, 1);
    final id = message.connectionId;
    final session = _wsSessions[id];
    if (session == null) {
      // No session yet. Either the frame beat its open across the bridge —
      // park it for [_dispatchWs] to replay — or the id already opened and
      // closed, which makes this a stale post-close frame we drop.
      if (!_wsOpened.contains(id)) {
        (_wsEarly[id] ??= [])
            .add((kind: message.kind, aux: message.aux, bytes: copy));
        _boundWsEarly();
      }
      return;
    }
    _deliverWs(session, message.kind, message.aux, copy);
  }

  /// Decodes one WS frame ([copy] already lifted out of native memory) and
  /// hands it to [session]. Shared by the live path ([_onWsMessage]) and the
  /// pre-open replay ([_dispatchWs]).
  void _deliverWs(_WsSessionImpl session, int kind, int aux, Uint8List copy) {
    if (kind == 8) {
      session._remoteClose(aux);
      return;
    }
    // aux == 1: a permessage-deflate payload (no context takeover), one
    // independent raw-deflate stream per message.
    final Uint8List bytes;
    if (aux == 1) {
      try {
        bytes = wsInflate(copy);
      } on Object {
        session._closeLocal(1007); // Undecodable: invalid frame payload.
        return;
      }
    } else {
      bytes = copy;
    }
    if (kind == 1) {
      // The engine validated UTF-8 for plain text; inflated text is checked
      // here.
      try {
        session._add(WsMessage.text(utf8.decode(bytes)));
      } on FormatException {
        session._closeLocal(1007);
      }
    } else {
      session._add(WsMessage.binary(bytes));
    }
  }

  /// Caps total parked pre-open frames, evicting the oldest connection's
  /// frames first — the same 1024 bound as [_boundEarly].
  void _boundWsEarly() {
    var total = 0;
    for (final list in _wsEarly.values) {
      total += list.length;
    }
    while (total > 1024 && _wsEarly.isNotEmpty) {
      total -= _wsEarly.remove(_wsEarly.keys.first)!.length;
    }
  }
}

/// Server-side [WsSession]. All sends are fire-and-forget into id-keyed
/// native calls, so every path is safe after close — the engine no-ops
/// unknown ids and Dart guards re-entrancy with [_done].
class _WsSessionImpl implements WsSession {
  _WsSessionImpl(
    this._id,
    this._handshake,
    this._native,
    this.compressed,
    this.protocol,
    this._onDone,
  );

  final int _id;
  final RequestContext _handshake;
  final NitroServerNative _native;
  final void Function() _onDone;

  final _messages = StreamController<WsMessage>();
  bool _done = false;
  int? _closeCode;

  @override
  final bool compressed;

  @override
  final String? protocol;

  @override
  int bufferedBytes = 0;

  @override
  RequestContext get handshake => _handshake;

  @override
  Stream<WsMessage> get messages => _messages.stream;

  @override
  int? get closeCode => _closeCode;

  @override
  int sendText(String text) => _send(wsTextBytes(text), false);

  @override
  int sendBytes(Uint8List bytes) => _send(bytes, true);

  int _send(Uint8List payload, bool binary) {
    if (_done) return -1;
    final deflate = compressed && payload.length >= WsSession.compressThreshold;
    try {
      bufferedBytes = _native.wsSend(
        _id,
        deflate ? wsDeflate(payload) : payload,
        binary,
        deflate,
      );
    } catch (_) {
      bufferedBytes = -1;
    }
    return bufferedBytes;
  }

  @override
  Future<void> close([int code = 1000]) async {
    _closeLocal(code);
  }

  void _add(WsMessage message) {
    if (!_done) _messages.add(message);
  }

  /// The shared close path: mark done, complete the closing handshake natively
  /// (a no-op on the reaped engine side, but it settles observers like the test
  /// client deterministically), and finish without further answers.
  void _finish(int code) {
    if (_done) return;
    _done = true;
    _closeCode = code;
    try {
      _native.wsClose(_id, code);
    } catch (_) {}
    _messages.close();
    _onDone();
  }

  /// Peer-initiated close (a close frame arrived): echoes the code and finishes.
  void _remoteClose(int code) => _finish(code);

  /// Local close (handler return/throw, explicit close): completes the closing
  /// handshake unless already done.
  void _closeLocal(int code) => _finish(code);

  /// Runner shutdown: same as a local close but without touching native
  /// (stop() already landed).
  void _shutdown() {
    if (_done) return;
    _done = true;
    _closeCode ??= 1006;
    _messages.close();
  }
}
