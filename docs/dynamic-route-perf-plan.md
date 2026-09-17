# Plan: improve dynamic-route throughput

## The gap, measured

`getStatic` (engine-served, no Dart) hits **122k req/s @ 8.1 µs/req**; the same
response through a **Dart handler** is **79k req/s @ 12.6 µs/req** (TFB `/json`,
8-core M1 Pro, wrk -c256, keep-alive). So the **~4.5 µs delta per request is the
native↔Dart round-trip** — that is the entire budget this plan targets. Go/Node
sit at ~136–140k because they never cross a language boundary; the *floor* for a
Dart-handler-over-native-engine server is one head-out + one respond-in crossing
plus Dart scheduling. Note nitro already wins tail latency (p99 ~5 ms vs
11–56 ms), so the goal is throughput without giving that up.

## Per-request lifecycle (where the 4.5 µs lives)

1. native: `uv_read` → `HttpParse` head → build `RawIncomingRequest` (strings:
   path, query, packedHeaders) → emit on `incomingRequests` (Backpressure.batch)
2. bridge: head record decoded on the Dart isolate
3. runner: dispatch to the handler (currently through an async `Future`)
4. handler: user code → `ResponseContext` → `respond()`
5. bridge: `respond()` FFI → native head build + queue + `uv_async_send`
6. native: `onAsync` (loop thread) → coalesce → `uv_write`

Steps 2–5 are the delta. Suspects, biggest-first (to be confirmed in Phase 0):
head-record decode + allocation, per-request async scheduling, `ResponseContext`
+ serialization, respond marshaling (headers list).

## Phase 0 — Measure before touching anything (mandatory)

- Env-gated engine timing (`NITRO_PERF`) stamping monotonic ns at parse-done,
  emit, respond-entry, write-submit; diff to attribute native vs bridge time.
- Dart microbench: dispatch-only (empty handler) vs full `/json` — isolates the
  scheduling + serialization cost from the FFI cost.
- Anchor: the `getStatic` 8.1 µs is the crossing-free ceiling; every phase is
  scored against closing the 4.5 µs to it.

## Phase 1 — Low-risk Dart-side wins (target: 79k → ~100k)

1. **Synchronous handler fast-path.** A handler returning a `ResponseContext`
   (not a `Future`) is invoked and answered inline — no per-request `Future`/
   microtask. Most handlers are sync; this removes one event-loop turn each.
2. **Lazy head decode.** `packedHeaders` is already lazy; make `path`/`query`
   decode-on-first-access too, so routes that ignore them pay no utf8+alloc.
3. **Reuse hot objects.** Pool/reuse `ResponseContext` and the `RawHeader` list
   on the dispatch path; skip the headers-list allocation for the common
   no-custom-header answer.
4. **Leaner respond.** For a handler that sets no custom headers, a respond
   variant that skips the `List<RawHeader>` marshaling entirely.

## Phase 2 — Structural (target: further under load)

5. **Response batching.** Mirror the head-side Backpressure.batch: queue
   `respond()` calls on the Dart isolate and flush once per event-loop turn as
   one FFI crossing carrying N answers. The engine already coalesces consecutive
   same-conn writes in `onAsync`; this cuts the *crossing* count under load.
6. **Engine-side response templates.** Generalize `writeTemplatedArray`: a
   handler describes a fixed template + the few dynamic values, the engine
   assembles the bytes natively — no full Dart serialization, one lean crossing.

## Phase 3 — Architectural bets (only if Phase 1–2 fall short)

7. **Native micro-handlers** for the hottest fixed shapes (echo, redirect,
   header-templated) — a middle ground between `getStatic` (fully constant) and
   a full Dart handler, run entirely in the reactor.
8. **Refreshable getStatic cache** as a documented pattern: re-register a
   `getStatic` route every N seconds for slowly-changing "dynamic" data —
   engine-served throughput for data that isn't per-request.

## Scoring

| lever | expected | risk | effort |
|-------|----------|------|--------|
| P1.1 sync fast-path | high | low | low |
| P1.2 lazy head decode | med | low | low |
| P1.3 object reuse | med | low | med |
| P1.4 leaner respond | med | low | low |
| P2.5 response batching | high (under load) | med | med |
| P2.6 engine templates | high (fixed shapes) | med | high |

Do P1 first (cheap, likely ~100k), re-measure against the 8.1 µs ceiling, then
decide whether P2 is worth it. Never trade away the p99 tail-latency win.
