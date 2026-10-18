# nitro_server

A production HTTP/1.1 and WebSocket server for Dart and Flutter. A native,
multithreaded C++ engine (libuv, via [Nitro](https://pub.dev/packages/nitro)
FFI) accepts, parses, routes and writes on every CPU core; your handlers run on
the Dart isolate. Client counterpart:
[`nitro_http`](https://github.com/Shreemanarjun/nitro_http).

```dart
import 'package:nitro_server/nitro_server.dart';

Future<void> main() async {
  final server = await NitroServer.bind(); // 127.0.0.1, a free port

  await server.get('/hello', (_) => ResponseContext.text('hi 👋'));
  await server.get(
    '/users/:id',
    (request) => ResponseContext.jsonBody({'id': request.param('id')}),
  );
  await server.post('/echo', (request) => ResponseContext.bytes(request.body));

  print('listening on ${server.uri}');
}
```

## Install

```sh
dart pub add nitro_server
```

**No toolchain needed for released versions.** A native-assets build hook
([`hook/build.dart`](hook/build.dart)) runs on `dart build`/`run`/`test`: it
downloads the prebuilt engine for your OS+arch from the matching GitHub release
(SHA-256-verified), and `dart build cli` bundles it beside the executable. The
prebuilts are **self-contained** — libuv/OpenSSL/brotli/nghttp2 statically
linked, all protocols compiled in — so a consumer needs **no cmake and no system
libraries**. (Pick the protocol at runtime with `ServerConfig(protocol:)`.) For
containers, the provided [`Dockerfile`](Dockerfile) bakes everything in.

### Prerequisites (only for building from source)

You only need a toolchain to build the engine yourself — on an unreleased
version, an exotic OS/arch the release doesn't cover, or with
`NITRO_SERVER_BUILD_FROM_SOURCE=1`. That needs a **C++17 compiler**,
**CMake ≥ 3.10**, and the Dart SDK (≥ 3.12) or Flutter SDK (≥ 3.10), plus a few
native libraries. Only **libuv** is required; the rest unlock optional features
and are **auto-detected at build time** (present → enabled, absent → cleanly
skipped):

| Library | Enables | Required? |
|---------|---------|-----------|
| **libuv** | the reactor I/O core | **yes** (build fails without it) |
| OpenSSL 3 | TLS / HTTPS (and h2 over TLS) | optional, auto-detected |
| libbrotli | `compress()` `br` encoding (else gzip) | optional, auto-detected |
| nghttp2 | **HTTP/2** (also pass `-DNITRO_SERVER_HTTP2=ON`) | optional |

**Install everything in one shot** — the simplest path, so you never hit a
piecemeal "libX not found" during the build:

```sh
# macOS (Homebrew)
brew install cmake pkg-config libuv openssl@3 brotli nghttp2

# Debian / Ubuntu
sudo apt-get install -y cmake pkg-config libuv1-dev libssl-dev libbrotli-dev libnghttp2-dev

# Windows (vcpkg) — then configure with the vcpkg toolchain file
vcpkg install libuv openssl brotli nghttp2 --triplet x64-windows
```

Then build the engine (TLS/brotli light up automatically from the libs above;
add the flag to also get HTTP/2):

```sh
cmake -S src -B build/lib -DCMAKE_BUILD_TYPE=Release -DNITRO_SERVER_HTTP2=ON
cmake --build build/lib --parallel
```

Minimal build (HTTP/1.1 + WebSocket only, no TLS/brotli/h2) needs just libuv:
`brew install cmake libuv` / `apt-get install -y cmake libuv1-dev`. Detection
uses `pkg-config` then CMake config then Homebrew prefixes; point it at a custom
location with `-DOPENSSL_ROOT_DIR=…` or `PKG_CONFIG_PATH`.

**For deployment, avoid the prerequisites on the target host entirely:**
`dart run nitro_server:nitro build --bundle-deps` compiles a self-contained
executable with libuv/OpenSSL/brotli/nghttp2 copied next to it and the load
paths rewritten (macOS/Linux) — copy the folder and run, no system libs needed.
Or ship the [`Dockerfile`](Dockerfile) image, which has them baked in.

## Features

- HTTP/1.1 (keep-alive, pipelining, `Expect: 100-continue`, chunked uploads) and
  RFC 6455 WebSocket, both in the native engine.
- Trie routing: `:param`, trailing `*`, custom verbs, prefixed groups.
- Middleware: CORS, gzip/brotli compression, access log, rate limit, bearer/API-
  key/basic auth.
- Streaming and file responses (`sendfile`), static file serving, multipart.
- Observability: Prometheus `/metrics`, `/healthz`, `/readyz`, and a live
  WebSocket-pushed dashboard.
- OpenAPI 3.1 + Swagger UI generated from the routes.
- `Server-Timing` response-time header on every answer; colourful startup banner.
- Graceful drain on SIGTERM/SIGINT; transactional hot reload.
- Typed public API (no `dynamic`); in-memory test client.
- Deploy recipes: Docker, Fly.io, Cloud Run, Kubernetes, Netlify.

Performance (8-core, handler `/json`): ~115k req/s on ~1.4 cores, the field's
tightest p99, ~2.4× the per-core efficiency of Go/Node — see
[Performance](#performance).

## How it works

A **libuv reactor** runs one event loop per CPU core, each with its own
`SO_REUSEPORT` listener (one listener on Windows), so a handful of loop threads
serve thousands of keep-alive connections — read-event driven, not a thread per
connection. Each loop parses and trie-matches the request, hands it to a Dart
isolate, then writes the answer (`sendfile` for files). **Adaptive dispatch**
deals requests across only as many `isolates` as raise throughput — light
handlers stay on one, CPU-bound ones fan out — so you set `isolates` to the core
count for any workload.

## Routing & handlers

```dart
// Verb shorthands; `:param` and trailing `*` captures.
await server.get('/users/:id', (r) => ResponseContext.text('user ${r.param('id')}'));
await server.post('/upload/*', handleUpload, maxBodyBytes: 50 * 1024 * 1024);

// Custom verbs and per-route middleware.
await server.route(HttpMethod.custom, '/items', report, customMethod: 'REPORT');
await server.get('/admin', dashboard, middleware: [requireAdmin]);

// A prefixed sub-router with its own middleware.
final api = server.group('/api/v1')..use(cors());
await api.get('/ping', (_) => ResponseContext.text('pong'));

// Fallbacks.
server.notFoundHandler = (request) => ResponseContext.text('nope', status: 404);
server.errorHandler = (error, request) => ResponseContext.text('oops', status: 500);
```

Precedence: static > param > wildcard, method-specific > `HttpMethod.all`, and
HEAD falls back to GET. A handler that outlives its route `timeout` is dropped
after the client gets a 408; a throwing handler answers 500.

`RequestContext`: `method`, `path`, `query`, `queryParameters`, `headers`,
`cookies`, `params`, `body`, `bodyStream` (with `streamBody: true`), `clientIp`
(the peer address off the socket), `text()`, `jsonMap()`, `jsonList()`,
`jsonAs<T>()`, `multipart()`, `header(name)`, `param(name)`, `queryParam(name)`.

`ResponseContext`: `text`, `json`, `jsonBody`, `jsonMap`, `html`, `bytes`,
`redirect`, `stream`, `file`; `withCookie(SetCookie(...))`. Sync handlers are
answered without a `Future`.

## WebSocket

```dart
await server.ws('/chat', (session) async {
  await for (final message in session.messages) {
    final text = message is WsText ? message.text : '(binary)';
    session.sendText('echo: $text');
  }
}, protocols: ['chat.v1']);
```

RFC 6455 handshake and frame loop in the engine: text/binary, ping/pong, close
codes, `permessage-deflate`, and subprotocol selection. `WsSession`: `messages`
(`WsText` | `WsBinary`), `sendText`/`sendBytes` (return the queued byte count,
`-1` when closed), `bufferedBytes`, `compressed`, `close(code)`.

## Middleware

```dart
await server.use(accessLog());
await server.use(cors(allowOrigin: 'https://example.com'));
await server.use(compress()); // gzip, or brotli when the engine is built with it
await server.use(rateLimit(maxRequests: 100)); // 100/min per client
await server.use(bearerAuth((token) => token == mySecret));
```

Server-wide (`server.use`, outermost first), per group, or per route
(`middleware:`). Also `apiKeyAuth`, `basicAuth`, and `staticFiles(dir)`
(`sendfile`, `etag`, 304, byte ranges, index files, traversal protection).

> `rateLimit`'s counters are in-memory and per isolate, so on a multi-isolate
> server the effective limit is `maxRequests × isolates` — pass a shared
> [`RateLimitStore`](#middleware) (or run the default `isolates: 1`) if you need
> a hard global limit. It keys clients by `X-Forwarded-For`/`X-Real-IP` (or a
> custom `keyExtractor`), since the engine does not expose the peer address to
> handlers; without a proxy setting those, all clients share one bucket.

## Production

### Health, metrics & a live dashboard

```dart
await serveObservability(server);
// GET /healthz   -> liveness (200 while serving)
// GET /readyz    -> readiness (503 once draining)
// GET /metrics   -> Prometheus text (per-route counts, 5xx, p50/p90/p99)
// GET /dashboard -> a self-contained auto-refreshing HTML dashboard
```

`/metrics` and `/dashboard` aggregate across every isolate by default, so what
you scrape is the whole server. `prometheusFormat(metrics)` and
`metricsJson(metrics)` are pure renderers if you want to expose the data your own
way — pass `await server.aggregatedMetrics()` for the cross-isolate view, or
`server.metrics` for just this isolate's.

### OpenAPI 3.1 + Swagger UI (generated from your routes)

The spec is built automatically from the registered routes. Use `serveOpenApi`
for a zero-config spec, or the `OpenApi` wrapper to embed docs *inline* where you
declare each route. Typed helpers make **body, query/header params, and auth**
all render and work in Swagger UI's "Try it out" — no raw OpenAPI maps:

```dart
final api = OpenApi(
  server,
  title: 'My API',
  // Declaring schemes lights up Swagger's "Authorize" button.
  securitySchemes: {'bearer': bearerScheme(bearerFormat: 'JWT')},
);

// Query + header inputs, and a response model.
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

// Request body: the schema + "Try it out" editor are inferred from the sample.
await api.post(
  '/users',
  createUser,
  doc: const OpenApiOperation(
    summary: 'Create a user',
    requestExample: {'name': 'Ada', 'email': 'ada@example.com'},
    extraResponses: {'400': OpenApiResponse('Invalid body')},
  ),
);

// Non-JSON bodies: a file picker, a raw/binary input, form fields…
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

// Auth: `requiresAuth` shows the padlock and sends the credential. Wire the
// matching middleware so the live route enforces it.
await api.get(
  '/me',
  me,
  middleware: [bearerAuth((t) => t == token)],
  doc: const OpenApiOperation(requiresAuth: ['bearer']),
);

await api.serve(); // GET /openapi.json + Swagger UI at /docs
```

Path params become `{param}`; `all` routes expand across the verbs; WebSocket and
custom-verb routes are surfaced under `x-additional-routes` so nothing is
dropped. **POST/PUT/PATCH always get a JSON `requestBody`** so Swagger shows a
body input even with no doc. Auth helpers cover all three families —
`bearerScheme()`, `apiKeyScheme()`, `basicScheme()` — and the Swagger page keeps
the Authorize token across reloads (`persistAuthorization`) with "Try it out"
open by default. Raw `parameters`/`requestBody`/`responses`/`security` remain as
full-control escape hatches.

### Graceful shutdown

```dart
shutdownOnSignals(server, drain: const Duration(seconds: 15));
// SIGTERM/SIGINT -> stop accepting, drain in-flight requests, then exit.
```

### Deployment

A multi-stage [`Dockerfile`](Dockerfile) builds the native engine and
AOT-compiles [`bin/server.dart`](bin/server.dart) into a slim, non-root image
with a `/readyz` healthcheck. [`docs/deployment.md`](docs/deployment.md) covers
Docker, Fly.io, Render, Railway, Cloud Run, Kubernetes (probes + drain) and
Netlify (static frontend + API/WebSocket proxy — a persistent native server
can't run as a serverless function).

## Configuration

Pass a `ServerConfig` to `bind`; register routes in a `setup` function (required
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
| `isolates` | `1` | Dart isolates available to run handlers; `0` = half the cores (1–8); each runs `setup`. Adaptive dispatch uses only as many as help |
| `wsMaxBufferBytes`, `wsCompression` | 1 MiB, `true` | WebSocket send queue before a 1009 close; negotiate `permessage-deflate` |
| `responseTiming` | `true` | add `Server-Timing: app;dur=<ms>` (dispatch→answer) to every handler answer; browsers show it in DevTools. Set `false` to shave one string per response at peak throughput |
| `tls` | none | `TlsConfig(certPem:, keyPem:)` or `certFile`/`keyFile`; throws `ServerTlsException` unless the engine was built with OpenSSL |
| `protocol` | `HttpProtocol.http2` | highest HTTP version to negotiate, in one knob: `http1` (HTTP/1.1 only), `http2` (adds `h2` via ALPN/h2c, falls back to 1.1), `http3` (reserved). Caps at what the engine was built with |

## Testing

`package:nitro_server/testing.dart` drives the real runner in memory — no
sockets, no native library, real routing/middleware/error mapping:

```dart
import 'package:nitro_server/testing.dart';

final client = await NitroTestClient.start();
await client.server.get('/users/:id', (r) => ResponseContext.text('u${r.param('id')}'));
final res = await client.get('/users/42');
expect(res.status, 200);
expect(res.text(), 'u42');
await client.close();
```

## Running: the `nitro` CLI

The package ships a `nitro` executable to run or compile a server entrypoint —
JIT with hot reload for dev, AOT for production:

```sh
# Run (default: bin/server.dart, JIT + hot reload via the VM service)
dart run nitro_server:nitro serve
dart run nitro_server:nitro serve bin/api.dart     # a different entrypoint
dart run nitro_server:nitro serve --aot            # compile, then run (prod-like)

# Compile
dart run nitro_server:nitro build                  # AOT exe → build/server
dart run nitro_server:nitro build --jit            # JIT snapshot
dart run nitro_server:nitro build -o dist/api      # custom output path

# Globally activated (dart pub global activate nitro_server):
nitro serve      # same commands, shorter
nitro build
```

`serve` is just `dart run --enable-vm-service <entry>`; `build` wraps
`dart compile exe`/`jit-snapshot`. Run those directly if you prefer — the CLI is
a convenience, not a requirement.

**Standalone binary.** `nitro build` copies the engine library next to the exe,
and the loader searches the executable's own directory first — so `build/server`
runs from any working directory. Keep the `.dylib`/`.so`/`.dll` beside the
binary when you move it. The native library still links its system deps (libuv,
and OpenSSL/brotli/nghttp2 if built in); to run on a host without them, build
with **`nitro build --bundle-deps`** (copies every native dep next to the exe
and rewrites the load paths — see [Prerequisites](#prerequisites)) or deploy the
provided [`Dockerfile`](Dockerfile), which bakes them in.

## Hot reload

`server.reload([setup])` rebuilds the whole routing surface on the live socket,
transactionally — added, removed and changed routes all take effect without
dropping the port or open connections, across every isolate. `enableHotReload`
(in `package:nitro_server/hot_reload.dart`) wires that to the VM's hot reload:

```dart
import 'package:nitro_server/nitro_server.dart';
import 'package:nitro_server/hot_reload.dart';

Future<void> setup(NitroServer server) async {
  await server.get('/hello', (_) => ResponseContext.text('hi'));
}

Future<void> main() async {
  final server = await NitroServer.bind(const ServerConfig(port: 8080), setup);
  try {
    await enableHotReload(server); // re-runs `setup` after each hot reload
  } catch (_) {
    // AOT or no VM service: serve without reload.
  }
}
```

**Availability.** Hot reload needs a running VM service, so it works under
`dart run --enable-vm-service bin/server.dart` (JIT) and is unavailable in an
AOT build (`dart compile exe`) — `enableHotReload` throws there, so guard it as
above and your server runs normally. The bundled `bin/server.dart` does exactly
this and prints `hot reload on`/`off` in its startup banner.

**How it works.** `enableHotReload` watches your source directories and, after
each reload, calls `server.reload()` to re-run `setup` and diff the route table.
`setup` must be a **top-level or static function** (Dart hot reload doesn't
re-patch a stored anonymous closure); handlers written inline inside `setup`
are fine.

## Performance

8-core box, handler `/json`, `wrk`/`oha`:

| metric | nitro | vs field |
| --- | --- | --- |
| throughput | ~115k req/s | 3rd (> dart:io, shelf) |
| closed-loop p99 | 0.76 ms | best |
| CPU efficiency | ~83k req/s per core | best (~2.4× Go) |
| memory under load | ~30 MB RSS | lean tier; ~20× < Node |

Full cross-framework tables (throughput, closed- and open-loop /
coordinated-omission-free latency, overload, CPU/core, memory, AOT vs JIT):
[`docs/benchmark-production.md`](docs/benchmark-production.md).

## Limitations

- **HTTP/2** ships in the engine when built with `-DNITRO_SERVER_HTTP2=ON`
  (+ nghttp2): live over TLS (ALPN `h2`) and h2c, 136/145 h2spec — see
  [`docs/http2.md`](docs/http2.md) / [`docs/conformance.md`](docs/conformance.md).
  It is **on by default and selectable per server at runtime** —
  `ServerConfig(protocol: HttpProtocol.http1)` forces HTTP/1.1, `.http2` enables
  h2 — no rebuild needed. The default engine build (no flag) is HTTP/1.1 +
  WebSocket. **HTTP/3** is not implemented ([`docs/http3.md`](docs/http3.md));
  terminate h3 at a proxy.
- **Not serverless.** It is a persistent native process (a Dart binary + the
  engine library); it runs on containers/VMs, not on function platforms.
- **State is shared by default.** The default build runs one isolate, so all
  state is already process-wide. When you scale to `isolates > 1`,
  `serveObservability` (`/metrics`, `/dashboard`) **aggregates every isolate
  automatically** — a scrape reflects the whole server, not the isolate that
  answered. The one exception is `rateLimit`: its in-memory counters are
  per isolate, so the effective limit is `maxRequests × isolates` unless you pass
  a shared [`RateLimitStore`](#middleware). (`server.metrics` is the sync,
  this-isolate snapshot; `await server.aggregatedMetrics()` is the cross-isolate
  sum the observability endpoints use.)
- **TLS/brotli are build-time.** They require the engine compiled with
  OpenSSL/libbrotli; the default build has them off (terminate TLS at a proxy,
  or build with `-DNITRO_SERVER_TLS=ON`). Once built with TLS, certificates
  **hot-reload** on a live server via `server.reloadTls(...)`.
- **Platforms:** iOS (foreground only — listener sockets suspend in the
  background), Android (foreground service), macOS/Linux/Windows (no
  constraints), Web (unsupported).
- `close(drain:)` answers connections accepted during the drain with `503`
  (`Connection: close`); a connection still in the kernel backlog at the final
  listener close may be reset.

## Dart-only use

No Flutter SDK dependency. `bind` opens the native library automatically —
Flutter bundles it; a Dart CLI builds it with cmake. `bind` searches
`NITRO_SERVER_DYLIB`, then `build/lib/<name>`, then `build/<name>`; for a custom
path call `loadNitroServerNative(path: ...)` (idempotent) or
`NitroServer.bindWith(dylibPath: ...)` before `bind`.

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
for an instrumented engine test build; `bash tool/fuzz.sh 60` for libFuzzer
targets (head parser, WebSocket frame parser, socket). `.github/workflows/ci.yml`
runs the suites, both coverage gates, and the thread/address sanitizers on Linux
and macOS.
