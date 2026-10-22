import 'dart:async';
import 'dart:io';

import 'package:nitro_server/nitro_server.dart';
import 'package:nitro_server/src/internal/server_runner.dart';
import 'package:nitro_server/src/nitro_server.native.dart';
import 'package:nitro_server/testing.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
  late NitroTestClient client;
  setUp(() => NitroTestClient.start().then((c) => client = c));
  tearDown(() => client.close()); // idempotent if a test already closed

  test('trigger drains and closes the server, forwarding the signal', () async {
    ProcessSignal? seen;
    final gs = shutdownOnSignals(
      client.server,
      signals: const [], // no OS handlers; drive it directly
      drain: const Duration(milliseconds: 10),
      onSignal: (s) => seen = s,
    );
    expect(gs.isShuttingDown, isFalse);
    await gs.trigger(ProcessSignal.sigterm);
    expect(gs.isShuttingDown, isTrue);
    expect(seen, ProcessSignal.sigterm);
    await client.server.onClose.timeout(const Duration(seconds: 2));
  });

  test('is idempotent: repeat triggers reuse the one shutdown', () async {
    var calls = 0;
    final gs = shutdownOnSignals(
      client.server,
      signals: const [],
      drain: Duration.zero,
      onSignal: (_) => calls++,
    );
    final a = gs.trigger(ProcessSignal.sigint);
    final b = gs.trigger(ProcessSignal.sigint);
    await Future.wait([a, b]);
    expect(calls, 1); // only the first trigger ran the callback
  });

  test(
    'installs default SIGINT/SIGTERM handlers that can be cancelled',
    () async {
      final gs = shutdownOnSignals(client.server); // defaults
      expect(gs, isA<GracefulShutdown>());
      expect(gs.isShuttingDown, isFalse);
      await gs.cancel(); // remove the OS handlers without shutting down
      // server still serves after cancel
      await client.server.get('/p', (_) => ResponseContext.text('p'));
      expect((await client.get('/p')).status, 200);
    },
  );

  test('auto-cancels its handlers when the server closes on its own', () async {
    final gs = shutdownOnSignals(
      client.server,
      signals: [ProcessSignal.sigusr1],
    );
    await client.server.close(); // close directly
    // onClose -> gs.cancel() ran; triggering now is a harmless no-op close.
    await gs.trigger();
    expect(gs.isShuttingDown, isTrue);
  });

  group('runner', () {
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

    group('lifecycle edges', () {
      test('close is idempotent', () async {
        await addGet('/');
        await runner.close();
        await runner.close();
        expect(fake.stopCalls, 1);
      });

      test('all event kinds map without throwing', () async {
        final kinds = <ServerEventKind>[];
        final sub = runner.events.listen((e) => kinds.add(e.kind));
        runner.addRoute(HttpMethod.get, '', '/', null, (_) async {
          return const ResponseContext();
        });
        for (var i = 0; i < ServerEventKind.values.length; i++) {
          fake.events.add(RawServerEvent(kind: i, message: 'm$i'));
        }
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(kinds, ServerEventKind.values);
        await sub.cancel();
      });

      test(
        'an engine 408 releases the request even if the handler never returns',
        () async {
          final never = Completer<ResponseContext>();
          runner.addRoute(
            HttpMethod.get,
            '',
            '/stuck',
            null,
            (_) => never.future,
          );
          fake.heads.add(
            fakeHead(requestId: 9100, path: '/stuck', routePattern: '/stuck'),
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(runner.metrics.inFlight, 1);
          fake.events.add(
            RawServerEvent(
              kind: ServerEventKind.handlerTimeout.index,
              requestId: 9100,
              message: 'handler timed out',
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(runner.metrics.inFlight, 0);
          never.complete(const ResponseContext()); // late: a no-op
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(fake.responded.where((r) => r.requestId == 9100), isEmpty);
        },
      );

      test('a late answer after close is dropped, never sent', () async {
        final gate = Completer<ResponseContext>();
        runner.addRoute(HttpMethod.get, '', '/slow', null, (_) => gate.future);
        await Future<void>.delayed(Duration.zero);

        fake.heads.add(
          fakeHead(requestId: 400, path: '/slow', routePattern: '/slow'),
        );
        // Wait until dispatch parks on the handler future…
        for (
          var i = 0;
          i < 200 && !runner.pendingIdsForTesting.contains(400);
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(runner.pendingIdsForTesting, contains(400));
        await runner.close();
        gate.complete(const ResponseContext());
        await Future<void>.delayed(const Duration(milliseconds: 30));
        // The engine never saw a response for the reaped request.
        expect(fake.responded.where((r) => r.requestId == 400), isEmpty);
      });
    });
  });
}
