// Every README `dart` fragment, verbatim (indentation aside), so the analyzer
// type-checks exactly what the README shows; readme_snippets_test.dart fails if
// a README line is missing here. Statement fragments live in functions that are
// never called.
// ignore_for_file: unnecessary_statements, unused_local_variable, unused_element
// ignore_for_file: prefer_const_constructors, avoid_redundant_argument_values
// ignore_for_file: prefer_function_declarations_over_variables, prefer_final_locals
// Verbatim README code (see readme_snippets_test.dart); not reformatted:
// dart format off
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nitro_server/nitro_server.dart';

/// Stand-in for the environment the snippets read.
final env = Platform.environment;

Future<void> fragment1(NitroServer server) async {
  await server.get('/users/:id', (r) => ResponseContext.text('user ${r.param('id')}'));
  await server.post('/upload/*', (r) => ResponseContext.text('${r.body.length} bytes'),
      maxBodyBytes: 50 * 1024 * 1024);
  await server.put('/items/:id', (r) => ResponseContext.jsonBody(r.jsonMap()));
  await server.delete('/items/:id', (r) => ResponseContext.text('', status: 204));
  await server.all('/ping', (_) => ResponseContext.text('pong'));

  await server.route(HttpMethod.custom, '/items', (_) => ResponseContext.text('report'),
      customMethod: 'REPORT');
  await server.get('/slow', (_) => ResponseContext.text('done'),
      timeout: const Duration(seconds: 5)); // 408 past it

  final api = server.group('/api/v1');
  await api.use(cors()); // before the group's routes
  await api.get('/ping', (_) => ResponseContext.text('pong'));
  final v2 = api.group('/v2');

  server.notFoundHandler = (r) => ResponseContext.text('no ${r.path}', status: 404);
  server.errorHandler = (e, r) => ResponseContext.text('oops: $e', status: 500);

  await server.unroute(HttpMethod.get, '/slow');
}

class UserController extends Controller {
  UserController() : super(prefix: '/users', middleware: [cors()]);
  final _users = <String, Object?>{'42': 'Ada'};

  @override
  Future<void> register(RouteGroup on) async {
    await on.get('/', (_) => ResponseContext.jsonBody(_users));
    await on.get('/:id', getOne);
    await on.post('/', create);
  }

  ResponseContext getOne(RequestContext c) =>
      ResponseContext.jsonBody({c.param('id'): _users[c.param('id')]});

  ResponseContext create(RequestContext c) {
    final body = c.jsonMap();
    _users['${body['id']}'] = body['name'];
    return ResponseContext.jsonBody(body, status: 201);
  }
}

Future<void> fragment2(NitroServer server) async {
  await server.mount(UserController());
}

Future<void> fragment3(NitroServer server) async {
  await server.getStatic('/health', utf8.encode('ok'), contentType: 'text/plain');
  await server.staticRoute(HttpMethod.get, '/version', utf8.encode('{"v":"1.0.0"}'),
      contentType: 'application/json', headers: {'cache-control': 'max-age=60'});
}

Future<void> fragment4(NitroServer server) async {
  await server.post('/users/:id', (r) {
    r.method;                 // HttpMethod.post (r.customMethod for custom verbs)
    r.path;                   // '/users/42' (r.routePattern = '/users/:id')
    r.param('id');            // '42' (r.params)
    r.queryParam('page');     // r.queryParameters, r.queryParamAll, r.queryParametersAll
    r.header('x-request-id'); // first value, case-insensitive; r.headers: Map<String, List<String>>
    r.cookies['session'];
    r.clientIp;               // '' when unavailable
    r.body;                   // Uint8List
    r.text();
    final m = r.jsonMap();    // also jsonList(), json(), jsonAs<T>()
    return ResponseContext.jsonBody({'id': r.param('id'), 'got': m});
  });
}

Future<void> fragment5(NitroServer server) async {
  await server.post('/upload', (r) {
    final parts = r.multipart(); // FormatException unless multipart/form-data
    for (final p in parts) {
      if (p.isFile) {
        File('uploads/${p.filename}').writeAsBytesSync(p.bytes); // p.contentType
      } else {
        print('${p.name} = ${p.text()}');
      }
    }
    return ResponseContext.jsonBody({'parts': parts.length});
  }, maxBodyBytes: 50 * 1024 * 1024);
}

Future<void> fragment6(NitroServer server) async {
  await server.post('/ingest', (r) async {
    var total = 0;
    await for (final chunk in r.bodyStream!) {
      total += chunk.length;
    }
    return ResponseContext.text('received $total bytes');
  }, streamBody: true); // r.body is empty, r.bodyStream is set
}

Future<void> fragment7(NitroServer server) async {
  ResponseContext.text('hi');                                      // text/plain; charset=utf-8
  ResponseContext.text('<b>hi</b>', contentType: 'text/html');
  ResponseContext.html('<h1>hi</h1>');
  ResponseContext.jsonBody({'ok': true, 'n': [1, 2]});             // any JSON-encodable
  ResponseContext.jsonMap({'ok': true});
  ResponseContext.json('{"pre":"encoded"}');
  ResponseContext.bytes(Uint8List(0), contentType: 'image/png');
  ResponseContext.redirect('/login');                              // 302; status: 301/303/307/308
  ResponseContext.file('report.pdf', contentType: 'application/pdf'); // engine-sent in chunks; offset:/length:
  ResponseContext.stream(Stream.value(Uint8List(0)), contentType: 'text/csv'); // chunked
  ResponseContext.text('created', status: 201, headers: {'location': '/items/7'});
}

Future<void> fragment8(NitroServer server) async {
  await server.get('/login', (_) => ResponseContext.text('ok')
      .withCookie(SetCookie('session', 'abc123',
          httpOnly: true, secure: true, sameSite: SameSite.lax,
          maxAge: const Duration(days: 7), path: '/'))
      .withHeader('cache-control', 'no-store'));
}

Future<void> fragment9(NitroServer server) async {
  await server.get('/events', (_) => ResponseContext.sse(
    Stream.periodic(const Duration(seconds: 1),
        (i) => SseEvent('tick $i', event: 'tick', id: '$i')).take(10),
  ));
}

Future<void> fragment10(NitroServer server) async {
  await server.post('/orders', (r) {
    if (r.jsonMap()['email'] == null) {
      return ResponseContext.problem(
        title: 'Validation failed', status: 422, detail: 'email is required',
        type: 'https://example.com/errors/validation', extensions: {'field': 'email'},
      );
    }
    return ResponseContext.text('ok', status: 201);
  });
}

Future<void> fragment11(NitroServer server) async {
  final kId = JsonToken('id'), kName = JsonToken('name'); // hoist interned keys

  await server.get('/report', (_) => ResponseContext.jsonWriter((w) {
    w..beginObject()..key('ok')..writeBool(true)..key('rows')..beginArray();
    for (var i = 0; i < 3; i++) {
      w..beginObject()..keyToken(kId)..writeInt(i)..keyToken(kName)..writeString('row $i')..endObject();
    }
    w..endArray()..endObject();
  }));
}

Future<void> fragment12(NitroServer server) async {
  await server.ws('/chat', (session) async {
    session.protocol;                        // negotiated subprotocol or null
    session.handshake.header('x-user');      // the upgrade request
    await for (final m in session.messages) {
      if (m is WsText) session.sendText('echo: ${m.text}');   // returns queued bytes; -1 = closed
      if (m is WsBinary) session.sendBytes(m.bytes);
      if (session.bufferedBytes > 1 << 20) await session.close(1009);
    }
    // returning or throwing closes the session; session.closeCode = peer's code
  }, protocols: ['chat.v1'], middleware: [bearerAuth((t) => t == 'secret')]);
}

Future<void> fragment13(NitroServer server) async {
  await server.use(accessLog());                       // json: true for JSON lines
  await server.use(requestId());                       // x-request-id in/out
  await server.use(cors(allowOrigin: 'https://example.com', allowCredentials: true));
  await server.use(compress(minBytes: 1024, level: 1, brotliQuality: 4));
  await server.use(rateLimit(maxRequests: 100, window: const Duration(minutes: 1)));
  await server.use(rateLimit(maxRequests: 100, trustedProxies: ['10.0.0.0/8'])); // believe X-Forwarded-For from these peers only
  await server.use(bearerAuth((token) => token == 'secret', realm: 'api'));
  await server.use(apiKeyAuth((key) => key == 'k', headerName: 'x-api-key'));
  await server.use(basicAuth((user, pass) => user == 'admin' && pass == 'pw'));
  await server.use(originPolicy(['https://app.example.com'])); // 403 unless Origin matches; also gates ws() handshakes (4403)

  // Static files: a handler on a wildcard route
  await server.get('/assets/*', staticFiles('web', maxAge: const Duration(hours: 1)));
}

Middleware timing() => (request, next) async {
  final sw = Stopwatch()..start();
  final res = await next(request);
  return res.withHeader('x-elapsed-ms', '${sw.elapsedMilliseconds}');
};

final Middleware requireAdmin = (request, next) => request.header('x-role') == 'admin'
    ? next(request)
    : ResponseContext.text('forbidden', status: 403);

Future<void> fragment14(NitroServer server) async {
  await server.use(timing());
  await server.get('/admin', (_) => ResponseContext.text('hi'), middleware: [requireAdmin]);
}

class CountingStore implements RateLimitStore { // swap the map for Redis INCR+EXPIRE
  final _hits = <String, RateLimitHit>{};
  @override
  RateLimitHit hit(String key, Duration window) {
    final now = DateTime.now();
    final prev = _hits[key];
    return _hits[key] = (prev == null || now.isAfter(prev.resetAt))
        ? RateLimitHit(count: 1, resetAt: now.add(window))
        : RateLimitHit(count: prev.count + 1, resetAt: prev.resetAt);
  }
}

Future<void> fragment15(NitroServer server) async {
  await server.use(rateLimit(
    maxRequests: 100,
    store: CountingStore(),
    keyExtractor: (r) => r.header('x-api-key') ?? r.clientIp,
    onLimit: (retryAfter) => ResponseContext.problem(title: 'Too many requests', status: 429),
  ));
}

final userSchema = ApiSchema.object({
  'name': ApiSchema.string(),
  'email': ApiSchema.string(format: 'email'),
  'age': ApiSchema.integer(nullable: true),
}, required: ['name', 'email']);

Future<void> fragment16(NitroServer server) async {
  await server.post('/users', (r) => ResponseContext.jsonBody(r.jsonMap(), status: 201),
      middleware: [validateJsonBody(userSchema)]); // 400 bad JSON, 422 schema failure
}

Future<void> setup(NitroServer server) async {
  await server.get('/report', (_) => ResponseContext.jsonBody({'ok': true}));
}

Future<void> fragmentConfigured() async {
  final server = await NitroServer.bind(
    const ServerConfig(port: 8080, isolates: 0),
    setup, // required when isolates != 1
  );
}

Future<void> fragment17(NitroServer server) async {
  final server = await NitroServer.bind(ServerConfig.fromEnv(Platform.environment), setup);
  // HOST PORT BACKLOG ISOLATES WORKER_THREADS MAX_BODY_BYTES MAX_BUFFERED_BODY_BYTES MAX_CONNECTIONS
  // MAX_CONNECTIONS_PER_IP MAX_REQUESTS_PER_CONNECTION MAX_IN_FLIGHT_REQUESTS MAX_CONNECTION_AGE_MS
  // KEEP_ALIVE_TIMEOUT_MS DEFAULT_TIMEOUT_MS HEADER_TIMEOUT_MS WRITE_TIMEOUT_MS BODY_TIMEOUT_MS
  // STREAM_IDLE_TIMEOUT_MS STREAM_MAX_BUFFER_BYTES WS_IDLE_TIMEOUT_MS WS_MAX_BUFFER_BYTES
  // WS_COMPRESSION RESPONSE_TIMING EXPOSE_ERROR_DETAILS PROXY_PROTOCOL HTTP_PROTOCOL
  // TLS_CERT_FILE+TLS_KEY_FILE | TLS_CERT_PEM+TLS_KEY_PEM TLS_MIN_VERSION (1.2|1.3)
  // TLS_CIPHERS TLS_CIPHER_SUITES TLS_CLIENT_CA_FILE | TLS_CLIENT_CA_PEM
  // A value that does not parse throws FormatException.
}

Future<void> fragment18(NitroServer server) async {
  final server = await NitroServer.bind(
    const ServerConfig(port: 8443, tls: TlsConfig(certFile: 'cert.pem', keyFile: 'key.pem')),
    setup,
  );
  server.reloadTls(const TlsConfig(certFile: 'renewed.pem', keyFile: 'renewed.key')); // no downtime
}

Future<void> fragment19(NitroServer server) async {
  var dbReady = false;
  await serveObservability(server,
      ready: () => dbReady,   // /readyz 503 while false
      middleware: [basicAuth((u, p) => u == 'ops' && p == env['OPS_PW'])], // guards /metrics + dashboard
      maxDashboardViewers: 16,
      dashboardPath: null,    // drop the dashboard
      prefix: 'myapp');
  // GET /healthz   200 while serving
  // GET /readyz    503 while draining or when a helper isolate died
  // GET /metrics   Prometheus text (requests, errors, in-flight, responses_total{class}, connections,
  //                event_loop_lag_seconds, helper_isolates_alive, per-route latency summary)
  // GET /dashboard live HTML
}

Future<void> fragment20(NitroServer server) async {
  await serveOpenApi(server, title: 'My API'); // spec from routes, Swagger UI at /docs
}

Future<void> fragment21(NitroServer server) async {
  final api = OpenApi(server, title: 'My API',
      securitySchemes: {'bearer': bearerScheme(bearerFormat: 'JWT')});

  await api.get('/search', (r) => ResponseContext.jsonBody({'q': r.queryParam('q')}),
      doc: const OpenApiOperation(
        summary: 'Search',
        params: [OpenApiParam.query('q', required: true), OpenApiParam.header('X-Request-Id')],
        responseExample: {'total': 0},
      ));

  await api.post('/users', (r) => ResponseContext.jsonBody(r.jsonMap(), status: 201),
      doc: const OpenApiOperation(
        requestExample: {'name': 'Ada', 'email': 'ada@example.com'},
        successStatus: 201,
        extraResponses: {'400': OpenApiResponse('Invalid body')},
      ));

  await api.post('/upload', (r) => ResponseContext.jsonBody({'parts': r.multipart().length}),
      doc: const OpenApiOperation(requestBodyDoc: OpenApiRequestBody.multipart(schema: {
        'type': 'object', 'properties': {'file': {'type': 'string', 'format': 'binary'}},
      })));

  await api.get('/me', (_) => ResponseContext.jsonBody({'ok': true}),
      middleware: [bearerAuth((t) => t == 'secret')],
      doc: const OpenApiOperation(requiresAuth: ['bearer']));

  await api.serve(middleware: [requireAdmin]); // /openapi.json + /docs
}

Future<void> fragment22(NitroServer server) async {
  final shutdown = shutdownOnSignals(server,
      drain: const Duration(seconds: 15), onSignal: (s) => print('$s: draining'));
  await server.onClose;
  // or: await server.close(drain: const Duration(seconds: 15));
}

Future<void> fragment23(NitroServer server) async {
  server.events.listen((e) => print('${e.kind.name} #${e.requestId}: ${e.message}'));
  // started, stopped, handlerTimeout, clientError, clientDisconnect, notice (helper isolate
  // died, ...), handlerError (handler threw or produced an unsendable response; message has
  // verb, path, error, stack)
}

Future<void> fragment24(NitroServer server) async {
  print(serverBanner(
    title: 'my-api', version: '1.0.0', uri: server.uri,
    isolates: server.isolates, pid: pid, routes: server.routes,
    links: {'docs': '/docs', 'metrics': '/metrics'},
    facts: ['hot reload off'], logo: nitroServerAsciiLogo,
    color: stdout.supportsAnsiEscapes,
  ));
}

Future<void> fragment25(NitroServer server) async {
  loadNitroServerNative(path: '/opt/libs/libnitro_server.so');
  final server = await NitroServer.bindWith(port: 8080, dylibPath: '/opt/libs/libnitro_server.so');
}

Future<void> fragment26(NitroServer server) async {
  try {
    await NitroServer.bind(const ServerConfig(port: 80));
  } on ServerBindException catch (e) {
    print('cannot bind: ${e.message}');
  } on ServerTlsException catch (e) {
    print('TLS unavailable: ${e.message}');
  }
}
