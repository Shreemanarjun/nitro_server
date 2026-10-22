# nitro_server

HTTP/1.1 + HTTP/2 + WebSocket server for Dart and Flutter. Native C++ engine
(libuv, via [Nitro](https://pub.dev/packages/nitro) FFI) does accept / parse /
route / write on every core; handlers run in Dart. Client library:
[`nitro_http`](https://github.com/Shreemanarjun/nitro_http).

```dart
import 'package:nitro_server/nitro_server.dart';

Future<void> main() async {
  final server = await NitroServer.bind(); // 127.0.0.1, a free port
  await server.get('/hello', (_) => ResponseContext.text('hi 👋'));
  await server.get('/users/:id', (r) => ResponseContext.jsonBody({'id': r.param('id')}));
  await server.post('/echo', (r) => ResponseContext.bytes(r.body));
  print('listening on ${server.uri}');
}
```

Full entrypoint to copy: [`bin/server.dart`](bin/server.dart) (routes, OpenAPI,
metrics, dashboard, drain, hot reload, env config).

- [Install](#install)
- [Build from source](#build-from-source)
- [CLI](#cli)
- [Routes](#routes)
- [Request](#request)
- [Response](#response)
- [WebSocket](#websocket)
- [Middleware](#middleware)
- [Configuration](#configuration)
- [Production](#production)
- [Testing](#testing)
- [Hot reload](#hot-reload)
- [Native library](#native-library)
- [Exceptions](#exceptions)
- [Limits](#limits)
- [Performance](#performance)
- [Developing](#developing)

## Install

```sh
dart pub add nitro_server
```

- Released versions need no toolchain: the build hook downloads the prebuilt
  engine for your OS/arch and `dart build cli` bundles it.
- Prebuilts are self-contained (libuv, OpenSSL, brotli, nghttp2 linked in).
- Downloads are verified against `hook/prebuilt_checksums.json` (ships in the
  package). `NITRO_SERVER_VERIFY_SIGSTORE=1` also runs `cosign verify-blob`.
  `NITRO_SERVER_PREBUILT_BASE_URL` points at a mirror.
- Do not `dart compile exe` a nitro_server program (no build hook, no engine).
  Use `dart build cli` or the CLI below.

## Build from source

Needed for an unreleased version, an uncovered OS/arch, or
`NITRO_SERVER_BUILD_FROM_SOURCE=1`. Requires a C++17 compiler, CMake ≥ 3.10,
Dart ≥ 3.12.

| Library | Enables | Required |
|---------|---------|----------|
| libuv | reactor | yes |
| OpenSSL 3 | TLS (and h2 over TLS) | optional, auto-detected |
| libbrotli | `compress()` `br` | optional, auto-detected |
| nghttp2 | HTTP/2 (`-DNITRO_SERVER_HTTP2=ON`) | optional |

```sh
brew install cmake pkg-config libuv openssl@3 brotli nghttp2                                  # macOS
sudo apt-get install -y cmake pkg-config libuv1-dev libssl-dev libbrotli-dev libnghttp2-dev   # Debian/Ubuntu
vcpkg install libuv openssl brotli nghttp2 --triplet x64-windows                              # Windows

cmake -S src -B build/lib -DCMAKE_BUILD_TYPE=Release -DNITRO_SERVER_HTTP2=ON
cmake --build build/lib --parallel
```

CMake options:

| Option | Effect |
|--------|--------|
| `-DNITRO_SERVER_HTTP2=ON` | HTTP/2 (needs nghttp2) |
| `-DNITRO_SERVER_STATIC_DEPS=ON` | link libuv/OpenSSL/brotli/nghttp2 statically |
| `-DNITRO_SERVER_WERROR=ON` | warnings are errors |
| `-DNITRO_SERVER_SANITIZE=address\|thread\|undefined` | instrumented build |
| `-DOPENSSL_ROOT_DIR=…` | point at an OpenSSL |

Windows: use the vcpkg toolchain file and let CMake pick the generator (or
`-G Ninja`).

```powershell
cmake -S src -B build/lib -DCMAKE_BUILD_TYPE=Release -DNITRO_SERVER_HTTP2=ON `
  -DCMAKE_TOOLCHAIN_FILE="$env:VCPKG_INSTALLATION_ROOT/scripts/buildsystems/vcpkg.cmake" `
  -DVCPKG_TARGET_TRIPLET=x64-windows
cmake --build build/lib --config Release --parallel
```

Runtime checks: `brotliAvailable()`; `bind` throws `ServerTlsException` when
TLS is requested on an engine without OpenSSL.

## CLI

`dart run nitro_server:nitro <cmd>` (or `nitro <cmd>` after
`dart pub global activate nitro_server`).

| Command | Does |
|---------|------|
| `serve` | run `bin/server.dart`, JIT + hot reload |
| `serve <entry>` | another entrypoint |
| `serve --aot` | compile, then run |
| `build` | AOT bundle → `build/<name>/bundle/bin/<name>` (engine in `bundle/lib/`) |
| `build --jit` | kernel snapshot → `build/<name>.dill` |
| `build -o <path>` | output path |
| `build --bundle-deps` | copy native deps beside the exe |

```sh
dart run nitro_server:nitro serve                 # dev
dart run nitro_server:nitro build                 # prod: ./build/server/bundle/bin/server
docker build -t myapp . && docker run -p 8080:8080 -e ADMIN_USER=ops -e ADMIN_PASSWORD=... myapp
```

Deploy recipes (Fly.io, Render, Railway, Cloud Run, Kubernetes, Netlify):
[`doc/deployment.md`](doc/deployment.md).

## Routes

Snippets run inside `setup(NitroServer server)` or after
`final server = await NitroServer.bind(const ServerConfig(port: 8080));`.
Handlers may be sync or async. `await` registrations.

```dart
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
```

Controller class:

```dart
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

await server.mount(UserController());
```

Engine-served static responses (no handler, no middleware, no FFI):

```dart
await server.getStatic('/health', utf8.encode('ok'), contentType: 'text/plain');
await server.staticRoute(HttpMethod.get, '/version', utf8.encode('{"v":"1.0.0"}'),
    contentType: 'application/json', headers: {'cache-control': 'max-age=60'});
```

- Precedence: static segment > `:param` > `*`; method-specific > `all`; HEAD
  falls back to GET.
- Middleware order: server → group → route.
- Handler past `timeout` → 408. Throwing handler → 500 (or `errorHandler`).

## Request

```dart
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
```

Multipart:

```dart
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
```

Limits: `maxParts` 1000, `maxPartHeaderBytes` 8 KiB, boundary 1–70 chars; parts
are views into `r.body`.

Streaming upload (HTTP/1.1):

```dart
await server.post('/ingest', (r) async {
  var total = 0;
  await for (final chunk in r.bodyStream!) {
    total += chunk.length;
  }
  return ResponseContext.text('received $total bytes');
}, streamBody: true); // r.body is empty, r.bodyStream is set
```

## Response

All take `status:` and `headers:`.

```dart
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
```

Cookies and headers:

```dart
await server.get('/login', (_) => ResponseContext.text('ok')
    .withCookie(SetCookie('session', 'abc123',
        httpOnly: true, secure: true, sameSite: SameSite.lax,
        maxAge: const Duration(days: 7), path: '/'))
    .withHeader('cache-control', 'no-store'));
```

`copyWith(status:, headers:)` keeps a stream/file/cookies. A header or cookie
with CR/LF/NUL is never sent: 500 + `handlerError` event.

Server-Sent Events:

```dart
await server.get('/events', (_) => ResponseContext.sse(
  Stream.periodic(const Duration(seconds: 1),
      (i) => SseEvent('tick $i', event: 'tick', id: '$i')).take(10),
));
```

`SseEvent(data, {event, id, retry})`, `bufferSize:` batches writes. Send
something more often than `streamIdleTimeout` (5 min) or the stream is closed.

Problem details (RFC 7807):

```dart
await server.post('/orders', (r) {
  if (r.jsonMap()['email'] == null) {
    return ResponseContext.problem(
      title: 'Validation failed', status: 422, detail: 'email is required',
      type: 'https://example.com/errors/validation', extensions: {'field': 'email'},
    );
  }
  return ResponseContext.text('ok', status: 201);
});
```

Native JSON writer (encodes into the engine's buffer, no Dart string):

```dart
final kId = JsonToken('id'), kName = JsonToken('name'); // hoist interned keys

await server.get('/report', (_) => ResponseContext.jsonWriter((w) {
  w..beginObject()..key('ok')..writeBool(true)..key('rows')..beginArray();
  for (var i = 0; i < 3; i++) {
    w..beginObject()..keyToken(kId)..writeInt(i)..keyToken(kName)..writeString('row $i')..endObject();
  }
  w..endArray()..endObject();
}));
```

`writeInt/Double/Num/String/Bool/Null`, `writeValue(any)`, `writeRaw(fragment)`,
`keyToken`/`writeStringToken`. The `build` callback is synchronous.

## WebSocket

```dart
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
```

- `WsSession`: `handshake`, `messages` (`WsText` | `WsBinary`), `sendText`,
  `sendBytes`, `bufferedBytes`, `compressed`, `protocol`, `closeCode`,
  `close([code = 1000])`.
- Engine does the handshake, ping/pong, close codes, `permessage-deflate`.
- Server-global middleware does not run on WS routes. Use
  `ws(middleware: [...])`: a rejection closes with `4000 + status` (401 → 4401),
  `1008` for a non-4xx, `1011` if the middleware throws.
- `group.ws(...)` prepends the group's `use` list.

## Middleware

```dart
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
```

- `staticFiles`: etag, 304, byte ranges, `index.html`; `..`, encoded dots,
  NUL, symlinks out of the root and dotfiles are 404 (`dotfiles: true`,
  `followSymlinks: false` to change).
- Scope: `server.use` (server-wide), `group.use` (before its routes),
  `middleware: [...]` per route or `ws()`, controllers.
- `cors()` refuses `*` with credentials. `rateLimit` keys on the socket peer
  unless `trustedProxies` names the peer.

Custom middleware:

```dart
Middleware timing() => (request, next) async {
  final sw = Stopwatch()..start();
  final res = await next(request);
  return res.withHeader('x-elapsed-ms', '${sw.elapsedMilliseconds}');
};

final Middleware requireAdmin = (request, next) => request.header('x-role') == 'admin'
    ? next(request)
    : ResponseContext.text('forbidden', status: 403);

await server.use(timing());
await server.get('/admin', (_) => ResponseContext.text('hi'), middleware: [requireAdmin]);
```

Shared rate-limit store (default store is per isolate, bounded to `maxKeys`):

```dart
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

await server.use(rateLimit(
  maxRequests: 100,
  store: CountingStore(),
  keyExtractor: (r) => r.header('x-api-key') ?? r.clientIp,
  onLimit: (retryAfter) => ResponseContext.problem(title: 'Too many requests', status: 429),
));
```

JSON body validation:

```dart
final userSchema = ApiSchema.object({
  'name': ApiSchema.string(),
  'email': ApiSchema.string(format: 'email'),
  'age': ApiSchema.integer(nullable: true),
}, required: ['name', 'email']);

await server.post('/users', (r) => ResponseContext.jsonBody(r.jsonMap(), status: 201),
    middleware: [validateJsonBody(userSchema)]); // 400 bad JSON, 422 schema failure
```

`ApiSchema.string/integer/number/boolean/object/array/ref`, `schema.validate(v)`,
`toJson()`; `maxErrors` (100) caps the 422 list.

## Configuration

```dart
Future<void> setup(NitroServer server) async {
  await server.get('/report', (_) => ResponseContext.jsonBody({'ok': true}));
}

final server = await NitroServer.bind(
  const ServerConfig(port: 8080, isolates: 0),
  setup, // required when isolates != 1
);
```

| `ServerConfig` | default | meaning |
| -------------- | ------- | ------- |
| `host`, `port`, `backlog` | `127.0.0.1`, `0`, `128` | bind address (IPv6 and `::` ok), port (`0` = free), listen backlog |
| `isolates` | `1` | handler isolates; `0` = one per core (needs `setup`); raise for CPU-bound handlers |
| `workerThreads` | `0` | libuv loop threads; `0` = one per core |
| `defaultTimeout` | 30 s | handler deadline, 408 past it and the request is released; `Duration.zero` disables |
| `keepAliveTimeout`, `maxRequestsPerConnection` | 5 s, `100` | idle deadline between requests; requests per connection (`0` = unbounded) |
| `headerTimeout` | idle timeout | absolute deadline from the first byte of a request head / TLS handshake |
| `bodyTimeout` | keep-alive timeout | stall window for a request body still arriving: 408 |
| `writeTimeout` | 30 s | stalled write drops the connection (+ `clientError`); cannot be disabled |
| `streamIdleTimeout` | 5 min | streaming response with no write for this long is closed (+ `clientError`); `Duration.zero` disables |
| `maxConnectionAge` | `0` = unbounded | hard connection lifetime (HTTP/1.1 after its answer, WS 1001, h2 GOAWAY) |
| `wsIdleTimeout` | 60 s | WS pinged at half, closed 1001 at the full window; `Duration.zero` disables |
| `maxBodyBytes` | 10 MiB | request body cap, 413; per route via `maxBodyBytes:` |
| `maxBufferedBodyBytes` | 64 MiB | HTTP/2: request-body bytes one session holds across streams; over the remainder 503, never fits 413; ≥ `maxBodyBytes` |
| `maxConnections`, `maxConnectionsPerIp` | `0` = unlimited | refused at accept; per-IP follows the PROXY client when `proxyProtocol` |
| `maxInFlightRequests` | `0` = unlimited | dispatched-not-answered budget; 503 + `Retry-After: 1` past it |
| `wsMaxBufferBytes`, `wsCompression` | 1 MiB, `true` | WS queue bound each direction (1009 past it); `permessage-deflate` |
| `streamMaxBufferBytes` | 4 MiB | unsent bytes a streaming response may queue; connection dropped past it; `0` = unlimited |
| `exposeErrorDetails` | `false` | `true` puts the error text in the 500 body (dev only); details always go to `events` |
| `proxyProtocol` | `false` | expect a HAProxy PROXY v1/v2 header first; its address becomes `clientIp` |
| `responseTiming` | `true` | `Server-Timing: app;dur=<ms>` on handler answers |
| `tls` | none | `TlsConfig(certPem:/keyPem:` or `certFile:/keyFile:)`; `minVersion`, `ciphers`, `cipherSuites`, `clientCaPem:/clientCaFile:` (mutual TLS) |
| `protocol` | `HttpProtocol.http2` | `http1`, `http2` (ALPN `h2` + h2c, falls back to 1.1), `http3` (reserved) |

Memory per connection: one body (h1) or `maxBufferedBodyBytes` (h2) +
`streamMaxBufferBytes` / `wsMaxBufferBytes` + 64 KiB parse buffer. Multiply by
`maxConnections` for the server bound.

`config.copyWith(...)`; `bind` runs `config.validate()` (`ArgumentError`).

Environment:

```dart
final server = await NitroServer.bind(ServerConfig.fromEnv(Platform.environment), setup);
// HOST PORT BACKLOG ISOLATES WORKER_THREADS MAX_BODY_BYTES MAX_BUFFERED_BODY_BYTES MAX_CONNECTIONS
// MAX_CONNECTIONS_PER_IP MAX_REQUESTS_PER_CONNECTION MAX_IN_FLIGHT_REQUESTS MAX_CONNECTION_AGE_MS
// KEEP_ALIVE_TIMEOUT_MS DEFAULT_TIMEOUT_MS HEADER_TIMEOUT_MS WRITE_TIMEOUT_MS BODY_TIMEOUT_MS
// STREAM_IDLE_TIMEOUT_MS STREAM_MAX_BUFFER_BYTES WS_IDLE_TIMEOUT_MS WS_MAX_BUFFER_BYTES
// WS_COMPRESSION RESPONSE_TIMING EXPOSE_ERROR_DETAILS PROXY_PROTOCOL HTTP_PROTOCOL
// TLS_CERT_FILE+TLS_KEY_FILE | TLS_CERT_PEM+TLS_KEY_PEM TLS_MIN_VERSION (1.2|1.3)
// TLS_CIPHERS TLS_CIPHER_SUITES TLS_CLIENT_CA_FILE | TLS_CLIENT_CA_PEM
// A value that does not parse throws FormatException.
```

TLS:

```dart
final server = await NitroServer.bind(
  const ServerConfig(port: 8443, tls: TlsConfig(certFile: 'cert.pem', keyFile: 'key.pem')),
  setup,
);
server.reloadTls(const TlsConfig(certFile: 'renewed.pem', keyFile: 'renewed.key')); // no downtime
```

## Production

Observability:

```dart
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
```

- Aggregates across isolates: `await server.aggregatedMetrics()`;
  `server.metrics` is this isolate.
- `prometheusFormat(m)` / `metricsJson(m)` are renderers.
- Put `middleware:` on a public listener; `/metrics` reveals route names.

OpenAPI + Swagger UI:

```dart
await serveOpenApi(server, title: 'My API'); // spec from routes, Swagger UI at /docs
```

```dart
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
```

- `OpenApiParam.query/.header/.cookie`; `OpenApiRequestBody.json/.form/.multipart/.text/.binary`.
- Schemes: `bearerScheme()`, `apiKeyScheme()`, `basicScheme()`, `oauth2Scheme()`,
  `openIdConnectScheme()`.
- Swagger UI pinned (`swaggerUiPinnedVersion` 5.17.14) with SRI + CSP.

Shutdown:

```dart
final shutdown = shutdownOnSignals(server,
    drain: const Duration(seconds: 15), onSignal: (s) => print('$s: draining'));
await server.onClose;
// or: await server.close(drain: const Duration(seconds: 15));
```

Events:

```dart
server.events.listen((e) => print('${e.kind.name} #${e.requestId}: ${e.message}'));
// started, stopped, handlerTimeout, clientError, clientDisconnect, notice (helper isolate
// died, ...), handlerError (handler threw or produced an unsendable response; message has
// verb, path, error, stack)
```

Banner:

```dart
print(serverBanner(
  title: 'my-api', version: '1.0.0', uri: server.uri,
  isolates: server.isolates, pid: pid, routes: server.routes,
  links: {'docs': '/docs', 'metrics': '/metrics'},
  facts: ['hot reload off'], logo: nitroServerAsciiLogo,
  color: stdout.supportsAnsiEscapes,
));
```

## Testing

`package:nitro_server/testing.dart`: the real runner in memory, no sockets, no
native library.

```dart
import 'package:nitro_server/nitro_server.dart';
import 'package:nitro_server/testing.dart';
import 'package:test/test.dart';

void main() {
  test('routes and websocket', () async {
    final client = await NitroTestClient.start();
    final s = client.server;
    await s.get('/users/:id', (r) => ResponseContext.text('u${r.param('id')}'));
    await s.post('/echo', (r) => ResponseContext.jsonBody(r.jsonMap()));
    await s.ws('/ws', (session) async {
      await for (final m in session.messages) {
        if (m is WsText) session.sendText('echo: ${m.text}');
      }
    });

    expect((await client.get('/users/42')).text(), 'u42');

    final posted = await client.post('/echo',
        body: {'a': 1}, headers: {'content-type': 'application/json'});
    expect(posted.status, 200);
    expect(posted.json(), {'a': 1});

    final ws = await client.ws('/ws');
    ws.sendText('hi');
    expect((await ws.messages.first).text, 'echo: hi');
    await ws.close();

    await client.close();
  });
}
```

Not enforced in memory: route timeouts, `maxBodyBytes`; `clientIp` is `''`,
`port` is 0.

## Hot reload

```dart
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
```

- `server.reload([setup])` swaps the whole routing surface on the live socket.
- Needs `hotreloader` in `dev_dependencies` and
  `dart run --enable-vm-service`; throws under AOT.
- `setup` must be a top-level or static function.

## Native library

Search order: explicit path → `NITRO_SERVER_DYLIB` → beside the executable
(`lib/`, `../lib/`) → `.dart_tool/lib` → `build/lib` → `build/`.

```dart
loadNitroServerNative(path: '/opt/libs/libnitro_server.so');
final server = await NitroServer.bindWith(port: 8080, dylibPath: '/opt/libs/libnitro_server.so');
```

## Exceptions

```dart
try {
  await NitroServer.bind(const ServerConfig(port: 80));
} on ServerBindException catch (e) {
  print('cannot bind: ${e.message}');
} on ServerTlsException catch (e) {
  print('TLS unavailable: ${e.message}');
}
```

- `NitroServerException` subclasses: `ServerBindException`,
  `ServerTlsException`, `ServerAlreadyRunningException`,
  `ServerNotRunningException`, `RouteNotFoundException`,
  `ServerBadRequestException`, `HandlerTimeoutException`,
  `ServerUnknownException`.
- `ArgumentError`: bad pattern/prefix, `isolates > 1` without `setup`,
  `config.validate()`, `cors()` wildcard + credentials, `rateLimit` limits.
- `StateError`: `reload` without a setup, missing dylib, helper isolate that
  never starts. `FormatException`: `json*()`, `multipart()`, `fromEnv`.
- A throwing handler answers `500 internal server error`; details go to
  `events` (`handlerError`).

## Limits

- Platforms: iOS (foreground), Android (foreground service), macOS, Linux,
  Windows. No web.
- HTTP/3 not implemented; terminate it at a proxy.
- TLS/brotli are build-time (prebuilts have both).
- Not serverless: a persistent process.
- `metrics` and the default rate-limit store are per isolate (use a shared
  `RateLimitStore`).
- `getStatic`/`staticRoute` answers never reach Dart: no auth, no logging, no
  rate limit.
- HTTP/2 request bodies are buffered (up to the route's `maxBodyBytes`), not
  streamed; `streamBody` is HTTP/1.1 only.
- Client addresses come from the socket; `X-Forwarded-For` only with
  `trustedProxies`; behind an L4 balancer use `proxyProtocol`.
- `close(drain:)`: new connections get 503, h2 gets GOAWAY; a connection still
  in the kernel backlog at final close may be reset.
- Helper isolates: one that misses `NitroServer.helperTimeout` (10 s) or dies
  is killed, detached, reported (`notice`, `/readyz` 503).

## Performance

`benchmark/blackbox/run.sh`: every framework an opaque HTTP server, `oha` at
64 keep-alive connections, 3 server cores each, load generator on other cores,
medians of interleaved reps, responses byte-validated. Linux container on
Apple Silicon, nitro 0.8.0, 2026-10-22, final engine, 5 reps. `nitro` =
`_dylib` build; `@Native` within 4% on every route. Hardening cost vs the
pre-audit tree, same run (`--base`): 1–4% on light routes (widest
-5.7% on `/q?a=1&b=two`), none on `/work`.

| framework | configuration |
|-----------|---------------|
| nitro | `isolates: 3` |
| go | `net/http`, `GOMAXPROCS=3` |
| node | `http` + `cluster`, 3 workers |
| dart:io | `HttpServer`, 3 isolates (`SO_REUSEPORT`) |
| shelf | `shelf_io.serve`, 3 isolates |

Throughput (req/s, median; **bold** = fastest):

| route | nitro | go | node | dart:io | shelf |
|-------|------:|---:|-----:|--------:|------:|
| `/json` (light I/O)¹ | 166k | **220k** | 150k | 71k | 61k |
| `/work` (encode 200 JSON records)² | 46k | 17k | **54k** | 8.6k | 8.4k |
| `/echo` (4 KB body) | 99k | 80k | **110k** | 64k | 46k |
| `/static` (engine fast-path)³ | **455k** | 223k | 148k | 75k | 61k |

¹ `/hello`, `/q`, `/users`, `/files`, `/mw` are within ~5% of `/json`.
² per-request encode on every framework.
³ nitro answers from the engine (`getStatic`); the others run a handler.

Tail latency, `/work` (ms, median; **bold** = best p99):

| framework | p50 | p90 | p99 | p50:p99 |
|-----------|----:|----:|----:|--------:|
| node | 1.05 | 1.52 | **3.59** | 3.4× |
| nitro | 1.21 | 2.56 | 4.11 | 3.4× |
| dart:io | 7.27 | 9.18 | 11.36 | 1.6× |
| shelf | 7.39 | 10.33 | 13.54 | 1.8× |
| go | 0.93 | 10.89 | 21.18 | 22.7× |

Peak RSS (whole workload; **bold** = lowest):

| framework | nitro | go | node | dart:io | shelf |
|-----------|------:|---:|-----:|--------:|------:|
| peak RSS | 151 MB | **12 MB** | 391 MB | 53 MB | 51 MB |

nitro = 3 isolate heaps + the engine; a single-isolate server is ~30–50 MB.
Full report of this run: `benchmark/blackbox/REPORT.md`. A/B of two nitro
builds: `run.sh --base <git-ref>` (see `benchmark/BENCHMARKING.md`).

## Developing

```sh
cmake -S src -B build/lib -DCMAKE_BUILD_TYPE=Release -DNITRO_SERVER_BUILD_TESTS=ON -DNITRO_SERVER_HTTP2=ON
cmake --build build/lib --parallel
./build/lib/nitro_server_tests/nitro_server_engine_tests   # C++ suite
dart test                                                  # Dart suites
bash tool/coverage.sh                                      # Dart 100% line gate
bash tool/cpp_coverage.sh 90                               # engine line gate
bash tool/fuzz.sh 60                                       # libFuzzer targets
run-clang-tidy -p build/tidy src/engine/*.cpp              # .clang-tidy
```

- Bridge spec: `lib/src/nitro_server.native.dart`; regenerate with
  `dart run build_runner build` + `nitrogen link`. Never edit `*.g.*`.
- CI (`ci.yml`): suites, both coverage gates, ASan/TSan (leak detection on
  Linux), fuzz smoke, clang-tidy, Docker build + `/readyz` + Trivy, h2spec
  (floor 136/146), Autobahn (0 FAILED). `soak.yml`: nightly 10-minute memory
  soak. `release.yml`: suites → prebuilts with Sigstore provenance, keyless
  cosign bundle, SPDX SBOM → `verify` job locks and re-verifies them
  (`tool/update_prebuilt_lock.sh`, `tool/verify_prebuilt_lock.dart`); commit
  the lock before `dart pub publish`.
- Audit record: [`doc/production-audit.md`](doc/production-audit.md).
