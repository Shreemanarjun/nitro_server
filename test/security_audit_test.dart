/// Executable form of the production audit's P0 findings, driven over real
/// sockets against the native engine (the fakes cannot reproduce them). Each
/// was reproduced on 2026-10-21 and fixed the same day; this suite is the
/// regression gate. P0-5 (inflate cap) and P0-8 (proxy trust) are unit-tested
/// in `ws_test.dart` and `middleware_test.dart`; P0-7 (Dockerfile) is gated
/// by the CI `docker` job.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nitro_server/nitro_server.dart';
import 'package:nitro_server/src/internal/native_attach.dart';
import 'package:test/test.dart';

String? _locateLibrary() {
  for (final c in nitroServerLibraryCandidates()) {
    if (File(c).existsSync()) return File(c).absolute.path;
  }
  return null;
}

/// Writes [request] on a fresh connection and returns whatever arrives within
/// [wait] (or until the server closes) — raw bytes, so framing is observable.
Future<String> _raw(
  int port,
  String request, {
  Duration wait = const Duration(seconds: 2),
}) async {
  final socket = await Socket.connect('127.0.0.1', port);
  socket.add(utf8.encode(request));
  await socket.flush();
  final buf = BytesBuilder();
  final sub = socket.listen(buf.add);
  await Future.any([sub.asFuture<void>(), Future<void>.delayed(wait)]);
  await sub.cancel();
  socket.destroy();
  return utf8.decode(buf.toBytes(), allowMalformed: true);
}

String _status(String r) => r.isEmpty ? '' : r.split('\r\n').first;
String _head(String r) =>
    r.contains('\r\n\r\n') ? r.substring(0, r.indexOf('\r\n\r\n')) : r;
String _body(String r) =>
    r.contains('\r\n\r\n') ? r.substring(r.indexOf('\r\n\r\n') + 4) : '';

void main() {
  final libraryPath = _locateLibrary();
  final notBuilt = libraryPath == null ? 'native library not built' : null;

  late NitroServer server;
  late int port;
  late Directory root;

  setUpAll(() async {
    if (libraryPath == null) return;
    resetNativeAttachForTesting();
    root = Directory.systemTemp.createTempSync('nitro_audit_');
    final served = Directory('${root.path}/public')..createSync();
    File('${served.path}/index.html').writeAsStringSync('hi');
    // Sits OUTSIDE the served directory: nothing may ever return its bytes.
    File('${root.path}/secret.txt').writeAsStringSync('SECRET');
    server = await NitroServer.bind(
      const ServerConfig(defaultTimeout: Duration(seconds: 2)),
    );
    await server.use(requestId());
    await server.get('/s/*', staticFiles(served.path));
    await server.post(
      '/echo',
      (r) => ResponseContext.jsonBody({'len': r.body.length}),
    );
    await server.get('/boom', (_) => throw StateError('db password hunter2'));
    await server.get(
      '/split',
      (_) => ResponseContext.text(
        'ok',
      ).withHeader('x-split', 'a\r\nInjected: yes'),
    );
    port = server.port;
  });

  tearDownAll(() async {
    if (libraryPath == null) return;
    await server.close();
    root.deleteSync(recursive: true);
  });

  group('P0-1 static files: encoded traversal', () {
    for (final path in [
      '/s/..%2fsecret.txt',
      '/s/%2e%2e%2fsecret.txt',
      '/s/%2e%2e/secret.txt',
    ]) {
      test('$path never leaves the served root', () async {
        final r = await _raw(
          port,
          'GET $path HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
        );
        expect(_status(r), isNot(contains(' 200 ')));
        expect(_body(r), isNot(contains('SECRET')));
      }, skip: notBuilt);
    }
  });

  group('P0-2 response splitting via reflected request id', () {
    test(
      'a bare LF inside X-Request-Id does not become a response header',
      () async {
        final r = await _raw(
          port,
          'GET /s/index.html HTTP/1.1\r\nHost: x\r\n'
          'X-Request-Id: ok\nInjected: yes\r\nConnection: close\r\n\r\n',
        );
        final lines = _head(r).split(RegExp(r'\r?\n'));
        expect(lines, isNot(contains(startsWith('Injected:'))));
        expect(
          _head(r),
          isNot(matches(RegExp(r'(^|[^\r])\n'))),
          reason: 'bare LF in the head',
        );
      },
      skip: notBuilt,
    );
  });

  group('P0-3 Transfer-Encoding is a validated token list', () {
    const chunked = '4\r\nabcd\r\n0\r\n\r\n';
    Future<String> post(String te) => _raw(
      port,
      'POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: $te\r\n'
      'Connection: close\r\n\r\n$chunked',
    );

    test(
      '"Chunked" (any case) is decoded as chunked, not as no body',
      () async {
        final r = await post('Chunked');
        expect(_status(r), contains(' 200 '));
        expect(jsonDecode(_body(r)), {'len': 4});
      },
      skip: notBuilt,
    );

    for (final te in ['notchunked', 'gzip', 'chunked, gzip']) {
      test('"$te" is refused (400/501) rather than guessed', () async {
        final r = await post(te);
        expect(_status(r), anyOf(contains(' 400 '), contains(' 501 ')));
      }, skip: notBuilt);
    }
  });

  group('P0-2 response splitting via a handler-set header', () {
    test(
      'a CR/LF in a handler header value is a 500, never on the wire',
      () async {
        final r = await _raw(
          port,
          'GET /split HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
        );
        expect(_status(r), contains(' 500 '));
        expect(_head(r), isNot(contains('Injected')));
        expect(_head(r).toLowerCase(), isNot(contains('x-split')));
      },
      skip: notBuilt,
    );
  });

  group('P0-6 error details', () {
    test('a throwing handler is a generic 500; details go to events', () async {
      final events = <ServerEvent>[];
      final sub = server.events.listen(events.add);
      final r = await _raw(
        port,
        'GET /boom HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
      );
      expect(_status(r), contains(' 500 '));
      expect(_body(r), 'internal server error');
      expect(r, isNot(contains('hunter2')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();
      final e = events.firstWhere(
        (e) => e.kind == ServerEventKind.handlerError,
      );
      expect(e.message, contains('hunter2'));
      expect(e.message, contains('GET /boom'));
    }, skip: notBuilt);
  });

  group('P1 HTTP/1.1 conformance on the wire', () {
    test('every answer carries Date; 204 has no Content-Length', () async {
      final r = await _raw(
        port,
        'GET /s/index.html HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
      );
      expect(_head(r).toLowerCase(), contains('\r\ndate: '));
      expect(_head(r), contains(' GMT'));
    }, skip: notBuilt);
  });

  group('P0-4 chunk-size parsing', () {
    test('trailing garbage in a chunk-size line is a 400', () async {
      final r = await _raw(
        port,
        'POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n'
        'Connection: close\r\n\r\n4zz\r\nabcd\r\n0\r\n\r\n',
      );
      expect(_status(r), contains(' 400 '));
    }, skip: notBuilt);
  });
}
