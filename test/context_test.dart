/// Request/response context behavior: cookies, query parameters, RFC 7807
/// problem responses, SSE, CORS/copyWith body preservation, the public value
/// types (ServerConfig/ResponseContext/RequestContext), packed headers and
/// ServerConfig.fromEnv. Client-backed groups run through the in-memory
/// client; the rest are pure unit calls.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:nitro_server/nitro_server.dart';
import 'package:nitro_server/src/internal/raw_mapping.dart';
import 'package:nitro_server/testing.dart';
import 'package:test/test.dart';

void main() {
  group('client', () {
    late NitroTestClient client;

    setUp(() async {
      client = await NitroTestClient.start();
    });

    tearDown(() async {
      await client.close();
    });

    group('cookies', () {
      test('request cookies parse by name, values verbatim', () async {
        await client.server.get(
          '/c',
          (r) => ResponseContext.jsonBody(r.cookies),
        );
        final res = await client.get(
          '/c',
          headers: {'cookie': 'a=1; b=two=2; bad; c= spaced '},
        );
        expect(res.json(), {'a': '1', 'b': 'two=2', 'c': 'spaced'});
        expect((await client.get('/c')).json(), <String, Object?>{});
      });

      test('SetCookie renders every attribute', () {
        final cookie = SetCookie(
          'id',
          '42',
          maxAge: const Duration(hours: 1),
          expires: DateTime.utc(1994, 11, 6, 8, 49, 37),
          domain: 'example.com',
          path: '/app',
          secure: true,
          httpOnly: true,
          sameSite: SameSite.lax,
        );
        expect(
          cookie.toHeaderValue(),
          'id=42; Expires=Sun, 06 Nov 1994 08:49:37 GMT; Max-Age=3600; '
          'Domain=example.com; Path=/app; Secure; HttpOnly; SameSite=Lax',
        );
        expect(const SetCookie('a', 'b').toHeaderValue(), 'a=b; Path=/');
        expect(cookie.toString(), startsWith('SetCookie(id=42'));
        expect(
          const SetCookie('s', '1', sameSite: SameSite.strict).toHeaderValue(),
          endsWith('SameSite=Strict'),
        );
        expect(
          const SetCookie('n', '1', sameSite: SameSite.none).toHeaderValue(),
          endsWith('SameSite=None'),
        );
      });

      test('withCookie keeps the answer and adds a set-cookie', () async {
        await client.server.get(
          '/login',
          (_) => ResponseContext.text('ok')
              .withCookie(const SetCookie('sid', 'abc', httpOnly: true))
              .withCookie(const SetCookie('theme', 'dark')),
        );
        final res = await client.get('/login');
        expect(res.text(), 'ok');
        // The in-memory client folds headers into a map: the last cookie
        // stands, the wire carries both (see the e2e test).
        expect(res.headers['set-cookie'], 'theme=dark; Path=/');
      });
    });

    group('query parameters', () {
      test(
        'queryParamAll keeps every repeated value; queryParam the last',
        () async {
          await client.server.get(
            '/q',
            (r) => ResponseContext.jsonBody({
              'all': r.queryParamAll('tag'),
              'one': r.queryParam('tag'),
              'missing': r.queryParamAll('nope'),
            }),
          );
          final res = await client.get('/q?tag=a&tag=b&tag=c&x=1');
          expect(res.json(), {
            'all': ['a', 'b', 'c'],
            'one': 'c',
            'missing': <String>[],
          });
        },
      );

      test(
        'malformed percent-encoding keeps the raw text, never throws',
        () async {
          await client.server.get(
            '/q',
            (r) => ResponseContext.text(
              '${r.queryParam('q')}|${r.queryParamAll('q').join(',')}',
            ),
          );
          expect((await client.get('/q?q=%zz')).text(), '%zz|%zz');
          expect((await client.get('/q?q=%')).text(), '%|%');
          expect(
            (await client.get('/q?q=%E0%A4%A')).text(),
            '%E0%A4%A|%E0%A4%A',
          );
          expect((await client.get('/q?q=a%20b')).text(), 'a b|a b');
        },
      );

      test('decodes percent-encoding and bare keys', () async {
        await client.server.get(
          '/q',
          (r) => ResponseContext.jsonBody({'v': r.queryParamAll('v')}),
        );
        final res = await client.get('/q?v=a%20b&v');
        expect(res.json(), {
          'v': ['a b', ''],
        });
      });
    });

    group('Server-Sent Events', () {
      test('SseEvent.encode formats fields and multi-line data', () {
        expect(const SseEvent('hello').encode(), 'data: hello\n\n');
        expect(
          const SseEvent(
            'a\nb',
            event: 'msg',
            id: '7',
            retry: Duration(seconds: 2),
          ).encode(),
          'event: msg\nid: 7\nretry: 2000\ndata: a\ndata: b\n\n',
        );
      });

      test('encode() strips CR/LF from event/id (no field injection)', () {
        // A newline in id/event would otherwise inject an extra SSE field or end
        // the event early. data splits on \r and \r\n too, not just \n.
        expect(
          const SseEvent(
            'x',
            id: 'a\nevent: steal',
            event: 'e\r\nvil',
          ).encode(),
          'event: evil\nid: aevent: steal\ndata: x\n\n',
        );
        expect(
          const SseEvent('a\rb\r\nc').encode(),
          'data: a\ndata: b\ndata: c\n\n',
        );
      });

      test('ResponseContext.sse streams events as text/event-stream', () async {
        await client.server.get(
          '/sse',
          (_) => ResponseContext.sse(
            Stream.fromIterable([
              const SseEvent('one'),
              const SseEvent('two', event: 'tick'),
            ]),
          ),
        );
        final res = await client.get('/sse');
        expect(res.headers['content-type'], contains('text/event-stream'));
        expect(res.headers['cache-control'], 'no-cache');
        expect(res.text(), 'data: one\n\nevent: tick\ndata: two\n\n');
      });
    });
  });

  group('ResponseContext.problem (RFC 7807)', () {
    test('builds a problem+json body with the standard members', () {
      final res = ResponseContext.problem(
        title: 'Invalid body',
        status: 422,
        detail: 'name is required',
        type: 'https://errors.example.com/validation',
        instance: '/users/7',
        extensions: {'field': 'name'},
      );
      expect(res.status, 422);
      expect(res.headers['content-type'], contains('application/problem+json'));
      expect(jsonDecode(utf8.decode(res.bodyBytes)), {
        'type': 'https://errors.example.com/validation',
        'title': 'Invalid body',
        'status': 422,
        'detail': 'name is required',
        'instance': '/users/7',
        'field': 'name',
      });
    });

    test('defaults: status 400, about:blank, optional members omitted', () {
      final res = ResponseContext.problem(title: 'Bad Request');
      expect(res.status, 400);
      final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map;
      expect(body['type'], 'about:blank');
      expect(body['status'], 400);
      expect(body.containsKey('detail'), isFalse);
      expect(body.containsKey('instance'), isFalse);
    });
  });

  // Regression: a header-stamping middleware (cors) rebuilt the response and
  // dropped the body for streaming / SSE / file answers (and set-cookies), so
  // they went out empty (Content-Length: 0). copyWith must carry them through.
  group('CORS / copyWith preserve body-bearing answers (regression)', () {
    RequestContext getReq() => RequestContext(
      method: HttpMethod.get,
      customMethod: '',
      path: '/',
      query: '',
      queryParameters: const {},
      headers: const {},
      params: const {},
      routePattern: '/',
      body: Uint8List(0),
    );

    test('copyWith carries stream, buffer, file range and cookies', () {
      final s = Stream<Uint8List>.value(Uint8List.fromList([1, 2, 3]));
      final streamed = ResponseContext.stream(
        s,
        status: 206,
        bufferSize: 64,
      ).copyWith(headers: {'x': 'y'});
      expect(streamed.status, 206);
      expect(streamed.headers['x'], 'y');
      expect(streamed.bodyStream, same(s));
      expect(streamed.streamBufferSize, 64);

      final filed = ResponseContext.file(
        '/tmp/x',
        offset: 10,
        length: 5,
      ).withCookie(const SetCookie('a', 'b')).copyWith(status: 200);
      expect(filed.filePath, '/tmp/x');
      expect(filed.fileOffset, 10);
      expect(filed.fileLength, 5);
      expect(filed.cookies.map((c) => c.name), contains('a'));
    });

    test('cors() keeps a streaming answer streaming', () async {
      final s = Stream<Uint8List>.value(Uint8List.fromList([1]));
      final out = await cors()(
        getReq(),
        (_) async => ResponseContext.stream(s, contentType: 'text/plain'),
      );
      expect(out.isStream, isTrue, reason: 'bodyStream must survive CORS');
      expect(out.bodyStream, same(s));
      expect(out.headers['access-control-allow-origin'], '*');
      expect(out.headers['content-type'], 'text/plain');
    });

    test('cors() keeps a file answer and its set-cookies', () async {
      final out = await cors()(
        getReq(),
        (_) async => ResponseContext.file(
          '/tmp/x',
        ).withCookie(const SetCookie('s', '1')),
      );
      expect(out.isFile, isTrue);
      expect(out.filePath, '/tmp/x');
      expect(out.cookies.map((c) => c.name), contains('s'));
    });

    test('plain RequestContext lowercases header keys for header()', () {
      final r = RequestContext(
        method: HttpMethod.get,
        customMethod: '',
        path: '/',
        query: '',
        queryParameters: const {},
        headers: const {
          'X-Foo': ['bar'],
        },
        params: const {},
        routePattern: '/',
        body: Uint8List(0),
      );
      expect(r.header('x-foo'), 'bar'); // found despite mixed-case storage
      expect(r.header('X-FOO'), 'bar');
    });
  });

  group('ServerConfig.fromEnv', () {
    test('overlays present env vars on the base, leaves the rest', () {
      final config = ServerConfig.fromEnv(const {
        'HOST': '0.0.0.0',
        'PORT': '9090',
        'ISOLATES': '4',
        'MAX_BODY_BYTES': '2048',
        'KEEP_ALIVE_TIMEOUT_MS': '1000',
        'RESPONSE_TIMING': 'false',
        'WS_COMPRESSION': '0',
      });
      expect(config.host, '0.0.0.0');
      expect(config.port, 9090);
      expect(config.isolates, 4);
      expect(config.maxBodyBytes, 2048);
      expect(config.keepAliveTimeout, const Duration(milliseconds: 1000));
      expect(config.responseTiming, isFalse);
      expect(config.wsCompression, isFalse);
      // Untouched default.
      expect(config.backlog, const ServerConfig().backlog);
    });

    test('an empty environment yields the base defaults', () {
      final config = ServerConfig.fromEnv(
        const {},
        base: const ServerConfig(port: 7000),
      );
      expect(config.port, 7000);
      expect(config.host, '127.0.0.1');
      expect(config.responseTiming, isTrue);
    });

    test('truthy spellings for booleans', () {
      expect(
        ServerConfig.fromEnv(const {'WS_COMPRESSION': 'yes'}).wsCompression,
        isTrue,
      );
      expect(
        ServerConfig.fromEnv(const {'WS_COMPRESSION': 'on'}).wsCompression,
        isTrue,
      );
      expect(
        ServerConfig.fromEnv(const {'WS_COMPRESSION': 'off'}).wsCompression,
        isFalse,
      );
      // A value that is not a boolean is an error, never silently "false".
      expect(
        () => ServerConfig.fromEnv(const {'WS_COMPRESSION': 'nope'}),
        throwsFormatException,
      );
    });

    test('a non-numeric integer variable throws instead of being ignored', () {
      expect(
        () => ServerConfig.fromEnv(const {'PORT': 'abc'}),
        throwsFormatException,
      );
      expect(
        () => ServerConfig.fromEnv(const {'MAX_BODY_BYTES': '10MB'}),
        throwsFormatException,
      );
      // Empty means unset.
      expect(ServerConfig.fromEnv(const {'PORT': ''}).port, 0);
    });

    test('reads every documented variable', () {
      final config = ServerConfig.fromEnv(const {
        'BACKLOG': '64',
        'MAX_REQUESTS_PER_CONNECTION': '1000',
        'HEADER_TIMEOUT_MS': '5000',
        'WRITE_TIMEOUT_MS': '7000',
        'BODY_TIMEOUT_MS': '9000',
        'WS_IDLE_TIMEOUT_MS': '30000',
        'MAX_CONNECTION_AGE_MS': '600000',
        'MAX_IN_FLIGHT_REQUESTS': '512',
        'WS_MAX_BUFFER_BYTES': '4096',
        'EXPOSE_ERROR_DETAILS': '1',
      });
      expect(config.bodyTimeout, const Duration(seconds: 9));
      expect(config.wsIdleTimeout, const Duration(seconds: 30));
      expect(config.maxConnectionAge, const Duration(minutes: 10));
      expect(config.maxInFlightRequests, 512);
      // Defaults: body stall = keep-alive window, WS liveness on at 60 s,
      // age and in-flight budget unbounded.
      expect(const ServerConfig().bodyTimeout, Duration.zero);
      expect(const ServerConfig().wsIdleTimeout, const Duration(seconds: 60));
      expect(const ServerConfig().maxConnectionAge, Duration.zero);
      expect(const ServerConfig().maxInFlightRequests, 0);
      expect(
        const ServerConfig()
            .copyWith(maxInFlightRequests: 3)
            .maxInFlightRequests,
        3,
      );
      expect(config.backlog, 64);
      expect(config.maxRequestsPerConnection, 1000);
      expect(config.headerTimeout, const Duration(seconds: 5));
      expect(config.writeTimeout, const Duration(seconds: 7));
      expect(config.wsMaxBufferBytes, 4096);
      expect(config.exposeErrorDetails, isTrue);
      expect(const ServerConfig().exposeErrorDetails, isFalse);
      expect(
        const ServerConfig()
            .copyWith(exposeErrorDetails: true)
            .exposeErrorDetails,
        isTrue,
      );
    });

    test('TLS policy, mutual TLS and PROXY protocol from the environment', () {
      final c = ServerConfig.fromEnv(const {
        'TLS_CERT_PEM': 'CERT',
        'TLS_KEY_PEM': 'KEY',
        'TLS_MIN_VERSION': '1.3',
        'TLS_CIPHERS': 'ECDHE-RSA-AES128-GCM-SHA256',
        'TLS_CIPHER_SUITES': 'TLS_AES_128_GCM_SHA256',
        'TLS_CLIENT_CA_FILE': '/ca.pem',
        'PROXY_PROTOCOL': 'true',
      });
      expect(c.tls.minVersion, TlsVersion.v13);
      expect(c.tls.ciphers, 'ECDHE-RSA-AES128-GCM-SHA256');
      expect(c.tls.cipherSuites, 'TLS_AES_128_GCM_SHA256');
      expect(c.tls.clientCaFile, '/ca.pem');
      expect(c.tls.mutual, isTrue);
      expect(c.proxyProtocol, isTrue);
      expect(const ServerConfig().proxyProtocol, isFalse);
      expect(const TlsConfig().minVersion, TlsVersion.v12);
      expect(const TlsConfig().mutual, isFalse);
      // Policy alone (no identity) is kept on the base's TLS config.
      expect(
        ServerConfig.fromEnv(const {'TLS_MIN_VERSION': '12'}).tls.minVersion,
        TlsVersion.v12,
      );
      expect(
        () => ServerConfig.fromEnv(const {'TLS_MIN_VERSION': '1.1'}),
        throwsFormatException,
      );
      // Mutual TLS without a server certificate cannot work: validate says so.
      expect(
        const ServerConfig(tls: TlsConfig(clientCaPem: 'CA')).validate,
        throwsArgumentError,
      );
      expect(
        const ServerConfig(
          tls: TlsConfig(certPem: 'C', keyPem: 'K', clientCaPem: 'CA'),
        ).validate,
        returnsNormally,
      );
      expect(const TlsConfig(certPem: 'C').copyWith(ciphers: 'X').ciphers, 'X');
      expect(
        const ServerConfig().copyWith(proxyProtocol: true).proxyProtocol,
        isTrue,
      );
    });

    test('TLS from files or inline PEM, always as a pair', () {
      final files = ServerConfig.fromEnv(const {
        'TLS_CERT_FILE': '/c.pem',
        'TLS_KEY_FILE': '/k.pem',
      });
      expect(files.tls.certFile, '/c.pem');
      expect(files.tls.keyFile, '/k.pem');
      final pem = ServerConfig.fromEnv(const {
        'TLS_CERT_PEM': 'CERT',
        'TLS_KEY_PEM': 'KEY',
      });
      expect(pem.tls.certPem, 'CERT');
      expect(pem.tls.keyPem, 'KEY');
      expect(
        () => ServerConfig.fromEnv(const {'TLS_CERT_FILE': '/c.pem'}),
        throwsFormatException,
      );
      expect(
        () => ServerConfig.fromEnv(const {'TLS_KEY_PEM': 'KEY'}),
        throwsFormatException,
      );
    });

    test('HTTP_PROTOCOL parses the protocol enum', () {
      expect(const ServerConfig().protocol, HttpProtocol.http2); // default
      expect(
        ServerConfig.fromEnv(const {'HTTP_PROTOCOL': 'http1.1'}).protocol,
        HttpProtocol.http1,
      );
      expect(
        ServerConfig.fromEnv(const {'HTTP_PROTOCOL': 'h2'}).protocol,
        HttpProtocol.http2,
      );
      expect(
        ServerConfig.fromEnv(const {'HTTP_PROTOCOL': '3'}).protocol,
        HttpProtocol.http3,
      );
      // Unset leaves the base default untouched; unknown is an error.
      expect(ServerConfig.fromEnv(const {}).protocol, HttpProtocol.http2);
      expect(
        () => ServerConfig.fromEnv(const {'HTTP_PROTOCOL': 'spdy'}),
        throwsFormatException,
      );
    });
  });

  group('ServerConfig.validate', () {
    test('accepts the defaults and sensible values', () {
      const ServerConfig().validate();
      const ServerConfig(
        port: 65535,
        maxConnections: 10,
        maxRequestsPerConnection: 5,
      ).validate();
    });

    test('rejects what the asserts would, at runtime', () {
      for (final bad in const <ServerConfig>[
        ServerConfig(port: -1),
        ServerConfig(port: 65536),
        ServerConfig(maxBodyBytes: 0),
        ServerConfig(maxBodyBytes: -1),
        ServerConfig(backlog: 0),
        ServerConfig(wsMaxBufferBytes: 0),
        ServerConfig(maxConnections: -1),
        ServerConfig(maxConnectionsPerIp: -1),
        ServerConfig(maxRequestsPerConnection: -1),
        ServerConfig(workerThreads: -1),
        ServerConfig(defaultTimeout: Duration(seconds: -1)),
        ServerConfig(keepAliveTimeout: Duration(seconds: -1)),
        ServerConfig(headerTimeout: Duration(seconds: -1)),
        ServerConfig(writeTimeout: Duration(seconds: -1)),
        ServerConfig(bodyTimeout: Duration(seconds: -1)),
        ServerConfig(wsIdleTimeout: Duration(seconds: -1)),
        ServerConfig(maxConnectionAge: Duration(seconds: -1)),
        ServerConfig(maxInFlightRequests: -1),
      ]) {
        expect(bad.validate, throwsArgumentError);
      }
    });
  });

  group('ServerConfig', () {
    test('isolates is typed, defaulted and copied', () {
      const base = ServerConfig();
      expect(base.isolates, 1);
      expect(base.copyWith(isolates: 0).isolates, 0);
      expect(base.copyWith(port: 8080).isolates, 1);
      expect(const ServerConfig(isolates: -1).validate, throwsArgumentError);
    });
  });

  group('ResponseContext', () {
    test('factories set content types', () {
      expect(
        ResponseContext.text('hi').headers['content-type'],
        contains('text/plain'),
      );
      expect(
        ResponseContext.json('{}').headers['content-type'],
        contains('application/json'),
      );
      expect(
        ResponseContext.jsonMap({'id': 42}).headers['content-type'],
        contains('application/json'),
      );
      expect(
        ResponseContext.html('<h1>hi</h1>').headers['content-type'],
        contains('text/html'),
      );
      expect(
        ResponseContext.bytes(Uint8List(0)).headers['content-type'],
        contains('octet-stream'),
      );
    });

    test('jsonMap encodes its argument', () {
      final response = ResponseContext.jsonMap({'id': 42, 'name': 'nitro'});
      expect(response.status, 200);
      expect(jsonDecode(utf8.decode(response.bodyBytes)), {
        'id': 42,
        'name': 'nitro',
      });
    });

    test('null body encodes empty', () {
      expect(const ResponseContext().bodyBytes, isEmpty);
    });

    test('status range is enforced', () {
      expect(() => ResponseContext(status: 99), throwsA(isA<AssertionError>()));
      expect(
        () => ResponseContext(status: 600),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('RequestContext', () {
    test('header lookup is case-insensitive, param direct', () {
      final context = RequestContext(
        method: HttpMethod.get,
        customMethod: '',
        path: '/users/42',
        query: '',
        queryParameters: const {},
        headers: const {
          'content-type': ['application/json'],
        },
        params: const {'id': '42'},
        routePattern: '/users/:id',
        body: Uint8List(0),
      );
      expect(context.header('Content-Type'), 'application/json');
      expect(context.param('id'), '42');
      expect(context.param('missing'), isNull);
    });

    test('queryParam, text and json read the request', () {
      final context = RequestContext(
        method: HttpMethod.post,
        customMethod: '',
        path: '/echo',
        query: 'a=1&b=two',
        queryParameters: const {'a': '1', 'b': 'two'},
        headers: const {},
        params: const {},
        routePattern: '/echo',
        body: Uint8List.fromList(utf8.encode('{"ok":true}')),
      );
      expect(context.queryParam('a'), '1');
      expect(context.queryParam('b'), 'two');
      expect(context.queryParam('missing'), isNull);
      expect(context.text(), '{"ok":true}');
      expect(context.json(), {'ok': true});
    });

    test('typed JSON accessors check the shape at the boundary', () {
      RequestContext withBody(String body) => RequestContext(
        method: HttpMethod.post,
        customMethod: '',
        path: '/echo',
        query: '',
        queryParameters: const {},
        headers: const {},
        params: const {},
        routePattern: '/echo',
        body: Uint8List.fromList(utf8.encode(body)),
      );
      final object = withBody('{"id": 42, "tags": ["a"]}');
      final Map<String, Object?> map = object.jsonMap();
      expect(map['id'], 42);
      expect(object.jsonAs<Map<String, Object?>>()['tags'], ['a']);
      final List<Object?> list = withBody('[1, 2]').jsonList();
      expect(list, [1, 2]);
      expect(withBody('"text"').jsonAs<String>(), 'text');
      // Valid JSON of the wrong shape fails loudly, never a late cast error.
      expect(object.jsonList, throwsFormatException);
      expect(() => withBody('[1]').jsonMap(), throwsFormatException);
      expect(() => withBody('{').jsonMap(), throwsFormatException);
    });
  });

  group('packed headers', () {
    test('pack and unpack round-trip, fold by lowercase name, keep order', () {
      final packed = packHeaders(
        {'Content-Type': 'a', 'x-Token': 'b'}.entries.followedBy(const [
          MapEntry('X-TOKEN', 'c'),
          MapEntry('empty', ''),
        ]),
      );
      expect(packed, 'Content-Type a x-Token b X-TOKEN c empty ');
      expect(unpackHeaders(packed), {
        'content-type': ['a'],
        'x-token': ['b', 'c'],
        'empty': [''],
      });
      expect(unpackHeaders(''), isEmpty);
      expect(packHeaders(const []), '');
    });

    test('a packed context unpacks headers and query on first access', () {
      final context = RequestContext.packed(
        method: HttpMethod.get,
        customMethod: '',
        path: '/q',
        query: 'a=1&b=two',
        packedHeaders: 'Accept */*',
        params: const {},
        routePattern: '/q',
        body: Uint8List(0),
      );
      expect(context.header('accept'), '*/*');
      expect(context.headers, {
        'accept': ['*/*'],
      });
      expect(context.queryParameters, {'a': '1', 'b': 'two'});
      expect(context.queryParam('b'), 'two');
      final plain = RequestContext(
        method: HttpMethod.get,
        customMethod: '',
        path: '/',
        query: '',
        headers: const {},
        params: const {},
        routePattern: '/',
        body: Uint8List(0),
      );
      expect(plain.queryParameters, isEmpty);
      expect(plain.headers, isEmpty);
    });
  });
}
