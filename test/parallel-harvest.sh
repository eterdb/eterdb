#!/usr/bin/env bash
# Gap probe: does the own-locks harvest (EterGetMyPredicateLockTargets) capture
# read-dependencies acquired by PARALLEL WORKERS? At SERIALIZABLE the workers
# acquire SIREAD predicate locks into the LEADER's shared SERIALIZABLEXACT; the
# leader's PRE_COMMIT walk of its own predicateLocks list must therefore include
# them. We force a parallel plan over a tracked table, read it, write a row (to
# get an xid + a ww anchor), commit, and assert the read on the parallel-scanned
# table was captured as a dependency.
set -euo pipefail
cd "$(dirname "$0")/.."
PGB="${PGBUILD:-$PWD/.pgbuild18}/bin"
PGDATADIR="${PGDATADIR:-$PWD/.pgdata-observe18}"
PORT="${PGPORT:-5433}"
DB="postgres://eter@localhost:$PORT/eter"
PSQL(){ "$PGB/psql" "$DB" -tAc "$1"; }
ERRLOG="$(mktemp)"; trap 'rm -f "$ERRLOG"' EXIT
pass(){ echo "  ✓ $1"; }
fail(){ echo "  ✗ $1"; exit 1; }

"$PGB/psql" "$DB" -q -v ON_ERROR_STOP=1 -f ext/eter/eter.sql >/dev/null 2>&1
"$PGB/psql" "$DB" -q -c "DROP EXTENSION IF EXISTS eter_ssi; CREATE EXTENSION eter_ssi;" >/dev/null
"$PGB/psql" "$DB" -q -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
-- Probes read-dependency capture, not the write-capture substrate, so it uses
-- the trigger oracle for write-history. capture_mode='trigger' is the test-only
-- override (product default 'auto' = sidecar, which refuses without one).
SET eter.capture_mode='trigger';
TRUNCATE eter.history, eter.dependencies, eter.ssi_reads, eter.markers, eter.tracked;
DROP TABLE IF EXISTS public.big, public.sink CASCADE;
CREATE TABLE public.big  (id bigint PRIMARY KEY, v int);
CREATE TABLE public.sink (id bigint PRIMARY KEY, note text);
INSERT INTO public.big SELECT g, g FROM generate_series(1,200000) g;  -- big enough to go parallel
INSERT INTO public.sink VALUES (1,'seed');
SELECT eter.track('public.big');
SELECT eter.track('public.sink');
SQL

DBOID=$(PSQL "SELECT oid FROM pg_database WHERE datname=current_database()")
PSQL "TRUNCATE eter.ssi_reads, eter.dependencies, eter.history" >/dev/null
: > "$PGDATADIR/eter_ssi.$DBOID.wal" 2>/dev/null || true

# confirm the plan WOULD be parallel under these settings (diagnostic)
PLAN=$("$PGB/psql" "$DB" -tAc "SET max_parallel_workers_per_gather=4; SET parallel_setup_cost=0; SET parallel_tuple_cost=0; SET min_parallel_table_scan_size=0; SET enable_indexscan=off; SET enable_bitmapscan=off; EXPLAIN (FORMAT TEXT) SELECT count(*) FROM public.big WHERE v>0" 2>/dev/null)
echo "$PLAN" | grep -qi "Parallel" && pass "plan is parallel (workers do the scan)" || echo "  ⚠ planner did not parallelize, probe inconclusive"

# W: a separate txn updates big (so there is a writer row in history to match a read against)
W=$(PSQL "WITH u AS (UPDATE public.big SET v=v+1 WHERE id=777 RETURNING 1) SELECT txid_current() FROM u")

# R: SERIALIZABLE, force a parallel plan, read big (workers acquire SIREAD), then write sink.
# Capture R's xid as the first numeric line (txid_current before the scan).
R=$("$PGB/psql" "$DB" -tA 2>"$ERRLOG" <<'SQL' | grep -E '^[0-9]+$' | head -1
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT txid_current();
SET LOCAL max_parallel_workers_per_gather = 4;
SET LOCAL parallel_setup_cost = 0;
SET LOCAL parallel_tuple_cost = 0;
SET LOCAL min_parallel_table_scan_size = 0;
SET LOCAL enable_indexscan = off;
SET LOCAL enable_bitmapscan = off;
SELECT count(*) FROM public.big WHERE v > 0;
INSERT INTO public.sink VALUES (floor(random()*1e9)::bigint, 'decided-from-big');
COMMIT;
SQL
)

PSQL "SELECT eter.refresh_dependencies()" >/dev/null

# The read set is drained to eter.ssi_reads then derived into eter.dependencies
# and ssi_reads is truncated each cycle, so assert on the DERIVED edge, not ssi_reads.
EDGE=$(PSQL "SELECT count(*) FROM eter.dependencies WHERE txid=$R AND depends_on=$W AND kind='rw'")
echo "  writer W=$W  parallel reader R=$R  rw-edges(R→W)=$EDGE"
[ "${EDGE:-0}" -gt 0 ] && pass "parallel-plan read-dependency captured as an rw edge (own-locks walk saw the parallel-execution sxact locks)" \
                       || fail "parallel read-dependency NOT captured, harvest GAP"

echo "PARALLEL PROBE DONE"
