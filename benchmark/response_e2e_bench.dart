// End-to-end response benchmark for win ③ (respond straight from the JsonWriter
// buffer vs toBytes + stage copy). Binds a real NitroServer, serves a jsonWriter
// JSON body, and hammers it over a real HTTP socket — so the number is a full
// request→build→send→receive round trip, not just the copy component.
//
// Run AOT (the server ships AOT; JIT numbers mislead):
//   dart compile exe benchmark/response_e2e_bench.dart -o /tmp/re && /tmp/re
// A/B win ③: flip the `respondFromWriter` branch in server_runner._answer
// (force the bodyBytes path), recompile and re-run to see the round trip with
// the copies back in.
import 'dart:io';
import 'package:nitro_server/nitro_server.dart';

Future<void> _one(HttpClient client, Uri url) async {
  final req = await client.getUrl(url);
  final resp = await req.close();
  await resp.drain<void>();
}

// Sequential: latency per request (socket-bound).
Future<double> _seq(HttpClient client, Uri url, int n) async {
  final sw = Stopwatch()..start();
  for (var i = 0; i < n; i++) {
    await _one(client, url);
  }
  sw.stop();
  return sw.elapsedMicroseconds / n;
}

// Concurrent: keep [conc] requests in flight — saturates the server so the CPU
// ③ saves (the eliminated copies) can show up as throughput.
Future<double> _conc(HttpClient client, Uri url, int n, int conc) async {
  var done = 0;
  final sw = Stopwatch()..start();
  Future<void> worker() async {
    while (done++ < n) {
      await _one(client, url);
    }
  }

  await Future.wait([for (var i = 0; i < conc; i++) worker()]);
  sw.stop();
  return n / (sw.elapsedMicroseconds / 1e6); // req/s
}

Future<void> main() async {
  loadNitroServerNative();
  final server = await NitroServer.bind();
  // A large body makes ③'s eliminated copies (toBytes + stage) visible above
  // the socket/HTTP noise; a small one shows the common-case floor.
  for (final size in [256, 65536]) {
    final payload = 'x' * size;
    final path = '/jw$size';
    await server.get(path, (_) async {
      return ResponseContext.jsonWriter((w) {
        w
          ..beginObject()
          ..key('data')
          ..writeString(payload)
          ..endObject();
      });
    });
    final client = HttpClient()..maxConnectionsPerHost = 64;
    final url = Uri.parse('http://127.0.0.1:${server.port}$path');
    await _seq(client, url, 500); // warm
    final usPer = await _seq(client, url, 3000);
    final rps = await _conc(client, url, 20000, 64);
    print(
      'jsonWriter ${size.toString().padLeft(6)} B body: '
      'seq ${usPer.toStringAsFixed(1).padLeft(6)} µs/req   '
      'conc(64) ${rps.toStringAsFixed(0).padLeft(7)} req/s',
    );
    client.close(force: true);
  }
  await server.close();
}
