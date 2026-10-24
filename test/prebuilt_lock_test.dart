/// The hook's prebuilt verification, end to end against a local "release":
/// an asset, its `.sha256` sidecar and a Sigstore bundle served by a Dart
/// HttpServer, a `cosign` stand-in on PATH that checks it is asked to verify
/// the release workflow's keyless identity, the lock produced by
/// `tool/update_prebuilt_lock.sh` from that release, and the hook's download
/// path consuming the lock in both modes.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:nitro_server/src/internal/prebuilt_lock.dart';
import 'package:test/test.dart';

const _asset = 'libnitro_server-linux-x64.so';
const _repo = 'Example/nitro_server';

void main() {
  final zeros = '0' * 60;
  final lock =
      '{"_comment": "x", "1.2.3": {'
      '"libnitro_server-linux-x64.so": "AbCd$zeros", "bad": "not-hex"}}';

  test('finds the locked digest, lowercased, only when it is a sha256', () {
    expect(
      expectedDigest(lock, '1.2.3', 'libnitro_server-linux-x64.so'),
      'abcd$zeros',
    );
    expect(expectedDigest(lock, '1.2.3', 'bad'), isNull); // not 64 hex chars
    expect(expectedDigest(lock, '1.2.3', 'missing'), isNull);
    expect(
      expectedDigest(lock, '9.9.9', 'libnitro_server-linux-x64.so'),
      isNull,
    );
    expect(expectedDigest('not json', '1.2.3', 'x'), isNull);
    expect(expectedDigest('[]', '1.2.3', 'x'), isNull);
    expect(expectedDigest('{"1.2.3": []}', '1.2.3', 'x'), isNull);
  });

  test('glibcAtLeast reads getconf output against the prebuilt floor', () {
    expect(glibcAtLeast('glibc 2.35', linuxPrebuiltMinGlibc), isTrue);
    expect(glibcAtLeast('glibc 2.39', linuxPrebuiltMinGlibc), isTrue);
    expect(glibcAtLeast('glibc 3.0', linuxPrebuiltMinGlibc), isTrue);
    expect(glibcAtLeast('glibc 2.34', linuxPrebuiltMinGlibc), isFalse);
    expect(glibcAtLeast('glibc 2.28', linuxPrebuiltMinGlibc), isFalse);
    expect(glibcAtLeast('', linuxPrebuiltMinGlibc), isTrue); // unknown: try
  });

  test('digestMatches compares whole digests, case-insensitively', () {
    expect(digestMatches('ab' * 32, 'AB' * 32), isTrue);
    expect(digestMatches('ab' * 32, '${'ab' * 31}ac'), isFalse);
    expect(digestMatches('ab' * 32, 'ab' * 31), isFalse);
  });

  test('base URL: GitHub Releases by default, a mirror when overridden', () {
    expect(
      prebuiltBaseUrl(_repo, '1.0.0', const {}).toString(),
      'https://github.com/Example/nitro_server/releases/download/v1.0.0/',
    );
    expect(
      prebuiltBaseUrl(_repo, '1.0.0', const {
        'NITRO_SERVER_PREBUILT_BASE_URL': 'http://127.0.0.1:9/r',
      }).toString(),
      'http://127.0.0.1:9/r/',
    );
  });

  group('end to end against a local release', () {
    late HttpServer release;
    late Directory tmp;
    late Uint8List assetBytes;
    late String digest;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('nitro_prebuilt_');
      assetBytes = Uint8List.fromList(
        List.generate(50 * 1024, (i) => (i * 31 + 7) & 0xff),
      );
      digest = sha256.convert(assetBytes).toString();
      // A mock GitHub release: the asset, its sidecar, its Sigstore bundle.
      release = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      release.listen((req) {
        final p = req.uri.path;
        if (p.endsWith('/$_asset')) {
          req.response.add(assetBytes);
        } else if (p.endsWith('/$_asset.sha256')) {
          req.response.write('$digest  $_asset\n');
        } else if (p.endsWith('/$_asset.sigstore.json')) {
          req.response.write(
            '{"mediaType":"application/vnd.dev.sigstore.bundle+json;version=0.3"}',
          );
        } else {
          req.response.statusCode = 404;
        }
        req.response.close();
      });
      // A cosign stand-in: records its arguments, verifies the keyless
      // identity policy is what it is asked for, and succeeds unless the
      // bundle says otherwise.
      final log = File('${tmp.path}/cosign.log');
      final bin = Directory('${tmp.path}/bin')..createSync();
      File('${bin.path}/cosign').writeAsStringSync('''#!/bin/sh
printf '%s\\n' "\$@" >> "${log.path}"
case " \$* " in
  *" --certificate-identity-regexp ^https://github.com/$_repo/ "*) ;;
  *) echo "identity policy missing" >&2; exit 2 ;;
esac
for a in "\$@"; do
  case "\$a" in *.sigstore.json) grep -q tampered "\$a" && { echo "signature mismatch" >&2; exit 1; } ;; esac
done
exit 0
''');
      Process.runSync('chmod', ['+x', '${bin.path}/cosign']);
      expect(log.existsSync(), isFalse);
    });

    tearDown(() async {
      await release.close(force: true);
      tmp.deleteSync(recursive: true);
    });

    Uri base() => Uri.parse('http://127.0.0.1:${release.port}/rel/');
    Map<String, String> env() => {
      'PATH': '${tmp.path}/bin:${Platform.environment['PATH']}',
      'NITRO_SERVER_PREBUILT_BASE_URL': base().toString(),
      'NITRO_SERVER_REPO': _repo,
    };
    Future<List<int>?> fetch(Uri url) async {
      final c = HttpClient();
      try {
        final res = await (await c.getUrl(url)).close();
        if (res.statusCode != 200) {
          await res.drain<void>();
          return null;
        }
        return (await res.fold<BytesBuilder>(
          BytesBuilder(),
          (b, d) => b..add(d),
        )).toBytes();
      } finally {
        c.close(force: true);
      }
    }

    // The hook runs `cosign` from PATH; here the stand-in is addressed by
    // path so the test cannot pick up a real cosign.
    Future<int> cosign(List<String> args) async =>
        (await Process.run('${tmp.path}/bin/cosign', args)).exitCode;
    String hex(List<int> b) => sha256.convert(b).toString();

    test(
      'the lock script locks the release; the hook accepts and refuses correctly',
      () async {
        // 1. tool/update_prebuilt_lock.sh against the mock release, with the
        //    cosign stand-in on PATH: produces the lock for 1.2.3.
        final lockFile = File('${tmp.path}/prebuilt_checksums.json')
          ..createSync(recursive: true)
          ..writeAsStringSync('{"_comment": "test", "0.0.1": {}}');
        final repoRoot = Directory.current.path;
        final script = File('${tmp.path}/tool/update_prebuilt_lock.sh')
          ..createSync(recursive: true)
          ..writeAsStringSync(
            File('$repoRoot/tool/update_prebuilt_lock.sh').readAsStringSync(),
          );
        Process.runSync('chmod', ['+x', script.path]);
        final run = await Process.run(
          'bash',
          [script.path, '1.2.3'],
          environment: env(),
          workingDirectory: tmp.path,
        );
        expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
        expect(run.stdout, contains('verified $_asset (sigstore)'));
        final lockJson = lockFile.readAsStringSync();
        expect(expectedDigest(lockJson, '1.2.3', _asset), digest);
        expect(
          File('${tmp.path}/cosign.log').readAsStringSync(),
          contains('verify-blob'),
        );

        // 2. The hook's path, plain mode: digest from the lock, asset accepted.
        final dest = File('${tmp.path}/out/$_asset');
        expect(
          await fetchVerifiedPrebuilt(
            base: base(),
            version: '1.2.3',
            asset: _asset,
            lockJson: lockJson,
            repo: _repo,
            dest: dest,
            fetch: fetch,
            runCosign: cosign,
            sha256Hex: hex,
          ),
          isTrue,
        );
        expect(dest.readAsBytesSync(), assetBytes);

        // 3. Strict mode: the bundle is fetched and cosign is asked to verify
        //    the release workflow's identity; the asset is kept.
        expect(
          await fetchVerifiedPrebuilt(
            base: base(),
            version: '1.2.3',
            asset: _asset,
            lockJson: lockJson,
            repo: _repo,
            dest: dest,
            fetch: fetch,
            runCosign: cosign,
            sha256Hex: hex,
            strictSigstore: true,
          ),
          isTrue,
        );
        expect(File('${dest.path}.sigstore.json').existsSync(), isTrue);
        final log = File('${tmp.path}/cosign.log').readAsStringSync();
        expect(log, contains('verify-blob'));
        expect(log, contains('--certificate-identity-regexp'));
        expect(log, contains('^https://github.com/$_repo/'));
        expect(log, contains('https://token.actions.githubusercontent.com'));

        // 4. A version the lock does not know: no download, source build.
        expect(
          await fetchVerifiedPrebuilt(
            base: base(),
            version: '9.9.9',
            asset: _asset,
            lockJson: lockJson,
            repo: _repo,
            dest: dest,
            fetch: fetch,
            runCosign: cosign,
            sha256Hex: hex,
          ),
          isFalse,
        );

        // 5. A tampered release (asset swapped together with its sidecar):
        //    the in-package lock still says no.
        final tamperedLock = lockJson.replaceFirst(digest, 'f' * 64);
        await expectLater(
          fetchVerifiedPrebuilt(
            base: base(),
            version: '1.2.3',
            asset: _asset,
            lockJson: tamperedLock,
            repo: _repo,
            dest: dest,
            fetch: fetch,
            runCosign: cosign,
            sha256Hex: hex,
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'm',
              contains('refusing'),
            ),
          ),
        );

        // 6. Strict mode with a bundle cosign rejects: refused, file removed.
        await expectLater(
          fetchVerifiedPrebuilt(
            base: base(),
            version: '1.2.3',
            asset: _asset,
            lockJson: lockJson,
            repo: _repo,
            dest: dest,
            fetch: (url) async {
              final b = await fetch(url);
              return url.path.endsWith('.sigstore.json')
                  ? utf8.encode('{"tampered": true}')
                  : b;
            },
            runCosign: cosign,
            sha256Hex: hex,
            strictSigstore: true,
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'm',
              contains('cosign rejected'),
            ),
          ),
        );
        expect(dest.existsSync(), isFalse);

        // 7. Strict mode with no bundle published: refused.
        await expectLater(
          fetchVerifiedPrebuilt(
            base: base(),
            version: '1.2.3',
            asset: _asset,
            lockJson: lockJson,
            repo: _repo,
            dest: dest,
            fetch: (url) async =>
                url.path.endsWith('.sigstore.json') ? null : fetch(url),
            runCosign: cosign,
            sha256Hex: hex,
            strictSigstore: true,
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'm',
              contains('no Sigstore bundle'),
            ),
          ),
        );
      },
    );
  });
}
