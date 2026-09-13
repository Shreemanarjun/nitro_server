## 0.0.2-wip

### Performance

* Dart dispatch: handlers are invoked inline instead of via `Future(() => …)`,
  saving one event-loop turn per request; the middleware fold is skipped when
  no middleware is registered; the `HttpMethod.all` fallback key is only
  built on a miss; empty bodies share one buffer; header names skip
  re-lowercasing when already lowercase.
* Duplicate-head dedup is now deterministic: a bounded (1024-entry) set of
  recently answered ids outlives the in-flight entry, so a stale resend can
  never dispatch again regardless of stream scheduling. (The old code relied
  on the extra event-loop turn above to win that race.)
* Native response path: headers and small bodies (≤ 128 KiB) go out in a
  single `send()` instead of two; per-header names are lowered once, not
  twice; the dispatch sink is loaded once per request instead of once per
  body chunk.
* Correctness fix on the hot path: `ResponseContext.text`/`json` now encode
  UTF-8 (`utf8.encode`) instead of emitting UTF-16 code units — non-ASCII
  bodies (e.g. emoji) were corrupted on the wire.

### Dart-only mode

* The package no longer depends on the Flutter SDK (`dart pub get`,
  `dart test`, `dart run` all work); the `ffiPlugin` metadata stays so
  Flutter apps keep automatic native bundling.
* New `loadNitroServerNative()` one-liner for Dart CLI programs (with
  `NITRO_SERVER_DYLIB` / `path:` override); the benchmark and the e2e suite
  use it instead of private loader boilerplate.
* Unit + e2e suites migrate from `package:flutter_test` to `package:test`;
  `tool/coverage.sh` runs `dart test` (Flutter fallback kept).

### Benchmark

* `benchmark/compare.dart` is now a three-way `dart:io` vs `shelf` vs
  `nitro_server` comparison (new `/json` case, unmeasured warmup, `--quick`
  smoke mode), still pure-Dart and `Connection: close` on every side — the
  nitro server binds with `keepAliveTimeout: Duration.zero`, since the engine
  default enables keep-alive and pooled reuse would measure pool luck. Docs
  updated with fresh numbers.

## 0.0.1

* TODO: Describe initial release.
