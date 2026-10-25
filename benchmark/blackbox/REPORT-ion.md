# Blackbox cross-framework benchmark

Throughput + full latency distribution + peak memory, one run, medians over reps.

**Headline:** the cleanest win is `/echo` — **119k vs Go's —** on real request-body parsing, with no fairness asterisk (`/static` is engine-served, `/work` carries the route note below). nitro is also ~51055.9× Go on `/work` and beats Node on `/echo`. Second on trivial routes: Go leads light I/O (`/json`) by ~-100%.

`p50:p99` is the tail-flatness ratio: **lower = flatter distribution, NOT faster.** **bold** req/s = fastest for that route.

(only one nitro variant ran: no @Native vs DynamicLibrary comparison in this report)



## Machine
- generator: oha 1.16.0 — run IN-container, pinned to cores 3-5 (disjoint from the server's 0-2)
- container: Debian GNU/Linux 13 (trixie) on aarch64; VM cores visible=6
- server cores=0-2 (3), client cores=3-5; memory cap=7.7 GiB
- load: 64 connections, 10s/route, 5 reps interleaved (order reversed on even reps), keep-alive; median reported
- host: docker --cpuset-cpus pin inside colima VM (Apple Silicon). For a cross-machine matrix, rerun run.sh on each host.
- image: nitro-blackbox, built from the tree now committed as 5d0bd44 (ServerDefaults, serverHeader/keepAliveHeader/collectMetrics, benchmark/ion_server); rerun from 5d0bd44 or later
- rerun (from the repo root; builds the same image, then runs this exact configuration):

  ```sh
  benchmark/blackbox/run.sh --cpus 0-5 --mem 7g --reps 5 --duration 10s --connections 64 --frameworks "nitro-native ion"
  ```

## Per-framework configuration (equal CPU budget = 3 cores)
- **nitro-native**: @Native code asset; isolates=3, engine event loops=3; parity config: no Server-Timing/x-server/Keep-Alive line, no per-request timeout, HTTP/1.1 only, no metrics recording
- **ion**: ion_web 0.1.2 + ion_router 0.1.1; shared isolates=3 (SO_REUSEPORT, pure-Dart HTTP/1.1 over dart:io sockets)


## Equal-work routes (same handler work, equal CPU budget)

`/work` encodes 200 JSON records **per request** on every framework (byte-identical output, validated below). An earlier version of this benchmark had the Go/Node handlers memcpy a body built **once** at startup (their `/work` ≈ their `/hello`), so any `/work` number from a prior page is NOT comparable to these — the handler's work changed. Go's `/work` (17k, p50:p99 **24×**) is dominated by per-request `encoding/json.Marshal` and the GC churn it creates: the 24× tail is GC-pause spikes, not steady slowness (the same Go does 221k on allocation-free light routes).

| route | framework | req/s | p50 | p90 | p95 | p99 | p50:p99 |
|---|---|--:|--:|--:|--:|--:|--:|
| /hello | nitro-native | **202150** | 0.27 | 0.50 | 0.62 | 0.92 | 3.4× |
| /hello | ion | 106478 | 0.33 | 0.52 | 2.01 | 7.90 | 24.0× |
| | | | | | | | |
| /json | nitro-native | **205198** | 0.27 | 0.50 | 0.62 | 0.93 | 3.4× |
| /json | ion | 107758 | 0.32 | 0.52 | 2.23 | 6.05 | 19.1× |
| | | | | | | | |
| /q?a=1&b=two | nitro-native | **195718** | 0.29 | 0.50 | 0.62 | 0.94 | 3.2× |
| /q?a=1&b=two | ion | 101215 | 0.36 | 0.64 | 2.50 | 7.79 | 21.7× |
| | | | | | | | |
| /users/42 | nitro-native | **206429** | 0.26 | 0.51 | 0.66 | 1.04 | 4.0× |
| /users/42 | ion | 118684 | 0.34 | 0.55 | 1.90 | 4.37 | 13.0× |
| | | | | | | | |
| /files/x | nitro-native | **201479** | 0.28 | 0.51 | 0.62 | 0.96 | 3.4× |
| /files/x | ion | 116196 | 0.35 | 0.55 | 1.91 | 4.74 | 13.7× |
| | | | | | | | |
| /mw | nitro-native | **206433** | 0.27 | 0.52 | 0.63 | 0.95 | 3.6× |
| /mw | ion | 106176 | 0.32 | 0.50 | 2.35 | 7.31 | 23.0× |
| | | | | | | | |
| /work | nitro-native | **51056** | 1.16 | 1.85 | 2.36 | 3.54 | 3.1× |
| /work | ion | 25071 | 2.33 | 3.27 | 4.27 | 7.34 | 3.2× |
| | | | | | | | |
| /echo|POST|4096 | nitro-native | **118607** | 0.51 | 0.79 | 0.92 | 1.16 | 2.3× |
| /echo|POST|4096 | ion | 73458 | 0.62 | 1.54 | 2.50 | 5.88 | 9.5× |
| | | | | | | | |

## Engine fast-path (NOT equal work — shown separately)

nitro answers `/static` from the engine (`getStatic`, no handler/FFI); the other frameworks run a handler returning the same bytes. Illustrates nitro's cached-response path, not an apples-to-apples comparison.

| route | framework | req/s | p50 | p90 | p95 | p99 | p50:p99 |
|---|---|--:|--:|--:|--:|--:|--:|
| /static | nitro-native | **479916** | 0.12 | 0.16 | 0.18 | 0.36 | 2.9× |
| /static | ion | 112744 | 0.32 | 0.49 | 1.90 | 5.39 | 16.9× |
| | | | | | | | |

## Peak memory (RSS MB — whole-workload high-water per framework)

Server process tree, median of per-rep peaks. Per-route memory is not isolated (routes share one server per rep), so it is one number per framework, not a column.

nitro's number = **3 isolate Dart heaps + the native libuv engine + per-isolate JsonWriter pools**; dartio runs the same 3 isolates with no native engine, Go is a single compact runtime. A separate per-route isolation probe confirmed nitro's RSS is **bounded**: `/work` peaks at the same level whether 1 or 3 isolates (the load splits across them, it does not multiply) and returns to baseline at idle — GC-reclaimed, not a leak. Earlier ~GB per-route figures were a measurement artifact (cumulative high-water misattributed to the last route).

**Per-component split** (isolation probe, 3 isolates): RSS is ~94% **fixed at startup** — the 3 Dart heaps + the native libuv engine, present at idle before any request. Load adds only ~16 MB (response buffers + JsonWriter pool), and the pool caps at live concurrency (~64 writers, a few MB) — nowhere near its `_poolMax=256` limit, so it is **not** a meaningful share; `_poolMax` becomes a knob only at far higher concurrency. The ~100 MB over dart:io (same 3 isolates, no engine) is therefore the native engine as a **fixed** cost, not retention or a per-request leak.

| framework | peak RSS MB |
|---|--:|
| nitro-native | 49 |
| ion | 78 |

## Response validation (rep 1)

Body-byte length per route must agree across frameworks (equal bytes = fair). Mismatches flagged.
Header bytes include the Date line (fixed length), so equal header bytes = equal wire overhead.

| route | bodies agree? | body bytes | headers agree? | header bytes |
|---|---|---|---|---|
| /hello | ✅ | nitro-native=12, ion=12 | ✅ | nitro-native=140, ion=140 |
| /json | ✅ | nitro-native=45, ion=45 | ✅ | nitro-native=140, ion=140 |
| /static | ✅ | nitro-native=12, ion=12 | ✅ | nitro-native=126, ion=126 |
| /q?a=1&b=two | ✅ | nitro-native=19, ion=19 | ✅ | nitro-native=147, ion=147 |
| /users/42 | ✅ | nitro-native=7, ion=7 | ✅ | nitro-native=140, ion=140 |
| /files/x | ✅ | nitro-native=13, ion=13 | ✅ | nitro-native=141, ion=141 |
| /mw | ✅ | nitro-native=12, ion=12 | ✅ | nitro-native=140, ion=140 |
| /work | ✅ | nitro-native=11617, ion=11617 | ✅ | nitro-native=150, ion=150 |
| /echo|POST|4096 | ✅ | nitro-native=4096, ion=4096 | ✅ | nitro-native=142, ion=142 |

All sampled responses returned HTTP 200.
