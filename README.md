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
| `server.route(method, pattern, handler, {timeout, customMethod, middleware})` | the general form, custom verbs included |
| `server.use(middleware)` | server-wide middleware, outermost first |
| `server.group(prefix)` | a path-prefixed view with its own middleware |
| `server.ws(pattern, handler)` | a WebSocket route (RFC 6455); the handler gets a `WsSession` |
| `server.notFoundHandler = …`, `server.errorHandler = …` | custom 404 and 500 answers |
| `server.unroute(method, pattern)` | removes a route; `RouteNotFoundException` if absent |
| `server.events` | broadcast lifecycle stream: started, stopped, handler timeouts |
| `server.close()` | stops, answers parked requests with 503; idempotent |

A handler receives a `RequestContext` (method, path, query, headers,
`:param` captures, the assembled body with `text()`, `jsonMap()`,
`jsonList()`, `jsonAs<T>()`) and returns a `ResponseContext` through the
`text`, `json`, `jsonBody`, `html`, `bytes`, `redirect` or `stream`
factories. A handler that outlives its route timeout loses: the client
already received a 408 and the late value is dropped. A throwing handler is
a 500 and the server keeps running.

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
| /hello | dart:io | 70 | 151 | 1,871 | 3,032 | 31,604 |
| /hello | shelf | 82 | 203 | 2,663 | 4,525 | 22,567 |
| /hello | nitro | 74 | 139 | 1,176 | 2,821 | 48,940 |
| /json | dart:io | 70 | 143 | 1,941 | 3,469 | 29,483 |
| /json | shelf | 82 | 174 | 2,647 | 3,868 | 22,663 |
| /json | nitro | 78 | 162 | 1,196 | 3,444 | 46,636 |
| /users/:id | dart:io | 72 | 164 | 1,890 | 2,942 | 31,548 |
| /users/:id | shelf | 82 | 190 | 2,612 | 3,419 | 23,895 |
| /users/:id | nitro | 78 | 178 | 1,223 | 4,371 | 45,455 |
| /files/* | dart:io | 71 | 176 | 1,916 | 2,820 | 32,217 |
| /files/* | shelf | 89 | 186 | 2,695 | 3,855 | 22,421 |
| /files/* | nitro | 74 | 148 | 1,130 | 2,591 | 52,682 |
| /q?a=1&b=two | dart:io | 70 | 147 | 1,969 | 2,824 | 31,470 |
| /q?a=1&b=two | shelf | 85 | 199 | 2,624 | 3,417 | 23,185 |
| /q?a=1&b=two | nitro | 74 | 142 | 1,143 | 2,538 | 52,412 |
| /mw | dart:io | 68 | 136 | 1,853 | 2,571 | 33,490 |
| /mw | shelf | 80 | 148 | 2,555 | 3,422 | 23,700 |
| /mw | nitro | 73 | 139 | 1,188 | 2,722 | 50,496 |
| /work | dart:io | 385 | 602 | 18,377 | 21,013 | 3,435 |
| /work | shelf | 394 | 656 | 19,266 | 34,330 | 3,269 |
| /work | nitro | 396 | 634 | 17,496 | 19,188 | 3,634 |
| POST /echo 4k | dart:io | 134 | 220 | 2,194 | 3,069 | 28,043 |
| POST /echo 4k | shelf | 147 | 235 | 2,908 | 3,881 | 21,338 |
| POST /echo 4k | nitro | 143 | 241 | 1,949 | 4,049 | 29,340 |
| POST /echo 1m | dart:io | 15,147 | 18,432 | 278,460 | 692,468 | 236 |
| POST /echo 1m | shelf | 14,747 | 15,351 | 261,539 | 420,825 | 255 |
| POST /echo 1m | nitro | 14,789 | 17,589 | 258,429 | 511,069 | 251 |
| GET /events | dart:io | 103 | 262 | 3,195 | 4,043 | 19,438 |
| GET /events | shelf | 89 | 189 | 2,878 | 3,863 | 21,685 |
| GET /events | nitro | 95 | 188 | 1,727 | 3,778 | 35,801 |

`Connection: close` on every side (every request pays a TCP handshake):

| Route | Server | seq p50 µs | seq p99 µs | load p50 µs | load p99 µs | req/s @64 |
|-------|--------|-----------:|-----------:|------------:|------------:|----------:|
| /hello | dart:io | 172 | 265 | 3,319 | 16,157 | 14,999 |
| /hello | shelf | 198 | 366 | 3,913 | 10,052 | 14,327 |
| /hello | nitro | 161 | 322 | 3,189 | 11,160 | 17,573 |
| /json | dart:io | 176 | 312 | 3,445 | 10,239 | 15,534 |
| /json | shelf | 197 | 418 | 4,236 | 10,647 | 13,085 |
| /json | nitro | 159 | 302 | 3,357 | 11,312 | 16,660 |
| /users/:id | dart:io | 191 | 398 | 3,330 | 11,140 | 15,474 |
| /users/:id | shelf | 209 | 433 | 3,931 | 9,070 | 14,156 |
| /users/:id | nitro | 158 | 298 | 3,426 | 12,236 | 15,469 |
| /files/* | dart:io | 184 | 380 | 3,175 | 10,789 | 17,238 |
| /files/* | shelf | 192 | 333 | 3,966 | 9,773 | 13,908 |
| /files/* | nitro | 155 | 254 | 3,184 | 9,891 | 17,782 |
| /q?a=1&b=two | dart:io | 177 | 302 | 3,260 | 9,518 | 16,318 |
| /q?a=1&b=two | shelf | 190 | 311 | 4,019 | 9,344 | 14,067 |
| /q?a=1&b=two | nitro | 155 | 263 | 3,234 | 10,916 | 17,126 |
| /mw | dart:io | 186 | 452 | 3,534 | 11,059 | 15,149 |
| /mw | shelf | 200 | 425 | 3,976 | 8,830 | 14,110 |
| /mw | nitro | 155 | 263 | 3,185 | 11,296 | 16,585 |
| /work | dart:io | 477 | 740 | 20,010 | 38,534 | 3,080 |
| /work | shelf | 510 | 1,046 | 20,712 | 30,109 | 3,057 |
| /work | nitro | 488 | 688 | 17,890 | 34,191 | 3,454 |
| POST /echo 4k | dart:io | 241 | 380 | 3,566 | 5,761 | 15,974 |
| POST /echo 4k | shelf | 255 | 401 | 4,218 | 6,605 | 13,757 |
| POST /echo 4k | nitro | 228 | 356 | 3,750 | 8,686 | 15,066 |
| POST /echo 1m | dart:io | 15,451 | 23,082 | 243,258 | 469,459 | 246 |
| POST /echo 1m | shelf | 15,402 | 23,847 | 264,279 | 511,168 | 224 |
| POST /echo 1m | nitro | 15,689 | 25,511 | 276,566 | 743,830 | 196 |
| GET /events | dart:io | 222 | 639 | 5,330 | 38,288 | 10,395 |
| GET /events | shelf | 198 | 428 | 4,525 | 7,345 | 12,650 |
| GET /events | nitro | 191 | 495 | 3,939 | 66,707 | 11,411 |

What the tables say: under keep-alive load nitro serves the small routes at
about 1.5× dart:io's rate with about 35% lower p50, and streams at about
1.8×, because parsing, routing and the write happen off the Dart isolate.
`/work` is handler-bound and equal on every side at one isolate; see
Scaling above. On one idle connection the two are within a few
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
  permessage-deflate.
- Request bodies are capped by `maxBodyBytes` (default 10 MiB); above it the
  engine answers 413 without dispatching. Response bodies may stream without
  bound via `ResponseContext.stream`; the route timeout then bounds
  time-to-first-byte only.
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
