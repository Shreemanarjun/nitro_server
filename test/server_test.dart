// Server module: whole-facade and runner behaviour that does not map to a
// narrower module (dispatch, config validation, cors, streams, fallbacks,
// value types, runner seams). Moved verbatim from server_facade_test.dart
// (facade harness: fake+runner+server) and server_edge_cases_test.dart (edge
// harness: fake+runner). The two harnesses get SEPARATE nested groups, each
// with its own setUp/tearDown — never one shared setUp.
import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:nitro_server/nitro_server.dart';
import 'package:nitro_server/src/internal/instance_keys.dart';
import 'package:nitro_server/src/internal/native_attach.dart';
import 'package:nitro_server/src/internal/server_runner.dart';
import 'package:nitro_server/src/nitro_server.native.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
  group('facade', () {
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

      test(
        'a throwing handler is a generic 500 (details stay server-side)',
        () async {
          await server.get('/boom', (_) async => throw StateError('kaput'));
          final response = await driveRequest(
            fake,
            requestId: 45,
            path: '/boom',
            routePattern: '/boom',
          );
          expect(response.status, 500);
          expect(String.fromCharCodes(response.body), 'internal server error');
        },
      );

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
        expect(String.fromCharCodes(response.body), 'internal server error');
      });
    });

    group('config & reload', () {
      test('config and uri reflect the config the server was built with', () {
        // forRunnerForTesting builds over a default ServerConfig (port 0).
        expect(server.config.host, '127.0.0.1');
        expect(server.config.port, 0);
        expect(server.config.tls.enabled, isFalse);
        expect(server.uri, Uri.parse('http://127.0.0.1:0'));
      });

      test('reload without a setup throws', () async {
        await expectLater(server.reload(), throwsStateError);
      });

      test(
        'reload tears down every route kind before re-running setup',
        () async {
          Future<ResponseContext> ok(RequestContext _) async =>
              const ResponseContext();
          // A handler, a WebSocket route, a static route, middleware and a 404.
          await server.reload((s) async {
            await s.get('/old', ok);
            await s.ws('/sock', (_) async {});
            await s.getStatic('/static', const [1, 2, 3]);
            s.use((request, next) => next(request));
            s.notFoundHandler = (_) => const ResponseContext(status: 418);
          });
          expect(
            fake.registered.map((r) => r.pattern),
            containsAll(['/old', '/sock']),
          );
          expect(fake.staticRegistered.single.pattern, '/static');

          fake.unregistered.clear();
          await server.reload((s) => s.get('/new', ok));
          expect(
            fake.unregistered,
            containsAll([
              ('GET', '/old'),
              ('GET', '/sock'),
              ('GET', '/static'),
            ]),
          );
          expect(fake.registered.last.pattern, '/new');
        },
      );

      test('routes lists each registered route with its kind', () async {
        Future<ResponseContext> ok(RequestContext _) async =>
            const ResponseContext();
        await server.get('/h', ok);
        await server.post('/p', ok);
        await server.route(HttpMethod.custom, '/c', ok, customMethod: 'FOO');
        await server.ws('/w', (_) async {});
        await server.getStatic('/s', const [1]);
        expect(server.routes.toSet(), {
          const RegisteredRoute(
            method: HttpMethod.get,
            pattern: '/h',
            kind: RouteKind.handler,
          ),
          const RegisteredRoute(
            method: HttpMethod.post,
            pattern: '/p',
            kind: RouteKind.handler,
          ),
          const RegisteredRoute(
            method: HttpMethod.custom,
            customMethod: 'FOO',
            pattern: '/c',
            kind: RouteKind.handler,
          ),
          const RegisteredRoute(
            method: HttpMethod.get,
            pattern: '/w',
            kind: RouteKind.webSocket,
          ),
          const RegisteredRoute(
            method: HttpMethod.get,
            pattern: '/s',
            kind: RouteKind.staticResponse,
          ),
        });
        // Value-type surface.
        final h = server.routes.firstWhere((r) => r.pattern == '/h');
        expect(h.methodToken, 'GET');
        expect(h.toString(), 'GET /h (handler)');
        final c = server.routes.firstWhere((r) => r.pattern == '/c');
        expect(c.methodToken, 'FOO');
        expect(h.hashCode, isNot(c.hashCode));
      });

      test(
        'a reload whose setup throws rolls back, keeping the old routes',
        () async {
          Future<ResponseContext> ok(RequestContext _) async =>
              const ResponseContext();
          await server.reload((s) async => s.get('/keep', ok));
          expect(server.routes.map((r) => r.pattern), ['/keep']);
          await expectLater(
            server.reload((s) async {
              await s.get('/temp', ok);
              throw StateError('boom');
            }),
            throwsStateError,
          );
          // The partial route is gone; the previous route survives.
          expect(server.routes.map((r) => r.pattern), ['/keep']);
        },
      );

      test('onClose completes when the server is closed', () async {
        await server.close();
        await expectLater(server.onClose, completes);
      });

      test(
        'reload with no argument re-runs the setup given the first time',
        () async {
          var runs = 0;
          await server.reload((_) async => runs++);
          await server.reload();
          expect(runs, 2);
        },
      );
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
        expect(
          DateTime.now().difference(started).inMilliseconds,
          lessThan(2000),
        );
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
        for (
          var i = 0;
          runner.pendingIdsForTesting.isNotEmpty && i < 200;
          i++
        ) {
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

      test('a body error after a buffered head drops without dispatch', () async {
        var calls = 0;
        final runner = ServerRunner(fake);
        addTearDown(runner.close);
        runner.addRoute(HttpMethod.post, '', '/perr', null, (_) async {
          calls++;
          return const ResponseContext();
        });
        await pump();
        // Head first, non-stream, body still incoming: the request parks
        // (pending, not complete, not a stream) awaiting its body.
        fake.heads.add(
          fakeHead(
            requestId: 42,
            method: RawServerMethod.post,
            path: '/perr',
            hasBody: true,
            contentLength: 5,
            routePattern: '/perr',
          ),
        );
        await pump();
        expect(runner.pendingIdsForTesting, {42});
        // A terminal body error lands before the end marker (the engine already
        // answered directly, e.g. 413): the parked handler is dropped, never run.
        fake.chunks.add(
          RawBodyChunk(
            bytes: Uint8List.fromList('too large'.codeUnits),
            requestId: 42,
            kind: RawBodyKind.error.index,
            aux: 0,
          ),
        );
        fake.chunks.add(fakeEnd(42));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(calls, 0);
        expect(fake.responded.where((r) => r.requestId == 42), isEmpty);
        expect(runner.pendingIdsForTesting, isEmpty);
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
        fake.heads.add(fakeHead(requestId: 42));
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
  });

  group('edge', () {
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

      test('selectWsProtocol: first accepted entry the client offered', () {
        expect(selectWsProtocol(null, ['a']), isNull);
        expect(selectWsProtocol('a', []), isNull);
        expect(selectWsProtocol('b , a', ['a', 'b']), 'a');
        expect(selectWsProtocol('c', ['a']), isNull);
      });

      test('every head dispatches (coalesced or not)', () async {
        var calls = 0;
        runner.addRoute(HttpMethod.get, '', '/b', null, (_) async {
          calls++;
          return const ResponseContext();
        });
        await Future<void>.delayed(Duration.zero);

        // Under load the bridge coalesces heads into one delivery; to the runner
        // they arrive as individual RawIncomingRequest events either way.
        fake.heads.add(fakeHead(requestId: 11, path: '/b', routePattern: '/b'));
        fake.heads.add(fakeHead(requestId: 12, path: '/b', routePattern: '/b'));
        await waitFor(11);
        await waitFor(12);
        expect(calls, 2);
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

        fake.heads.add(fakeHead(requestId: 10, path: '/q', routePattern: '/q'));
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

      test('ServerConfig rejects nonsense at validate() (bind calls it)', () {
        expect(const ServerConfig(port: -1).validate, throwsArgumentError);
        expect(const ServerConfig(port: 70000).validate, throwsArgumentError);
        expect(const ServerConfig(backlog: 0).validate, throwsArgumentError);
        expect(
          const ServerConfig(maxBodyBytes: 0).validate,
          throwsArgumentError,
        );
        expect(const ServerConfig().validate, returnsNormally);
      });

      test('ResponseContext rejects out-of-range statuses', () {
        expect(
          () => ResponseContext(status: 99),
          throwsA(isA<AssertionError>()),
        );
        expect(
          () => ResponseContext(status: 1000),
          throwsA(isA<AssertionError>()),
        );
      });
    });

    group('cors', () {
      // NOTE: cors() wraps matched routes only — an OPTIONS preflight to a
      // path with no matching route is still the default 404. Register `all`
      // (or an explicit OPTIONS route) for preflighted paths.
      test(
        'a real preflight (Access-Control-Request-Method) short-circuits 204',
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
              headers: const [
                RawHeader(name: 'access-control-request-method', value: 'GET'),
              ],
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

      test(
        'a plain OPTIONS (not a preflight) falls through to the route',
        () async {
          var calls = 0;
          runner.use(cors());
          runner.addRoute(HttpMethod.all, '', '/res', null, (_) async {
            calls++;
            return ResponseContext.text('handled');
          });
          await Future<void>.delayed(Duration.zero);

          fake.heads.add(
            fakeHead(
              requestId: 101,
              method: RawServerMethod.options,
              path: '/res',
              routePattern: '/res',
            ),
          );
          final response = await waitFor(101);
          expect(response.status, 200); // the route ran, cors didn't shadow it
          expect(String.fromCharCodes(response.body), 'handled');
          expect(response.headers['access-control-allow-origin'], '*');
          expect(calls, 1);
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
          return const ResponseContext(
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
          const RawIncomingRequest(
            requestId: 209,
            path: '/fold',
            packedHeaders: 'X-Token a x-token b',
            routePattern: '/fold',
          ),
        );
        await waitFor(209);
        expect(seen!.headers['x-token'], ['a', 'b']);
        expect(seen!.header('X-TOKEN'), 'a');
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
              bytes: Uint8List.fromList(
                utf8.encode('body exceeds maxBodyBytes'),
              ),
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
        expect(
          fake.streamChunks[502]!.map(String.fromCharCodes).join(),
          'part',
        );
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
        expect(
          fake.streamChunks[504]!.map(String.fromCharCodes).join(),
          'oops',
        );
      });

      test(
        'a rejected startStream (timeout won) drops the stream cleanly',
        () async {
          fake.startStreamFailures.add(505);
          var handlerRan = false;
          runner.addRoute(HttpMethod.get, '', '/late', null, (_) {
            handlerRan = true;
            return ResponseContext.stream(
              Stream.value(Uint8List.fromList([1])),
            );
          });
          await Future<void>.delayed(Duration.zero);
          fake.heads.add(
            fakeHead(requestId: 505, path: '/late', routePattern: '/late'),
          );
          for (var i = 0; i < 200 && !handlerRan; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          expect(handlerRan, isTrue);
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(runner.pendingIdsForTesting, isNot(contains(505)));
          expect(fake.streamsStarted, isNot(contains(505)));
          expect(fake.streamChunks, isNot(contains(505)));
        },
      );
    });
  });
}
