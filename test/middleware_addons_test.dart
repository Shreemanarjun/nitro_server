import 'dart:convert';

import 'package:nitro_server/nitro_server.dart';
import 'package:nitro_server/testing.dart';
import 'package:test/test.dart';

String _basic(String user, String pass) =>
    'Basic ${base64.encode(utf8.encode('$user:$pass'))}';

void main() {
  late NitroTestClient client;

  setUp(() async {
    client = await NitroTestClient.start();
    await client.server.get('/ok', (_) => ResponseContext.text('ok'));
  });
  tearDown(() => client.close());

  group('rateLimit', () {
    test('allows up to the limit then answers 429 with Retry-After', () async {
      await client.server.use(rateLimit(maxRequests: 3));
      for (var i = 0; i < 3; i++) {
        expect((await client.get('/ok')).status, 200, reason: 'req $i');
      }
      final limited = await client.get('/ok');
      expect(limited.status, 429);
      expect(limited.text(), 'rate limit exceeded');
      expect(int.parse(limited.headers['retry-after']!), greaterThan(0));
    });

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
      expect((await client.get('/ok', headers: {'x-tenant': 'a'})).status, 200);
      final r = await client.get('/ok', headers: {'x-tenant': 'a'});
      expect(r.status, 503);
      expect(r.text(), 'busy');
      // Different tenant, own bucket.
      expect((await client.get('/ok', headers: {'x-tenant': 'b'})).status, 200);
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
        (await client.get('/ok', headers: {'authorization': 'Basic x'})).status,
        401, // wrong scheme
      );
      expect(
        (await client.get('/ok', headers: {'authorization': 'Bearer '})).status,
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
      expect((await client.get('/ok', headers: {'x-my-key': 'K'})).status, 200);
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
}
