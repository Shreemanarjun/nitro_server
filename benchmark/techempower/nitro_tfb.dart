// TechEmpower-style TFB server — nitro_server. Standard endpoints:
//   GET /json      -> application/json  {"message":"Hello, World!"}  (serialized per request)
//   GET /plaintext -> text/plain        Hello, World!
// Multi-isolate (one per core), keep-alive, no per-connection request cap.
// Prints "PORT <n>" once listening; the runner (run.sh) reads it.
import 'dart:io';

import 'package:nitro_server/nitro_server.dart';

Future<void> _setup(NitroServer server) async {
  await server.get(
    '/json',
    (_) => ResponseContext.jsonBody({'message': 'Hello, World!'}),
  );
  await server.get('/plaintext', (_) => ResponseContext.text('Hello, World!'));
}

Future<void> main() async {
  loadNitroServerNative();
  final cores = Platform.numberOfProcessors;
  final server = await NitroServer.bind(
    ServerConfig(port: 8080, isolates: cores, maxRequestsPerConnection: 0),
    _setup,
  );
  stdout.writeln('PORT ${server.port}');
  await ProcessSignal.sigterm.watch().first;
  await server.close();
}
