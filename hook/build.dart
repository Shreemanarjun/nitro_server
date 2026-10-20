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
import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';

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
  final downloaded = await _download(input, os, arch, dest);
  if (downloaded != null) return downloaded;
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
  final base = 'https://github.com/$_repo/releases/download/v$version/$asset';
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final expected = (await _fetch(
      client,
      Uri.parse('$base.sha256'),
    ))?.let((b) => utf8.decode(b).trim().split(RegExp(r'\s+')).first);
    if (expected == null) return null; // no prebuilt published for this target
    final bytes = await _fetch(client, Uri.parse(base));
    if (bytes == null) return null;
    final actual = sha256.convert(bytes).toString();
    if (actual != expected) {
      throw StateError('checksum mismatch for $asset: $actual != $expected');
    }
    await dest.create(recursive: true);
    await dest.writeAsBytes(bytes, flush: true);
    return dest;
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
  final out = <int>[];
  await for (final chunk in res) {
    out.addAll(chunk);
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

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
