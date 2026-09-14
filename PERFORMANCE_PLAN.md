# nitro_server — performance plan

Goal: the fastest Dart HTTP server on latency (sequential and under load),
throughput and tail, in the real-world keep-alive mode, measured — never
claimed — by `benchmark/compare.dart` with the driver in separate isolates.

Every number below is from the same machine (Apple M1 Pro, 8 cores,
loopback, AOT `dart compile exe`, `--quick`: 32 connections across 4 client
isolates, 1 s load per case). Run-to-run variance is about ±10%; compare
rows within one table, not across sessions. Full-length runs (64
connections, 3 s, 2 rounds) are in `benchmark/README.md`.

## 1. What was wrong (measured)

The first honest measurement — driver moved out of the server's isolate —
showed nitro **behind** dart:io under load, with a tail 10× worse:

| keep-alive, 32 conns | seq p50 µs | load p50 µs | load p99 µs | req/s |
|----------------------|-----------:|------------:|------------:|------:|
| dart:io /hello       |         68 |         895 |       1,275 | 33,902 |
| nitro   /hello (old) |         81 |         620 |  **14,525** | 27,090 |
| dart:io POST 4k      |        129 |       1,156 |       1,594 | 27,701 |
| nitro   POST 4k (old)|        142 |       1,027 |  **23,097** | 14,973 |
| dart:io GET /events  |         98 |       1,597 |       3,578 | 17,957 |
| nitro   /events (old)|        141 |       1,502 |       9,518 | 16,186 |

(The previous driver ran the `HttpClient` on the same isolate as every
server, so every sweep was client-bound at ~22k req/s and the three servers
looked alike. That benchmark could not have shown any of this.)

Three causes, isolated one at a time:

1. **Worker starvation.** The pool defaulted to `max(8, 2×cores)` = 16
   threads for 32 live keep-alive connections. Idle connections were
   bounced through the accept queue between workers (the `yieldToQueued`
   guard), each bounce a lock + wake. Setting `--workers 64` alone:
   /hello 27,090 → 38,417 req/s, p99 14.5 ms → 2.5 ms.
2. **Three thread hops per request.** Worker recv wake → Dart port wake →
   worker condition-variable wake, plus the response copied twice (Dart
   arena → `req->body` vector → socket). dart:io pays one hop.
3. **Streams crossed the bridge and woke the worker once per chunk**: 20 SSE
   events = 20 FFI calls + 20 condvar wakes + 20 syscalls.

## 2. What was done (each step measured)

| step | change | /hello req/s | /hello load p50 / p99 | /events req/s | POST 4k req/s |
|------|--------|-------------:|----------------------:|--------------:|--------------:|
| baseline | old engine, 16 workers | 27,090 | 620 / 14,525 | 16,186 | 14,973 |
| A | 64 workers | 38,417 | 696 / 2,464 | — | 27,534 |
| B | direct-write answers, poll-park workers, 64-worker default, inline small bodies, 64 KiB body reads | 50,194 | 593 / 1,417 | 9,217 ↓ | 31,225 |
| C | stream chunks queued to the worker (coalescing) | 44,671* | 593 / 1,613 | 27,438 | — |
| D | leaf-call FFI fast path (`respond`/`startStream`/`sendStreamChunk`) | **52,097** | **568 / 1,296** | **33,293** | **31,631** |
| ref | dart:io, same run as D | 33,680 | 886 / 1,316 | 19,827 | 27,060 |

\* same engine as B for this case; the 44.7k vs 50.2k spread is run-to-run
variance, which is why the plan quotes deltas from same-session tables.

Step B in detail (`src/engine/ServerInstance.cpp`, `PendingTable.h`):

* Sockets are non-blocking; reads go through `poll()+recv`. The answering
  thread — Dart's `respond`, or the worker on 408/503 — builds the status
  line + headers and writes headers+body with one `sendmsg(MSG_DONTWAIT)`.
  Whatever the socket buffer refuses becomes `req->tail`; one byte on the
  worker's wake pipe makes it flush. A completed keep-alive answer wakes
  nobody: the next request's bytes wake the worker in `poll()`.
* Pipelined input (bytes already in `carry`, or arriving mid-answer) sets
  `workerWaiting`, so the answering thread pokes exactly then. The worker
  never reads the socket while an answer is in flight (ordering), and
  never closes an fd another thread may still write (the `answered` /
  `done` handshake under the per-request mutex owns that).
* Step B's own regression — /events fell to 9.2k because 20 syscalls per
  response landed on the single Dart isolate — is what step C fixed: chunks
  always go through the tail, so the worker sends whatever accumulated
  since its last pass in one write. Twenty 8-byte events became a handful
  of `sendmsg` calls, off the isolate.
* Small bodies (≤ 64 KiB) are read in full before the head is emitted:
  Dart gets one chunk + one complete head (two port messages, one head
  decode) instead of head + chunk + end marker (three, two decodes).

Step D (`lib/src/internal/fast_calls.dart`): the generated bindings cost
0.7 µs per call in AOT (arena, record writer, two native allocations, error
plumbing); the leaf binding with reusable buffers costs 0.18 µs
(`tool/perf/respond_bench.dart`). A stream response makes 22 such calls.
`test/fast_calls_test.dart` pins the hand-rolled header encoding
byte-for-byte to Nitro's generated encoder.

Where nitro still trails: sequential latency on tiny routes (72 vs 67 µs
p50) and on POST 4k (149 vs 131 µs). That is the remaining second thread
hop (worker → Dart port) plus the body's two copies on the way in; see §3.

## 3. What comes next, in payoff order

Each item names the measured cost it attacks and how to verify it.

### 3.1 Lazy request decode (spec v2) — Dart isolate, every request

The isolate is the one serial stage. Per request it decodes a full
`RawIncomingRequest`: path, query, pattern, N headers (2 strings each),
params — ~10 string allocations — then `_foldHeaders` builds a map of
lists most handlers never read. Change the wire to carry the head as one
zero-copy byte blob (path/pattern offsets + raw header bytes) and decode
headers on first access in `RequestContext` (the public `headers` map
stays; it becomes lazily built). Estimated −3 µs of ~19 µs per request on
the isolate (~15% throughput). Needs `nitro_server.native.dart` +
`build_runner` regeneration; verify with the /hello and POST rows.

### 3.2 Multiple Dart isolates behind one engine — past the single-isolate ceiling

At ~52k req/s the isolate is saturated: doubling the load to 8 client
isolates and 64 connections leaves nitro at 43.6k req/s (dart:io 28.1k)
with load p50 1,072 µs — no more throughput, only deeper queues, while the
C++ workers are mostly parked. dart:io scales with
`HttpServer.bind(shared: true)` across isolates; nitro can do the same
with less machinery: the engine keeps one accept loop and round-robins
`emitHead` across N bound emitters (body chunks and end markers follow
their head's emitter). API sketch, type-safe:

```dart
final server = await NitroServer.bind(
  const ServerConfig(isolates: 4),
  setup: registerRoutes, // top-level `FutureOr<void> Function(NitroServer)`
);
```

Each isolate runs its own `ServerRunner` with the same routes (registration
is idempotent on the shared router). Handlers stay ordinary closures inside
`setup`. Expected: near-linear to ~4 isolates on this machine (150–200k
req/s on /hello). Verify with `--clients 8 --connections 128`.

### 3.3 Reactor instead of thread-per-connection — beyond ~500 live connections

Parked threads are cheap until they are not: 10k idle keep-alive
connections would be 10k threads. A kqueue/epoll reactor (one thread owns
the connection state machine; the direct-write path is unchanged — the
Dart thread still writes, and re-arms `POLLOUT` interest on `EAGAIN`)
replaces the pool. The abandoned first attempt left a usable `Poller`
scaffold in git commit `2df34f3` (`Poller.h/.cpp`). Not a throughput item
at 32–64 connections; a connection-count item. Verify with
`--connections 1000 --clients 8`.

### 3.4 Request-side copies — POST latency

A 4 KiB body is copied native→malloc (chunk), then Dart copies the
zero-copy view into its heap, then the response body is copied into the
FFI buffer. Two of the three can go: emit the body inline in the head blob
(3.1 makes this natural), and let `ResponseContext.bytes` of an
externally-allocated `Uint8List` skip the staging copy. Verify with the
POST 4k sequential row (target: below dart:io's 131 µs).

### 3.5 Smaller items, each worth a row in the table

* Pre-encoded response heads for repeated `(status, headers)` pairs (the
  `content-type: text/plain` case) — saves the header encode per answer.
* `TCP_NODELAY` + a single `sendmsg` already cover one-shot answers; for
  streams, batch the terminal marker with the last chunk (done) and let
  the worker use `writev` across tail segments (currently one buffer).
* `Router::match` copies the `RouteEntry` (two strings) per hit; return a
  pointer into the trie under the shared lock.

Out of scope for performance but on the roadmap: native TLS, HTTP/2,
WebSocket compression.

## 4. Type safety (public API)

The public surface (`lib/src/api/*`) is strongly typed: enums for methods
and events, `Uint8List` bodies, `Map<String, String>` headers on responses,
typed exceptions. The one untyped spot, `RequestContext.json()` returning
`dynamic`, now has typed siblings — `jsonMap()`, `jsonList()`, `jsonAs<T>()`
— that throw `FormatException` at the boundary when the shape is wrong.
`json()` remains for callers that want the raw decode.

Candidate for a future major: `WsMessage` as a sealed hierarchy
(`WsText` / `WsBinary`) so `switch` is exhaustive instead of checking
`isText`. Breaking, so not done here.

## 5. How to reproduce

```sh
cmake -S src -B build/lib -DCMAKE_BUILD_TYPE=Release
cmake --build build/lib --parallel
dart compile exe benchmark/compare.dart -o build/benchmark/compare
./build/benchmark/compare --quick --keep-alive        # headline mode
./build/benchmark/compare --quick                     # Connection: close
./build/benchmark/compare --keep-alive --json out.json # full run
dart compile exe tool/perf/respond_bench.dart -o build/respond_bench && ./build/respond_bench
```
