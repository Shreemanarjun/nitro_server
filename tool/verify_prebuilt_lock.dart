/// Downloads every asset locked for a version through the build hook's own
/// verification path (`fetchVerifiedPrebuilt`) and reports accept / refuse,
/// so a release can be checked end to end before the package is published:
///
///   dart tool/verify_prebuilt_lock.dart 1.0.0            # digest lock
///   NITRO_SERVER_VERIFY_SIGSTORE=1 dart tool/verify_prebuilt_lock.dart 1.0.0
///
/// (`dart <file>`, not `dart run`: the latter would run the build hook first.)
///
/// Exit 1 when any locked asset is refused or missing.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../hook/prebuilt_lock.dart';

/// `NITRO_SERVER_REPO` / `NITRO_SERVER_PREBUILT_LOCK` point the check at another
/// release and lock (the strict path was proven against GoReleaser's and
/// Syft's GitHub-Actions-signed releases this way).
final _repo =
    Platform.environment['NITRO_SERVER_REPO'] ?? 'Shreemanarjun/nitro_server';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('usage: dart tool/verify_prebuilt_lock.dart <version>');
    exit(2);
  }
  final version = args.single;
  final lockJson = File(
    Platform.environment['NITRO_SERVER_PREBUILT_LOCK'] ??
        'hook/prebuilt_checksums.json',
  ).readAsStringSync();
  final assets = ((jsonDecode(lockJson) as Map)[version] as Map?)?.keys;
  if (assets == null || assets.isEmpty) {
    stderr.writeln('no assets locked for $version');
    exit(1);
  }
  final env = Platform.environment;
  final strict = env['NITRO_SERVER_VERIFY_SIGSTORE'];
  final client = HttpClient();
  final tmp = Directory.systemTemp.createTempSync('nitro_verify_');
  var failed = false;
  try {
    for (final asset in assets.cast<String>()) {
      try {
        final ok = await fetchVerifiedPrebuilt(
          base: prebuiltBaseUrl(_repo, version, env),
          version: version,
          asset: asset,
          lockJson: lockJson,
          repo: _repo,
          dest: File('${tmp.path}/$asset'),
          fetch: (url) async {
            final res = await (await client.getUrl(url)).close();
            if (res.statusCode != 200) {
              await res.drain<void>();
              return null;
            }
            return (await res.fold(
              BytesBuilder(),
              (b, d) => b..add(d),
            )).toBytes();
          },
          runCosign: (a) async => (await Process.run('cosign', a)).exitCode,
          sha256Hex: (b) => sha256.convert(b).toString(),
          strictSigstore: strict == '1' || strict == 'true',
        );
        stdout.writeln('${ok ? 'accepted' : 'MISSING '} $asset');
        failed |= !ok;
      } on StateError catch (e) {
        stdout.writeln('REFUSED  $asset: ${e.message}');
        failed = true;
      }
    }
  } finally {
    client.close(force: true);
    tmp.deleteSync(recursive: true);
  }
  exit(failed ? 1 : 0);
}
