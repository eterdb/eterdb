#!/usr/bin/env bash
# EterDB Phase 3, capture-sidecar differential test (local, no Docker, no ZFS).
# Deliberately SINGLE-DB: gates the in-engine capture mechanism (trigger↔sidecar
# oracle equivalence, this is also what keeps trigger-mode covered). The
# externalized two-DB path is proven by
# test/{meta-externalize,inventree-e2e,e2e,storage-pitr}.sh.
#
# Stands up a throwaway logical-decoding Postgres cluster and proves the
# logical-decoding capture sidecar is a faithful replacement for the Phase 1/2
# in-DB trigger oracle:
#   Phase A  equivalence, trigger and sidecar, capturing the SAME writes, produce
#            equivalent eter.history (row images, txids, fingerprint grouping).
#   Phase B  undo with the trigger RETIRED, the frozen undo surface still works
#            end-to-end on sidecar-populated history (clean, dependent, cascade,
#            external refs, is_undo stamping, no phantom dependents).
#   Phase C  restart idempotency, kill the sidecar mid-stream, restart, and the
#            history is exactly-once (no gaps, no duplicates).
#
# Everything runs against a private cluster on its own port/datadir, torn down on
# exit. The machine's main Postgres is untouched.
set -euo pipefail
cd "$(dirname "$0")/.."

PGBIN="${PGBIN:-/opt/homebrew/opt/postgresql@18/bin}"
PGPORT="${ETER_TEST_PORT:-5433}"
PGDATA="$PWD/.pgdata-capture"
LOGDIR="$PGDATA"
DBURL="postgres://eter:eter@localhost:$PGPORT/eter"
SLOT=eter_slot
PSQL_DB="$PGBIN/psql $DBURL -tAqc"
go build -C cli -o eter . || { echo "go build of the eter CLI failed (need Go installed)"; exit 1; }
ETER="$PWD/cli/eter --db $DBURL"
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
  "$PGBIN/pg_ctl" -D "$PGDATA" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$PGDATA"
}
trap cleanup EXIT

start_sidecar() {
  # Deliberately single-DB (store == tenant) → acknowledge it explicitly (issue #67).
  DATABASE_URL="$DBURL" ETER_ALLOW_SINGLE_DB=1 "$CAPBIN" >"$LOGDIR/capture.log" 2>&1 &
  SIDECAR_PID=$!
}

# Wait until the sidecar has connected and its slot is streaming.
wait_sidecar() {
  local i a
  for i in $(seq 1 60); do
    a=$($PSQL_DB "SELECT coalesce((SELECT active FROM pg_replication_slots WHERE slot_name='$SLOT'),false)")
    [ "$a" = "t" ] && return 0
    sleep 0.25
  done
  fail "sidecar slot never became active (see $LOGDIR/capture.log)"
}

# Wait until a count query is >= a minimum AND stable across a few reads.
wait_drain() { # $1 = count SQL, $2 = minimum expected
  local q="$1" min="$2" prev=-1 stable=0 cur i
  for i in $(seq 1 120); do
    cur=$($PSQL_DB "$q")
    if [ "$cur" = "$prev" ] && [ "$cur" -ge "$min" ]; then stable=$((stable+1)); else stable=0; fi
    [ "$stable" -ge 3 ] && return 0
    prev="$cur"; sleep 0.25
  done
  fail "drain timeout (q=[$q] min=$min last=$cur; see $LOGDIR/capture.log)"
}

apply_engine() { "$PGBIN/psql" "$DBURL" -q -f ext/eter/eter.sql >/dev/null; }
apply_schema() { "$PGBIN/psql" "$DBURL" -q -f demo/schema.sql >/dev/null; }

# Seed baseline e-commerce data (mirrors the demo). Seeding happens before the
# slot is created, so it is never captured, matching the trigger, which is
# installed only at track time.
seed() {
  $PSQL_DB "
    INSERT INTO customers(name,email) SELECT 'cust'||g, 'c'||g||'@example.com' FROM generate_series(1,5) g;
    INSERT INTO products(name,price_cents) SELECT 'prod'||g, 1000*g FROM generate_series(1,4) g;
    INSERT INTO orders(customer_id,status,total_cents) SELECT 1+(g%5),'placed',5000+g*1300 FROM generate_series(1,20) g;
    INSERT INTO invoices(order_id,amount_cents,status,stripe_charge_id)
      SELECT id, total_cents, 'issued', 'ch_'||substr(md5(id::text),1,24) FROM orders;"
}
# Create the slot AFTER the publication exists (track creates eter_pub):
# pgoutput resolves publications against a HISTORIC catalog snapshot per decoded
# position. (PG18 tolerates decoding positions that predate the publication, but
# the deployed entrypoint doesn't rely on that, it creates the empty publication
# BEFORE the slot; Phase E gates that exact ordering.)
create_slot() { $PSQL_DB "SELECT pg_create_logical_replication_slot('$SLOT','pgoutput')" >/dev/null; }
track_all_mode() { $PSQL_DB "SET eter.capture_mode='$1'; SELECT eter.track_all();" >/dev/null; }

# The tracked workload (post-track, so both trigger and sidecar see it): a little
# legitimate traffic + the 2:00 PM incident. $1='dependent' adds a later write to
# one corrupted invoice (creates a ww conflict).
incident() {
  $PSQL_DB "UPDATE orders SET status='shipped' WHERE id<=5;"
  $PSQL_DB "WITH u AS (UPDATE invoices SET amount_cents=amount_cents*10 RETURNING 1) SELECT txid_current() FROM u LIMIT 1;" >/dev/null
  if [ "${1:-}" = "dependent" ]; then
    $PSQL_DB "UPDATE invoices SET status='paid' WHERE id=1;"
  fi
}

reset_state() {
  stop_sidecar
  $PSQL_DB "SELECT pg_drop_replication_slot('$SLOT') FROM pg_replication_slots WHERE slot_name='$SLOT'" >/dev/null 2>&1 || true
  $PSQL_DB "DROP PUBLICATION IF EXISTS eter_pub" >/dev/null 2>&1 || true
  $PSQL_DB "TRUNCATE eter.history, eter.dependencies, eter.markers, eter.tracked, eter.capture_state, eter.undo_txn" >/dev/null
  apply_schema
}

# ---------------------------------------------------------------------------
echo "==> spinning up throwaway logical cluster on :$PGPORT"
rm -rf "$PGDATA"
"$PGBIN/initdb" -D "$PGDATA" -U eter --auth-local=trust --auth-host=trust >/dev/null
cat >>"$PGDATA/postgresql.conf" <<EOF
wal_level = logical
max_wal_senders = 8
max_replication_slots = 8
port = $PGPORT
listen_addresses = 'localhost'
EOF
"$PGBIN/pg_ctl" -D "$PGDATA" -l "$LOGDIR/server.log" -w start >/dev/null
"$PGBIN/createdb" -h localhost -p "$PGPORT" -U eter eter
pass "cluster up (wal_level=logical)"

apply_engine
apply_schema
pass "engine + demo schema applied"

# ===========================================================================
echo "==> PHASE A: trigger vs sidecar equivalence (same writes, capture_mode='both')"
seed
track_all_mode both        # installs trigger AND sidecar publication/replica-identity
create_slot                # publication now exists; seeds precede the slot (not captured)
incident dependent         # shipped + incident + one dependent write
# Trigger captured synchronously; count its rows before the sidecar adds its own.
TRIG=$($PSQL_DB "SELECT count(*) FROM eter.history WHERE application_name IS DISTINCT FROM 'eter-capture'")
[ "$TRIG" -ge 26 ] || fail "trigger oracle captured too few rows ($TRIG)"
pass "trigger oracle captured $TRIG changes synchronously"

start_sidecar; wait_sidecar
wait_drain "SELECT count(*) FROM eter.history WHERE application_name='eter-capture'" "$TRIG"
SC=$($PSQL_DB "SELECT count(*) FROM eter.history WHERE application_name='eter-capture'")
[ "$SC" = "$TRIG" ] || fail "sidecar row count $SC != trigger $TRIG"
pass "sidecar captured the same $SC changes via logical decoding"

# Row-image + txid equivalence per tracked table: reconstruct each history row to
# its canonical tuple and compare the multisets (symmetric EXCEPT ALL == 0).
for T in invoices orders; do
  DIFF=$($PSQL_DB "
    WITH tr AS (
      SELECT txid, op,
             (jsonb_populate_record(NULL::public.$T, row_before))::text AS b,
             (jsonb_populate_record(NULL::public.$T, row_after))::text  AS a
      FROM eter.history
      WHERE table_name='public.$T'::regclass::text AND application_name IS DISTINCT FROM 'eter-capture'),
    sc AS (
      SELECT txid, op,
             (jsonb_populate_record(NULL::public.$T, row_before))::text AS b,
             (jsonb_populate_record(NULL::public.$T, row_after))::text  AS a
      FROM eter.history
      WHERE table_name='public.$T'::regclass::text AND application_name='eter-capture')
    SELECT (SELECT count(*) FROM (SELECT * FROM tr EXCEPT ALL SELECT * FROM sc) x)
         + (SELECT count(*) FROM (SELECT * FROM sc EXCEPT ALL SELECT * FROM tr) y);")
  [ "$DIFF" = "0" ] || fail "row-image/txid mismatch on $T (symmetric diff=$DIFF)"
  pass "row images + txids identical on $T"
done

# Fingerprint equivalence-class: the sidecar's structural fingerprints are not the
# trigger's SQL-text hashes, but they must PARTITION the rows identically, i.e.
# the sorted multiset of per-fingerprint group sizes matches.
SAME_GROUPS=$($PSQL_DB "
  WITH tr AS (SELECT fingerprint, count(*) c FROM eter.history
                WHERE application_name IS DISTINCT FROM 'eter-capture' GROUP BY fingerprint),
       sc AS (SELECT fingerprint, count(*) c FROM eter.history
                WHERE application_name='eter-capture' GROUP BY fingerprint)
  SELECT (SELECT array_agg(c ORDER BY c) FROM tr) = (SELECT array_agg(c ORDER BY c) FROM sc);")
[ "$SAME_GROUPS" = "t" ] || fail "fingerprint grouping differs between trigger and sidecar"
pass "fingerprint equivalence-class (statement-shape grouping) matches"
stop_sidecar

# ===========================================================================
echo "==> PHASE B: undo end-to-end with the trigger RETIRED (sidecar-only)"
reset_state
seed
track_all_mode sidecar     # NO trigger installed, capture is the sidecar alone
create_slot
start_sidecar; wait_sidecar
incident                   # clean incident (no dependent)
wait_drain "SELECT count(*) FROM eter.history WHERE NOT is_undo" 25
TX=$($PSQL_DB "SELECT txid FROM eter.history WHERE table_name='public.invoices'::regclass::text ORDER BY id DESC LIMIT 1")
pass "sidecar-only history populated; incident txid=$TX"

PLAN=$($ETER preview "$TX" --json)
[ "$(echo "$PLAN" | jget classification)" = "clean" ] || fail "expected clean classification"
[ "$(echo "$PLAN" | jget external_refs.count)" -ge 20 ] || fail "expected >=20 external refs"
pass "preview = clean; surfaced $(echo "$PLAN" | jget external_refs.count) external Stripe refs"

SHIPPED_BEFORE=$($PSQL_DB "SELECT count(*) FROM orders WHERE status='shipped'")
CHARGE_BEFORE=$($PSQL_DB "SELECT stripe_charge_id FROM invoices ORDER BY id LIMIT 1")
RES=$($ETER undo "$TX" --apply --json)
[ "$(echo "$RES" | jget status)" = "applied" ] || fail "undo not applied"
MISMATCH=$($PSQL_DB "SELECT count(*) FROM invoices i JOIN orders o ON o.id=i.order_id WHERE i.amount_cents<>o.total_cents")
[ "$MISMATCH" = "0" ] || fail "undo did not restore invoices ($MISMATCH wrong)"
[ "$($PSQL_DB "SELECT count(*) FROM orders WHERE status='shipped'")" = "$SHIPPED_BEFORE" ] || fail "unrelated 'shipped' writes changed"
[ "$($PSQL_DB "SELECT stripe_charge_id FROM invoices ORDER BY id LIMIT 1")" = "$CHARGE_BEFORE" ] || fail "external charge id altered"
pass "clean undo restored invoices exactly; unrelated writes + external refs untouched"

# The compensating writes are themselves decoded, assert they are stamped is_undo
# (via eter.undo_txn) and create no phantom dependents.
REVERTED=$(echo "$RES" | jget reverted_ops)
wait_drain "SELECT count(*) FROM eter.history WHERE is_undo" "$REVERTED"
[ "$($PSQL_DB "SELECT count(*) FROM eter.history WHERE is_undo")" -ge "$REVERTED" ] || fail "undo writes not stamped is_undo"
[ "$($ETER preview "$TX" --json | jget classification)" = "clean" ] || fail "undo writes created a phantom dependent"
pass "compensating writes stamped is_undo; no phantom dependents"

echo "==> PHASE B (dependent): refusal + cascade on sidecar history"
reset_state
seed; track_all_mode sidecar; create_slot; start_sidecar; wait_sidecar
incident dependent
wait_drain "SELECT count(*) FROM eter.history WHERE NOT is_undo" 26
TXD=$($PSQL_DB "SELECT txid FROM eter.history h WHERE table_name='public.invoices'::regclass::text GROUP BY txid ORDER BY count(*) DESC LIMIT 1")
[ "$($ETER preview "$TXD" --json | jget classification)" = "dependent" ] || fail "expected dependent classification"
pass "read-after-write on same row classified dependent"
set +e; $ETER undo "$TXD" --apply --json >/dev/null 2>&1; CODE=$?; set -e
[ "$CODE" = "4" ] || fail "expected exit 4 in clean_only, got $CODE"
pass "clean_only undo refused dependent (exit 4)"
[ "$($ETER undo "$TXD" --apply --cascade --json | jget status)" = "applied" ] || fail "cascade failed"
[ "$($PSQL_DB "SELECT count(*) FROM invoices i JOIN orders o ON o.id=i.order_id WHERE i.amount_cents<>o.total_cents")" = "0" ] || fail "cascade did not restore"
pass "cascade reverted incident + dependent; invoices restored"
stop_sidecar

# ===========================================================================
echo "==> PHASE C: restart idempotency (no gaps, no duplicates)"
reset_state
$PSQL_DB "DROP TABLE IF EXISTS public.widgets; CREATE TABLE public.widgets(id int PRIMARY KEY, v int)"
track_all_mode sidecar
create_slot
start_sidecar; wait_sidecar
$PSQL_DB "INSERT INTO widgets SELECT g, g*10 FROM generate_series(1,5) g" >/dev/null
wait_drain "SELECT count(*) FROM eter.history WHERE table_name='public.widgets'::regclass::text" 5
pass "captured first 5 inserts"
stop_sidecar
$PSQL_DB "INSERT INTO widgets SELECT g, g*10 FROM generate_series(6,10) g" >/dev/null   # writes while sidecar is DOWN
start_sidecar; wait_sidecar
wait_drain "SELECT count(*) FROM eter.history WHERE table_name='public.widgets'::regclass::text" 10
TOTAL=$($PSQL_DB "SELECT count(*) FROM eter.history WHERE table_name='public.widgets'::regclass::text")
DUPS=$($PSQL_DB "SELECT count(*) FROM (SELECT txid,pk,op,count(*) c FROM eter.history WHERE table_name='public.widgets'::regclass::text GROUP BY 1,2,3 HAVING count(*)>1) d")
[ "$TOTAL" = "10" ] || fail "expected exactly 10 captured inserts after restart, got $TOTAL"
[ "$DUPS" = "0" ] || fail "found $DUPS duplicate history rows after restart"
pass "resumed across restart: exactly 10 rows, 0 duplicates"
stop_sidecar

# ===========================================================================
echo "==> PHASE D: TOASTed (out-of-line) before-images survive logical decoding"
# The trigger oracle uses to_jsonb(OLD), which detoasts transparently. The
# shipping sidecar path reads the logical-decoding OLD image under REPLICA
# IDENTITY FULL, where out-of-line TOAST values are subject to the
# "unchanged-toast" optimization. Undo of an UPDATE/DELETE restores from
# row_before, so the OLD image MUST carry the full toasted value, including
# when the UPDATE leaves that column untouched. Nothing else in the suite
# writes a value wide enough to toast, so this is the gate for that.

# A column wide + incompressible enough to force out-of-line TOAST storage
# (~12 KB of random md5 hex per row, well past the ~2 KB toast threshold and
# uncompressible, so it cannot stay inline).
docs_seed() {
  $PSQL_DB "DROP TABLE IF EXISTS public.docs;
            CREATE TABLE public.docs(id int PRIMARY KEY, tag text, body text);"
  $PSQL_DB "INSERT INTO docs SELECT g, 'v0',
              (SELECT string_agg(md5((random()*g + s)::text), '') FROM generate_series(1,400) s)
            FROM generate_series(1,3) g;"
}

# --- D1: trigger vs sidecar before-image equivalence on toasted rows --------
reset_state
docs_seed                  # seed BEFORE the slot: initial bodies are not captured
TOASTSZ=$($PSQL_DB "SELECT pg_relation_size((SELECT reltoastrelid FROM pg_class WHERE oid='public.docs'::regclass))")
[ "$TOASTSZ" -gt 0 ] || fail "docs.body did not toast out-of-line (toast rel empty), test would be vacuous"
pass "docs.body stored out-of-line in TOAST ($TOASTSZ bytes)"

track_all_mode both        # trigger + REPLICA IDENTITY FULL + publication (RI set BEFORE the writes)
create_slot
$PSQL_DB "UPDATE docs SET tag='v1', body=body||'!' WHERE id=1;"  # toast CHANGED
$PSQL_DB "UPDATE docs SET tag='v1' WHERE id=2;"                  # toast UNCHANGED (the crux)
$PSQL_DB "DELETE FROM docs WHERE id=3;"                          # before-image must carry full body
TRIG=$($PSQL_DB "SELECT count(*) FROM eter.history WHERE table_name='public.docs'::regclass::text AND application_name IS DISTINCT FROM 'eter-capture'")
[ "$TRIG" = "3" ] || fail "trigger oracle captured $TRIG docs changes, expected 3"

start_sidecar; wait_sidecar
wait_drain "SELECT count(*) FROM eter.history WHERE table_name='public.docs'::regclass::text AND application_name='eter-capture'" 3

# Undo-critical equivalence is on row_before (op U/D): reconstruct it to the
# canonical tuple and compare the multisets against the toast-safe oracle.
# (row_after for the unchanged-toast UPDATE legitimately drops the value in the
# NEW image, pgoutput's unchanged-toast marker, but undo never reads it.)
DIFF=$($PSQL_DB "
  WITH tr AS (SELECT txid, op, (jsonb_populate_record(NULL::public.docs, row_before))::text AS b
              FROM eter.history WHERE table_name='public.docs'::regclass::text
                AND op IN ('U','D') AND application_name IS DISTINCT FROM 'eter-capture'),
       sc AS (SELECT txid, op, (jsonb_populate_record(NULL::public.docs, row_before))::text AS b
              FROM eter.history WHERE table_name='public.docs'::regclass::text
                AND op IN ('U','D') AND application_name='eter-capture')
  SELECT (SELECT count(*) FROM (SELECT * FROM tr EXCEPT ALL SELECT * FROM sc) x)
       + (SELECT count(*) FROM (SELECT * FROM sc EXCEPT ALL SELECT * FROM tr) y);")
[ "$DIFF" = "0" ] || fail "toasted before-image mismatch trigger vs sidecar (symmetric diff=$DIFF)"
pass "before-images identical trigger vs sidecar across toast changed/unchanged/delete"

# Make the crux explicit: the UNCHANGED-toast UPDATE (id=2) must still carry the
# FULL old body in the sidecar before-image, not an unchanged-toast hole.
ORIG_LEN=$($PSQL_DB "SELECT length((jsonb_populate_record(NULL::public.docs, row_before)).body)
  FROM eter.history WHERE table_name='public.docs'::regclass::text
    AND application_name IS DISTINCT FROM 'eter-capture' AND op='U' AND (pk->>'id')='2'")
SC_LEN=$($PSQL_DB "SELECT length((jsonb_populate_record(NULL::public.docs, row_before)).body)
  FROM eter.history WHERE table_name='public.docs'::regclass::text
    AND application_name='eter-capture' AND op='U' AND (pk->>'id')='2'")
{ [ -n "$SC_LEN" ] && [ "$SC_LEN" = "$ORIG_LEN" ]; } || fail "unchanged-toast before-image dropped: sidecar body len [$SC_LEN] != oracle [$ORIG_LEN]"
pass "unchanged-toast UPDATE keeps full $SC_LEN-char before-image in sidecar history"
stop_sidecar

# --- D2: undo restores a toasted column from sidecar-only history -----------
reset_state
docs_seed
track_all_mode sidecar     # no trigger, sidecar history is the only source
create_slot
start_sidecar; wait_sidecar
ORIG_BODY_LEN=$($PSQL_DB "SELECT length(body) FROM docs WHERE id=2")
$PSQL_DB "UPDATE docs SET tag='v9' WHERE id=2;"   # body UNCHANGED by the write
wait_drain "SELECT count(*) FROM eter.history WHERE table_name='public.docs'::regclass::text AND NOT is_undo" 1
TXU=$($PSQL_DB "SELECT txid FROM eter.history WHERE table_name='public.docs'::regclass::text AND op='U' ORDER BY id DESC LIMIT 1")
[ "$($ETER preview "$TXU" --json | jget classification)" = "clean" ] || fail "expected clean classification for toast undo"
[ "$($ETER undo "$TXU" --apply --json | jget status)" = "applied" ] || fail "toast undo not applied"
# _compensate restores EVERY column from row_before; if the OLD image lost the
# toast value, body is now NULL/short. (The write left body unchanged, so a
# correct undo leaves the full original body in place.)
AFTER_LEN=$($PSQL_DB "SELECT coalesce(length(body),-1) FROM docs WHERE id=2")
AFTER_TAG=$($PSQL_DB "SELECT tag FROM docs WHERE id=2")
[ "$AFTER_LEN" = "$ORIG_BODY_LEN" ] || fail "undo corrupted toasted body: len $AFTER_LEN != original $ORIG_BODY_LEN"
[ "$AFTER_TAG" = "v0" ] || fail "undo did not restore tag (got '$AFTER_TAG')"
pass "undo restored unchanged-toast body intact ($AFTER_LEN chars) and reverted tag"
stop_sidecar

# ===========================================================================
echo "==> PHASE E: entrypoint ordering, publication+slot at init, sidecar attaches LATE"
# The deployed default (engine image, 2026-07-10): eter.capture_mode='sidecar'
# with the publication + slot pre-created at image init, BEFORE any `eter
# track`, before the app's first write, and before the capture container is up.
# The gap-free claim rests on this exact ordering, so gate it:
#   init:   _ensure_publication (empty) → slot          (the entrypoint's order)
#   window: app writes an untracked table (no `eter track` yet)
#   then:   track_all (publication gains members) → tracked writes
#   late:   the sidecar attaches ONLY NOW → everything post-track is captured,
#           exactly once; pre-track writes are not (trigger-equivalent semantics).
reset_state
$PSQL_DB "ALTER DATABASE eter SET eter.capture_mode = 'sidecar'" >/dev/null
$PSQL_DB "SELECT eter._ensure_publication()" >/dev/null   # entrypoint: publication first…
create_slot                                               # …then the slot, at init
pass "init ordering replicated: empty eter_pub + slot, no tracked tables yet"

# The window: app traffic BEFORE `eter track`, untracked-table DML the decoder
# must pass over without tripping on publication membership at historic positions.
$PSQL_DB "DROP TABLE IF EXISTS public.pretrack; CREATE TABLE public.pretrack(id int PRIMARY KEY, v int)" >/dev/null
$PSQL_DB "INSERT INTO pretrack SELECT g, g*10 FROM generate_series(1,3) g" >/dev/null

track_all_mode sidecar                                    # publication gains members
$PSQL_DB "INSERT INTO pretrack SELECT g, g*10 FROM generate_series(4,9) g" >/dev/null  # tracked, sidecar still DOWN
pass "window written: 3 pre-track + 6 post-track rows, sidecar not yet started"

start_sidecar; wait_sidecar
wait_drain "SELECT count(*) FROM eter.history WHERE table_name='public.pretrack'::regclass::text" 6
TOTAL=$($PSQL_DB "SELECT count(*) FROM eter.history WHERE table_name='public.pretrack'::regclass::text")
DUPS=$($PSQL_DB "SELECT count(*) FROM (SELECT txid,pk,op,count(*) c FROM eter.history WHERE table_name='public.pretrack'::regclass::text GROUP BY 1,2,3 HAVING count(*)>1) d")
PRE=$($PSQL_DB "SELECT count(*) FROM eter.history WHERE table_name='public.pretrack'::regclass::text AND (pk->>'id')::int <= 3")
[ "$TOTAL" = "6" ] || fail "late-attach sidecar captured $TOTAL rows, expected exactly the 6 post-track writes"
[ "$DUPS" = "0" ] || fail "late-attach capture produced $DUPS duplicate rows"
[ "$PRE" = "0" ] || fail "pre-track writes leaked into history ($PRE rows), capture must begin at track"
pass "sidecar attached late and captured exactly the 6 post-track writes (0 dups, 0 pre-track)"
stop_sidecar

echo ""
echo "ALL PHASE 3 CAPTURE-DIFF CHECKS PASSED ✅"
