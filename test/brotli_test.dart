// Native brotli codec + the compress() middleware's brotli path. Loads the
// cmake-built library and skips when it is absent (like json_writer_test /
// server_e2e_test). Where those run without the native library, compress()
// falls back to gzip — covered separately in features_test.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nitro_server/nitro_server.dart';
import 'package:nitro_server/testing.dart';
import 'package:test/test.dart';

String? _locate() {
  for (final c in nitroServerLibraryCandidates()) {
    if (File(c).existsSync()) return File(c).absolute.path;
  }
  return null;
}

void main() {
  final libPath = _locate();

  group('brotli', () {
    setUpAll(() {
      if (libPath != null) loadNitroServerNative(path: libPath);
    });

    test('is available once the engine library is loaded', () {
      expect(brotliAvailable(), isTrue);
    });

    test('compress/decompress round-trips and shrinks text', () {
      final body = Uint8List.fromList(
        utf8.encode(List.generate(400, (i) => 'row $i: item-$i\n').join()),
      );
      final compressed = brotliCompress(body, 5);
      expect(compressed.length, lessThan(body.length));
      expect(brotliDecompress(compressed), equals(body));
    });

    test(
      'compress() middleware prefers brotli when the client accepts br',
      () async {
        final client = await NitroTestClient.start();
        final big = List.generate(
          400,
          (i) => 'line $i of compressible text\n',
        ).join();
        await client.server.use(compress());
        await client.server.get('/t', (_) => ResponseContext.text(big));

        // br offered -> brotli, and the body decodes back to the original.
        final br = await client.get(
          '/t',
          headers: {'accept-encoding': 'gzip, br'},
        );
        expect(br.headers['content-encoding'], 'br');
        expect(br.headers['vary'], 'accept-encoding');
        expect(br.body.length, lessThan(big.length));
        expect(utf8.decode(brotliDecompress(Uint8List.fromList(br.body))), big);

        // Only gzip offered -> gzip (brotli available but not accepted).
        final gz = await client.get('/t', headers: {'accept-encoding': 'gzip'});
        expect(gz.headers['content-encoding'], 'gzip');
        expect(utf8.decode(gzip.decode(gz.body)), big);

        await client.close();
      },
    );
  }, skip: libPath == null ? 'native library not built' : null);
}
