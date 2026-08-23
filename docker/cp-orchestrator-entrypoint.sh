#!/usr/bin/env bash
# Orchestrator wrapper for the bundled control-plane container: ensure the backup
# directory exists on the shared volume, wait for the local metadata store + the
# remote engine, then exec the orchestrator (the /v1 API + job runner + storage
# maintenance scheduler). supervisord restarts us on crash.
#
# Required env: DATABASE_URL (tenant engine) and ETER_META_URL (local meta store,
#               a SEPARATE database, the RequireMetaURL gate enforces this).
# Recommended:  ETER_WAL_ARCHIVE (shared volume), ETER_API_TOKEN.
set -euo pipefail

if [ -n "${ETER_BACKUP_DIR:-}" ] && ! mkdir -p "$ETER_BACKUP_DIR" 2>/dev/null; then
  echo "orchestrator: cannot create ETER_BACKUP_DIR=$ETER_BACKUP_DIR, is the shared" >&2
  echo "              /var/lib/eter volume mounted and writable by the postgres user?" >&2
  exit 1
fi

wait_for() {
  local url="$1" name="$2" i
  for i in $(seq 1 150); do
    if pg_isready -d "$url" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  echo "eter control-plane/orchestrator: $name not ready after timeout" >&2
  return 1
}

wait_for "${ETER_META_URL:?ETER_META_URL is required}" "metadata store"
wait_for "${DATABASE_URL:?DATABASE_URL is required}"    "engine"
exec eter-orchestrator "$@"
