/// Nightly soak: one server, four traffic kinds (keep-alive HTTP, WebSocket
/// echo, HTTP/2-capable chunked streaming, SSE) hammered concurrently for
/// `--seconds` (default 300), sampling the process RSS. Fails when RSS at the
/// end exceeds the RSS at the quarter mark by more than `--max-growth-percent`
/// (default 25) — a leak in any path shows as monotonic growth, a healthy
/// server plateaus. Also fails on any request/socket error.
///
///   dart run tool/soak.dart --seconds 120 --max-growth-percent 25
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nitro_server/nitro_server.dart';

Future<void> main(List<String> args) async {
  var seconds = 300;
  var maxGrowth = 25.0;
  for (var i = 0; i + 1 < args.length; i += 2) {
    if (args[i] == '--seconds') seconds = int.parse(args[i + 1]);
    if (args[i] == '--max-growth-percent') {
      maxGrowth = double.parse(args[i + 1]);
    }
  }
  final server = await NitroServer.bind(
    const ServerConfig(wsIdleTimeout: Duration(seconds: 30)),
  );
  await server.get('/hello', (_) => ResponseContext.text('hello'));
  await server.post('/echo', (r) => ResponseContext.bytes(r.body));
  await server.get(
    '/stream',
    (_) => ResponseContext.stream(
      Stream<Uint8List>.fromIterable(
        List.generate(20, (i) => Uint8List.fromList(utf8.encode('chunk $i\n'))),
      ),
    ),
  );
  await server.get(
    '/events',
    (_) => ResponseContext.sse(
      Stream<SseEvent>.fromIterable(
        List.generate(5, (i) => SseEvent('tick $i')),
      ),
    ),
  );
  await server.ws('/ws', (session) async {
    await for (final m in session.messages) {
      if (m is WsText) session.sendText(m.text);
    }
  });
  final port = server.port;
  final errors = <String>[];
  var requests = 0;
  final stop = DateTime.now().add(Duration(seconds: seconds));

  Future<void> httpLoop(String path, {List<int>? body}) async {
    final client = HttpClient();
    try {
      while (DateTime.now().isBefore(stop)) {
        try {
          final req = await client.openUrl(
            body == null ? 'GET' : 'POST',
            Uri.parse('http://127.0.0.1:$port$path'),
          );
          if (body != null) req.add(body);
          final res = await req.close();
          await res.drain<void>();
          if (res.statusCode != 200) errors.add('$path -> ${res.statusCode}');
          requests++;
        } catch (e) {
          errors.add('$path: $e');
          if (errors.length > 50) return;
        }
      }
    } finally {
      client.close(force: true);
    }
  }

  Future<void> wsLoop() async {
    while (DateTime.now().isBefore(stop)) {
      try {
        final ws = await WebSocket.connect('ws://127.0.0.1:$port/ws');
        final replies = StreamIterator<dynamic>(ws);
        for (var i = 0; i < 50 && DateTime.now().isBefore(stop); i++) {
          ws.add('ping $i');
          final got = await replies.moveNext().timeout(
            const Duration(seconds: 5),
          );
          if (!got || replies.current != 'ping $i') {
            errors.add('ws echo mismatch');
          }
          requests++;
        }
        await replies.cancel();
        await ws.close();
      } catch (e) {
        errors.add('ws: $e');
        if (errors.length > 50) return;
      }
    }
  }

  final samples = <int>[];
  final sampler = Timer.periodic(const Duration(seconds: 5), (_) {
    samples.add(ProcessInfo.currentRss);
    stdout.writeln(
      '[soak] t+${samples.length * 5}s rss=${(samples.last / 1e6).toStringAsFixed(1)}MB '
      'requests=$requests errors=${errors.length} conns=${server.liveConnections}',
    );
  });
  await Future.wait([
    for (var i = 0; i < 4; i++) httpLoop('/hello'),
    for (var i = 0; i < 2; i++) httpLoop('/echo', body: List.filled(4096, 65)),
    for (var i = 0; i < 2; i++) httpLoop('/stream'),
    httpLoop('/events'),
    for (var i = 0; i < 2; i++) wsLoop(),
  ]);
  sampler.cancel();
  await server.close();
  if (samples.length < 4) {
    stderr.writeln('[soak] too short to judge (< 20 s)');
    exit(2);
  }
  final quarter = samples[samples.length ~/ 4];
  final last = samples.last;
  final growth = (last - quarter) / quarter * 100;
  stdout.writeln(
    '[soak] requests=$requests errors=${errors.length} '
    'rss quarter=${(quarter / 1e6).toStringAsFixed(1)}MB '
    'end=${(last / 1e6).toStringAsFixed(1)}MB growth=${growth.toStringAsFixed(1)}%',
  );
  for (final e in errors.take(10)) {
    stderr.writeln('[soak] error: $e');
  }
  if (errors.isNotEmpty || growth > maxGrowth) exit(1);
}
