// HTTP conformance: the production-readiness matrix.
//
// Where `nitro_http` proves itself against `http_client_conformance_tests`,
// the server proves itself against the RFCs directly — there is no standard
// Dart server-conformance package, so this file IS the suite. Each group pins
// one wire behavior (RFC 9110 semantics, RFC 9112 framing) with byte-level
// assertions through raw sockets wherever `HttpClient` would normalize the
// evidence away.
//
// Native-gated like `server_e2e_test.dart`: skipped without the built dylib,
// `NITRO_SERVER_DYLIB` overrides the path.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:nitro_server/nitro_server.dart';
import 'package:nitro_server/src/internal/instance_keys.dart';
import 'package:nitro_server/src/internal/native_attach.dart';

String? _locateLibrary() {
  final override = Platform.environment['NITRO_SERVER_DYLIB'];
  if (override != null && File(override).existsSync()) return override;
  final names = <String>[
    if (Platform.isMacOS) 'libnitro_server.dylib',
    if (Platform.isLinux) 'libnitro_server.so',
    if (Platform.isWindows) 'nitro_server.dll',
  ];
  const roots = <String>['build/lib', 'build'];
  for (final root in roots) {
    for (final name in names) {
      final candidate = File('$root/$name');
      if (candidate.existsSync()) return candidate.absolute.path;
    }
  }
  return null;
}

/// FNV-1a 32-bit: integrity without a crypto dependency.
int _fnv(List<int> bytes) {
  var hash = 0x811c9dc5;
  for (final byte in bytes) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash;
}

Uint8List _patternBytes(int n) {
  final out = Uint8List(n);
  var state = 0x12345678;
  for (var i = 0; i < n; i++) {
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    out[i] = (state >> 16) & 0xff;
  }
  return out;
}

/// One raw connection: write [request], read until close. Returns the raw
/// response bytes — status line, headers and body unnormalized.
Future<Uint8List> _raw(int port, List<int> request) async {
  final socket = await Socket.connect('127.0.0.1', port);
  try {
    socket.add(request);
    final builder = BytesBuilder(copy: false);
    await for (final chunk in socket) {
      builder.add(chunk);
    }
    return builder.toBytes();
  } finally {
    socket.destroy();
  }
}

/// Byte offset of the `\r\n\r\n` that ends the head. Heads are ASCII by
/// construction; bodies may be arbitrary bytes, so nothing here decodes the
/// full response.
int _headEnd(Uint8List response) {
  for (var i = 0; i + 3 < response.length; i++) {
    if (response[i] == 13 &&
        response[i + 1] == 10 &&
        response[i + 2] == 13 &&
        response[i + 3] == 10) {
      return i;
    }
  }
  throw StateError('no head terminator in ${response.length} bytes');
}

int _statusOf(Uint8List response) {
  final head = ascii.decode(response.sublist(0, response.indexOf(13)));
  return int.parse(head.split(' ')[1]);
}

Uint8List _bodyOf(Uint8List response) {
  return response.sublist(_headEnd(response) + 4);
}

String _headerOf(Uint8List response, String name) {
  final text = ascii.decode(response.sublist(0, _headEnd(response)));
  final head = text;
  for (final line in head.split('\r\n').skip(1)) {
    final colon = line.indexOf(':');
    if (colon > 0 && line.substring(0, colon).trim().toLowerCase() == name) {
      return line.substring(colon + 1).trim();
    }
  }
  return '';
}

Future<Uint8List> _clientBody(
  int port,
  String method,
  String path, {
  Map<String, String>? headers,
  List<int>? body,
  int? expectStatus,
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:$port$path'),
    );
    headers?.forEach(request.headers.set);
    if (body != null) request.add(body);
    final response = await request.close().timeout(
      const Duration(seconds: 20),
    );
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    if (expectStatus != null) {
      expect(response.statusCode, expectStatus, reason: '$method $path');
    }
    return builder.toBytes();
  } finally {
    client.close(force: true);
  }
}

void main() {
  final libraryPath = _locateLibrary();
  final skipReason = libraryPath == null
      ? 'native library not built — run: cmake -S src -B build/lib && '
            'cmake --build build/lib --parallel'
      : null;

  group('conformance', () {
    setUpAll(() {
      if (libraryPath == null) return;
      DynamicLibrary.open(libraryPath);
      resetNativeAttachForTesting();
      Ids.resetForTesting();
    });

    late NitroServer server;
    late int port;

    setUpAll(() async {
      if (libraryPath == null) return;
      server = await NitroServer.bind();
      port = server.port;

      server.route(HttpMethod.all, '/methods', (request) async {
        final method = request.method == HttpMethod.custom
            ? request.customMethod
            : request.method.token;
        return ResponseContext.json(
          jsonEncode({'method': method, 'bodyLength': request.body.length}),
        );
      });
      server.route(HttpMethod.get, '/status/:code', (request) async {
        final code = int.parse(request.param('code')!);
        return ResponseContext(
          status: code,
          headers: const {'x-code': 'yes'},
          body: Uint8List.fromList('code $code'.codeUnits),
        );
      });
      server.route(
        HttpMethod.get,
        '/head-test',
        (_) async => ResponseContext.text('twelve bytes'),
      );
      server.route(
        HttpMethod.head,
        '/head-test',
        (_) async => ResponseContext.text('twelve bytes'),
      );
      server.route(HttpMethod.get, '/headers', (request) async {
        return ResponseContext.json(jsonEncode(request.headers));
      });
      server.route(HttpMethod.get, '/query', (request) async {
        return ResponseContext.json(
          jsonEncode({
            'query': request.query,
            'params': request.queryParameters,
          }),
        );
      });
      server.route(HttpMethod.post, '/upload', (request) async {
        return ResponseContext.json(
          jsonEncode({'length': request.body.length, 'fnv': _fnv(request.body)}),
        );
      });
      server.route(HttpMethod.get, '/binary/:n', (request) async {
        final n = int.parse(request.param('n')!);
        return ResponseContext.bytes(_patternBytes(n));
      });
      server.route(
        HttpMethod.custom,
        '/cache',
        (_) async => ResponseContext.text('purged'),
        customMethod: 'PURGE',
      );
      server.route(
        HttpMethod.get,
        '/wild/*',
        (request) async => ResponseContext.text('wild:${request.path}'),
      );
      server.route(
        HttpMethod.get,
        '/empty',
        (_) async => const ResponseContext(status: 204),
      );
    });

    tearDownAll(() async {
      if (libraryPath == null) return;
      await server.close();
    });

    group('methods (RFC 9110 §9)', () {
      test('every standard verb reaches its handler', () async {
        for (final verb in [
          'GET',
          'POST',
          'PUT',
          'DELETE',
          'PATCH',
          'HEAD',
          'OPTIONS',
        ]) {
          // HEAD answers through the /head-test route; the rest via /methods.
          final path = verb == 'HEAD' ? '/head-test' : '/methods';
          final body = await _clientBody(port, verb, path);
          if (verb == 'HEAD') {
            expect(body, isEmpty, reason: 'HEAD must carry no body');
          } else {
            final decoded = jsonDecode(utf8.decode(body));
            expect(decoded['method'], verb);
          }
        }
      }, skip: skipReason);

      test('custom methods round-trip their token', () async {
        final raw = await _raw(
          port,
          ascii.encode('PURGE /cache HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n'),
        );
        expect(_statusOf(raw), 200);
        expect(utf8.decode(_bodyOf(raw)), 'purged');
      }, skip: skipReason);
    });

    group('status codes (RFC 9110 §15)', () {
      test('arbitrary statuses pass through untouched', () async {
        for (final code in [200, 201, 204, 400, 404, 500]) {
          final raw = await _raw(
            port,
            ascii.encode(
              'GET /status/$code HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
            ),
          );
          expect(_statusOf(raw), code);
          expect(_headerOf(raw, 'x-code'), 'yes');
        }
      }, skip: skipReason);

      test('204 carries no body bytes', () async {
        final raw = await _raw(
          port,
          ascii.encode(
            'GET /empty HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
          ),
        );
        expect(_statusOf(raw), 204);
        expect(_bodyOf(raw), isEmpty);
      }, skip: skipReason);
    });

    group('HEAD (RFC 9110 §9.3.2)', () {
      test('headers describe the body, bytes do not follow', () async {
        final raw = await _raw(
          port,
          ascii.encode(
            'HEAD /head-test HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
          ),
        );
        expect(_statusOf(raw), 200);
        expect(_headerOf(raw, 'content-length'), 'twelve bytes'.length.toString());
        expect(_bodyOf(raw), isEmpty);
      }, skip: skipReason);
    });

    group('headers (RFC 9110 §5)', () {
      test('duplicate request headers all survive', () async {
        final raw = await _raw(
          port,
          ascii.encode(
            'GET /headers HTTP/1.1\r\nHost: x\r\nX-Dup: a\r\nX-Dup: b\r\nConnection: close\r\n\r\n',
          ),
        );
        expect(_statusOf(raw), 200);
        final decoded = jsonDecode(utf8.decode(_bodyOf(raw)));
        expect(decoded['x-dup'], ['a', 'b']);
      }, skip: skipReason);

      // Regression: the parsed head ends before the terminal CRLF of its last
      // header line, so that line has no line ending. It used to be dropped —
      // hiding a trailing `Connection: close` or `Content-Length`.
      test('the last header line is parsed, not dropped', () async {
        final raw = await _raw(
          port,
          ascii.encode(
            'GET /headers HTTP/1.1\r\nHost: x\r\nConnection: close\r\nX-Last: yes\r\n\r\n',
          ),
        );
        expect(_statusOf(raw), 200);
        final decoded = jsonDecode(utf8.decode(_bodyOf(raw)));
        expect(decoded['x-last'], ['yes']);
      }, skip: skipReason);

      test('Connection: close as the last header still closes', () async {
        final raw = await _raw(
          port,
          ascii.encode(
            'GET /headers HTTP/1.1\r\nHost: x\r\nX-Last: yes\r\nConnection: close\r\n\r\n',
          ),
        );
        expect(_headerOf(raw, 'connection'), 'close');
        // _raw returns only at EOF: reaching here proves the close.
        expect(_statusOf(raw), 200);
      }, skip: skipReason);

      test('every response carries an exact content-length', () async {
        final raw = await _raw(
          port,
          ascii.encode(
            'GET /binary/1024 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
          ),
        );
        expect(_statusOf(raw), 200);
        expect(_headerOf(raw, 'content-length'), '1024');
        expect(_bodyOf(raw), orderedEquals(_patternBytes(1024)));
      }, skip: skipReason);

      test('the server closes the connection after each response', () async {
        final raw = await _raw(
          port,
          ascii.encode(
            'GET /methods HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
          ),
        );
        expect(_headerOf(raw, 'connection'), 'close');
        // _raw returns only at EOF: reaching here proves the close.
        expect(_statusOf(raw), 200);
      }, skip: skipReason);
    });

    group('query strings (RFC 3986 §3.4)', () {
      test('empty, single, multi and encoded params', () async {
        for (final entry in {
          '/query': {},
          '/query?a=1': {'a': '1'},
          '/query?a=1&b=two&c=3': {'a': '1', 'b': 'two', 'c': '3'},
          '/query?q=hello%20world': {'q': 'hello world'},
        }.entries) {
          final body = await _clientBody(port, 'GET', entry.key);
          expect(jsonDecode(utf8.decode(body))['params'], entry.value);
        }
      }, skip: skipReason);
    });

    group('bodies (RFC 9112 §6-7)', () {
      test('empty POST has zero-length body', () async {
        final body = await _clientBody(port, 'POST', '/upload', body: []);
        expect(jsonDecode(utf8.decode(body))['length'], 0);
      }, skip: skipReason);

      test('1 MB upload arrives bit-intact', () async {
        final payload = _patternBytes(1 << 20);
        final body = await _clientBody(port, 'POST', '/upload', body: payload);
        final decoded = jsonDecode(utf8.decode(body));
        expect(decoded['length'], 1 << 20);
        expect(decoded['fnv'], _fnv(payload));
      }, skip: skipReason);

      test('5 MB upload arrives bit-intact', () async {
        final payload = _patternBytes(5 << 20);
        final body = await _clientBody(port, 'POST', '/upload', body: payload);
        final decoded = jsonDecode(utf8.decode(body));
        expect(decoded['length'], 5 << 20);
        expect(decoded['fnv'], _fnv(payload));
      }, skip: skipReason);

      test('chunked uploads are de-chunked', () async {
        final socket = await Socket.connect('127.0.0.1', port);
        try {
          socket.add(
            ascii.encode(
              'POST /upload HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n',
            ),
          );
          for (final piece in ['5\r\nhello\r\n', '6\r\n world\r\n', '0\r\n\r\n']) {
            socket.add(ascii.encode(piece));
          }
          final builder = BytesBuilder(copy: false);
          await for (final chunk in socket) {
            builder.add(chunk);
          }
          final raw = builder.toBytes();
          expect(_statusOf(raw), 200);
          expect(
            jsonDecode(utf8.decode(_bodyOf(raw)))['length'],
            'hello world'.length,
          );
        } finally {
          socket.destroy();
        }
      }, skip: skipReason);

      test('Expect: 100-continue is honoured', () async {
        final socket = await Socket.connect('127.0.0.1', port);
        try {
          final received = BytesBuilder(copy: false);
          final done = Completer<void>();
          socket.listen(
            received.add,
            onDone: done.complete,
            onError: done.completeError,
          );
          socket.add(
            ascii.encode(
              'POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\nExpect: 100-continue\r\nConnection: close\r\n\r\n',
            ),
          );
          await socket.flush();
          // The interim response must arrive before the body is sent.
          await Future<void>.delayed(const Duration(milliseconds: 300));
          expect(
            ascii.decode(received.toBytes()),
            contains('100 Continue'),
          );
          socket.add([1, 2, 3]);
          await done.future.timeout(const Duration(seconds: 10));
          final raw = received.toBytes();
          final text = ascii.decode(raw);
          final finalHead = text.indexOf('HTTP/1.1', 1);
          expect(finalHead, isNot(-1));
          expect(
            _statusOf(raw.sublist(finalHead)),
            200,
            reason: 'final response after continued body',
          );
        } finally {
          socket.destroy();
        }
      }, skip: skipReason);
    });

    group('framing robustness (RFC 9112 §2-3)', () {
      test('a request split across TCP segments still parses', () async {
        final socket = await Socket.connect('127.0.0.1', port);
        try {
          for (final piece in [
            'GET /met',
            'hods HTTP/1.1\r\nHo',
            'st: x\r\nConnection: close\r\n\r\n',
          ]) {
            socket.add(ascii.encode(piece));
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          final builder = BytesBuilder(copy: false);
          await for (final chunk in socket) {
            builder.add(chunk);
          }
          expect(_statusOf(builder.toBytes()), 200);
        } finally {
          socket.destroy();
        }
      }, skip: skipReason);

      test('garbage is a 400, not a hang or crash', () async {
        final raw = await _raw(port, ascii.encode('GARBAGE\r\n\r\n'));
        expect(_statusOf(raw), 400);
      }, skip: skipReason);

      test('a bad content-length is a 400', () async {
        final raw = await _raw(
          port,
          ascii.encode(
            'POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: banana\r\nConnection: close\r\n\r\n',
          ),
        );
        expect(_statusOf(raw), 400);
      }, skip: skipReason);

      test('a truncated body is a 400 and the server survives', () async {
        final socket = await Socket.connect('127.0.0.1', port);
        try {
          socket.add(
            ascii.encode(
              'POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\nConnection: close\r\n\r\nshort',
            ),
          );
          await socket.flush();
          // Half-close the write side: the server sees EOF before 100 bytes.
          await socket.close();
          final builder = BytesBuilder(copy: false);
          await for (final chunk in socket) {
            builder.add(chunk);
          }
          expect(_statusOf(builder.toBytes()), 400);
        } finally {
          socket.destroy();
        }
        // Still serving afterwards.
        final body = await _clientBody(port, 'GET', '/methods');
        expect(jsonDecode(utf8.decode(body))['method'], 'GET');
      }, skip: skipReason);
    });

    group('keep-alive (RFC 9112 §9)', () {
      /// Incremental framed reader: one socket, many responses.
      Future<List<Uint8List>> readResponses(Socket socket, int count) async {
        final buffer = <int>[];
        final responses = <Uint8List>[];
        final done = Completer<void>();
        socket.listen(
          buffer.addAll,
          onDone: done.complete,
          onError: done.completeError,
        );
        int headEnd(List<int> bytes) {
          for (var i = 0; i + 3 < bytes.length; i++) {
            if (bytes[i] == 13 &&
                bytes[i + 1] == 10 &&
                bytes[i + 2] == 13 &&
                bytes[i + 3] == 10) {
              return i;
            }
          }
          return -1;
        }

        while (responses.length < count) {
          int end = headEnd(buffer);
          while (end < 0) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
            // Rescan BEFORE checking `done`: on loopback a fast answer plus
            // the server's close (pipelined `Connection: close`) can all land
            // inside one poll window. Checking `done` first throws away
            // complete responses already sitting in `buffer`.
            end = headEnd(buffer);
            if (end < 0 && done.isCompleted) {
              throw StateError('connection closed mid-response');
            }
          }
          final head = ascii.decode(buffer.sublist(0, end));
          var contentLength = 0;
          for (final line in head.split('\r\n').skip(1)) {
            final colon = line.indexOf(':');
            if (colon > 0 &&
                line.substring(0, colon).trim().toLowerCase() ==
                    'content-length') {
              contentLength = int.parse(line.substring(colon + 1).trim());
            }
          }
          final total = end + 4 + contentLength;
          while (buffer.length < total) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
            if (done.isCompleted && buffer.length < total) {
              throw StateError('connection closed mid-body');
            }
          }
          responses.add(Uint8List.fromList(buffer.sublist(0, total)));
          buffer.removeRange(0, total);
        }
        return responses;
      }

      test('sequential requests share one connection', () async {
        final socket = await Socket.connect('127.0.0.1', port);
        try {
          socket.add(
            ascii.encode('GET /methods HTTP/1.1\r\nHost: x\r\n\r\n'),
          );
          socket.add(
            ascii.encode('GET /binary/16 HTTP/1.1\r\nHost: x\r\n\r\n'),
          );
          final responses = await readResponses(socket, 2).timeout(
            const Duration(seconds: 10),
          );
          expect(_statusOf(responses[0]), 200);
          expect(_headerOf(responses[0], 'connection'), 'keep-alive');
          expect(_statusOf(responses[1]), 200);
          expect(_bodyOf(responses[1]), orderedEquals(_patternBytes(16)));
        } finally {
          socket.destroy();
        }
      }, skip: skipReason);

      test('pipelined requests get ordered responses', () async {
        final socket = await Socket.connect('127.0.0.1', port);
        try {
          // Both heads in one segment: the engine must not mistake the
          // second head for the first request's body.
          socket.add(
            ascii.encode(
              'GET /methods HTTP/1.1\r\nHost: x\r\n\r\n'
              'GET /methods HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
            ),
          );
          final responses = await readResponses(socket, 2).timeout(
            const Duration(seconds: 10),
          );
          expect(_statusOf(responses[0]), 200);
          expect(_headerOf(responses[0], 'connection'), 'keep-alive');
          expect(_statusOf(responses[1]), 200);
          expect(_headerOf(responses[1], 'connection'), 'close');
        } finally {
          socket.destroy();
        }
      }, skip: skipReason);

      test('POST echo keeps framing across requests', () async {
        final socket = await Socket.connect('127.0.0.1', port);
        try {
          final payload = List<int>.generate(5000, (i) => i & 0xff);
          socket.add(
            ascii.encode(
              'POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: ${payload.length}\r\n\r\n',
            ),
          );
          socket.add(payload);
          socket.add(
            ascii.encode('GET /methods HTTP/1.1\r\nHost: x\r\n\r\n'),
          );
          final responses = await readResponses(socket, 2).timeout(
            const Duration(seconds: 10),
          );
          expect(_statusOf(responses[0]), 200);
          expect(
            jsonDecode(utf8.decode(_bodyOf(responses[0])))['length'],
            5000,
          );
          expect(_statusOf(responses[1]), 200);
        } finally {
          socket.destroy();
        }
      }, skip: skipReason);

      test('HTTP/1.0 closes unless asked to keep', () async {
        final raw = await _raw(
          port,
          ascii.encode('GET /methods HTTP/1.0\r\nHost: x\r\n\r\n'),
        );
        expect(_statusOf(raw), 200);
        expect(_headerOf(raw, 'connection'), 'close');
      }, skip: skipReason);
    });

    group('routing', () {
      test('wildcard captures deep paths', () async {
        final body = await _clientBody(port, 'GET', '/wild/a/b/c');
        expect(utf8.decode(body), 'wild:/wild/a/b/c');
      }, skip: skipReason);

      test('unrouted paths are engine 404s', () async {
        final raw = await _raw(
          port,
          ascii.encode(
            'GET /nothing/here HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
          ),
        );
        expect(_statusOf(raw), 404);
      }, skip: skipReason);
    });

    group('load', () {
      test('mixed parallel workload stays exact', () async {
        final futures = <Future<void>>[];
        for (var i = 0; i < 40; i++) {
          final index = i;
          futures.add(
            () async {
              switch (index % 4) {
                case 0:
                  final body = await _clientBody(
                    port,
                    'GET',
                    '/binary/4096',
                  );
                  expect(body, orderedEquals(_patternBytes(4096)));
                case 1:
                  final payload = _patternBytes(65536);
                  final body = await _clientBody(
                    port,
                    'POST',
                    '/upload',
                    body: payload,
                  );
                  expect(
                    jsonDecode(utf8.decode(body))['fnv'],
                    _fnv(payload),
                  );
                case 2:
                  final body = await _clientBody(
                    port,
                    'GET',
                    '/query?i=$index',
                  );
                  expect(
                    jsonDecode(utf8.decode(body))['params'],
                    {'i': '$index'},
                  );
                default:
                  final raw = await _raw(
                    port,
                    ascii.encode(
                      'GET /status/201 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
                    ),
                  );
                  expect(_statusOf(raw), 201);
              }
            }(),
          );
        }
        await Future.wait(futures);
      }, skip: skipReason);
    });
  });
}
