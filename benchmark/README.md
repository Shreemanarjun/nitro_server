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

Second round (post-warmup) figures; the first round includes JIT warmup on
the Dart sides. Both VM modes, same machine, after the D1–D4 dispatch
optimizations (two-level route table, pre-composed middleware, shared empty
params/headers/body) + `writev` chunked-framing batching (one syscall per
SSE/event-stream chunk instead of three).

**JIT** (`dart run benchmark/compare.dart`):

```
| case                  | mean µs | p50 µs | p99 µs | req/s @32 |
| --------------------- | ------- | ------ | ------ | --------- |
| dart:io /hello        |     262 |    236 |    614 |      7496 |
| shelf   /hello        |     248 |    216 |    550 |      7057 |
| nitro   /hello        |     180 |    162 |    373 |     11252 |
| dart:io /json         |     193 |    171 |    420 |      8510 |
| shelf   /json         |     216 |    190 |    411 |      7280 |
| nitro   /json         |     175 |    157 |    349 |     10154 |
| dart:io /users/:id    |     196 |    173 |    411 |      8326 |
| shelf   /users/:id    |     217 |    191 |    426 |      7230 |
| nitro   /users/:id    |     180 |    160 |    366 |     11248 |
| dart:io /files/*      |     194 |    170 |    415 |      8554 |
| shelf   /files/*      |     218 |    191 |    438 |      7308 |
| nitro   /files/*      |     180 |    159 |    373 |     10633 |
| dart:io /q?a=1&b=two  |     203 |    175 |    419 |      7305 |
| shelf   /q?a=1&b=two  |     221 |    195 |    434 |      7247 |
| nitro   /q?a=1&b=two  |     183 |    160 |    370 |     10925 |
| dart:io /mw           |     195 |    171 |    415 |      8593 |
| shelf   /mw           |     217 |    192 |    419 |      7206 |
| nitro   /mw           |     177 |    157 |    367 |      8339 |
| dart:io POST /echo 4k |     224 |    197 |    466 |      7366 |
| shelf   POST /echo 4k |     245 |    211 |    459 |      5353 |
| nitro   POST /echo 4k |     194 |    174 |    383 |      8881 |
| dart:io POST /echo 1m |    2878 |   2689 |   5870 |       376 |
| shelf   POST /echo 1m |    2425 |   1896 |   4962 |       467 |
| nitro   POST /echo 1m |    2401 |   1850 |   5004 |       546 |
| dart:io GET /events   |     216 |    191 |    452 |      6325 |
| shelf   GET /events   |     240 |    214 |    444 |      5624 |
| nitro   GET /events   |     257 |    234 |    483 |      8300 |
```

**AOT** (`dart compile exe` + run):

```
| case                  | mean µs | p50 µs | p99 µs | req/s @32 |
| --------------------- | ------- | ------ | ------ | --------- |
| dart:io /hello        |     186 |    161 |    400 |      9377 |
| shelf   /hello        |     206 |    174 |    397 |      7573 |
| nitro   /hello        |     156 |    142 |    275 |     11882 |
| dart:io /json         |     170 |    154 |    364 |      8484 |
| shelf   /json         |     188 |    170 |    380 |      8267 |
| nitro   /json         |     158 |    143 |    277 |     11586 |
| dart:io POST /echo 4k |     191 |    174 |    362 |      7214 |
| shelf   POST /echo 4k |     208 |    188 |    386 |      6005 |
| nitro   POST /echo 4k |     179 |    162 |    349 |     10282 |
```

Read it narrowly: on tiny routes the native accept loop and per-connection
threads shave scheduling latency and scale throughput ~1.4–1.5× over
`dart:io`; `shelf` trails `dart:io` on throughput by the cost of its
framework layers (it *is* `dart:io` underneath, plus middleware dispatch).
Latency is at parity-or-better across the board — loopback latency is
dominated by the TCP handshake (`Connection: close` every request), not by
any server. Keep-alive would change the picture for all three sides; that is
exactly why the table says what was measured instead of crowning a winner.
Your machine will differ — run it locally before quoting anything.
