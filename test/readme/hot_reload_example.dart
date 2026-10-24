// README block: Hot reload (verbatim; verified by readme_snippets_test.dart).
// Verbatim README code (see readme_snippets_test.dart); not reformatted:
// dart format off
import 'package:nitro_server/hot_reload.dart';
import 'package:nitro_server/nitro_server.dart';

Future<void> setup(NitroServer server) async {
  await server.get('/hello', (_) => ResponseContext.text('hi'));
}

Future<void> main() async {
  final server = await NitroServer.bind(const ServerConfig(port: 8080), setup);
  try {
    await enableHotReload(server, log: print); // watch: ['lib', 'bin']
  } catch (_) {
    // AOT or no VM service
  }
  await server.onClose;
}
