import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:nitro_server/nitro_server.dart';

/// Single-subscription response reader over a raw socket.
class Conn {
  Conn(this.s) {
    s.listen(_onData, onDone: () => _done.complete());
  }
  final Socket s;
  final buf = BytesBuilder(copy: false);
  final _done = Completer<void>();
  final _waiters = <Completer<String>>[];
  void _onData(List<int> c) {
    buf.add(c);
    _pump();
  }
  void _pump() {
    while (_waiters.isNotEmpty) {
      final bytes = buf.toBytes();
      final text = ascii.decode(bytes, allowInvalid: true);
      final hi = text.indexOf('\r\n\r\n');
      if (hi == -1) return;
      final m = RegExp(r'Content-Length:\s*(\d+)', caseSensitive: false).firstMatch(text);
      final cl = m == null ? 0 : int.parse(m.group(1)!);
      if (bytes.length < hi + 4 + cl) return;
      buf.clear();
      if (bytes.length > hi + 4 + cl) {
        buf.add(bytes.sublist(hi + 4 + cl));
      }
      _waiters.removeAt(0).complete(text.substring(0, bytes.length < hi + 4 + cl ? text.length : hi));
    }
  }
  Future<String> next() {
    final c = Completer<String>();
    _waiters.add(c);
    _pump();
    return c.future.timeout(const Duration(seconds: 5));
  }
  Future<void> get closed => _done.future;
}

Future<void> main() async {
  loadNitroServerNative();
  final server = await NitroServer.bind(
    const ServerConfig(keepAliveTimeout: Duration(milliseconds: 250)),
  );
  await server.route(HttpMethod.get, '/h', (_) async => ResponseContext.text('hi'));
  final socket = await Socket.connect('127.0.0.1', server.port);
  final conn = Conn(socket);
  socket.add(ascii.encode('GET /h HTTP/1.1\r\nHost: x\r\n\r\n'));
  print('R1: ${(await conn.next()).split('\r\n').first}');
  await Future<void>.delayed(const Duration(milliseconds: 100));
  socket.add(ascii.encode('GET /h HTTP/1.1\r\nHost: x\r\n\r\n'));
  try {
    print('R2: ${(await conn.next()).split('\r\n').first}');
  } catch (e) {
    print('R2 FAILED: $e');
  }
  try {
    final s2 = await Socket.connect('127.0.0.1', server.port);
    final c2 = Conn(s2);
    s2.add(ascii.encode('GET /h HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n'));
    print('R3(new conn): ${(await c2.next()).split('\r\n').first}');
    s2.destroy();
  } catch (e) {
    print('R3 FAILED: $e');
  }
  try {
    await conn.closed.timeout(const Duration(seconds: 2));
    print('IDLE CLOSED OK');
  } catch (e) {
    print('IDLE NOT CLOSED');
  }
  socket.destroy();
  await server.close();
}
