# Benchmark: `nitro_server` vs `dart:io HttpServer`

`compare.dart` serves identical routes from both servers and drives them with
an identical client methodology, interleaved A/B/A/B so machine drift cannot
favor one side. Both sides close every connection (`Connection: close`), so
neither benefits from keep-alive.

## Run

```sh
cmake -S src -B build/lib -DCMAKE_BUILD_TYPE=Release
cmake --build build/lib --parallel
dart run benchmark/compare.dart
```

## How to read the numbers

| column     | what it measures                                              |
|------------|---------------------------------------------------------------|
| mean / p50 | per-request latency, 500 sequential requests on one client    |
| p99        | tail latency — the Dart↔native round-trip under no contention  |
| req/s @32  | throughput, 4000 requests across 32 concurrent workers        |

The number worth publishing is the **round-trip under load** (`/hello` p99
and the concurrency sweep), not a hello-world max. A single headline number
hides exactly the contention behavior this plugin exists to improve.

## Example run (Apple M-series, loopback, release dylib)

```
| case                 | mean µs | p50 µs | p99 µs | req/s @32 |
| -------------------- | ------- | ------ | ------ | --------- |
| dart:io /hello       |     215 |    198 |    564 |      7780 |
| nitro   /hello       |     176 |    160 |    401 |     10233 |
| dart:io POST /echo 4k|     200 |    185 |    424 |      6888 |
| nitro   POST /echo 4k|     205 |    190 |    465 |      8696 |
```

(Second-round figures; the first round includes JIT warmup on both sides.)

Read it narrowly: on tiny routes the native accept loop and per-connection
threads shave scheduling latency and scale throughput ~1.3×; on a 4 KB echo
the two are at parity because both sides are dominated by the same socket
copy. Your machine will differ — run it locally before quoting anything.
