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
  final first = await socket.first.timeout(const Duration(seconds: 5));
  print('RESP: ${ascii.decode(first).split('\r\n').first}');
  try {
    await socket.done.timeout(const Duration(seconds: 3));
    print('CLOSED OK');
  } catch (e) {
    print('NOT CLOSED');
  }
  socket.destroy();
  await server.close();
}
