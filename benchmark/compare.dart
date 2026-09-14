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
// * Same machine, same loopback, interleaved phases (A/B/C/A/B/C) so a
//   thermal excursion cannot favor one side.
// * Warmup before measuring (JIT + connection pools settle), then reports
//   latency distributions AND throughput, never a single headline number.
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:benchmark_harness/benchmark_harness.dart';
import 'package:nitro_server/nitro_server.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

/// Routes served byte-identically by all servers.
final Map<String, Uint8List> _routes = {
  '/hello': Uint8List.fromList('hello world!'.codeUnits),
  '/json': Uint8List.fromList(
    jsonEncode({'id': 42, 'name': 'nitro', 'tags': ['a', 'b', 'c']}).codeUnits,
  ),
};

final Uint8List _echoPayload = Uint8List.fromList(
  List<int>.generate(4096, (i) => i & 0xff),
);

// ── Servers ──────────────────────────────────────────────────────────────────

Future<HttpServer> _startDartServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.defaultResponseHeaders.clear();
  server.listen((request) async {
    final path = request.uri.path;
    final response = request.response;
    response.headers.set('connection', 'close');
    try {
      if (request.method == 'POST' && path == '/echo') {
        final body = await request.fold<BytesBuilder>(
          BytesBuilder(),
          (b, d) => b..add(d),
        );
        response.headers.contentType = ContentType.binary;
        response.contentLength = body.length;
        response.add(body.toBytes());
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
  });
  return server;
}

Response _shelfHandler(Request request) {
  if (request.method == 'POST' && request.url.path == 'echo') {
    // Shelf reads the body asynchronously; the sync handler half below only
    // covers GETs, so POST is handled in [_startShelfServer]'s wrapper.
    throw StateError('unreachable');
  }
  final body = _routes['/${request.url.path}'];
  if (body == null) {
    return Response.notFound(
      'not found',
      headers: {'connection': 'close'},
    );
  }
  return Response.ok(
    body,
    headers: {'connection': 'close', 'content-type': 'text/plain'},
  );
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
          'connection': 'close',
          'content-type': 'application/octet-stream',
        },
      );
    }
    return _shelfHandler(request);
  }

  final server = await shelf_io.serve(
    handler,
    InternetAddress.loopbackIPv4,
    0,
  );
  server.defaultResponseHeaders.clear();
  return server;
}

Future<NitroServer> _startNitroServer() async {
  // `Duration.zero` disables keep-alive: every response carries
  // `Connection: close`, matching the dart:io and shelf servers below.
  // (The engine default enables keep-alive, which `HttpClient` pools — a
  // pooled reuse racing a server-side close measures pool luck, not servers.)
  final server = await NitroServer.bind(
    const ServerConfig(keepAliveTimeout: Duration.zero),
  );
  for (final entry in _routes.entries) {
    final body = entry.value;
    await server.get(entry.key, (_) async {
      return ResponseContext.bytes(body);
    });
  }
  await server.post('/echo', (request) async {
    return ResponseContext.bytes(request.body);
  });
  return server;
}

// ── Driver (identical for every server) ──────────────────────────────────────

/// One measured GET. Returns microseconds.
Future<int> _get(HttpClient client, int port, String path) async {
  final stopwatch = Stopwatch()..start();
  final request = await client.getUrl(Uri.parse('http://127.0.0.1:$port$path'));
  final response = await request.close();
  await response.drain<void>();
  stopwatch.stop();
  if (response.statusCode != 200) throw StateError('got ${response.statusCode}');
  return stopwatch.elapsedMicroseconds;
}

Future<int> _postEcho(HttpClient client, int port) async {
  final stopwatch = Stopwatch()..start();
  final request = await client.postUrl(Uri.parse('http://127.0.0.1:$port/echo'));
  request.add(_echoPayload);
  final response = await request.close();
  var received = 0;
  await for (final chunk in response) {
    received += chunk.length;
  }
  stopwatch.stop();
  if (response.statusCode != 200 || received != _echoPayload.length) {
    throw StateError('echo mismatch: ${response.statusCode}/$received');
  }
  return stopwatch.elapsedMicroseconds;
}

Map<String, double> _summarize(List<int> samplesUs) {
  final sorted = [...samplesUs]..sort();
  double pct(double p) =>
      sorted[(sorted.length * p).clamp(0, sorted.length - 1).toInt()].toDouble();
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

Future<String> _phase(
  String label,
  int port,
  Future<int> Function(HttpClient, int) op, {
  required int concurrency,
  required int concurrentTotal,
}) async {
  // Sequential latency, harnessed (`measure()` runs setup → 100 ms warmup →
  // ~2 s exercise → teardown; the client lives in setup/teardown, unmeasured).
  final benchmark = _RequestBenchmark(label, port, op);
  final meanUs = await benchmark.measure();
  final lat = _summarize(benchmark.samplesUs);

  // Concurrent throughput (custom sweep: the harness is single-shot only).
  final client = HttpClient()..maxConnectionsPerHost = concurrency * 2;
  final stopwatch = Stopwatch()..start();
  var remaining = concurrentTotal;
  await Future.wait([
    for (var w = 0; w < concurrency; w++)
      () async {
        while (true) {
          if (remaining-- <= 0) return;
          await op(client, port);
        }
      }(),
  ]);
  stopwatch.stop();
  client.close(force: true);
  final rps = concurrentTotal / stopwatch.elapsedMicroseconds * 1e6;

  // Standard harness line, then the table row.
  print('$label(RunTime): ${meanUs.toStringAsFixed(4)} us. '
      '(n=${benchmark.samplesUs.length})');
  return '| $label | ${meanUs.toStringAsFixed(0)} | '
      '${lat['p50']!.toStringAsFixed(0)} | ${lat['p99']!.toStringAsFixed(0)} | '
      '${rps.toStringAsFixed(0)} |';
}

Future<void> main(List<String> args) async {
  final quick = args.contains('--quick');
  const concurrency = 32;
  final concurrentTotal = quick ? 800 : 4000;
  final rounds = quick ? 1 : 2;

  // Dart-only loading: Flutter apps skip this (the tooling bundles the
  // library); `dart run` / the compiled exe needs the explicit open.
  // `NITRO_SERVER_DYLIB` or `--dylib <path>` overrides the search when the
  // compiled exe runs from a different working directory.
  String? dylibFlag;
  final dylibIdx = args.indexOf('--dylib');
  if (dylibIdx != -1 && dylibIdx + 1 < args.length) {
    dylibFlag = args[dylibIdx + 1];
  }
  final loadedFrom = loadNitroServerNative(path: dylibFlag);
  final mode = _vmMode();
  print('nitro_server vs shelf vs dart:io HttpServer — same routes, same driver');
  print('(mode: $mode; native library: $loadedFrom'
      '${quick ? '; --quick' : ''})');
  print('');
  print('Latency via package:benchmark_harness (AsyncBenchmarkBase, ~2 s '
      'exercise per case); throughput via a custom $concurrency-worker sweep.');
  print('');

  final dartServer = await _startDartServer();
  final shelfServer = await _startShelfServer();
  final nitroServer = await _startNitroServer();

  final cases = <(String, Future<int> Function(HttpClient, int), int)>[
    ('dart:io /hello', (c, p) => _get(c, p, '/hello'), dartServer.port),
    ('shelf   /hello', (c, p) => _get(c, p, '/hello'), shelfServer.port),
    ('nitro   /hello', (c, p) => _get(c, p, '/hello'), nitroServer.port),
    ('dart:io /json', (c, p) => _get(c, p, '/json'), dartServer.port),
    ('shelf   /json', (c, p) => _get(c, p, '/json'), shelfServer.port),
    ('nitro   /json', (c, p) => _get(c, p, '/json'), nitroServer.port),
    ('dart:io POST /echo 4k', _postEcho, dartServer.port),
    ('shelf   POST /echo 4k', _postEcho, shelfServer.port),
    ('nitro   POST /echo 4k', _postEcho, nitroServer.port),
  ];

  // Interleaved A/B/C so machine drift cannot favor one side.
  for (var round = 0; round < rounds; round++) {
    print('| case | mean µs | p50 µs | p99 µs | req/s @32 |');
    print('| ---- | ------- | ------ | ------ | --------- |');
    for (final (label, op, port) in cases) {
      print(await _phase(
        label,
        port,
        op,
        concurrency: concurrency,
        concurrentTotal: concurrentTotal,
      ));
    }
    print('');
  }

  await dartServer.close(force: true);
  await shelfServer.close(force: true);
  await nitroServer.close();
  print('Concurrent: $concurrentTotal requests across $concurrency workers '
      '(throughput). Sequential latency: harness 2 s exercise per case.');
}
