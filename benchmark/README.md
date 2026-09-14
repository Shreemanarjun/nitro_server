# Benchmark: `nitro_server` vs `shelf` vs `dart:io HttpServer`

`compare.dart` serves the same routes from all three servers and drives them
with the same client, in interleaved rounds (A/B/C, A/B/C) so machine drift
cannot favor one side. Every case asserts exact status and bytes.

The driver never shares a server's isolate. Sequential latency comes from
one client isolate running `package:benchmark_harness` (unmeasured setup,
100 ms warmup, ~2 s exercise, p50/p99 from the same samples). Load comes
from several client isolates in a closed loop for a fixed time, reporting
throughput and latency under load.

## Cases

| case | what it stresses |
|------|------------------|
| `/hello`, `/json` | tiny literal routes: accept, dispatch, serialize |
| `/users/:id` | `:param` capture |
| `/files/*` | trailing wildcard |
| `/q?a=1&b=two` | query parsing |
| `/mw` | one pass-through middleware layer on every side |
| `/work` | a JSON-encoding handler (200 records): handler CPU, where `--isolates` matters |
| `POST /echo 4k` | 4 KiB upload and echo |
| `POST /echo 1m` | 1 MiB upload and echo (loopback-bound) |
| `GET /events` | 20-chunk `text/event-stream` |

## Connection modes

Default: every side closes every connection. The `dart:io` and `shelf`
handlers answer `Connection: close`; nitro binds with
`keepAliveTimeout: Duration.zero`. Otherwise `HttpClient` would pool some
connections and the result would depend on pool luck.

`--keep-alive`: persistent connections on all sides, the real-world mode
and the one to quote. Nitro binds with `maxRequestsPerConnection: 0`
because the other two never cap requests per connection.

## Run

```sh
cmake -S src -B build/lib -DCMAKE_BUILD_TYPE=Release
cmake --build build/lib --parallel

dart run benchmark/compare.dart --quick               # JIT: edit-run loop
dart compile exe benchmark/compare.dart -o build/benchmark/compare
./build/benchmark/compare --keep-alive                 # AOT: what ships
```

| flag | meaning |
|------|---------|
| `--quick` | 1 s of load per case, 32 connections, one round |
| `--keep-alive` | persistent connections on all sides |
| `--connections N` | load connections, default 64 |
| `--clients N` | client isolates sharing them, default 4 |
| `--seconds N` | load duration per case, default 3 |
| `--only "<case>"` | one case, e.g. `"GET /events"` |
| `--workers N` | cap of nitro's worker pool; 0 = engine default |
| `--isolates N` | Dart isolates behind nitro (0 = auto); dart:io gets the same number of `shared: true` isolates |
| `--raw` | raw-socket load client for the one-shot cases: a few µs of client CPU per request instead of `HttpClient`'s tens. Use it when the driver, not the server, saturates the machine. Exact bytes are still asserted. |
| `--json <path>` | machine-readable results |
| `--dylib <path>` | native library path for the compiled exe |

The header line names the VM mode (`JIT` or `AOT`). The engine is compiled
C++ either way; the mode changes the driver, the dart:io and shelf
handlers and nitro's Dart runner. Quote AOT.

## Columns

| column | measures |
|--------|----------|
| seq p50/p99 | one connection, one request at a time |
| load p50/p99 | per-request latency while N connections run |
| req/s @N | completed requests per second across N connections |

Under-load latency and throughput are the numbers that matter; a
single-connection hello-world hides contention.

## Results (Apple M1 Pro, loopback, AOT)

64 connections from 4 client isolates, 3 s of load per case, second of two
rounds. `GET /events` sends 20 chunks: on nitro the native worker writes
them and coalesces bursts; on dart:io and shelf each chunk is a `flush()`
on the isolate.

Keep-alive (`--keep-alive`):

| Route | Server | seq p50 µs | seq p99 µs | load p50 µs | load p99 µs | req/s @64 |
|-------|--------|-----------:|-----------:|------------:|------------:|----------:|
| /hello | dart:io | 70 | 151 | 1,871 | 3,032 | 31,604 |
| /hello | shelf | 82 | 203 | 2,663 | 4,525 | 22,567 |
| /hello | nitro | 74 | 139 | 1,176 | 2,821 | 48,940 |
| /json | dart:io | 70 | 143 | 1,941 | 3,469 | 29,483 |
| /json | shelf | 82 | 174 | 2,647 | 3,868 | 22,663 |
| /json | nitro | 78 | 162 | 1,196 | 3,444 | 46,636 |
| /users/:id | dart:io | 72 | 164 | 1,890 | 2,942 | 31,548 |
| /users/:id | shelf | 82 | 190 | 2,612 | 3,419 | 23,895 |
| /users/:id | nitro | 78 | 178 | 1,223 | 4,371 | 45,455 |
| /files/* | dart:io | 71 | 176 | 1,916 | 2,820 | 32,217 |
| /files/* | shelf | 89 | 186 | 2,695 | 3,855 | 22,421 |
| /files/* | nitro | 74 | 148 | 1,130 | 2,591 | 52,682 |
| /q?a=1&b=two | dart:io | 70 | 147 | 1,969 | 2,824 | 31,470 |
| /q?a=1&b=two | shelf | 85 | 199 | 2,624 | 3,417 | 23,185 |
| /q?a=1&b=two | nitro | 74 | 142 | 1,143 | 2,538 | 52,412 |
| /mw | dart:io | 68 | 136 | 1,853 | 2,571 | 33,490 |
| /mw | shelf | 80 | 148 | 2,555 | 3,422 | 23,700 |
| /mw | nitro | 73 | 139 | 1,188 | 2,722 | 50,496 |
| /work | dart:io | 385 | 602 | 18,377 | 21,013 | 3,435 |
| /work | shelf | 394 | 656 | 19,266 | 34,330 | 3,269 |
| /work | nitro | 396 | 634 | 17,496 | 19,188 | 3,634 |
| POST /echo 4k | dart:io | 134 | 220 | 2,194 | 3,069 | 28,043 |
| POST /echo 4k | shelf | 147 | 235 | 2,908 | 3,881 | 21,338 |
| POST /echo 4k | nitro | 143 | 241 | 1,949 | 4,049 | 29,340 |
| POST /echo 1m | dart:io | 15,147 | 18,432 | 278,460 | 692,468 | 236 |
| POST /echo 1m | shelf | 14,747 | 15,351 | 261,539 | 420,825 | 255 |
| POST /echo 1m | nitro | 14,789 | 17,589 | 258,429 | 511,069 | 251 |
| GET /events | dart:io | 103 | 262 | 3,195 | 4,043 | 19,438 |
| GET /events | shelf | 89 | 189 | 2,878 | 3,863 | 21,685 |
| GET /events | nitro | 95 | 188 | 1,727 | 3,778 | 35,801 |

`Connection: close` (default):

| Route | Server | seq p50 µs | seq p99 µs | load p50 µs | load p99 µs | req/s @64 |
|-------|--------|-----------:|-----------:|------------:|------------:|----------:|
| /hello | dart:io | 172 | 265 | 3,319 | 16,157 | 14,999 |
| /hello | shelf | 198 | 366 | 3,913 | 10,052 | 14,327 |
| /hello | nitro | 161 | 322 | 3,189 | 11,160 | 17,573 |
| /json | dart:io | 176 | 312 | 3,445 | 10,239 | 15,534 |
| /json | shelf | 197 | 418 | 4,236 | 10,647 | 13,085 |
| /json | nitro | 159 | 302 | 3,357 | 11,312 | 16,660 |
| /users/:id | dart:io | 191 | 398 | 3,330 | 11,140 | 15,474 |
| /users/:id | shelf | 209 | 433 | 3,931 | 9,070 | 14,156 |
| /users/:id | nitro | 158 | 298 | 3,426 | 12,236 | 15,469 |
| /files/* | dart:io | 184 | 380 | 3,175 | 10,789 | 17,238 |
| /files/* | shelf | 192 | 333 | 3,966 | 9,773 | 13,908 |
| /files/* | nitro | 155 | 254 | 3,184 | 9,891 | 17,782 |
| /q?a=1&b=two | dart:io | 177 | 302 | 3,260 | 9,518 | 16,318 |
| /q?a=1&b=two | shelf | 190 | 311 | 4,019 | 9,344 | 14,067 |
| /q?a=1&b=two | nitro | 155 | 263 | 3,234 | 10,916 | 17,126 |
| /mw | dart:io | 186 | 452 | 3,534 | 11,059 | 15,149 |
| /mw | shelf | 200 | 425 | 3,976 | 8,830 | 14,110 |
| /mw | nitro | 155 | 263 | 3,185 | 11,296 | 16,585 |
| /work | dart:io | 477 | 740 | 20,010 | 38,534 | 3,080 |
| /work | shelf | 510 | 1,046 | 20,712 | 30,109 | 3,057 |
| /work | nitro | 488 | 688 | 17,890 | 34,191 | 3,454 |
| POST /echo 4k | dart:io | 241 | 380 | 3,566 | 5,761 | 15,974 |
| POST /echo 4k | shelf | 255 | 401 | 4,218 | 6,605 | 13,757 |
| POST /echo 4k | nitro | 228 | 356 | 3,750 | 8,686 | 15,066 |
| POST /echo 1m | dart:io | 15,451 | 23,082 | 243,258 | 469,459 | 246 |
| POST /echo 1m | shelf | 15,402 | 23,847 | 264,279 | 511,168 | 224 |
| POST /echo 1m | nitro | 15,689 | 25,511 | 276,566 | 743,830 | 196 |
| GET /events | dart:io | 222 | 639 | 5,330 | 38,288 | 10,395 |
| GET /events | shelf | 198 | 428 | 4,525 | 7,345 | 12,650 |
| GET /events | nitro | 191 | 495 | 3,939 | 66,707 | 11,411 |

Under keep-alive load nitro serves the small routes at about 1.5× dart:io's
rate with about 35% lower p50, and streams at about 1.8×. `/work` is
handler-bound: equal on every side at one isolate. On one idle connection
the two are within a few microseconds. `POST /echo 1m` is bound by loopback
bandwidth on every side. `shelf` trails `dart:io` by its framework layers.
With `Connection: close` the handshake dominates: throughput is within 10%
on every case, and nitro's tails on streaming and the 1 MiB echo are worse
than dart:io's.

`/work` is where `--isolates` matters. With the raw client and 32
connections, one isolate serves about 3.4k req/s on every side; four
isolates give nitro 10.9k and dart:io (`shared: true` ×4) 11.3k, while
shelf stays single-isolate. The full scaling tables are in
`PERFORMANCE_PLAN.md`.

Your machine will differ. Run it before quoting anything.
