// Nitro-only load driver: sustains the benchmark's exact client pattern
// (Connection: close, 32 concurrent workers) against nitro_server alone, so a
// profiler can sample the hot path without the dart:io/shelf phases mixed in.
//
//   dart run tool/perf/nitro_only.dart [seconds]
import 'dart:async';
import 'dart:io';

import 'package:nitro_server/nitro_server.dart';

Future<void> main(List<String> args) async {
  final seconds = args.isEmpty ? 15 : int.parse(args.first);
  loadNitroServerNative();
  final server = await NitroServer.bind(
    const ServerConfig(keepAliveTimeout: Duration.zero),
  );
  await server.route(HttpMethod.get, '/hello', (_) async {
    return ResponseContext.text('hello');
  });
  await server.route(HttpMethod.get, '/json', (_) async {
    return ResponseContext.json('{"ok":true,"n":1}');
  });
  print('LISTENING ${server.port}');

  final deadline = DateTime.now().add(Duration(seconds: seconds));
  var done = 0;
  final started = DateTime.now();
  await Future.wait(
    List.generate(32, (worker) async {
      while (DateTime.now().isBefore(deadline)) {
        final client = HttpClient();
        try {
          final request = await client.getUrl(
            Uri.parse('http://127.0.0.1:${server.port}/hello'),
          );
          final response = await request.close();
          await response.drain<void>();
          done++;
        } catch (_) {
          // Load loop: a dropped connection under saturation is not the point.
        } finally {
          client.close(force: true);
        }
      }
    }),
  );
  final elapsed = DateTime.now().difference(started);
  final rps = done / (elapsed.inMilliseconds / 1000);
  print(
    'DONE $done requests in ${elapsed.inMilliseconds}ms → '
    '${rps.toStringAsFixed(0)} req/s',
  );
  await server.close();
}
