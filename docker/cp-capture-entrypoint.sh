#!/usr/bin/env bash
# Capture sidecar wrapper for the bundled control-plane container: wait until
# BOTH the local metadata store and the remote engine accept connections, then
# exec the logical-decoding capture binary. supervisord restarts us on crash,
# so if the engine is briefly unreachable we simply retry.
#
# Required env: DATABASE_URL (the tenant engine, container A) and ETER_META_URL
#               (the local metadata store, this container).
set -euo pipefail

wait_for() {
  local url="$1" name="$2" i
  for i in $(seq 1 150); do
    if pg_isready -d "$url" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  echo "eter control-plane/capture: $name not ready after timeout" >&2
  return 1
}

wait_for "${ETER_META_URL:?ETER_META_URL is required}" "metadata store"
wait_for "${DATABASE_URL:?DATABASE_URL is required}"    "engine"
exec eter-capture "$@"
