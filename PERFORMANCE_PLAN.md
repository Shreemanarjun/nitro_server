# nitro_server performance plan

Goal: the fastest Dart HTTP server on latency, throughput and tail in the
keep-alive mode, as measured by `benchmark/compare.dart` with the driver in
separate isolates.

All numbers are from one machine (Apple M1 Pro, 8 cores, loopback, AOT).
Unless a row says otherwise: `--quick`, 32 connections across 4 client
isolates, 1 s of load per case. Run-to-run variance is about ±10%, so
compare rows within one table. Full-length runs (64 connections, 3 s, two
rounds) are in `benchmark/README.md`.

## 1. Starting point

With the driver moved out of the server's isolate, nitro was behind
dart:io under load, with a tail 10× worse:

| keep-alive, 32 conns | seq p50 µs | load p50 µs | load p99 µs | req/s |
|----------------------|-----------:|------------:|------------:|------:|
| dart:io /hello       |         68 |         895 |       1,275 | 33,902 |
| nitro   /hello (old) |         81 |         620 |  **14,525** | 27,090 |
| dart:io POST 4k      |        129 |       1,156 |       1,594 | 27,701 |
| nitro   POST 4k (old)|        142 |       1,027 |  **23,097** | 14,973 |
| dart:io GET /events  |         98 |       1,597 |       3,578 | 17,957 |
| nitro   /events (old)|        141 |       1,502 |       9,518 | 16,186 |

The previous driver ran `HttpClient` on the same isolate as every server,
so every sweep was client-bound at ~22k req/s and the three servers looked
alike.

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

## 2. Changes, each measured

| step | change | /hello req/s | /hello load p50 / p99 | /events req/s | POST 4k req/s |
|------|--------|-------------:|----------------------:|--------------:|--------------:|
| baseline | old engine, 16 workers | 27,090 | 620 / 14,525 | 16,186 | 14,973 |
| A | 64 workers | 38,417 | 696 / 2,464 | — | 27,534 |
| B | direct-write answers, poll-park workers, 64-worker default, inline small bodies, 64 KiB body reads | 50,194 | 593 / 1,417 | 9,217 ↓ | 31,225 |
| C | stream chunks queued to the worker (coalescing) | 44,671* | 593 / 1,613 | 27,438 | — |
| D | leaf-call FFI fast path (`respond`/`startStream`/`sendStreamChunk`) | **52,097** | **568 / 1,296** | **33,293** | **31,631** |
| ref | dart:io, same run as D | 33,680 | 886 / 1,316 | 19,827 | 27,060 |
| E | auto-scaling pool (floor = cores, grows on demand, retires idle) | 52,758 / 52,077 (two runs) | 571 / 1,230 | — | — |
| E′ | same engine, pool pinned at 8 (`--workers 8`) | 3,128 | 184 / 433 | — | — |

Step E keeps D's throughput while a quiet server holds `cores` threads
instead of 64. E′ is the control: a pool smaller than the live connections
cycles every request's connection through the queue. The first growth
trigger fired only at accept time and stalled at 7.7k req/s in one run,
because keep-alive connections are accepted once and a missed spawn was
never retried. Growth now also fires when a worker yields a connection
back to the queue; two consecutive runs then read 52.8k and 52.1k.

\* same engine as B for this case; the 44.7k vs 50.2k spread is run-to-run
variance.

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

## 3. Next steps, in payoff order

Each item names the cost it attacks and how to verify it.

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

### 3.2 Multiple Dart isolates behind one engine (done: `ServerConfig.isolates`)

With the `HttpClient` driver nitro reads ~52k req/s at 1, 2 and 4 isolates
alike, and 8 driver isolates lower it: the driver's ~50 µs of CPU per
request saturates the 8-core box first. The raw-socket load client
(`--raw`) costs a few µs per request and moves the ceiling:

| keep-alive, `--raw`, 32 conns | nitro req/s | dart:io req/s |
|-------------------------------|------------:|--------------:|
| /hello, isolates 1            | 61,464 | 36,401 |
| /hello, isolates 2            | 60,189 | 35,727 |
| /hello, isolates 4            | 61,893 | 36,003 |
| /hello, isolates 1, 6 clients / 48 conns | 60,052 | 34,323 |
| /hello, isolates 4 (dart:io `shared: true` ×4) | 61,269 | 63,253 |

On a trivial handler nitro's single isolate is not the limit at 60k req/s
on this machine; dart:io's is, at 36k. The knob matters where handlers do
work. `/work` JSON-encodes 200 records (~290 µs of CPU):

| keep-alive, `--raw`, 32 conns | nitro req/s | dart:io req/s (`shared: true` ×N) | shelf |
|-------------------------------|------------:|----------------------------------:|------:|
| /work, isolates 1             | 3,413 | 3,464 | 3,347 |
| /work, isolates 4             | **10,929** | 11,298 | 3,058 (single) |

On handler-bound work both stacks scale the same way: 3.2× on 8 cores
with 4 isolates, and the knob costs nothing unused. On tiny routes nitro
reaches with one isolate (61k) what dart:io needs four for (63k), because
parsing, routing and the write are off the isolate. Neither passes ~62k on
this box; see the 6-client row.

Implementation: the engine keeps a list of sinks (`addEmitter`), deals each
request's head round-robin and routes every later message of that request
(chunks, end marker, timeout event) to the same sink; `NitroServer.bind`
spawns `isolates − 1` helper isolates that resolve the same engine key,
run the same `setup`, and close with the server. `isolates: 0` picks half
the cores (1–8). dart:io's equivalent is `HttpServer.bind(shared: true)`
per isolate, which the benchmark now gives it under `--isolates N` so the
comparison stays fair.

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

## 4. Type safety of the public API

`lib/src/api/*` is strongly typed: enums for methods and events,
`Uint8List` bodies, `Map<String, String>` response headers, typed
exceptions. The one untyped spot, `RequestContext.json()` returning
`dynamic`, has typed siblings `jsonMap()`, `jsonList()` and `jsonAs<T>()`
that throw `FormatException` when the shape is wrong. `json()` stays for
the raw decode.

For a future major: `WsMessage` as a sealed hierarchy (`WsText`,
`WsBinary`) so a `switch` is exhaustive. Breaking, so not done here.

## 5. How to reproduce

```sh
cmake -S src -B build/lib -DCMAKE_BUILD_TYPE=Release
cmake --build build/lib --parallel
dart compile exe benchmark/compare.dart -o build/benchmark/compare
./build/benchmark/compare --quick --keep-alive        # headline mode
./build/benchmark/compare --quick                     # Connection: close
./build/benchmark/compare --keep-alive --json out.json # full run
./build/benchmark/compare --quick --keep-alive --raw --only /work --isolates 4  # handler-CPU scaling
dart compile exe tool/perf/respond_bench.dart -o build/respond_bench && ./build/respond_bench
```
