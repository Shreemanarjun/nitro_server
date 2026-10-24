/// Real-socket checks for the P1 availability work in
/// the production audit: method-aware 405, the global in-flight budget,
/// WebSocket liveness, connection age, body-stall deadlines and helper-isolate
/// supervision. Each test binds its own server with the knob under test.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:nitro_server/nitro_server.dart';
import 'package:nitro_server/src/internal/native_attach.dart';
import 'package:test/test.dart';

import 'support/tls_cert.dart';

String? _locateLibrary() {
  for (final c in nitroServerLibraryCandidates()) {
    if (File(c).existsSync()) return File(c).absolute.path;
  }
  return null;
}

/// Writes [request] on a fresh connection; returns the bytes that arrive
/// until the server closes or [wait] elapses.
Future<String> _raw(
  int port,
  String request, {
  Duration wait = const Duration(seconds: 3),
}) async {
  final socket = await Socket.connect('127.0.0.1', port);
  socket.add(utf8.encode(request));
  await socket.flush();
  final buf = BytesBuilder();
  final sub = socket.listen(buf.add);
  await Future.any([sub.asFuture<void>(), Future<void>.delayed(wait)]);
  await sub.cancel();
  socket.destroy();
  return utf8.decode(buf.toBytes(), allowMalformed: true);
}

String _status(String r) => r.isEmpty ? '' : r.split('\r\n').first;
String _header(String r, String name) {
  for (final line in r.split('\r\n')) {
    final colon = line.indexOf(':');
    if (colon > 0 && line.substring(0, colon).toLowerCase() == name) {
      return line.substring(colon + 1).trim();
    }
  }
  return '';
}

/// Routes for the helper tests; the body names the answering isolate.
Future<void> _whoSetup(NitroServer server) async {
  await server.get('/who', (_) async {
    return ResponseContext.text(Isolate.current.debugName ?? 'unnamed');
  });
}

/// The same routes, plus a helper isolate that throws an uncaught error after
/// it has booted (a stray timer): must surface as a notice, never as a reply.
Future<void> _noisyHelperSetup(NitroServer server) async {
  await _whoSetup(server);
  if ((Isolate.current.debugName ?? '').startsWith('nitro_server:')) {
    Timer(const Duration(milliseconds: 150), () => throw StateError('stray'));
  }
}

/// The same routes, plus a helper isolate that dies shortly after booting
/// (what a crash / OOM kill / `Isolate.exit` looks like to the supervisor).
Future<void> _dyingHelperSetup(NitroServer server) async {
  await _whoSetup(server);
  if ((Isolate.current.debugName ?? '').startsWith('nitro_server:')) {
    Timer(const Duration(milliseconds: 150), () => Isolate.current.kill());
  }
}

/// The same routes, but a helper isolate running this never returns: what a
/// wedged helper looks like to the main isolate.
Future<void> _wedgeHelpersSetup(NitroServer server) async {
  await _whoSetup(server);
  if ((Isolate.current.debugName ?? '').startsWith('nitro_server:')) {
    while (true) {} // never yields; killed by the supervisor
  }
}

void main() {
  final libraryPath = _locateLibrary();
  final skipReason = libraryPath == null ? 'native library not built' : null;

  setUpAll(() {
    if (libraryPath == null) return;
    resetNativeAttachForTesting();
  });

  NitroServer? server;
  tearDown(() async {
    await server?.close();
    server = null;
  });

  test(
    'a method mismatch is 405 with Allow; an unknown path stays 404',
    () async {
      server = await NitroServer.bind();
      await server!.get('/only', (_) => ResponseContext.text('get'));
      await server!.put('/only', (_) => ResponseContext.text('put'));
      final r = await _raw(
        server!.port,
        'POST /only HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
      );
      expect(_status(r), contains(' 405 '));
      expect(_header(r, 'allow'), 'GET, HEAD, PUT');
      final miss = await _raw(
        server!.port,
        'GET /nothing HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
      );
      expect(_status(miss), contains(' 404 '));
    },
    skip: skipReason,
  );

  test(
    'maxInFlightRequests answers 503 past the budget, 200 under it',
    () async {
      final gate = Completer<void>();
      server = await NitroServer.bind(
        const ServerConfig(maxInFlightRequests: 1),
      );
      await server!.get('/slow', (_) async {
        await gate.future;
        return ResponseContext.text('done');
      });
      final first = _raw(
        server!.port,
        'GET /slow HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
        wait: const Duration(seconds: 5),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final refused = await _raw(
        server!.port,
        'GET /slow HTTP/1.1\r\nHost: x\r\n\r\n',
      );
      expect(_status(refused), contains(' 503 '));
      expect(_header(refused, 'retry-after'), '1');
      gate.complete();
      expect(_status(await first), contains(' 200 '));
    },
    skip: skipReason,
  );

  test('wsIdleTimeout pings a quiet peer, then closes 1001', () async {
    server = await NitroServer.bind(
      const ServerConfig(wsIdleTimeout: Duration(milliseconds: 600)),
    );
    await server!.ws('/ws', (session) => session.messages.drain<void>());
    final events = <ServerEvent>[];
    final sub = server!.events.listen(events.add);
    // A hand-rolled client that never answers the ping.
    final socket = await Socket.connect('127.0.0.1', server!.port);
    socket.add(
      utf8.encode(
        'GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n'
        'Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
        'Sec-WebSocket-Version: 13\r\n\r\n',
      ),
    );
    final bytes = BytesBuilder();
    final done = socket.listen(bytes.add).asFuture<void>();
    await done.timeout(const Duration(seconds: 3));
    final all = bytes.toBytes();
    final head = utf8.decode(all, allowMalformed: true);
    expect(head, startsWith('HTTP/1.1 101'));
    final frames = all.sublist(head.indexOf('\r\n\r\n') + 4);
    // 0x89 0x00: an unmasked, empty ping; 0x88 0x02 0x03 0xE9: close 1001.
    expect(frames, containsAllInOrder([0x89, 0x00, 0x88, 0x02, 0x03, 0xe9]));
    socket.destroy();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await sub.cancel();
    expect(events.map((e) => e.message), contains('websocket idle timeout'));
  }, skip: skipReason);

  test('maxConnectionAge closes an idle keep-alive connection', () async {
    server = await NitroServer.bind(
      const ServerConfig(
        maxConnectionAge: Duration(milliseconds: 400),
        keepAliveTimeout: Duration(seconds: 10),
      ),
    );
    await server!.get('/x', (_) => ResponseContext.text('x'));
    final socket = await Socket.connect('127.0.0.1', server!.port);
    socket.add(utf8.encode('GET /x HTTP/1.1\r\nHost: x\r\n\r\n'));
    final bytes = BytesBuilder();
    final t = Stopwatch()..start();
    await socket
        .listen(bytes.add)
        .asFuture<void>()
        .timeout(const Duration(seconds: 3));
    t.stop();
    final r = utf8.decode(bytes.toBytes());
    expect(_status(r), contains(' 200 '));
    expect(_header(r, 'connection'), 'keep-alive');
    // EOF arrived (the listen future completed) once the age passed.
    expect(t.elapsedMilliseconds, greaterThanOrEqualTo(300));
    socket.destroy();
  }, skip: skipReason);

  test('bodyTimeout answers 408 to an upload that stops arriving', () async {
    server = await NitroServer.bind(
      const ServerConfig(bodyTimeout: Duration(milliseconds: 300)),
    );
    await server!.post('/up', (r) => ResponseContext.text('${r.body.length}'));
    final events = <ServerEvent>[];
    final sub = server!.events.listen(events.add);
    final r = await _raw(
      server!.port,
      'POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\nabc',
    );
    expect(_status(r), contains(' 408 '));
    await sub.cancel();
    expect(
      events
          .where((e) => e.kind == ServerEventKind.clientError)
          .map((e) => e.message),
      contains('request body timed out'),
    );
  }, skip: skipReason);

  test(
    'proxyProtocol: the PROXY header names the client; none closes',
    () async {
      server = await NitroServer.bind(const ServerConfig(proxyProtocol: true));
      await server!.get('/ip', (r) => ResponseContext.text(r.clientIp));
      final events = <ServerEvent>[];
      final sub = server!.events.listen(events.add);
      final v1 = await _raw(
        server!.port,
        'PROXY TCP4 203.0.113.9 10.0.0.1 51000 80\r\n'
        'GET /ip HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
      );
      expect(_status(v1), contains(' 200 '));
      expect(v1, endsWith('203.0.113.9'));
      // A direct client with no header is dropped, and the drop is reported.
      final bare = await _raw(
        server!.port,
        'GET /ip HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
        wait: const Duration(seconds: 1),
      );
      expect(bare, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();
      expect(
        events.map((e) => e.message),
        contains('invalid PROXY protocol header'),
      );
    },
    skip: skipReason,
  );

  test('mutual TLS: a client without a certificate is refused', () async {
    server = await NitroServer.bind(
      const ServerConfig(
        tls: TlsConfig(
          certPem: testCertPem,
          keyPem: testKeyPem,
          clientCaPem: testCertPem, // self-signed: its own trust anchor
        ),
      ),
    );
    await server!.get('/secure', (_) => ResponseContext.text('mtls'));
    final url = Uri.parse('https://127.0.0.1:${server!.port}/secure');
    // No client certificate: the handshake fails.
    final anon = HttpClient()..badCertificateCallback = (c, h, p) => true;
    await expectLater(
      () async => (await anon.getUrl(url)).close(),
      throwsA(anyOf(isA<HandshakeException>(), isA<HttpException>())),
    );
    anon.close(force: true);
    // With the certificate: served.
    final ctx = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(testCertPem))
      ..usePrivateKeyBytes(utf8.encode(testKeyPem));
    final client = HttpClient(context: ctx)
      ..badCertificateCallback = (c, h, p) => true;
    final res = await (await client.getUrl(url)).close();
    expect(res.statusCode, 200);
    expect(await res.transform(utf8.decoder).join(), 'mtls');
    client.close(force: true);
  }, skip: skipReason);

  test('a rejected TLS policy fails bind, not the first client', () async {
    await expectLater(
      NitroServer.bind(
        const ServerConfig(
          tls: TlsConfig(
            certPem: testCertPem,
            keyPem: testKeyPem,
            ciphers: 'NOT-A-CIPHER',
          ),
        ),
      ),
      throwsA(isA<ServerTlsException>()),
    );
  }, skip: skipReason);

  test(
    'withHeader / withCookie keep a JsonWriter body (re-audit #8)',
    () async {
      server = await NitroServer.bind();
      await server!.use(requestId());
      await server!.get(
        '/w',
        (_) => ResponseContext.jsonWriter((w) {
          w
            ..beginObject()
            ..key('a')
            ..writeInt(1)
            ..endObject();
        }).withCookie(const SetCookie('k', 'v')),
      );
      final r = await _raw(
        server!.port,
        'GET /w HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
      );
      expect(_status(r), contains(' 200 '));
      expect(r, endsWith('{"a":1}'));
      expect(_header(r, 'set-cookie'), startsWith('k=v'));
      expect(_header(r, 'x-request-id'), isNotEmpty);
    },
    skip: skipReason,
  );

  test(
    'a cookie that would split a streamed (SSE) answer is refused (re-audit #1)',
    () async {
      server = await NitroServer.bind();
      await server!.get(
        '/sse',
        (_) => ResponseContext.sse(
          Stream.value(const SseEvent('tick')),
        ).withCookie(const SetCookie('sid', 'ok\r\nX-Injected: yes')),
      );
      await server!.get(
        '/sse-ok',
        (_) => ResponseContext.sse(
          Stream.value(const SseEvent('tick')),
        ).withCookie(const SetCookie('sid', 'ok')),
      );
      final bad = await _raw(
        server!.port,
        'GET /sse HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
      );
      expect(_status(bad), contains(' 500 '));
      expect(bad, isNot(contains('X-Injected')));
      final ok = await _raw(
        server!.port,
        'GET /sse-ok HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
      );
      expect(_status(ok), contains(' 200 '));
      expect(_header(ok, 'set-cookie'), startsWith('sid=ok'));
      expect(_header(ok, 'date'), isNotEmpty); // streamed heads carry Date now
      expect(_header(ok, 'transfer-encoding'), 'chunked');
    },
    skip: skipReason,
  );

  test(
    'a 204 with a handler body never leaks bytes into the next response',
    () async {
      server = await NitroServer.bind();
      await server!.get(
        '/nc',
        (_) => ResponseContext.text('LEAKED', status: 204),
      );
      await server!.get('/ok', (_) => ResponseContext.text('fine'));
      final r = await _raw(
        server!.port,
        'GET /nc HTTP/1.1\r\nHost: x\r\n\r\n'
        'GET /ok HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
      );
      expect(r, isNot(contains('LEAKED')));
      expect(r, contains('HTTP/1.1 204'));
      expect(r, contains('HTTP/1.1 200'));
      expect(r, endsWith('fine'));
    },
    skip: skipReason,
  );

  test('a Latin-1 header byte is a 400, never a stranded request', () async {
    server = await NitroServer.bind(
      const ServerConfig(defaultTimeout: Duration(seconds: 5)),
    );
    await server!.get('/hello', (_) => ResponseContext.text('hi'));
    final socket = await Socket.connect('127.0.0.1', server!.port);
    socket.add([
      ...utf8.encode('GET /hello HTTP/1.1\r\nHost: x\r\nUser-Agent: caf'),
      0xe9,
      ...utf8.encode('\r\nConnection: close\r\n\r\n'),
    ]);
    final bytes = BytesBuilder();
    final t = Stopwatch()..start();
    await socket
        .listen(bytes.add)
        .asFuture<void>()
        .timeout(const Duration(seconds: 3));
    expect(utf8.decode(bytes.toBytes()), startsWith('HTTP/1.1 400'));
    expect(t.elapsedMilliseconds, lessThan(1000));
    socket.destroy();
    expect(server!.metrics.inFlight, 0);
  }, skip: skipReason);

  test(
    'headerTimeout is absolute: a header line every 300 ms does not extend it',
    () async {
      server = await NitroServer.bind(
        const ServerConfig(headerTimeout: Duration(milliseconds: 800)),
      );
      await server!.get('/x', (_) => ResponseContext.text('never'));
      final socket = await Socket.connect('127.0.0.1', server!.port);
      final closed = Completer<void>();
      socket.listen((_) {}, onDone: closed.complete, onError: (_) {});
      final t = Stopwatch()..start();
      socket.add(utf8.encode('GET /x HTTP/1.1\r\nHost: x\r\n'));
      // Keep dripping: an extendable timer would never fire.
      for (var i = 0; i < 12 && !closed.isCompleted; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        if (!closed.isCompleted) {
          try {
            socket.add(utf8.encode('X-Drip-$i: y\r\n'));
          } on SocketException {
            break;
          }
        }
      }
      await closed.future.timeout(const Duration(seconds: 2));
      t.stop();
      // 800 ms deadline + one sweep tick: well under the 3.6 s the drip lasts.
      expect(t.elapsedMilliseconds, lessThan(2000));
      socket.destroy();
    },
    skip: skipReason,
  );

  test(
    'streamIdleTimeout closes an SSE stream the handler stopped feeding',
    () async {
      server = await NitroServer.bind(
        const ServerConfig(streamIdleTimeout: Duration(milliseconds: 300)),
      );
      final silent = StreamController<SseEvent>();
      addTearDown(silent.close);
      await server!.get('/events', (_) {
        silent.add(const SseEvent('first'));
        return ResponseContext.sse(silent.stream, bufferSize: 0);
      });
      final events = <ServerEvent>[];
      final sub = server!.events.listen(events.add);
      final t = Stopwatch()..start();
      final r = await _raw(
        server!.port,
        'GET /events HTTP/1.1\r\nHost: x\r\n\r\n',
      );
      t.stop();
      expect(r, contains('data: first'));
      expect(t.elapsedMilliseconds, lessThan(2500), reason: 'not closed');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();
      expect(
        events.map((e) => e.message),
        contains(contains('stream idle timeout')),
      );
    },
    skip: skipReason,
  );

  group('helper isolate supervision', () {
    final saved = NitroServer.helperTimeout;
    tearDown(() => NitroServer.helperTimeout = saved);

    test(
      'a helper that dies is noticed at once, not on the next reply',
      () async {
        server = await NitroServer.bind(
          const ServerConfig(isolates: 2),
          _dyingHelperSetup,
        );
        expect(server!.helpersAlive, 1);
        final events = <ServerEvent>[];
        final sub = server!.events.listen(events.add);
        // The helper kills itself ~150 ms after boot; no reply is pending, so
        // only the exit port can tell — well inside helperTimeout (10 s).
        final t = Stopwatch()..start();
        while (server!.helpersHealthy && t.elapsedMilliseconds < 3000) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        t.stop();
        expect(server!.helpersHealthy, isFalse);
        expect(server!.helpersAlive, 0);
        expect(t.elapsedMilliseconds, lessThan(3000));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await sub.cancel();
        expect(
          events
              .where((e) => e.kind == ServerEventKind.notice)
              .map((e) => e.message),
          contains(contains('exited')),
        );
        // Nothing is sent to the dead helper; metrics still aggregate.
        final agg = await server!.aggregatedMetrics();
        expect(agg, isNotNull);
        // The main isolate still serves.
        final who = await _raw(
          server!.port,
          'GET /who HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
        );
        expect(_status(who), contains(' 200 '));
      },
      skip: skipReason,
    );

    test(
      'a helper that wedges on reload is killed; the server serves on',
      () async {
        NitroServer.helperTimeout = const Duration(milliseconds: 700);
        server = await NitroServer.bind(
          const ServerConfig(isolates: 2),
          _whoSetup,
        );
        expect(server!.helpersAlive, 1);
        expect(server!.helpersHealthy, isTrue);
        final events = <ServerEvent>[];
        final sub = server!.events.listen(events.add);
        final t = Stopwatch()..start();
        await server!.reload(_wedgeHelpersSetup);
        t.stop();
        expect(t.elapsedMilliseconds, lessThan(5000));
        expect(server!.helpersAlive, 0);
        expect(server!.helpersHealthy, isFalse);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await sub.cancel();
        expect(
          events
              .where((e) => e.kind == ServerEventKind.notice)
              .map((e) => e.message),
          contains(contains('unresponsive during reload')),
        );
        // Metrics skip the dead helper; readiness reports the degradation.
        final agg = await server!.aggregatedMetrics();
        expect(agg, isNotNull);
        await serveObservability(server!);
        final ready = await _raw(
          server!.port,
          'GET /readyz HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
        );
        expect(_status(ready), contains(' 503 '));
        final who = await _raw(
          server!.port,
          'GET /who HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
        );
        expect(_status(who), contains(' 200 '));
        // close() does not wait on the dead helper.
        final c = Stopwatch()..start();
        await server!.close();
        server = null;
        expect(c.elapsedMilliseconds, lessThan(2000));
      },
      skip: skipReason,
    );

    test('an uncaught error in a running helper is reported, and so is the '
        'death it causes', () async {
      server = await NitroServer.bind(
        const ServerConfig(isolates: 2),
        _noisyHelperSetup,
      );
      final notices = <String>[];
      final sub = server!.events
          .where((e) => e.kind == ServerEventKind.notice)
          .listen((e) => notices.add(e.message));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await sub.cancel();
      // The error itself, never read as a reply...
      expect(notices, contains(contains('uncaught error')));
      expect(notices, contains(contains('stray')));
      // ...and, since uncaught errors are fatal to a Dart isolate, the exit
      // it causes: the helper is dead, detached and reported at once (before
      // this fix it stayed "alive" until a reply timed out, readiness green).
      expect(notices, contains(contains('exited')));
      expect(server!.helpersAlive, 0);
      expect(server!.helpersHealthy, isFalse);
      // The main isolate serves on; nothing waits on the dead helper.
      expect((await server!.aggregatedMetrics()).requests, 0);
      await server!.reload(_whoSetup);
      final who = await _raw(
        server!.port,
        'GET /who HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
      );
      expect(_status(who), contains(' 200 '));
    }, skip: skipReason);

    test(
      'a helper that never starts fails bind within helperTimeout',
      () async {
        NitroServer.helperTimeout = const Duration(milliseconds: 500);
        final t = Stopwatch()..start();
        await expectLater(
          NitroServer.bind(const ServerConfig(isolates: 2), _wedgeHelpersSetup),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('failed to start'),
            ),
          ),
        );
        expect(t.elapsedMilliseconds, lessThan(5000));
      },
      skip: skipReason,
    );
  });
}
