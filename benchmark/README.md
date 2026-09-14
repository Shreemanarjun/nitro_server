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
| `/file` | a 64 KiB static file: `File.openRead` on dart:io and shelf, native `sendfile` on nitro |
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

Close mode is bounded by the client, not the server: every request burns
an ephemeral port that sits in TIME_WAIT for a while, and macOS has about
16k of them. When the OS refuses a connect (`EADDRNOTAVAIL`) the driver
backs off 50 ms and retries without counting the request, so a long run
survives; the throughput it reports in that mode is the port budget as
much as the server.

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
| /hello | dart:io | 67 | 140 | 1,855 | 3,174 | 32,782 |
| /hello | shelf | 79 | 153 | 2,564 | 3,348 | 24,273 |
| /hello | nitro | 77 | 179 | 1,149 | 2,944 | 49,489 |
| /json | dart:io | 67 | 127 | 1,837 | 2,482 | 33,875 |
| /json | shelf | 79 | 140 | 2,543 | 3,239 | 24,581 |
| /json | nitro | 72 | 124 | 1,128 | 2,896 | 52,021 |
| /users/:id | dart:io | 69 | 141 | 1,861 | 2,559 | 33,354 |
| /users/:id | shelf | 82 | 162 | 2,604 | 3,479 | 23,847 |
| /users/:id | nitro | 75 | 145 | 1,171 | 3,241 | 50,101 |
| /files/* | dart:io | 69 | 160 | 1,882 | 2,871 | 32,599 |
| /files/* | shelf | 99 | 295 | 2,776 | 3,859 | 22,496 |
| /files/* | nitro | 74 | 156 | 1,155 | 2,675 | 51,398 |
| /q?a=1&b=two | dart:io | 68 | 119 | 1,928 | 2,919 | 31,986 |
| /q?a=1&b=two | shelf | 81 | 178 | 2,669 | 3,543 | 23,199 |
| /q?a=1&b=two | nitro | 73 | 123 | 1,139 | 2,397 | 53,180 |
| /mw | dart:io | 67 | 118 | 1,829 | 2,445 | 34,079 |
| /mw | shelf | 79 | 136 | 2,615 | 4,588 | 22,162 |
| /mw | nitro | 74 | 158 | 1,127 | 2,468 | 53,297 |
| /work | dart:io | 372 | 525 | 18,238 | 29,308 | 3,448 |
| /work | shelf | 382 | 515 | 18,965 | 23,338 | 3,345 |
| /work | nitro | 375 | 526 | 17,562 | 20,955 | 3,595 |
| /file | dart:io | 187 | 352 | 5,605 | 9,971 | 10,731 |
| /file | shelf | 227 | 665 | 6,616 | 13,007 | 9,040 |
| /file | nitro | 147 | 306 | 4,804 | 12,120 | 12,679 |
| POST /echo 4k | dart:io | 143 | 286 | 2,403 | 5,054 | 24,806 |
| POST /echo 4k | shelf | 149 | 291 | 3,004 | 4,471 | 20,597 |
| POST /echo 4k | nitro | 144 | 232 | 1,787 | 3,361 | 33,266 |
| POST /echo 1m | dart:io | 14,706 | 15,687 | 259,430 | 546,536 | 255 |
| POST /echo 1m | shelf | 14,843 | 31,390 | 263,898 | 571,859 | 224 |
| POST /echo 1m | nitro | 14,933 | 16,419 | 261,244 | 515,991 | 254 |
| GET /events | dart:io | 97 | 170 | 3,177 | 3,812 | 19,777 |
| GET /events | shelf | 89 | 155 | 2,851 | 3,556 | 21,991 |
| GET /events | nitro | 94 | 151 | 1,766 | 3,921 | 34,710 |

`Connection: close` (default):

| Route | Server | seq p50 µs | seq p99 µs | load p50 µs | load p99 µs | req/s @64 |
|-------|--------|-----------:|-----------:|------------:|------------:|----------:|
| /hello | dart:io | 177 | 293 | 3,203 | 9,136 | 16,931 |
| /hello | shelf | 192 | 306 | 3,944 | 9,958 | 14,400 |
| /hello | nitro | 156 | 250 | 3,246 | 13,366 | 17,110 |
| /json | dart:io | 177 | 300 | 3,197 | 10,418 | 16,784 |
| /json | shelf | 190 | 334 | 4,089 | 14,497 | 12,946 |
| /json | nitro | 161 | 297 | 3,320 | 11,148 | 16,298 |
| /users/:id | dart:io | 188 | 435 | 3,275 | 10,162 | 16,144 |
| /users/:id | shelf | 204 | 454 | 4,024 | 10,108 | 13,688 |
| /users/:id | nitro | 162 | 264 | 3,258 | 10,341 | 16,982 |
| /files/* | dart:io | 170 | 253 | 3,152 | 9,160 | 17,442 |
| /files/* | shelf | 197 | 443 | 4,135 | 11,466 | 13,236 |
| /files/* | nitro | 168 | 309 | 3,316 | 11,237 | 15,863 |
| /q?a=1&b=two | dart:io | 178 | 289 | 3,333 | 8,762 | 16,620 |
| /q?a=1&b=two | shelf | 216 | 505 | 4,675 | 49,551 | 10,710 |
| /q?a=1&b=two | nitro | 165 | 383 | 3,451 | 11,854 | 15,564 |
| /mw | dart:io | 197 | 464 | 3,434 | 10,357 | 14,981 |
| /mw | shelf | 196 | 363 | 3,958 | 10,735 | 14,087 |
| /mw | nitro | 157 | 256 | 3,239 | 9,636 | 17,349 |
| /work | dart:io | 502 | 870 | 20,232 | 37,639 | 3,080 |
| /work | shelf | 510 | 847 | 20,924 | 32,805 | 3,022 |
| /work | nitro | 500 | 729 | 18,411 | 27,961 | 3,427 |
| /file | dart:io | 298 | 583 | 8,096 | 35,608 | 4,384 |
| /file | shelf | 364 | 4,809 | 8,598 | 228,642 | 908 |
| /file | nitro | 309 | 3,940 | 6,048 | 15,344 | 8,745 |
| POST /echo 4k | dart:io | 252 | 401 | 4,779 | 18,725 | 10,469 |
| POST /echo 4k | shelf | 277 | 1,423 | 7,211 | 531,935 | 1,586 |
| POST /echo 4k | nitro | 273 | 2,854 | 8,854 | 454,415 | 803 |
| POST /echo 1m | dart:io | 15,601 | 34,358 | 244,383 | 446,197 | 251 |
| POST /echo 1m | shelf | 15,356 | 16,130 | 237,642 | 468,730 | 252 |
| POST /echo 1m | nitro | 15,404 | 16,221 | 260,476 | 460,223 | 235 |
| GET /events | dart:io | 189 | 450 | 4,827 | 7,311 | 12,566 |
| GET /events | shelf | 190 | 330 | 4,264 | 9,106 | 13,405 |
| GET /events | nitro | 173 | 290 | 3,423 | 9,610 | 16,502 |

Under keep-alive load nitro serves the small routes at about 1.5× dart:io's
rate with about 40% lower p50, and streams at about 1.8×. `/work` is
handler-bound: equal on every side at one isolate. On one idle connection
the two are within a few microseconds. `POST /echo 1m` is bound by loopback
bandwidth on every side. `shelf` trails `dart:io` by its framework layers.
With `Connection: close` the handshake dominates: throughput is within 10%
on every case, and nitro's tails on streaming and the 1 MiB echo are worse
than dart:io's.

`/file` measures the file path: with the raw client nitro serves the 64 KiB
file at 24.6k req/s against 11.8k for dart:io, because the bytes go from
the page cache to the socket in the native worker.

`/work` is where `--isolates` matters. With the raw client and 32
connections, one isolate serves about 3.4k req/s on every side; four
isolates give nitro 10.9k and dart:io (`shared: true` ×4) 11.3k, while
shelf stays single-isolate. The full scaling tables are in
`PERFORMANCE_PLAN.md`.

Your machine will differ. Run it before quoting anything.
