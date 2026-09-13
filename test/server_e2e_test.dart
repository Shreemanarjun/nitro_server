// End-to-end proof that the whole stack works: public API → runner →
// generated bridge → C++ engine → a real socket → back.
//
// Every other test replaces the FFI boundary with a fake, which is what makes
// them fast and hermetic. This one does the opposite and is the only place a
// genuine integration bug can surface. `dart:io HttpClient` is the driver —
// the roles are flipped from `nitro_http`'s suite, where a shelf server plays
// this part.
//
// It loads the library built by:
//
//   cmake -S src -B build/lib -DCMAKE_BUILD_TYPE=Release
//   cmake --build build/lib --parallel
//
// and skips itself when that artifact is absent, so `flutter test` still
// passes on a machine that has not built native code. `NITRO_SERVER_DYLIB`
// overrides the path.
//
// On Apple platforms Nitro resolves symbols with `DynamicLibrary.process()`,
// which searches images already loaded into the process — so opening the dylib
// here is what makes the plugin visible to the generated bindings.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_server/nitro_server.dart';
import 'package:nitro_server/src/internal/instance_keys.dart';
import 'package:nitro_server/src/internal/native_attach.dart';
import 'package:nitro_server/src/nitro_server.native.dart';

String? _locateLibrary() {
  final override = Platform.environment['NITRO_SERVER_DYLIB'];
  if (override != null && File(override).existsSync()) return override;

  final names = <String>[
    if (Platform.isMacOS) 'libnitro_server.dylib',
    if (Platform.isLinux) 'libnitro_server.so',
    if (Platform.isWindows) 'nitro_server.dll',
  ];
  const roots = <String>['build/lib', 'build'];
  for (final root in roots) {
    for (final name in names) {
      final candidate = File('$root/$name');
      if (candidate.existsSync()) return candidate.absolute.path;
    }
  }
  return null;
}

/// Drives one request with a fresh client: the engine closes connections
/// (`Connection: close`), so sharing a client gains nothing here.
Future<({int status, String body, HttpHeaders headers})> _get(
  int port,
  String path, {
  String method = 'GET',
  Map<String, String>? headers,
  List<int>? body,
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:$port$path'),
    );
    headers?.forEach(request.headers.set);
    if (body != null) request.add(body);
    final response = await request.close().timeout(
      const Duration(seconds: 15),
    );
    final bytes = await response.fold<BytesBuilder>(
      BytesBuilder(),
      (b, d) => b..add(d),
    );
    return (
      status: response.statusCode,
      body: utf8.decode(bytes.toBytes()),
      headers: response.headers,
    );
  } finally {
    client.close(force: true);
  }
}

/// [_get] for binary bodies: no UTF-8 decode, exact bytes back.
Future<({int status, Uint8List body})> _getBytes(
  int port,
  String path, {
  String method = 'GET',
  List<int>? body,
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:$port$path'),
    );
    if (body != null) request.add(body);
    final response = await request.close().timeout(
      const Duration(seconds: 15),
    );
    final builder = await response.fold<BytesBuilder>(
      BytesBuilder(),
      (b, d) => b..add(d),
    );
    return (status: response.statusCode, body: builder.toBytes());
  } finally {
    client.close(force: true);
  }
}

void main() {
  final libraryPath = _locateLibrary();
  final skipReason = libraryPath == null
      ? 'native library not built — run: cmake -S src -B build/lib && '
            'cmake --build build/lib --parallel'
      : null;

  group('native server', () {
    setUpAll(() {
      if (libraryPath == null) return;
      // Makes the plugin's symbols resolvable through DynamicLibrary.process(),
      // which is how Nitro loads on Apple platforms.
      DynamicLibrary.open(libraryPath);
      resetNativeAttachForTesting();
      Ids.resetForTesting();
    });

    // Nullable, not `late`: a test that throws before assigning would
    // otherwise fail again in tearDown and bury the real error under it.
    NitroServer? server;

    tearDown(() async {
      await server?.close();
      server = null;
    });

    test('reports engine capabilities', () async {
      expect(
        NitroServerNative.engine.engineVersion(),
        contains('nitro_server'),
      );
      expect(NitroServerNative.engine.supportsTls(), isFalse);
    }, skip: skipReason);

    test('starts on an ephemeral port and stops', () async {
      server = await NitroServer.bind();
      expect(server!.port, isNot(0));

      // Nothing registered: every path is a 404 from the engine itself.
      final res = await _get(server!.port, '/anything');
      expect(res.status, 404);

      final port = server!.port;
      await server!.close();
      server = null;

      // The listener is gone: connecting must fail, not hang.
      await expectLater(_get(port, '/'), throwsA(isA<Exception>()));
    }, skip: skipReason);

    test('matches a literal route and echoes the method', () async {
      server = await NitroServer.bind();
      await server!.route(HttpMethod.get, '/hello', (request) async {
        return ResponseContext.text('hi from ${request.method.name}');
      });

      final res = await _get(server!.port, '/hello');
      expect(res.status, 200);
      expect(res.body, 'hi from get');
    }, skip: skipReason);

    test('captures :param segments into the handler', () async {
      server = await NitroServer.bind();
      await server!.route(HttpMethod.get, '/users/:id', (request) async {
        return ResponseContext.json(
          jsonEncode({'id': request.param('id')}),
        );
      });

      final res = await _get(server!.port, '/users/42');
      expect(res.status, 200);
      expect(jsonDecode(res.body), {'id': '42'});
    }, skip: skipReason);

    test('static beats param beats wildcard', () async {
      server = await NitroServer.bind();
      await server!.route(
        HttpMethod.get,
        '/files/*',
        (_) async => ResponseContext.text('wild'),
      );
      await server!.route(
        HttpMethod.get,
        '/files/:name',
        (request) async => ResponseContext.text('param'),
      );
      await server!.route(
        HttpMethod.get,
        '/files/readme',
        (_) async => ResponseContext.text('static'),
      );

      expect((await _get(server!.port, '/files/readme')).body, 'static');
      expect((await _get(server!.port, '/files/other')).body, 'param');
      expect((await _get(server!.port, '/files/a/b')).body, 'wild');
    }, skip: skipReason);

    test('echoes a POST body byte-intact', () async {
      server = await NitroServer.bind();
      await server!.route(HttpMethod.post, '/echo', (request) async {
        return ResponseContext.bytes(request.body);
      });

      final payload = List<int>.generate(200000, (i) => i & 0xff);
      final res = await _getBytes(
        server!.port,
        '/echo',
        method: 'POST',
        body: payload,
      );
      expect(res.status, 200);
      expect(res.body, orderedEquals(payload));
    }, skip: skipReason);

    test('query string and headers reach the handler', () async {
      server = await NitroServer.bind();
      await server!.route(HttpMethod.get, '/q', (request) async {
        return ResponseContext.json(
          jsonEncode({
            'query': request.queryParameters,
            'token': request.header('x-token'),
          }),
        );
      });

      final res = await _get(
        server!.port,
        '/q?a=1&b=two',
        headers: {'x-token': 's3cret'},
      );
      expect(res.status, 200);
      expect(
        jsonDecode(res.body),
        {
          'query': {'a': '1', 'b': 'two'},
          'token': 's3cret',
        },
      );
    }, skip: skipReason);

    test('unregistering removes the route', () async {
      server = await NitroServer.bind();
      await server!.route(
        HttpMethod.get,
        '/temp',
        (_) async => ResponseContext.text('here'),
      );
      expect((await _get(server!.port, '/temp')).status, 200);

      await server!.unroute(HttpMethod.get, '/temp');
      expect((await _get(server!.port, '/temp')).status, 404);

      await expectLater(
        server!.unroute(HttpMethod.get, '/temp'),
        throwsA(isA<RouteNotFoundException>()),
      );
    }, skip: skipReason);

    test('a bad pattern is rejected before touching native routes', () async {
      server = await NitroServer.bind();
      await expectLater(
        server!.route(HttpMethod.get, 'no-slash', (_) async {
          return const ResponseContext();
        }),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        server!.route(HttpMethod.get, '/a/*/b', (_) async {
          return const ResponseContext();
        }),
        throwsA(isA<ServerBadRequestException>()),
      );
    }, skip: skipReason);

    test('concurrent connections do not deadlock', () async {
      server = await NitroServer.bind();
      await server!.route(HttpMethod.get, '/users/:id', (request) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return ResponseContext.text('user ${request.param('id')}');
      });

      // 32 simultaneous connections through 32 parked native threads and one
      // shared (never blocking) Dart isolate. A shared bridge lock or a
      // clobbered callback slot would serialize or corrupt these.
      final results = await Future.wait([
        for (var i = 0; i < 32; i++) _get(server!.port, '/users/$i'),
      ]);
      for (var i = 0; i < 32; i++) {
        expect(results[i].status, 200, reason: 'request $i failed');
        expect(results[i].body, 'user $i', reason: 'request $i misrouted');
      }
    }, skip: skipReason);

    test('a slow handler hits its per-route timeout alone', () async {
      server = await NitroServer.bind();
      await server!.route(
        HttpMethod.get,
        '/slow',
        (_) async {
          await Future<void>.delayed(const Duration(seconds: 5));
          return ResponseContext.text('too late');
        },
        timeout: const Duration(milliseconds: 400),
      );
      await server!.route(
        HttpMethod.get,
        '/fast',
        (_) async => ResponseContext.text('fast'),
      );

      final slow = await _get(server!.port, '/slow');
      expect(slow.status, 408);

      // The wedged connection did not take the server with it.
      final fast = await _get(server!.port, '/fast');
      expect(fast.status, 200);
      expect(fast.body, 'fast');

      // And the late handler result was dropped, not sent twice: the client
      // already has its 408 and the connection is closed.
    }, skip: skipReason);

    test('a throwing handler is a 500, and the server survives', () async {
      server = await NitroServer.bind();
      await server!.route(HttpMethod.get, '/boom', (_) async {
        throw StateError('kaput');
      });
      await server!.route(
        HttpMethod.get,
        '/ok',
        (_) async => ResponseContext.text('ok'),
      );

      expect((await _get(server!.port, '/boom')).status, 500);
      expect((await _get(server!.port, '/ok')).body, 'ok');
    }, skip: skipReason);

    test('handler timeouts surface on the events stream', () async {
      server = await NitroServer.bind();
      final timeouts = <ServerEvent>[];
      final sub = server!.events
          .where((e) => e.kind == ServerEventKind.handlerTimeout)
          .listen(timeouts.add);
      addTearDown(sub.cancel);

      await server!.route(
        HttpMethod.get,
        '/slow',
        (_) async {
          await Future<void>.delayed(const Duration(seconds: 5));
          return ResponseContext.text('late');
        },
        timeout: const Duration(milliseconds: 200),
      );
      await server!.route(
        HttpMethod.get,
        '/ready',
        (_) async => ResponseContext.text('ready'),
      );

      // The started event fires before any request; the route below proves
      // the stream was live from bind.
      expect((await _get(server!.port, '/ready')).body, 'ready');
      expect((await _get(server!.port, '/slow')).status, 408);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(timeouts, hasLength(1));
    }, skip: skipReason);

    test('a shared client reuses keep-alive connections', () async {
      server = await NitroServer.bind();
      await server!.route(
        HttpMethod.get,
        '/r',
        (_) async => ResponseContext.text('reused'),
      );

      // One client, sequential requests: HttpClient pools the keep-alive
      // connection transparently. Failure here means the framing is off.
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      for (var i = 0; i < 10; i++) {
        final request = await client.getUrl(
          Uri.parse('http://127.0.0.1:${server!.port}/r'),
        );
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        expect(response.statusCode, 200);
        expect(body, 'reused');
      }
    }, skip: skipReason);

    test('idle keep-alive connections close after the timeout', () async {
      server = await NitroServer.bind(
        const ServerConfig(keepAliveTimeout: Duration(milliseconds: 250)),
      );
      await server!.route(
        HttpMethod.get,
        '/h',
        (_) async => ResponseContext.text('hi'),
      );

      final socket = await Socket.connect('127.0.0.1', server!.port);
      addTearDown(() => socket.destroy());
      socket.add(ascii.encode('GET /h HTTP/1.1\r\nHost: x\r\n\r\n'));
      // Drain the one framed response; the socket must then go quiet…
      final first = await socket.first.timeout(const Duration(seconds: 5));
      expect(ascii.decode(first), contains('200'));
      // …and the server must close it after the idle deadline, not hold it
      // forever and leak the worker.
      await socket.done.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw StateError('idle connection never closed'),
      );
    }, skip: skipReason);

    test('maxRequestsPerConnection forces a fresh connection', () async {
      server = await NitroServer.bind(
        const ServerConfig(maxRequestsPerConnection: 2),
      );
      await server!.route(
        HttpMethod.get,
        '/m',
        (_) async => ResponseContext.text('m'),
      );

      final socket = await Socket.connect('127.0.0.1', server!.port);
      addTearDown(() => socket.destroy());
      final received = BytesBuilder(copy: false);
      final done = Completer<void>();
      socket.listen(
        received.add,
        onDone: done.complete,
        onError: done.completeError,
      );
      socket.add(ascii.encode('GET /m HTTP/1.1\r\nHost: x\r\n\r\n'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      socket.add(ascii.encode('GET /m HTTP/1.1\r\nHost: x\r\n\r\n'));
      await done.future.timeout(const Duration(seconds: 5));

      final text = ascii.decode(received.toBytes());
      // First response stays alive, second closes: exactly two statuses.
      expect('HTTP/1.1'.allMatches(text).length, 2);
      expect(text, contains('Connection: keep-alive'));
      expect(text, contains('Connection: close'));
    }, skip: skipReason);

    test('middleware wraps handlers in registration order', () async {
      server = await NitroServer.bind();
      final order = <String>[];
      await server!.use((request, next) async {
        order.add('outer-before');
        final response = await next(request);
        order.add('outer-after');
        return response;
      });
      await server!.use((request, next) async {
        order.add('inner-before');
        final response = await next(request);
        order.add('inner-after');
        return response;
      });
      await server!.route(
        HttpMethod.get,
        '/w',
        (_) async => ResponseContext.text('w'),
      );

      expect((await _get(server!.port, '/w')).body, 'w');
      expect(order, [
        'outer-before',
        'inner-before',
        'inner-after',
        'outer-after',
      ]);
    }, skip: skipReason);

    test('a second bind on the same port fails to bind', () async {
      server = await NitroServer.bind(const ServerConfig(port: 0));
      final port = server!.port;
      await expectLater(
        NitroServer.bind(ServerConfig(port: port)),
        throwsA(isA<ServerBindException>()),
      );
    }, skip: skipReason);

    test('TLS config is refused honestly on a non-TLS build', () async {
      await expectLater(
        NitroServer.bind(
          const ServerConfig(
            port: 0,
            tls: TlsConfig(certPem: 'x', keyPem: 'y'),
          ),
        ),
        throwsA(isA<ServerTlsException>()),
      );
    }, skip: skipReason);

    test('the first native touch of a new incarnation stops stragglers',
        () async {
      server = await NitroServer.bind();
      await server!.route(
        HttpMethod.get,
        '/',
        (_) async => ResponseContext.text('one'),
      );
      final firstPort = server!.port;
      expect((await _get(firstPort, '/')).body, 'one');

      // A hot restart replaces the Dart isolate; the handshake guard — an
      // ordinary static — goes back to false. Nothing about native changes.
      resetNativeAttachForTesting();
      Ids.resetForTesting();

      // First native touch of the new incarnation stops the old listener.
      final reborn = await NitroServer.bind();
      addTearDown(reborn.close);
      await reborn.route(
        HttpMethod.get,
        '/',
        (_) async => ResponseContext.text('two'),
      );
      expect((await _get(reborn.port, '/')).body, 'two');

      // The straggler is gone: the old port refuses connections now.
      await server!.close();
      server = null;
      await expectLater(_get(firstPort, '/'), throwsA(isA<Exception>()));
    }, skip: skipReason);
  });
}
