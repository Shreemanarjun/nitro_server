# nitro_server

A fast HTTP server for Flutter backed by a native multithreaded C++ engine
over Nitro FFI — the listener twin of
[`nitro_http`](https://github.com/Shreemanarjun/nitro_http), built with the
same nitrogen_cli pattern, the same test discipline, and the same honesty
about numbers.

```dart
import 'package:nitro_server/nitro_server.dart';

final server = await NitroServer.bind(); // ephemeral port, 127.0.0.1

await server.get('/hello', (_) async => ResponseContext.text('hi 👋'));
await server.get('/users/:id', (request) async {
  return ResponseContext.json('{"id": "${request.param('id')}"}');
});
await server.post('/echo', (request) async {
  return ResponseContext.bytes(request.body);
});

print('listening on http://127.0.0.1:${server.port}');
await server.close();
```

## How it works

One `NitroServer` owns one native accept loop. Each connection runs on its own
worker thread: parse → trie route lookup → dispatch to Dart over a stream →
park on that request's **own** condition variable until your handler answers
with `respond` or the route's timeout fires. No shared bridge lock, no
callbacks (one `NativeCallable` slot per method would clobber concurrent
requests — the same lesson `nitro_http` learned), and the Dart isolate never
blocks. That is the whole deadlock story.

Routing is a segment trie built on day one: `:param` captures, trailing `*`
wildcards, static-beats-param-beats-wildcard precedence, per-route timeouts.

## API

| call | does |
| ---- | ---- |
| `NitroServer.bind([config])` | binds + starts; port `0` picks a free one, read back from `server.port` |
| `server.get/post/put/delete/patch/head/options/all(pattern, handler)` | one-line route registration |
| `server.route(method, pattern, handler, {timeout, customMethod})` | full control, incl. custom verbs |
| `server.unroute(method, pattern)` | removes a route (`RouteNotFoundException` if absent) |
| `server.close()` | stops, answers parked requests with 503, idempotent |
| `server.events` | broadcast lifecycle stream (started, stopped, handler timeouts) |

Handlers receive a `RequestContext` (method, path, query, headers, `:param`
captures, assembled body) and return a `ResponseContext` (status, headers,
body) via the `text` / `json` / `bytes` factories. A handler that outlives its
route timeout loses: the client already got a 408 and the late value is
dropped, never sent twice. A throwing handler is a 500; the server survives.

## Platform lifecycle (loud by design)

- **iOS:** start only in the foreground — the OS suspends listener sockets in
  the background. The example app stops its server when backgrounded rather
  than letting it die silently.
- **Android:** serve from a foreground service; the engine cannot keep the
  process alive by itself.
- **Desktop:** no constraints — the reference platform for testing.
- **Web:** unsupported. Browsers cannot bind raw sockets; there is no shim.

## How it compares

For Dart servers the realistic alternatives are `dart:io HttpServer` (stdlib),
`shelf`/`shelf_io` (which sits on `dart:io`), and framework servers like
Alfred. Dimensions that actually differ:

| dimension | `dart:io` / shelf | `nitro_server` |
| --------- | ----------------- | -------------- |
| connection handling | single-threaded event loop; slow handlers stall the loop unless offloaded to isolates | native thread per connection; a slow handler costs one thread, never the loop |
| routing | manual (`request.uri.path` switches) or shelf_router middleware | built-in trie with `:param` + `*`, static-first precedence |
| per-route timeouts | hand-rolled `Future.timeout` per handler | enforced natively per route; late answers dropped exactly once |
| request size cap | manual content-length accounting | `maxBodyBytes` enforced while streaming (413 + no dispatch) |
| upload streaming | `Stream<List<int>>` on the event loop | zero-copy chunk stream with ack-based release |
| TLS | `SecurityContext` (mature) | **not yet** — non-empty TLS config fails honestly with `ServerTlsException` |
| keep-alive | yes | no (v1 closes every connection; see below) |
| web | n/a (server) | unsupported |

Measured, not claimed — same routes, same driver, interleaved A/B (see
[`benchmark/`](benchmark/) for methodology and how to re-run):

```
| case                 | mean µs | p50 µs | p99 µs | req/s @32 |
| dart:io /hello       |     215 |    198 |    564 |      7780 |
| nitro   /hello       |     176 |    160 |    401 |     10233 |
| dart:io POST /echo 4k|     200 |    185 |    424 |      6888 |
| nitro   POST /echo 4k|     205 |    190 |    465 |      8696 |
```

Read narrowly: the native accept loop shaves scheduling latency and scales
small-route throughput ~1.3× on loopback; on a 4 KB echo both sides are socket
copy and land at parity. Keep-alive would change the picture in `dart:io`'s
favor for tiny routes — that is exactly why the table says what was measured
(`Connection: close` both sides) instead of crowning a winner. Run
`dart run benchmark/compare.dart` on your hardware before quoting anything.

## Limits (v1, stated plainly)

- HTTP/1.1 only; responses always close the connection.
- No TLS yet (`supportsTls() == false`; tracked for the `oatpp-libressl` phase).
- Bodies capped by `maxBodyBytes` (default 10 MB); above it the engine answers
  413 without dispatching.
- The transport is a minimal blocking-IO core shaped like oat++'s
  `HttpConnectionHandler` so the router, pending table and bridge protocol
  move over unchanged when oat++ is vendored.

## Developing

The Nitro spec `lib/src/nitro_server.native.dart` is the source of truth —
change it and run `nitrogen generate`, never edit `*.g.*` files. CI fails if
regeneration is not a no-op.

```sh
# native library (needed by the e2e + conformance suites; they skip without it)
cmake -S src -B build/lib -DCMAKE_BUILD_TYPE=Release
cmake --build build/lib --parallel

# Dart: 102 tests, 100% line floor enforced
flutter test
bash tool/coverage.sh

# C++: 36 tests (router, pending table, wire, loopback server)
cmake -S src -B build/cpp_test -DCMAKE_BUILD_TYPE=Release -DNITRO_SERVER_BUILD_TESTS=ON
cmake --build build/cpp_test --parallel
./build/cpp_test/nitro_server_tests/nitro_server_engine_tests
```

Test map: `server_config_test` (types + mapping tables) · `runner_test`
(dispatch + ack protocol, fakes) · `server_edge_cases_test` (wild inputs,
fakes) · `server_facade_test` (public entry points, fakes) ·
`server_e2e_test` (native: start/stop, params, 32-way concurrency, per-route
timeout) · `server_conformance_test` (RFC 9110/9112 matrix over raw sockets) ·
`test/cpp` (gtest engine suite). Nothing depends on `dart:io HttpServer`,
`shelf`, or the network — the driver is `HttpClient` + raw `Socket`s against
loopback, or fakes.
