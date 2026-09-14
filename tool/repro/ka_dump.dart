import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:nitro_server/nitro_server.dart';
Future<void> main() async {
  loadNitroServerNative();
  final server = await NitroServer.bind(
    const ServerConfig(keepAliveTimeout: Duration(milliseconds: 250)),
  );
  await server.route(HttpMethod.get, '/h', (_) async => ResponseContext.text('hi'));
  final socket = await Socket.connect('127.0.0.1', server.port);
  socket.add(ascii.encode('GET /h HTTP/1.1\r\nHost: x\r\n\r\n'));
  final buf = BytesBuilder(copy: false);
  final c = Completer<void>();
  late StreamSubscription sub;
  sub = socket.listen((chunk) {
    buf.add(chunk);
    final text = ascii.decode(buf.toBytes(), allowInvalid: true);
    if (text.contains('\r\n\r\n')) {
      if (!c.isCompleted) c.complete();
    }
  }, onDone: () => print('SOCKET DONE (closed by server)'), onError: (e) => print('SOCK ERR $e'));
  await c.future.timeout(const Duration(seconds: 5));
  final text = ascii.decode(buf.toBytes());
  print('FULL RESP: ${text.replaceAll('\r\n', '|')}');
  print('--- waiting for idle close 3s ---');
  // keep listening, check done
  var closed = false;
  socket.done.then((_) { closed = true; print('DONE future completed'); });
  await Future<void>.delayed(const Duration(seconds: 3));
  print('closed=$closed');
  // try second request on same conn
  print('sending 2nd request...');
  socket.add(ascii.encode('GET /h HTTP/1.1\r\nHost: x\r\n\r\n'));
  await Future<void>.delayed(const Duration(milliseconds: 500));
  final text2 = ascii.decode(buf.toBytes());
  print('BUF AFTER 2nd: ${text2.replaceAll('\r\n', '|')}');
  print('closed after 2nd wait=$closed');
  await sub.cancel();
  socket.destroy();
  await server.close();
}
