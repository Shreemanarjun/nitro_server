// nitro (current thread-per-connection engine) across N isolates, keep-alive.
// Serves /static (engine-served, getStatic) and /hello (Dart handler). Prints
// the bound port. Build: dart compile exe from the package root so the
// nitro_server package and its dylib resolve. args: [isolates].
//
// Hot reload: `dart run --enable-vm-service benchmark/experiments/nitro_server.dart`,
// then edit `_setup` and save. `_setup` must be top-level (as here) for reload
// to pick up the change.
import 'dart:io' show Platform;

import 'package:nitro_server/hot_reload.dart';
import 'package:nitro_server/nitro_server.dart';

Future<void> _setup(NitroServer s) async {
  await s.get(
    '/hello',
    (context) => ResponseContext.text('hello arjun query${context.query}'),
  );
  await s.getStatic('/static', 'hello'.codeUnits, contentType: 'text/plain');
}

Future<void> main(List<String> args) async {
  final n = args.isEmpty ? 4 : int.parse(args.first);
  final dylib = Platform.environment['NITRO_DYLIB'];
  loadNitroServerNative(path: dylib == null || dylib.isEmpty ? null : dylib);
  final server = await NitroServer.bind(
    ServerConfig(maxRequestsPerConnection: 0, isolates: n, port: 8080),
    _setup,
  );
  await enableHotReload(server, log: print);
  print('LISTENING http://${server.config.host}:${server.port}');
}
