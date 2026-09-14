// Edge cases: the inputs a production server meets in the wild that the
// happy-path suites never produce. All against fakes — no native library.
//
// Each test names the failure it guards, because an edge-case test without
// its "why" gets deleted the first time someone confuses it with redundancy.
import 'dart:async';
import 'dart:convert';
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
    test(
      're-registering a pattern replaces the handler, not the route',
      () async {
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
      },
    );

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

    test(
      'same pattern on different methods dispatches independently',
      () async {
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
      },
    );

    test('custom-method heads dispatch by token', () async {
      RequestContext? seen;
      runner.addRoute(HttpMethod.custom, 'PURGE', '/cache', null, (
        request,
      ) async {
        seen = request;
        return const ResponseContext();
      });
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
      expect(() => ResponseContext(status: 99), throwsA(isA<AssertionError>()));
      expect(
        () => ResponseContext(status: 1000),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('middleware', () {
    test('accessLog formats method, path, status and latency', () async {
      final lines = <String>[];
      runner.use(accessLog(sink: lines.add));
      runner.addRoute(
        HttpMethod.get,
        '',
        '/logged',
        null,
        (_) async => ResponseContext.text('ok'),
      );
      await Future<void>.delayed(Duration.zero);

      final response = await driveRequest(
        fake,
        requestId: 50,
        path: '/logged',
        routePattern: '/logged',
      );
      expect(response.status, 200);
      expect(lines.single, matches(r'"GET /logged" 200 \d+ms'));
    });

    test('accessLog records 500s for throwing handlers', () async {
      final lines = <String>[];
      runner.use(accessLog(sink: lines.add));
      runner.addRoute(HttpMethod.get, '', '/blogged', null, (_) async {
        throw StateError('nope');
      });
      await Future<void>.delayed(Duration.zero);

      await driveRequest(
        fake,
        requestId: 51,
        path: '/blogged',
        routePattern: '/blogged',
      );
      expect(lines.single, matches(r'"/blogged" 500 \d+ms'));
    });

    test('middleware applies to routes registered before use()', () async {
      var wrapped = false;
      runner.addRoute(HttpMethod.get, '', '/pre', null, (_) async {
        return const ResponseContext();
      });
      runner.use((request, next) async {
        wrapped = true;
        return next(request);
      });
      await Future<void>.delayed(Duration.zero);

      await driveRequest(
        fake,
        requestId: 52,
        path: '/pre',
        routePattern: '/pre',
      );
      expect(wrapped, isTrue);
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

    test('a late answer after close is dropped, never sent', () async {
      final gate = Completer<ResponseContext>();
      runner.addRoute(HttpMethod.get, '', '/slow', null, (_) => gate.future);
      await Future<void>.delayed(Duration.zero);

      fake.heads.add(
        fakeHead(requestId: 400, path: '/slow', routePattern: '/slow'),
      );
      // Wait until dispatch parks on the handler future…
      for (
        var i = 0;
        i < 200 && !runner.pendingIdsForTesting.contains(400);
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(runner.pendingIdsForTesting, contains(400));
      await runner.close();
      gate.complete(const ResponseContext());
      await Future<void>.delayed(const Duration(milliseconds: 30));
      // The engine never saw a response for the reaped request.
      expect(fake.responded.where((r) => r.requestId == 400), isEmpty);
    });
  });

  group('cors', () {
    // NOTE: cors() wraps matched routes only — an OPTIONS preflight to a
    // path with no matching route is still the default 404. Register `all`
    // (or an explicit OPTIONS route) for preflighted paths.
    test(
      'preflight short-circuits with 204 and never runs the handler',
      () async {
        var calls = 0;
        runner.use(cors());
        runner.addRoute(HttpMethod.all, '', '/res', null, (_) async {
          calls++;
          return ResponseContext.text('never');
        });
        await Future<void>.delayed(Duration.zero);

        fake.heads.add(
          fakeHead(
            requestId: 100,
            method: RawServerMethod.options,
            path: '/res',
            routePattern: '/res',
          ),
        );
        final response = await waitFor(100);
        expect(response.status, 204);
        expect(response.body, isEmpty);
        expect(response.headers['access-control-allow-origin'], '*');
        expect(
          response.headers['access-control-allow-methods'],
          contains('GET'),
        );
        expect(calls, 0);
      },
    );

    test('plain responses carry the policy headers', () async {
      runner.use(cors());
      await addGet('/res', (_) async => ResponseContext.text('hi'));
      final response = await driveRequest(
        fake,
        requestId: 101,
        path: '/res',
        routePattern: '/res',
      );
      expect(response.status, 200);
      expect(response.headers['access-control-allow-origin'], '*');
      expect(response.headers['access-control-max-age'], '86400');
    });

    test('handler-set headers win over the policy', () async {
      runner.use(cors(allowOrigin: 'https://policy.test'));
      runner.addRoute(HttpMethod.get, '', '/refined', null, (_) async {
        return ResponseContext.text(
          'hi',
          headers: {'access-control-allow-origin': 'https://route.test'},
        );
      });
      await Future<void>.delayed(Duration.zero);

      final response = await driveRequest(
        fake,
        requestId: 102,
        path: '/refined',
        routePattern: '/refined',
      );
      expect(
        response.headers['access-control-allow-origin'],
        'https://route.test',
      );
    });

    test('credentials and opt-out max-age are honoured', () async {
      runner.use(
        cors(
          allowOrigin: 'https://app.test',
          allowCredentials: true,
          maxAge: null,
        ),
      );
      await addGet('/cred', (_) async => ResponseContext.text('hi'));
      final response = await driveRequest(
        fake,
        requestId: 103,
        path: '/cred',
        routePattern: '/cred',
      );
      expect(
        response.headers['access-control-allow-origin'],
        'https://app.test',
      );
      expect(response.headers['access-control-allow-credentials'], 'true');
      expect(response.headers, isNot(contains('access-control-max-age')));
    });
  });

  group('middleware composition', () {
    test('global wraps group wraps route-local wraps handler', () async {
      final server = NitroServer.forRunnerForTesting(runner);
      final order = <String>[];
      Middleware named(String name) {
        return (request, next) async {
          order.add('$name-before');
          final response = await next(request);
          order.add('$name-after');
          return response;
        };
      }

      await server.use(named('global'));
      final api = server.group('/api');
      await api.use(named('group'));
      await api.get('/x', (request) async {
        order.add('handler');
        return const ResponseContext();
      }, middleware: [named('route')]);

      await driveRequest(
        fake,
        requestId: 110,
        path: '/api/x',
        routePattern: '/api/x',
      );
      expect(order, [
        'global-before',
        'group-before',
        'route-before',
        'handler',
        'route-after',
        'group-after',
        'global-after',
      ]);
    });

    test('group middleware does not leak to ungrouped routes', () async {
      final server = NitroServer.forRunnerForTesting(runner);
      var groupCalls = 0;
      final api = server.group('/api');
      await api.use((request, next) async {
        groupCalls++;
        return next(request);
      });
      await api.get('/in', (_) async => const ResponseContext());
      await server.get('/out', (_) async => const ResponseContext());

      await driveRequest(
        fake,
        requestId: 111,
        path: '/out',
        routePattern: '/out',
      );
      expect(groupCalls, 0);
      await driveRequest(
        fake,
        requestId: 112,
        path: '/api/in',
        routePattern: '/api/in',
      );
      expect(groupCalls, 1);
    });

    test('a short-circuit middleware answers without the handler', () async {
      var calls = 0;
      runner.use((request, next) async {
        if (request.path == '/blocked') {
          return ResponseContext.text('denied', status: 403);
        }
        return next(request);
      });
      runner.addRoute(HttpMethod.get, '', '/blocked', null, (_) async {
        calls++;
        return const ResponseContext();
      });
      await Future<void>.delayed(Duration.zero);

      final response = await driveRequest(
        fake,
        requestId: 113,
        path: '/blocked',
        routePattern: '/blocked',
      );
      expect(response.status, 403);
      expect(String.fromCharCodes(response.body), 'denied');
      expect(calls, 0);
    });

    test('middleware can stamp the outgoing response', () async {
      runner.use((request, next) async {
        final response = await next(request);
        return ResponseContext(
          status: response.status,
          headers: {...response.headers, 'x-via': 'edge'},
          body: response.body,
        );
      });
      await addGet('/stamped', (_) async => ResponseContext.text('hi'));
      final response = await driveRequest(
        fake,
        requestId: 114,
        path: '/stamped',
        routePattern: '/stamped',
      );
      expect(response.headers['x-via'], 'edge');
      expect(String.fromCharCodes(response.body), 'hi');
    });
  });

  group('dispatch robustness', () {
    test('data chunks arriving before the head are reassembled', () async {
      runner.addRoute(HttpMethod.post, '', '/early', null, (request) async {
        return ResponseContext.text('got:${request.text()}');
      });
      await Future<void>.delayed(Duration.zero);

      // Chunks land first (separate ports, no cross-ordering) and park…
      fake.chunks.add(fakeData(200, 'hel'.codeUnits));
      fake.chunks.add(fakeData(200, 'lo'.codeUnits));
      fake.chunks.add(fakeEnd(200));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // …then the head releases them.
      fake.heads.add(
        fakeHead(
          requestId: 200,
          method: RawServerMethod.post,
          path: '/early',
          hasBody: true,
          contentLength: 5,
          routePattern: '/early',
        ),
      );
      final response = await waitFor(200);
      expect(String.fromCharCodes(response.body), 'got:hello');
    });

    test('interleaved bodies stay with their own request', () async {
      runner.addRoute(HttpMethod.post, '', '/mix', null, (request) async {
        return ResponseContext.text(request.text());
      });
      await Future<void>.delayed(Duration.zero);

      fake.heads.add(
        fakeHead(
          requestId: 201,
          method: RawServerMethod.post,
          path: '/mix',
          hasBody: true,
          contentLength: 2,
          routePattern: '/mix',
        ),
      );
      fake.heads.add(
        fakeHead(
          requestId: 202,
          method: RawServerMethod.post,
          path: '/mix',
          hasBody: true,
          contentLength: 2,
          routePattern: '/mix',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      fake.chunks.add(fakeData(201, 'aa'.codeUnits));
      fake.chunks.add(fakeData(202, 'bb'.codeUnits));
      fake.chunks.add(fakeEnd(202));
      fake.chunks.add(fakeEnd(201));
      final first = await waitFor(201);
      final second = await waitFor(202);
      expect(String.fromCharCodes(first.body), 'aa');
      expect(String.fromCharCodes(second.body), 'bb');
    });

    test('multi-chunk bodies concatenate in order', () async {
      runner.addRoute(HttpMethod.post, '', '/cat', null, (request) async {
        return ResponseContext.bytes(request.body);
      });
      await Future<void>.delayed(Duration.zero);

      fake.heads.add(
        fakeHead(
          requestId: 203,
          method: RawServerMethod.post,
          path: '/cat',
          hasBody: true,
          contentLength: 6,
          routePattern: '/cat',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      fake.chunks.add(fakeData(203, [3, 1]));
      fake.chunks.add(fakeData(203, [4, 1]));
      fake.chunks.add(fakeData(203, [5, 9]));
      fake.chunks.add(fakeEnd(203));
      final response = await waitFor(203);
      expect(response.body, orderedEquals([3, 1, 4, 1, 5, 9]));
    });

    test(
      'a stale data chunk after the end is dropped, not answered twice',
      () async {
        var calls = 0;
        runner.addRoute(HttpMethod.post, '', '/stale', null, (request) async {
          calls++;
          return ResponseContext.text('n=${request.body.length}');
        });
        await Future<void>.delayed(Duration.zero);

        fake.heads.add(
          fakeHead(
            requestId: 204,
            method: RawServerMethod.post,
            path: '/stale',
            hasBody: true,
            contentLength: 1,
            routePattern: '/stale',
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        fake.chunks.add(fakeData(204, [7]));
        fake.chunks.add(fakeEnd(204));
        await waitFor(204);
        fake.chunks.add(fakeData(204, [8])); // Straggler on a reaped id.
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(calls, 1);
        expect(fake.responded.where((r) => r.requestId == 204), hasLength(1));
        expect(fake.acked.where((a) => a.$1 == 204), hasLength(2));
      },
    );

    test('a duplicate head after the answer never redispatches', () async {
      var calls = 0;
      await addGet('/dup', (_) async {
        calls++;
        return const ResponseContext();
      });
      await driveRequest(
        fake,
        requestId: 205,
        path: '/dup',
        routePattern: '/dup',
      );
      expect(calls, 1);
      // Stale resend of the same id long after completion.
      fake.heads.add(
        fakeHead(requestId: 205, path: '/dup', routePattern: '/dup'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(calls, 1);
      expect(fake.responded.where((r) => r.requestId == 205), hasLength(1));
    });

    test('a removed route answers 404', () async {
      await addGet('/gone', (_) async => ResponseContext.text('here'));
      runner.removeRoute(HttpMethod.get, '', '/gone');
      final response = await driveRequest(
        fake,
        requestId: 206,
        path: '/gone',
        routePattern: '/gone',
      );
      expect(response.status, 404);
    });

    test('status and headers ride the wire untouched', () async {
      runner.addRoute(HttpMethod.post, '', '/made', null, (_) async {
        return ResponseContext(
          status: 201,
          headers: {'location': '/made/1', 'x-n': 'v'},
        );
      });
      await Future<void>.delayed(Duration.zero);

      final response = await driveRequest(
        fake,
        requestId: 207,
        method: RawServerMethod.post,
        path: '/made',
        routePattern: '/made',
      );
      expect(response.status, 201);
      expect(response.headers['location'], '/made/1');
      expect(response.headers['x-n'], 'v');
    });

    test('query strings land in queryParameters', () async {
      RequestContext? seen;
      runner.addRoute(HttpMethod.get, '', '/q', null, (request) async {
        seen = request;
        return const ResponseContext();
      });
      await Future<void>.delayed(Duration.zero);

      fake.heads.add(
        fakeHead(
          requestId: 208,
          path: '/q',
          query: 'a=1&b=two',
          routePattern: '/q',
        ),
      );
      await waitFor(208);
      expect(seen!.query, 'a=1&b=two');
      expect(seen!.queryParameters, {'a': '1', 'b': 'two'});
      expect(seen!.queryParam('a'), '1');
    });

    test('casing variants of one header fold to a single key', () async {
      RequestContext? seen;
      await addGet('/fold', (request) async {
        seen = request;
        return const ResponseContext();
      });
      fake.heads.add(
        RawIncomingRequest(
          requestId: 209,
          method: RawServerMethod.get,
          path: '/fold',
          headers: [
            RawHeader(name: 'X-Token', value: 'a'),
            RawHeader(name: 'x-token', value: 'b'),
          ],
          routePattern: '/fold',
        ),
      );
      await waitFor(209);
      expect(seen!.headers['x-token'], ['a', 'b']);
      expect(seen!.header('X-TOKEN'), 'a');
    });
  });

  group('config and value edges', () {
    test('copyWith keeps defaults and replaces only given fields', () {
      const base = ServerConfig();
      final copy = base.copyWith(port: 8080, host: '0.0.0.0');
      expect(copy.port, 8080);
      expect(copy.host, '0.0.0.0');
      expect(copy.backlog, base.backlog);
      expect(copy.maxBodyBytes, base.maxBodyBytes);
      expect(copy.defaultTimeout, base.defaultTimeout);
      expect(copy.keepAliveTimeout, base.keepAliveTimeout);
      expect(copy.maxRequestsPerConnection, base.maxRequestsPerConnection);
      expect(copy.workerThreads, base.workerThreads);
      expect(const ServerConfig().copyWith().port, 0);
    });

    test('ServerConfig rejects negative budgets', () {
      expect(
        () => ServerConfig(maxRequestsPerConnection: -1),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => ServerConfig(workerThreads: -1),
        throwsA(isA<AssertionError>()),
      );
    });

    test('registration methods return the server for chaining', () async {
      final server = NitroServer.forRunnerForTesting(runner);
      Future<ResponseContext> ok(RequestContext _) async {
        return const ResponseContext();
      }

      final afterGet = await server.get('/a', ok);
      final afterUse = await afterGet.use((request, next) => next(request));
      final afterUnroute = await afterUse.unroute(HttpMethod.get, '/a');
      expect(afterGet, same(server));
      expect(afterUse, same(server));
      expect(afterUnroute, same(server));
      final api = server.group('/g');
      expect(await api.get('/b', ok), same(api));
    });

    test(
      'a failing native registration throws typed and installs nothing',
      () async {
        fake.registerFailures['/bad'] = const RawServerStatus(
          errorKind: RawServerErrorKind.badRequest,
          errorMessage: 'wildcards only trail',
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
        final response = await driveRequest(
          fake,
          requestId: 210,
          path: '/bad',
          routePattern: '/bad',
        );
        expect(response.status, 404);
      },
    );

    test('a failing native start surfaces the typed error', () {
      fake.startResult = const RawServerStatus(
        errorKind: RawServerErrorKind.bindFailed,
        errorMessage: 'denied',
      );
      expect(
        () => runner.start(const ServerConfig()),
        throwsA(isA<ServerBindException>()),
      );
    });

    test('redirect answers empty with a location', () async {
      await addGet('/old', (_) async => ResponseContext.redirect('/new'));
      final response = await driveRequest(
        fake,
        requestId: 211,
        path: '/old',
        routePattern: '/old',
      );
      expect(response.status, 302);
      expect(response.body, isEmpty);
      expect(response.headers['location'], '/new');
    });

    test('redirect rejects non-redirect statuses', () {
      expect(
        () => ResponseContext.redirect('/x', status: 200),
        throwsA(isA<AssertionError>()),
      );
    });

    test('jsonBody encodes lists as well as maps', () async {
      await addGet(
        '/list',
        (_) async => ResponseContext.jsonBody([
          1,
          {'a': true},
        ]),
      );
      final response = await driveRequest(
        fake,
        requestId: 212,
        path: '/list',
        routePattern: '/list',
      );
      expect(response.headers['content-type'], contains('application/json'));
      expect(jsonDecode(String.fromCharCodes(response.body)), [
        1,
        {'a': true},
      ]);
    });
  });

  group('streams', () {
    test(
      'a streamBody route streams chunks, acks each, and errors the stream',
      () async {
        String? seen;
        final done = Completer<void>();
        runner.addRoute(
          HttpMethod.post,
          '',
          '/up',
          null,
          (request) async {
            expect(request.body, isEmpty);
            final got = <int>[];
            try {
              await for (final chunk in request.bodyStream!) {
                got.addAll(chunk);
              }
            } on StateError catch (e) {
              seen = 'error after ${got.length}: ${e.message}';
              done.complete();
              return ResponseContext.text(seen!, status: 413);
            }
            return ResponseContext.text('complete ${got.length}');
          },
          const [],
          true,
        );
        await Future<void>.delayed(Duration.zero);
        // A chunk that beats its head is handed over first.
        fake.chunks.add(fakeData(700, [9]));
        fake.heads.add(
          fakeHead(
            requestId: 700,
            method: RawServerMethod.post,
            path: '/up',
            routePattern: '/up',
            hasBody: true,
            contentLength: 20,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        fake.chunks.add(fakeData(700, [1, 2, 3]));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        // Streamed bodies release native memory as they go, not at the end.
        expect(fake.acked.where((a) => a.$1 == 700), isNotEmpty);
        fake.chunks.add(
          RawBodyChunk(
            bytes: Uint8List.fromList(utf8.encode('body exceeds maxBodyBytes')),
            requestId: 700,
            kind: RawBodyKind.error.index,
            aux: RawServerErrorKind.requestTooLarge.index,
          ),
        );
        fake.chunks.add(fakeEnd(700));
        await done.future.timeout(const Duration(seconds: 5));
        expect(seen, 'error after 4: body exceeds maxBodyBytes');
        for (
          var i = 0;
          i < 100 && runner.pendingIdsForTesting.contains(700);
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(
          fake.responded.where((r) => r.requestId == 700).single.status,
          413,
        );
      },
    );

    test('status, headers and chunks ride startStream in order', () async {
      final controller = StreamController<Uint8List>();
      runner.addRoute(HttpMethod.get, '', '/ev', null, (_) async {
        return ResponseContext.stream(
          controller.stream,
          headers: {'x-feed': 'yes'},
        );
      });
      await Future<void>.delayed(Duration.zero);

      fake.heads.add(
        fakeHead(requestId: 500, path: '/ev', routePattern: '/ev'),
      );
      for (var i = 0; i < 200 && !fake.streamsStarted.containsKey(500); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final started = fake.streamsStarted[500]!;
      expect(started.status, 200);
      expect(started.headers['content-type'], contains('octet-stream'));
      expect(started.headers['x-feed'], 'yes');

      controller.add(Uint8List.fromList('a'.codeUnits));
      controller.add(Uint8List.fromList('bc'.codeUnits));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await controller.close();
      for (var i = 0; i < 200 && !fake.streamsEnded.contains(500); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final chunks = fake.streamChunks[500]!;
      expect(chunks.map(String.fromCharCodes).join(), 'abc');
      expect(fake.streamsEnded, contains(500));
      expect(runner.pendingIdsForTesting, isNot(contains(500)));
    });

    test('empty chunks never reach the engine', () async {
      final controller = StreamController<Uint8List>();
      runner.addRoute(HttpMethod.get, '', '/pad', null, (_) async {
        return ResponseContext.stream(controller.stream);
      });
      await Future<void>.delayed(Duration.zero);

      fake.heads.add(
        fakeHead(requestId: 501, path: '/pad', routePattern: '/pad'),
      );
      for (var i = 0; i < 200 && !fake.streamsStarted.containsKey(501); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      controller.add(Uint8List(0)); // Would terminate a chunked body.
      controller.add(Uint8List.fromList([1]));
      controller.add(Uint8List(0));
      await controller.close();
      for (var i = 0; i < 200 && !fake.streamsEnded.contains(501); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      // Only the payload chunk crossed; the terminal call carries no bytes.
      expect(fake.streamChunks[501], hasLength(1));
      expect(fake.streamChunks[501]!.single, orderedEquals([1]));
    });

    test('a stream error truncates instead of hanging', () async {
      final controller = StreamController<Uint8List>();
      runner.addRoute(HttpMethod.get, '', '/flaky', null, (_) async {
        return ResponseContext.stream(controller.stream);
      });
      await Future<void>.delayed(Duration.zero);

      fake.heads.add(
        fakeHead(requestId: 502, path: '/flaky', routePattern: '/flaky'),
      );
      for (var i = 0; i < 200 && !fake.streamsStarted.containsKey(502); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      controller.add(Uint8List.fromList('part'.codeUnits));
      controller.addError(StateError('feed died'));
      for (var i = 0; i < 200 && !fake.streamsEnded.contains(502); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      // Bytes so far, then a clean terminator: the client sees 'part'.
      expect(fake.streamChunks[502]!.map(String.fromCharCodes).join(), 'part');
      expect(fake.streamsEnded, contains(502));
    });

    test('close mid-stream stops forwarding and drops the id', () async {
      final controller = StreamController<Uint8List>(sync: true);
      runner.addRoute(HttpMethod.get, '', '/long', null, (_) async {
        return ResponseContext.stream(controller.stream);
      });
      await Future<void>.delayed(Duration.zero);

      fake.heads.add(
        fakeHead(requestId: 503, path: '/long', routePattern: '/long'),
      );
      for (var i = 0; i < 200 && !fake.streamsStarted.containsKey(503); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      controller.add(Uint8List.fromList([1]));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(fake.streamChunks[503], hasLength(1));

      await runner.close();
      controller.add(Uint8List.fromList([2]));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // Nothing forwarded after close; no terminal for a dead engine.
      expect(fake.streamChunks[503], hasLength(1));
      expect(fake.streamsEnded, isNot(contains(503)));
      await controller.close();
    });

    test('a throwing error page may answer with a stream', () async {
      runner.addRoute(HttpMethod.get, '', '/boom', null, (_) async {
        throw StateError('kaput');
      });
      runner.errorHandler = (error, _) => ResponseContext.stream(
        Stream.value(Uint8List.fromList('oops'.codeUnits)),
      );
      await Future<void>.delayed(Duration.zero);

      // Streams never `respond`, so drive the head by hand and watch the
      // stream signals instead of `fake.responded`.
      fake.heads.add(
        fakeHead(requestId: 504, path: '/boom', routePattern: '/boom'),
      );
      for (var i = 0; i < 200 && !fake.streamsEnded.contains(504); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(fake.responded.where((r) => r.requestId == 504), isEmpty);
      expect(fake.streamsStarted[504]!.status, 200);
      expect(fake.streamChunks[504]!.map(String.fromCharCodes).join(), 'oops');
    });

    test(
      'a rejected startStream (timeout won) drops the stream cleanly',
      () async {
        fake.startStreamFailures.add(505);
        runner.addRoute(
          HttpMethod.get,
          '',
          '/late',
          null,
          (_) => ResponseContext.stream(Stream.value(Uint8List.fromList([1]))),
        );
        await Future<void>.delayed(Duration.zero);
        fake.heads.add(
          fakeHead(requestId: 505, path: '/late', routePattern: '/late'),
        );
        for (
          var i = 0;
          i < 100 && runner.pendingIdsForTesting.contains(505);
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(runner.pendingIdsForTesting, isNot(contains(505)));
        expect(fake.streamsStarted, isNot(contains(505)));
        expect(fake.streamChunks, isNot(contains(505)));
      },
    );
  });

  group('websockets', () {
    Future<WsSession> openSession(
      int id, {
      String path = '/chat',
      String pattern = '/chat',
      List<RawRouteParam> params = const [],
      WsHandler? handler,
    }) async {
      final opened = Completer<WsSession>();
      runner.addWsRoute(pattern, (session) async {
        if (!opened.isCompleted) opened.complete(session);
        await handler?.call(session);
      });
      await Future<void>.delayed(Duration.zero);
      fake.heads.add(
        fakeHead(
          requestId: id,
          path: path,
          routePattern: pattern,
          params: params,
        ),
      );
      return opened.future.timeout(const Duration(seconds: 5));
    }

    void inject(int id, int kind, Uint8List payload, [int code = 0]) {
      fake.wsOut.add(
        RawWsMessage(payload: payload, connectionId: id, kind: kind, aux: code),
      );
    }

    Future<void> waitWsClosed(int id) async {
      for (var i = 0; i < 200; i++) {
        if (fake.wsClosed.any((c) => c.$1 == id)) return;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      throw StateError('no wsClose for $id');
    }

    test(
      'session seams: live ids, close code, shutdown on runner close',
      () async {
        final session = await openSession(590);
        expect(runner.wsSessionIdsForTesting, {590});
        expect(session.closeCode, isNull);
        // Runner shutdown reaps the session without a native close call: the
        // engine is already stopped by then.
        await runner.close();
        expect(session.closeCode, 1006);
        expect(runner.wsSessionIdsForTesting, isEmpty);
        expect(fake.wsClosed, isEmpty);
        // Sends after shutdown are dropped, never errors.
        session.sendText('late');
        expect(fake.wsSent, isEmpty);
      },
    );

    test('open dispatches with the handshake pattern and params', () async {
      final session = await openSession(
        600,
        path: '/rooms/lobby',
        pattern: '/rooms/:room',
        params: const [RawRouteParam(name: 'room', value: 'lobby')],
      );
      expect(session.handshake.param('room'), 'lobby');
      expect(session.handshake.path, '/rooms/lobby');
      expect(session.handshake.routePattern, '/rooms/:room');
      await session.close();
      await waitWsClosed(600);
      expect(fake.wsClosed.single, (600, 1000));
    });

    test('text and binary messages reach the handler in order', () async {
      final received = <WsMessage>[];
      final done = Completer<void>();
      await openSession(
        601,
        handler: (session) async {
          await for (final message in session.messages) {
            received.add(message);
          }
          done.complete();
        },
      );
      inject(601, 1, Uint8List.fromList('hi'.codeUnits));
      inject(601, 2, Uint8List.fromList([1, 2, 3]));
      inject(601, 8, Uint8List(0), 1000);
      await done.future.timeout(const Duration(seconds: 5));
      expect(received, hasLength(2));
      expect(received[0].isText, isTrue);
      expect(received[0].text, 'hi');
      expect(received[1].isBinary, isTrue);
      expect(received[1].bytes, orderedEquals([1, 2, 3]));
      // Peer-initiated close echoes the peer code (a no-op on the reaped
      // engine side) so close observers complete deterministically.
      expect(fake.wsClosed.single, (601, 1000));
    });

    test('sends ride wsSend with the right opcode flag', () async {
      final session = await openSession(602);
      session.sendText('yo');
      session.sendBytes(Uint8List.fromList([9]));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(fake.wsSent, hasLength(2));
      expect(fake.wsSent[0].$1, 602);
      expect(String.fromCharCodes(fake.wsSent[0].$2), 'yo');
      expect(fake.wsSent[0].$3, isFalse);
      expect(fake.wsSent[1].$2, orderedEquals([9]));
      expect(fake.wsSent[1].$3, isTrue);
      await session.close();
    });

    test('a throwing handler closes with 1011', () async {
      await openSession(
        603,
        handler: (_) async {
          throw StateError('handler died');
        },
      );
      await waitWsClosed(603);
      expect(fake.wsClosed.single, (603, 1011));
    });

    test('messages for unknown sessions are acked and dropped', () async {
      await addGet('/unrelated');
      inject(604, 1, Uint8List.fromList('ghost'.codeUnits));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      // Copied then acked (zero-copy contract), bytes dropped, no crash.
      expect(fake.acked.any((a) => a.$1 == 604), isTrue);
    });

    test('registering ws evicts http on the same pattern and back', () async {
      var httpCalls = 0;
      var wsCalls = 0;
      runner.addRoute(HttpMethod.get, '', '/dupe', null, (_) async {
        httpCalls++;
        return const ResponseContext();
      });
      runner.addWsRoute('/dupe', (_) async {
        wsCalls++;
      });
      await Future<void>.delayed(Duration.zero);
      fake.heads.add(
        fakeHead(requestId: 605, path: '/dupe', routePattern: '/dupe'),
      );
      await waitWsClosed(605);
      expect(wsCalls, 1);
      expect(httpCalls, 0);

      runner.addRoute(HttpMethod.get, '', '/dupe', null, (_) async {
        httpCalls++;
        return const ResponseContext();
      });
      await Future<void>.delayed(Duration.zero);
      final response = await driveRequest(
        fake,
        requestId: 606,
        path: '/dupe',
        routePattern: '/dupe',
      );
      expect(response.status, 200);
      expect(httpCalls, 1);
      expect(wsCalls, 1);
    });

    test('unroute removes the ws route', () async {
      await openSession(607, pattern: '/bye');
      await Future<void>.delayed(Duration.zero);
      runner.removeRoute(HttpMethod.get, '', '/bye');
      final response = await driveRequest(
        fake,
        requestId: 608,
        path: '/bye',
        routePattern: '/bye',
      );
      expect(response.status, 404);
    });

    test('close is idempotent and drops late sends', () async {
      final session = await openSession(609);
      await session.close(1000);
      await session.close(1000);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(fake.wsClosed.where((c) => c.$1 == 609), hasLength(1));
      session.sendText('late');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(fake.wsSent.where((s) => s.$1 == 609), isEmpty);
    });
  });
}
