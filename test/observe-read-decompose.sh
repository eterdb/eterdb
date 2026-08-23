#!/usr/bin/env bash
# Issue #154, Step 0 - decompose the observe-mode READ cost empirically.
#
# WHY. test/performance_report.md establishes that observe-mode read overhead
# scales with concurrency (~26% @16 clients → ~51% @100), and that it is pure
# SIREAD predicate-lock work (read-only -S txns skip the commit-time harvest).
# But "SIREAD work" is two distinct shared-memory costs, and the right fix
# depends on which one dominates:
#
#   1. per-TXN registration/teardown - EterMaybeRegisterObserveXact →
#      GetSerializableTransactionSnapshotInt takes SerializableXactHashLock
#      EXCLUSIVE, and ReleasePredicateLocks takes it again at commit. If this
#      dominates, a much smaller patch (lightweight observe registration, no
#      shared sxact) captures most of the win first.
#   2. per-READ predicate-lock hash inserts - each PredicateLockAcquire (from
#      PredicateLockTID) takes one of 16 PredicateLockManager partition locks +
#      SerializablePredicateList and inserts into two shared hashes. If this
#      dominates, only full backend-local capture (skip the shared inserts) helps.
#
# INSTRUMENT. The overhead is CPU burned in these code paths (atomics /
# cache-line bouncing / spin, plus the extra work itself), NOT backends parking
# on contended locks: the -S workload is latency-bound (sub-ms txns, backends
# mostly idle between statements), so 20 Hz pg_stat_activity.wait_event sampling
# catches ~nothing - the LWLock episodes are microseconds. So we CPU-profile a
# busy backend with Apple `sample` and attribute *inclusive* samples to each SSI
# entrypoint. observe-ON vs observe-OFF isolates the delta; ON−OFF split across
# registration (item 1) vs read-acquire (item 2) is the answer Step 0 wants.
#
# Env: PATCHED_BIN DUR CLIENTS PORT PROF_SECS
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="${PATCHED_BIN:-$PWD/.pgbuild18-opt/bin}"
DATA="$PWD/test/read-decompose-data"
PORT="${PORT:-5442}"
DB=eter_read_decompose
DUR="${DUR:-30}"
CLIENTS="${CLIENTS:-100}"
PROF_SECS="${PROF_SECS:-18}"

if [ ! -x "$BIN/postgres" ]; then echo "no patched postgres at $BIN (build .pgbuild18-opt)"; exit 1; fi
command -v sample >/dev/null || { echo "Apple 'sample' profiler not found (macOS only)"; exit 1; }

cleanup(){ "$BIN/pg_ctl" -D "$DATA" -m immediate stop >/dev/null 2>&1 || true; rm -rf "$DATA"; }
trap cleanup EXIT

echo "==> build + install eter_ssi against the -O2 engine ($BIN)"
make -C ext/eter_ssi PG_CONFIG="$BIN/pg_config" clean >/dev/null 2>&1 || true
make -C ext/eter_ssi PG_CONFIG="$BIN/pg_config" install >/dev/null

rm -rf "$DATA"; mkdir -p "$DATA"
"$BIN/initdb" -D "$DATA" -U eter --auth=trust >/dev/null
cat >> "$DATA/postgresql.conf" <<EOF
port = $PORT
listen_addresses = 'localhost'
unix_socket_directories = '/tmp'
shared_buffers = 128MB
max_connections = 300
max_pred_locks_per_transaction = 1024
shared_preload_libraries = 'eter_ssi'
eter_observe_mode = off
EOF
"$BIN/pg_ctl" -D "$DATA" -w -t 60 -l "$DATA/server.log" start >/dev/null
"$BIN/createdb" -p "$PORT" -U eter "$DB"
"$BIN/psql" -p "$PORT" -U eter -d "$DB" -q -f ext/eter/eter.sql >/dev/null 2>&1
"$BIN/psql" -p "$PORT" -U eter -d "$DB" -q -c "CREATE EXTENSION eter_ssi;" >/dev/null
"$BIN/pgbench" -i -s 10 -p "$PORT" -U eter "$DB" >/dev/null 2>&1

PMPID=$(head -1 "$DATA/postmaster.pid")

# Pick the busiest live client backend (all run the same -S loop, so one is
# representative): the postmaster child with the highest %cpu.
busiest_backend(){
  pgrep -P "$PMPID" 2>/dev/null | while read -r p; do
    c=$(ps -o %cpu= -p "$p" 2>/dev/null | tr -d ' '); echo "${c:-0} $p";
  done | sort -rn | head -1 | awk '{print $2}'
}

# The SSI entrypoints we attribute inclusive samples to.
REG='GetSerializableTransactionSnapshotInt'   # item 1: per-txn registration
TEARDOWN='ReleasePredicateLocks'              # item 1: per-txn teardown at commit
ACQTID='PredicateLockTID'                     # item 2: per-read acquire entrypoint
ACQ='PredicateLockAcquire'                    # item 2: the hash insert itself
COUT='HeapCheckForSerializableConflictOut'    # read-path conflict check
SSI_ANY='eter_ssi'                            # the extension capture (should be ~0 on read-only)

incl(){ # symbol file -> max inclusive samples for that frame (0 if absent)
  # `sample` prints "<count> <Symbol>  (in ...)" but the count sits AFTER the
  # tree-drawing prefix ("+ ! : |"), not at line start - grab the integer that
  # immediately precedes the symbol name and take the largest (the top node).
  grep -oE "[0-9]+ +$1( |\()" "$2" 2>/dev/null | grep -oE '^[0-9]+' | sort -rn | head -1 || true
}

profile(){ # mode -> writes $DATA/prof.$mode (+ prof.$mode.cg = Call graph section only)
  local mode=$1 t=$(( CLIENTS<10?CLIENTS:10 ))
  PGOPTIONS="-c eter_observe_mode=$mode" "$BIN/pgbench" -S -c "$CLIENTS" -j "$t" -T "$DUR" \
     -p "$PORT" -U eter "$DB" > "$DATA/out.$mode" 2>&1 &
  local bgp=$!
  sleep 5                                     # warmup, let backends spin up
  local pid; pid=$(busiest_backend)
  [ -n "$pid" ] || { echo "no backend to profile"; wait $bgp; return 1; }
  sample "$pid" "$PROF_SECS" -mayDie -file "$DATA/prof.$mode" >/dev/null 2>&1 || true
  wait $bgp 2>/dev/null || true
  # Isolate the "Call graph:" section (inclusive tree). The later
  # "Total number in stack (recursive counted multiple)" section double-counts
  # frames and must NOT feed inclusive/total math.
  awk '/^Call graph:/{g=1} /^Total number in stack/{g=0} g' \
    "$DATA/prof.$mode" > "$DATA/prof.$mode.cg"
}

echo "# Observe READ cost decomposition - CPU profile attribution under -S"
echo "# host $(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m), PG $("$BIN/postgres" --version | awk '{print $3}'), clients=$CLIENTS dur=${DUR}s prof=${PROF_SECS}s"
echo

for mode in on off; do
  profile "$mode"
  tps=$(grep -E 'tps = [0-9.]+' "$DATA/out.$mode" | head -1 | sed -E 's/.*tps = ([0-9.]+).*/\1/')
  # total samples = the Call graph root frame (the largest count in that section).
  total=$(incl 'Thread_[0-9]+' "$DATA/prof.$mode.cg")
  total=${total:-1}
  # leaf self-time parked in the kernel semaphore (an LWLock the backend blocks on)
  semop=$(awk '/Sort by top of stack/{f=1} f&&/ semop /{print $NF; exit}' "$DATA/prof.$mode")
  semop=${semop:-0}
  printf "== observe %s  (tps=%s, profiled %s samples) ==\n" "$mode" "$tps" "$total"
  for pair in "registration(item1):$REG" "teardown(item1):$TEARDOWN" \
              "PredicateLockTID(item2):$ACQTID" "PredicateLockAcquire(item2):$ACQ" \
              "conflictOut-read:$COUT" "eter_ssi-capture:$SSI_ANY"; do
    label=${pair%%:*}; sym=${pair##*:}
    n=$(incl "$sym" "$DATA/prof.$mode.cg"); n=${n:-0}
    printf "   %-26s %8s  %6s\n" "$label" "$n" \
      "$(awk -v a="$n" -v b="$total" 'BEGIN{printf "%.1f%%", (b?100*a/b:0)}')"
  done
  printf "   %-26s %8s  %6s   (backend parked on a contended LWLock)\n" "leaf: semop (kernel wait)" "$semop" \
    "$(awk -v a="$semop" -v b="$total" 'BEGIN{printf "%.1f%%", (b?100*a/b:0)}')"
  echo
done

cp -f "$DATA/prof.on" test/read-decompose-prof.on.txt 2>/dev/null || true
cp -f "$DATA/prof.off" test/read-decompose-prof.off.txt 2>/dev/null || true

echo "== interpretation =="
echo "  The observe-ON minus observe-OFF delta in each row is that path's marginal CPU."
echo "  registration+teardown dominant -> lightweight-registration patch wins most first."
echo "  PredicateLockTID/Acquire dominant -> need full backend-local capture (skip shared inserts)."
echo "  Full call-tree reports preserved: test/read-decompose-prof.{on,off}.txt"
echo "DONE"
