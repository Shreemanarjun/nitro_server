// JsonWriter (native-backed) — every method produces bytes identical to
// jsonEncode. Loads the cmake-built library; skips when it is absent, like
// server_e2e_test.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:nitro_server/nitro_server.dart';
import 'package:test/test.dart';

String? _locate() {
  for (final c in nitroServerLibraryCandidates()) {
    if (File(c).existsSync()) return File(c).absolute.path;
  }
  return null;
}

void main() {
  final libPath = _locate();

  group('JsonWriter', () {
    setUpAll(() {
      // loadNitroServerNative records the path, so JsonWriter's loader takes
      // the open-by-path branch (the CLI path) rather than process().
      if (libPath != null) loadNitroServerNative(path: libPath);
    });

    Uint8List enc(void Function(JsonWriter) build) {
      final w = JsonWriter();
      build(w);
      final bytes = w.toBytes();
      w.dispose();
      return bytes;
    }

    void matches(void Function(JsonWriter) build, Object? expected) {
      expect(enc(build), equals(utf8.encode(jsonEncode(expected))));
    }

    test('primitives match jsonEncode', () {
      matches((w) => w.writeInt(42), 42);
      matches((w) => w.writeInt(-7), -7);
      matches((w) => w.writeInt(0), 0);
      matches((w) => w.writeBool(true), true);
      matches((w) => w.writeBool(false), false);
      matches((w) => w.writeNull(), null);
      matches((w) => w.writeString('hi'), 'hi');
    });

    test('doubles match jsonEncode', () {
      for (final d in [0.0, 1.5, 3.0, -2.25, 0.1, 1e21, 1e-7, 1e100, 100.0]) {
        matches((w) => w.writeDouble(d), d);
      }
    });

    test('writeDouble is byte-identical to jsonEncode across many doubles', () {
      // The native formatter (std::to_chars shortest + Dart's ECMAScript-style
      // rendering) must match double.toString() exactly. Edge cases + a fuzz.
      final edges = <double>[
        0.0, -0.0, 1.0, -1.0, 0.5, 0.25, 1.5, 3.0, 298.5, 100.0, 1234.5,
        0.1, 0.2, 0.3, 0.0001, 1e-6, 1e-7, 1e20, 1e21, 1e22, 1e-20, 1e-21,
        1e100, 1e-100, 1e308, 1e-308, double.minPositive,
        1.7976931348623157e308, 3.141592653589793, 2.718281828459045,
        123456789.123456789, 9007199254740992.0, 9007199254740993.0,
        -0.0001, -1e21, -3.5, 5e-324, 4.9e-324,
        for (var i = 0; i < 200; i++) i * 1.5, // the /work payload's scores
      ];
      final rng = math.Random(0xC0FFEE);
      final fuzz = <double>[
        for (var i = 0; i < 20000; i++)
          (rng.nextDouble() - 0.5) *
              math.pow(10, rng.nextInt(60) - 30).toDouble(),
      ];
      final w = JsonWriter();
      try {
        for (final d in [...edges, ...fuzz]) {
          if (!d.isFinite) continue;
          w.reset();
          w.writeDouble(d);
          expect(
            utf8.decode(w.toBytes()),
            jsonEncode(d),
            reason: 'writeDouble($d) != jsonEncode($d)',
          );
        }
      } finally {
        w.dispose();
      }
    });

    test('writeNum picks int or double', () {
      matches((w) => w.writeNum(5), 5);
      matches((w) => w.writeNum(5.5), 5.5);
    });

    test('strings escape like jsonEncode', () {
      for (final s in [
        'a"b',
        'back\\slash',
        'tab\tnewline\ncarriage\rbell\b',
        'ctrl',
        'unicode é 🎉 日本',
        '',
      ]) {
        matches((w) => w.writeString(s), s);
      }
    });

    test('keys escape and frame objects', () {
      matches((w) {
        w
          ..beginObject()
          ..key('a"b')
          ..writeInt(1)
          ..key('name')
          ..writeString('x')
          ..endObject();
      }, {'a"b': 1, 'name': 'x'});
    });

    test('nested objects and arrays', () {
      matches(
        (w) {
          w
            ..beginArray()
            ..beginObject()
            ..key('tags')
            ..beginArray()
            ..writeString('x')
            ..writeString('y')
            ..endArray()
            ..key('ok')
            ..writeBool(true)
            ..key('nil')
            ..writeNull()
            ..endObject()
            ..writeInt(7)
            ..endArray();
        },
        [
          {
            'tags': ['x', 'y'],
            'ok': true,
            'nil': null,
          },
          7,
        ],
      );
    });

    test('the /work shape is byte-identical to jsonEncode', () {
      final data = [
        for (var i = 0; i < 200; i++)
          {
            'id': i,
            'name': 'item-\$i',
            'tags': ['a', 'b'],
            'score': i * 1.5,
          },
      ];
      final got = enc((w) {
        w.beginArray();
        for (final row in data) {
          final m = row;
          w
            ..beginObject()
            ..key('id')
            ..writeInt(m['id'] as int)
            ..key('name')
            ..writeString(m['name'] as String)
            ..key('tags')
            ..beginArray()
            ..writeString('a')
            ..writeString('b')
            ..endArray()
            ..key('score')
            ..writeDouble(m['score'] as double)
            ..endObject();
        }
        w.endArray();
      });
      expect(got, equals(utf8.encode(jsonEncode(data))));
    });

    test('writeTemplatedArray is byte-identical to jsonEncode', () {
      final segments = [
        JsonToken('{"id":'),
        JsonToken(',"score":'),
        JsonToken('}'),
      ];
      // First call allocates the scratch; the second (smaller) reuses it.
      for (final rows in [
        [1, 2, 3],
        [7],
      ]) {
        final ids = Int64List.fromList(rows);
        final scores = Float64List.fromList([for (final r in rows) r * 1.5]);
        final got = enc(
          (w) => w.writeTemplatedArray(segments, [
            IntColumn(ids),
            DoubleColumn(scores),
          ]),
        );
        final expected = [
          for (var i = 0; i < rows.length; i++)
            {'id': rows[i], 'score': rows[i] * 1.5},
        ];
        expect(got, equals(utf8.encode(jsonEncode(expected))));
      }
    });

    test('writeTemplatedArray matches the /work shape', () {
      final segments = [
        JsonToken('{"id":'),
        JsonToken(',"name":"item-\$i","tags":["a","b"],"score":'),
        JsonToken('}'),
      ];
      final ids = Int64List.fromList([for (var i = 0; i < 200; i++) i]);
      final scores = Float64List.fromList([
        for (var i = 0; i < 200; i++) i * 1.5,
      ]);
      final got = enc(
        (w) => w.writeTemplatedArray(segments, [
          IntColumn(ids),
          DoubleColumn(scores),
        ]),
      );
      final expected = [
        for (var i = 0; i < 200; i++)
          {
            'id': i,
            'name': 'item-\$i',
            'tags': ['a', 'b'],
            'score': i * 1.5,
          },
      ];
      expect(got, equals(utf8.encode(jsonEncode(expected))));
    });

    test('writeTemplatedArray validates segment count and column lengths', () {
      final w = JsonWriter();
      // Two columns need three segments.
      expect(
        () => w.writeTemplatedArray(
          [JsonToken('['), JsonToken(']')],
          [IntColumn(Int64List(1)), DoubleColumn(Float64List(1))],
        ),
        throwsArgumentError,
      );
      // Columns must be the same length.
      expect(
        () => w.writeTemplatedArray(
          [JsonToken('{"a":'), JsonToken(',"b":'), JsonToken('}')],
          [IntColumn(Int64List(3)), DoubleColumn(Float64List(2))],
        ),
        throwsArgumentError,
      );
      w.dispose();
    });

    test('writeRaw injects a pre-encoded fragment verbatim', () {
      expect(enc((w) => w.writeRaw('[1,2,3]')), utf8.encode('[1,2,3]'));
    });

    test('interned tokens emit the same bytes as key/writeString', () {
      final kId = JsonToken('i"d'); // a key needing escaping
      final vName = JsonToken('a\tb');
      final empty = JsonToken('');
      expect(kId.length, 3);
      expect(empty.length, 0);
      matches((w) {
        w
          ..beginObject()
          ..keyToken(kId)
          ..writeStringToken(vName)
          ..keyToken(empty)
          ..writeStringToken(empty)
          ..endObject();
      }, {'i"d': 'a\tb', '': ''});
    });

    test('reset reuses the writer', () {
      final w = JsonWriter();
      w.writeInt(1);
      expect(w.toBytes(), utf8.encode('1'));
      w.reset();
      w.writeString('two');
      expect(w.toBytes(), utf8.encode('"two"'));
      w.dispose();
    });

    test('writeDouble rejects non-finite, like jsonEncode', () {
      final w = JsonWriter();
      expect(() => w.writeDouble(double.nan), throwsArgumentError);
      expect(() => w.writeDouble(double.infinity), throwsArgumentError);
      w.dispose();
    });

    test('writeValue serializes any JSON value byte-identically to jsonEncode', () {
      final w = JsonWriter();
      for (final v in <Object?>[
        null,
        true,
        42,
        -3.5,
        'a "quoted"\n\tvalue',
        [1, 'two', false, null],
        {'id': 1, 'tags': ['x', 'y'], 'meta': {'v': 2, 'ok': true}},
        <String, Object?>{},
        <Object?>[],
      ]) {
        w.reset();
        w.writeValue(v);
        expect(w.toBytes(), utf8.encode(jsonEncode(v)), reason: '$v');
      }
      w.dispose();
    });

    test('writeValue uses toJson() and rejects an unencodable object', () {
      final w = JsonWriter();
      w.writeValue(_Money(5));  // has toJson
      expect(w.toBytes(), utf8.encode('{"cents":5}'));
      w.reset();
      expect(() => w.writeValue(_NoJson()),
          throwsA(isA<JsonUnsupportedObjectError>()));
      w.dispose();
    });

    test('dispose is idempotent', () {
      final w = JsonWriter()..writeInt(1);
      w.dispose();
      w.dispose();
    });

    test('ResponseContext.jsonWriter builds a JSON response', () {
      final ctx = ResponseContext.jsonWriter((w) {
        w
          ..beginObject()
          ..key('a')
          ..writeInt(1)
          ..endObject();
      });
      expect(ctx.status, 200);
      expect(ctx.headers['content-type'], contains('application/json'));
      expect(ctx.body, utf8.encode('{"a":1}'));
    });

    test('ResponseContext.jsonWriter honours status and headers', () {
      final ctx = ResponseContext.jsonWriter(
        (w) => w.writeInt(1),
        status: 201,
        headers: {'x-test': 'yes'},
      );
      expect(ctx.status, 201);
      expect(ctx.headers['x-test'], 'yes');
      expect(ctx.body, utf8.encode('1'));
    });
  }, skip: libPath == null ? 'native library not built' : null);
}

/// A value object with a `toJson()`, like a real domain type — writeValue must
/// call it, mirroring jsonEncode.
class _Money {
  final int cents;
  _Money(this.cents);
  Map<String, Object?> toJson() => {'cents': cents};
}

/// No `toJson()` — writeValue must reject it with JsonUnsupportedObjectError.
class _NoJson {}
