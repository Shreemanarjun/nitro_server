#!/usr/bin/env bash
# Coverage gate: full-suite line coverage must hold the floor.
# Mirrors nitro_http's tool/coverage.sh. Generated bridge code (*.g.dart,
# lib/src/generated) is excluded — it is verified by `nitrogen generate`
# being a no-op in CI, not by line hits.
#
# The suite is pure `package:test`, so `dart test` is the primary runner
# (no Flutter SDK needed beyond resolving the `nitro` bridge dependency).
# `flutter test` still works as a fallback since Flutter bundles the Dart SDK.
#
# Usage: bash tool/coverage.sh [FLOOR=100] [--html]
set -euo pipefail
cd "$(dirname "$0")/.."

FLOOR=100
HTML=0
for arg in "$@"; do
  case "$arg" in
    --html) HTML=1 ;;
    *) FLOOR="$arg" ;;
  esac
done

if command -v dart >/dev/null 2>&1; then
  # `dart test --coverage` writes per-suite VM JSON, not lcov: convert, or
  # the gate reads whatever stale lcov.info sits in the directory.
  rm -rf coverage/test
  dart test --coverage=coverage
  dart run coverage:format_coverage --lcov --in=coverage/test \
    --out=coverage/lcov.info --report-on=lib \
    --packages=.dart_tool/package_config.json --check-ignore
else
  flutter test --coverage
fi
lcov --ignore-errors unused --remove coverage/lcov.info \
  '*/nitro_server.g.dart' '*/generated/*' \
  -o coverage/lcov.filtered.info >/dev/null

if [ "$HTML" -eq 1 ]; then
  genhtml coverage/lcov.filtered.info -o coverage/html >/dev/null
  echo "HTML report: coverage/html/index.html"
fi

SUMMARY=$(lcov --summary coverage/lcov.filtered.info 2>&1)
echo "$SUMMARY"
RATE=$(echo "$SUMMARY" | grep -oE 'lines\.*: [0-9.]+%' | grep -oE '[0-9]+(\.[0-9]+)?')
INT=${RATE%.*}
if [ "$INT" -lt "$FLOOR" ]; then
  echo "FAIL: line coverage ${RATE}% is below the ${FLOOR}% floor"
  lcov --list coverage/lcov.filtered.info 2>&1 | tail -n +5
  exit 1
fi
echo "PASS: line coverage ${RATE}% meets the ${FLOOR}% floor"

# Per-file report: anything below 100% is named, so a dip points at its file.
echo "--- files below 100% ---"
lcov --list coverage/lcov.filtered.info 2>&1 | awk '$2 != "100%" && $2 != "Rate" && NF > 1 {print}'
