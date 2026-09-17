// jsonEncode (dart:convert) vs the native JsonWriter across payload sizes, to
// find where the native path's speed beats its FFI-per-token overhead.
//   dart compile exe tool/perf/json_bench.dart -o build/json_bench && ./build/json_bench
// ignore_for_file: avoid_print
import 'dart:convert';

import 'package:nitro_server/nitro_server.dart';

int _sink = 0;

double _timeNaive(Object? obj, int n) {
  final sw = Stopwatch()..start();
  for (var i = 0; i < n; i++) {
    _sink ^= utf8.encode(jsonEncode(obj)).length; // jsonEncode + utf8.encode
  }
  sw.stop();
  return sw.elapsedMicroseconds / n;
}

double _timeUtf8Encoder(Object? obj, int n) {
  final sw = Stopwatch()..start();
  for (var i = 0; i < n; i++) {
    _sink ^= JsonUtf8Encoder().convert(obj).length; // what jsonBody uses today
  }
  sw.stop();
  return sw.elapsedMicroseconds / n;
}

double _timeWriter(void Function(JsonWriter) build, int n) {
  final w = JsonWriter();
  final sw = Stopwatch()..start();
  for (var i = 0; i < n; i++) {
    w.reset();
    build(w);
    _sink ^= w.toBytes().length;
  }
  sw.stop();
  w.dispose();
  return sw.elapsedMicroseconds / n;
}

void main() {
  loadNitroServerNative();
  const n = 100000;

  // 1) small: the TFB /json object.
  final small = {'message': 'Hello, World!'};
  void smallW(JsonWriter w) {
    w
      ..beginObject()
      ..key('message')
      ..writeString('Hello, World!')
      ..endObject();
  }

  // 2) medium: a realistic ~9-field user record.
  final medium = {
    'id': 12345,
    'name': 'Ada Lovelace',
    'email': 'ada@example.com',
    'age': 36,
    'active': true,
    'score': 98.6,
    'tags': ['admin', 'beta', 'vip'],
    'address': {'city': 'London', 'zip': 'SW1'},
  };
  void mediumW(JsonWriter w) {
    w
      ..beginObject()
      ..key('id')..writeInt(12345)
      ..key('name')..writeString('Ada Lovelace')
      ..key('email')..writeString('ada@example.com')
      ..key('age')..writeInt(36)
      ..key('active')..writeBool(true)
      ..key('score')..writeDouble(98.6)
      ..key('tags')..beginArray()..writeString('admin')..writeString('beta')..writeString('vip')..endArray()
      ..key('address')..beginObject()..key('city')..writeString('London')..key('zip')..writeString('SW1')..endObject()
      ..endObject();
  }

  // 3) array: TFB /fortunes scale — 100 {id, message}.
  final rows = [
    for (var i = 0; i < 100; i++)
      {'id': i, 'message': 'fortune number $i is a pretty long-ish string'},
  ];
  void rowsW(JsonWriter w) {
    w.beginArray();
    for (var i = 0; i < 100; i++) {
      w
        ..beginObject()
        ..key('id')..writeInt(i)
        ..key('message')..writeString('fortune number $i is a pretty long-ish string')
        ..endObject();
    }
    w.endArray();
  }

  for (final (label, obj, _) in [
    ('small  (1 field)', small, smallW),
    ('medium (9 fields)', medium, mediumW),
    ('array  (100 rows)', rows, rowsW),
  ]) {
    final bytes = utf8.encode(jsonEncode(obj)).length;
    _timeNaive(obj, 2000);
    _timeUtf8Encoder(obj, 2000);
    _timeWriter((w) => w.writeValue(obj), 2000);
    final naive = _timeNaive(obj, n);
    final u8 = _timeUtf8Encoder(obj, n);
    final gv = _timeWriter((w) => w.writeValue(obj), n); // native generic walk
    print('${label.padRight(18)} ${bytes.toString().padLeft(5)}B | '
        'naive ${naive.toStringAsFixed(2).padLeft(6)} | '
        'JsonUtf8Encoder ${u8.toStringAsFixed(2).padLeft(6)}us (jsonBody today) | '
        'writeValue ${gv.toStringAsFixed(2).padLeft(6)}us | '
        'vs jsonBody ${(u8 / gv).toStringAsFixed(2)}x');
  }
  if (_sink == 0x7fffffff) print('');
}
