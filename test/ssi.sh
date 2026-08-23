#!/usr/bin/env bash
# EterDB Phase 2 (strict mode) verification: real SSI read-dependency capture.
# Deliberately SINGLE-DB: this gates an in-engine mechanism (SSI capture is always
# in the tenant, independent of topology). The externalized two-DB path is proven
# by test/{meta-externalize,inventree-e2e,e2e,storage-pitr}.sh.
#
# Proves the differentiated claim: a later transaction that only READ what the
# target wrote (no write-write overlap) is correctly detected as a dependency via
# Postgres's native SSI predicate locks, something write-write analysis and any
# CDC/proxy cannot see.
#
# Runs on the patched engine (.pgbuild18 + .pgdata-observe18), the shipping substrate;
# strict mode works there with observe mode OFF (the patch is dormant, the isolation
# suite proves stock serializability is unchanged). No stock-PG shortcut. Brings the
# cluster up if it isn't already, and leaves a cluster it started stopped on exit.
# Override PGPORT / PG_CONFIG / DATABASE_URL only to point at another patched build.
set -euo pipefail
cd "$(dirname "$0")/.."

PGB="${PGBUILD:-$PWD/.pgbuild18}/bin"
PORT="${PGPORT:-5433}"
DATADIR="${PGDATADIR:-$PWD/.pgdata-observe18}"
DBURL="${DATABASE_URL:-postgres://eter@localhost:$PORT/eter}"
PG_CONFIG="${PG_CONFIG:-$PGB/pg_config}"
STARTED_CLUSTER=0
[ -x "$PGB/postgres" ] || { echo "patched Postgres not found at $PGB, see pg/README.md"; exit 1; }
[ -f "$DATADIR/PG_VERSION" ] || { echo "patched datadir $DATADIR not initialised, see pg/README.md"; exit 1; }
PSQL="$PGB/psql $DBURL -tAc"

pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; exit 1; }
jq_class() { node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{const o=JSON.parse(s);process.stdout.write(o[process.argv[1]]===undefined?"":JSON.stringify(o[process.argv[1]]))})' "$1"; }

cleanup() {
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
make -C ext/eter_ssi PG_CONFIG="$PG_CONFIG" install >/dev/null
pass "extension installed"

echo "==> reset engine + extension (strict mode → observe mode OFF)"
$PSQL "SELECT 1" >/dev/null || fail "Postgres not reachable at $DBURL"
"$PGB/psql" "$DBURL" -q -v ON_ERROR_STOP=1 -f ext/eter/eter.sql
"$PGB/psql" "$DBURL" -q -c "DROP EXTENSION IF EXISTS eter_ssi; CREATE EXTENSION eter_ssi;" \
                 -c "ALTER DATABASE $($PSQL 'SELECT current_database()') SET session_preload_libraries='eter_ssi';" \
                 -c "ALTER DATABASE $($PSQL 'SELECT current_database()') SET eter_observe_mode=off;"
"$PGB/psql" "$DBURL" -q -v ON_ERROR_STOP=1 <<'SQL'
-- This suite tests SSI read-dependency capture, not the capture substrate, so it
-- uses the in-DB trigger oracle for write-history rather than standing up a
-- capture sidecar. capture_mode='trigger' is the test-only override (the product
-- default is 'auto' = sidecar, which refuses without a running sidecar).
SET eter.capture_mode='trigger';
TRUNCATE eter.history, eter.dependencies, eter.ssi_reads, eter.markers, eter.tracked;
DROP TABLE IF EXISTS public.orders, public.products CASCADE;
CREATE TABLE public.products (id bigint PRIMARY KEY, price_cents int);
CREATE TABLE public.orders   (id bigint PRIMARY KEY, product_id bigint, charged_cents int);
INSERT INTO public.products VALUES (1, 10000), (2, 5000);
SELECT eter.track('public.products');
SELECT eter.track('public.orders');
SQL
pass "schema tracked"

echo "==> scenario: W writes product 1; R (SERIALIZABLE) reads it and writes an order"
W=$($PSQL "WITH u AS (UPDATE public.products SET price_cents=20000 WHERE id=1 RETURNING 1) SELECT txid_current() FROM u")
"$PGB/psql" "$DBURL" -q <<SQL
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT price_cents FROM public.products WHERE id=1;
INSERT INTO public.orders VALUES (1, 1, 20000);
COMMIT;
SQL
pass "writer txid=$W committed; serializable reader committed"

echo "==> refresh persisted SSI graph"
$PSQL "SELECT eter.refresh_dependencies()" >/dev/null
EDGES=$($PSQL "SELECT count(*) FROM eter.dependencies WHERE depends_on=$W AND kind='rw'")
[ "$EDGES" -ge 1 ] || fail "expected a read-dependency edge on W=$W, got $EDGES"
pass "captured $EDGES read-write dependency edge(s) from native SSI"

echo "==> control: write-write analysis alone sees no conflict"
WW=$($PSQL "SELECT count(*) FROM eter._ww_conflicts($W)")
[ "$WW" = "0" ] || fail "expected 0 write-write conflicts (no later write to products), got $WW"
pass "write-write conflicts = 0 (a CDC/proxy would call this a clean undo)"

echo "==> preview_undo(W) must be DEPENDENT via the read-edge"
PLAN=$($PSQL "SELECT eter.preview_undo($W)")
CLASS=$(echo "$PLAN" | jq_class classification | tr -d '"')
[ "$CLASS" = "dependent" ] || fail "expected dependent classification, got $CLASS"
echo "$PLAN" | node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{const o=JSON.parse(s);const e=o.conflict_edges||[];if(!e.some(x=>x.kinds.includes("rw")))process.exit(1)})' \
  || fail "expected an rw conflict edge in the plan"
pass "preview = dependent, driven by the SSI read-dependency (write-write would have said clean)"

echo "==> clean control: a write nobody read stays clean"
W2=$($PSQL "WITH u AS (UPDATE public.products SET price_cents=6000 WHERE id=2 RETURNING 1) SELECT txid_current() FROM u")
$PSQL "SELECT eter.refresh_dependencies()" >/dev/null
CLASS2=$($PSQL "SELECT eter.preview_undo($W2)->>'classification'")
[ "$CLASS2" = "clean" ] || fail "expected clean for an unread write, got $CLASS2"
pass "unread write classified clean (no false dependents)"

echo "==> sidecar-mode: a write captured WITHOUT a ctid (history.tid NULL) still"
echo "    yields the read-edge, matched by PK (eter.resolve_pk), not ctid"
$PSQL "INSERT INTO public.products VALUES (3, 3000)" >/dev/null
W3=$($PSQL "WITH u AS (UPDATE public.products SET price_cents=3500 WHERE id=3 RETURNING 1) SELECT txid_current() FROM u")
# Simulate logical-decoding capture: drop the ctid the trigger recorded, so the
# only way to match this write to a read is primary-key resolution.
$PSQL "UPDATE eter.history SET tid=NULL WHERE txid=$W3"
[ "$($PSQL "SELECT count(*) FROM eter.history WHERE txid=$W3 AND tid IS NOT NULL")" = "0" ] || fail "tid not cleared"
"$PGB/psql" "$DBURL" -q >/dev/null <<SQL
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT price_cents FROM public.products WHERE id=3;
INSERT INTO public.orders VALUES (3, 3, 3500);
COMMIT;
SQL
$PSQL "SELECT eter.refresh_dependencies()" >/dev/null
EDGES3=$($PSQL "SELECT count(*) FROM eter.dependencies WHERE depends_on=$W3 AND kind='rw'")
[ "$EDGES3" -ge 1 ] || fail "no rw edge for a ctid-less (sidecar) write, PK resolution failed"
[ "$($PSQL "SELECT eter.preview_undo($W3)->>'classification'")" = "dependent" ] || fail "ctid-less write should be dependent via PK edge"
pass "rw edge derived for a ctid-less write via PK resolution; preview = dependent"

echo ""
echo "ALL PHASE 2 (STRICT-MODE SSI) CHECKS PASSED ✅"
