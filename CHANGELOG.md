## 0.0.1

Initial release: a fast HTTP server backed by a native multithreaded C++
engine over Nitro FFI, with trie routing (`:param` + trailing `*`,
static-beats-param-beats-wildcard), per-route timeouts, middleware,
keep-alive, and `maxBodyBytes` enforcement.

### Performance

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

### Benchmark

* `benchmark/compare.dart` compares `dart:io` vs `shelf` vs `nitro_server`
  on identical routes with an identical driver: sequential latency via
  `package:benchmark_harness` (`AsyncBenchmarkBase`, ~10k samples per case)
  plus a custom 32-worker throughput sweep, `Connection: close` on every
  side, interleaved rounds. See `benchmark/` for methodology and numbers.
