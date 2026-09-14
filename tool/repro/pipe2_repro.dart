import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:nitro_server/nitro_server.dart';

class Conn {
  Conn(this.s) {
    s.listen(_onData, onDone: () => _done.complete(), onError: _done.completeError);
  }
  final Socket s;
  final buf = BytesBuilder(copy: false);
  final _done = Completer<void>();
  final _waiters = <Completer<String>>[];
  void _onData(List<int> c) { buf.add(c); _pump(); }
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
}

Future<void> main() async {
  loadNitroServerNative();
  final server = await NitroServer.bind();
  await server.route(HttpMethod.all, '/methods', (request) async {
    return ResponseContext.json(jsonEncode({'method': 'GET'}));
  });
  await server.route(HttpMethod.get, '/binary/:n', (request) async {
    final n = int.parse(request.param('n')!);
    return ResponseContext.bytes(Uint8List.fromList(List<int>.generate(n, (i) => i & 0xff)));
  });
  // Sequential test replica.
  var socket = await Socket.connect('127.0.0.1', server.port);
  var conn = Conn(socket);
  socket.add(ascii.encode('GET /methods HTTP/1.1\r\nHost: x\r\n\r\n'));
  socket.add(ascii.encode('GET /binary/16 HTTP/1.1\r\nHost: x\r\n\r\n'));
  print('S1: ${(await conn.next()).split('\r\n').first}');
  print('S2: ${(await conn.next()).split('\r\n').first}');
  socket.destroy();
  await Future<void>.delayed(const Duration(milliseconds: 200));
  // Pipelined test replica.
  socket = await Socket.connect('127.0.0.1', server.port);
  conn = Conn(socket);
  socket.add(ascii.encode(
    'GET /methods HTTP/1.1\r\nHost: x\r\n\r\n'
    'GET /methods HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
  ));
  try {
    print('P1: ${(await conn.next()).split('\r\n').first}');
    print('P2: ${(await conn.next()).split('\r\n').first}');
  } catch (e) {
    print('PIPELINED FAILED: $e');
  }
  socket.destroy();
  await server.close();
}
