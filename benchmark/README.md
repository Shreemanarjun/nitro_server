# Benchmark: `nitro_server` vs `shelf` vs `dart:io HttpServer`

`compare.dart` serves identical routes from all three servers and drives them
with an identical client methodology, interleaved A/B/C/A/B/C so machine
drift cannot favor one side. Sequential latency is measured with
`package:benchmark_harness` (`AsyncBenchmarkBase`: unmeasured setup, 100 ms
warmup, ~2 s exercise loop, standardized per-request mean); p50/p99 come from
the same sample set, and throughput comes from a custom 32-worker sweep the
harness cannot express. All sides close every connection
(`Connection: close`): the `dart:io` and `shelf` handlers answer `close`, and
nitro binds with `ServerConfig(keepAliveTimeout: Duration.zero)` — the engine
default enables keep-alive, which `HttpClient` would otherwise pool, turning
the benchmark into a pool-luck contest instead of a server comparison.

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
params/headers/body):

**JIT** (`dart run benchmark/compare.dart`):

```
| case                 | mean µs | p50 µs | p99 µs | req/s @32 |
| -------------------- | ------- | ------ | ------ | --------- |
| dart:io /hello       |     189 |    170 |    398 |      7427 |
| shelf   /hello       |     220 |    193 |    476 |      6941 |
| nitro   /hello       |     187 |    161 |    430 |     10582 |
| dart:io /json        |     196 |    172 |    413 |      8756 |
| shelf   /json        |     207 |    183 |    397 |      7303 |
| nitro   /json        |     168 |    149 |    294 |     11474 |
| dart:io POST /echo 4k|     201 |    182 |    369 |      7277 |
| shelf   POST /echo 4k|     222 |    198 |    397 |      6521 |
| nitro   POST /echo 4k|     190 |    168 |    349 |     10041 |
```

**AOT** (`dart compile exe` + run):

```
| case                 | mean µs | p50 µs | p99 µs | req/s @32 |
| -------------------- | ------- | ------ | ------ | --------- |
| dart:io /hello       |     186 |    161 |    400 |      9377 |
| shelf   /hello       |     206 |    174 |    397 |      7573 |
| nitro   /hello       |     156 |    142 |    275 |     11882 |
| dart:io /json        |     170 |    154 |    364 |      8484 |
| shelf   /json        |     188 |    170 |    380 |      8267 |
| nitro   /json        |     158 |    143 |    277 |     11586 |
| dart:io POST /echo 4k|     191 |    174 |    362 |      7214 |
| shelf   POST /echo 4k|     208 |    188 |    386 |      6005 |
| nitro   POST /echo 4k|     179 |    162 |    349 |     10282 |
```

Read it narrowly: on tiny routes the native accept loop and per-connection
threads shave scheduling latency and scale throughput ~1.2–1.4× over
`dart:io`; `shelf` trails `dart:io` on throughput by the cost of its
framework layers (it *is* `dart:io` underneath, plus middleware dispatch).
Latency is at parity-or-better across the board — loopback latency is
dominated by the TCP handshake (`Connection: close` every request), not by
any server. Keep-alive would change the picture for all three sides; that is
exactly why the table says what was measured instead of crowning a winner.
Your machine will differ — run it locally before quoting anything.
