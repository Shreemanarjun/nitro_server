// Facade coverage: every `NitroServer` shorthand and value-type line, against
// fakes. The engine behavior behind these is covered by the e2e and C++
// suites; what lives here is the promise that each public entry point reaches
// the bridge with the right wire values.
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_server/nitro_server.dart';
import 'package:nitro_server/src/internal/instance_keys.dart';
import 'package:nitro_server/src/internal/native_attach.dart';
import 'package:nitro_server/src/internal/server_runner.dart';
import 'package:nitro_server/src/nitro_server.native.dart';

import 'support/fakes.dart';

void main() {
  late FakeNitroServerNative fake;
  late NitroServer server;

  setUp(() {
    fake = FakeNitroServerNative();
    server = NitroServer.forRunnerForTesting(ServerRunner(fake));
  });

  tearDown(() async {
    await server.close();
    await fake.close();
    resetNativeAttachForTesting();
    Ids.resetForTesting();
  });

  Future<void> pump() => Future<void>.delayed(Duration.zero);

  group('shorthands', () {
    test('every verb shorthand registers its token', () async {
      Future<ResponseContext> ok(RequestContext _) async {
        return const ResponseContext();
      }
      await server.get('/get', ok);
      await server.head('/head', ok);
      await server.post('/post', ok);
      await server.put('/put', ok);
      await server.delete('/delete', ok);
      await server.patch('/patch', ok);
      await server.options('/options', ok);
      await server.all('/all', ok);

      final methods = {
        for (final r in fake.registered) r.pattern: r.method,
      };
      expect(methods, {
        '/get': RawServerMethod.get,
        '/head': RawServerMethod.head,
        '/post': RawServerMethod.post,
        '/put': RawServerMethod.put,
        '/delete': RawServerMethod.delete,
        '/patch': RawServerMethod.patch,
        '/options': RawServerMethod.options,
        '/all': RawServerMethod.all,
      });
    });

    test('timeouts ride through the shorthand', () async {
      await server.get(
        '/t',
        (_) async => const ResponseContext(),
        timeout: const Duration(milliseconds: 250),
      );
      expect(fake.registered.single.timeoutMs, 250);
    });

    test('no timeout inherits the server default', () async {
      await server.get('/d', (_) async => const ResponseContext());
      expect(fake.registered.single.timeoutMs, -1);
    });

    test('unroute forwards method and pattern', () async {
      await server.get('/gone', (_) async => const ResponseContext());
      await server.unroute(HttpMethod.get, '/gone');
      expect(fake.unregistered, [('GET', '/gone')]);
    });

    test('port and events delegate to the runner', () async {
      expect(server.port, 0);
      final kinds = <ServerEventKind>[];
      final sub = server.events.listen((e) => kinds.add(e.kind));
      await server.get('/e', (_) async => const ResponseContext());
      fake.events.add(const RawServerEvent(kind: 4, message: 'hi'));
      await pump();
      await pump();
      expect(kinds, [ServerEventKind.notice]);
      await sub.cancel();
    });

    test('route validates before touching native', () async {
      await expectLater(
        server.route(HttpMethod.get, 'nope', (_) async {
          return const ResponseContext();
        }),
        throwsA(isA<ArgumentError>()),
      );
      expect(fake.registered, isEmpty);
    });
  });

  group('value types', () {
    test('TlsConfig.enabled', () {
      expect(const TlsConfig().enabled, isFalse);
      expect(const TlsConfig(certPem: 'c', keyPem: 'k').enabled, isTrue);
      expect(const TlsConfig(certFile: 'c').enabled, isTrue);
      expect(const TlsConfig(keyFile: 'k').enabled, isTrue);
    });

    test('ServerEvent toString names the kind', () {
      expect(
        const ServerEvent(
          kind: ServerEventKind.started,
          requestId: 0,
          message: 'up',
        ).toString(),
        contains('started'),
      );
    });

    test('exceptions render their messages', () {
      expect(
        const ServerBindException('denied').toString(),
        contains('denied'),
      );
      expect(
        const ServerBindException('x'),
        isA<NitroServerException>(),
      );
    });

    test('ServerConfig stores its tuning', () {
      const config = ServerConfig(
        host: '0.0.0.0',
        port: 8080,
        backlog: 64,
        maxBodyBytes: 1024,
        defaultTimeout: Duration(seconds: 5),
      );
      expect(config.host, '0.0.0.0');
      expect(config.port, 8080);
      expect(config.backlog, 64);
      expect(config.maxBodyBytes, 1024);
      expect(config.defaultTimeout, const Duration(seconds: 5));
      expect(config.tls.enabled, isFalse);
    });
  });

  group('runner seams', () {
    test('stop delegates to native', () async {
      final runner = ServerRunner(fake);
      addTearDown(runner.close);
      runner.addRoute(
        HttpMethod.get,
        '',
        '/',
        null,
        (_) async => const ResponseContext(),
      );
      runner.stop();
      expect(fake.stopCalls, 1);
    });

    test('pendingIds tracks unfinished requests', () async {
      final runner = ServerRunner(fake);
      addTearDown(runner.close);
      runner.addRoute(
        HttpMethod.post,
        '',
        '/p',
        null,
        (_) async => const ResponseContext(),
      );
      await pump();
      expect(runner.pendingIdsForTesting, isEmpty);
      fake.heads.add(
        fakeHead(
          requestId: 40,
          method: RawServerMethod.post,
          path: '/p',
          hasBody: true,
          contentLength: 1,
          routePattern: '/p',
        ),
      );
      await pump();
      expect(runner.pendingIdsForTesting, {40});
      fake.chunks.add(fakeData(40, [1]));
      fake.chunks.add(fakeEnd(40));
      for (var i = 0;
          runner.pendingIdsForTesting.isNotEmpty && i < 200;
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(runner.pendingIdsForTesting, isEmpty);
    });

    test('an early error attaches when its head lands, then drops', () async {
      var calls = 0;
      final runner = ServerRunner(fake);
      addTearDown(runner.close);
      runner.addRoute(HttpMethod.post, '', '/ee', null, (_) async {
        calls++;
        return const ResponseContext();
      });
      await pump();

      fake.chunks.add(
        RawBodyChunk(
          bytes: Uint8List.fromList('early'.codeUnits),
          requestId: 41,
          kind: RawBodyKind.error.index,
          aux: 0,
        ),
      );
      await pump();
      fake.heads.add(
        fakeHead(
          requestId: 41,
          method: RawServerMethod.post,
          path: '/ee',
          hasBody: true,
          contentLength: 5,
          routePattern: '/ee',
        ),
      );
      fake.chunks.add(fakeEnd(41));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // Terminal error: the engine already answered, so no dispatch.
      expect(calls, 0);
      expect(fake.responded.where((r) => r.requestId == 41), isEmpty);
      // …but the payload was still acked exactly once.
      expect(fake.acked.where((a) => a.$1 == 41), [(41, 1)]);
    });

    test('orphan chunks are bounded', () async {
      final runner = ServerRunner(fake);
      addTearDown(runner.close);
      runner.addRoute(
        HttpMethod.get,
        '',
        '/',
        null,
        (_) async => const ResponseContext(),
      );
      await pump();
      // 1100 headless requests per orphan kind: each parks one entry, then
      // the bound reaps the oldest. No head ever arrives, so nothing
      // dispatches — exercising all three eviction branches.
      for (var i = 100; i < 1200; i++) {
        fake.chunks.add(fakeData(i, [1]));
      }
      for (var i = 2000; i < 3100; i++) {
        fake.chunks.add(
          RawBodyChunk(
            bytes: Uint8List.fromList([1]),
            requestId: i,
            kind: RawBodyKind.error.index,
            aux: 0,
          ),
        );
      }
      for (var i = 4000; i < 5100; i++) {
        fake.chunks.add(fakeEnd(i));
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(fake.responded, isEmpty);
    });

    test('stream errors never escape the runner', () async {
      final runner = ServerRunner(fake);
      addTearDown(runner.close);
      runner.addRoute(
        HttpMethod.get,
        '',
        '/',
        null,
        (_) async => const ResponseContext(),
      );
      await pump();
      // A bridge failure surfaces as a stream error; the runner swallows it
      // rather than crashing the isolate, and keeps serving afterwards.
      fake.heads.addError(StateError('bridge hiccup'));
      fake.chunks.addError(StateError('bridge hiccup'));
      fake.events.addError(StateError('bridge hiccup'));
      await pump();
      fake.heads.add(fakeHead(requestId: 42, path: '/', routePattern: '/'));
      for (var i = 0; i < 200; i++) {
        if (fake.responded.any((r) => r.requestId == 42)) break;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(fake.responded.any((r) => r.requestId == 42), isTrue);
    });

    test('a background isolate never reconciles native state', () async {
      // Mirrors nitro_http: a background isolate's statics are fresh too, so
      // it cannot tell a hot restart from simply being new. If it reconciled,
      // it would stop the root isolate's servers.
      final debugName = await Isolate.run(() {
        ensureNativeAttached();
        return Isolate.current.debugName;
      });
      expect(debugName, isNot('main'));
      expect(nativeAttachedForTesting, isFalse);
    });
  });
}
