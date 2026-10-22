// Route-group facade behavior and config/value edges, against fakes.
// Moved verbatim from server_facade_test.dart ('route groups') and
// server_edge_cases_test.dart ('config and value edges'). Two harness shapes:
// the facade group needs fake+runner+server; the edge group needs fake+runner.
import 'dart:async';
import 'dart:convert';

import 'package:nitro_server/nitro_server.dart';
import 'package:nitro_server/src/internal/instance_keys.dart';
import 'package:nitro_server/src/internal/native_attach.dart';
import 'package:nitro_server/src/internal/server_runner.dart';
import 'package:nitro_server/src/nitro_server.native.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
  group('runner', () {
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

        test(
          'grouped routes dispatch and unroute by prefixed pattern',
          () async {
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
          },
        );
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
            const ServerConfig(maxRequestsPerConnection: -1).validate,
            throwsArgumentError,
          );
          expect(
            const ServerConfig(workerThreads: -1).validate,
            throwsArgumentError,
          );
          expect(
            const ServerConfig(maxConnections: -1).validate,
            throwsArgumentError,
          );
          expect(
            const ServerConfig(maxConnectionsPerIp: -1).validate,
            throwsArgumentError,
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
          expect(
            response.headers['content-type'],
            contains('application/json'),
          );
          expect(jsonDecode(String.fromCharCodes(response.body)), [
            1,
            {'a': true},
          ]);
        });
      });
    });
  });
}
