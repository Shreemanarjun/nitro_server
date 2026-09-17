// End-to-end proof that the whole stack works: public API → runner →
// generated bridge → C++ engine → a real socket → back.
//
// Every other test replaces the FFI boundary with a fake, which is what makes
// them fast and hermetic. This one does the opposite and is the only place a
// genuine integration bug can surface. `dart:io HttpClient` is the driver —
// the roles are flipped from `nitro_http`'s suite, where a shelf server plays
// this part.
//
// It loads the library built by:
//
//   cmake -S src -B build/lib -DCMAKE_BUILD_TYPE=Release
//   cmake --build build/lib --parallel
//
// and skips itself when that artifact is absent, so `dart test` still
// passes on a machine that has not built native code. `NITRO_SERVER_DYLIB`
// overrides the path.
//
// On Apple platforms Nitro resolves symbols with `DynamicLibrary.process()`,
// which searches images already loaded into the process — so opening the dylib
// here is what makes the plugin visible to the generated bindings.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';
import 'package:nitro_server/nitro_server.dart';
import 'package:nitro_server/src/internal/instance_keys.dart';
import 'package:nitro_server/src/internal/native_attach.dart';
import 'package:nitro_server/src/nitro_server.native.dart';

import 'support/tls_cert.dart';

String? _locateLibrary() {
  for (final candidate in nitroServerLibraryCandidates()) {
    if (File(candidate).existsSync()) return File(candidate).absolute.path;
  }
  return null;
}

/// Drives one request with a fresh client: the engine closes connections
/// (`Connection: close`), so sharing a client gains nothing here.
Future<({int status, String body, HttpHeaders headers})> _get(
  int port,
  String path, {
  String method = 'GET',
  Map<String, String>? headers,
  List<int>? body,
  String host = '127.0.0.1',
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(
      method,
      Uri.parse('http://$host:$port$path'),
    );
    headers?.forEach(request.headers.set);
    if (body != null) request.add(body);
    final response = await request.close().timeout(const Duration(seconds: 15));
    final bytes = await response.fold<BytesBuilder>(
      BytesBuilder(),
      (b, d) => b..add(d),
    );
    return (
      status: response.statusCode,
      body: utf8.decode(bytes.toBytes()),
      headers: response.headers,
    );
  } finally {
    client.close(force: true);
  }
}

/// [_get] for binary bodies: no UTF-8 decode, exact bytes back.
Future<({int status, Uint8List body})> _getBytes(
  int port,
  String path, {
  String method = 'GET',
  List<int>? body,
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:$port$path'),
    );
    if (body != null) request.add(body);
    final response = await request.close().timeout(const Duration(seconds: 15));
    final builder = await response.fold<BytesBuilder>(
      BytesBuilder(),
      (b, d) => b..add(d),
    );
    return (status: response.statusCode, body: builder.toBytes());
  } finally {
    client.close(force: true);
  }
}

/// WebSocket test helpers: minimal RFC 6455 frame codec over a raw socket.
/// Server frames are never masked; client frames always are.
List<int> _maskFrame(int opcode, List<int> payload, {bool fin = true}) {
  const mask = [0x11, 0x22, 0x33, 0x44];
  final out = <int>[(fin ? 0x80 : 0) | opcode];
  final n = payload.length;
  if (n < 126) {
    out.add(0x80 | n);
  } else if (n <= 0xffff) {
    out.addAll([0x80 | 126, (n >> 8) & 0xff, n & 0xff]);
  } else {
    out.add(0x80 | 127);
    for (var i = 7; i >= 0; i--) {
      out.add((n >> (8 * i)) & 0xff);
    }
  }
  out.addAll(mask);
  for (var i = 0; i < n; i++) {
    out.add(payload[i] ^ mask[i % 4]);
  }
  return out;
}

Future<void> _fillWs(
  StreamIterator<Uint8List> it,
  BytesBuilder buf,
  int n,
) async {
  while (buf.length < n) {
    if (!await it.moveNext().timeout(const Duration(seconds: 10))) {
      throw StateError('eof waiting for $n bytes');
    }
    buf.add(it.current);
  }
}

int _crlfIndex(List<int> bytes) {
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

/// Reads the HTTP head (through `\r\n\r\n`), keeping trailing frame bytes.
Future<String> _readWsHead(
  StreamIterator<Uint8List> it,
  BytesBuilder buf,
) async {
  while (true) {
    final i = _crlfIndex(buf.toBytes());
    if (i != -1) {
      final bytes = buf.toBytes();
      final head = ascii.decode(bytes.sublist(0, i));
      buf.clear();
      buf.add(bytes.sublist(i + 4));
      return head;
    }
    if (!await it.moveNext().timeout(const Duration(seconds: 10))) {
      throw StateError('eof waiting for handshake');
    }
    buf.add(it.current);
  }
}

/// Reads one server frame. `moveNext() == false` afterwards means the
/// server closed the socket.
Future<({int opcode, Uint8List payload})> _readWsFrame(
  StreamIterator<Uint8List> it,
  BytesBuilder buf,
) async {
  await _fillWs(it, buf, 2);
  var bytes = buf.toBytes();
  final opcode = bytes[0] & 0x0f;
  var len = bytes[1] & 0x7f;
  var pos = 2;
  if (len == 126) {
    await _fillWs(it, buf, 4);
    bytes = buf.toBytes();
    len = (bytes[2] << 8) | bytes[3];
    pos = 4;
  } else if (len == 127) {
    await _fillWs(it, buf, 10);
    bytes = buf.toBytes();
    len = 0;
    for (var i = 0; i < 8; i++) {
      len = (len << 8) | bytes[2 + i];
    }
    pos = 10;
  }
  if ((bytes[1] & 0x80) != 0) {
    await _fillWs(it, buf, pos + 4);
    pos += 4;
  }
  await _fillWs(it, buf, pos + len);
  bytes = buf.toBytes();
  final payload = Uint8List.fromList(bytes.sublist(pos, pos + len));
  buf.clear();
  buf.add(bytes.sublist(pos + len));
  return (opcode: opcode, payload: payload);
}

/// A setup that fails only in helper isolates (named `nitro_server:…` by
/// the server): bind must surface it.
Future<void> _helperOnlyThrow(NitroServer server) async {
  if ((Isolate.current.debugName ?? '').startsWith('nitro_server:')) {
    throw StateError('helper setup failed on purpose');
  }
}

/// Fails only in the second helper (`…:2`), so the first one is already
/// running when bind gives up and must be closed on the way out.
Future<void> _secondHelperThrows(NitroServer server) async {
  if ((Isolate.current.debugName ?? '').endsWith(':2')) {
    throw StateError('second helper failed on purpose');
  }
}

/// Entry for the main-isolate attach test: opens the library (a fresh
/// isolate resolves symbols through the process, but the load guard is
/// per isolate), reconciles, and reports.
Future<void> _attachAsMain((String?, SendPort) args) async {
  final (libraryPath, reply) = args;
  if (libraryPath != null) DynamicLibrary.open(libraryPath);
  ensureNativeAttached();
  reply.send('attached');
}

/// Routes for the isolates test: the body names the answering isolate.
Future<void> _whoSetup(NitroServer server) async {
  await server.get('/who', (_) async {
    return ResponseContext.text(Isolate.current.debugName ?? 'unnamed');
  });
}

void main() {
  final libraryPath = _locateLibrary();
  final skipReason = libraryPath == null
      ? 'native library not built — run: cmake -S src -B build/lib && '
            'cmake --build build/lib --parallel'
      : null;

  group('native server', () {
    setUpAll(() {
      if (libraryPath == null) return;
      // Makes the plugin's symbols resolvable through DynamicLibrary.process(),
      // which is how Nitro loads on Apple platforms.
      DynamicLibrary.open(libraryPath);
      resetNativeAttachForTesting();
      Ids.resetForTesting();
    });

    // Nullable, not `late`: a test that throws before assigning would
    // otherwise fail again in tearDown and bury the real error under it.
    NitroServer? server;

    tearDown(() async {
      await server?.close();
      server = null;
    });

    test('reports engine capabilities', () async {
      expect(
        NitroServerNative.engine.engineVersion(),
        contains('nitro_server'),
      );
      expect(NitroServerNative.engine.supportsTls(), isTrue);
    }, skip: skipReason);

    test('serves HTTPS with a PEM cert over a real TLS socket', () async {
      server = await NitroServer.bind(
        const ServerConfig(
          tls: TlsConfig(certPem: testCertPem, keyPem: testKeyPem),
        ),
      );
      await server!.get('/secure', (_) => ResponseContext.text('over tls'));
      await server!.post('/echo', (r) async => ResponseContext.bytes(r.body));

      final client = HttpClient()
        ..badCertificateCallback = (cert, host, port) => true;
      final get = await client.getUrl(
        Uri.parse('https://127.0.0.1:${server!.port}/secure'),
      );
      final getRes = await get.close();
      expect(getRes.statusCode, 200);
      expect(await getRes.transform(utf8.decoder).join(), 'over tls');

      final post = await client.postUrl(
        Uri.parse('https://127.0.0.1:${server!.port}/echo'),
      );
      post.add(utf8.encode('ping'));
      final postRes = await post.close();
      expect(await postRes.transform(utf8.decoder).join(), 'ping');
      client.close(force: true);
    }, skip: skipReason);

    test('a TLS config with a mismatched key fails to start', () async {
      await expectLater(
        NitroServer.bind(
          const ServerConfig(
            tls: TlsConfig(
              certPem: testCertPem,
              keyPem:
                  '-----BEGIN PRIVATE KEY-----\nnope\n-----END PRIVATE KEY-----\n',
            ),
          ),
        ),
        throwsA(isA<ServerTlsException>()),
      );
    }, skip: skipReason);

    test('starts on an ephemeral port and stops', () async {
      server = await NitroServer.bind();
      expect(server!.port, isNot(0));

      // Nothing registered: every path is a 404 from the engine itself.
      final res = await _get(server!.port, '/anything');
      expect(res.status, 404);

      final port = server!.port;
      await server!.close();
      server = null;

      // The listener is gone: connecting must fail, not hang.
      await expectLater(_get(port, '/'), throwsA(isA<Exception>()));
    }, skip: skipReason);

    test(
      'answers with more header bytes than the fast path preallocates',
      () async {
        // The leaf-call answer path stages headers in a 2 KiB native buffer
        // and grows it on demand; a 6 KiB header set must arrive intact.
        server = await NitroServer.bind();
        final big = 'v' * 6000;
        await server!.get('/big-headers', (_) async {
          return ResponseContext.text('ok', headers: {'x-big': big});
        });
        final res = await _get(server!.port, '/big-headers');
        expect(res.status, 200);
        expect(res.body, 'ok');
        expect(res.headers.value('x-big'), big);
      },
      skip: skipReason,
    );

    test('isolates: 2 deals requests across both runners', () async {
      server = await NitroServer.bind(
        const ServerConfig(isolates: 2),
        _whoSetup,
      );
      expect(server!.isolates, 2);
      final seen = <String>{};
      for (var i = 0; i < 8; i++) {
        final res = await _get(server!.port, '/who');
        expect(res.status, 200);
        seen.add(res.body);
      }
      // Round-robin: every other request lands on the helper isolate.
      expect(seen, hasLength(2));
      // A route only the main isolate knows is a 404 on the helper's turn:
      // registration outside `setup` does not reach helpers.
      await server!.get('/main-only', (_) async => ResponseContext.text('m'));
      final statuses = <int>{};
      for (var i = 0; i < 4; i++) {
        statuses.add((await _get(server!.port, '/main-only')).status);
      }
      expect(statuses, {200, 404});
    }, skip: skipReason);

    test('isolates: 0 picks a size from the CPU count', () async {
      server = await NitroServer.bind(
        const ServerConfig(isolates: 0),
        _whoSetup,
      );
      expect(server!.isolates, (Platform.numberOfProcessors ~/ 2).clamp(1, 8));
      expect((await _get(server!.port, '/who')).status, 200);
    }, skip: skipReason);

    test('bindWith forwards its arguments and setup', () async {
      server = await NitroServer.bindWith(
        keepAliveTimeout: Duration.zero,
        isolates: 1,
        setup: _whoSetup,
      );
      final res = await _get(server!.port, '/who');
      expect(res.status, 200);
      expect(res.headers.value('connection'), 'close');
    }, skip: skipReason);

    test(
      'a setup that throws in a helper fails bind instead of hanging',
      () async {
        await expectLater(
          NitroServer.bind(
            const ServerConfig(isolates: 2),
            _helperOnlyThrow,
          ).timeout(const Duration(seconds: 10)),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('failed to start'),
            ),
          ),
        );
      },
      skip: skipReason,
    );

    test(
      'a helper failing after another started closes the survivor',
      () async {
        await expectLater(
          NitroServer.bind(
            const ServerConfig(isolates: 3),
            _secondHelperThrows,
          ).timeout(const Duration(seconds: 10)),
          throwsA(isA<StateError>()),
        );
      },
      skip: skipReason,
    );

    test('the main isolate reconciles native state on attach', () async {
      // `ensureNativeAttached` resets the engine only from the isolate named
      // `main`; under `dart test` that is never the test isolate, so spawn
      // one with that name and prove the reset path runs without error.
      final done = ReceivePort();
      await Isolate.spawn(_attachAsMain, (
        libraryPath,
        done.sendPort,
      ), debugName: 'main');
      expect(await done.first, 'attached');
    }, skip: skipReason);

    test('isolates above 1 need a setup function', () async {
      await expectLater(
        NitroServer.bind(const ServerConfig(isolates: 2)),
        throwsArgumentError,
      );
    }, skip: skipReason);

    test(
      'close(drain:) finishes accepted work and refuses new connections',
      () async {
        server = await NitroServer.bind();
        final gate = Completer<void>();
        await server!.get('/slow', (_) async {
          await gate.future;
          return ResponseContext.text('done');
        });
        final port = server!.port;
        final pending = _get(port, '/slow');
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final closing = server!.close(drain: const Duration(seconds: 5));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        // Draining: the listener is gone, the in-flight request still lands.
        await expectLater(_get(port, '/slow'), throwsA(isA<Exception>()));
        gate.complete();
        expect((await pending).body, 'done');
        await closing;
        server = null;
      },
      skip: skipReason,
    );

    test('connection limits and the header deadline are enforced', () async {
      server = await NitroServer.bind(
        const ServerConfig(
          maxConnections: 2,
          maxConnectionsPerIp: 2,
          headerTimeout: Duration(milliseconds: 200),
        ),
      );
      final port = server!.port;
      // Two silent connections hold the cap; a third is closed at once.
      final a = await Socket.connect('127.0.0.1', port);
      final b = await Socket.connect('127.0.0.1', port);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final c = await Socket.connect('127.0.0.1', port);
      expect(await c.fold<int>(0, (n, d) => n + d.length), 0);
      // The silent ones are cut at the header deadline, freeing the cap.
      await a.drain<void>().timeout(const Duration(seconds: 2));
      await b.drain<void>().timeout(const Duration(seconds: 2));
      a.destroy();
      b.destroy();
      c.destroy();
      await server!.get('/ok', (_) => ResponseContext.text('ok'));
      expect((await _get(port, '/ok')).body, 'ok');
    }, skip: skipReason);

    test('streamBody routes read the upload as it arrives', () async {
      server = await NitroServer.bind();
      await server!.post('/up', streamBody: true, (request) async {
        expect(request.body, isEmpty);
        var bytes = 0;
        var chunks = 0;
        var hash = 0x811c9dc5;
        await for (final chunk in request.bodyStream!) {
          chunks++;
          bytes += chunk.length;
          for (final b in chunk) {
            hash ^= b;
            hash = (hash * 0x01000193) & 0xffffffff;
          }
        }
        return ResponseContext.jsonBody({
          'bytes': bytes,
          'chunks': chunks,
          'hash': hash,
        });
      });
      final payload = Uint8List.fromList(
        List.generate(3 * 1024 * 1024, (i) => i & 0xff),
      );
      var expected = 0x811c9dc5;
      for (final b in payload) {
        expected ^= b;
        expected = (expected * 0x01000193) & 0xffffffff;
      }
      final res = await _get(
        server!.port,
        '/up',
        method: 'POST',
        body: payload,
      );
      expect(res.status, 200);
      final json = jsonDecode(res.body) as Map<String, Object?>;
      expect(json['bytes'], payload.length);
      expect(json['hash'], expected);
      expect(json['chunks'], greaterThan(1));
      // A small streamed body works the same way (never the inline form).
      final small = await _get(
        server!.port,
        '/up',
        method: 'POST',
        body: [1, 2, 3],
      );
      expect((jsonDecode(small.body) as Map)['bytes'], 3);
    }, skip: skipReason);

    test(
      'a streamBody handler answering early still drains the wire',
      () async {
        server = await NitroServer.bind();
        await server!.post('/first', streamBody: true, (request) async {
          final first = await request.bodyStream!.first;
          return ResponseContext.text('got ${first.length} early');
        });
        final res = await _get(
          server!.port,
          '/first',
          method: 'POST',
          body: List.filled(200 * 1024, 7),
        );
        expect(res.status, 200);
        expect(res.body, startsWith('got '));
      },
      skip: skipReason,
    );

    test(
      'file answers are sent natively, ranges through staticFiles',
      () async {
        final dir = Directory.systemTemp.createTempSync('nitro_e2e_files');
        addTearDown(() => dir.deleteSync(recursive: true));
        final content = Uint8List.fromList(
          List.generate(2 * 1024 * 1024 + 123, (i) => (i * 7) & 0xff),
        );
        File('${dir.path}/big.bin').writeAsBytesSync(content);
        server = await NitroServer.bind();
        await server!.get('/static/*', staticFiles(dir.path));
        await server!.get(
          '/direct',
          (_) => ResponseContext.file('${dir.path}/big.bin'),
        );
        final whole = await _getBytes(server!.port, '/static/big.bin');
        expect(whole.status, 200);
        expect(whole.body, content);
        final direct = await _getBytes(server!.port, '/direct');
        expect(direct.body.length, content.length);
        final head = await _get(server!.port, '/direct', method: 'HEAD');
        expect(head.headers.contentLength, content.length);
        expect(head.body, isEmpty);
        final client = HttpClient();
        try {
          final req = await client.getUrl(
            Uri.parse('http://127.0.0.1:${server!.port}/static/big.bin'),
          );
          req.headers.set('range', 'bytes=1000-1009');
          final res = await req.close();
          expect(res.statusCode, 206);
          expect(
            res.headers.value('content-range'),
            'bytes 1000-1009/${content.length}',
          );
          final bytes = await res.fold<BytesBuilder>(
            BytesBuilder(),
            (b, d) => b..add(d),
          );
          expect(bytes.toBytes(), content.sublist(1000, 1010));
        } finally {
          client.close(force: true);
        }
        expect((await _get(server!.port, '/static/nope')).status, 404);
      },
      skip: skipReason,
    );

    test('template routes assemble the body from path + query, engine-side', () async {
      server = await NitroServer.bind();
      await server!.getTemplated(
        '/tmpl/:id',
        '{"id":{id},"ok":true}',
        contentType: 'application/json',
      );
      await server!.getTemplated('/pair/:a/:b', '{a}-{b!}');
      // A query slot, form-decoded, plus a raw numeric query field.
      await server!.getTemplated(
        '/search',
        '{"q":{?q},"page":{?page!}}',
        contentType: 'application/json',
      );

      final res = await _get(server!.port, '/tmpl/42');
      expect(res.status, 200);
      expect(res.body, '{"id":"42","ok":true}');
      expect(res.headers.contentType?.mimeType, 'application/json');

      // HEAD: length framed, no body.
      final head = await _get(server!.port, '/tmpl/42', method: 'HEAD');
      expect(head.headers.contentLength, '{"id":"42","ok":true}'.length);
      expect(head.body, isEmpty);

      // jsonString escaping keeps a tricky value inside its JSON string: the
      // response must still parse, whatever the router does with %-encoding.
      final tricky = await _get(server!.port, '/tmpl/a%22b%5Cc');
      expect(tricky.status, 200);
      expect(() => jsonDecode(tricky.body), returnsNormally);

      // Two slots, one raw (no quotes).
      final pair = await _get(server!.port, '/pair/x/y');
      expect(pair.body, '"x"-y');

      // Query slots: q form-decoded to "a b", page raw.
      final search = await _get(server!.port, '/search?q=a%20b&page=2');
      expect(search.body, '{"q":"a b","page":2}');

      // The typed JSON builder over the real engine.
      await server!.getTemplatedJson('/j/:id', {
        'userId': Slot.param('id'),
        'n': Slot.paramRaw('id'),
        'q': Slot.query('q'),
        'ok': true,
      });
      final j = await _get(server!.port, '/j/9?q=x');
      expect(j.headers.contentType?.mimeType, 'application/json');
      expect(jsonDecode(j.body), {'userId': '9', 'n': 9, 'q': 'x', 'ok': true});
    });

    test('several cookies ride as separate set-cookie headers', () async {
      server = await NitroServer.bind();
      await server!.get(
        '/login',
        (r) => ResponseContext.text('cookies: ${r.cookies}')
            .withCookie(const SetCookie('sid', 'abc', httpOnly: true))
            .withCookie(
              const SetCookie('theme', 'dark', maxAge: Duration(days: 1)),
            ),
      );
      await server!.get(
        '/stream',
        (_) => ResponseContext(
          bodyStream: Stream.value(Uint8List.fromList([1])),
          cookies: const [SetCookie('s', '1')],
        ),
      );
      final res = await _get(
        server!.port,
        '/login',
        headers: {'cookie': 'a=1; b=2'},
      );
      expect(res.body, 'cookies: {a: 1, b: 2}');
      expect(res.headers['set-cookie'], [
        'sid=abc; Path=/; HttpOnly',
        'theme=dark; Max-Age=86400; Path=/',
      ]);
      final streamed = await _get(server!.port, '/stream');
      expect(streamed.headers['set-cookie'], ['s=1; Path=/']);
    }, skip: skipReason);

    test('metrics count real requests', () async {
      server = await NitroServer.bind();
      await server!.get('/m', (_) => ResponseContext.text('m'));
      for (var i = 0; i < 3; i++) {
        await _get(server!.port, '/m');
      }
      final metrics = server!.metrics;
      expect(metrics.requests, 3);
      expect(metrics.byRoute['/m']!.latency.count, 3);
      expect(metrics.byRoute['/m']!.latency.maxUs, greaterThan(0));
    }, skip: skipReason);

    test('ws protocols: the route\'s first offered subprotocol wins', () async {
      server = await NitroServer.bind();
      String? seen;
      await server!.ws('/p', (session) async {
        seen = session.protocol;
        await for (final message in session.messages) {
          session.sendText(message.text!);
        }
      }, protocols: ['graphql-ws', 'json']);
      final url = 'ws://127.0.0.1:${server!.port}/p';
      final socket = await WebSocket.connect(
        url,
        protocols: ['json', 'graphql-ws'],
      );
      expect(socket.protocol, 'graphql-ws');
      socket.add('x');
      expect(await socket.first, 'x');
      await socket.close();
      expect(seen, 'graphql-ws');
      await expectLater(
        WebSocket.connect(url, protocols: ['xml']),
        throwsA(isA<WebSocketException>()),
      );
    }, skip: skipReason);

    test('permessage-deflate round-trips with dart:io\'s client', () async {
      server = await NitroServer.bind();
      await server!.ws('/deflate', (session) async {
        expect(session.compressed, isTrue);
        await for (final message in session.messages) {
          session.sendText('echo:${message.text}');
        }
      });
      final big = 'compressible text ' * 200;
      final socket = await WebSocket.connect(
        'ws://127.0.0.1:${server!.port}/deflate',
        compression: CompressionOptions.compressionDefault,
      );
      // dart:io's `WebSocket.extensions` is always empty; the proof that
      // deflate is on is the handler's `compressed` check plus the bytes
      // surviving dart:io's compressor and our inflater in both directions.
      socket.add(big);
      socket.add('tiny');
      final replies = await socket.take(2).toList();
      expect(replies, ['echo:$big', 'echo:tiny']);
      await socket.close();
    }, skip: skipReason);

    test('wsCompression: false declines the extension', () async {
      server = await NitroServer.bind(const ServerConfig(wsCompression: false));
      await server!.ws('/plain', (session) async {
        expect(session.compressed, isFalse);
        await for (final m in session.messages) {
          session.sendText(m.text!);
        }
      });
      final socket = await WebSocket.connect(
        'ws://127.0.0.1:${server!.port}/plain',
        compression: CompressionOptions.compressionDefault,
      );
      socket.add('p');
      expect(await socket.first, 'p');
      await socket.close();
    }, skip: skipReason);

    test('a session over its send buffer is closed with 1009', () async {
      server = await NitroServer.bind(
        const ServerConfig(wsMaxBufferBytes: 64 * 1024),
      );
      final closed = Completer<int?>();
      await server!.ws('/flood', (session) async {
        // The peer never reads: the socket fills, then the queue, then the
        // engine closes the session. Sends after that report -1.
        var last = 0;
        for (var i = 0; i < 400 && last >= 0; i++) {
          last = session.sendBytes(Uint8List(16 * 1024));
          await Future<void>.delayed(Duration.zero);
        }
        expect(last, -1);
        await session.messages.drain<void>();
        closed.complete(session.closeCode);
      });
      final raw = await Socket.connect('127.0.0.1', server!.port);
      raw.add(
        ascii.encode(
          'GET /flood HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n'
          'Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
          'Sec-WebSocket-Version: 13\r\n\r\n',
        ),
      );
      // Read nothing: let the server's send buffer and queue fill.
      expect(await closed.future.timeout(const Duration(seconds: 10)), 1009);
      raw.destroy();
    }, skip: skipReason);

    test('a per-route body cap answers 413 below the server cap', () async {
      server = await NitroServer.bind();
      await server!.post(
        '/small',
        maxBodyBytes: 100,
        (r) => ResponseContext.text('${r.body.length}'),
      );
      await server!.post(
        '/big',
        (r) => ResponseContext.text('${r.body.length}'),
      );
      final payload = List.filled(1000, 1);
      expect(
        (await _get(
          server!.port,
          '/small',
          method: 'POST',
          body: payload,
        )).status,
        413,
      );
      expect(
        (await _get(server!.port, '/small', method: 'POST', body: [1, 2])).body,
        '2',
      );
      expect(
        (await _get(server!.port, '/big', method: 'POST', body: payload)).body,
        '1000',
      );
    }, skip: skipReason);

    test('a peer that stops reading is dropped at the write timeout', () async {
      server = await NitroServer.bind(
        const ServerConfig(writeTimeout: Duration(milliseconds: 300)),
      );
      await server!.get(
        '/huge',
        (_) => ResponseContext.bytes(Uint8List(8 * 1024 * 1024)),
      );
      final dropped = server!.events
          .firstWhere((e) => e.kind == ServerEventKind.clientError)
          .timeout(const Duration(seconds: 5));
      final raw = await Socket.connect('127.0.0.1', server!.port);
      raw.add(ascii.encode('GET /huge HTTP/1.1\r\nHost: x\r\n\r\n'));
      // Never read: the engine gives up on the stalled write and says so.
      final event = await dropped;
      expect(event.message, contains('write timed out'));
      raw.destroy();
    }, skip: skipReason);

    test('close(drain:) serves a connection still in the backlog', () async {
      server = await NitroServer.bind();
      await server!.get('/x', (_) => ResponseContext.text('served'));
      final port = server!.port;
      // Connect, send, and drain at once: the sweep accepts the queued
      // connection before the listener closes, and the drain waits for it.
      final raw = await Socket.connect('127.0.0.1', port);
      raw.add(ascii.encode('GET /x HTTP/1.1\r\nHost: x\r\n\r\n'));
      final closing = server!.close(drain: const Duration(seconds: 5));
      final response = await raw.fold<List<int>>([], (b, d) => b..addAll(d));
      expect(ascii.decode(response), contains('served'));
      raw.destroy();
      await closing;
      server = null;
    }, skip: skipReason);

    test('matches a literal route and echoes the method', () async {
      server = await NitroServer.bind();
      await server!.route(HttpMethod.get, '/hello', (request) async {
        return ResponseContext.text('hi from ${request.method.name}');
      });

      final res = await _get(server!.port, '/hello');
      expect(res.status, 200);
      expect(res.body, 'hi from get');
    }, skip: skipReason);

    test('captures :param segments into the handler', () async {
      server = await NitroServer.bind();
      await server!.route(HttpMethod.get, '/users/:id', (request) async {
        return ResponseContext.json(jsonEncode({'id': request.param('id')}));
      });

      final res = await _get(server!.port, '/users/42');
      expect(res.status, 200);
      expect(jsonDecode(res.body), {'id': '42'});
    }, skip: skipReason);

    test('static beats param beats wildcard', () async {
      server = await NitroServer.bind();
      await server!.route(
        HttpMethod.get,
        '/files/*',
        (_) async => ResponseContext.text('wild'),
      );
      await server!.route(
        HttpMethod.get,
        '/files/:name',
        (request) async => ResponseContext.text('param'),
      );
      await server!.route(
        HttpMethod.get,
        '/files/readme',
        (_) async => ResponseContext.text('static'),
      );

      expect((await _get(server!.port, '/files/readme')).body, 'static');
      expect((await _get(server!.port, '/files/other')).body, 'param');
      expect((await _get(server!.port, '/files/a/b')).body, 'wild');
    }, skip: skipReason);

    test('echoes a POST body byte-intact', () async {
      server = await NitroServer.bind();
      await server!.route(HttpMethod.post, '/echo', (request) async {
        return ResponseContext.bytes(request.body);
      });

      final payload = List<int>.generate(200000, (i) => i & 0xff);
      final res = await _getBytes(
        server!.port,
        '/echo',
        method: 'POST',
        body: payload,
      );
      expect(res.status, 200);
      expect(res.body, orderedEquals(payload));
    }, skip: skipReason);

    test('query string and headers reach the handler', () async {
      server = await NitroServer.bind();
      await server!.route(HttpMethod.get, '/q', (request) async {
        return ResponseContext.json(
          jsonEncode({
            'query': request.queryParameters,
            'token': request.header('x-token'),
          }),
        );
      });

      final res = await _get(
        server!.port,
        '/q?a=1&b=two',
        headers: {'x-token': 's3cret'},
      );
      expect(res.status, 200);
      expect(jsonDecode(res.body), {
        'query': {'a': '1', 'b': 'two'},
        'token': 's3cret',
      });
    }, skip: skipReason);

    test('unregistering removes the route', () async {
      server = await NitroServer.bind();
      await server!.route(
        HttpMethod.get,
        '/temp',
        (_) async => ResponseContext.text('here'),
      );
      expect((await _get(server!.port, '/temp')).status, 200);

      await server!.unroute(HttpMethod.get, '/temp');
      expect((await _get(server!.port, '/temp')).status, 404);

      await expectLater(
        server!.unroute(HttpMethod.get, '/temp'),
        throwsA(isA<RouteNotFoundException>()),
      );
    }, skip: skipReason);

    test('a bad pattern is rejected before touching native routes', () async {
      server = await NitroServer.bind();
      await expectLater(
        server!.route(HttpMethod.get, 'no-slash', (_) async {
          return const ResponseContext();
        }),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        server!.route(HttpMethod.get, '/a/*/b', (_) async {
          return const ResponseContext();
        }),
        throwsA(isA<ServerBadRequestException>()),
      );
    }, skip: skipReason);

    test('concurrent connections do not deadlock', () async {
      server = await NitroServer.bind();
      await server!.route(HttpMethod.get, '/users/:id', (request) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return ResponseContext.text('user ${request.param('id')}');
      });

      // 32 simultaneous connections through 32 parked native threads and one
      // shared (never blocking) Dart isolate. A shared bridge lock or a
      // clobbered callback slot would serialize or corrupt these.
      final results = await Future.wait([
        for (var i = 0; i < 32; i++) _get(server!.port, '/users/$i'),
      ]);
      for (var i = 0; i < 32; i++) {
        expect(results[i].status, 200, reason: 'request $i failed');
        expect(results[i].body, 'user $i', reason: 'request $i misrouted');
      }
    }, skip: skipReason);

    test('a slow handler hits its per-route timeout alone', () async {
      server = await NitroServer.bind();
      await server!.route(HttpMethod.get, '/slow', (_) async {
        await Future<void>.delayed(const Duration(seconds: 5));
        return ResponseContext.text('too late');
      }, timeout: const Duration(milliseconds: 400));
      await server!.route(
        HttpMethod.get,
        '/fast',
        (_) async => ResponseContext.text('fast'),
      );

      final slow = await _get(server!.port, '/slow');
      expect(slow.status, 408);

      // The wedged connection did not take the server with it.
      final fast = await _get(server!.port, '/fast');
      expect(fast.status, 200);
      expect(fast.body, 'fast');

      // And the late handler result was dropped, not sent twice: the client
      // already has its 408 and the connection is closed.
    }, skip: skipReason);

    test('a throwing handler is a 500, and the server survives', () async {
      server = await NitroServer.bind();
      await server!.route(HttpMethod.get, '/boom', (_) async {
        throw StateError('kaput');
      });
      await server!.route(
        HttpMethod.get,
        '/ok',
        (_) async => ResponseContext.text('ok'),
      );

      expect((await _get(server!.port, '/boom')).status, 500);
      expect((await _get(server!.port, '/ok')).body, 'ok');
    }, skip: skipReason);

    test('handler timeouts surface on the events stream', () async {
      server = await NitroServer.bind();
      final timeouts = <ServerEvent>[];
      final sub = server!.events
          .where((e) => e.kind == ServerEventKind.handlerTimeout)
          .listen(timeouts.add);
      addTearDown(sub.cancel);

      await server!.route(HttpMethod.get, '/slow', (_) async {
        await Future<void>.delayed(const Duration(seconds: 5));
        return ResponseContext.text('late');
      }, timeout: const Duration(milliseconds: 200));
      await server!.route(
        HttpMethod.get,
        '/ready',
        (_) async => ResponseContext.text('ready'),
      );

      // The started event fires before any request; the route below proves
      // the stream was live from bind.
      expect((await _get(server!.port, '/ready')).body, 'ready');
      expect((await _get(server!.port, '/slow')).status, 408);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(timeouts, hasLength(1));
    }, skip: skipReason);

    test('a shared client reuses keep-alive connections', () async {
      server = await NitroServer.bind();
      await server!.route(
        HttpMethod.get,
        '/r',
        (_) async => ResponseContext.text('reused'),
      );

      // One client, sequential requests: HttpClient pools the keep-alive
      // connection transparently. Failure here means the framing is off.
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      for (var i = 0; i < 10; i++) {
        final request = await client.getUrl(
          Uri.parse('http://127.0.0.1:${server!.port}/r'),
        );
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        expect(response.statusCode, 200);
        expect(body, 'reused');
      }
    }, skip: skipReason);

    test('idle keep-alive connections close after the timeout', () async {
      server = await NitroServer.bind(
        const ServerConfig(keepAliveTimeout: Duration(milliseconds: 250)),
      );
      await server!.route(
        HttpMethod.get,
        '/h',
        (_) async => ResponseContext.text('hi'),
      );

      final socket = await Socket.connect('127.0.0.1', server!.port);
      addTearDown(() => socket.destroy());
      socket.add(ascii.encode('GET /h HTTP/1.1\r\nHost: x\r\n\r\n'));
      // Drain the one framed response through a persistent listener; the
      // socket must then go quiet…
      //
      // NOTE: do NOT use `socket.first` here. `first` cancels the stream
      // subscription after one chunk, which pauses the socket — and a paused
      // socket never completes `done`, even after the server closes the
      // connection (verified identical against stock dart:io HttpServer, so
      // this is a Dart client quirk, not engine behavior). The persistent
      // listener below keeps the socket resumed so the close is observed.
      //
      // NOTE: do NOT await `socket.done` either — that is the IOSink done
      // future, which completes when THIS side closes its write half, not
      // when the server closes. The server-side close is observed through
      // the stream's onDone below.
      final firstBytes = Completer<List<int>>();
      final closedByServer = Completer<void>();
      final sub = socket.listen(
        (chunk) {
          if (!firstBytes.isCompleted) firstBytes.complete(chunk);
        },
        onDone: closedByServer.complete,
        onError: closedByServer.completeError,
      );
      addTearDown(sub.cancel);
      final first = await firstBytes.future.timeout(const Duration(seconds: 5));
      expect(ascii.decode(first), contains('200'));
      // …and the server must close it after the idle deadline, not hold it
      // forever and leak the worker.
      await closedByServer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw StateError('idle connection never closed'),
      );
    }, skip: skipReason);

    test('maxRequestsPerConnection forces a fresh connection', () async {
      server = await NitroServer.bind(
        const ServerConfig(maxRequestsPerConnection: 2),
      );
      await server!.route(
        HttpMethod.get,
        '/m',
        (_) async => ResponseContext.text('m'),
      );

      final socket = await Socket.connect('127.0.0.1', server!.port);
      addTearDown(() => socket.destroy());
      final received = BytesBuilder(copy: false);
      final done = Completer<void>();
      socket.listen(
        received.add,
        onDone: done.complete,
        onError: done.completeError,
      );
      socket.add(ascii.encode('GET /m HTTP/1.1\r\nHost: x\r\n\r\n'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      socket.add(ascii.encode('GET /m HTTP/1.1\r\nHost: x\r\n\r\n'));
      await done.future.timeout(const Duration(seconds: 5));

      final text = ascii.decode(received.toBytes());
      // First response stays alive, second closes: exactly two statuses.
      expect('HTTP/1.1'.allMatches(text).length, 2);
      expect(text, contains('Connection: keep-alive'));
      expect(text, contains('Connection: close'));
    }, skip: skipReason);

    test('middleware wraps handlers in registration order', () async {
      server = await NitroServer.bind();
      final order = <String>[];
      await server!.use((request, next) async {
        order.add('outer-before');
        final response = await next(request);
        order.add('outer-after');
        return response;
      });
      await server!.use((request, next) async {
        order.add('inner-before');
        final response = await next(request);
        order.add('inner-after');
        return response;
      });
      await server!.route(
        HttpMethod.get,
        '/w',
        (_) async => ResponseContext.text('w'),
      );

      expect((await _get(server!.port, '/w')).body, 'w');
      expect(order, [
        'outer-before',
        'inner-before',
        'inner-after',
        'outer-after',
      ]);
    }, skip: skipReason);

    test(
      'a websocket handshake is refused with 426, never dispatched',
      () async {
        var calls = 0;
        server = await NitroServer.bind();
        await server!.route(HttpMethod.get, '/chat', (_) async {
          calls++;
          return ResponseContext.text('not a socket');
        });

        final res = await _get(
          server!.port,
          '/chat',
          headers: {
            'Connection': 'Upgrade',
            'Upgrade': 'websocket',
            'Sec-WebSocket-Version': '13',
            'Sec-WebSocket-Key': 'dGhlIHNhbXBsZSBub25jZQ==',
          },
        );
        expect(res.status, 426);
        expect(res.body, contains('websocket'));
        expect(calls, 0);
      },
      skip: skipReason,
    );

    test('binds IPv6 loopback when asked', () async {
      server = await NitroServer.bind(const ServerConfig(host: '::1'));
      await server!.route(
        HttpMethod.get,
        '/h6',
        (_) async => ResponseContext.text('v6'),
      );

      final res = await _get(server!.port, '/h6', host: '[::1]');
      expect(res.status, 200);
      expect(res.body, 'v6');
    }, skip: skipReason);

    test(
      'a stream answers chunked events, then the server keeps serving',
      () async {
        server = await NitroServer.bind();
        await server!.route(HttpMethod.get, '/events', (_) async {
          return ResponseContext.stream(
            Stream.periodic(
              const Duration(milliseconds: 20),
              (i) => ascii.encode('data: $i\n\n'),
            ).take(3),
            headers: {'content-type': 'text/event-stream'},
          );
        });
        await server!.route(
          HttpMethod.get,
          '/ok',
          (_) async => ResponseContext.text('ok'),
        );

        final events = await _get(server!.port, '/events');
        expect(events.status, 200);
        expect(events.body, 'data: 0\n\ndata: 1\n\ndata: 2\n\n');

        // The streamed connection completed cleanly; the server is unaffected.
        expect((await _get(server!.port, '/ok')).body, 'ok');
      },
      skip: skipReason,
    );

    test('websocket echo works over real frames', () async {
      server = await NitroServer.bind();
      await server!.ws('/chat', (session) async {
        await for (final message in session.messages) {
          if (message.isText) session.sendText('echo:${message.text}');
        }
      });

      final socket = await Socket.connect('127.0.0.1', server!.port);
      addTearDown(() => socket.destroy());
      // StreamIterator holds one subscription for its life: no pause quirk.
      final it = StreamIterator<Uint8List>(socket);
      final buf = BytesBuilder(copy: false);
      socket.add(
        ascii.encode(
          'GET /chat HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n'
          'Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
          'Sec-WebSocket-Version: 13\r\n\r\n',
        ),
      );
      final head = await _readWsHead(it, buf);
      expect(head, contains('101'));
      expect(head, contains('s3pPLMBiTxaQ9kYGzzhZRbK+xOo='));

      socket.add(_maskFrame(0x1, ascii.encode('hi')));
      final text = await _readWsFrame(it, buf);
      expect(text.opcode, 0x1);
      expect(ascii.decode(text.payload), 'echo:hi');

      socket.add(_maskFrame(0x9, [1, 2]));
      final pong = await _readWsFrame(it, buf);
      expect(pong.opcode, 0xA);
      expect(pong.payload, orderedEquals([1, 2]));

      socket.add(_maskFrame(0x8, [0x03, 0xE8]));
      final echoed = await _readWsFrame(it, buf);
      expect(echoed.opcode, 0x8);
      // The server's echo closes the socket: stream ends.
      expect(await it.moveNext(), isFalse);
    }, skip: skipReason);

    test('a second bind on the same port fails to bind', () async {
      server = await NitroServer.bind(const ServerConfig(port: 0));
      final port = server!.port;
      await expectLater(
        NitroServer.bind(ServerConfig(port: port)),
        throwsA(isA<ServerBindException>()),
      );
    }, skip: skipReason);

    test('TLS config is refused honestly on a non-TLS build', () async {
      await expectLater(
        NitroServer.bind(
          const ServerConfig(
            port: 0,
            tls: TlsConfig(certPem: 'x', keyPem: 'y'),
          ),
        ),
        throwsA(isA<ServerTlsException>()),
      );
    }, skip: skipReason);

    test(
      'the first native touch of a new incarnation stops stragglers',
      () async {
        server = await NitroServer.bind();
        await server!.route(
          HttpMethod.get,
          '/',
          (_) async => ResponseContext.text('one'),
        );
        final firstPort = server!.port;
        expect((await _get(firstPort, '/')).body, 'one');

        // A hot restart replaces the Dart isolate; the handshake guard — an
        // ordinary static — goes back to false. Nothing about native changes.
        resetNativeAttachForTesting();
        Ids.resetForTesting();

        // First native touch of the new incarnation stops the old listener.
        //
        // NOTE: this goes through `resetNative` explicitly, not through the
        // automatic handshake in `bind`. The handshake skips the reset unless
        // the isolate is named 'main' (so background isolates can't kill the
        // root isolate's servers) — and under `dart test` the isolate is named
        // `test_suite:...`, never 'main'. In production the root isolate is
        // always 'main', so the automatic path applies there; here we perform
        // the same touch by hand.
        NitroServerNative.forKey(kEngineKey).resetNative();

        // A real hot restart kills the old isolate: the old runner, its stream
        // subscriptions and its handler table die with it — only native state
        // survives until the reset above stops it. Detach the old runner the
        // same way here (stop is idempotent and already done), or its still-
        // subscribed handler table answers for the reborn server and the
        // recycled 's:1' key routes both runners' responds at one instance.
        await server!.close();
        server = null;

        // First native touch of the new incarnation stops the old listener.
        final reborn = await NitroServer.bind();
        addTearDown(reborn.close);
        await reborn.route(
          HttpMethod.get,
          '/',
          (_) async => ResponseContext.text('two'),
        );
        expect((await _get(reborn.port, '/')).body, 'two');

        // The straggler is gone: the old port refuses connections now.
        await expectLater(_get(firstPort, '/'), throwsA(isA<Exception>()));
      },
      skip: skipReason,
    );
  });
}
