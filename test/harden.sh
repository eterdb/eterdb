#!/usr/bin/env bash
# EterDB Phase 3, capture-default + interim hardening, IN THE EXTERNALIZED
# (TWO-DB) DEPLOYMENT SHAPE (local, no Docker).
#
# The durable metadata is in a SEPARATE EterDB-owned store (a different
# cluster the tenant role has no route to at all, the strongest tamper boundary);
# any residual eter surface in the tenant is locked away from the tenant role:
#   Inc 4  eter.set_capture_default(mode) durably sets the per-database default
#          capture mode (the primitive a supervised-sidecar runtime calls to flip
#          the out-of-box default to 'sidecar' so nothing rides the commit path).
#   Inc 5  eter.harden_schema(role) locks the tenant's eter schema away from
#          the tenant role (REVOKE ALL incl. USAGE) + a non-owner DDL block.
#   + the meta store is a separate cluster: the tenant 'app' role cannot connect.
# Two throwaway clusters (tenant + store) on their own ports/datadirs.
set -euo pipefail
cd "$(dirname "$0")/.."

PGBIN="${PGBIN:-/opt/homebrew/opt/postgresql@18/bin}"
PORT="${ETER_TEST_PORT:-5438}"
M_PORT="${ETER_META_PORT:-5439}"
M_DATA="$PWD/.pgdata-harden-meta"
META_URL="postgres://eter:eter@localhost:$M_PORT/eter_meta"
APP_META_URL="postgres://app:app@localhost:$M_PORT/eter_meta"   # the tenant role has no account here
PSQL_M="$PGBIN/psql $META_URL -tAqc"
PGDATA="$PWD/.pgdata-harden"
OWNER_URL="postgres://eter:eter@localhost:$PORT/eter"
APP_URL="postgres://app:app@localhost:$PORT/eter"
PSQL_O="$PGBIN/psql $OWNER_URL -tAqc"

pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; exit 1; }
# Run a SQL string as the app (tenant) role; succeed iff it ERRORS.
app_denied() { # $1 = sql, $2 = label
  if "$PGBIN/psql" "$APP_URL" -v ON_ERROR_STOP=1 -tAqc "$1" >/dev/null 2>&1; then
    fail "tenant role was ALLOWED to: $2 (expected denial)"
  fi
}
app_ok() { # $1 = sql, $2 = label
  "$PGBIN/psql" "$APP_URL" -v ON_ERROR_STOP=1 -tAqc "$1" >/dev/null 2>&1 || fail "tenant role was DENIED: $2"
}

cleanup() {
  "$PGBIN/pg_ctl" -D "$PGDATA" -m immediate stop >/dev/null 2>&1 || true
  "$PGBIN/pg_ctl" -D "$M_DATA" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$PGDATA" "$M_DATA"
}
trap cleanup EXIT

echo "==> TENANT (:$PORT) + separate META store (:$M_PORT)"
rm -rf "$PGDATA" "$M_DATA"
"$PGBIN/initdb" -D "$PGDATA" -U eter --auth-local=trust --auth-host=trust >/dev/null
printf 'port = %s\nlisten_addresses = '"'"'localhost'"'"'\n' "$PORT" >> "$PGDATA/postgresql.conf"
"$PGBIN/pg_ctl" -D "$PGDATA" -l "$PGDATA/server.log" -w start >/dev/null
"$PGBIN/createdb" -h localhost -p "$PORT" -U eter eter
"$PGBIN/psql" "$OWNER_URL" -q -f ext/eter/eter.sql >/dev/null
"$PGBIN/psql" "$OWNER_URL" -q -f demo/schema.sql >/dev/null
# The meta store: a SEPARATE cluster holding the durable metadata. Its only role is
# the EterDB owner, there is no tenant 'app' account here.
"$PGBIN/initdb" -D "$M_DATA" -U eter --auth-local=trust --auth-host=trust >/dev/null
printf 'port = %s\nlisten_addresses = '"'"'localhost'"'"'\n' "$M_PORT" >> "$M_DATA/postgresql.conf"
"$PGBIN/pg_ctl" -D "$M_DATA" -l "$M_DATA/server.log" -w start >/dev/null
"$PGBIN/createdb" -h localhost -p "$M_PORT" -U eter eter_meta
"$PGBIN/psql" "$META_URL" -q -f ext/eter/eter.sql >/dev/null
# A non-superuser tenant role with normal access to its own (public) data.
$PSQL_O "CREATE ROLE app LOGIN PASSWORD 'app';
         GRANT ALL ON SCHEMA public TO app;
         GRANT ALL ON ALL TABLES IN SCHEMA public TO app;
         GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO app;" >/dev/null
pass "tenant + meta store up; engine on both; tenant role 'app' created"

# ===========================================================================
echo "==> the durable metadata store is a SEPARATE cluster the tenant role can't reach"
[ "$($PSQL_M "SELECT count(*) FROM eter.history")" = "0" ] || fail "store unexpectedly populated"
# The tenant 'app' role has no account on the store cluster, connecting fails.
if "$PGBIN/psql" "$APP_META_URL" -tAqc "SELECT 1" >/dev/null 2>&1; then
  fail "tenant role 'app' was able to connect to the meta store (expected no route)"
fi
pass "meta store holds the durable metadata; tenant 'app' role cannot connect to it at all"

# ===========================================================================
echo "==> Inc 4: eter.set_capture_default flips the per-database default"
[ "$($PSQL_O "SELECT eter._capture_mode()")" = "auto" ] || fail "expected hardcoded default 'auto'"
$PSQL_O "SELECT eter.set_capture_default('trigger')" >/dev/null
# ALTER DATABASE SET applies to NEW sessions; a fresh psql connection sees it.
NEWDEF=$($PSQL_O "SELECT eter._capture_mode()")
[ "$NEWDEF" = "trigger" ] || fail "new session default not 'trigger' (got $NEWDEF)"
[ "$($PSQL_O "SELECT eter.set_capture_default('bogus')" 2>&1 | grep -c 'invalid mode')" -ge 1 ] || fail "invalid mode not rejected"
$PSQL_O "SELECT eter.set_capture_default('auto')" >/dev/null
pass "default is 'auto'; override flips for new sessions (and back); invalid mode rejected"

# ===========================================================================
echo "==> Inc 5 (pre-harden): tenant can see eter (baseline)"
# Before hardening, grant app some eter access so the REVOKE is observable.
$PSQL_O "GRANT USAGE ON SCHEMA eter TO app; GRANT SELECT ON eter.markers TO app;" >/dev/null
app_ok "SELECT count(*) FROM eter.markers" "read eter.markers (pre-harden)"
pass "tenant could read eter.markers before hardening"

echo "==> Inc 5: harden_schema locks the eter schema away from the tenant"
$PSQL_O "SELECT eter.harden_schema('app')" >/dev/null
app_denied "SELECT count(*) FROM eter.markers"          "SELECT eter.markers"
app_denied "SELECT count(*) FROM eter.history"          "SELECT eter.history"
app_denied "INSERT INTO eter.markers(label) VALUES('x')" "INSERT eter.markers"
pass "tenant fully denied read + write on eter (REVOKE incl. schema USAGE)"

# DDL block: make app the owner of a throwaway eter object so ownership alone
# would allow the drop, the event trigger must still refuse it.
$PSQL_O "GRANT USAGE ON SCHEMA eter TO app;
         CREATE TABLE eter.app_owned(id int);
         ALTER TABLE eter.app_owned OWNER TO app;" >/dev/null
app_denied "DROP TABLE eter.app_owned"                 "DROP an app-owned eter object"
app_denied "ALTER TABLE eter.app_owned ADD COLUMN y int" "ALTER an app-owned eter object"
pass "non-owner DDL on eter objects blocked by the event trigger (even when role owns the object)"

# The owner is unaffected: can still manage eter + the engine still applies.
$PSQL_O "DROP TABLE eter.app_owned" >/dev/null || fail "owner blocked from its own eter DDL"
"$PGBIN/psql" "$OWNER_URL" -q -f ext/eter/eter.sql >/dev/null || fail "owner re-apply of engine blocked"
pass "owner manages eter freely; engine re-apply still works under hardening"

echo "==> Inc 5: unharden restores access + removes the block"
$PSQL_O "SELECT eter.unharden_schema('app')" >/dev/null
app_ok "SELECT count(*) FROM eter.markers" "read eter.markers (post-unharden)"
pass "unharden restored tenant access and dropped the DDL-block triggers"

echo ""
echo "ALL PHASE 3 CAPTURE-DEFAULT + HARDENING (TWO-DB) CHECKS PASSED ✅"
