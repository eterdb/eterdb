# eter_ssi: SSI read/write dependency capture (Phase 2, built)

A real loadable C extension that retains the read/write dependency graph Postgres
computes inside its SSI machinery and discards at commit. This is the data no
CDC/proxy can see, and what makes an undo `dependent` when a later transaction only
*read* (never wrote) the rows being reversed.

## How it works
- **Capture (off the commit path).** An `XactCallback` at `PRE_COMMIT` reads the
  committing backend's SIREAD predicate locks via the exported
  `GetPredicateLockStatusData()` (filtered to its own vxid + database) and appends
  `(reader_xid, reloid, block, offset, locktype, read_pk)` to a per-database
  append-only SSI-WAL (`$PGDATA/eter_ssi.<dboid>.wal`). The `read_pk` is the read
  row's primary key, resolved **eagerly at read time**: a tuple/index read hook
  (`eter_tuple_read_hook` / `eter_index_read_hook`) `heap_copytuple`s the live row
  into a per-txn stash and `eter.resolve_pk`s it at `PRE_COMMIT`, so it survives
  the vacuum / HOT line-pointer reuse that a drain-time lookup used to race (the
  false-clean the `test/false-clean.sh` gate caught). Read-only transactions (no
  xid) are skipped, they can never be an undo target nor constrain a reversal.
- **Two modes.**
  - *Strict*, at SERIALIZABLE, on stock Postgres. (`test/ssi.sh`)
  - *Observe*, at READ COMMITTED, on the EterDB-patched engine
    (`eter_observe_mode`, see `pg/`), with zero serialization failures. Observe
    capture is backend-local (`LocalPredicateLockHash`, no shared
    `SERIALIZABLEXACT`), harvested at `PRE_COMMIT`. (`test/observe.sh`)
- **Drain → graph.** `eter.drain_ssi_wal()` (C/SPI) ingests the WAL into
  `eter.ssi_reads`; `eter.derive_dependencies()` matches each read to the writes
  that touched the same **`(table, pk)`** (the read's `read_pk` against each
  write's PK from `eter.history`) to produce real `rw` read-edges in
  `eter.dependencies`. Matching by PK rather than `ctid` is what lets read-edges
  resolve in sidecar mode, where logical-decoding writes have no `ctid`
  (`history.tid` is NULL); block/relation granularity remains the safe
  over-approximation when a precise PK is absent. `eter.refresh_dependencies()`
  does both and then clears `ssi_reads` (bounded growth). `preview_undo`
  classifies `dependent` on ww OR rw edges.
- **Background worker (auto-drain).** When loaded via `shared_preload_libraries`,
  a bgworker periodically runs `refresh_dependencies()` on a configured database, so
  dependencies appear without an explicit call:
  ```
  shared_preload_libraries = 'eter_ssi'
  eter_ssi.drain_database = '<db>'        # one worker drains one database
  eter_ssi.drain_interval_ms = 300
  ```
  (Capture also works via `session_preload_libraries` without the worker.)

## Build / install
```bash
make PG_CONFIG="$(which pg_config)" install
psql "$DB" -c "CREATE EXTENSION eter_ssi;"
# strict mode: run workload at SERIALIZABLE.
# observe mode: needs the patched engine (pg/), then eter_observe_mode=on at READ COMMITTED.
```

## Scope / remaining
- The SSI-WAL is a file (append at commit). A shared-memory ring buffer (per the
  pitch) is a later optimization off even the file-append path.
- One drain worker per database; multi-database hosting would spawn one each.
- Tuple/page/relation match granularity; page/relation is the safe over-approximation.
