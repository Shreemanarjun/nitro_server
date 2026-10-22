/// Reference nitro_server entrypoint and usage example — the one the Dockerfile
/// builds. It demonstrates every route type (text/JSON/params/query/body/bytes,
/// all verbs, wildcard, streaming, WebSocket, a prefixed group) plus the
/// production add-ons: middleware (CORS, compression, access log, rate limit,
/// bearer/API-key/basic auth), OpenAPI + Swagger UI (query + header inputs,
/// request bodies, response models, a working Authorize for all three auth
/// families), the live metrics dashboard, graceful shutdown, and hot reload.
/// Reads `HOST`/`PORT` from the environment.
///
/// Run locally with hot reload on: `dart run --enable-vm-service bin/server.dart`
/// (or `dart run nitro_server:serve`). Edit a handler in [setup] and save — the
/// routes rebuild on the live socket. In a container it is AOT-compiled (no hot
/// reload); see `Dockerfile`.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nitro_server/hot_reload.dart';
import 'package:nitro_server/nitro_server.dart';

/// Registers every route and middleware. Top-level (not an inline closure) so
/// hot reload can re-patch it and so it runs identically on every isolate.
Future<void> setup(NitroServer server) async {
  final env = Platform.environment;

  // Server-wide middleware (outermost first). The access log is colourful and
  // shows method · status · latency (µs/ms) · path · client IP.
  await server.use(accessLog());
  await server.use(cors());
  await server.use(compress());

  // Documented routes via the OpenApi wrapper. Security schemes are declared
  // once here so Swagger's "Authorize" covers bearer, API-key and basic; each
  // protected route opts in with `requiresAuth`. `servers` is left empty so
  // Try-it-out targets whatever origin served /docs (proxy/https safe).
  final api = OpenApi(
    server,
    title: 'nitro_server example',
    description: 'Every route type, documented from code.',
    securitySchemes: {
      'bearer': bearerScheme(bearerFormat: 'JWT'),
      'apiKey': apiKeyScheme(), // defaults to the x-api-key header
      'basic': basicScheme(),
    },
  );

  await api.get(
    '/',
    (_) => ResponseContext.text('nitro_server up now ! enjoy love'),
    doc: const OpenApiOperation(
      summary: 'Liveness text',
      responseDescription: 'Plain-text liveness string',
    ),
  );

  // Path param + JSON response, with a response model shown in Swagger.
  await api.get(
    '/users/:id',
    (request) => ResponseContext.jsonBody({'id': request.param('id')}),
    doc: const OpenApiOperation(
      summary: 'Fetch a user by id',
      // Matches the handler's actual shape.
      responseExample: {'id': '42'},
    ),
  );

  // Query + header parameters: Swagger renders inputs and sends them.
  await api.get(
    '/search',
    (request) => ResponseContext.jsonBody({
      'q': request.queryParam('q'),
      'page': request.queryParam('page') ?? '1',
      'requestId': request.header('x-request-id'),
    }),
    doc: const OpenApiOperation(
      summary: 'Search with ?q=&page=&sort=',
      params: [
        OpenApiParam.query(
          'q',
          required: true,
          description: 'search text',
          example: 'ada',
        ),
        OpenApiParam.query('page', schema: {'type': 'integer'}, example: 1),
        OpenApiParam.query('sort', enumValues: ['asc', 'desc'], example: 'asc'),
        OpenApiParam.header('X-Request-Id', description: 'Correlation id'),
      ],
    ),
  );

  // JSON request body in, JSON out. The handler validates the body, so the
  // documented 201/400 match what it actually returns.
  await api.post(
    '/users',
    (request) {
      final Map<String, Object?> body;
      try {
        body = request.jsonMap();
      } on FormatException {
        return ResponseContext.jsonBody({'error': 'bad body'}, status: 400);
      }
      return ResponseContext.jsonBody({'created': body}, status: 201);
    },
    doc: const OpenApiOperation(
      summary: 'Create a user from a JSON body',
      requestExample: {'name': 'Ada', 'email': 'ada@example.com', 'age': 36},
      successStatus: 201,
      responseExample: {
        'created': {'name': 'Ada'},
      },
      extraResponses: {
        '400': OpenApiResponse(
          'Invalid JSON body',
          example: {'error': 'bad body'},
        ),
      },
    ),
  );

  // Raw bytes echo — documented as a binary (octet-stream) body so Swagger
  // shows a file/raw input instead of a JSON editor.
  await api.put(
    '/echo',
    (request) => ResponseContext.bytes(request.body),
    doc: const OpenApiOperation(
      summary: 'Echo the request body',
      requestBodyDoc: OpenApiRequestBody.binary(),
    ),
  );

  // Multipart upload with a file field — Swagger renders a file picker.
  await api.post(
    '/upload',
    (request) {
      final parts = request.multipart();
      return ResponseContext.jsonBody({'parts': parts.length});
    },
    doc: const OpenApiOperation(
      summary: 'Upload a file (multipart/form-data)',
      requestBodyDoc: OpenApiRequestBody.multipart(
        required: true,
        schema: {
          'type': 'object',
          'properties': {
            'file': {'type': 'string', 'format': 'binary'},
            'name': {'type': 'string'},
          },
        },
      ),
    ),
  );

  await api.patch(
    '/users/:id',
    (request) => ResponseContext.jsonBody({'patched': request.param('id')}),
    doc: const OpenApiOperation(
      summary: 'Patch a user',
      requestExample: {'email': 'new@example.com'},
    ),
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

  // Protected routes — one per auth family. Each declares `requiresAuth` so
  // Swagger shows the padlock and sends the credential, and wires the matching
  // middleware so the live route actually enforces it. There are NO built-in
  // credentials: until API_TOKEN / API_KEY / BASIC_USER+BASIC_PASSWORD are set
  // the protected routes refuse every caller (401), so an image started with
  // defaults exposes nothing (e.g. `API_TOKEN=dev` for local play).
  await api.get(
    '/api/v1/me',
    (_) => ResponseContext.jsonBody({'ok': true}),
    middleware: [
      rateLimit(maxRequests: 100),
      bearerAuth((token) => _configured(env['API_TOKEN'], token)),
    ],
    doc: const OpenApiOperation(
      summary: 'Who am I (bearer — token: \$API_TOKEN)',
      requiresAuth: ['bearer'],
    ),
  );

  await api.get(
    '/api/v1/key',
    (_) => ResponseContext.jsonBody({'ok': true}),
    middleware: [apiKeyAuth((key) => _configured(env['API_KEY'], key))],
    doc: const OpenApiOperation(
      summary: 'API-key protected (x-api-key: \$API_KEY)',
      requiresAuth: ['apiKey'],
    ),
  );

  await api.get(
    '/api/v1/admin',
    (_) => ResponseContext.jsonBody({'ok': true}),
    middleware: [
      basicAuth(
        (user, pass) =>
            _configured(env['BASIC_USER'], user) &&
            _configured(env['BASIC_PASSWORD'], pass),
      ),
    ],
    doc: const OpenApiOperation(
      summary: 'Basic protected (\$BASIC_USER:\$BASIC_PASSWORD)',
      requiresAuth: ['basic'],
    ),
  );

  // Static files from ./public (serves index.html; 404 if the dir is absent).
  await server.get('/static/*', staticFiles('public'));

  // WebSocket echo: the payload back verbatim (text as text, bytes as bytes)
  // — what an echo client, and the Autobahn conformance suite, expect.
  await server.ws('/ws/echo', (session) async {
    await for (final message in session.messages) {
      if (message is WsText) {
        session.sendText(message.text);
      } else if (message is WsBinary) {
        session.sendBytes(message.bytes);
      }
    }
  });

  // Operational endpoints (single handler isolate, so metrics are consistent).
  // On a public listener they are guarded: HTTP basic auth when ADMIN_USER +
  // ADMIN_PASSWORD are set, otherwise loopback clients only. /healthz and
  // /readyz stay open for probes.
  final adminUser = env['ADMIN_USER'], adminPassword = env['ADMIN_PASSWORD'];
  final ops = <Middleware>[
    if (adminUser != null && adminPassword != null)
      basicAuth(
        (user, pass) =>
            secureEquals(user, adminUser) && secureEquals(pass, adminPassword),
      )
    else
      loopbackOnly,
  ];
  await serveObservability(server, middleware: ops);
  await api.serve(middleware: ops); // /openapi.json, /docs
}

/// Compares two secrets in time independent of where they differ, so a
/// response-time oracle cannot recover a credential byte by byte.
bool secureEquals(String a, String b) {
  final x = utf8.encode(a), y = utf8.encode(b);
  var diff = x.length ^ y.length;
  for (var i = 0; i < x.length && i < y.length; i++) {
    diff |= x[i] ^ y[i];
  }
  return diff == 0;
}

/// Admits only clients connecting from this host (an SSH tunnel, a sidecar);
/// A configured secret matches the presented one in constant time; an unset
/// secret matches nothing — there is no default credential to guess.
bool _configured(String? secret, String presented) =>
    secret != null && secureEquals(secret, presented);

/// everyone else is 403. The example's stand-in for real admin auth — and
/// only that: behind a reverse proxy on the SAME host every peer is loopback,
/// so there set `ADMIN_USER`/`ADMIN_PASSWORD` (basic auth replaces this
/// check) or the proxy must not forward these paths.
Future<ResponseContext> loopbackOnly(
  RequestContext request,
  RequestHandler next,
) async {
  final ip = request.clientIp;
  if (ip == '127.0.0.1' || ip == '::1' || ip == '::ffff:127.0.0.1') {
    return next(request);
  }
  return ResponseContext.problem(
    title: 'Operational endpoints are loopback-only',
    status: 403,
    detail: 'set ADMIN_USER and ADMIN_PASSWORD to reach them remotely',
  );
}

Future<void> main() async {
  final startup = Stopwatch()..start();
  final env = Platform.environment;
  final host = env['HOST'] ?? '0.0.0.0';
  final port = int.tryParse(env['PORT'] ?? '') ?? 8080;

  final server = await NitroServer.bind(
    ServerConfig(host: host, port: port),
    setup,
  );

  // Always try hot reload: it attaches under `dart run --enable-vm-service`
  // (JIT) and is gracefully unavailable in an AOT build. Edit a handler in
  // [setup], save, and the routes rebuild on the live socket.
  var hotReload = false;
  try {
    await enableHotReload(server, log: (m) => stdout.writeln('  ↻ $m'));
    hotReload = true;
  } catch (_) {
    // AOT or VM service disabled: serve normally, no reload.
  }

  // Graceful drain on SIGTERM/SIGINT (containers, Ctrl-C).
  shutdownOnSignals(server, drain: const Duration(seconds: 15));

  // No credential configured = the matching example route refuses everyone.
  if (env['API_TOKEN'] == null ||
      env['API_KEY'] == null ||
      env['BASIC_USER'] == null ||
      env['BASIC_PASSWORD'] == null) {
    stderr.writeln(
      '  ! API_TOKEN / API_KEY / BASIC_USER+BASIC_PASSWORD unset: the example '
      'routes they protect answer 401 to everyone until set '
      '(ADMIN_USER/ADMIN_PASSWORD guard /metrics, /dashboard, /docs off-host)',
    );
  }

  startup.stop();
  stdout.writeln(
    serverBanner(
      title: 'nitro_server',
      version: '1.0.0',
      logo: nitroServerAsciiLogo,
      uri: server.uri,
      isolates: server.config.isolates,
      pid: pid,
      routes: server.routes,
      links: const {
        'docs': '/docs',
        'dashboard': '/dashboard',
        'metrics': '/metrics',
        'health': '/healthz',
        'ready': '/readyz',
      },
      facts: [
        'started in ${startup.elapsedMilliseconds}ms',
        'hot reload ${hotReload ? 'on' : 'off'}',
        'timing ${server.config.responseTiming ? 'on' : 'off'}',
      ],
      extra: const ['ready · press Ctrl-C to stop'],
      color: stdout.supportsAnsiEscapes,
    ),
  );
  await server.onClose;
}
