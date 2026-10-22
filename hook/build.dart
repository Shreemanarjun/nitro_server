// Native-assets build hook: provisions the nitro_server engine library so
// `dart pub add nitro_server` needs no manual cmake step. At build time
// (`dart build`/`run`/`test`/`compile`) it, for the target OS+arch:
//
//   1. downloads the matching prebuilt from the GitHub release for this package
//      version, verifying its SHA-256 (cached under the hook output dir), then
//   2. declares it a `CodeAsset` so Dart bundles it on `dart compile exe` and
//      resolves it at run time.
//
// Falls back to a source build via `src/engine.cmake` when there is no matching
// prebuilt (an unreleased version, an exotic OS/arch) or when
// `NITRO_SERVER_BUILD_FROM_SOURCE=1` is set. The prebuilts are self-contained
// (libuv/OpenSSL/brotli/nghttp2 statically linked, all protocols compiled in),
// so a consumer needs no toolchain and no system libraries.
//
// The hook never throws out of `build`: if it cannot provision a library it
// emits a hint and no asset, and the package's runtime loader
// (`loadNitroServerNative`) still finds a manually-built `build/lib/<lib>`.
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';

import 'prebuilt_lock.dart';

const _repo = 'Shreemanarjun/nitro_server';

void main(List<String> args) async {
  await build(args, (input, output) async {
    // This build wants no code assets.
    if (!input.config.buildCodeAssets) return;
    final os = input.config.code.targetOS;
    final arch = input.config.code.targetArchitecture;
    try {
      final lib = await _provision(input, os, arch);
      // Couldn't provision; the package's manual loader still applies.
      if (lib == null) return;
      output.assets.code.add(
        CodeAsset(
          package: 'nitro_server',
          name: 'nitro_server',
          linkMode: DynamicLoadingBundled(),
          file: lib.uri,
        ),
      );
      output.dependencies.add(input.packageRoot.resolve('pubspec.yaml'));
      output.dependencies.add(
        input.packageRoot.resolve('hook/prebuilt_checksums.json'),
      );
      // Re-run when what the library was made from changes; without these the
      // hooks runner serves its cached output and a rebuilt `build/lib` (or an
      // edited engine source) never reaches `dart test` / `dart run`.
      final reused = File.fromUri(
        input.packageRoot.resolve('build/lib/${_libFileName(os)}'),
      );
      if (await reused.exists()) output.dependencies.add(reused.uri);
      output.dependencies.add(input.packageRoot.resolve('CMakeLists.txt'));
      final src = Directory.fromUri(input.packageRoot.resolve('src/'));
      if (await src.exists()) {
        await for (final f in src.list(recursive: true)) {
          if (f is File) output.dependencies.add(f.uri);
        }
      }
    } catch (e) {
      stderr.writeln(
        'nitro_server build hook: could not provision the native library ($e).\n'
        'Falling back to a manually-built library — see the README '
        '"Prerequisites" section. Set NITRO_SERVER_BUILD_FROM_SOURCE=1 to build '
        'it from source in this hook instead.',
      );
    }
  });
}

/// Returns the engine library for [os]/[arch] in the hook output directory,
/// or null if it could not be provisioned.
Future<File?> _provision(BuildInput input, OS os, Architecture arch) async {
  final dest = File.fromUri(input.outputDirectory.resolve(_libFileName(os)));
  final fromSource = Platform.environment['NITRO_SERVER_BUILD_FROM_SOURCE'];
  if (fromSource == '1' || fromSource == 'true') {
    return _buildFromSource(input, os, dest);
  }
  // NITRO_SERVER_NO_DOWNLOAD=1 skips the prebuilt lookup (an offline or
  // air-gapped build, a container that already built the engine).
  final noDownload = Platform.environment['NITRO_SERVER_NO_DOWNLOAD'];
  if (noDownload != '1' && noDownload != 'true') {
    final downloaded = await _download(input, os, arch, dest);
    if (downloaded != null) return downloaded;
  }
  // Reuse a library the package already built at `build/lib` (the repo's own
  // dev/CI flow) so the hook adds no rebuild there. Absent for a pub-cache
  // consumer (read-only package root, no build/lib).
  final existing = File.fromUri(
    input.packageRoot.resolve('build/lib/${_libFileName(os)}'),
  );
  if (await existing.exists()) {
    await dest.create(recursive: true);
    await existing.copy(dest.path);
    return dest;
  }
  // No matching prebuilt (unreleased version / exotic target): build from src.
  return _buildFromSource(input, os, dest);
}

/// Downloads the release prebuilt + its `.sha256`, verifies, and writes [dest].
/// Returns null on any miss (404, checksum mismatch, offline) so the caller can
/// fall back to a source build.
Future<File?> _download(
  BuildInput input,
  OS os,
  Architecture arch,
  File dest,
) async {
  final version = _packageVersion(input);
  if (version == null) return null;
  final asset = 'libnitro_server-${_osTag(os)}-${arch.name}.${_ext(os)}';
  // The digest comes from the lock shipped INSIDE this package, never from
  // the release page: a replaced asset + sidecar cannot pass. No entry means
  // this target has no verified prebuilt — fall back to a source build.
  final lockFile = File.fromUri(
    input.packageRoot.resolve('hook/prebuilt_checksums.json'),
  );
  if (!await lockFile.exists()) return null;
  final lockJson = await lockFile.readAsString();
  if (expectedDigest(lockJson, version, asset) == null) {
    // Expected for a version whose release has not been cut (the lock is
    // filled from the release's assets) and for an unsupported target.
    stderr.writeln(
      'nitro_server: no verified prebuilt locked for $version/$asset in '
      'hook/prebuilt_checksums.json — building the engine from source',
    );
    return null;
  }
  final env = Platform.environment;
  final strict = env['NITRO_SERVER_VERIFY_SIGSTORE'];
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final ok = await fetchVerifiedPrebuilt(
      base: prebuiltBaseUrl(_repo, version, env),
      version: version,
      asset: asset,
      lockJson: lockJson,
      repo: _repo,
      dest: dest,
      fetch: (url) => _fetch(client, url),
      runCosign: (args) async => (await Process.run('cosign', args)).exitCode,
      sha256Hex: (bytes) => sha256.convert(bytes).toString(),
      // Strict mode: additionally verify the release's Sigstore bundle with
      // cosign (keyless identity of the release workflow). Opt-in because it
      // needs cosign on PATH; when asked for and not satisfiable, the
      // prebuilt is refused rather than silently trusted.
      strictSigstore: strict == '1' || strict == 'true',
    );
    return ok ? dest : null;
  } finally {
    client.close(force: true);
  }
}

/// GETs [url] (following redirects), returning the body or null on non-200.
Future<List<int>?> _fetch(HttpClient client, Uri url) async {
  final req = await client.getUrl(url);
  final res = await req.close().timeout(const Duration(seconds: 60));
  if (res.statusCode != 200) {
    await res.drain<void>();
    return null;
  }
  // Bounded: a stalled or endless body cannot hang or balloon the build.
  const maxBytes = 64 * 1024 * 1024;
  final out = <int>[];
  await for (final chunk in res.timeout(const Duration(seconds: 60))) {
    out.addAll(chunk);
    if (out.length > maxBytes) {
      throw StateError('prebuilt download exceeds $maxBytes bytes');
    }
  }
  return out;
}

/// Builds the engine from `src/` via cmake into the hook output directory.
/// Returns null (with a hint) when cmake or a required library is missing.
Future<File?> _buildFromSource(BuildInput input, OS os, File dest) async {
  final src = input.packageRoot.resolve('src').toFilePath();
  final buildDir = input.outputDirectory.resolve('cmake').toFilePath();
  if (!await _exists('cmake')) {
    stderr.writeln(
      'nitro_server: no prebuilt for this target and cmake is not installed; '
      'cannot build the engine from source.',
    );
    return null;
  }
  final configure = await Process.run('cmake', [
    '-S', src,
    '-B', buildDir,
    '-DCMAKE_BUILD_TYPE=Release',
    '-DNITRO_SERVER_HTTP2=ON', // ship all protocols; disable per-server at runtime
  ]);
  if (configure.exitCode != 0) {
    stderr.writeln(
      'nitro_server: cmake configure failed:\n${configure.stderr}',
    );
    return null;
  }
  final make = await Process.run('cmake', ['--build', buildDir, '--parallel']);
  if (make.exitCode != 0) {
    stderr.writeln('nitro_server: cmake build failed:\n${make.stderr}');
    return null;
  }
  // Find the produced library (location varies by generator) and copy it out.
  final name = _libFileName(os);
  final built = await Directory(buildDir)
      .list(recursive: true)
      .where((e) => e is File && e.uri.pathSegments.last == name)
      .cast<File>()
      .firstWhere((_) => true, orElse: () => File(''));
  if (built.path.isEmpty || !await built.exists()) {
    stderr.writeln('nitro_server: build succeeded but $name was not found.');
    return null;
  }
  await dest.create(recursive: true);
  await built.copy(dest.path);
  return dest;
}

Future<bool> _exists(String exe) async {
  try {
    final which = Platform.isWindows ? 'where' : 'which';
    return (await Process.run(which, [exe])).exitCode == 0;
  } catch (_) {
    return false;
  }
}

String? _packageVersion(BuildInput input) {
  final f = File.fromUri(input.packageRoot.resolve('pubspec.yaml'));
  if (!f.existsSync()) return null;
  for (final line in f.readAsLinesSync()) {
    final m = RegExp(r'^version:\s*(\S+)').firstMatch(line);
    if (m != null) return m.group(1);
  }
  return null;
}

String _libFileName(OS os) => switch (os) {
  OS.windows => 'nitro_server.dll',
  OS.macOS => 'libnitro_server.dylib',
  _ => 'libnitro_server.so',
};
String _osTag(OS os) => switch (os) {
  OS.macOS => 'macos',
  OS.windows => 'windows',
  _ => 'linux',
};
String _ext(OS os) => switch (os) {
  OS.windows => 'dll',
  OS.macOS => 'dylib',
  _ => 'so',
};
