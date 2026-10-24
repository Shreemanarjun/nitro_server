import 'dart:io';

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

    group('staticFiles', () {
      late Directory root;

      setUp(() {
        root = Directory.systemTemp.createTempSync('nitro_static');
        File('${root.path}/index.html').writeAsStringSync('<h1>home</h1>');
        File('${root.path}/app.js').writeAsStringSync('console.log(1)');
        File(
          '${root.path}/data.bin',
        ).writeAsBytesSync(List.generate(100, (i) => i));
        Directory('${root.path}/docs').createSync();
        File('${root.path}/docs/index.html').writeAsStringSync('docs');
        File('${root.path}/no.ext').writeAsStringSync('?');
      });

      tearDown(() => root.deleteSync(recursive: true));

      test(
        'serves files with types, index pages and caching headers',
        () async {
          await client.server.get(
            '/s/*',
            staticFiles(root.path, maxAge: const Duration(minutes: 5)),
          );
          final js = await client.get('/s/app.js');
          expect(js.status, 200);
          expect(js.text(), 'console.log(1)');
          expect(
            js.headers['content-type'],
            startsWith('application/javascript'),
          );
          expect(js.headers['accept-ranges'], 'bytes');
          expect(js.headers['cache-control'], 'max-age=300');
          expect(js.headers['etag'], startsWith('W/"'));
          expect(js.headers['last-modified'], endsWith('GMT'));
          expect((await client.get('/s/')).text(), '<h1>home</h1>');
          expect((await client.get('/s/docs')).text(), 'docs');
          expect((await client.get('/s/docs/')).text(), 'docs');
          expect(
            (await client.get('/s/no.ext')).headers['content-type'],
            'application/octet-stream',
          );
          expect((await client.get('/s/missing.txt')).status, 404);
          expect((await client.get('/s/../etc/passwd')).status, 404);
          expect((await client.get('/s/a%5Cb')).status, 404);
          expect((await client.get('/s/./app.js')).text(), 'console.log(1)');
        },
      );

      test('conditional requests answer 304', () async {
        await client.server.get('/s/*', staticFiles(root.path));
        final first = await client.get('/s/app.js');
        final etag = first.headers['etag']!;
        final modified = first.headers['last-modified']!;
        expect(
          (await client.get(
            '/s/app.js',
            headers: {'if-none-match': etag},
          )).status,
          304,
        );
        expect(
          (await client.get(
            '/s/app.js',
            headers: {'if-none-match': '"other", $etag'},
          )).status,
          304,
        );
        expect(
          (await client.get(
            '/s/app.js',
            headers: {'if-none-match': '*'},
          )).status,
          304,
        );
        expect(
          (await client.get(
            '/s/app.js',
            headers: {'if-none-match': '"other"'},
          )).status,
          200,
        );
        expect(
          (await client.get(
            '/s/app.js',
            headers: {'if-modified-since': modified},
          )).status,
          304,
        );
        expect(
          (await client.get(
            '/s/app.js',
            headers: {'if-modified-since': 'Thu, 01 Jan 1970 00:00:00 GMT'},
          )).status,
          200,
        );
        expect(
          (await client.get(
            '/s/app.js',
            headers: {'if-modified-since': 'garbage'},
          )).status,
          200,
        );
      });

      test('byte ranges answer 206, bad ones 416, odd ones whole', () async {
        await client.server.get('/s/*', staticFiles(root.path));
        final part = await client.get(
          '/s/data.bin',
          headers: {'range': 'bytes=10-19'},
        );
        expect(part.status, 206);
        expect(part.headers['content-range'], 'bytes 10-19/100');
        expect(part.body, List.generate(10, (i) => 10 + i));
        final tail = await client.get(
          '/s/data.bin',
          headers: {'range': 'bytes=95-'},
        );
        expect(tail.body, [95, 96, 97, 98, 99]);
        final suffix = await client.get(
          '/s/data.bin',
          headers: {'range': 'bytes=-3'},
        );
        expect(suffix.headers['content-range'], 'bytes 97-99/100');
        final over = await client.get(
          '/s/data.bin',
          headers: {'range': 'bytes=90-500'},
        );
        expect(over.headers['content-range'], 'bytes 90-99/100');
        final bigSuffix = await client.get(
          '/s/data.bin',
          headers: {'range': 'bytes=-500'},
        );
        expect(bigSuffix.headers['content-range'], 'bytes 0-99/100');
        final bad = await client.get(
          '/s/data.bin',
          headers: {'range': 'bytes=200-300'},
        );
        expect(bad.status, 416);
        expect(bad.headers['content-range'], 'bytes */100');
        expect(
          (await client.get(
            '/s/data.bin',
            headers: {'range': 'bytes=30-10'},
          )).status,
          416,
        );
        for (final ignored in [
          'items=1-2',
          'bytes=1-2,4-5',
          'bytes=x',
          'bytes=1-x',
          'bytes=-0',
          'bytes=-x',
        ]) {
          final whole = await client.get(
            '/s/data.bin',
            headers: {'range': ignored},
          );
          expect(whole.status, 200, reason: ignored);
          expect(whole.body.length, 100, reason: ignored);
        }
      });

      test('an empty file has no satisfiable suffix range', () async {
        File('${root.path}/empty').writeAsBytesSync([]);
        await client.server.get('/s/*', staticFiles(root.path));
        expect(
          (await client.get('/s/empty', headers: {'range': 'bytes=-1'})).status,
          416,
        );
        expect((await client.get('/s/empty')).status, 200);
      });

      test('a non-wildcard mount serves the whole path under root', () async {
        await client.server.get('/app.js', staticFiles(root.path));
        expect((await client.get('/app.js')).text(), 'console.log(1)');
      });

      group('containment (the production audit P0-1)', () {
        late Directory outer;
        late Directory served;

        setUp(() {
          outer = Directory.systemTemp.createTempSync('nitro_static_outer');
          served = Directory('${outer.path}/public')..createSync();
          File('${served.path}/index.html').writeAsStringSync('hi');
          File('${served.path}/.env').writeAsStringSync('TOKEN=x');
          Directory('${served.path}/.well-known').createSync();
          File('${served.path}/.well-known/x').writeAsStringSync('well-known');
          File('${outer.path}/secret.txt').writeAsStringSync('SECRET');
          File('${served.path}/inner.txt').writeAsStringSync('inner');
          Link('${served.path}/escape').createSync('${outer.path}/secret.txt');
          Link('${served.path}/alias').createSync('${served.path}/inner.txt');
          Link('${served.path}/updir').createSync(outer.path);
        });

        tearDown(() => outer.deleteSync(recursive: true));

        test('percent-encoded traversal never leaves the root', () async {
          await client.server.get('/s/*', staticFiles(served.path));
          for (final path in [
            '/s/../secret.txt',
            '/s/..%2fsecret.txt',
            '/s/%2e%2e%2fsecret.txt',
            '/s/%2e%2e/secret.txt',
            '/s/%2e%2e%5csecret.txt',
            '/s/..%5csecret.txt',
            '/s/.%2e/secret.txt',
            '/s/%00/index.html',
            '/s/%2fetc%2fpasswd',
            '/s/%zz',
          ]) {
            final r = await client.get(path);
            expect(r.status, 404, reason: path);
            expect(r.text(), isNot(contains('SECRET')), reason: path);
          }
          // A benign encoded segment still resolves.
          expect((await client.get('/s/%69ndex.html')).text(), 'hi');
          expect((await client.get('/s/./index.html')).text(), 'hi');
        });

        test('a symlink out of the root is a 404; one inside serves', () async {
          await client.server.get('/s/*', staticFiles(served.path));
          expect((await client.get('/s/escape')).status, 404);
          expect((await client.get('/s/updir/secret.txt')).status, 404);
          expect((await client.get('/s/alias')).text(), 'inner');
        });

        test('followSymlinks: false refuses even an in-root link', () async {
          await client.server.get(
            '/s/*',
            staticFiles(served.path, followSymlinks: false),
          );
          expect((await client.get('/s/alias')).status, 404);
          expect((await client.get('/s/inner.txt')).text(), 'inner');
        });

        test(
          'a root that does not exist (yet) serves 404, never throws',
          () async {
            await client.server.get(
              '/m/*',
              staticFiles('${outer.path}/not-yet-created'),
            );
            expect((await client.get('/m/index.html')).status, 404);
            // A file that vanishes between stat and resolve is a 404 too.
            final ghost = File('${served.path}/ghost.txt')
              ..writeAsStringSync('g');
            await client.server.get('/g/*', staticFiles(served.path));
            expect((await client.get('/g/ghost.txt')).text(), 'g');
            ghost.deleteSync();
            expect((await client.get('/g/ghost.txt')).status, 404);
          },
        );

        test('dotfiles are hidden unless opted in', () async {
          await client.server.get('/s/*', staticFiles(served.path));
          expect((await client.get('/s/.env')).status, 404);
          expect((await client.get('/s/.well-known/x')).status, 404);
          await client.server.get(
            '/d/*',
            staticFiles(served.path, dotfiles: true),
          );
          expect((await client.get('/d/.env')).text(), 'TOKEN=x');
          expect((await client.get('/d/.well-known/x')).text(), 'well-known');
          expect((await client.get('/d/..%2fsecret.txt')).status, 404);
        });
      });
    });

    group('ResponseContext.file', () {
      test('answers file bytes through the in-memory engine', () async {
        final dir = Directory.systemTemp.createTempSync('nitro_file');
        final file = File('${dir.path}/f.txt')..writeAsStringSync('0123456789');
        addTearDown(() => dir.deleteSync(recursive: true));
        await client.server.get(
          '/f',
          (_) => ResponseContext.file(file.path, contentType: 'text/plain'),
        );
        await client.server.get(
          '/part',
          (_) => ResponseContext.file(file.path, offset: 2, length: 3),
        );
        await client.server.get(
          '/gone',
          (_) => ResponseContext.file('${dir.path}/nope'),
        );
        await client.server.get(
          '/past',
          (_) => ResponseContext.file(file.path, offset: 99),
        );
        expect((await client.get('/f')).text(), '0123456789');
        expect((await client.get('/f')).headers['content-type'], 'text/plain');
        expect((await client.get('/part')).text(), '234');
        expect((await client.get('/gone')).status, 404);
        expect((await client.get('/past')).status, 404);
        expect(ResponseContext.file(file.path).isFile, isTrue);
        expect(const ResponseContext().isFile, isFalse);
      });
    });
  });
}
