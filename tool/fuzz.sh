#!/usr/bin/env bash
# Builds the libFuzzer targets (test/fuzz) with clang and runs each one for
# SECONDS (default 30) from its seed corpus. Exits non-zero on a crash.
#
# Usage: bash tool/fuzz.sh [SECONDS]
set -euo pipefail
cd "$(dirname "$0")/.."
SECS=${1:-30}
# Apple's clang ships no libFuzzer runtime; Homebrew LLVM does.
CXX=${CXX:-$([ -x /opt/homebrew/opt/llvm/bin/clang++ ] && echo /opt/homebrew/opt/llvm/bin/clang++ || echo clang++)}
cmake -S test/fuzz -B build/fuzz -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_CXX_COMPILER="$CXX" >/dev/null
cmake --build build/fuzz --parallel >/dev/null
for t in head_fuzz ws_frame_fuzz template_fuzz server_fuzz; do
  mkdir -p "build/fuzz/corpus/$t"
  echo "== $t ($SECS s)"
  "./build/fuzz/$t" -max_total_time="$SECS" -max_len=4096 -print_final_stats=1 \
    "build/fuzz/corpus/$t" "test/fuzz/corpus/$t" 2>&1 |
    grep -E "^(#[0-9]+ +DONE|stat::|==.*ERROR|SUMMARY|.*crash-)" || true
  if ls crash-* leak-* timeout-* >/dev/null 2>&1; then
    echo "fuzz artifact from $t:"; ls crash-* leak-* timeout-*; exit 1
  fi
done
