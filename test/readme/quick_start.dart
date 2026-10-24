// README block: quick start (verbatim; verified by readme_snippets_test.dart).
// Verbatim README code (see readme_snippets_test.dart); not reformatted:
// dart format off
import 'package:nitro_server/nitro_server.dart';

Future<void> main() async {
  final server = await NitroServer.bind(); // 127.0.0.1, a free port
  await server.get('/hello', (_) => ResponseContext.text('hi 👋'));
  await server.get('/users/:id', (r) => ResponseContext.jsonBody({'id': r.param('id')}));
  await server.post('/echo', (r) => ResponseContext.bytes(r.body));
  print('listening on ${server.uri}');
}
