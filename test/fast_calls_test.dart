/// The hand-rolled header encoder in [FastCalls] must stay byte-identical
/// to Nitro's generated `List<RawHeader>` argument encoding: the engine
/// decodes both with the same reader, and a drift would corrupt headers
/// silently rather than fail a checksum.
library;

import 'package:nitro/nitro.dart';
import 'package:nitro_server/src/internal/fast_calls.dart';
import 'package:nitro_server/src/nitro_server.native.dart';
import 'package:test/test.dart';

void main() {
  Uint8List generated(Map<String, String> headers) {
    final raw = [
      for (final e in headers.entries) RawHeader(name: e.key, value: e.value),
    ];
    final ptr = RecordWriter.encodeIndexedList(
      raw,
      (w, e) => e.writeFields(w),
      calloc,
    );
    try {
      final payloadLen = ptr.cast<Int32>().value;
      return Uint8List.fromList(ptr.asTypedList(4 + payloadLen));
    } finally {
      calloc.free(ptr);
    }
  }

  Uint8List fast(Map<String, String> headers) {
    final view = Uint8List(FastCalls.headerListBytes(headers));
    final n = FastCalls.encodeHeaderList(
      headers,
      view,
      ByteData.sublistView(view),
    );
    return view.sublist(0, n);
  }

  test('header list encoding matches the generated encoder', () {
    for (final headers in <Map<String, String>>[
      const {},
      const {'content-type': 'text/plain; charset=utf-8'},
      const {'content-type': 'application/json', 'x-count': '42', 'etag': ''},
      // Non-ASCII takes the UTF-8 path: lengths are bytes, not code units.
      const {'x-greeting': 'héllo 👋', 'x-ünïcode': 'ok'},
    ]) {
      expect(fast(headers), generated(headers), reason: '$headers');
    }
  });
}
