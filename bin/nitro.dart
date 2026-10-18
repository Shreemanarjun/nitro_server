/// `nitro` — the dev CLI for a nitro_server app.
///
/// ```sh
/// dart run nitro_server:nitro serve            # run bin/server.dart, JIT + hot reload
/// dart run nitro_server:nitro serve --aot       # AOT-compile then run (prod-like, no reload)
/// dart run nitro_server:nitro build             # AOT: dart build cli → build/<name>/bundle
/// dart run nitro_server:nitro build --jit       # JIT snapshot: dart compile jit-snapshot
/// # once globally activated (`dart pub global activate nitro_server`):
/// nitro serve | nitro build [entry] [--aot|--jit] [-o out]
/// ```
///
/// `serve` defaults to JIT with the VM service on so [enableHotReload] attaches;
/// `build` defaults to a self-contained AOT executable. Both are thin wrappers
/// over `dart run`/`dart compile` with stdio inherited — run those directly if
/// you prefer.
library;

import 'dart:io';

import 'package:nitro_server/nitro_server.dart' show nitroServerLibraryName;

const _usage = '''
nitro — dev CLI for nitro_server

usage:
  nitro serve [entry] [--aot]            run a server (default: JIT + hot reload)
  nitro build [entry] [--jit] [--bundle-deps] [-o out]   compile a server

  entry   defaults to bin/server.dart
  --aot   serve: compile then run the native exe (no hot reload)
  --jit   build: emit a JIT snapshot instead of a native exe
  --bundle-deps  build: copy native deps next to the exe + rewrite install
                 names, for a cross-machine-portable bundle (macOS/Linux)
  -o,--output   build output path (default build/<entry-basename>[.exe])
''';

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.first == '-h' || args.first == '--help') {
    stdout.write(_usage);
    exit(args.isEmpty ? 2 : 0);
  }
  final command = args.first;
  final rest = args.skip(1).toList();
  switch (command) {
    case 'serve':
      exit(await _serve(rest));
    case 'build':
      exit(await _build(rest));
    default:
      stderr.writeln('nitro: unknown command "$command"\n');
      stderr.write(_usage);
      exit(2);
  }
}

/// Positional entry (first non-flag arg) or the default.
String _entry(List<String> args) =>
    args.firstWhere((a) => !a.startsWith('-'), orElse: () => 'bin/server.dart');

bool _hasFlag(List<String> args, String flag) => args.contains(flag);

String? _option(List<String> args, List<String> names) {
  for (var i = 0; i < args.length - 1; i++) {
    if (names.contains(args[i])) return args[i + 1];
  }
  return null;
}

Future<int> _serve(List<String> args) async {
  final entry = _entry(args);
  if (!File(entry).existsSync()) {
    stderr.writeln('nitro serve: entrypoint not found: $entry');
    return 2;
  }
  final forwarded = args
      .where((a) => a != entry && !a.startsWith('--aot'))
      .toList();

  if (_hasFlag(args, '--aot')) {
    // Prod-like: compile then run the native binary (no hot reload).
    final out = await _compileExe(entry);
    if (out == null) return 1;
    stdout.writeln('↻ nitro serve (aot) — $out');
    return _run(out, forwarded);
  }

  stdout.writeln('↻ nitro serve — $entry (JIT, hot reload on)');
  return _run('dart', ['run', '--enable-vm-service', entry, ...forwarded]);
}

Future<int> _build(List<String> args) async {
  final entry = _entry(args);
  if (!File(entry).existsSync()) {
    stderr.writeln('nitro build: entrypoint not found: $entry');
    return 2;
  }
  final output = _option(args, ['-o', '--output']);
  if (_hasFlag(args, '--jit')) {
    final out = output ?? 'build/${_base(entry)}.jit';
    _ensureDir(out);
    stdout.writeln('→ nitro build (jit snapshot) — $out');
    return _run('dart', ['compile', 'jit-snapshot', '-o', out, entry]);
  }
  final exe = await _compileExe(entry, output: output);
  if (exe == null) return 1;
  if (_hasFlag(args, '--bundle-deps')) {
    // The engine lib lives in the bundle's lib/ (sibling of bin/), not next to
    // the exe. bundle/bin/<exe> -> bundle/lib.
    final libDir = '${File(exe).parent.parent.path}/lib';
    await _bundleTransitiveDeps(libDir);
  }
  return 0;
}

/// AOT-builds [entry] into a self-contained CLI bundle, returning the path to
/// the compiled executable (under `<out>/bundle/bin/`) or null on failure.
///
/// Uses `dart build cli`, not `dart compile exe`: once the package graph has
/// native-asset build hooks (nitro_server ships one), `dart compile` refuses
/// and directs you here. `dart build cli` runs the hook — provisioning the
/// engine library — and bundles it into `<out>/bundle/lib/`, which the runtime
/// loader resolves via its `<exe>/../lib` candidate (see native_loader.dart).
Future<String?> _compileExe(String entry, {String? output}) async {
  final base = _base(entry);
  final dir = output ?? 'build/$base';
  // A stale file from an older `dart compile exe -o build/<base>` run would
  // collide with the bundle directory dart build cli creates there.
  final stale = File(dir);
  if (stale.existsSync()) stale.deleteSync();
  stdout.writeln('→ building (aot cli bundle) — $dir/bundle');
  final code = await _run('dart', ['build', 'cli', '-t', entry, '-o', dir]);
  if (code != 0) return null;
  // `dart build cli` writes <dir>/bundle/bin/<exe>; the exe is named for the
  // entry, but fall back to whatever single executable landed in bin/.
  final binDir = Directory('$dir/bundle/bin');
  final named = File('${binDir.path}/$base');
  if (named.existsSync()) return named.path;
  final produced = binDir.existsSync()
      ? binDir.listSync().whereType<File>().toList()
      : <File>[];
  if (produced.isEmpty) {
    stderr.writeln('nitro build: no executable produced under ${binDir.path}');
    return null;
  }
  return produced.first.path;
}

/// Makes the native-library bundle self-contained for cross-machine deploy:
/// copies every non-system dynamic dependency next to [exePath] and rewrites
/// each library's references to `@loader_path/<name>`, so the binary runs
/// without the build machine's Homebrew/apt libraries. macOS
/// (`otool`/`install_name_tool`) and Linux (`patchelf`) only; elsewhere, a
/// note points at Docker.
Future<void> _bundleTransitiveDeps(String exePath) async {
  final dir = File(exePath).parent.path;
  if (Platform.isMacOS) {
    await _bundleMac(dir);
  } else if (Platform.isLinux) {
    await _bundleLinux(dir);
  } else {
    stdout.writeln(
      '  --bundle-deps: unsupported on this OS; use the Docker image for a '
      'self-contained deploy',
    );
  }
}

/// macOS: BFS over `otool -L`, copying non-system deps and rewriting install
/// names to `@loader_path`.
Future<void> _bundleMac(String dir) async {
  if (!await _hasTool('install_name_tool') || !await _hasTool('otool')) {
    stdout.writeln(
      '  --bundle-deps: need Xcode command-line tools (otool, '
      'install_name_tool)',
    );
    return;
  }
  final name = nitroServerLibraryName();
  final root = '$dir/$name';
  if (!File(root).existsSync()) {
    stdout.writeln('  --bundle-deps: $name not bundled; nothing to rewrite');
    return;
  }
  final seen = <String>{};
  final queue = <String>[root];
  var bundled = 0;
  while (queue.isNotEmpty) {
    final lib = queue.removeLast();
    if (!seen.add(lib)) continue;
    final out = await Process.run('otool', ['-L', lib]);
    for (final line in (out.stdout as String).split('\n').skip(1)) {
      final dep = line.trim().split(' (').first.trim();
      if (dep.isEmpty || _isSystemLib(dep)) continue;
      if (!dep.startsWith('/')) continue; // already @rpath/@loader_path
      final depName = dep.split('/').last;
      final dest = '$dir/$depName';
      if (!File(dest).existsSync() && File(dep).existsSync()) {
        File(dep).copySync(dest);
        bundled++;
        queue.add(dest);
      }
      await Process.run('install_name_tool', [
        '-change',
        dep,
        '@loader_path/$depName',
        lib,
      ]);
    }
  }
  // install_name_tool invalidates the ad-hoc code signature; on Apple Silicon
  // dyld then refuses to load the dylib. Re-sign each modified library.
  final signed = await _hasTool('codesign');
  if (signed) {
    for (final lib in seen) {
      await Process.run('codesign', ['--force', '--sign', '-', lib]);
    }
  }
  stdout.writeln(
    '  --bundle-deps: bundled $bundled native dependency(ies) next to the '
    'executable (macOS @loader_path${signed ? ', re-signed' : ''})',
  );
}

/// Linux: copy non-system `.so` deps and set an `$ORIGIN` rpath with patchelf.
Future<void> _bundleLinux(String dir) async {
  if (!await _hasTool('patchelf') || !await _hasTool('ldd')) {
    stdout.writeln('  --bundle-deps: need patchelf and ldd');
    return;
  }
  final name = nitroServerLibraryName();
  final root = '$dir/$name';
  if (!File(root).existsSync()) return;
  final out = await Process.run('ldd', [root]);
  var bundled = 0;
  for (final line in (out.stdout as String).split('\n')) {
    final arrow = line.indexOf('=> ');
    if (arrow == -1) continue;
    final dep = line.substring(arrow + 3).split(' (').first.trim();
    if (dep.isEmpty || _isSystemLib(dep) || !File(dep).existsSync()) continue;
    final dest = '$dir/${dep.split('/').last}';
    if (!File(dest).existsSync()) {
      File(dep).copySync(dest);
      bundled++;
    }
  }
  await Process.run('patchelf', ['--set-rpath', r'$ORIGIN', root]);
  stdout.writeln(
    '  --bundle-deps: bundled $bundled .so dependency(ies) with '
    r'an $ORIGIN rpath',
  );
}

bool _isSystemLib(String path) =>
    path.startsWith('/usr/lib/') ||
    path.startsWith('/System/') ||
    path.startsWith('/lib/') ||
    path.startsWith('/lib64/');

Future<bool> _hasTool(String name) async {
  final r = await Process.run('which', [name]);
  return r.exitCode == 0;
}

String _base(String entry) =>
    entry.split('/').last.replaceAll(RegExp(r'\.dart$'), '');

void _ensureDir(String path) {
  final dir = File(path).parent;
  if (!dir.existsSync()) dir.createSync(recursive: true);
}

/// Runs [exe] with [args], inheriting stdio, forwarding SIGINT. Returns exit code.
Future<int> _run(String exe, List<String> args) async {
  final proc = await Process.start(
    exe,
    args,
    mode: ProcessStartMode.inheritStdio,
  );
  final sigint = ProcessSignal.sigint.watch().listen((_) => proc.kill());
  final code = await proc.exitCode;
  await sigint.cancel();
  return code;
}
