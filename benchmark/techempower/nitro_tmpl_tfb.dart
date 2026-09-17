// Template-route vs handler comparison (same body shape, one :id slot).
//   GET /t/:id -> engine-assembled templated JSON (no Dart per request)
//   GET /h/:id -> Dart handler producing the same JSON
import 'dart:io';
import 'package:nitro_server/nitro_server.dart';

Future<void> _setup(NitroServer server) async {
  await server.getTemplated('/t/:id', '{"message":"Hello, World!","id":{id}}',
      contentType: 'application/json');
  await server.get('/h/:id', (ctx) => ResponseContext.jsonBody(
      {'message': 'Hello, World!', 'id': ctx.param('id') ?? ''}));
}

Future<void> main() async {
  loadNitroServerNative();
  final cores = Platform.numberOfProcessors;
  final server = await NitroServer.bind(
    ServerConfig(port: 8080, isolates: cores, maxRequestsPerConnection: 0), _setup);
  stdout.writeln('PORT ${server.port}');
  await ProcessSignal.sigterm.watch().first;
  await server.close();
}
