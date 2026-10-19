#!/usr/bin/env bash
# Host wrapper: build the benchmark image and run it in a CONTROLLED black box so
# anyone reproduces comparable numbers. Run from anywhere; paths resolve to the
# repo root.
#
#   benchmark/docker/bench.sh [--cpus 0-3] [--mem 4g] [-- <extra compare flags>]
#
# Determinism levers (all pinned here):
#   * base image digest  — DART_VERSION build arg (pin a digest for byte-exact)
#   * CPU set            — --cpuset-cpus so the run always gets the same cores
#   * memory             — --memory == --memory-swap (no swap surprises)
#   * controller         — run-bench.sh measures adaptive AND pinned
# Results land in benchmark/docker/out/{results,results-adaptive,results-pinned}.txt
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

CPUSET="0-3"          # 4 pinned cores; change to match the box you standardize on
MEM="4g"
EXTRA=()
while [ $# -gt 0 ]; do
  case "$1" in
    --cpus) CPUSET="$2"; shift 2 ;;
    --mem)  MEM="$2"; shift 2 ;;
    --) shift; EXTRA=("$@"); break ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

mkdir -p benchmark/docker/out
echo "building nitro-bench image…"
docker build -f benchmark/docker/Dockerfile -t nitro-bench .

echo "running controlled benchmark: cpuset=$CPUSET mem=$MEM flags='${EXTRA[*]:-}'"
# --cpuset-cpus pins the cores; --memory==--memory-swap disables swap; the
# container sees exactly these resources, so GOMAXPROCS/nproc are deterministic.
docker run --rm \
  --cpuset-cpus="$CPUSET" \
  --memory="$MEM" --memory-swap="$MEM" \
  -e COMPARE_FLAGS="${EXTRA[*]:-}" \
  -v "$ROOT/benchmark/docker/out:/out" \
  nitro-bench

echo
echo "results written to benchmark/docker/out/"
echo "  results.txt           — adaptive + pinned, side by side"
echo "  results-adaptive.txt  — production-realistic (controller auto)"
echo "  results-pinned.txt    — deterministic (controller frozen)"
