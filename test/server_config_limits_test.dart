/// The memory/time bounds added by the second re-audit: streamIdleTimeout,
/// streamMaxBufferBytes, maxBufferedBodyBytes — validated, copied, read from
/// the environment, and handed to the engine.
library;

import 'package:nitro_server/nitro_server.dart';
import 'package:test/test.dart';

void main() {
  test('defaults are bounded, not unlimited', () {
    const c = ServerConfig();
    expect(c.streamIdleTimeout, const Duration(minutes: 5));
    expect(c.streamMaxBufferBytes, 4 * 1024 * 1024);
    expect(c.maxBufferedBodyBytes, 64 * 1024 * 1024);
    expect(c.maxBufferedBodyBytes, greaterThanOrEqualTo(c.maxBodyBytes));
  });

  test('validate rejects the impossible values', () {
    expect(
      () => const ServerConfig(streamMaxBufferBytes: -1).validate(),
      throwsArgumentError,
    );
    expect(
      () => const ServerConfig(maxBufferedBodyBytes: -1).validate(),
      throwsArgumentError,
    );
    expect(
      () => const ServerConfig(
        maxBodyBytes: 1024,
        maxBufferedBodyBytes: 512,
      ).validate(),
      throwsArgumentError,
      reason: 'the budget must hold at least one full body',
    );
    expect(
      () => const ServerConfig(
        streamIdleTimeout: Duration(seconds: -1),
      ).validate(),
      throwsArgumentError,
    );
    // Zero is the documented "off" for each.
    const ServerConfig(
      streamIdleTimeout: Duration.zero,
      streamMaxBufferBytes: 0,
      maxBufferedBodyBytes: 0,
    ).validate();
  });

  test('copyWith and fromEnv carry the knobs', () {
    final c = const ServerConfig().copyWith(
      streamIdleTimeout: const Duration(seconds: 7),
      streamMaxBufferBytes: 123,
      maxBufferedBodyBytes: 20 * 1024 * 1024,
    );
    expect(c.streamIdleTimeout, const Duration(seconds: 7));
    expect(c.streamMaxBufferBytes, 123);
    expect(c.maxBufferedBodyBytes, 20 * 1024 * 1024);
    final e = ServerConfig.fromEnv({
      'STREAM_IDLE_TIMEOUT_MS': '1500',
      'STREAM_MAX_BUFFER_BYTES': '2048',
      'MAX_BUFFERED_BODY_BYTES': '33554432',
    });
    expect(e.streamIdleTimeout, const Duration(milliseconds: 1500));
    expect(e.streamMaxBufferBytes, 2048);
    expect(e.maxBufferedBodyBytes, 32 * 1024 * 1024);
  });
}
