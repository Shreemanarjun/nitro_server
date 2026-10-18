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

The native engine library is built from source with cmake (see
[Developing](#developing)); `bind` loads it automatically. For containers, use
the provided [`Dockerfile`](Dockerfile).

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
- Graceful drain on SIGTERM/SIGINT; transactional hot reload.
- Typed public API (no `dynamic`); in-memory test client.
- Deploy recipes: Docker, Fly.io, Cloud Run, Kubernetes, Netlify.

Performance (8-core, handler `/json`): ~115k req/s on ~1.4 cores, the field's
tightest p99, ~2.4× the per-core efficiency of Go/Node — see
[Performance](#performance).

## How it works

- A **libuv reactor**: one event loop per CPU core, each with its own
  `SO_REUSEPORT` listener, so the kernel load-balances accepts. A handful of
  loop threads serve thousands of keep-alive connections — connection state is
  heap-owned and read-event driven, not a thread per connection. (Windows has no
  `SO_REUSEPORT`: a single listener there.)
- Each loop parses the request, matches it in a segment trie, and hands it to a
  Dart isolate over a stream. The handler's answer is enqueued and the
  connection's loop is woken (`uv_async_send`) to write it (`sendfile` for
  files). A response racing a connection close is dropped, never a
  use-after-free.
- **Adaptive dispatch.** Requests are dealt across only as many of the
  configured `isolates` as actually raise throughput: a light/IO-bound handler
  stays on one isolate (the engine already parallelizes the I/O), while a
  CPU-bound or head-of-line-blocked workload fans out across all. So you can set
  `isolates` to the core count for any workload — extra isolates are headroom
  for heavy handlers, never a tax on light ones.

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
`cookies`, `params`, `body`, `bodyStream` (with `streamBody: true`), `text()`,
`jsonMap()`, `jsonList()`, `jsonAs<T>()`, `multipart()`, `header(name)`,
`param(name)`, `queryParam(name)`.

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

> Middleware state lives per isolate. `rateLimit`'s counters are per isolate, so
> on a multi-isolate server the effective limit is `maxRequests × isolates` —
> put it behind a shared gateway, or run `isolates: 1`, if you need a hard
> global limit. It keys clients by `X-Forwarded-For`/`X-Real-IP` (or a custom
> `keyExtractor`), since the engine does not expose the peer address to
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

`prometheusFormat(server.metrics)` and `metricsJson(server.metrics)` are pure
renderers if you want to expose the data your own way.

### OpenAPI 3.1 + Swagger UI (generated from your routes)

The spec is built automatically from the registered routes. Use `serveOpenApi`
for a zero-config spec, or the `OpenApi` wrapper to embed docs *inline* where you
declare each route:

```dart
final api = OpenApi(server, title: 'My API', version: '1.0.0');

await api.get(
  '/users/:id',
  getUser,
  doc: const OpenApiOperation(
    summary: 'Fetch a user',
    responses: {
      '200': {'description': 'the user'},
      '404': {'description': 'not found'},
    },
  ),
);
await api.post('/users', createUser); // documented with the auto skeleton

await api.serve(); // GET /openapi.json + Swagger UI at /docs
```

Path params become `{param}`; `all` routes expand across the verbs; WebSocket and
custom-verb routes are surfaced under `x-additional-routes` so nothing is
dropped. Enrich individual operations (request/response schemas, tags, security)
via `OpenApiOperation`, and declare `servers`/`securitySchemes`/`tags` on the
wrapper or `serveOpenApi`.

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
| `tls` | none | `TlsConfig(certPem:, keyPem:)` or `certFile`/`keyFile`; throws `ServerTlsException` unless the engine was built with OpenSSL |

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

`server.reload([setup])` rebuilds the whole routing surface on the live socket,
transactionally. Wire it to VM hot reload with the opt-in helper (add
`hotreloader` to `dev_dependencies`):

```dart
import 'package:nitro_server/nitro_server.dart';
import 'package:nitro_server/hot_reload.dart';

Future<void> main() async {
  final server = await NitroServer.bind(const ServerConfig(port: 8080), setup);
  await enableHotReload(server); // re-runs `setup` after each hot reload
}
```

Run with `dart run --enable-vm-service bin/server.dart`, then edit a handler and
save. `setup` must be a **top-level or static function** (Dart hot reload doesn't
re-patch a stored anonymous closure); handlers written inline inside `setup` are
fine.

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

- **HTTP/1.1 only** — no HTTP/2 or HTTP/3 yet.
- **Not serverless.** It is a persistent native process (a Dart binary + the
  engine library); it runs on containers/VMs, not on function platforms.
- **Per-isolate state.** `server.metrics` and middleware state (e.g.
  `rateLimit`) are per isolate; with `isolates > 1` aggregate externally
  (Prometheus sums scrapes) or keep operational endpoints on one isolate.
- **No client IP in handlers.** Derive clients from proxy headers
  (`X-Forwarded-For`/`X-Real-IP`).
- **TLS/brotli are build-time.** They require the engine to be compiled with
  OpenSSL/libbrotli; the default build has them off (terminate TLS at a proxy,
  or build with `-DNITRO_SERVER_TLS=ON`).
- **Platforms:** iOS (foreground only — listener sockets suspend in the
  background), Android (foreground service), macOS/Linux/Windows (no
  constraints), Web (unsupported).
- `close(drain:)` resets connections still in the kernel backlog only if they
  arrive after the drain's final accept sweep.

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
