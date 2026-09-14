# nitro_server

HTTP/1.1 and WebSocket server for Dart and Flutter. A native C++ engine
(via [Nitro](https://pub.dev/packages/nitro) FFI) accepts, parses, routes
and writes; handlers run on the Dart isolate. Client counterpart:
[`nitro_http`](https://github.com/Shreemanarjun/nitro_http).

```dart
import 'package:nitro_server/nitro_server.dart';

final server = await NitroServer.bind(); // 127.0.0.1, free port

await server.get('/hello', (_) => ResponseContext.text('hi 👋'));
await server.get('/users/:id', (request) {
  return ResponseContext.jsonBody({'id': request.param('id')});
});
await server.post('/echo', (request) => ResponseContext.bytes(request.body));

print('listening on http://127.0.0.1:${server.port}');
await server.close();
```

## Architecture

- One accept loop per server; one native worker thread per live connection
  from an auto-scaling pool.
- The worker parses the request, matches it in a segment trie, hands it to
  Dart over a stream and parks in `poll()`.
- The Dart thread writes the response with one non-blocking `sendmsg`.
  Bytes the socket cannot take are queued and flushed by the worker; stream
  chunks and file bodies (`sendfile`) always go through the worker.
- Request headers cross the bridge as one packed string and are unpacked
  on first access; query parameters parse on first access.
- Heads combine per isolate: heads that arrive while the previous bridge
  post is in flight cross as one message, so a burst costs one post per
  pass rather than one per head.
- Per-request state lives under its own mutex. No shared bridge lock, no
  callbacks, and the Dart isolate never blocks.
- Routing: `:param` segments, trailing `*`, static > param > wildcard,
  method-specific > `HttpMethod.all`, HEAD falls back to GET.

## API

| call | does |
| ---- | ---- |
| `NitroServer.bind([config, setup])` | binds and starts; port `0` picks a free one (`server.port`); `setup` registers routes before the first request, required when `isolates > 1` |
| `server.get/post/put/delete/patch/head/options/all(pattern, handler, {timeout, middleware, streamBody, maxBodyBytes})` | route registration |
| `server.route(method, pattern, handler, {customMethod, …})` | general form, custom verbs |
| `server.use(middleware)` | server-wide middleware, outermost first |
| `server.group(prefix)` | path-prefixed view with its own middleware |
| `server.ws(pattern, handler, {protocols})` | WebSocket route (RFC 6455); the handler gets a `WsSession`; `protocols` selects a subprotocol |
| `server.notFoundHandler`, `server.errorHandler` | custom 404 and 500 answers |
| `server.unroute(method, pattern)` | removes a route; `RouteNotFoundException` if absent |
| `server.events` | lifecycle stream: started, stopped, handler timeout, client error |
| `server.metrics` | per-route request and 5xx counts, latency p50/p90/p99 |
| `server.close({drain})` | stops; with `drain:` stops accepting, closes idle connections and waits up to `drain` for in-flight requests |

TLS: pass `ServerConfig(tls: TlsConfig(certPem: ..., keyPem: ...))` (or
`certFile`/`keyFile`). Requires a native build with OpenSSL available to
cmake; otherwise `bind` throws `ServerTlsException`. HTTP/1.1 over TLS,
ALPN `http/1.1`, `wss://` WebSockets included.

`RequestContext`: `method`, `path`, `query`, `queryParameters`, `headers`,
`cookies`, `params`, `body`, `bodyStream` (with `streamBody: true`),
`text()`, `jsonMap()`, `jsonList()`, `jsonAs<T>()`, `multipart()`.

`ResponseContext`: `text`, `json`, `jsonBody`, `html`, `bytes`, `redirect`,
`stream`, `file`; `withCookie(SetCookie(...))`. A handler that outlives its
route timeout is dropped after the client's 408. A throwing handler answers
500.

`WsSession`: `messages` (`WsText` | `WsBinary`), `sendText`/`sendBytes`
(return queued bytes, `-1` when closed), `bufferedBytes`, `compressed`,
`close(code)`.

Built-in handlers and middleware: `staticFiles(dir)` (`sendfile`, `etag`,
304, byte ranges, index files), `compress()` (gzip), `cors()`,
`accessLog()`.

`package:nitro_server/testing.dart`: `NitroTestClient`, an in-memory client
over the real runner, no sockets.

## Configuration

| `ServerConfig` | default | meaning |
| -------------- | ------- | ------- |
| `host`, `port`, `backlog` | `127.0.0.1`, `0`, `128` | bind address (IPv6 literals and `::` supported), port (`0` = free), listen backlog |
| `defaultTimeout` | 30 s | handler deadline; 408 on expiry |
| `keepAliveTimeout`, `maxRequestsPerConnection` | 5 s, `100` | idle deadline between requests (`Duration.zero` disables keep-alive); requests per connection (`0` = unbounded) |
| `maxBodyBytes` | 10 MiB | request body cap, 413 above it; per route via `maxBodyBytes:` |
| `headerTimeout` | idle timeout | deadline for a new connection's first request head |
| `writeTimeout` | 30 s | a write with no progress for this long drops the connection and emits `clientError` |
| `maxConnections`, `maxConnectionsPerIp` | `0` = unlimited | refused at accept |
| `workerThreads` | `max(64, 4 × cores)` | cap of the worker pool; the pool starts at one thread per core, grows on demand, retires idle threads after 10 s |
| `isolates` | `1` | Dart isolates running handlers; `0` = half the cores (1–8); requests are dealt round-robin; each isolate runs `setup` |
| `wsMaxBufferBytes`, `wsCompression` | 1 MiB, `true` | WebSocket send queue before a 1009 close; negotiate `permessage-deflate` |
| `tls` | none | any non-empty value throws `ServerTlsException` |

```dart
Future<void> setup(NitroServer server) async {
  await server.get('/report', (_) => ResponseContext.jsonBody(buildReport()));
}

final server = await NitroServer.bind(const ServerConfig(isolates: 0), setup);
```

## Platforms

- iOS: start in the foreground; listener sockets are suspended in the
  background.
- Android: run from a foreground service.
- macOS, Linux, Windows: no constraints.
- Web: unsupported.

## Dart-only use

No Flutter SDK dependency. Build the library with cmake and open it once:

```dart
import 'package:nitro_server/nitro_server.dart';

void main() async {
  loadNitroServerNative(); // build/lib/libnitro_server.{dylib,so,dll}
  final server = await NitroServer.bind();
  await server.get('/hello', (_) => ResponseContext.text('hi 👋'));
}
```

Search order: `path:` argument, `NITRO_SERVER_DYLIB`, `build/lib/<name>`,
`build/<name>`.

## Benchmark

`dart:io HttpServer`, `shelf` and `nitro_server` on identical routes with an
identical driver in separate client isolates; every case asserts exact
bytes. Method, flags and raw results: [`benchmark/`](benchmark/). Apple M1
Pro, loopback, AOT, 64 connections from 4 client isolates, 3 s of load per
case, second of two rounds.

Keep-alive:

| Route | Server | seq p50 µs | seq p99 µs | load p50 µs | load p99 µs | req/s @64 |
|-------|--------|-----------:|-----------:|------------:|------------:|----------:|
| /hello | dart:io | 67 | 140 | 1,855 | 3,174 | 32,782 |
| /hello | shelf | 79 | 153 | 2,564 | 3,348 | 24,273 |
| /hello | nitro | 77 | 179 | 1,149 | 2,944 | 49,489 |
| /json | dart:io | 67 | 127 | 1,837 | 2,482 | 33,875 |
| /json | shelf | 79 | 140 | 2,543 | 3,239 | 24,581 |
| /json | nitro | 72 | 124 | 1,128 | 2,896 | 52,021 |
| /users/:id | dart:io | 69 | 141 | 1,861 | 2,559 | 33,354 |
| /users/:id | shelf | 82 | 162 | 2,604 | 3,479 | 23,847 |
| /users/:id | nitro | 75 | 145 | 1,171 | 3,241 | 50,101 |
| /files/* | dart:io | 69 | 160 | 1,882 | 2,871 | 32,599 |
| /files/* | shelf | 99 | 295 | 2,776 | 3,859 | 22,496 |
| /files/* | nitro | 74 | 156 | 1,155 | 2,675 | 51,398 |
| /q?a=1&b=two | dart:io | 68 | 119 | 1,928 | 2,919 | 31,986 |
| /q?a=1&b=two | shelf | 81 | 178 | 2,669 | 3,543 | 23,199 |
| /q?a=1&b=two | nitro | 73 | 123 | 1,139 | 2,397 | 53,180 |
| /mw | dart:io | 67 | 118 | 1,829 | 2,445 | 34,079 |
| /mw | shelf | 79 | 136 | 2,615 | 4,588 | 22,162 |
| /mw | nitro | 74 | 158 | 1,127 | 2,468 | 53,297 |
| /work | dart:io | 372 | 525 | 18,238 | 29,308 | 3,448 |
| /work | shelf | 382 | 515 | 18,965 | 23,338 | 3,345 |
| /work | nitro | 375 | 526 | 17,562 | 20,955 | 3,595 |
| /file | dart:io | 187 | 352 | 5,605 | 9,971 | 10,731 |
| /file | shelf | 227 | 665 | 6,616 | 13,007 | 9,040 |
| /file | nitro | 147 | 306 | 4,804 | 12,120 | 12,679 |
| POST /echo 4k | dart:io | 143 | 286 | 2,403 | 5,054 | 24,806 |
| POST /echo 4k | shelf | 149 | 291 | 3,004 | 4,471 | 20,597 |
| POST /echo 4k | nitro | 144 | 232 | 1,787 | 3,361 | 33,266 |
| POST /echo 1m | dart:io | 14,706 | 15,687 | 259,430 | 546,536 | 255 |
| POST /echo 1m | shelf | 14,843 | 31,390 | 263,898 | 571,859 | 224 |
| POST /echo 1m | nitro | 14,933 | 16,419 | 261,244 | 515,991 | 254 |
| GET /events | dart:io | 97 | 170 | 3,177 | 3,812 | 19,777 |
| GET /events | shelf | 89 | 155 | 2,851 | 3,556 | 21,991 |
| GET /events | nitro | 94 | 151 | 1,766 | 3,921 | 34,710 |

Ratios in that table: small routes 1.5–1.7× dart:io's throughput at 37–41%
lower load p50; `GET /events` 1.8×; `POST /echo 4k` 1.3×; `/file` 1.2×
(2.1× with the raw-socket driver: 24.6k vs 11.8k req/s); `/work` and
`POST /echo 1m` equal (handler-bound and bandwidth-bound). Sequential p50
on an idle connection is within 10 µs of dart:io.

`Connection: close` (sequential latency only; a load sweep in this mode
measures the client's ephemeral-port budget):

| Route | Server | seq p50 µs | seq p99 µs |
|-------|--------|-----------:|-----------:|
| /hello | dart:io | 173 | 391 |
| /hello | shelf | 184 | 458 |
| /hello | nitro | 139 | 260 |
| /json | dart:io | 161 | 339 |
| /json | shelf | 170 | 300 |
| /json | nitro | 149 | 290 |
| /users/:id | dart:io | 160 | 288 |
| /users/:id | shelf | 172 | 308 |
| /users/:id | nitro | 150 | 311 |
| /files/* | dart:io | 166 | 375 |
| /files/* | shelf | 170 | 311 |
| /files/* | nitro | 145 | 270 |
| /q?a=1&b=two | dart:io | 163 | 378 |
| /q?a=1&b=two | shelf | 169 | 309 |
| /q?a=1&b=two | nitro | 139 | 247 |
| /mw | dart:io | 161 | 301 |
| /mw | shelf | 182 | 355 |
| /mw | nitro | 139 | 272 |
| /work | dart:io | 472 | 676 |
| /work | shelf | 487 | 720 |
| /work | nitro | 484 | 664 |
| /file | dart:io | 265 | 462 |
| /file | shelf | 277 | 446 |
| /file | nitro | 201 | 375 |
| POST /echo 4k | dart:io | 231 | 425 |
| POST /echo 4k | shelf | 246 | 439 |
| POST /echo 4k | nitro | 218 | 405 |
| POST /echo 1m | dart:io | 15,195 | 16,851 |
| POST /echo 1m | shelf | 15,155 | 16,158 |
| POST /echo 1m | nitro | 15,036 | 19,874 |
| GET /events | dart:io | 184 | 361 |
| GET /events | shelf | 174 | 283 |
| GET /events | nitro | 155 | 243 |

## Limits

- HTTP/1.1 only (no HTTP/2).
- One native thread per live connection: suited to hundreds of concurrent
  connections, not thousands.
- `close(drain:)` resets connections still in the kernel backlog only if
  they arrive after the drain's final accept sweep.

## Developing

`lib/src/nitro_server.native.dart` is the bridge spec. Regenerate with
`dart run build_runner build`; `*.g.*` files are never edited by hand.

```sh
cmake -S src -B build/lib -DCMAKE_BUILD_TYPE=Release -DNITRO_SERVER_BUILD_TESTS=ON
cmake --build build/lib --parallel
./build/lib/nitro_server_tests/nitro_server_engine_tests   # C++ suite
dart test                                                  # Dart suites
bash tool/coverage.sh                                      # Dart 100% line gate
bash tool/cpp_coverage.sh 90                               # engine line gate
```

Sanitizers and fuzzing (clang):

```sh
cmake -S src -B build/san -DNITRO_SERVER_BUILD_TESTS=ON -DNITRO_SERVER_SANITIZE=thread
cmake --build build/san --parallel --target nitro_server_engine_tests
./build/san/nitro_server_tests/nitro_server_engine_tests   # ThreadSanitizer
bash tool/fuzz.sh 60                                        # libFuzzer: head, frame, socket
```

`.github/workflows/ci.yml` runs the suites, both coverage gates, and the
thread and address sanitizers on Linux and macOS. Fuzzing is a local tool
(`tool/fuzz.sh`); `test/fuzz` is not tracked.

Tests: `server_config_test` (types, mapping), `runner_test` (dispatch and
ack protocol, fakes), `server_edge_cases_test`, `server_facade_test`,
`features_test` (compress, metrics, cookies, multipart, static files),
`fast_calls_test` (leaf-call wire format), `native_loader_test`,
`test_client_test`, `server_e2e_test` (native engine over sockets),
`server_conformance_test` (RFC 9110/9112 over raw sockets), `test/cpp`
(gtest engine suite).
