# Benchmark: `nitro_server` vs `shelf` vs `dart:io HttpServer`

`compare.dart` serves identical routes from all three servers and drives them
with an identical client methodology, interleaved A/B/C/A/B/C so machine
drift cannot favor one side. The driver never shares the server's isolate:
sequential latency comes from one client isolate running
`package:benchmark_harness` (`AsyncBenchmarkBase`: unmeasured setup, 100 ms
warmup, ~2 s exercise loop, standardized per-request mean; p50/p99 from the
same sample set), and the load sweep runs from several client isolates in a
closed loop for a fixed time, reporting throughput AND latency under load.
(A client on the server's event loop measures itself: the previous
single-isolate driver capped every server at ~22k req/s.)

## Cases

| case | what it stresses |
|------|------------------|
| `/hello`, `/json` | tiny literal routes: accept + dispatch + serialize |
| `/users/:id` | `:param` capture (trie param edges + Dart params map) |
| `/files/*` | trailing-wildcard match |
| `/q?a=1&b=two` | query parsing (`splitQueryString` vs `Uri` equivalents) |
| `/mw` | one pass-through middleware layer on every side |
| `POST /echo 4k` | 4 KiB upload + echo (body streaming, zero-copy ack path) |
| `POST /echo 1m` | 1 MiB upload + echo (bandwidth-bound; engine chunk emits) |
| `GET /events` | 20-chunk `text/event-stream` (chunked framing: 1 syscall/chunk on nitro via `writev`) |

Every case asserts exact status + bytes, so a faster wrong answer cannot win.
Bodies are byte-identical across sides, including the query echo (key order
`a,b`) and the wildcard echo (`wild:/files/a/b/c`).

## Connection modes

Default: all sides close every connection (`Connection: close`) — the
`dart:io` and `shelf` handlers answer `close`, and nitro binds with
`ServerConfig(keepAliveTimeout: Duration.zero)`. The engine default enables
keep-alive, which `HttpClient` would otherwise pool, turning the benchmark
into a pool-luck contest instead of a server comparison.

`--keep-alive` flips all three sides to persistent connections (the
real-world mode): nitro binds the default `ServerConfig`, the Dart sides
stop forcing `close`. Expect ~3× lower latency everywhere — the handshake
dominates loopback — and read that table, not this one, for serving claims.

The file is pure Dart (no Flutter imports): running it is the proof that the
package works in Dart-only mode.

## Run

```sh
cmake -S src -B build/lib -DCMAKE_BUILD_TYPE=Release
cmake --build build/lib --parallel

# JIT (edit-run loop; round 1 includes compiler warmup on the Dart sides)
dart run benchmark/compare.dart [--quick]

# AOT (what Flutter release ships; no JIT warmup, peak optimizer)
dart compile exe benchmark/compare.dart -o build/benchmark/compare
./build/benchmark/compare [--quick]
# from another directory:
# ./build/benchmark/compare --dylib /abs/path/to/libnitro_server.dylib
```

Flags: `--quick` (1 s load per case, 32 connections, 1 round; smoke test),
`--keep-alive` (persistent connections on all sides — the real-world mode
and the headline), `--connections N` (load connections, default 64),
`--clients N` (client isolates sharing them, default 4), `--seconds N` (load
duration per case, default 3), `--only "<case>"` (one case, e.g.
`"GET /events"`), `--workers N` (nitro's native worker pool; 0 = engine
default), `--json <path>` (machine-readable results), `--dylib <path>`
(native library override for the compiled exe).

Run BOTH modes before quoting numbers. The header line reports the
detected mode (`JIT` under `dart run`, `AOT` in the compiled exe), so a
pasted table always says which VM it came from. If nitro wins in one mode
only, report exactly that — a benchmark that can only pass in one VM mode
is a hint, not a verdict. The native engine itself is AOT-compiled C++
either way; the mode changes the Dart driver, the shelf/dart:io handlers,
and nitro's Dart runner — i.e. everything except the engine under test,
which is why the AOT run is the cleaner engine comparison.

## How to read the numbers

| column      | what it measures                                              |
|-------------|---------------------------------------------------------------|
| seq p50/p99 | one connection, one request at a time (~10k samples, ~2 s)    |
| load p50/p99| per-request latency while N connections hammer the server     |
| req/s @N    | completed requests per second across N connections, K isolates|

The number worth publishing is the **round-trip under load** (p99 and the
concurrency sweep), not a hello-world max. A single headline number hides
exactly the contention behavior this plugin exists to improve.

## Example run (Apple M1 Pro, loopback, release dylib, AOT)

Both tables: 64 connections across 4 client isolates, 3 s of load per case,
second of two interleaved rounds, `dart compile exe` driver. Every case
asserts exact status + bytes. `GET /events` sends 20 chunks through
`text/event-stream`; on nitro each chunk crosses the FFI bridge once and is
written by the native worker (bursts coalesce), on dart:io/shelf each is a
`flush()` on the isolate.

**Keep-alive** (`--keep-alive`, the real-world mode):

__KEEPALIVE_TABLE__

**Connection: close** (default; every request pays a TCP handshake):

__CLOSE_TABLE__

Read it narrowly. Under load nitro serves the small routes at roughly 1.5×
dart:io's throughput with ~35% lower p50, and streams at ~1.7×, because
parsing, routing and the response write happen off the Dart isolate and a
keep-alive answer wakes no thread. Sequential latency on one idle
connection is within a few microseconds of dart:io: the remaining
worker→isolate hop costs about what native parsing saves. `POST /echo 1m`
is loopback-bound and identical everywhere. `shelf` trails `dart:io` by the
cost of its framework layers. The measured history behind these numbers,
and what limits them now, is in `PERFORMANCE_PLAN.md`.

Your machine will differ — run it locally before quoting anything.
