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

      test('refuses hostile boundaries and bounds parts and part headers', () {
        Uint8List body(String s) => Uint8List.fromList(utf8.encode(s));
        // RFC 2046: 1-70 bchars, not ending in a space.
        for (final bad in ['', 'x' * 71, 'a b ', 'a"b', 'a\\b', 'a;b']) {
          expect(
            () => parseMultipart(
              body('--$bad\r\n\r\n--$bad--'),
              'multipart/form-data; boundary="$bad"',
            ),
            throwsFormatException,
            reason: bad,
          );
        }
        // Too many parts.
        final many = StringBuffer();
        for (var i = 0; i < 5; i++) {
          many.write(
            '--b\r\nContent-Disposition: form-data; name=f$i\r\n\r\nv\r\n',
          );
        }
        many.write('--b--');
        const type = 'multipart/form-data; boundary=b';
        expect(parseMultipart(body(many.toString()), type), hasLength(5));
        expect(
          () => parseMultipart(body(many.toString()), type, maxParts: 4),
          throwsFormatException,
        );
        // An oversized part header block.
        final fat =
            '--b\r\nContent-Disposition: form-data; name=a\r\n'
            'X-Pad: ${'p' * 100}\r\n\r\nv\r\n--b--';
        expect(parseMultipart(body(fat), type), hasLength(1));
        expect(
          () => parseMultipart(body(fat), type, maxPartHeaderBytes: 64),
          throwsFormatException,
        );
        // The request accessor forwards the limits.
        final req = RequestContext(
          method: HttpMethod.post,
          customMethod: '',
          path: '/',
          query: '',
          headers: const {
            'content-type': [type],
          },
          params: const {},
          routePattern: '/',
          body: body(many.toString()),
        );
        expect(req.multipart(), hasLength(5));
        expect(() => req.multipart(maxParts: 2), throwsFormatException);
        // A boundary whose first byte is common in the body (first-byte skip
        // + verify) still finds exactly the real delimiters.
        const tricky =
            '--ab\r\nContent-Disposition: form-data; name=x\r\n\r\n'
            '-a-ab-a-\r\n--ab--';
        final parts = parseMultipart(
          body(tricky),
          'multipart/form-data; boundary=ab',
        );
        expect(parts.single.text(), '-a-ab-a-');
      });

      test('a UTF-8 filename (what browsers send) parses', () {
        final body = Uint8List.fromList(
          utf8.encode(
            '--b\r\nContent-Disposition: form-data; name="f"; '
            'filename="résumé ✓.pdf"\r\nContent-Type: application/pdf\r\n\r\n'
            'PDF\r\n--b--',
          ),
        );
        final part = parseMultipart(
          body,
          'multipart/form-data; boundary=b',
        ).single;
        expect(part.filename, 'résumé ✓.pdf');
        expect(part.text(), 'PDF');
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
