#!/usr/bin/env bash
# Reactor benchmark: nitro (current thread-per-connection) vs nitro-libuv
# (the reactor spike — what nitro's libuv engine-served path will do) vs Go
# net/http vs dart:io, driven by the same raw C++ keep-alive load generator
# across a sweep of connection counts. Every server returns the same tiny
# fixed body, so throughput reflects the I/O model / connection scaling.
#
# Usage: bash bench_reactor.sh [conns...]        (default: 64 256 512 1024)
# Requires: libuv (brew install libuv / apt install libuv1-dev), Go, Dart, and
# the nitro dylib at build/lib/libnitro_server.dylib.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"
CONNS=("$@"); [ ${#CONNS[@]} -eq 0 ] && CONNS=(64 256 512 1024)
SECS=3
N=4                       # isolates (nitro/dartio) / loops (libuv)
DEV=/Library/Developer/CommandLineTools
export DYLD_LIBRARY_PATH="${DYLD_LIBRARY_PATH:-}:/opt/homebrew/lib"
# nitro's dylib, by absolute path so the harness finds it from any CWD.
export NITRO_DYLIB="$ROOT/build/lib/libnitro_server.dylib"
say() { printf '%s\n' "$*" >&2; }
: > /tmp/br_results.txt

say "building loadgen + servers…"
DEVELOPER_DIR=$DEV clang++ -O2 -std=c++17 loadgen.cpp -o /tmp/br_loadgen
DEVELOPER_DIR=$DEV cc -O2 uv_reactor_spike.c -o /tmp/br_uv \
  -I/opt/homebrew/include -L/opt/homebrew/lib -luv -lpthread
go build -o /tmp/br_go go_server.go
( cd "$ROOT"; dart compile exe benchmark/experiments/dartio_server.dart -o /tmp/br_dartio >/dev/null )
( cd "$ROOT"; dart compile exe benchmark/experiments/nitro_server.dart  -o /tmp/br_nitro  >/dev/null )

wait_port() { # logfile -> port
  for _ in $(seq 1 40); do
    p=$(grep -oE 'LISTENING [0-9]+' "$1" 2>/dev/null | awk '{print $2}' | head -1)
    [ -n "$p" ] && { echo "$p"; return; }; sleep 0.25
  done
}

sweep() { # name port path
  local name=$1 port=$2 path=$3 c rps
  for c in "${CONNS[@]}"; do
    rps=$(/tmp/br_loadgen "$port" "$c" "$SECS" "$path")
    printf '%s|%s|%s\n' "$name" "$c" "$rps" >> /tmp/br_results.txt
  done
}

server() { # name "start cmd" path [fixed_port]
  local name=$1 cmd=$2 path=$3 fixed=${4:-}
  bash -c "$cmd" > /tmp/br.log 2>&1 &
  local pid=$! port
  if [ -n "$fixed" ]; then sleep 1.5; port=$fixed; else port=$(wait_port /tmp/br.log); fi
  if [ -z "${port:-}" ]; then say "  $name: no port"; kill $pid 2>/dev/null||true; return; fi
  say "  $name on $port"
  sweep "$name" "$port" "$path"
  kill $pid 2>/dev/null || true; wait $pid 2>/dev/null || true; sleep 0.5
}

say "sweep: ${CONNS[*]} conns, ${SECS}s each, N=$N"
server "nitro /static"       "/tmp/br_nitro $N"        /static
server "nitro-libuv (spike)" "/tmp/br_uv 8100 $N"      /static 8100
server "go net/http"         "/tmp/br_go"              /hello
server "dart:io"             "/tmp/br_dartio $N"       /hello

python3 - "${CONNS[@]}" <<'PY'
import sys
conns = sys.argv[1:]
rows = {}
for line in open('/tmp/br_results.txt'):
    name, c, rps = line.rstrip('\n').split('|'); rows.setdefault(name, {})[c] = int(rps)
order = ["nitro /static", "nitro-libuv (spike)", "go net/http", "dart:io"]
w = max(len(n) for n in order)
hdr = "server".ljust(w) + "".join(f" | {c+' conns':>11}" for c in conns)
print(); print(hdr); print("-"*len(hdr))
for name in order:
    if name in rows:
        print(name.ljust(w) + "".join(f" | {rows[name].get(c,0):>11,}" for c in conns))
PY
