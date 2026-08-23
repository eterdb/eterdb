#!/usr/bin/env bash
# EterDB Automated Test Coverage Runner
# Runs both Go unit tests with coverage and the C extension integration tests with coverage.

set -euo pipefail
cd "$(dirname "$0")/.."

# The patched PG18 build these integration tests run against. The PG16 build
# dirs (.pgbuild / .pgdata-observe) this script used to hardcode are gone:
# EterDB is PG18-only, and the REL_16_14 patch was deleted in 2026-07-20.
PGBUILD="${PGBUILD:-$PWD/.pgbuild18}"
PGDATADIR="${PGDATADIR:-$PWD/.pgdata-observe18}"

# 1. Setup coverage directory
mkdir -p coverage
rm -f coverage/*

echo "================================================================="
echo " EterDB Test Coverage Suite"
echo "================================================================="
echo

# 2. Go CLI Unit Coverage
echo "==> Running Go CLI Unit Tests..."
(
  cd cli
  go test -coverprofile=../coverage/cli-unit.out ./... >/dev/null 2>&1 || true
)
if [ -f coverage/cli-unit.out ]; then
  CLI_COV=$(cd cli && go tool cover -func=../coverage/cli-unit.out | tail -n 1 | awk '{print $NF}')
  echo "  ✓ Go CLI Unit Coverage: $CLI_COV"
else
  echo "  ✗ Go CLI Unit Coverage: failed to generate report"
  CLI_COV="N/A"
fi

# 3. Go Sidecars Unit Coverage
echo "==> Running Go Sidecars Unit Tests..."
(
  cd sidecars
  go test -coverprofile=../coverage/sidecars-unit.out ./... >/dev/null 2>&1 || true
)
if [ -f coverage/sidecars-unit.out ]; then
  SIDECARS_COV=$(cd sidecars && go tool cover -func=../coverage/sidecars-unit.out | tail -n 1 | awk '{print $NF}')
  echo "  ✓ Go Sidecars Unit Coverage: $SIDECARS_COV"
else
  echo "  ✗ Go Sidecars Unit Coverage: failed to generate report"
  SIDECARS_COV="N/A"
fi


# 4. C Extension Integration Coverage
echo "==> Instrumenting C Extension for Coverage..."

# Make sure the server is stopped first to avoid lock/state collision
"$PGBUILD"/bin/pg_ctl -D "$PGDATADIR" stop -m immediate >/dev/null 2>&1 || true

# Recompile C extension with coverage flags
make -C ext/eter_ssi PG_CONFIG="$PGBUILD"/bin/pg_config PG_SYSROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk COPT="--coverage" LDFLAGS="--coverage -isysroot /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk" clean install >/dev/null

# Remove any old coverage data files
rm -f ext/eter_ssi/*.gcda

# Start server
"$PGBUILD"/bin/pg_ctl -D "$PGDATADIR" -o "-p 5433" -l "$PGDATADIR/server.log" start >/dev/null

echo "==> Running C Extension integration tests (observe.sh & ssi.sh)..."
# Run integration tests
COPT="--coverage" LDFLAGS="--coverage -isysroot /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk" bash test/observe.sh >/dev/null || echo "  ⚠️ observe.sh returned errors"
COPT="--coverage" LDFLAGS="--coverage -isysroot /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk" bash test/ssi.sh >/dev/null || echo "  ⚠️ ssi.sh returned errors"

# Stop server to flush .gcda
echo "==> Stopping Postgres to flush coverage metrics..."
"$PGBUILD"/bin/pg_ctl -D "$PGDATADIR" stop -m fast >/dev/null

# Generate gcov report
if [ -f ext/eter_ssi/eter_ssi.gcda ]; then
  echo "==> Generating C Extension Coverage Report..."
  (
    cd ext/eter_ssi
    gcov eter_ssi.c > gcov.log 2>&1
  )
  if [ -f ext/eter_ssi/eter_ssi.c.gcov ]; then
    C_COV_LINE=$(grep "Lines executed:" ext/eter_ssi/gcov.log | head -n 1)
    C_COV=$(echo "$C_COV_LINE" | awk '{print $2}')
    echo "  ✓ C Extension (eter_ssi.c) Coverage: $C_COV"
    
    # Copy reports to coverage directory
    cp ext/eter_ssi/eter_ssi.c.gcov coverage/eter_ssi.c.gcov
  else
    echo "  ✗ C Extension Coverage: failed to parse gcov report"
    C_COV="N/A"
  fi
else
  echo "  ✗ C Extension Coverage: no gcda file found (tests did not execute or server didn't stop cleanly)"
  C_COV="N/A"
fi

# Clean up C extension to avoid shipping coverage-instrumented binary in dev/prod
make -C ext/eter_ssi PG_CONFIG="$PGBUILD"/bin/pg_config PG_SYSROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk clean install >/dev/null

echo
echo "================================================================="
echo " Coverage Summary"
echo "================================================================="
echo "  Go CLI Unit Coverage:       $CLI_COV"
echo "  Go Sidecars Unit Coverage:  $SIDECARS_COV"
echo "  C Extension (eter_ssi.c):   $C_COV"
echo "================================================================="
echo "Full reports saved to 'coverage/' directory."
