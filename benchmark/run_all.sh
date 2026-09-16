#!/usr/bin/env bash
# Runs the compare benchmark in BOTH JIT (dart run) and AOT (compiled exe)
# modes and writes everything to benchmark/results.txt. Nothing else should be
# running: this owns the machine.
#
#   bash benchmark/run_all.sh [extra compare flags...]
#
# Defaults to --keep-alive with the default isolate count (1): nitro's I/O
# sweet spot — one Dart handler isolate over the multi-loop native reactor —
# and Go at its natural all-cores. Each mode is captured with a single
# buffered redirect (no per-line append) so file I/O can't perturb the run.
set -euo pipefail
cd "$(dirname "$0")/.."
export DYLD_LIBRARY_PATH="/opt/homebrew/lib:${DYLD_LIBRARY_PATH:-}"
export NITRO_SERVER_DYLIB="$PWD/build/lib/libnitro_server.dylib"
DEV=/Library/Developer/CommandLineTools
OUT="benchmark/results.txt"
FLAGS=(--keep-alive "$@")
JIT=/tmp/cmp_jit.txt
AOT=/tmp/cmp_aot.txt

# Clean slate: no stray servers/clients contending for cores.
for p in 'build/benchmark/compare' 'compare_go_server' 'compare.dart' \
         'nitro_server_engine_tests'; do pkill -9 -f "$p" 2>/dev/null || true; done
sleep 1

DEVELOPER_DIR=$DEV dart run benchmark/compare.dart "${FLAGS[@]}" > "$JIT" 2>&1
DEVELOPER_DIR=$DEV ./build/benchmark/compare "${FLAGS[@]}" > "$AOT" 2>&1

{
  echo "nitro_server compare benchmark"
  echo "date:    $(date)"
  echo "machine: $(uname -sm), $(sysctl -n hw.logicalcpu) logical CPUs"
  echo "config:  ${FLAGS[*]}  (Go GOMAXPROCS = all cores)"
  echo
  echo "============================================================"
  echo " JIT mode  (dart run — round 1 includes JIT warmup)"
  echo "============================================================"
  cat "$JIT"
  echo
  echo "============================================================"
  echo " AOT mode  (compiled exe — no JIT warmup, peak optimizer)"
  echo "============================================================"
  cat "$AOT"
} > "$OUT"

echo "wrote $OUT"
