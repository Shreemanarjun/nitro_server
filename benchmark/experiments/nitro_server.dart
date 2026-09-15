// nitro (current thread-per-connection engine) across N isolates, keep-alive.
// Serves /static (engine-served, getStatic) and /hello (Dart handler). Prints
// the bound port. Build: dart compile exe from the package root so the
// nitro_server package and its dylib resolve. args: [isolates].
import 'dart:io' show Platform;

import 'package:nitro_server/nitro_server.dart';

Future<void> main(List<String> args) async {
  final n = args.isEmpty ? 4 : int.parse(args.first);
  // NITRO_DYLIB lets the runner point at the built dylib regardless of CWD.
  final dylib = Platform.environment['NITRO_DYLIB'];
  loadNitroServerNative(path: dylib == null || dylib.isEmpty ? null : dylib);
  final server = await NitroServer.bind(
    ServerConfig(maxRequestsPerConnection: 0, isolates: n),
    (s) async {
      await s.get('/hello', (_) => ResponseContext.text('hello'));
      await s.getStatic('/static', 'hello'.codeUnits, contentType: 'text/plain');
    },
  );
  print('LISTENING ${server.port}');
}
