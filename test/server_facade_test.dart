// Facade coverage: every `NitroServer` shorthand and value-type line, against
// fakes. The engine behavior behind these is covered by the e2e and C++
// suites; what lives here is the promise that each public entry point reaches
// the bridge with the right wire values.
import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:nitro_server/nitro_server.dart';
import 'package:nitro_server/src/internal/instance_keys.dart';
import 'package:nitro_server/src/internal/native_attach.dart';
import 'package:nitro_server/src/internal/server_runner.dart';
import 'package:nitro_server/src/nitro_server.native.dart';

import 'support/fakes.dart';

void main() {
  late FakeNitroServerNative fake;
  late ServerRunner runner;
  late NitroServer server;

  setUp(() {
    fake = FakeNitroServerNative();
    runner = ServerRunner(fake);
    server = NitroServer.forRunnerForTesting(runner);
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

      final methods = {for (final r in fake.registered) r.pattern: r.method};
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

  group('route groups', () {
    test('verbs join the prefix', () async {
      Future<ResponseContext> ok(RequestContext _) async {
        return const ResponseContext();
      }

      final api = server.group('/api');
      await api.get('/users', ok);
      await api.post('/users', ok);
      await api.head('/head', ok);
      await api.put('/put', ok);
      await api.delete('/delete', ok);
      await api.patch('/patch', ok);
      await api.options('/options', ok);
      await api.all('/wild', ok);
      await api.ws('/live', (_) async {});

      expect(
        {for (final r in fake.registered) r.pattern: r.method},
        {
          '/api/users': RawServerMethod.post,
          '/api/head': RawServerMethod.head,
          '/api/put': RawServerMethod.put,
          '/api/delete': RawServerMethod.delete,
          '/api/patch': RawServerMethod.patch,
          '/api/options': RawServerMethod.options,
          '/api/wild': RawServerMethod.all,
          '/api/live': RawServerMethod.get,
        },
      );
      expect(fake.registered.last.isWebSocket, isTrue);
    });

    test('nesting appends, slashes collapse, root is identity', () async {
      Future<ResponseContext> ok(RequestContext _) async {
        return const ResponseContext();
      }

      final v2 = server.group('/api').group('/v2');
      expect(v2.prefix, '/api/v2');
      await v2.get('/x', ok);
      await server.group('/').get('/root', ok);
      await server.group('/trail/').get('/x', ok);

      expect(
        {for (final r in fake.registered) r.pattern},
        {'/api/v2/x', '/root', '/trail/x'},
      );
    });

    test('a bare prefix throws before touching native', () {
      expect(() => server.group('api'), throwsArgumentError);
      expect(fake.registered, isEmpty);
    });

    test('grouped routes dispatch and unroute by prefixed pattern', () async {
      final api = server.group('/api');
      await api.get('/users/:id', (request) async {
        return ResponseContext.text('user ${request.param('id')}');
      });
      final response = await driveRequest(
        fake,
        requestId: 40,
        path: '/api/users/7',
        routePattern: '/api/users/:id',
        params: const [RawRouteParam(name: 'id', value: '7')],
      );
      expect(String.fromCharCodes(response.body), 'user 7');

      await api.unroute(HttpMethod.get, '/users/:id');
      expect(fake.unregistered, [('GET', '/api/users/:id')]);
    });
  });

  group('fallbacks', () {
    setUp(() {
      // These tests drive requests with no routes registered and no
      // `start()`: subscribe here, the way `bind` would in production, or
      // the fake's broadcast streams drop the head before any listener
      // exists. (Scoped to this group: the runner-seams tests below create
      // a second runner on the same fake and assert single-consumer
      // dispatch and ack invariants.)
      runner.ensureListeningForTesting();
    });

    test('unknown routes answer empty 404 by default', () async {
      final response = await driveRequest(
        fake,
        requestId: 41,
        path: '/ghost',
        routePattern: '/ghost',
      );
      expect(response.status, 404);
      expect(response.body, isEmpty);
    });

    test('custom sync and async not-found pages see the request', () async {
      server.notFoundHandler = (request) =>
          ResponseContext.text('lost: ${request.path}', status: 404);
      var response = await driveRequest(
        fake,
        requestId: 42,
        path: '/a',
        routePattern: '/a',
      );
      expect(String.fromCharCodes(response.body), 'lost: /a');

      server.notFoundHandler = (request) async =>
          ResponseContext.text('async lost', status: 404);
      response = await driveRequest(
        fake,
        requestId: 43,
        path: '/b',
        routePattern: '/b',
      );
      expect(response.status, 404);
      expect(String.fromCharCodes(response.body), 'async lost');
    });

    test('a throwing not-found fallback degrades to empty 404', () async {
      server.notFoundHandler = (_) => throw StateError('no page');
      final response = await driveRequest(
        fake,
        requestId: 44,
        path: '/c',
        routePattern: '/c',
      );
      expect(response.status, 404);
      expect(response.body, isEmpty);
    });

    test('a throwing handler is a 500 naming the error', () async {
      await server.get('/boom', (_) async => throw StateError('kaput'));
      final response = await driveRequest(
        fake,
        requestId: 45,
        path: '/boom',
        routePattern: '/boom',
      );
      expect(response.status, 500);
      expect(String.fromCharCodes(response.body), contains('kaput'));
    });

    test('custom error pages see the error, sync or async', () async {
      await server.get('/sync-boom', (_) => throw StateError('sync'));
      await server.get('/async-boom', (_) async => throw StateError('async'));
      server.errorHandler = (error, request) =>
          ResponseContext.text('oops $error @ ${request.path}', status: 500);

      var response = await driveRequest(
        fake,
        requestId: 46,
        path: '/sync-boom',
        routePattern: '/sync-boom',
      );
      expect(String.fromCharCodes(response.body), contains('sync'));

      server.errorHandler = (error, _) async =>
          ResponseContext.text('async oops', status: 500);
      response = await driveRequest(
        fake,
        requestId: 47,
        path: '/async-boom',
        routePattern: '/async-boom',
      );
      expect(String.fromCharCodes(response.body), 'async oops');
    });

    test('a throwing error fallback degrades to the default 500', () async {
      await server.get('/boom2', (_) async => throw StateError('kaput'));
      server.errorHandler = (error, _) => throw StateError('worse');
      final response = await driveRequest(
        fake,
        requestId: 48,
        path: '/boom2',
        routePattern: '/boom2',
      );
      expect(response.status, 500);
      expect(String.fromCharCodes(response.body), contains('kaput'));
    });
  });

  group('middleware', () {
    test('accessLog prints by default and names custom methods', () async {
      final lines = <String>[];
      await runZoned(
        () async {
          await server.use(accessLog());
          await server.route(
            HttpMethod.custom,
            '/p',
            (_) => const ResponseContext(),
            customMethod: 'PURGE',
          );
          await driveRequest(
            fake,
            requestId: 60,
            method: RawServerMethod.custom,
            customMethod: 'PURGE',
            path: '/p',
            routePattern: '/p',
          );
        },
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, line) => lines.add(line),
        ),
      );
      expect(lines, hasLength(1));
      expect(lines.single, startsWith('"PURGE /p" 200 '));
    });
  });

  group('value types', () {
    test('ResponseContext.isStream tells the two body kinds apart', () {
      expect(const ResponseContext().isStream, isFalse);
      expect(
        ResponseContext.stream(const Stream<Uint8List>.empty()).isStream,
        isTrue,
      );
    });

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
      expect(const ServerBindException('x'), isA<NitroServerException>());
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
    test(
      'close(drain:) drains until in-flight reaches zero, then stops',
      () async {
        fake.inFlight = 3;
        fake.live = 5;
        await server.close(drain: const Duration(seconds: 2));
        expect(fake.drained, isTrue);
        expect(fake.inFlight, 0);
        expect(fake.live, 0);
        expect(fake.stopCalls, 1);
      },
    );

    test('a drain past its deadline still stops', () async {
      fake.inFlight = 1 << 30;
      final started = DateTime.now();
      await server.close(drain: const Duration(milliseconds: 30));
      expect(DateTime.now().difference(started).inMilliseconds, lessThan(2000));
      expect(fake.stopCalls, 1);
    });

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
      for (var i = 0; runner.pendingIdsForTesting.isNotEmpty && i < 200; i++) {
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
