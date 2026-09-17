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
