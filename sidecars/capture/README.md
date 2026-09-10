# `eter-capture`, capture sidecar (Phase 3)

Replaces the Phase 1/2 in-DB `eter_capture` AFTER trigger. Consumes the main
DB's logical replication slot (`pgoutput`) and writes the same `eter.history`
rows out-of-process, off the commit hot path. The DB's own committed WAL stream
is authoritative: bounded decode lag, never divergence.

Written in **Go** (`github.com/jackc/pglogrepl` + `pgx`); see
[`docs/adr/0001-sidecars-in-go.md`](../../docs/adr/0001-sidecars-in-go.md).

## Run

```bash
export DATABASE_URL=postgres://eter:eter@localhost:5432/eter
make capture            # or: go run -C sidecars ./capture
# build a static binary:  make sidecars-build  →  sidecars/bin/eter-capture
```

The sidecar (idempotently) creates publication `eter_pub`, the logical slot
`eter_slot`, and the `eter.capture_state` cursor row; reconciles publication
membership + `REPLICA IDENTITY FULL` against `eter.tracked`; then streams.

Env: `ETER_SLOT`, `ETER_PUBLICATION`, `ETER_RECONCILE_MS`.

## Requires (one-time, on the main DB, needs a restart)

```
wal_level = logical
max_wal_senders >= 4
max_replication_slots >= 4
```

`eter.track` must run in **sidecar mode** (the default): it sets `REPLICA
IDENTITY FULL` and adds the table to `eter_pub` instead of installing the
trigger. Set `eter.capture_mode = 'trigger'` to fall back to the in-DB oracle
(used by `test/capture-diff.sh`).

## Exactly-once / restart

Each committed transaction's history rows are written **atomically** with an
advance of `eter.capture_state.last_commit_lsn`; the slot is acknowledged only
afterwards. On restart the slot resumes from its confirmed-flush LSN and any
re-delivered commit is filtered by the LSN cursor, so no gaps and no duplicates.
A stopped sidecar with a live slot retains WAL; drop the slot
(`pg_drop_replication_slot`) when tearing an environment down.

## Known limitations (this increment)

- **History is in the main DB.** It is fully durable (WAL-logged, in backups /
  replicas / ZFS snapshots) and gap-free, but does not yet survive the main DB
  failing independently. The writer (`store.go`) is a single narrow seam so relocating to a
  separate history-store instance later is a one-module change. That ships with
  the ZFS storage sidecar (Linux host).
- **`fingerprint` / `statement_sample` are structural** (op + table + changed
  columns), not SQL-text-derived, logical decoding carries no statement text.
  Cohort-by-shape selection still works; the values are not byte-comparable to
  the trigger's. See `fingerprint.go`.
- **No `db_user` / per-write `application_name` / `ctid`.** `application_name` is
  the sentinel `eter-capture`; `db_user` defaults to the sidecar role; `tid`
  is NULL (logical decoding has no `ctid`, the documented basis for the
  `eter_ssi` PK-resolution rework).
- **`committed_at` is the commit timestamp** (from the WAL commit record), not the
  per-row `clock_timestamp()` the trigger used, more correct, slightly different.
- **Capture is asynchronous** (bounded lag). Reads of history immediately after a
  write may briefly lag; authoritative and drift-free, but not instantaneous.
