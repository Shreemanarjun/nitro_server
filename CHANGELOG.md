## 0.0.1

Initial release.

### Server

* HTTP/1.1 with keep-alive, pipelining, `Expect: 100-continue`, chunked
  uploads, chunked and file responses.
* Request-smuggling defense (RFC 9112 §6.1/§6.3.3/§3.2): rejects
  Content-Length with Transfer-Encoding, duplicated Content-Length, and a
  missing or duplicated Host on HTTP/1.1 with 400 before routing.
* Trie routing: `:param`, trailing `*`, static > param > wildcard,
  method-specific > `all`, HEAD falls back to GET.
* `staticRoute` / `getStatic`: a fixed-response route answered entirely inside
  the engine — the request never crosses into Dart, so it serves at raw engine
  speed (~122k req/s vs dart:io's ~96k on a saturating load, ~60% over nitro's
  own handler path). The engine frames `Content-Length`/`Connection` and
  answers HEAD headers-only; ideal for health checks, static assets, and
  cached bodies. `getStatic` is the GET shorthand; `staticRoute` takes any
  method (custom included). See `benchmark/README.md`.
* Per-route `timeout`, `maxBodyBytes`, `middleware`, `streamBody`.
* `ServerConfig`: `maxBodyBytes`, `keepAliveTimeout`,
  `maxRequestsPerConnection`, `headerTimeout`, `writeTimeout`,
  `maxConnections`, `maxConnectionsPerIp`, `workerThreads`, `isolates`,
  `wsMaxBufferBytes`, `wsCompression`.
* `close(drain:)`: final accept sweep, idle connections closed, in-flight
  requests awaited up to the deadline.
* Events: started, stopped, handler timeout, client error (write timeout).
* `server.metrics`: per-route request and 5xx counts, latency
  p50/p90/p99.

### Handlers

* `RequestContext`: headers, cookies, params, query, body, `bodyStream`,
  `text()`, `jsonMap()`, `jsonList()`, `jsonAs<T>()`, `multipart()`.
* `ResponseContext`: `text`, `json`, `jsonBody`, `html`, `bytes`,
  `redirect`, `stream`, `file`, `withCookie`; several `set-cookie` headers
  per answer.
* Middleware: server-wide, per group, per route; `cors()`, `accessLog()`,
  `compress()`.
* `staticFiles(dir)`: content types, `etag`, `last-modified`, 304, byte
  ranges (206/416), index files, traversal protection.
* Sync handlers are answered without a Future.

### WebSocket

* RFC 6455 handshake and frame loop in the engine; text, binary, ping/pong,
  close codes.
* Non-blocking sends with a per-session queue; `sendText`/`sendBytes`
  return the queued byte count; `bufferedBytes`; 1009 past
  `wsMaxBufferBytes`.
* `permessage-deflate` (RFC 7692, no context takeover).
* Subprotocol selection: `server.ws(pattern, handler, protocols: [...])`
  picks the first offered match, refuses a no-overlap offer with 400, and
  exposes it as `WsSession.protocol`.
* Sealed `WsMessage`: `WsText`, `WsBinary`.

### Engine

* Direct-write answers: the answering thread writes the response with one
  non-blocking `sendmsg`; workers park in `poll()` on the socket and a wake
  pipe; partial writes are flushed by the worker.
* Stream chunks are queued to the worker and coalesced per flush.
* Auto-scaling worker pool: one thread per core, growth on demand up to
  `workerThreads`, idle retirement after 10 s.
* Round-robin dispatch across `isolates` runners; every message of a
  request goes to the runner that received its head.
* Bodies up to 64 KiB are emitted as one chunk plus one complete head;
  larger bodies are read in 64 KiB blocks.
* Leaf-call FFI path for `respond`, `startStream` and `sendStreamChunk`
  over reusable native buffers (0.18 µs per call vs 0.7 µs generated, AOT).
* Request headers cross the bridge as one packed string (`packedHeaders`)
  and unpack on first access; `queryParameters` parses on first access.
* Heads combine per isolate (`RawIncomingBatch`): heads that arrive while
  the previous bridge post is in flight cross as one message.
* `sendfile` for file answers (read + `SSL_write` fallback under TLS).
* TLS via OpenSSL when built with it (`ServerConfig.tls`): HTTP/1.1 and
  `wss://` over TLS 1.2+, ALPN `http/1.1`, PEM strings or files, cert/key
  validated at `start()`. TLS I/O is confined to the worker thread; the
  non-TLS direct-write path is unchanged.

### Tooling

* Dart-only mode: `loadNitroServerNative()`, `NITRO_SERVER_DYLIB`.
* `NitroTestClient` (`package:nitro_server/testing.dart`).
* `benchmark/compare.dart`: dart:io vs shelf vs nitro, client isolates,
  `--raw` (now including `POST /echo 1m`), `--isolates`, `--cooldown`,
  `--json`; WebSocket echo cases (text, binary, permessage-deflate).
* `tool/coverage.sh`: 100% line gate over `lib/`, `coverage:ignore`
  markers honoured.
* `tool/cpp_coverage.sh`: clang source-based line gate over `src/engine`.
* `-DNITRO_SERVER_SANITIZE=thread|address|undefined`: instrumented engine
  test build.
* `tool/fuzz.sh`: libFuzzer targets for the request-head parser, the
  WebSocket frame parser, and a live socket-level server.
* `.github/workflows/ci.yml`: suites, both coverage gates, and the thread
  and address sanitizers on Linux and macOS.
