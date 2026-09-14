import 'dart:convert';
import 'dart:io';
Future<void> main() async {
  // Control: stock dart:io server that closes idle keep-alive quickly.
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.idleTimeout = const Duration(milliseconds: 250);
  server.listen((req) async {
    req.response.headers.set('connection', 'keep-alive');
    req.response.write('hi');
    await req.response.close();
  });
  final socket = await Socket.connect('127.0.0.1', server.port);
  socket.add(ascii.encode('GET /h HTTP/1.1\r\nHost: x\r\n\r\n'));
  final first = await socket.first.timeout(const Duration(seconds: 5));
  print('RESP OK ${first.length}b');
  try {
    await socket.done.timeout(const Duration(seconds: 3));
    print('CTRL CLOSED OK');
  } catch (_) {
    print('CTRL NOT CLOSED');
  }
  socket.destroy();
  await server.close(force: true);
}
