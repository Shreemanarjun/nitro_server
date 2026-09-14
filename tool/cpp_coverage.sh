#!/usr/bin/env bash
# C++ engine line-coverage gate (clang source-based coverage over src/engine).
#
# Usage: bash tool/cpp_coverage.sh [FLOOR]
# Env:   CXX (default clang++), LLVM_PROFDATA, LLVM_COV (default: PATH, then xcrun)
set -euo pipefail
cd "$(dirname "$0")/.."
FLOOR=${1:-100}
PROFDATA=${LLVM_PROFDATA:-$(command -v llvm-profdata || xcrun -f llvm-profdata)}
COV=${LLVM_COV:-$(command -v llvm-cov || xcrun -f llvm-cov)}

cmake -S src -B build/cov -DCMAKE_BUILD_TYPE=Debug -DNITRO_SERVER_BUILD_TESTS=ON \
  -DNITRO_SERVER_COVERAGE=ON -DCMAKE_CXX_COMPILER="${CXX:-clang++}" >/dev/null
cmake --build build/cov --parallel --target nitro_server_engine_tests >/dev/null
rm -f build/cov/engine-*.profraw
LLVM_PROFILE_FILE=build/cov/engine-%p.profraw \
  ./build/cov/nitro_server_tests/nitro_server_engine_tests >/dev/null
"$PROFDATA" merge -sparse build/cov/engine-*.profraw -o build/cov/engine.profdata
"$COV" report ./build/cov/nitro_server_tests/nitro_server_engine_tests \
  -instr-profile=build/cov/engine.profdata src/engine | tee build/cov/report.txt
if [ "${1:-}" = "--html" ] || [ "${HTML:-0}" = "1" ]; then
  "$COV" show ./build/cov/nitro_server_tests/nitro_server_engine_tests \
    -instr-profile=build/cov/engine.profdata src/engine -format=html \
    -output-dir=build/cov/html >/dev/null
  echo "HTML report: build/cov/html/index.html"
fi
# TOTAL row: line cover is the 10th of 13 columns (with branch columns) or
# the last of 10 (without).
RATE=$(awk '/^TOTAL/ { print (NF >= 13) ? $(NF-3) : $NF }' build/cov/report.txt | tr -d '%')
INT=${RATE%.*}
echo "engine line coverage: ${RATE}% (floor ${FLOOR}%)"
[ "$INT" -ge "$FLOOR" ] || { echo "below floor"; exit 1; }
