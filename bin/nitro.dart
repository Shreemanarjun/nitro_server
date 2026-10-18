/// `nitro` — the dev CLI for a nitro_server app.
///
/// ```sh
/// dart run nitro_server:nitro serve            # run bin/server.dart, JIT + hot reload
/// dart run nitro_server:nitro serve --aot       # AOT-compile then run (prod-like, no reload)
/// dart run nitro_server:nitro build             # AOT: dart compile exe → build/<name>
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
  nitro build [entry] [--jit] [-o out]   compile a server (default: AOT exe)

  entry   defaults to bin/server.dart
  --aot   serve: compile then run the native exe (no hot reload)
  --jit   build: emit a JIT snapshot instead of a native exe
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
  final out = await _compileExe(entry, output: output);
  return out == null ? 1 : 0;
}

/// AOT-compiles [entry] to a native executable, returning its path or null.
/// Copies the native engine library next to the exe so the result is a
/// self-contained bundle the loader finds regardless of working directory.
Future<String?> _compileExe(String entry, {String? output}) async {
  final out = output ?? 'build/${_base(entry)}';
  _ensureDir(out);
  stdout.writeln('→ compiling (aot exe) — $out');
  final code = await _run('dart', ['compile', 'exe', '-o', out, entry]);
  if (code != 0) return null;
  _bundleDylib(out);
  return out;
}

/// Copies the cmake-built native library next to [exePath] so the compiled
/// server runs standalone (the loader searches the executable's directory).
void _bundleDylib(String exePath) {
  final name = nitroServerLibraryName();
  File? src;
  for (final candidate in ['build/lib/$name', 'build/$name']) {
    if (File(candidate).existsSync()) {
      src = File(candidate);
      break;
    }
  }
  if (src == null) {
    stdout.writeln(
      '  note: $name not found under build/ — build the engine with '
      '`cmake -S src -B build/lib -DCMAKE_BUILD_TYPE=Release && '
      'cmake --build build/lib`, or set NITRO_SERVER_DYLIB at run time',
    );
    return;
  }
  final dest = '${File(exePath).parent.path}/$name';
  if (File(dest).absolute.path != src.absolute.path) {
    src.copySync(dest);
    stdout.writeln('  bundled $name next to the executable');
  }
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
