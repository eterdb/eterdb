-- Twenty-on-EterDB demo, SCENARIO B incident: a DESTRUCTIVE edit wipes deal values.
--
-- The story: a stage-automation bug (or an AI agent) zeroes a deal's value the moment
-- it transitions to "Customer" (Twenty's closed-won stage), `amountAmountMicros` is
-- set to 0. This is the hard case on
-- purpose: the original value is DESTROYED. No formula recovers it (unlike a doubling,
-- which you'd just halve), the only thing that can put it back is eter's before-image
-- in history. Each affected deal is a SEPARATE transaction (a real per-row job), so
-- eter sees a cohort of same-shape writes, selectable by statement shape + the wiped
-- value (0) + time.
--
-- After running this, Twenty's "Quarterly Revenue by Stage" dashboard (and
-- eter_demo.quarterly_revenue()) report $0 Customer-stage revenue → the faulty
-- quarterly report, with the real numbers gone. Scenario B cohort-reverts it,
-- restoring each deal's exact prior value from history.
--
-- PREREQ: tables tracked via eter.track_all (so these writes are captured). Capture sidecar
-- running if you are in sidecar/two-DB mode.
--
-- Run:  psql "$DATABASE_URL" -f test/twenty/20-incident-bad-edits.sql

\set ON_ERROR_STOP on

-- This incident is healed from HISTORY (before-images), not from read-dependencies -
-- read-dep capture is Scenario C's concern (a decision job that reads a corrupted
-- value). This buggy per-row job has no meaningful reads: on a real (large) Twenty
-- table each `WHERE id = ...` update touches one row, but on this tiny demo table the
-- scans incidentally read deals a prior edit already zeroed, manufacturing
-- cohort-internal read-dependencies that make clean_only skip a few members
-- (reverting the whole cohort makes those internal deps moot, but the timing of when
-- they derive is a race - surfaced by #154). Run the incident with observe off so its
-- incidental reads don't enter the graph; the WRITES are still captured to history by
-- the sidecar (logical decoding is independent of observe), so the cohort heal is exact
-- and deterministic. Observe stays on for the tenant generally; this is one session.
SET eter_observe_mode = off;

-- Mark the incident start so the cohort can be scoped by time.
SELECT now() AS incident_t0 \gset
\echo 'Incident start (use as --since):' :'incident_t0'

-- One UPDATE per affected row, each its own transaction. We target current-quarter
-- Customer-stage (closed-won) deals and WIPE the value to 0. Done in a plpgsql loop
-- with per-row COMMIT.
DO $$
DECLARE
  ws  text;
  r   record;
  n   int := 0;
BEGIN
  SELECT nspname INTO ws FROM pg_namespace
   WHERE nspname LIKE 'workspace\_%' ORDER BY nspname LIMIT 1;
  IF ws IS NULL THEN RAISE EXCEPTION 'no workspace_* schema found'; END IF;

  FOR r IN EXECUTE format($q$
      SELECT id FROM %I.opportunity
       WHERE "stage" = 'CUSTOMER'
         AND "amountAmountMicros" <> 0
         AND "closeDate" >= date_trunc('quarter', now())
         AND "closeDate" <  date_trunc('quarter', now()) + interval '3 months'
       ORDER BY id
    $q$, ws)
  LOOP
    -- Each statement is its own txn: zeroing the value is the DESTRUCTIVE BUG.
    EXECUTE format(
      'UPDATE %I.opportunity SET "amountAmountMicros" = 0 WHERE id = %L',
      ws, r.id);
    COMMIT;   -- procedural COMMIT → one transaction per affected deal
    n := n + 1;
  END LOOP;
  RAISE NOTICE 'BAD AUTOMATION: wiped value to 0 on % Customer-stage deals (each its own txn)', n;
END $$;

\echo '== Report AFTER the bad automation (Won revenue collapsed to 0; originals gone) =='
SELECT * FROM eter_demo.quarterly_revenue();
