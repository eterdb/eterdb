#!/usr/bin/env bash
# EterDB, ORCHESTRATOR e2e: the single HTTP entry point + managed restore jobs.
# Runs LOCALLY against a patched PG18 build (no VM, no root).
#
# Proves the two things the orchestrator exists for:
#   1. SINGLE ENTRY POINT: the CLI runs with ONLY ETER_URL + ETER_TOKEN (no
#      DATABASE_URL), init/track/log/preview/undo/status flow through the
#      orchestrator's /v1 API with the frozen exit-code contract intact
#      (0 ok · 3 not-found · 4 dependent), because error bodies carry the
#      engine's message text verbatim.
#   2. MANAGED RESTORES: snapshot/recover-* become async jobs (eter.jobs),
#      submitted, single-flight (never overlapping), surviving orchestrator
#      crashes truthfully (orphaned running job → failed at boot; the job's own
#      restore debris swept while a manual sidecar's rec_* dir is spared),
#      cancelable, bounded by ETER_JOB_TIMEOUT_SEC, with structured output
#      rendered back by the CLI.
#   3. LOSSLESS BY DEFAULT: the orchestrator runs the storage preflight (DDL
#      logging + archiving), so a managed recover-table replays WAL past the
#      base backup, rows written AFTER the snapshot and BEFORE the drop come
#      back. (A backup-only degrade would silently pass a weaker assert; this
#      pins the strong one.)
#   4. SELF-SCHEDULING: with ETER_SCHEDULE_INTERVAL_SEC>0 the orchestrator's
#      cycle takes scheduled backups on its own, no daemon, no manual snapshot.
#   + auth: /v1/* is bearer-guarded; the root probe is open.
#
# Deliberately SINGLE-DB (store == tenant): the two-DB split is the same shared
# DirectClient code path e2e'd by test/e2e.sh + meta-externalize.sh; this
# harness isolates what is NEW (wire protocol, jobs, scheduling, crash paths).
#
# Requires the patched Postgres (PG18) built into .pgbuild18 (see pg/README.md);
# override with PGBUILD=/path/to/prefix.
#   bash test/orchestrator.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD

PGB="${PGBUILD:-$PWD/.pgbuild18}/bin"
[ -x "$PGB/postgres" ] || { echo "patched Postgres not found at $PGB, see pg/README.md"; exit 1; }
export PATH="$PGB:$PATH"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/eter-orch.XXXXXX")
MP=$WORK/pgtenant
ARCHIVE=$WORK/walarchive
BACKUPS=$WORK/backups
PORT="${PGPORT:-5520}"
ORCH_PORT=4410
TOKEN=sekrit-token
DBURL="postgres://eter@localhost:$PORT/eter"
ORCH_URL="http://localhost:$ORCH_PORT"

command -v go >/dev/null || { echo "Go toolchain required"; exit 1; }
STORE_BIN=$WORK/eter-storage
ORCH_BIN=$WORK/eter-orchestrator
CLI=$WORK/eter
( cd sidecars && CGO_ENABLED=0 go build -o "$STORE_BIN" ./storage \
  && CGO_ENABLED=0 go build -o "$ORCH_BIN" ./orchestrator ) || { echo "go build failed"; exit 1; }
CGO_ENABLED=0 go build -C "$ROOT/cli" -o "$CLI" . || { echo "eter CLI build failed"; exit 1; }

pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; exit 1; }
PSQL() { psql "$DBURL" -tAqc "$1"; }
# The CLI in SINGLE-URL mode: only the orchestrator URL + token, NO DATABASE_URL.
eter() { env -u DATABASE_URL -u ETER_META_URL ETER_URL="$ORCH_URL" ETER_TOKEN="$TOKEN" "$CLI" "$@"; }
jget(){ node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{const o=JSON.parse(s);let v=o;for(const k of process.argv[1].split("."))v=v[k];process.stdout.write(String(v))})' "$1"; }

ORCH_PID=""
start_orch() { # start_orch [extra env as VAR=val ...]
  # Deliberately single-DB (store == tenant) → acknowledge it explicitly (issue #67).
  # The scheduled eter-storage cycles inherit this env, so it covers them too.
  env DATABASE_URL="$DBURL" ETER_ALLOW_SINGLE_DB=1 ETER_BACKUP_DIR="$BACKUPS" ETER_WAL_ARCHIVE="$ARCHIVE" \
      ETER_PG_BINDIR="$PGB" ETER_STORAGE_BIN="$STORE_BIN" ETER_API_TOKEN="$TOKEN" \
      ETER_PORT="$ORCH_PORT" ETER_SCHEDULE_INTERVAL_SEC=0 ETER_TMP_PORT=5620 \
      ETER_SQL_FILE="$ROOT/ext/eter/eter.sql" \
      "$@" "$ORCH_BIN" >>"$WORK/orch.log" 2>&1 & ORCH_PID=$!
  for i in $(seq 1 50); do
    curl -s -o /dev/null "$ORCH_URL/" && return 0
    sleep 0.2
  done
  tail -5 "$WORK/orch.log"; fail "orchestrator never came up"
}
stop_orch() { if [ -n "$ORCH_PID" ]; then kill "$ORCH_PID" 2>/dev/null || true; wait "$ORCH_PID" 2>/dev/null || true; ORCH_PID=""; fi; }

teardown() {
  stop_orch
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
archive_command = 'cp %p $ARCHIVE/%f'
eter_observe_mode = on
max_pred_locks_per_transaction = 4096
EOF
pg_ctl -D "$MP" -l "$MP/pg.log" -w -t 60 start >/dev/null
createdb -h localhost -p "$PORT" -U eter eter
# This test exercises the single-URL CLI-over-HTTP flow, not the capture
# substrate, and runs no capture sidecar. Pin the tenant to the trigger oracle
# (test-only override) so `eter track` via the orchestrator installs in-DB
# capture instead of refusing (the product default 'auto' needs a live sidecar).
psql -h localhost -p "$PORT" -U eter -d eter -c "ALTER DATABASE eter SET eter.capture_mode='trigger'" >/dev/null
pass "tenant up on :$PORT"

echo "==> orchestrator up on :$ORCH_PORT (token-guarded)"
start_orch
pass "orchestrator listening"

echo "==> auth: /v1/* guarded, root probe open"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$ORCH_URL/v1/status")" = "401" ] || fail "/v1/status without token should 401"
BODY=$(curl -s "$ORCH_URL/v1/status")
echo "$BODY" | grep -q '"error":"unauthorized"' || fail "401 body shape wrong: $BODY"
[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$ORCH_URL/v1/status")" = "200" ] || fail "/v1/status with token should 200"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$ORCH_URL/")" = "200" ] || fail "root probe should be open"
pass "bearer auth enforced on /v1/* only"

echo "==> SINGLE ENTRY POINT: full CLI flow with ETER_URL only (no DATABASE_URL)"
eter init >/dev/null || fail "eter init via orchestrator failed"
PSQL "CREATE TABLE public.widgets(id int PRIMARY KEY, name text, qty int)" >/dev/null
PSQL "INSERT INTO public.widgets SELECT g, 'w'||g, g*100 FROM generate_series(1,10) g" >/dev/null
eter track public.widgets >/dev/null || fail "eter track via orchestrator failed"
INCTX=$(PSQL "WITH u AS (UPDATE public.widgets SET qty = 0 WHERE id <= 5 RETURNING 1) SELECT txid_current() FROM u LIMIT 1")
[ "$(eter log --json | jget 0.txid)" = "$INCTX" ] || fail "eter log via orchestrator should show the incident txn"
[ "$(eter preview "$INCTX" --json | jget classification)" = "clean" ] || fail "preview should be clean"
eter undo "$INCTX" --apply >/dev/null || fail "clean undo via orchestrator failed"
[ "$(PSQL "SELECT count(*) FROM public.widgets WHERE qty = id*100")" = "10" ] || fail "undo did not restore quantities"
[ "$(eter status --json | jget ready)" = "true" ] || fail "eter status should be ready"
pass "init/track/log/preview/undo/status, one URL, zero DSNs"

echo "==> exit-code contract survives the HTTP hop (3 = not found, 4 = dependent)"
set +e; eter undo 999999999 --apply >/dev/null 2>&1; RC=$?; set -e
[ "$RC" = "3" ] || fail "unknown txid should exit 3 (got $RC)"
W=$(PSQL "WITH u AS (UPDATE public.widgets SET qty = 1 WHERE id = 7 RETURNING 1) SELECT txid_current() FROM u")
PSQL "UPDATE public.widgets SET qty = 2 WHERE id = 7" >/dev/null   # later write → dependent
[ "$(eter preview "$W" --json | jget classification)" = "dependent" ] || fail "preview should be dependent"
set +e; eter undo "$W" --apply >/dev/null 2>&1; RC=$?; set -e
[ "$RC" = "4" ] || fail "dependent clean_only undo should exit 4 (got $RC)"
pass "exit codes 3/4 preserved through the orchestrator (verbatim engine messages)"

echo "==> PREFLIGHT: an orchestrator boot (post-init) enables DDL logging by itself"
# The first boot ran pre-init (nothing to enable); a restart now must preflight
# the installed engine, this is what makes managed recovery LOSSLESS, and it
# must need no manual `SELECT eter.enable_ddl_logging()`.
stop_orch
start_orch
for i in $(seq 1 50); do
  [ "$(PSQL "SELECT count(*) FROM pg_event_trigger WHERE evtname IN ('eter_ddl_end','eter_sql_drop')")" = "2" ] && break
  sleep 0.2
done
[ "$(PSQL "SELECT count(*) FROM pg_event_trigger WHERE evtname IN ('eter_ddl_end','eter_sql_drop')")" = "2" ] \
  || fail "boot preflight did not enable DDL logging"
pass "boot preflight enabled DDL logging (no manual step)"

echo "==> MANAGED RESTORE: snapshot + LOSSLESS recover-table as jobs"
SNAP=$(eter snapshot manual) || fail "eter snapshot via orchestrator failed"
echo "$SNAP" | grep -q "^base-" || fail "snapshot job did not return a backup name (got '$SNAP')"
# Rows written AFTER the base backup: a backup-only (degraded) recovery would
# lose these, recovering them proves the drop's LSN was logged and WAL was
# replayed to just before it.
PSQL "INSERT INTO public.widgets SELECT g, 'w'||g, g*100 FROM generate_series(11,13) g" >/dev/null
PSQL "DROP TABLE public.widgets" >/dev/null
[ "$(PSQL "SELECT count(*) FROM eter.ddl_log WHERE is_destructive AND object_identity LIKE '%widgets%' AND snapshot_lsn IS NOT NULL")" -ge 1 ] \
  || fail "destructive DROP not recorded in eter.ddl_log (preflight regression?)"
OUT=$(eter recover-table public.widgets) || fail "recover-table job failed"
echo "$OUT" | grep -q "✓ recovered table public.widgets, 13 row(s)" || fail "recover output wrong (want 13 rows incl. post-backup writes): $OUT"
[ "$(PSQL "SELECT count(*) FROM public.widgets WHERE name='w'||id")" = "13" ] || fail "post-backup writes lost, recovery degraded to backup-only"
[ "$(PSQL "SELECT count(*) FROM eter.jobs WHERE state='succeeded' AND kind IN ('snapshot','recover-table')")" = "2" ] || fail "eter.jobs should record both jobs succeeded"
[ "$(eter jobs --json | jget 0.state)" = "succeeded" ] || fail "eter jobs list should show the last job succeeded"
JID=$(eter jobs --json | jget 0.id)
[ "$(eter jobs "$JID" --json | jget kind)" = "recover-table" ] || fail "eter jobs <id> shape wrong"
pass "snapshot + recover-table ran as jobs; eter.jobs records + CLI renders ✓"

echo "==> as-of through the orchestrator"
PSQL "UPDATE public.widgets SET qty = 424242 WHERE id = 1" >/dev/null
sleep 2
TPIT=$(PSQL "SELECT now()::text")   # T: qty is 424242 here (backup from the scenario above pre-dates it)
sleep 2
PSQL "UPDATE public.widgets SET qty = 555555 WHERE id = 1" >/dev/null
PSQL "SELECT pg_switch_wal()" >/dev/null
ASOF=$(eter as-of "$TPIT" "SELECT qty FROM public.widgets WHERE id=1" | tail -1)
[ "$ASOF" = "424242" ] || fail "as-of should read the historical value 424242 (got '$ASOF')"
pass "as-of PITR read returned the historical value via a job"

echo "==> SINGLE-FLIGHT: two queued restores never overlap"
J1=$(eter snapshot --no-wait --json | jget job_id)
J2=$(eter recover-rows public.widgets --no-wait --json | jget job_id)
for i in $(seq 1 120); do
  S2=$(PSQL "SELECT state FROM eter.jobs WHERE id=$J2")
  case "$S2" in succeeded|failed|canceled) break;; esac
  sleep 0.5
done
[ "$(PSQL "SELECT state FROM eter.jobs WHERE id=$J1")" = "succeeded" ] || fail "job $J1 should have succeeded"
[ "$(PSQL "SELECT state FROM eter.jobs WHERE id=$J2")" = "succeeded" ] || fail "job $J2 should have succeeded"
OVERLAP=$(PSQL "SELECT (SELECT started_at FROM eter.jobs WHERE id=$J2) < (SELECT finished_at FROM eter.jobs WHERE id=$J1)")
[ "$OVERLAP" = "f" ] || fail "jobs overlapped, single-flight violated"
pass "queued jobs ran strictly serialized (started_at($J2) >= finished_at($J1))"

echo "==> SCHEDULED CYCLE: the orchestrator takes backups on its own (no daemon)"
stop_orch
NSCHED=$(PSQL "SELECT count(*) FROM eter.storage_snapshots WHERE kind='scheduled'")
# 1s cadence + a 1-byte WAL gate so the cycle actually backs up in a test-sized DB.
start_orch ETER_SCHEDULE_INTERVAL_SEC=1 ETER_SNAPSHOT_MIN_WAL_BYTES=1
for i in $(seq 1 60); do
  [ "$(PSQL "SELECT count(*) FROM eter.storage_snapshots WHERE kind='scheduled'")" -gt "$NSCHED" ] && break
  sleep 0.5
done
[ "$(PSQL "SELECT count(*) FROM eter.storage_snapshots WHERE kind='scheduled'")" -gt "$NSCHED" ] \
  || fail "no scheduled backup appeared, orchestrator cycle scheduling broken"
pass "scheduled cycle took a backup through the job lane"

echo "==> CRASH RECOVERY: kill -9 mid-restore → boot fails the orphan + sweeps debris"
stop_orch
cat > "$WORK/slow-storage.sh" <<EOF
#!/bin/sh
echo '{"comp":"storage","msg":"slow stub running"}' >&2
sleep 300
EOF
chmod +x "$WORK/slow-storage.sh"
start_orch ETER_STORAGE_BIN="$WORK/slow-storage.sh"
JC=$(eter recover-table public.widgets --no-wait --json | jget job_id)
for i in $(seq 1 50); do
  [ "$(PSQL "SELECT state FROM eter.jobs WHERE id=$JC")" = "running" ] && break
  sleep 0.2
done
[ "$(PSQL "SELECT state FROM eter.jobs WHERE id=$JC")" = "running" ] || fail "crash-test job never started"
mkdir -p "$BACKUPS/.restore/job-$JC"     # simulate restore debris the SIGKILL'd job left
mkdir -p "$BACKUPS/.restore/rec_manual"  # simulate a MANUAL sidecar recovery in flight
kill -9 "$ORCH_PID"; wait "$ORCH_PID" 2>/dev/null || true; ORCH_PID=""
start_orch   # normal binary again
[ "$(PSQL "SELECT state FROM eter.jobs WHERE id=$JC")" = "failed" ] || fail "orphaned running job not failed at boot"
PSQL "SELECT error FROM eter.jobs WHERE id=$JC" | grep -q "restarted" || fail "orphan failure reason missing"
[ ! -d "$BACKUPS/.restore/job-$JC" ] || fail "job restore debris not swept at boot"
[ -d "$BACKUPS/.restore/rec_manual" ] || fail "manual sidecar restore dir must NOT be swept (kills an in-flight manual recovery)"
rmdir "$BACKUPS/.restore/rec_manual"
[ -z "$(ls -A "$BACKUPS/.restore" 2>/dev/null)" ] || fail "unexpected restore debris left: $(ls -A "$BACKUPS/.restore")"
pass "orphaned job failed truthfully at boot; job debris swept, manual rec_* spared"

echo "==> CANCEL: a queued job cancels cleanly"
stop_orch
start_orch ETER_STORAGE_BIN="$WORK/slow-storage.sh"
JA=$(eter snapshot --no-wait --json | jget job_id)     # occupies the lane (slow stub)
JB=$(eter snapshot --no-wait --json | jget job_id)     # stays queued behind it
eter jobs "$JB" --cancel >/dev/null || fail "cancel of queued job failed"
[ "$(PSQL "SELECT state FROM eter.jobs WHERE id=$JB")" = "canceled" ] || fail "queued job not canceled"
eter jobs "$JA" --cancel >/dev/null || fail "cancel of running job failed"
for i in $(seq 1 60); do
  [ "$(PSQL "SELECT state FROM eter.jobs WHERE id=$JA")" = "canceled" ] && break
  sleep 0.5
done
[ "$(PSQL "SELECT state FROM eter.jobs WHERE id=$JA")" = "canceled" ] || fail "running job not canceled (SIGTERM/KILL path)"
pass "queued + running jobs cancel; states recorded"

echo "==> JOB TIMEOUT: a hung sidecar cannot wedge the lane (ETER_JOB_TIMEOUT_SEC)"
stop_orch
start_orch ETER_STORAGE_BIN="$WORK/slow-storage.sh" ETER_JOB_TIMEOUT_SEC=2
JT=$(eter snapshot --no-wait --json | jget job_id)
for i in $(seq 1 60); do
  [ "$(PSQL "SELECT state FROM eter.jobs WHERE id=$JT")" = "failed" ] && break
  sleep 0.5
done
[ "$(PSQL "SELECT state FROM eter.jobs WHERE id=$JT")" = "failed" ] || fail "hung job did not fail on timeout (state: $(PSQL "SELECT state FROM eter.jobs WHERE id=$JT"))"
PSQL "SELECT error FROM eter.jobs WHERE id=$JT" | grep -q "timed out" || fail "timeout not surfaced in the job error"
pass "hung job failed after the timeout with a clear reason"

echo ""
echo "ALL ORCHESTRATOR (SINGLE ENTRY POINT + MANAGED RESTORES) CHECKS PASSED ✅"
