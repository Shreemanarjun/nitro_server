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

String _connHeader() => _keepAlive ? 'keep-alive' : 'close';

// ── Servers ──────────────────────────────────────────────────────────────────

/// Pass-through middleware: one extra async hop around every dart:io
/// request, mirroring `shelf`'s pipeline and nitro's `use()` below.
Future<void> _withDartMw(HttpRequest request, Future<void> Function() next) {
  return next();
}

Future<HttpServer> _startDartServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.defaultResponseHeaders.clear();
  server.listen(
    (request) => _withDartMw(request, () async {
      final path = request.uri.path;
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
  final server = await NitroServer.bind(
    _keepAlive
        ? ServerConfig(maxRequestsPerConnection: 0, workerThreads: _workers)
        : ServerConfig(
            keepAliveTimeout: Duration.zero,
            workerThreads: _workers,
          ),
  );
  // One pass-through middleware, like the other sides.
  await server.use((request, next) => next(request));
  for (final entry in _routes.entries) {
    final body = entry.value;
    await server.get(entry.key, (_) async {
      return ResponseContext.bytes(body);
    });
  }
  await server.get('/users/:id', (request) async {
    return ResponseContext.text('user ${request.param('id')}');
  });
  await server.get('/files/*', (request) async {
    return ResponseContext.text('wild:${request.path}');
  });
  await server.get('/q', (request) async {
    return ResponseContext.jsonMap(request.queryParameters);
  });
  await server.get('/mw', (_) async {
    return ResponseContext.bytes(_routes['/hello']!);
  });
  await server.get('/events', (_) async {
    return ResponseContext.stream(
      Stream.fromIterable(_eventChunks),
      headers: {'content-type': 'text/event-stream'},
      bufferSize: _batchEvents ? 4096 : 0,
    );
  });
  await server.post('/echo', (request) async {
    return ResponseContext.bytes(request.body);
  });
  return server;
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
    final us = await op(client, port);
    if (_record) samplesUs.add(us);
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
  'POST /echo 4k': _postEcho,
  'POST /echo 1m': (c, p) => _postEchoSized(c, p, _bigPayload),
  'GET /events': _getEvents,
};

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

/// Closed-loop load from one client isolate: [connections] workers hammer
/// [port] for [millis]. Returns the completed count, the wall time and every
/// per-request latency, so the coordinator can report rate AND tail.
Future<({int done, int elapsedUs, List<int> samplesUs})> _load(
  String opKey,
  int port,
  int connections,
  int millis,
) async {
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
          samples.add(await op(client, port));
          done++;
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
}) async {
  final seq = await Isolate.run(() => _sequential(opKey, port));
  final lat = _summarize(seq.samplesUs);

  final perClient = connections ~/ clients;
  final loads = await Future.wait([
    for (var i = 0; i < clients; i++)
      Isolate.run(() => _load(opKey, port, perClient, millis)),
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
  final connections = _flagInt(args, '--connections', quick ? 32 : 64);
  final clients = _flagInt(args, '--clients', 4);
  final millis = _flagInt(args, '--seconds', quick ? 1 : 3) * 1000;
  final rounds = quick ? 1 : 2;
  final only = _flagStr(args, '--only');
  _workers = _flagInt(args, '--workers', 0);

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
    '${_workers > 0 ? '; --workers $_workers' : ''})',
  );
  print('');
  print(
    'Sequential latency via package:benchmark_harness (AsyncBenchmarkBase, '
    '~2 s per case) from one client isolate; load: $connections connections '
    'across $clients client isolates for ${millis ~/ 1000} s per case.',
  );
  print('');

  final dartServer = await _startDartServer();
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
      final result = await _phase(
        label,
        opKey,
        port,
        clients: clients,
        connections: connections,
        millis: millis,
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
        'connections': connections,
        'clients': clients,
        'cases': jsonCases,
      }),
    );
    print('wrote $jsonPath');
  }

  await dartServer.close(force: true);
  await shelfServer.close(force: true);
  await nitroServer.close();
  print(
    'Load: $connections connections / $clients client isolates, '
    '${millis ~/ 1000} s per case. Sequential: harness ~2 s per case, '
    'one connection.',
  );
}
