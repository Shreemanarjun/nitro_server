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

__KEEPALIVE_TABLE__

`Connection: close` (default):

__CLOSE_TABLE__

Under keep-alive load nitro serves the small routes at about 1.5× dart:io's
rate with about 35% lower p50, and streams at about 1.8×. `/work` is
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
