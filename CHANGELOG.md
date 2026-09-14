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
* `tool/coverage.sh` converts `dart test --coverage` output to lcov before
  gating; it used to read a stale file.
