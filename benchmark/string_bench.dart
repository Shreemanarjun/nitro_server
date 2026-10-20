// String-building microbenchmark for the server hot path — the JSON response
// build cost that dominates string-heavy endpoints.
//
//   A. JsonWriter (native flat buffer + interned key tokens + the ASCII
//      fast-path encode in _marshal — win ①) building a realistic payload.
//   B. jsonEncode(map) + utf8.encode — the dart:convert baseline a naive
//      handler pays (build a Dart String, then re-encode it to UTF-8).
//   C. toBytes() — the writer→Dart copy that win ③ (respond straight from the
//      native writer buffer) eliminates, measured across response sizes.
//
// Run AOT (the server ships AOT; JIT numbers mislead):
//   dart compile exe benchmark/string_bench.dart -o /tmp/sb && /tmp/sb
// loadNitroServerNative() dlopens the engine from build/lib (dart compile exe
// skips build hooks, so the lib must be built: cmake --build build/lib).
// Prints ns/op + MB/s; A beats B, and C shows the per-response copy ③ removes.
import 'dart:convert';
import 'dart:typed_data';
import 'package:nitro_server/nitro_server.dart';

// Candidate decode fast-path (win, decode direction): for a short ASCII body,
// String.fromCharCodes beats utf8.decode; larger bodies skip straight to
// utf8.decode so there is no regression. Measured below to pick the threshold.
const _asciiFastMax = 256;
String decodeFast(Uint8List b) {
  if (b.length <= _asciiFastMax) {
    for (var i = 0; i < b.length; i++) {
      if (b[i] >= 0x80) return utf8.decode(b);
    }
    return String.fromCharCodes(b);
  }
  return utf8.decode(b);
}

int _med(List<int> xs) {
  xs.sort();
  return xs[xs.length ~/ 2];
}

int _run(int iters, void Function() body, {int warm = 2000}) {
  for (var i = 0; i < warm; i++) {
    body();
  }
  return _med([
    for (var s = 0; s < 7; s++)
      () {
        final sw = Stopwatch()..start();
        for (var i = 0; i < iters; i++) {
          body();
        }
        sw.stop();
        return sw.elapsedMicroseconds * 1000 ~/ iters;
      }(),
  ]);
}

void main() {
  // Load the engine lib so JsonWriter's loader takes the open-by-path branch
  // (its native bindings otherwise need process() visibility, absent under a
  // bare `dart run`). The loader searches build/lib + the staged code asset.
  loadNitroServerNative();

  // A realistic list-of-objects payload (ASCII keys + mixed values).
  final rows = [
    for (var i = 0; i < 20; i++)
      {
        'id': 1000 + i,
        'name': 'user_$i',
        'email': 'user$i@example.com',
        'role': i.isEven ? 'admin' : 'member',
        'active': i % 3 != 0,
        'score': 42.5 + i,
      },
  ];

  // Interned keys (built once) — the V8-internalized-string analog.
  final kId = JsonToken('id'),
      kName = JsonToken('name'),
      kEmail = JsonToken('email'),
      kRole = JsonToken('role'),
      kActive = JsonToken('active'),
      kScore = JsonToken('score');

  final w = JsonWriter();
  void buildA() {
    w.reset();
    w.beginArray();
    for (final r in rows) {
      w.beginObject();
      w.keyToken(kId);
      w.writeInt(r['id'] as int);
      w.keyToken(kName);
      w.writeString(r['name'] as String);
      w.keyToken(kEmail);
      w.writeString(r['email'] as String);
      w.keyToken(kRole);
      w.writeString(r['role'] as String);
      w.keyToken(kActive);
      w.writeBool(r['active'] as bool);
      w.keyToken(kScore);
      w.writeDouble(r['score'] as double);
      w.endObject();
    }
    w.endArray();
  }

  // size + byte-identity sanity
  buildA();
  final aBytes = w.toBytes();
  final bBytes = utf8.encode(jsonEncode(rows));
  final identical = aBytes.length == bBytes.length;
  final size = aBytes.length;

  const iters = 20000;
  final a = _run(iters, buildA); // build only (no toBytes)
  final aFull = _run(iters, () {
    buildA();
    w.toBytes();
  }); // build + toBytes (what a handler pays today)
  final b = _run(iters, () => utf8.encode(jsonEncode(rows)));

  double mbps(int ns) => size / (ns / 1e9) / 1e6;
  print('payload: $size bytes, 20 objects × 6 fields  (JsonWriter==jsonEncode bytes: $identical)');
  print('--------------------------------------------------------------');
  print('A JsonWriter build only        ${a.toString().padLeft(6)} ns  ${mbps(a).toStringAsFixed(0).padLeft(6)} MB/s');
  print('A JsonWriter build + toBytes()  ${aFull.toString().padLeft(5)} ns  ${mbps(aFull).toStringAsFixed(0).padLeft(6)} MB/s');
  print('B jsonEncode + utf8.encode      ${b.toString().padLeft(5)} ns  ${mbps(b).toStringAsFixed(0).padLeft(6)} MB/s');
  print('  → JsonWriter(+toBytes) is ${(b / aFull).toStringAsFixed(2)}x the dart:convert baseline');
  print('  → toBytes() copy (win ③ removes it) costs ${aFull - a} ns at $size bytes');

  // B2. String-value-heavy payload — isolates writeString (win ②: escape+encode
  // in one Dart pass + jw_raw memcpy, vs encode + native jw_string escape-scan).
  final strs = [for (var i = 0; i < 50; i++) 'the quick brown fox #$i jumps over'];
  final kV = JsonToken('v');
  void buildStr() {
    w.reset();
    w.beginArray();
    for (final s in strs) {
      w
        ..beginObject()
        ..keyToken(kV)
        ..writeString(s)
        ..endObject();
    }
    w.endArray();
  }

  buildStr();
  final strSize = w.toBytes().length;
  final sNs = _run(20000, () {
    buildStr();
    w.toBytes();
  });
  print('');
  print('win ② — string-heavy ($strSize B, 50 string values): writeString build+toBytes = $sNs ns  (${(strSize / (sNs / 1e9) / 1e6).toStringAsFixed(0)} MB/s)');

  // Decode direction: utf8.decode vs the ASCII fast-path across sizes.
  print('');
  print('decode — utf8.decode vs ASCII fast-path (String.fromCharCodes):');
  for (final n in [8, 32, 128, 256, 1024]) {
    final bytes = Uint8List.fromList(List.generate(n, (i) => 0x61 + i % 26));
    final u = _run(100000, () => utf8.decode(bytes));
    final f = _run(100000, () => decodeFast(bytes));
    print('  ${n.toString().padLeft(5)} B: utf8.decode ${u.toString().padLeft(4)} ns  fast ${f.toString().padLeft(4)} ns  → ${(u / f).toStringAsFixed(2)}x');
  }

  // C. The win-③ copy across response sizes: toBytes() = writer→Dart copy.
  print('');
  print('win ③ — per-response toBytes() copy that respond-from-writer removes:');
  for (final n in [256, 4096, 65536]) {
    final big = 'x' * n;
    w.reset();
    w.beginObject();
    w.keyToken(kName);
    w.writeString(big);
    w.endObject();
    final tb = _run(n <= 4096 ? 50000 : 10000, w.toBytes);
    print('  ${n.toString().padLeft(6)} B response: toBytes() = ${tb.toString().padLeft(5)} ns  (${(n / (tb / 1e9) / 1e6).toStringAsFixed(0)} MB/s copied, avoidable)');
  }
}
