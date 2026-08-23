#!/usr/bin/env bash
# Confound-free measurement of observe-mode READ overhead vs read concurrency.
#
# WHY THIS EXISTS. The standard perf harness (test/perf-overhead.sh) measures
# each config on its own fresh cluster, and always runs Observe Mode *last* of
# the five configs. On a laptop that opens two confounds for a surprising
# result (observe read overhead ~doubling from ~27% @16 clients to ~53% @100):
#   1. thermal drift, observe always runs on the hottest CPU state, and the
#      penalty would grow with client count (more heat);
#   2. fresh-cluster / config-ordering variance.
# This harness removes both. `eter_observe_mode` is PGC_USERSET, so we hold ONE
# warm cluster (never restarted) and flip the GUC per pgbench run via PGOPTIONS,
# INTERLEAVING off/on/off/on so any monotonic drift cancels out of the paired
# marginal. It also runs one reversed (on-first) pair per level: if the cost
# were just "observe ran later/hotter", reversing the order would collapse it.
# It doesn't, the reversed marginal matches the forward marginal, which is the
# proof the overhead is real SIREAD predicate-lock contention, not an artifact.
#
# NOTE ON THE MECHANISM CHECK (post issue #154): observe now captures the read
# set BACKEND-LOCALLY (no shared SERIALIZABLEXACT, no shared predicate-lock hash
# inserts), so SIREAD locks no longer appear in pg_locks - the mid-run snapshot
# below reads ~0 for BOTH observe on and off. That is expected and correct: the
# locks moved into the per-backend LocalPredicateLockHash. pg_locks is no longer a
# witness that observe fired; test/false-clean.sh (100% rw-edge recall) is.
#
# Result on M1 Pro / PG18.4 / -O2 (median of interleaved rounds), read-only -S:
#   16c 2.2%  ·  32c 1.7%  ·  64c 3.5%  ·  100c 3.3% - FLAT with concurrency.
#   Before issue #154 (shared SERIALIZABLEXACT register+teardown on the global
#   SerializableXactHashLock) this curve climbed 27%→53%; the decomposition
#   (test/observe-read-decompose.md) showed the commit-time teardown was ~2/3 of a
#   backend's wall-clock, and going backend-local removed it. See performance_report.md.
#
# Env: PATCHED_BIN DUR ROUNDS CLIENT_LEVELS PORT
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="${PATCHED_BIN:-$PWD/.pgbuild18-opt/bin}"
DATA="$PWD/test/read-ab-data"
PORT="${PORT:-5441}"
DB=eter_read_ab
DUR="${DUR:-15}"
ROUNDS="${ROUNDS:-4}"
CLIENT_LEVELS="${CLIENT_LEVELS:-16 32 64 100}"

if [ ! -x "$BIN/postgres" ]; then echo "no patched postgres at $BIN (build .pgbuild18-opt)"; exit 1; fi

cleanup(){ "$BIN/pg_ctl" -D "$DATA" -m immediate stop >/dev/null 2>&1 || true; rm -rf "$DATA"; }
trap cleanup EXIT

rm -rf "$DATA"; mkdir -p "$DATA"
"$BIN/initdb" -D "$DATA" -U eter --auth=trust >/dev/null
cat >> "$DATA/postgresql.conf" <<EOF
port = $PORT
listen_addresses = 'localhost'
unix_socket_directories = '/tmp'
shared_buffers = 128MB
max_connections = 250
max_pred_locks_per_transaction = 1024
shared_preload_libraries = 'eter_ssi'
eter_observe_mode = off
EOF
"$BIN/pg_ctl" -D "$DATA" -w -t 60 -l "$DATA/server.log" start >/dev/null
"$BIN/createdb" -p "$PORT" -U eter "$DB"
"$BIN/psql" -p "$PORT" -U eter -d "$DB" -q -f ext/eter/eter.sql >/dev/null 2>&1
"$BIN/psql" -p "$PORT" -U eter -d "$DB" -q -c "CREATE EXTENSION eter_ssi;" >/dev/null
"$BIN/pgbench" -i -s 10 -p "$PORT" -U eter "$DB" >/dev/null 2>&1

tps_of(){ grep -E 'tps = [0-9.]+' "$1" | head -1 | sed -E 's/.*tps = ([0-9.]+).*/\1/'; }
run(){ # mode clients -> tps (integrity-gated on zero aborts)
  local mode=$1 c=$2 t=$(( $2<10?$2:10 ))
  PGOPTIONS="-c eter_observe_mode=$mode" "$BIN/pgbench" -S -c "$c" -j "$t" -T "$DUR" \
     -p "$PORT" -U eter "$DB" > "$DATA/out" 2>&1
  grep -qE 'number of failed transactions: 0 ' "$DATA/out" || { echo "ABORTS in $mode/$c"; cat "$DATA/out"; exit 1; }
  tps_of "$DATA/out"
}

echo "# Confound-free observe READ A/B, one warm cluster, interleaved, PGOPTIONS toggle"
echo "# host $(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m), $("$BIN/postgres" --version | awk '{print $3}'), dur=${DUR}s rounds=$ROUNDS/level"
echo

# Post issue #154 this reads 0/0: observe locks are backend-local now, not in
# pg_locks. Kept as a regression tripwire - if observe-ON ever shows >0 here again,
# something re-introduced shared predicate locks on the read path.
echo "== mechanism check: SIReadLock entries during observe-ON -S vs observe-OFF =="
PGOPTIONS="-c eter_observe_mode=on" "$BIN/pgbench" -S -c 16 -j 8 -T 8 -p "$PORT" -U eter "$DB" >/dev/null 2>&1 &
BGP=$!; sleep 3
on_locks=$("$BIN/psql" -p "$PORT" -U eter -d "$DB" -tAc "SELECT count(*) FROM pg_locks WHERE mode='SIReadLock'")
wait $BGP 2>/dev/null || true
PGOPTIONS="-c eter_observe_mode=off" "$BIN/pgbench" -S -c 16 -j 8 -T 8 -p "$PORT" -U eter "$DB" >/dev/null 2>&1 &
BGP=$!; sleep 3
off_locks=$("$BIN/psql" -p "$PORT" -U eter -d "$DB" -tAc "SELECT count(*) FROM pg_locks WHERE mode='SIReadLock'")
wait $BGP 2>/dev/null || true
echo "  SIReadLock rows mid-run:  observe-ON=$on_locks   observe-OFF=$off_locks"
echo "  (ON>>0 = predicate locks really acquired on reads; OFF~0)"
echo

for c in $CLIENT_LEVELS; do
  echo "== $c clients =="
  offs=(); ons=()
  run off "$c" >/dev/null                     # warm this level
  for r in $(seq 1 "$ROUNDS"); do
    o=$(run off "$c"); n=$(run on "$c")        # OFF then ON, tightly paired
    printf "  round %d: off=%-12s on=%-12s marginal=%s%%\n" "$r" "$o" "$n" \
      "$(awk -v a="$o" -v b="$n" 'BEGIN{printf "%.1f",(a-b)/a*100}')"
    offs+=("$o"); ons+=("$n")
  done
  n2=$(run on "$c"); o2=$(run off "$c")         # reversed (on-first) control
  printf "  reversed (on-first): on=%-12s off=%-12s marginal=%s%%\n" "$n2" "$o2" \
    "$(awk -v a="$o2" -v b="$n2" 'BEGIN{printf "%.1f",(a-b)/a*100}')"
  offm=$(printf '%s\n' "${offs[@]}" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')
  onm=$(printf '%s\n' "${ons[@]}"  | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')
  echo "  --> median off=$offm on=$onm  MARGINAL=$(awk -v a="$offm" -v b="$onm" 'BEGIN{printf "%.1f%%",(a-b)/a*100}')"
  echo
done
echo "DONE"
