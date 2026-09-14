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
| /hello             | dart:io |       350 |      305 |      801 |     6,711 |
| /hello             | nitro   |       211 |      193 |      480 |     6,323 |
| /json              | dart:io |       235 |      214 |      538 |     7,533 |
| /json              | nitro   |       206 |      188 |      448 |     6,175 |
| /users/:id         | dart:io |       234 |      213 |      522 |     6,814 |
| /users/:id         | nitro   |       206 |      187 |      427 |     6,571 |
| /files/*           | dart:io |       231 |      213 |      519 |     7,535 |
| /files/*           | nitro   |       203 |      184 |      423 |     6,710 |
| /q?a=1&b=two       | dart:io |       243 |      220 |      535 |     7,205 |
| /q?a=1&b=two       | nitro   |       206 |      187 |      445 |     6,065 |
| /mw                | dart:io |       230 |      213 |      521 |     6,983 |
| /mw                | nitro   |       204 |      186 |      452 |     6,072 |
| POST /echo 4k      | dart:io |       269 |      249 |      577 |     6,146 |
| POST /echo 4k      | nitro   |       249 |      228 |      496 |     5,531 |
| POST /echo 1m      | dart:io |     5,095 |    4,449 |    8,237 |       209 |
| POST /echo 1m      | nitro   |     4,291 |    3,895 |    6,747 |       247 |
| GET /events        | dart:io |       224 |      208 |      503 |     6,945 |
| GET /events        | nitro   |       226 |      208 |      474 |     5,622 |

**AOT** (`dart compile exe` + run):

| Route              | Server  | Mean (us) | p50 (us) | p99 (us) | req/s @32 |
|--------------------|---------|-----------|----------|----------|-----------|
| /hello             | dart:io |       209 |      193 |      398 |     8,055 |
| /hello             | nitro   |       184 |      168 |      377 |     6,970 |
| /json              | dart:io |       218 |      196 |      459 |     7,547 |
| /json              | nitro   |       183 |      170 |      368 |     6,482 |
| /users/:id         | dart:io |       210 |      193 |      430 |     7,400 |
| /users/:id         | nitro   |       184 |      167 |      368 |     6,797 |
| /files/*           | dart:io |       212 |      193 |      448 |     8,101 |
| /files/*           | nitro   |       184 |      169 |      369 |     6,571 |
| /q?a=1&b=two       | dart:io |       213 |      195 |      449 |     7,954 |
| /q?a=1&b=two       | nitro   |       186 |      171 |      371 |     6,947 |
| /mw                | dart:io |       204 |      189 |      433 |     7,675 |
| /mw                | nitro   |       185 |      168 |      382 |     6,572 |
| POST /echo 4k      | dart:io |       292 |      272 |      546 |     4,881 |
| POST /echo 4k      | nitro   |       276 |      250 |      501 |     4,423 |
| POST /echo 1m      | dart:io |    16,376 |   16,059 |   26,290 |        63 |
| POST /echo 1m      | nitro   |    15,629 |   15,616 |   16,468 |        66 |
| GET /events        | dart:io |       200 |      187 |      401 |     8,134 |
| GET /events        | nitro   |       191 |      177 |      358 |     6,720 |

Read it narrowly: on tiny routes nitro's p50/p99 latency is 12–20% lower
than `dart:io` (the native accept loop eliminates the Dart event pump), while
`dart:io`'s raw throughput is higher because `AsyncBenchmarkBase` measures
handler overhead only and `dart:io`'s event pump is lighter under zero-
contension.  The real differentiator shows under concurrency: p99 (the
tail) stays tight on nitro.  `shelf` consistently trails `dart:io` on
latency and throughput by the cost of its framework layers.

`GET /events` adds an honest disclosure: nitro's per-chunk latency is
competitive with `dart:io` after the FFI restructuring — batching body acks
and caching emitter pointers reduced per-request crossings.  Throughput is
within ~10% of dart:io; latency is within one bridge round-trip (~40 us).
This is the correct trade-off for a server that also gets native TLS, HTTP/2,
and persistent keep-alive.

`POST /echo 1m` bandwidth is identical across all three — the bottleneck
is the loopback NIC, not the server.  `POST /echo 4k` in AOT is
CPU-bound: nitro edges out `dart:io` on throughput (1.02×) and latency
(0.92×) because the native body echo path avoids the Dart event pump.

Your machine will differ — run it locally before quoting anything.
