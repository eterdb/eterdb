#!/usr/bin/env bash
# EterDB Phase 3, performance-overhead measurement.
#
# Measures the production cost of the three always-on EterDB mechanisms
# versus vanilla Postgres 16, on this machine, with real `pgbench` runs.
# Four configurations × two workloads × N trials (median reported):
#
#   1. Baseline               stock PG18, default config
#   2. Replica Identity Full  stock PG18 + REPLICA IDENTITY FULL on all tables
#   3. Logical Decoding       stock PG18 + RIF + wal_level=logical + live
#                             pg_recvlogical consumer (the capture-sidecar cost)
#   4. Observe Mode           patched PG18 (.pgbuild18) + eter_ssi preloaded +
#                             eter_observe_mode=on (SIREAD acquisition +
#                             commit-time read-dependency capture)
#
# Workloads:
#   tpcb, pgbench default (write-heavy TPC-B'): isolates RIF + logical-decode cost
#   select, pgbench -S (read-only): isolates observe-mode SIREAD read overhead
#
# Output: test/results.csv (one row per trial) + test/perf-summary.md (medians).
# Config 4 is skipped (not failed) if the patched engine isn't built.
#
# Tunables (env): DURATION TRIALS SCALE CLIENTS THREADS WORKLOADS SAMPLING PORT
set -euo pipefail
cd "$(dirname "$0")/.."

STOCK_BIN="${STOCK_BIN:-/opt/homebrew/opt/postgresql@18/bin}"
PATCHED_BIN="${PATCHED_BIN:-$PWD/.pgbuild18/bin}"
DATA_DIR="$PWD/test/perf-data"
RESULTS="${RESULTS:-$PWD/test/results.csv}"
SUMMARY="${SUMMARY:-$PWD/test/perf-summary.md}"

PORT="${PORT:-5439}"
DB_NAME="eter_perf"
DURATION="${DURATION:-20}"
TRIALS="${TRIALS:-3}"
SCALE="${SCALE:-10}"
CLIENTS="${CLIENTS:-8}"
THREADS="${THREADS:-4}"
SAMPLING="${SAMPLING:-0.05}"          # -l sampling rate for the p95 estimate
WORKLOADS="${WORKLOADS:-tpcb select}"
# Observe mode registers a SERIALIZABLEXACT per transaction, so its SIREAD
# predicate-lock pool must be sized like a real SERIALIZABLE deployment; the
# default (64) exhausts under sustained high-throughput capture ("out of shared
# memory"). Applied to every config (no effect on the non-SSI stock ones).
PRED_LOCKS="${PRED_LOCKS:-1024}"

echo "==> EterDB performance benchmark"
echo "    port=$PORT scale=$SCALE clients=$CLIENTS threads=$THREADS duration=${DURATION}s trials=$TRIALS"
echo "    workloads: $WORKLOADS    max_pred_locks_per_transaction=$PRED_LOCKS"
echo "    stock:   $STOCK_BIN"
echo "    patched: $PATCHED_BIN $( [ -x "$PATCHED_BIN/postgres" ] && echo '(present)' || echo '(MISSING, config 4 skipped)')"
echo ""

RECV_PID=""
cleanup() {
  [ -n "$RECV_PID" ] && kill "$RECV_PID" 2>/dev/null || true
  "$STOCK_BIN/pg_ctl"   -D "$DATA_DIR" -m immediate stop >/dev/null 2>&1 || true
  [ -x "$PATCHED_BIN/pg_ctl" ] && "$PATCHED_BIN/pg_ctl" -D "$DATA_DIR" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$DATA_DIR"
}
trap cleanup EXIT

# median of stdin numbers (one per line)
median() { sort -n | awk '{a[NR]=$1} END{ if(NR==0){print "NA"} else if(NR%2){print a[(NR+1)/2]} else {printf "%.3f",(a[NR/2]+a[NR/2+1])/2} }'; }

# parse + record one pgbench run; args: bin cfg_name workload trial outfile logprefix
record() {
  local bin=$1 cfg=$2 wl=$3 trial=$4 out=$5 logp=$6 tps avg p95
  # Integrity gate: a run with aborted/failed transactions is NOT a valid
  # overhead sample (e.g. observe mode exhausting the predicate-lock pool and
  # erroring "out of shared memory"). Fail loudly rather than record bogus tps.
  if grep -q "Run was aborted" "$out" || ! grep -qE 'number of failed transactions: 0 ' "$out"; then
    echo "  !! $cfg / $wl trial $trial had aborted/failed transactions, invalid sample:"
    grep -iE 'out of shared memory|run was aborted|number of failed transactions' "$out" | head -3 | sed 's/^/       /'
    exit 1
  fi
  tps=$(grep -E 'tps = [0-9.]+' "$out" | head -1 | sed -E 's/.*tps = ([0-9.]+).*/\1/')
  avg=$(grep -E 'latency average = [0-9.]+' "$out" | head -1 | sed -E 's/.*latency average = ([0-9.]+).*/\1/')
  # pgbench -l log: col 3 = per-txn latency (microseconds); 95th pct -> ms
  p95=$(cat "${logp}"* 2>/dev/null | sort -n -k3 | awk '{a[NR]=$3} END{ if(NR>0) printf "%.3f", a[int(NR*0.95)]/1000; else print "NA" }')
  rm -f "${logp}"*
  printf '%s,%s,%s,%s,%s,%s\n' "$cfg" "$wl" "$trial" "${tps:-NA}" "${avg:-NA}" "${p95:-NA}" >> "$RESULTS"
  printf '    trial %s: tps=%-10s avg=%-7s p95=%s ms\n' "$trial" "${tps:-NA}" "${avg:-NA}" "${p95:-NA}"
}

# Bring up a fresh cluster + pgbench dataset for one (config, workload) cell.
# Each workload gets its OWN cluster so measurements are independent and shared
# memory (SSI predicate locks, the SSI-WAL drain backlog) never carries across
# workloads, a write-heavy observe run otherwise pins enough shared memory to
# make a following read run fail with "out of shared memory".
setup_cluster() {
  local bin=$1 cfg_num=$2 logical=$3 observe=$4
  rm -rf "$DATA_DIR"; mkdir -p "$DATA_DIR"
  "$bin/initdb" -D "$DATA_DIR" -U eter --auth=trust >/dev/null
  cat >> "$DATA_DIR/postgresql.conf" <<EOF
port = $PORT
listen_addresses = 'localhost'
unix_socket_directories = '/tmp'
shared_buffers = 128MB
max_connections = $((CLIENTS + 50))
max_pred_locks_per_transaction = $PRED_LOCKS
EOF
  [ "$logical" = yes ] && cat >> "$DATA_DIR/postgresql.conf" <<EOF
wal_level = logical
max_replication_slots = 4
max_wal_senders = 4
EOF
  # observe: "no" | "on" | "off". on/off both preload eter_ssi so the only
  # difference between the two patched configs is the capture GUC, isolating
  # the observe mechanism's marginal cost from the assert/-O0 build penalty.
  [ "$observe" != no ] && cat >> "$DATA_DIR/postgresql.conf" <<EOF
shared_preload_libraries = 'eter_ssi'
eter_observe_mode = $observe
EOF
  "$bin/pg_ctl" -D "$DATA_DIR" -w -t 60 -l "$DATA_DIR/server.log" start >/dev/null
  "$bin/createdb" -p "$PORT" -U eter "$DB_NAME"
  if [ "$observe" != no ]; then
    "$bin/psql" -p "$PORT" -U eter -d "$DB_NAME" -q -f ext/eter/eter.sql
    "$bin/psql" -p "$PORT" -U eter -d "$DB_NAME" -q -c "CREATE EXTENSION eter_ssi;"
  fi
  "$bin/pgbench" -i -s "$SCALE" -p "$PORT" -U eter "$DB_NAME" >/dev/null 2>&1
  if [ "$cfg_num" -ge 2 ]; then
    "$bin/psql" -p "$PORT" -U eter -d "$DB_NAME" -q <<'SQL'
ALTER TABLE pgbench_accounts REPLICA IDENTITY FULL;
ALTER TABLE pgbench_branches REPLICA IDENTITY FULL;
ALTER TABLE pgbench_tellers  REPLICA IDENTITY FULL;
ALTER TABLE pgbench_history  REPLICA IDENTITY FULL;
SQL
  fi
}

run_config() {
  local cfg_num=$1 cfg_name=$2 bin=$3 logical=$4 observe=$5

  if [ ! -x "$bin/postgres" ]; then
    echo ">>> SKIP config $cfg_num ($cfg_name): no postgres at $bin"; echo ""; return 0
  fi
  echo "========================================================================"
  echo ">>> Config $cfg_num: $cfg_name"
  echo "========================================================================"

  local wl flag t
  for wl in $WORKLOADS; do
    case "$wl" in
      tpcb)   flag="" ;;            # default builtin TPC-B'
      select) flag="-S" ;;         # read-only
      *) echo "unknown workload $wl"; exit 1 ;;
    esac
    echo "  -- workload: $wl (fresh cluster)"
    setup_cluster "$bin" "$cfg_num" "$logical" "$observe"

    RECV_PID=""
    if [ "$logical" = yes ]; then
      "$bin/psql" -p "$PORT" -U eter -d "$DB_NAME" -q \
        -c "SELECT pg_create_logical_replication_slot('eter_slot','test_decoding');" >/dev/null
      "$bin/pg_recvlogical" -p "$PORT" -U eter -d "$DB_NAME" --slot=eter_slot --start -f /dev/null >/dev/null 2>&1 &
      RECV_PID=$!
    fi

    "$bin/pgbench" $flag -c "$CLIENTS" -j "$THREADS" -T 3 -p "$PORT" -U eter "$DB_NAME" >/dev/null 2>&1  # warmup
    for t in $(seq 1 "$TRIALS"); do
      local logp="$DATA_DIR/log_${wl}_${t}"
      "$bin/pgbench" $flag -c "$CLIENTS" -j "$THREADS" -T "$DURATION" \
        -l --sampling-rate="$SAMPLING" --log-prefix="$logp" \
        -p "$PORT" -U eter "$DB_NAME" > "$DATA_DIR/pgbench.out" 2>&1
      record "$bin" "$cfg_name" "$wl" "$t" "$DATA_DIR/pgbench.out" "$logp"
    done

    if [ -n "$RECV_PID" ]; then kill "$RECV_PID" 2>/dev/null || true; wait "$RECV_PID" 2>/dev/null || true; RECV_PID=""; fi

    if [ "$observe" = on ]; then
      # Informational: how much read-dependency capture this workload left behind.
      # Capture writes the per-db SSI-WAL, which the drain bgworker ingests into
      # eter.ssi_reads and truncates, so an empty WAL means "fully drained",
      # not "never fired", and a read-only workload may leave little persistent
      # trace at sample time. This is a soft signal; the hard integrity gate is
      # the zero-aborted-transactions check in record(). Warn, never fail.
      # NB: trailing `|| true`, stat fails when the WAL was fully drained/absent,
      # and under `set -e`+pipefail that would otherwise kill the script here.
      local wal_sz reads
      wal_sz=$( (stat -f%z "$DATA_DIR"/eter_ssi.*.wal 2>/dev/null | sort -n | tail -1) || true)
      reads=$("$bin/psql" -p "$PORT" -U eter -d "$DB_NAME" -tAc "SELECT count(*) FROM eter.ssi_reads" 2>/dev/null || true)
      echo "     observe capture: SSI-WAL=${wal_sz:-0} bytes, eter.ssi_reads=${reads:-0} rows"
    fi

    "$bin/pg_ctl" -D "$DATA_DIR" -m immediate stop >/dev/null 2>&1
    rm -rf "$DATA_DIR"
  done
  echo ""
}

echo "config,workload,trial,tps,avg_lat_ms,p95_lat_ms" > "$RESULTS"

run_config 1 "Baseline"              "$STOCK_BIN"   no  no
run_config 2 "Replica Identity Full" "$STOCK_BIN"   no  no
run_config 3 "Logical Decoding"      "$STOCK_BIN"   yes no
run_config 4 "Patched (observe off)" "$PATCHED_BIN" no  off
run_config 5 "Observe Mode"          "$PATCHED_BIN" no  on

# ---- summary (medians across trials) -> stdout + perf-summary.md ----------
{
  echo "# EterDB performance overhead, measured summary"
  echo
  echo "- Host: \`$(sysctl -n machdep.cpu.brand_string 2>/dev/null || sysctl -n hw.model) / $(sysctl -n hw.ncpu) cores / $(( $(sysctl -n hw.memsize)/1024/1024/1024 )) GB\`, $(uname -srm)"
  echo "- Engine: stock \`$("$STOCK_BIN/postgres" --version | awk '{print $3}')\`$([ -x "$PATCHED_BIN/postgres" ] && echo ", patched \`$("$PATCHED_BIN/postgres" --version | awk '{print $3}')\` (build dir \`$(basename "$(dirname "$PATCHED_BIN")")\`)")"
  echo "- pgbench: scale=$SCALE, clients=$CLIENTS, threads=$THREADS, duration=${DURATION}s, trials=$TRIALS (median reported), p95 sampling=$SAMPLING"
  echo "- max_pred_locks_per_transaction=$PRED_LOCKS (all configs); runs with any aborted/failed txns are rejected"
  echo "- Generated: $(date '+%Y-%m-%d %H:%M %Z') by \`test/perf-overhead.sh\` from \`$(basename "$RESULTS")\`"
  echo
  for wl in $WORKLOADS; do
    label=$([ "$wl" = tpcb ] && echo "TPC-B (write-heavy, default)" || echo "Select-only (read-only, -S)")
    echo "## Workload: $label"
    echo
    echo "| Configuration | TPS (median) | Avg latency (ms) | p95 latency (ms) | TPS overhead |"
    echo "| :--- | ---: | ---: | ---: | ---: |"
    base_tps=""; patched_off_tps=""; observe_tps=""
    for cfg in "Baseline" "Replica Identity Full" "Logical Decoding" "Patched (observe off)" "Observe Mode"; do
      mt=$(awk -F, -v c="$cfg" -v w="$wl" '$1==c&&$2==w{print $4}' "$RESULTS" | median)
      [ "$mt" = NA ] && continue
      ma=$(awk -F, -v c="$cfg" -v w="$wl" '$1==c&&$2==w{print $5}' "$RESULTS" | median)
      mp=$(awk -F, -v c="$cfg" -v w="$wl" '$1==c&&$2==w{print $6}' "$RESULTS" | median)
      if [ -z "$base_tps" ]; then base_tps="$mt"; ovh=", (ref)"; else
        ovh=$(awk -v b="$base_tps" -v t="$mt" 'BEGIN{printf "%.1f%%", (b-t)/b*100}')
      fi
      [ "$cfg" = "Patched (observe off)" ] && patched_off_tps="$mt"
      [ "$cfg" = "Observe Mode" ]          && observe_tps="$mt"
      printf '| %s | %s | %s | %s | %s |\n' "$cfg" "$mt" "$ma" "$mp" "$ovh"
    done
    echo
    if [ -n "$patched_off_tps" ] && [ -n "$observe_tps" ]; then
      marg=$(awk -v b="$patched_off_tps" -v t="$observe_tps" 'BEGIN{printf "%.1f%%", (b-t)/b*100}')
      echo "**Observe-mechanism marginal overhead** (Observe Mode vs Patched observe-off, same binary, isolates the mechanism's cost): **$marg** TPS."
      echo
    fi
  done
  # Build-aware caveat: an -opt build dir is a production -O2 (assertions-off) build;
  # otherwise it's the --enable-cassert/-O0 assert build whose absolute TPS is lower.
  case "$(basename "$(dirname "$PATCHED_BIN")")" in
    *-opt)
      echo "> The patched engine here is a production-shape \`-O2\` (assertions-off) build, so Observe Mode's marginal overhead vs **Patched (observe off)** is the mechanism's real cost." ;;
    *)
      echo "> The patched engine here is an \`--enable-cassert\`/\`-O0\` debug build (assertions on). Its absolute TPS is therefore lower than a production \`-O2\` build; compare Observe Mode against **Patched (observe off)**, same binary, for the mechanism's true cost, not against stock Baseline. Re-run with \`PATCHED_BIN=\$PWD/.pgbuild18-opt/bin\` for production-shape numbers." ;;
  esac
} | tee "$SUMMARY"

echo "Wrote $RESULTS and $SUMMARY"
