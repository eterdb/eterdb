# `eter-orchestrator`, the single HTTP entry point + managed restore jobs

One URL for the eter CLI (`eter connect --url http://…:4400 --token …`): the orchestrator
serves the `/v1` API (init / track / log / preview / undo / cohort / markers / status,
the same wire protocol the retired TS eter-server spoke, so the CLI's hosted transport is
unchanged) and runs the storage sidecar's minutes-long PITR restores as **async jobs**.
See [`docs/adr/0004-orchestrator-single-endpoint.md`](../../docs/adr/0004-orchestrator-single-endpoint.md).

## What it does
- **Engine API**: handlers delegate to the shared [`eterclient`](../eterclient/) DirectClient
  (tenant + meta-store pools, the exact code the CLI's direct mode runs). Error bodies carry
  the engine's message verbatim (`{"ok":false,"error":…}`, 409/404/500), the CLI's stable
  exit codes depend on that text.
- **Storage jobs**: `POST /v1/storage/{snapshot,recover-table,recover-rows,recover-column,as-of}`
  → `202 {job_id}`; `GET /v1/jobs[/{id}]`, `POST /v1/jobs/{id}/cancel`,
  `GET /v1/storage/backups`. Jobs are durable rows in `eter.jobs` (meta store). Execution
  execs the `eter-storage` binary, **single-flight** (one serial lane: restores are
  full-copy IO bursts, and serializing moots throwaway-port collisions), per-job restore dir
  (`…/.restore/job-<id>`) + tmp port, structured stdout (`ETER_STORAGE_JSON=1`) as the job
  output, structured stderr as progress events.
- **Crash safety**: at boot every orphaned `running` job → `failed('orchestrator restarted
  during execution')` and leftover `job-*` restore dirs are swept (any throwaway postmaster
  stopped by pidfile first; top-level `rec_*`/`asof_*` dirs belong to a manually-run
  sidecar, possibly in flight, and are left alone). Cancel = SIGTERM, 10s grace, SIGKILL.
  `ETER_JOB_TIMEOUT_SEC` (default 3600) bounds every job/cycle so a hung sidecar can't wedge
  the lane forever.
- **Maintenance scheduling**: ticks `eter-storage cycle` (preflight + WAL flush after
  destructive DDL + WAL/age-gated scheduled backup + retention) through the same lane every
  `ETER_SCHEDULE_INTERVAL_SEC`, and runs the storage **preflight** once at boot (DDL logging
  on + WAL archiving verified, the lossless-recovery prerequisites `eter-storage daemon`
  used to ensure). **Run the orchestrator OR `eter-storage daemon`, never both**
  (double-scheduling = duplicate backups).

## Config (env)
`DATABASE_URL` (required), `ETER_META_URL` (default tenant), `ETER_PORT` (4400), `ETER_HOST`,
`ETER_API_TOKEN` (optional bearer guarding `/v1/*`), `ETER_STORAGE_BIN` (default
`eter-storage` on PATH), `ETER_SCHEDULE_INTERVAL_SEC` (30; 0 = off), `ETER_JOB_TIMEOUT_SEC`
(per-job/cycle execution bound; 3600, 0 = unbounded),
`ETER_BACKUP_DIR`/`ETER_RESTORE_DIR`/`ETER_WAL_ARCHIVE`/`ETER_PG_BINDIR` (passed to storage
jobs; backup dir unset ⇒ API-only mode, storage submissions fail loudly), `ETER_TMP_PORT`
(per-job base, 5599), `ETER_SQL_FILE` (engine SQL for `/v1/init`).

## Running it
In the shipping stack the orchestrator runs inside the `control-plane` container (alongside the
meta store + capture sidecar); `docker compose up -d` starts it on :4400.
```bash
ETER_API_TOKEN=change-me docker compose up -d   # engine + control-plane (:4400)
eter connect --url http://localhost:4400 --token $ETER_API_TOKEN
eter preview <txid>                 # engine ops, one URL, no DSNs
eter recover-table public.widgets   # submits a job + waits (--no-wait for async)
eter jobs                           # list; eter jobs <id> [--cancel]
```
Locally: `make orchestrator` (needs `DATABASE_URL`). `test/orchestrator.sh` is the e2e.
