# `eter-storage`, storage sidecar (Phase 3)

Temporal storage as **pg_basebackup base backups + archived WAL**, driven by a sidecar
that orchestrates `pg_basebackup` / `pg_ctl` / `pg_dump` / `psql` (standard PITR, see
[`docs/adr/0003-storage-substrate-basebackup-pitr.md`](../../docs/adr/0003-storage-substrate-basebackup-pitr.md)).
No storage-engine surgery, no in-DB tombstones: the live database stays clean; recovery
happens on throwaway restored copies. Everything is an ordinary unprivileged Postgres
operation, **no root, no kernel module, no privileged container**; it runs anywhere
containers (or plain processes) run.

Written in **Go** (a single static binary); see
[`docs/adr/0001-sidecars-in-go.md`](../../docs/adr/0001-sidecars-in-go.md).

## Commands
```
go run -C sidecars ./storage <cmd>     # or the built binary: sidecars/bin/eter-storage <cmd>
  snapshot [kind]                 take + record a retained base backup (eter.storage_snapshots)
  list                            list recorded backups
  recover-table   <ident> [snap]  restore a dropped/truncated table
  recover-rows    <ident> [snap]  restore truncated rows (WAL-replayed to just before the TRUNCATE; ON CONFLICT DO NOTHING keeps newer writes)
  recover-column  <ident> <col> [snap]   re-add + repopulate a dropped column, matched by PK
  as-of <iso> <sql>               run sql against the DB as it was at time iso (PITR)
  daemon [intervalSec]            periodic base backups + WAL flush when destructive DDL appears
  cycle                           ONE daemon iteration (for an external scheduler, the orchestrator)
  preflight                       ensure DDL logging on + verify WAL archiving (what daemon does at start)
```

`ETER_STORAGE_JSON=1` switches result lines on stdout to single-line JSON objects (the
orchestrator's job runner sets it); unset, the human output is unchanged.

**Orchestrated deployments** (the recommended shape, see `../orchestrator/README.md` +
ADR 0004): the orchestrator schedules `cycle` and runs recoveries as async jobs. Run the
orchestrator **or** `daemon`, never both (double-scheduling = duplicate backups; cost, not
corruption). One more reason to prefer the orchestrator: its single-flight lane makes a
scheduled retention pass and a running recovery mutually exclusive. In standalone `daemon`
mode a **manual `recover-*` run in parallel is a separate process with no shared lane**, if
retention prunes the exact base backup that recovery is mid-copy on, the restore copy is
truncated (the recovery fails; the live DB is untouched). With retention knobs enabled in
daemon mode, don't run manual recoveries concurrently, or run recoveries through the
orchestrator.

## How recovery works
1. **Snapshot:** `pg_basebackup -Fp -c fast` into `ETER_BACKUP_DIR/base-<stamp>`; record the
   backup's **end LSN** + first needed WAL segment. With `ETER_WAL_ARCHIVE` set the backup
   carries no WAL (`-X none`) and the sidecar forces the end-of-backup segment out to the
   archive before recording it. A **down archiver fails the snapshot fast**: the sidecar
   probes archiver liveness *before* starting (a `-X none` backup-stop blocks server-side
   until the segment archives, so pg_basebackup would otherwise hang forever), and a
   backup whose end segment still can't be confirmed within ~60s is **discarded, never
   catalogued**. Without an archive the backup embeds WAL (`-X stream`) so it stays
   startable on its own.
2. **Object recovery:** copy the chosen base backup into a throwaway restore dir → configure
   archive recovery → **replay archived WAL forward to just before the drop's LSN**
   (`recovery_target_lsn` from `eter.ddl_log.snapshot_lsn`, `recovery_target_inclusive=off`,
   promote) → stand a throwaway Postgres on it → `pg_dump`/`SELECT` the lost object → restore
   into the live DB → remove the dir. The backup is only a *base*: WAL replay means writes
   made between the backup and the drop are recovered too, so backup cadence never bounds
   data completeness (only replay time). Requires `ETER_WAL_ARCHIVE`; without it, recovery
   falls back to the backup frozen at its own consistency point, where rows written after
   the backup and before the drop are lost.
3. **As-of-T:** copy the newest backup before T, set `restore_command` +
   `recovery_target_time = T` + `recovery_target_action = promote`, replay archived WAL,
   query the promoted copy. The live DB is never touched.

## Prerequisites for lossless recovery (enforced)
Lossless object recovery needs two things on, so they are **preflighted**: the `daemon` at
start, every `cycle` invocation (each cycle is a fresh process, this is how orchestrated
deployments get the guarantee), the orchestrator once at boot, and `eter-storage preflight`
on demand:
- **DDL logging**, every `DROP`/`TRUNCATE` records its LSN in `eter.ddl_log`, the target the
  restore replays WAL to. The daemon calls `eter.enable_ddl_logging()` itself (idempotent). TRUNCATE
  is invisible to DDL event triggers, so the engine captures it with a per-table `AFTER TRUNCATE`
  trigger (auto-attached to existing + newly-created tables).
- **WAL archiving**, recovery replays *archived* WAL. The daemon can't turn `archive_mode` on (needs
  a restart), so it verifies it: a hard error if `ETER_WAL_ARCHIVE` is set but the server isn't
  archiving, a warning (degrades to backup-only) if no archive is configured.

`pg_basebackup` connects over the **replication protocol**: the tenant needs a `replication`
`pg_hba.conf` entry (the `all` database keyword does not cover it) and `max_wal_senders > 0`.
initdb-default hba files include it; the engine image provisions it.

## Config (env)
`DATABASE_URL` (live DSN), `ETER_BACKUP_DIR` (where base backups live, e.g.
`/var/lib/eter/backups`), `ETER_META_URL` (durable bookkeeping store; defaults to the
tenant), `ETER_WAL_ARCHIVE` (archive dir, required for `as-of` + lossless recovery),
`ETER_RESTORE_DIR` (throwaway restore workdir; default `<ETER_BACKUP_DIR>/.restore`),
`ETER_TMP_PORT` (recovery instance socket port), `ETER_PG_BINDIR` (PG binaries if not on
PATH, must match the tenant's major), `ETER_SNAPSHOT_MIN_WAL_BYTES` (WAL gate for the
daemon's scheduled backups; default 1 GiB), `ETER_BACKUP_MAX_AGE_HOURS` (force a scheduled
backup when the newest is older; default 24), `ETER_RECOVERY_TIMEOUT_SEC` (WAL-replay bound
for a restore; default 300), `ETER_PG_OS_USER` (LEGACY: only for a root-run sidecar,
wraps the throwaway server in `sudo -u` and chowns restore dirs; leave unset in the normal
same-user deployment).

The archive path is double-quoted inside `restore_command`/`archive_command` (spaces are
fine); it must not contain quote characters.

### Retention (backups/WAL only, history is NEVER pruned)
Default: **retain everything** (months-old restore always works). Opt-in knobs, applied by
the daemon after each scheduled backup:
- `ETER_BACKUP_RETAIN_COUNT=N`, keep the oldest backup (the anchor of the whole recovery
  horizon) + the N newest; prune middles. Never touches WAL.
- `ETER_BACKUP_HORIZON_DAYS=D`, bound recovery depth to D days: prune backups oldest-first
  while one backup at-or-before `now()-D` remains, then `pg_archivecleanup` WAL older than
  the oldest retained backup's start segment.
Pruned catalog rows keep an audit trail (`pruned_at`); recovery ignores them. This policy is
for the re-derivable recovery substrate only, `eter.history` retention is a separate,
committed never-prune DECISION (PLAN.md).

## Running it
An ordinary unprivileged process (the `eter-storage` binary). In the shipping
stack it runs **inside the `control-plane` container**, driven by the orchestrator's storage
scheduler, so there is no standalone storage service to start:
```bash
ETER_API_TOKEN=change-me docker compose up -d   # engine + control-plane
eter recover-table public.widgets               # a managed restore job
```
See [`docker/README.md`](../../docker/README.md). The control-plane image is built `FROM` the
engine image (it needs the patched PG server binaries, same major, to stand up the recovery
instance) and runs as the `postgres` user. The engine (writes `wal-archive/`) and the storage
machinery (owns `backups/` + throwaway restores) share one `/var/lib/eter` volume. This maps
onto two production hosts: the tenant engine, and the control-plane host that also does recovery.

Locally (no Docker), `test/storage-pitr.sh` stands the whole two-DB shape up against a
patched PG18 build (`.pgbuild18`, override `PGBUILD`) and proves dropped-table,
WAL-replay-past-backup, dropped-column, truncated-rows, and as-of-T recovery;
`test/storage-lifecycle.sh` covers the unattended machinery, `cycle` scheduling (incl.
preflight enabling DDL logging by itself), the WAL-gated cadence, the destructive-DDL
flush, both retention knobs (incl. `pg_archivecleanup` with PITR from the retained anchor
still working), and the archiver-down snapshot discard. macOS or Linux, no VM.

## Limitations (this increment)
- WAL-replay object recovery needs the WAL segment holding the drop to be **archived**:
  `archive_command` only ships completed segments. The sidecar forces a segment switch
  itself (`ensureArchivedThrough`) before replaying, and the daemon does the same the moment
  it notices a destructive DDL. Without `ETER_WAL_ARCHIVE` at all, recovery degrades to
  backup-only (rows written after the base backup and before the drop are lost).
- A restore materializes a **full copy** of the base backup and replays WAL, minutes for
  large tenants, not the milliseconds a ZFS clone took. `ETER_RECOVERY_TIMEOUT_SEC` bounds
  the wait.
- Plain-format `pg_basebackup` does not map **user tablespaces**; preflight warns if any
  exist, objects in them are not recoverable by this sidecar.
- Recovery uses `pg_dump`/`SELECT` extraction; for very large objects a filesystem-level
  path would be faster (future).
- `recover-table` restores the relation and its own constraints; inbound FKs from other
  tables are the operator's call (re-add after dependents exist).
- Base backups are full physical copies (no COW): disk scales with backup count × DB size.
  The retention knobs above are the lever; parquet / object-storage tiering (or
  pgBackRest/WAL-G at the `backupT` seam) is the deferred cost lever for off-host/cold data.
