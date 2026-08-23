#!/usr/bin/env bash
# EterDB, observe-precision surfacing test (local, no Docker, no ZFS, NO patch).
#
# Gates observe-mode lever (2): "flag tables seqscanned by writers → undo is coarse
# here." Observe captures EVERY read-write transaction's reads and Postgres coarsens
# SIREAD locks tuple→page→relation, so a writer that SEQSCANS a table produces a
# relation-level (table-wide) rw over-approximation: sound (never a missed
# dependency) but coarse. This test proves the engine now SURFACES that coarseness
# instead of hiding it, a precise tuple-match dependent is labelled 'exact', a
# seqscan over-approximation is labelled 'over-approx', and eter.coarse_dependencies()
# reports the seqscanned tables as the "add an index here" product surface.
#
# Deliberately exercises the BASE-ENGINE store derive (eter.derive_from_read_set
# + preview_undo + coarse_dependencies) on a plain Homebrew PG18: we seed the
# forwarded read-set / history / tracked directly, so no logical decoding, no
# eter_ssi extension, and no observe patch are needed (the extension derive
# mirrors this code path and is re-validated by ssi.sh / observe.sh / false-clean.sh).
# Throwaway cluster on its own port/datadir, torn down on exit.
set -euo pipefail
cd "$(dirname "$0")/.."

PGBIN="${PGBIN:-/opt/homebrew/opt/postgresql@18/bin}"
PGPORT="${ETER_TEST_PORT:-5440}"
PGDATA="$PWD/.pgdata-precision"
DBURL="postgres://eter:eter@localhost:$PGPORT/eter"
PSQL="$PGBIN/psql $DBURL -tAqc"
go build -C cli -o eter . || { echo "go build of the eter CLI failed (need Go installed)"; exit 1; }
ETER="$PWD/cli/eter --db $DBURL"

pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; exit 1; }
jget() { node -e 'const o=JSON.parse(require("fs").readFileSync(0,"utf8"));let v=o;for(const k of process.argv[1].split("."))v=v[k];process.stdout.write(JSON.stringify(v))' "$1"; }

cleanup() {
  "$PGBIN/pg_ctl" -D "$PGDATA" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$PGDATA"
}
trap cleanup EXIT

echo "==> spinning up throwaway cluster on :$PGPORT"
rm -rf "$PGDATA"
"$PGBIN/initdb" -D "$PGDATA" -U eter --auth-local=trust --auth-host=trust >/dev/null
cat >>"$PGDATA/postgresql.conf" <<EOF
port = $PGPORT
listen_addresses = 'localhost'
EOF
"$PGBIN/pg_ctl" -D "$PGDATA" -l "$PGDATA/server.log" -w start >/dev/null
"$PGBIN/createdb" -h localhost -p "$PGPORT" -U eter eter
"$PGBIN/psql" "$DBURL" -q -f ext/eter/eter.sql >/dev/null
pass "cluster up + engine applied"

# ---------------------------------------------------------------------------
# Seed the writer-side history (the rows a bad txn touched) and the tracked PK
# catalog the derive needs. Two writers to 'inventory' (the table readers will
# seqscan) so a relation over-approximation fans out to BOTH. Decisions are the
# tier-2 sink the readers write to (so their xids resolve to txids in history).
# ---------------------------------------------------------------------------
echo "==> seeding writers + tracked catalog"
$PSQL "
  INSERT INTO eter.tracked(table_name, pk_cols) VALUES
    ('inventory', ARRAY['id']), ('decisions', ARRAY['id']);
  -- Writers (the targets of an undo). committed_at t0, earliest.
  INSERT INTO eter.history(txid, fingerprint, table_name, op, pk, committed_at) VALUES
    (1000,'w','inventory','U','{\"id\":\"1\"}','2026-06-01 10:00:00+00'),
    (1001,'w','inventory','U','{\"id\":\"2\"}','2026-06-01 10:00:00+00');
  -- Each reader also WRITES a decision row, so its 32-bit xid resolves to a txid
  -- in history (the derive maps reader_xid -> txid via the reader's own writes).
  INSERT INTO eter.history(txid, fingerprint, table_name, op, pk, committed_at) VALUES
    (2000,'d','decisions','I','{\"id\":\"10\"}','2026-06-02 11:00:00+00'),  -- R_exact
    (2001,'d','decisions','I','{\"id\":\"11\"}','2026-06-02 11:00:00+00'),  -- R_coarse
    (2002,'d','decisions','I','{\"id\":\"12\"}','2026-06-02 11:00:00+00');  -- R_both
" >/dev/null
pass "2 inventory writers (txn 1000/1001) + 3 decision-writers seeded"

# ---------------------------------------------------------------------------
# Seed the forwarded read-set. locktype: 2=tuple (precise), 1=page, 0=relation.
#   R_exact (2000):  tuple read of inventory id=1     -> precise edge to W 1000
#   R_coarse (2001): relation (seqscan) read          -> coarse edges to 1000 AND 1001
#   R_both (2002):   tuple read of id=2 AND a seqscan  -> precise to 1001, coarse to 1000
# ---------------------------------------------------------------------------
echo "==> seeding forwarded read-set (precise + seqscan reads)"
$PSQL "
  INSERT INTO eter.read_set(reader_xid, table_name, blk, \"off\", locktype, read_pk) VALUES
    (2000,'inventory',0,1,2,'1'),     -- R_exact: precise tuple read of id=1
    (2001,'inventory',0,0,0,NULL),    -- R_coarse: relation-level seqscan
    (2002,'inventory',0,2,2,'2'),     -- R_both: precise tuple read of id=2
    (2002,'inventory',0,0,0,NULL);    -- R_both: ALSO a seqscan (relation)
  SELECT eter.derive_from_read_set();
" >/dev/null
pass "read-set derived into eter.dependencies"

# ---------------------------------------------------------------------------
echo "==> ASSERT 1: most-precise-wins per (reader,target) within one derive"
# R_both/W2(1001) has BOTH a tuple match (id=2) and a relation over-approx: keep tuple.
G_BOTH=$($PSQL "SELECT detail->>'granularity' FROM eter.dependencies WHERE txid=2002 AND depends_on=1001 AND kind='rw'")
[ "$G_BOTH" = "tuple" ] || fail "R_both→W2 should keep the MOST PRECISE granularity (tuple), got '$G_BOTH'"
pass "R_both→W2: tuple match wins over the relation over-approx"
# R_both/W1(1000): only a relation over-approx (id=1 not precisely read by R_both) -> relation.
G_BOTH1=$($PSQL "SELECT detail->>'granularity' FROM eter.dependencies WHERE txid=2002 AND depends_on=1000 AND kind='rw'")
[ "$G_BOTH1" = "relation" ] || fail "R_both→W1 has only a seqscan edge, expected relation, got '$G_BOTH1'"
pass "R_both→W1: relation (only the seqscan implicates it)"

echo "==> ASSERT 2: preview_undo(1000) labels exact vs over-approx dependents"
PLAN=$($PSQL "SELECT eter.preview_undo(1000)")
[ "$(echo "$PLAN" | jget classification)" = '"dependent"' ] || fail "W 1000 should be dependent"
# R_exact (2000): precise tuple read of id=1 -> exact
E2000=$(echo "$PLAN" | node -e 'const p=JSON.parse(require("fs").readFileSync(0,"utf8"));const e=p.conflict_edges.find(x=>x.txid===2000);process.stdout.write(e?e.precision+"/"+e.rw_granularity:"MISSING")')
[ "$E2000" = "exact/tuple" ] || fail "R_exact (2000) should be exact/tuple, got '$E2000'"
pass "R_exact (2000): exact / tuple"
# R_coarse (2001): seqscan -> over-approx / relation
E2001=$(echo "$PLAN" | node -e 'const p=JSON.parse(require("fs").readFileSync(0,"utf8"));const e=p.conflict_edges.find(x=>x.txid===2001);process.stdout.write(e?e.precision+"/"+e.rw_granularity:"MISSING")')
[ "$E2001" = "over-approx/relation" ] || fail "R_coarse (2001) should be over-approx/relation, got '$E2001'"
pass "R_coarse (2001): over-approx / relation"

echo "==> ASSERT 3: precision summary + coarse_tables"
SUM=$(echo "$PLAN" | jget precision)
EXACT=$(echo "$SUM" | jget exact_dependents); OVER=$(echo "$SUM" | jget over_approx_dependents)
[ "$EXACT" = "1" ] || fail "expected 1 exact dependent (R_exact), got $EXACT"
[ "$OVER"  = "2" ] || fail "expected 2 over-approx dependents (R_coarse + R_both), got $OVER"
[ "$(echo "$SUM" | jget coarse_tables)" = '["inventory"]' ] || fail "coarse_tables should be [inventory], got $(echo "$SUM" | jget coarse_tables)"
pass "precision: 1 exact, 2 over-approx, coarse_tables=[inventory]"

echo "==> ASSERT 4: eter.coarse_dependencies() product surface"
CD=$($PSQL "SELECT eter.coarse_dependencies()")
# Coarse edges: R_coarse→{1000,1001} (2 relation) + R_both→1000 (1 relation) = 3.
[ "$(echo "$CD" | jget coarse_edge_count)" = "3" ] || fail "expected 3 coarse edges, got $(echo "$CD" | jget coarse_edge_count)"
T0=$(echo "$CD" | node -e 'const o=JSON.parse(require("fs").readFileSync(0,"utf8"));const t=o.tables[0];process.stdout.write(t.table+"|"+t.coarse_edges+"|"+t.readers+"|"+JSON.stringify(t.granularities))')
[ "$T0" = 'inventory|3|2|{"relation":3}' ] || fail "coarse table report mismatch, got '$T0'"
pass "coarse_dependencies: inventory has 3 relation edges from 2 readers"

echo "==> ASSERT 5: cross-run granularity UPGRADE (coarse first, precise later)"
# R_up (2003) first seqscans inventory (coarse edge to W 1000), then in a LATER
# derive precisely reads id=1, the stored edge must UPGRADE relation -> tuple.
$PSQL "
  INSERT INTO eter.history(txid, fingerprint, table_name, op, pk, committed_at)
    VALUES (2003,'d','decisions','I','{\"id\":\"13\"}','2026-06-02 12:00:00+00');
  INSERT INTO eter.read_set(reader_xid, table_name, blk, \"off\", locktype, read_pk)
    VALUES (2003,'inventory',0,0,0,NULL);          -- run 1: seqscan only
  SELECT eter.derive_from_read_set();
" >/dev/null
G_UP1=$($PSQL "SELECT detail->>'granularity' FROM eter.dependencies WHERE txid=2003 AND depends_on=1000 AND kind='rw'")
[ "$G_UP1" = "relation" ] || fail "R_up after run 1 should be relation, got '$G_UP1'"
$PSQL "
  INSERT INTO eter.read_set(reader_xid, table_name, blk, \"off\", locktype, read_pk)
    VALUES (2003,'inventory',0,1,2,'1');            -- run 2: precise read of id=1
  SELECT eter.derive_from_read_set();
" >/dev/null
G_UP2=$($PSQL "SELECT detail->>'granularity' FROM eter.dependencies WHERE txid=2003 AND depends_on=1000 AND kind='rw'")
[ "$G_UP2" = "tuple" ] || fail "R_up should UPGRADE to tuple after a precise match, got '$G_UP2'"
pass "stored coarse edge upgraded relation -> tuple on a later precise match"

echo "==> ASSERT 6: age_read_edges prunes OLD rw edges + read_set, keeps recent + ww (lever 4)"
# rw read-edges are DERIVED/regenerable, not source history, so they may be
# retention-scoped. All readers so far (2000-2003) committed 2026-06-02; seed a
# RECENT reader (9000, committed now) whose edge must SURVIVE, a ww edge that must
# be UNTOUCHED, and a pending read_set row for an old reader that must be pruned.
$PSQL "
  INSERT INTO eter.history(txid, fingerprint, table_name, op, pk, committed_at)
    VALUES (9000,'d','decisions','I','{\"id\":\"90\"}', now());
  INSERT INTO eter.dependencies(txid, depends_on, kind, detail)
    VALUES (9000, 1000, 'rw', '{\"granularity\":\"tuple\",\"table\":\"inventory\"}');
  -- a ww edge on an OLD reader: age_read_edges must NOT touch it (history backbone)
  INSERT INTO eter.dependencies(txid, depends_on, kind, detail)
    VALUES (2000, 1000, 'ww', '{}');
  -- a pending forwarded read for an OLD reader (2001): aging should drop it
  INSERT INTO eter.read_set(reader_xid, table_name, blk, \"off\", locktype, read_pk)
    VALUES (2001,'inventory',0,0,0,NULL);
" >/dev/null
AGE=$($PSQL "SELECT eter.age_read_edges(interval '7 days')")
DEL_E=$(echo "$AGE" | jget deleted_rw_edges)
DEL_R=$(echo "$AGE" | jget deleted_read_set)
OLD_RW_LEFT=$($PSQL "SELECT count(*) FROM eter.dependencies WHERE kind='rw' AND txid IN (2000,2001,2002,2003)")
[ "$OLD_RW_LEFT" = "0" ] || fail "old rw edges should be pruned, $OLD_RW_LEFT left"
RECENT_RW=$($PSQL "SELECT count(*) FROM eter.dependencies WHERE kind='rw' AND txid=9000")
[ "$RECENT_RW" = "1" ] || fail "recent rw edge (9000) must survive aging, got $RECENT_RW"
WW_LEFT=$($PSQL "SELECT count(*) FROM eter.dependencies WHERE kind='ww'")
[ "$WW_LEFT" = "1" ] || fail "ww edge must NOT be aged out, got $WW_LEFT"
RS_OLD=$($PSQL "SELECT count(*) FROM eter.read_set WHERE reader_xid=2001")
[ "$RS_OLD" = "0" ] || fail "old forwarded read-set should be pruned, $RS_OLD left"
[ "$DEL_R" -ge 1 ] || fail "expected >=1 read_set row deleted, got $DEL_R"
pass "age_read_edges: pruned $DEL_E old rw edges + $DEL_R read rows; kept recent rw + ww"

echo "==> ASSERT 7: aging is sound for undo, preview keeps history/ww + recent rw only"
# After aging W1000's OLD rw dependents (2000/2001/2002) are forgotten; the recent
# rw dependent (9000) is retained. The history-derived undo plan is untouched, so a
# revert still works off history, read-edge scoping never weakens the source.
P2=$($PSQL "SELECT eter.preview_undo(1000)")
C2=$(echo "$P2" | jget conflicts)
[ "$C2" = "[9000]" ] || fail "after aging, W1000 should surface only the recent rw dependent 9000, got $C2"
[ "$(echo "$P2" | jget op_count)" -ge 1 ] || fail "undo plan (from history) must survive rw aging"
pass "preview_undo(1000): old read-dependents aged out, recent retained, undo plan intact"

echo "==> ASSERT 8: a non-negative interval is required"
if $PSQL "SELECT eter.age_read_edges(interval '-1 day')" >/dev/null 2>&1; then
  fail "age_read_edges should reject a negative interval"
fi
pass "age_read_edges rejects a negative keep interval"

# ---------------------------------------------------------------------------
echo "==> ALL OBSERVE-PRECISION ASSERTIONS PASSED"
