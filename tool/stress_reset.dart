// Stress probe for the residual x86-Linux-CI stall: a reborn server's first
// GET occasionally hangs after an in-process engine reset. That flake is
// unreproducible on Apple Silicon and rare even on x86, so it is hard to fix
// or to prove fixed. This harness compresses it: it repeats the EXACT lifecycle
// of the e2e test 'the first native touch of a new incarnation stops stragglers'
// in ONE process, hundreds of times, each GET under a tight timeout — turning a
// 1-in-many flake into a dense, fail-fast repro on a loaded runner.
//
// It is intentionally NOT named *_test.dart, so `dart test` / tool/coverage.sh
// ignore it — it adds zero flakiness to the gating suite. Run it explicitly:
//
//   dart run tool/stress_reset.dart [iterations]
//
// Env:
//   NITRO_STRESS_TIMEOUT_MS  per-GET timeout in ms (default 3000). A healthy
//                            GET is single-digit ms; a stall trips this and the
//                            probe exits non-zero naming the iteration + timing.
//
// Exit 0 = every iteration's reborn GET answered within budget (vindicates the
// retry mitigation — the stall did not reproduce even under this density).
// Exit 1 = a stall or wrong body reproduced; the printed iteration/timing is the
// ground-truth repro to attach a fix to. See the ci-tls-flakiness memory.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:nitro_server/nitro_server.dart';
import 'package:nitro_server/src/internal/instance_keys.dart';
import 'package:nitro_server/src/internal/native_attach.dart';
import 'package:nitro_server/src/nitro_server.native.dart';

/// One plain-HTTP GET of `/` over a fresh client (no connection reuse, exactly
/// like the e2e test's `_get`), bounded by [timeout].
Future<String> _get(int port, Duration timeout) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port/'));
    final res = await req.close().timeout(timeout);
    return await res.transform(utf8.decoder).join().timeout(timeout);
  } finally {
    client.close(force: true);
  }
}

Future<void> main(List<String> args) async {
  final iterations = args.isNotEmpty ? int.parse(args.first) : 200;
  final timeout = Duration(
    milliseconds:
        int.tryParse(Platform.environment['NITRO_STRESS_TIMEOUT_MS'] ?? '') ??
        3000,
  );
  stdout.writeln(
    'stress_reset: $iterations iterations, per-GET timeout '
    '${timeout.inMilliseconds}ms, pid $pid',
  );

  final total = Stopwatch()..start();
  var worstMs = 0;
  // The previous incarnation stays alive across the reset so a real straggler
  // exists, then is closed — mirroring the e2e test (close A only AFTER the
  // resetNative touch, before binding B).
  NitroServer? prev;
  for (var i = 0; i < iterations; i++) {
    if (prev != null) {
      // The hot-restart touch between incarnations: the handshake guard and the
      // Dart-side id counter reset, then the native reset stops the old listener
      // — then the straggler is closed.
      resetNativeAttachForTesting();
      Ids.resetForTesting();
      NitroServerNative.forKey(kEngineKey).resetNative();
      await prev.close();
    }

    final reborn = await NitroServer.bind();
    await reborn.route(
      HttpMethod.get,
      '/',
      (_) async => ResponseContext.text('ok$i'),
    );

    final get = Stopwatch()..start();
    final String body;
    try {
      body = await _get(reborn.port, timeout);
    } on TimeoutException {
      stderr.writeln(
        'STALL reproduced at iteration $i (port ${reborn.port}): reborn GET '
        'exceeded ${timeout.inMilliseconds}ms. worst-so-far ${worstMs}ms.',
      );
      await reborn.close();
      exitCode = 1;
      return;
    }
    get.stop();

    if (body != 'ok$i') {
      stderr.writeln(
        'WRONG BODY at iteration $i (port ${reborn.port}): got "$body" '
        'want "ok$i" — a straggler answered for the reborn server.',
      );
      await reborn.close();
      exitCode = 1;
      return;
    }

    if (get.elapsedMilliseconds > worstMs) worstMs = get.elapsedMilliseconds;
    if (i % 25 == 0) {
      stdout.writeln(
        '  iter $i: ${get.elapsedMilliseconds}ms (worst ${worstMs}ms)',
      );
    }
    prev = reborn;
  }
  await prev?.close();
  total.stop();
  stdout.writeln(
    'stress_reset: PASSED $iterations iterations in ${total.elapsedMilliseconds}ms, '
    'worst reborn GET ${worstMs}ms — stall did NOT reproduce.',
  );
}
