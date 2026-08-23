-- Twenty-on-EterDB demo, SCENARIO A incident: a botched migration drops a column.
--
-- The story: a "schema cleanup" migration (or an agent's ALTER TABLE) drops a column
-- that Twenty's object metadata STILL references. The column's data is gone and the
-- Opportunities view in Twenty starts erroring (the GraphQL layer selects a column
-- that no longer exists), a vivid "the app is broken" beat. eter logged the DROP
-- (eter.ddl_log), and the storage sidecar has been taking rolling ZFS snapshots all
-- along, so the column's data still is in the latest snapshot from before the DROP,
-- and we recover the column + its data by PK and the app goes healthy again.
--
-- We drop the deal's CLOSE DATE column ("closeDate"), a real, populated standard
-- column that the report reads, so its loss is both visible (app error) and
-- consequential (the quarterly report can't bucket deals). Twenty's metadata for the
-- field is left intact, which is exactly why the app errors rather than silently
-- forgetting the field.
--
-- PREREQ: tables tracked + DDL logging on; storage sidecar daemon running so a
-- recent snapshot from before the DROP exists (it snapshots every 60s; recovery picks
-- the latest one at/before the DROP's LSN). The recovery itself is driven by
-- test/twenty-e2e.sh (storage sidecar: recover-column), NOT here, this file is
-- only the destructive event.
--
-- Run:  psql "$DATABASE_URL" -f test/twenty/30-incident-drop-column.sql

\set ON_ERROR_STOP on

SELECT now() AS ddl_t0 \gset
\echo 'Pre-DROP marker (snapshot must precede this):' :'ddl_t0'

DO $$
DECLARE ws text;
BEGIN
  SELECT nspname INTO ws FROM pg_namespace
   WHERE nspname LIKE 'workspace\_%' ORDER BY nspname LIMIT 1;
  IF ws IS NULL THEN RAISE EXCEPTION 'no workspace_* schema found'; END IF;
  -- The destructive migration. eter's ddl_command_end + sql_drop event triggers
  -- record this in eter.ddl_log (object identity, statement, snapshot_lsn,
  -- needs_snapshot=true) and NOTIFY eter_ddl so the storage daemon snapshots.
  EXECUTE format('ALTER TABLE %I.opportunity DROP COLUMN "closeDate"', ws);
  RAISE NOTICE 'BOTCHED MIGRATION: dropped %.opportunity."closeDate"', ws;
END $$;

\echo '== eter.ddl_log now indexes the destructive DROP for recovery =='
SELECT command_tag, object_identity, is_destructive, needs_snapshot
  FROM eter.ddl_log
 WHERE object_identity LIKE '%opportunity%closeDate%'
 ORDER BY id DESC LIMIT 1;
