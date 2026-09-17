# Research: the Dart FFI/isolate wall on the handler path, and how to beat it

Question: the engine-served paths (`getStatic`) sit at ~135–142k,
level with go's net/http, but the **Dart handler** is stuck at ~82k. What in the
Dart VM caps it, and can it be raised? Findings from the dart-lang / flutter
issue trackers, mapped onto nitro's architecture.

## The wall, and it is measured — by the SDK itself

nitro's handler pays a per-request **native → Dart → native round-trip** that
go/node do not: the connection thread posts the request head to the Dart isolate
(a port message, `Dart_PostCObject`), the handler runs, and `respond` crosses
back via FFI. Measured end to end at ~4.5 µs; the FFI-out (`respond`) is only
0.16 µs, so the crossing *into* the isolate is the bulk.

The decisive data point is **flutter/flutter#192343**: isolate round-trip latency
on the **standalone Dart VM is ~5 µs and flat at every isolate count**
(`0.005 ms`), while the *Flutter engine* degrades ~100× once 8 isolates run
concurrently (0.025 ms → 2.446 ms), because of `Scavenger::MaxMutatorThreadCount`
landing on 8 with the engine's 16 MB new-gen vs the standalone VM's 32 MB.

Two things follow, both important:

1. **nitro runs on the standalone AOT VM** (`dart compile exe`), so it is on the
   *flat* side — the Flutter 100×-at-8-isolates cliff does **not** apply. Good.
2. nitro's measured ~4.5 µs handler round-trip **is** the standalone VM's
   isolate-message floor (~5 µs). The handler is not slow because nitro is
   inefficient — it is at the VM's inherent cost of delivering a message into an
   isolate. go/node have **no isolate boundary at all**, so they never pay it.

So "make the handler as fast as go/node" = "stop paying the isolate round-trip
per request." Everything below is about that.

## What does NOT help (checked, ruled out)

- **`NativeCallable.listener`** (call Dart from any native thread): its arguments
  are sent **over a SendPort** to the target isolate — the same mechanism and the
  same ~5 µs cost as the head port today. void-only, async. No win.
- **`NativeCallable.isolateLocal`**: must be invoked from the isolate's *own*
  mutator thread; it aborts the process if called from another thread. nitro's
  connection/loop threads are *not* the isolate thread, so it cannot deliver a
  head. No win.
- **A faster JSON codec** (encode or a native/simdjson decoder): serialization is
  ~1–2 µs for a normal body, dwarfed by the 4.5 µs crossing; and a native decoder
  loses to the VM's in-heap `jsonDecode` because materializing Dart objects
  across FFI is the same wall. See `benchmark-results.md`; not the lever.

## Levers that CAN raise it, ranked

### 1. Shared-memory head delivery + Dart-side polling — PROTOTYPED, REFUTED
Replace the per-request `Dart_PostCObject` with a **shared native queue** the
engine writes heads into and the Dart isolate **polls** by leaf FFI (FFI-allocated
native memory is genuinely shared — a `malloc`'d pointer is just an address).

**Built behind `NITRO_POLL_HEADS=1` (single-isolate) and measured — it lost.**
Single-isolate `/json`, `wrk -t2 -c64`, avg 3×6 s:

| head delivery | req/s | p50 | p99 |
|---|--:|--:|--:|
| port (`Dart_PostCObject`) | **124511** | 454 µs | 679 µs |
| shared-memory poll | 112084 | 530 µs | 782 µs |

**~10% slower, worse latency.** Why the research's premise didn't hold: the port
path is **already batched** — `Backpressure.batch` coalesces every head that
arrives while the isolate is busy into *one* message per pass, so the ~5 µs
isolate latency is amortized over the batch; there is no per-request 5 µs to
reclaim. Active polling instead *adds* cost (a leaf FFI poll + a microtask/timer
reschedule + mutex + idle backoff) and breaks the event loop's natural
interleaving of head-in and respond-out. A blocking poll can't help either: the
single isolate must also drain respond results, so it cannot park in native code.
**Conclusion: the batched port is not the bottleneck; do not pursue this.** The
prototype was built (`NITRO_POLL_HEADS=1`), measured, and then **reverted** — the
numbers above are the record.

### 2. `@Native external` for the FFI-out (respond) path — minor, modern
Dart's `@Native external` compiles the trampoline into the call body and drops the
`asFunction` closure wrapper (dart-lang/sdk#43889, the `@Native` call
optimization; #52692 on FFI call cost). nitro's `FastCalls` already uses
`asFunction(isLeaf: true)` at 0.16 µs; moving to `@Native external` + leaf shaves
a little more off an already-cheap path. Small (respond is not the bottleneck),
but it is the current best-practice FFI binding and worth adopting when the
nitrogen-generated bindings support it.

### 3. Isolate groups / shared-memory multithreading — the future fix, not yet
Dart is actively building **shared-memory multithreading** (dart-lang/language
`working/333`); some experimental isolate/shared-heap APIs already leaked to
stable and are being reworked (dart-lang/sdk#64285). Isolates spawned into the
same **isolate group** share a heap and exchange structured objects far more
cheaply (#46754). If a future stable API lets native code hand a request to a
Dart isolate over shared memory without a port copy, that is the clean fix to the
wall this whole document is about. **Watch it; don't build on it yet** (unstable).

### Already shipped in nitro (the table stakes are done)
- Heads batch to one port post per pass under load (`Backpressure.batch`).
- Request bodies are **zero-copy**: native-owned payloads released via `ackBody`,
  no isolate copy (avoids the 3-copy problem of dart-lang/language#1862).
- `respond` is a **leaf FFI** call over reused buffers (`FastCalls`), 0.16 µs.
- The reactor uses poll-park worker threads + wake pipes on the C++ side.
- Router `match` returns a `RouteEntry*` (no per-request copy) and reuses a
  thread-local split buffer.

## Bottom line

The handler's throughput is bound by the native→Dart→native round-trip, and the
standalone VM's isolate message costs ~5 µs (SDK-measured, flat). But the obvious
fix — **shared-memory polling instead of the port (lever 1) — was prototyped and
measured ~10% slower** (see above): the port is *already* batched, so its
per-request cost is amortized and there is nothing to reclaim by polling. So
there is **no measured Dart-side lever** that raises the handler; it is at its
floor, and go/node's edge is simply having no isolate boundary. Until Dart's
shared-memory multithreading lands (lever 3) with a zero-copy way to hand work to
an isolate *without* the port copy, the honest fast lane for per-request-varying
responses that don't need arbitrary Dart logic is the engine-served path
(`getStatic`, already at go's level), which sidesteps the isolate
entirely. The handler stays the tool for real logic, at its ~82k floor with the
field's best tail latency.

## Raw engine throughput — the `getStatic` path (C++ reactor, no isolate)

The handler is capped by the isolate wall, but the **engine-served path**
(`getStatic`, ~142k) competes head-to-head with go's net/http (143k) / node
(150k) with no Dart in the loop — so *that* is where raw throughput is winnable.
Reading nitro's write path (`UvReactor::writeAnswer`), the per-response cost is
**three heap allocations on the loop thread**: `new std::string(payload)`,
`new uv_write_t`, `new WriteCtx`, then an async `uv_write` + its `onWrite`
callback. go/node avoid per-request allocation (sync.Pool / V8). Ranked levers:

1. **`uv_try_write` fast path — the top lever.** For a small response to a fast
   client the socket send buffer has room, so `uv_try_write` writes it
   **synchronously in one syscall with zero allocations** — no `uv_write_t`, no
   `WriteCtx`, no heap `std::string`, no `onWrite` hop. Only fall back to async
   `uv_write` when `uv_try_write` is partial/`EAGAIN`. This is the standard
   high-perf libuv pattern and directly targets the getStatic/`json` case.
   Moderate complexity (the post-write resume/close must run inline instead of
   in `onWrite`). **The experiment to run** — A/B it like the router change.
2. **Pool `uv_write_t` + `WriteCtx`** (freelist) for the async fallback, and
   reuse a per-connection payload buffer (one in-flight write per connection
   under the parked-thread model). Cuts the remaining allocations.
3. **io_uring — not the lever for network I/O.** libuv's io_uring is mainly for
   *file* ops; there is a "mismatch between io_uring's request-based model and
   libuv's callback-based I/O model that stops libuv from achieving maximal
   performance for network I/O" (libuv#4044). v1.50.0 (Jan 2025) added io_uring
   *epoll batching* (`UV_LOOP_USE_IO_URING_SQPOLL`) — a modest, Linux-only win on
   the `epoll_wait` syscall, worth enabling but not transformational.
4. **Socket tuning** — `TCP_NODELAY` (confirm on), `SO_SNDBUF` sizing; minor.

Expected: lever 1 is the one that could take getStatic past net/http toward
node. It does **not** touch the handler (that is the isolate wall) — but with
templates gone, getStatic is the engine-served fast lane, so this is where the
throughput headroom actually is.

## Sources
- [flutter/flutter#192343 — isolate round-trip 100× at 8 isolates (engine only; standalone VM flat ~5 µs)](https://github.com/flutter/flutter/issues/192343)
- [dart-lang/sdk#53156 — `Dart_PostCObject_DL` has noticeable latency](https://github.com/dart-lang/sdk/issues/53156)
- [dart-lang/sdk#49524 — make `Dart_Post` schedule on the port's isolate](https://github.com/dart-lang/sdk/issues/49524)
- [dart-lang/sdk#52692 — FFI function-call overhead](https://github.com/dart-lang/sdk/issues/52692)
- [dart-lang/sdk#43889 — change native calls to use FFI calls (the `@Native` optimization)](https://github.com/dart-lang/sdk/issues/43889)
- [dart:ffi `NativeCallable.listener` (cross-thread, over a SendPort)](https://api.flutter.dev/flutter/dart-ffi/NativeCallable/NativeCallable.listener.html)
- [dart:ffi `NativeCallable.isolateLocal` (same-thread only)](https://api.flutter.dev/flutter/dart-ffi/NativeCallable/NativeCallable.isolateLocal.html)
- [dart-lang/language `working/333` — shared-memory multithreading proposal](https://github.com/dart-lang/language/blob/master/working/333%20-%20shared%20memory%20multithreading/proposal.md)
- [dart-lang/sdk#64285 — unship experimental isolate APIs](https://github.com/dart-lang/sdk/issues/64285)
- [dart-lang/sdk#46754 — enable isolate groups by default](https://github.com/dart-lang/sdk/issues/46754)
- [dart-lang/language#1862 — passing large objects across isolates/FFI without copies](https://github.com/dart-lang/language/issues/1862)
- [libuv#4044 — use io_uring for network I/O (model mismatch, not maximal for sockets)](https://github.com/libuv/libuv/issues/4044)
- [libuv v1.50.0 release — "always use io_uring for epoll batching"](https://github.com/libuv/libuv/releases)
- [libuv mailing list — uv_write performance / write_queue_size / SO_SNDBUF](https://www.mail-archive.com/libuv@googlegroups.com/msg00721.html)
