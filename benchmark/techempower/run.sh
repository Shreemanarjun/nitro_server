#!/usr/bin/env bash
# TechEmpower-style benchmark (github.com/TechEmpower/FrameworkBenchmarks):
# standard /json (serialize {"message":"Hello, World!"} per request) and
# /plaintext ("Hello, World!") endpoints, driven by `wrk` at TFB concurrency.
# One server process at a time on :8080, release builds, keep-alive.
#
#   env: DUR (seconds, default 10)  CONN (connections, default 256)
#
# Dart servers are AOT-compiled (dart compile exe), Go is `go build`, Node is
# JIT (its only mode) — the same release posture TFB uses.
set -o pipefail
cd "$(dirname "$0")/../.."           # -> nitro_server package root
OUT=build/tfb; mkdir -p "$OUT"
CORES=$(sysctl -n hw.ncpu 2>/dev/null || nproc)
DUR=${DUR:-10}; CONN=${CONN:-256}; PORT=8080

echo "building release binaries (cores=$CORES)..."
cmake --build build/lib --parallel >/dev/null 2>&1
dart compile exe benchmark/techempower/nitro_tfb.dart  -o "$OUT/nitro"  >/dev/null 2>&1 || { echo "nitro build failed"; exit 1; }
dart compile exe benchmark/techempower/dartio_tfb.dart -o "$OUT/dartio" >/dev/null 2>&1 || { echo "dartio build failed"; exit 1; }
dart compile exe benchmark/techempower/shelf_tfb.dart  -o "$OUT/shelf"  >/dev/null 2>&1 || { echo "shelf build failed"; exit 1; }
go build -o "$OUT/go" benchmark/techempower/go_tfb.go               || { echo "go build failed"; exit 1; }

wait_port() { for _ in $(seq 1 60); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && return 0; sleep 0.5; done; return 1; }
stop() { kill "$1" 2>/dev/null; pkill -f "$2" 2>/dev/null; sleep 1; }

# wrk one endpoint -> "rps p50 p99" (p50/p99 as printed, e.g. 1.23ms)
wrk_stat() {
  wrk -t"$CORES" -c"$CONN" -d"${DUR}s" --latency "http://127.0.0.1:$PORT/$1" 2>/dev/null | awk '
    /Requests\/sec/ { rps=$2 }
    /^[[:space:]]*50%/ { p50=$2 }
    /^[[:space:]]*99%/ { p99=$2 }
    END { printf "%s %s %s", rps, p50, p99 }'
}

RESULTS="$OUT/results.txt"; : > "$RESULTS"
run() {  # name  start-cmd  pkill-pattern
  printf 'benchmarking %-7s ' "$1"
  eval "$2 >$OUT/$1.log 2>&1 &"; local pid=$!
  if ! wait_port; then echo "FAILED to start (see $OUT/$1.log)"; stop "$pid" "$3"; return; fi
  sleep 1
  local j p
  j=$(wrk_stat json)
  p=$(wrk_stat plaintext)
  echo "$1 $j $p" >> "$RESULTS"
  echo "done"
  stop "$pid" "$3"
}

run nitro  "$OUT/nitro"  "techempower/nitro"
run dartio "$OUT/dartio" "techempower/dartio"
run shelf  "$OUT/shelf"  "techempower/shelf"
run go     "$OUT/go"     "techempower/go"
run node   "node benchmark/techempower/node_tfb.js" "node_tfb"

echo
echo "TechEmpower-style results — cores=$CORES, conn=$CONN, dur=${DUR}s, keep-alive"
printf '%-9s | %14s %8s %8s | %14s %8s %8s\n' "framework" "JSON req/s" "p50" "p99" "TEXT req/s" "p50" "p99"
echo "----------+----------------------------------+----------------------------------"
while read -r f jr jp jq pr pp pq; do
  printf '%-9s | %14s %8s %8s | %14s %8s %8s\n' "$f" "$jr" "$jp" "$jq" "$pr" "$pp" "$pq"
done < "$RESULTS"
