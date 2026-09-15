#!/usr/bin/env bash
# Runs the compare benchmark in BOTH JIT (dart run) and AOT (compiled exe)
# modes, keep-alive, multi-isolate (fair /work), and writes everything to
# benchmark/results.txt. Nothing else should be running: this owns the machine.
#   bash benchmark/run_all.sh [extra compare flags...]
set -euo pipefail
cd "$(dirname "$0")/.."
export DYLD_LIBRARY_PATH="/opt/homebrew/lib:${DYLD_LIBRARY_PATH:-}"
export NITRO_SERVER_DYLIB="$PWD/build/lib/libnitro_server.dylib"
OUT="benchmark/results.txt"
FLAGS=(--keep-alive --isolates 0 "$@")   # --isolates 0 = numberOfProcessors/2

# Clean slate: no stray servers/clients contending for cores.
pkill -f 'build/benchmark/compare' 2>/dev/null || true
pkill -f 'compare_go_server' 2>/dev/null || true
pkill -f 'nitro_server_engine_tests' 2>/dev/null || true
sleep 1

{
  echo "nitro_server compare benchmark — full run"
  echo "date:    $(date)"
  echo "machine: $(uname -sm), $(sysctl -n hw.logicalcpu) logical CPUs"
  echo "config:  ${FLAGS[*]}  (Go GOMAXPROCS pinned to the isolate count)"
  echo "dylib:   $NITRO_SERVER_DYLIB"
  echo
  echo "============================================================"
  echo " JIT mode  (dart run — includes JIT warmup in round 1)"
  echo "============================================================"
} > "$OUT"

DEVELOPER_DIR=/Library/Developer/CommandLineTools \
  dart run benchmark/compare.dart "${FLAGS[@]}" >> "$OUT" 2>&1

{
  echo
  echo "============================================================"
  echo " AOT mode  (compiled exe — no JIT warmup, peak optimizer)"
  echo "============================================================"
} >> "$OUT"

DEVELOPER_DIR=/Library/Developer/CommandLineTools \
  ./build/benchmark/compare "${FLAGS[@]}" >> "$OUT" 2>&1

echo "wrote $OUT"
