#!/usr/bin/env bash
# Host wrapper for the TRUE-BLACKBOX cross-framework benchmark. Builds a pinned,
# reproducible image and runs it in a CONTROLLED black box so anyone gets a
# comparable result. Run from anywhere; paths resolve to the repo root.
#
#   benchmark/blackbox/run.sh [--cpus 0-3] [--mem 4g] [--reps 5] \
#                             [--duration 10s] [--connections 64] \
#                             [--frameworks "nitro-native nitro-dylib go node dartio shelf"]
#
# CPU split: the pinned cpuset is halved — first half = server cores, second
# half = oha (load generator) cores — so client and server never contend. Needs
# a Linux container host with cpuset support (Docker Desktop / colima / Linux);
# macOS has no CPU pinning natively, which is exactly why this runs in a VM.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

CPUS="0-3"; MEM="4g"; REPS=5; DURATION="10s"; CONNECTIONS=64
FRAMEWORKS="nitro-native nitro-dylib go node dartio shelf"
while [ $# -gt 0 ]; do case "$1" in
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

# Vendor the UNPUBLISHED local nitro packages into the build context so the
# image is self-contained + reproducible. Delete this block once nitro ships.
VEND="benchmark/blackbox/_vendor"
NE="../../flutter_package/nitro_ecosystem/packages"
if [ -d "$NE/nitro" ]; then
  rm -rf "$VEND"; mkdir -p "$VEND"
  for p in nitro nitro_generator nitro_annotations; do
    rsync -a --delete --exclude .dart_tool --exclude build "$NE/$p/" "$VEND/$p/"
  done
  echo "vendored local nitro into $VEND"
else
  echo "WARN: local nitro ($NE) not found — image will use pub.dev nitro (may lack @Native)"
fi

echo "building nitro-blackbox image…"
docker build -f benchmark/blackbox/Dockerfile -t nitro-blackbox .

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
