# nitro_server

Production HTTP/1.1 + WebSocket server for Dart and Flutter. A native,
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

## Features

- HTTP/1.1 (keep-alive, pipelining, `Expect: 100-continue`, chunked uploads) and
  RFC 6455 WebSocket, both in the native engine. HTTP/2 when built in.
- Trie routing: `:param`, trailing `*`, custom verbs, prefixed groups.
- Middleware: CORS, gzip/brotli compression, access log, rate limit,
  bearer/API-key/basic auth.
- Streaming and file responses (`sendfile`), static file serving, multipart.
- Observability: Prometheus `/metrics`, `/healthz`, `/readyz`, live dashboard.
- OpenAPI 3.1 + Swagger UI generated from the routes.
- `Server-Timing` header per answer; graceful drain; transactional hot reload.
- Typed public API (no `dynamic`); in-memory test client.

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

## Commands — the `nitro` CLI

`dart run nitro_server:nitro <cmd>` (or `nitro <cmd>` after
`dart pub global activate nitro_server`):

| Command | Does |
|---------|------|
| `serve` | run `bin/server.dart`, JIT + hot reload (VM service) |
| `serve <entry>` | run a different entrypoint |
| `serve --aot` | compile, then run (prod-like) |
| `build` | AOT exe → `build/server` |
| `build --jit` | JIT snapshot |
| `build -o <path>` | custom output path |
| `build --bundle-deps` | AOT exe + native deps copied beside it, load paths rewritten (self-contained) |

`serve` wraps `dart run --enable-vm-service`; `build` wraps
`dart compile exe`/`jit-snapshot`. Run those directly if you prefer.

## Build & run

```sh
# dev — hot reload on
dart run nitro_server:nitro serve

# production — AOT
dart run nitro_server:nitro build      # -> build/server (engine lib copied beside it)
./build/server                         # runs from any working directory

# self-contained — no system libs on the target host
dart run nitro_server:nitro build --bundle-deps

# container — engine + deps baked in
docker build -t myapp .
docker run -p 8080:8080 myapp
```

AOT has no hot reload. Keep the `.dylib`/`.so`/`.dll` beside a moved binary, or
use `--bundle-deps`. Deploy recipes (Fly.io, Render, Railway, Cloud Run,
Kubernetes, Netlify): [`docs/deployment.md`](docs/deployment.md).

## How it works

A **libuv reactor** runs one event loop per CPU core, each with its own
`SO_REUSEPORT` listener, so a few loop threads serve thousands of keep-alive
connections. Each loop parses, trie-matches, hands the request to a Dart
isolate, then writes the answer (`sendfile` for files). **Adaptive dispatch**
spreads work across only as many `isolates` as raise throughput — so leave
`isolates` at `1` for IO-bound work and raise it (or `isolates: 0`) for
CPU-bound handlers.

## Routes

```dart
// Verbs + :param + trailing * capture
await server.get('/users/:id', (r) => ResponseContext.text('user ${r.param('id')}'));
await server.post('/upload/*', handleUpload, maxBodyBytes: 50 * 1024 * 1024);

// Custom verb, per-route middleware
await server.route(HttpMethod.custom, '/items', report, customMethod: 'REPORT');
await server.get('/admin', dashboard, middleware: [requireAdmin]);

// Prefixed group with its own middleware
final api = server.group('/api/v1')..use(cors());
await api.get('/ping', (_) => ResponseContext.text('pong'));

// Streaming, file, static
await server.get('/stream', (_) => ResponseContext.stream(byteStream));
await server.get('/download', (_) => ResponseContext.file('report.pdf'));
await server.get('/static/*', staticFiles('public'));

// WebSocket
await server.ws('/chat', (session) async {
  await for (final m in session.messages) {
    session.sendText('echo: ${m is WsText ? m.text : '(binary)'}');
  }
}, protocols: ['chat.v1']);

// Fallbacks
server.notFoundHandler = (r) => ResponseContext.text('nope', status: 404);
server.errorHandler = (e, r) => ResponseContext.text('oops', status: 500);
```

Precedence: static > param > wildcard; method-specific > `HttpMethod.all`; HEAD
falls back to GET. A handler past its `timeout` → 408; a throwing handler → 500.

## API

<a id="api"></a>

**`RequestContext`** — `method`, `path`, `query`, `queryParameters`, `headers`,
`cookies`, `params`, `body`, `bodyStream` (with `streamBody: true`), `clientIp`;
`text()`, `jsonMap()`, `jsonList()`, `jsonAs<T>()`, `multipart()`, `header(n)`,
`param(n)`, `queryParam(n)`.

**`ResponseContext`** — `text`, `json`, `jsonBody`, `jsonMap`, `jsonWriter`
(native zero-copy encoder), `html`, `bytes`, `redirect`, `stream`, `file`;
`.withCookie(SetCookie(...))`. Sync handlers answer without a `Future`.

**`WsSession`** — `messages` (`WsText` | `WsBinary`), `sendText`/`sendBytes`
(return queued byte count, `-1` when closed), `bufferedBytes`, `compressed`,
`close(code)`. Engine handles the RFC 6455 handshake, ping/pong, close codes,
`permessage-deflate`, subprotocol selection.

## Middleware

```dart
await server.use(accessLog());
await server.use(cors(allowOrigin: 'https://example.com'));
await server.use(compress());                 // gzip, or brotli if the engine has it
await server.use(rateLimit(maxRequests: 100)); // 100/min per client
await server.use(bearerAuth((t) => t == secret));
```

Available: `accessLog`, `cors`, `compress`, `rateLimit`, `bearerAuth`,
`apiKeyAuth`, `basicAuth`, `staticFiles(dir)` (sendfile, etag, 304, byte ranges,
index files, traversal-safe). Scope: server-wide (`server.use`, outermost
first), per group, or per route (`middleware:`).

> `rateLimit` counters are in-memory per isolate — on a multi-isolate server the
> effective limit is `maxRequests × isolates`; pass a shared `RateLimitStore`
> for a hard global cap. Keys on `X-Forwarded-For`/`X-Real-IP` or a custom
> `keyExtractor`.

## Observability

```dart
await serveObservability(server);
// /healthz   liveness (200 while serving)
// /readyz    readiness (503 once draining)
// /metrics   Prometheus text (per-route counts, 5xx, p50/p90/p99)
// /dashboard self-contained auto-refreshing HTML
```

Aggregates across every isolate. `prometheusFormat(m)` / `metricsJson(m)` are
pure renderers; `await server.aggregatedMetrics()` = cross-isolate view,
`server.metrics` = this isolate.

## OpenAPI 3.1 + Swagger UI

Built from the registered routes. Typed helpers render body, query/header params
and auth in Swagger "Try it out" — no raw OpenAPI maps.

```dart
final api = OpenApi(server, title: 'My API',
  securitySchemes: {'bearer': bearerScheme(bearerFormat: 'JWT')});

await api.get('/search', search, doc: const OpenApiOperation(
  summary: 'Search',
  params: [OpenApiParam.query('q', required: true), OpenApiParam.header('X-Request-Id')],
  responseExample: {'total': 0}));

await api.post('/users', createUser, doc: const OpenApiOperation(
  requestExample: {'name': 'Ada', 'email': 'ada@example.com'}));

await api.serve(); // GET /openapi.json + Swagger UI at /docs
```

POST/PUT/PATCH always get a JSON `requestBody`. Auth schemes: `bearerScheme()`,
`apiKeyScheme()`, `basicScheme()`. Raw
`parameters`/`requestBody`/`responses`/`security` remain as escape hatches.

## Configuration — `ServerConfig`

Pass to `bind`; register routes in a `setup` function (required when
`isolates != 1`, so every isolate builds the same routes):

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

## Graceful shutdown

```dart
shutdownOnSignals(server, drain: const Duration(seconds: 15));
// SIGTERM/SIGINT -> stop accepting, drain in-flight requests, then exit.
```

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

## Hot reload

```dart
import 'package:nitro_server/hot_reload.dart';

Future<void> main() async {
  final server = await NitroServer.bind(const ServerConfig(port: 8080), setup);
  try {
    await enableHotReload(server); // re-runs `setup` after each hot reload
  } catch (_) {
    // AOT or no VM service: serve without reload.
  }
}
```

`server.reload([setup])` rebuilds the whole routing surface transactionally on
the live socket (added/removed/changed routes, across every isolate, no dropped
connections). Needs a VM service — works under `dart run --enable-vm-service`
(JIT), throws under AOT (guard as above). `setup` must be a **top-level or
static function** (hot reload cannot re-patch a stored closure); inline handlers
are fine.

## Native library loading (Dart-only, no Flutter)

`bind` opens the native library automatically — Flutter bundles it, a Dart CLI
builds it with cmake. Search order: `NITRO_SERVER_DYLIB` → `build/lib/<name>` →
`build/<name>`. For a custom path call `loadNitroServerNative(path: ...)`
(idempotent) or `NitroServer.bindWith(dylibPath: ...)` before `bind`.

## Platforms & limitations

- **Platforms:** iOS (foreground only), Android (foreground service),
  macOS/Linux/Windows (unconstrained), Web (unsupported).
- **HTTP/2** on by default and runtime-selectable (`ServerConfig(protocol:)`)
  when built `-DNITRO_SERVER_HTTP2=ON` (+ nghttp2); **HTTP/3** not implemented —
  terminate at a proxy. See [`docs/http2.md`](docs/http2.md),
  [`docs/http3.md`](docs/http3.md), [`docs/conformance.md`](docs/conformance.md).
- **TLS/brotli are build-time** (OpenSSL/libbrotli, off by default); certificates
  hot-reload via `server.reloadTls(...)`.
- **Not serverless** — a persistent native process, for containers/VMs.
- **State is process-wide** (one isolate by default); observability
  auto-aggregates at `isolates > 1`, but see the `rateLimit` note above.
- `close(drain:)` answers connections accepted during drain with `503`; one still
  in the kernel backlog at final listener close may be reset.

## Performance

8-core box, handler `/json`, `wrk`/`oha`:

| metric | nitro | vs field |
| --- | --- | --- |
| throughput | ~115k req/s | 3rd (> dart:io, shelf) |
| closed-loop p99 | 0.76 ms | best |
| CPU efficiency | ~83k req/s per core | best (~2.4× Go) |
| memory under load | ~30 MB RSS | lean tier; ~20× < Node |

Full cross-framework comparison (throughput, p50–p99 latency, memory, AOT,
response-validated fairness) is the reproducible blackbox harness — run
`benchmark/blackbox/run.sh`; methodology in
[`benchmark/BENCHMARKING.md`](benchmark/BENCHMARKING.md).

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
