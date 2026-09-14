import 'dart:convert';
import 'dart:io';
import 'package:nitro_server/nitro_server.dart';
Future<void> main() async {
  loadNitroServerNative();
  final server = await NitroServer.bind(
    const ServerConfig(keepAliveTimeout: Duration(milliseconds: 250)),
  );
  await server.route(HttpMethod.get, '/h', (_) async => ResponseContext.text('hi'));
  print('PORT=${server.port} PID=$pid');
  final socket = await Socket.connect('127.0.0.1', server.port);
  socket.add(ascii.encode('GET /h HTTP/1.1\r\nHost: x\r\n\r\n'));
  final first = await socket.first.timeout(const Duration(seconds: 5));
  print('RESP OK ${first.length}b, waiting 3s for server close...');
  await Future<void>.delayed(const Duration(seconds: 3));
  print('STILL HERE (check lsof now)');
  await Future<void>.delayed(const Duration(seconds: 4));
  socket.destroy();
  await server.close();
}
