# Observe-mode READ overhead - cost decomposition (issue #154, Step 0)

**Question.** `test/performance_report.md` shows observe-mode read overhead scaling
with concurrency (~26% @16 clients → ~51% @100), and identifies it as pure SIREAD
predicate-lock work (read-only `-S` txns skip the commit-time harvest). Issue #154
Step 0 asks: *which* SIREAD cost is it - per-transaction `SERIALIZABLEXACT`
registration/teardown (one global `SerializableXactHashLock`), or per-read
predicate-lock hash inserts (16 `PredicateLockManager` partition locks)? The fix
differs: if registration/teardown dominates, a small patch (no shared sxact)
captures most of the win; if per-read inserts dominate, only full backend-local
capture (skip the shared hash) helps.

**Method.** `test/observe-read-decompose.sh`. One warm `-O2` cluster
(`.pgbuild18-opt`), `pgbench -S` at 100 clients, `eter_observe_mode` on vs off via
`PGOPTIONS`. The `-S` workload is latency-bound (sub-ms txns, backends mostly idle
between statements), so 20 Hz `pg_stat_activity.wait_event` sampling resolves almost
nothing - the LWLock episodes are microseconds. Instead we **CPU-profile** a busy
backend with Apple `sample` (1 ms, ~15 k samples) and attribute *inclusive* samples
to each SSI entrypoint. observe-OFF is the control (must be ~0 - patch dormant).

## Result (M1 Pro, PG18.4, `-O2`, 100 clients)

Throughput reproduces the report: **~88k tps ON vs ~188k OFF ≈ 53% marginal.**

| Path | Symbol | Inclusive share (ON) | (OFF) |
| :--- | :--- | ---: | ---: |
| **Per-txn teardown (item 1)** | `ReleasePredicateLocks` | **64.4%** | 0% |
| - of which parked in kernel | leaf `semop` (LWLock wait) | 67.1% | 0% |
| Per-txn registration (item 1) | `GetSerializableTransactionSnapshotInt` | 0.8% | 0% |
| Per-read acquire (item 2) | `PredicateLockTID` | 0.1% | 0% |
| Per-read insert (item 2) | `PredicateLockAcquire` | 0.1% | 0% |

**The entire read overhead is one thing: `ReleasePredicateLocks` at commit.** Every
observe transaction takes the single global `SerializableXactHashLock` **EXCLUSIVE**
in `ReleasePredicateLocks` (predicate.c, to move its `SERIALIZABLEXACT` onto the
finished list + clean up conflicts). At ~88k commits/s across 100 clients they all
serialize on that one lock, so ~2/3 of a backend's wall-clock is spent *parked in
`semop`* waiting for it. This is the concurrency-scaling term - it worsens as commit
rate rises, exactly matching the 26%→51% curve.

Registration touches the same lock but holds it briefly (0.8%). **Per-read
predicate-lock inserts - the 16 partition locks, the `NUM_PREDICATELOCK_PARTITIONS`
lever, and the main target of "backend-local capture" - cost 0.2% combined, which is
negligible.**

## Implications for the fix

- **The win comes from not creating a shared `SERIALIZABLEXACT` at all.** No sxact →
  no `ReleasePredicateLocks` teardown → the global-lock contention (~65%) disappears.
  This is the issue's "lightweight observe registration, no shared sxact" partial,
  and Step 0 says it should capture essentially the whole win on its own. Skipping
  the per-read shared hash inserts is still correct (they become moot without a
  shared sxact), but is not itself where the cost is.
- **Anti-levers confirmed dead.** Bumping `NUM_PREDICATELOCK_PARTITIONS` (16→128) and
  lowering `max_pred_locks_per_page` target the 0.2% per-read path - not worth doing.
- **Read set still available locally.** The read-time tuple stash (`eter_ssi`) already
  captures exact rows backend-locally; `LocalPredicateLockHash` already does the
  tuple→page→relation granularity bookkeeping locally today. Backend-local capture
  harvests that local set at `PRE_COMMIT` instead of the shared sxact's lock list -
  no global structure touched on the hot path.
- **Free bonus, now explained.** Observe xacts stop consuming `PredXact` slots and
  stop taking `SerializableXactHashLock`, so they no longer hold back SIREAD cleanup /
  summarization for genuine SERIALIZABLE txns, and ops finding (a)
  (`max_pred_locks_per_transaction` sizing) is moot for observe.

## Post-fix verification (backend-local capture shipped)

Re-running the same harness after the fix (observe-local capture: no shared
`SERIALIZABLEXACT`, read set harvested from `LocalPredicateLockHash` at
`PRE_COMMIT`), 100 clients, `-O2`:

| Path | Symbol | Before | After |
| :--- | :--- | ---: | ---: |
| Per-txn teardown | `ReleasePredicateLocks` | 64.4% | **0.0%** |
| leaf `semop` (LWLock park) | - | 67.1% | **0.0%** |
| **Read marginal (tps)** | observe on vs off | **~48-53%** | **~2.6%** |

And `test/observe-read-scaling.sh` (interleaved A/B) went from a rising 27%→53%
curve to **flat 2-3%** across 16/32/64/100 clients. The teardown park is gone;
what remains (~2-3%) is the per-read local-hash insert + `heap_copytuple` stash,
which does not scale with concurrency.

**Soundness note (parallel query).** Backend-local capture is in the leader's
`LocalPredicateLockHash`; parallel *workers* don't arm observe and share no sxact,
so a parallel index/bitmap scan's worker-side tuple reads would go uncaptured (the
old shared-sxact design captured them via `parallel.c`'s unconditional
`ShareSerializableXact`). To keep capture COMPLETE, `eter_ssi` installs a
`planner_hook` that forces `max_parallel_workers_per_gather = 0` while a
transaction has observe mode on - every observe read then happens in the one
backend that harvests. Analytics readers that don't need capture should run with
observe off per-role (`eter_observe_mode` is `PGC_USERSET`) and keep parallelism.

*Regenerate: `bash test/observe-read-decompose.sh` (raw `sample` dumps are written to the
gitignored `test/read-decompose-prof.{on,off}.txt`).*
