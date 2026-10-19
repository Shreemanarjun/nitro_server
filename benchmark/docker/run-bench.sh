#!/usr/bin/env bash
# In-container benchmark runner. Runs the full compare suite in BOTH controller
# modes and writes the tables (plus a reproducible environment header) to /out.
#
#   ADAPTIVE: the engine's dispatch controller sizes the worker/isolate fan-out
#             from live load — production-realistic, but its convergence can vary
#             run to run, which is why we also measure:
#   PINNED:   NITRO_DISPATCH forces a fixed dispatch width, so the controller
#             cannot move and the number is deterministic black-box.
#
# Everything else is held fixed (same engine, same driver, same --keep-alive,
# same isolate count, GOMAXPROCS = container cpuset). Extra compare flags pass
# through $COMPARE_FLAGS; the pinned width is $NITRO_DISPATCH_PIN (default 1, the
# single-isolate I/O sweet spot the headline uses).
set -euo pipefail
cd /app

OUT=${OUT_DIR:-/out}
mkdir -p "$OUT"
FLAGS=(--keep-alive ${COMPARE_FLAGS:-})
PIN=${NITRO_DISPATCH_PIN:-1}

header() {
  echo "nitro_server compare benchmark (dockerized, controlled)"
  echo "mode:    $1"
  echo "image:   dart $(dart --version 2>&1 | sed -E 's/.*version: ([0-9.]+).*/\1/')"
  echo "go:      $(go version 2>&1 | awk '{print $3}')"
  echo "node:    $(node --version 2>&1)"
  echo "cpus:    $(nproc) online$([ -r /sys/fs/cgroup/cpu.max ] && echo " (cgroup cpu.max: $(cat /sys/fs/cgroup/cpu.max))")"
  echo "mem:     $([ -r /sys/fs/cgroup/memory.max ] && cat /sys/fs/cgroup/memory.max || echo unknown) (cgroup bytes)"
  echo "engine:  $(basename "${NITRO_SERVER_DYLIB:-?}") (HTTP/2 off unless rebuilt)"
  echo "flags:   ${FLAGS[*]}"
  echo
}

# Clean slate between modes: no stray peer servers holding cores.
reap() { for p in build/benchmark/compare compare_go_server compare_node_server; do
           pkill -9 -f "$p" 2>/dev/null || true; done; sleep 1; }

echo "== ADAPTIVE controller =="
reap
{ header "ADAPTIVE (auto dispatch controller)"
  ./build/benchmark/compare "${FLAGS[@]}"; } > "$OUT/results-adaptive.txt" 2>&1 || true
echo "wrote $OUT/results-adaptive.txt"

echo "== PINNED controller (NITRO_DISPATCH=$PIN) =="
reap
{ header "PINNED (NITRO_DISPATCH=$PIN — controller frozen)"
  NITRO_DISPATCH="$PIN" ./build/benchmark/compare "${FLAGS[@]}"; } > "$OUT/results-pinned.txt" 2>&1 || true
echo "wrote $OUT/results-pinned.txt"

# One combined artifact for easy side-by-side reading.
{ echo "############## ADAPTIVE ##############"; cat "$OUT/results-adaptive.txt"
  echo; echo "############## PINNED ##############"; cat "$OUT/results-pinned.txt"
} > "$OUT/results.txt"
echo "wrote $OUT/results.txt"
