-- Twenty-on-EterDB e2e fixture, the "Quarterly Revenue by Stage" report.
--
-- This mirrors, in plain SQL, the aggregate that Twenty's native Dashboard widget
-- computes ("Sum of Opportunity Amount, grouped by Stage, this quarter"), the same
-- number at the DB layer, so test/twenty-e2e.sh can assert wrong→right after the
-- destructive incident + the cohort heal.
--
-- The report is READ-DERIVED STATE, it reads opportunity rows and sums them. That
-- is the whole point of scenario B: a backup/PITR can restore the rows, but only
-- eter knows the report (and any decision taken off it) DEPENDED on the bad rows.
--
-- Opportunity money is a Twenty "currency" composite → columns:
--     amountAmountMicros  bigint   -- value * 1e6
--     amountCurrencyCode  text
-- Stage is an enum text column; closeDate is timestamptz. We resolve the workspace
-- schema dynamically and build the view over it.

\set ON_ERROR_STOP on

CREATE SCHEMA IF NOT EXISTS eter_demo;

-- Quarterly revenue by stage for the CURRENT quarter, in whole currency units.
--
-- This is a late-bound FUNCTION, not a view, on purpose: Twenty computes its
-- dashboard widget in app code, so it has no DB-level dependency on any single
-- column. Modelling the report as a view would forge a hard dependency that the
-- real app never has, and it would block Scenario A's plain DROP COLUMN. A plpgsql
-- function with a dynamic EXECUTE re-resolves the workspace schema (and the dropped
-- column) at CALL time, so DROP COLUMN "closeDate" succeeds, calling the report then
-- errors (the "app is broken" beat), and it works again once the column is recovered.
CREATE OR REPLACE FUNCTION eter_demo.quarterly_revenue()
RETURNS TABLE(quarter timestamptz, stage text, deals bigint, revenue numeric)
LANGUAGE plpgsql AS $fn$
DECLARE ws text;
BEGIN
  SELECT nspname INTO ws FROM pg_namespace
   WHERE nspname LIKE 'workspace\_%' ORDER BY nspname LIMIT 1;
  IF ws IS NULL THEN RAISE EXCEPTION 'no workspace_* schema found'; END IF;
  RETURN QUERY EXECUTE format($fmt$
    SELECT date_trunc('quarter', "closeDate")          AS quarter,
           "stage"::text                                 AS stage,
           count(*)                                      AS deals,
           round(sum("amountAmountMicros") / 1e6, 2)     AS revenue
      FROM %I.opportunity
     WHERE "closeDate" >= date_trunc('quarter', now())
       AND "closeDate" <  date_trunc('quarter', now()) + interval '3 months'
     GROUP BY 1, 2
     ORDER BY 1, 2
  $fmt$, ws);
END $fn$;

\echo '== Quarterly Revenue by Stage (current quarter) =='
SELECT * FROM eter_demo.quarterly_revenue();
