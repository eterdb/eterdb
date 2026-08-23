#!/bin/sh
# EterDB Phase 3, TEMPORAL-DEPTH ("aged database") e2e, on the EXTERNALIZED
# (TWO-DB) ARCHITECTURE. Runs LOCALLY (macOS or Linux) with no VM, no ZFS, no
# root, the storage substrate is pg_basebackup + WAL replay (ADR 0003), plain
# unprivileged operations on plain directories.
#
# Every other test restores changes that are SECONDS old. This is the one
# dimension nothing else exercises: AGE. The product promise is "we can undo your
# incident from two months ago", a promise about (a) the mechanism being
# age-blind and (b) the data still being there because we never prune.
#
# The undo/extract mechanics ARE age-blind: cohort selection filters on
# committed_at, and backup selection is by LSN. So we faithfully exercise the
# time-window path by BACKDATING eter.history.committed_at (in the store) and a
# pre-migration base backup's created_at, not by waiting two months. Substrate
# is the SHIPPING one: the PATCHED Postgres in OBSERVE mode @ READ COMMITTED,
# tenant PG + meta store + capture sidecar (+ read-set forwarder) + storage
# sidecar. We deliberately do NOT fall back to stock PG even though this test has
# no SERIALIZABLE readers, testing stock would validate something that isn't
# what ships. New surface: age + scale + a DEPENDENT SUBSET inside the cohort +
# the known post-migration-NULL limit, all under observe.
#
# Scenarios:
#   A. Aged row-batch restore via TIME-WINDOW + value/fingerprint COHORT (not a
#      txid) at ~1M-row scale: a "~2 months ago" bad batch (500 txns) that some
#      later LEGITIMATE re-edits partially overwrote. The since-untouched txns
#      restore exactly; the re-edited subset is flagged dependent and SKIPPED by
#      clean_only (surfaced, not clobbered); unrelated writes survive.
#   B. Aged column recovery from a BACKDATED pre-migration base backup: a
#      "~2 months ago" DROP COLUMN recovered by PK from the old backup; rows
#      INSERTED after the backup stay NULL, the known limit.
#   + RETENTION: the committed DEFAULT policy is NEVER PRUNE (retain the whole
#      history + all base backups, the ETER_BACKUP_RETAIN_COUNT /
#      ETER_BACKUP_HORIZON_DAYS knobs are opt-in and OFF here). Months-old
#      restore works *because* nothing was cut. We assert the aged history rows +
#      the aged backup (catalog row AND on-disk dir) are still present. The
#      deferred cost lever for old/cold data is parquet/object-storage tiering,
#      a COST tool, not a deletion policy.
#   + final assertion: the TENANT holds 0 history / 0 dependencies / 0 ssi_reads.
#
# Requires the patched Postgres (PG18) built into .pgbuild18 (see pg/README.md);
# override with PGBUILD=/path/to/prefix.
#   bash test/temporal-depth.sh
set -eu
cd "$(dirname "$0")/.."
ROOT=$PWD

# Observe mode is the SHIPPING substrate, so every test runs on the PATCHED
# Postgres at READ COMMITTED, never stock PG (EterDB is PG18 only).
PGBIN="${PGBUILD:-$ROOT/.pgbuild18}/bin"
[ -x "$PGBIN/postgres" ] || { echo "patched Postgres not found at $PGBIN, see pg/README.md"; exit 1; }
export PATH="$PGBIN:$PATH"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/eter-tdep.XXXXXX")
MP=$WORK/pgtenant; WAL=$WORK/walarchive; BACKUPS=$WORK/backups; PORT=5503
META_MP=$WORK/pgmeta;                                           META_PORT=5504
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
export ETER_META_URL="$META_URL"
export ETER_BACKUP_DIR="$BACKUPS" ETER_TMP_PORT=5599 ETER_WAL_ARCHIVE="$WAL"
export ETER_PG_BINDIR="$PGBIN"

pass(){ echo "  ✓ $1"; }
fail(){ echo "  ✗ $1"; exit 1; }
PSQL(){   psql "$DBURL" -tAqc "$1"; }          # tenant (user data + apply + SSI capture)
PSQL_M(){ psql "$META_URL" -tAqc "$1"; }       # store  (durable eter metadata)
store(){ "$STORE" "$@"; }
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
wait_store(){ q="$1"; min="$2"; prev=-1; stable=0; i=0; while [ $i -lt 400 ]; do cur=$(PSQL_M "$q"); if [ "$cur" = "$prev" ] && [ "$cur" -ge "$min" ]; then stable=$((stable+1)); else stable=0; fi; [ "$stable" -ge 3 ] && return 0; prev="$cur"; i=$((i+1)); sleep 0.25; done; fail "store drain timeout (q=[$q] min=$min last=$cur)"; }

echo "==> build eter_ssi (OBSERVE-capable, no strict-only) against the patched engine"
PGCFG="$PGBIN/pg_config"
rm -rf "$WORK/eter_ssi" && cp -r "$ROOT/ext/eter_ssi" "$WORK/eter_ssi"
make -C "$WORK/eter_ssi" PG_CONFIG="$PGCFG" clean install 2>&1 | tail -3
pass "eter_ssi built + installed (observe-capable, against patched PG)"

echo "==> TENANT: patched PG18, OBSERVE mode @ READ COMMITTED + logical decoding (plain dirs, no ZFS, no root)"
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
[ "$(PSQL "SHOW eter_observe_mode")" = "on" ]                  || fail "observe mode not on (patched PG GUC)"
[ "$(PSQL "SHOW default_transaction_isolation")" = "read committed" ] || fail "tenant must run at READ COMMITTED (observe, not strict)"
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
pass "meta store up; engine applied (read-side derive + cohort are here)"

echo "==> load the InvenTree demo dataset, then AMPLIFY to ~1M rows (aged-DB scale)"
[ -f "$FIX" ] || curl -sSL -o "$FIX" https://raw.githubusercontent.com/inventree/demo-dataset/master/inventree_data.json
node "$ROOT/test/inventree/gen-sql.mjs" "$FIX" > "$WORK/itree_load.sql"
psql "$DBURL" -q -v ON_ERROR_STOP=1 -f "$WORK/itree_load.sql" >/dev/null
# Clone stock_stockitem ~783x with fresh PKs (column list pulled from the catalog,
# id offset by n*1e6 so PKs stay unique) to reach ~1M rows. Done BEFORE tracking
# so the bulk never enters history, history stays focused on the txns under test
# (mirrors inventree-e2e, which tracks after load).
psql "$DBURL" -q -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
DO $$
DECLARE cols text;
BEGIN
  SELECT string_agg(quote_ident(attname), ', ') INTO cols
  FROM pg_attribute
  WHERE attrelid='public.stock_stockitem'::regclass AND attnum>0 AND NOT attisdropped AND attname<>'id';
  EXECUTE format(
    'INSERT INTO public.stock_stockitem (id, %1$s) SELECT b.id + g.n*1000000, %1$s FROM public.stock_stockitem b CROSS JOIN generate_series(1,783) g(n)',
    cols);
END $$;
SQL
ITEMS=$(PSQL "SELECT count(*) FROM public.stock_stockitem")
PARTS=$(PSQL "SELECT count(*) FROM public.part_part")
[ "$ITEMS" -ge 950000 ] && [ "$PARTS" -ge 400 ] || fail "aged-DB scale not reached ($ITEMS items, $PARTS parts)"
pass "aged DB at scale: $ITEMS stock items, $PARTS parts"

echo "==> track everything (sidecar mode) + start the capture sidecar (history→store + forwarder)"
PSQL "SET eter.capture_mode='sidecar'; SELECT eter.track_all();" >/dev/null
PSQL "SELECT pg_create_logical_replication_slot('$SLOT','pgoutput')" >/dev/null
DATABASE_URL="$DBURL" ETER_META_URL="$META_URL" "$CAP" >"$MP/capture.log" 2>&1 & CAP_PID=$!
wait_cap
pass "capture sidecar streaming to the store; $(PSQL "SELECT count(*) FROM eter.tracked") tables tracked"

# ===========================================================================
echo "==> SCENARIO A: aged ('~2 months ago') bad batch, restored by TIME-WINDOW + value cohort"
# Scale (10x the original recovery size): NTXN same-shape txns (UPDATE ... SET
# quantity='0' WHERE id IN (RPER ids)) over the smallest NBAD ids. ntile(NTXN) cuts
# those ids into NTXN contiguous groups of RPER; the first NDEP_TXN groups (smallest
# NDEP ids) become the DEPENDENT subset (later re-edited), the rest stay CLEAN.
NTXN=500; RPER=6
NBAD=$((NTXN*RPER))                 # 3000 rows in the bad batch
NDEP_TXN=150; NDEP=$((NDEP_TXN*RPER))   # 150 txns / 900 rows re-edited → dependent
NCLEAN=$((NBAD-NDEP))               # 2100 rows / 350 txns stay clean
NCLEAN_TXN=$((NTXN-NDEP_TXN))
NOTHER=2000                         # unrelated present-day writes that must survive
DEP_IDS=$(PSQL "SELECT string_agg(id::text,',') FROM (SELECT id FROM public.stock_stockitem ORDER BY id LIMIT $NDEP) q")
CLEAN_IDS=$(PSQL "SELECT string_agg(id::text,',') FROM (SELECT id FROM public.stock_stockitem ORDER BY id LIMIT $NCLEAN OFFSET $NDEP) q")
OTHER_IDS=$(PSQL "SELECT string_agg(id::text,',') FROM (SELECT id FROM public.stock_stockitem ORDER BY id LIMIT $NOTHER OFFSET $NBAD) q")
SUM_CLEAN_ORIG=$(PSQL "SELECT md5(string_agg(id||':'||coalesce(quantity,''),',' ORDER BY id)) FROM public.stock_stockitem WHERE id IN ($CLEAN_IDS)")

T0=$(PSQL "SELECT now()")
# Emit NTXN single-statement UPDATEs (one txid each in autocommit), same shape/value.
psql "$DBURL" -tAc "SELECT 'UPDATE public.stock_stockitem SET quantity=''0'' WHERE id IN ('||string_agg(id::text,',' ORDER BY id)||');'
  FROM (SELECT id, ntile($NTXN) OVER (ORDER BY id) g FROM (SELECT id FROM public.stock_stockitem ORDER BY id LIMIT $NBAD) q0) q
  GROUP BY g ORDER BY g" > /tmp/badbatch.sql
psql "$DBURL" -q -v ON_ERROR_STOP=1 -f /tmp/badbatch.sql >/dev/null
[ "$(PSQL "SELECT count(*) FROM public.stock_stockitem WHERE id IN ($CLEAN_IDS,$DEP_IDS) AND quantity='0'")" = "$NBAD" ] || fail "bad batch did not zero $NBAD rows"
wait_store "SELECT count(*) FROM eter.history WHERE op='U' AND table_name='stock_stockitem' AND row_after->>'quantity'='0' AND committed_at >= '$T0'::timestamptz" "$NBAD"
pass "fired $NTXN-txn bad batch zeroing $NBAD rows (captured to the store)"

# BACKDATE the bad batch ~60 days in the STORE (the 'mid-April migration'). The
# undo mechanics are age-blind; this faithfully exercises the time-window path.
AGED=$(PSQL_M "WITH u AS (UPDATE eter.history SET committed_at = committed_at - interval '60 days'
  WHERE op='U' AND table_name='stock_stockitem' AND row_after->>'quantity'='0' AND committed_at >= '$T0'::timestamptz
  RETURNING 1) SELECT count(*) FROM u")
[ "$AGED" = "$NBAD" ] || fail "backdating touched $AGED rows, expected $NBAD"
pass "backdated the bad batch to ~60 days ago in the store ($AGED history rows)"

# Later, PRESENT-DAY activity: (a) unrelated updates that must survive, and
# (b) LEGITIMATE re-edits to the dependent subset's rows (a real new value), a
# later write to the same (table,pk) makes those NDEP_TXN bad txns 'dependent'.
PSQL "UPDATE public.stock_stockitem SET quantity='88888' WHERE id IN ($OTHER_IDS)" >/dev/null
PSQL "UPDATE public.stock_stockitem SET quantity='777' WHERE id IN ($DEP_IDS)" >/dev/null
wait_store "SELECT count(*) FROM eter.history WHERE table_name='stock_stockitem' AND row_after->>'quantity'='777'" "$NDEP"
wait_store "SELECT count(*) FROM eter.history WHERE table_name='stock_stockitem' AND row_after->>'quantity'='88888'" "$NOTHER"
pass "later legit activity: $NOTHER unrelated updates + $NDEP re-edits over the dependent subset"

# Restore by what the operator actually knows: the migration's window + shape +
# bad value, never a txid. The aged window isolates it from all present-day rows.
FP=$(PSQL_M "SELECT fingerprint FROM eter.history WHERE op='U' AND table_name='stock_stockitem' AND row_after->>'quantity'='0' LIMIT 1")
SINCE=$(PSQL "SELECT (now() - interval '70 days')::text"); UNTIL=$(PSQL "SELECT (now() - interval '50 days')::text")
PREV=$(eter undo-cohort --table stock_stockitem --fingerprint "$FP" --since "$SINCE" --until "$UNTIL" --where '{"quantity":"0"}' --json)
[ "$(echo "$PREV" | jget txn_count)" = "$NTXN" ]      || fail "cohort should find $NTXN aged txns (got $(echo "$PREV" | jget txn_count))"
[ "$(echo "$PREV" | jget clean)" = "$NCLEAN_TXN" ]    || fail "cohort should preview $NCLEAN_TXN clean (got $(echo "$PREV" | jget clean))"
[ "$(echo "$PREV" | jget dependent)" = "$NDEP_TXN" ]  || fail "cohort should preview $NDEP_TXN dependent (got $(echo "$PREV" | jget dependent))"
pass "previewed the aged cohort: $NTXN txns = $NCLEAN_TXN clean + $NDEP_TXN dependent (re-edited subset), at ~1M scale"

RES=$(eter undo-cohort --table stock_stockitem --fingerprint "$FP" --since "$SINCE" --until "$UNTIL" --where '{"quantity":"0"}' --apply --json)
[ "$(echo "$RES" | jget reverted_txns)" = "$NCLEAN_TXN" ]    || fail "expected $NCLEAN_TXN clean txns reverted (got $(echo "$RES" | jget reverted_txns))"
[ "$(echo "$RES" | jget skipped_dependent)" = "$NDEP_TXN" ] || fail "expected $NDEP_TXN dependent txns skipped (got $(echo "$RES" | jget skipped_dependent))"
[ "$(PSQL "SELECT md5(string_agg(id||':'||coalesce(quantity,''),',' ORDER BY id)) FROM public.stock_stockitem WHERE id IN ($CLEAN_IDS)")" = "$SUM_CLEAN_ORIG" ] || fail "since-untouched rows not restored to their exact originals"
[ "$(PSQL "SELECT count(*) FROM public.stock_stockitem WHERE id IN ($DEP_IDS) AND quantity='777'")" = "$NDEP" ] || fail "re-edited subset was clobbered (must keep the legit value)"
[ "$(PSQL "SELECT count(*) FROM public.stock_stockitem WHERE id IN ($OTHER_IDS) AND quantity='88888'")" = "$NOTHER" ] || fail "unrelated present-day writes were disturbed"
pass "aged restore: $NCLEAN_TXN clean txns restored EXACTLY, $NDEP_TXN dependent skipped (legit re-edits intact), $NOTHER unrelated survived"

# ===========================================================================
echo "==> SCENARIO B: aged column recovery from a BACKDATED pre-migration base backup"
store snapshot manual >/dev/null
# Backdate the backup ~60 days (represents an old pre-migration base backup;
# selection is by LSN, so age is faithful but mechanism-irrelevant).
PSQL_M "UPDATE eter.storage_snapshots SET created_at = created_at - interval '60 days' WHERE id = (SELECT max(id) FROM eter.storage_snapshots)" >/dev/null
IPNB=$(PSQL "SELECT md5(string_agg(id||':'||coalesce(\"IPN\",''),',' ORDER BY id)) FROM public.part_part")
NPARTS=$(PSQL "SELECT count(*) FROM public.part_part")
# Rows INSERTED AFTER the snapshot, not present in the old snapshot.
PSQL "INSERT INTO public.part_part(id,\"IPN\") VALUES (900001,'POST-MIG-1'),(900002,'POST-MIG-2')" >/dev/null
PSQL "ALTER TABLE public.part_part DROP COLUMN \"IPN\"" >/dev/null   # the '~2 months ago' migration
[ "$(PSQL "SELECT count(*) FROM information_schema.columns WHERE table_name='part_part' AND column_name='IPN'")" = "0" ] || fail "IPN not dropped"
store recover-column public.part_part IPN >/dev/null 2>&1
[ "$(PSQL "SELECT md5(string_agg(id||':'||coalesce(\"IPN\",''),',' ORDER BY id)) FROM public.part_part WHERE id NOT IN (900001,900002)")" = "$IPNB" ] || fail "pre-migration IPN not recovered exactly by PK from the aged snapshot"
[ "$(PSQL "SELECT count(*) FROM public.part_part WHERE id IN (900001,900002) AND \"IPN\" IS NULL")" = "2" ] || fail "post-migration rows should stay NULL (the known limit), not in the old snapshot"
pass "recovered \"IPN\" for all $NPARTS pre-migration parts from the ~60-day-old snapshot; 2 post-migration rows stayed NULL"

# ===========================================================================
echo "==> RETENTION: months-old restore worked BECAUSE nothing was pruned (committed default)"
# EterDB's DEFAULT never prunes: history is append-only and base backups + WAL are
# retained (the ETER_BACKUP_RETAIN_COUNT / ETER_BACKUP_HORIZON_DAYS knobs are
# opt-in and off here, and they are a policy for the re-derivable recovery
# substrate, never for history). The whole-history cost is real and accepted; the
# deferred lever for old/cold data is parquet/object-storage TIERING, a cost
# tool, not a deletion policy. The two aged restores above succeeded precisely
# because the aged metadata is all still here. Assert it is.
[ "$(PSQL_M "SELECT count(*) FROM eter.history WHERE op='U' AND table_name='stock_stockitem' AND row_after->>'quantity'='0' AND committed_at < now() - interval '50 days'")" = "$NBAD" ] || fail "aged bad-batch history was pruned, it must be retained in full"
[ "$(PSQL_M "SELECT count(*) FROM eter.storage_snapshots WHERE created_at < now() - interval '50 days' AND pruned_at IS NULL")" -ge 1 ] || fail "aged pre-migration backup record was pruned"
AGED_BK=$(PSQL_M "SELECT backup_name FROM eter.storage_snapshots WHERE created_at < now() - interval '50 days' AND pruned_at IS NULL ORDER BY id LIMIT 1")
[ -d "$BACKUPS/$AGED_BK" ] || fail "the base backup dir backing the aged recovery is gone ($BACKUPS/$AGED_BK)"
pass "$NBAD aged history rows + the ~60-day-old backup (catalog row + on-disk dir) all retained, no pruning, restore stayed possible at depth"

# ===========================================================================
echo "==> TENANT IS CLEAN: zero durable EterDB metadata in the tenant DB"
# Under OBSERVE mode every read across the run staged SSI predicate-read targets in
# the tenant's eter.ssi_reads; the capture sidecar's forwarder ships them to the
# store and clears the tenant staging. Wait for that to drain before asserting.
i=0; while [ "$(PSQL "SELECT count(*) FROM eter.ssi_reads")" != "0" ]; do i=$((i+1)); [ $i -gt 120 ] && fail "forwarder never cleared tenant ssi_reads (observe staging)"; sleep 0.5; done
[ "$(PSQL "SELECT count(*) FROM eter.history")" = "0" ]      || fail "tenant has history rows, expected ZERO"
[ "$(PSQL "SELECT count(*) FROM eter.dependencies")" = "0" ] || fail "tenant has dependency rows, expected ZERO"
[ "$(PSQL "SELECT count(*) FROM eter.ssi_reads")" = "0" ]    || fail "tenant has staged reads, forwarder did not clear ssi_reads"
pass "tenant: 0 history / 0 dependencies / 0 ssi_reads, full aged OBSERVE cycle, all durable metadata in the store"

echo ""
echo "ALL TEMPORAL-DEPTH (AGED DB / TWO-DB) CHECKS PASSED ✅"
