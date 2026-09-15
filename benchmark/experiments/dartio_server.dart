// dart:io HttpServer, shared:true across N isolates on one port — the same
// model the benchmark's dart:io side uses. Serves /hello. Prints the port.
import 'dart:io';
import 'dart:isolate';
Future<HttpServer> _bind(int port) async {
  final s = await HttpServer.bind(InternetAddress.loopbackIPv4, port, shared: true);
  s.defaultResponseHeaders.clear();
  s.listen((req) {
    final r = req.response;
    r.headers.contentType = ContentType.text;
    final body = 'hello';
    r.contentLength = body.length;
    r.write(body);
    r.close();
  });
  return s;
}
void _iso(int port) { _bind(port); }
Future<void> main(List<String> args) async {
  final n = args.isEmpty ? 4 : int.parse(args.first);
  final s = await _bind(0);
  final port = s.port;
  for (var i = 1; i < n; i++) {
    await Isolate.spawn(_iso, port);
  }
  print('LISTENING $port');
}
