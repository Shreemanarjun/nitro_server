// Compares `dart:io HttpServer` vs `shelf` vs `nitro_server` on identical
// routes with an identical client methodology.
//
// Run (from the package root, after building the native library):
//
//   cmake -S src -B build/lib -DCMAKE_BUILD_TYPE=Release
//   cmake --build build/lib --parallel
//   dart run benchmark/compare.dart [--quick]
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

Future<void> _phase(
  String label,
  int port,
  Future<int> Function(HttpClient, int) op, {
  required int sequential,
  required int concurrency,
  required int concurrentTotal,
}) async {
  // Sequential latency.
  var client = HttpClient();
  final latencies = <int>[];
  for (var i = 0; i < sequential; i++) {
    latencies.add(await op(client, port));
  }
  client.close(force: true);
  final lat = _summarize(latencies);

  // Concurrent throughput.
  client = HttpClient()..maxConnectionsPerHost = concurrency * 2;
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

  print(
    '| $label | ${lat['mean']!.toStringAsFixed(0)} | '
    '${lat['p50']!.toStringAsFixed(0)} | ${lat['p99']!.toStringAsFixed(0)} | '
    '${rps.toStringAsFixed(0)} |',
  );
}

/// Unmeasured warmup: JIT-compiles the handlers and settles the client pools
/// so round one is not a compiler benchmark.
Future<void> _warmup(
  int port,
  Future<int> Function(HttpClient, int) op,
) async {
  final client = HttpClient();
  for (var i = 0; i < 200; i++) {
    await op(client, port);
  }
  client.close(force: true);
}

Future<void> main(List<String> args) async {
  final quick = args.contains('--quick');
  final sequential = quick ? 100 : 500;
  const concurrency = 32;
  final concurrentTotal = quick ? 800 : 4000;
  final rounds = quick ? 1 : 2;

  // Dart-only loading: Flutter apps skip this (the tooling bundles the
  // library); `dart run` needs the explicit open.
  final loadedFrom = loadNitroServerNative();
  print('nitro_server vs shelf vs dart:io HttpServer — same routes, same driver');
  print('(native library: $loadedFrom${quick ? '; --quick' : ''})');
  print('');
  print('| case | mean µs | p50 µs | p99 µs | req/s @32 |');
  print('| ---- | ------- | ------ | ------ | --------- |');

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

  for (final (_, op, port) in cases) {
    await _warmup(port, op);
  }

  // Interleaved A/B/C so machine drift cannot favor one side.
  for (var round = 0; round < rounds; round++) {
    for (final (label, op, port) in cases) {
      await _phase(
        label,
        port,
        op,
        sequential: sequential,
        concurrency: concurrency,
        concurrentTotal: concurrentTotal,
      );
    }
  }

  await dartServer.close(force: true);
  await shelfServer.close(force: true);
  await nitroServer.close();
  print('');
  print('Sequential: $sequential requests on one client (latency). '
      'Concurrent: $concurrentTotal requests across $concurrency workers '
      '(throughput). Warmup: 200 unmeasured requests per case.');
}
