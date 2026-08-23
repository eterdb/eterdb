#!/usr/bin/env bash
# EterDB Phase 3, DROP TABLE CASCADE e2e (issue #65). Runs LOCALLY (macOS or
# Linux) with no VM, no ZFS, no root: same storage substrate as storage-pitr.sh,
# pg_basebackup base backups + archived-WAL replay into a throwaway Postgres
# (ADR 0003), all ordinary unprivileged operations, bookkeeping in a SEPARATE
# EterDB-owned store (ETER_META_URL), not the tenant.
#
# CASCADE is the sharp case a `DROP TABLE` recovery must get right: dropping a
# parent table with CASCADE silently takes out *other* objects that depend on it
#, a child table's FOREIGN KEY constraint, a dependent VIEW, none of which the
# operator named. This test proves, end to end:
#   - the CASCADE really removes the collateral (FK on the surviving child, the
#     view) while the child table itself survives with its data;
#   - the DDL log indexes EXACTLY ONE destructive event, the parent DROP TABLE.
#     The cascade-dropped FK/view are internal (r.original = false) and are NOT
#     mistaken for separately-recoverable drops (the recovery index stays clean);
#   - `recover-table` restores the parent table exactly, INCLUDING a row written
#     after the base backup (WAL replayed to just before the drop), and finds the
#     correct pre-drop backup even when a newer backup was taken AFTER the CASCADE;
#   - the surviving child's rows are untouched and, once the parent is back, carry
#     zero dangling references;
#   - the STRICT boundary: object-scoped recovery restores the dropped OBJECT, not
#     the collateral. The FK and view are still absent right after recover-table,
#     but because the referenced parent rows are back, the operator re-establishes
#     both cleanly (the FK validates with zero violations), making the schema whole.
#
# Defaults to the patched Postgres (PG18) in .pgbuild18, the engine that ships,
# but storage recovery is mode-independent, so it also runs against a stock
# Postgres (override PGBUILD=/path/to/prefix); observe GUCs are added only when
# the build understands them.
set -euo pipefail
cd "$(dirname "$0")/.."

PGB="${PGBUILD:-$PWD/.pgbuild18}/bin"
[ -x "$PGB/postgres" ] || { echo "Postgres not found at $PGB, see pg/README.md (or set PGBUILD)"; exit 1; }
export PATH="$PGB:$PATH"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/eter-cascade.XXXXXX")
MP=$WORK/pgtenant
META_MP=$WORK/pgmeta
ARCHIVE=$WORK/walarchive
BACKUPS=$WORK/backups
PORT="${PGPORT:-5520}"
META_PORT=$((PORT + 2))
DBURL="postgres://eter@localhost:$PORT/eter"
META_URL="postgres://eter@localhost:$META_PORT/eter_meta"

# Storage sidecar is Go (docs/adr/0001-sidecars-in-go.md), build a static binary.
SIDE=$WORK/eter-storage
( cd sidecars && CGO_ENABLED=0 go build -o "$SIDE" ./storage ) \
  || { echo "go build storage failed"; exit 1; }

export DATABASE_URL="$DBURL"
export ETER_META_URL="$META_URL"          # storage bookkeeping → the store
export ETER_BACKUP_DIR="$BACKUPS"
export ETER_TMP_PORT=$((PORT + 99))
export ETER_WAL_ARCHIVE="$ARCHIVE"
export ETER_PG_BINDIR="$PGB"
unset ETER_PG_OS_USER 2>/dev/null || true # same-uid path: sidecar == postgres user

pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; exit 1; }
PSQL() { psql "$DBURL" -tAqc "$1"; }          # tenant (user data)
PSQL_M() { psql "$META_URL" -tAqc "$1"; }     # store  (storage bookkeeping)
side() { "$SIDE" "$@"; }                      # storage sidecar (inherits ETER_META_URL)
# Force the current WAL segment out to a fresh file and wait until it is archived,
# so restore-based recovery can replay up to the latest writes. archive_command
# only ships COMPLETED segments.
flush_wal() {
  SEG=$(PSQL "SELECT pg_walfile_name(pg_current_wal_lsn())")
  PSQL "SELECT pg_switch_wal()" >/dev/null
  i=0; while [ ! -f "$ARCHIVE/$SEG" ] && [ $i -lt 30 ]; do i=$((i+1)); sleep 1; done
  [ -f "$ARCHIVE/$SEG" ] || fail "WAL segment $SEG never archived"
}

teardown() {
  pg_ctl -D "$MP" -m immediate stop >/dev/null 2>&1 || true
  pg_ctl -D "$META_MP" -m immediate stop >/dev/null 2>&1 || true
  # any throwaway recovery instance still up (failed run) is under $BACKUPS/.restore
  for d in "$BACKUPS"/.restore/*/ ; do
    [ -d "$d" ] && pg_ctl -D "$d" -m immediate stop >/dev/null 2>&1 || true
  done
  rm -rf "$WORK"
}
trap teardown EXIT

# The shipping engine runs observe on; a stock Postgres doesn't know the GUC.
# Storage recovery is mode-independent, so probe and add observe only if supported.
OBSERVE_CONF=""
if postgres --describe-config 2>/dev/null | grep -q eter_observe_mode; then
  OBSERVE_CONF=$'eter_observe_mode = on\nmax_pred_locks_per_transaction = 4096'
fi

echo "==> set up tenant PG with WAL archiving (plain dirs, no ZFS, no root)"
mkdir -p "$ARCHIVE" "$BACKUPS"
initdb -D "$MP" -U eter --auth-local=trust --auth-host=trust >/dev/null
cat >>"$MP/postgresql.conf" <<EOF
port = $PORT
listen_addresses = 'localhost'
unix_socket_directories = '/tmp'
wal_level = replica
archive_mode = on
archive_command = 'cp %p $ARCHIVE/%f'
$OBSERVE_CONF
EOF
pg_ctl -D "$MP" -l "$MP/pg.log" -w -t 60 start >/dev/null
createdb -h localhost -p "$PORT" -U eter eter
psql "$DBURL" -q -f ext/eter/eter.sql >/dev/null
# DDL logging records each destructive DROP's LSN (eter.ddl_log.snapshot_lsn),
# object recovery replays archived WAL to just before it.
psql "$DBURL" -q -c "SELECT eter.enable_ddl_logging()" >/dev/null
pass "tenant PG up${OBSERVE_CONF:+ (observe on)}, archiving to $ARCHIVE, engine + DDL logging applied"

echo "==> META STORE: separate EterDB-owned PG"
initdb -D "$META_MP" -U eter --auth-local=trust --auth-host=trust >/dev/null
cat >>"$META_MP/postgresql.conf" <<EOF
port = $META_PORT
listen_addresses = 'localhost'
unix_socket_directories = '/tmp'
EOF
pg_ctl -D "$META_MP" -l "$META_MP/pg.log" -w -t 60 start >/dev/null
createdb -h localhost -p "$META_PORT" -U eter eter_meta
psql "$META_URL" -q -f ext/eter/eter.sql >/dev/null
pass "meta store up; storage bookkeeping (storage_snapshots, recovery_log) is here"

# ---------------------------------------------------------------------------
echo "==> build the dependency web: customers <- orders (FK), gold_customers (view)"
PSQL "CREATE TABLE public.customers(id int PRIMARY KEY, name text, tier text)"
PSQL "INSERT INTO public.customers SELECT g, 'c'||g, 'gold' FROM generate_series(1,5) g"
PSQL "CREATE TABLE public.orders(id int PRIMARY KEY,
        customer_id int REFERENCES public.customers(id), amt int)"
PSQL "INSERT INTO public.orders SELECT g, ((g-1)%5)+1, g*10 FROM generate_series(1,12) g"
PSQL "CREATE VIEW public.gold_customers AS
        SELECT id, name FROM public.customers WHERE tier='gold'"
[ "$(PSQL "SELECT count(*) FROM pg_constraint WHERE conrelid='public.orders'::regclass AND contype='f'")" = "1" ] \
  || fail "expected the orders->customers FK to exist before the drop"
[ "$(PSQL "SELECT count(*) FROM pg_views WHERE schemaname='public' AND viewname='gold_customers'")" = "1" ] \
  || fail "expected gold_customers view to exist before the drop"
pass "dependency web up: 5 customers, 12 orders (FK), 1 dependent view"

SNAP1=$(side snapshot manual); pass "base backup taken: $SNAP1"
[ -d "$BACKUPS/$SNAP1" ] || fail "backup dir $BACKUPS/$SNAP1 missing on disk"
PSQL "INSERT INTO public.customers VALUES (6,'c6','silver')"   # write AFTER backup, before drop

# ---------------------------------------------------------------------------
echo "==> DROP TABLE public.customers CASCADE"
PSQL "DROP TABLE public.customers CASCADE"
flush_wal
[ "$(PSQL "SELECT to_regclass('public.customers') IS NULL")" = "t" ] || fail "customers not actually dropped"
[ "$(PSQL "SELECT to_regclass('public.orders') IS NOT NULL")" = "t" ] || fail "CASCADE wrongly dropped the child table orders"
[ "$(PSQL "SELECT count(*) FROM pg_constraint WHERE conrelid='public.orders'::regclass AND contype='f'")" = "0" ] \
  || fail "CASCADE should have dropped the orders->customers FK constraint"
[ "$(PSQL "SELECT count(*) FROM pg_views WHERE schemaname='public' AND viewname='gold_customers'")" = "0" ] \
  || fail "CASCADE should have dropped the dependent view"
[ "$(PSQL "SELECT count(*) FROM public.orders")" = "12" ] || fail "surviving child orders lost rows"
pass "CASCADE removed collateral: FK on orders + gold_customers view gone; orders table + 12 rows survive"

# ---------------------------------------------------------------------------
# The recovery index must not be confused by CASCADE. Only the parent DROP TABLE
# is an operator-issued, top-level (r.original) destructive event; the FK and view
# are internal cascade drops (r.original = false) and must NOT be logged as
# separately-recoverable, otherwise the sidecar would chase phantom objects.
echo "==> DDL log indexes exactly ONE destructive event (the parent drop)"
DESTRUCT=$(PSQL "SELECT count(*) FROM eter.ddl_log WHERE is_destructive")
[ "$DESTRUCT" = "1" ] || fail "expected exactly 1 destructive drop under CASCADE, got $DESTRUCT"
ONE=$(PSQL "SELECT count(*) FROM eter.ddl_log
             WHERE is_destructive AND object_type='table' AND command_tag='DROP TABLE'
               AND object_identity='public.customers' AND needs_snapshot AND snapshot_lsn IS NOT NULL")
[ "$ONE" = "1" ] || fail "the one destructive row is not the DROP TABLE public.customers recovery index"
LEAK=$(PSQL "SELECT count(*) FROM eter.ddl_log
              WHERE is_destructive AND object_identity IN ('public.gold_customers','orders_customer_id_fkey')")
[ "$LEAK" = "0" ] || fail "cascade-dropped FK/view leaked into the destructive recovery index"
pass "recovery index clean: 1 destructive event (DROP TABLE public.customers); cascade FK/view excluded"

# ---------------------------------------------------------------------------
# A newer backup taken AFTER the CASCADE must not fool recovery: object recovery
# restores the backup taken BEFORE the drop (resolved by the drop's LSN), replays
# WAL to just before it, and so recovers the post-backup write (customer 6) too.
echo "==> recover-table finds the pre-drop backup despite a newer post-drop backup"
SNAP_AFTER=$(side snapshot manual); pass "decoy base backup taken AFTER the drop: $SNAP_AFTER"
side recover-table public.customers >/dev/null 2>&1
[ "$(PSQL "SELECT count(*) FROM public.customers")" = "6" ] \
  || fail "table not recovered to 6 rows (post-backup write via WAL replay missing, or wrong backup picked)"
[ "$(PSQL "SELECT count(*) FROM public.customers WHERE name='c'||id")" = "6" ] \
  || fail "recovered customer rows differ from originals"
[ "$(PSQL "SELECT tier FROM public.customers WHERE id=6")" = "silver" ] \
  || fail "post-backup row (customer 6) not recovered by WAL replay"
pass "parent recovered exactly: 6 rows incl. the post-backup write (WAL replayed to just before the drop)"

# ---------------------------------------------------------------------------
echo "==> STRICT boundary: object-scoped recovery restores the OBJECT, not the collateral"
[ "$(PSQL "SELECT count(*) FROM pg_constraint WHERE conrelid='public.orders'::regclass AND contype='f'")" = "0" ] \
  || fail "recover-table unexpectedly re-created the FK (it is object-scoped by design)"
[ "$(PSQL "SELECT count(*) FROM pg_views WHERE schemaname='public' AND viewname='gold_customers'")" = "0" ] \
  || fail "recover-table unexpectedly re-created the view (it is object-scoped by design)"
[ "$(PSQL "SELECT count(*) FROM public.orders")" = "12" ] || fail "surviving child rows changed by recovery"
pass "FK + view still absent after recover-table (recovery is object-scoped, as designed)"

# ---------------------------------------------------------------------------
# Closure: the referenced parent rows are back, so the schema is whole-able. The
# child carries zero dangling references, so re-ADDing the FK validates with no
# violations, and the dependent view re-creates cleanly.
echo "==> closure: with the parent back, the operator re-establishes the collateral"
DANGLE=$(PSQL "SELECT count(*) FROM public.orders o
                WHERE NOT EXISTS (SELECT 1 FROM public.customers c WHERE c.id=o.customer_id)")
[ "$DANGLE" = "0" ] || fail "orders carry $DANGLE dangling references, parent rows not fully recovered"
PSQL "ALTER TABLE public.orders
        ADD CONSTRAINT orders_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id)" >/dev/null \
  || fail "re-adding the FK failed, recovered parent rows do not satisfy the child's references"
PSQL "CREATE VIEW public.gold_customers AS
        SELECT id, name FROM public.customers WHERE tier='gold'" >/dev/null \
  || fail "re-creating the dependent view failed"
[ "$(PSQL "SELECT count(*) FROM pg_constraint WHERE conrelid='public.orders'::regclass AND contype='f' AND convalidated")" = "1" ] \
  || fail "re-added FK is not validated"
[ "$(PSQL "SELECT count(*) FROM public.gold_customers")" = "5" ] || fail "re-created view returns wrong rows"
pass "FK re-added + validated (0 violations) and view re-created, schema whole again"

# ---------------------------------------------------------------------------
echo "==> bookkeeping is in the STORE, not the tenant"
SNAPS=$(PSQL_M "SELECT count(*) FROM eter.storage_snapshots")
RECS=$(PSQL_M "SELECT count(*) FROM eter.recovery_log WHERE object_identity='public.customers' AND object_type='table'")
[ "$SNAPS" -ge 2 ] || fail "store should hold the backup catalog (>=2 backups, got $SNAPS)"
[ "$RECS" -ge 1 ] || fail "store should hold the CASCADE table recovery in the recovery log (got $RECS)"
[ "$(PSQL "SELECT count(*) FROM eter.storage_snapshots")" = "0" ] || fail "tenant holds backup-catalog rows, expected ZERO"
[ "$(PSQL "SELECT count(*) FROM eter.recovery_log")" = "0" ]      || fail "tenant holds recovery-log rows, expected ZERO"
pass "backup catalog ($SNAPS) + recovery log in the store; tenant eter bookkeeping is empty"

echo ""
echo "ALL DROP TABLE CASCADE E2E CHECKS PASSED ✅"
