#!/usr/bin/env bash
# EterDB Phase 3, DDL-logging test (local, no Docker, no ZFS).
#
# Proves the destructive-DDL recovery INDEX: EterDB logs schema changes (it
# never rewrites them, no tombstones, no compatibility views). A DROP TABLE /
# DROP COLUMN is recorded in eter.ddl_log with its object identity, txid, statement
# sample, and needs_snapshot flag, the index the storage sidecar uses to restore
# the pre-event base backup and extract the lost object. CREATE/ALTER are logged
# as a non-destructive audit trail; EterDB's own schema is never logged.
set -euo pipefail
cd "$(dirname "$0")/.."

PGBIN="${PGBIN:-/opt/homebrew/opt/postgresql@18/bin}"
PGPORT="${ETER_TEST_PORT:-5440}"
PGDATA="$PWD/.pgdata-ddl"
DBURL="postgres://eter:eter@localhost:$PGPORT/eter"
PSQL_DB="$PGBIN/psql $DBURL -tAqc"

pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; exit 1; }
cleanup() { "$PGBIN/pg_ctl" -D "$PGDATA" -m immediate stop >/dev/null 2>&1 || true; rm -rf "$PGDATA"; }
trap cleanup EXIT

echo "==> spinning up throwaway cluster on :$PGPORT"
rm -rf "$PGDATA"
"$PGBIN/initdb" -D "$PGDATA" -U eter --auth-local=trust --auth-host=trust >/dev/null
{ echo "port = $PGPORT"; echo "listen_addresses = 'localhost'"; echo "client_min_messages = warning"; } >>"$PGDATA/postgresql.conf"
"$PGBIN/pg_ctl" -D "$PGDATA" -l "$PGDATA/server.log" -w start >/dev/null
"$PGBIN/createdb" -h localhost -p "$PGPORT" -U eter eter
"$PGBIN/psql" "$DBURL" -q -f ext/eter/eter.sql >/dev/null
pass "cluster up; engine applied"

$PSQL_DB "SELECT eter.enable_ddl_logging()" >/dev/null
pass "DDL logging enabled (event triggers installed)"

# Schema changes the log must capture.
$PSQL_DB "CREATE TABLE public.parts(id int PRIMARY KEY, name text, legacy_code text)" >/dev/null
$PSQL_DB "ALTER TABLE public.parts ADD COLUMN sku text" >/dev/null
$PSQL_DB "ALTER TABLE public.parts DROP COLUMN legacy_code" >/dev/null   # destructive: column
$PSQL_DB "DROP TABLE public.parts" >/dev/null                            # destructive: table

# CREATE + ALTER are audited as non-destructive.
CREATES=$($PSQL_DB "SELECT count(*) FROM eter.ddl_log WHERE command_tag='CREATE TABLE' AND NOT is_destructive")
[ "$CREATES" -ge 1 ] || fail "CREATE TABLE not logged"
ALTERS=$($PSQL_DB "SELECT count(*) FROM eter.ddl_log WHERE command_tag='ALTER TABLE' AND NOT is_destructive")
[ "$ALTERS" -ge 1 ] || fail "ALTER TABLE (add column) not logged"
pass "CREATE/ALTER logged as non-destructive audit trail"

# Destructive drops: the recovery index. Exactly two original drops (the column
# and the table); cascade/internal objects (pkey index, identity sequence) excluded.
DESTRUCT=$($PSQL_DB "SELECT count(*) FROM eter.ddl_log WHERE is_destructive")
[ "$DESTRUCT" = "2" ] || fail "expected 2 destructive drops, got $DESTRUCT"
pass "exactly 2 destructive drops indexed (column + table; cascades excluded)"

COL=$($PSQL_DB "SELECT count(*) FROM eter.ddl_log
                WHERE is_destructive AND object_type='table column'
                  AND object_identity='public.parts.legacy_code' AND needs_snapshot")
[ "$COL" = "1" ] || fail "DROP COLUMN public.parts.legacy_code not indexed correctly"
pass "DROP COLUMN indexed: object='public.parts.legacy_code', needs_snapshot=t"

TBL=$($PSQL_DB "SELECT count(*) FROM eter.ddl_log
                WHERE is_destructive AND object_type='table'
                  AND object_identity='public.parts' AND needs_snapshot")
[ "$TBL" = "1" ] || fail "DROP TABLE public.parts not indexed correctly"
pass "DROP TABLE indexed: object='public.parts', needs_snapshot=t"

# Provenance: txid, statement sample and snapshot_lsn are captured for recovery.
META=$($PSQL_DB "SELECT count(*) FROM eter.ddl_log
                 WHERE is_destructive AND txid > 0 AND statement ILIKE '%parts%' AND snapshot_lsn IS NOT NULL")
[ "$META" = "2" ] || fail "destructive rows missing txid/statement/snapshot_lsn provenance"
pass "destructive rows carry txid + statement + snapshot_lsn (recovery provenance)"

# EterDB's own schema is never logged (engine DDL pre-dates enable, and the
# triggers skip schema 'eter'); create a eter object now to confirm the skip.
$PSQL_DB "CREATE TABLE eter._probe(id int)" >/dev/null
SELF=$($PSQL_DB "SELECT count(*) FROM eter.ddl_log WHERE schema_name='eter'")
[ "$SELF" = "0" ] || fail "EterDB engine DDL leaked into the log ($SELF rows)"
pass "EterDB's own schema changes are not logged"

# disable removes the triggers cleanly.
$PSQL_DB "SELECT eter.disable_ddl_logging()" >/dev/null
LEFT=$($PSQL_DB "SELECT count(*) FROM pg_event_trigger WHERE evtname IN ('eter_ddl_end','eter_sql_drop')")
[ "$LEFT" = "0" ] || fail "disable_ddl_logging left event triggers behind"
pass "disable_ddl_logging removed the event triggers"

echo ""
echo "ALL PHASE 3 DDL-LOG CHECKS PASSED ✅"
