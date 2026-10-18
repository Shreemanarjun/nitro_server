// Compile-checks the code snippets in README.md against the real API. The
// snippet bodies live in functions that are never executed — `dart analyze` and
// `dart test` still type-check them, so a drifted snippet fails the build.
// ignore_for_file: unreachable_from_main, unused_local_variable
import 'dart:typed_data';

import 'package:nitro_server/hot_reload.dart';
import 'package:nitro_server/nitro_server.dart';
import 'package:nitro_server/testing.dart';
import 'package:test/test.dart';

// Stub handlers/middleware the snippets refer to.
ResponseContext getUser(RequestContext r) =>
    ResponseContext.jsonBody({'id': r.param('id')});
ResponseContext createUser(RequestContext r) => ResponseContext.text('made');
ResponseContext search(RequestContext r) =>
    ResponseContext.jsonBody({'q': null});
ResponseContext upload(RequestContext r) => ResponseContext.text('ok');
ResponseContext me(RequestContext r) => ResponseContext.jsonBody({'ok': true});
const token = 'dev';
ResponseContext handleUpload(RequestContext r) => ResponseContext.text('ok');
ResponseContext dashboard(RequestContext r) => ResponseContext.text('admin');
ResponseContext report(RequestContext r) => ResponseContext.text('report');
Middleware get requireAdmin =>
    (request, next) => next(request);
const mySecret = 'secret';

// README: Quick start
Future<void> quickStart() async {
  final server = await NitroServer.bind();
  await server.get('/hello', (_) => ResponseContext.text('hi 👋'));
  await server.get(
    '/users/:id',
    (request) => ResponseContext.jsonBody({'id': request.param('id')}),
  );
  await server.post('/echo', (request) => ResponseContext.bytes(request.body));
  print('listening on ${server.uri}');
}

// README: Routing & handlers
Future<void> routing(NitroServer server) async {
  await server.get(
    '/users/:id',
    (r) => ResponseContext.text('user ${r.param('id')}'),
  );
  await server.post('/upload/*', handleUpload, maxBodyBytes: 50 * 1024 * 1024);
  await server.route(
    HttpMethod.custom,
    '/items',
    report,
    customMethod: 'REPORT',
  );
  await server.get('/admin', dashboard, middleware: [requireAdmin]);
  final api = server.group('/api/v1')..use(cors());
  await api.get('/ping', (_) => ResponseContext.text('pong'));
  server.notFoundHandler = (request) =>
      ResponseContext.text('nope', status: 404);
  server.errorHandler = (error, request) =>
      ResponseContext.text('oops', status: 500);
}

// README: WebSocket
Future<void> websocket(NitroServer server) async {
  await server.ws('/chat', (session) async {
    await for (final message in session.messages) {
      final text = message is WsText ? message.text : '(binary)';
      session.sendText('echo: $text');
    }
  }, protocols: ['chat.v1']);
}

// README: Middleware
Future<void> middleware(NitroServer server) async {
  await server.use(accessLog());
  await server.use(cors(allowOrigin: 'https://example.com'));
  await server.use(compress());
  await server.use(rateLimit(maxRequests: 100));
  await server.use(bearerAuth((token) => token == mySecret));
}

// README: Production — observability, OpenAPI, graceful shutdown
Future<void> production(NitroServer server) async {
  await serveObservability(server);

  final api = OpenApi(
    server,
    title: 'My API',
    securitySchemes: {'bearer': bearerScheme(bearerFormat: 'JWT')},
  );

  await api.get(
    '/search',
    search,
    doc: const OpenApiOperation(
      summary: 'Search',
      params: [
        OpenApiParam.query('q', required: true, example: 'ada'),
        OpenApiParam.query('page', schema: {'type': 'integer'}),
        OpenApiParam.header('X-Request-Id'),
      ],
      responseExample: {'total': 0},
    ),
  );
  await api.post(
    '/users',
    createUser,
    doc: const OpenApiOperation(
      summary: 'Create a user',
      requestExample: {'name': 'Ada', 'email': 'ada@example.com'},
      extraResponses: {'400': OpenApiResponse('Invalid body')},
    ),
  );
  await api.post(
    '/upload',
    upload,
    doc: const OpenApiOperation(
      requestBodyDoc: OpenApiRequestBody.multipart(
        schema: {
          'type': 'object',
          'properties': {
            'file': {'type': 'string', 'format': 'binary'},
          },
        },
      ),
    ),
  );
  await api.get(
    '/me',
    me,
    middleware: [bearerAuth((t) => t == token)],
    doc: const OpenApiOperation(requiresAuth: ['bearer']),
  );
  await api.serve();

  shutdownOnSignals(server, drain: const Duration(seconds: 15));
}

// README: Configuration
Future<void> setup(NitroServer server) async {
  await server.get('/report', (_) => ResponseContext.jsonBody({'ok': true}));
}

Future<void> configured() async {
  final server = await NitroServer.bind(
    const ServerConfig(port: 8080, isolates: 0),
    setup,
  );
  print(server.uri);
}

// README: Testing
Future<void> testingSnippet() async {
  final client = await NitroTestClient.start();
  await client.server.get(
    '/users/:id',
    (r) => ResponseContext.text('u${r.param('id')}'),
  );
  final res = await client.get('/users/42');
  assert(res.status == 200);
  assert(res.text() == 'u42');
  await client.close();
}

// README: Hot reload
Future<void> hotReload() async {
  final server = await NitroServer.bind(const ServerConfig(port: 8080), setup);
  try {
    await enableHotReload(server); // re-runs `setup` after each hot reload
  } catch (_) {
    // AOT or no VM service: serve without reload.
  }
}

// README: Startup banner
String banner(NitroServer server) => serverBanner(
  title: 'nitro_server',
  version: '1.0.0',
  logo: nitroServerAsciiLogo,
  uri: server.uri,
  routes: server.routes,
  links: const {'docs': '/docs'},
);

// README: Dart-only use / loader
Future<void> loader() async {
  final Uint8List _ = Uint8List(0); // ensure dart:typed_data is used
  loadNitroServerNative();
}

void main() {
  test('README snippets type-check against the public API', () {
    // The snippet functions above are compiled (type-checked) but not run;
    // reaching here means they all compile.
    expect(quickStart, isA<Function>());
  });
}
