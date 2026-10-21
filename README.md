# nitro_server

Production HTTP/1.1 + HTTP/2 + WebSocket server for Dart and Flutter. A native,
multithreaded C++ engine (libuv, via [Nitro](https://pub.dev/packages/nitro)
FFI) accepts, parses, routes and writes on every CPU core; handlers run on the
Dart isolate. Client counterpart:
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

> **Production starting point:** copy [`bin/server.dart`](bin/server.dart) — a
> complete entrypoint with every route type, OpenAPI + Swagger UI, `/metrics` +
> live dashboard, graceful drain and hot reload; reads `HOST`/`PORT` from the env.

## Contents

- [Features](#features)
- [Installation](#installation)
- [Commands (nitro CLI)](#commands-nitro-cli)
- [Build and run](#build-and-run)
- [How it works](#how-it-works)
- [Routes](#routes) — Express-style · class-based controllers · engine-served
- [Request](#request) — params, query, headers, cookies, body · multipart · streaming
- [Response](#response) — types · cookies & headers · SSE · problem+json · native JSON
- [WebSocket](#websocket)
- [Middleware](#middleware) — built-in · custom · shared rate-limit store · JSON validation
- [Configuration (ServerConfig)](#configuration-serverconfig) — table · from env · TLS
- [Production](#production) — observability · OpenAPI · shutdown · events · banner
- [Testing](#testing)
- [Hot reload](#hot-reload)
- [Native library loading](#native-library-loading)
- [Exceptions](#exceptions)
- [Platforms and limitations](#platforms-and-limitations)
- [Performance](#performance)
- [Developing](#developing)

## Features

- HTTP/1.1 (keep-alive, pipelining, `Expect: 100-continue`, chunked uploads),
  HTTP/2 (ALPN `h2` + h2c, runtime-selectable) and RFC 6455 WebSocket, all in
  the native engine. Engine-served static responses (no handler, no FFI).
- Trie routing: `:param`, trailing `*`, custom verbs, prefixed groups, class-based
  controllers.
- Responses: text/JSON/HTML/bytes/redirect/file (`sendfile`)/stream, Server-Sent
  Events, RFC 7807 problem+json, a native zero-copy JSON writer.
- Middleware: CORS, gzip/brotli, access log, request IDs, rate limit (pluggable
  store), bearer/API-key/basic auth, JSON-schema body validation, static files.
- Observability: Prometheus `/metrics`, `/healthz`, `/readyz`, live dashboard,
  server event stream. OpenAPI 3.1 + Swagger UI generated from the routes.
- `Server-Timing` per answer; graceful drain; transactional hot reload; TLS with
  zero-downtime cert rotation.
- Typed public API (no `dynamic`); in-memory test client (HTTP + WebSocket).

## Installation

```sh
dart pub add nitro_server
```

Released versions need **no toolchain**. A native-assets build hook
([`hook/build.dart`](hook/build.dart)) downloads the prebuilt engine for your
OS+arch from the matching GitHub release (SHA-256 verified); `dart build cli`
bundles it beside the executable. The prebuilts are **self-contained**
(libuv/OpenSSL/brotli/nghttp2 statically linked, all protocols compiled in) — a
consumer needs **no cmake and no system libraries**.

### Build from source

Only needed on an unreleased version, an OS/arch the release does not cover, or
with `NITRO_SERVER_BUILD_FROM_SOURCE=1`. Needs a **C++17 compiler**,
**CMake ≥ 3.10**, and Dart ≥ 3.12 (or Flutter ≥ 3.10), plus native libs
(auto-detected: present → enabled, absent → skipped):

| Library | Enables | Required |
|---------|---------|----------|
| **libuv** | reactor I/O core | **yes** (build fails without it) |
| OpenSSL 3 | TLS / HTTPS (and h2 over TLS) | optional |
| libbrotli | `compress()` `br` encoding (else gzip) | optional |
| nghttp2 | HTTP/2 (also pass `-DNITRO_SERVER_HTTP2=ON`) | optional |

```sh
# 1. install deps
brew install cmake pkg-config libuv openssl@3 brotli nghttp2                                  # macOS
sudo apt-get install -y cmake pkg-config libuv1-dev libssl-dev libbrotli-dev libnghttp2-dev   # Debian/Ubuntu
vcpkg install libuv openssl brotli nghttp2 --triplet x64-windows                              # Windows (+vcpkg toolchain)

# 2. build the engine (TLS/brotli auto-enable from the libs; the flag adds HTTP/2)
cmake -S src -B build/lib -DCMAKE_BUILD_TYPE=Release -DNITRO_SERVER_HTTP2=ON
cmake --build build/lib --parallel
```

Minimal build (HTTP/1.1 + WebSocket, no TLS/brotli/h2) needs only libuv.
Detection order: `pkg-config` → CMake config → Homebrew prefix; override with
`-DOPENSSL_ROOT_DIR=…` or `PKG_CONFIG_PATH`.

### Enabling TLS, brotli, gzip, HTTP/2

Prebuilt engines ship with **all of these on**; this matters only when building
from source. Nothing is a `-D` switch except HTTP/2 and static linking:

| feature | build time | runtime |
|---------|------------|---------|
| **TLS / HTTPS** | auto — `find_package(OpenSSL)` found → compiled in (`-DOPENSSL_ROOT_DIR=…` to point at one). There is no `NITRO_SERVER_TLS` option | `ServerConfig(tls: TlsConfig(...))`; `bind` throws `ServerTlsException` if the engine lacks it |
| **brotli** | auto — `pkg-config libbrotlienc` found → compiled in | `compress()` sends `br` when `brotliAvailable()` and the client accepts it; `brotliQuality:` 0–11 (default 4) |
| **gzip** | always (dart:io zlib) | `compress()` fallback; `level:` 1–9 (default 1 = fastest) |
| **HTTP/2** | **`-DNITRO_SERVER_HTTP2=ON`** + nghttp2 — configure fails if nghttp2 is missing. Off by default from source; the build hook and prebuilts pass it | `ServerConfig(protocol:)` — `http2` (default: ALPN `h2` + h2c) or `http1` |
| static deps | `-DNITRO_SERVER_STATIC_DEPS=ON` links libuv/OpenSSL/brotli/nghttp2 into the engine | — |

Check a built engine from Dart with `brotliAvailable()`; TLS and the `protocol`
cap surface as `bind` errors.

**Windows.** Configure with the vcpkg toolchain and **let CMake pick the
generator** — do not pass `-G "Visual Studio 17 2022"` unless that exact VS is
installed, or configure fails with *could not find any instance of Visual
Studio* (CI never hard-codes one):

```powershell
vcpkg install libuv openssl brotli nghttp2 --triplet x64-windows
cmake -S src -B build/lib -DCMAKE_BUILD_TYPE=Release -DNITRO_SERVER_HTTP2=ON `
  -DCMAKE_TOOLCHAIN_FILE="$env:VCPKG_INSTALLATION_ROOT/scripts/buildsystems/vcpkg.cmake" `
  -DVCPKG_TARGET_TRIPLET=x64-windows
cmake --build build/lib --config Release --parallel
```

No Visual Studio at all? Install the *Desktop development with C++* workload
(Build Tools suffice) or use `-G Ninja` with `ninja` on `PATH`.

## Commands (nitro CLI)

`dart run nitro_server:nitro <cmd>` (or `nitro <cmd>` after
`dart pub global activate nitro_server`):

| Command | Does |
|---------|------|
| `serve` | run `bin/server.dart`, JIT + hot reload (VM service) |
| `serve <entry>` | run a different entrypoint |
| `serve --aot` | compile, then run (prod-like) |
| `build` | AOT bundle via `dart build cli` → `build/<name>/bundle/bin/<name>` (engine in `bundle/lib/`) |
| `build --jit` | kernel snapshot → `build/<name>.dill` (run: `dart build/<name>.dill`) |
| `build -o <path>` | custom output path |
| `build --bundle-deps` | AOT exe + native deps copied beside it, load paths rewritten (self-contained) |

`serve` wraps `dart run --enable-vm-service`; `build` wraps `dart build cli`
(AOT bundle) or `dart compile kernel` (`--jit`). **Do not `dart compile exe`** a
nitro_server program: it skips the build hook, so the `@Native` bridge has no
engine asset — it only appears to work on macOS (process-wide `dlopen`) and fails
on Linux/Windows. `dart build cli` is the equivalent that bundles the engine.

## Build and run

```sh
# dev — hot reload on
dart run nitro_server:nitro serve

# production — AOT
dart run nitro_server:nitro build      # -> build/server/bundle/bin/server (+ bundle/lib/libnitro_server.*)
./build/server/bundle/bin/server       # runs from any working directory

# self-contained — no system libs on the target host
dart run nitro_server:nitro build --bundle-deps

# container — engine + deps baked in
docker build -t myapp .
docker run -p 8080:8080 myapp
```

AOT has no hot reload. Move the whole `bundle/` directory (the engine lives in
`bundle/lib/`); `--bundle-deps` adds the system deps there too. Deploy recipes (Fly.io, Render, Railway, Cloud Run,
Kubernetes, Netlify): [`doc/deployment.md`](doc/deployment.md).

## How it works

A **libuv reactor** runs one event loop per CPU core, each with its own
`SO_REUSEPORT` listener, so a few loop threads serve thousands of keep-alive
connections. Each loop parses, trie-matches, hands the request to a Dart
isolate, then writes the answer (`sendfile` for files). **Adaptive dispatch**
spreads work across only as many `isolates` as raise throughput — so leave
`isolates` at `1` for IO-bound work and raise it (or `isolates: 0`) for
CPU-bound handlers.

---

Snippets below run inside a `setup(NitroServer server)` function or after
`final server = await NitroServer.bind(const ServerConfig(port: 8080));`.
Handlers may be sync or async (`FutureOr`); registration calls return a
`Future` — `await` them. Imports used: `dart:convert`, `dart:io`,
`dart:typed_data`, `package:nitro_server/nitro_server.dart`.

## Routes

Two styles, same router — the fluent **Express-style** API, or a **`Controller`**
class for larger apps. Mix freely.

### Express-style (fluent)

```dart
// Verbs + :param + trailing * capture
await server.get('/users/:id', (r) => ResponseContext.text('user ${r.param('id')}'));
await server.post('/upload/*', (r) => ResponseContext.text('${r.body.length} bytes'),
    maxBodyBytes: 50 * 1024 * 1024);
await server.put('/items/:id', (r) => ResponseContext.jsonBody(r.jsonMap()));
await server.delete('/items/:id', (r) => ResponseContext.text('', status: 204));
await server.all('/ping', (_) => ResponseContext.text('pong')); // every method

// Custom verb, per-route middleware and timeout
await server.route(HttpMethod.custom, '/items', (_) => ResponseContext.text('report'),
    customMethod: 'REPORT');
await server.get('/slow', (_) => ResponseContext.text('done'),
    timeout: const Duration(seconds: 5)); // 408 past the deadline

// Prefixed group with its own middleware (call `use` BEFORE registering routes)
final api = server.group('/api/v1');
await api.use(cors());
await api.get('/ping', (_) => ResponseContext.text('pong')); // GET /api/v1/ping
final v2 = api.group('/v2');                                  // nested: /api/v1/v2/...

// Fallbacks
server.notFoundHandler = (r) => ResponseContext.text('no ${r.path}', status: 404);
server.errorHandler = (e, r) => ResponseContext.text('oops: $e', status: 500);

// Remove a route on a live server
await server.unroute(HttpMethod.get, '/slow');
```

### Class-based (controllers)

Group related routes behind a shared prefix + middleware; handlers are methods
that share the controller's fields (injected deps) — the nitro_server analogue
of a Spring `@RestController`, with no annotations and no codegen (AOT-safe).

```dart
import 'package:nitro_server/nitro_server.dart';

class UserController extends Controller {
  UserController() : super(prefix: '/users', middleware: [cors()]);
  final _users = <String, Object?>{'42': 'Ada'};

  @override
  Future<void> register(RouteGroup on) async {
    await on.get('/', (_) => ResponseContext.jsonBody(_users)); // GET  /users
    await on.get('/:id', getOne); //                               GET  /users/:id
    await on.post('/', create); //                                 POST /users
  }

  ResponseContext getOne(RequestContext c) =>
      ResponseContext.jsonBody({c.param('id'): _users[c.param('id')]});

  ResponseContext create(RequestContext c) {
    final body = c.jsonMap();
    _users['${body['id']}'] = body['name'];
    return ResponseContext.jsonBody(body, status: 201);
  }
}

Future<void> main() async {
  final server = await NitroServer.bind(const ServerConfig(port: 8080));
  await server.mount(UserController()); // mounts chain: (await a).mount(b)
  print('listening on ${server.uri}');
}
```

### Engine-served static responses

Answered by the native engine with no handler, no middleware and no FFI
round-trip — the `/static` fast path in [Performance](#performance). Use it for
health strings, version blobs, cached fragments.

```dart
await server.getStatic('/health', utf8.encode('ok'), contentType: 'text/plain');
await server.staticRoute(HttpMethod.get, '/version', utf8.encode('{"v":"1.0.0"}'),
    contentType: 'application/json', headers: {'cache-control': 'max-age=60'});
```

Precedence: static segment > `:param` > `*`; method-specific > `all`; HEAD falls
back to GET. Middleware order: server-wide → group → per-route. A handler past
its `timeout` → 408; a throwing handler → 500 (or your `errorHandler`).

## Request

### Reading the request

```dart
await server.post('/users/:id', (r) {
  r.method; //                HttpMethod.post   (r.customMethod for custom verbs)
  r.path; //                  '/users/42'       (r.routePattern = '/users/:id')
  r.param('id'); //           '42'              (r.params)
  r.queryParam('page'); //    ?page=2 → '2'     (r.queryParameters; r.queryParamAll / queryParametersAll for repeats)
  r.header('x-request-id'); //first value, case-insensitive (r.headers: Map<String, List<String>>)
  r.cookies['session']; //    parsed `cookie` header
  r.clientIp; //              peer address ('' when unavailable)
  r.body; //                  Uint8List
  r.text(); //                UTF-8 string
  final m = r.jsonMap(); //   Map<String, Object?>   — also r.jsonList(), r.json(), r.jsonAs<T>()
  return ResponseContext.jsonBody({'id': r.param('id'), 'got': m});
});
```

`jsonAs<T>()` decodes then checks `is T` — `T` is a JSON type the decoder yields
(`Map<String, Object?>`, `List<Object?>`, `String`, `int`…), not a model class;
a mismatch throws `FormatException`.

### Multipart uploads

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

### Streaming request bodies

```dart
await server.post('/ingest', (r) async {
  var total = 0;
  await for (final chunk in r.bodyStream!) {
    total += chunk.length; // process as it arrives — nothing is buffered
  }
  return ResponseContext.text('received $total bytes');
}, streamBody: true); // r.body is empty, r.bodyStream is set
```

## Response

### Response types

Return any of these from a handler; all take `status:` and `headers:`.

```dart
ResponseContext.text('hi'); //                                   text/plain; charset=utf-8
ResponseContext.text('<b>hi</b>', contentType: 'text/html');
ResponseContext.html('<h1>hi</h1>');
ResponseContext.jsonBody({'ok': true, 'n': [1, 2]}); //          any JSON-encodable, single-pass UTF-8
ResponseContext.jsonMap({'ok': true}); //                        Map only
ResponseContext.json('{"pre":"encoded"}'); //                    an already-encoded string
ResponseContext.bytes(Uint8List(0), contentType: 'image/png');
ResponseContext.redirect('/login'); //                           302; status: 301/303/307/308
ResponseContext.file('report.pdf', contentType: 'application/pdf'); // sendfile; offset:/length: for ranges
ResponseContext.stream(Stream.value(Uint8List(0)), contentType: 'text/csv'); // chunked; bufferSize: 65536
ResponseContext.text('created', status: 201, headers: {'location': '/items/7'});
```

### Cookies and headers

```dart
await server.get('/login', (_) => ResponseContext.text('ok')
    .withCookie(SetCookie('session', 'abc123',
        httpOnly: true, secure: true, sameSite: SameSite.lax,
        maxAge: const Duration(days: 7), path: '/'))
    .withHeader('cache-control', 'no-store'));
```

`copyWith(status:, headers:)` changes status/headers while keeping a stream,
file or cookies intact — use it in middleware instead of rebuilding a response.

### Server-Sent Events

```dart
await server.get('/events', (_) => ResponseContext.sse(
  Stream.periodic(const Duration(seconds: 1),
      (i) => SseEvent('tick $i', event: 'tick', id: '$i')).take(10),
)); // text/event-stream, cache-control: no-cache
```

`SseEvent(data, {event, id, retry})`; `bufferSize:` batches writes.

### Problem details (RFC 7807)

```dart
await server.post('/orders', (r) {
  if (r.jsonMap()['email'] == null) {
    return ResponseContext.problem(
      title: 'Validation failed', status: 422, detail: 'email is required',
      type: 'https://example.com/errors/validation', extensions: {'field': 'email'},
    ); // application/problem+json
  }
  return ResponseContext.text('ok', status: 201);
});
```

### Native JSON fast path

Encodes straight into a pooled native buffer the engine writes from — no Dart
`String`/`List` materialization. The `build` callback is synchronous.

```dart
final kId = JsonToken('id'), kName = JsonToken('name'); // interned keys, hoist once

await server.get('/report', (_) => ResponseContext.jsonWriter((w) {
  w..beginObject()..key('ok')..writeBool(true)..key('rows')..beginArray();
  for (var i = 0; i < 3; i++) {
    w..beginObject()..keyToken(kId)..writeInt(i)..keyToken(kName)..writeString('row $i')..endObject();
  }
  w..endArray()..endObject();
}));
```

`writeInt/Double/Num/String/Bool/Null`, `writeValue(any)` walks a Map/List,
`writeRaw(fragment)` splices pre-encoded JSON, `keyToken`/`writeStringToken` for
interned strings. This is the path behind the `/work` numbers in
[Performance](#performance).

## WebSocket

```dart
await server.ws('/chat', (session) async {
  print('subprotocol: ${session.protocol}'); // negotiated, or null
  print('user: ${session.handshake.header('x-user')}'); // the upgrade request

  await for (final m in session.messages) {
    if (m is WsText) {
      session.sendText('echo: ${m.text}'); // returns queued bytes: 0 = on the wire, -1 = closed
    } else if (m is WsBinary) {
      session.sendBytes(m.bytes);
    }
    if (session.bufferedBytes > 1 << 20) await session.close(1009); // slow consumer
  }
  // returning (or throwing) closes the session; session.closeCode = the peer's code
}, protocols: ['chat.v1'], middleware: [bearerAuth((t) => t == 'secret')]); // gates the handshake
```

`WsSession`: `handshake` (the upgrade `RequestContext`), `messages`
(`WsText` | `WsBinary`), `sendText`/`sendBytes`, `bufferedBytes`, `compressed`
(`permessage-deflate` negotiated; frames ≥ 256 B compressed), `protocol`,
`closeCode`, `close([code = 1000])`. The engine handles the RFC 6455 handshake,
ping/pong and close codes. `group.ws(...)` takes the same `protocols:` and
`middleware:` and prepends the group's `use` list.

**Middleware on WebSocket routes.** Server-global middleware does not wrap WS
handlers (the engine completes the upgrade before dispatch), so
`ws(middleware: [...])` runs a chain against the handshake *before* your
handler — reuse `bearerAuth`/`apiKeyAuth`/`basicAuth` or any custom middleware
unchanged. The 101 is already on the wire, so a short-circuit cannot become an
HTTP status: the socket closes with **`4000 + status`** (401 → 4401,
403 → 4403 — the app range) or **1008** for a non-4xx, **1011** if the
middleware throws, and the handler never runs. Read it client-side from the
close code.

## Middleware

### Built-in

```dart
await server.use(accessLog()); //                      method · status · latency · path · ip  (json: true → JSON lines)
await server.use(requestId()); //                      x-request-id in/out  (generator: () => ...)
await server.use(cors(allowOrigin: 'https://example.com', allowCredentials: true));
await server.use(compress(minBytes: 1024, level: 1, brotliQuality: 4)); // br if built in + accepted, else gzip
await server.use(rateLimit(maxRequests: 100, window: const Duration(minutes: 1))); // 429 + Retry-After
await server.use(bearerAuth((token) => token == 'secret', realm: 'api'));
await server.use(apiKeyAuth((key) => key == 'k', headerName: 'x-api-key'));
await server.use(basicAuth((user, pass) => user == 'admin' && pass == 'pw'));

// Static files are a HANDLER on a wildcard route, not middleware:
await server.get('/assets/*', staticFiles('web', maxAge: const Duration(hours: 1)));
// sendfile · etag · 304 · byte ranges (206/416) · index.html · `..` traversal → 404
```

Scope: server-wide (`server.use`, outermost first), per group (`group.use`,
before registering its routes), per route (`middleware: [...]`, on HTTP routes
and `ws()` alike), per controller. Verifier callbacks may be async.

### Custom middleware

```dart
// Signature: FutureOr<ResponseContext> Function(RequestContext request, RequestHandler next)
Middleware timing() => (request, next) async {
  final sw = Stopwatch()..start();
  final res = await next(request); // continue the chain; return early to short-circuit
  return res.withHeader('x-elapsed-ms', '${sw.elapsedMilliseconds}');
};

final Middleware requireAdmin = (request, next) => request.header('x-role') == 'admin'
    ? next(request)
    : ResponseContext.text('forbidden', status: 403);

await server.use(timing());
await server.get('/admin', (_) => ResponseContext.text('hi'), middleware: [requireAdmin]);
```

### Shared rate-limit store

The default `InMemoryRateLimitStore` is per isolate (effective limit =
`maxRequests × isolates`). Implement `RateLimitStore` over Redis/etc. to share
one counter across isolates and replicas:

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

### JSON body validation

```dart
final userSchema = ApiSchema.object({
  'name': ApiSchema.string(),
  'email': ApiSchema.string(format: 'email'),
  'age': ApiSchema.integer(nullable: true),
}, required: ['name', 'email']);

await server.post('/users', (r) => ResponseContext.jsonBody(r.jsonMap(), status: 201),
    middleware: [validateJsonBody(userSchema)]); // 400 bad JSON · 422 schema failure (problem+json); body-bearing routes only, not streamBody
```

`ApiSchema.string/integer/number/boolean/object/array/ref`; `schema.validate(v)`
returns the error list for manual use; `toJson()` is OpenAPI-compatible.

## Configuration (ServerConfig)

Pass to `bind` (positional); register routes in a `setup` function (required
when `isolates != 1`, so every isolate builds the same routes):

```dart
Future<void> setup(NitroServer server) async {
  await server.get('/report', (_) => ResponseContext.jsonBody({'ok': true}));
}

final server = await NitroServer.bind(
  const ServerConfig(port: 8080, isolates: 0),
  setup,
);
```

| `ServerConfig` | default | meaning |
| -------------- | ------- | ------- |
| `host`, `port`, `backlog` | `127.0.0.1`, `0`, `128` | bind address (IPv6 literals and `::` supported), port (`0` = free), listen backlog |
| `defaultTimeout` | 30 s | handler deadline; 408 on expiry |
| `keepAliveTimeout`, `maxRequestsPerConnection` | 5 s, `100` | idle deadline between requests (`Duration.zero` disables keep-alive); requests per connection (`0` = unbounded) |
| `maxBodyBytes` | 10 MiB | request body cap, 413 above it; per route via `maxBodyBytes:` |
| `headerTimeout` | idle timeout | deadline for a new connection's first request head |
| `writeTimeout` | 30 s | a stalled write drops the connection and emits `clientError` |
| `maxConnections`, `maxConnectionsPerIp` | `0` = unlimited | refused at accept |
| `workerThreads` | `0` | caps the libuv event-loop threads; `0` = one per core |
| `isolates` | `1` | Dart isolates for handlers (`1` is optimal for IO-bound — the engine already uses every core); `0` = auto (one per core, 1–32) with a `setup`, else `1`; raise for CPU-bound. Each runs `setup`; adaptive dispatch uses only as many as help |
| `wsMaxBufferBytes`, `wsCompression` | 1 MiB, `true` | WebSocket send queue before a 1009 close; negotiate `permessage-deflate` |
| `responseTiming` | `true` | add `Server-Timing: app;dur=<ms>` to every handler answer; `false` shaves one string per response at peak throughput |
| `tls` | none | `TlsConfig(certPem:, keyPem:)` or `certFile`/`keyFile`; throws `ServerTlsException` unless the engine was built with OpenSSL |
| `protocol` | `HttpProtocol.http2` | highest HTTP version to negotiate: `http1` (1.1 only), `http2` (adds `h2` via ALPN/h2c, falls back to 1.1), `http3` (reserved). Caps at what the engine was built with |

`config.copyWith(...)` tweaks a config; `server.config` is the resolved one.

### From the environment

```dart
final server = await NitroServer.bind(ServerConfig.fromEnv(Platform.environment), setup);
// HOST PORT ISOLATES WORKER_THREADS MAX_BODY_BYTES MAX_CONNECTIONS MAX_CONNECTIONS_PER_IP
// KEEP_ALIVE_TIMEOUT_MS DEFAULT_TIMEOUT_MS RESPONSE_TIMING WS_COMPRESSION HTTP_PROTOCOL
```

### TLS

```dart
final server = await NitroServer.bind(
  const ServerConfig(port: 8443, tls: TlsConfig(certFile: 'cert.pem', keyFile: 'key.pem')), // or certPem:/keyPem:
  setup,
); // server.uri is https://…; h2 via ALPN when protocol is http2

server.reloadTls(const TlsConfig(certFile: 'renewed.pem', keyFile: 'renewed.key')); // zero-downtime; returns false if unavailable
```

Needs the engine built with OpenSSL (prebuilts include it); otherwise `bind`
throws `ServerTlsException`.

## Production

### Observability

```dart
var dbReady = false;
await serveObservability(server,
    ready: () => dbReady, //  /readyz 503 while false — REPLACES the default (ready until close()), so drain-awareness is yours
    dashboardPath: null, //   drop the dashboard (default '/dashboard')
    prefix: 'myapp'); //      metric name prefix
// GET /healthz   liveness (200 while serving)
// GET /readyz    readiness
// GET /metrics   Prometheus text (per-route counts, 5xx, p50/p90/p99)
// GET /dashboard self-contained auto-refreshing HTML (WebSocket-pushed)
```

Aggregates across every isolate. `prometheusFormat(m)` / `metricsJson(m)` are
pure renderers; `await server.aggregatedMetrics()` = cross-isolate view,
`server.metrics` = this isolate only.

### OpenAPI 3.1 + Swagger UI

Built from the registered routes. Typed helpers render body, query/header params
and auth in Swagger "Try it out" — no raw OpenAPI maps.

```dart
await serveOpenApi(server, title: 'My API'); // zero-config: spec from routes, Swagger UI at /docs
```

```dart
final api = OpenApi(server, title: 'My API',
    securitySchemes: {'bearer': bearerScheme(bearerFormat: 'JWT')}); // lights up "Authorize"

await api.get('/search', (r) => ResponseContext.jsonBody({'q': r.queryParam('q')}),
    doc: const OpenApiOperation(
      summary: 'Search',
      params: [OpenApiParam.query('q', required: true), OpenApiParam.header('X-Request-Id')],
      responseExample: {'total': 0},
    ));

await api.post('/users', (r) => ResponseContext.jsonBody(r.jsonMap(), status: 201),
    doc: const OpenApiOperation(
      requestExample: {'name': 'Ada', 'email': 'ada@example.com'}, // schema + editor inferred
      successStatus: 201,
      extraResponses: {'400': OpenApiResponse('Invalid body')},
    ));

await api.post('/upload', (r) => ResponseContext.jsonBody({'parts': r.multipart().length}),
    doc: const OpenApiOperation(requestBodyDoc: OpenApiRequestBody.multipart(schema: {
      'type': 'object', 'properties': {'file': {'type': 'string', 'format': 'binary'}},
    })));

await api.get('/me', (_) => ResponseContext.jsonBody({'ok': true}),
    middleware: [bearerAuth((t) => t == 'secret')],
    doc: const OpenApiOperation(requiresAuth: ['bearer'])); // padlock + credential sent

await api.serve(); // GET /openapi.json + Swagger UI at /docs
```

Path params come from `:param`; `OpenApiParam.query/.header/.cookie`;
`OpenApiRequestBody.json/.form/.multipart/.text/.binary`. POST/PUT/PATCH always
get a JSON `requestBody`. Schemes: `bearerScheme()`, `apiKeyScheme()`,
`basicScheme()`, `oauth2Scheme()`, `openIdConnectScheme()`. Raw
`parameters`/`requestBody`/`responses`/`security` remain as escape hatches.

### Graceful shutdown

```dart
final shutdown = shutdownOnSignals(server,
    drain: const Duration(seconds: 15), onSignal: (s) => print('$s: draining'));
// SIGTERM/SIGINT → stop accepting, drain in-flight requests, then exit.
// shutdown.isShuttingDown · await shutdown.trigger() · await shutdown.cancel()

await server.onClose; // keep main alive
```

Direct: `await server.close(drain: const Duration(seconds: 15))` — without
`drain:` it closes immediately (parked requests get 503).

### Server events

```dart
server.events.listen((e) => print('${e.kind.name} #${e.requestId}: ${e.message}'));
// ServerEventKind: started, stopped, handlerTimeout, clientError, clientDisconnect, notice
```

### Startup banner

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

`package:nitro_server/testing.dart` drives the real runner in memory — no
sockets, no native library, real routing/middleware/error mapping, HTTP and
WebSocket. Import both libraries (`testing.dart` does not re-export the main one).

```dart
import 'package:nitro_server/nitro_server.dart';
import 'package:nitro_server/testing.dart';
import 'package:test/test.dart';

void main() {
  test('routes and websocket', () async {
    final client = await NitroTestClient.start();
    final s = client.server; // register exactly as in production
    await s.get('/users/:id', (r) => ResponseContext.text('u${r.param('id')}'));
    await s.post('/echo', (r) => ResponseContext.jsonBody(r.jsonMap()));
    await s.ws('/ws', (session) async {
      await for (final m in session.messages) {
        if (m is WsText) session.sendText('echo: ${m.text}');
      }
    });

    expect((await client.get('/users/42')).text(), 'u42');

    final posted = await client.post('/echo',
        body: {'a': 1}, headers: {'content-type': 'application/json'}); // Map → JSON
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

`client.request(HttpMethod.custom, '/x', customMethod: 'REPORT')` for custom
verbs; `body:` accepts `String`, bytes or `Map`. Divergences: no sockets
(`port` = 0), route timeouts and `maxBodyBytes` not enforced, `clientIp` = `''`.

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
    await enableHotReload(server, log: print); // watch: ['lib', 'bin'] to narrow; returns a HotReloader (.stop())
  } catch (_) {
    // AOT or no VM service: serve without reload.
  }
  await server.onClose;
}
```

`server.reload([setup])` rebuilds the whole routing surface transactionally on
the live socket (added/removed/changed routes, across every isolate, no dropped
connections). Needs `hotreloader` in `dev_dependencies` and a VM service —
`dart run --enable-vm-service bin/server.dart` (JIT); throws under AOT, so guard
as above. `setup` must be a **top-level or static function** (hot reload cannot
re-patch a stored closure); inline handlers are fine.

## Native library loading

`bind` opens the native library automatically — Flutter bundles it, a Dart CLI
builds it with cmake. Search order: explicit path → `NITRO_SERVER_DYLIB` →
beside the executable (`lib/`, `../lib/`) → `.dart_tool/lib` → `build/lib` →
`build/`.

```dart
loadNitroServerNative(path: '/opt/libs/libnitro_server.so'); // idempotent; StateError lists searched paths
// or
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

All extend `NitroServerException` (`message`): `ServerBindException`,
`ServerTlsException`, `ServerAlreadyRunningException`,
`ServerNotRunningException`, `RouteNotFoundException` (from `unroute`),
`ServerBadRequestException`, `HandlerTimeoutException`,
`ServerUnknownException`. Plain Dart errors elsewhere: `ArgumentError` (bad
pattern/prefix, `isolates > 1` without `setup`), `StateError` (`reload` without a
setup, missing dylib), `FormatException` (`json*()`, `multipart()`).

## Platforms and limitations

- **Platforms:** iOS (foreground only), Android (foreground service),
  macOS/Linux/Windows (unconstrained), Web (unsupported).
- **HTTP/2** on by default and runtime-selectable (`ServerConfig(protocol:)`)
  when built `-DNITRO_SERVER_HTTP2=ON` (+ nghttp2); **HTTP/3** not implemented —
  terminate at a proxy. See [`doc/http2.md`](doc/http2.md),
  [`doc/http3.md`](doc/http3.md), [`doc/conformance.md`](doc/conformance.md).
- **TLS/brotli are build-time**: auto-enabled when OpenSSL/libbrotli are found at
  engine build (prebuilts have both) — see
  [Enabling TLS, brotli, gzip, HTTP/2](#enabling-tls-brotli-gzip-http2).
  Certificates hot-reload via `server.reloadTls(...)`.
- **Not serverless** — a persistent native process, for containers/VMs.
- **State is process-wide** (one isolate by default); observability
  auto-aggregates at `isolates > 1`, but `metrics` and the default rate-limit
  store are per isolate (see [shared store](#shared-rate-limit-store)).
- **Server-global middleware does not wrap WebSocket routes** (the engine
  upgrades first) — use `ws(middleware: [...])`, which gates the handshake and
  maps a rejection to a close code (see [WebSocket](#websocket)).
- `close(drain:)` answers connections accepted during drain with `503`; one still
  in the kernel backlog at final listener close may be reset.

## Performance

Reproducible blackbox harness: each framework an opaque HTTP server, `oha` at 64
keep-alive connections, **equal CPU budget (3 server cores each)**, load
generator on disjoint cores, medians of interleaved reps, **responses
byte-validated identical across frameworks**; Linux container on Apple Silicon,
measured 2026-10-21 on the published nitro 0.8.0. The `nitro` column is the
`_dylib` build; `@Native` is within noise on every route. Run it: `benchmark/blackbox/run.sh`; methodology in
[`benchmark/BENCHMARKING.md`](benchmark/BENCHMARKING.md).

**Headline:** fastest where there is real per-request work — `/echo` (beats Go,
~ties Node), `/work` (~2.8× Go), and the engine `/static` fast-path. Second on
trivial I/O: Go leads `/hello`…`/mw` by ~20%.

### Setup (equal CPU budget = 3 cores each)

| framework | configuration |
|-----------|---------------|
| **nitro** | `@Native` code asset **and** `DynamicLibrary` (both shown — within noise); `isolates: 3`, engine fans CPU work across them |
| go | `net/http`; `GOMAXPROCS=3` |
| node | `http` + `cluster`, 3 workers |
| dart:io | `HttpServer`, 3 shared isolates (`SO_REUSEPORT`) |
| shelf | `shelf_io.serve`, 3 shared isolates (`SO_REUSEPORT` — dart:io underneath) |

### Throughput (req/s, median; **bold** = fastest per route)

| route | nitro | go | node | dart:io | shelf |
|-------|------:|---:|-----:|--------:|------:|
| `/json` (light I/O)¹ | 174k | **208k** | 134k | 78k | 62k |
| `/work` (encode 200 JSON records)² | 44k | 16k | **53k** | 8.5k | 8.2k |
| `/echo` (4 KB body) | 102k | 73k | **106k** | 61k | 51k |
| `/static` (engine fast-path)³ | **442k** | 215k | 132k | 75k | 66k |

¹ `/hello`, `/q`, `/users`, `/files`, `/mw` track `/json` within ~5%.
² per-request encode on every framework (equal work).
³ nitro answers from the engine (`getStatic`, no handler/FFI); the others run a
handler returning the same bytes — not apples-to-apples.

### Tail latency — `/work` (ms, median; **bold** = best p99)

| framework | p50 | p90 | p99 | p50:p99 |
|-----------|----:|----:|----:|--------:|
| node | 1.11 | 1.53 | **3.60** | 3.2× |
| nitro | 1.21 | 2.61 | 4.14 | 3.4× |
| dart:io | 7.31 | 8.93 | 10.89 | 1.5× |
| shelf | 7.80 | 9.05 | 13.84 | 1.8× |
| go | 0.97 | 11.28 | 22.55 | 23× |

`p50:p99` is flatness, not speed (dart:io's and shelf's 1.5–1.8× is flatness of a
slow number — ~8k req/s vs nitro's 44k). Go's 23× is per-request-`Marshal` GC-pause
spikes, not steady slowness.

### Peak memory (RSS, whole-workload high-water; **bold** = lowest)

| framework | nitro | go | node | dart:io | shelf |
|-----------|------:|---:|-----:|--------:|------:|
| peak RSS | 154 MB | **12 MB** | 395 MB | 51 MB | 51 MB |

nitro = 3 isolate Dart heaps + the native libuv engine (~fixed at startup; load
adds only ~16 MB — the JsonWriter pool bounds per-request churn). A light-route
single-isolate server (the default) is ~30–50 MB.

## Developing

`lib/src/nitro_server.native.dart` is the bridge spec; regenerate the `*.g.*`
files with `dart run build_runner build` (never edit them by hand).

```sh
cmake -S src -B build/lib -DCMAKE_BUILD_TYPE=Release -DNITRO_SERVER_BUILD_TESTS=ON
cmake --build build/lib --parallel
./build/lib/nitro_server_tests/nitro_server_engine_tests   # C++ suite
dart test                                                  # Dart suites
bash tool/coverage.sh                                      # Dart 100% line gate
bash tool/cpp_coverage.sh 90                               # engine line gate
```

Sanitizers/fuzzing (clang): `-DNITRO_SERVER_SANITIZE=thread|address|undefined`
for an instrumented engine build; `bash tool/fuzz.sh 60` for libFuzzer targets.
`.github/workflows/ci.yml` runs the suites, both coverage gates, and the
thread/address sanitizers on Linux and macOS.
