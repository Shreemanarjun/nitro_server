import 'dart:convert';
import 'dart:typed_data';

import 'package:nitro_server/nitro_server.dart';
import 'package:nitro_server/testing.dart';
import 'package:test/test.dart';

void main() {
  group('client', () {
    late NitroTestClient client;

    setUp(() async {
      client = await NitroTestClient.start();
    });

    tearDown(() async {
      await client.close();
    });

    group('multipart', () {
      Uint8List body(String boundary, List<String> parts) => Uint8List.fromList(
        utf8.encode(
          '--$boundary\r\n${parts.join('\r\n--$boundary\r\n')}\r\n--$boundary--\r\n',
        ),
      );

      test('fields and files parse with names, filenames and types', () async {
        await client.server.post('/up', (r) {
          final parts = r.multipart();
          return ResponseContext.jsonBody([
            for (final p in parts)
              {
                'name': p.name,
                'file': p.filename,
                'type': p.contentType,
                'text': p.text(),
                'isFile': p.isFile,
              },
          ]);
        });
        final res = await client.post(
          '/up',
          headers: {'content-type': 'multipart/form-data; boundary="xyz"'},
          body: body('xyz', [
            'Content-Disposition: form-data; name="field"\r\n\r\nvalue',
            'Content-Disposition: form-data; name="f"; filename="a.txt"\r\n'
                'Content-Type: text/plain\r\n\r\nline1\r\nline2',
          ]),
        );
        expect(res.status, 200);
        expect(res.json(), [
          {
            'name': 'field',
            'file': null,
            'type': null,
            'text': 'value',
            'isFile': false,
          },
          {
            'name': 'f',
            'file': 'a.txt',
            'type': 'text/plain',
            'text': 'line1\r\nline2',
            'isFile': true,
          },
        ]);
        expect(
          parseMultipart(
            body('q', ['Content-Disposition: form-data; name=x\r\n\r\n']),
            'multipart/form-data; boundary=q',
          ).single.toString(),
          'MultipartPart(x, 0 bytes)',
        );
        expect(
          parseMultipart(
            body('q', [
              'Content-Disposition: form-data; name=x; filename=y\r\n\r\nz',
            ]),
            'multipart/form-data; boundary=q',
          ).single.toString(),
          'MultipartPart(x, file=y, 1 bytes)',
        );
      });

      test('rejects non-multipart and malformed bodies loudly', () {
        const ok = 'multipart/form-data; boundary=b';
        expect(
          () => parseMultipart(Uint8List(0), 'text/plain'),
          throwsFormatException,
        );
        expect(
          () => parseMultipart(Uint8List(0), 'multipart/form-data'),
          throwsFormatException,
        );
        expect(() => parseMultipart(Uint8List(0), ok), throwsFormatException);
        final noCrlf = Uint8List.fromList(utf8.encode('--bxx'));
        expect(() => parseMultipart(noCrlf, ok), throwsFormatException);
        final unterminated = Uint8List.fromList(
          utf8.encode('--b\r\nContent-Disposition: form-data; name=a'),
        );
        expect(() => parseMultipart(unterminated, ok), throwsFormatException);
        final noClose = Uint8List.fromList(
          utf8.encode('--b\r\nContent-Disposition: form-data; name=a\r\n\r\nv'),
        );
        expect(() => parseMultipart(noClose, ok), throwsFormatException);
        final noName = Uint8List.fromList(
          utf8.encode('--b\r\nContent-Type: text/plain\r\n\r\nv\r\n--b--'),
        );
        expect(() => parseMultipart(noName, ok), throwsFormatException);
        final noType = RequestContext(
          method: HttpMethod.post,
          customMethod: '',
          path: '/',
          query: '',
          queryParameters: const {},
          headers: const {},
          params: const {},
          routePattern: '/',
          body: Uint8List(0),
        );
        expect(noType.multipart, throwsFormatException);
      });
    });
  });
}
