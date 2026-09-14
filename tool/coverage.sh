#!/usr/bin/env bash
# Coverage gate: full-suite line coverage must hold the floor.
# Generated bridge code (*.g.dart, lib/src/generated) is excluded — it is
# verified by `nitrogen generate` being a no-op in CI, not by line hits.
#
# The suite is pure `package:test`, so `dart test` is the primary runner.
# `flutter test` is the fallback. The line rate is parsed from the lcov file
# in Python rather than via `lcov --summary`, because lcov 1.x and 2.x differ
# in strictness (2.x errors on Dart lcov's absent function coverpoints), and
# the gate must run identically on every runner. `lcov` is only needed for the
# optional `--html` report.
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

if [ "$HTML" -eq 1 ] && command -v genhtml >/dev/null 2>&1; then
  genhtml --ignore-errors empty,unused,category coverage/lcov.info \
    -o coverage/html >/dev/null 2>&1 || genhtml coverage/lcov.info -o coverage/html >/dev/null
  echo "HTML report: coverage/html/index.html"
fi

# Line rate over lib/, excluding generated bridge code. Parsed straight from
# the lcov records so no lcov binary (and no version quirk) is on the path.
python3 - "$FLOOR" <<'PY'
import re, sys
floor = float(sys.argv[1])
skip = re.compile(r'nitro_server\.g\.dart$|/generated/')
cur = None
total = covered = 0
per_file = {}
for line in open('coverage/lcov.info', encoding='utf-8'):
    line = line.rstrip('\n')
    if line.startswith('SF:'):
        cur = line[3:]
    elif line.startswith('DA:') and cur and not skip.search(cur):
        _, hits = line[3:].split(',')
        t, c = per_file.get(cur, (0, 0))
        per_file[cur] = (t + 1, c + (1 if int(hits) > 0 else 0))
for t, c in per_file.values():
    total += t
    covered += c
rate = 100.0 * covered / total if total else 100.0
print(f"line coverage: {rate:.1f}% ({covered}/{total} lines, floor {floor:.0f}%)")
below = sorted(f for f, (t, c) in per_file.items() if c < t)
if below:
    print("--- files below 100% ---")
    for f in below:
        t, c = per_file[f]
        print(f"  {100.0*c/t:.1f}%  {f}")
if rate + 1e-9 < floor:
    print(f"FAIL: line coverage {rate:.1f}% is below the {floor:.0f}% floor")
    sys.exit(1)
print(f"PASS: line coverage {rate:.1f}% meets the {floor:.0f}% floor")
PY
