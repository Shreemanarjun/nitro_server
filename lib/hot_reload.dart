/// Opt-in hot reload for a Dart CLI `nitro_server`. Separate from the core
/// library so `nitro_server` itself stays dependency-free: this file imports
/// `package:hotreloader`, which you add to your own `dev_dependencies`.
///
/// ```dart
/// import 'package:nitro_server/nitro_server.dart';
/// import 'package:nitro_server/hot_reload.dart';
///
/// Future<void> setup(NitroServer server) async {
///   await server.get('/hello', (_) => ResponseContext.text('hi'));
/// }
///
/// void main() async {
///   final server = await NitroServer.bind(const ServerConfig(port: 8080), setup);
///   await enableHotReload(server); // re-runs `setup` after every hot reload
///   print('listening on ${server.uri}');
/// }
/// ```
///
/// Run with the VM service on so hot reload can attach, then edit a handler
/// and save:
///
/// ```sh
/// dart run --enable-vm-service bin/server.dart
/// ```
///
/// Every reload re-runs `setup` on the live socket via [NitroServer.reload]:
/// added, removed and changed routes all take effect without dropping the port
/// or open connections. Works across isolates.
///
/// `setup` must be a **top-level or static function** (as above), not an inline
/// closure passed to [NitroServer.bind] — Dart hot reload does not re-patch a
/// stored anonymous closure, so a `bind(config, (s) async { ... })` would keep
/// serving the old routes. (A top-level `setup` is already required for
/// `isolates > 1`.) Handlers written inline inside that top-level `setup` are
/// fine.
// coverage:ignore-file
library;

import 'dart:async';
import 'dart:io';

// hotreloader is deliberately a dev_dependency: consumers of this opt-in file
// add it themselves, so the core package ships no runtime dependency.
// ignore: depend_on_referenced_packages
import 'package:hotreloader/hotreloader.dart';

import 'nitro_server.dart';

/// Wires [server]'s route [NitroServer.reload] to every VM hot reload. Returns
/// the [HotReloader]; call `.stop()` to detach. A failing `setup` is printed
/// to stderr rather than killing the reload loop.
///
/// hotreloader only auto-watches `bin/`, `lib/` and `test/`, so a server whose
/// entry lives elsewhere (an `example/` or `benchmark/` file) would never
/// reload. [watch] fixes that: the directories to watch for `.dart` changes,
/// defaulting to the running script's own directory. Pass `const []` to rely
/// on hotreloader's watchers alone.
///
/// Pass [log] to trace reload activity — the watched directories, each change
/// that triggers a reload, the VM reload result and the route rebuild. Left
/// null it is silent (only a failing `setup` still goes to stderr). Pass
/// `print`, `stderr.writeln`, or route it into your own logger.
Future<HotReloader> enableHotReload(
  NitroServer server, {
  Iterable<String>? watch,
  void Function(String message)? log,
}) async {
  final reloader = await HotReloader.create(
    onAfterReload: (ctx) {
      log?.call('hot reload: VM ${ctx.result.name}; rebuilding routes');
      server.reload().then(
        (_) => log?.call(
          'hot reload: routes rebuilt (${server.isolates} '
          'isolate(s))',
        ),
        onError: (Object error, StackTrace stack) {
          stderr.writeln('nitro_server: hot reload failed: $error\n$stack');
        },
      );
    },
  );

  final dirs = {...?watch, if (watch == null) ?_scriptDir()};
  log?.call('hot reload: watching ${dirs.join(', ')}');
  Timer? debounce;
  for (final dir in dirs) {
    if (!Directory(dir).existsSync()) continue;
    Directory(dir).watch(recursive: true).listen((event) {
      if (!event.path.endsWith('.dart')) return;
      final path = event.path;
      // Trailing debounce: fire after the writes settle, so an editor's
      // temp-file-then-rename save is fully on disk before the VM re-reads it.
      debounce?.cancel();
      debounce = Timer(const Duration(milliseconds: 300), () {
        log?.call('hot reload: $path changed, reloading');
        unawaited(reloader.reloadCode());
      });
    });
  }
  return reloader;
}

/// The directory of the running entry script, or null if it is not a file URI.
String? _scriptDir() {
  final script = Platform.script;
  return script.scheme == 'file' ? File.fromUri(script).parent.path : null;
}
