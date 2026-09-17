// TechEmpower-style TFB server — shelf (shelf_io). /json + /plaintext.
// One shared listener per core, keep-alive.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

Response _handler(Request req) {
  switch (req.url.path) {
    case 'plaintext':
      return Response.ok(
        'Hello, World!',
        headers: const {'content-type': 'text/plain'},
      );
    case 'json':
      return Response.ok(
        jsonEncode({'message': 'Hello, World!'}),
        headers: const {'content-type': 'application/json'},
      );
    default:
      return Response.notFound('');
  }
}

Future<void> _serve(int port) async {
  await shelf_io.serve(
    _handler,
    InternetAddress.loopbackIPv4,
    port,
    shared: true,
  );
}

Future<void> main() async {
  const port = 8080;
  final cores = Platform.numberOfProcessors;
  for (var i = 1; i < cores; i++) {
    await Isolate.spawn(_serve, port);
  }
  await _serve(port);
  stdout.writeln('PORT $port');
}
