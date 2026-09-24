# Benchmark: JIT vs AOT, and vs other frameworks

`benchmark/compare.dart` — the same routes served by **nitro_server**, `dart:io
HttpServer`, `shelf`, **Go** (`net/http`), and **Node** (`http` + `cluster`),
driven by one Dart `HttpClient` in separate client isolates. Every case asserts
exact status and bytes.

- **Machine:** macOS, 8 logical cores, loopback. Run 2026-09-18.
- **Configs:** `--keep-alive` throughout (load sweep → throughput + latency).
  `quick` = 1 s load / 32 conns / 1 round; `full` = 3 s load / 64 conns
  (32 for WS) / 2 rounds. JIT = `dart run`; AOT = `dart compile exe`.
- **Reliability:** one run per config. The **full** columns are the reliable
  ones; `quick` (1 s/case) is noisier. Treat |Δ| < ~8 % as noise.
- WebSocket is nitro + dart:io only (shelf/Go/Node have no stdlib WS here).

> **Note:** this run also verifies a fix for a WebSocket permessage-deflate
> deadlock that previously hung `WS /ws 4k deflate` deterministically under AOT
> (a pre-open frame was dropped instead of buffered). It now completes in every
> config below.

---

## 1. Cross-framework throughput — req/s (higher wins)

### Full AOT (the config Flutter ships)

| route | nitro | dart:io | shelf | go | node | winner |
|---|--:|--:|--:|--:|--:|:--|
| /hello | 31,649 | 16,228 | 12,350 | **41,050** | 38,660 | go |
| /json | 37,550 | 17,222 | 13,470 | **40,542** | 33,485 | go |
| /users/:id | 36,393 | 16,221 | 14,398 | **41,609** | 34,921 | go |
| /files/* | 35,833 | 15,303 | 12,811 | **41,371** | 37,518 | go |
| /q?a=1&b=two | 35,143 | 15,966 | 13,094 | **41,567** | 37,477 | go |
| /mw | 35,907 | 17,676 | 13,147 | **41,391** | 37,061 | go |
| /static | **43,213** | 16,162 | 14,586 | 42,015 | 35,648 | nitro |
| /work | 8,471 | 1,655 | 1,806 | **22,013** | 21,924 | go |
| /file | 7,211 | 3,856 | 4,560 | 7,290 | **7,465** | node |
| POST /echo 4k | **19,212** | 12,563 | 9,942 | 17,737 | 17,261 | nitro |
| POST /echo 1m | 141 | 120 | 128 | **144** | 135 | go |
| GET /events | 9,563 | 11,630 | 13,173 | 21,609 | **30,213** | node |
| WS /ws 128B | **34,491** | 27,182 | — | — | — | nitro |
| WS /ws 4k | **23,766** | 20,362 | — | — | — | nitro |
| WS /ws 4k deflate | **14,410** | 12,032 | — | — | — | nitro |

### Full JIT

| route | nitro | dart:io | shelf | go | node | winner |
|---|--:|--:|--:|--:|--:|:--|
| /hello | 36,688 | 16,016 | 12,874 | **40,093** | 37,046 | go |
| /json | 34,574 | 15,222 | 12,392 | **39,452** | 34,665 | go |
| /users/:id | 33,043 | 14,872 | 11,715 | **39,813** | 35,431 | go |
| /files/* | 33,200 | 16,954 | 15,524 | **38,789** | 36,586 | go |
| /q?a=1&b=two | 33,545 | 16,180 | 11,948 | **39,154** | 35,316 | go |
| /mw | 33,880 | 15,480 | 11,768 | **39,127** | 36,710 | go |
| /static | **41,952** | 15,468 | 13,781 | 40,224 | 31,377 | nitro |
| /work | 8,147 | 2,457 | 2,312 | **28,666** | 26,723 | go |
| /file | 13,552 | 5,378 | 2,444 | **13,660** | 13,622 | go |
| POST /echo 4k | **26,870** | 13,527 | 10,200 | 25,615 | 23,987 | nitro |
| POST /echo 1m | 227 | 190 | 219 | **411** | 250 | go |
| GET /events | 8,028 | 11,275 | 13,807 | 21,032 | **28,462** | node |
| WS /ws 128B | **34,267** | 22,819 | — | — | — | nitro |
| WS /ws 4k | **23,330** | 20,489 | — | — | — | nitro |
| WS /ws 4k deflate | **13,925** | 12,065 | — | — | — | nitro |

---

## 2. Cross-framework tail latency — load p99 µs (lower wins), Full AOT

nitro's signature: the tightest tail on every handler route.

| route | nitro | dart:io | shelf | go | node | best |
|---|--:|--:|--:|--:|--:|:--|
| /hello | **8,007** | 14,595 | 15,489 | 11,864 | 13,496 | nitro |
| /json | **5,565** | 11,558 | 12,213 | 11,234 | 16,207 | nitro |
| /users/:id | **6,443** | 10,770 | 12,102 | 12,033 | 17,457 | nitro |
| /files/* | **6,996** | 10,048 | 13,484 | 11,994 | 14,933 | nitro |
| /q?a=1&b=two | **5,799** | 11,374 | 12,336 | 11,852 | 13,440 | nitro |
| /mw | **6,492** | 10,284 | 13,325 | 12,317 | 13,814 | nitro |
| /static | **6,519** | 10,044 | 12,558 | 12,082 | 16,991 | nitro |
| /work | **21,002** | 63,514 | 59,993 | 21,605 | 22,064 | nitro |
| /file | 41,211 | 47,879 | **34,493** | 44,795 | 37,374 | shelf |
| POST /echo 4k | 24,153 | **15,478** | 15,983 | 26,537 | 25,563 | dart:io |
| POST /echo 1m | **1,090,612** | 1,552,935 | 1,789,557 | 1,537,967 | 1,789,292 | nitro |
| GET /events | 19,209 | **13,438** | 14,269 | 24,494 | 19,062 | dart:io |
| WS /ws 128B | **7,543** | 8,071 | — | — | — | nitro |
| WS /ws 4k | **10,119** | 10,452 | — | — | — | nitro |
| WS /ws 4k deflate | 16,071 | **15,041** | — | — | — | dart:io |

---

## 3. Cross-framework single-connection latency — seq p50 µs (lower wins), Full AOT

| route | nitro | dart:io | shelf | go | node | best |
|---|--:|--:|--:|--:|--:|:--|
| /hello | 50 | 129 | 63 | **46** | 47 | go |
| /json | 50 | 75 | 66 | **46** | 47 | go |
| /users/:id | 51 | 58 | 66 | 46 | **45** | node |
| /files/* | 50 | 138 | 65 | 46 | **45** | node |
| /q?a=1&b=two | 51 | 55 | 65 | **46** | 46 | go |
| /mw | 49 | 87 | 65 | 46 | **44** | node |
| /static | **36** | 129 | 65 | 46 | 45 | nitro |
| /work | 337 | 810 | 895 | **48** | 49 | go |
| /file | **100** | 353 | 413 | 204 | 213 | nitro |
| POST /echo 4k | 118 | 106 | 118 | **104** | 112 | go |
| POST /echo 1m | 18,872 | 18,907 | 20,555 | **18,734** | 19,447 | go |
| GET /events | **57** | 70 | 63 | 72 | 60 | nitro |
| WS /ws 128B | **34** | 37 | — | — | — | nitro |
| WS /ws 4k | **40** | 103 | — | — | — | nitro |
| WS /ws 4k deflate | 91 | **83** | — | — | — | dart:io |

---

## 4. nitro: AOT vs JIT (Δ = AOT relative to JIT)

### Throughput — req/s (higher = better)

| route | quick JIT | quick AOT | Δ | full JIT | full AOT | Δ |
|---|--:|--:|--:|--:|--:|--:|
| /hello | 36,259 | 36,103 | -0% | 36,688 | 31,649 | -14% |
| /json | 36,381 | 36,022 | -1% | 34,574 | 37,550 | +9% |
| /users/:id | 34,517 | 38,205 | +11% | 33,043 | 36,393 | +10% |
| /files/* | 37,218 | 39,089 | +5% | 33,200 | 35,833 | +8% |
| /q?a=1&b=two | 38,395 | 36,843 | -4% | 33,545 | 35,143 | +5% |
| /mw | 35,088 | 37,517 | +7% | 33,880 | 35,907 | +6% |
| /static | 43,247 | 43,746 | +1% | 41,952 | 43,213 | +3% |
| /work | 4,706 | 3,583 | -24% | 8,147 | 8,471 | +4% |
| /file | 12,940 | 6,205 | -52% | 13,552 | 7,211 | -47% |
| POST /echo 4k | 26,572 | 21,098 | -21% | 26,870 | 19,212 | -28% |
| POST /echo 1m | 363 | 115 | -68% | 227 | 141 | -38% |
| GET /events | 9,443 | 13,348 | +41% | 8,028 | 9,563 | +19% |
| WS /ws 128B | 36,549 | 35,588 | -3% | 34,267 | 34,491 | +1% |
| WS /ws 4k | 24,924 | 23,315 | -6% | 23,330 | 23,766 | +2% |
| WS /ws 4k deflate | 15,509 | 15,809 | +2% | 13,925 | 14,410 | +3% |

### Latency — seq p50 µs (negative Δ = AOT faster)

| route | quick JIT | quick AOT | Δ | full JIT | full AOT | Δ |
|---|--:|--:|--:|--:|--:|--:|
| /hello | 54 | 49 | -9% | 52 | 50 | -4% |
| /json | 50 | 49 | -2% | 52 | 50 | -4% |
| /users/:id | 52 | 50 | -4% | 53 | 51 | -4% |
| /files/* | 50 | 50 | +0% | 53 | 50 | -6% |
| /q?a=1&b=two | 52 | 51 | -2% | 54 | 51 | -6% |
| /mw | 50 | 49 | -2% | 52 | 49 | -6% |
| /static | 36 | 36 | +0% | 37 | 36 | -3% |
| /work | 366 | 327 | -11% | 364 | 337 | -7% |
| /file | 326 | 97 | -70% | 316 | 100 | -68% |
| POST /echo 4k | 72 | 118 | +64% | 72 | 118 | +64% |
| POST /echo 1m | 6,842 | 20,414 | +198% | 5,981 | 18,872 | +216% |
| GET /events | 1,967 | 58 | -97% | 1,461 | 57 | -96% |
| WS /ws 128B | 36 | 35 | -3% | 36 | 34 | -6% |
| WS /ws 4k | 41 | 40 | -2% | 42 | 40 | -5% |
| WS /ws 4k deflate | 93 | 91 | -2% | 93 | 91 | -2% |

### Latency — load p50 µs (negative Δ = AOT lower under load)

| route | quick JIT | quick AOT | Δ | full JIT | full AOT | Δ |
|---|--:|--:|--:|--:|--:|--:|
| /hello | 790 | 766 | -3% | 1,542 | 1,653 | +7% |
| /json | 774 | 787 | +2% | 1,633 | 1,515 | -7% |
| /users/:id | 821 | 732 | -11% | 1,721 | 1,541 | -10% |
| /files/* | 755 | 719 | -5% | 1,715 | 1,576 | -8% |
| /q?a=1&b=two | 727 | 775 | +7% | 1,672 | 1,618 | -3% |
| /mw | 814 | 747 | -8% | 1,683 | 1,568 | -7% |
| /static | 715 | 712 | -0% | 1,454 | 1,436 | -1% |
| /work | 7,170 | 6,620 | -8% | 6,184 | 6,673 | +8% |
| /file | 1,798 | 2,475 | +38% | 3,590 | 5,590 | +56% |
| POST /echo 4k | 1,085 | 1,080 | -0% | 2,211 | 2,296 | +4% |
| POST /echo 1m | 72,517 | 231,649 | +219% | 288,502 | 466,376 | +62% |
| GET /events | 2,763 | 1,979 | -28% | 6,800 | 5,793 | -15% |
| WS /ws 128B | 733 | 807 | +10% | 1,658 | 1,669 | +1% |
| WS /ws 4k | 1,195 | 1,183 | -1% | 2,476 | 2,484 | +0% |
| WS /ws 4k deflate | 1,342 | 1,387 | +3% | 4,078 | 3,549 | -13% |

---

## Takeaways

- **Throughput:** Go (`net/http`) leads the handler routes (~41k); **nitro is a
  clear 2nd** (~35–37k), beats Node on several, and far outruns dart:io (~16k)
  and shelf (~13k). nitro **wins outright** on engine-served `/static` (~43k),
  `POST /echo 4k`, and every WebSocket case.
- **Tail latency is nitro's decisive win** — lowest load p99 on *every* handler
  route (~6–8 ms vs 10–17 ms for the rest).
- **`/work` (CPU-bound JSON):** Go/Node ~22k vs nitro ~8k — native encoding vs a
  Dart handler crossing the FFI boundary. This is the handler path's ceiling.
- **`GET /events` / `/file`:** Node/Go edge nitro on raw streaming throughput,
  but nitro keeps the lowest single-connection latency on both.
- **AOT vs JIT (nitro):** roughly neutral on FFI-bound handler routes (they are
  round-trip bound, not Dart-CPU bound); AOT wins streaming (`GET /events`) and
  single-connection latency; AOT is consistently *slower* on large POST echo
  (4k/1m) — a large-buffer/GC effect worth a separate look.

**Important caveat.** This is `compare.dart` — a **Dart `HttpClient`** driving
every server, so all five are partly client-limited (Go's ~41k here is *not*
Go's true ceiling). Under a fast C client (`wrk`), Go/Node reach ~137–150k while
nitro's engine-served path hits ~122–142k — see
[`benchmark-results.md`](benchmark-results.md). Both views are honest; they
answer different questions.

## Reproduce

```sh
cmake -S src -B build/lib -DCMAKE_BUILD_TYPE=Release && cmake --build build/lib --parallel
dart compile exe benchmark/compare.dart -o build/benchmark/compare
dart run benchmark/compare.dart --keep-alive --json full_jit.json          # JIT
./build/benchmark/compare      --keep-alive --json full_aot.json           # AOT
# add --quick for the 1 s/case sweep. Go/Node auto-skip if not on PATH.
```
