// Unit tests for ServerRunner dispatch against the fake bridge.
// Covers: head-only dispatch, body reassembly, early (pre-head) chunks,
// terminal body errors, unknown-route 404, handler throws → 500,
// per-chunk ack accounting, event re-broadcast, register failure mapping.
import 'dart:typed_data';

import 'package:test/test.dart';
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

  Future<void> addEcho(String pattern) async {
    runner.addRoute(
      HttpMethod.get,
      '',
      pattern,
      null,
      (request) async => ResponseContext.text('got ${request.path}'),
    );
    // addRoute subscribes; let the subscription land before emitting.
    await Future<void>.delayed(Duration.zero);
  }

  group('dispatch', () {
    test('a head without a body dispatches immediately', () async {
      await addEcho('/');
      final response = await driveRequest(fake, requestId: 1);
      expect(response.status, 200);
      expect(String.fromCharCodes(response.body), 'got /');
    });

    test('a body is reassembled across chunks before dispatch', () async {
      RequestContext? seen;
      runner.addRoute(HttpMethod.post, '', '/upload', null, (request) async {
        seen = request;
        return ResponseContext.text('n=${request.body.length}');
      });
      await Future<void>.delayed(Duration.zero);

      fake.heads.add(
        fakeHead(
          requestId: 2,
          method: RawServerMethod.post,
          path: '/upload',
          hasBody: true,
          contentLength: 6,
          routePattern: '/upload',
        ),
      );
      // Two chunks before the end marker: dispatch must wait for both.
      fake.chunks.add(fakeData(2, [1, 2, 3]));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        fake.responded.where((r) => r.requestId == 2),
        isEmpty,
        reason: 'dispatched before the body completed',
      );
      fake.chunks.add(fakeData(2, [4, 5, 6]));
      fake.chunks.add(fakeEnd(2));

      for (var i = 0; i < 200; i++) {
        if (fake.responded.any((r) => r.requestId == 2)) break;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final response = fake.responded.firstWhere((r) => r.requestId == 2);
      expect(response.status, 200);
      expect(String.fromCharCodes(response.body), 'n=6');
      expect(seen!.body, orderedEquals([1, 2, 3, 4, 5, 6]));
    });

    test(
      'chunks that arrive before their head are parked, not dropped',
      () async {
        runner.addRoute(HttpMethod.post, '', '/early', null, (request) async {
          return ResponseContext.text('n=${request.body.length}');
        });
        await Future<void>.delayed(Duration.zero);

        fake.chunks.add(fakeData(3, [9, 9]));
        fake.chunks.add(fakeEnd(3));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        fake.heads.add(
          fakeHead(
            requestId: 3,
            method: RawServerMethod.post,
            path: '/early',
            hasBody: true,
            contentLength: 2,
            routePattern: '/early',
          ),
        );

        for (var i = 0; i < 200; i++) {
          if (fake.responded.any((r) => r.requestId == 3)) break;
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        final response = fake.responded.firstWhere((r) => r.requestId == 3);
        expect(String.fromCharCodes(response.body), 'n=2');
      },
    );

    test('params, query and headers reach the handler', () async {
      RequestContext? seen;
      runner.addRoute(HttpMethod.get, '', '/users/:id', null, (request) async {
        seen = request;
        return const ResponseContext();
      });
      await Future<void>.delayed(Duration.zero);

      fake.heads.add(
        fakeHead(
          requestId: 4,
          path: '/users/42',
          query: 'verbose=true',
          headers: const [
            RawHeader(name: 'X-Token', value: 'abc'),
            RawHeader(name: 'X-Token', value: 'def'),
          ],
          routePattern: '/users/:id',
          params: const [RawRouteParam(name: 'id', value: '42')],
        ),
      );

      for (var i = 0; i < 200; i++) {
        if (fake.responded.any((r) => r.requestId == 4)) break;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(seen!.param('id'), '42');
      expect(seen!.queryParameters, {'verbose': 'true'});
      expect(seen!.header('x-token'), 'abc');
      expect(seen!.headers['x-token'], ['abc', 'def']);
    });

    test('an all-method registration answers every method', () async {
      runner.addRoute(
        HttpMethod.all,
        '',
        '/any',
        null,
        (request) async => ResponseContext.text('m=${request.method.name}'),
      );
      await Future<void>.delayed(Duration.zero);

      for (final method in [RawServerMethod.get, RawServerMethod.post]) {
        fake.heads.add(
          fakeHead(
            requestId: method.index + 20,
            method: method,
            path: '/any',
            routePattern: '/any',
          ),
        );
      }
      for (var i = 0; i < 200; i++) {
        if (fake.responded.length >= 2) break;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(
        fake.responded.map((r) => String.fromCharCodes(r.body)),
        containsAll(['m=get', 'm=post']),
      );
    });

    test('a specific registration beats an all-method one', () async {
      runner.addRoute(
        HttpMethod.all,
        '',
        '/both',
        null,
        (_) async => ResponseContext.text('all'),
      );
      runner.addRoute(
        HttpMethod.get,
        '',
        '/both',
        null,
        (_) async => ResponseContext.text('specific'),
      );
      await Future<void>.delayed(Duration.zero);

      final response = await driveRequest(
        fake,
        requestId: 30,
        path: '/both',
        routePattern: '/both',
      );
      expect(String.fromCharCodes(response.body), 'specific');
    });

    test('an unregistered route pattern answers 404', () async {
      await addEcho('/');
      final response = await driveRequest(
        fake,
        requestId: 5,
        path: '/gone',
        routePattern: '/gone',
      );
      expect(response.status, 404);
    });

    test('a throwing handler answers 500, once', () async {
      runner.addRoute(HttpMethod.get, '', '/boom', null, (_) async {
        throw StateError('kaput');
      });
      await Future<void>.delayed(Duration.zero);

      final response = await driveRequest(
        fake,
        requestId: 6,
        path: '/boom',
        routePattern: '/boom',
      );
      expect(response.status, 500);
      expect(fake.responded.where((r) => r.requestId == 6), hasLength(1));
    });

    test('a terminal body error never reaches the handler', () async {
      var called = false;
      runner.addRoute(HttpMethod.post, '', '/big', null, (_) async {
        called = true;
        return const ResponseContext();
      });
      await Future<void>.delayed(Duration.zero);

      fake.heads.add(
        fakeHead(
          requestId: 7,
          method: RawServerMethod.post,
          path: '/big',
          hasBody: true,
          routePattern: '/big',
        ),
      );
      fake.chunks.add(
        RawBodyChunk(
          bytes: Uint8List.fromList('too big'.codeUnits),
          requestId: 7,
          kind: RawBodyKind.error.index,
          aux: RawServerErrorKind.requestTooLarge.index,
        ),
      );
      fake.chunks.add(fakeEnd(7));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(called, isFalse);
      expect(fake.responded.where((r) => r.requestId == 7), isEmpty);
    });

    test('response headers and status are forwarded', () async {
      runner.addRoute(HttpMethod.get, '', '/h', null, (_) async {
        return const ResponseContext(
          status: 201,
          headers: {'x-made-by': 'test'},
        );
      });
      await Future<void>.delayed(Duration.zero);

      final response = await driveRequest(
        fake,
        requestId: 8,
        path: '/h',
        routePattern: '/h',
      );
      expect(response.status, 201);
      expect(response.headers['x-made-by'], 'test');
    });
  });

  group('ack protocol', () {
    test('every copied chunk is acked cumulatively', () async {
      runner.addRoute(HttpMethod.post, '', '/a', null, (request) async {
        return ResponseContext.text('n=${request.body.length}');
      });
      await Future<void>.delayed(Duration.zero);

      fake.heads.add(
        fakeHead(
          requestId: 9,
          method: RawServerMethod.post,
          path: '/a',
          hasBody: true,
          contentLength: 3,
          routePattern: '/a',
        ),
      );
      fake.chunks.add(fakeData(9, [1]));
      fake.chunks.add(fakeData(9, [2]));
      fake.chunks.add(fakeData(9, [3]));
      fake.chunks.add(fakeEnd(9));

      for (var i = 0; i < 200; i++) {
        if (fake.responded.any((r) => r.requestId == 9)) break;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final acks = fake.acked.where((a) => a.$1 == 9).toList();
      expect(acks, [(9, 3)]);
    });

    test('early chunks are acked when complete', () async {
      runner.addRoute(HttpMethod.post, '', '/e', null, (_) async {
        return const ResponseContext();
      });
      await Future<void>.delayed(Duration.zero);

      fake.chunks.add(fakeData(10, [1, 2]));
      fake.heads.add(
        fakeHead(
          requestId: 10,
          method: RawServerMethod.post,
          path: '/e',
          hasBody: true,
          contentLength: 2,
          routePattern: '/e',
        ),
      );
      fake.chunks.add(fakeEnd(10));
      for (var i = 0; i < 200; i++) {
        if (fake.responded.any((r) => r.requestId == 10)) break;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(fake.responded.any((r) => r.requestId == 10), isTrue);
      final acks = fake.acked.where((a) => a.$1 == 10).toList();
      expect(acks, [(10, 1)]);
    });
  });

  group('routes and lifecycle', () {
    test('register failure throws the mapped exception', () {
      fake.registerFailures['/bad'] = const RawServerStatus(
        errorKind: RawServerErrorKind.badRequest,
        errorMessage: 'nope',
      );
      expect(
        () => runner.addRoute(
          HttpMethod.get,
          '',
          '/bad',
          null,
          (_) async => const ResponseContext(),
        ),
        throwsA(isA<ServerBadRequestException>()),
      );
    });

    test('unregister forwards the token and pattern', () {
      runner.addRoute(
        HttpMethod.get,
        '',
        '/x',
        null,
        (_) async => const ResponseContext(),
      );
      runner.removeRoute(HttpMethod.get, '', '/x');
      expect(fake.unregistered, [('GET', '/x')]);
    });

    test('custom methods round-trip their token', () {
      runner.addRoute(
        HttpMethod.custom,
        'PURGE',
        '/cache',
        null,
        (_) async => const ResponseContext(),
      );
      expect(fake.registered.single.customMethod, 'PURGE');
      runner.removeRoute(HttpMethod.custom, 'PURGE', '/cache');
      expect(fake.unregistered, [('PURGE', '/cache')]);
    });

    test('start configures then starts, returning the bound port', () {
      const config = ServerConfig(port: 0, host: '127.0.0.1');
      final port = runner.start(config);
      expect(port, 8080);
      expect(fake.configureCalls, 1);
      expect(fake.lastConfig!.host, '127.0.0.1');
      expect(fake.lastConfig!.port, 0);
      expect(fake.startCalls, 1);
    });

    test('start failure throws the mapped exception', () {
      fake.startResult = const RawServerStatus(
        errorKind: RawServerErrorKind.bindFailed,
        errorMessage: 'in use',
      );
      expect(
        () => runner.start(const ServerConfig()),
        throwsA(isA<ServerBindException>()),
      );
    });

    test('server events are re-broadcast', () async {
      final seen = <ServerEvent>[];
      final sub = runner.events.listen(seen.add);
      // Subscribing to events does not subscribe the native streams; the
      // runner subscribes natively on first route/start.
      runner.addRoute(
        HttpMethod.get,
        '',
        '/',
        null,
        (_) async => const ResponseContext(),
      );
      fake.events.add(
        const RawServerEvent(kind: 2, requestId: 11, message: 'slow'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(seen.single.kind, ServerEventKind.handlerTimeout);
      expect(seen.single.requestId, 11);
      await sub.cancel();
    });

    test(
      'close stops native and cancels without disposing the bridge',
      () async {
        await addEcho('/');
        await runner.close();
        expect(fake.stopCalls, 1);
        // Heads after close are ignored, never dispatched.
        fake.heads.add(fakeHead(requestId: 12));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(fake.responded, isEmpty);
      },
    );
  });
}
