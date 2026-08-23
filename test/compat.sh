#!/usr/bin/env bash
# EterDB Phase 3, COMPATIBILITY EVIDENCE harness.
#
# The core engineering constraint (PLAN §"Core engineering constraints" #1)
# is "near-stock Postgres + a small, upstream-tracked patch set", every
# extension/ORM/dialect must still work. This harness is the evidence: a curated
# matrix of popular Postgres extensions (incl. pgvector) is
#   (1) BUILT against the EterDB-patched engine (PGXS, the same toolchain a
#       user would use),
#   (2) LOADED (CREATE EXTENSION) on the patched cluster,
#   (3) SMOKE-tested (its core operation runs), and
#   (4) proven to COEXIST with eter tracking + observe-mode SSI capture +
#       dependency-aware undo, including read-dependency capture through
#       non-btree access methods (GiST / GIN / HNSW) and custom types, which is
#       exactly the surface the observe-mode SSI patch is most likely to perturb
#       (it hooks predicate-lock acquisition).
#
# The matrix is regenerated into test/compatibility-matrix.md (the published
# artifact; analysed in test/compatibility_report.md alongside the Postgres
# regression-suite pass-rates).
#
# Deliberately SINGLE-DB: this gates an in-engine mechanism (does the patched
# engine still host the ecosystem), which is topology-independent. Runs on the
# patched --enable-cassert cluster; brings it up if needed and leaves a cluster
# it started stopped on exit. No Docker, no ZFS.
#
# Targets PG18 (.pgbuild18 / .pgsrc18 / .pgdata-observe18 / :5433).
set -euo pipefail
cd "$(dirname "$0")/.."

PGB="${PGBUILD:-$PWD/.pgbuild18}/bin"
PGSRC="${PGSRC:-$PWD/.pgsrc18}"
PORT="${PGPORT:-5433}"
DATADIR="${PGDATADIR:-$PWD/.pgdata-observe18}"
PGVECTOR_DIR="${PGVECTOR_DIR:-$PWD/.pgvector}"
PGVECTOR_REF="${PGVECTOR_REF:-v0.8.2}"   # 0.8.1+ required for PG18 (vacuum_delay_point signature)
DB="postgres://eter@localhost:$PORT/compat"
ADMIN="postgres://eter@localhost:$PORT/postgres"
REPORT="${COMPAT_REPORT:-test/compatibility-matrix.md}"
STARTED_CLUSTER=0
FAILED=0

[ -x "$PGB/postgres" ]      || { echo "patched Postgres not found at $PGB, see pg/README.md"; exit 1; }
[ -d "$PGSRC/contrib" ]     || { echo "patched source contrib tree not found at $PGSRC/contrib, see pg/README.md"; exit 1; }
[ -f "$DATADIR/PG_VERSION" ] || { echo "patched datadir $DATADIR not initialised, see pg/README.md"; exit 1; }

PSQL(){  "$PGB/psql" "$DB" -tAc "$1"; }
PSQLF(){ "$PGB/psql" "$DB" -q -v ON_ERROR_STOP=1 "$@"; }
pass(){ echo "  ✓ $1"; }
warn(){ echo "  ! $1"; }
fail(){ echo "  ✗ $1"; FAILED=$((FAILED+1)); }

cleanup(){
  if [ "$STARTED_CLUSTER" = "1" ]; then
    "$PGB/pg_ctl" -D "$DATADIR" stop -m fast >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# ---- matrix result accumulation -------------------------------------------
# add_row: ext | version | build | load | smoke | regress | eter+observe | note
declare -a ROWS=()
add_row(){ ROWS+=("| $1 | $2 | $3 | $4 | $5 | $6 | $7 | $8 |"); }

PGVER="$("$PGB/pg_config" --version)"
echo "==> compatibility matrix on the PATCHED engine: $PGVER"

# ---- 1. bring up the patched cluster --------------------------------------
echo "==> patched cluster up on :$PORT"
if ! "$PGB/pg_isready" -p "$PORT" >/dev/null 2>&1; then
  "$PGB/pg_ctl" -D "$DATADIR" -o "-p $PORT" -l "$DATADIR/server.log" start >/dev/null
  STARTED_CLUSTER=1
  for i in $(seq 1 30); do "$PGB/pg_isready" -p "$PORT" >/dev/null 2>&1 && break; sleep 0.3; done
fi
"$PGB/pg_isready" -p "$PORT" >/dev/null 2>&1 || { echo "patched cluster did not come up on :$PORT"; exit 1; }
"$PGB/createdb" -p "$PORT" -U eter postgres >/dev/null 2>&1 || true
# pg_regress (extension installcheck) connects via these; it creates its own
# contrib_regression DB, which does NOT inherit the compat DB's observe/preload
# GUCs, so each suite runs against the patched BINARY on a clean database.
export PGHOST=localhost PGPORT="$PORT" PGUSER=eter
unset PGDATABASE 2>/dev/null || true
pass "cluster reachable ($([ "$STARTED_CLUSTER" = 1 ] && echo 'started by harness' || echo 'already running'))"

# fresh compat database
"$PGB/psql" "$ADMIN" -q -c "DROP DATABASE IF EXISTS compat WITH (FORCE);" -c "CREATE DATABASE compat;" >/dev/null
pass "fresh 'compat' database"

# ---- 2. build eter_ssi + the engine into compat ------------------------
echo "==> eter engine + eter_ssi + observe mode"
make -C ext/eter_ssi PG_CONFIG="$PGB/pg_config" clean >/dev/null 2>&1 || true
make -C ext/eter_ssi PG_CONFIG="$PGB/pg_config" install >/dev/null
PSQLF -f ext/eter/eter.sql >/dev/null
PSQLF -c "DROP EXTENSION IF EXISTS eter_ssi; CREATE EXTENSION eter_ssi;" \
      -c "ALTER DATABASE compat SET session_preload_libraries='eter_ssi';" \
      -c "ALTER DATABASE compat SET eter_observe_mode=on;" >/dev/null
# new sessions from here pick up the preload + observe GUC
[ "$(PSQL 'SHOW eter_observe_mode')" = "on" ] || { echo "observe mode not on"; exit 1; }
[ "$(PSQL 'SHOW default_transaction_isolation')" = "read committed" ] || { echo "not RC"; exit 1; }
SSI_VER="$(PSQL "SELECT extversion FROM pg_extension WHERE extname='eter_ssi'")"
pass "eter engine + eter_ssi $SSI_VER loaded; observe ON @ READ COMMITTED"
add_row "eter_ssi" "$SSI_VER" "✓" "✓" "✓ (engine)" "ssi/observe/false-clean" "✓ (engine)" "the SSI read-dep capture extension itself"

# ---- 2b. preamble preflight (issue #197) -----------------------------------
# Every coexist block below tracks a table in-engine. That contract changed
# under this harness once already (#188 made eter.track refuse with no capture
# sidecar attached, and compat.sh was the one script not updated), and the
# breakage read as 13 rows of `capture=✗` next to `build=✓ load=✓ smoke=✓`, so
# it looked like a partial pass for three days rather than a dead harness.
# Check the contract itself FIRST, and abort loudly: no point building 13
# extensions from source when the preamble cannot work.
echo "==> preamble preflight: the in-engine capture contract"
if ! PSQL_BIN="$PGB/psql" ETER_CONTRACT_URL="$DB" bash test/capture-contract.sh; then
  echo ""                                                                       >&2
  echo "!! ABORTING: the in-engine capture contract this harness depends on"     >&2
  echo "!! has changed. Every coexist check below would fail for that reason"    >&2
  echo "!! alone, which is NOT an extension compatibility finding."              >&2
  echo "!! Fix the preamble (see test/capture-contract.sh), then re-run."        >&2
  exit 2
fi

# ---- helpers ---------------------------------------------------------------
# regress_ext NAME SUBDIR, run the extension's OWN regression suite (pg_regress
# via PGXS installcheck) against the patched BINARY; sets REG to "N/N", "k/N", or
# ", " (no suite). This is the strong per-extension evidence: the extension's full
# test corpus passes on the patched engine, not just a single smoke query.
regress_ext(){
  local name="$1" subdir="$2" out f t n
  REG=", "
  out="$(make -C "$subdir" USE_PGXS=1 PG_CONFIG="$PGB/pg_config" installcheck 2>&1 || true)"
  echo "$out" > "/tmp/compat-regress-$name.log"
  if n="$(echo "$out" | grep -oE '# All [0-9]+ tests passed' | grep -oE '[0-9]+')" && [ -n "$n" ]; then
    REG="$n/$n"
  elif echo "$out" | grep -qE '# [0-9]+ of [0-9]+ tests failed'; then
    f="$(echo "$out" | grep -oE '# [0-9]+ of [0-9]+ tests failed' | grep -oE '[0-9]+' | sed -n 1p)"
    t="$(echo "$out" | grep -oE '# [0-9]+ of [0-9]+ tests failed' | grep -oE '[0-9]+' | sed -n 2p)"
    REG="$((t-f))/$t"
  fi
}

# build_ext NAME SUBDIR, PGXS build+install of a contrib subdir; sets BUILD_OK
build_ext(){
  local name="$1" subdir="$2"
  if make -C "$subdir" USE_PGXS=1 PG_CONFIG="$PGB/pg_config" install >/dev/null 2>"/tmp/compat-build-$name.err"; then
    BUILD_OK=1
  else
    BUILD_OK=0
  fi
}

# load_ext NAME, CREATE EXTENSION; sets LOAD_OK and EXT_VER
load_ext(){
  local name="$1"
  if "$PGB/psql" "$DB" -q -v ON_ERROR_STOP=1 -c "DROP EXTENSION IF EXISTS \"$name\" CASCADE; CREATE EXTENSION \"$name\";" >/dev/null 2>"/tmp/compat-load-$name.err"; then
    LOAD_OK=1
    EXT_VER="$(PSQL "SELECT extversion FROM pg_extension WHERE extname='$name'")"
  else
    LOAD_OK=0; EXT_VER="-"
  fi
}

# smoke NAME SQL EXPECT, run SQL (-tA), compare trimmed output to EXPECT
#   EXPECT="" means "just runs without error"
smoke(){
  local name="$1" sql="$2" expect="${3:-}" out
  if ! out="$("$PGB/psql" "$DB" -tAc "$sql" 2>"/tmp/compat-smoke-$name.err")"; then
    SMOKE_OK=0; return
  fi
  out="$(echo "$out" | tr -d '[:space:]')"
  if [ -z "$expect" ] || [ "$out" = "$expect" ]; then SMOKE_OK=1; else SMOKE_OK=0; echo "    smoke($name): got '$out' want '$expect'" >&2; fi
}

# coexist: track a table using the extension's TYPE + AM, prove two claims:
#   COE_CAP, read-dependency capture works THROUGH the extension's index AM
#     (the observe-mode SSI-patch claim): a writer W2 sets row id=2 to a sentinel;
#     a reader (enable_seqscan=off) finds id=2 via the extension index and writes a
#     sink row → preview_undo(W2) must be `dependent` AND a write nobody read (W1)
#     must be `clean`. This is the patch/ecosystem-interaction claim and is REQUIRED.
#   COE_UNDO, the custom type round-trips through the trigger-mode row image:
#     undo W1 must restore the exact prior typed value. Best-effort: the trigger
#     captures `to_jsonb(row)`, and a column type with a STRUCTURED jsonb cast
#     (e.g. hstore → {"k":"1"}, not valid hstore input syntax) cannot be rebuilt by
#     `jsonb_populate_record`. Recorded per type; a failure here is a documented
#     trigger-path round-trip limit (see test/compatibility_report.md), not a patch
#     incompatibility, so it does NOT fail the suite.
# args: NAME COLTYPE INDEXDEF SEEDEXPR OLDVAL NEWVAL SENTINEL READER_PRED
COE_CAP=0; COE_UNDO=0
coexist(){
  local name="$1" coltype="$2" indexdef="$3" seedexpr="$4" oldval="$5" newval="$6" sentinel="$7" reader_pred="$8"
  COE_CAP=0; COE_UNDO=0
  local setup_failed=0
  "$PGB/psql" "$DB" -q -v ON_ERROR_STOP=1 >/dev/null 2>"/tmp/compat-coe-$name.err" <<SQL || setup_failed=1
-- Tests observe-mode READ capture through the extension's index AM, not the
-- write-capture substrate, and COE_UNDO deliberately exercises the trigger-mode
-- row image. capture_mode='trigger' is the test-only override (product default
-- 'auto' = sidecar, which refuses without one).
SET eter.capture_mode='trigger';
TRUNCATE eter.history, eter.dependencies, eter.ssi_reads, eter.markers,
         eter.tracked, eter.undo_txn RESTART IDENTITY CASCADE;
DROP TABLE IF EXISTS compat_t, compat_sink CASCADE;
CREATE TABLE compat_t (id bigint PRIMARY KEY, val $coltype);
CREATE TABLE compat_sink (id bigserial PRIMARY KEY, note text);
INSERT INTO compat_t SELECT g, $seedexpr FROM generate_series(3,2000) g;
INSERT INTO compat_t VALUES (1, $oldval), (2, $oldval);
CREATE INDEX compat_t_idx ON compat_t $indexdef;
ANALYZE compat_t;
SELECT eter.track('compat_t');
SELECT eter.track('compat_sink');
SQL
  # Distinguish a HARNESS failure from an extension finding. The setup block is
  # mostly extension-specific (the custom type, the AM index def), so a failure
  # there is normally a real per-extension result and returns 0 above. But a
  # failure raised by eter.track is the shared in-engine contract breaking, which
  # is not about this extension at all and would repeat for all 13. Say so and
  # stop, rather than emitting a row that reads like a partial pass (issue #197).
  if grep -q 'eter\.track:' "/tmp/compat-coe-$name.err" 2>/dev/null; then
    echo ""                                                                     >&2
    echo "!! ABORTING at $name: eter.track failed, so this harness's preamble"   >&2
    echo "!! is broken, not the extension. The engine contract changed:"         >&2
    sed 's/^/!!   /' "/tmp/compat-coe-$name.err"                                 >&2
    exit 2
  fi
  if [ "$setup_failed" = 1 ]; then
    return 0   # extension-specific setup failure (custom type / AM index), a real result
  fi
  : > "$DATADIR/eter_ssi.wal" 2>/dev/null || true

  # W1: clean write to id=1 (nobody reads it)
  local W1 W2
  W1="$(PSQL "WITH u AS (UPDATE compat_t SET val=$newval WHERE id=1 RETURNING 1) SELECT txid_current() FROM u")" || return 0
  # W2: write the sentinel to id=2 (the reader will find it via the index)
  W2="$(PSQL "WITH u AS (UPDATE compat_t SET val=$sentinel WHERE id=2 RETURNING 1) SELECT txid_current() FROM u")" || return 0

  # Reader: force the extension index, read id=2 (W2's row), then write a sink row.
  "$PGB/psql" "$DB" -q -v ON_ERROR_STOP=1 >/dev/null 2>>"/tmp/compat-coe-$name.err" <<SQL || return 0
SET enable_seqscan=off;
BEGIN;  -- READ COMMITTED (observe)
SELECT id FROM compat_t WHERE $reader_pred;
INSERT INTO compat_sink(note) VALUES ('read-derived');
COMMIT;
SQL

  PSQL "SELECT eter.refresh_dependencies()" >/dev/null || return 0
  local c2 c1
  c2="$(PSQL "SELECT eter.preview_undo($W2)->>'classification'" 2>/dev/null || true)"
  c1="$(PSQL "SELECT eter.preview_undo($W1)->>'classification'" 2>/dev/null || true)"
  [ "$c2" = "dependent" ] || { echo "    coexist($name): W2 expected dependent, got '$c2'" >&2; return 0; }
  [ "$c1" = "clean" ]     || { echo "    coexist($name): W1 expected clean, got '$c1'" >&2; return 0; }
  COE_CAP=1   # the required claim holds

  # best-effort: the trigger-mode row image round-trips this column type
  if PSQL "SELECT eter.undo($W1,'clean_only')" >/dev/null 2>"/tmp/compat-undo-$name.err"; then
    [ "$(PSQL "SELECT (val = $oldval) FROM compat_t WHERE id=1")" = "t" ] && COE_UNDO=1
  fi
}

echo ""
echo "==> extension matrix"

# ===========================================================================
# Tier B, type + non-btree AM extensions: full coexist (rw-through-AM + undo)
# ===========================================================================

run_indexed(){
  # NAME SUBDIR EXTNAME SMOKE_SQL SMOKE_EXPECT COLTYPE INDEXDEF SEEDEXPR OLDVAL NEWVAL SENTINEL READER_PRED NOTE
  local name="$1" subdir="$2" extname="$3" ssql="$4" sexp="$5" coltype="$6" idef="$7" seed="$8" oldv="$9" newv="${10}" sent="${11}" pred="${12}" note="${13}"
  build_ext "$name" "$subdir"
  if [ "$BUILD_OK" = 1 ]; then load_ext "$extname"; else LOAD_OK=0; EXT_VER="-"; fi
  if [ "$LOAD_OK" = 1 ]; then smoke "$name" "$ssql" "$sexp"; else SMOKE_OK=0; fi
  if [ "$BUILD_OK" = 1 ]; then regress_ext "$name" "$subdir"; else REG=", "; fi
  if [ "${SMOKE_OK:-0}" = 1 ]; then coexist "$name" "$coltype" "$idef" "$seed" "$oldv" "$newv" "$sent" "$pred"; else COE_CAP=0; COE_UNDO=0; fi
  local b=$([ "$BUILD_OK" = 1 ] && echo "✓" || echo "✗")
  local l=$([ "$LOAD_OK"  = 1 ] && echo "✓" || echo "✗")
  local s=$([ "${SMOKE_OK:-0}" = 1 ] && echo "✓" || echo "✗")
  # eter+observe cell: capture-through-AM is the required claim; undo round-trip is annotated
  local c rownote="$note"
  if [ "$COE_CAP" = 1 ] && [ "$COE_UNDO" = 1 ]; then
    c="✓"
  elif [ "$COE_CAP" = 1 ]; then
    c="✓ capture / ⚠ undo"
    rownote="$note, observe rw-capture through the AM works; trigger-mode undo can't rebuild this type from its jsonb image (see report)"
  else
    c="✗"
  fi
  add_row "$name" "$EXT_VER" "$b" "$l" "$s" "$REG" "$c" "$rownote"
  if [ "$BUILD_OK$LOAD_OK${SMOKE_OK:-0}$COE_CAP" = "1111" ]; then
    if [ "$COE_UNDO" = 1 ]; then pass "$name, build/load/smoke/regress($REG)/coexist (capture + undo)";
    else warn "$name, build/load/smoke/regress($REG) + observe rw-capture ✓; trigger-mode undo round-trip ⚠ (documented limit)"; fi
  else
    fail "$name (build=$b load=$l smoke=$s regress=$REG capture=$([ "$COE_CAP" = 1 ] && echo ✓ || echo ✗))"
  fi
}

run_indexed pg_trgm   "$PGSRC/contrib/pg_trgm"   pg_trgm \
  "SELECT round(similarity('eter','eterdb')::numeric,3)" "" \
  "text" "USING gin (val gin_trgm_ops)" "'row-'||g" "'baseline-one'" "'clean-new-1'" "'zzqqxxsentinel'" \
  "val LIKE '%zzqqxx%'" "GIN trigram index (LIKE); SIREAD on GIN pages"

run_indexed btree_gist "$PGSRC/contrib/btree_gist" btree_gist \
  "SELECT 1" "1" \
  "int" "USING gist (val)" "g+100000" "100001" "555" "987654" \
  "val = 987654" "GiST over a scalar int (equality via GiST)"

run_indexed hstore    "$PGSRC/contrib/hstore"    hstore \
  "SELECT (hstore('a','1')->'a')" "1" \
  "hstore" "USING gin (val)" "hstore('k', g::text)" "hstore('k','1')" "hstore('k','clean1')" "hstore('k','sentinel2')" \
  "val @> hstore('k','sentinel2')" "key-value type + GIN containment"

run_indexed ltree     "$PGSRC/contrib/ltree"     ltree \
  "SELECT nlevel('a.b.c'::ltree)" "3" \
  "ltree" "USING gist (val)" "text2ltree('a.b.n'||g)" "'a.b.base'::ltree" "'a.b.clean1'::ltree" "'a.b.sentinel2'::ltree" \
  "val = 'a.b.sentinel2'::ltree" "tree-path type + GiST"

run_indexed cube      "$PGSRC/contrib/cube"      cube \
  "SELECT cube_dim(cube(ARRAY[1.0,2.0]))" "2" \
  "cube" "USING gist (val)" "cube(ARRAY[g::float8])" "cube(ARRAY[1.0])" "cube(ARRAY[5.5])" "cube(ARRAY[987654.0])" \
  "val @> cube(ARRAY[987654.0])" "multidim cube type + GiST"

run_indexed intarray  "$PGSRC/contrib/intarray"  intarray \
  "SELECT (ARRAY[3,1,2]::int[] | 4)::text" "{1,2,3,4}" \
  "int[]" "USING gin (val gin__int_ops)" "ARRAY[g]" "ARRAY[1]" "ARRAY[5]" "ARRAY[987654]" \
  "val @> ARRAY[987654]" "int-array GIN opclass (gin__int_ops)"

run_indexed citext    "$PGSRC/contrib/citext"    citext \
  "SELECT 'ABC'::citext = 'abc'::citext" "t" \
  "citext" "USING btree (val)" "('row'||g)::citext" "'base'::citext" "'clean1'::citext" "'SeNtInEl2'::citext" \
  "val = 'sentinel2'::citext" "case-insensitive text (read matches via citext semantics)"

# ===========================================================================
# pgvector, the headline: vector type + ANN index, read captured through HNSW
# ===========================================================================
if [ ! -d "$PGVECTOR_DIR/.git" ]; then
  echo "==> cloning pgvector $PGVECTOR_REF"
  git clone --depth 1 --branch "$PGVECTOR_REF" https://github.com/pgvector/pgvector.git "$PGVECTOR_DIR" >/dev/null 2>&1 \
    || warn "pgvector clone failed (offline?), skipping"
fi
if [ -d "$PGVECTOR_DIR/.git" ]; then
  make -C "$PGVECTOR_DIR" clean >/dev/null 2>&1 || true
  run_indexed vector "$PGVECTOR_DIR" vector \
    "SELECT '[1,2,3]'::vector <-> '[1,2,4]'::vector" "1" \
    "vector(3)" "USING hnsw (val vector_l2_ops)" "ARRAY[g%97, (g*7)%89, (g*13)%83]::vector" \
    "'[1,1,1]'::vector" "'[2,2,2]'::vector" "'[900,900,900]'::vector" \
    "true ORDER BY val <-> '[900,900,900]'::vector LIMIT 1" "pgvector: vector type + HNSW ANN; read captured through HNSW"
else
  add_row "vector" "-" ", " ", " ", " ", " ", " "pgvector source unavailable (offline), skipped"
fi

# ===========================================================================
# Tier A, function/type extensions: build + load + smoke (no tracked-type AM)
# ===========================================================================
run_func(){
  local name="$1" subdir="$2" extname="$3" ssql="$4" sexp="$5" note="$6" required="${7:-1}"
  build_ext "$name" "$subdir"
  if [ "$BUILD_OK" = 1 ]; then load_ext "$extname"; else LOAD_OK=0; EXT_VER="-"; fi
  if [ "$LOAD_OK" = 1 ]; then smoke "$name" "$ssql" "$sexp"; else SMOKE_OK=0; fi
  if [ "$BUILD_OK" = 1 ]; then regress_ext "$name" "$subdir"; else REG=", "; fi
  local b=$([ "$BUILD_OK" = 1 ] && echo "✓" || echo "✗")
  local l=$([ "$LOAD_OK"  = 1 ] && echo "✓" || echo "✗")
  local s=$([ "${SMOKE_OK:-0}" = 1 ] && echo "✓" || echo "✗")
  add_row "$name" "$EXT_VER" "$b" "$l" "$s" "$REG" ", (function/type)" "$note"
  if [ "$BUILD_OK$LOAD_OK${SMOKE_OK:-0}" = "111" ]; then
    pass "$name, build/load/smoke/regress($REG)"
  elif [ "$required" = 0 ]; then
    warn "$name, optional (build=$b load=$l smoke=$s); external dep likely absent, not counted"
    # rewrite last row to flag optional
    ROWS[${#ROWS[@]}-1]="| $name | $EXT_VER | $b | $l | $s | $REG |, (function/type) | $note (optional, external dep) |"
  else
    fail "$name (build=$b load=$l smoke=$s regress=$REG)"
  fi
}

run_func fuzzystrmatch "$PGSRC/contrib/fuzzystrmatch" fuzzystrmatch \
  "SELECT levenshtein('kitten','sitting')" "3" "fuzzy string matching"

run_func unaccent "$PGSRC/contrib/unaccent" unaccent \
  "SELECT unaccent('Hôtel')" "Hotel" "accent-removing text search dictionary"

run_func tablefunc "$PGSRC/contrib/tablefunc" tablefunc \
  "SELECT count(*) FROM normal_rand(7, 0, 1)" "7" "crosstab / normal_rand set-returning functions"

run_func isn "$PGSRC/contrib/isn" isn \
  "SELECT issn('1436-4522')" "1436-4522" "international standard numbers (ISBN/ISSN types)"

# pgcrypto needs OpenSSL; if the patched build was configured --without-openssl
# its build/load will fail. Mark optional, its absence is a build-config choice,
# not a EterDB incompatibility.
run_func pgcrypto "$PGSRC/contrib/pgcrypto" pgcrypto \
  "SELECT encode(digest('eter','sha256'),'hex')" "" "cryptographic functions (needs OpenSSL)" 0

# ---- emit the matrix -------------------------------------------------------
{
  echo "# EterDB, extension compatibility matrix"
  echo
  echo "Generated by \`test/compat.sh\` on the **EterDB-patched** Postgres engine"
  echo "(observe-mode core patch applied, \`eter_ssi\` preloaded, observe mode ON at"
  echo "READ COMMITTED). Each extension is built from source against the patched engine"
  echo "(PGXS), loaded, smoke-tested, and, for type/index extensions, proven to coexist"
  echo "with eter tracking + observe-mode SSI read-dependency capture + dependency-aware"
  echo "undo. See \`test/compatibility_report.md\` for analysis + the regression-suite"
  echo "pass-rates."
  echo
  echo "- **Engine:** \`$PGVER\` (patched)"
  echo "- **eter_ssi:** \`$SSI_VER\`"
  echo "- **Generated:** $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo
  echo "**Columns**, *build*: compiles against the patched engine; *load*: \`CREATE EXTENSION\`"
  echo "succeeds; *smoke*: a core operation returns the expected result; *regress*: the"
  echo "extension's OWN \`pg_regress\` suite (PGXS \`installcheck\`) passes on the patched"
  echo "binary (n/n tests); *eter+observe*: a tracked table using the extension's"
  echo "type/index round-trips a clean undo AND a reader that finds a row through the"
  echo "extension's access method is surfaced as a read-\`dependent\` (rw edge captured"
  echo "through the AM)."
  echo
  echo "| Extension | Version | Build | Load | Smoke | Regress | eter + observe | Notes |"
  echo "|-----------|---------|:-----:|:----:|:-----:|:-------:|:-----------------:|-------|"
  for r in "${ROWS[@]}"; do echo "$r"; done
} > "$REPORT"

echo ""
echo "==> wrote $REPORT"
if [ "$FAILED" = 0 ]; then
  echo "ALL COMPATIBILITY CHECKS PASSED ✅  (patched engine hosts the extension matrix; eter+observe coexist)"
else
  echo "COMPATIBILITY FAILURES: $FAILED ✗"
  exit 1
fi
