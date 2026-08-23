#!/usr/bin/env bash
# EterDB Phase 3, storage-sidecar test, RUN ON THE EXTERNALIZED (TWO-DB)
# ARCHITECTURE. Runs LOCALLY (macOS or Linux) with no VM, no ZFS, no root: the
# storage substrate is pg_basebackup base backups + archived-WAL replay into a
# throwaway Postgres (ADR 0003), which are ordinary unprivileged operations.
# Proves object-level recovery, the thing a trigger/CDC oracle can never do,
# with the storage sidecar's OWN bookkeeping (storage_snapshots, recovery_log)
# written to a SEPARATE EterDB-owned store (ETER_META_URL), not the tenant:
#   - dropped TABLE recovered exactly, unrelated tables untouched
#   - writes between the base backup and the drop recovered (WAL replay)
#   - dropped COLUMN re-added + repopulated by PK; post-drop rows stay NULL
#   - TRUNCATE'd rows restored without clobbering rows written after the truncate
#   - as-of-T read via restore + WAL replay (PITR) returns the historical value
#   + the backup catalog + recovery log are in the STORE, not the tenant.
#
# Requires the patched Postgres (PG18) built into .pgbuild18 (see pg/README.md);
# override with PGBUILD=/path/to/prefix. Storage recovery is mode-independent,
# but we test the engine that actually ships (observe on).
set -euo pipefail
cd "$(dirname "$0")/.."

PGB="${PGBUILD:-$PWD/.pgbuild18}/bin"
[ -x "$PGB/postgres" ] || { echo "patched Postgres not found at $PGB, see pg/README.md"; exit 1; }
export PATH="$PGB:$PATH"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/eter-pitr.XXXXXX")
MP=$WORK/pgtenant
META_MP=$WORK/pgmeta
ARCHIVE=$WORK/walarchive
BACKUPS=$WORK/backups
PORT="${PGPORT:-5500}"
META_PORT=$((PORT + 2))
DBURL="postgres://eter@localhost:$PORT/eter"
META_URL="postgres://eter@localhost:$META_PORT/eter_meta"

# Storage sidecar is Go (docs/adr/0001-sidecars-in-go.md), build a static binary.
SIDE=$WORK/eter-storage
( cd sidecars && CGO_ENABLED=0 go build -o "$SIDE" ./storage ) \
  || { echo "go build storage failed"; exit 1; }

export DATABASE_URL="$DBURL"
export ETER_META_URL="$META_URL"          # storage bookkeeping → the store
export ETER_BACKUP_DIR="$BACKUPS"
export ETER_TMP_PORT=$((PORT + 99))
export ETER_WAL_ARCHIVE="$ARCHIVE"
export ETER_PG_BINDIR="$PGB"
unset ETER_PG_OS_USER 2>/dev/null || true # same-uid path: sidecar == postgres user

pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; exit 1; }
PSQL() { psql "$DBURL" -tAqc "$1"; }          # tenant (user data)
PSQL_M() { psql "$META_URL" -tAqc "$1"; }     # store  (storage bookkeeping)
side() { "$SIDE" "$@"; }                      # storage sidecar (inherits ETER_META_URL)
# Force the current WAL segment out to a fresh file and wait until it is archived,
# so restore-based recovery (as-of-T PITR + WAL-replay object recovery) can replay
# up to the latest writes. archive_command only ships COMPLETED segments.
flush_wal() {
  SEG=$(PSQL "SELECT pg_walfile_name(pg_current_wal_lsn())")
  PSQL "SELECT pg_switch_wal()" >/dev/null
  i=0; while [ ! -f "$ARCHIVE/$SEG" ] && [ $i -lt 30 ]; do i=$((i+1)); sleep 1; done
  [ -f "$ARCHIVE/$SEG" ] || fail "WAL segment $SEG never archived"
}

teardown() {
  pg_ctl -D "$MP" -m immediate stop >/dev/null 2>&1 || true
  pg_ctl -D "$META_MP" -m immediate stop >/dev/null 2>&1 || true
  # any throwaway recovery instance still up (failed run) is under $BACKUPS/.restore
  for d in "$BACKUPS"/.restore/*/ ; do
    [ -d "$d" ] && pg_ctl -D "$d" -m immediate stop >/dev/null 2>&1 || true
  done
  rm -rf "$WORK"
}
trap teardown EXIT

echo "==> set up tenant PG18 with WAL archiving (plain dirs, no ZFS, no root)"
mkdir -p "$ARCHIVE" "$BACKUPS"
initdb -D "$MP" -U eter --auth-local=trust --auth-host=trust >/dev/null
cat >>"$MP/postgresql.conf" <<EOF
port = $PORT
listen_addresses = 'localhost'
unix_socket_directories = '/tmp'
wal_level = replica
archive_mode = on
archive_command = 'cp %p $ARCHIVE/%f'
eter_observe_mode = on
max_pred_locks_per_transaction = 4096
EOF
pg_ctl -D "$MP" -l "$MP/pg.log" -w -t 60 start >/dev/null
createdb -h localhost -p "$PORT" -U eter eter
psql "$DBURL" -q -f ext/eter/eter.sql >/dev/null
# DDL logging records each destructive DROP's LSN (eter.ddl_log.snapshot_lsn),
# object recovery replays archived WAL to just before it.
psql "$DBURL" -q -c "SELECT eter.enable_ddl_logging()" >/dev/null
pass "tenant PG up, archiving to $ARCHIVE, engine + DDL logging applied"

echo "==> META STORE: separate EterDB-owned PG18"
initdb -D "$META_MP" -U eter --auth-local=trust --auth-host=trust >/dev/null
cat >>"$META_MP/postgresql.conf" <<EOF
port = $META_PORT
listen_addresses = 'localhost'
unix_socket_directories = '/tmp'
EOF
pg_ctl -D "$META_MP" -l "$META_MP/pg.log" -w -t 60 start >/dev/null
createdb -h localhost -p "$META_PORT" -U eter eter_meta
psql "$META_URL" -q -f ext/eter/eter.sql >/dev/null
pass "meta store up; storage bookkeeping (storage_snapshots, recovery_log) is here"

# ---------------------------------------------------------------------------
echo "==> DROP TABLE recovery"
PSQL "CREATE TABLE public.keep(id int PRIMARY KEY, v int)"          # unrelated table
PSQL "INSERT INTO public.keep SELECT g, g FROM generate_series(1,3) g"
PSQL "CREATE TABLE public.widgets(id int PRIMARY KEY, name text, qty int)"
PSQL "INSERT INTO public.widgets SELECT g, 'w'||g, g*100 FROM generate_series(1,10) g"
SNAP1=$(side snapshot manual); pass "base backup taken: $SNAP1"
[ -d "$BACKUPS/$SNAP1" ] || fail "backup dir $BACKUPS/$SNAP1 missing on disk"
PSQL "INSERT INTO public.keep VALUES (4,4)"                          # write AFTER backup, unrelated
PSQL "DROP TABLE public.widgets"
flush_wal
[ "$(PSQL "SELECT to_regclass('public.widgets') IS NULL")" = "t" ] || fail "widgets not actually dropped"
side recover-table public.widgets >/dev/null 2>&1
[ "$(PSQL "SELECT count(*) FROM public.widgets")" = "10" ] || fail "table not recovered to 10 rows"
[ "$(PSQL "SELECT count(*) FROM public.widgets WHERE name='w'||id AND qty=id*100")" = "10" ] || fail "recovered rows differ from original"
[ "$(PSQL "SELECT count(*) FROM public.keep")" = "4" ] || fail "unrelated table changed by table recovery"
pass "dropped table recovered exactly (10 rows); unrelated table untouched"

# ---------------------------------------------------------------------------
# Regression: writes made AFTER the base backup but BEFORE the drop must be
# recovered, object recovery replays archived WAL to just before the drop's LSN,
# so backup cadence never bounds data completeness. (Backup-only recovery
# would lose every row in this window.)
echo "==> WAL-replay recovery (writes between backup and drop)"
PSQL "CREATE TABLE public.orders(id int PRIMARY KEY, amt int)"
PSQL "INSERT INTO public.orders SELECT g, g FROM generate_series(1,5) g"   # BEFORE backup
SNAP_R=$(side snapshot manual); pass "base backup taken: $SNAP_R"
PSQL "INSERT INTO public.orders SELECT g, g FROM generate_series(6,20) g"  # AFTER backup, before drop
PSQL "UPDATE public.orders SET amt = amt*10 WHERE id <= 5"                 # mutate pre-backup rows too
PSQL "DROP TABLE public.orders"
flush_wal
side recover-table public.orders >/dev/null 2>&1
[ "$(PSQL "SELECT count(*) FROM public.orders")" = "20" ] || fail "post-backup rows lost, expected 20 (WAL not replayed to the drop?)"
[ "$(PSQL "SELECT count(*) FROM public.orders WHERE id<=5 AND amt=id*10")" = "5" ] || fail "post-backup UPDATE not recovered"
[ "$(PSQL "SELECT count(*) FROM public.orders WHERE id>5 AND amt=id")" = "15" ] || fail "post-backup INSERTs not recovered"
pass "all 20 rows recovered incl. writes after the backup (WAL replayed to just before the drop)"

# ---------------------------------------------------------------------------
echo "==> DROP COLUMN recovery"
PSQL "CREATE TABLE public.gadgets(id int PRIMARY KEY, name text, secret text)"
PSQL "INSERT INTO public.gadgets SELECT g, 'g'||g, 'sek-'||g FROM generate_series(1,5) g"
SNAP2=$(side snapshot manual); pass "base backup taken: $SNAP2"
PSQL "ALTER TABLE public.gadgets DROP COLUMN secret"
PSQL "INSERT INTO public.gadgets(id,name) VALUES (6,'g6')"           # new row AFTER drop
flush_wal
[ "$(PSQL "SELECT count(*) FROM information_schema.columns WHERE table_name='gadgets' AND column_name='secret'")" = "0" ] || fail "secret not dropped"
side recover-column public.gadgets secret >/dev/null 2>&1
[ "$(PSQL "SELECT count(*) FROM public.gadgets WHERE secret = 'sek-'||id")" = "5" ] || fail "column values not restored for ids 1-5"
[ "$(PSQL "SELECT secret IS NULL FROM public.gadgets WHERE id=6")" = "t" ] || fail "post-drop row should have NULL secret"
pass "dropped column re-added + repopulated by PK (5 rows); post-drop row stayed NULL"

# ---------------------------------------------------------------------------
echo "==> TRUNCATE rows recovery (post-backup writes recovered; post-truncate writes survive)"
PSQL "CREATE TABLE public.stock(id int PRIMARY KEY, qty int)"
PSQL "INSERT INTO public.stock SELECT g, g*5 FROM generate_series(1,8) g"    # BEFORE backup
SNAP3=$(side snapshot manual); pass "base backup taken: $SNAP3"
PSQL "INSERT INTO public.stock SELECT g, g*5 FROM generate_series(9,12) g"   # AFTER backup, before truncate
PSQL "TRUNCATE public.stock"
flush_wal
PSQL "INSERT INTO public.stock VALUES (20,200),(21,210)"             # writes AFTER truncate
side recover-rows public.stock >/dev/null 2>&1
[ "$(PSQL "SELECT count(*) FROM public.stock")" = "14" ] || fail "expected 12 restored + 2 new = 14 rows"
[ "$(PSQL "SELECT count(*) FROM public.stock WHERE id BETWEEN 1 AND 12 AND qty=id*5")" = "12" ] || fail "pre-truncate rows not restored exactly (incl. post-backup writes 9-12)"
[ "$(PSQL "SELECT qty FROM public.stock WHERE id=20")" = "200" ] || fail "post-truncate row clobbered"
pass "truncated rows restored (12 incl. post-backup writes) + post-truncate writes preserved (2)"

# ---------------------------------------------------------------------------
echo "==> as-of-T read (restore + WAL replay / PITR)"
PSQL "CREATE TABLE public.cfg(id int PRIMARY KEY, v int)"
PSQL "INSERT INTO public.cfg VALUES (1,1)"
SNAP4=$(side snapshot manual); pass "base backup taken: $SNAP4"
PSQL "UPDATE public.cfg SET v=2 WHERE id=1"
sleep 2
TPIT=$(PSQL "SELECT now()")                                          # T: v is 2 here
sleep 2
PSQL "UPDATE public.cfg SET v=3 WHERE id=1"
flush_wal   # so PITR can replay up to T (segment holding v=2/v=3 must be archived)
ASOF=$(side as-of "$TPIT" "SELECT v FROM public.cfg WHERE id=1" 2>"$WORK/asof.err" | tail -1)
[ "$(PSQL "SELECT v FROM public.cfg WHERE id=1")" = "3" ] || fail "live value should be 3"
[ "$ASOF" = "2" ] || { echo "--- as-of stderr ---"; cat "$WORK/asof.err"; fail "as-of-T should read v=2 (got '$ASOF')"; }
pass "as-of-T read returned the historical value (v=2) while live is v=3"

# ---------------------------------------------------------------------------
echo "==> bookkeeping is in the STORE, not the tenant"
SNAPS=$(PSQL_M "SELECT count(*) FROM eter.storage_snapshots")
RECS=$(PSQL_M "SELECT count(*) FROM eter.recovery_log")
[ "$SNAPS" -ge 4 ] || fail "store should hold the backup catalog (>=4 backups, got $SNAPS)"
[ "$RECS" -ge 3 ] || fail "store should hold the recovery log (>=3 recoveries: table/column/rows, got $RECS)"
[ "$(PSQL "SELECT count(*) FROM eter.storage_snapshots")" = "0" ] || fail "tenant holds backup-catalog rows, expected ZERO (they belong in the store)"
[ "$(PSQL "SELECT count(*) FROM eter.recovery_log")" = "0" ]      || fail "tenant holds recovery-log rows, expected ZERO"
pass "backup catalog ($SNAPS) + recovery log ($RECS) in the store; tenant eter bookkeeping is empty"

echo ""
echo "ALL PHASE 3 STORAGE-PITR (TWO-DB / EXTERNALIZED, NO ZFS, NO ROOT) CHECKS PASSED ✅"
