#!/usr/bin/env bash
# EterDB Phase 3, storage LIFECYCLE e2e: the parts of the storage substrate
# that PRODUCTION runs but object-recovery tests never touch. storage-pitr.sh
# proves recovery mechanics by calling snapshot/recover-* by hand; this suite
# proves the machinery that runs UNATTENDED, against a real cluster:
#
#   1. `cycle` (what the orchestrator schedules): first backup taken
#      unconditionally, and its preflight enables DDL logging by itself,
#      no manual `SELECT eter.enable_ddl_logging()` anywhere in this suite.
#   2. WAL-gated cadence: an idle cycle SKIPS the backup; accumulation past
#      ETER_SNAPSHOT_MIN_WAL_BYTES takes one.
#   3. Destructive-DDL flush: a DROP's WAL segment is forced to the archive by
#      the next cycle even when no backup is due.
#   4. Retention ETER_BACKUP_RETAIN_COUNT: middles pruned on disk, catalog rows
#      kept as audit (pruned_at), oldest anchor + newest retained.
#   5. Recovery stays LOSSLESS after pruning (post-backup writes recovered).
#   6. Retention ETER_BACKUP_HORIZON_DAYS: aged backups pruned, archived WAL
#      before the oldest retained backup's start segment deleted
#      (pg_archivecleanup), and an as-of-T read anchored on that oldest
#      retained backup still replays correctly across the cleaned archive.
#   7. Archiver DOWN: a snapshot is REFUSED fast (before pg_basebackup, whose
#      -X none backup-stop would otherwise block forever on the server side),
#      no hang, no unrestorable backup in the catalog, no orphan dir; snapshots
#      work again once the archiver recovers.
#
# Single-DB (store == tenant) on purpose: the two-DB split is e2e'd by
# storage-pitr.sh / meta-externalize.sh; this harness isolates scheduling,
# retention, and failure reporting. Requires the patched PG18 (.pgbuild18;
# override with PGBUILD) + the Go toolchain + node.
#   bash test/storage-lifecycle.sh
set -euo pipefail
cd "$(dirname "$0")/.."

PGB="${PGBUILD:-$PWD/.pgbuild18}/bin"
[ -x "$PGB/postgres" ] || { echo "patched Postgres not found at $PGB, see pg/README.md"; exit 1; }
export PATH="$PGB:$PATH"

# Portable command timeout: GNU coreutils `timeout`, else Homebrew's `gtimeout`,
# else run unbounded (macOS ships no `timeout`). The guarded commands normally
# return promptly; the bound is only a hang guard, so unbounded is a safe fallback.
if command -v timeout >/dev/null 2>&1; then _timeout() { command timeout "$@"; }
elif command -v gtimeout >/dev/null 2>&1; then _timeout() { command gtimeout "$@"; }
else _timeout() { shift; "$@"; }
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/eter-lifecycle.XXXXXX")
MP=$WORK/pgtenant
# Deliberately a path WITH A SPACE: the sidecar double-quotes the archive path
# inside restore_command (and the engine entrypoint inside archive_command), and
# this suite is what keeps that claim true, every recovery below replays
# through this archive.
ARCHIVE="$WORK/wal archive"
BACKUPS=$WORK/backups
PORT="${PGPORT:-5530}"
DBURL="postgres://eter@localhost:$PORT/eter"

SIDE=$WORK/eter-storage
( cd sidecars && CGO_ENABLED=0 go build -o "$SIDE" ./storage ) \
  || { echo "go build storage failed"; exit 1; }

export DATABASE_URL="$DBURL"
export ETER_ALLOW_SINGLE_DB=1                  # deliberately single-DB (store == tenant); issue #67
export ETER_BACKUP_DIR="$BACKUPS"
export ETER_WAL_ARCHIVE="$ARCHIVE"
export ETER_TMP_PORT=$((PORT + 99))
export ETER_PG_BINDIR="$PGB"
export ETER_STORAGE_JSON=1                    # parse results; human line covered elsewhere

pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; exit 1; }
PSQL() { psql "$DBURL" -tAqc "$1"; }
jget(){ node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{const o=JSON.parse(s);let v=o;for(const k of process.argv[1].split("."))v=v[k];process.stdout.write(String(v))})' "$1"; }
unpruned() { PSQL "SELECT count(*) FROM eter.storage_snapshots WHERE pruned_at IS NULL"; }
flush_wal() {
  SEG=$(PSQL "SELECT pg_walfile_name(pg_current_wal_lsn())")
  PSQL "SELECT pg_switch_wal()" >/dev/null
  i=0; while [ ! -f "$ARCHIVE/$SEG" ] && [ $i -lt 30 ]; do i=$((i+1)); sleep 1; done
  [ -f "$ARCHIVE/$SEG" ] || fail "WAL segment $SEG never archived"
}

teardown() {
  pg_ctl -D "$MP" -m immediate stop >/dev/null 2>&1 || true
  for d in "$BACKUPS"/.restore/*/ ; do
    [ -d "$d" ] && pg_ctl -D "$d" -m immediate stop >/dev/null 2>&1 || true
  done
  rm -rf "$WORK"
}
trap teardown EXIT

echo "==> tenant PG18 with WAL archiving (single-DB: store == tenant)"
mkdir -p "$ARCHIVE" "$BACKUPS"
initdb -D "$MP" -U eter --auth-local=trust --auth-host=trust >/dev/null
cat >>"$MP/postgresql.conf" <<EOF
port = $PORT
listen_addresses = 'localhost'
unix_socket_directories = '/tmp'
wal_level = replica
archive_mode = on
archive_command = 'cp "%p" "$ARCHIVE/%f"'
eter_observe_mode = on
max_pred_locks_per_transaction = 4096
EOF
pg_ctl -D "$MP" -l "$MP/pg.log" -w -t 60 start >/dev/null
createdb -h localhost -p "$PORT" -U eter eter
psql "$DBURL" -q -f ext/eter/eter.sql >/dev/null
# NOTE: eter.enable_ddl_logging() is deliberately NOT called, the cycle's
# preflight must do it (that regression shipped once; this suite pins it).
pass "tenant up on :$PORT, engine applied, DDL logging NOT manually enabled"

echo "==> FIRST CYCLE: unconditional first backup + preflight enables DDL logging"
[ "$(PSQL "SELECT count(*) FROM pg_event_trigger WHERE evtname IN ('eter_ddl_end','eter_sql_drop')")" = "0" ] \
  || fail "precondition: DDL logging should start OFF"
C1=$("$SIDE" cycle) || fail "first cycle failed"
[ "$(echo "$C1" | jget took_backup)" = "true" ] || fail "first cycle must take the first backup (got: $C1)"
[ "$(unpruned)" = "1" ] || fail "backup catalog should have 1 row"
[ "$(PSQL "SELECT count(*) FROM pg_event_trigger WHERE evtname IN ('eter_ddl_end','eter_sql_drop')")" = "2" ] \
  || fail "cycle preflight did not enable DDL logging"
pass "first backup taken; DDL logging enabled by the cycle itself"

echo "==> WAL GATE: idle cycle skips; accumulation past the gate backs up"
C2=$("$SIDE" cycle) || fail "idle cycle failed"
[ "$(echo "$C2" | jget took_backup)" = "false" ] || fail "idle cycle below the WAL gate must skip the backup"
[ "$(unpruned)" = "1" ] || fail "idle cycle must not add a backup"
PSQL "CREATE TABLE public.filler(id int PRIMARY KEY, pad text)" >/dev/null
PSQL "INSERT INTO public.filler SELECT g, repeat('x',200) FROM generate_series(1,2000) g" >/dev/null
C3=$(env ETER_SNAPSHOT_MIN_WAL_BYTES=1 "$SIDE" cycle) || fail "gated cycle failed"
[ "$(echo "$C3" | jget took_backup)" = "true" ] || fail "cycle past the WAL gate must back up"
[ "$(unpruned)" = "2" ] || fail "backup catalog should have 2 rows"
pass "WAL-gated cadence: skip when idle, back up past the gate"

echo "==> DESTRUCTIVE-DDL FLUSH: the next cycle ships the drop's WAL segment"
PSQL "CREATE TABLE public.tflush(id int PRIMARY KEY)" >/dev/null
PSQL "DROP TABLE public.tflush" >/dev/null
C4=$("$SIDE" cycle) || fail "flush cycle failed"
[ "$(echo "$C4" | jget took_backup)" = "false" ] || fail "flush cycle should not be backup-due"
DROPLSN=$(echo "$C4" | jget archived_lsn)
[ -n "$DROPLSN" ] && [ "$DROPLSN" != "null" ] || fail "cycle did not see the destructive DDL LSN (DDL logging chain broken?)"
[ "$(PSQL "SELECT last_archived_wal >= pg_walfile_name('$DROPLSN'::pg_lsn) FROM pg_stat_archiver")" = "t" ] \
  || fail "the drop's WAL segment was not forced to the archive"
pass "drop LSN $DROPLSN seen and its segment archived without a backup"

echo "==> RETENTION (RETAIN_COUNT=1): middles pruned on disk, anchor + newest kept"
env ETER_SNAPSHOT_MIN_WAL_BYTES=1 "$SIDE" cycle >/dev/null || fail "filler cycle failed"   # b3
env ETER_SNAPSHOT_MIN_WAL_BYTES=1 "$SIDE" cycle >/dev/null || fail "filler cycle failed"   # b4
[ "$(unpruned)" = "4" ] || fail "expected 4 unpruned backups before retention (got $(unpruned))"
env ETER_SNAPSHOT_MIN_WAL_BYTES=1 ETER_BACKUP_RETAIN_COUNT=1 "$SIDE" cycle >/dev/null || fail "retention cycle failed"  # b5 + prune
[ "$(unpruned)" = "2" ] || fail "retain-count should keep oldest anchor + 1 newest (got $(unpruned))"
[ "$(PSQL "SELECT count(*) FROM eter.storage_snapshots WHERE pruned_at IS NOT NULL")" = "3" ] \
  || fail "pruned catalog rows should remain as audit trail"
B_ANCHOR=$(PSQL "SELECT backup_name FROM eter.storage_snapshots WHERE pruned_at IS NULL ORDER BY id LIMIT 1")
B_NEWEST=$(PSQL "SELECT backup_name FROM eter.storage_snapshots WHERE pruned_at IS NULL ORDER BY id DESC LIMIT 1")
[ -d "$BACKUPS/$B_ANCHOR" ] || fail "anchor backup dir missing"
[ -d "$BACKUPS/$B_NEWEST" ] || fail "newest backup dir missing"
for p in $(PSQL "SELECT backup_name FROM eter.storage_snapshots WHERE pruned_at IS NOT NULL"); do
  [ ! -d "$BACKUPS/$p" ] || fail "pruned backup $p still on disk"
done
pass "3 middles pruned from disk (audit rows kept); anchor $B_ANCHOR + newest retained"

echo "==> RECOVERY STAYS LOSSLESS AFTER PRUNING (post-backup writes recovered)"
PSQL "CREATE TABLE public.marker(id int PRIMARY KEY, v int)" >/dev/null
PSQL "INSERT INTO public.marker VALUES (1, 1)" >/dev/null
PSQL "CREATE TABLE public.t2(id int PRIMARY KEY, v text)" >/dev/null
PSQL "INSERT INTO public.t2 SELECT g, 'r'||g FROM generate_series(1,5) g" >/dev/null
flush_wal
sleep 1; TMID=$(PSQL "SELECT now()::text"); sleep 1   # T: marker=1, no backup at/after T yet
env ETER_SNAPSHOT_MIN_WAL_BYTES=1 "$SIDE" cycle >/dev/null || fail "b6 cycle failed"        # b6 (post-TMID)
PSQL "UPDATE public.marker SET v = 2 WHERE id = 1" >/dev/null
PSQL "INSERT INTO public.t2 SELECT g, 'r'||g FROM generate_series(6,8) g" >/dev/null        # post-b6 writes
PSQL "DROP TABLE public.t2" >/dev/null
"$SIDE" recover-table public.t2 >/dev/null || fail "recover-table after pruning failed"
[ "$(PSQL "SELECT count(*) FROM public.t2 WHERE v='r'||id")" = "8" ] \
  || fail "post-backup writes lost, recovery degraded (got $(PSQL "SELECT count(*) FROM public.t2"))"
pass "dropped table recovered with all 8 rows incl. post-backup writes"

echo "==> RETENTION (HORIZON_DAYS=1): aged backups pruned + WAL archive cleaned, chain intact"
# Age the two oldest unpruned backups past the horizon (the mechanics are
# age-blind, same backdating technique as test/temporal-depth.sh).
PSQL "UPDATE eter.storage_snapshots SET created_at = now() - interval '10 days'
      WHERE pruned_at IS NULL AND id IN (
        SELECT id FROM eter.storage_snapshots WHERE pruned_at IS NULL ORDER BY id LIMIT 2)" >/dev/null
NARCH_BEFORE=$(ls "$ARCHIVE" | wc -l)
env ETER_SNAPSHOT_MIN_WAL_BYTES=1 ETER_BACKUP_HORIZON_DAYS=1 "$SIDE" cycle >/dev/null || fail "horizon cycle failed"  # b7 + prune + archivecleanup
[ ! -d "$BACKUPS/$B_ANCHOR" ] || fail "aged pre-horizon backup $B_ANCHOR should be pruned"
NEW_ANCHOR=$(PSQL "SELECT backup_name FROM eter.storage_snapshots WHERE pruned_at IS NULL ORDER BY id LIMIT 1")
[ -d "$BACKUPS/$NEW_ANCHOR" ] || fail "horizon anchor $NEW_ANCHOR missing from disk"
ANCHOR_WALSTART=$(PSQL "SELECT wal_start FROM eter.storage_snapshots WHERE backup_name = '$NEW_ANCHOR'")
NARCH_AFTER=$(ls "$ARCHIVE" | wc -l)
[ "$NARCH_AFTER" -lt "$NARCH_BEFORE" ] || fail "pg_archivecleanup removed nothing ($NARCH_BEFORE -> $NARCH_AFTER)"
# Only plain 24-hex segment files count: pg_archivecleanup deliberately keeps
# .backup / .history metadata files (tiny, timeline bookkeeping, not WAL).
OLDEST_SEG=$(ls "$ARCHIVE" | grep -E '^[0-9A-F]{24}$' | sort | head -1)
if [ "$OLDEST_SEG" \< "$ANCHOR_WALSTART" ]; then
  fail "archive still holds WAL older than the anchor's start segment ($OLDEST_SEG < $ANCHOR_WALSTART)"
fi
# The strong assert: an as-of-T read that must anchor on the OLDEST retained
# backup and replay across the cleaned archive still returns the historical value.
ASOF=$(env -u ETER_STORAGE_JSON "$SIDE" as-of "$TMID" "SELECT v FROM public.marker WHERE id=1" | tail -1)
[ "$ASOF" = "1" ] || fail "as-of from the horizon anchor broke after WAL cleanup (got '$ASOF'; live=$(PSQL "SELECT v FROM public.marker WHERE id=1"))"
pass "aged backup pruned, dead WAL cleaned, PITR from the retained anchor intact"

echo "==> PK-LESS TABLE: recover-rows refuses early with an actionable message"
# Row-level TRUNCATE recovery dedupes by PK; on a PK-less table it must fail
# with the requirePK message (wired end-to-end), not a Postgres syntax error
# from `ON CONFLICT () DO NOTHING`.
PSQL "CREATE TABLE public.nopk(v int)" >/dev/null
PSQL "INSERT INTO public.nopk SELECT g FROM generate_series(1,4) g" >/dev/null
"$SIDE" snapshot pkless >/dev/null || fail "snapshot for the pk-less scenario failed"
PSQL "TRUNCATE public.nopk" >/dev/null
set +e
NOPK_OUT=$(_timeout 180 "$SIDE" recover-rows public.nopk 2>&1); NOPK_RC=$?
set -e
[ "$NOPK_RC" != "0" ] || fail "recover-rows on a PK-less table must fail"
echo "$NOPK_OUT" | grep -q "no primary key" || fail "PK-less failure not actionable (got: $NOPK_OUT)"
[ "$(PSQL "SELECT count(*) FROM public.nopk")" = "0" ] || fail "failed recovery must not have written rows"
pass "recover-rows on a PK-less table refused with 'no primary key'; live table untouched"

echo "==> ARCHIVER DOWN: snapshot fails fast, nothing catalogued (takes ~60s)"
# A dead archiver must fail the snapshot BEFORE pg_basebackup starts: with
# -X none the server's backup-stop blocks forever waiting for archival, so
# there is no after-the-fact discard to rely on (this hang is exactly what
# this section originally caught).
NCAT=$(PSQL "SELECT count(*) FROM eter.storage_snapshots")
NDIRS=$(ls -d "$BACKUPS"/base-* | wc -l)
PSQL "ALTER SYSTEM SET archive_command = '/bin/false'" >/dev/null
PSQL "SELECT pg_reload_conf()" >/dev/null
PSQL "INSERT INTO public.filler VALUES (999999, 'post-outage row')" >/dev/null
set +e
BROKEN_OUT=$(_timeout 180 "$SIDE" snapshot broken 2>&1); BROKEN_RC=$?
set -e
[ "$BROKEN_RC" != "124" ] || fail "snapshot HUNG with the archiver down (pg_basebackup wait, the pre-check regressed)"
[ "$BROKEN_RC" != "0" ] || fail "snapshot must FAIL while the archiver is down"
echo "$BROKEN_OUT" | grep -q "refusing to start a backup" || fail "failure should refuse before pg_basebackup (got: $BROKEN_OUT)"
[ "$(PSQL "SELECT count(*) FROM eter.storage_snapshots")" = "$NCAT" ] \
  || fail "an unrestorable backup entered the catalog"
[ "$(ls -d "$BACKUPS"/base-* | wc -l)" = "$NDIRS" ] || fail "discarded backup dir left on disk"
PSQL "ALTER SYSTEM RESET archive_command" >/dev/null
PSQL "SELECT pg_reload_conf()" >/dev/null
"$SIDE" snapshot recovered >/dev/null || fail "snapshot should work again once the archiver recovers"
[ "$(PSQL "SELECT count(*) FROM eter.storage_snapshots")" = "$((NCAT + 1))" ] || fail "recovered snapshot not catalogued"
pass "archiver outage: snapshot refused fast, nothing catalogued; healthy again after recovery"

echo ""
echo "ALL STORAGE-LIFECYCLE (SCHEDULING + RETENTION + FAILURE REPORTING) CHECKS PASSED ✅"
