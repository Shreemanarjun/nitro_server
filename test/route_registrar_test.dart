// Route registration behavior: the registrar/runner edges and the facade
// verb shorthands. Moved verbatim from server_edge_cases_test.dart and
// server_facade_test.dart. Each harness keeps its own setUp in a nested group.
import 'dart:async';

import 'package:nitro_server/nitro_server.dart';
import 'package:nitro_server/src/internal/instance_keys.dart';
import 'package:nitro_server/src/internal/native_attach.dart';
import 'package:nitro_server/src/internal/server_runner.dart';
import 'package:nitro_server/src/nitro_server.native.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
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
          const RawIncomingRequest(
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
          const RawIncomingRequest(
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
  });

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
  });
}
