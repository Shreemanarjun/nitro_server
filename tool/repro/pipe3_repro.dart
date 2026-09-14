import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:nitro_server/nitro_server.dart';

// Exact mirror of the conformance test's readResponses.
Future<List<Uint8List>> readResponses(Socket socket, int count) async {
  final buffer = <int>[];
  final responses = <Uint8List>[];
  final done = Completer<void>();
  socket.listen(buffer.addAll, onDone: done.complete, onError: done.completeError);
  int headEnd(List<int> bytes) {
    for (var i = 0; i + 3 < bytes.length; i++) {
      if (bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10) return i;
    }
    return -1;
  }
  while (responses.length < count) {
    int end = headEnd(buffer);
    while (end < 0) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      if (done.isCompleted) throw StateError('CLOSED got=${responses.length} buf=${buffer.length} bytes=${buffer}');
      end = headEnd(buffer);
    }
    final head = ascii.decode(buffer.sublist(0, end));
    var contentLength = 0;
    for (final line in head.split('\r\n').skip(1)) {
      final colon = line.indexOf(':');
      if (colon > 0 && line.substring(0, colon).trim().toLowerCase() == 'content-length') {
        contentLength = int.parse(line.substring(colon + 1).trim());
      }
    }
    final total = end + 4 + contentLength;
    while (buffer.length < total) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      if (done.isCompleted && buffer.length < total) throw StateError('connection closed mid-body');
    }
    responses.add(Uint8List.fromList(buffer.sublist(0, total)));
    buffer.removeRange(0, total);
  }
  return responses;
}

Future<void> main() async {
  loadNitroServerNative();
  final server = await NitroServer.bind();
  await server.route(HttpMethod.all, '/methods', (request) async {
    return ResponseContext.json(jsonEncode({'method': 'GET', 'bodyLength': request.body.length}));
  });
  await server.route(HttpMethod.get, '/binary/:n', (request) async {
    final n = int.parse(request.param('n')!);
    return ResponseContext.bytes(Uint8List.fromList(List<int>.generate(n, (i) => i & 0xff)));
  });
  for (var round = 0; round < 3; round++) {
    var socket = await Socket.connect('127.0.0.1', server.port);
    try {
      socket.add(ascii.encode('GET /methods HTTP/1.1\r\nHost: x\r\n\r\n'));
      socket.add(ascii.encode('GET /binary/16 HTTP/1.1\r\nHost: x\r\n\r\n'));
      final r = await readResponses(socket, 2).timeout(const Duration(seconds: 10));
      print('round $round sequential: ${r.length} responses OK');
    } finally {
      socket.destroy();
    }
    socket = await Socket.connect('127.0.0.1', server.port);
    try {
      socket.add(ascii.encode(
        'GET /methods HTTP/1.1\r\nHost: x\r\n\r\n'
        'GET /methods HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
      ));
      final r = await readResponses(socket, 2).timeout(const Duration(seconds: 10));
      print('round $round pipelined: ${r.length} responses OK');
    } catch (e) {
      print('round $round PIPELINED FAILED: $e');
    } finally {
      socket.destroy();
    }
  }
  await server.close();
}
