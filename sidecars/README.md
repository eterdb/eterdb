# EterDB sidecars (Phase 3)

Phase 3 makes the alpha's storage substrate **real** (not a demo placeholder) without any
Postgres-internals surgery. The temporal storage is provided by **pg_basebackup base backups +
archived WAL** (standard PITR, ADR 0003; unprivileged, no COW filesystem), monitored and
driven by sidecar processes. The main database stays clean: no history triggers, no DDL
rewriting.

Rejected alternatives (and why): a custom `smgr` page store / pageserver, "brain surgery on
smgr is a non-starter"; in-DB destructive-DDL rewriting (rename-to-tombstone), "a dirty hack
that makes the main DB a mess over time"; ZFS-COW as the substrate, replaced (it forced a
privileged container + kernel module on a Linux host; see ADR 0003).

**Stack:** both sidecars are **Go** (one module, `sidecars/go.mod`; two static binaries
`eter-capture` + `eter-storage`). Build with `make sidecars-build` or `bash sidecars/build.sh`.
Rationale in [`docs/adr/0001-sidecars-in-go.md`](../docs/adr/0001-sidecars-in-go.md).

## `capture/`, write history via logical decoding  ✅ BUILT
- Consumes the main DB's `pgoutput` logical replication slot (`wal_level=logical`; tracked
  tables use `REPLICA IDENTITY FULL` for full before/after images).
- Writes `(txid, commit_lsn, table, pk, before, after, fingerprint, committed_at)` to the
  history store. **This increment** the history store is `eter.history` in the main DB
  (durable, gap-free) behind a narrow `appendHistory()` seam; relocating to a separate instance
  (no bloat) ships with the storage sidecar.
- Replaces the Phase 1/2 in-DB `eter.capture` trigger (gated by `eter.capture_mode`;
  `sidecar` mode installs no trigger). Authoritative (the DB's own committed WAL stream,
  bounded lag, never divergence). Exactly-once across restarts via an LSN cursor.
- Differential-tested against the trigger oracle: `bash test/capture-diff.sh` (local, no ZFS).
- See `capture/README.md` for run/ops and the known limitations (structural fingerprints,
  commit-time `committed_at`, no `ctid`/`db_user`, async lag).
- DDL logging (event trigger) + the destructive-DDL→snapshot signal ship with `storage/`.

## `storage/`, base backups + WAL time-travel & recovery  ✅ BUILT
- The sidecar takes **retained `pg_basebackup` base backups** (recorded in
  `eter.storage_snapshots` with their end LSN; WAL-gated scheduled cadence via `daemon`) and
  the DB continuously **archives WAL**.
- **As-of-T reads:** copy the nearest earlier backup into a throwaway dir, replay archived WAL
  to `recovery_target_time` and promote, real PITR; the live DB is untouched.
- **Object recovery** (what triggers can't do): restore the pre-event backup, replay WAL to
  just before the drop, stand a throwaway Postgres on it, extract a dropped table / column /
  truncated rows, restore into prod.
- Go orchestrator over `pg_basebackup`/`pg_ctl`/`pg_dump`/`psql` (no engine surgery, no
  privilege), validated locally by `test/storage-pitr.sh`. See `storage/README.md`.
- Retention defaults to keep-everything; opt-in `ETER_BACKUP_RETAIN_COUNT` /
  `ETER_BACKUP_HORIZON_DAYS` bound the (re-derivable) backups/WAL, never `eter.history`.
  Parquet/object tiering deferred.

## `orchestrator/`, single HTTP entry point + managed restore jobs  ✅ BUILT
- Serves the `/v1` API the CLI's hosted transport speaks (one URL, no DSNs) and runs
  storage operations as **async, single-flight, crash-safe jobs** (`eter.jobs`), exec'ing
  `eter-storage` per job and scheduling its maintenance `cycle`. See
  `orchestrator/README.md` + ADR 0004. Run it **or** `eter-storage daemon`, never both.

## `eterclient/`, the shared Go engine client
- The two-pool (tenant + meta store) `DirectClient` + the `EterClient` interface + engine
  result types. One implementation feeds the CLI's direct mode (imported back via a
  `replace` directive in `cli/go.mod`) and the orchestrator's handlers. Changes here must
  be re-tested in BOTH modules (`sidecars/` and `cli/`).

## Notes
- The one piece that can NOT be a sidecar is SSI read-dependency capture, predicate reads are
  invisible outside the backend, so that stays in-engine (`ext/eter_ssi` + observe patch).
- The CLI / undo SQL surface (the frozen interface) does not change.
