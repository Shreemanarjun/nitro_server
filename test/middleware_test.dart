/// Middleware: compression and the add-on middlewares driven through the
/// in-memory client, plus middleware composition against the fake runner.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nitro_server/nitro_server.dart';
import 'package:nitro_server/src/internal/instance_keys.dart';
import 'package:nitro_server/src/internal/native_attach.dart';
import 'package:nitro_server/src/internal/server_runner.dart';
import 'package:nitro_server/src/nitro_server.native.dart';
import 'package:nitro_server/testing.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

String _basic(String user, String pass) =>
    'Basic ${base64.encode(utf8.encode('$user:$pass'))}';

void main() {
  // --- client harness: compress (features_test setUp, no /ok) ---
  group('client (compress)', () {
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
        final res = await client.get(
          '/t',
          headers: {'accept-encoding': 'gzip'},
        );
        expect(res.headers['content-encoding'], 'gzip');
        expect(res.headers['vary'], 'accept-encoding');
        expect(res.body.length, lessThan(big.length));
        expect(utf8.decode(gzip.decode(res.body)), big);
      });

      test('preserves handler set-cookies on a compressed response', () async {
        await client.server.use(compress());
        await client.server.get(
          '/sc',
          (_) => ResponseContext.text(
            big,
          ).withCookie(const SetCookie('sid', 'abc')),
        );
        final res = await client.get(
          '/sc',
          headers: {'accept-encoding': 'gzip'},
        );
        expect(res.headers['content-encoding'], 'gzip'); // was compressed
        expect(res.headers['set-cookie'], contains('sid=abc')); // cookie kept
      });

      test('honours a custom compression level (round-trips)', () async {
        // Repetitive-but-varied body so a higher level can compress tighter.
        final body = List.generate(400, (i) => 'row $i: item-$i\n').join();
        await client.server.use(compress(level: 9));
        await client.server.get('/t', (_) => ResponseContext.text(body));
        final res = await client.get(
          '/t',
          headers: {'accept-encoding': 'gzip'},
        );
        expect(res.headers['content-encoding'], 'gzip');
        expect(utf8.decode(gzip.decode(res.body)), body);
      });

      test(
        'leaves small, opaque, pre-encoded and unaccepting answers alone',
        () async {
          await client.server.use(compress(minBytes: 10));
          await client.server.get('/small', (_) => ResponseContext.text('hi'));
          await client.server.get(
            '/png',
            (_) => ResponseContext.bytes(
              Uint8List(2000),
              contentType: 'image/png',
            ),
          );
          await client.server.get(
            '/pre',
            (_) =>
                ResponseContext.text(big, headers: {'content-encoding': 'br'}),
          );
          await client.server.get('/t', (_) => ResponseContext.text(big));
          await client.server.get(
            '/s',
            (_) => ResponseContext.stream(Stream.value(utf8.encode(big))),
          );
          const accept = {'accept-encoding': 'gzip, deflate'};
          for (final path in ['/small', '/png', '/pre', '/s']) {
            final res = await client.get(path, headers: accept);
            expect(
              res.headers['content-encoding'],
              isNot('gzip'),
              reason: path,
            );
          }
          final plain = await client.get('/t');
          expect(plain.headers.containsKey('content-encoding'), isFalse);
          expect(plain.text(), big);
        },
      );

      test('honours a custom content-type allowlist', () async {
        await client.server.use(
          compress(contentTypes: {'application/x-custom'}),
        );
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
  });

  // --- client harness: add-on middlewares (middleware_addons_test setUp
  //     registers GET /ok before each test) ---
  group('client (addons)', () {
    late NitroTestClient client;

    setUp(() async {
      client = await NitroTestClient.start();
      await client.server.get('/ok', (_) => ResponseContext.text('ok'));
    });
    tearDown(() => client.close());

    group('accessLog', () {
      test('plain format: method, status, latency, path (no colour)', () async {
        final lines = <String>[];
        await client.server.use(accessLog(sink: lines.add, color: false));
        expect((await client.get('/ok')).status, 200);
        expect(lines, hasLength(1));
        expect(lines.single, isNot(contains('\x1b[')));
        expect(
          lines.single,
          matches(RegExp(r'^GET +200 +\d+(\.\d+)?(µs|ms) +/ok')),
        );
      });

      test('colour wraps the line in ANSI', () async {
        final lines = <String>[];
        await client.server.use(accessLog(sink: lines.add, color: true));
        await client.get('/ok');
        expect(lines.single, contains('\x1b['));
      });

      test('a slow handler logs milliseconds', () async {
        final lines = <String>[];
        await client.server.use(accessLog(sink: lines.add, color: false));
        await client.server.get('/slow', (_) async {
          await Future<void>.delayed(const Duration(milliseconds: 3));
          return ResponseContext.text('slow');
        });
        await client.get('/slow');
        expect(lines.single, contains('ms'));
      });

      test('a throwing handler is logged as 500 and rethrown', () async {
        final lines = <String>[];
        await client.server.use(accessLog(sink: lines.add, color: false));
        await client.server.get('/boom', (_) => throw StateError('x'));
        expect((await client.get('/boom')).status, 500);
        expect(lines.single, matches(RegExp(r'^GET +500 ')));
      });

      test('json mode emits one structured object per request', () async {
        final lines = <String>[];
        await client.server.use(accessLog(sink: lines.add, json: true));
        await client.get('/ok');
        final obj = jsonDecode(lines.single) as Map<String, Object?>;
        expect(obj['method'], 'GET');
        expect(obj['status'], 200);
        expect(obj['path'], '/ok');
        expect(obj['latency_us'], isA<int>());
        expect(lines.single, isNot(contains('\x1b['))); // never coloured
      });
    });

    group('requestId', () {
      test('generates an X-Request-Id when the client sends none', () async {
        await client.server.use(requestId());
        await client.server.get('/ok', (_) => ResponseContext.text('ok'));
        final res = await client.get('/ok');
        expect(res.headers['x-request-id'], isNotNull);
        expect(res.headers['x-request-id'], isNotEmpty);
      });

      test('echoes the client X-Request-Id / X-Correlation-Id', () async {
        await client.server.use(requestId());
        await client.server.get('/ok', (_) => ResponseContext.text('ok'));
        expect(
          (await client.get(
            '/ok',
            headers: {'x-request-id': 'abc123'},
          )).headers['x-request-id'],
          'abc123',
        );
        expect(
          (await client.get(
            '/ok',
            headers: {'x-correlation-id': 'corr'},
          )).headers['x-request-id'],
          'corr',
        );
      });

      test('a handler-set id wins', () async {
        await client.server.use(requestId());
        await client.server.get(
          '/ok',
          (_) => ResponseContext.text('ok').withHeader('x-request-id', 'mine'),
        );
        expect((await client.get('/ok')).headers['x-request-id'], 'mine');
      });

      test('a handler id under mixed case wins (no duplicate stamp)', () async {
        await client.server.use(requestId());
        await client.server.get(
          '/ok',
          (_) => ResponseContext.text('ok').withHeader('X-Request-Id', 'MINE'),
        );
        // case-insensitive match => keep the handler's, don't add a second id
        expect((await client.get('/ok')).headers['x-request-id'], 'MINE');
      });
    });

    group('rateLimit', () {
      test(
        'allows up to the limit then answers 429 with Retry-After',
        () async {
          await client.server.use(rateLimit(maxRequests: 3));
          for (var i = 0; i < 3; i++) {
            expect((await client.get('/ok')).status, 200, reason: 'req $i');
          }
          final limited = await client.get('/ok');
          expect(limited.status, 429);
          expect(limited.text(), 'rate limit exceeded');
          expect(int.parse(limited.headers['retry-after']!), greaterThan(0));
        },
      );

      test('resets after the window elapses', () async {
        await client.server.use(
          rateLimit(maxRequests: 1, window: const Duration(milliseconds: 60)),
        );
        expect((await client.get('/ok')).status, 200);
        expect((await client.get('/ok')).status, 429);
        await Future<void>.delayed(const Duration(milliseconds: 90));
        expect((await client.get('/ok')).status, 200); // new window
      });

      test('keys per client via X-Forwarded-For, then X-Real-IP', () async {
        await client.server.use(rateLimit(maxRequests: 1));
        // Client A exhausts its bucket.
        expect(
          (await client.get(
            '/ok',
            headers: {'x-forwarded-for': '1.1.1.1'},
          )).status,
          200,
        );
        expect(
          (await client.get(
            '/ok',
            headers: {'x-forwarded-for': '1.1.1.1, p'},
          )).status,
          429, // same first hop
        );
        // Client B (different hop) has its own bucket.
        expect(
          (await client.get(
            '/ok',
            headers: {'x-forwarded-for': '2.2.2.2'},
          )).status,
          200,
        );
        // X-Real-IP path (no XFF).
        expect(
          (await client.get('/ok', headers: {'x-real-ip': '3.3.3.3'})).status,
          200,
        );
        expect(
          (await client.get('/ok', headers: {'x-real-ip': '3.3.3.3'})).status,
          429,
        );
      });

      test('with no proxy headers, all clients share one bucket', () async {
        await client.server.use(rateLimit(maxRequests: 1));
        expect((await client.get('/ok')).status, 200);
        expect((await client.get('/ok')).status, 429);
      });

      test('custom keyExtractor and onLimit', () async {
        await client.server.use(
          rateLimit(
            maxRequests: 1,
            keyExtractor: (r) => r.header('x-tenant') ?? 'none',
            onLimit: (retryAfter) => ResponseContext.text('busy', status: 503),
          ),
        );
        expect(
          (await client.get('/ok', headers: {'x-tenant': 'a'})).status,
          200,
        );
        final r = await client.get('/ok', headers: {'x-tenant': 'a'});
        expect(r.status, 503);
        expect(r.text(), 'busy');
        // Different tenant, own bucket.
        expect(
          (await client.get('/ok', headers: {'x-tenant': 'b'})).status,
          200,
        );
      });

      test('evicts expired keys on a new window', () async {
        await client.server.use(
          rateLimit(maxRequests: 1, window: const Duration(milliseconds: 40)),
        );
        await client.get('/ok', headers: {'x-real-ip': 'old'});
        await Future<void>.delayed(const Duration(milliseconds: 60));
        // A fresh request for a different key triggers eviction of 'old'.
        expect(
          (await client.get('/ok', headers: {'x-real-ip': 'new'})).status,
          200,
        );
      });

      test('rejects a non-positive limit', () {
        expect(() => rateLimit(maxRequests: 0), throwsA(isA<AssertionError>()));
      });

      test(
        'a shared RateLimitStore enforces one limit across servers',
        () async {
          // One store shared by two independent servers stands in for a limit
          // shared across isolates/hosts.
          final shared = InMemoryRateLimitStore();
          final a = await NitroTestClient.start();
          final b = await NitroTestClient.start();
          addTearDown(a.close);
          addTearDown(b.close);
          for (final c in [a, b]) {
            await c.server.use(
              rateLimit(
                maxRequests: 2,
                store: shared,
                keyExtractor: (_) => 'k',
              ),
            );
            await c.server.get('/ok', (_) => ResponseContext.text('ok'));
          }
          // The two allowed hits are counted across BOTH servers; the third — on
          // either — is limited, proving the shared bucket.
          expect((await a.get('/ok')).status, 200);
          expect((await b.get('/ok')).status, 200);
          expect((await a.get('/ok')).status, 429);
          expect((await b.get('/ok')).status, 429);
        },
      );
    });

    group('bearerAuth', () {
      test('passes a valid token and challenges otherwise', () async {
        await client.server.use(bearerAuth((t) => t == 'sekret', realm: 'z'));
        expect(
          (await client.get(
            '/ok',
            headers: {'authorization': 'Bearer sekret'},
          )).status,
          200,
        );
        final no = await client.get('/ok');
        expect(no.status, 401);
        expect(no.headers['www-authenticate'], 'Bearer realm="z"');
        expect(
          (await client.get(
            '/ok',
            headers: {'authorization': 'Bearer nope'},
          )).status,
          401,
        );
        expect(
          (await client.get(
            '/ok',
            headers: {'authorization': 'Basic x'},
          )).status,
          401, // wrong scheme
        );
        expect(
          (await client.get(
            '/ok',
            headers: {'authorization': 'Bearer '},
          )).status,
          401, // empty token
        );
      });

      test('accepts an async verifier and case-insensitive scheme', () async {
        await client.server.use(bearerAuth((t) async => t == 'a'));
        expect(
          (await client.get(
            '/ok',
            headers: {'authorization': 'bearer a'},
          )).status,
          200,
        );
      });
    });

    group('apiKeyAuth', () {
      test('checks the configured header', () async {
        await client.server.use(
          apiKeyAuth((k) => k == 'K', headerName: 'X-My-Key'),
        );
        expect(
          (await client.get('/ok', headers: {'x-my-key': 'K'})).status,
          200,
        );
        expect((await client.get('/ok')).status, 401); // missing
        expect(
          (await client.get('/ok', headers: {'x-my-key': 'bad'})).status,
          401,
        );
      });
    });

    group('basicAuth', () {
      test('decodes and verifies credentials, else challenges', () async {
        await client.server.use(
          basicAuth((u, p) => u == 'admin' && p == 'pw', realm: 'r'),
        );
        expect(
          (await client.get(
            '/ok',
            headers: {'authorization': _basic('admin', 'pw')},
          )).status,
          200,
        );
        final no = await client.get('/ok');
        expect(no.status, 401);
        expect(no.headers['www-authenticate'], 'Basic realm="r"');
        expect(
          (await client.get(
            '/ok',
            headers: {'authorization': _basic('admin', 'x')},
          )).status,
          401, // wrong password
        );
        expect(
          (await client.get(
            '/ok',
            headers: {'authorization': 'Basic !!!notb64'},
          )).status,
          401, // malformed base64
        );
        final noColon = base64.encode(utf8.encode('nocolon'));
        expect(
          (await client.get(
            '/ok',
            headers: {'authorization': 'Basic $noColon'},
          )).status,
          401, // no user:pass separator
        );
        expect(
          (await client.get(
            '/ok',
            headers: {'authorization': 'Bearer x'},
          )).status,
          401, // wrong scheme
        );
      });

      test('supports a password containing a colon', () async {
        await client.server.use(basicAuth((u, p) => u == 'a' && p == 'b:c:d'));
        expect(
          (await client.get(
            '/ok',
            headers: {'authorization': _basic('a', 'b:c:d')},
          )).status,
          200,
        );
      });
    });
  });

  // --- fake+drive harness: edge_cases (fake+runner, local addGet) ---
  group('runner (edge)', () {
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
        expect(
          lines.single,
          matches(RegExp(r'^GET +200 +\d+(\.\d+)?(µs|ms) +/logged')),
        );
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
        expect(
          lines.single,
          matches(RegExp(r'^GET +500 +\d+(\.\d+)?(µs|ms) +/blogged')),
        );
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
  });

  // --- fake+drive harness: facade (fake+runner+server, Ids reset) ---
  group('runner (facade)', () {
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
        // New format: method · status · latency(µs/ms) · path, plain off a TTY.
        expect(
          lines.single,
          matches(RegExp(r'^PURGE +200 +\d+(\.\d+)?(µs|ms) +/p$')),
        );
      });
    });
  });
}
