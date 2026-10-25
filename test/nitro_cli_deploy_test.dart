/// `nitro deploy` through the real CLI: files land where asked, existing files
/// are kept, and bad input is refused with exit code 2.
library;

import 'dart:io';

import 'package:test/test.dart';

Future<ProcessResult> nitro(List<String> args) => Process.run(
  'dart',
  ['run', 'bin/nitro.dart', ...args],
  environment: {'NITRO_SERVER_NO_DOWNLOAD': '1'},
);

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('nitro_deploy_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('writes a target, keeps existing files, refuses bad input', () async {
    final out = tmp.path;
    var r = await nitro([
      'deploy',
      'netlify',
      '--out',
      out,
      '--backend',
      'https://api.example.com',
      '--publish',
      'dist',
    ]);
    expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
    final toml = File('$out/netlify.toml');
    expect(toml.existsSync(), isTrue);
    expect(
      toml.readAsStringSync(),
      contains('https://api.example.com/api/:splat'),
    );
    expect(r.stdout, contains('npx netlify deploy --prod --dir dist'));

    toml.writeAsStringSync('# mine');
    r = await nitro([
      'deploy',
      'netlify',
      '--out',
      out,
      '--backend',
      'https://x.y',
    ]);
    expect(r.exitCode, 0);
    expect(toml.readAsStringSync(), '# mine'); // kept without --force
    expect(r.stdout, contains('kept'));

    r = await nitro(['deploy', 'vercel', '--out', out]);
    expect(r.exitCode, 2);
    expect(r.stderr, contains('--backend'));

    r = await nitro(['deploy', 'heroku']);
    expect(r.exitCode, 2);
    expect(r.stderr, contains('target must be one of'));

    Directory('$out/public').createSync();

    r = await nitro([
      'deploy',
      'cloudflare',
      '--out',
      out,
      '--name',
      'demo-api',
    ]);
    expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
    for (final f in [
      'Dockerfile',
      'wrangler.jsonc',
      'worker.js',
      'package.json',
    ]) {
      expect(File('$out/$f').existsSync(), isTrue, reason: f);
    }
    // public/ exists next to the pubspec: it is copied into the runtime image.
    expect(
      File('$out/Dockerfile').readAsStringSync(),
      contains('COPY --from=build /app/public/ /app/public/'),
    );
  }, timeout: const Timeout(Duration(minutes: 3)));
}
