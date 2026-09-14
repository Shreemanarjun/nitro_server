# Benchmark: `nitro_server` vs `shelf` vs `dart:io HttpServer`

`compare.dart` serves the same routes from all three servers and drives
them with the same client, in interleaved rounds (A/B/C, A/B/C). Every
case asserts exact status and bytes.

- Sequential latency: one client isolate, `package:benchmark_harness`
  (100 ms warmup, ~2 s exercise), p50/p99 from the same samples.
- Load: several client isolates in a closed loop for a fixed time;
  throughput and per-request latency.
- The driver never shares a server's isolate.

## Cases

| case | exercises |
|------|-----------|
| `/hello`, `/json` | literal routes |
| `/users/:id` | `:param` capture |
| `/files/*` | trailing wildcard |
| `/q?a=1&b=two` | query parsing |
| `/mw` | one pass-through middleware layer |
| `/work` | JSON-encoding handler (200 records): handler CPU |
| `/file` | 64 KiB static file: `File.openRead` on dart:io and shelf, `sendfile` on nitro |
| `POST /echo 4k` | 4 KiB upload and echo |
| `POST /echo 1m` | 1 MiB upload and echo |
| `GET /events` | 20-chunk `text/event-stream` |
| `WS /ws 128B`, `4k`, `4k deflate` | WebSocket echo: text, binary, permessage-deflate |

## Modes

- `--keep-alive`: persistent connections on all sides. Nitro binds with
  `maxRequestsPerConnection: 0`; the other two never cap requests per
  connection.
- Default (close): every side answers `Connection: close`. Sequential
  latency only, one round, `--cooldown` seconds before each side (default
  30). A load sweep in this mode exhausts the client's ephemeral ports
  (macOS: ~16k ports, 30 s TIME_WAIT); `--connections N` forces one anyway.
  The driver retries after 50 ms on `EADDRNOTAVAIL`.

## Run

```sh
cmake -S src -B build/lib -DCMAKE_BUILD_TYPE=Release
cmake --build build/lib --parallel
dart compile exe benchmark/compare.dart -o build/benchmark/compare
./build/benchmark/compare --keep-alive
./build/benchmark/compare
```

`dart run benchmark/compare.dart` runs the driver under the JIT; quote AOT.

| flag | meaning |
|------|---------|
| `--quick` | 1 s of load per case, 32 connections, one round |
| `--keep-alive` | persistent connections on all sides |
| `--connections N` | load connections (default 64 keep-alive, 0 close) |
| `--clients N` | client isolates (default 4) |
| `--seconds N` | load duration per case (default 3) |
| `--only "<case>"` | one case, e.g. `"GET /events"` |
| `--workers N` | nitro worker-pool cap (0 = engine default) |
| `--isolates N` | Dart isolates for nitro (0 = auto) and `shared: true` isolates for dart:io |
| `--raw` | raw-socket load client for one-shot cases (a few µs of client CPU per request) |
| `--cooldown N` | seconds before each side (default 30 in close mode, 0 otherwise) |
| `--json <path>` | machine-readable results |
| `--dylib <path>` | native library path |

## Columns

| column | measures |
|--------|----------|
| seq p50/p99 | one connection, one request at a time |
| load p50/p99 | per-request latency with N connections open |
| req/s @N | completed requests per second across N connections |

## Results

Apple M1 Pro, loopback, AOT. Keep-alive: 64 connections from 4 client
isolates, 3 s of load per case, second of two rounds.

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

`Connection: close` (sequential only, 30 s cooldown before each side):

| Route | Server | seq p50 µs | seq p99 µs |
|-------|--------|-----------:|-----------:|
| /hello | dart:io | 173 | 391 |
| /hello | shelf | 184 | 458 |
| /hello | nitro | 139 | 260 |
| /json | dart:io | 161 | 339 |
| /json | shelf | 170 | 300 |
| /json | nitro | 149 | 290 |
| /users/:id | dart:io | 160 | 288 |
| /users/:id | shelf | 172 | 308 |
| /users/:id | nitro | 150 | 311 |
| /files/* | dart:io | 166 | 375 |
| /files/* | shelf | 170 | 311 |
| /files/* | nitro | 145 | 270 |
| /q?a=1&b=two | dart:io | 163 | 378 |
| /q?a=1&b=two | shelf | 169 | 309 |
| /q?a=1&b=two | nitro | 139 | 247 |
| /mw | dart:io | 161 | 301 |
| /mw | shelf | 182 | 355 |
| /mw | nitro | 139 | 272 |
| /work | dart:io | 472 | 676 |
| /work | shelf | 487 | 720 |
| /work | nitro | 484 | 664 |
| /file | dart:io | 265 | 462 |
| /file | shelf | 277 | 446 |
| /file | nitro | 201 | 375 |
| POST /echo 4k | dart:io | 231 | 425 |
| POST /echo 4k | shelf | 246 | 439 |
| POST /echo 4k | nitro | 218 | 405 |
| POST /echo 1m | dart:io | 15,195 | 16,851 |
| POST /echo 1m | shelf | 15,155 | 16,158 |
| POST /echo 1m | nitro | 15,036 | 19,874 |
| GET /events | dart:io | 184 | 361 |
| GET /events | shelf | 174 | 283 |
| GET /events | nitro | 155 | 243 |

Additional measurements (`--quick --raw`, 32 connections):

| case | nitro req/s | dart:io req/s | shelf req/s |
|------|------------:|--------------:|------------:|
| `/hello`, 1 isolate | 61,464 | 36,401 | — |
| `/hello`, 4 isolates (dart:io `shared: true` ×4) | 61,269 | 63,253 | — |
| `/work`, 1 isolate | 3,413 | 3,464 | 3,347 |
| `/work`, 4 isolates | 10,929 | 11,298 | 3,058 |
| `/file` | 24,627 | 11,827 | 10,865 |

WebSocket echo (keep-alive, one message per round trip; shelf has no
WebSocket):

| case | nitro req/s | dart:io req/s | nitro seq p50 | dart:io seq p50 |
|------|------------:|--------------:|--------------:|----------------:|
| `WS /ws 128B` | 62,730 | 42,859 | 55 us | 51 us |
| `WS /ws 4k` | 58,478 | 41,824 | 59 us | 53 us |
| `WS /ws 4k deflate` | 20,314 | 20,354 | 111 us | 98 us |

Numbers are machine-specific.
