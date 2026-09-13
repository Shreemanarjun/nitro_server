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
dart run benchmark/compare.dart [--quick]
```

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
the Dart sides:

```
| case                 | mean µs | p50 µs | p99 µs | req/s @32 |
| -------------------- | ------- | ------ | ------ | --------- |
| dart:io /hello       |     186 |    162 |    398 |      7868 |
| shelf   /hello       |     208 |    184 |    424 |      7328 |
| nitro   /hello       |     171 |    151 |    350 |      9967 |
| dart:io /json        |     186 |    163 |    399 |      8497 |
| shelf   /json        |     207 |    182 |    416 |      6951 |
| nitro   /json        |     167 |    148 |    347 |     11074 |
| dart:io POST /echo 4k|     206 |    182 |    387 |      7072 |
| shelf   POST /echo 4k|     227 |    199 |    446 |      6545 |
| nitro   POST /echo 4k|     186 |    166 |    366 |      9798 |
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
