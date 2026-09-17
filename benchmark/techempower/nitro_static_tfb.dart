// TFB server — nitro_server, ENGINE-SERVED variant. Same /json + /plaintext
// bytes, but registered with `getStatic`: the native reactor answers them on
// its own thread with zero Dart dispatch (no per-request FFI round-trip). This
// is nitro's path to Go/Node throughput for cacheable responses. Contrast with
// nitro_tfb.dart, which runs a Dart handler per request.
import 'dart:convert';
import 'dart:io';

import 'package:nitro_server/nitro_server.dart';

Future<void> _setup(NitroServer server) async {
  await server.getStatic(
    '/json',
    utf8.encode('{"message":"Hello, World!"}'),
    contentType: 'application/json',
  );
  await server.getStatic(
    '/plaintext',
    utf8.encode('Hello, World!'),
    contentType: 'text/plain',
  );
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
