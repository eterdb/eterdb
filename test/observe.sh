#!/usr/bin/env bash
# EterDB Phase 2 OBSERVE MODE verification.
# Deliberately SINGLE-DB: gates an in-engine mechanism (observe-mode SSI capture in
# the tenant, topology-independent). The externalized two-DB path is proven by
# test/{meta-externalize,inventree-e2e,e2e,storage-pitr}.sh.
#
# Proves the headline novel claim: the EterDB-patched Postgres records SSI
# predicate-read dependencies under READ COMMITTED, with ZERO serialization
# failures and no change to visibility, so an undo is correctly classified
# `dependent` from a later transaction that only READ what it wrote, on a
# workload that runs at the default isolation level (no SERIALIZABLE required).
#
# Requires the patched Postgres (PG18) built into .pgbuild18 (see pg/README.md):
#   ./configure --prefix=$PWD/.pgbuild18 ... && make && make install   (in .pgsrc18, patched)
#   .pgbuild18/bin/initdb -D .pgdata-observe18 -U eter --auth=trust
#   .pgbuild18/bin/pg_ctl  -D .pgdata-observe18 -o "-p 5433" start
set -euo pipefail
cd "$(dirname "$0")/.."

PGB="${PGBUILD:-$PWD/.pgbuild18}/bin"
DATADIR="${PGDATADIR:-$PWD/.pgdata-observe18}"
PORT="${PGPORT:-5433}"
DB="${DATABASE_URL:-postgres://eter@localhost:$PORT/eter}"
[ -x "$PGB/psql" ] || { echo "patched Postgres not found at $PGB, see pg/README.md"; exit 1; }
PSQL(){ "$PGB/psql" "$DB" -tAc "$1"; }
pass(){ echo "  ✓ $1"; }
fail(){ echo "  ✗ $1"; exit 1; }

echo "==> build + install eter_ssi against the patched engine"
make -C ext/eter_ssi PG_CONFIG="$PGB/pg_config" clean >/dev/null 2>&1 || true
make -C ext/eter_ssi PG_CONFIG="$PGB/pg_config" install >/dev/null
pass "extension installed"

echo "==> engine + extension + observe mode"
PSQL "SELECT 1" >/dev/null || fail "patched cluster not reachable at $DB"
"$PGB/psql" "$DB" -q -v ON_ERROR_STOP=1 -f ext/eter/eter.sql
"$PGB/psql" "$DB" -q -c "DROP EXTENSION IF EXISTS eter_ssi; CREATE EXTENSION eter_ssi;" \
  -c "ALTER DATABASE $(PSQL 'SELECT current_database()') SET session_preload_libraries='eter_ssi';" \
  -c "ALTER DATABASE $(PSQL 'SELECT current_database()') SET eter_observe_mode=on;"
"$PGB/psql" "$DB" -q -v ON_ERROR_STOP=1 <<'SQL'
-- Tests observe-mode READ capture, not the write-capture substrate, so it uses
-- the trigger oracle for write-history. capture_mode='trigger' is the test-only
-- override (product default 'auto' = sidecar, which refuses without one).
SET eter.capture_mode='trigger';
TRUNCATE eter.history, eter.dependencies, eter.ssi_reads, eter.markers, eter.tracked;
DROP TABLE IF EXISTS public.orders, public.products CASCADE;
CREATE TABLE public.products (id bigint PRIMARY KEY, price_cents int);
CREATE TABLE public.orders   (id bigint PRIMARY KEY, product_id bigint, charged_cents int);
INSERT INTO public.products VALUES (1,10000),(2,5000);
SELECT eter.track('public.products');
SELECT eter.track('public.orders');
SQL
[ "$(PSQL 'SHOW eter_observe_mode')" = "on" ] || fail "observe mode not on"
[ "$(PSQL 'SHOW default_transaction_isolation')" = "read committed" ] || fail "expected READ COMMITTED"
pass "observe mode ON at READ COMMITTED (no SERIALIZABLE)"

: > "$DATADIR/eter_ssi.wal" 2>/dev/null || true

echo "==> W writes product 1; R (READ COMMITTED) reads it and writes an order"
W=$(PSQL "WITH u AS (UPDATE public.products SET price_cents=20000 WHERE id=1 RETURNING 1) SELECT txid_current() FROM u")
"$PGB/psql" "$DB" -q 2>obs_err.txt <<'SQL'
BEGIN;  -- default READ COMMITTED
SELECT price_cents FROM public.products WHERE id=1;
INSERT INTO public.orders VALUES (1,1,20000);
COMMIT;
SQL
SERR=$(grep -c 'could not serialize' obs_err.txt || true)
[ "$SERR" = "0" ] || fail "expected ZERO serialization failures, got $SERR"
pass "writer + reader committed at READ COMMITTED with 0 serialization failures"

echo "==> refresh persisted SSI graph (captured under READ COMMITTED)"
PSQL "SELECT eter.refresh_dependencies()" >/dev/null
EDGES=$(PSQL "SELECT count(*) FROM eter.dependencies WHERE depends_on=$W AND kind='rw'")
[ "$EDGES" -ge 1 ] || fail "no read-dependency edge captured under READ COMMITTED (got $EDGES)"
pass "captured $EDGES rw edge(s) under READ COMMITTED, stock Postgres records none here"

WW=$(PSQL "SELECT count(*) FROM eter._ww_conflicts($W)")
[ "$WW" = "0" ] || fail "expected 0 write-write conflicts, got $WW"
CLASS=$(PSQL "SELECT eter.preview_undo($W)->>'classification'")
[ "$CLASS" = "dependent" ] || fail "expected dependent, got $CLASS"
pass "preview_undo(W) = dependent via the read-edge (write-write alone = clean)"

echo "==> control: a write nobody read stays clean"
W2=$(PSQL "WITH u AS (UPDATE public.products SET price_cents=6000 WHERE id=2 RETURNING 1) SELECT txid_current() FROM u")
PSQL "SELECT eter.refresh_dependencies()" >/dev/null
[ "$(PSQL "SELECT eter.preview_undo($W2)->>'classification'")" = "clean" ] || fail "unread write should be clean"
pass "unread write classified clean (no false dependents)"

# ---------------------------------------------------------------------------
# PRECISION of an indexed read (issue #192 regression guard).
#
# The control above cannot catch this class: it creates its unread write AFTER
# the reader commits, so the derive's time-order guard (reader >= writer) drops
# the edge no matter how coarse the capture was. Here BOTH writes land BEFORE
# the read, so the only thing keeping the unread one clean is that the read was
# captured precisely.
#
# This is the shape issue #175 regressed and #192 fixed: an [Index Only] Scan
# takes its SIREAD lock on the INDEX, a page target with no row identity, and
# resolving that to "every write to this table" made a plain `WHERE id = $1`
# read implicate the table's entire write history. Note false-clean.sh cannot
# catch it either, being a RECALL gate: over-approximation only makes it greener.
# ---------------------------------------------------------------------------
echo "==> issue #192: an indexed read implicates ONLY the row it read"
: > "$DATADIR/eter_ssi.wal" 2>/dev/null || true
PSQL "SELECT eter.refresh_dependencies()" >/dev/null
WREAD=$(PSQL "WITH u AS (UPDATE public.products SET price_cents=31000 WHERE id=1 RETURNING 1) SELECT txid_current() FROM u")
WUNREAD=$(PSQL "WITH u AS (UPDATE public.products SET price_cents=32000 WHERE id=2 RETURNING 1) SELECT txid_current() FROM u")
R192=$("$PGB/psql" "$DB" -tAq <<SQL | tail -1
BEGIN;
SET LOCAL enable_seqscan=off; SET LOCAL enable_bitmapscan=off;  -- plain Index Scan
SELECT price_cents FROM public.products WHERE id=1;             -- reads ONLY id=1
INSERT INTO public.orders VALUES (192,1,31000);
SELECT txid_current();
COMMIT;
SQL
)
PSQL "SELECT eter.refresh_dependencies()" >/dev/null
GR=$(PSQL "SELECT detail->>'granularity' FROM eter.dependencies WHERE txid=$R192 AND depends_on=$WREAD AND kind='rw'")
[ "$GR" = "tuple" ] || fail "the read row's writer should be captured at TUPLE granularity, got '$GR'"
NCOARSE=$(PSQL "SELECT count(*) FROM eter.dependencies WHERE txid=$R192 AND depends_on=$WUNREAD AND kind='rw'")
[ "$NCOARSE" = "0" ] || fail "indexed read leaked onto an UNREAD write (issue #192 coarsening is back): $NCOARSE edge(s)"
[ "$(PSQL "SELECT eter.preview_undo($WUNREAD)->>'classification'")" = "clean" ] || fail "unread write must stay clean under an indexed read (issue #192)"
[ "$(PSQL "SELECT eter.preview_undo($WREAD)->>'classification'")" = "dependent" ] || fail "the read row's writer must be dependent"
pass "indexed read → tuple-precise edge to the row read, NO edge to the unread write (issue #192)"

echo "==> issue #192: an index scan that matched NOTHING still over-approximates (sound)"
: > "$DATADIR/eter_ssi.wal" 2>/dev/null || true
PSQL "SELECT eter.refresh_dependencies()" >/dev/null
WEMPTY=$(PSQL "WITH u AS (UPDATE public.products SET price_cents=33000 WHERE id=2 RETURNING 1) SELECT txid_current() FROM u")
REMPTY=$("$PGB/psql" "$DB" -tAq <<SQL | tail -1
BEGIN;
SET LOCAL enable_seqscan=off; SET LOCAL enable_bitmapscan=off;
SELECT price_cents FROM public.products WHERE id=999999;        -- matches NOTHING
INSERT INTO public.orders VALUES (193,1,0);
SELECT txid_current();
COMMIT;
SQL
)
PSQL "SELECT eter.refresh_dependencies()" >/dev/null
# The empty scan read no row we can name, so its predicate read is real and must
# stay surfaced coarsely. Suppression is driven by positive evidence of capture,
# never by absence of a signal, which is what keeps the harvest sound.
[ "$(PSQL "SELECT count(*) FROM eter.dependencies WHERE txid=$REMPTY AND depends_on=$WEMPTY AND kind='rw'")" -ge 1 ] \
  || fail "an empty index scan must still over-approximate (phantom read dropped)"
pass "empty index scan still surfaces the coarse relation edge (conservatism preserved)"

# ---------------------------------------------------------------------------
# Observe-precision lever 3: a SEQSCAN locks the whole relation (one relation-level
# predicate lock), not per-tuple, so by default it over-approximates to "every write
# to the table is a dependent." With eter_ssi.max_seqscan_capture raised (OPT-IN,
# default 0 = off, see eter_ssi.c), eter_seqscan_read captures each row the seqscan
# returns, so a read is captured per-ROW (granularity 'tuple') and the coarse
# relation line is suppressed when fully captured, falling back to the sound
# table-level relation edge above the cap.
# ---------------------------------------------------------------------------
echo "==> lever 3: an opt-in SEQSCAN read is captured PER-ROW (tuple), coarse suppressed"
: > "$DATADIR/eter_ssi.wal" 2>/dev/null || true
PSQL "SELECT eter.refresh_dependencies()" >/dev/null   # drain anything pending
W3=$(PSQL "WITH u AS (UPDATE public.products SET price_cents=21000 WHERE id=1 RETURNING 1) SELECT txid_current() FROM u")
R3=$("$PGB/psql" "$DB" -tAq <<'SQL' | tail -1
BEGIN;
SET LOCAL eter_ssi.max_seqscan_capture = 10000;        -- opt in to per-row capture
SET LOCAL enable_indexscan=off; SET LOCAL enable_bitmapscan=off; SET LOCAL enable_indexonlyscan=off;
SELECT sum(price_cents) FROM public.products;          -- seqscan over all rows
INSERT INTO public.orders VALUES (3,1,21000);
SELECT txid_current();
COMMIT;
SQL
)
PSQL "SELECT eter.refresh_dependencies()" >/dev/null
GR3=$(PSQL "SELECT detail->>'granularity' FROM eter.dependencies WHERE depends_on=$W3 AND txid=$R3 AND kind='rw'")
[ "$GR3" = "tuple" ] || fail "seqscan read should be captured per-row (tuple), got '$GR3'"
REL3=$(PSQL "SELECT count(*) FROM eter.dependencies WHERE txid=$R3 AND kind='rw' AND detail->>'granularity'='relation'")
[ "$REL3" = "0" ] || fail "coarse relation edge should be SUPPRESSED for a fully-captured seqscan, got $REL3"
pass "seqscan read captured per-row (tuple); coarse relation over-approx suppressed"

echo "==> lever 3: beyond the cap, capture falls back to SOUND coarse (relation)"
: > "$DATADIR/eter_ssi.wal" 2>/dev/null || true
W4=$(PSQL "WITH u AS (UPDATE public.products SET price_cents=22000 WHERE id=1 RETURNING 1) SELECT txid_current() FROM u")
R4=$("$PGB/psql" "$DB" -tAq <<'SQL' | tail -1
BEGIN;
SET LOCAL eter_ssi.max_seqscan_capture = 1;            -- cap below the 2-row table
SET LOCAL enable_indexscan=off; SET LOCAL enable_bitmapscan=off; SET LOCAL enable_indexonlyscan=off;
SELECT sum(price_cents) FROM public.products;          -- 2 rows > cap → overflow
INSERT INTO public.orders VALUES (4,1,22000);
SELECT txid_current();
COMMIT;
SQL
)
PSQL "SELECT eter.refresh_dependencies()" >/dev/null
GR4=$(PSQL "SELECT detail->>'granularity' FROM eter.dependencies WHERE depends_on=$W4 AND txid=$R4 AND kind='rw'")
[ "$GR4" = "relation" ] || fail "beyond cap, seqscan should fall back to coarse relation, got '$GR4'"
pass "cap exceeded → sound table-level over-approximation (relation)"

echo ""
echo "ALL PHASE 2 OBSERVE-MODE CHECKS PASSED ✅  (READ COMMITTED, zero 40001s)"
