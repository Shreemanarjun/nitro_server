/// ServerConfig.serverHeader and ServerConfig.keepAliveHeader on the wire,
/// against the real engine: defaults keep both, the switches remove them.
library;

import 'dart:convert';
import 'dart:io';

import 'package:nitro_server/nitro_server.dart';
import 'package:test/test.dart';

Future<String> rawHead(int port) async {
  final s = await Socket.connect('127.0.0.1', port);
  s.write('GET /h HTTP/1.1\r\nHost: x\r\n\r\n');
  final buf = StringBuffer();
  await for (final chunk in s.timeout(const Duration(seconds: 5))) {
    buf.write(latin1.decode(chunk));
    if (buf.toString().contains('\r\n\r\nok')) break;
  }
  s.destroy();
  return buf.toString();
}

void main() {
  test('defaults: x-server and Keep-Alive timeout are sent', () async {
    final server = await NitroServer.bind();
    await server.get('/h', (_) => ResponseContext.text('ok'));
    final head = await rawHead(server.port);
    await server.close();
    expect(head, contains('x-server: ${ServerDefaults.serverHeader}'));
    expect(head, contains('Keep-Alive: timeout=5'));
  });

  test('serverHeader: null and keepAliveHeader: false remove both', () async {
    final server = await NitroServer.bind(
      const ServerConfig(serverHeader: null, keepAliveHeader: false),
    );
    await server.get('/h', (_) => ResponseContext.text('ok'));
    final head = await rawHead(server.port);
    await server.close();
    expect(head.toLowerCase(), isNot(contains('x-server')));
    expect(head, isNot(contains('Keep-Alive:')));
    expect(head, contains('Connection: keep-alive'));
  });

  test('a custom serverHeader and copyWith', () async {
    const c = ServerConfig(serverHeader: 'acme');
    expect(c.copyWith(clearServerHeader: true).serverHeader, isNull);
    expect(c.copyWith(keepAliveHeader: false).keepAliveHeader, isFalse);
    final server = await NitroServer.bind(c);
    await server.get('/h', (_) => ResponseContext.text('ok'));
    final head = await rawHead(server.port);
    await server.close();
    expect(head, contains('x-server: acme'));
  });

  test('collectMetrics: false records nothing; default records', () async {
    for (final on in [true, false]) {
      final server = await NitroServer.bind(ServerConfig(collectMetrics: on));
      await server.get('/h', (_) => ResponseContext.text('ok'));
      await rawHead(server.port);
      final snap = server.metrics;
      await server.close();
      expect(snap.requests, on ? 1 : 0, reason: 'collectMetrics: $on');
    }
  });
}
