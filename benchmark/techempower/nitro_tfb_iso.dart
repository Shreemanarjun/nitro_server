// Param isolate-count variant of nitro_tfb for the scaling spike.
// argv[0] = isolate count (default cores). Everything else identical to nitro_tfb.
import 'dart:io';

import 'package:nitro_server/nitro_server.dart';

// CPU-heavy per request: ~tens of µs of pure Dart compute so the isolate thread
// (not the engine) is the bottleneck — the one case where isolates>1 could win.
int _burn() {
  var x = 0;
  for (var i = 0; i < 200000; i++) {
    x = (x + i) ^ (x << 1);
  }
  return x;
}

Future<void> _setup(NitroServer server) async {
  await server.get(
    '/json',
    (_) => ResponseContext.jsonBody({'message': 'Hello, World!'}),
  );
  await server.get('/plaintext', (_) => ResponseContext.text('Hello, World!'));
  await server.get('/work', (_) => ResponseContext.jsonBody({'r': _burn()}));
}

Future<void> main(List<String> args) async {
  loadNitroServerNative();
  final cores = Platform.numberOfProcessors;
  final iso = args.isNotEmpty ? int.parse(args[0]) : cores;
  final wt = args.length > 1 ? int.parse(args[1]) : 0;
  final server = await NitroServer.bind(
    ServerConfig(
      port: 8080,
      isolates: iso,
      workerThreads: wt,
      maxRequestsPerConnection: 0,
    ),
    _setup,
  );
  stdout.writeln('PORT ${server.port} ISO $iso WT $wt');
  await ProcessSignal.sigterm.watch().first;
  await server.close();
}
