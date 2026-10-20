# Benchmarking nitro_server — the rule

Performance numbers for this project are only trustworthy if they are produced
**this way**. The dev-machine run-to-run variance is ~10–15%, large enough to
invent or hide an entire framework's worth of difference, so the method — not
just the number — is what makes a result real. Follow this for every perf claim.

## Hard rules

1. **Blackbox + containerized for cross-framework.** To compare nitro_server
   against other frameworks (Go, Node, dart:io, shelf) or to compare its own
   builds (`@Native` vs `_dylib`), use `benchmark/blackbox/` — each framework is
   an opaque HTTP server hit by an external load generator (`oha`) inside a
   pinned container. Never eyeball numbers from different tools or machines.

2. **Disjoint pinned cores.** The server and the load generator must run on
   **different** CPU cores (the harness splits the cpuset: first half = server,
   second half = `oha`) so the client never steals the server's CPU. This needs
   a Linux container host (Docker Desktop / colima / Linux) — macOS has no core
   pinning, which is the whole reason this runs in a VM.

3. **Interleave + median, never two separate full runs.** Measure every
   framework once per rep, loop N reps (`--reps`, default 5), and report the
   **median** per (framework, route). Comparing two *separate* full runs is
   banned: the drift between them dwarfs the real delta. (This fabricated a
   phantom "6–15% @Native regression" once — it vanished under interleaving.)
   For a tight A/B, run the two targets back-to-back within each rep.

4. **Warm up, then measure.** Every measured run is preceded by a warmup pass
   (JIT/branch-predictor/allocator warmth, TLS session cache, connection pool).

5. **One server at a time.** Only the framework under test runs — no noisy
   neighbours sharing the box.

6. **AOT, keep-alive is the headline.** Quote AOT (`dart compile exe`) numbers,
   not JIT. Keep-alive (connection reuse) is the headline load mode; the
   `Connection: close` number measures the port budget, not the server.

7. **Record provenance.** The container pins the base image, CPU set, memory
   (`--memory == --memory-swap`, no swap) and records each framework's version.
   Every run writes a **machine header** (OS/arch, VM cores, server vs client
   cpuset, memory cap, oha version, generator-pinning note) into the report.

8. **Equal CPU budget.** Every framework gets the SAME number of cores for
   handler work (`SRV_N` = the server half of the cpuset): nitro `--isolates N`,
   Go `GOMAXPROCS=N`, Node `NODE_PROCS=N`, dart:io `shared` isolates = N. The one
   exception is shelf (single-isolate by design) — stated in the config table.
   Without this, `/work` (CPU-bound) is a core-count artifact, not a comparison.

9. **Validate responses, don't just count them.** The harness curls every route
   once and records status + content-type + body-byte length, then asserts the
   body length AGREES across frameworks (equal bytes = fair work). A framework
   returning 200 with a truncated body is flagged, not scored.

10. **Publish the whole distribution + memory, not one number.** The report is
    `req/s`, `p50/p90/p95/p99`, the `p50:p99` tail-flatness ratio, and peak
    resident memory (RSS of the server process tree) — medianed over reps. Raw
    per-rep samples are committed (`out/raw/samples.csv`) so tail claims are
    auditable, not asserted.

11. **`/static` is not equal work — report it separately.** nitro answers
    `/static` from the engine (`getStatic`, no handler/FFI); the others run a
    handler. The report puts it in its own "engine fast-path" section, never in
    the equal-work table.

## The harnesses

| harness | use it for | how |
|---|---|---|
| **`benchmark/blackbox/`** | cross-framework + `@Native` vs `_dylib`, request/response routes | `benchmark/blackbox/run.sh` |
| `benchmark/compare.dart` | same routes incl. **SSE + WebSocket + getStatic** (oha can't drive open streams) | `./build/benchmark/compare --keep-alive` (AOT) — see [run_all.sh](run_all.sh) |
| `benchmark/docker/` | isolating the engine's **adaptive dispatch controller** (adaptive vs pinned) | `benchmark/docker/bench.sh` |

### Blackbox (cross-framework) — the default

```bash
benchmark/blackbox/run.sh                         # 4 cores (srv 0-1 / cli 2-3), 4 GiB, 5 reps
benchmark/blackbox/run.sh --cpus 0-7 --mem 8g --reps 7 --duration 15s
benchmark/blackbox/run.sh --frameworks "nitro-native nitro-dylib go"
```

Output → `benchmark/blackbox/out/report.md` (machine header, per-framework config,
the equal-work table with `req/s` + `p50/p90/p95/p99` + `p50:p99` ratio + peak
memory, the `/static` engine fast-path section, and the response-validation
table), plus `out/raw/{samples.csv,validation.csv}` (every rep + the body-length
checks). Covers the request/response routes (`/hello /json /q /users /files /mw
/work` + `POST /echo`, and `/static` separately). **SSE (`/events`) and WebSocket
are excluded** — `oha` measures request/response, not open streams; use
`compare.dart` for those.

Prereqs: a running container host (`colima start` on macOS) and, until nitro is
published, the local `nitro_ecosystem` checkout at `../../flutter_package/…`
(run.sh vendors it into the image; see the Dockerfile).

## CPU-bound (`/work`) auto-tune

A CPU-bound handler runs on Dart **isolates**; one isolate caps `/work` at a
single core. nitro's engine already **fans a CPU-bound handler across the
isolates it is given** (see `dispatch_controller_test.cpp`) — so the fix is to
give it the cores: `ServerConfig(isolates: 0)` auto-scales to the machine when a
`setup` is passed, and the blackbox launches nitro with `--isolates N` (= the
equal budget above). nitro then *scales* with cores (competitive with Node,
approaching Go); it won't beat Go's per-core efficiency on `/work` — that residual
is the Dart-encode + FFI-per-token cost, a separate code lever
([[cpu-bound-perf-levers]]), not isolate count.

**The `setup` must be a top-level or static function** (so a multi-isolate server
can send it to every isolate — a closure crosses only if it captures nothing
mutable). The blackbox's nitro setup (`_nitroSetup` in `compare.dart`) is
top-level for exactly this reason.

## `@Native` vs `_dylib` — the settled result

Measured perf-**neutral** for this workload (all deltas within the ±10–15% noise
floor; see [[native-assets-at-native-migration]] in memory). The ~1.7× FFI
call-floor win is real at microbench level but a sub-µs sliver of the 80–190 µs
per request (socket I/O + parse + engine dominate). `@Native`'s value is
packaging (self-contained code asset, no cmake for consumers), not speed. Re-run
`benchmark/blackbox/run.sh --frameworks "nitro-native nitro-dylib"` before
re-litigating.
