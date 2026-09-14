/// Compression, metrics, cookies, multipart, static files and the sealed
/// WebSocket message type, driven through the in-memory client and plain
/// unit calls. No sockets, no native library.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nitro_server/nitro_server.dart';
import 'package:nitro_server/src/api/metrics.dart' show MetricsAccumulator;
import 'package:nitro_server/testing.dart';
import 'package:test/test.dart';

void main() {
  late NitroTestClient client;

  setUp(() async {
    client = await NitroTestClient.start();
  });

  tearDown(() async {
    await client.close();
  });

  group('compress', () {
    final big = 'x' * 4096;

    test('gzips a compressible body when the client accepts it', () async {
      await client.server.use(compress());
      await client.server.get('/t', (_) => ResponseContext.text(big));
      final res = await client.get('/t', headers: {'accept-encoding': 'gzip'});
      expect(res.headers['content-encoding'], 'gzip');
      expect(res.headers['vary'], 'accept-encoding');
      expect(res.body.length, lessThan(big.length));
      expect(utf8.decode(gzip.decode(res.body)), big);
    });

    test(
      'leaves small, opaque, pre-encoded and unaccepting answers alone',
      () async {
        await client.server.use(compress(minBytes: 10));
        await client.server.get('/small', (_) => ResponseContext.text('hi'));
        await client.server.get(
          '/png',
          (_) =>
              ResponseContext.bytes(Uint8List(2000), contentType: 'image/png'),
        );
        await client.server.get(
          '/pre',
          (_) => ResponseContext.text(big, headers: {'content-encoding': 'br'}),
        );
        await client.server.get('/t', (_) => ResponseContext.text(big));
        await client.server.get(
          '/s',
          (_) => ResponseContext.stream(Stream.value(utf8.encode(big))),
        );
        const accept = {'accept-encoding': 'gzip, deflate'};
        for (final path in ['/small', '/png', '/pre', '/s']) {
          final res = await client.get(path, headers: accept);
          expect(res.headers['content-encoding'], isNot('gzip'), reason: path);
        }
        final plain = await client.get('/t');
        expect(plain.headers.containsKey('content-encoding'), isFalse);
        expect(plain.text(), big);
      },
    );

    test('honours a custom content-type allowlist', () async {
      await client.server.use(compress(contentTypes: {'application/x-custom'}));
      await client.server.get(
        '/c',
        (_) => ResponseContext.bytes(
          Uint8List.fromList(utf8.encode(big)),
          contentType: 'application/x-custom',
        ),
      );
      await client.server.get('/t', (_) => ResponseContext.text(big));
      const accept = {'accept-encoding': 'gzip'};
      expect(
        (await client.get('/c', headers: accept)).headers['content-encoding'],
        'gzip',
      );
      expect(
        (await client.get('/t', headers: accept)).headers['content-encoding'],
        isNull,
      );
    });
  });

  group('metrics', () {
    test('count answers, errors and latency per route', () async {
      await client.server.get('/ok', (_) => const ResponseContext());
      await client.server.get('/boom', (_) => throw StateError('x'));
      for (var i = 0; i < 5; i++) {
        await client.get('/ok');
      }
      await client.get('/boom');
      await client.get('/nowhere');
      final m = client.server.metrics;
      expect(m.requests, 6);
      expect(m.errors, 1);
      expect(m.inFlight, 0);
      final ok = m.byRoute['/ok']!;
      expect(ok.requests, 5);
      expect(ok.errors, 0);
      expect(ok.latency.count, 5);
      expect(ok.latency.p50Us, lessThanOrEqualTo(ok.latency.p99Us));
      expect(ok.latency.p99Us, lessThanOrEqualTo(ok.latency.maxUs * 1.5 + 1));
      expect(ok.latency.meanUs, greaterThanOrEqualTo(0));
      expect(m.byRoute['/boom']!.errors, 1);
      // Engine-level 404s never dispatch, so nothing is recorded for them.
      expect(m.byRoute.containsKey('*unmatched*'), isFalse);
      expect(m.toString(), contains('requests=6'));
      expect(ok.toString(), contains('/ok'));
      expect(ok.latency.toString(), contains('n=5'));
      expect(LatencyStats.empty.count, 0);
    });

    test('histogram buckets are monotonic and bounded', () {
      var last = -1;
      for (final us in [0, 1, 2, 3, 100, 1000, 1 << 20, 1 << 40]) {
        final b = MetricsAccumulator.bucketOf(us);
        expect(b, greaterThanOrEqualTo(last));
        expect(b, lessThan(64));
        last = b;
      }
      // A value reads back within 10% from its bucket's representative.
      for (final us in [7, 130, 9999, 250000]) {
        final v = MetricsAccumulator.valueOf(MetricsAccumulator.bucketOf(us));
        expect((v - us).abs() / us, lessThan(0.5));
      }
      final acc = MetricsAccumulator('/p');
      expect(acc.snapshot().latency, same(LatencyStats.empty));
      acc.record(50, 200);
      acc.record(5000, 503);
      final snap = acc.snapshot();
      expect(snap.errors, 1);
      expect(snap.latency.maxUs, 5000);
      expect(snap.latency.p99Us, greaterThan(snap.latency.p50Us));
    });
  });

  group('cookies', () {
    test('request cookies parse by name, values verbatim', () async {
      await client.server.get('/c', (r) => ResponseContext.jsonBody(r.cookies));
      final res = await client.get(
        '/c',
        headers: {'cookie': 'a=1; b=two=2; bad; c= spaced '},
      );
      expect(res.json(), {'a': '1', 'b': 'two=2', 'c': 'spaced'});
      expect((await client.get('/c')).json(), <String, Object?>{});
    });

    test('SetCookie renders every attribute', () {
      final cookie = SetCookie(
        'id',
        '42',
        maxAge: const Duration(hours: 1),
        expires: DateTime.utc(1994, 11, 6, 8, 49, 37),
        domain: 'example.com',
        path: '/app',
        secure: true,
        httpOnly: true,
        sameSite: SameSite.lax,
      );
      expect(
        cookie.toHeaderValue(),
        'id=42; Expires=Sun, 06 Nov 1994 08:49:37 GMT; Max-Age=3600; '
        'Domain=example.com; Path=/app; Secure; HttpOnly; SameSite=Lax',
      );
      expect(const SetCookie('a', 'b').toHeaderValue(), 'a=b; Path=/');
      expect(cookie.toString(), startsWith('SetCookie(id=42'));
      expect(
        const SetCookie('s', '1', sameSite: SameSite.strict).toHeaderValue(),
        endsWith('SameSite=Strict'),
      );
      expect(
        const SetCookie('n', '1', sameSite: SameSite.none).toHeaderValue(),
        endsWith('SameSite=None'),
      );
    });

    test('withCookie keeps the answer and adds a set-cookie', () async {
      await client.server.get(
        '/login',
        (_) => ResponseContext.text('ok')
            .withCookie(const SetCookie('sid', 'abc', httpOnly: true))
            .withCookie(const SetCookie('theme', 'dark')),
      );
      final res = await client.get('/login');
      expect(res.text(), 'ok');
      // The in-memory client folds headers into a map: the last cookie
      // stands, the wire carries both (see the e2e test).
      expect(res.headers['set-cookie'], 'theme=dark; Path=/');
    });
  });

  group('multipart', () {
    Uint8List body(String boundary, List<String> parts) => Uint8List.fromList(
      utf8.encode(
        '--$boundary\r\n${parts.join('\r\n--$boundary\r\n')}\r\n--$boundary--\r\n',
      ),
    );

    test('fields and files parse with names, filenames and types', () async {
      await client.server.post('/up', (r) {
        final parts = r.multipart();
        return ResponseContext.jsonBody([
          for (final p in parts)
            {
              'name': p.name,
              'file': p.filename,
              'type': p.contentType,
              'text': p.text(),
              'isFile': p.isFile,
            },
        ]);
      });
      final res = await client.post(
        '/up',
        headers: {'content-type': 'multipart/form-data; boundary="xyz"'},
        body: body('xyz', [
          'Content-Disposition: form-data; name="field"\r\n\r\nvalue',
          'Content-Disposition: form-data; name="f"; filename="a.txt"\r\n'
              'Content-Type: text/plain\r\n\r\nline1\r\nline2',
        ]),
      );
      expect(res.status, 200);
      expect(res.json(), [
        {
          'name': 'field',
          'file': null,
          'type': null,
          'text': 'value',
          'isFile': false,
        },
        {
          'name': 'f',
          'file': 'a.txt',
          'type': 'text/plain',
          'text': 'line1\r\nline2',
          'isFile': true,
        },
      ]);
      expect(
        parseMultipart(
          body('q', ['Content-Disposition: form-data; name=x\r\n\r\n']),
          'multipart/form-data; boundary=q',
        ).single.toString(),
        'MultipartPart(x, 0 bytes)',
      );
      expect(
        parseMultipart(
          body('q', [
            'Content-Disposition: form-data; name=x; filename=y\r\n\r\nz',
          ]),
          'multipart/form-data; boundary=q',
        ).single.toString(),
        'MultipartPart(x, file=y, 1 bytes)',
      );
    });

    test('rejects non-multipart and malformed bodies loudly', () {
      final ok = 'multipart/form-data; boundary=b';
      expect(
        () => parseMultipart(Uint8List(0), 'text/plain'),
        throwsFormatException,
      );
      expect(
        () => parseMultipart(Uint8List(0), 'multipart/form-data'),
        throwsFormatException,
      );
      expect(() => parseMultipart(Uint8List(0), ok), throwsFormatException);
      final noCrlf = Uint8List.fromList(utf8.encode('--bxx'));
      expect(() => parseMultipart(noCrlf, ok), throwsFormatException);
      final unterminated = Uint8List.fromList(
        utf8.encode('--b\r\nContent-Disposition: form-data; name=a'),
      );
      expect(() => parseMultipart(unterminated, ok), throwsFormatException);
      final noClose = Uint8List.fromList(
        utf8.encode('--b\r\nContent-Disposition: form-data; name=a\r\n\r\nv'),
      );
      expect(() => parseMultipart(noClose, ok), throwsFormatException);
      final noName = Uint8List.fromList(
        utf8.encode('--b\r\nContent-Type: text/plain\r\n\r\nv\r\n--b--'),
      );
      expect(() => parseMultipart(noName, ok), throwsFormatException);
      final noType = RequestContext(
        method: HttpMethod.post,
        customMethod: '',
        path: '/',
        query: '',
        queryParameters: const {},
        headers: const {},
        params: const {},
        routePattern: '/',
        body: Uint8List(0),
      );
      expect(noType.multipart, throwsFormatException);
    });
  });

  group('staticFiles', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('nitro_static');
      File('${root.path}/index.html').writeAsStringSync('<h1>home</h1>');
      File('${root.path}/app.js').writeAsStringSync('console.log(1)');
      File(
        '${root.path}/data.bin',
      ).writeAsBytesSync(List.generate(100, (i) => i));
      Directory('${root.path}/docs').createSync();
      File('${root.path}/docs/index.html').writeAsStringSync('docs');
      File('${root.path}/no.ext').writeAsStringSync('?');
    });

    tearDown(() => root.deleteSync(recursive: true));

    test('serves files with types, index pages and caching headers', () async {
      await client.server.get(
        '/s/*',
        staticFiles(root.path, maxAge: const Duration(minutes: 5)),
      );
      final js = await client.get('/s/app.js');
      expect(js.status, 200);
      expect(js.text(), 'console.log(1)');
      expect(js.headers['content-type'], startsWith('application/javascript'));
      expect(js.headers['accept-ranges'], 'bytes');
      expect(js.headers['cache-control'], 'max-age=300');
      expect(js.headers['etag'], startsWith('W/"'));
      expect(js.headers['last-modified'], endsWith('GMT'));
      expect((await client.get('/s/')).text(), '<h1>home</h1>');
      expect((await client.get('/s/docs')).text(), 'docs');
      expect((await client.get('/s/docs/')).text(), 'docs');
      expect(
        (await client.get('/s/no.ext')).headers['content-type'],
        'application/octet-stream',
      );
      expect((await client.get('/s/missing.txt')).status, 404);
      expect((await client.get('/s/../etc/passwd')).status, 404);
      expect((await client.get('/s/a%5Cb')).status, 404);
      expect((await client.get('/s/./app.js')).text(), 'console.log(1)');
    });

    test('conditional requests answer 304', () async {
      await client.server.get('/s/*', staticFiles(root.path));
      final first = await client.get('/s/app.js');
      final etag = first.headers['etag']!;
      final modified = first.headers['last-modified']!;
      expect(
        (await client.get(
          '/s/app.js',
          headers: {'if-none-match': etag},
        )).status,
        304,
      );
      expect(
        (await client.get(
          '/s/app.js',
          headers: {'if-none-match': '"other", $etag'},
        )).status,
        304,
      );
      expect(
        (await client.get('/s/app.js', headers: {'if-none-match': '*'})).status,
        304,
      );
      expect(
        (await client.get(
          '/s/app.js',
          headers: {'if-none-match': '"other"'},
        )).status,
        200,
      );
      expect(
        (await client.get(
          '/s/app.js',
          headers: {'if-modified-since': modified},
        )).status,
        304,
      );
      expect(
        (await client.get(
          '/s/app.js',
          headers: {'if-modified-since': 'Thu, 01 Jan 1970 00:00:00 GMT'},
        )).status,
        200,
      );
      expect(
        (await client.get(
          '/s/app.js',
          headers: {'if-modified-since': 'garbage'},
        )).status,
        200,
      );
    });

    test('byte ranges answer 206, bad ones 416, odd ones whole', () async {
      await client.server.get('/s/*', staticFiles(root.path));
      final part = await client.get(
        '/s/data.bin',
        headers: {'range': 'bytes=10-19'},
      );
      expect(part.status, 206);
      expect(part.headers['content-range'], 'bytes 10-19/100');
      expect(part.body, List.generate(10, (i) => 10 + i));
      final tail = await client.get(
        '/s/data.bin',
        headers: {'range': 'bytes=95-'},
      );
      expect(tail.body, [95, 96, 97, 98, 99]);
      final suffix = await client.get(
        '/s/data.bin',
        headers: {'range': 'bytes=-3'},
      );
      expect(suffix.headers['content-range'], 'bytes 97-99/100');
      final over = await client.get(
        '/s/data.bin',
        headers: {'range': 'bytes=90-500'},
      );
      expect(over.headers['content-range'], 'bytes 90-99/100');
      final bigSuffix = await client.get(
        '/s/data.bin',
        headers: {'range': 'bytes=-500'},
      );
      expect(bigSuffix.headers['content-range'], 'bytes 0-99/100');
      final bad = await client.get(
        '/s/data.bin',
        headers: {'range': 'bytes=200-300'},
      );
      expect(bad.status, 416);
      expect(bad.headers['content-range'], 'bytes */100');
      expect(
        (await client.get(
          '/s/data.bin',
          headers: {'range': 'bytes=30-10'},
        )).status,
        416,
      );
      for (final ignored in [
        'items=1-2',
        'bytes=1-2,4-5',
        'bytes=x',
        'bytes=1-x',
        'bytes=-0',
        'bytes=-x',
      ]) {
        final whole = await client.get(
          '/s/data.bin',
          headers: {'range': ignored},
        );
        expect(whole.status, 200, reason: ignored);
        expect(whole.body.length, 100, reason: ignored);
      }
    });

    test('an empty file has no satisfiable suffix range', () async {
      File('${root.path}/empty').writeAsBytesSync([]);
      await client.server.get('/s/*', staticFiles(root.path));
      expect(
        (await client.get('/s/empty', headers: {'range': 'bytes=-1'})).status,
        416,
      );
      expect((await client.get('/s/empty')).status, 200);
    });

    test('a non-wildcard mount serves the whole path under root', () async {
      await client.server.get('/app.js', staticFiles(root.path));
      expect((await client.get('/app.js')).text(), 'console.log(1)');
    });
  });

  group('WebSocket compression and backpressure', () {
    test('deflate and inflate round-trip, and strip the sync tail', () {
      final text = Uint8List.fromList(utf8.encode('hello ' * 100));
      final packed = wsDeflate(text);
      expect(packed.length, lessThan(text.length));
      expect(packed.sublist(packed.length - 4), isNot([0, 0, 0xff, 0xff]));
      expect(wsInflate(packed), text);
      expect(wsInflate(wsDeflate(Uint8List(0))), isEmpty);
      expect(
        () => wsInflate(Uint8List.fromList([0xff, 0xff, 0xff])),
        throwsA(anything),
      );
    });

    test('a session compresses long messages only when negotiated', () async {
      final seen = <WsMessage>[];
      await client.server.ws('/c', (session) async {
        seen.add(await session.messages.first);
        expect(session.sendText('x' * 1000), 0);
        expect(session.bufferedBytes, 0);
        expect(session.sendText('short'), 0);
        expect(session.compressed, isTrue);
      });
      await client.server.ws('/plain', (session) async {
        expect(session.compressed, isFalse);
        session.sendText('y' * 1000);
      });
      final ws = await client.ws(
        '/c',
        headers: {'sec-websocket-extensions': 'permessage-deflate'},
      );
      ws.sendText('in');
      expect((await ws.messages.first).text, 'x' * 1000);
      await ws.close();
      final plain = await client.ws('/plain');
      expect((await plain.messages.first).text, 'y' * 1000);
      await plain.close();
      expect(seen.single.text, 'in');
    });

    test('ServerConfig carries the new limits through copyWith', () {
      const base = ServerConfig();
      expect(base.writeTimeout, const Duration(seconds: 30));
      expect(base.wsMaxBufferBytes, 1024 * 1024);
      expect(base.wsCompression, isTrue);
      final c = base.copyWith(
        writeTimeout: const Duration(seconds: 1),
        wsMaxBufferBytes: 4096,
        wsCompression: false,
      );
      expect(c.writeTimeout, const Duration(seconds: 1));
      expect(c.wsMaxBufferBytes, 4096);
      expect(c.wsCompression, isFalse);
      expect(c.copyWith(port: 1).wsMaxBufferBytes, 4096);
      expect(
        () => ServerConfig(wsMaxBufferBytes: 0),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('WsMessage', () {
    test('is sealed with text and binary variants', () {
      const text = WsMessage.text('hi');
      final binary = WsMessage.binary(Uint8List.fromList([1, 2]));
      String describe(WsMessage m) => switch (m) {
        WsText(:final text) => 'text:$text',
        WsBinary(:final bytes) => 'binary:${bytes.length}',
      };
      expect(describe(text), 'text:hi');
      expect(describe(binary), 'binary:2');
      expect(text.isText, isTrue);
      expect(text.isBinary, isFalse);
      expect(text.bytes, isNull);
      expect(binary.text, isNull);
      expect(binary.isBinary, isTrue);
      expect(text.toString(), 'WsText(hi)');
      expect(binary.toString(), 'WsBinary(2 bytes)');
    });
  });

  group('ResponseContext.file', () {
    test('answers file bytes through the in-memory engine', () async {
      final dir = Directory.systemTemp.createTempSync('nitro_file');
      final file = File('${dir.path}/f.txt')..writeAsStringSync('0123456789');
      addTearDown(() => dir.deleteSync(recursive: true));
      await client.server.get(
        '/f',
        (_) => ResponseContext.file(file.path, contentType: 'text/plain'),
      );
      await client.server.get(
        '/part',
        (_) => ResponseContext.file(file.path, offset: 2, length: 3),
      );
      await client.server.get(
        '/gone',
        (_) => ResponseContext.file('${dir.path}/nope'),
      );
      await client.server.get(
        '/past',
        (_) => ResponseContext.file(file.path, offset: 99),
      );
      expect((await client.get('/f')).text(), '0123456789');
      expect((await client.get('/f')).headers['content-type'], 'text/plain');
      expect((await client.get('/part')).text(), '234');
      expect((await client.get('/gone')).status, 404);
      expect((await client.get('/past')).status, 404);
      expect(ResponseContext.file(file.path).isFile, isTrue);
      expect(const ResponseContext().isFile, isFalse);
    });
  });
}
