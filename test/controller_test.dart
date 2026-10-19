import 'package:nitro_server/nitro_server.dart';
import 'package:nitro_server/src/internal/server_runner.dart';
import 'package:nitro_server/src/nitro_server.native.dart';
import 'package:test/test.dart';

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
  });

  group('controllers (mount)', () {
    test('scopes prefix + middleware and dispatches method handlers', () async {
      await server.mount(_GreetController('hi'));
      expect(
        {for (final r in fake.registered) r.pattern: r.method},
        {'/greet/:name': RawServerMethod.get, '/greet/': RawServerMethod.post},
      );
      final res = await driveRequest(
        fake,
        requestId: 50,
        path: '/greet/sam',
        routePattern: '/greet/:name',
        params: const [RawRouteParam(name: 'name', value: 'sam')],
      );
      expect(String.fromCharCodes(res.body), 'hi sam'); // uses the DI'd field
      expect(res.headers['x-greet'], 'on'); // group middleware applied
    });

    test('mounts chain and a root controller mounts at /', () async {
      await (await server.mount(
        _GreetController('hey'),
      )).mount(const _PingController());
      expect({
        for (final r in fake.registered) r.pattern,
      }, containsAll(<String>{'/greet/:name', '/greet/', '/ping'}));
    });
  });
}

// ── Test controllers for the `mount` group ──────────────────────────────────
// Handlers are methods, so they share the controller's injected field — the
// DX the class form buys over free functions.
class _GreetController extends Controller {
  _GreetController(this.greeting)
    : super(prefix: '/greet', middleware: [_tag('x-greet', 'on')]);
  final String greeting;

  @override
  Future<void> register(RouteGroup on) async {
    await on.get('/:name', hello);
    await on.post('/', hello);
  }

  Future<ResponseContext> hello(RequestContext c) async =>
      ResponseContext.text('$greeting ${c.param('name')}');
}

class _PingController extends Controller {
  const _PingController() : super(prefix: '/');

  @override
  Future<void> register(RouteGroup on) async {
    await on.get('/ping', (_) async => ResponseContext.text('pong'));
  }
}

Middleware _tag(String name, String value) =>
    (req, next) async => (await next(req)).withHeader(name, value);
