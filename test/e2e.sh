#!/usr/bin/env bash
# EterDB Phase 1 end-to-end, ON THE EXTERNALIZED (TWO-DB) ARCHITECTURE.
# Self-contained: spins a TENANT cluster (user data) + a separate EterDB-owned
# META store (durable metadata), runs the demo e-commerce 2:00 PM incident with the
# capture sidecar streaming history → store, and asserts the frozen Phase-1 agent
# surface via the real CLI (cross-DB undo):
#   - clean undo restores exact pre-incident state; unrelated writes survive
#   - external references (Stripe) surfaced; untouched by the DB-only undo
#   - dry-run does not mutate; dependent → exit 4; cascade resolves; unknown → exit 3
#   - the TENANT holds ZERO durable metadata (it all is in the store)
#
# NB: the incident is driven deterministically (the same writes `eter demo`
# fires) rather than via `eter demo up`, whose monolithic drop→create→track→
# incident flow races the sidecar's catalog reconcile in sidecar mode. Overlapping
# DML coverage also is in test/meta-externalize.sh; this adds the Phase-1 agent
# surface (external refs, dry-run, exit codes) on the externalized substrate.
set -euo pipefail
cd "$(dirname "$0")/.."

# Observe mode is the shipping substrate → run on the PATCHED PG (host .pgbuild18),
# not stock Homebrew PG. Override PGBIN=... if your patched build is elsewhere.
PGBIN="${PGBIN:-$PWD/.pgbuild18/bin}"
[ -x "$PGBIN/postgres" ] || { echo "patched Postgres not found at $PGBIN, build it per pg/README.md"; exit 1; }
T_PORT="${ETER_TENANT_PORT:-5445}"; M_PORT="${ETER_META_PORT:-5446}"
T_DATA="$PWD/.pgdata-e2e-tenant"; M_DATA="$PWD/.pgdata-e2e-meta"
TENANT_URL="postgres://eter:eter@localhost:$T_PORT/eter"
META_URL="postgres://eter:eter@localhost:$M_PORT/eter_meta"
SLOT=eter_slot
PSQL_T="$PGBIN/psql $TENANT_URL -tAqc"
PSQL_M="$PGBIN/psql $META_URL -tAqc"
go build -C cli -o eter . || { echo "go build of the eter CLI failed (need Go installed)"; exit 1; }
ETER="env ETER_META_URL=$META_URL $PWD/cli/eter --db $TENANT_URL"
SIDECAR_PID=""
# Build the Go capture sidecar once (static binary → clean kill on teardown).
CAPBIN="$PWD/sidecars/bin/eter-capture"
( cd "$PWD/sidecars" && CGO_ENABLED=0 go build -o bin/eter-capture ./capture ) || { echo "go build capture failed"; exit 1; }

pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; exit 1; }
jget() { node -e 'const o=JSON.parse(require("fs").readFileSync(0,"utf8"));let v=o;for(const k of process.argv[1].split("."))v=v[k];process.stdout.write(String(v))' "$1"; }

stop_sidecar() { if [ -n "${SIDECAR_PID:-}" ]; then kill "$SIDECAR_PID" 2>/dev/null || true; wait "$SIDECAR_PID" 2>/dev/null || true; SIDECAR_PID=""; fi; }
cleanup() {
  stop_sidecar
  "$PGBIN/pg_ctl" -D "$T_DATA" -m immediate stop >/dev/null 2>&1 || true
  "$PGBIN/pg_ctl" -D "$M_DATA" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$T_DATA" "$M_DATA"
}
trap cleanup EXIT

wait_sidecar() {
  for i in $(seq 1 60); do
    [ "$($PSQL_T "SELECT coalesce((SELECT active FROM pg_replication_slots WHERE slot_name='$SLOT'),false)")" = "t" ] && return 0
    sleep 0.25
  done
  fail "sidecar slot never became active (see $T_DATA/capture.log)"
}
# wait until a count query against the STORE is >= min and stable.
wait_store() {
  local q="$1" min="$2" prev=-1 stable=0 cur i
  for i in $(seq 1 120); do
    cur=$($PSQL_M "$q")
    if [ "$cur" = "$prev" ] && [ "$cur" -ge "$min" ]; then stable=$((stable+1)); else stable=0; fi
    [ "$stable" -ge 3 ] && return 0
    prev="$cur"; sleep 0.25
  done
  fail "store drain timeout (q=[$q] min=$min last=$cur; see $T_DATA/capture.log)"
}

echo "==> spinning up TENANT (:$T_PORT, logical) + META store (:$M_PORT)"
rm -rf "$T_DATA" "$M_DATA"
"$PGBIN/initdb" -D "$T_DATA" -U eter --auth-local=trust --auth-host=trust >/dev/null
cat >>"$T_DATA/postgresql.conf" <<EOF
port = $T_PORT
listen_addresses = 'localhost'
wal_level = logical
max_wal_senders = 8
max_replication_slots = 8
eter_observe_mode = on
max_pred_locks_per_transaction = 4096
EOF
"$PGBIN/pg_ctl" -D "$T_DATA" -l "$T_DATA/server.log" -w start >/dev/null
"$PGBIN/createdb" -h localhost -p "$T_PORT" -U eter eter
"$PGBIN/initdb" -D "$M_DATA" -U eter --auth-local=trust --auth-host=trust >/dev/null
printf 'port = %s\nlisten_addresses = '"'"'localhost'"'"'\n' "$M_PORT" >> "$M_DATA/postgresql.conf"
"$PGBIN/pg_ctl" -D "$M_DATA" -l "$M_DATA/server.log" -w start >/dev/null
"$PGBIN/createdb" -h localhost -p "$M_PORT" -U eter eter_meta
"$PGBIN/psql" "$TENANT_URL" -q -f ext/eter/eter.sql >/dev/null
"$PGBIN/psql" "$TENANT_URL" -q -f demo/schema.sql >/dev/null
"$PGBIN/psql" "$META_URL"   -q -f ext/eter/eter.sql >/dev/null
pass "tenant + meta store up; engine applied to both, demo schema on tenant"

# Track in sidecar mode BEFORE starting the sidecar (so it boots with the catalog
# populated, reliable capture, no reconcile race), then start it.
$PSQL_T "SET eter.capture_mode='sidecar'; SELECT eter.track_all();" >/dev/null
$PSQL_T "SELECT pg_create_logical_replication_slot('$SLOT','pgoutput')" >/dev/null
DATABASE_URL="$TENANT_URL" ETER_META_URL="$META_URL" "$CAPBIN" >"$T_DATA/capture.log" 2>&1 &
SIDECAR_PID=$!
wait_sidecar
pass "capture sidecar streaming tenant → store"

# Seed the e-commerce demo (post-track, so it is captured) + a little unrelated
# background traffic that must survive undo.
$PSQL_T "
  INSERT INTO customers(name,email) SELECT 'cust'||g, 'c'||g||'@example.com' FROM generate_series(1,5) g;
  INSERT INTO products(name,price_cents) SELECT 'prod'||g, 1000*g FROM generate_series(1,4) g;
  INSERT INTO orders(customer_id,status,total_cents) SELECT 1+(g%5),'placed',5000+g*1300 FROM generate_series(1,20) g;
  INSERT INTO invoices(order_id,amount_cents,status,stripe_charge_id)
    SELECT id, total_cents, 'issued', 'ch_'||substr(md5(id::text),1,24) FROM orders;" >/dev/null
$PSQL_T "UPDATE orders SET status='shipped' WHERE id<=5" >/dev/null   # unrelated background write
SHIPPED_BEFORE=$($PSQL_T "SELECT count(*) FROM orders WHERE status='shipped'")
CHARGE_BEFORE=$($PSQL_T "SELECT stripe_charge_id FROM invoices ORDER BY id LIMIT 1")

# ===========================================================================
echo "==> CLEAN UNDO scenario"
TXID=$($PSQL_T "WITH u AS (UPDATE invoices SET amount_cents=amount_cents*10 RETURNING 1) SELECT txid_current() FROM u LIMIT 1")   # the 2:00 PM incident
CORRUPT=$($PSQL_T "SELECT count(*) FROM invoices i JOIN orders o ON o.id=i.order_id WHERE i.amount_cents=o.total_cents*10")
[ "$CORRUPT" -gt 0 ] || fail "incident did not corrupt invoices"
wait_store "SELECT count(*) FROM eter.history WHERE txid=$TXID AND op='U' AND table_name='invoices'" 20
pass "incident txid=$TXID corrupted $CORRUPT invoices (captured to the store)"

PLAN=$($ETER preview "$TXID" --json)
[ "$(echo "$PLAN" | jget classification)" = "clean" ] || fail "expected clean classification"
[ "$(echo "$PLAN" | jget external_refs.count)" -ge 20 ] || fail "expected >=20 external refs surfaced"
pass "preview = clean; surfaced $(echo "$PLAN" | jget external_refs.count) external Stripe references"

$ETER undo "$TXID" --json >/dev/null   # dry-run (no --apply) must not mutate
[ "$($PSQL_T "SELECT count(*) FROM invoices i JOIN orders o ON o.id=i.order_id WHERE i.amount_cents=o.total_cents*10")" = "$CORRUPT" ] || fail "dry-run mutated data"
pass "dry-run did not mutate"

[ "$(echo "$($ETER undo "$TXID" --apply --json)" | jget status)" = "applied" ] || fail "undo not applied"
[ "$($PSQL_T "SELECT count(*) FROM invoices i JOIN orders o ON o.id=i.order_id WHERE i.amount_cents<>o.total_cents")" = "0" ] || fail "undo did not restore invoices"
[ "$($PSQL_T "SELECT count(*) FROM orders WHERE status='shipped'")" = "$SHIPPED_BEFORE" ] || fail "unrelated 'shipped' orders changed by undo"
[ "$($PSQL_T "SELECT stripe_charge_id FROM invoices ORDER BY id LIMIT 1")" = "$CHARGE_BEFORE" ] || fail "undo altered an external Stripe charge id"
pass "clean undo restored invoices exactly (cross-DB); unrelated writes + external charge ids untouched"

echo "==> not-found exit code"
set +e; $ETER preview 999999999 --json >/dev/null 2>&1; CODE=$?; set -e
[ "$CODE" = "3" ] || fail "expected exit 3 for unknown txid, got $CODE"
pass "unknown txid -> exit 3"

# ===========================================================================
echo "==> DEPENDENT scenario (refusal + cascade)"
TXID2=$($PSQL_T "WITH u AS (UPDATE invoices SET amount_cents=amount_cents*10 RETURNING 1) SELECT txid_current() FROM u LIMIT 1")
$PSQL_T "UPDATE invoices SET status='paid' WHERE id=1" >/dev/null   # later write to a corrupted row → ww conflict
wait_store "SELECT count(*) FROM eter.history WHERE op='U' AND table_name='invoices' AND NOT is_undo AND txid IN ($TXID2)" 20
[ "$($ETER preview "$TXID2" --json | jget classification)" = "dependent" ] || fail "expected dependent classification"
pass "preview = dependent (later write to a corrupted invoice)"

set +e; $ETER undo "$TXID2" --apply --json >/dev/null 2>&1; CODE2=$?; set -e
[ "$CODE2" = "4" ] || fail "expected exit 4 (dependent) in clean_only, got $CODE2"
pass "clean_only undo refused the dependent (exit 4)"

[ "$(echo "$($ETER undo "$TXID2" --apply --cascade --json)" | jget status)" = "applied" ] || fail "cascade undo failed"
[ "$($PSQL_T "SELECT count(*) FROM invoices i JOIN orders o ON o.id=i.order_id WHERE i.amount_cents<>o.total_cents")" = "0" ] || fail "cascade did not restore invoices"
pass "cascade reverted incident + dependent; invoices restored (cross-DB)"

# ===========================================================================
echo "==> tenant holds zero durable EterDB history"
[ "$($PSQL_T "SELECT count(*) FROM eter.history")" = "0" ] || fail "tenant has history rows, expected ZERO (it all is in the store)"
[ "$($PSQL_M "SELECT count(*) FROM eter.history WHERE NOT is_undo")" -ge 20 ] || fail "store is missing the captured history"
pass "tenant eter.history empty; the incident history is in the store"

echo ""
echo "ALL PHASE 1 E2E (TWO-DB / EXTERNALIZED) CHECKS PASSED ✅"
