import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:nitro_server/nitro_server.dart';

class Conn {
  Conn(this.s) {
    s.listen(_onData, onDone: () => _done.complete(), onError: _done.completeError);
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
      if (bytes.length > hi + 4 + cl) buf.add(bytes.sublist(hi + 4 + cl));
      _waiters.removeAt(0).complete(text);
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
  final server = await NitroServer.bind();
  await server.route(HttpMethod.all, '/methods', (request) async {
    return ResponseContext.text('m:${request.path}');
  });
  final socket = await Socket.connect('127.0.0.1', server.port);
  final conn = Conn(socket);
  socket.add(ascii.encode(
    'GET /methods HTTP/1.1\r\nHost: x\r\n\r\n'
    'GET /methods HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
  ));
  try {
    final r1 = await conn.next();
    print('R1: ${r1.split('\r\n').first} conn=${RegExp(r'Connection:\s*(\S+)', caseSensitive: false).firstMatch(r1)?.group(1)}');
    final r2 = await conn.next();
    print('R2: ${r2.split('\r\n').first} conn=${RegExp(r'Connection:\s*(\S+)', caseSensitive: false).firstMatch(r2)?.group(1)}');
  } catch (e) {
    print('FAILED: $e');
  }
  socket.destroy();
  await server.close();
}
