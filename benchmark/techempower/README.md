# TechEmpower-style benchmark

A cross-framework comparison in the style of
[TechEmpower FrameworkBenchmarks](https://github.com/TechEmpower/FrameworkBenchmarks):
standard endpoints, a real HTTP load generator (`wrk`), release builds, and
keep-alive at fixed concurrency — a cleaner apples-to-apples than the in-process
`benchmark/compare.dart` driver.

## Endpoints (TFB "JSON" and "Plaintext" test types)

| path | content-type | body |
|------|--------------|------|
| `GET /json` | `application/json` | `{"message":"Hello, World!"}` — **serialized per request** |
| `GET /plaintext` | `text/plain` | `Hello, World!` |

The DB-backed TFB tests (single/multiple query, fortunes, updates) are out of
scope here — they need Postgres and a driver per framework.

## Frameworks

| server | file | build | parallelism |
|--------|------|-------|-------------|
| nitro_server | `nitro_tfb.dart` | `dart compile exe` (AOT) | isolates = cores |
| dart:io | `dartio_tfb.dart` | AOT | `HttpServer.bind(shared:)` per core |
| shelf | `shelf_tfb.dart` | AOT | `shelf_io.serve(shared:)` per core |
| Go net/http | `go_tfb.go` | `go build` | GOMAXPROCS = cores |
| Node.js | `node_tfb.js` | JIT (Node has no AOT) | `cluster` worker per core |

## Run

```sh
brew install wrk          # the TFB load generator (once)
DUR=10 CONN=256 bash benchmark/techempower/run.sh
```

`run.sh` builds every server, then for each one: starts it on `:8080`, waits for
the port, runs `wrk -t<cores> -c<CONN> -d<DUR>s --latency` against `/json` and
`/plaintext`, records `Requests/sec` + p50/p99 latency, and stops it. One server
runs at a time so they never contend. Prints a comparison table at the end.

`CONN=256` mirrors TFB's JSON concurrency; raise `CONN` (TFB drives plaintext up
to 16384, pipelined) to probe the high-concurrency tail.

## Notes

- Loopback only: this measures server CPU efficiency, not a NIC. Numbers are
  relative between frameworks on the same machine, not absolute TFB rankings.
- nitro and dart:io/shelf are AOT (what Flutter release ships); Go is compiled;
  Node is JIT — each framework's real release posture.
