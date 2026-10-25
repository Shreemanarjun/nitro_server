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
// Android and iOS (Flutter apps) have no prebuilts: there the engine and a
// vendored libuv (third_party/libuv) are compiled from source with the
// toolchain the Flutter tool hands the hook (NDK clang / Xcode clang), see
// [_buildMobile]. TLS, brotli and HTTP/2 are not compiled in on mobile.
//
// The hook never throws out of `build`: if it cannot provision a library it
// emits a hint and no asset, and the package's runtime loader
// (`loadNitroServerNative`) still finds a manually-built `build/lib/<lib>`.
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

import 'package:nitro_server/src/internal/prebuilt_lock.dart';

const _repo = 'Shreemanarjun/nitro_server';

void main(List<String> args) async {
  await build(args, (input, output) async {
    // This build wants no code assets.
    if (!input.config.buildCodeAssets) return;
    final os = input.config.code.targetOS;
    final arch = input.config.code.targetArchitecture;
    if (os == OS.android || os == OS.iOS) {
      // Errors propagate: a Flutter mobile build without the engine would
      // only fail later, at run time, with a missing-symbol error.
      await _buildMobile(input, output);
      return;
    }
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
        input.packageRoot.resolve('prebuilt_checksums.json'),
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
  // A library the package itself built at `build/lib` wins over any
  // download: that is the repo's own dev/CI flow, and its tests must run
  // against the engine in the tree, never against a released one. A
  // pub-cache consumer has no build/lib and goes straight to the prebuilt.
  final existing = File.fromUri(
    input.packageRoot.resolve('build/lib/${_libFileName(os)}'),
  );
  if (await existing.exists()) {
    await dest.create(recursive: true);
    await existing.copy(dest.path);
    return dest;
  }
  // NITRO_SERVER_NO_DOWNLOAD=1 skips the prebuilt lookup (an offline or
  // air-gapped build, a container that already built the engine).
  final noDownload = Platform.environment['NITRO_SERVER_NO_DOWNLOAD'];
  if (noDownload != '1' && noDownload != 'true') {
    final downloaded = await _download(input, os, arch, dest);
    if (downloaded != null) return downloaded;
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
    input.packageRoot.resolve('prebuilt_checksums.json'),
  );
  if (!await lockFile.exists()) return null;
  final lockJson = await lockFile.readAsString();
  if (expectedDigest(lockJson, version, asset) == null) {
    // Expected for a version whose release has not been cut (the lock is
    // filled from the release's assets) and for an unsupported target.
    stderr.writeln(
      'nitro_server: no verified prebuilt locked for $version/$asset in '
      'prebuilt_checksums.json — building the engine from source',
    );
    return null;
  }
  // A Linux host older than the prebuilt's glibc floor cannot load it: say
  // so and build from source rather than bundle something that fails at
  // startup. Best effort — no getconf, no opinion.
  if (os == OS.linux && await _exists('getconf')) {
    final r = await Process.run('getconf', ['GNU_LIBC_VERSION']);
    final out = '${r.stdout}'.trim();
    if (r.exitCode == 0 && !glibcAtLeast(out, linuxPrebuiltMinGlibc)) {
      stderr.writeln(
        'nitro_server: this host has $out; the prebuilt engine needs glibc '
        '${linuxPrebuiltMinGlibc.$1}.${linuxPrebuiltMinGlibc.$2}+ — building '
        'from source',
      );
      return null;
    }
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
  Future<ProcessResult> configureWith({required bool http2}) =>
      Process.run('cmake', [
        '-S',
        src,
        '-B',
        buildDir,
        '-DCMAKE_BUILD_TYPE=Release',
        '-DNITRO_SERVER_HTTP2=${http2 ? 'ON' : 'OFF'}',
      ]);
  // Ship every protocol when the host has nghttp2; without it HTTP/2 is
  // simply not compiled in (like TLS and brotli, which are auto-detected)
  // instead of failing the whole engine build.
  var configure = await configureWith(http2: true);
  if (configure.exitCode != 0) {
    stderr.writeln(
      'nitro_server: building without HTTP/2 (nghttp2 not found); '
      'install libnghttp2 for h2.',
    );
    configure = await configureWith(http2: false);
  }
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

/// libuv sources (third_party/libuv, from its CMakeLists.txt) for [os].
List<String> _libuvSources(OS os) => [
  for (final f in const [
    'fs-poll',
    'idna',
    'inet',
    'random',
    'strscpy',
    'strtok',
    'thread-common',
    'threadpool',
    'timer',
    'uv-common',
    'uv-data-getter-setters',
    'version',
  ])
    'third_party/libuv/src/$f.c',
  for (final f in [
    'async',
    'core',
    'dl',
    'fs',
    'getaddrinfo',
    'getnameinfo',
    'loop-watcher',
    'loop',
    'pipe',
    'poll',
    'process',
    'random-devurandom',
    'signal',
    'stream',
    'tcp',
    'thread',
    'tty',
    'udp',
    'proctitle',
    if (os == OS.android) ...[
      'linux',
      'procfs-exepath',
      'random-getentropy',
      'random-getrandom',
      'random-sysctl-linux',
    ] else ...[
      'bsd-ifaddrs',
      'kqueue',
      'random-getentropy',
      'darwin-proctitle',
      'darwin',
      'fsevents',
    ],
  ])
    'third_party/libuv/src/unix/$f.c',
];

/// Android / iOS: compiles libuv + the Dart DL shim (C) into a private
/// static archive, then the engine (C++17) into the shared library declared
/// as `package:nitro_server/nitro_server`, the asset id the generated
/// `@Native` bindings resolve. The C step runs into a throwaway output so the
/// archive is linked, never shipped.
Future<void> _buildMobile(BuildInput input, BuildOutputBuilder output) async {
  final os = input.config.code.targetOS;
  final cLib = CBuilder.library(
    name: 'nitro_server_c',
    assetName: 'nitro_server_c',
    sources: [..._libuvSources(os), 'src/dart_api_dl.c'],
    includes: [
      'third_party/libuv/include',
      'third_party/libuv/src',
      'src/native',
    ],
    defines: {
      '_FILE_OFFSET_BITS': '64',
      '_LARGEFILE_SOURCE': null,
      if (os == OS.android) '_GNU_SOURCE': null,
      if (os == OS.iOS) ...{
        '_DARWIN_UNLIMITED_SELECT': '1',
        '_DARWIN_USE_64_BIT_INODE': '1',
      },
    },
    flags: const ['-w'], // third-party C: its warnings are not ours to fix
    linkModePreference: LinkModePreference.static,
    optimizationLevel: OptimizationLevel.o2,
  );
  await cLib.run(input: input, output: BuildOutputBuilder());
  final engine = CBuilder.library(
    name: 'nitro_server',
    assetName: 'nitro_server',
    language: Language.cpp,
    std: 'c++17',
    cppLinkStdLib: os == OS.android ? 'c++_static' : null,
    sources: const [
      'src/nitro_server.cpp',
      'src/HybridNitroServer.cpp',
      'lib/src/generated/cpp/nitro_server.bridge.g.cpp',
    ],
    includes: const [
      'src',
      'src/native',
      'lib/src/generated/cpp',
      'third_party/libuv/include',
    ],
    defines: const {'NITRO_SERVER_LIBUV': '1', 'DART_SHARED_LIB': null},
    libraries: ['nitro_server_c', if (os == OS.android) 'dl'],
    libraryDirectories: [input.outputDirectory.toFilePath()],
    linkModePreference: LinkModePreference.dynamic,
    optimizationLevel: OptimizationLevel.o2,
  );
  await engine.run(input: input, output: output);
  output.dependencies.add(input.packageRoot.resolve('third_party/libuv/'));
}
