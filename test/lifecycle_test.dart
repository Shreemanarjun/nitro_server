import 'dart:io';

import 'package:nitro_server/nitro_server.dart';
import 'package:nitro_server/testing.dart';
import 'package:test/test.dart';

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
}
