// Edge cases: the inputs a production server meets in the wild that the
// happy-path suites never produce. All against fakes — no native library.
//
// Each test names the failure it guards, because an edge-case test without
// its "why" gets deleted the first time someone confuses it with redundancy.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_server/nitro_server.dart';
import 'package:nitro_server/src/internal/server_runner.dart';
import 'package:nitro_server/src/nitro_server.native.dart';

import 'support/fakes.dart';

void main() {
  late FakeNitroServerNative fake;
  late ServerRunner runner;

  setUp(() {
    fake = FakeNitroServerNative();
    runner = ServerRunner(fake);
  });

  tearDown(() async {
    await runner.close();
    await fake.close();
  });

  Future<void> addGet(String pattern, [RequestHandler? handler]) async {
    runner.addRoute(
      HttpMethod.get,
      '',
      pattern,
      null,
      handler ?? (_) async => const ResponseContext(),
    );
    await Future<void>.delayed(Duration.zero);
  }

  Future<DrivenResponse> waitFor(int requestId) async {
    for (var i = 0; i < 200; i++) {
      final found = fake.responded.where((r) => r.requestId == requestId);
      if (found.isNotEmpty) return found.first;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    throw StateError('no response for $requestId');
  }

  group('registration edges', () {
    test('re-registering a pattern replaces the handler, not the route', () async {
      runner.addRoute(
        HttpMethod.get,
        '',
        '/r',
        null,
        (_) async => ResponseContext.text('first'),
      );
      runner.addRoute(
        HttpMethod.get,
        '',
        '/r',
        null,
        (_) async => ResponseContext.text('second'),
      );
      await Future<void>.delayed(Duration.zero);

      final response = await driveRequest(
        fake,
        requestId: 1,
        path: '/r',
        routePattern: '/r',
      );
      expect(String.fromCharCodes(response.body), 'second');
      expect(fake.registered.length, 2);
    });

    test('unregistering an unknown route throws RouteNotFoundException', () {
      fake.unregisterFailures['/ghost'] = const RawServerStatus(
        errorKind: RawServerErrorKind.routeNotFound,
        errorMessage: 'no such route',
      );
      expect(
        () => runner.removeRoute(HttpMethod.get, '', '/ghost'),
        throwsA(isA<RouteNotFoundException>()),
      );
    });

    test('same pattern on different methods dispatches independently', () async {
      runner.addRoute(
        HttpMethod.get,
        '',
        '/m',
        null,
        (_) async => ResponseContext.text('get'),
      );
      runner.addRoute(
        HttpMethod.post,
        '',
        '/m',
        null,
        (_) async => ResponseContext.text('post'),
      );
      await Future<void>.delayed(Duration.zero);

      final getResponse = await driveRequest(
        fake,
        requestId: 2,
        path: '/m',
        routePattern: '/m',
      );
      final postResponse = await driveRequest(
        fake,
        requestId: 3,
        method: RawServerMethod.post,
        path: '/m',
        routePattern: '/m',
      );
      // Dispatch keys on the head method, not just the pattern.
      expect(String.fromCharCodes(getResponse.body), 'get');
      expect(String.fromCharCodes(postResponse.body), 'post');
    });

    test('custom-method heads dispatch by token', () async {
      RequestContext? seen;
      runner.addRoute(
        HttpMethod.custom,
        'PURGE',
        '/cache',
        null,
        (request) async {
          seen = request;
          return const ResponseContext();
        },
      );
      await Future<void>.delayed(Duration.zero);

      fake.heads.add(
        RawIncomingRequest(
          requestId: 4,
          method: RawServerMethod.custom,
          customMethod: 'PURGE',
          path: '/cache',
          routePattern: '/cache',
        ),
      );
      await waitFor(4);
      expect(seen!.method, HttpMethod.custom);
      expect(seen!.customMethod, 'PURGE');
    });

    test('a wrong custom token does not match', () async {
      await addGet('/cache');
      fake.heads.add(
        RawIncomingRequest(
          requestId: 5,
          method: RawServerMethod.custom,
          customMethod: 'BAN',
          path: '/cache',
          routePattern: '/cache',
        ),
      );
      final response = await waitFor(5);
      expect(response.status, 404);
    });
  });

  group('dispatch edges', () {
    test('a doubled end marker dispatches exactly once', () async {
      var calls = 0;
      runner.addRoute(HttpMethod.post, '', '/once', null, (_) async {
        calls++;
        return const ResponseContext();
      });
      await Future<void>.delayed(Duration.zero);

      fake.heads.add(
        fakeHead(
          requestId: 6,
          method: RawServerMethod.post,
          path: '/once',
          hasBody: true,
          contentLength: 1,
          routePattern: '/once',
        ),
      );
      fake.chunks.add(fakeData(6, [1]));
      fake.chunks.add(fakeEnd(6));
      fake.chunks.add(fakeEnd(6)); // Stale duplicate.
      await waitFor(6);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(calls, 1);
      expect(fake.responded.where((r) => r.requestId == 6), hasLength(1));
    });

    test('a doubled head dispatches exactly once', () async {
      var calls = 0;
      runner.addRoute(HttpMethod.get, '', '/d', null, (_) async {
        calls++;
        return const ResponseContext();
      });
      await Future<void>.delayed(Duration.zero);

      fake.heads.add(fakeHead(requestId: 7, path: '/d', routePattern: '/d'));
      fake.heads.add(fakeHead(requestId: 7, path: '/d', routePattern: '/d'));
      await waitFor(7);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(calls, 1);
    });

    test('hasBody with zero chunks still dispatches on end', () async {
      runner.addRoute(HttpMethod.post, '', '/zb', null, (request) async {
        return ResponseContext.text('n=${request.body.length}');
      });
      await Future<void>.delayed(Duration.zero);

      fake.heads.add(
        fakeHead(
          requestId: 8,
          method: RawServerMethod.post,
          path: '/zb',
          hasBody: true,
          contentLength: 0,
          routePattern: '/zb',
        ),
      );
      fake.chunks.add(fakeEnd(8));
      final response = await waitFor(8);
      expect(String.fromCharCodes(response.body), 'n=0');
    });

    test('a body error before any data never dispatches', () async {
      var calls = 0;
      runner.addRoute(HttpMethod.post, '', '/err0', null, (_) async {
        calls++;
        return const ResponseContext();
      });
      await Future<void>.delayed(Duration.zero);

      fake.heads.add(
        fakeHead(
          requestId: 9,
          method: RawServerMethod.post,
          path: '/err0',
          hasBody: true,
          contentLength: 10,
          routePattern: '/err0',
        ),
      );
      fake.chunks.add(
        RawBodyChunk(
          bytes: Uint8List.fromList('x'.codeUnits),
          requestId: 9,
          kind: RawBodyKind.error.index,
          aux: RawServerErrorKind.requestTooLarge.index,
        ),
      );
      fake.chunks.add(fakeEnd(9));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(calls, 0);
      expect(fake.responded.where((r) => r.requestId == 9), isEmpty);
    });

    test('empty query string parses to an empty map', () async {
      RequestContext? seen;
      runner.addRoute(HttpMethod.get, '', '/q', null, (request) async {
        seen = request;
        return const ResponseContext();
      });
      await Future<void>.delayed(Duration.zero);

      fake.heads.add(
        fakeHead(requestId: 10, path: '/q', query: '', routePattern: '/q'),
      );
      await waitFor(10);
      expect(seen!.query, isEmpty);
      expect(seen!.queryParameters, isEmpty);
    });

    test('head-only request carries empty headers and body', () async {
      RequestContext? seen;
      await addGet('/bare', (request) async {
        seen = request;
        return const ResponseContext();
      });
      fake.heads.add(
        fakeHead(requestId: 11, path: '/bare', routePattern: '/bare'),
      );
      await waitFor(11);
      expect(seen!.headers, isEmpty);
      expect(seen!.body, isEmpty);
      expect(seen!.params, isEmpty);
    });

    test('a sync-throwing handler still answers 500', () async {
      runner.addRoute(HttpMethod.get, '', '/sync-boom', null, (_) {
        throw StateError('sync');
      });
      await Future<void>.delayed(Duration.zero);

      final response = await driveRequest(
        fake,
        requestId: 12,
        path: '/sync-boom',
        routePattern: '/sync-boom',
      );
      expect(response.status, 500);
    });
  });

  group('config validation', () {
    test('patterns must be /-rooted', () async {
      final server = NitroServer.forRunnerForTesting(runner);
      await expectLater(
        server.route(HttpMethod.get, 'relative', (_) async {
          return const ResponseContext();
        }),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('custom without a token is rejected', () async {
      final server = NitroServer.forRunnerForTesting(runner);
      await expectLater(
        server.route(HttpMethod.custom, '/c', (_) async {
          return const ResponseContext();
        }),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('ServerConfig rejects nonsense', () {
      expect(() => ServerConfig(port: -1), throwsA(isA<AssertionError>()));
      expect(() => ServerConfig(port: 70000), throwsA(isA<AssertionError>()));
      expect(() => ServerConfig(backlog: 0), throwsA(isA<AssertionError>()));
      expect(
        () => ServerConfig(maxBodyBytes: 0),
        throwsA(isA<AssertionError>()),
      );
    });

    test('ResponseContext rejects out-of-range statuses', () {
      expect(() => ResponseContext(status: 99), throwsAssertionError);
      expect(() => ResponseContext(status: 1000), throwsAssertionError);
    });
  });

  group('lifecycle edges', () {
    test('close is idempotent', () async {
      await addGet('/');
      await runner.close();
      await runner.close();
      expect(fake.stopCalls, 1);
    });

    test('all event kinds map without throwing', () async {
      final kinds = <ServerEventKind>[];
      final sub = runner.events.listen((e) => kinds.add(e.kind));
      runner.addRoute(HttpMethod.get, '', '/', null, (_) async {
        return const ResponseContext();
      });
      for (var i = 0; i < ServerEventKind.values.length; i++) {
        fake.events.add(RawServerEvent(kind: i, message: 'm$i'));
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(kinds, ServerEventKind.values);
      await sub.cancel();
    });
  });
}

