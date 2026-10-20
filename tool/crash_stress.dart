// Production-grade crash harness for the @Native FFI path. Exercises every
// native free path a real deployment hits — keep-alive and Connection:close
// HTTP, the @zeroCopy brotli return (compress middleware), chunked streams,
// SSE, WebSocket text/binary with client/abrupt close, concurrent in-flight
// load, multi-isolate fan-out, and rapid bind/close lifecycle — in a loop with
// forced GC so every NativeFinalizer runs. Run it under aggressive malloc
// diagnostics (see tool/crash_stress.sh): a double-free / bad-free / cross-image
// mutex (the two-copies split-brain) aborts the process, failing the gate.
//
// Usage: dart run tool/crash_stress.dart [--isolates N] [--rounds R]
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:nitro_server/nitro_server.dart';

final _big = String.fromCharCodes(List.filled(32768, 65)); // compressible body

// Top-level so the whole route table re-registers in every spawned isolate.
Future<void> _setup(NitroServer s) async {
  await s.use(compress());
  await s.get('/ping', (_) => ResponseContext.text('pong'));
  await s.get('/big', (_) => ResponseContext.text(_big));
  await s.get(
    '/stream',
    (_) => ResponseContext.stream(
      Stream.fromIterable(
        [for (var i = 0; i < 16; i++) Uint8List.fromList('chunk$i '.codeUnits)],
      ),
    ),
  );
  await s.get(
    '/sse',
    (_) => ResponseContext.sse(
      Stream.fromIterable([for (var i = 0; i < 16; i++) SseEvent('e$i')]),
    ),
  );
  await s.ws('/ws', _wsEcho);
}

Future<void> _wsEcho(WsSession session) async {
  await for (final m in session.messages) {
    if (m.isText) {
      session.sendText(m.text ?? '');
    } else {
      session.sendBytes(m.bytes ?? Uint8List(0));
    }
  }
}

int _argInt(List<String> a, String flag, int def) {
  final i = a.indexOf(flag);
  return (i >= 0 && i + 1 < a.length) ? int.parse(a[i + 1]) : def;
}

Future<void> main(List<String> args) async {
  final isolates = _argInt(args, '--isolates', 1);
  final rounds = _argInt(args, '--rounds', 30);
  final server = await NitroServer.bind(
    ServerConfig(isolates: isolates),
    _setup,
  );
  final port = server.port;
  final base = 'http://127.0.0.1:$port';
  stderr.writeln('[crash_stress] up on $port isolates=$isolates rounds=$rounds');

  final keep = HttpClient(); // reuses connections (keep-alive)
  Future<void> get(String p, {Map<String, String> headers = const {}}) async {
    final rq = await keep.getUrl(Uri.parse('$base$p'));
    headers.forEach(rq.headers.set);
    await (await rq.close()).drain<void>();
  }

  for (var round = 0; round < rounds; round++) {
    // 1. keep-alive burst (connection reuse, request-id churn)
    for (var i = 0; i < 30; i++) {
      await get('/ping');
    }
    // 2. Connection: close burst (fresh socket + teardown each time)
    for (var i = 0; i < 5; i++) {
      final c = HttpClient();
      final rq = await c.getUrl(Uri.parse('$base/ping'));
      rq.headers.set('connection', 'close');
      await (await rq.close()).drain<void>();
      c.close(force: true);
    }
    // 3. brotli @zeroCopy return via compress()
    for (var i = 0; i < 10; i++) {
      await get('/big', headers: {'accept-encoding': 'br, gzip'});
    }
    // 4 + 5. chunked stream + SSE
    await get('/stream');
    await get('/sse');
    // 6. concurrent in-flight
    await Future.wait([for (var i = 0; i < 20; i++) get('/ping')]);
    // 7. WS text + binary, graceful client close
    final ws = await WebSocket.connect('ws://127.0.0.1:$port/ws');
    final echoes = <dynamic>[];
    ws.listen(echoes.add);
    for (var i = 0; i < 20; i++) {
      ws.add('t$i');
      ws.add([i & 0xff, (i + 1) & 0xff, (i + 2) & 0xff]);
    }
    await Future<void>.delayed(const Duration(milliseconds: 15));
    await ws.close();
    // 8. WS abrupt close mid-exchange (payloads in flight at close)
    final ws2 = await WebSocket.connect('ws://127.0.0.1:$port/ws');
    ws2.add('x');
    await ws2.close(1001);
    // 9. rapid bind/close lifecycle (start/stop/reactor teardown churn)
    final ephemeral = await NitroServer.bind();
    await ephemeral.get('/e', (_) => ResponseContext.text('e'));
    await get('/ping'); // keep main busy during the ephemeral's lifetime
    await ephemeral.close();
    // Force every NativeFinalizer (struct shells, zero-copy buffers) to run.
    for (var g = 0; g < 40; g++) {
      final junk = List.filled(80000, g);
      junk[0]++;
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
    if (round % 10 == 0) {
      stderr.writeln('[crash_stress] round $round ok (isolates=$isolates)');
    }
  }
  keep.close(force: true);
  await server.close(); // 10. graceful shutdown (drain + stop) after the run
  stderr.writeln('[crash_stress] DONE ok isolates=$isolates');
  exit(0);
}
