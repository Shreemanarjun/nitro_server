## 0.0.1

Initial release: an HTTP/1.1 and WebSocket server backed by a native C++
engine over Nitro FFI. Trie routing (`:param`, trailing `*`, static beats
param beats wildcard), per-route timeouts, middleware, route groups,
keep-alive, `maxBodyBytes`, chunked response streams, an in-memory test
client, and a Dart-only mode with no Flutter SDK dependency.

### Engine

* Direct-write answers. The thread that answers (Dart's `respond`, or the
  worker on timeout and shutdown) serializes the response and writes it
  with one non-blocking `sendmsg`. Workers park in `poll()` on the socket
  and a per-worker wake pipe instead of a condition variable, so a
  keep-alive answer needs no thread wake and no copy. A partial write is
  queued as a tail the worker flushes.
* Stream chunks are queued for the worker and coalesced per flush pass
  rather than written on the Dart isolate one syscall per chunk.
* Auto-scaling worker pool: one thread per core at start, growth when a
  queued or yielded connection finds nobody idle, retirement of idle
  threads above the floor after 10 s. `ServerConfig.workerThreads` is the
  cap (`0` = `max(64, 4 × cores)`).
* Multi-isolate serving: `ServerConfig.isolates` (`0` = auto) runs that
  many Dart runners behind one engine. Requests are dealt round-robin and
  every message of a request goes to the runner that received its head.
  Routes are registered by the `setup` function `bind` accepts, once per
  isolate.
* Bodies up to 64 KiB are read in full before the head is emitted: one
  chunk plus one complete head instead of head, chunk and end marker.
  Larger bodies are read in 64 KiB blocks.
* Leaf-call FFI path for `respond`, `startStream` and `sendStreamChunk`
  over reusable native buffers: 0.18 µs per call versus 0.7 µs for the
  generated bindings (AOT). The generated bindings remain the fallback and
  a test pins the wire format byte for byte.
* Header parsing over `string_view`, allocation-free case-insensitive
  compares, route matching without per-branch vector copies.

### Features

* Streaming uploads: `streamBody: true` on a route runs the handler when
  the head is in and delivers the body on `RequestContext.bodyStream`,
  releasing native memory chunk by chunk.
* File answers: `ResponseContext.file` sends a file (or a byte range) from
  a native worker with `sendfile`; `staticFiles(dir)` adds content types,
  `etag`/`last-modified`, 304 for conditional requests, 206/416 for byte
  ranges, index pages and traversal protection.
* Graceful shutdown: `close(drain:)` stops accepting, marks answers
  `Connection: close` and waits for in-flight requests.
* Accept-time limits: `maxConnections`, `maxConnectionsPerIp` and a
  `headerTimeout` for silent connections, enforced natively.
* `compress()` gzip middleware, negotiated on `Accept-Encoding` and content
  type.
* `server.metrics`: per-route request and 5xx counts with latency
  p50/p90/p99 from a fixed histogram.
* Cookies (`request.cookies`, `SetCookie`, `withCookie`; several
  `set-cookie` headers per answer) and `request.multipart()` for
  `multipart/form-data`.
* `WsMessage` is sealed (`WsText`, `WsBinary`); the `text`/`binary`
  factories and accessors are unchanged.
* HEAD requests fall back to the GET route, in the router and the runner.

### Dart API

* `RequestContext.jsonMap()`, `jsonList()` and `jsonAs<T>()`: typed JSON
  body accessors that throw `FormatException` when the shape is wrong.
  `json()` stays for the raw decode.
* `ResponseContext.jsonBody`, `html`, `redirect`, `stream`;
  `ServerConfig.copyWith`; `NitroServer.bindWith`; per-route and per-group
  middleware; built-in `cors()` and `accessLog()`.
* Handlers may return a `ResponseContext` synchronously; the runner invokes
  them through `Future.sync`, so a sync handler skips an event-loop turn.
* `ResponseContext.text` and `json` encode UTF-8, so non-ASCII bodies
  survive the wire.
* `loadNitroServerNative()` for Dart CLI programs, with `NITRO_SERVER_DYLIB`
  and `path:` overrides.

### Benchmark

* `benchmark/compare.dart` compares `dart:io`, `shelf` and `nitro_server`
  on identical routes. The driver runs in separate client isolates:
  sequential latency through `package:benchmark_harness`, load through a
  closed-loop sweep that reports throughput and latency under load.
  `--raw` swaps in a raw-socket load client, `--isolates N` gives both
  nitro and dart:io N isolates, `/work` measures handler CPU. Flags and
  results are in `benchmark/README.md`; the measured history is in
  `PERFORMANCE_PLAN.md`.
* `/file` case: a 64 KiB static file, `File.openRead` on the Dart sides
  versus native `sendfile` on nitro.
* `tool/coverage.sh` converts `dart test --coverage` output to lcov before
  gating and honours `coverage:ignore` markers; it used to read a stale file
  and mis-parse the percentage, so the gate never actually enforced 100%.
