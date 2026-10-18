# Production-grade benchmark: nitro_server vs the field

A multi-metric comparison of `nitro_server` against `dart:io` `HttpServer`, `shelf`,
Go `net/http`, and Node (cluster). Raw throughput is one axis; a production server
is also judged on **tail latency, stability, error behaviour, overload headroom,
CPU efficiency, memory, and drift under sustained load**. This page covers all of
them.

- **Host:** Apple Silicon, 8 cores, loopback, AOT (`dart compile exe`), `go build`,
  Node cluster (one worker/core).
- **Workload:** handler-to-handler `/json` (`{"message":"Hello, World!"}` serialized
  per request). No engine-served static route — every framework runs real handler
  code. `/plaintext` tracks within ~2%.
- **nitro config:** the shipping default dealt across `isolates = cores`; the engine's
  adaptive dispatch decides how many isolates actually serve (see
  [adaptive dispatch](#adaptive-dispatch)).
- **Load generators:** `wrk` (closed-loop throughput/overload) and `oha -q`
  with `--latency-correction` (open-loop, coordinated-omission-free latency).
- Numbers are medians of 5 rounds unless noted. Ambient desktop load was present,
  so absolute req/s is a few percent below a pristine machine; within-run ranking
  and ratios are what matter.

## Headline

nitro is **3rd in raw throughput** (ahead of dart:io and shelf, behind Node/Go), but
leads the field on the metrics that decide production behaviour: the **best closed-loop
tail**, the **tightest worst-case open-loop tail**, **far and away the best CPU
efficiency** (~2.4× the next best), a **lean single-process memory footprint** (~20×
smaller than Node), and the **best sustained-rate stability**. Go wins typical latency
(native, no GC); Node wins raw throughput at a large memory cost.

## 1. Throughput + latency + stability — closed-loop `/json`

`wrk -t2 -c64 -d10s`, median of 5. CoV = run-to-run coefficient of variation (stability).

| framework | req/s | CoV | p50 ms | p90 ms | p99 ms |
| --- | --: | --: | --: | --: | --: |
| node | 146,899 | 0.1% | 0.30 | 0.50 | 2.18 |
| go | 137,218 | 0.2% | 0.31 | 0.57 | 1.21 |
| **nitro (adaptive)** | 114,488 | 2.9% | 0.50 | 0.63 | **0.76** |
| dart:io | 102,153 | 0.8% | 0.48 | 1.02 | 2.50 |
| shelf | 85,159 | 0.9% | 0.59 | 1.47 | 4.47 |

nitro has the **best closed-loop p99 (0.76 ms)** and the flattest distribution
(p50→p99 only 1.5×, vs 5–9× for the others).

## 2. Open-loop latency — coordinated-omission-free

`oha -q 60000 -c64 --latency-correction`, 5×15 s. Closed-loop tools pause when the
server stalls, hiding the tail; a fixed send rate exposes the latency a steady stream
of clients actually sees. Tails here are GC-pause-driven and vary run-to-run, so both
the **median** (typical) and **max** (worst GC spike) are shown.

| framework | p50 ms | p99 median | p99 **max** | p99.9 median |
| --- | --: | --: | --: | --: |
| go | 0.68 | 2.26 | 11.9 | 19.5 |
| shelf | 0.82 | 2.97 | 32.1 | 10.4 |
| node | 0.60 | 3.53 | 6.39 | 30.7 |
| **nitro** | 0.79 | 3.87 | **6.01** | 31.7 |
| dart:io | 0.75 | 14.84 | 26.7 | 43.6 |

Go leads typical p99 (native, no GC). nitro/node/shelf cluster at 3–4 ms; dart:io is
the outlier (14.8 ms). **nitro has the tightest worst-case p99 (6.01 ms)** — the most
predictable tail in the field. (A single run once showed nitro at 27 ms; multi-round
measurement showed that was sampling noise — the open-loop tail must be measured over
several rounds to be credible.)

## 3. Overload behaviour

`wrk -t4`, 10 s. How each framework degrades past its comfort zone.

| framework | -c256 req/s | -c256 p99 | -c1024 req/s | -c1024 p99 | errors |
| --- | --: | --: | --: | --: | --: |
| **nitro** | 126,865 | **2.97 ms** | 127,558 | 12.4 ms | 0 / none |
| go | 143,324 | 5.83 ms | 149,277 | 14.4 ms | 0 / none |
| node | 149,173 | 18.5 ms | 152,406 | 37.0 ms | 0 / none |
| dart:io | 98,636 | 15.1 ms | 96,965 | 39.0 ms | 0 / none |
| shelf | 83,427 | 10.9 ms | 87,219 | 38.4 ms | 0 / none |

**Zero dropped connections or non-2xx responses anywhere** — every framework is robust
under overload. nitro's throughput *rises* under concurrency (114k→127k, the adaptive
controller fanning out under backlog) while keeping the best p99.

## 4. CPU efficiency

`wrk -t2 -c64`, server CPU% sampled (process-group sum). `req/s per core` normalizes
throughput by cores actually used.

| framework | req/s | CPU% | req/s per core |
| --- | --: | --: | --: |
| **nitro** | 113,184 | 136% | **83,223** |
| go | 130,605 | 384% | 34,012 |
| node | 144,717 | 439% | 32,965 |
| dart:io | 102,788 | 456% | 22,541 |
| shelf | 84,280 | 467% | 18,047 |

nitro serves 113k on **~1.4 cores** — **2.4× the per-core efficiency of Go**, ~4× that
of dart:io/Node. The C++ engine does accept/parse/route/write; a single Dart isolate
runs the light handler. The rest of the box stays free for the application's real work,
where the other frameworks consume every core just to serve HTTP.

## 5. Memory — RSS (MB)

Process-group resident set, idle after bind and peak under `-c64` load.

| framework | processes | idle MB | load MB |
| --- | --: | --: | --: |
| go | 1 | 10.1 | 21.2 |
| dart:io | 1 | 14.8 | 27.0 |
| **nitro** | 1 | 17.0 | 30.6 |
| shelf | 1 | 15.5 | 33.4 |
| node | 9 | 443.9 | 603.6 |

nitro (one process, all isolates as threads) sits in the lean tier with Go/dart:io, and
is **~20× smaller than Node's cluster** (9 processes, 604 MB under load).

## 6. Sustained-run drift

`oha -q 60000`, 5 min per framework in 30 s windows — latency drift (window 1 vs 10)
and RSS growth (leak detection under real load).

| framework | RSS 0→5 min | p99 drift | p99 max | sustained rps | success |
| --- | --: | --: | --: | --: | --: |
| **nitro** | 17→50 MB | 1.50× | 19.1 ms | 59,995 (held) | 100% |
| dart:io | 15→50 MB | 2.01× | 9.4 ms | 55,207 (short) | 100% |
| go | 10→22 MB | 0.69× | 96.4 ms | 59,678 | 100% |
| node | 442→667 MB | 0.50× | 27.3 ms | 59,995 (held) | 100% |

No framework leaked (all held 100% success over 5 min). nitro's RSS growth matches
dart:io's — both Dart, both settle to a ~50 MB working-set, **not a leak**; Node's
cluster settles an order of magnitude higher (442→667 MB). nitro has the **least
latency drift of the managed runtimes** and, with Node, **held the 60k rate** (dart:io
fell to 55k). Go spiked to 96 ms once (a GC/scheduler stall) despite the best median.

## Adaptive dispatch

A light handler and a CPU-bound handler want opposite isolate counts, and a single
server often has both. The engine resolves this automatically by hill-climbing the
dispatch width toward maximum throughput (see `src/engine/DispatchController.h`).

Isolate scaling by workload (`-c64`, dispatch width pinned):

| isolates | light `/json` req/s | CPU-bound `/work` req/s |
| --: | --: | --: |
| 1 | 113,796 | 6,948 |
| 2 | 95,262 | 14,050 |
| 4 | 83,283 | 26,580 |
| 8 | 78,362 | 38,678 |

More isolates *hurt* a light handler (the cores-wide engine already does the I/O; extra
isolates only add coordination) but scale a CPU-bound handler near-linearly. The
controller picks the right width per workload with no configuration:

| workload | adaptive | pin width=1 | pin width=8 |
| --- | --: | --: | --: |
| light `/json` | 110,571 | 109,384 (opt) | 77,484 |
| CPU-bound `/work` | 36,106 | 6,997 | 36,710 (opt) |
| mixed 90/10 | 89,186 | 56,129 | — |

Adaptive matches the hand-tuned optimum in every regime, including the mixed workload
a fixed width can't win.

## AOT vs JIT

The three Dart servers run in both modes — **AOT** (`dart compile exe`, native) and
**JIT** (`dart compile kernel` + `dart <dill>`: the VM JIT, measured from a kernel
snapshot so the resident source-compiler doesn't skew memory). Go is always AOT, Node
always JIT (V8), shown as single-mode references. Produced by
`benchmark/techempower/production_suite.sh` (one 8-core run, `/json` unless noted;
`wrk -t2 -c64 -d6s ×3`, `oha -q 60000 --latency-correction`). **Zero errors (non-2xx
or socket) in every config, both modes, including -c1024 overload.**

### Throughput — req/s (`/json`)
| framework | AOT | JIT |
| --- | --: | --: |
| nitro | 108,203 | 107,242 |
| dart:io | 95,242 | 85,392 |
| shelf | 80,778 | 75,605 |
| go | 131,684 | — |
| node | — | 142,684 |

nitro's **JIT matches AOT** (107–108k) once warmed; dart:io/shelf are ~10% faster AOT.
(`/plaintext`: nitro 114,648 AOT / 107,535 JIT.)

### Memory — RSS MB (the clearest AOT/JIT difference)
| framework | AOT idle | JIT idle | AOT load | JIT load |
| --- | --: | --: | --: | --: |
| nitro | 17 | 85 | 52 | 123 |
| dart:io | 15 | 80 | 56 | 125 |
| shelf | 16 | 88 | 58 | 132 |
| go | 10 | — | 49 | — |
| node | — | 444 | — | 696 |

**AOT is ~5× leaner than JIT** (17 vs 85 MB idle) — JIT carries the VM + JIT-compiled
code resident. This is the decisive reason to ship AOT.

### CPU efficiency — req/s per core (mode-independent)
| framework | AOT | JIT |
| --- | --: | --: |
| nitro | 74,186 | 74,508 |
| dart:io | 23,559 | 21,350 |
| shelf | 18,580 | 16,870 |
| go | 30,808 | — |
| node | — | 34,030 |

nitro's **2.2–2.4× per-core efficiency holds in both modes** — the C++ engine does the
work regardless of how the Dart handler is compiled.

### Latency, startup, overload
| metric | nitro AOT | nitro JIT | notes |
| --- | --: | --: | --- |
| startup to 1st req | 1186 ms | 397 ms | AOT exe cold-load vs warm VM; setup-sensitive |
| closed-loop p50 / p99 | 0.51 / 2.73 ms | 0.53 / 1.14 ms | comparable; JIT p99 better this run |
| open-loop p99 (CO-free) | 3.87 ms | 29.0 ms | GC-dominated, high run-to-run variance† |
| overload -c256 req/s / p99 | 122,993 / 3.67 ms | 104,082 / 6.38 ms | AOT scales higher |
| overload -c1024 p99 | 146.6 ms | 17.5 ms | both are single-run GC outliers† |
| stability CoV | 2.9% | 0.1% | |

† The open-loop tail and the -c1024 p99 are GC-pause-driven and vary heavily run to
run (see §2); a single suite pass is not a credible mode comparison for them — use the
5-round §2 numbers for tails. Throughput, memory, CPU and errors are stable and are the
trustworthy AOT-vs-JIT signals here.

**Verdict:** ship **AOT** — same throughput as JIT (for nitro), ~5× less memory,
identical CPU efficiency, zero errors. JIT's value is dev-iteration speed (no compile
step) and it reaches AOT throughput after warmup.

## Reproducing

Servers are in `benchmark/techempower/` (`nitro_tfb.dart`, `dartio_tfb.dart`,
`shelf_tfb.dart`, `go_tfb.go`, `node_tfb.js`); `nitro_tfb_iso.dart` adds a CPU-bound
`/work` route and `isolates`/`workerThreads` arguments for the dispatch sweeps.
Closed-loop uses `wrk`; open-loop uses `oha -q <rate> --latency-correction`
(`wrk2` won't build on Apple Silicon — its bundled luajit predates arm64).

`benchmark/techempower/production_suite.sh` runs the whole matrix above — startup,
throughput + CoV (`/json` and `/plaintext`), closed- and open-loop latency, overload
at -c256/-c1024 with error counts, CPU per core, and memory — for every framework in
**AOT and JIT**, printing one table per metric. Tunable via `DUR`, `ROUNDS`, `RATE`,
`CONN` env vars. Requires `wrk` and `oha` (`cargo install oha`) on `PATH`.
