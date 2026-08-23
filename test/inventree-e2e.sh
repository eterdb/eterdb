#!/bin/sh
# EterDB Phase 3, realistic-data end-to-end on the InvenTree demo dataset,
# RUN ON THE EXTERNALIZED (TWO-DB) ARCHITECTURE. Runs LOCALLY (macOS or Linux)
# with no VM, no ZFS, no root, the storage substrate is pg_basebackup + WAL
# replay (ADR 0003), plain unprivileged operations on plain directories.
#
# This is the "make the alpha real" capstone: a full destructive→restore cycle on
# real InvenTree data (parts, stock, orders, 10k+ records) with ALL durable
# EterDB metadata in a SEPARATE EterDB-owned store (ETER_META_URL), the
# tenant DB holding ZERO durable metadata. Substrate: tenant PG + a meta
# store PG + logical-decoding capture sidecar (history→store) + SSI read-set
# forwarder (deps derived in the store) + PITR storage sidecar (base backups/
# recovery → store). Scenarios:
#   1. Row removal + surgical undo via the CLI (cross-DB), unrelated writes survive
#   2. Dropped-column recovery (real mixed-case column "IPN")
#   3. TRUNCATE + dropped-table recovery (post-event writes survive)
#   4. Cohort reversal of a bad batch by statement-shape + value (CLI, cross-DB)
#   5. Tier-2 read-derived decision: read-set forwarded to the store, derived THERE
#      at preview, surfaced as a read-dependent; clean_only undo refuses
#   + final assertion: the TENANT holds 0 history / 0 dependencies / 0 ssi_reads.
#
# Requires the patched Postgres (PG18) built into .pgbuild18 (see pg/README.md);
# override with PGBUILD=/path/to/prefix.
#   bash test/inventree-e2e.sh
set -eu
cd "$(dirname "$0")/.."
ROOT=$PWD

# Observe mode is the SHIPPING substrate, so this runs on the PATCHED Postgres at
# READ COMMITTED, never stock PG (EterDB is PG18 only).
PGBIN="${PGBUILD:-$ROOT/.pgbuild18}/bin"
[ -x "$PGBIN/postgres" ] || { echo "patched Postgres not found at $PGBIN, see pg/README.md"; exit 1; }
export PATH="$PGBIN:$PATH"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/eter-itree.XXXXXX")
MP=$WORK/pgtenant; WAL=$WORK/walarchive; BACKUPS=$WORK/backups; PORT=5501
META_MP=$WORK/pgmeta;                                           META_PORT=5502
DBURL="postgres://eter@localhost:$PORT/eter"
META_URL="postgres://eter@localhost:$META_PORT/eter_meta"
SLOT=eter_slot
FIX=/tmp/inventree_data.json
# Sidecars are Go (docs/adr/0001-sidecars-in-go.md), build static binaries once.
command -v go >/dev/null || { echo "Go toolchain required"; exit 1; }
CAP=$WORK/eter-capture
STORE=$WORK/eter-storage
( cd "$ROOT/sidecars" && CGO_ENABLED=0 go build -o "$CAP" ./capture \
  && CGO_ENABLED=0 go build -o "$STORE" ./storage ) || { echo "go build sidecars failed"; exit 1; }
CLI=$WORK/eter   # Go CLI binary (built below)
CAP_PID=""

export DATABASE_URL="$DBURL"
export ETER_META_URL="$META_URL"           # the lever: metadata is in the store
export ETER_BACKUP_DIR="$BACKUPS" ETER_TMP_PORT=5598 ETER_WAL_ARCHIVE="$WAL"
export ETER_PG_BINDIR="$PGBIN"

pass(){ echo "  ✓ $1"; }
fail(){ echo "  ✗ $1"; exit 1; }
PSQL(){   psql "$DBURL" -tAqc "$1"; }          # tenant (user data + apply + SSI capture)
PSQL_M(){ psql "$META_URL" -tAqc "$1"; }       # store  (durable eter metadata)
store(){ "$STORE" "$@"; }                      # storage sidecar (inherits ETER_META_URL)
# the real CLI, two-DB: reads/preview resolve against the store, undo applies
# cross-DB in the tenant via eter.undo_rows.
CGO_ENABLED=0 go build -C "$ROOT/cli" -o "$CLI" . || fail "eter CLI build failed"
eter(){ env ETER_META_URL="$META_URL" "$CLI" --db "$DBURL" "$@"; }
jget(){ node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{const o=JSON.parse(s);let v=o;for(const k of process.argv[1].split("."))v=v[k];process.stdout.write(String(v))})' "$1"; }

stop_cap(){ if [ -n "${CAP_PID:-}" ]; then kill "$CAP_PID" 2>/dev/null || true; wait "$CAP_PID" 2>/dev/null || true; CAP_PID=""; fi; }
teardown(){
  stop_cap
  pg_ctl -D "$MP" -m immediate stop >/dev/null 2>&1 || true
  pg_ctl -D "$META_MP" -m immediate stop >/dev/null 2>&1 || true
  for d in "$BACKUPS"/.restore/*/ ; do
    [ -d "$d" ] && pg_ctl -D "$d" -m immediate stop >/dev/null 2>&1 || true
  done
  rm -rf "$WORK"
}
trap teardown EXIT

wait_cap(){ i=0; while [ "$(PSQL "SELECT coalesce((SELECT active FROM pg_replication_slots WHERE slot_name='$SLOT'),false)")" != "t" ]; do i=$((i+1)); [ $i -gt 60 ] && fail "capture sidecar slot never active"; sleep 0.25; done; }
# wait until a count query against the STORE (where history/deps/read_set live) is
# >= min and stable.
wait_store(){ q="$1"; min="$2"; prev=-1; stable=0; i=0; while [ $i -lt 200 ]; do cur=$(PSQL_M "$q"); if [ "$cur" = "$prev" ] && [ "$cur" -ge "$min" ]; then stable=$((stable+1)); else stable=0; fi; [ "$stable" -ge 3 ] && return 0; prev="$cur"; i=$((i+1)); sleep 0.25; done; fail "store drain timeout (q=[$q] min=$min last=$cur)"; }

echo "==> build eter_ssi (OBSERVE-capable, no strict-only) against the patched engine"
PGCFG="$PGBIN/pg_config"
rm -rf "$WORK/eter_ssi" && cp -r "$ROOT/ext/eter_ssi" "$WORK/eter_ssi"
make -C "$WORK/eter_ssi" PG_CONFIG="$PGCFG" clean install 2>&1 | tail -3
pass "eter_ssi built + installed (observe-capable, against patched PG)"

echo "==> TENANT: patched PG18 with logical decoding + WAL archiving (plain dirs, no ZFS, no root)"
mkdir -p "$WAL" "$BACKUPS"
initdb -D "$MP" -U eter --auth-local=trust --auth-host=trust >/dev/null
cat >>"$MP/postgresql.conf" <<EOF
port = $PORT
listen_addresses = 'localhost'
unix_socket_directories = '/tmp'
wal_level = logical
max_wal_senders = 8
max_replication_slots = 8
archive_mode = on
archive_command = 'cp %p $WAL/%f'
session_preload_libraries = 'eter_ssi'
eter_observe_mode = on
max_pred_locks_per_transaction = 4096
EOF
pg_ctl -D "$MP" -l "$MP/pg.log" -w -t 60 start >/dev/null
createdb -h localhost -p "$PORT" -U eter eter
psql "$DBURL" -q -f "$ROOT/ext/eter/eter.sql" >/dev/null
psql "$DBURL" -q -c "CREATE EXTENSION eter_ssi" >/dev/null
[ "$(PSQL "SHOW eter_observe_mode")" = "on" ] || fail "observe mode not on (patched PG)"
[ "$(PSQL "SHOW default_transaction_isolation")" = "read committed" ] || fail "tenant must run at READ COMMITTED (observe)"
pass "tenant up on PATCHED PG; engine + eter_ssi installed; OBSERVE mode ON @ READ COMMITTED"

echo "==> META STORE: separate EterDB-owned PG18"
initdb -D "$META_MP" -U eter --auth-local=trust --auth-host=trust >/dev/null
cat >>"$META_MP/postgresql.conf" <<EOF
port = $META_PORT
listen_addresses = 'localhost'
unix_socket_directories = '/tmp'
EOF
pg_ctl -D "$META_MP" -l "$META_MP/pg.log" -w -t 60 start >/dev/null
createdb -h localhost -p "$META_PORT" -U eter eter_meta
psql "$META_URL" -q -f "$ROOT/ext/eter/eter.sql" >/dev/null
pass "meta store up; engine applied (read-side derive is here)"

echo "==> load the InvenTree demo dataset (real Django fixture)"
[ -f "$FIX" ] || curl -sSL -o "$FIX" https://raw.githubusercontent.com/inventree/demo-dataset/master/inventree_data.json
node "$ROOT/test/inventree/gen-sql.mjs" "$FIX" > "$WORK/itree_load.sql"
psql "$DBURL" -q -v ON_ERROR_STOP=1 -f "$WORK/itree_load.sql" >/dev/null
PARTS=$(PSQL "SELECT count(*) FROM public.part_part")
ITEMS=$(PSQL "SELECT count(*) FROM public.stock_stockitem")
[ "$PARTS" -ge 400 ] && [ "$ITEMS" -ge 1000 ] || fail "InvenTree data did not load ($PARTS parts, $ITEMS items)"
# Amplify stock_stockitem to ~100k rows (clone with offset PKs) BEFORE tracking so
# the bulk stays out of history. On a production-sized table the planner uses the
# PK index for selective reads (id =/IN) → tuple/page-level SIREAD → captured
# PRECISELY by the read stash; only genuinely unindexed predicates (location,
# quantity) seqscan → relation-level → coarse over-approximation. The tiny raw
# fixture would seqscan everything and over-approximate every read (see SCENARIO 6).
psql "$DBURL" -q -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
DO $$
DECLARE cols text;
BEGIN
  SELECT string_agg(quote_ident(attname), ', ') INTO cols FROM pg_attribute
  WHERE attrelid='public.stock_stockitem'::regclass AND attnum>0 AND NOT attisdropped AND attname<>'id';
  EXECUTE format('INSERT INTO public.stock_stockitem (id, %1$s) SELECT b.id + g.n*1000000, %1$s FROM public.stock_stockitem b CROSS JOIN generate_series(1,78) g(n)', cols);
END $$;
ANALYZE public.stock_stockitem;
SQL
ITEMS=$(PSQL "SELECT count(*) FROM public.stock_stockitem")
[ "$ITEMS" -ge 90000 ] || fail "amplification did not reach ~100k ($ITEMS items)"
PSQL "CREATE TABLE public.reorder_decision (id bigint PRIMARY KEY, item_id bigint, decision text)" >/dev/null
pass "loaded real InvenTree data + amplified to $ITEMS stock items ($PARTS parts, $(PSQL "SELECT count(*) FROM public.stock_stockitemtracking") tracking rows)"

echo "==> track everything (sidecar mode) + start the capture sidecar (history→store + forwarder)"
PSQL "SET eter.capture_mode='sidecar'; SELECT eter.track_all();" >/dev/null
PSQL "SELECT pg_create_logical_replication_slot('$SLOT','pgoutput')" >/dev/null
DATABASE_URL="$DBURL" ETER_META_URL="$META_URL" "$CAP" >"$MP/capture.log" 2>&1 & CAP_PID=$!
wait_cap
pass "capture sidecar streaming to the store; $(PSQL "SELECT count(*) FROM eter.tracked") tables tracked"

# ===========================================================================
echo "==> SCENARIO 1: row removal + surgical undo via the CLI (cross-DB)"
LOC=$(PSQL "SELECT location FROM public.stock_stockitem WHERE location IS NOT NULL GROUP BY location ORDER BY count(*) DESC LIMIT 1")
NDEL=$(PSQL "SELECT count(*) FROM public.stock_stockitem WHERE location=$LOC")
SUMB=$(PSQL "SELECT md5(string_agg(id||':'||coalesce(quantity,'')||':'||coalesce(part::text,''),',' ORDER BY id)) FROM public.stock_stockitem WHERE location=$LOC")
# Concurrent legitimate traffic addresses rows BY PRIMARY KEY, the common OLTP
# write, so under OBSERVE it reads via an index scan (tuple-level SIREAD →
# captured precisely by the read stash), NOT a seqscan. An unindexed predicate
# update here (e.g. WHERE location=$OLOC) would take a RELATION-level predicate
# lock and over-approximate to "read the whole table", which under observe would
# spuriously flag this DELETE as read-dependent (the known seqscan limit, see
# SCENARIO 6, which exercises that on purpose).
OIDS=$(PSQL "SELECT string_agg(id::text,',') FROM (SELECT id FROM public.stock_stockitem WHERE location IS DISTINCT FROM $LOC ORDER BY id LIMIT 50) q")
PSQL "UPDATE public.stock_stockitem SET quantity='99999' WHERE id IN ($OIDS)" >/dev/null
NOTHER=$(PSQL "SELECT count(*) FROM public.stock_stockitem WHERE id IN ($OIDS) AND quantity='99999'")
DELTX=$(PSQL "WITH d AS (DELETE FROM public.stock_stockitem WHERE location=$LOC RETURNING 1) SELECT txid_current() FROM d LIMIT 1")
# history is in the STORE now (sidecar writes it there; table_name is the bare
# canonical name the sidecar records).
wait_store "SELECT count(*) FROM eter.history WHERE op='D' AND table_name='stock_stockitem'" "$NDEL"
[ "$(eter preview "$DELTX" --json | jget classification)" = "clean" ] || fail "delete batch should preview clean"
eter undo "$DELTX" --apply >/dev/null || fail "clean undo failed"
[ "$(PSQL "SELECT count(*) FROM public.stock_stockitem WHERE location=$LOC")" = "$NDEL" ] || fail "deleted rows not restored ($NDEL expected)"
[ "$(PSQL "SELECT md5(string_agg(id||':'||coalesce(quantity,'')||':'||coalesce(part::text,''),',' ORDER BY id)) FROM public.stock_stockitem WHERE location=$LOC")" = "$SUMB" ] || fail "restored rows differ from originals"
[ "$(PSQL "SELECT count(*) FROM public.stock_stockitem WHERE id IN ($OIDS) AND quantity='99999'")" = "$NOTHER" ] || fail "unrelated concurrent writes were disturbed"
pass "deleted $NDEL stock items, CLI-undone cross-DB + restored exactly (clean preview under OBSERVE); $NOTHER unrelated PK-updates survived"

# ===========================================================================
echo "==> SCENARIO 2: dropped-column recovery (real mixed-case column \"IPN\")"
store snapshot manual >/dev/null
IPNB=$(PSQL "SELECT md5(string_agg(id||':'||coalesce(\"IPN\",''),',' ORDER BY id)) FROM public.part_part")
PSQL "ALTER TABLE public.part_part DROP COLUMN \"IPN\"" >/dev/null
[ "$(PSQL "SELECT count(*) FROM information_schema.columns WHERE table_name='part_part' AND column_name='IPN'")" = "0" ] || fail "IPN not dropped"
store recover-column public.part_part IPN >/dev/null 2>&1
[ "$(PSQL "SELECT md5(string_agg(id||':'||coalesce(\"IPN\",''),',' ORDER BY id)) FROM public.part_part")" = "$IPNB" ] || fail "IPN values not fully recovered"
pass "recovered dropped column \"IPN\" for all $PARTS parts, values identical (snapshot catalog in the store)"

# ===========================================================================
echo "==> SCENARIO 3: TRUNCATE rows + dropped-table recovery (post-event writes survive)"
NTRACK=$(PSQL "SELECT count(*) FROM public.stock_stockitemtracking")
NSOLI=$(PSQL "SELECT count(*) FROM public.order_salesorderlineitem")
store snapshot manual >/dev/null
PSQL "TRUNCATE public.stock_stockitemtracking" >/dev/null
PSQL "INSERT INTO public.stock_stockitemtracking(id) VALUES (900001),(900002)" >/dev/null   # writes AFTER truncate
PSQL "DROP TABLE public.order_salesorderlineitem" >/dev/null
store recover-rows public.stock_stockitemtracking >/dev/null 2>&1
store recover-table public.order_salesorderlineitem >/dev/null 2>&1
EXP=$((NTRACK + 2))
[ "$(PSQL "SELECT count(*) FROM public.stock_stockitemtracking")" = "$EXP" ] || fail "tracking rows not restored ($EXP expected)"
[ "$(PSQL "SELECT count(*) FROM public.stock_stockitemtracking WHERE id IN (900001,900002)")" = "2" ] || fail "post-truncate rows clobbered"
[ "$(PSQL "SELECT count(*) FROM public.order_salesorderlineitem")" = "$NSOLI" ] || fail "dropped table not recovered ($NSOLI expected)"
pass "restored $NTRACK truncated tracking rows (+2 newer kept) and recovered dropped table ($NSOLI rows)"

# ===========================================================================
echo "==> SCENARIO 4: cohort reversal of a bad batch by statement-shape (CLI, cross-DB)"
T0=$(PSQL "SELECT now()")
IDS=$(PSQL "SELECT string_agg(id::text,' ') FROM (SELECT id FROM public.stock_stockitem ORDER BY id LIMIT 15) q")
for ID in $IDS; do
  PSQL "UPDATE public.stock_stockitem SET quantity='0' WHERE id=$ID" >/dev/null   # one txn each, same shape
done
wait_store "SELECT count(*) FROM eter.history WHERE op='U' AND committed_at >= '$T0'::timestamptz AND table_name='stock_stockitem'" 15
FP=$(PSQL_M "SELECT fingerprint FROM eter.history WHERE op='U' AND committed_at >= '$T0'::timestamptz AND table_name='stock_stockitem' LIMIT 1")
# Scope the cohort by the bad VALUE (quantity zeroed) + statement shape + time.
# Pass the BARE table name ('stock_stockitem'), the store has no user catalog, so
# the table predicate must match the stored canonical name, not public.X::regclass.
PRED='{"quantity":"0"}'
PREV=$(eter undo-cohort --table stock_stockitem --fingerprint "$FP" --since "$T0" --where "$PRED" --json | jget txn_count)
[ "$PREV" = "15" ] || fail "cohort preview should find 15 txns (got $PREV)"
ZEROED=$(PSQL "SELECT count(*) FROM public.stock_stockitem WHERE id IN ($(echo $IDS | tr ' ' ',')) AND quantity='0'")
[ "$ZEROED" = "15" ] || fail "batch did not zero 15 rows"
eter undo-cohort --table stock_stockitem --fingerprint "$FP" --since "$T0" --where "$PRED" --apply >/dev/null || fail "cohort undo failed"
[ "$(PSQL "SELECT count(*) FROM public.stock_stockitem WHERE id IN ($(echo $IDS | tr ' ' ',')) AND quantity='0'")" = "0" ] || fail "cohort undo did not restore quantities"
pass "previewed + reversed a 15-transaction bad batch (selected by shape+value, applied cross-DB)"

# ===========================================================================
echo "==> SCENARIO 5: TIER-2 read-derived decision, read-set forwarded + derived IN THE STORE"
# A bad transaction writes a wrong stock level; a later job at the DEFAULT
# isolation (READ COMMITTED, the shipping mode, NOT SERIALIZABLE) READS that level
# and writes a reorder DECISION to another table with NO FK back. Under OBSERVE
# mode the patched engine still captures that predicate read (zero 40001s); it is
# FORWARDED to the store and DERIVED there at preview, surfacing the decision-
# writer as a read-dependent; clean_only undo refuses (no blind auto-revert).
SID=$(PSQL "SELECT id FROM public.stock_stockitem ORDER BY id DESC LIMIT 1")
BADTX=$(PSQL "WITH u AS (UPDATE public.stock_stockitem SET quantity='0' WHERE id=$SID RETURNING 1) SELECT txid_current() FROM u")
wait_store "SELECT count(*) FROM eter.history WHERE txid=$BADTX AND op='U' AND table_name='stock_stockitem'" 1
[ "$(PSQL_M "SELECT count(*) FROM eter.history WHERE txid=$BADTX AND tid IS NOT NULL")" = "0" ] || fail "sidecar write should have NULL tid"
psql "$DBURL" -q >/dev/null <<SQL
BEGIN;  -- default READ COMMITTED (observe mode captures the read; no SERIALIZABLE)
SELECT quantity FROM public.stock_stockitem WHERE id=$SID;   -- reads the bad '0'
INSERT INTO public.reorder_decision(id, item_id, decision) VALUES (1, $SID, 'no-reorder: stock is zero');
COMMIT;
SQL
wait_store "SELECT count(*) FROM eter.history WHERE table_name='reorder_decision' AND NOT is_undo" 1
wait_store "SELECT count(*) FROM eter.read_set" 1   # forwarder shipped the read-set to the store
RDR=$(PSQL_M "SELECT DISTINCT txid FROM eter.history WHERE table_name='reorder_decision' AND NOT is_undo LIMIT 1")
# preview derives the rw graph IN THE STORE (derive_from_read_set) and classifies.
[ "$(eter preview "$BADTX" --json | jget classification)" = "dependent" ] || fail "bad stock write should be dependent via the read-derived decision"
[ "$(PSQL_M "SELECT count(*) FROM eter.dependencies WHERE depends_on=$BADTX AND txid=$RDR AND kind='rw'")" -ge 1 ] || fail "the decision-writer was not surfaced as a read-dependent (derive-in-store on a ctid-less write)"
pass "decision row surfaced as a read-dependent of the bad write, read-set forwarded + DERIVED IN THE STORE"
set +e; eter undo "$BADTX" --apply >/dev/null 2>&1; RC=$?; set -e
[ "$RC" != "0" ] || fail "clean_only undo of a dependent should refuse (would auto-revert blind)"
[ "$(PSQL "SELECT count(*) FROM public.reorder_decision WHERE item_id=$SID")" = "1" ] || fail "the derived decision row was disturbed"
pass "undo refused cross-DB (no blind auto-revert); decision left for human/orchestrator, tier-2 boundary holds"

# ===========================================================================
echo "==> SCENARIO 6: the KNOWN coarse limit, seqscan OVER-APPROXIMATION under observe"
# Scenario 5 showed PRECISE capture: an indexed PK read → tuple-level → exact dep.
# This is the other side of the trade. A bad write to one row; a later txn runs an
# UNINDEXED predicate read that matches NOTHING (so it has no logical dependency on
# the bad row), then writes a decision. Postgres still takes a RELATION-level SIREAD
# lock for the seqscan (it physically scanned every row), so observe SOUNDLY but
# CONSERVATIVELY flags the bad write as read-dependent, a false positive in the
# SAFE direction (never a missed dep, never a silent revert). This is exactly the
# over-approximation that pure strict-mode testing hid; we assert it on purpose.
SID6=$(PSQL "SELECT id FROM public.stock_stockitem ORDER BY id LIMIT 1")
BADTX6=$(PSQL "WITH u AS (UPDATE public.stock_stockitem SET quantity='0' WHERE id=$SID6 RETURNING 1) SELECT txid_current() FROM u")
wait_store "SELECT count(*) FROM eter.history WHERE txid=$BADTX6 AND op='U' AND table_name='stock_stockitem'" 1
psql "$DBURL" -q >/dev/null <<SQL
BEGIN;  -- READ COMMITTED; the read below is an UNINDEXED seqscan that matches nothing
SELECT count(*) FROM public.stock_stockitem WHERE quantity='__no_such_value__';
INSERT INTO public.reorder_decision(id, item_id, decision) VALUES (2, $SID6, 'audit: full-table scan');
COMMIT;
SQL
wait_store "SELECT count(*) FROM eter.history WHERE table_name='reorder_decision' AND NOT is_undo" 2
wait_store "SELECT count(*) FROM eter.read_set" 1
[ "$(eter preview "$BADTX6" --json | jget classification)" = "dependent" ] || fail "seqscan reader should OVER-APPROXIMATE → bad write flagged dependent (known coarse limit)"
[ "$(PSQL_M "SELECT count(*) FROM eter.dependencies WHERE depends_on=$BADTX6 AND kind='rw' AND detail->>'granularity'='relation'")" -ge 1 ] || fail "expected a relation-granularity (coarse, over-approx) rw edge to the bad write"
set +e; eter undo "$BADTX6" --apply >/dev/null 2>&1; RC6=$?; set -e
[ "$RC6" != "0" ] || fail "clean_only must refuse the conservatively-flagged write (no blind revert)"
pass "OBSERVE known limit: an unindexed seqscan that matched NOTHING still over-approximated (relation-level) → bad write conservatively flagged dependent + refused, sound (never a false-clean), the cost is extra human review, never corruption"

# ===========================================================================
echo "==> TENANT IS CLEAN: zero durable EterDB metadata in the tenant DB"
# Observe mode stages every read's predicate targets in eter.ssi_reads; the
# sidecar forwarder ships + clears them. Wait for that drain before asserting.
i=0; while [ "$(PSQL "SELECT count(*) FROM eter.ssi_reads")" != "0" ]; do i=$((i+1)); [ $i -gt 120 ] && fail "forwarder never cleared tenant ssi_reads (observe staging)"; sleep 0.5; done
[ "$(PSQL "SELECT count(*) FROM eter.history")" = "0" ]      || fail "tenant has history rows, expected ZERO (it all is in the store)"
[ "$(PSQL "SELECT count(*) FROM eter.dependencies")" = "0" ] || fail "tenant has dependency rows, expected ZERO"
[ "$(PSQL "SELECT count(*) FROM eter.ssi_reads")" = "0" ]    || fail "tenant has staged reads, forwarder did not clear ssi_reads"
[ "$(PSQL_M "SELECT count(*) FROM eter.history WHERE NOT is_undo")" -ge "$NDEL" ] || fail "store is missing the captured history"
pass "tenant: 0 history / 0 dependencies / 0 ssi_reads, full cycle ran with all durable metadata in the store"

echo ""
echo "ALL PHASE 3 INVENTREE E2E (TWO-DB / EXTERNALIZED) CHECKS PASSED ✅"
