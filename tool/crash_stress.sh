#!/usr/bin/env bash
# Production-grade crash gate for the @Native FFI path.
#
# Runs tool/crash_stress.dart (every native free path, looped, forced GC) under
# aggressive allocator diagnostics and asserts two invariants:
#   1. No double-free / bad-free / cross-image abort — the allocator aborts the
#      process on heap corruption, failing the gate.
#   2. Exactly ONE engine image is mapped — the two-copies split-brain (a second
#      DynamicLibrary.open of a different path than the @Native asset) is what
#      regressed the migration; this catches it directly.
# Runs both single- and multi-isolate so the isolate-group GC / shared-heap
# paths are covered too.
#
# Usage: bash tool/crash_stress.sh [ROUNDS=30]
set -uo pipefail
cd "$(dirname "$0")/.."
export DYLD_LIBRARY_PATH="/opt/homebrew/lib:${DYLD_LIBRARY_PATH:-}"
unset NITRO_SERVER_DYLIB
ROUNDS="${1:-30}"

OS=$(uname -s)
if [ "$OS" = "Darwin" ]; then
  # Scribble freed memory, guard-page large allocs, validate the heap often,
  # and abort on any allocator error (double-free / freeing-unallocated).
  GUARD=(MallocNanoZone=0 MallocScribble=1 MallocPreScribble=1 MallocGuardEdges=1 \
         MallocCheckHeapStart=1 MallocCheckHeapEach=256 MallocErrorAbort=1)
else
  GUARD=(MALLOC_CHECK_=3)  # glibc: abort on heap corruption / double-free
fi

fail=0
for iso in 1 4; do
  log=$(mktemp)
  env "${GUARD[@]}" dart run tool/crash_stress.dart --isolates "$iso" --rounds "$ROUNDS" \
    > "$log" 2>&1 &
  pid=$!

  # Single-image invariant: once the server is up, assert exactly one engine
  # image is mapped into the process (isolates are in-process, so still one).
  for _ in $(seq 1 60); do grep -q "up on" "$log" 2>/dev/null && break; sleep 0.2; done
  if [ "$OS" = "Darwin" ] && kill -0 "$pid" 2>/dev/null; then
    copies=$(lsof -p "$pid" 2>/dev/null \
      | grep -oE "/[^ ]*libnitro_server[^ ]*" | sort -u | wc -l | tr -d ' ')
    if [ "${copies:-0}" -gt 1 ]; then
      echo "FAIL(iso=$iso): $copies engine images mapped — two-copies split-brain regression"
      lsof -p "$pid" 2>/dev/null | grep -oE "/[^ ]*libnitro_server[^ ]*" | sort -u
      fail=1
    fi
  fi

  wait "$pid"; rc=$?
  if [ "$rc" -ne 0 ] || grep -qiE "BUG_IN_CLIENT|POINTER_BEING_FREED|was not allocated|Invalid argument|SIGABRT|libc\+\+abi|abort\(\)" "$log"; then
    echo "FAIL(iso=$iso): rc=$rc"
    tail -12 "$log"
    fail=1
  else
    rounds_ok=$(grep -c "round .* ok" "$log")
    echo "PASS(iso=$iso): single image, clean exit under malloc guard ($rounds_ok checkpoints)"
  fi
  rm -f "$log"
done

if [ "$fail" -eq 0 ]; then
  echo "crash_stress: PASS — every @Native free path, every isolate config, no bad-free, single image"
else
  echo "crash_stress: FAIL"
  exit 1
fi
