#!/usr/bin/env bash
# Metadata-store Postgres for the bundled control-plane container.
#
# On first boot this initializes a SEPARATE cluster (db `eter_meta`) and applies
# the eter SQL engine (write history, dependency graph, ddl_log, backup catalog,
# job queue), then runs postgres in the foreground under supervisord. It is the
# SAME durable metadata store the 4-service stack runs as its own `meta`
# container; here it is colocated with the capture + orchestrator daemons in one
# deployment unit. Crucially it is STILL separate from the tenant engine
# (container A), so durable recovery metadata survives the tenant having a very
# bad day, the one invariant the split exists to protect.
#
# supervisord runs this as the `postgres` user (no gosu needed). Re-running with
# an existing data dir just starts the server (idempotent).
set -euo pipefail

META_PGDATA="${META_PGDATA:-/var/lib/eter-meta/data}"
META_DB="${META_DB:-eter_meta}"
META_USER="${POSTGRES_USER:-eter}"
META_PASSWORD="${POSTGRES_PASSWORD:-eter}"
META_PORT="${META_PORT:-5432}"
ETER_SQL_FILE="${ETER_SQL_FILE:-/opt/eter/eter.sql}"

if [ ! -s "$META_PGDATA/PG_VERSION" ]; then
  echo "eter control-plane: initializing metadata store in $META_PGDATA"
  mkdir -p "$META_PGDATA"
  initdb -D "$META_PGDATA" -U "$META_USER" --auth-local=trust --auth-host=trust >/dev/null

  cat >> "$META_PGDATA/postgresql.conf" <<CONF
# The metadata store only ever serves the local capture + orchestrator daemons
# over the loopback interface inside this container, never the tenant.
listen_addresses = 'localhost'
port = ${META_PORT}
CONF
  echo "host all all 127.0.0.1/32 trust" >> "$META_PGDATA/pg_hba.conf"
  echo "host all all ::1/128 trust"       >> "$META_PGDATA/pg_hba.conf"

  # Bootstrap over the unix socket, create the meta DB, apply the eter schema.
  pg_ctl -D "$META_PGDATA" -o "-c listen_addresses='' -p ${META_PORT}" -w start
  psql -v ON_ERROR_STOP=1 -p "$META_PORT" -U "$META_USER" -d postgres <<SQL
SELECT 'CREATE DATABASE ${META_DB}'
 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${META_DB}')\gexec
ALTER ROLE ${META_USER} WITH PASSWORD '${META_PASSWORD}';
SQL
  psql -v ON_ERROR_STOP=1 -p "$META_PORT" -U "$META_USER" -d "$META_DB" -f "$ETER_SQL_FILE"
  pg_ctl -D "$META_PGDATA" -w stop
  echo "eter control-plane: metadata store ready (db=${META_DB})"
fi

exec postgres -D "$META_PGDATA"
