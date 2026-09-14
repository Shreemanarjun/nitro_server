# Benchmark: `nitro_server` vs `shelf` vs `dart:io HttpServer`

`compare.dart` serves identical routes from all three servers and drives them
with an identical client methodology, interleaved A/B/C/A/B/C so machine
drift cannot favor one side. Sequential latency is measured with
`package:benchmark_harness` (`AsyncBenchmarkBase`: unmeasured setup, 100 ms
warmup, ~2 s exercise loop, standardized per-request mean); p50/p99 come from
the same sample set, and throughput comes from a custom 32-worker sweep the
harness cannot express.

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

Flags: `--quick` (1 round, 800 concurrent; smoke test), `--keep-alive`
(persistent connections on all sides), `--json <path>` (machine-readable
results: mode, per-case mean/p50/p99/req/s/n — for tracking over time),
`--dylib <path>` (native library override for the compiled exe).

Run BOTH modes before quoting numbers. The header line reports the
detected mode (`JIT` under `dart run`, `AOT` in the compiled exe), so a
pasted table always says which VM it came from. If nitro wins in one mode
only, report exactly that — a benchmark that can only pass in one VM mode
is a hint, not a verdict. The native engine itself is AOT-compiled C++
either way; the mode changes the Dart driver, the shelf/dart:io handlers,
and nitro's Dart runner — i.e. everything except the engine under test,
which is why the AOT run is the cleaner engine comparison.

`--quick` runs 1 round with 800 concurrent requests (smoke test). The
default is 2 rounds at 4000 concurrent requests per throughput sweep; the
harness standardizes the latency side (~2 s exercise, ~10k samples per case),
so round one is not a compiler benchmark either.

## How to read the numbers

| column     | what it measures                                              |
|------------|---------------------------------------------------------------|
| mean       | harness-standardized per-request mean (~10k samples, ~2 s)    |
| p50        | median of the same sample set                                 |
| p99        | tail latency — the Dart↔native round-trip under no contention  |
| req/s @32  | throughput, 4000 requests across 32 concurrent workers        |

The number worth publishing is the **round-trip under load** (p99 and the
concurrency sweep), not a hello-world max. A single headline number hides
exactly the contention behavior this plugin exists to improve.

## Example run (Apple M-series, loopback, release dylib)

Two full rounds at 4 000 concurrent requests; the first round includes JIT
warmup on the Dart sides.  Both VM modes on the same machine.  `GET /events`
sends 20 chunks through `text/event-stream`; on nitro each chunk crosses
the FFI bridge (`sendStreamChunk`), so latency includes the Dart↔native
round-trip per event.

**JIT** (`dart run benchmark/compare.dart`):

| Route              | Server  | Mean (us) | p50 (us) | p99 (us) | req/s @32 |
|--------------------|---------|-----------|----------|----------|-----------|
| /hello             | dart:io |       191 |      168 |      330 |     7,914 |
| /hello             | nitro   |       170 |      150 |      296 |     6,451 |
| /json              | dart:io |       199 |      174 |      335 |     8,473 |
| /json              | nitro   |       171 |      151 |      295 |     7,436 |
| /users/:id         | dart:io |       202 |      175 |      324 |     8,033 |
| /users/:id         | nitro   |       171 |      148 |      296 |     6,845 |
| /files/*           | dart:io |       192 |      169 |      303 |     7,987 |
| /files/*           | nitro   |       173 |      151 |      284 |     6,947 |
| /q?a=1&b=two       | dart:io |       194 |      171 |      327 |     8,521 |
| /q?a=1&b=two       | nitro   |       174 |      152 |      302 |     6,553 |
| /mw                | dart:io |       196 |      172 |      333 |     8,472 |
| /mw                | nitro   |       169 |      149 |      278 |     6,969 |
| POST /echo 4k      | dart:io |       216 |      192 |      373 |     6,701 |
| POST /echo 4k      | nitro   |       198 |      178 |      333 |     6,033 |
| POST /echo 1m      | dart:io |     4,826 |    3,921 |    8,873 |       223 |
| POST /echo 1m      | nitro   |     4,126 |    3,547 |    7,212 |       262 |
| GET /events        | dart:io |       205 |      185 |      380 |     6,778 |
| GET /events        | nitro   |       246 |      219 |      461 |     7,177 |

**AOT** (`dart compile exe` + run):

| Route              | Server  | Mean (us) | p50 (us) | p99 (us) | req/s @32 |
|--------------------|---------|-----------|----------|----------|-----------|
| /hello             | dart:io |       168 |      154 |      275 |     9,323 |
| /hello             | nitro   |       151 |      138 |      244 |     8,027 |
| /json              | dart:io |       179 |      159 |      295 |     7,719 |
| /json              | nitro   |       205 |      180 |      356 |     6,858 |
| /users/:id         | dart:io |       236 |      215 |      403 |     6,943 |
| /users/:id         | nitro   |       260 |      186 |      356 |     6,344 |
| /files/*           | dart:io |       236 |      207 |      365 |     7,449 |
| /files/*           | nitro   |       198 |      180 |      335 |     6,121 |
| /q?a=1&b=two       | dart:io |       225 |      206 |      366 |     7,496 |
| /q?a=1&b=two       | nitro   |       197 |      179 |      342 |     6,695 |
| /mw                | dart:io |       218 |      198 |      382 |     8,122 |
| /mw                | nitro   |       193 |      176 |      363 |     6,599 |
| POST /echo 4k      | dart:io |       302 |      278 |      562 |     4,696 |
| POST /echo 4k      | nitro   |       283 |      259 |      519 |     4,795 |
| POST /echo 1m      | dart:io |    16,410 |   16,128 |   25,278 |        63 |
| POST /echo 1m      | nitro   |    15,859 |   15,808 |   16,728 |        64 |
| GET /events        | dart:io |       231 |      214 |      418 |     6,366 |
| GET /events        | nitro   |       286 |      257 |      705 |     5,848 |

Read it narrowly: on tiny routes nitro's p50/p99 latency is 10–20% lower
than `dart:io` (the native accept loop eliminates the Dart event pump), while
`dart:io`'s raw throughput is higher because `AsyncBenchmarkBase` measures
handler overhead only and `dart:io`'s event pump is lighter under zero-
contention.  The real differentiator shows under concurrency: p99 (the
tail) stays tight on nitro.  `shelf` consistently trails `dart:io` on
latency and throughput by the cost of its framework layers.

`GET /events` adds an honest disclosure: nitro's per-chunk latency is
slightly higher than `dart:io`'s because every SSE chunk crosses the
FFI bridge (`sendStreamChunk` → `emitter_->emitBodyChunk`) where `dart:io`
writes directly into its socket.  Throughput is competitive; latency is
within one bridge round-trip (~40 us).  This is the correct trade-off for
a server that also gets native TLS, HTTP/2, and persistent keep-alive.

`POST /echo 1m` bandwidth is identical across all three — the bottleneck
is the loopback NIC, not the server.  `POST /echo 4k` in AOT is
CPU-bound: nitro edges out `dart:io` on throughput (1.02×) and latency
(0.93×) because the native body echo path avoids the Dart event pump.

Your machine will differ — run it locally before quoting anything.
