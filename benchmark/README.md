# Benchmark: `nitro_server` vs `shelf` vs `dart:io HttpServer`

`compare.dart` serves identical routes from all three servers and drives them
with an identical client methodology, interleaved A/B/C/A/B/C so machine
drift cannot favor one side. All sides close every connection
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

`--quick` runs 1 round at 100 sequential / 800 concurrent requests (smoke
test). The default is 2 rounds at 500 sequential / 4000 concurrent, with 200
unmeasured warmup requests per case (JIT + pools settle, so round one is not
a compiler benchmark).

## How to read the numbers

| column     | what it measures                                              |
|------------|---------------------------------------------------------------|
| mean / p50 | per-request latency, sequential requests on one client        |
| p99        | tail latency — the Dart↔native round-trip under no contention  |
| req/s @32  | throughput, concurrent requests across 32 workers             |

The number worth publishing is the **round-trip under load** (p99 and the
concurrency sweep), not a hello-world max. A single headline number hides
exactly the contention behavior this plugin exists to improve.

## Example run (Apple M-series, loopback, release dylib)

Second round (post-warmup) figures; the first round includes JIT warmup on
the Dart sides:

```
| case                 | mean µs | p50 µs | p99 µs | req/s @32 |
| -------------------- | ------- | ------ | ------ | --------- |
| dart:io /hello       |     176 |    160 |    404 |      8474 |
| shelf   /hello       |     255 |    182 |    410 |      7371 |
| nitro   /hello       |     157 |    145 |    338 |     10474 |
| dart:io /json        |     171 |    158 |    390 |      8892 |
| shelf   /json        |     191 |    174 |    435 |      7194 |
| nitro   /json        |     169 |    144 |    351 |     11457 |
| dart:io POST /echo 4k|     210 |    195 |    443 |      7562 |
| shelf   POST /echo 4k|     211 |    194 |    430 |      5506 |
| nitro   POST /echo 4k|     181 |    168 |    345 |      9471 |
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
