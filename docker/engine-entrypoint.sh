#!/usr/bin/env bash
# First-boot bootstrap for the EterDB engine image: initialize the cluster,
# turn on observe-mode capture (eter_ssi preloaded + the drain bgworker + the
# eter_observe_mode GUC), install the eter SQL engine and the eter_ssi
# extension, then exec postgres. Idempotent, re-running with an existing data
# dir just starts the server.
set -euo pipefail

POSTGRES_USER="${POSTGRES_USER:-eter}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-eter}"
POSTGRES_DB="${POSTGRES_DB:-eter}"

# Drop privileges to the postgres user (the server refuses to run as root).
if [ "$(id -u)" = '0' ]; then
  mkdir -p "$PGDATA"
  chown -R postgres:postgres "$PGDATA" /var/lib/postgresql
  exec gosu postgres "$0" "$@"
fi

if [ ! -s "$PGDATA/PG_VERSION" ]; then
  echo "eterdb: initializing a new cluster in $PGDATA"
  initdb -U "$POSTGRES_USER" --auth-local=trust --auth-host=trust >/dev/null

  cat >> "$PGDATA/postgresql.conf" <<CONF
listen_addresses = '*'
# Observe mode: capture read dependencies without serialization failures.
shared_preload_libraries = 'eter_ssi'
# WAL archiving, required for lossless object recovery (the storage sidecar
# replays archived WAL to just before a drop/truncate). Enabled when a WAL archive
# dir is provided (ETER_WAL_ARCHIVE), typically a volume shared with the storage
# sidecar. wal_level=logical below already satisfies archiving.
CONF
  if [ -n "${ETER_WAL_ARCHIVE:-}" ]; then
    mkdir -p "$ETER_WAL_ARCHIVE"
    cat >> "$PGDATA/postgresql.conf" <<CONF
archive_mode = on
archive_command = 'test ! -f "${ETER_WAL_ARCHIVE}/%f" && cp "%p" "${ETER_WAL_ARCHIVE}/%f"'
CONF
  fi
  cat >> "$PGDATA/postgresql.conf" <<CONF
eter_ssi.drain_database = '${POSTGRES_DB}'
# SSI predicate-lock pool, observe depends on predicate locks; raise it (the
# default exhausts under load → "out of shared memory"). See test/perf-overhead.
max_pred_locks_per_transaction = 1024
# Logical decoding, so the capture sidecar can run off the commit path if used.
wal_level = logical
max_wal_senders = 10
max_replication_slots = 10
CONF
  echo "host all all all trust" >> "$PGDATA/pg_hba.conf"
  # pg_basebackup (the storage sidecar's base backups) connects via the
  # replication protocol, which the `all` database keyword above does NOT match.
  echo "host replication all all trust" >> "$PGDATA/pg_hba.conf"

  # Bootstrap over the unix socket only (no TCP yet).
  pg_ctl -D "$PGDATA" -o "-c listen_addresses=''" -w start

  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<SQL
SELECT 'CREATE DATABASE ${POSTGRES_DB}'
 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${POSTGRES_DB}')\gexec
ALTER ROLE ${POSTGRES_USER} WITH PASSWORD '${POSTGRES_PASSWORD}';
SQL

  # Install the eter engine + the read-dependency capture extension, and make
  # observe mode the default for this database (every session captures reads).
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
    -f /opt/eter/eter.sql
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
    -c "CREATE EXTENSION IF NOT EXISTS eter_ssi" \
    -c "ALTER DATABASE ${POSTGRES_DB} SET eter_observe_mode = on" \
    -c "SELECT eter.enable_ddl_logging()"  # record each DROP/TRUNCATE's LSN for storage recovery

  # Capture mode: 'sidecar' (the DEFAULT, the shipping architecture) means NO
  # history trigger in the tenant; the capture sidecar decodes writes off the
  # commit path. The logical slot is created HERE, at init, so capture is
  # gap-free even if the sidecar container starts late, the slot retains WAL
  # until consumed. Set ETER_CAPTURE_MODE=trigger ONLY for a standalone engine
  # with no capture sidecar (in-DB trigger capture; a slotless engine must not
  # pin WAL it will never drain).
  ETER_CAPTURE_MODE="${ETER_CAPTURE_MODE:-sidecar}"
  if [ "$ETER_CAPTURE_MODE" = "sidecar" ]; then
    ETER_SLOT="${ETER_SLOT:-eter_slot}"
    # Publication BEFORE slot: pgoutput resolves publications against a HISTORIC
    # catalog snapshot at each decoded position, so creating eter_pub (empty,
    # track adds members) ahead of the slot guarantees it exists at every
    # position the slot can ever decode, on any PG version.
    # capture_mode='sidecar' is pinned explicitly (not left to the 'auto' default)
    # so track() never has to observe an attached sidecar; it bypasses the
    # presence check, so a table tracked in the boot gap before the capture
    # container attaches still gets its publication membership + REPLICA IDENTITY.
    # auto_track + DDL logging make every table created later (the demo, an app's
    # own schema) track itself, so the deployed stack ends "everything tracked".
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
      -c "ALTER DATABASE ${POSTGRES_DB} SET eter.capture_mode = 'sidecar'" \
      -c "SELECT eter._ensure_publication()" \
      -c "SELECT pg_create_logical_replication_slot('${ETER_SLOT}', 'pgoutput') WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = '${ETER_SLOT}')" \
      -c "SELECT eter.set_auto_track(true)" \
      -c "SELECT eter.enable_ddl_logging()"
    echo "eterdb: capture mode = sidecar (slot ${ETER_SLOT} pre-created, auto-track on, run the capture sidecar)"
  else
    echo "eterdb: capture mode = trigger (in-DB capture; no sidecar expected)"
  fi

  pg_ctl -D "$PGDATA" -w stop
  # Mark this data dir as EterDB-bootstrapped, so a later boot can tell a real
  # eter cluster apart from a stale or foreign pgdata that skipped bootstrap.
  touch "$PGDATA/.eter_engine_initialized"
  echo "eterdb: engine ready (observe mode on, eter + eter_ssi installed)"
elif [ ! -f "$PGDATA/.eter_engine_initialized" ]; then
  # PG_VERSION exists but this dir was NOT bootstrapped by EterDB: a stale or
  # foreign Postgres data directory (a leftover volume from earlier work, or a
  # plain postgres image). It has no eter role/engine, so the demo would fail
  # with `role "eter" does not exist`. Fail immediately with the fix instead of
  # exec'ing a broken server that only trips the healthcheck 120s later.
  echo "eterdb: ERROR: the mounted pgdata was not initialized by EterDB" >&2
  echo "eterdb:        (an existing data directory with no eter role/engine)." >&2
  echo "eterdb:        Wipe the stale volume and let EterDB bootstrap fresh:" >&2
  echo "eterdb:            docker compose down -v && docker compose up -d" >&2
  exit 1
fi

exec "$@"
