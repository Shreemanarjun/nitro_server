// Marshalling cost of `respond` on the Dart isolate, generated binding vs
// the leaf fast path. Unknown request ids: the engine returns immediately,
// so the loop measures only the Dart→native call itself.
//
//   dart run tool/perf/respond_bench.dart        (JIT)
//   dart compile exe tool/perf/respond_bench.dart -o build/respond_bench && ./build/respond_bench
// ignore_for_file: avoid_print
import 'dart:typed_data';

import 'package:nitro_server/nitro_server.dart';
import 'package:nitro_server/src/internal/fast_calls.dart';
import 'package:nitro_server/src/internal/native_attach.dart';
import 'package:nitro_server/src/nitro_server.native.dart';

void main() {
  loadNitroServerNative();
  final native = attachedNative('s:bench');
  final fast = FastCalls.bind(native);
  final headers = {'content-type': 'text/plain; charset=utf-8'};
  final rawHeaders = [
    for (final e in headers.entries) RawHeader(name: e.key, value: e.value),
  ];
  final body = Uint8List.fromList('hello world!'.codeUnits);
  const n = 200000;

  for (var round = 0; round < 3; round++) {
    final sw = Stopwatch()..start();
    for (var i = 0; i < n; i++) {
      native.respond(-1 - i, 200, rawHeaders, body);
    }
    sw.stop();
    final generated = sw.elapsedMicroseconds / n;
    sw
      ..reset()
      ..start();
    for (var i = 0; i < n; i++) {
      fast.respond(-1 - i, 200, headers, body);
    }
    sw.stop();
    final leaf = sw.elapsedMicroseconds / n;
    print(
      'round $round: generated ${generated.toStringAsFixed(2)} us/call, '
      'fast ${leaf.toStringAsFixed(2)} us/call',
    );
  }
  fast.dispose();
}
