## 1.0.0

First stable release. A production HTTP/1.1 + WebSocket server for Dart and
Flutter, backed by a native multithreaded C++ (libuv) engine over Nitro FFI.

### Server & routing

* `NitroServer.bind([config, setup])` opens the native library itself and starts
  listening; port `0` picks a free port. `bindWith(dylibPath:)` loads a specific
  library.
* Trie routing: `:param`, trailing `*`, static > param > wildcard,
  method-specific > `all`, HEAD falls back to GET. Verb shorthands
  (`get`/`post`/`put`/`delete`/`patch`/`head`/`options`/`all`), `route` for
  custom verbs, `group(prefix)` for prefixed sub-routers, `unroute`.
* Per-route `timeout`, `maxBodyBytes`, `middleware`, `streamBody`.
* `server.config`, `server.uri`, `server.routes` (a `RegisteredRoute` snapshot),
  `server.events`, `server.metrics`, `server.onClose`.
* `server.reload([setup])`: rebuilds the routing surface on the live socket,
  transactionally (old routes serve until the new ones register; a throwing
  `setup` rolls back), across all isolates.
* `close({drain})`: stop now, or drain in-flight requests up to a deadline.

### Handlers

* `RequestContext`: `headers`, `cookies`, `params`, `query`, `body`,
  `bodyStream`, `text()`, `jsonMap()`, `jsonList()`, `jsonAs<T>()`, `multipart()`.
* `ResponseContext`: `text`, `json`, `jsonBody`, `html`, `bytes`, `redirect`,
  `stream`, `file`, `withCookie`. Sync handlers answer without a `Future`.

### WebSocket

* RFC 6455 handshake and frame loop in the engine; text/binary, ping/pong, close
  codes, `permessage-deflate` (RFC 7692), subprotocol selection.
* `WsSession`: `messages`, `sendText`/`sendBytes`, `bufferedBytes`, `compressed`,
  `close(code)`; 1009 past `wsMaxBufferBytes`.

### Middleware & production add-ons

* Built-in middleware: `cors()`, `compress()` (gzip/brotli), `accessLog()`,
  `rateLimit()` (per-client fixed window), `bearerAuth()`/`apiKeyAuth()`/
  `basicAuth()`.
* `serveObservability(server)`: `/healthz`, `/readyz` (503 while draining),
  Prometheus `/metrics`, and a self-contained live `/dashboard`
  (`prometheusFormat`/`metricsJson` are the pure renderers).
* OpenAPI 3.1 generated from the registered routes: `serveOpenApi(server)` serves
  `/openapi.json` + Swagger UI at `/docs`; the `OpenApi` wrapper captures
  per-route docs inline at registration; non-HTTP routes (WebSocket, custom
  verbs) are surfaced under `x-additional-routes`.
* `shutdownOnSignals(server)`: graceful SIGTERM/SIGINT drain (`GracefulShutdown`
  can also be triggered programmatically).
* `staticFiles(dir)`: `sendfile`, `etag`, `last-modified`, 304, byte ranges,
  index files, traversal protection.

### Engine

* libuv reactor: one event loop per core over `SO_REUSEPORT`; connection state
  is read-event driven, not a thread per connection.
* Adaptive dispatch: deals requests across only as many of the configured
  `isolates` as raise throughput — light handlers stay on one, CPU-bound/mixed
  ones fan out — so `isolates` can be the core count for any workload.
* Direct-write answers (one non-blocking `sendmsg`), `sendfile` for files,
  per-isolate head coalescing, leaf-call FFI for `respond`/stream.
* HTTP/1.1 with keep-alive, pipelining, `Expect: 100-continue`, chunked uploads,
  chunked/file responses. Request-smuggling defense (RFC 9112).
* TLS via OpenSSL when built with it (`ServerConfig.tls`): HTTP/1.1 + `wss://`,
  ALPN `http/1.1`.

### Tooling & deployment

* `package:nitro_server/testing.dart`: `NitroTestClient`, an in-memory client
  over the real runner (no sockets, no native library).
* `package:nitro_server/hot_reload.dart`: `enableHotReload(server)` wires VM hot
  reload to `reload()` (opt-in `hotreloader` dev-dependency).
* Deployment: multi-stage `Dockerfile`, `docker-compose.yml`, `fly.toml`,
  `netlify.toml` (static-frontend proxy), and `bin/server.dart` reference
  entrypoint. Guide: `docs/deployment.md`.
* 100% Dart line coverage and a C++ engine coverage gate; ThreadSanitizer and
  AddressSanitizer in CI; libFuzzer targets for the head/frame parsers.
