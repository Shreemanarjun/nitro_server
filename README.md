# nitro_server

An HTTP/1.1 and WebSocket server for Dart and Flutter. A native C++ engine
(over [Nitro](https://pub.dev/packages/nitro) FFI) accepts, parses, routes
and writes; your handlers run on the Dart isolate. Same tooling and test
discipline as [`nitro_http`](https://github.com/Shreemanarjun/nitro_http),
its client twin.

```dart
import 'package:nitro_server/nitro_server.dart';

final server = await NitroServer.bind(); // 127.0.0.1, free port

await server.get('/hello', (_) async => ResponseContext.text('hi 👋'));
await server.get('/users/:id', (request) async {
  return ResponseContext.jsonBody({'id': request.param('id')});
});
await server.post('/echo', (request) async {
  return ResponseContext.bytes(request.body);
});

print('listening on http://127.0.0.1:${server.port}');
await server.close();
```

## How it works

One `NitroServer` owns one native accept loop. A connection is served by a
native worker thread: parse, route through a segment trie, hand the request
to Dart over a stream, then park in `poll()` until the answer is on the wire
or the route's timeout fires.

The answer is written by the thread that produces it. Your handler's
`respond` serializes status, headers and body and writes them to the socket
with one non-blocking `sendmsg` on the Dart thread. Nothing is copied into a
queue and no thread is woken; the next request's bytes wake the worker.
Bytes the socket buffer cannot take yet become a tail the worker flushes.
Stream chunks always go through that tail, so a burst of small chunks
leaves in a few syscalls instead of one per chunk.

There is no shared bridge lock and there are no callbacks: each request
waits on its own state under its own mutex, and the Dart isolate never
blocks.

Routing: `:param` captures, a trailing `*` wildcard, static beats param
beats wildcard, per-route timeouts, `HttpMethod.all` as the fallback.

## API

| call | does |
| ---- | ---- |
| `NitroServer.bind([config, setup])` | binds and starts; port `0` picks a free one, read it from `server.port`; `setup` registers routes before the first request (required when `isolates > 1`) |
| `server.get/post/put/delete/patch/head/options/all(pattern, handler)` | route registration |
| `server.route(method, pattern, handler, {timeout, customMethod, middleware, streamBody})` | the general form, custom verbs included; `streamBody: true` runs the handler on the head and delivers the upload on `request.bodyStream` |
| `server.use(middleware)` | server-wide middleware, outermost first |
| `server.group(prefix)` | a path-prefixed view with its own middleware |
| `server.ws(pattern, handler)` | a WebSocket route (RFC 6455); the handler gets a `WsSession` |
| `server.notFoundHandler = …`, `server.errorHandler = …` | custom 404 and 500 answers |
| `server.unroute(method, pattern)` | removes a route; `RouteNotFoundException` if absent |
| `server.events` | broadcast lifecycle stream: started, stopped, handler timeouts |
| `server.metrics` | per-route request counts, 5xx counts and latency p50/p90/p99 |
| `server.close({drain})` | stops now (parked requests get 503), or with `drain:` stops accepting first and waits up to that long for in-flight requests |

A handler receives a `RequestContext` (method, path, query, headers,
`cookies`, `:param` captures, the assembled body with `text()`, `jsonMap()`,
`jsonList()`, `jsonAs<T>()`, `multipart()`) and returns a `ResponseContext`
through the `text`, `json`, `jsonBody`, `html`, `bytes`, `redirect`,
`stream` or `file` factories, plus `withCookie(SetCookie(...))`. A handler
that outlives its route timeout loses: the client already received a 408
and the late value is dropped. A throwing handler is a 500 and the server
keeps running. HEAD requests use the GET route when no HEAD route exists.

Built in: `staticFiles(dir)` (native `sendfile`, `etag`, 304, byte ranges),
`compress()` (gzip when the client accepts it), `cors()`, `accessLog()`.
`ServerConfig` also caps `maxConnections` and `maxConnectionsPerIp` at the
door and cuts silent connections at `headerTimeout`.

`package:nitro_server/testing.dart` has an in-memory `NitroTestClient` for
handler tests without sockets.

## Scaling

| knob | default | effect |
| ---- | ------- | ------ |
| `ServerConfig.workerThreads` | `0` = `max(64, 4 × cores)` | Cap of the native worker pool. The pool starts at one thread per core, grows when a connection is queued and nobody is idle, and retires threads above the floor after 10 s idle. A worker is pinned to its connection while a handler runs, so the cap must exceed the keep-alive connections you expect to hold at once. |
| `ServerConfig.isolates` | `1` | Dart isolates running handlers behind the one engine; `0` picks half the cores (1 to 8). Requests are dealt round-robin. Every isolate runs the `setup` function given to `bind`, so register routes there. Use it when handlers do real CPU work: one isolate serves 60k `/hello` req/s but only 3.4k of a JSON-encoding handler, and four isolates make that 10.9k (numbers in `PERFORMANCE_PLAN.md`). |

```dart
Future<void> setup(NitroServer server) async {
  await server.get('/report', (_) async => ResponseContext.jsonBody(buildReport()));
}

final server = await NitroServer.bind(const ServerConfig(isolates: 0), setup);
```

## Platform lifecycle

- **iOS:** start in the foreground only; the OS suspends listener sockets in
  the background. The example app stops its server when backgrounded.
- **Android:** serve from a foreground service; the engine cannot keep the
  process alive.
- **Desktop:** no constraints; the reference platform for testing.
- **Web:** unsupported. Browsers cannot bind sockets.

## Dart-only mode

The package has no Flutter SDK dependency: `dart pub get`, `dart test` and
`dart run` work. Flutter apps are unchanged; the `ffiPlugin` metadata still
builds and bundles the native library.

A Dart CLI program builds the library with cmake and opens it once:

```dart
import 'package:nitro_server/nitro_server.dart';

void main() async {
  loadNitroServerNative(); // opens build/lib/libnitro_server.{dylib,so,dll}
  final server = await NitroServer.bind();
  await server.get('/hello', (_) async => ResponseContext.text('hi 👋'));
  print('listening on http://127.0.0.1:${server.port}');
}
```

`NITRO_SERVER_DYLIB` or an explicit `path:` overrides the search, which
defaults to `build/lib/<name>` then `build/<name>`.

## How it compares

The Dart alternatives are `dart:io HttpServer` and `shelf` (which runs on
`dart:io`).

| | `dart:io` / shelf | `nitro_server` |
| - | ----------------- | -------------- |
| connection handling | one event loop; a slow handler stalls it unless moved to another isolate | native thread per connection; a slow handler costs one thread |
| answer path | handler → Dart socket buffer → event-loop write | handler → one non-blocking `sendmsg`, no copy, no wake |
| routing | by hand, or `shelf_router` | built-in trie with `:param` and `*` |
| per-route timeouts | `Future.timeout` by hand | native, per route; a late answer is dropped exactly once |
| request size cap | by hand | `maxBodyBytes`, enforced while streaming (413, no dispatch) |
| static files | `File.openRead()` through the isolate | `sendfile` from a native worker; bytes never enter Dart |
| scaling handlers | `HttpServer.bind(shared: true)` per isolate | `ServerConfig.isolates` |
| TLS | `SecurityContext` | not yet; a non-empty `TlsConfig` throws `ServerTlsException` |
| web | n/a | unsupported |

Same routes, same driver, same machine, interleaved rounds; every case
asserts exact bytes. AOT (`dart compile exe`), Apple M1 Pro, loopback,
64 connections from 4 client isolates, 3 s per case, second of two rounds.
Method and flags: [`benchmark/`](benchmark/).

Keep-alive on every side:

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

`Connection: close` on every side (every request pays a TCP handshake):

__CLOSE_TABLE__

What the tables say: under keep-alive load nitro serves the small routes at
about 1.5× dart:io's rate with about 40% lower p50, and streams at about
1.8×, because parsing, routing and the write happen off the Dart isolate.
The 64 KiB static file reads 1.2× in the table, where the `HttpClient`
driver bounds it, and 2× with the raw-socket client (24.6k vs 11.8k req/s):
`sendfile` never copies it into Dart. `/work` is handler-bound and equal
on every side at one isolate; see Scaling above. On one idle connection the two are within a few
microseconds: nitro's remaining worker-to-isolate hop costs about what
dart:io's parsing costs. The 1 MiB echo is bound by loopback bandwidth.
With `Connection: close` the handshake dominates: throughput is within
10% on every case, and nitro's tails on streaming and the 1 MiB echo are
worse than dart:io's. `PERFORMANCE_PLAN.md` records how these numbers came
about and what limits them now.

## Limits

- HTTP/1.1 only.
- No TLS (`supportsTls()` is false).
- WebSocket: text and binary messages, ping/pong, close codes; no
  permessage-deflate, and sends are synchronous (no backpressure signal).
- Request bodies are capped by `maxBodyBytes` (default 10 MiB); above it the
  engine answers 413 without dispatching. Routes with `streamBody: true`
  read past that as they go. Response bodies may stream without bound via
  `ResponseContext.stream`; the route timeout then bounds
  time-to-first-byte only.
- `close(drain:)` keeps connections the engine has accepted; a connection
  still in the kernel backlog at that moment is reset with the listener.
- Thread per connection: fine to a few hundred live keep-alive connections;
  a poller-based reactor is the planned step beyond that.

## Developing

`lib/src/nitro_server.native.dart` is the source of truth for the bridge.
Change it and regenerate with `dart run build_runner build`; never edit
`*.g.*` files. CI fails if regeneration is not a no-op.

```sh
# native library (the e2e and conformance suites skip without it)
cmake -S src -B build/lib -DCMAKE_BUILD_TYPE=Release
cmake --build build/lib --parallel

# Dart suites (no Flutter SDK needed) and the coverage gate
dart test
bash tool/coverage.sh

# C++ engine suite: router, pending table, wire, loopback server
cmake -S src -B build/lib -DCMAKE_BUILD_TYPE=Release -DNITRO_SERVER_BUILD_TESTS=ON
cmake --build build/lib --parallel
./build/lib/nitro_server_tests/nitro_server_engine_tests
```

Test map: `server_config_test` (types, mapping tables) · `runner_test`
(dispatch and ack protocol, fakes) · `server_edge_cases_test` (wild inputs,
fakes) · `server_facade_test` (public entry points, fakes) ·
`fast_calls_test` (wire format of the leaf-call path) · `server_e2e_test`
(native: lifecycle, params, concurrency, timeouts, isolates, WebSocket) ·
`server_conformance_test` (RFC 9110/9112 matrix over raw sockets) ·
`test_client_test` · `test/cpp` (gtest engine suite). Tests never depend on
`dart:io HttpServer`, `shelf` or the network.
