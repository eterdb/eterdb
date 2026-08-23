# EterDB Postgres patch set (observe mode)

`patches/0001-eter-observe-mode-pg18.patch` is the small, upstream-tracked core patch that
makes **observe mode** possible: recording SSI predicate-read dependencies under **READ
COMMITTED**, with no serialization-failure (40001) enforcement and no change to visibility.

This is the "near-stock Postgres + small patch set" the pitch describes (the same model
Neon uses). It is **built + verified under live assertions**, see "Validation" below.

## What the patch does (9 files, ~390 lines)
Observe capture is **backend-local** (issue #154): a transaction below SERIALIZABLE
acquires SIREAD predicate locks in the per-backend `LocalPredicateLockHash` - the
tuple→page→relation granularity/promotion bookkeeping core already keeps locally -
and **never registers a shared `SERIALIZABLEXACT`** or inserts into the shared
predicate-lock hash. The read set is harvested from the local table at `PRE_COMMIT`.
This is what makes observe cheap: the shared `SERIALIZABLEXACT` lifecycle took the
global `SerializableXactHashLock` exclusively at commit teardown, and under read
concurrency that teardown was ~2/3 of an observe backend's wall-clock
(`test/observe-read-decompose.md`); with no shared sxact there is no teardown, and
the read overhead goes from ~26%→51% (rising with concurrency) to a flat ~2-3%.

- Adds GUC `eter_observe_mode` (`guc_tables.c`).
- `snapmgr.c`: at first-snapshot setup, calls `EterMaybeRegisterObserveXact()`.
- **Read-time PK capture hook** (`predicate.[ch]` + the 3 `heapam.c`/`heapam_handler.c` call
  sites): `PredicateLockTID` gains a `HeapTuple` parameter and, when a tuple SIREAD lock is
  acquired, invokes `eter_tuple_read_hook(relation, tuple)` with the live tuple. `eter_ssi`
  sets that hook to `heap_copytuple` the read tuple into a per-transaction stash (lock-free, no
  catalog access under the buffer lock) and resolve its primary key from that own-memory copy at
  `PRE_COMMIT`, so read↔write matching is immune to vacuum/line-pointer reuse (closes the
  false-clean the completeness harness found). NULL/no-op on stock Postgres.
- `predicate.c`:
  - `EterMaybeRegisterObserveXact()` arms observe-local capture: it sets
    `MyXactIsObserveLocal` and creates `LocalPredicateLockHash` - **no snapshot, no
    shared sxact**, so visibility is untouched (`MySerializableXact` stays `Invalid`).
  - `SerializationNeededForRead` and `CheckForSerializableConflictOutNeeded` admit an
    observe-local xact so reads still **acquire** predicate locks, but the conflict-out
    paths return before dereferencing the (absent) sxact - capture without enforcement,
    never a 40001.
  - `PredicateLockAcquire` skips the shared `CreatePredicateLock` (and
    `DeleteChildTargetLocks`) for observe-local; only the local hash + promotion counters
    are touched. The whole granularity/promotion machinery already ran locally.
  - `ReleasePredicateLocks` frees the local hash for an observe-local xact and returns -
    **no `SerializableXactHashLock`, no finished-list move** (the removed teardown cost).
  - **Read-set harvest** (`EterGetMyPredicateLockTargets`, declared in
    `predicate_internals.h`): mode-transparent. For a real SERIALIZABLE xact it walks
    `MySerializableXact->predicateLocks` under `SerializablePredicateListLock` (strict
    mode, unchanged); for observe-local it walks `LocalPredicateLockHash` (no shared lock -
    it's per-backend memory). Same captured set `eter_ssi` consumes; `eter_ssi` calls one
    function either way.
- **Index read hook** (`predicate.[ch]` + the `indexam.c`/`nodeIndexonlyscan.c` call sites,
  issue #192): a btree [Index Only] Scan takes its SIREAD lock on the **index**, a page
  target carrying no row identity, so the harvest could only resolve it to "every write to
  the underlying table". Applied to an ordinary indexed read that over-approximation is not
  merely coarse: a single `UPDATE ... WHERE id = $1` made its writer depend on the table's
  entire write history, so a cohort of unrelated single-row writes classified **0 clean**.
  `eter_index_read_hook(heapRel, tid, indexoid, fetched)` fires once an index scan has
  produced a row, naming the index. With `fetched=true` the heap tuple came back through
  that index and `PredicateLockTID` already stashed it; with `fetched=false` an Index Only
  Scan answered from an all-visible page, so the TID is handed over to be stashed and
  resolved at `PRE_COMMIT` (this is what made the issue #175 index-only capture *precise*
  rather than table-wide). `eter_ssi` then drops the coarse index-relation line for indexes
  it covered precisely. A bitmap index scan reports itself the same way from
  `index_getbitmap` (its rows are predicate-locked, and so stashed, by the bitmap *heap*
  scan). An index that never fires the hook, an empty scan that matched nothing whose
  predicate read is real and must stay surfaced, keeps the coarse line. Suppression is
  driven by positive evidence of precise capture, never by assumption, which is what keeps
  it sound.
  > **Boundary.** Per-row capture stops once SSI promotes to a RELATION-level lock:
  > `PredicateLockTID` returns before the read hook when a relation lock already covers the
  > tuple. That promotion emits its own coarse heap-relation line, which is deliberately
  > *not* suppressed: it is not redundant, the rows behind it really were not captured. So
  > a read wide enough to promote still over-approximates to table level. Sound, and tunable
  > with `max_pred_locks_per_relation` / `max_pred_locks_per_transaction`.
- `predicate.h`: exports `eter_observe_mode` + `EterMaybeRegisterObserveXact()`.

Lock-coarsening under memory pressure still applies, so the captured graph
*over-approximates* (the safe direction) exactly as the pitch states.

**Parallel query.** Parallel workers don't arm observe and share no sxact with the
leader, so their reads would go uncaptured. `eter_ssi` installs a `planner_hook` that
forces `max_parallel_workers_per_gather = 0` whenever `eter_observe_mode` is on, so
every observe read happens in the one backend that harvests - capture stays complete.
(Readers that don't need capture should set `eter_observe_mode = off` per-role and keep
full parallelism.)

## Validation (assertion-enabled)
Built `--enable-cassert --enable-depend` (confirm with `SHOW debug_assertions` → `on`), PG18.4:
- **Stock serializability unchanged:** `src/test/isolation` 119/119 and `src/test/regress`
  231/231 pass, with the patch present and observe mode off (the default), including every
  SSI/write-skew/predicate spec, with zero assertion traps.
- **Observe path is assert-clean:** `test/observe.sh`, `test/ssi.sh`, and `test/false-clean.sh`
  (100% rw-edge recall) pass under live assertions. (The assert build catches real bugs - e.g.
  the backend-local rework tripped an assert where `CheckForSerializableConflictOutNeeded`
  dereferenced the absent sxact; a non-assert build would have SIGSEGV'd in production instead.)
- **Enforcement intact:** at SERIALIZABLE a write-skew still raises exactly one 40001; under
  observe mode (READ COMMITTED) the same workload commits cleanly while the reads are captured.

## Target: PG18
EterDB runs on **PG18** (`REL_18_4`). The one tracked patch file
(`patches/0001-eter-observe-mode-pg18.patch`) + `eter_ssi` are the only things that pin the project
to a version; the sidecars / SQL engine / CLI are version-agnostic. PG19 is deferred while it is
still in beta (`REL_19_BETA1`).

PG16 was the original target and is **gone**: its patch was deleted once PG18 became the sole
build/test target, since nothing applied it. `eter_ssi` still compiles against an unpatched engine
with `-DETER_STRICT_ONLY`, which drops observe mode and captures at SERIALIZABLE only.

## Build (PG18, `.pgbuild18`)
The default prefix/datadir/port the harness expects. `test/observe.sh` and `test/ssi.sh` default to
`.pgbuild18` / `.pgdata-observe18` / 5433 (override via `PGBUILD` / `PGDATADIR` / `PGPORT`):
```bash
git clone --depth 1 --branch REL_18_4 https://github.com/postgres/postgres.git .pgsrc18
git -C .pgsrc18 apply ../pg/patches/0001-eter-observe-mode-pg18.patch
cd .pgsrc18
./configure --prefix="$PWD/../.pgbuild18" --enable-cassert --enable-depend \
  --without-icu --without-readline --without-zlib CFLAGS=-O0
make -j8 && make install
cd ..
.pgbuild18/bin/initdb  -D .pgdata-observe18 -U eter --auth=trust
.pgbuild18/bin/pg_ctl   -D .pgdata-observe18 -o "-p 5438" -l .pgdata-observe18/server.log start
.pgbuild18/bin/createdb -p 5438 -U eter eter
PGBUILD="$PWD/.pgbuild18" PGDATADIR="$PWD/.pgdata-observe18" PGPORT=5438 bash test/observe.sh
PGBUILD="$PWD/.pgbuild18" PGDATADIR="$PWD/.pgdata-observe18" PGPORT=5438 bash test/ssi.sh
```

### PG18 validation record (assertion-enabled, `debug_assertions=on`)
Re-ran the full gauntlet on `.pgbuild18` (REL_18_4, `--enable-cassert`):
- `src/test/isolation` **119/119** and `src/test/regress` **231/231** pass (higher counts than PG16's
  117/220 because PG18 ships more specs; 0 `not ok`, both exit 0), stock serializability unchanged
  with the patch present and observe off.
- `test/observe.sh` (READ COMMITTED capture, zero 40001) and `test/ssi.sh` (strict-mode rw edge +
  the ctid-less sidecar PK-resolution case) both green.

`.pgsrc*/`, `.pgbuild*/`, and `.pgdata*/` are gitignored; only the patches are tracked.
Production builds should drop `CFLAGS=-O0`/`--without-*` and validate against the Postgres
regression suite (Phase 5).
