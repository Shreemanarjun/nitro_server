/// `nitro` — the dev CLI for a nitro_server app.
///
/// ```sh
/// dart run nitro_server:nitro serve            # run bin/server.dart, JIT + hot reload
/// dart run nitro_server:nitro serve --aot       # AOT-compile then run (prod-like, no reload)
/// dart run nitro_server:nitro build             # AOT: dart build cli → build/<name>/bundle
/// dart run nitro_server:nitro build --jit       # kernel snapshot → run with: dart build/<name>.dill
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
import 'package:nitro_server/src/deploy/targets.dart';

const _usage = '''
nitro — dev CLI for nitro_server

usage:
  nitro serve [entry] [--aot]            run a server (default: JIT + hot reload)
  nitro build [entry] [--jit] [--bundle-deps] [-o out]   compile a server
  nitro deploy <docker|cloudflare|netlify|vercel> [options]
          write what the target needs (Dockerfile, wrangler.jsonc + worker.js,
          netlify.toml, vercel.json); --run also runs the deploy commands

  entry   defaults to bin/server.dart
  --aot   serve: compile then run the native exe (no hot reload)
  --jit   build: emit a kernel snapshot (run: dart <out>.dill) not a native exe
  --bundle-deps  build: copy native deps next to the exe + rewrite install
                 names, for a cross-machine-portable bundle (macOS/Linux)
  -o,--output   build output path (default build/<entry-basename>[.exe])

deploy options:
  --name <n>            image / Worker name (default nitro-app)
  --entry <file>        Dart entrypoint (default bin/server.dart)
  --port <p>            container port (default 8080)
  --health <path>       HEALTHCHECK path (default /readyz)
  --instance-type <t>   cloudflare: lite|basic|standard-1.. (default basic)
  --instances <n>       cloudflare: instances the Worker spreads over (default 3)
  --sleep-after <d>     cloudflare: idle time before sleep (default 15m)
  --backend <url>       netlify|vercel: the running nitro_server to proxy to
  --api-prefix <path>   netlify|vercel: proxied prefix (default /api)
  --publish <dir>       netlify: static dir to publish (default public)
  --platform <p>        docker: image platform (default linux/amd64; host = this machine)
  --assets <dirs>       docker: comma-separated dirs copied into the image
                        (default: whichever of public, assets, web exist)
  --out <dir>           where to write (default .)
  --force               overwrite files that already exist
  --run                 run the deploy commands after writing the files
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
    case 'deploy':
      exit(await _deploy(rest));
    default:
      stderr.writeln('nitro: unknown command "$command"\n');
      stderr.write(_usage);
      exit(2);
  }
}

/// Positional entry (first non-flag arg) or the default. Skips the value of
/// `-o`/`--output` so `nitro build -o out/app` isn't read as entry `out/app`.
String _entry(List<String> args) {
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '-o' || a == '--output') {
      i++; // step over the option's value
      continue;
    }
    if (!a.startsWith('-')) return a;
  }
  return 'bin/server.dart';
}

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
    // A kernel snapshot, not `dart compile jit-snapshot`: jit-snapshot trains
    // by RUNNING the entry, which never returns for a server (it hangs). Kernel
    // compiles without executing and runs under the JIT via `dart <out>`,
    // starting faster than source.
    final out = output ?? 'build/${_base(entry)}.dill';
    _ensureDir(out);
    stdout.writeln('→ nitro build (kernel snapshot) — $out   (run: dart $out)');
    return _run('dart', ['compile', 'kernel', '-o', out, entry]);
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
/// copies every non-system dynamic dependency into [libDir] (the bundle's
/// `lib/`, where the engine library lives) and rewrites each library's
/// references to `@loader_path/<name>`, so the binary runs without the build
/// machine's Homebrew/apt libraries. macOS (`otool`/`install_name_tool`) and
/// Linux (`patchelf`) only; elsewhere, a note points at Docker.
Future<void> _bundleTransitiveDeps(String libDir) async {
  if (Platform.isMacOS) {
    await _bundleMac(libDir);
  } else if (Platform.isLinux) {
    await _bundleLinux(libDir);
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

/// `nitro deploy <target>`: render the target's files, then (with --run) the
/// commands that finish the deployment. Existing files are kept unless
/// --force, so a hand-edited config survives a re-run.
Future<int> _deploy(List<String> args) async {
  final targetName = args.where((a) => !a.startsWith('-')).firstOrNull;
  final target = targetName == null ? null : DeployTarget.parse(targetName);
  if (target == null) {
    stderr.writeln(
      'nitro deploy: target must be one of '
      '${DeployTarget.values.map((t) => t.name).join(', ')}\n',
    );
    stderr.write(_usage);
    return 2;
  }
  int intOpt(String name, int fallback) {
    final v = _option(args, [name]);
    return v == null ? fallback : (int.tryParse(v) ?? -1);
  }

  final out = _option(args, ['--out']) ?? '.';
  final assetsArg = _option(args, ['--assets']);
  final assets = assetsArg != null
      ? assetsArg
            .split(',')
            .map((a) => a.trim())
            .where((a) => a.isNotEmpty)
            .toList()
      : [
          for (final d in const ['public', 'assets', 'web'])
            if (Directory('$out/$d').existsSync()) d,
        ];
  final options = DeployOptions(
    name: _option(args, ['--name']) ?? 'nitro-app',
    entry: _option(args, ['--entry']) ?? 'bin/server.dart',
    port: intOpt('--port', 8080),
    healthPath: _option(args, ['--health']) ?? '/readyz',
    instanceType: _option(args, ['--instance-type']) ?? 'basic',
    instances: intOpt('--instances', 3),
    sleepAfter: _option(args, ['--sleep-after']) ?? '15m',
    backend: _option(args, ['--backend']),
    apiPrefix: _option(args, ['--api-prefix']) ?? '/api',
    publishDir: _option(args, ['--publish']) ?? 'public',
    platform: _option(args, ['--platform']) ?? 'linux/amd64',
    assets: assets,
  );
  final problem = validateDeploy(target, options);
  if (problem != null) {
    stderr.writeln('nitro deploy ${target.name}: $problem');
    return 2;
  }
  final force = _hasFlag(args, '--force');
  for (final entry in renderDeploy(target, options).entries) {
    final file = File('$out/${entry.key}');
    if (file.existsSync() && !force) {
      stdout.writeln('  kept     ${file.path} (exists; --force to overwrite)');
      continue;
    }
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(entry.value);
    stdout.writeln('  wrote    ${file.path}');
  }
  final commands = deployCommands(target, options);
  if (needsBackend(target)) {
    stdout.writeln(
      '  note     ${target.name} hosts the static site only; '
      '${options.apiPrefix}/* is proxied to ${options.backend}',
    );
  }
  if (!_hasFlag(args, '--run')) {
    stdout.writeln(
      '  next     (cd $out && ${commands.map((c) => c.join(' ')).join(' && ')})',
    );
    return 0;
  }
  for (final c in commands) {
    stdout.writeln('  run      ${c.join(' ')}');
    final code = await _runIn(out, c.first, c.sublist(1));
    if (code != 0) return code;
  }
  return 0;
}

Future<int> _runIn(String dir, String exe, List<String> args) async {
  final p = await Process.start(
    exe,
    args,
    workingDirectory: dir,
    mode: ProcessStartMode.inheritStdio,
  );
  return p.exitCode;
}
