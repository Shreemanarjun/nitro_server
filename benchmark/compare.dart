// Compares `dart:io HttpServer` against `nitro_server` on identical routes
// with an identical client methodology.
//
// Run (from the package root, after building the native library):
//
//   cmake -S src -B build/lib -DCMAKE_BUILD_TYPE=Release
//   cmake --build build/lib --parallel
//   dart run benchmark/compare.dart
//
// Fairness rules, stated so the numbers stay honest:
// * Same three routes on both servers, same response bytes.
// * Same driver: one `HttpClient` per phase, `Connection: close` semantics
//   on both sides (nitro_server always closes; the dart:io server is
//   configured to close too), so neither side benefits from keep-alive.
// * Same machine, same loopback, interleaved phases (A/B/A/B) so a thermal
//   excursion cannot favor one side.
// * Reports latency distributions AND throughput, never a single headline
//   number. The number worth publishing is the Dart↔native round-trip under
//   load (the `/hello` p99 and the concurrency sweep), not a hello-world max.
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:nitro_server/nitro_server.dart';

/// Routes served byte-identically by both servers.
final Map<String, Uint8List> _routes = {
  '/hello': Uint8List.fromList('hello world!'.codeUnits),
  '/json': Uint8List.fromList(
    jsonEncode({'id': 42, 'name': 'nitro', 'tags': ['a', 'b', 'c']}).codeUnits,
  ),
};

final Uint8List _echoPayload = Uint8List.fromList(
  List<int>.generate(4096, (i) => i & 0xff),
);

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

Future<NitroServer> _startNitroServer() async {
  final server = await NitroServer.bind();
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
  double pct(double p) => sorted[(sorted.length * p).clamp(0, sorted.length - 1).toInt()].toDouble();
  final mean = sorted.reduce((a, b) => a + b) / sorted.length;
  return {'mean': mean, 'p50': pct(0.5), 'p99': pct(0.99)};
}

Future<void> _phase(
  String label,
  int port,
  Future<int> Function(HttpClient, int) op, {
  int sequential = 500,
  int concurrency = 32,
  int concurrentTotal = 4000,
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

void _loadNative() {
  final script = Platform.script.toFilePath();
  final root = script.substring(0, script.indexOf('/benchmark/'));
  final candidates = [
    if (Platform.isMacOS) '$root/build/lib/libnitro_server.dylib',
    if (Platform.isLinux) '$root/build/lib/libnitro_server.so',
    if (Platform.isWindows) '$root\\build\\lib\\nitro_server.dll',
  ];
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) {
      DynamicLibrary.open(candidate);
      return;
    }
  }
  stderr.writeln(
    'Native library not found. Build it first:\n'
    '  cmake -S src -B build/lib -DCMAKE_BUILD_TYPE=Release\n'
    '  cmake --build build/lib --parallel',
  );
  exit(2);
}

Future<void> main() async {
  _loadNative();
  print('nitro_server vs dart:io HttpServer — same routes, same driver');
  print('');
  print('| case | mean µs | p50 µs | p99 µs | req/s @32 |');
  print('| ---- | ------- | ------ | ------ | --------- |');

  final dartServer = await _startDartServer();
  final nitroServer = await _startNitroServer();

  // Interleaved A/B so machine drift cannot favor one side.
  for (var round = 0; round < 2; round++) {
    await _phase('dart:io /hello', dartServer.port, (c, p) => _get(c, p, '/hello'));
    await _phase('nitro   /hello', nitroServer.port, (c, p) => _get(c, p, '/hello'));
  }
  for (var round = 0; round < 2; round++) {
    await _phase('dart:io POST /echo 4k', dartServer.port, _postEcho);
    await _phase('nitro   POST /echo 4k', nitroServer.port, _postEcho);
  }

  await dartServer.close(force: true);
  await nitroServer.close();
  print('');
  print('Sequential: 500 requests on one client (latency). '
      'Concurrent: 4000 requests across 32 workers (throughput).');
}
