#!/usr/bin/env bash
# EterDB regression: undo must FAIL LOUDLY when its compensating write matches
# zero rows, instead of reporting a false {"status":"applied"} (issue #189).
#
# The sharp case is row-level security: a compensating UPDATE/DELETE issued by an
# RLS-bound role whose USING policy filters the target row out targets nothing,
# and PostgreSQL reports zero rows affected WITHOUT raising. Before the fix,
# eter._compensate() never checked ROW_COUNT, so undo counted the op as reverted
# and returned success while the data stayed exactly as corrupted (found on a real
# Supabase project, #184). After the fix it raises and the undo transaction aborts.
#
# Runs LOCALLY on ONE throwaway Postgres cluster, no sidecar, no meta store: the
# bug is pure engine SQL and RLS is core Postgres, so capture uses the in-DB
# trigger oracle (eter.capture_mode='trigger') for synchronous history. Defaults
# to the shipping PG18 build but runs on any PG (override PGBUILD=/path/to/prefix).
set -euo pipefail
cd "$(dirname "$0")/.."

PGB="${PGBUILD:-$PWD/.pgbuild18}/bin"
[ -x "$PGB/postgres" ] || { echo "Postgres not found at $PGB, see pg/README.md (or set PGBUILD)"; exit 1; }
export PATH="$PGB:$PATH"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/eter-undo-rls.XXXXXX")
MP=$WORK/pg
PORT="${PGPORT:-5528}"
DBURL="postgres://eter@localhost:$PORT/eter"      # superuser (owner, bypasses RLS)
APPURL="postgres://app@localhost:$PORT/eter"      # RLS-bound app role

teardown() { pg_ctl -D "$MP" -m immediate stop >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap teardown EXIT

pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; exit 1; }
PSQL()  { psql "$DBURL"  -tAqc "$1"; }   # as superuser eter (bypasses RLS)
APP()   { psql "$APPURL" -tAqc "$1"; }   # as the RLS-bound app role

# The shipping engine runs observe on; a stock Postgres doesn't know the GUC. This
# test is mode-independent, so add it only when the build understands it.
OBSERVE_CONF=""
if postgres --describe-config 2>/dev/null | grep -q eter_observe_mode; then
  OBSERVE_CONF=$'eter_observe_mode = on\nmax_pred_locks_per_transaction = 4096'
fi

echo "==> set up a single throwaway Postgres cluster (trigger-mode capture)"
initdb -D "$MP" -U eter --auth-local=trust --auth-host=trust >/dev/null
cat >>"$MP/postgresql.conf" <<EOF
port = $PORT
listen_addresses = 'localhost'
unix_socket_directories = '/tmp'
$OBSERVE_CONF
EOF
pg_ctl -D "$MP" -l "$MP/pg.log" -w -t 60 start >/dev/null
createdb -h localhost -p "$PORT" -U eter eter
psql "$DBURL" -q -f ext/eter/eter.sql >/dev/null
# Trigger oracle => synchronous history, no sidecar. Set at DB level so every
# session (setup as eter, undo as app) captures the same way.
PSQL "ALTER DATABASE eter SET eter.capture_mode = 'trigger'" >/dev/null
pass "cluster up${OBSERVE_CONF:+ (observe on)}, engine loaded, trigger capture"

echo "==> seed a tracked table and fire the incident (as the owner)"
psql "$DBURL" -q >/dev/null <<'SQL'
CREATE TABLE public.accounts (id int PRIMARY KEY, balance int NOT NULL);
SELECT eter.track('public.accounts');
INSERT INTO public.accounts VALUES (1, 100), (2, 250);
-- the incident: a migration that zeroes a balance (lossy; only the before-image recovers it)
UPDATE public.accounts SET balance = 0 WHERE id = 1;
SQL
TXID=$(PSQL "SELECT max(txid) FROM eter.history WHERE op='U'")
[ -n "$TXID" ] && [ "$TXID" != "" ] || fail "no UPDATE captured in history"
[ "$(PSQL "SELECT balance FROM public.accounts WHERE id=1")" = "0" ] || fail "incident did not zero the balance"
pass "incident txid=$TXID captured; account 1 balance is 0 (corrupted)"

echo "==> lock the table behind an RLS policy that matches nothing, grant the app role"
psql "$DBURL" -q >/dev/null <<'SQL'
CREATE ROLE app LOGIN NOSUPERUSER;             -- NOBYPASSRLS is the default
GRANT USAGE ON SCHEMA eter, public TO app;
GRANT ALL ON ALL TABLES IN SCHEMA eter TO app;
GRANT ALL ON ALL SEQUENCES IN SCHEMA eter TO app;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.accounts TO app;
ALTER TABLE public.accounts ENABLE ROW LEVEL SECURITY;
CREATE POLICY block ON public.accounts USING (false) WITH CHECK (false);
SQL
# Sanity: the app role genuinely cannot see or change the row (RLS filters it).
[ "$(APP "SELECT count(*) FROM public.accounts")" = "0" ] || fail "RLS did not filter the app role's view"
pass "RLS enabled; the app role sees zero rows of accounts"

echo "==> undo as the RLS-bound role: must FAIL, not silently report success"
set +e
OUT=$(psql "$APPURL" -tAqc "SELECT eter.undo($TXID)" 2>&1); RC=$?
set -e
[ "$RC" -ne 0 ] || fail "undo returned success (exit 0) despite changing nothing: $OUT"
echo "$OUT" | grep -q "matched 0 rows" || fail "undo failed but without the zero-row diagnosis: $OUT"
# The row must still be corrupted (verified as the owner, who bypasses RLS): the
# aborted undo committed nothing, and no undo-history row was written.
[ "$(PSQL "SELECT balance FROM public.accounts WHERE id=1")" = "0" ] || fail "balance changed despite the undo failing"
[ "$(PSQL "SELECT count(*) FROM eter.history WHERE is_undo")" = "0" ] || fail "an undo-history row was written for a zero-row undo"
pass "undo raised (\"matched 0 rows\"), exit $RC; balance still 0, no undo history written"

echo "==> lift the RLS filter: the same undo now succeeds and restores the row"
# Disable RLS (the policy stays defined but inactive) so the owner-equivalent
# write path is unblocked; the undo must now actually change the row.
PSQL "ALTER TABLE public.accounts DISABLE ROW LEVEL SECURITY" >/dev/null
APPOUT=$(APP "SELECT eter.undo($TXID)")
echo "$APPOUT" | grep -qE '"status":[[:space:]]*"applied"' || fail "undo did not report applied once unblocked: $APPOUT"
[ "$(PSQL "SELECT balance FROM public.accounts WHERE id=1")" = "100" ] || fail "balance not restored to 100 after a real undo"
pass "unblocked undo restored account 1 to 100 (proves the guard blocks only zero-row writes)"

echo "==> undo-of-INSERT under RLS also fails loudly (DELETE branch)"
# A fresh, isolated row (its own transaction, never updated => no dependents), so
# the undo classifies clean and reaches the compensating DELETE. Under RLS that
# DELETE is filtered to zero rows; "already gone" is indistinguishable from
# "filtered" to an RLS-bound role, so it is a failure too, never a silent no-op.
PSQL "INSERT INTO public.accounts VALUES (3, 999)" >/dev/null
INS_TXID=$(PSQL "SELECT max(txid) FROM eter.history WHERE op='I' AND NOT is_undo")
PSQL "ALTER TABLE public.accounts ENABLE ROW LEVEL SECURITY" >/dev/null  -- reactivates the 'block' policy
set +e
OUT2=$(psql "$APPURL" -tAqc "SELECT eter.undo($INS_TXID)" 2>&1); RC2=$?
set -e
[ "$RC2" -ne 0 ] || fail "undo-of-INSERT returned success despite deleting nothing: $OUT2"
echo "$OUT2" | grep -q "matched 0 rows" || fail "undo-of-INSERT failed without the zero-row diagnosis: $OUT2"
[ "$(PSQL "SELECT count(*) FROM public.accounts WHERE id=3")" = "1" ] || fail "row vanished despite the undo failing"
pass "undo-of-INSERT raised (\"matched 0 rows\"); the row survives"

echo "ALL PASS (issue #189: zero-row undo fails loudly instead of false success)"
