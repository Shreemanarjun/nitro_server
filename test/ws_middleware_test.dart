/// `ws(middleware:)`: route middleware gates a WebSocket handshake before the
/// handler runs. The engine has already upgraded, so a short-circuit closes
/// the socket (4000+status for a 4xx, 1008 otherwise, 1011 on a throw) instead
/// of answering an HTTP status. Driven through the in-memory client, which
/// runs real runner dispatch and surfaces the handler-side close code.
library;

import 'package:nitro_server/nitro_server.dart';
import 'package:nitro_server/testing.dart';
import 'package:test/test.dart';

void main() {
  late NitroTestClient client;
  late NitroServer server;

  setUp(() async {
    client = await NitroTestClient.start();
    server = client.server;
  });

  tearDown(() => client.close());

  test(
    'originPolicy gates the handshake: 4403 unless the Origin is listed',
    () async {
      await server.ws(
        '/origin',
        (s) async {},
        middleware: [
          originPolicy(['https://app.example.com']),
        ],
      );
      final bare = await client.ws('/origin'); // browsers always send Origin
      expect(await bare.closedCode, 4403);
      final wrong = await client.ws(
        '/origin',
        headers: {'origin': 'https://evil.example'},
      );
      expect(await wrong.closedCode, 4403);
      final ok = await client.ws(
        '/origin',
        headers: {'origin': 'https://app.example.com'},
      );
      expect(await ok.closedCode, 1000); // the handler ran and returned
    },
  );

  test('no middleware: the handler runs and its return closes 1000', () async {
    var ran = false;
    await server.ws('/plain', (s) async {
      ran = true;
    });
    final ws = await client.ws('/plain');
    expect(await ws.closedCode, 1000);
    expect(ran, isTrue);
  });

  test(
    'bearerAuth without a token closes 4401; the handler never runs',
    () async {
      var ran = false;
      await server.ws('/secure', (s) async {
        ran = true;
      }, middleware: [bearerAuth((t) => t == 'secret')]);
      final ws = await client.ws('/secure');
      expect(await ws.closedCode, 4401);
      expect(ran, isFalse);
    },
  );

  test(
    'bearerAuth with the token hands the same handshake to the handler',
    () async {
      String? seen;
      await server.ws('/secure', (s) async {
        seen = s.handshake.header('x-who');
      }, middleware: [bearerAuth((t) => t == 'secret')]);
      final ws = await client.ws(
        '/secure',
        headers: {'authorization': 'Bearer secret', 'x-who': 'ada'},
      );
      expect(await ws.closedCode, 1000);
      expect(seen, 'ada');
    },
  );

  test(
    'middleware composes outermost first: the first rejection wins',
    () async {
      await server.ws(
        '/both',
        (_) async {},
        middleware: [
          (r, next) => ResponseContext.text('a', status: 401),
          (r, next) => ResponseContext.text('b', status: 403),
        ],
      );
      expect(await (await client.ws('/both')).closedCode, 4401);
    },
  );

  test('a non-4xx short-circuit closes 1008 (policy violation)', () async {
    await server.ws(
      '/five',
      (_) async {},
      middleware: [(r, next) => ResponseContext.text('x', status: 500)],
    );
    expect(await (await client.ws('/five')).closedCode, 1008);
  });

  test('a throwing middleware closes 1011', () async {
    await server.ws(
      '/boom',
      (_) async {},
      middleware: [(r, next) => throw StateError('boom')],
    );
    expect(await (await client.ws('/boom')).closedCode, 1011);
  });

  test("a group's use() list prepends to group.ws", () async {
    var ran = false;
    final api = server.group('/api');
    await api.use(
      (r, next) => r.header('x-role') == 'admin'
          ? next(r)
          : ResponseContext.text('no', status: 403),
    );
    await api.ws('/chat', (_) async {
      ran = true;
    });
    expect(await (await client.ws('/api/chat')).closedCode, 4403);
    expect(ran, isFalse);
    final ok = await client.ws('/api/chat', headers: {'x-role': 'admin'});
    expect(await ok.closedCode, 1000);
    expect(ran, isTrue);
  });
}
