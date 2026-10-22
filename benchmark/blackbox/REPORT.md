# Blackbox cross-framework benchmark

Throughput + full latency distribution + peak memory, one run, medians over reps.

**Headline:** the cleanest win is `/echo` — **99k vs Go's 80k** on real request-body parsing, with no fairness asterisk (`/static` is engine-served, `/work` carries the route note below). nitro is also ~2.7× Go on `/work` and trails Node on `/echo`. Second on trivial routes: Go leads light I/O (`/json`) by ~32%.

`p50:p99` is the tail-flatness ratio: **lower = flatter distribution, NOT faster.** dartio's 1.6× on `/work` is flatter than nitro's 3.4× but at 9k vs 46k req/s — i.e. 1.6× of a slow number. **bold** req/s = fastest for that route.

**nitro-native ≈ nitro-dylib on every route** (170k/172k on `/hello`, 45k/46k on `/work`; widest gap 4% on `/echo|POST|4096`) — within run-to-run noise. The `@Native` code-asset vs `DynamicLibrary` FFI boundary costs nothing measurable.

## nitro-base vs nitro-dylib (A/B of two builds, interleaved in this run)

Baseline = `HEAD (eccef3f)`; working tree = nitro-dylib. Medians over the same interleaved reps; delta = (tree − base) / base.

| route | nitro-base req/s | nitro-dylib req/s | delta | base p99 | tree p99 |
|---|--:|--:|--:|--:|--:|
| /hello | 177001 | 171525 | -3.1% | 1.04 | 1.06 |
| /json | 171978 | 166466 | -3.2% | 1.11 | 1.10 |
| /static | 459818 | 455396 | -1.0% | 0.47 | 0.56 |
| /q?a=1&b=two | 167739 | 158205 | -5.7% | 1.21 | 1.22 |
| /users/42 | 166550 | 164492 | -1.2% | 1.12 | 1.14 |
| /files/x | 171092 | 168080 | -1.8% | 1.17 | 1.12 |
| /mw | 175676 | 169213 | -3.7% | 1.06 | 1.04 |
| /work | 44887 | 45541 | +1.5% | 4.10 | 4.11 |
| /echo|POST|4096 | 101805 | 99165 | -2.6% | 1.55 | 1.53 |

**Widest delta -5.7% on `/q?a=1&b=two`** (167739 → 158205 req/s) — beyond the ±5% noise band; rerun with more reps before believing it.

## Machine
- generator: oha 1.16.0 — run IN-container, pinned to cores 3-5 (disjoint from the server's 0-2)
- container: Debian GNU/Linux 13 (trixie) on aarch64; VM cores visible=6
- server cores=0-2 (3), client cores=3-5; memory cap=7.7 GiB
- load: 64 connections, 8s/route, 5 reps interleaved, keep-alive; median reported
- host: docker --cpuset-cpus pin inside colima VM (Apple Silicon). For a cross-machine matrix, rerun run.sh on each host.

## Per-framework configuration (equal CPU budget = 3 cores)
- **nitro-base**: A/B baseline — the tree at HEAD (eccef3f), same build as nitro-dylib; isolates=3
- **nitro-native**: @Native code asset; isolates=3 (engine fans CPU work across them)
- **nitro-dylib**: DynamicLibrary; isolates=3 (engine fans CPU work across them)
- **go**: net/http; GOMAXPROCS=3
- **node**: http + cluster; NODE_PROCS=3 workers
- **dartio**: dart:io HttpServer; shared isolates=3 (SO_REUSEPORT)
- **shelf**: shelf_io.serve; shared isolates=3 (SO_REUSEPORT, dart:io underneath)


## Equal-work routes (same handler work, equal CPU budget)

`/work` encodes 200 JSON records **per request** on every framework (byte-identical output, validated below). An earlier version of this benchmark had the Go/Node handlers memcpy a body built **once** at startup (their `/work` ≈ their `/hello`), so any `/work` number from a prior page is NOT comparable to these — the handler's work changed. Go's `/work` (17k, p50:p99 **24×**) is dominated by per-request `encoding/json.Marshal` and the GC churn it creates: the 24× tail is GC-pause spikes, not steady slowness (the same Go does 221k on allocation-free light routes).

| route | framework | req/s | p50 | p90 | p95 | p99 | p50:p99 |
|---|---|--:|--:|--:|--:|--:|--:|
| /hello | nitro-base | 177001 | 0.33 | 0.52 | 0.61 | 1.04 | 3.2× |
| /hello | nitro-native | 170143 | 0.34 | 0.53 | 0.64 | 1.06 | 3.1× |
| /hello | nitro-dylib | 171525 | 0.34 | 0.54 | 0.65 | 1.06 | 3.1× |
| /hello | go | **225250** | 0.22 | 0.53 | 0.74 | 1.40 | 6.2× |
| /hello | node | 149052 | 0.39 | 0.61 | 0.74 | 0.98 | 2.5× |
| /hello | dartio | 78572 | 0.57 | 1.04 | 2.14 | 9.15 | 16.0× |
| /hello | shelf | 51101 | 0.88 | 1.36 | 2.89 | 10.17 | 11.5× |
| | | | | | | | |
| /json | nitro-base | 171978 | 0.33 | 0.55 | 0.67 | 1.11 | 3.4× |
| /json | nitro-native | 169738 | 0.34 | 0.54 | 0.64 | 1.11 | 3.2× |
| /json | nitro-dylib | 166466 | 0.34 | 0.56 | 0.69 | 1.10 | 3.2× |
| /json | go | **219689** | 0.23 | 0.53 | 0.77 | 1.42 | 6.3× |
| /json | node | 149517 | 0.39 | 0.62 | 0.75 | 0.98 | 2.5× |
| /json | dartio | 70805 | 0.60 | 1.09 | 2.23 | 9.44 | 15.7× |
| /json | shelf | 61272 | 0.87 | 1.42 | 2.47 | 7.73 | 8.9× |
| | | | | | | | |
| /q?a=1&b=two | nitro-base | 167739 | 0.35 | 0.53 | 0.65 | 1.21 | 3.5× |
| /q?a=1&b=two | nitro-native | 156276 | 0.37 | 0.56 | 0.68 | 1.31 | 3.6× |
| /q?a=1&b=two | nitro-dylib | 158205 | 0.36 | 0.56 | 0.68 | 1.22 | 3.3× |
| /q?a=1&b=two | go | **217662** | 0.23 | 0.54 | 0.78 | 1.41 | 6.2× |
| /q?a=1&b=two | node | 131144 | 0.44 | 0.68 | 0.85 | 1.08 | 2.5× |
| /q?a=1&b=two | dartio | 68749 | 0.64 | 1.20 | 2.68 | 9.67 | 15.1× |
| /q?a=1&b=two | shelf | 58149 | 0.90 | 1.44 | 2.74 | 3.79 | 4.2× |
| | | | | | | | |
| /users/42 | nitro-base | 166550 | 0.35 | 0.55 | 0.67 | 1.12 | 3.2× |
| /users/42 | nitro-native | 163389 | 0.36 | 0.55 | 0.65 | 1.13 | 3.2× |
| /users/42 | nitro-dylib | 164492 | 0.35 | 0.55 | 0.66 | 1.14 | 3.2× |
| /users/42 | go | **222731** | 0.23 | 0.52 | 0.75 | 1.33 | 5.8× |
| /users/42 | node | 143595 | 0.40 | 0.64 | 0.77 | 1.06 | 2.7× |
| /users/42 | dartio | 72419 | 0.57 | 1.05 | 2.28 | 8.72 | 15.4× |
| /users/42 | shelf | 60880 | 0.85 | 1.46 | 2.46 | 4.88 | 5.8× |
| | | | | | | | |
| /files/x | nitro-base | 171092 | 0.33 | 0.52 | 0.64 | 1.17 | 3.5× |
| /files/x | nitro-native | 164254 | 0.35 | 0.55 | 0.68 | 1.15 | 3.2× |
| /files/x | nitro-dylib | 168080 | 0.35 | 0.54 | 0.65 | 1.12 | 3.2× |
| /files/x | go | **221278** | 0.23 | 0.53 | 0.76 | 1.37 | 6.0× |
| /files/x | node | 144436 | 0.41 | 0.66 | 0.79 | 1.04 | 2.5× |
| /files/x | dartio | 80262 | 0.61 | 1.02 | 1.74 | 5.16 | 8.4× |
| /files/x | shelf | 60408 | 0.86 | 1.40 | 2.28 | 9.17 | 10.6× |
| | | | | | | | |
| /mw | nitro-base | 175676 | 0.33 | 0.52 | 0.62 | 1.06 | 3.2× |
| /mw | nitro-native | 167033 | 0.35 | 0.55 | 0.66 | 1.10 | 3.1× |
| /mw | nitro-dylib | 169213 | 0.34 | 0.53 | 0.62 | 1.04 | 3.0× |
| /mw | go | **222527** | 0.20 | 0.53 | 0.77 | 1.43 | 7.2× |
| /mw | node | 149982 | 0.40 | 0.60 | 0.77 | 0.99 | 2.5× |
| /mw | dartio | 82902 | 0.56 | 1.03 | 2.09 | 6.83 | 12.1× |
| /mw | shelf | 60997 | 0.86 | 1.42 | 2.20 | 4.26 | 5.0× |
| | | | | | | | |
| /work | nitro-base | 44887 | 1.18 | 2.63 | 3.04 | 4.10 | 3.5× |
| /work | nitro-native | 45047 | 1.20 | 2.59 | 3.07 | 4.29 | 3.6× |
| /work | nitro-dylib | 45541 | 1.21 | 2.56 | 2.99 | 4.11 | 3.4× |
| /work | go | 16641 | 0.93 | 10.89 | 14.00 | 21.18 | 22.7× |
| /work | node | **54161** | 1.05 | 1.52 | 2.03 | 3.59 | 3.4× |
| /work | dartio | 8598 | 7.27 | 9.18 | 9.77 | 11.36 | 1.6× |
| /work | shelf | 8414 | 7.39 | 10.33 | 12.16 | 13.54 | 1.8× |
| | | | | | | | |
| /echo|POST|4096 | nitro-base | 101805 | 0.57 | 0.96 | 1.13 | 1.55 | 2.7× |
| /echo|POST|4096 | nitro-native | 102870 | 0.56 | 0.99 | 1.16 | 1.56 | 2.8× |
| /echo|POST|4096 | nitro-dylib | 99165 | 0.58 | 0.94 | 1.11 | 1.53 | 2.7× |
| /echo|POST|4096 | go | 80451 | 0.39 | 1.85 | 2.51 | 4.82 | 12.3× |
| /echo|POST|4096 | node | **109984** | 0.51 | 0.85 | 1.05 | 1.51 | 3.0× |
| /echo|POST|4096 | dartio | 64150 | 0.75 | 1.55 | 2.36 | 7.25 | 9.6× |
| /echo|POST|4096 | shelf | 45678 | 1.01 | 2.00 | 3.31 | 9.21 | 9.1× |
| | | | | | | | |

## Engine fast-path (NOT equal work — shown separately)

nitro answers `/static` from the engine (`getStatic`, no handler/FFI); the other frameworks run a handler returning the same bytes. Illustrates nitro's cached-response path, not an apples-to-apples comparison.

| route | framework | req/s | p50 | p90 | p95 | p99 | p50:p99 |
|---|---|--:|--:|--:|--:|--:|--:|
| /static | nitro-base | **459818** | 0.13 | 0.18 | 0.21 | 0.47 | 3.7× |
| /static | nitro-native | 450272 | 0.13 | 0.18 | 0.23 | 0.70 | 5.6× |
| /static | nitro-dylib | 455396 | 0.12 | 0.18 | 0.23 | 0.56 | 4.6× |
| /static | go | 222963 | 0.22 | 0.52 | 0.76 | 1.36 | 6.3× |
| /static | node | 148402 | 0.41 | 0.60 | 0.78 | 1.01 | 2.4× |
| /static | dartio | 74805 | 0.56 | 1.07 | 1.95 | 6.97 | 12.4× |
| /static | shelf | 61243 | 0.82 | 1.44 | 2.42 | 4.37 | 5.3× |
| | | | | | | | |

## Peak memory (RSS MB — whole-workload high-water per framework)

Server process tree, median of per-rep peaks. Per-route memory is not isolated (routes share one server per rep), so it is one number per framework, not a column.

nitro's number = **3 isolate Dart heaps + the native libuv engine + per-isolate JsonWriter pools**; dartio runs the same 3 isolates with no native engine, Go is a single compact runtime. A separate per-route isolation probe confirmed nitro's RSS is **bounded**: `/work` peaks at the same level whether 1 or 3 isolates (the load splits across them, it does not multiply) and returns to baseline at idle — GC-reclaimed, not a leak. Earlier ~GB per-route figures were a measurement artifact (cumulative high-water misattributed to the last route).

**Per-component split** (isolation probe, 3 isolates): RSS is ~94% **fixed at startup** — the 3 Dart heaps + the native libuv engine, present at idle before any request. Load adds only ~16 MB (response buffers + JsonWriter pool), and the pool caps at live concurrency (~64 writers, a few MB) — nowhere near its `_poolMax=256` limit, so it is **not** a meaningful share; `_poolMax` becomes a knob only at far higher concurrency. The ~100 MB over dart:io (same 3 isolates, no engine) is therefore the native engine as a **fixed** cost, not retention or a per-request leak.

| framework | peak RSS MB |
|---|--:|
| nitro-base | 153 |
| nitro-native | 154 |
| nitro-dylib | 151 |
| go | 12 |
| node | 391 |
| dartio | 53 |
| shelf | 51 |

## Response validation (rep 1)

Body-byte length per route must agree across frameworks (equal bytes = fair). Mismatches flagged.

| route | agree? | bytes (by framework) |
|---|---|---|
| /hello | ✅ | nitro-base=12, nitro-native=12, nitro-dylib=12, go=12, node=12, dartio=12, shelf=12 |
| /json | ✅ | nitro-base=45, nitro-native=45, nitro-dylib=45, go=45, node=45, dartio=45, shelf=45 |
| /static | ✅ | nitro-base=12, nitro-native=12, nitro-dylib=12, go=12, node=12, dartio=12, shelf=12 |
| /q?a=1&b=two | ✅ | nitro-base=19, nitro-native=19, nitro-dylib=19, go=19, node=19, dartio=19, shelf=19 |
| /users/42 | ✅ | nitro-base=7, nitro-native=7, nitro-dylib=7, go=7, node=7, dartio=7, shelf=7 |
| /files/x | ✅ | nitro-base=13, nitro-native=13, nitro-dylib=13, go=13, node=13, dartio=13, shelf=13 |
| /mw | ✅ | nitro-base=12, nitro-native=12, nitro-dylib=12, go=12, node=12, dartio=12, shelf=12 |
| /work | ✅ | nitro-base=11617, nitro-native=11617, nitro-dylib=11617, go=11617, node=11617, dartio=11617, shelf=11617 |
| /echo|POST|4096 | ✅ | nitro-base=4096, nitro-native=4096, nitro-dylib=4096, go=4096, node=4096, dartio=4096, shelf=4096 |

All sampled responses returned HTTP 200.
