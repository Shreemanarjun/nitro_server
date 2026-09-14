## 0.0.1

Initial release: a fast HTTP server backed by a native multithreaded C++
engine over Nitro FFI, with trie routing (`:param` + trailing `*`,
static-beats-param-beats-wildcard), per-route timeouts, middleware,
keep-alive, and `maxBodyBytes` enforcement.

### Performance

* Direct-write answer path: the thread that answers (Dart's `respond`, or
  the worker on timeout/stop) serializes and writes the response itself,
  non-blocking, and the connection worker parks in `poll()` on the socket
  plus a per-worker wake pipe instead of a condition variable. A keep-alive
  answer needs no thread wake and no response copy; only a partial write
  (queued as a tail the worker flushes) or a closing answer pokes the pipe.
* Stream chunks are queued for the worker and coalesced per flush pass
  instead of written on the Dart isolate one syscall per chunk.
* Worker pool default `max(64, 4 × cores)`: fewer workers than live
  keep-alive connections cycled connections through the queue between
  workers (measured 14 ms p99 at 32 connections on 16 workers).
* Small request bodies (≤ 64 KiB) are read in full before the head is
  emitted: one chunk + one complete head instead of head + chunk + end
  marker, and a single head decode on the Dart side. Large bodies read in
  64 KiB blocks (was 4 KiB).
* Leaf-call FFI fast path for `respond`/`startStream`/`sendStreamChunk`
  over reusable native buffers (0.7 µs → 0.18 µs per call in AOT), with
  the generated bindings as the fallback and a test pinning the wire
  format byte-for-byte.
* Dart dispatch: handlers are invoked inline instead of via
  `Future(() => …)` (one event-loop turn saved per request); the middleware
  fold is skipped when no middleware is registered; the `HttpMethod.all`
  fallback key is only built on a miss; empty bodies share one buffer;
  header names skip re-lowercasing when already lowercase.
* Duplicate-head dedup is deterministic: a bounded (1024-entry) set of
  recently answered ids outlives the in-flight entry, so a stale resend can
  never dispatch again regardless of stream scheduling.
* Native response path: headers and small bodies (≤ 128 KiB) go out in a
  single `send()` instead of two; per-header names are lowered once, not
  twice; the dispatch sink is loaded once per request instead of once per
  body chunk.
* `ResponseContext.text`/`json` encode UTF-8 (`utf8.encode`) instead of
  emitting UTF-16 code units, so non-ASCII bodies survive the wire.

### Dart-only mode

* No Flutter SDK dependency: `dart pub get`, `dart test` and `dart run` all
  work. The `ffiPlugin` metadata stays, so Flutter apps keep automatic
  native bundling.
* New `loadNitroServerNative()` one-liner for Dart CLI programs (with
  `NITRO_SERVER_DYLIB` / `path:` override).
* Suites run on `package:test`; `tool/coverage.sh` prefers `dart test`.

### API

* `RequestContext.jsonMap()`, `jsonList()` and `jsonAs<T>()`: typed JSON
  body accessors that throw `FormatException` at the boundary when the
  shape is wrong, instead of a late cast error deep in a handler.
  `json()` stays for callers that want the raw decode.

### Benchmark

* `benchmark/compare.dart` compares `dart:io` vs `shelf` vs `nitro_server`
  on identical routes with an identical driver: sequential latency via
  `package:benchmark_harness` (`AsyncBenchmarkBase`, ~10k samples per case)
  from one client isolate, plus a closed-loop load sweep from several
  client isolates reporting throughput AND latency under load (p50/p99).
  The driver never shares the server's isolate — a client on the server's
  event loop measures itself. Flags: `--keep-alive`, `--connections`,
  `--clients`, `--seconds`, `--only`, `--workers`, `--json`. See
  `benchmark/` for methodology and numbers, `PERFORMANCE_PLAN.md` for the
  measured history and what comes next.
