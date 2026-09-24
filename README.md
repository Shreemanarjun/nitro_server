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
| `server.port`, `server.config`, `server.uri` | the bound port, the resolved `ServerConfig` it started with (port and isolates filled in), and the base URL (`http(s)://host:port`) |
| `server.reload([setup])` | rebuilds every route on the live socket — re-runs `setup` (or the one `bind` was given), so added, removed and changed routes take effect without dropping the port; single-isolate. Turnkey hot reload: `package:nitro_server/hot_reload.dart` |
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

No Flutter SDK dependency. Build the library with cmake; `bind` opens it
automatically — Flutter bundles the native library, a Dart CLI builds it, and
either way you never call the loader by hand:

```dart
import 'package:nitro_server/nitro_server.dart';

void main() async {
  final server = await NitroServer.bind(); // finds build/lib/libnitro_server.*
  await server.get('/hello', (_) => ResponseContext.text('hi 👋'));
}
```

`bind` searches `NITRO_SERVER_DYLIB`, then `build/lib/<name>`, then
`build/<name>`. To load from a custom path, call
`loadNitroServerNative(path: ...)` before `bind` (idempotent).

## Hot reload

`server.reload()` rebuilds the whole routing surface on the live socket, so a
`setup` edit takes effect without a restart. Wire it to VM hot reload with the
opt-in helper (add `hotreloader` to your `dev_dependencies`):

```dart
import 'package:nitro_server/nitro_server.dart';
import 'package:nitro_server/hot_reload.dart';

void main() async {
  final server = await NitroServer.bind(const ServerConfig(port: 8080), setup);
  await enableHotReload(server); // re-runs `setup` after every hot reload
}
```

Pass `enableHotReload(server, log: print)` to trace reloads (watched dirs, each
change, the VM result, the route rebuild); it is silent otherwise. `watch:`
overrides which directories are watched.

Run it with `dart run --enable-vm-service bin/server.dart`, then edit a handler
and save. `setup` must be a **top-level or static function** (not an inline
`bind(config, (s) async { … })` closure) — Dart hot reload doesn't re-patch a
stored anonymous closure. Handlers written inline inside `setup` are fine.
`enableHotReload` also watches the entry script's own directory, so a server
run from anywhere (not just `bin`/`lib`) reloads.

## Benchmark

`dart:io HttpServer`, `shelf` and `nitro_server` on identical routes with an
identical driver in separate client isolates; every case asserts exact
bytes. Method, flags and full per-route tables (keep-alive and
`Connection: close`): [`benchmark/`](benchmark/). Apple M1 Pro, loopback, AOT,
64 connections from 4 client isolates, 3 s of load per case.

Headline: on small routes nitro sustains **1.5–1.7× dart:io's throughput** at
37–41% lower load p50 (`GET /events` 1.8×, `POST /echo 4k` 1.3×, `/file` 1.2×;
`/work` and `POST /echo 1m` are handler- and bandwidth-bound, so they tie).
Sequential p50 on an idle connection is within 10 µs of dart:io. For a fast C
client (`wrk`) and the Go/Node comparison, see
[`docs/benchmark-results.md`](docs/benchmark-results.md).

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
