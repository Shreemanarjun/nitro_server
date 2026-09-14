import 'dart:convert';
import 'dart:io';
Future<void> main() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    req.response.headers.set('connection', 'keep-alive');
    req.response.write('hi');
    await req.response.close();
  });
  for (final useFirst in [true, false]) {
    final socket = await Socket.connect('127.0.0.1', server.port);
    socket.add(ascii.encode('GET /h HTTP/1.1\r\nHost: x\r\n\r\n'));
    if (useFirst) {
      final first = await socket.first.timeout(const Duration(seconds: 5));
      print('first-mode got ${first.length} bytes');
    } else {
      final sub = socket.listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await sub.cancel();
      print('listen-mode waited');
    }
    // Server closes idle keep-alive after its default timeout; force-close from server side:
    await Future<void>.delayed(const Duration(milliseconds: 100));
    socket.destroy();
    print('useFirst=$useFirst done (destroyed client-side)');
  }
  await server.close(force: true);
}
