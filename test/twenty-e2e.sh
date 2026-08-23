#!/bin/sh
# EterDB, Twenty-CRM realistic-data e2e.
# RUN ON THE EXTERNALIZED (TWO-DB) ARCHITECTURE. Runs LOCALLY (macOS or Linux)
# with no VM, no ZFS, no root, the storage substrate is pg_basebackup + WAL
# replay (ADR 0003), plain unprivileged operations on plain directories.
#
# Like test/inventree-e2e.sh (which loads InvenTree's fixture rather than running
# Django), this loads a FAITHFUL Twenty-shaped schema rather than running Twenty's
# NestJS app. The schema mirrors Twenty exactly where it matters: a per-workspace schema
# `workspace_<id>` holding an `opportunity` table whose money is a currency composite
# (amountAmountMicros bigint + amountCurrencyCode text), stage enum text, closeDate
# timestamptz. It then runs the incident scenarios through the REAL eter mechanics,
# using the SQL fixtures in test/twenty/:
#
#   A. Dropped-column recovery, a botched migration DROPs opportunity."closeDate";
#      recovered by PK from a pre-DDL base backup (storage sidecar).
#   B. Destructive row edits → faulty quarterly report, a buggy job WIPES CUSTOMER deal
#      amounts to 0 (each its own txn), destroying the originals; the Quarterly-Revenue-
#      by-Stage aggregate collapses to $0; cohort-revert by value+shape+time restores
#      each deal's exact prior value from history; a concurrent legit edit survives.
#   C. Tier-2 read-derived decision, a READ COMMITTED job reads a corrupted amount
#      and writes a forecast decision to another table (no FK back); surfaced as a
#      read-dependent (derived IN THE STORE); clean_only undo refuses.
#   + final: the TENANT holds 0 history / 0 dependencies / 0 ssi_reads.
#
# Requires the patched Postgres (PG18) built into .pgbuild18 (see pg/README.md);
# override with PGBUILD=/path/to/prefix.
#   bash test/twenty-e2e.sh
set -eu
cd "$(dirname "$0")/.."
ROOT=$PWD

PGBIN="${PGBUILD:-$ROOT/.pgbuild18}/bin"
[ -x "$PGBIN/postgres" ] || { echo "patched Postgres not found at $PGBIN, see pg/README.md"; exit 1; }
export PATH="$PGBIN:$PATH"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/eter-twenty.XXXXXX")
MP=$WORK/pgtenant; WAL=$WORK/walarchive; BACKUPS=$WORK/backups; PORT=5511
META_MP=$WORK/pgmeta;                                           META_PORT=5512
DBURL="postgres://eter@localhost:$PORT/eter"
META_URL="postgres://eter@localhost:$META_PORT/eter_meta"
SLOT=eter_slot
WS=workspace_demo                       # the simulated Twenty workspace schema
command -v go >/dev/null || { echo "Go toolchain required"; exit 1; }
CAP=$WORK/eter-capture
STORE=$WORK/eter-storage
( cd "$ROOT/sidecars" && CGO_ENABLED=0 go build -o "$CAP" ./capture \
  && CGO_ENABLED=0 go build -o "$STORE" ./storage ) || { echo "go build sidecars failed"; exit 1; }
export ETER_STORAGE_BIN="$STORE"   # so `eter recover-*` / `eter snapshot` proxy to it
CLI=$WORK/eter
CAP_PID=""
export DATABASE_URL="$DBURL"
export ETER_META_URL="$META_URL"
export ETER_BACKUP_DIR="$BACKUPS" ETER_TMP_PORT=5598 ETER_WAL_ARCHIVE="$WAL"
export ETER_PG_BINDIR="$PGBIN"

pass(){ echo "  ✓ $1"; }
fail(){ echo "  ✗ $1"; exit 1; }
PSQL(){   psql "$DBURL" -tAqc "$1"; }
PSQL_M(){ psql "$META_URL" -tAqc "$1"; }
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
wait_store(){ q="$1"; min="$2"; prev=-1; stable=0; i=0; while [ $i -lt 200 ]; do cur=$(PSQL_M "$q"); if [ "$cur" = "$prev" ] && [ "$cur" -ge "$min" ]; then stable=$((stable+1)); else stable=0; fi; [ "$stable" -ge 3 ] && return 0; prev="$cur"; i=$((i+1)); sleep 0.25; done; fail "store drain timeout (q=[$q] min=$min last=$cur)"; }

echo "==> build eter_ssi against the patched engine"
PGCFG="$PGBIN/pg_config"
rm -rf "$WORK/eter_ssi" && cp -r "$ROOT/ext/eter_ssi" "$WORK/eter_ssi"
# Don't pipe make through tail, that masks its exit code (a stale cached PG build
# whose headers lack the seqscan hook fails to compile here, and we must NOT proceed
# on the old .so). Capture to a log and surface it on failure.
make -C "$WORK/eter_ssi" PG_CONFIG="$PGCFG" clean install >"$WORK/eter_ssi_make.log" 2>&1 \
  || { tail -20 "$WORK/eter_ssi_make.log"; fail "eter_ssi build failed"; }
pass "eter_ssi built + installed (observe-capable)"

echo "==> TENANT: patched PG18, logical decoding + WAL archiving + observe (plain dirs, no ZFS, no root)"
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
[ "$(PSQL "SHOW eter_observe_mode")" = "on" ] || fail "observe mode not on"
pass "tenant up on PATCHED PG; OBSERVE @ READ COMMITTED"

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
pass "meta store up"

echo "==> seed a FAITHFUL Twenty-shaped workspace schema ($WS.opportunity)"
psql "$DBURL" -q -v ON_ERROR_STOP=1 <<SQL >/dev/null
CREATE SCHEMA $WS;
CREATE TABLE $WS.opportunity (
  id                  text PRIMARY KEY,
  name                text NOT NULL,
  "stage"             text NOT NULL,
  "amountAmountMicros" bigint NOT NULL,
  "amountCurrencyCode" text NOT NULL DEFAULT 'USD',
  "closeDate"         timestamptz,
  -- external side-effects (Act IV): the billing charge + receipt email a closed-won
  -- deal triggered, surfaced by eter.external_refs (NOT reversed by undo).
  "stripeChargeId"    text,
  "confirmationEmail" text
);
CREATE TABLE $WS.forecast_decision (id text PRIMARY KEY, opportunity_id text, decision text);
-- 30 current-quarter CUSTOMER deals (\$50k each), plus 10 non-CUSTOMER + 10 last-quarter
-- deals that must stay UNTOUCHED by a current-quarter-CUSTOMER incident.
INSERT INTO $WS.opportunity (id, name, "stage", "amountAmountMicros", "closeDate")
SELECT 'won-'||g, 'Deal '||g, 'CUSTOMER', 50000::bigint*1000000,
       date_trunc('quarter', now()) + interval '10 days'
FROM generate_series(1,30) g;
INSERT INTO $WS.opportunity (id, name, "stage", "amountAmountMicros", "closeDate")
SELECT 'open-'||g, 'Open '||g, 'PROPOSAL', 30000::bigint*1000000,
       date_trunc('quarter', now()) + interval '20 days'
FROM generate_series(1,10) g;
INSERT INTO $WS.opportunity (id, name, "stage", "amountAmountMicros", "closeDate")
SELECT 'old-'||g, 'Old '||g, 'CUSTOMER', 40000::bigint*1000000,
       date_trunc('quarter', now()) - interval '20 days'
FROM generate_series(1,10) g;
-- closed-won deals carry an external billing charge + confirmation email (Act IV).
UPDATE $WS.opportunity
   SET "stripeChargeId"    = 'ch_' || substr(md5(random()::text || id), 1, 24),
       "confirmationEmail" = 'deal+' || substr(md5(id), 1, 8) || '@acme.example'
 WHERE "stage" = 'CUSTOMER';
SQL
NOPP=$(PSQL "SELECT count(*) FROM $WS.opportunity")
[ "$NOPP" = "50" ] || fail "seed loaded $NOPP opportunities (expected 50)"
pass "seeded $NOPP Twenty-shaped opportunities (30 current-quarter CUSTOMER)"

echo "==> track (sidecar mode) + report view + start capture sidecar"
PSQL "SET eter.capture_mode='sidecar'; SELECT eter.track_all();" >/dev/null
PSQL "SELECT eter.enable_ddl_logging()" >/dev/null
psql "$DBURL" -q -v ON_ERROR_STOP=1 -f "$ROOT"/test/twenty/10-report.sql >/dev/null
PSQL "SELECT pg_create_logical_replication_slot('$SLOT','pgoutput')" >/dev/null
DATABASE_URL="$DBURL" ETER_META_URL="$META_URL" "$CAP" >"$MP/capture.log" 2>&1 & CAP_PID=$!
wait_cap
pass "capture streaming to store; $(PSQL "SELECT count(*) FROM eter.tracked") tables tracked; report function defined"

# Actual CUSTOMER revenue for the current quarter (whole units) BEFORE any incident.
REV0=$(PSQL "SELECT coalesce(sum(revenue),0)::text FROM eter_demo.quarterly_revenue() WHERE stage='CUSTOMER'")
[ "$REV0" = "1500000.00" ] || fail "baseline CUSTOMER revenue unexpected ($REV0; want 1500000.00 = 30 × 50k)"
pass "baseline Quarterly-Revenue-by-Stage CUSTOMER = $REV0"

# ===========================================================================
echo "==> SCENARIO A: dropped-column recovery (opportunity.\"closeDate\")"
eter snapshot manual >/dev/null
CDB=$(PSQL "SELECT md5(string_agg(id||':'||coalesce(\"closeDate\"::text,''),',' ORDER BY id)) FROM $WS.opportunity")
psql "$DBURL" -q -v ON_ERROR_STOP=1 -f "$ROOT"/test/twenty/30-incident-drop-column.sql >/dev/null
[ "$(PSQL "SELECT count(*) FROM information_schema.columns WHERE table_schema='$WS' AND table_name='opportunity' AND column_name='closeDate'")" = "0" ] || fail "closeDate not actually dropped"
# The DDL log is forwarded tenant→store by the capture sidecar on its interval; wait for it.
wait_store "SELECT count(*) FROM eter.ddl_log WHERE is_destructive AND object_identity LIKE '%closeDate%'" 1
eter recover-column "$WS.opportunity" closeDate >/dev/null 2>&1
[ "$(PSQL "SELECT count(*) FROM information_schema.columns WHERE table_schema='$WS' AND table_name='opportunity' AND column_name='closeDate'")" = "1" ] || fail "closeDate not recovered"
[ "$(PSQL "SELECT md5(string_agg(id||':'||coalesce(\"closeDate\"::text,''),',' ORDER BY id)) FROM $WS.opportunity")" = "$CDB" ] || fail "recovered closeDate values differ from originals"
pass "dropped opportunity.\"closeDate\" recovered for all $NOPP deals, values identical (pre-DDL snapshot)"

# ===========================================================================
echo "==> SCENARIO B: bad row edits → faulty quarterly report → cohort heal"
# A concurrent LEGITIMATE edit to a DIFFERENT deal must survive the revert.
PSQL "UPDATE $WS.opportunity SET name='Renamed (legit)' WHERE id='open-1'" >/dev/null
T0=$(PSQL "SELECT now()")
# The DESTRUCTIVE bug: wipes amountAmountMicros to 0 on every current-quarter CUSTOMER deal,
# each its own txn. The original values are GONE, only the before-image in history can
# restore them. Reuses the actual camera script.
psql "$DBURL" -q -v ON_ERROR_STOP=1 -f "$ROOT"/test/twenty/20-incident-bad-edits.sql >/dev/null
wait_store "SELECT count(*) FROM eter.history WHERE op='U' AND table_name='$WS.opportunity' AND committed_at >= '$T0'::timestamptz" 30
REVBAD=$(PSQL "SELECT coalesce(sum(revenue),0)::text FROM eter_demo.quarterly_revenue() WHERE stage='CUSTOMER'")
[ "$REVBAD" = "0.00" ] || fail "report should collapse to 0.00 (got $REVBAD)"
pass "destructive bug wiped 30 CUSTOMER deals to 0 → report collapsed: CUSTOMER = $REVBAD (was $REV0)"
# Cohort by the destructive value (0) + statement-shape + time. Undo restores each
# deal's exact prior value from history, nothing else could (the value was destroyed).
PREV=$(eter cohort --table "$WS.opportunity" --since "$T0" --where '{"amountAmountMicros":"0"}' --json | jget txn_count)
[ "$PREV" = "30" ] || fail "cohort preview should find 30 txns (got $PREV)"
eter undo-cohort --table "$WS.opportunity" --since "$T0" --where '{"amountAmountMicros":"0"}' --apply >/dev/null || fail "cohort undo failed"
REVFIX=$(PSQL "SELECT coalesce(sum(revenue),0)::text FROM eter_demo.quarterly_revenue() WHERE stage='CUSTOMER'")
[ "$REVFIX" = "$REV0" ] || fail "report not healed (got $REVFIX, want $REV0)"
[ "$(PSQL "SELECT name FROM $WS.opportunity WHERE id='open-1'")" = "Renamed (legit)" ] || fail "concurrent legit edit was clobbered by the revert"
pass "cohort-reverted 30 destructive txns → exact prior values restored from history ($REVFIX); concurrent legit edit survived"

# ===========================================================================
echo "==> SCENARIO C: tier-2 read-derived forecast decision surfaced"
OID=$(PSQL "SELECT id FROM $WS.opportunity WHERE stage='CUSTOMER' ORDER BY id LIMIT 1")
BADTX=$(PSQL "WITH u AS (UPDATE $WS.opportunity SET \"amountAmountMicros\"=0 WHERE id='$OID' RETURNING 1) SELECT txid_current() FROM u")
wait_store "SELECT count(*) FROM eter.history WHERE txid=$BADTX AND op='U' AND table_name='$WS.opportunity'" 1
psql "$DBURL" -q >/dev/null <<SQL
BEGIN;  -- default READ COMMITTED; observe captures the predicate read
SELECT "amountAmountMicros" FROM $WS.opportunity WHERE id='$OID';   -- reads the bad 0
INSERT INTO $WS.forecast_decision(id, opportunity_id, decision) VALUES ('f1', '$OID', 'downgrade forecast: deal value is 0');
COMMIT;
SQL
wait_store "SELECT count(*) FROM eter.history WHERE table_name='$WS.forecast_decision' AND NOT is_undo" 1
wait_store "SELECT count(*) FROM eter.read_set" 1
[ "$(eter preview "$BADTX" --json | jget classification)" = "dependent" ] || fail "bad write should be dependent via the read-derived forecast"
set +e; eter undo "$BADTX" --apply >/dev/null 2>&1; RC=$?; set -e
[ "$RC" != "0" ] || fail "clean_only undo of a dependent should refuse"
[ "$(PSQL "SELECT count(*) FROM $WS.forecast_decision WHERE opportunity_id='$OID'")" = "1" ] || fail "the derived forecast row was disturbed"
pass "forecast decision surfaced as read-dependent (derived in store); undo refused, tier-2 boundary holds"

# ===========================================================================
echo "==> ACT IV: external effects surfaced (NOT reversed)"
# The wiped deal carries a Stripe charge + confirmation email; preview must surface
# both from the affected row so the operator sees what undo does NOT reverse.
ERC=$(eter preview "$BADTX" --json | jget external_refs.count)
[ "$ERC" = "2" ] || fail "external_refs should surface the stripe charge + email on the affected deal (got $ERC)"
EKINDS=$(eter preview "$BADTX" --json | node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{const o=JSON.parse(s);process.stdout.write(Object.keys(o.external_refs.kinds).sort().join(","))})')
[ "$EKINDS" = "email,stripe" ] || fail "external_refs kinds should be email+stripe (got $EKINDS)"
pass "preview surfaces 2 external refs ($EKINDS) on the affected deal, DB undone, external side-effects flagged"

# ===========================================================================
echo "==> TENANT IS CLEAN: zero durable EterDB metadata in the tenant DB"
i=0; while [ "$(PSQL "SELECT count(*) FROM eter.ssi_reads")" != "0" ]; do i=$((i+1)); [ $i -gt 120 ] && fail "forwarder never cleared tenant ssi_reads"; sleep 0.5; done
[ "$(PSQL "SELECT count(*) FROM eter.history")" = "0" ]      || fail "tenant has history rows, expected ZERO"
[ "$(PSQL "SELECT count(*) FROM eter.dependencies")" = "0" ] || fail "tenant has dependency rows, expected ZERO"
pass "tenant: 0 history / 0 dependencies / 0 ssi_reads, full cycle ran with all durable metadata in the store"

echo ""
echo "ALL TWENTY-CRM E2E (TWO-DB / EXTERNALIZED) CHECKS PASSED ✅"
