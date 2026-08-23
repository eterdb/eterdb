#!/usr/bin/env bash
# EterDB Phase 3, observe-mode COMPLETENESS gate: the false-clean harness.
# Deliberately SINGLE-DB: gates the in-engine SSI capture/derive recall mechanism
# (topology-independent). The externalized two-DB path is proven by
# test/{meta-externalize,inventree-e2e,e2e,storage-pitr}.sh.
#
# The assertion suites (isolation 117/117, regress 220/220) prove the patched
# engine's stock SSI paths are unbroken. They do NOT prove the observe-mode
# read-dependency graph is COMPLETE. A single missed read-dependency is a
# false-clean, observe mode reporting a write `clean` (safe to revert) when a
# later transaction actually read it, i.e. a silent corruption. This harness
# hunts those: randomized concurrent read-then-write workloads on the patched
# engine, compared against a version-stamped ground-truth oracle, asserting full
# rw-edge recall. See test/false-clean/harness.mjs for the oracle's design and
# its plainly-stated scope.
#
# Runs entirely local on the patched --enable-cassert cluster (.pgbuild18 +
# .pgdata-observe18), no Docker, no ZFS. Brings the cluster up if it isn't
# already, and leaves a cluster it started stopped on exit.
set -euo pipefail
cd "$(dirname "$0")/.."

PGB="${PGBUILD:-$PWD/.pgbuild18}/bin"
PORT="${PGPORT:-5433}"
DATADIR="${PGDATADIR:-$PWD/.pgdata-observe18}"
DB="${DATABASE_URL:-postgres://eter@localhost:$PORT/eter}"
STARTED_CLUSTER=0

[ -x "$PGB/postgres" ] || { echo "patched Postgres not found at $PGB, see pg/README.md"; exit 1; }
[ -f "$DATADIR/PG_VERSION" ] || { echo "patched datadir $DATADIR not initialised, see pg/README.md"; exit 1; }

PSQL(){ "$PGB/psql" "$DB" -tAc "$1"; }
pass(){ echo "  ✓ $1"; }
fail(){ echo "  ✗ $1"; exit 1; }

cleanup(){
  if [ "$STARTED_CLUSTER" = "1" ]; then
    "$PGB/pg_ctl" -D "$DATADIR" stop -m fast >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "==> patched cluster up on :$PORT"
if ! "$PGB/pg_isready" -p "$PORT" >/dev/null 2>&1; then
  "$PGB/pg_ctl" -D "$DATADIR" -o "-p $PORT" -l "$DATADIR/server.log" start >/dev/null
  STARTED_CLUSTER=1
  for i in $(seq 1 30); do "$PGB/pg_isready" -p "$PORT" >/dev/null 2>&1 && break; sleep 0.3; done
fi
"$PGB/pg_isready" -p "$PORT" >/dev/null 2>&1 || fail "patched cluster did not come up on :$PORT"
"$PGB/createdb" -p "$PORT" -U eter eter >/dev/null 2>&1 || true
pass "cluster reachable ($([ "$STARTED_CLUSTER" = 1 ] && echo 'started by harness' || echo 'already running'))"

echo "==> build + install eter_ssi against the patched engine"
make -C ext/eter_ssi PG_CONFIG="$PGB/pg_config" clean >/dev/null 2>&1 || true
make -C ext/eter_ssi PG_CONFIG="$PGB/pg_config" install >/dev/null
pass "eter_ssi installed"

echo "==> engine + extension + observe mode"
PSQL "SELECT 1" >/dev/null || fail "patched cluster not reachable at $DB"
"$PGB/psql" "$DB" -q -v ON_ERROR_STOP=1 -f ext/eter/eter.sql
"$PGB/psql" "$DB" -q -v ON_ERROR_STOP=1 \
  -c "DROP EXTENSION IF EXISTS eter_ssi; CREATE EXTENSION eter_ssi;" \
  -c "ALTER DATABASE $(PSQL 'SELECT current_database()') SET session_preload_libraries='eter_ssi';" \
  -c "ALTER DATABASE $(PSQL 'SELECT current_database()') SET eter_observe_mode=on;" \
  -c "ALTER DATABASE $(PSQL 'SELECT current_database()') SET eter.capture_mode='trigger';"
[ "$(PSQL 'SHOW eter_observe_mode')" = "on" ] || fail "observe mode not on"
pass "observe mode ON at READ COMMITTED"

# fresh SSI-WAL: the PRE_COMMIT hook appends here; drain truncates it.
: > "$DATADIR/eter_ssi.wal" 2>/dev/null || true

echo "==> hunting false-cleans (randomized rounds + deterministic fixtures)"
DATABASE_URL="$DB" node test/false-clean/harness.mjs

echo ""
echo "FALSE-CLEAN GATE PASSED ✅"
