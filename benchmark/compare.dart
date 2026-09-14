// Compares `dart:io HttpServer` vs `shelf` vs `nitro_server` on identical
// routes with an identical client methodology.
//
// Run (from the package root, after building the native library):
//
//   cmake -S src -B build/lib -DCMAKE_BUILD_TYPE=Release
//   cmake --build build/lib --parallel
//
//   # JIT mode (default `dart run`: fast to iterate, includes JIT warmup):
//   dart run benchmark/compare.dart [--quick]
//
//   # AOT mode (what Flutter release ships: no JIT warmup, peak optimizer):
//   dart compile exe benchmark/compare.dart -o build/benchmark/compare
//   ./build/benchmark/compare [--quick]
//
// Run BOTH and compare: round 1 of the JIT run includes compiler warmup on
// the Dart sides (nitro's engine is native either way), while the AOT run
// shows steady-state without it. If nitro wins in one mode only, say so —
// a benchmark that can only pass in one VM mode is a hint, not a verdict.
//
// This file is pure Dart (no Flutter imports): it is the proof that the
// package runs in Dart-only mode. `shelf` is used the way everyone uses it —
// `shelf_io.serve` — so the comparison measures the real framework cost, not
// a hand-rolled fast path.
//
// Fairness rules, stated so the numbers stay honest:
// * Same three routes on all servers, same response bytes.
// * Same driver: one `HttpClient` per phase, `Connection: close` semantics
//   enforced on every side (the dart:io and shelf handlers answer `close`;
//   nitro binds with `keepAliveTimeout: Duration.zero`), so nobody benefits
//   from keep-alive pooling while someone else pays for handshakes.
// * In `--keep-alive` mode nitro binds `maxRequestsPerConnection: 0`:
//   dart:io and shelf never cap requests per connection, so capping only
//   nitro would meter reconnects into nitro's numbers.
// * Every case asserts exact status AND bytes (full compare on small
//   bodies, FNV checksum on large/echo bodies) — a faster wrong answer
//   cannot win.
// * Same machine, same loopback, interleaved phases (A/B/C/A/B/C) so a
//   thermal excursion cannot favor one side.
// * Warmup before measuring (JIT + connection pools settle), then reports
//   latency distributions AND throughput, never a single headline number.
// * `--batch-events` coalesces the 20 SSE events on ALL sides (same bytes,
//   each side's natural framing) to show the batching tradeoff fairly.
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:benchmark_harness/benchmark_harness.dart';
import 'package:nitro_server/nitro_server.dart';
import 'package:shelf/shelf.dart' hide Middleware;
import 'package:shelf/shelf_io.dart' as shelf_io;

/// Routes served byte-identically by all servers.
final Map<String, Uint8List> _routes = {
  '/hello': Uint8List.fromList('hello world!'.codeUnits),
  '/json': Uint8List.fromList(
    jsonEncode({
      'id': 42,
      'name': 'nitro',
      'tags': ['a', 'b', 'c'],
    }).codeUnits,
  ),
};

/// `/work`: a handler doing real CPU — JSON-encoding 200 small records —
/// the shape of an API endpoint rather than a byte echo. Deterministic, so
/// the exact bytes are asserted like every other case. This is where
/// isolates matter: a single Dart isolate is the ceiling for handler work.
Uint8List _workBody() => Uint8List.fromList(
  jsonEncode([
    for (var i = 0; i < 200; i++)
      {
        'id': i,
        'name': 'item-\$i',
        'tags': ['a', 'b'],
        'score': i * 1.5,
      },
  ]).codeUnits,
);
final Uint8List _workExpected = _workBody();

/// `/file`: a 64 KiB static file. dart:io and shelf stream it through the
/// isolate (`File.openRead`); nitro answers `ResponseContext.file`, which
/// the native worker sends with `sendfile` — the bytes never enter Dart.
final File _staticFile = () {
  final dir = Directory.systemTemp.createTempSync('nitro_bench_file');
  final file = File('${dir.path}/asset.bin')
    ..writeAsBytesSync(List<int>.generate(64 * 1024, (i) => (i * 31) & 0xff));
  return file;
}();
final Uint8List _fileExpected = _staticFile.readAsBytesSync();

final Uint8List _echoPayload = Uint8List.fromList(
  List<int>.generate(4096, (i) => i & 0xff),
);

/// 1 MiB upload/download body. Generated, never stored per request.
final Uint8List _bigPayload = Uint8List.fromList(
  List<int>.generate(1024 * 1024, (i) => i & 0xff),
);

/// Streamed events: 20 chunks, same bytes on every side.
final List<Uint8List> _eventChunks = [
  for (var i = 0; i < 20; i++) Uint8List.fromList('data: $i\n\n'.codeUnits),
];
final int _eventsTotalBytes = _eventChunks.fold(
  0,
  (sum, chunk) => sum + chunk.length,
);

/// The 20 events coalesced: identical bytes, one write. Used by all sides
/// under `--batch-events` so the batching tradeoff is measured fairly.
final Uint8List _eventsAll = Uint8List.fromList([
  for (final chunk in _eventChunks) ...chunk,
]);

/// FNV-1a checksums, precomputed once: echo verification must touch content
/// (a server returning wrong bytes of the right length must fail) without
/// retaining megabyte bodies per iteration.
int _fnv(List<int> bytes) {
  var h = 0x811c9dc5;
  for (final b in bytes) {
    h ^= b;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h;
}

final int _echoHash = _fnv(_echoPayload);
final int _bigHash = _fnv(_bigPayload);

/// When true the servers may keep connections alive (the real-world mode).
/// Wired by `--keep-alive`; the default stays `Connection: close` so the
/// handshake cost is identical on all sides.
bool _keepAlive = false;

/// When true every side sends the 20 SSE events coalesced instead of
/// per-chunk (same bytes, each side's natural framing). Wired by
/// `--batch-events`; default off so the headline numbers measure the
/// real-time (per-event) path.
bool _batchEvents = false;

/// Native worker threads for nitro (`--workers N`); 0 keeps the engine
/// default. Threads park per connection, so fewer workers than connections
/// means idle connections cycle through the queue between workers.
int _workers = 0;

/// Dart isolates behind nitro (`--isolates N`; 1 = the calling isolate
/// only, 0 = auto-size from the CPU count).
int _isolates = 1;

String _connHeader() => _keepAlive ? 'keep-alive' : 'close';

// ── Servers ──────────────────────────────────────────────────────────────────

/// Pass-through middleware: one extra async hop around every dart:io
/// request, mirroring `shelf`'s pipeline and nitro's `use()` below.
Future<void> _withDartMw(HttpRequest request, Future<void> Function() next) {
  return next();
}

/// Extra dart:io isolates sharing the port (`HttpServer.bind(shared:
/// true)`): dart:io's own answer to the single-isolate ceiling, spawned
/// when `--isolates N` asks nitro for N isolates so both sides get the
/// same number of cores for handler work.
Future<List<Isolate>> _spawnSharedDartServers(int port, int count) async {
  final isolates = <Isolate>[];
  for (var i = 0; i < count; i++) {
    final ready = ReceivePort();
    // The isolate's own copies of the mode flags start at their defaults:
    // hand the real ones over, or those isolates answer `Connection: close`.
    isolates.add(
      await Isolate.spawn(_sharedDartServerMain, (
        port: port,
        keepAlive: _keepAlive,
        batchEvents: _batchEvents,
        ready: ready.sendPort,
      ), onError: ready.sendPort),
    );
    final first = await ready.first;
    if (first != true) {
      throw StateError('dart:io shared isolate $i failed to bind: $first');
    }
  }
  return isolates;
}

Future<void> _sharedDartServerMain(
  ({int port, bool keepAlive, bool batchEvents, SendPort ready}) args,
) async {
  _keepAlive = args.keepAlive;
  _batchEvents = args.batchEvents;
  await _startDartServer(port: args.port, shared: true);
  args.ready.send(true);
}

Future<HttpServer> _startDartServer({int port = 0, bool shared = false}) async {
  final server = await HttpServer.bind(
    InternetAddress.loopbackIPv4,
    port,
    shared: shared,
  );
  server.defaultResponseHeaders.clear();
  server.listen(
    (request) => _withDartMw(request, () async {
      final path = request.uri.path;
      if (path == '/ws') {
        final ws = await WebSocketTransformer.upgrade(request);
        ws.listen(ws.add, onError: (_) {});
        return;
      }
      final response = request.response;
      response.headers.set('connection', _connHeader());
      try {
        if (request.method == 'POST' && path == '/echo') {
          final body = await request.fold<BytesBuilder>(
            BytesBuilder(),
            (b, d) => b..add(d),
          );
          response.headers.contentType = ContentType.binary;
          response.contentLength = body.length;
          response.add(body.toBytes());
        } else if (request.method == 'GET' && path == '/events') {
          response.headers.contentType = ContentType('text', 'event-stream');
          if (_batchEvents) {
            response.contentLength = _eventsAll.length;
            response.add(_eventsAll);
          } else {
            for (final chunk in _eventChunks) {
              response.add(chunk);
              await response.flush();
            }
          }
        } else if (request.method == 'GET' && path.startsWith('/users/')) {
          final id = path.substring('/users/'.length);
          final body = Uint8List.fromList('user $id'.codeUnits);
          response.contentLength = body.length;
          response.add(body);
        } else if (request.method == 'GET' && path.startsWith('/files/')) {
          final body = Uint8List.fromList('wild:$path'.codeUnits);
          response.contentLength = body.length;
          response.add(body);
        } else if (request.method == 'GET' && path == '/q') {
          final body = Uint8List.fromList(
            jsonEncode(request.uri.queryParameters).codeUnits,
          );
          response.contentLength = body.length;
          response.add(body);
        } else if (request.method == 'GET' && path == '/mw') {
          final body = _routes['/hello']!;
          response.contentLength = body.length;
          response.add(body);
        } else if (request.method == 'GET' && path == '/work') {
          final body = _workBody();
          response.headers.contentType = ContentType.json;
          response.contentLength = body.length;
          response.add(body);
        } else if (request.method == 'GET' && path == '/file') {
          response.headers.contentType = ContentType.binary;
          response.contentLength = _fileExpected.length;
          await response.addStream(_staticFile.openRead());
        } else if (_routes.containsKey(path)) {
          final body = _routes[path]!;
          response.contentLength = body.length;
          response.add(body);
        } else {
          response.statusCode = 404;
          response.write('not found');
        }
      } catch (_) {
        response.statusCode = 500;
      }
      await response.close();
    }),
  );
  return server;
}

Response _shelfHandler(Request request) {
  if (request.method == 'POST' && request.url.path == 'echo') {
    // Shelf reads the body asynchronously; the sync handler half below only
    // covers GETs, so POST is handled in [_startShelfServer]'s wrapper.
    throw StateError('unreachable');
  }
  final path = '/${request.url.path}';
  Uint8List? body;
  if (request.method == 'GET' && path == '/events') {
    if (_batchEvents) {
      return Response.ok(
        _eventsAll,
        headers: {
          'connection': _connHeader(),
          'content-type': 'text/event-stream',
        },
      );
    }
    return Response.ok(
      Stream.fromIterable(_eventChunks),
      headers: {
        'connection': _connHeader(),
        'content-type': 'text/event-stream',
      },
    );
  } else if (request.method == 'GET' && path.startsWith('/users/')) {
    body = Uint8List.fromList(
      'user ${path.substring('/users/'.length)}'.codeUnits,
    );
  } else if (request.method == 'GET' && path.startsWith('/files/')) {
    body = Uint8List.fromList('wild:$path'.codeUnits);
  } else if (request.method == 'GET' && path == '/q') {
    body = Uint8List.fromList(
      jsonEncode(request.url.queryParameters).codeUnits,
    );
  } else if (request.method == 'GET' && path == '/mw') {
    body = _routes['/hello'];
  } else if (request.method == 'GET' && path == '/work') {
    body = _workBody();
  } else if (request.method == 'GET' && path == '/file') {
    return Response.ok(
      _staticFile.openRead(),
      headers: {
        'connection': _connHeader(),
        'content-type': 'application/octet-stream',
        'content-length': '${_fileExpected.length}',
      },
    );
  } else {
    body = _routes[path];
  }
  if (body == null) {
    return Response.notFound(
      'not found',
      headers: {'connection': _connHeader()},
    );
  }
  return Response.ok(
    body,
    headers: {'connection': _connHeader(), 'content-type': 'text/plain'},
  );
}

/// One pass-through layer, like the other sides. Typed without shelf's
/// `Middleware` typedef (hidden: it collides with nitro's) — this identical
/// shape satisfies `Pipeline.addMiddleware` all the same.
FutureOr<Response> Function(Request) _shelfMw(
  FutureOr<Response> Function(Request) inner,
) {
  return (request) => inner(request);
}

Future<HttpServer> _startShelfServer() async {
  Future<Response> handler(Request request) async {
    if (request.method == 'POST' && request.url.path == 'echo') {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in request.read()) {
        builder.add(chunk);
      }
      return Response.ok(
        builder.toBytes(),
        headers: {
          'connection': _connHeader(),
          'content-type': 'application/octet-stream',
        },
      );
    }
    return _shelfHandler(request);
  }

  final pipeline = const Pipeline().addMiddleware(_shelfMw).addHandler(handler);
  final server = await shelf_io.serve(
    pipeline,
    InternetAddress.loopbackIPv4,
    0,
  );
  server.defaultResponseHeaders.clear();
  return server;
}

/// Route registration for nitro as a setup function: with `--isolates N`
/// it runs once per isolate, so it captures only the values it needs.
ServerSetup _nitroSetup(bool batchEvents) {
  return (server) async {
    // One pass-through middleware, like the other sides. Handlers return
    // their response directly: nothing here awaits, and the dart:io and
    // shelf handlers do their work synchronously too.
    await server.use((request, next) => next(request));
    for (final entry in _routes.entries) {
      final body = entry.value;
      await server.get(entry.key, (_) => ResponseContext.bytes(body));
    }
    await server.get(
      '/users/:id',
      (request) => ResponseContext.text('user ${request.param('id')}'),
    );
    await server.get(
      '/files/*',
      (request) => ResponseContext.text('wild:${request.path}'),
    );
    await server.get(
      '/q',
      (request) => ResponseContext.jsonMap(request.queryParameters),
    );
    await server.get('/mw', (_) => ResponseContext.bytes(_routes['/hello']!));
    await server.get(
      '/work',
      (_) =>
          ResponseContext.bytes(_workBody(), contentType: 'application/json'),
    );
    await server.get('/file', (_) => ResponseContext.file(_staticFile.path));
    await server.get(
      '/events',
      (_) => ResponseContext.stream(
        Stream.fromIterable(_eventChunks),
        headers: {'content-type': 'text/event-stream'},
        bufferSize: batchEvents ? 4096 : 0,
      ),
    );
    await server.post(
      '/echo',
      (request) => ResponseContext.bytes(request.body),
    );
    await server.ws('/ws', (session) async {
      await for (final message in session.messages) {
        if (message.isText) {
          session.sendText(message.text!);
        } else {
          session.sendBytes(message.bytes!);
        }
      }
    });
  };
}

Future<NitroServer> _startNitroServer() async {
  // Without `--keep-alive` every response carries `Connection: close`,
  // matching the dart:io and shelf servers below. (The engine default
  // enables keep-alive, which `HttpClient` pools — a pooled reuse racing a
  // server-side close measures pool luck, not servers.)
  //
  // With `--keep-alive` the request cap is lifted as well as the timeout:
  // dart:io and shelf never cap requests per connection, so metering
  // reconnects into only nitro's numbers would punish it for a limit the
  // others don't have.
  final config = _keepAlive
      ? ServerConfig(
          maxRequestsPerConnection: 0,
          workerThreads: _workers,
          isolates: _isolates,
        )
      : ServerConfig(
          keepAliveTimeout: Duration.zero,
          workerThreads: _workers,
          isolates: _isolates,
        );
  return NitroServer.bind(config, _nitroSetup(_batchEvents));
}

// ── Driver (identical for every server) ──────────────────────────────────────

Future<int> _postEcho(HttpClient client, int port) async {
  final stopwatch = Stopwatch()..start();
  final request = await client.postUrl(
    Uri.parse('http://127.0.0.1:$port/echo'),
  );
  request.add(_echoPayload);
  final response = await request.close();
  var received = 0;
  var hash = 0x811c9dc5;
  await for (final chunk in response) {
    received += chunk.length;
    for (final b in chunk) {
      hash ^= b;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
  }
  stopwatch.stop();
  if (response.statusCode != 200 ||
      received != _echoPayload.length ||
      hash != _echoHash) {
    throw StateError('echo mismatch: ${response.statusCode}/$received');
  }
  return stopwatch.elapsedMicroseconds;
}

/// One measured GET with an exact body expectation. Returns microseconds.
Future<int> _getExpect(
  HttpClient client,
  int port,
  String path,
  List<int> expected,
) async {
  final stopwatch = Stopwatch()..start();
  final request = await client.getUrl(Uri.parse('http://127.0.0.1:$port$path'));
  final response = await request.close();
  final builder = await response.fold<BytesBuilder>(
    BytesBuilder(),
    (b, d) => b..add(d),
  );
  stopwatch.stop();
  final body = builder.toBytes();
  if (response.statusCode != 200 || !_equals(body, expected)) {
    throw StateError('GET $path mismatch: ${response.statusCode}');
  }
  return stopwatch.elapsedMicroseconds;
}

bool _equals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// One measured POST echo of [payload] bytes (only [_bigPayload] is used;
/// the hash is precomputed). Returns microseconds.
Future<int> _postEchoSized(
  HttpClient client,
  int port,
  Uint8List payload,
) async {
  final stopwatch = Stopwatch()..start();
  final request = await client.postUrl(
    Uri.parse('http://127.0.0.1:$port/echo'),
  );
  request.add(payload);
  final response = await request.close();
  var received = 0;
  var hash = 0x811c9dc5;
  await for (final chunk in response) {
    received += chunk.length;
    for (final b in chunk) {
      hash ^= b;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
  }
  stopwatch.stop();
  if (response.statusCode != 200 ||
      received != payload.length ||
      hash != _bigHash) {
    throw StateError('echo mismatch: ${response.statusCode}/$received');
  }
  return stopwatch.elapsedMicroseconds;
}

/// One measured SSE drain: same event bytes on every side.
Future<int> _getEvents(HttpClient client, int port) async {
  final stopwatch = Stopwatch()..start();
  final request = await client.getUrl(
    Uri.parse('http://127.0.0.1:$port/events'),
  );
  final response = await request.close();
  final builder = await response.fold<BytesBuilder>(
    BytesBuilder(),
    (b, d) => b..add(d),
  );
  stopwatch.stop();
  final body = builder.toBytes();
  if (response.statusCode != 200 || body.length != _eventsTotalBytes) {
    throw StateError('events mismatch: ${response.statusCode}/${body.length}');
  }
  return stopwatch.elapsedMicroseconds;
}

Map<String, double> _summarize(List<int> samplesUs) {
  final sorted = [...samplesUs]..sort();
  double pct(double p) =>
      sorted[(sorted.length * p).clamp(0, sorted.length - 1).toInt()]
          .toDouble();
  final mean = sorted.reduce((a, b) => a + b) / sorted.length;
  return {'mean': mean, 'p50': pct(0.5), 'p99': pct(0.99)};
}

/// One benchmark case driven by `package:benchmark_harness`.
///
/// The harness owns the sequential-latency loop: unmeasured `setup()` builds
/// one `HttpClient`, a 100 ms warmup settles JIT + pools, then `exercise()`
/// runs one request per iteration for ~2 s and the harness reports the
/// standardized per-request mean. We record the same iterations to derive
/// p50/p99, so every column comes from one identical sample set — no double
/// measurement.
class _RequestBenchmark extends AsyncBenchmarkBase {
  _RequestBenchmark(super.name, this.port, this.op);

  final int port;
  final Future<int> Function(HttpClient, int) op;
  late final HttpClient client;
  final samplesUs = <int>[];
  bool _record = false;

  @override
  Future<void> setup() async {
    client = HttpClient();
  }

  @override
  Future<void> exercise() async {
    _record = true;
    await run();
    _record = false;
  }

  @override
  Future<void> run() async {
    try {
      final us = await op(client, port);
      if (_record) samplesUs.add(us);
    } on SocketException catch (e) {
      // Close mode: out of ephemeral ports (see _load). Back off, skip.
      if (!_isPortExhaustion(e)) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  @override
  Future<void> teardown() async {
    client.close(force: true);
  }
}

/// JIT vs AOT detection for labeling results.
///
/// `dart run` launches the Dart VM binary (executable ends in `dart` /
/// `dartaotruntime`); a `dart compile exe` binary IS the executable, so any
/// other executable name means AOT. AOT is what Flutter release ships, JIT
/// is the edit-run loop — the numbers are only comparable within one mode.
String _vmMode() {
  final exe = Platform.executable.toLowerCase();
  final isJit =
      exe.endsWith('dart') ||
      exe.endsWith('dart.exe') ||
      exe.contains('dartaotruntime');
  return isJit ? 'JIT' : 'AOT';
}

typedef _Op = Future<int> Function(HttpClient client, int port);

final Uint8List _queryExpected = Uint8List.fromList(
  jsonEncode({'a': '1', 'b': 'two'}).codeUnits,
);
final Uint8List _paramExpected = Uint8List.fromList('user 42'.codeUnits);
final Uint8List _wildExpected = Uint8List.fromList(
  'wild:/files/a/b/c'.codeUnits,
);

/// Every case as a top-level table so client isolates resolve an op by key:
/// a closure over server state cannot cross an isolate boundary, a key can.
final Map<String, _Op> _ops = {
  '/hello': (c, p) => _getExpect(c, p, '/hello', _routes['/hello']!),
  '/json': (c, p) => _getExpect(c, p, '/json', _routes['/json']!),
  '/users/:id': (c, p) => _getExpect(c, p, '/users/42', _paramExpected),
  '/files/*': (c, p) => _getExpect(c, p, '/files/a/b/c', _wildExpected),
  '/q?a=1&b=two': (c, p) => _getExpect(c, p, '/q?a=1&b=two', _queryExpected),
  '/mw': (c, p) => _getExpect(c, p, '/mw', _routes['/hello']!),
  '/work': (c, p) => _getExpect(c, p, '/work', _workExpected),
  '/file': (c, p) => _getExpect(c, p, '/file', _fileExpected),
  'POST /echo 4k': _postEcho,
  'POST /echo 1m': (c, p) => _postEchoSized(c, p, _bigPayload),
  'GET /events': _getEvents,
};

/// WebSocket echo cases: message size, frame type, and whether the client
/// offers permessage-deflate (both servers accept it when offered). The
/// deflate payload is compressible text; the binary one is not.
final Map<String, ({Object message, bool deflate})> _wsCases = {
  'WS /ws 128B': (message: 'a' * 128, deflate: false),
  'WS /ws 4k': (message: _echoPayload, deflate: false),
  'WS /ws 4k deflate': (
    message: ('the quick brown fox ' * 205).substring(0, 4096),
    deflate: true,
  ),
};

Future<WebSocket> _wsConnect(String opKey, int port) {
  final c = _wsCases[opKey]!;
  return WebSocket.connect(
    'ws://127.0.0.1:$port/ws',
    compression: c.deflate
        ? CompressionOptions.compressionDefault
        : CompressionOptions.compressionOff,
  );
}

/// One echo round trip on an open socket. Returns microseconds.
Future<int> _wsEcho(
  StreamIterator<dynamic> incoming,
  WebSocket ws,
  Object message,
) async {
  final stopwatch = Stopwatch()..start();
  ws.add(message);
  if (!await incoming.moveNext()) throw StateError('ws: closed');
  stopwatch.stop();
  final echoed = incoming.current;
  final ok = message is String
      ? echoed == message
      : echoed is List<int> &&
            _equals(Uint8List.fromList(echoed), message as Uint8List);
  if (!ok) throw StateError('ws: echo mismatch');
  return stopwatch.elapsedMicroseconds;
}

class _WsBenchmark extends AsyncBenchmarkBase {
  _WsBenchmark(super.name, this.port);

  final int port;
  late final WebSocket ws;
  late final StreamIterator<dynamic> incoming;
  final samplesUs = <int>[];
  bool _record = false;

  @override
  Future<void> setup() async {
    ws = await _wsConnect(name, port);
    incoming = StreamIterator(ws);
  }

  @override
  Future<void> exercise() async {
    _record = true;
    await run();
    _record = false;
  }

  @override
  Future<void> run() async {
    final us = await _wsEcho(incoming, ws, _wsCases[name]!.message);
    if (_record) samplesUs.add(us);
  }

  @override
  Future<void> teardown() => ws.close();
}

Future<({double meanUs, List<int> samplesUs})> _wsSequential(
  String opKey,
  int port,
) async {
  final benchmark = _WsBenchmark(opKey, port);
  final meanUs = await benchmark.measure();
  return (meanUs: meanUs, samplesUs: benchmark.samplesUs);
}

Future<({int done, int elapsedUs, List<int> samplesUs})> _wsLoad(
  String opKey,
  int port,
  int connections,
  int millis,
) async {
  final message = _wsCases[opKey]!.message;
  final samples = <int>[];
  final deadline = DateTime.now().add(Duration(milliseconds: millis));
  final stopwatch = Stopwatch()..start();
  await Future.wait([
    for (var w = 0; w < connections; w++)
      () async {
        final ws = await _wsConnect(opKey, port);
        final incoming = StreamIterator<dynamic>(ws);
        while (DateTime.now().isBefore(deadline)) {
          samples.add(await _wsEcho(incoming, ws, message));
        }
        await ws.close();
      }(),
  ]);
  stopwatch.stop();
  return (
    done: samples.length,
    elapsedUs: stopwatch.elapsedMicroseconds,
    samplesUs: samples,
  );
}

/// Sequential latency, run in its own isolate: one connection, the harness
/// owns the loop. The server isolate only serves.
Future<({double meanUs, List<int> samplesUs})> _sequential(
  String opKey,
  int port,
) async {
  final benchmark = _RequestBenchmark(opKey, port, _ops[opKey]!);
  final meanUs = await benchmark.measure();
  return (meanUs: meanUs, samplesUs: benchmark.samplesUs);
}

/// Raw-socket request/expectation for the cases the `--raw` load client
/// can drive: one-shot bodies with a `Content-Length` (streams stay on
/// `HttpClient`). Returns null for other cases.
({List<int> request, Uint8List expected})? _rawCase(
  String opKey,
  bool keepAlive,
) {
  final conn = keepAlive ? 'keep-alive' : 'close';
  ({List<int> request, Uint8List expected}) get(String path, Uint8List body) =>
      (
        request: ascii.encode(
          'GET $path HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: $conn\r\n\r\n',
        ),
        expected: body,
      );
  ({List<int> request, Uint8List expected}) post(Uint8List body) => (
    request: [
      ...ascii.encode(
        'POST /echo HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: $conn\r\n'
        'Content-Length: ${body.length}\r\n\r\n',
      ),
      ...body,
    ],
    expected: body,
  );
  return switch (opKey) {
    '/hello' => get('/hello', _routes['/hello']!),
    '/json' => get('/json', _routes['/json']!),
    '/users/:id' => get('/users/42', _paramExpected),
    '/files/*' => get('/files/a/b/c', _wildExpected),
    '/q?a=1&b=two' => get('/q?a=1&b=two', _queryExpected),
    '/mw' => get('/mw', _routes['/hello']!),
    '/work' => get('/work', _workExpected),
    '/file' => get('/file', _fileExpected),
    'POST /echo 4k' => post(_echoPayload),
    'POST /echo 1m' => post(_bigPayload),
    _ => null,
  };
}

/// One raw-socket connection in a closed loop: send, read one framed
/// response (`Content-Length`), verify status + exact bytes, repeat. Costs
/// the client a few microseconds per request instead of `HttpClient`'s
/// tens, so the server — not the driver — is what saturates.
Future<void> _rawConnection(
  int port,
  List<int> request,
  Uint8List expected,
  bool keepAlive,
  DateTime deadline,
  List<int> samples,
) async {
  Socket? socket;
  final buffer = BytesBuilder(copy: false);
  StreamIterator<Uint8List>? chunks;
  Future<Socket> connect() async {
    final s = await Socket.connect('127.0.0.1', port);
    s.setOption(SocketOption.tcpNoDelay, true);
    chunks = StreamIterator(s);
    return s;
  }

  while (DateTime.now().isBefore(deadline)) {
    final stopwatch = Stopwatch()..start();
    try {
      socket ??= await connect();
    } on SocketException catch (e) {
      if (!_isPortExhaustion(e)) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      continue;
    }
    socket.add(request);
    var bytes = buffer.toBytes();
    buffer.clear();
    var headEnd = _indexOfCrlfCrlf(bytes);
    while (headEnd < 0) {
      if (!await chunks!.moveNext()) throw StateError('raw: closed in head');
      buffer
        ..add(bytes)
        ..add(chunks!.current);
      bytes = buffer.toBytes();
      buffer.clear();
      headEnd = _indexOfCrlfCrlf(bytes);
    }
    final head = ascii.decode(bytes.sublist(0, headEnd));
    if (!head.startsWith('HTTP/1.1 200')) {
      throw StateError('raw: bad status: ${head.split('\r\n').first}');
    }
    final length = _contentLength(head);
    // Body bytes are appended, never re-materialised: a megabyte response
    // arriving in many chunks costs one copy, not one per chunk.
    buffer.add(Uint8List.sublistView(bytes, headEnd + 4));
    var have = bytes.length - headEnd - 4;
    while (have < length) {
      if (!await chunks!.moveNext()) throw StateError('raw: closed in body');
      buffer.add(chunks!.current);
      have += chunks!.current.length;
    }
    stopwatch.stop();
    final body = buffer.takeBytes();
    if (length != expected.length ||
        !_equals(Uint8List.sublistView(body, 0, length), expected)) {
      throw StateError('raw: body mismatch');
    }
    samples.add(stopwatch.elapsedMicroseconds);
    // Surplus bytes belong to the next response; a closing server ends it.
    if (body.length > length) buffer.add(Uint8List.sublistView(body, length));
    if (!keepAlive || head.toLowerCase().contains('connection: close')) {
      socket.destroy();
      socket = null;
      buffer.clear();
    }
  }
  socket?.destroy();
}

/// EADDRNOTAVAIL (macOS errno 49, Linux 99): no ephemeral port free.
bool _isPortExhaustion(SocketException e) {
  final code = e.osError?.errorCode;
  return code == 49 || code == 99;
}

int _indexOfCrlfCrlf(Uint8List bytes) {
  for (var i = 0; i + 3 < bytes.length; i++) {
    if (bytes[i] == 13 &&
        bytes[i + 1] == 10 &&
        bytes[i + 2] == 13 &&
        bytes[i + 3] == 10) {
      return i;
    }
  }
  return -1;
}

int _contentLength(String head) {
  for (final line in head.split('\r\n').skip(1)) {
    final colon = line.indexOf(':');
    if (colon > 0 &&
        line.substring(0, colon).trim().toLowerCase() == 'content-length') {
      return int.parse(line.substring(colon + 1).trim());
    }
  }
  throw StateError('raw: no content-length in response');
}

/// Closed-loop load from one client isolate: [connections] workers hammer
/// [port] for [millis]. Returns the completed count, the wall time and every
/// per-request latency, so the coordinator can report rate AND tail.
/// With [raw] the workers are raw sockets (see [_rawConnection]) for the
/// cases that support it; others fall back to `HttpClient`.
Future<({int done, int elapsedUs, List<int> samplesUs})> _load(
  String opKey,
  int port,
  int connections,
  int millis, {
  required bool raw,
  required bool keepAlive,
}) async {
  final rawCase = raw ? _rawCase(opKey, keepAlive) : null;
  if (rawCase != null) {
    final samples = <int>[];
    final deadline = DateTime.now().add(Duration(milliseconds: millis));
    final stopwatch = Stopwatch()..start();
    await Future.wait([
      for (var w = 0; w < connections; w++)
        _rawConnection(
          port,
          rawCase.request,
          rawCase.expected,
          keepAlive,
          deadline,
          samples,
        ),
    ]);
    stopwatch.stop();
    return (
      done: samples.length,
      elapsedUs: stopwatch.elapsedMicroseconds,
      samplesUs: samples,
    );
  }
  final op = _ops[opKey]!;
  final client = HttpClient()..maxConnectionsPerHost = connections;
  final samples = <int>[];
  final deadline = DateTime.now().add(Duration(milliseconds: millis));
  final stopwatch = Stopwatch()..start();
  var done = 0;
  await Future.wait([
    for (var w = 0; w < connections; w++)
      () async {
        while (DateTime.now().isBefore(deadline)) {
          try {
            samples.add(await op(client, port));
            done++;
          } on SocketException catch (e) {
            // Close mode opens a connection per request: the OS runs out
            // of ephemeral ports (TIME_WAIT) before the server runs out of
            // anything. Back off and retry; the request is not counted.
            if (!_isPortExhaustion(e)) rethrow;
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }
      }(),
  ]);
  stopwatch.stop();
  client.close(force: true);
  return (
    done: done,
    elapsedUs: stopwatch.elapsedMicroseconds,
    samplesUs: samples,
  );
}

/// One case: sequential latency from one client isolate, then a closed-loop
/// sweep from [clients] isolates sharing [connections] connections. Every
/// client lives in its own isolate so the server under test owns its event
/// loop — a driver sharing the isolate would measure itself.
Future<({String row, Map<String, Object?> json})> _phase(
  String label,
  String opKey,
  int port, {
  required int clients,
  required int connections,
  required int millis,
  required bool raw,
  required bool keepAlive,
}) async {
  final ws = _wsCases.containsKey(opKey);
  final seq = await Isolate.run(
    () => ws ? _wsSequential(opKey, port) : _sequential(opKey, port),
  );
  final lat = _summarize(seq.samplesUs);

  if (connections == 0) {
    // No load sweep (close mode by default): the sequential columns are
    // the measurement, the rest reads as absent.
    print(
      '$label(RunTime): ${seq.meanUs.toStringAsFixed(4)} us. '
      '(n=${seq.samplesUs.length})',
    );
    return (
      row:
          '| $label | ${lat['p50']!.toStringAsFixed(0)} | '
          '${lat['p99']!.toStringAsFixed(0)} | — | — | — |',
      json: {
        'case': label,
        'seq_mean_us': double.parse(seq.meanUs.toStringAsFixed(1)),
        'seq_p50_us': lat['p50'],
        'seq_p99_us': lat['p99'],
        'load_p50_us': null,
        'load_p99_us': null,
        'req_per_s': null,
        'n': seq.samplesUs.length,
        'connections': 0,
      },
    );
  }

  final perClient = connections ~/ clients;
  final loads = await Future.wait([
    for (var i = 0; i < clients; i++)
      Isolate.run(
        () => ws
            ? _wsLoad(opKey, port, perClient, millis)
            : _load(
                opKey,
                port,
                perClient,
                millis,
                raw: raw,
                keepAlive: keepAlive,
              ),
      ),
  ]);
  final rps = loads.fold(0.0, (s, l) => s + l.done / l.elapsedUs * 1e6);
  final under = _summarize([for (final l in loads) ...l.samplesUs]);

  print(
    '$label(RunTime): ${seq.meanUs.toStringAsFixed(4)} us. '
    '(n=${seq.samplesUs.length})',
  );
  return (
    row:
        '| $label | ${lat['p50']!.toStringAsFixed(0)} | '
        '${lat['p99']!.toStringAsFixed(0)} | '
        '${under['p50']!.toStringAsFixed(0)} | '
        '${under['p99']!.toStringAsFixed(0)} | '
        '${rps.toStringAsFixed(0)} |',
    json: {
      'case': label,
      'seq_mean_us': double.parse(seq.meanUs.toStringAsFixed(1)),
      'seq_p50_us': lat['p50'],
      'seq_p99_us': lat['p99'],
      'load_p50_us': under['p50'],
      'load_p99_us': under['p99'],
      'req_per_s': double.parse(rps.toStringAsFixed(1)),
      'n': seq.samplesUs.length,
      'connections': connections,
    },
  );
}

int _flagInt(List<String> args, String flag, int fallback) {
  final i = args.indexOf(flag);
  return i != -1 && i + 1 < args.length ? int.parse(args[i + 1]) : fallback;
}

String? _flagStr(List<String> args, String flag) {
  final i = args.indexOf(flag);
  return i != -1 && i + 1 < args.length ? args[i + 1] : null;
}

Future<void> main(List<String> args) async {
  final quick = args.contains('--quick');
  _keepAlive = args.contains('--keep-alive');
  _batchEvents = args.contains('--batch-events');
  // Close mode opens a connection per request, and each one parks an
  // ephemeral port in TIME_WAIT (30 s on macOS, ~16k ports): a load sweep
  // there measures the port budget, not the server. So close mode runs the
  // sequential phase only, one round, with a cooldown between sides so
  // every side starts with a recovered budget. Pass --connections to force
  // a sweep anyway.
  final connections = _flagInt(
    args,
    '--connections',
    !_keepAlive ? 0 : (quick ? 32 : 64),
  );
  final clients = _flagInt(args, '--clients', 4);
  final millis = _flagInt(args, '--seconds', quick ? 1 : 3) * 1000;
  final rounds = quick || !_keepAlive ? 1 : 2;
  final cooldown = Duration(
    seconds: _flagInt(args, '--cooldown', _keepAlive || quick ? 0 : 30),
  );
  final only = _flagStr(args, '--only');
  final raw = args.contains('--raw');
  _workers = _flagInt(args, '--workers', 0);
  _isolates = _flagInt(args, '--isolates', 1);

  // Dart-only loading: Flutter apps skip this (the tooling bundles the
  // library); `dart run` / the compiled exe needs the explicit open.
  // `NITRO_SERVER_DYLIB` or `--dylib <path>` overrides the search when the
  // compiled exe runs from a different working directory.
  final loadedFrom = loadNitroServerNative(path: _flagStr(args, '--dylib'));
  final jsonPath = _flagStr(args, '--json');
  final mode = _vmMode();
  print(
    'nitro_server vs shelf vs dart:io HttpServer — same routes, same driver',
  );
  print(
    '(mode: $mode; native library: $loadedFrom'
    '${quick ? '; --quick' : ''}${_keepAlive ? '; --keep-alive' : ''}'
    '${_batchEvents ? '; --batch-events' : ''}'
    '${_workers > 0 ? '; --workers $_workers' : ''}'
    '${_isolates != 1 ? '; --isolates $_isolates' : ''}'
    '${raw ? '; --raw' : ''}'
    '${cooldown > Duration.zero ? '; --cooldown ${cooldown.inSeconds}' : ''})',
  );
  print('');
  print(
    'Sequential latency via package:benchmark_harness (AsyncBenchmarkBase, '
    '~2 s per case) from one client isolate; load: '
    '${connections == 0 ? 'none (sequential only)' : '$connections connections across $clients client isolates for ${millis ~/ 1000} s per case'}.',
  );
  print('');

  // `shared: true` on the FIRST bind too: a later shared bind on a port
  // held by an exclusive listener fails with "address in use".
  final dartServer = await _startDartServer(shared: _isolates != 1);
  final dartIsolates = _isolates == 1
      ? <Isolate>[]
      : await _spawnSharedDartServers(
          dartServer.port,
          (_isolates == 0 ? Platform.numberOfProcessors ~/ 2 : _isolates) - 1,
        );
  final shelfServer = await _startShelfServer();
  final nitroServer = await _startNitroServer();

  final sides = <(String, int)>[
    ('dart:io', dartServer.port),
    ('shelf  ', shelfServer.port),
    ('nitro  ', nitroServer.port),
  ];
  final cases = <(String, String, int)>[
    for (final opKey in _ops.keys)
      if (only == null || opKey == only)
        for (final (side, port) in sides) ('$side $opKey', opKey, port),
    for (final opKey in _wsCases.keys)
      if (only == null || opKey == only)
        for (final (side, port) in sides)
          if (!side.startsWith('shelf')) ('$side $opKey', opKey, port),
  ];

  final jsonCases = <Map<String, Object?>>[];
  // Interleaved A/B/C so machine drift cannot favor one side.
  for (var round = 0; round < rounds; round++) {
    print(
      '| case | seq p50 µs | seq p99 µs | load p50 µs | load p99 µs | '
      'req/s @$connections |',
    );
    print(
      '| ---- | ---------- | ---------- | ----------- | ----------- | --- |',
    );
    for (final (label, opKey, port) in cases) {
      if (cooldown > Duration.zero) await Future<void>.delayed(cooldown);
      final result = await _phase(
        label,
        opKey,
        port,
        clients: clients,
        connections: connections,
        millis: millis,
        raw: raw,
        keepAlive: _keepAlive,
      );
      print(result.row);
      if (round == rounds - 1) jsonCases.add(result.json);
    }
    print('');
  }

  if (jsonPath != null) {
    File(jsonPath).writeAsStringSync(
      jsonEncode({
        'mode': mode,
        'keep_alive': _keepAlive,
        'batch_events': _batchEvents,
        'quick': quick,
        'raw': raw,
        'connections': connections,
        'clients': clients,
        'cases': jsonCases,
      }),
    );
    print('wrote $jsonPath');
  }

  await dartServer.close(force: true);
  for (final isolate in dartIsolates) {
    isolate.kill(priority: Isolate.immediate);
  }
  await shelfServer.close(force: true);
  await nitroServer.close();
  print(
    'Load: $connections connections / $clients client isolates, '
    '${millis ~/ 1000} s per case. Sequential: harness ~2 s per case, '
    'one connection.',
  );
}
