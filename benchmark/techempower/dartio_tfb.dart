// TechEmpower-style TFB server — dart:io HttpServer. /json + /plaintext.
// One shared listener per core (SO_REUSEPORT via `shared: true`), keep-alive.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

final Uint8List _plaintext = Uint8List.fromList(utf8.encode('Hello, World!'));

Future<void> _serve(int port) async {
  final server = await HttpServer.bind(
    InternetAddress.loopbackIPv4,
    port,
    shared: true,
  );
  server.defaultResponseHeaders.clear();
  await for (final req in server) {
    final res = req.response;
    if (req.uri.path == '/plaintext') {
      res.headers.set(HttpHeaders.contentTypeHeader, 'text/plain');
      res.add(_plaintext);
    } else if (req.uri.path == '/json') {
      res.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      res.add(utf8.encode(jsonEncode({'message': 'Hello, World!'})));
    } else {
      res.statusCode = 404;
    }
    await res.close();
  }
}

Future<void> main() async {
  const port = 8080;
  final cores = Platform.numberOfProcessors;
  for (var i = 1; i < cores; i++) {
    await Isolate.spawn(_serve, port);
  }
  stdout.writeln('PORT $port');
  await _serve(port);
}
