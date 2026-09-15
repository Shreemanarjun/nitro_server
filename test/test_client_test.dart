// In-memory test client coverage: routing fidelity against the engine's
// precedence, body/header/query delivery, and the documented divergences
// (direct 404s, no timeouts). No native library, no sockets.
import 'dart:async';

import 'package:nitro/nitro.dart';
import 'package:test/test.dart';
import 'package:nitro_server/nitro_server.dart';
import 'package:nitro_server/testing.dart';

void main() {
  late NitroTestClient client;

  setUp(() async {
    client = await NitroTestClient.start();
  });

  tearDown(() async {
    await client.close();
  });

  test('every verb shorthand reaches its route', () async {
    for (final method in [
      HttpMethod.head,
      HttpMethod.put,
      HttpMethod.delete,
      HttpMethod.patch,
      HttpMethod.options,
      HttpMethod.trace,
    ]) {
      await client.server.route(
        method,
        '/verb',
        (request) => ResponseContext.text(request.method.token),
      );
    }
    expect((await client.head('/verb')).status, 200);
    expect((await client.put('/verb', body: 'x')).text(), 'PUT');
    expect((await client.delete('/verb')).text(), 'DELETE');
    expect((await client.patch('/verb', body: 'x')).text(), 'PATCH');
    expect((await client.options('/verb')).text(), 'OPTIONS');
    expect((await client.request(HttpMethod.trace, '/verb')).text(), 'TRACE');
    // `*` as a request token is not a custom verb either.
    expect((await client.request(HttpMethod.all, '/verb')).status, 404);
  });

  test(
    'an all-method route answers every known verb, never a custom one',
    () async {
      await client.server.all(
        '/any',
        (r) => ResponseContext.text(r.method.token),
      );
      for (final method in [
        HttpMethod.put,
        HttpMethod.delete,
        HttpMethod.patch,
        HttpMethod.options,
        HttpMethod.trace,
      ]) {
        expect((await client.request(method, '/any')).text(), method.token);
      }
      final custom = await client.request(
        HttpMethod.custom,
        '/any',
        customMethod: 'PURGE',
      );
      expect(custom.status, 404);
    },
  );

  test('getStatic answers a fixed body with no handler', () async {
    await client.server.getStatic(
      '/health',
      'OK'.codeUnits,
      contentType: 'text/plain',
      headers: const {'cache-control': 'max-age=60'},
    );
    final res = await client.get('/health');
    expect(res.status, 200);
    expect(res.text(), 'OK');
    expect(res.headers['content-type'], 'text/plain');
    expect(res.headers['cache-control'], 'max-age=60');
  });

  test('getStatic takes a status and replaces a handler at its path', () async {
    await client.server.get('/p', (_) => ResponseContext.text('handler'));
    expect((await client.get('/p')).text(), 'handler');
    await client.server.getStatic('/p', 'gone'.codeUnits, status: 410);
    final res = await client.get('/p');
    expect(res.status, 410);
    expect(res.text(), 'gone');
  });

  test('getStatic re-registration replaces the fixed body', () async {
    await client.server.getStatic('/v', 'one'.codeUnits);
    expect((await client.get('/v')).text(), 'one');
    await client.server.getStatic('/v', 'two'.codeUnits);
    expect((await client.get('/v')).text(), 'two');
  });

  test('getStatic matches params, serves HEAD headers-only, rejects other '
      'methods', () async {
    await client.server.getStatic('/health', 'OK'.codeUnits);
    await client.server.getStatic('/u/:id', 'user'.codeUnits);

    // A `:param` static route matches with engine precedence.
    expect((await client.get('/u/42')).text(), 'user');

    // HEAD falls back to the GET static route: status held, body dropped.
    final head = await client.head('/health');
    expect(head.status, 200);
    expect(head.body, isEmpty);

    // A GET-only static route does not answer other methods (no All fallback).
    expect((await client.post('/health', body: 'x')).status, 404);
  });

  test('a custom method needs its token, a body needs a known type', () async {
    await client.server.post('/x', (_) => const ResponseContext());
    await expectLater(
      client.request(HttpMethod.custom, '/x'),
      throwsArgumentError,
    );
    await expectLater(client.post('/x', body: 42), throwsArgumentError);
  });

  test('an unanswered request times out with StateError', () async {
    final slow = await NitroTestClient.start(
      responseTimeout: const Duration(milliseconds: 30),
    );
    await slow.server.get('/never', (_) => Completer<ResponseContext>().future);
    await expectLater(slow.get('/never'), throwsStateError);
    await slow.close();
  });

  test('a websocket handshake carries headers to the session', () async {
    await client.server.ws('/live', (session) async {
      session.sendText(session.handshake.header('x-token') ?? 'none');
    });
    final ws = await client.ws('/live', headers: {'x-token': 't1'});
    expect((await ws.messages.first).text, 't1');
    await ws.close();
  });

  test('a websocket route displaced by an HTTP route never opens', () async {
    final slow = await NitroTestClient.start(
      responseTimeout: const Duration(milliseconds: 30),
    );
    await slow.server.ws('/live', (_) async {});
    // Same pattern, GET: the runner evicts the WS handler; the in-memory
    // engine still sees a WS route and dispatches, so no session opens.
    await slow.server.get('/live', (_) => ResponseContext.text('http'));
    await expectLater(slow.ws('/live'), throwsStateError);
    await slow.close();
  });

  test('a literal route answers', () async {
    await client.server.get('/hello', (_) async {
      return ResponseContext.text('hi');
    });
    final response = await client.get('/hello');
    expect(response.status, 200);
    expect(response.text(), 'hi');
  });

  test(':param segments are captured', () async {
    await client.server.get('/users/:id', (request) async {
      return ResponseContext.jsonMap({'id': request.param('id')});
    });
    final response = await client.get('/users/42');
    expect(response.json(), {'id': '42'});
  });

  test('static beats param beats wildcard', () async {
    await client.server.get('/files/*', (_) async {
      return ResponseContext.text('wild');
    });
    await client.server.get('/files/:name', (_) async {
      return ResponseContext.text('param');
    });
    await client.server.get('/files/readme', (_) async {
      return ResponseContext.text('static');
    });
    expect((await client.get('/files/readme')).text(), 'static');
    expect((await client.get('/files/other')).text(), 'param');
    expect((await client.get('/files/a/b')).text(), 'wild');
  });

  test('method-specific beats all', () async {
    await client.server.all('/m', (_) async {
      return ResponseContext.text('all');
    });
    await client.server.post('/m', (_) async {
      return ResponseContext.text('post');
    });
    expect((await client.post('/m')).text(), 'post');
    expect((await client.get('/m')).text(), 'all');
  });

  test('query, headers and bodies reach the handler', () async {
    await client.server.post('/echo', (request) async {
      return ResponseContext.jsonMap({
        'query': request.queryParameters,
        'token': request.header('x-token'),
        'body': request.text(),
      });
    });
    final response = await client.post(
      '/echo?a=1&b=two',
      body: 'payload',
      headers: {'x-token': 's3cret'},
    );
    expect(response.json(), {
      'query': {'a': '1', 'b': 'two'},
      'token': 's3cret',
      'body': 'payload',
    });
  });

  test('map bodies encode as JSON, byte bodies pass through', () async {
    await client.server.post('/in', (request) async {
      return ResponseContext.bytes(request.body);
    });
    final jsonRes = await client.post('/in', body: {'n': 1});
    expect(jsonRes.json(), {'n': 1});
    final bytesRes = await client.post('/in', body: [1, 2, 3]);
    expect(bytesRes.body, orderedEquals([1, 2, 3]));
  });

  test('groups prefix and middleware run in order', () async {
    final order = <String>[];
    await client.server.use((request, next) async {
      order.add('global');
      return next(request);
    });
    final api = client.server.group('/api');
    await api.get('/x', (_) async {
      order.add('handler');
      return const ResponseContext();
    });
    final response = await client.get('/api/x');
    expect(response.status, 200);
    expect(order, ['global', 'handler']);
  });

  test('a throwing handler is a 500 naming the error', () async {
    await client.server.get('/boom', (_) async {
      throw StateError('kaput');
    });
    final response = await client.get('/boom');
    expect(response.status, 500);
    expect(response.text(), contains('kaput'));
  });

  test('unrouted paths bypass the runner fallbacks, like the engine', () async {
    client.server.notFoundHandler = (request) =>
        ResponseContext.text('custom', status: 404);
    final response = await client.get('/ghost');
    expect(response.status, 404);
    expect(response.text(), 'not found');
  });

  test('unregistering removes the route', () async {
    await client.server.get('/temp', (_) async {
      return ResponseContext.text('here');
    });
    expect((await client.get('/temp')).status, 200);
    await client.server.unroute(HttpMethod.get, '/temp');
    expect((await client.get('/temp')).status, 404);
    await expectLater(
      client.server.unroute(HttpMethod.get, '/temp'),
      throwsA(isA<RouteNotFoundException>()),
    );
  });

  test('custom-method routes dispatch by token', () async {
    await client.server.route(
      HttpMethod.custom,
      '/cache',
      (request) async => ResponseContext.text('saw ${request.customMethod}'),
      customMethod: 'purge',
    );
    final response = await client.request(
      HttpMethod.custom,
      '/cache',
      customMethod: 'PURGE',
    );
    expect(response.text(), 'saw PURGE');
    expect((await client.get('/cache')).status, 404);
  });

  test('close is idempotent', () async {
    await client.close();
    await client.close();
  });

  test('streams concatenate into one body', () async {
    await client.server.get('/events', (_) async {
      return ResponseContext.stream(
        Stream.fromIterable([
          Uint8List.fromList('a'.codeUnits),
          Uint8List.fromList('bc'.codeUnits),
        ]),
        headers: {'content-type': 'text/event-stream'},
      );
    });
    final response = await client.get('/events');
    expect(response.status, 200);
    expect(response.headers['content-type'], 'text/event-stream');
    expect(response.text(), 'abc');
  });

  test('a slow stream still completes', () async {
    await client.server.get('/drip', (_) async {
      return ResponseContext.stream(
        Stream.periodic(
          const Duration(milliseconds: 20),
          (i) => Uint8List.fromList('$i,'.codeUnits),
        ).take(3),
      );
    });
    final response = await client.get('/drip');
    expect(response.text(), '0,1,2,');
  });

  test('buffered streams coalesce chunks with identical bytes', () async {
    await client.server.get('/buf', (_) async {
      return ResponseContext.stream(
        Stream.fromIterable([
          Uint8List.fromList('a'.codeUnits),
          Uint8List.fromList('bc'.codeUnits),
          Uint8List.fromList('def'.codeUnits),
        ]),
        bufferSize: 1024,
      );
    });
    await client.server.get('/raw', (_) async {
      return ResponseContext.stream(
        Stream.fromIterable([
          Uint8List.fromList('a'.codeUnits),
          Uint8List.fromList('bc'.codeUnits),
          Uint8List.fromList('def'.codeUnits),
        ]),
      );
    });
    final before = client.streamChunkCount;
    final buffered = await client.get('/buf');
    final afterBuffered = client.streamChunkCount;
    final raw = await client.get('/raw');
    final afterRaw = client.streamChunkCount;
    expect(buffered.text(), 'abcdef');
    expect(raw.text(), 'abcdef');
    // 6 bytes under a 1024-byte buffer: one crossing. Unbuffered: three.
    expect(afterBuffered - before, 1);
    expect(afterRaw - afterBuffered, 3);
  });

  test('buffered streams flush partial buffers at end', () async {
    await client.server.get('/part', (_) async {
      return ResponseContext.stream(
        Stream.fromIterable([
          Uint8List.fromList('abcdef'.codeUnits),
          Uint8List.fromList('gh'.codeUnits),
        ]),
        bufferSize: 5,
      );
    });
    final before = client.streamChunkCount;
    final response = await client.get('/part');
    // 6 bytes flush as one chunk at threshold, 2 remainder at end: two
    // crossings, bytes identical and ordered.
    expect(response.text(), 'abcdefgh');
    expect(client.streamChunkCount - before, 2);
  });

  test('websocket echo round-trips', () async {
    await client.server.ws('/chat', (session) async {
      await for (final message in session.messages) {
        if (message.isText) session.sendText('echo:${message.text}');
        if (message.isBinary) session.sendBytes(message.bytes!);
      }
    });
    final conn = await client.ws('/chat');
    final received = <WsMessage>[];
    final sub = conn.messages.listen(received.add);
    conn.sendText('hi');
    conn.sendBytes(Uint8List.fromList([7]));
    for (var i = 0; i < 200 && received.length < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(received, hasLength(2));
    expect(received[0].text, 'echo:hi');
    expect(received[1].bytes, orderedEquals([7]));
    await sub.cancel();
    await conn.close();
  });

  test('websocket handshake carries params and query', () async {
    RequestContext? seen;
    await client.server.ws('/rooms/:room', (session) async {
      seen = session.handshake;
      await session.close(4401);
    });
    final conn = await client.ws('/rooms/lobby?token=abc');
    expect(await conn.closedCode, 4401);
    expect(seen!.param('room'), 'lobby');
    expect(seen!.queryParam('token'), 'abc');
  });

  test('websocket to a missing route throws', () async {
    await expectLater(client.ws('/ghost'), throwsStateError);
  });
}
