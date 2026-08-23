#!/usr/bin/env bash
# Sidecar-only capture: the headline guarantees.
#   - the engine default is 'auto' (sidecar, or refuse)
#   - eter.track REFUSES loudly with no capture sidecar (no silent no-capture)
#   - `eter init` installs the engine anyway and reports tables PENDING (exit 0)
#   - `eter track --all` with no sidecar exits 7 (ExitPrereq)
#   - with a live logical consumer present, track/init do sidecar setup (no trigger)
#   - auto-track-on-create tracks a new PK table; a CREATE never breaks when the
#     sidecar is gone
# One throwaway cluster, no meta store, no Docker. Mode-independent, so it runs on
# any PG build, defaulting to $PGBUILD (.pgbuild18).
set -euo pipefail

PGBUILD="${PGBUILD:-$PWD/.pgbuild18}"
PGBIN="$PGBUILD/bin"
PORT="${ETER_REFUSE_PORT:-5455}"
DATA="$PWD/.pgdata-capture-refuse"
DBURL="postgres://postgres@localhost:$PORT/postgres?host=/tmp"

pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗ %s\033[0m\n' "$1"; exit 1; }

RECV_PID=""
cleanup() {
  [ -n "$RECV_PID" ] && kill "$RECV_PID" 2>/dev/null || true
  "$PGBIN/pg_ctl" -D "$DATA" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$DATA"
}
trap cleanup EXIT

rm -rf "$DATA"
"$PGBIN/initdb" -D "$DATA" -U postgres --auth-local=trust --auth-host=trust >/dev/null
cat >> "$DATA/postgresql.conf" <<CONF
port = $PORT
unix_socket_directories = '/tmp'
wal_level = logical
max_replication_slots = 8
max_wal_senders = 8
CONF
"$PGBIN/pg_ctl" -D "$DATA" -l "$DATA/server.log" -w start >/dev/null
PSQL() { "$PGBIN/psql" "$DBURL" -tAc "$1"; }

go build -C cli -o eter . || fail "eter CLI build failed"
ETER="$PWD/cli/eter --db $DBURL"

echo "==> engine + defaults"
PSQL "CREATE TABLE public.a(id int primary key, v text)" >/dev/null
PSQL "CREATE TABLE public.b(id int primary key)" >/dev/null
PSQL "CREATE TABLE public.nopk(v text)" >/dev/null
$ETER init --json >/dev/null 2>&1 || true            # engine only for now
[ "$(PSQL "SELECT eter._capture_mode()")" = "auto" ] || fail "default capture mode is not 'auto'"
[ "$(PSQL "SELECT eter._sidecar_present()")" = "f" ] || fail "sidecar falsely reported present"
pass "engine default is 'auto'; no sidecar detected"

echo "==> refuse-loud with no sidecar"
if PSQL "SELECT eter.track('public.a')" >/dev/null 2>&1; then
  fail "track SUCCEEDED with no sidecar (should refuse)"
fi
MSG="$(PSQL "SELECT eter.track('public.a')" 2>&1 || true)"
echo "$MSG" | grep -q "no capture sidecar detected" || fail "refuse message missing (got: $MSG)"
[ "$(PSQL "SELECT count(*) FROM eter.tracked")" = "0" ] || fail "a table was tracked despite the refuse"
pass "eter.track refuses loudly; nothing tracked"

echo "==> eter track --all -> exit 7"
set +e
$ETER track --all --json >/dev/null 2>&1
[ "$?" = "7" ] || fail "track --all did not exit 7 with no sidecar"
set -e
pass "track --all exits 7 (ExitPrereq)"

echo "==> eter init auto-track reports pending (exit 0), installs the engine"
OUT="$($ETER init --json)" || fail "eter init failed with no sidecar"
echo "$OUT" | grep -q '"pending": 2' || fail "init did not report 2 pending (got: $OUT)"
[ "$(PSQL "SELECT eter._auto_track_enabled()")" = "t" ] || fail "init did not enable auto_track"
pass "init installs + reports pending; auto_track on"

echo "==> bring a live logical consumer up (stand-in for the capture sidecar)"
PSQL "CREATE PUBLICATION eter_pub" >/dev/null 2>&1 || true
PSQL "SELECT pg_create_logical_replication_slot('eter_slot','pgoutput')" >/dev/null
"$PGBIN/pg_recvlogical" -h /tmp -p "$PORT" -U postgres -d postgres \
  --slot=eter_slot --start -o proto_version=1 -o publication_names=eter_pub -f /dev/null \
  >/dev/null 2>&1 &
RECV_PID=$!
for _ in $(seq 1 30); do
  [ "$(PSQL "SELECT coalesce((SELECT active FROM pg_replication_slots WHERE slot_name='eter_slot'),false)")" = "t" ] && break
  sleep 0.3
done
[ "$(PSQL "SELECT eter._sidecar_present()")" = "t" ] || fail "sidecar not detected once the slot is active"
pass "sidecar detected (active logical slot + eter_pub)"

echo "==> track now does sidecar setup, no trigger"
PSQL "SELECT eter.track('public.a')" >/dev/null
[ "$(PSQL "SELECT relreplident FROM pg_class WHERE oid='public.a'::regclass")" = "f" ] || fail "REPLICA IDENTITY not FULL"
[ "$(PSQL "SELECT count(*) FROM pg_publication_rel pr JOIN pg_publication p ON p.oid=pr.prpubid WHERE p.pubname='eter_pub' AND pr.prrelid='public.a'::regclass")" = "1" ] || fail "table not in eter_pub"
[ "$(PSQL "SELECT count(*) FROM pg_trigger WHERE tgrelid='public.a'::regclass AND tgname='eter_capture'")" = "0" ] || fail "a capture trigger was installed in sidecar mode"
pass "track set REPLICA IDENTITY FULL + publication, no trigger"

echo "==> auto-track-on-create; CREATE never breaks"
PSQL "SELECT eter.enable_ddl_logging()" >/dev/null
PSQL "SELECT eter.set_auto_track(true)" >/dev/null
PSQL "CREATE TABLE public.c(id int primary key)" >/dev/null
[ "$(PSQL "SELECT count(*) FROM eter.tracked WHERE table_name='c'")" = "1" ] || fail "new PK table not auto-tracked"
kill "$RECV_PID" 2>/dev/null; RECV_PID=""; sleep 1
PSQL "CREATE TABLE public.d(id int primary key)" >/dev/null || fail "CREATE TABLE broke with the sidecar gone"
[ "$(PSQL "SELECT count(*) FROM eter.tracked WHERE table_name='d'")" = "0" ] || fail "d tracked though no sidecar (auto-track should have been swallowed)"
pass "new table auto-tracks; CREATE succeeds (untracked) when the sidecar is gone"

echo
echo "ALL SIDECAR-ONLY CAPTURE CHECKS PASSED ✅"
