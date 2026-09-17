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

## Phase 0 — Measure (done; findings below)

Two things are already settled, which reshapes the plan:

- **The synchronous handler fast-path already exists.** `RequestHandler`,
  `Middleware`, `NotFoundHandler`, `ErrorHandler` and `ServerSetup` are all
  `FutureOr`; `ServerRunner._dispatch` answers a synchronous handler **inline**
  (`if (result is ResponseContext) _deliver(...)`, no Future/microtask), and a
  no-middleware route allocates zero closures (`_identity`). The 79k already
  benefits — there is **no further `FutureOr` win in the request path.**
- **Serialization is free.** `/json` (75.2k, `jsonEncode` per request) measured
  identical to `/raw` (75.3k, precomputed bytes) at `-t4 -c64`. So `jsonEncode`
  of a tiny object costs nothing; the whole ~4.5 µs gap to `getStatic` is the
  **native↔Dart dispatch round-trip**, not response building.

So the budget is: head-record wire decode → `RequestContext` build → the head
stream delivery (FFI) + the `respond` FFI (2 crossings) → native head build +
write. That is what the remaining phases must cut. Still TODO in Phase 0: an
env-gated engine timer to split head-decode vs the two crossings.

## Phase 1 — Trim the per-request Dart work (target: 79k → ~90k)

1. ~~Synchronous handler fast-path~~ — **already done** (see Phase 0).
2. **Lazy head decode.** The head arrives as `RawIncomingRequest` with `path`,
   `query`, `packedHeaders` strings; `/json` ignores all three yet pays their
   utf8+alloc. `packedHeaders` is already lazy — extend to `path`/`query` so a
   route that doesn't read them skips the decode. (Touches the generated record
   or a hand-rolled head reader.)
3. **Reuse hot objects.** Pool/reuse `RequestContext` and the `RawHeader` list
   on the dispatch path; share one empty list for the common no-custom-header
   answer. **Partly done:** `httpMethodOf` now returns `const`-canonicalized
   records (no per-request method-record alloc on dispatch), the empty
   `RawHeader` list and empty param map/body are shared. Verified flat on
   throughput (~80.6k `/json`, `-t4 -c64`) — as expected: this is GC/tail
   relief, not a crossing cut. `RequestContext` pooling is still open (risky:
   async handlers outlive the dispatch frame).
4. **Leaner respond.** A `respond` variant that skips `List<RawHeader>`
   marshaling entirely when the handler set no custom headers (the `/json`,
   `/plaintext` case).

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
