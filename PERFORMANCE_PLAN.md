# Performance notes

Apple M1 Pro (8 cores), loopback, AOT. Unless stated: `--quick`, 32
connections across 4 client isolates, 1 s of load per case. Run-to-run
variance is about ±10%. Full-length results: `benchmark/README.md`.

## Engine changes, keep-alive `/hello`

| step | change | req/s | load p50 / p99 µs |
|------|--------|------:|------------------:|
| 0 | thread pool of 16 fixed workers, condition-variable wakes | 27,090 | 620 / 14,525 |
| A | 64 fixed workers | 38,417 | 696 / 2,464 |
| B | direct-write answers, poll-park workers, inline bodies ≤ 64 KiB, 64 KiB reads | 50,194 | 593 / 1,417 |
| C | stream chunks queued to the worker | 44,671 | 593 / 1,613 |
| D | leaf-call FFI path | 52,097 | 568 / 1,296 |
| E | auto-scaling pool (floor = cores, cap = 64) | 52,758 | 571 / 1,230 |
| E′ | pool pinned at 8 | 3,128 | 184 / 433 |
| F | sync handlers answered inline | 57,809 (`--raw`) | 533 / 1,070 |
| G | packed request headers, lazy unpack; query parsed on access | 61,891 (`--raw`) | 488 / 1,167 |
| H | heads combined per isolate under load (`RawIncomingBatch`) | 62,766 (`--raw`) | 488 / 941 |
| — | dart:io, same run as D | 33,680 | 886 / 1,316 |

G against the `--raw` baseline below (61,464) and, with the `HttpClient`
driver, 49,006 against 49,489: within run-to-run variance. H the same on
`/hello`; it drops the per-head contended bridge post, so its effect shows
only once the client stops being the bound (below).

## Scaling: 8 client isolates, 64 connections (`--raw`, `/hello`)

The 4-client default leaves the client the bound at this rate. With 8
client isolates the server saturates:

| server | req/s |
|--------|------:|
| dart:io, `shared: true` x4 | 68,581 |
| nitro, 4 isolates | 57,305 |
| nitro, 1 isolate | 58,812 |

dart:io scales past nitro here: it drives many sockets per `kevent`, while
nitro posts once per head per worker thread. Batching (H) cuts the post
count under load, not the per-connection thread or `poll` wake. Closing
the gap is the reactor (open item 2), not another bridge tweak.

Other cases across the same steps:

| step | `GET /events` req/s | `POST /echo 4k` req/s |
|------|--------------------:|----------------------:|
| 0 | 16,186 | 14,973 |
| B | 9,217 | 31,225 |
| C | 27,438 | — |
| D | 33,293 | 31,631 |
| dart:io | 19,827 | 27,060 |

Mechanisms behind B–D:

- Non-blocking sockets; reads via `poll()` + `recv`.
- The answering thread builds the head and writes head + body with one
  `sendmsg(MSG_DONTWAIT)`; the remainder becomes a per-request tail the
  worker flushes after one wake-pipe byte. A completed keep-alive answer
  wakes nobody.
- Pipelined input sets `workerWaiting`; the answering thread pokes only
  then. An fd is closed only by its worker.
- Stream chunks always go through the tail; the worker sends what
  accumulated since its last pass.
- Generated bindings: 0.7 µs per call (arena, record writer, two native
  allocations); leaf bindings with reusable buffers: 0.18 µs
  (`tool/perf/respond_bench.dart`). `test/fast_calls_test.dart` pins the
  wire format.

## Isolates (`--raw`)

| case | nitro | dart:io (`shared: true` ×N) | shelf |
|------|------:|----------------------------:|------:|
| `/hello`, 1 isolate | 61,464 | 36,401 | — |
| `/hello`, 2 isolates | 60,189 | 35,727 | — |
| `/hello`, 4 isolates | 61,893 | 36,003 | — |
| `/hello`, 4 isolates, dart:io shared ×4 | 61,269 | 63,253 | — |
| `/hello`, 1 isolate, 6 clients / 48 connections | 60,052 | 34,323 | — |
| `/work`, 1 isolate | 3,413 | 3,464 | 3,347 |
| `/work`, 4 isolates | 10,929 | 11,298 | 3,058 |

The `/hello` ceiling on this machine is the machine; the `/work` ceiling is
the isolate.

## Static files (`/file`, 64 KiB)

| driver | nitro | dart:io | shelf | nitro seq p50 | dart:io seq p50 |
|--------|------:|--------:|------:|--------------:|----------------:|
| `HttpClient` | 14,089 | 11,508 | 10,075 | 138 µs | 213 µs |
| `--raw` | 24,627 | 11,827 | 10,865 | 139 µs | 180 µs |

## Remaining per-request cost (Dart isolate, AOT, `/hello`)

About 16 µs: port message delivery ~2, head decode (~10 strings) ~3,
`RequestContext` ~2 (headers and query decode on first access), answer
call ~1, bookkeeping ~1, plus the handler.

## Open items

1. Head as one zero-copy blob; method, path and params decoded on access.
   Step G (headers, query) measured within variance on `/hello`.
2. Reactor (kqueue/epoll) instead of thread per connection, for thousands of
   connections. A `Poller` scaffold exists in commit `2df34f3`.
3. Request-side copies: inline small bodies in the head blob; skip the
   staging copy for externally allocated response bytes. Target: `POST 4k`
   sequential p50 below dart:io's.
4. Pre-encoded response heads for `const` header maps.
5. `Router::match` returns a pointer instead of copying the `RouteEntry`.
6. TLS in the engine; HTTP/2 via ALPN afterwards.

Done since: subprotocol selection (`server.ws(protocols:)`), per-isolate
head batching (step H), the `src/engine` line gate (`tool/cpp_coverage.sh`,
95%), thread/address sanitizers, and CI across Linux and macOS. libFuzzer
targets (`tool/fuzz.sh`, `test/fuzz`) are a local, untracked tool.

## Reproduce

```sh
cmake -S src -B build/lib -DCMAKE_BUILD_TYPE=Release
cmake --build build/lib --parallel
dart compile exe benchmark/compare.dart -o build/benchmark/compare
./build/benchmark/compare --keep-alive --json out.json
./build/benchmark/compare --quick --keep-alive --raw --only /work --isolates 4
dart compile exe tool/perf/respond_bench.dart -o build/respond_bench && ./build/respond_bench
```
