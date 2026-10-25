#!/usr/bin/env bash
# Host wrapper for the TRUE-BLACKBOX cross-framework benchmark. Builds a pinned,
# reproducible image and runs it in a CONTROLLED black box so anyone gets a
# comparable result. Run from anywhere; paths resolve to the repo root.
#
#   benchmark/blackbox/run.sh [--cpus 0-3] [--mem 4g] [--reps 5] \
#                             [--duration 10s] [--connections 64] \
#                             [--frameworks "nitro-native nitro-dylib go node dartio shelf ion"]
#                             [--base <git-ref>]
#
# --base <ref> is the A/B mode: the tree at <ref> is exported, built the same
# way inside the image and served as the extra framework `nitro-base`, so two
# builds of nitro are measured INTERLEAVED in one run — the only comparison the
# methodology accepts for a small delta (two separate full runs drift more than
# the delta). Typical: `--base HEAD --frameworks "nitro-base nitro-dylib"`.
#
# CPU split: the pinned cpuset is halved — first half = server cores, second
# half = oha (load generator) cores — so client and server never contend. Needs
# a Linux container host with cpuset support (Docker Desktop / colima / Linux);
# macOS has no CPU pinning natively, which is exactly why this runs in a VM.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

CPUS="0-3"; MEM="4g"; REPS=5; DURATION="10s"; CONNECTIONS=64
FRAMEWORKS="nitro-native nitro-dylib go node dartio shelf ion"
BASE=""
while [ $# -gt 0 ]; do case "$1" in
  --base) BASE="$2"; shift 2 ;;
  --cpus) CPUS="$2"; shift 2 ;;
  --mem) MEM="$2"; shift 2 ;;
  --reps) REPS="$2"; shift 2 ;;
  --duration) DURATION="$2"; shift 2 ;;
  --connections) CONNECTIONS="$2"; shift 2 ;;
  --frameworks) FRAMEWORKS="$2"; shift 2 ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
esac; done

# Split the cpuset in half: server cores | client cores (disjoint).
lo="${CPUS%-*}"; hi="${CPUS#*-}"; n=$((hi - lo + 1))
if [ "$n" -lt 2 ]; then echo "need >=2 cores in --cpus (got $CPUS)"; exit 2; fi
half=$((n / 2)); SRV="$lo-$((lo + half - 1))"; CLI="$((lo + half))-$hi"

# A/B baseline tree: exported from git (never a dirty copy), removed after.
rm -rf benchmark/blackbox/base
if [ -n "$BASE" ]; then
  mkdir -p benchmark/blackbox/base
  git archive "$BASE" | tar -x -C benchmark/blackbox/base
  # .dockerignore's root-only exclusions, applied to the export too (example/
  # pulls flutter_test into pub's resolution; the rest is dead weight).
  (cd benchmark/blackbox/base && rm -rf example test android ios macos linux windows doc .github)
  trap 'rm -rf "$ROOT/benchmark/blackbox/base"' EXIT
  echo "A/B baseline: $BASE ($(git rev-parse --short "$BASE")) -> nitro-base"
fi

echo "building nitro-blackbox image…"
docker build -f benchmark/blackbox/Dockerfile -t nitro-blackbox --build-arg "BASE_REF=${BASE:+$BASE ($(git rev-parse --short "$BASE"))}" .

mkdir -p benchmark/blackbox/out
echo "running: cpus=$CPUS (srv=$SRV cli=$CLI) mem=$MEM reps=$REPS dur=$DURATION conns=$CONNECTIONS"
echo "frameworks: $FRAMEWORKS"
# --cpuset-cpus pins cores; --memory==--memory-swap disables swap surprises.
docker run --rm \
  --cpuset-cpus="$CPUS" --memory="$MEM" --memory-swap="$MEM" \
  -e SRV_CORES="$SRV" -e CLI_CORES="$CLI" -e REPS="$REPS" \
  -e DURATION="$DURATION" -e CONNECTIONS="$CONNECTIONS" \
  -e FRAMEWORKS="$FRAMEWORKS" \
  -v "$ROOT/benchmark/blackbox/out:/out" \
  nitro-blackbox

echo "results: benchmark/blackbox/out/report.md  (raw samples: out/raw/samples.csv)"
