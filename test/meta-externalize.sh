#!/usr/bin/env bash
# EterDB Phase 3, externalized-metadata test (local, no Docker, no ZFS).
#
# Proves the "Externalize durable metadata" increment (PLAN.md): eter.* durable
# metadata is in a SEPARATE EterDB-owned Postgres INSTANCE, the tenant DB
# carries zero history on its commit path, and undo stays correct across the
# cross-DB boundary.
#
# Topology, two throwaway clusters, each on its own datadir + port:
#   TENANT (:5434, wal_level=logical), user tables + the SSI/capture surface +
#           the compensation-apply entrypoint (eter.undo_rows). No history.
#   META   (:5435), durable eter.* (history, capture_state,
#           undo_txn, markers) + the read-side engine (preview_undo runs here).
# The capture sidecar decodes the TENANT and writes history into the META store
# (DATABASE_URL=tenant, ETER_META_URL=meta). The CLI reads/previews from META,
# applies compensation in TENANT.
#
# Asserts: (1) history is written to META = the workload's writes; (2) TENANT has ZERO
# history rows on the commit path; (3) CLI log/show/status read from META; (4)
# clean undo restores exactly, applied in TENANT from META history; (5) a dependent
# (ww) undo refuses in clean_only (exit 4) and (6) cascade resolves. Both clusters
# are torn down on exit; the machine's main Postgres is untouched.
set -euo pipefail
cd "$(dirname "$0")/.."

# Observe mode is the shipping substrate → run on the PATCHED PG (host .pgbuild18),
# not stock Homebrew PG. Override with PGBIN=... if your patched build is elsewhere.
PGBIN="${PGBIN:-$PWD/.pgbuild18/bin}"
[ -x "$PGBIN/postgres" ] || { echo "patched Postgres not found at $PGBIN, build it per pg/README.md"; exit 1; }
TENANT_PORT="${ETER_TENANT_PORT:-5434}"
META_PORT="${ETER_META_PORT:-5435}"
TENANT_DATA="$PWD/.pgdata-mx-tenant"
META_DATA="$PWD/.pgdata-mx-meta"
TENANT_URL="postgres://eter:eter@localhost:$TENANT_PORT/eter"
META_URL="postgres://eter:eter@localhost:$META_PORT/eter_meta"
SLOT=eter_slot
PSQL_T="$PGBIN/psql $TENANT_URL -tAqc"
PSQL_M="$PGBIN/psql $META_URL -tAqc"
# CLI in two-DB mode: --db = tenant, ETER_META_URL = the external store.
go build -C cli -o eter . || { echo "go build of the eter CLI failed (need Go installed)"; exit 1; }
ETER="env ETER_META_URL=$META_URL $PWD/cli/eter --db $TENANT_URL"
SIDECAR_PID=""
# Build the Go capture sidecar once (static binary → clean kill on teardown).
CAPBIN="$PWD/sidecars/bin/eter-capture"
( cd "$PWD/sidecars" && CGO_ENABLED=0 go build -o bin/eter-capture ./capture ) || { echo "go build capture failed"; exit 1; }

pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; exit 1; }
jget() { node -e 'const o=JSON.parse(require("fs").readFileSync(0,"utf8"));let v=o;for(const k of process.argv[1].split("."))v=v[k];process.stdout.write(String(v))' "$1"; }

stop_sidecar() {
  if [ -n "${SIDECAR_PID:-}" ]; then
    kill "$SIDECAR_PID" 2>/dev/null || true
    wait "$SIDECAR_PID" 2>/dev/null || true
    SIDECAR_PID=""
  fi
}
cleanup() {
  stop_sidecar
  "$PGBIN/pg_ctl" -D "$TENANT_DATA" -m immediate stop >/dev/null 2>&1 || true
  "$PGBIN/pg_ctl" -D "$META_DATA"   -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$TENANT_DATA" "$META_DATA"
}
trap cleanup EXIT

start_sidecar() {
  DATABASE_URL="$TENANT_URL" ETER_META_URL="$META_URL" \
    "$CAPBIN" >"$TENANT_DATA/capture.log" 2>&1 &
  SIDECAR_PID=$!
}
wait_sidecar() {
  local i a
  for i in $(seq 1 60); do
    a=$($PSQL_T "SELECT coalesce((SELECT active FROM pg_replication_slots WHERE slot_name='$SLOT'),false)")
    [ "$a" = "t" ] && return 0
    sleep 0.25
  done
  fail "sidecar slot never became active (see $TENANT_DATA/capture.log)"
}
# Wait until a count query is >= min and stable. $3 picks the cluster: M (meta,
# default) or T (tenant, e.g. for the writer-index projection).
wait_drain() { # $1 = count SQL, $2 = minimum expected, $3 = M|T
  local q="$1" min="$2" psql="$PSQL_M" prev=-1 stable=0 cur i
  [ "${3:-M}" = "T" ] && psql="$PSQL_T"
  for i in $(seq 1 120); do
    cur=$($psql "$q")
    if [ "$cur" = "$prev" ] && [ "$cur" -ge "$min" ]; then stable=$((stable+1)); else stable=0; fi
    [ "$stable" -ge 3 ] && return 0
    prev="$cur"; sleep 0.25
  done
  fail "drain timeout (q=[$q] min=$min last=$cur; see $TENANT_DATA/capture.log)"
}

seed() {
  $PSQL_T "
    INSERT INTO customers(name,email) SELECT 'cust'||g, 'c'||g||'@example.com' FROM generate_series(1,5) g;
    INSERT INTO products(name,price_cents) SELECT 'prod'||g, 1000*g FROM generate_series(1,4) g;
    INSERT INTO orders(customer_id,status,total_cents) SELECT 1+(g%5),'placed',5000+g*1300 FROM generate_series(1,20) g;
    INSERT INTO invoices(order_id,amount_cents,status,stripe_charge_id)
      SELECT id, total_cents, 'issued', 'ch_'||substr(md5(id::text),1,24) FROM orders;"
}
incident() {
  $PSQL_T "UPDATE orders SET status='shipped' WHERE id<=5;"
  $PSQL_T "WITH u AS (UPDATE invoices SET amount_cents=amount_cents*10 RETURNING 1) SELECT txid_current() FROM u LIMIT 1;" >/dev/null
  if [ "${1:-}" = "dependent" ]; then
    $PSQL_T "UPDATE invoices SET status='paid' WHERE id=1;"
  fi
}
reset_tenant() {
  stop_sidecar
  $PSQL_T "SELECT pg_drop_replication_slot('$SLOT') FROM pg_replication_slots WHERE slot_name='$SLOT'" >/dev/null 2>&1 || true
  $PSQL_T "DROP PUBLICATION IF EXISTS eter_pub" >/dev/null 2>&1 || true
  $PSQL_T "TRUNCATE eter.tracked, eter.history, eter.dependencies" >/dev/null
  "$PGBIN/psql" "$TENANT_URL" -q -f demo/schema.sql >/dev/null
  $PSQL_M "TRUNCATE eter.history, eter.markers, eter.capture_state, eter.undo_txn, eter.dependencies" >/dev/null
}

# ---------------------------------------------------------------------------
echo "==> spinning up TENANT (:$TENANT_PORT, logical) + META (:$META_PORT) clusters"
rm -rf "$TENANT_DATA" "$META_DATA"
"$PGBIN/initdb" -D "$TENANT_DATA" -U eter --auth-local=trust --auth-host=trust >/dev/null
cat >>"$TENANT_DATA/postgresql.conf" <<EOF
wal_level = logical
max_wal_senders = 8
max_replication_slots = 8
port = $TENANT_PORT
listen_addresses = 'localhost'
max_pred_locks_per_transaction = 4096
EOF
"$PGBIN/pg_ctl" -D "$TENANT_DATA" -l "$TENANT_DATA/server.log" -w start >/dev/null
"$PGBIN/createdb" -h localhost -p "$TENANT_PORT" -U eter eter

"$PGBIN/initdb" -D "$META_DATA" -U eter --auth-local=trust --auth-host=trust >/dev/null
cat >>"$META_DATA/postgresql.conf" <<EOF
port = $META_PORT
listen_addresses = 'localhost'
EOF
"$PGBIN/pg_ctl" -D "$META_DATA" -l "$META_DATA/server.log" -w start >/dev/null
"$PGBIN/createdb" -h localhost -p "$META_PORT" -U eter eter_meta
pass "two clusters up (tenant wal_level=logical; meta is the external store)"

# Engine schema on BOTH (META runs preview_undo; TENANT runs the compensation
# apply + holds eter.tracked). Demo user tables on the TENANT only.
"$PGBIN/psql" "$TENANT_URL" -q -f ext/eter/eter.sql >/dev/null
"$PGBIN/psql" "$TENANT_URL" -q -f demo/schema.sql >/dev/null
"$PGBIN/psql" "$META_URL"   -q -f ext/eter/eter.sql >/dev/null
pass "engine applied to tenant + meta; demo schema on tenant"

# ===========================================================================
echo "==> PHASE A: capture writes history to the EXTERNAL store, not the tenant"
seed                                            # pre-slot, never captured
$PSQL_T "SET eter.capture_mode='sidecar'; SELECT eter.track_all();" >/dev/null
$PSQL_T "SELECT pg_create_logical_replication_slot('$SLOT','pgoutput')" >/dev/null
start_sidecar; wait_sidecar
incident                                        # clean incident (shipped + ×10)
wait_drain "SELECT count(*) FROM eter.history WHERE NOT is_undo" 25

META_ROWS=$($PSQL_M "SELECT count(*) FROM eter.history WHERE NOT is_undo")
# Inc 6: the tenant holds NO history at all, no trigger (zero on the commit path)
# and no writer-index (derivation moved to the store). Durable history lives only
# in the store, with row images.
TENANT_HIST=$($PSQL_T "SELECT count(*) FROM eter.history")
META_IMG=$($PSQL_M "SELECT count(*) FROM eter.history WHERE row_after IS NOT NULL")
[ "$META_ROWS" -ge 25 ] || fail "meta store captured too few history rows ($META_ROWS)"
[ "$TENANT_HIST" = "0" ] || fail "tenant holds $TENANT_HIST history rows, expected ZERO"
[ "$META_IMG" -ge 20 ] || fail "meta store missing row images ($META_IMG)"
pass "full history + row images in the META store ($META_ROWS rows); tenant eter.history is empty"

# ===========================================================================
echo "==> PHASE B: CLI reads resolve against the external store"
# NB: query the META store by the stored text table_name. The sidecar records the
# name as the capture connection's regclass renders it ('invoices', public is on
# its search_path), and the META store has no user tables, so ::regclass can't
# resolve there anyway (that's the point: META holds metadata, not data).
TX=$($PSQL_M "SELECT txid FROM eter.history WHERE table_name='invoices' ORDER BY id DESC LIMIT 1")
LOG_TX=$($ETER log --json | node -e 'const a=JSON.parse(require("fs").readFileSync(0,"utf8"));process.stdout.write(a.some(r=>String(r.txid)===process.argv[1])?"yes":"no")' "$TX")
[ "$LOG_TX" = "yes" ] || fail "eter log did not surface the incident txid from the meta store"
[ "$($ETER status --json | jget changes)" -ge 25 ] || fail "eter status changes not read from meta store"
[ "$($ETER show "$TX" --json | node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(0,"utf8")).length))')" -ge 1 ] || fail "eter show empty"
pass "log / status / show all read durable metadata from the external store"

# ===========================================================================
echo "==> PHASE C: clean undo, preview in META, compensation applied in TENANT"
PLAN=$($ETER preview "$TX" --json)
[ "$(echo "$PLAN" | jget classification)" = "clean" ] || fail "expected clean classification"
[ "$(echo "$PLAN" | jget external_refs.count)" -ge 20 ] || fail "expected >=20 external refs"
pass "preview = clean (computed against META history); $(echo "$PLAN" | jget external_refs.count) external refs surfaced"

SHIPPED_BEFORE=$($PSQL_T "SELECT count(*) FROM orders WHERE status='shipped'")
RES=$($ETER undo "$TX" --apply --json)
[ "$(echo "$RES" | jget status)" = "applied" ] || fail "undo not applied"
MISMATCH=$($PSQL_T "SELECT count(*) FROM invoices i JOIN orders o ON o.id=i.order_id WHERE i.amount_cents<>o.total_cents")
[ "$MISMATCH" = "0" ] || fail "undo did not restore invoices in the tenant ($MISMATCH wrong)"
[ "$($PSQL_T "SELECT count(*) FROM orders WHERE status='shipped'")" = "$SHIPPED_BEFORE" ] || fail "unrelated 'shipped' writes changed"
pass "clean undo restored tenant invoices exactly from external history; unrelated writes survived"

# The compensating writes are decoded back into META and stamped is_undo via the
# undo marker the orchestrator wrote to the store.
REVERTED=$(echo "$RES" | jget reverted_ops)
wait_drain "SELECT count(*) FROM eter.history WHERE is_undo" "$REVERTED"
[ "$($ETER preview "$TX" --json | jget classification)" = "clean" ] || fail "undo writes created a phantom dependent"
pass "compensating writes stamped is_undo in META; no phantom dependents"

# ===========================================================================
echo "==> PHASE D: dependent (ww), refusal + cross-DB cascade"
reset_tenant
seed
$PSQL_T "SET eter.capture_mode='sidecar'; SELECT eter.track_all();" >/dev/null
$PSQL_T "SELECT pg_create_logical_replication_slot('$SLOT','pgoutput')" >/dev/null
start_sidecar; wait_sidecar
incident dependent
wait_drain "SELECT count(*) FROM eter.history WHERE NOT is_undo" 26
TXD=$($PSQL_M "SELECT txid FROM eter.history h WHERE table_name='invoices' GROUP BY txid ORDER BY count(*) DESC LIMIT 1")
[ "$($ETER preview "$TXD" --json | jget classification)" = "dependent" ] || fail "expected dependent classification"
pass "later write to same row classified dependent (ww edge from META history)"

set +e; $ETER undo "$TXD" --apply --json >/dev/null 2>&1; CODE=$?; set -e
[ "$CODE" = "4" ] || fail "expected exit 4 in clean_only, got $CODE"
pass "clean_only undo refused the dependent (exit 4), no blind revert across DBs"

[ "$($ETER undo "$TXD" --apply --cascade --json | jget status)" = "applied" ] || fail "cascade failed"
[ "$($PSQL_T "SELECT count(*) FROM invoices i JOIN orders o ON o.id=i.order_id WHERE i.amount_cents<>o.total_cents")" = "0" ] || fail "cascade did not restore tenant"
pass "cross-DB cascade reverted incident + dependent; tenant invoices restored"
stop_sidecar

# ===========================================================================
echo "==> PHASE E: tier-2 rw read-dependency surfaced ACROSS DBs (derive in store)"
# The differentiator: a later txn that only READ what the target wrote (no ww
# overlap) must still be flagged dependent. Inc 6: the read-set is CAPTURED in the
# tenant (eter_ssi) but FORWARDED to the store by the sidecar, and DERIVED in the
# store on-demand at preview time, the tenant keeps no dependency graph and no
# durable read-set. OBSERVE mode (READ COMMITTED) on the patched engine, the
# shipping substrate; the reader below acquires no SERIALIZABLE, takes no 40001.
reset_tenant
# Build the OBSERVE-capable eter_ssi (no -DETER_STRICT_ONLY) against the
# patched engine, load it into the tenant, and turn observe mode on.
make -C ext/eter_ssi PG_CONFIG="$PGBIN/pg_config" clean install >/dev/null
"$PGBIN/psql" "$TENANT_URL" -q -c "DROP EXTENSION IF EXISTS eter_ssi; CREATE EXTENSION eter_ssi;" \
  -c "ALTER DATABASE eter SET session_preload_libraries='eter_ssi';" \
  -c "ALTER DATABASE eter SET eter_observe_mode=on;" >/dev/null
[ "$($PSQL_T "SHOW eter_observe_mode")" = "on" ] || fail "observe mode not on (patched PG)"
$PSQL_T "DROP TABLE IF EXISTS public.orders, public.products CASCADE;
  CREATE TABLE public.products(id bigint PRIMARY KEY, price_cents int);
  CREATE TABLE public.orders(id bigint PRIMARY KEY, product_id bigint, charged_cents int);
  INSERT INTO public.products VALUES (1,10000),(2,5000);
  SET eter.capture_mode='sidecar';
  SELECT eter.track('public.products'); SELECT eter.track('public.orders');" >/dev/null
$PSQL_T "SELECT pg_create_logical_replication_slot('$SLOT','pgoutput')" >/dev/null
start_sidecar; wait_sidecar
# W writes product 1; R (default READ COMMITTED, observe captures the read) reads
# it and writes an order, tier-2: the causal link is the read, NO write-write to W.
W=$($PSQL_T "WITH u AS (UPDATE public.products SET price_cents=20000 WHERE id=1 RETURNING 1) SELECT txid_current() FROM u")
"$PGBIN/psql" "$TENANT_URL" -q >/dev/null <<SQL
BEGIN;  -- default READ COMMITTED; observe mode captures the predicate read (no SERIALIZABLE)
SELECT price_cents FROM public.products WHERE id=1;
INSERT INTO public.orders VALUES (1,1,20000);
COMMIT;
SQL
# History must reach the store (writer + reader, for the match + xid resolution);
# the sidecar's forwarder must ship the read-set into the store's staging.
wait_drain "SELECT count(*) FROM eter.history WHERE table_name IN ('products','orders')" 2 M
wait_drain "SELECT count(*) FROM eter.read_set" 1 M
pass "history in store; read-set forwarded to the store ($($PSQL_M "SELECT count(*) FROM eter.read_set") staged reads)"

# The tenant holds NO dependency graph and NO durable read-set, the forwarder
# truncates ssi_reads each cycle, and derive never runs in the tenant. Under observe
# every read stages SIREAD targets, so wait for the forwarder to drain them first.
i=0; while [ "$($PSQL_T "SELECT count(*) FROM eter.ssi_reads")" != "0" ]; do i=$((i+1)); [ "$i" -gt 120 ] && fail "forwarder never cleared tenant ssi_reads"; sleep 0.5; done
[ "$($PSQL_T "SELECT count(*) FROM eter.history")" = "0" ]      || fail "tenant has history rows, expected ZERO"
[ "$($PSQL_T "SELECT count(*) FROM eter.dependencies")" = "0" ] || fail "tenant has dependency rows, expected ZERO"
[ "$($PSQL_T "SELECT count(*) FROM eter.ssi_reads")" = "0" ]    || fail "tenant has staged reads, forwarder did not clear ssi_reads"
pass "tenant is clean: 0 history, 0 dependencies, 0 ssi_reads (capture-only)"

# preview triggers derive_from_read_set IN THE STORE, then classifies.
CLASS=$($ETER preview "$W" --json | jget classification)
[ "$CLASS" = "dependent" ] || fail "rw read-dependency not surfaced across DBs, preview said $CLASS"
$ETER preview "$W" --json | node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{const o=JSON.parse(s);if(!(o.conflict_edges||[]).some(x=>x.kinds.includes("rw")))process.exit(1)})' \
  || fail "expected an rw conflict edge in the cross-DB plan"
[ "$($PSQL_M "SELECT count(*) FROM eter.dependencies WHERE depends_on=$W AND kind='rw'")" -ge 1 ] \
  || fail "store derive did not produce the rw-edge for W=$W"
[ "$($PSQL_M "SELECT count(*) FROM eter._ww_conflicts($W)")" = "0" ] \
  || fail "expected 0 write-write conflicts (a CDC/proxy would call this clean)"
pass "preview = dependent via the read-edge DERIVED IN THE STORE; write-write alone sees 0"

set +e; $ETER undo "$W" --apply --json >/dev/null 2>&1; CODE=$?; set -e
[ "$CODE" = "4" ] || fail "expected exit 4 (clean_only refuses rw-dependent), got $CODE"
pass "clean_only undo refused the read-derived dependent across DBs (exit 4, no blind revert)"
stop_sidecar

# ===========================================================================
echo "==> PHASE F: DDL-log recovery index externalized to the store"
# eter.ddl_log is CAPTURED by tenant event triggers (they can only fire inside
# the cluster whose DDL they watch) but its DURABLE home is the store, the capture
# sidecar's DDL-log forwarder ships each row there (preserving the tenant's txid /
# snapshot_lsn / committed_at) and PRUNES the tenant copy, so the tenant keeps no
# durable recovery index. The storage daemon then reads the destructive signal from
# the store.
reset_tenant
$PSQL_T "TRUNCATE eter.ddl_log" >/dev/null
$PSQL_M "TRUNCATE eter.ddl_log" >/dev/null
$PSQL_T "SELECT eter.enable_ddl_logging()" >/dev/null
$PSQL_T "SELECT pg_create_logical_replication_slot('$SLOT','pgoutput')" >/dev/null
start_sidecar; wait_sidecar

# Schema changes the recovery index must capture: an audit trail (CREATE/ALTER) and
# two destructive drops (a column + a table, the recovery events).
$PSQL_T "CREATE TABLE public.ddlf(id int PRIMARY KEY, name text, legacy_code text)" >/dev/null
$PSQL_T "ALTER TABLE public.ddlf ADD COLUMN sku text" >/dev/null
$PSQL_T "ALTER TABLE public.ddlf DROP COLUMN legacy_code" >/dev/null   # destructive: column
$PSQL_T "DROP TABLE public.ddlf" >/dev/null                           # destructive: table

# The forwarder must ship the durable index into the STORE.
wait_drain "SELECT count(*) FROM eter.ddl_log WHERE is_destructive" 2 M
pass "DDL rows forwarded to the store ($($PSQL_M "SELECT count(*) FROM eter.ddl_log") rows)"

# Exactly the two original destructive drops, with full recovery provenance carried
# across (object identity + needs_snapshot + snapshot_lsn + the tenant src_id), and
# the CREATE/ALTER audit trail present.
DESTRUCT=$($PSQL_M "SELECT count(*) FROM eter.ddl_log WHERE is_destructive")
[ "$DESTRUCT" = "2" ] || fail "store: expected 2 destructive drops, got $DESTRUCT"
COL=$($PSQL_M "SELECT count(*) FROM eter.ddl_log
               WHERE is_destructive AND object_type='table column'
                 AND object_identity='public.ddlf.legacy_code' AND needs_snapshot
                 AND snapshot_lsn IS NOT NULL AND src_id IS NOT NULL")
[ "$COL" = "1" ] || fail "store: DROP COLUMN public.ddlf.legacy_code not indexed with full provenance"
TBL=$($PSQL_M "SELECT count(*) FROM eter.ddl_log
               WHERE is_destructive AND object_type='table'
                 AND object_identity='public.ddlf' AND needs_snapshot
                 AND snapshot_lsn IS NOT NULL AND src_id IS NOT NULL")
[ "$TBL" = "1" ] || fail "store: DROP TABLE public.ddlf not indexed with full provenance"
AUDIT=$($PSQL_M "SELECT count(*) FROM eter.ddl_log
                 WHERE NOT is_destructive AND command_tag IN ('CREATE TABLE','ALTER TABLE')")
[ "$AUDIT" -ge 2 ] || fail "store: CREATE/ALTER audit trail missing ($AUDIT)"
pass "store holds the full recovery index: 2 destructive drops (column+table) + audit trail, provenance intact"

# Tenant copy is transient staging, pruned once durably in the store.
i=0; while [ "$($PSQL_T "SELECT count(*) FROM eter.ddl_log")" != "0" ]; do i=$((i+1)); [ "$i" -gt 120 ] && fail "forwarder never pruned tenant ddl_log"; sleep 0.5; done
pass "tenant eter.ddl_log is empty, zero durable recovery index in the tenant"

# Idempotent re-ship: forwarding is keyed on src_id, so no duplicates ever (e.g. a
# crash between store-insert and tenant-prune). Re-insert the same rows by hand and
# confirm the unique index drops them.
DUP_BEFORE=$($PSQL_M "SELECT count(*) FROM eter.ddl_log")
$PSQL_M "INSERT INTO eter.ddl_log (src_id, txid, command_tag, is_destructive, needs_snapshot)
         SELECT src_id, txid, command_tag, is_destructive, needs_snapshot
           FROM eter.ddl_log WHERE src_id IS NOT NULL
         ON CONFLICT (src_id) WHERE src_id IS NOT NULL DO NOTHING" >/dev/null
[ "$($PSQL_M "SELECT count(*) FROM eter.ddl_log")" = "$DUP_BEFORE" ] || fail "re-ship duplicated ddl_log rows (idempotency broken)"
pass "re-ship is idempotent (src_id unique index drops duplicates), at-least-once ship, exactly-once store"
stop_sidecar

echo ""
echo "ALL PHASE 3 METADATA-EXTERNALIZE CHECKS PASSED ✅"
