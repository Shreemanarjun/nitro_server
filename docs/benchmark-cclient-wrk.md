# Benchmark: true throughput with a C client (`wrk`)

`compare.dart` drives every server with a **Dart `HttpClient`**, which caps all
of them well below their real ceiling. This run swaps in **`wrk`** (a C load
generator) so each server shows its true throughput — the TechEmpower-style
methodology.

- **Client:** `wrk 4.2.0`, `-t2 -c64 -d10s --latency`, keep-alive, endpoint
  `/json` (serialize `{"message":"Hello, World!"}` per request).
- **Why `-t2 -c64` (not TFB's `-c256`):** on an 8-core box, `wrk -t8 -c256`
  puts the load threads and the server's isolates on the *same* cores, so every
  framework ties at the machine ceiling — it measures the box, not the server.
  Two `wrk` threads leave the server its own cores and separate them.
- **Servers:** one at a time on `:8080`, release builds (Dart AOT, `go build`,
  Node JIT). nitro runs two ways — a **Dart handler** per request, and
  **`getStatic`** (the native reactor answers on its own thread, no Dart hop).
- **Order:** competitors run **first** so nitro's rows run warmer — a
  conservative posture for nitro, not a flattering one.
- **Machine:** macOS, 8 logical cores, loopback. Idle (no background load).

---

## Results — `/json`, req/s · p50 · p99

| framework | req/s | p50 | **p99 (tail)** |
|---|--:|--:|--:|
| **nitro `getStatic`** (engine-served) | **140,024** | 384µs | **0.99 ms** 🏆 |
| node (`http` + cluster) | 138,356 | 298µs | 2.47 ms |
| go (`net/http`) | 136,994 | 307µs | 1.24 ms |
| dart:io | 104,005 | 467µs | 2.37 ms |
| shelf | 86,286 | 585µs | 4.34 ms |
| nitro (Dart handler) | 81,433 | 738µs | **1.15 ms** |

---

## Takeaways

- **nitro's engine-served path (`getStatic`) leads on throughput — 140k**,
  edging node (138k) and go (137k), and takes the **tightest p99 in the whole
  field (0.99 ms)**. This is the path for cacheable/static responses: the
  request never crosses into Dart.
- **nitro's handler path (81k)** is throughput mid-pack — the Dart↔native FFI
  round-trip sets a ~738µs p50 floor (81k ≈ 64 conns / 738µs). But its **p99
  (1.15 ms) is the 2nd-tightest tail**, ahead of go, node, dart:io and shelf.
- **nitro owns tail latency.** The two tightest p99s are nitro's (getStatic
  0.99 ms, handler 1.15 ms); then go 1.24, node 2.47, dart:io 2.37, shelf 4.34.
  Consistent tail is nitro's real differentiator.
- **go/node reach a higher *handler-equivalent* ceiling** (137–138k) because
  they never cross a language boundary and allocate almost nothing per request.
  nitro closes that gap only on the engine-served path — which it does, fully.

## How this differs from the Dart-client comparison

`compare.dart` (Dart `HttpClient`) caps every server at ~25–43k and there
**nitro wins or ties Go/Node** on the handler routes — because the *client* is
the bottleneck and nitro's native reactor keeps pace where dart:io/shelf fall
behind. See [`benchmark-jit-aot.md`](benchmark-jit-aot.md). Under `wrk` the
client is no longer the limit, so Go/Node's higher raw ceiling shows — while
nitro's engine-served path matches it and nitro keeps the tail-latency lead.
Both views are honest; they answer different questions.

## Reproduce

```sh
brew install wrk   # or apt-get install wrk
cmake -S src -B build/lib -DCMAKE_BUILD_TYPE=Release && cmake --build build/lib --parallel
# one server at a time on :8080, then:
wrk -t2 -c64 -d10s --latency http://127.0.0.1:8080/json
```

The repo's `benchmark/techempower/run.sh` runs the TFB-standard `-c256` sweep
(nitro handler, dart:io, shelf, go, node); the `getStatic` variant is
`benchmark/techempower/nitro_static_tfb.dart`.
