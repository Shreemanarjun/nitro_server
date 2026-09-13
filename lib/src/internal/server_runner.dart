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

/// Handler lookup key: the method token plus the registered pattern.
String handlerKey(HttpMethod method, String customToken, String pattern) {
  final token = method == HttpMethod.custom ? customToken : method.token;
  return '$token $pattern';
}

class _Pending {
  _Pending(this.head);

  final RawIncomingRequest head;
  final BytesBuilder body = BytesBuilder(copy: false);
  String? error;
  bool complete = false;
  bool dispatched = false;
}

class ServerRunner {
  ServerRunner(this._native);

  final NitroServerNative _native;
  final _pending = <int, _Pending>{};
  final _early = <int, List<Uint8List>>{};
  final _earlyErrors = <int, String>{};
  final _earlyComplete = <int>{};

  /// Cumulative ack count per request. Every copied chunk (data or error) is
  /// acked the moment it is copied — including chunks that arrive before
  /// their head — so native memory is freed promptly and exactly once.
  final _acked = <int, int>{};
  final _handlers = <String, RequestHandler>{};
  final _middlewares = <Middleware>[];
  final _events = StreamController<ServerEvent>.broadcast();

  StreamSubscription<RawIncomingRequest>? _heads;
  StreamSubscription<RawBodyChunk>? _chunks;
  StreamSubscription<RawServerEvent>? _serverEvents;
  bool _listening = false;
  bool _closed = false;

  /// The re-broadcast engine events (lifecycle, timeouts, client errors).
  Stream<ServerEvent> get events => _events.stream;

  /// Test seam: ids with an unfinished request.
  Set<int> get pendingIdsForTesting => {..._pending.keys};

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
    RequestHandler handler,
  ) {
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
    _handlers[handlerKey(method, customToken, pattern)] = handler;
  }

  /// Appends [middleware] to the chain. Order is registration order: the
  /// first `use` is the outermost wrapper. Applies to routes registered
  /// before AND after — the chain is resolved at dispatch, not at
  /// registration.
  void use(Middleware middleware) => _middlewares.add(middleware);

  void removeRoute(HttpMethod method, String customToken, String pattern) {
    final token = method == HttpMethod.custom ? customToken : method.token;
    final status = _native.unregisterRoute(token, pattern);
    throwIfFailed(status, operation: 'unregisterRoute($pattern)');
    _handlers.remove(handlerKey(method, customToken, pattern));
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
    if (_pending.containsKey(head.requestId)) return;
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
      _pending.remove(head.requestId);
      return;
    }
    final (method, custom) = httpMethodOf(head.method, head.customMethod);
    // Method-specific registrations win; `HttpMethod.all` is the fallback —
    // mirroring the native router's precedence (specific beats All).
    final handler = _handlers[handlerKey(method, custom, head.routePattern)] ??
        _handlers[handlerKey(HttpMethod.all, '', head.routePattern)];
    if (handler == null) {
      _answer(head.requestId, const ResponseContext(status: 404));
      _pending.remove(head.requestId);
      return;
    }
    final piped = _middlewares.reversed.fold<RequestHandler>(
      handler,
      (next, middleware) => (request) => middleware(request, next),
    );
    final context = RequestContext(
      method: method,
      customMethod: custom,
      path: head.path,
      query: head.query,
      queryParameters: head.query.isEmpty
          ? const {}
          : Uri.splitQueryString(head.query),
      headers: _foldHeaders(head.headers),
      params: {for (final p in head.params) p.name: p.value},
      routePattern: head.routePattern,
      body: pending.body.toBytes(),
    );
    Future(() => piped(context)).then(
      (response) {
        _answer(head.requestId, response);
        _pending.remove(head.requestId);
      },
      onError: (Object error) {
        _answer(
          head.requestId,
          ResponseContext.text('handler error: $error', status: 500),
        );
        _pending.remove(head.requestId);
      },
    );
  }

  static Map<String, List<String>> _foldHeaders(List<RawHeader> headers) {
    final out = <String, List<String>>{};
    for (final header in headers) {
      (out[header.name.toLowerCase()] ??= []).add(header.value);
    }
    return out;
  }

  void _answer(int requestId, ResponseContext response) {
    if (_closed) return;
    try {
      _native.respond(
        requestId,
        response.status,
        [
          for (final entry in response.headers.entries)
            RawHeader(name: entry.key, value: entry.value),
        ],
        response.bodyBytes,
      );
    } catch (_) {
      // The request was already answered (timeout won) or the server went
      // away mid-flight. Exactly-once is the engine's job; Dart never retries.
    }
  }
}
