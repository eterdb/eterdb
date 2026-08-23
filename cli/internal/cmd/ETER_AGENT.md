# Driving EterDB from an agent (Claude)

`eter` is a CLI for inspecting and **surgically reversing** transactions on a live
Postgres. It is safe to use autonomously **if you follow the preview-before-apply rule
below**. Every command supports `--json`; prefer it.

## The mental model
- Each change to a tracked table is recorded with its **transaction id (txid)**.
- Reversing a txid is either **clean** (no later transaction wrote *or read* the same rows) or
  **dependent** (a later write touched the rows, or a later txn *read* what you're undoing;
  reverting blindly could corrupt state).
- You always **preview** first. `eter undo <txid>` is a dry run; it only mutates with
  `--apply`.

## Safe workflow
1. `eter log --json`, find the offending transaction(s).
2. `eter preview <txid> --json`, read `classification`:
   - `"clean"` → `eter undo <txid> --apply`
   - `"dependent"` → inspect `conflict_edges` (each has `kinds`: `ww` = a later write to the
     same rows, `rw` = a later txn that *read* what you're undoing). Decide:
     - reverse the dependents too: `eter undo <txid> --apply --cascade`
     - keep them, revert only the target: `eter undo <txid> --apply --targeted`
       (this can leave derived rows inconsistent, only with user intent)
   - Check `precision` / each edge's `precision` field: `"exact"` means the dependent provably
     touched the reverted rows; `"over-approx"` means a writer *seqscanned* the table and may not
     have read them (the safe direction, never a missed dependency). `coarse_tables` lists the
     tables where adding an index on the readers' filter columns would make the dependency precise.
3. For an incident spanning many writes, select a **cohort** instead of one txid:
   `eter cohort --table public.invoices --since '<deploy time>' --json`, review, then
   `eter undo-cohort --table public.invoices --since '<deploy time>' --apply`. In the default
   `clean_only` mode `undo-cohort` **skips and reports** dependents rather than aborting the batch:
   read `reverted_txns` / `skipped_dependent` / `skipped_txids`, then re-run the skipped ones with
   `--cascade` or `--targeted` after review.

## Exit codes (branch on these)
- `0` ok · `2` usage · `3` not found · `4` **dependent (undo refused in clean_only)** ·
  `5` database error · `6` config error · `7` **prerequisite missing** (e.g. `track`
  refused because no capture sidecar is attached).

A `4` means: do **not** retry with `--apply` blindly. Re-run `preview`, surface the
conflicts to the human, and only then choose `--cascade` or `--targeted`.

## External references (what an undo cannot reach)
`preview` returns `external_refs`, foreign keys into external systems (Stripe `ch_…`,
emails, message ids) found in the rows the undo touches. **These are NOT reversed by an
undo.** When they are present, tell the user plainly: the database rows will be restored,
but e.g. the Stripe charges already fired and the emails already sent are not undone. (This
is the ground truth a future "revert orchestrator" would act on; today it is informational.)

## Known limitations (alpha)
- Dependency analysis detects **write-write** conflicts exactly **and read dependencies**,
  a later txn that *read* the changed value and wrote something derived is captured via SSI
  (built + assertion-validated; 100% read-edge recall on the false-clean gate). A `clean`
  result therefore means "no later txn wrote *or read* these rows", the dependency a CDC or
  proxy cannot see. The one residual coarseness: a writer that **seqscans** a table is
  surfaced as `over-approx` (it may not have read the exact reverted rows), extra reviews,
  never a missed edge.
- **Modes:** *observe mode* (default, built) records dependencies while the app stays on READ
  COMMITTED, no serialization failures, no visibility change; *strict mode* is SERIALIZABLE
  and can return retryable `40001` errors, treat those as retry-the-transaction, not a
  failure. Under load, SIREAD lock coarsening makes the graph *over*-approximate (extra
  `dependent` classifications, surfaced as `over-approx`); that is the safe direction, never a
  corrupt revert.
- EterDB reverses **database state only**. It cannot unsend an email or refund a
  charge, see `external_refs` above. State that boundary plainly.
- Tables must have a primary key to be reversible.

## Connection
- Direct mode: `--db <postgres-url>` or `DATABASE_URL`.
- Hosted mode (the orchestrator, the single entry point): `--url <orchestrator>` +
  `--token <token>` or `ETER_URL` / `ETER_TOKEN` (or persist once with
  `eter connect --url … --token …`). One URL covers everything below.

## Schema recovery + time travel (storage commands)
`snapshot [label]` · `recover-table <schema.table> [snapshot]` ·
`recover-rows <schema.table> [snapshot]` · `recover-column <schema.table> <col> [snapshot]` ·
`as-of <iso-time> <sql>`. All take `--json`. In hosted mode these run as **async jobs** on
the orchestrator: the command submits and **waits by default** (restores take minutes,
they restore a base backup and replay WAL); pass `--no-wait` to get `{job_id}` back
immediately and follow with `eter jobs <id>` (`--cancel` to abort). Failed jobs carry the
engine's error text, so the exit codes above still apply. In direct mode they proxy to the
local `eter-storage` binary instead (no job queue).
