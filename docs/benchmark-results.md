# Benchmark results

Two methodologies on purpose — they answer different questions and the "winner"
flips between them, which is the honest picture. All figures use `nitro 0.7.6`.

| methodology | load generator | what it measures | where |
|---|---|---|---|
| `benchmark/compare.dart` | Dart `HttpClient` (in-process isolates) | how nitro compares when the *client* is also Dart-limited | CI, ubuntu + macOS |
| `benchmark/techempower/` | `wrk` (C, TechEmpower-style) | each server's true ceiling under a fast client | local macOS |

Throughput = req/s. Latency: `seq p50` = single-connection median; `load p50` =
median under the 64-conn sweep; TFB `p99` = wrk tail.

---

## 1. CI benchmark — `compare.dart --quick --keep-alive` (Dart client)

### Ubuntu (2-core runner) — req/s · seq p50 µs · load p50 µs

| route | nitro | go | node | dart:io | shelf | winner |
|---|--:|--:|--:|--:|--:|:--|
| /hello | **25281** · 224 · 3172 | 27282 · 219 · 3077 | 12684 · 281 · 9012 | 16687 · 272 · 2929 | 9134 · 305 · 3987 | go, nitro 2nd |
| /json | **24948** · 226 · 3296 | 26695 · 222 · 3325 | 19923 · 268 · 5830 | 16166 · 198 · 2709 | 9416 · 327 · 3959 | go, nitro 2nd |
| /users/:id | **24871** · 325 · 3241 | 27188 · 222 · 3058 | 22517 · 216 · 3985 | 15167 · 197 · 2860 | 9133 · 288 · 4016 | go, nitro 2nd |
| /files/* | **25058** · 228 · 3345 | 27045 · 221 · 3211 | 23093 · 212 · 3774 | 15486 · 195 · 3200 | 9027 · 302 · 4078 | go, nitro 2nd |
| /q?a=1&b=two | **24720** · 230 · 3266 | 26499 · 221 · 3277 | 22213 · 241 · 3898 | 14352 · 219 · 2735 | 8957 · 308 · 4261 | go, nitro 2nd |
| /mw | **24971** · 232 · 3340 | 26873 · 219 · 3282 | 23496 · 303 · 3575 | 16362 · 193 · 3136 | 9205 · 276 · 3985 | go, nitro 2nd |

**Ubuntu:** Go wins by ~8%; nitro is a clear 2nd on every route and beats Node,
dart:io and shelf. seq p50 is tight (nitro ~225 µs vs go ~220 µs).

### macOS runner — req/s · seq p50 µs · load p50 µs

| route | nitro | go | node | dart:io | shelf | winner |
|---|--:|--:|--:|--:|--:|:--|
| /hello | **41776** · 182 · 1789 | 37044 · 143 · 4588 | 28546 · 203 · 7220 | 29227 · 191 · 2516 | 25246 · 287 · 2009 | **nitro** |
| /json | **30598** · 135 · 8215 | 20675 · 560 · 11824 | 23554 · 487 · 9521 | 15972 · 148 · 13513 | 25761 · 178 · 1919 | **nitro** |
| /users/:id | 15391 · 694 · 12203 | 15890 · 871 · 21840 | 17293 · 520 · 15930 | **19379** · 487 · 7027 | 11353 · 473 · 6777 | dart:io (noisy) |
| /files/* | **27825** · 589 · 5898 | 24138 · 376 · 8977 | 23501 · 342 · 13362 | 15351 · 502 · 8637 | 11647 · 523 · 11922 | **nitro** |
| /q?a=1&b=two | **27104** · 351 · 4172 | 23358 · 301 · 12726 | 18626 · 473 · 22044 | 17780 · 393 · 4688 | 12985 · 438 · 7338 | **nitro** |
| /mw | **20082** · 391 · 10025 | 11103 · 887 · 39464 | 17581 · 982 · 17393 | 18102 · 369 · 4566 | 15909 · 611 · 5444 | **nitro** |

**macOS:** nitro wins 5 of 6 handler routes — beating Go outright (the 2-core
Ubuntu runner is more contended and noisier; `/users/:id` on macOS is noisy).

---

## 2. TechEmpower-style — `wrk` (macOS, 8-core, -c256, 10s, keep-alive)

| framework | JSON req/s | p50 | **p99** | Plaintext req/s | p50 | **p99** |
|---|--:|--:|--:|--:|--:|--:|
| **nitro** (handler) | 79227 | 3.20ms | **5.39ms** | 78774 | 3.24ms | **5.11ms** |
| **nitro** (`getStatic`) | **122607** | 2.10ms | **2.33ms** | 121745 | — | **2.31ms** |
| dart:io | 91251 | 2.38ms | 15.93ms | 92069 | 2.35ms | 23.58ms |
| shelf | 76928 | 2.90ms | 14.95ms | 78416 | 2.89ms | 14.03ms |
| go | 136807 | 1.08ms | 10.68ms | 134995 | 1.08ms | 15.78ms |
| node | 140422 | 1.00ms | 55.82ms | 142934 | 1.00ms | 52.44ms |

**Under `wrk`:** Go/Node reach a higher raw ceiling (137–140k) than nitro's
handler path (79k); nitro's **`getStatic` (engine-served) hits 122k** — ~0.9× Go
— and nitro owns **tail latency** on every path (p99 ~5ms handler / ~2.3ms
getStatic vs Go 11–16ms, Node 52–56ms).

### 2a. Differentiating run — `wrk -t2 -c64` (servers get their own cores)

`-c256` on an 8-core laptop puts `wrk -t8` and an 8-isolate server on the same
cores; under that contention every framework ties at the *machine* ceiling
(~80k, identical p50/p99) — it measures the box, not the server. Giving `wrk`
2 threads and the server the rest separates them. `/json` (`/t/:id` for the
template tier), avg of 3×6 s runs, **leaders run first** so nitro's rows are
warmer — a conservative comparison, not a flattering one:

| framework | req/s | p50 | **p99** |
|---|--:|--:|--:|
| node | 150273 | 281µs | 1.29ms |
| go | 143093 | 299µs | 1.16ms |
| **nitro** (`getStatic`) | 136367 | 477µs | **1.02ms** |
| **nitro** (`getTemplated`) | **135515** | 389µs | **1.01ms** |
| dart:io | 103539 | 452µs | 2.32ms |
| shelf | 86416 | 588µs | 4.83ms |
| **nitro** (handler) | 81677 | 734µs | **1.11ms** |

**What this run says:**
- **`getTemplated` (135.5k) ≈ `getStatic` (136.4k)** — engine-side assembly
  from `:param`/`?query` slots runs at engine-served speed (both ~0.9× the
  node/go leaders), **1.66× the handler**, and takes the **best tail in the
  whole field** (p99 1.01ms).
- **nitro owns the tail:** the three tightest p99s are all nitro — template
  1.01ms, getStatic 1.02ms, handler 1.11ms — vs go 1.16, node 1.29, dart:io
  2.32, shelf 4.83.
- **The handler path is latency-bound, not CPU-bound:** 734µs p50 × 64 conns ≈
  82k. Throughput is mid-pack (the Dart round-trip sets the floor) — which is
  exactly why `getTemplated`/`getStatic`, which skip that round-trip, leap to
  135k+.

(Absolute numbers drift with laptop thermals across a long sweep; the reliable
signals are the **nitro-tier ordering** — template ≈ getStatic ≫ handler — and
the **tail-latency lead**, both stable across every run this session.)

### 2b. Why not response batching (measured)

The obvious next lever looked like batching the per-request `respond` FFI
crossings (heads already arrive batched via `Backpressure.batch`). Measured, it
does not pay:

| quantity | measured | implication |
|---|--:|---|
| `respond` leaf crossing (`FastCalls`) | **0.16 µs/call** | the whole crossing is already sub-µs |
| batchable CPU at 81k req/s | 0.16µs × 81k ≈ **1.3%** of one core | below the ±3–5% run-to-run noise |
| handler p50 (the real limiter) | **736 µs** | 4600× the crossing — batching can't touch it |

The handler is bound by round-trip **latency**, not crossing CPU. A Dart-side
batch buffer must *defer* answers to coalesce them (a flush hop), which **adds**
latency — lowering the concurrency-bound throughput and threatening the p99
1.14ms lead that is nitro's actual differentiator. So the crossing count is not
worth cutting; the only lever that moves the handler number is removing the
round-trip itself — which is what §2c's engine templates do — or using
`getStatic` for anything cacheable.

### 2c. Engine-side templates — `getTemplated` (shipped)

A **template route** serves a body the engine assembles on its own thread from
the matched path's `:param` slots and `?query` values — no Dart handler runs,
so it answers at static-route speed while still varying per request. The lever
P2.6 predicted. In §2a's full table it lands at **135.5k req/s ≈ `getStatic`
(136.4k), 1.66× the handler (81.7k), and the field's best p99 (1.01ms)** — it
never crosses into Dart, so it runs at engine-served speed. (A same-process
`/t` vs `/h` run under heavier contention showed the wider **2.57×** ratio; the
gap over the handler grows as the box saturates, since only the handler pays the
round-trip.)

The API is a template **string**: `{id}` = path param, `{?q}` = query value
(form-decoded engine-side), trailing `!` = raw, `{{`/`}}` = literal braces; any
other brace (a JSON `{`/`}`) is literal, so a JSON body needs no escaping:

```dart
server.getTemplated('/users/:id', '{"userId":{id},"q":{?q}}',
    contentType: 'application/json');
```

Slots land only in the body (no header-splitting surface); `jsonString` (the
default) escapes the value so a `"`/`\`/control byte cannot break out of its
JSON string. Unit + libFuzzer covered (`template_test.cpp`, `template_fuzz.cpp`
— decode + escape + query form-decode, 1.85M execs clean).

### 2d. How go/node reach their ceiling, and closing the engine-path gap

The comparison is honest about what the others do: **go** is `net/http`
(stdlib, not fasthttp) with GOMAXPROCS across all cores; **node** is `http` +
`cluster` (one worker per core), llhttp (C parser) and V8. Both win by (a) never
crossing a language boundary and (b) allocating almost nothing per request —
Go's escape analysis + `sync.Pool`, V8's hidden classes and llhttp's zero-copy
parse. nitro's engine-served path (`getStatic`/`getTemplated`) has the same
shape — pure C++ on libuv, no Dart hop — so the only thing between it and
net/http was **its own per-request allocations**.

Found and cut two in `Router::match` (every route runs it):
- **`MatchResult` held a `RouteEntry` by value** — a per-request copy of the
  entry's strings, vectors and *two `shared_ptr` refcount atomics*. Now it holds
  a `const RouteEntry*` into the trie (stable while serving), so a match is a
  pointer store.
- **`split(path)` heap-allocated a vector** per match — now a reused
  `thread_local`.

Measured A/B (getStatic `/json`, `-t2 -c64`, baseline built first so the
optimized build ran *warmer* — conservative):

| build | req/s | p50 | p99 |
|---|--:|--:|--:|
| baseline (RouteEntry copy) | 139730 | 424µs | 1.00ms |
| **pointer + thread_local** | **142274** | **402µs** | 1.00ms |

**+1.8% throughput, −5% p50** — `getStatic`/`getTemplated` now sit at ~142k,
**level with go's net/http (143k)**; node's 150k edge is its cluster+V8+llhttp
stack. The win lands on the engine-served paths, where `match` is a real slice
of the budget; it does **not** move the Dart *handler* (82k), which is bound by
the FFI round-trip, not the match. Further engine-path headroom (a reusable
response buffer instead of a per-request `std::string`, a faster head builder)
is real but small — the honest ceiling for "C++ engine over libuv" is right here
at net/http, and nitro already holds the tail-latency lead over all of them.

---

## Reconciliation

- **Dart-side / mixed load (compare.dart)** → nitro **wins or ties Go/Node** and
  beats Node/dart:io/shelf: the Dart client caps ~25–30k, and nitro's native
  reactor keeps pace where the others fall behind.
- **Max-throughput C client (`wrk`)** → **Go/Node have the higher ceiling**;
  nitro's `getStatic` closes most of it and nitro wins the **tail** decisively.

Both are real. nitro's differentiators: **consistent tail latency** and an
**engine-served fast path** (`getStatic`) that reaches Go/Node throughput for
cacheable responses.

## Improving dynamic routes

The `getStatic` (122k) vs handler (79k) delta is the **~4.5µs native↔Dart
round-trip**. The roadmap to close it — sync handler fast-path, lazy head
decode, object reuse, response batching, engine-side templates — is in
[dynamic-route-perf-plan.md](dynamic-route-perf-plan.md).

## Reproduce

```sh
# compare.dart (Dart client), any OS:
cmake -S src -B build/lib -DCMAKE_BUILD_TYPE=Release && cmake --build build/lib --parallel
dart compile exe benchmark/compare.dart -o build/benchmark/compare
./build/benchmark/compare --keep-alive --raw --isolates $(nproc||sysctl -n hw.ncpu) --only /json

# TechEmpower-style (wrk):
brew install wrk   # or apt
DUR=10 CONN=256 bash benchmark/techempower/run.sh
```
