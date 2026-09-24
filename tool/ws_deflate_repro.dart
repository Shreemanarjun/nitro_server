import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:nitro_server/nitro_server.dart';

// Minimal repro of the WS-deflate load hang, env-driven for bisection:
//   SEQ_MS   sequential burst duration before load (0 = skip)     default 2000
//   ISO      load isolates                                         default 4
//   CONN     connections per load isolate                         default 8
//   LOAD_MS  load duration                                         default 1000
//   DEFLATE  1=compressed client, 0=plain                          default 1
//   KA       1=maxRequestsPerConnection:0                          default 1
//   AOT: dart compile exe tool/ws_deflate_repro.dart -o build/wsr && ./build/wsr
const _text = 'the quick brown fox ';
int _envi(String k, int d) => int.tryParse(Platform.environment[k] ?? '') ?? d;

Future<int> _loadIsolate(
  (int port, int perConn, int millis, bool deflate) a,
) async {
  final (port, perConn, millis, deflate) = a;
  final msg = (_text * 205).substring(0, 4096);
  final comp = deflate
      ? CompressionOptions.compressionDefault
      : CompressionOptions.compressionOff;
  final deadline = DateTime.now().add(Duration(milliseconds: millis));
  var done = 0;
  await Future.wait([
    for (var c = 0; c < perConn; c++)
      () async {
        final ws = await WebSocket.connect(
          'ws://127.0.0.1:$port/ws',
          compression: comp,
        );
        final incoming = StreamIterator<dynamic>(ws);
        while (DateTime.now().isBefore(deadline)) {
          ws.add(msg);
          if (!await incoming.moveNext()) break;
          done++;
        }
        await ws.close();
      }(),
  ]);
  return done;
}

Future<int> _spawn(int port, int perConn, int millis, bool deflate) =>
    Isolate.run(() => _loadIsolate((port, perConn, millis, deflate)));

Future<void> main() async {
  loadNitroServerNative();
  final mode = const bool.fromEnvironment('dart.vm.product') ? 'AOT' : 'JIT';
  final seqMs = _envi('SEQ_MS', 2000);
  final iso = _envi('ISO', 4);
  final conn = _envi('CONN', 8);
  final loadMs = _envi('LOAD_MS', 1000);
  final deflate = _envi('DEFLATE', 1) == 1;
  final ka = _envi('KA', 1) == 1;

  final server = await NitroServer.bind(
    ServerConfig(port: 0, isolates: 1, maxRequestsPerConnection: ka ? 0 : 100),
  );
  await server.ws('/ws', (s) async {
    await for (final m in s.messages) {
      if (m is WsText) s.sendText(m.text);
      if (m is WsBinary) s.sendBytes(m.bytes);
    }
  });
  final port = server.port;
  stdout.writeln(
    '[$mode] SEQ_MS=$seqMs ISO=$iso CONN=$conn LOAD_MS=$loadMs '
    'DEFLATE=${deflate ? 1 : 0} KA=${ka ? 1 : 0}',
  );

  if (seqMs > 0) {
    final sn = await _spawn(port, 1, seqMs, deflate);
    stdout.writeln('[$mode]   seq done: $sn echoes');
  }
  final loads = [
    for (var i = 0; i < iso; i++) _spawn(port, conn, loadMs, deflate),
  ];
  final r = await Future.any([
    Future.wait(loads).then((v) => v.fold<int>(0, (a, b) => a + b)),
    Future<int>.delayed(const Duration(seconds: 12), () => -1),
  ]);
  stdout.writeln(
    r < 0
        ? '[$mode] HANG: load did not finish in 12s'
        : '[$mode] OK: $r load echoes',
  );
  await server.close();
  exit(r < 0 ? 1 : 0);
}
