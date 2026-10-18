/// Reference nitro_server entrypoint and usage example — the one the Dockerfile
/// builds. It demonstrates every route type (text/JSON/params/query/body/bytes,
/// all verbs, wildcard, streaming, WebSocket, a prefixed group) plus the
/// production add-ons: middleware (CORS, compression, access log, rate limit,
/// bearer auth), OpenAPI + Swagger UI, the live metrics dashboard, and graceful
/// shutdown. Reads `HOST`/`PORT` from the environment.
///
/// Run locally: `dart run bin/server.dart` (after building the native lib, see
/// README). In a container it is AOT-compiled; see `Dockerfile`.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nitro_server/nitro_server.dart';

Future<void> main() async {
  final env = Platform.environment;
  final host = env['HOST'] ?? '0.0.0.0';
  final port = int.tryParse(env['PORT'] ?? '') ?? 8080;

  final server = await NitroServer.bind(ServerConfig(host: host, port: port));

  // Server-wide middleware (outermost first).
  await server.use(accessLog());
  await server.use(cors());
  await server.use(compress());

  // Documented routes via the OpenAPI wrapper: each registers a real route and
  // captures its spec inline.
  final api = OpenApi(
    server,
    title: 'nitro_server example',
    description: 'Every route type, documented from code.',
    servers: const [OpenApiServer('http://localhost:8080')],
  );

  await api.get(
    '/',
    (_) => ResponseContext.text('nitro_server up'),
    doc: const OpenApiOperation(summary: 'Liveness text'),
  );

  // Path param + JSON response.
  await api.get(
    '/users/:id',
    (request) => ResponseContext.jsonBody({'id': request.param('id')}),
    doc: const OpenApiOperation(summary: 'Fetch a user by id'),
  );

  // Query parameters.
  await api.get(
    '/search',
    (request) => ResponseContext.jsonBody({
      'q': request.queryParam('q'),
      'page': request.queryParam('page') ?? '1',
    }),
    doc: const OpenApiOperation(summary: 'Search with ?q=&page='),
  );

  // JSON request body in, JSON out.
  await api.post(
    '/users',
    (request) =>
        ResponseContext.jsonBody({'created': request.jsonMap()}, status: 201),
    doc: const OpenApiOperation(summary: 'Create a user from a JSON body'),
  );

  // Raw bytes echo.
  await api.put(
    '/echo',
    (request) => ResponseContext.bytes(request.body),
    doc: const OpenApiOperation(summary: 'Echo the request body'),
  );

  await api.patch(
    '/users/:id',
    (request) => ResponseContext.jsonBody({'patched': request.param('id')}),
    doc: const OpenApiOperation(summary: 'Patch a user'),
  );

  await api.delete(
    '/users/:id',
    (request) => ResponseContext.text('deleted ${request.param('id')}'),
    doc: const OpenApiOperation(summary: 'Delete a user'),
  );

  // Wildcard + a chunked streaming response.
  await api.get(
    '/stream',
    (_) => ResponseContext.stream(
      Stream<Uint8List>.periodic(
        const Duration(milliseconds: 100),
        (i) => Uint8List.fromList(utf8.encode('chunk $i\n')),
      ).take(5),
    ),
    doc: const OpenApiOperation(summary: 'Five chunks, 100ms apart'),
  );

  // A prefixed group with its own middleware: rate-limited, bearer-protected.
  final secure = server.group('/api/v1');
  await secure.use(rateLimit(maxRequests: 100));
  await secure.use(bearerAuth((token) => token == (env['API_TOKEN'] ?? 'dev')));
  await secure.get('/me', (_) => ResponseContext.jsonBody({'ok': true}));

  // Static files from ./public (serves index.html; 404 if the dir is absent).
  await server.get('/static/*', staticFiles('public'));

  // WebSocket echo.
  await server.ws('/ws/echo', (session) async {
    await for (final message in session.messages) {
      if (message is WsText) {
        session.sendText('echo: ${message.text}');
      } else if (message is WsBinary) {
        session.sendBytes(message.bytes);
      }
    }
  });

  // Operational endpoints (single handler isolate, so metrics are consistent).
  await serveObservability(server); // /metrics, /healthz, /readyz, /dashboard
  await api.serve(); // /openapi.json, /docs

  // Graceful drain on SIGTERM/SIGINT (containers, Ctrl-C).
  shutdownOnSignals(server, drain: const Duration(seconds: 15));

  stdout.writeln('nitro_server listening on ${server.uri}');
  stdout.writeln(
    '  docs: ${server.uri}/docs   dashboard: ${server.uri}/dashboard',
  );
  await server.onClose;
}
