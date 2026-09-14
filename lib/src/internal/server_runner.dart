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
import 'dart:typed_data';

import '../api/context.dart';
import '../api/event.dart';
import '../api/http_method.dart';
import '../nitro_server.native.dart';
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
  _RouteEntry(this.handler, this.routeComposer, this.piped);

  final RequestHandler handler;
  final HandlerComposer routeComposer;
  RequestHandler piped;
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
}

/// Shared empty body for head-only requests: every GET without a body would
/// otherwise allocate its own zero-length buffer on dispatch.
final Uint8List _emptyBody = Uint8List(0);

/// Lowercases an HTTP header name, fast-pathing the already-lowercase case
/// (the engine preserves client casing, and most clients send lowercase).
String _lowerHeaderName(String name) {
  for (var i = 0; i < name.length; i++) {
    final unit = name.codeUnitAt(i);
    if (unit >= 0x41 && unit <= 0x5A) return name.toLowerCase();
  }
  return name;
}

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
      compose = (handler) => (request) => middleware(request, next(handler));
    }
    return compose;
  }

  final NitroServerNative _native;
  final _pending = <int, _Pending>{};

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

  /// Answers unmatched requests. Defaults to an empty 404.
  NotFoundHandler _notFoundHandler = (_) => const ResponseContext(status: 404);

  /// Answers requests whose handler threw. Defaults to a 500 text body.
  ErrorHandler _errorHandler =
      (error, _) => ResponseContext.text('handler error: $error', status: 500);

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
  bool _listening = false;
  bool _closed = false;

  /// The re-broadcast engine events (lifecycle, timeouts, client errors).
  Stream<ServerEvent> get events => _events.stream;

  /// Test seam: ids with an unfinished request.
  Set<int> get pendingIdsForTesting => {..._pending.keys};

  /// Test seam: subscribes the engine streams without touching native state,
  /// mirroring what `addRoute`/`start` do in production. Needed by tests that
  /// drive requests against a runner with no routes and no `start()` — the
  /// fake's broadcast streams drop a head emitted before any subscriber, and
  /// in production a request can never arrive before `start()` subscribed.
  void ensureListeningForTesting() => _ensureListening();

  /// Marks [requestId] answered: drops the in-flight entry and records the
  /// id so a stale duplicate head can never dispatch again.
  void _complete(int requestId) {
    _pending.remove(requestId);
    _completed.add(requestId);
    if (_completed.length > 1024) _completed.remove(_completed.first);
  }

  void _ensureListening() {
    if (_listening) return;
    _listening = true;
    _heads = _native.incomingRequests.listen(
      _onHead,
      onError: (_) {},
    );
    _chunks = _native.bodyChunks.listen(
      _onChunk,
      onError: (_) {},
    );
    _serverEvents = _native.serverEvents.listen(
      _onEvent,
      onError: (_) {},
    );
  }

  // ── Route table ────────────────────────────────────────────────────────────

  void addRoute(
    HttpMethod method,
    String customToken,
    String pattern,
    Duration? timeout,
    RequestHandler handler, [
    List<Middleware> middleware = const [],
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
      ),
    );
    throwIfFailed(status, operation: 'registerRoute($pattern)');
    // Route-local middleware sits inside the global chain: the entry's
    // `piped` is global(routeLocal(handler)), matching use()'s refresh.
    final routeComposer = _composeAll(middleware);
    final entry =
        _RouteEntry(handler, routeComposer, _compose(routeComposer(handler)));
    (_routes[_tokenOf(method, customToken)] ??= {})[pattern] = entry;
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
    final status = _native.unregisterRoute(_tokenOf(method, customToken), pattern);
    throwIfFailed(status, operation: 'unregisterRoute($pattern)');
    _routes[_tokenOf(method, customToken)]?.remove(pattern);
  }

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  int start(ServerConfig config) {
    _ensureListening();
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
    await _heads?.cancel();
    await _chunks?.cancel();
    await _serverEvents?.cancel();
    _listening = false;
    await _events.close();
  }

  // ── Dispatch ───────────────────────────────────────────────────────────────

  /// Copies a chunk payload out of native memory and acks it in one step.
  /// Every data/error chunk passes through here exactly once, so every
  /// payload is freed exactly once.
  Uint8List _copyAndAck(int requestId, Uint8List view) {
    final copy = Uint8List.fromList(view);
    final next = (_acked[requestId] ?? 0) + 1;
    _acked[requestId] = next;
    _native.ackBody(requestId, next);
    return copy;
  }

  void _onHead(RawIncomingRequest head) {
    if (_closed) return;
    if (_pending.containsKey(head.requestId) ||
        _completed.contains(head.requestId)) {
      return;
    }
    final pending = _pending[head.requestId] = _Pending(head);
    final early = _early.remove(head.requestId);
    if (early != null) {
      for (final bytes in early) {
        pending.body.add(bytes);
      }
    }
    final earlyError = _earlyErrors.remove(head.requestId);
    if (earlyError != null) pending.error = earlyError;
    if (!head.hasBody || _earlyComplete.remove(head.requestId)) {
      pending.complete = true;
      _dispatch(pending);
    }
  }

  void _onChunk(RawBodyChunk chunk) {
    if (_closed) return;
    final kind = RawBodyKind.values[chunk.kind];
    if (kind == RawBodyKind.data) {
      // Copy FIRST: `bytes` is a view into native memory that the ack frees.
      final copy = _copyAndAck(chunk.requestId, chunk.bytes);
      final pending = _pending[chunk.requestId];
      if (pending == null) {
        // Head has not landed yet: park the COPY (already acked) until it
        // does. Never the view — it dies with this handler.
        (_early[chunk.requestId] ??= []).add(copy);
        _boundEarly();
      } else if (!pending.complete) {
        pending.body.add(copy);
      }
      // A chunk for a completed request is a stale duplicate: already acked
      // above, bytes dropped.
    } else if (kind == RawBodyKind.error) {
      final message = String.fromCharCodes(chunk.bytes);
      _copyAndAck(chunk.requestId, chunk.bytes);
      final pending = _pending[chunk.requestId];
      if (pending == null) {
        _earlyErrors[chunk.requestId] = message;
        _boundEarly();
      } else if (!pending.complete) {
        pending.error = message;
      }
    } else {
      // End marker: no payload, no sequence consumed, no ack.
      final pending = _pending[chunk.requestId];
      if (pending == null) {
        _earlyComplete.add(chunk.requestId);
        _boundEarly();
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
    final head = pending.head;
    if (pending.error != null) {
      // The engine already answered directly (413, truncated body) and
      // reaped the request. Running the handler would answer into the void —
      // `respond` would no-op — so drop it here instead.
      _complete(head.requestId);
      return;
    }
    final (method, custom) = httpMethodOf(head.method, head.customMethod);
    // Method-specific registrations win; `HttpMethod.all` (`*`) is the
    // fallback — mirroring the native router's precedence (specific beats
    // All). Two-level lookup: no key string is built on any path.
    final byPattern = _routes[_tokenOf(method, custom)];
    final entry =
        byPattern?[head.routePattern] ?? _routes['*']?[head.routePattern];
    // The context is built before the branch: both the handler and the
    // not-found fallback receive it.
    final context = RequestContext(
      method: method,
      customMethod: custom,
      path: head.path,
      query: head.query,
      queryParameters: head.query.isEmpty
          ? const {}
          : Uri.splitQueryString(head.query),
      headers: _foldHeaders(head.headers),
      // Paramless routes (the common GET hot path) share one empty map.
      params: head.params.isEmpty
          ? const {}
          : {for (final p in head.params) p.name: p.value},
      routePattern: head.routePattern,
      // GET-style heads carry no body: share one empty buffer instead of
      // allocating per request.
      body: pending.body.isEmpty ? _emptyBody : pending.body.toBytes(),
    );
    if (entry == null) {
      _guardedNotFound(context).then((response) {
        _deliver(head.requestId, response);
      });
      return;
    }
    // The middleware chain was composed into `piped` at registration (or at
    // the last `use()`): dispatch is a single call through it — no fold, no
    // per-request closure allocation.
    final piped = entry.piped;
    // Future.sync: a sync handler (RequestHandler may return the response
    // directly) answers without an extra event-loop turn, and a
    // synchronously-throwing handler still lands in onError below — no
    // separate try/catch needed.
    Future<ResponseContext>.sync(() => piped(context)).then(
      (response) {
        _deliver(head.requestId, response);
      },
      onError: (Object error) {
        // The handler's future failed: the custom error page (guarded, so it
        // cannot throw) answers instead of the default 500.
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
    if (response.bodyStream != null) {
      _answerStream(requestId, response);
    } else {
      _answer(requestId, response);
      _complete(requestId);
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

  static Map<String, List<String>> _foldHeaders(List<RawHeader> headers) {
    final out = <String, List<String>>{};
    for (final header in headers) {
      (out[_lowerHeaderName(header.name)] ??= []).add(header.value);
    }
    return out;
  }

  void _answer(int requestId, ResponseContext response) {
    if (_closed) return;
    try {
      _native.respond(
        requestId,
        response.status,
        _rawHeaders(response),
        response.bodyBytes,
      );
    } catch (_) {
      // The request was already answered (timeout won) or the server went
      // away mid-flight. Exactly-once is the engine's job; Dart never retries.
    }
  }

  /// Headerless answers (the common small-response case) share one canonical
  /// empty list instead of allocating a fresh growable one.
  static List<RawHeader> _rawHeaders(ResponseContext response) {
    if (response.headers.isEmpty) return const <RawHeader>[];
    return [
      for (final entry in response.headers.entries)
        RawHeader(name: entry.key, value: entry.value),
    ];
  }

  /// Opens a chunked stream and forwards the body into it. Completion —
  /// clean end or stream error — sends the terminal chunk and marks the id
  /// answered, so a stale duplicate head can never dispatch again. A stream
  /// error truncates rather than hangs: the client sees a clean terminator
  /// after the bytes so far.
  void _answerStream(int requestId, ResponseContext response) {
    if (_closed) return;
    try {
      _native.startStream(requestId, response.status, _rawHeaders(response));
    } catch (_) {
      // The timeout won before the first byte (or the server went away):
      // drop the stream unopened and mark the id answered.
      _complete(requestId);
      return;
    }
    late final StreamSubscription<Uint8List> sub;
    sub = response.bodyStream!.listen(
      (chunk) {
        if (_closed || chunk.isEmpty) return;
        try {
          _native.sendStreamChunk(requestId, chunk, false);
        } catch (_) {}
      },
      onError: (_) => _finishStream(requestId),
      onDone: () => _finishStream(requestId),
      cancelOnError: true,
    );
    _outbound[requestId] = sub;
  }

  void _finishStream(int requestId) {
    final sub = _outbound.remove(requestId);
    if (!_closed) {
      try {
        _native.sendStreamChunk(requestId, Uint8List(0), true);
      } catch (_) {}
    }
    _complete(requestId);
    sub?.cancel();
  }
}
