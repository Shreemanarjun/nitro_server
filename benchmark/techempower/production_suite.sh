#!/bin/zsh
# Comprehensive production-metrics suite, AOT vs JIT. Compares nitro_server against
# dart:io, shelf, Go net/http and Node (cluster) across EVERY comparison type:
#   startup time, throughput (+stability CoV) for /json and /plaintext,
#   closed-loop latency (p50/p90/p99), open-loop / coordinated-omission-free latency
#   (p50/p90/p99/p99.9), overload at -c256 and -c1024 (+error counts),
#   CPU efficiency (req/s per core), and memory (idle/load RSS).
# The three Dart servers run in BOTH modes:
#   AOT = dart compile exe (ahead-of-time native)
#   JIT = dart compile kernel + dart <dill> (VM JIT, no resident source compiler)
# Go is always AOT; Node is always JIT (V8). Tools: wrk (closed-loop) and
# oha -q --latency-correction (open-loop). Env: DUR, ROUNDS, RATE, CONN, DIR.
set -u
cd "$(dirname "$0")/../.." || exit 1
export PATH="$HOME/.cargo/bin:/Users/shreemanarjunsahu/.puro/shared/pub_cache/bin:$PATH"
O=${DIR:-/tmp/psuite}; mkdir -p $O; PORT=8080; B=benchmark/techempower
DUR=${DUR:-6}; ROUNDS=${ROUNDS:-3}; RATE=${RATE:-60000}; CONN=${CONN:-64}
CORES=$(sysctl -n hw.ncpu)
RES=$O/results.csv; : > $RES
have(){ command -v "$1" >/dev/null 2>&1; }
have wrk || { echo "wrk required"; exit 1; }
OHA=1; have oha || OHA=0

echo "building AOT exes + JIT kernels (nitro, dart:io, shelf) + go ..."
for s in nitro dartio shelf; do
  dart compile exe    $B/${s}_tfb.dart -o "$O/$s.aot"  >/dev/null 2>&1 || { echo "$s aot fail"; exit 1; }
  dart compile kernel $B/${s}_tfb.dart -o "$O/$s.dill" >/dev/null 2>&1 || { echo "$s jit fail"; exit 1; }
done
go build -o "$O/go.aot" $B/go_tfb.go >/dev/null 2>&1 || { echo "go fail"; exit 1; }
echo "built. (DUR=$DUR ROUNDS=$ROUNDS RATE=$RATE CONN=$CONN cores=$CORES)"

CONFIGS=(
  "nitro|AOT|$O/nitro.aot|$O/nitro.aot"
  "nitro|JIT|dart $O/nitro.dill|nitro.dill"
  "dart:io|AOT|$O/dartio.aot|$O/dartio.aot"
  "dart:io|JIT|dart $O/dartio.dill|dartio.dill"
  "shelf|AOT|$O/shelf.aot|$O/shelf.aot"
  "shelf|JIT|dart $O/shelf.dill|shelf.dill"
  "go|AOT|$O/go.aot|$O/go.aot"
  "node|JIT|node $B/node_tfb.js|node_tfb"
)
cl(){ pkill -9 -f node_tfb 2>/dev/null; pkill -9 -f '\.dill' 2>/dev/null; for p in $(lsof -ti tcp:$PORT 2>/dev/null); do kill -9 $p 2>/dev/null; done; sleep 0.7; }
med(){ printf '%s\n' "$@"|sort -n|awk '{a[NR]=$1}END{print a[int((NR+1)/2)]}'; }
rssmb(){ pgrep -f "$1" 2>/dev/null|xargs -n1 ps -o rss= -p 2>/dev/null|awk '{s+=$1}END{printf "%.0f",s/1024}'; }
now(){ python3 -c 'import time;print(int(time.time()*1000))'; }
werr(){ local o="$1"; local n=$(echo "$o"|grep -oE 'Non-2xx or 3xx responses: [0-9]+'|grep -oE '[0-9]+$'); local s=$(echo "$o"|grep 'Socket errors'|grep -oE '[0-9]+'|awk '{t+=$1}END{print t+0}'); echo $(( ${n:-0} + ${s:-0} )); }
trap 'cl' EXIT

for cfg in $CONFIGS; do
  lbl=${cfg%%|*}; r1=${cfg#*|}; mode=${r1%%|*}; r2=${r1#*|}; cmd=${r2%%|*}; pat=${r2##*|}
  cl
  t0=$(now); eval "$cmd >$O/srv.log 2>&1 &"; spid=$!
  ok=0; for _ in $(seq 1 150); do curl -sf http://127.0.0.1:$PORT/json >/dev/null 2>&1 && { ok=1; break; }; sleep 0.1; done
  [ $ok -ne 1 ] && { echo "$lbl/$mode START FAIL"; kill -9 $spid 2>/dev/null; cl; continue; }
  startms=$(( $(now) - t0 )); idle=$(rssmb "$pat")
  wrk -t2 -c$CONN -d3s "http://127.0.0.1:$PORT/json" >/dev/null 2>&1   # warmup (JIT tiering)
  # /json throughput + CoV + latency + errors over ROUNDS
  jr=(); jp50=(); jp90=(); jp99=(); jerr=0
  for r in $(seq 1 $ROUNDS); do
    o=$(wrk -t2 -c$CONN -d${DUR}s --latency "http://127.0.0.1:$PORT/json" 2>/dev/null)
    jr+=($(echo "$o"|awk '/Requests\/sec/{print $2}')); jp50+=($(echo "$o"|awk '/^[[:space:]]*50%/{print $2}'))
    jp90+=($(echo "$o"|awk '/^[[:space:]]*90%/{print $2}')); jp99+=($(echo "$o"|awk '/^[[:space:]]*99%/{print $2}'))
    jerr=$(( jerr + $(werr "$o") ))
  done
  jrps=$(med $jr); jcov=$(echo "${jr[@]}"|awk '{for(i=1;i<=NF;i++){s+=$i;v[i]=$i}m=s/NF;for(i=1;i<=NF;i++)ss+=(v[i]-m)^2;printf "%.1f",100*sqrt(ss/NF)/m}')
  # /plaintext throughput + p99
  o=$(wrk -t2 -c$CONN -d${DUR}s --latency "http://127.0.0.1:$PORT/plaintext" 2>/dev/null)
  prps=$(echo "$o"|awk '/Requests\/sec/{print $2}'); pp99=$(echo "$o"|awk '/^[[:space:]]*99%/{print $2}')
  # open-loop CO-free distribution (median of ROUNDS)
  op50=(); op90=(); op99=(); op999=()
  if [ $OHA -eq 1 ]; then
    for r in $(seq 1 $ROUNDS); do
      oo=$(oha -q $RATE -c $CONN -z 10s --latency-correction --no-tui "http://127.0.0.1:$PORT/json" 2>/dev/null)
      g(){ echo "$oo"|awk -v p="$1" '$0 ~ p" in"{print $3}'; }
      op50+=($(g 50.00%)); op90+=($(g 90.00%)); op99+=($(g 99.00%)); op999+=($(g 99.90%))
    done
    ohap50=$(med $op50); ohap90=$(med $op90); ohap99=$(med $op99); ohap999=$(med $op999)
  else ohap50=na; ohap90=na; ohap99=na; ohap999=na; fi
  # overload -c256 and -c1024
  o=$(wrk -t4 -c256 -d${DUR}s --latency "http://127.0.0.1:$PORT/json" 2>/dev/null)
  o256r=$(echo "$o"|awk '/Requests\/sec/{print $2}'); o256p=$(echo "$o"|awk '/^[[:space:]]*99%/{print $2}'); o256e=$(werr "$o")
  o=$(wrk -t4 -c1024 -d${DUR}s --latency "http://127.0.0.1:$PORT/json" 2>/dev/null)
  o1kr=$(echo "$o"|awk '/Requests\/sec/{print $2}'); o1kp=$(echo "$o"|awk '/^[[:space:]]*99%/{print $2}'); o1ke=$(werr "$o")
  # CPU% + req/s per core + load RSS
  ( : >$O/cpu.txt; for _ in $(seq 1 12); do c=$(pgrep -f "$pat"|xargs -n1 ps -o %cpu= -p 2>/dev/null|awk '{t+=$1}END{print t}'); [ -n "$c" ]&&echo $c>>$O/cpu.txt; sleep 0.5; done ) & samp=$!
  o=$(wrk -t2 -c$CONN -d${DUR}s "http://127.0.0.1:$PORT/json" 2>/dev/null)
  load=$(rssmb "$pat"); wait $samp 2>/dev/null
  lrps=$(echo "$o"|awk '/Requests\/sec/{print $2}'); cpu=$(awk '{s+=$1;n++}END{if(n)printf "%.0f",s/n;else print 0}' $O/cpu.txt)
  percore=$(awk -v r="$lrps" -v c="$cpu" 'BEGIN{if(c>0)printf "%.0f",r/(c/100);else print 0}')
  echo "$lbl,$mode,$startms,$jrps,$jcov,$(med $jp50),$(med $jp90),$(med $jp99),$jerr,$prps,$pp99,$ohap50,$ohap90,$ohap99,$ohap999,$o256r,$o256p,$o256e,$o1kr,$o1kp,$o1ke,$cpu,$percore,$idle,$load">>$RES
  echo "  done $lbl/$mode: start=${startms}ms json=$jrps(CoV$jcov%) p99=$(med $jp99) oha_p99=$ohap99 ovl256=$o256r/$o256p ovl1k=$o1kr/$o1kp cpu=${cpu}%($percore/core) mem=$idle/$load MB err=$((jerr+o256e+o1ke))"
  kill -9 $spid 2>/dev/null; cl
done

C(){ awk -F, -v L="$1" -v M="$2" -v N="$3" '$1==L&&$2==M{print $N}' $RES; }  # label mode field
echo
echo "############ PRODUCTION SUITE — AOT vs JIT (/json unless noted, $CORES cores) ############"
echo "wrk -t2 -c$CONN -d${DUR}s x$ROUNDS | oha -q $RATE --latency-correction | overload wrk -t4"
dartrow(){ printf '%-10s | %13s | %13s\n' "$1" "$(C $1 AOT $2)" "$(C $1 JIT $2)"; }
sec(){ echo; echo "== $1 ==                               AOT             JIT"; for f in nitro dart:io shelf; do dartrow $f $2; done
  printf '%-10s | %13s | %13s\n' go "$(C go AOT $2)" "(n/a)"; printf '%-10s | %13s | %13s\n' node "(n/a)" "$(C node JIT $2)"; }
sec "Startup to 1st request (ms)" 3
sec "Throughput /json (req/s)" 4
sec "Stability CoV (%)" 5
sec "Closed-loop p50" 6
sec "Closed-loop p90" 7
sec "Closed-loop p99" 8
sec "Throughput /plaintext (req/s)" 10
sec "Open-loop p50 (ms)" 12
sec "Open-loop p99 (ms, CO-free)" 14
sec "Open-loop p99.9 (ms)" 15
sec "Overload -c256 req/s" 16
sec "Overload -c256 p99" 17
sec "Overload -c1024 req/s" 19
sec "Overload -c1024 p99" 20
sec "CPU req/s per core" 23
sec "Memory idle (MB)" 24
sec "Memory load (MB)" 25
echo
echo "errors (non-2xx + socket) across all runs per config:"
awk -F, 'NR>0{print "  "$1"/"$2": json="$9" ovl256="$18" ovl1024="$21}' $RES
echo
echo "=== CSV: name,mode,startms,jrps,jcov,jp50,jp90,jp99,jerr,prps,pp99,op50,op90,op99,op999,o256r,o256p,o256e,o1kr,o1kp,o1ke,cpu,percore,idleMB,loadMB ==="
cat $RES
echo "ALL DONE"
