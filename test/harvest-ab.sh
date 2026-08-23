#!/usr/bin/env bash
# A/B the commit-time SSI read-set harvest: OLD global-walk
# (GetPredicateLockStatusData over the whole cluster + 17 locks) vs NEW own-locks
# walk (EterGetMyPredicateLockTargets over MySerializableXact->predicateLocks).
#
# Same -O2 patched engine binary and same cluster, only the eter_ssi dylib is
# swapped between variants, so any TPS delta is the harvest change alone (no
# machine-variance confound from comparing against earlier recorded runs).
# Observe mode ON (READ COMMITTED): every commit harvests its read set.
set -euo pipefail
cd "$(dirname "$0")/.."

PGB="$PWD/.pgbuild18-opt/bin"
PORT="${PORT:-5440}"
DATA="$PWD/.pgdata-harvest-ab"
DB=eter
DUR="${DUR:-15}"
TRIALS="${TRIALS:-3}"
SCALE="${SCALE:-10}"
THREADS="${THREADS:-8}"
CLIENT_POINTS="${CLIENT_POINTS:-16 64 128}"
NEW_DYLIB=/tmp/eter_ssi_new.dylib
OLD_DYLIB=/tmp/eter_ssi_old.dylib
DEST="$($PGB/pg_config --pkglibdir)/eter_ssi.dylib"

[ -f "$NEW_DYLIB" ] && [ -f "$OLD_DYLIB" ] || { echo "build /tmp/eter_ssi_{new,old}.dylib first"; exit 1; }

"$PGB/pg_ctl" -D "$DATA" -m immediate stop >/dev/null 2>&1 || true
rm -rf "$DATA"
"$PGB/initdb" -D "$DATA" -U eter --auth=trust >/dev/null
cat >> "$DATA/postgresql.conf" <<EOF
port = $PORT
shared_buffers = 512MB
max_connections = 400
max_pred_locks_per_transaction = 4096
fsync = off
synchronous_commit = off
session_preload_libraries = 'eter_ssi'
eter_observe_mode = on
EOF
"$PGB/pg_ctl" -D "$DATA" -l "$DATA/server.log" start >/dev/null
for i in $(seq 1 30); do "$PGB/pg_isready" -p "$PORT" >/dev/null 2>&1 && break; sleep 0.3; done

"$PGB/psql" -p "$PORT" -U eter -d postgres -tAc "CREATE DATABASE $DB" >/dev/null 2>&1 || true
"$PGB/psql" -p "$PORT" -U eter -d "$DB" -q -f ext/eter/eter.sql >/dev/null 2>&1
"$PGB/psql" -p "$PORT" -U eter -d "$DB" -q -c "DROP EXTENSION IF EXISTS eter_ssi; CREATE EXTENSION eter_ssi;" >/dev/null
"$PGB/pgbench" -i -s "$SCALE" -p "$PORT" -U eter "$DB" >/dev/null 2>&1
echo "init done: scale=$SCALE dur=${DUR}s trials=$TRIALS threads=$THREADS  points=[$CLIENT_POINTS]"
echo

median() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2}'; }

run_variant() {
  local name=$1 dylib=$2 flag=$3 clients=$4
  cp "$dylib" "$DEST"
  "$PGB/pg_ctl" -D "$DATA" -m fast restart >/dev/null 2>&1
  for i in $(seq 1 30); do "$PGB/pg_isready" -p "$PORT" >/dev/null 2>&1 && break; sleep 0.3; done
  "$PGB/pgbench" $flag -c "$clients" -j "$THREADS" -T 3 -p "$PORT" -U eter "$DB" >/dev/null 2>&1  # warmup
  local tps=() ab
  for t in $(seq 1 "$TRIALS"); do
    local out
    out=$("$PGB/pgbench" $flag -c "$clients" -j "$THREADS" -T "$DUR" -p "$PORT" -U eter "$DB" 2>&1)
    ab=$(echo "$out" | grep -c "could not serialize\|deadlock\|ERROR" || true)
    [ "$ab" != 0 ] && { echo "  $name c=$clients: ABORTS=$ab, rejected"; return 1; }
    tps+=("$(echo "$out" | awk '/tps =/{print $3; exit}')")
  done
  median "${tps[@]}"
}

for wl in "tpcb:" "select:-S"; do
  name="${wl%%:*}"; flag="${wl##*:}"
  echo "### workload=$name"
  printf "%-8s %12s %12s %10s\n" clients old_tps new_tps gain
  for c in $CLIENT_POINTS; do
    o=$(run_variant OLD "$OLD_DYLIB" "$flag" "$c") || continue
    n=$(run_variant NEW "$NEW_DYLIB" "$flag" "$c") || continue
    g=$(awk -v o="$o" -v n="$n" 'BEGIN{printf "%+.1f%%", (n-o)/o*100}')
    printf "%-8s %12.0f %12.0f %10s\n" "$c" "$o" "$n" "$g"
  done
  echo
done

"$PGB/pg_ctl" -D "$DATA" -m fast stop >/dev/null 2>&1 || true
echo "A/B DONE"
