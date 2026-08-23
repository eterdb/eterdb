#!/usr/bin/env bash
#
# capture-contract.sh - pin the in-engine capture contract every harness
# preamble depends on.
#
# Background (issue #197): test/compat.sh tracked tables in-engine and was
# broken for three days by #188 (capture is sidecar-only, so eter.track refuses
# with no sidecar attached). Nothing caught it, because compat.sh is local-only
# and not CI-gated: it builds 13 extensions from source and needs the patched
# engine. Most of the harness suite is local-only for the same reason.
#
# The drift risk, though, is concentrated in the PREAMBLE (track / capture mode
# / preview), not the scenario body, and the preamble is pure SQL: it needs no
# patched engine, no extension toolchain, and no fixtures. So this script pins
# it on ANY Postgres 18 in a couple of seconds, and CI runs it against a stock
# postgres:18 service container.
#
# It serves two callers:
#   1. CI (.github/workflows/ci.yml, job `capture-contract`), with
#      ETER_CONTRACT_LOAD=1 so it loads ext/eter/eter.sql itself.
#   2. A harness preflight. compat.sh runs it before the extension matrix, so a
#      broken preamble aborts loudly up front instead of surfacing as 13 rows
#      of `capture=✗` that read like a partial pass.
#
# Usage:
#   ETER_CONTRACT_URL=postgres://...  bash test/capture-contract.sh
#   ETER_CONTRACT_LOAD=1 ...          also (re)loads ext/eter/eter.sql first
#   PSQL_BIN=/path/to/psql            psql to use (default: psql on PATH)
#
# It touches only its own scratch objects (eter_contract_*) and untracks/drops
# them on exit, so it is safe to run against a live harness cluster.
#
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

PSQL_BIN="${PSQL_BIN:-psql}"
URL="${ETER_CONTRACT_URL:-${DATABASE_URL:-postgres://postgres@localhost:5432/postgres}}"
ERRF="$(mktemp)"

# A harness cluster may carry a persisted per-database capture mode (false-clean.sh
# does exactly that: ALTER DATABASE ... SET eter.capture_mode='trigger'). Every
# check below therefore states the mode it wants explicitly, and the two that
# probe the UNSET behaviour clear the GUC in-session with set_config(...,'',false)
# rather than RESET, which would only restore that persisted database-level value.
# Wrapped in DO rather than a bare SELECT so it emits no row of its own, which
# would otherwise land in the captured scalar.
UNSET_MODE="DO \$do\$ BEGIN PERFORM set_config('eter.capture_mode','',false); END \$do\$;"

# Run SQL for effect, quietly. Fails the script outright: these are setup steps,
# not assertions.
run() { # <sql> <label>
  "$PSQL_BIN" "$URL" -X -q -v ON_ERROR_STOP=1 -tAc "$1" >/dev/null 2>"$ERRF" \
    || { echo "  FAIL setup: $2" >&2; cat "$ERRF" >&2; exit 1; }
}

status=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1" >&2; status=1; }

# Assert a SQL scalar equals an expected value. Pass ONE value-returning
# statement (optionally preceded by setup statements ending in `;` that return
# nothing), so the captured stdout is the scalar and nothing else. NOTICEs go to
# stderr and are surfaced only when the query errors.
eq() { # <sql> <expected> <label>
  local got
  got="$("$PSQL_BIN" "$URL" -X -q -v ON_ERROR_STOP=1 -tAc "$1" 2>"$ERRF")" \
    || { fail "$3 (query errored: $(tr '\n' ' ' <"$ERRF"))"; return; }
  [ "$got" = "$2" ] && pass "$3" || fail "$3 (expected '$2', got '$got')"
}

# Assert a SQL statement raises, with the message matching a pattern.
raises() { # <sql> <pattern> <label>
  local out
  if out="$("$PSQL_BIN" "$URL" -X -q -v ON_ERROR_STOP=1 -tAc "$1" 2>&1)"; then
    fail "$3 (expected an error, statement succeeded)"
  elif echo "$out" | grep -qi -- "$2"; then
    pass "$3"
  else
    fail "$3 (error did not match '$2': $out)"
  fi
}

cleanup() {
  "$PSQL_BIN" "$URL" -X -q -tAc "
    SELECT eter.untrack('eter_contract_t') WHERE to_regclass('eter_contract_t') IS NOT NULL;
    DELETE FROM eter.tracked WHERE table_name LIKE '%eter_contract_%';
    DROP TABLE IF EXISTS eter_contract_t, eter_contract_nopk CASCADE;" >/dev/null 2>&1 || true
  rm -f "$ERRF"
}
trap cleanup EXIT

echo "==> capture contract (${URL##*@})"

if [ "${ETER_CONTRACT_LOAD:-0}" = 1 ]; then
  "$PSQL_BIN" "$URL" -X -q -v ON_ERROR_STOP=1 -f ext/eter/eter.sql >/dev/null \
    || { echo "  FAIL could not load ext/eter/eter.sql" >&2; exit 1; }
fi

run "DROP TABLE IF EXISTS eter_contract_t, eter_contract_nopk CASCADE;
     DELETE FROM eter.tracked WHERE table_name LIKE '%eter_contract_%';
     CREATE TABLE eter_contract_t (id bigint PRIMARY KEY, v text);
     CREATE TABLE eter_contract_nopk (v text);" "create scratch tables (is eter loaded?)"

# --- 1. defaults -------------------------------------------------------------
# 'auto' is the product default and means sidecar capture. The named modes are
# test-only overrides (see the eter.sql header), so a harness that wants one
# must ask for it explicitly.
eq "$UNSET_MODE SELECT eter._capture_mode()" "auto" \
   "an unset eter.capture_mode resolves to 'auto'"
eq "SELECT eter._sidecar_present()" "f" \
   "no sidecar detected on a cluster with no active logical slot"

# --- 2. the refusal ----------------------------------------------------------
# This is the contract #188 introduced and the one that broke compat.sh. It has
# to stay a hard, typed failure: a silent no-capture track on managed Postgres
# is the failure mode the refusal exists to prevent.
raises "$UNSET_MODE SELECT eter.track('eter_contract_t')" \
  "no capture sidecar detected" \
  "track refuses in 'auto' with no sidecar attached"

eq "SELECT count(*) FROM eter.tracked WHERE table_name LIKE '%eter_contract_t'" "0" \
   "the refusal leaves no half-tracked row behind"

# The CLI's exit-code 7 path keys off the SQLSTATE, not the message text.
eq "$UNSET_MODE
    DO \$\$ BEGIN
      PERFORM eter.track('eter_contract_t');
      RAISE EXCEPTION 'contract violation: track() succeeded with no sidecar';
    EXCEPTION WHEN object_not_in_prerequisite_state THEN
      RAISE NOTICE 'refused as expected';
    END \$\$;
    SELECT 'caught'" "caught" \
   "the refusal raises SQLSTATE 55000 (object_not_in_prerequisite_state)"

# --- 3. the harness overrides ------------------------------------------------
# Both escape hatches the local harnesses rely on. If either stops working, the
# preambles in test/ stop working with it.
run "SET eter.capture_mode='trigger'; SELECT eter.track('eter_contract_t');" \
    "track under capture_mode='trigger'"
eq "SELECT count(*) FROM pg_trigger
     WHERE tgrelid='eter_contract_t'::regclass AND tgname='eter_capture'" "1" \
   "capture_mode='trigger' installs the in-DB trigger oracle"

run "SELECT eter.untrack('eter_contract_t');" "untrack"
run "SET eter.capture_mode='sidecar'; SELECT eter.track('eter_contract_t');" \
    "track under capture_mode='sidecar' (bypasses the presence check)"

eq "SELECT relreplident FROM pg_class WHERE oid='eter_contract_t'::regclass" "f" \
   "capture_mode='sidecar' sets REPLICA IDENTITY FULL"

eq "SELECT count(*) FROM pg_trigger
     WHERE tgrelid='eter_contract_t'::regclass AND tgname='eter_capture'" "0" \
   "the sidecar path installs no trigger (nothing on the commit path)"

eq "SELECT count(*) FROM pg_publication_rel pr JOIN pg_publication p ON p.oid=pr.prpubid
     WHERE p.pubname='eter_pub' AND pr.prrelid='eter_contract_t'::regclass" "1" \
   "the sidecar path adds the table to eter_pub"

# --- 4. the other refusal ----------------------------------------------------
# Surgical undo needs row identity, so a PK-less table is refused regardless of
# capture mode. Harnesses seed tables expecting this to hold.
raises "SET eter.capture_mode='trigger'; SELECT eter.track('eter_contract_nopk')" \
  "has no primary key" \
  "track refuses a table with no primary key"

echo
if [ "$status" -ne 0 ]; then
  echo "capture-contract: FAILED. The in-engine capture contract changed." >&2
  echo "Harness preambles in test/ depend on it; check them before merging." >&2
else
  echo "capture-contract: clean."
fi
exit "$status"
