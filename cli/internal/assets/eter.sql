-- EterDB engine, SQL surface (v0.1.0, Phase 1)
-- =================================================================
-- This file is the FROZEN INTERFACE the CLI and dashboard call into:
--   eter.track / untrack / track_all
--   eter.preview_undo(txid)        -> plan { classification, ops, conflicts }
--   eter.undo(txid, mode)          -> applies compensating transaction
--   eter.select_cohort(...) / eter.undo_cohort(...)
--
-- The change history is captured one of two ways, selected by the GUC
-- `eter.capture_mode` (read by eter.track):
--   'trigger' (default), the Phase 1/2 REFERENCE ORACLE: an in-transaction AFTER
--               trigger that records before/after row images. It commits atomically
--               with the write it observes, so it cannot drift, but it is on the
--               commit hot path.
--   'sidecar' (Phase 3, opt-in), NO trigger. Tracked tables get REPLICA IDENTITY
--               FULL and join publication `eter_pub`; an out-of-process capture
--               sidecar consumes logical decoding and writes the same eter.history
--               rows off the commit path. Authoritative (the DB's own committed WAL),
--               bounded lag, never divergent. Becomes the default once the sidecar is
--               part of the standard runtime.
-- The signatures below do NOT change between modes (frozen interface). In Phase 2
-- read-dependencies are swapped from the conservative approximation here to real
-- SSI capture (eter.dependencies, populated by the eter_ssi C extension).
--
-- Safe to re-run: every object is created idempotently. `eter init` applies
-- this file; docker-compose applies it at first boot.

CREATE SCHEMA IF NOT EXISTS eter;

COMMENT ON SCHEMA eter IS 'EterDB temporal engine: change history + dependency-aware undo.';

-- ----------------------------------------------------------------------------
-- Tables
-- ----------------------------------------------------------------------------

-- One row per tracked table, with its primary-key column list (cached so the
-- capture trigger stays cheap).
CREATE TABLE IF NOT EXISTS eter.tracked (
  table_name   text PRIMARY KEY,           -- regclass::text, schema-qualified
  pk_cols      text[] NOT NULL,
  tracked_at   timestamptz NOT NULL DEFAULT now()
);

-- Append-only change log. row_before/row_after are full row images as jsonb.
CREATE TABLE IF NOT EXISTS eter.history (
  id                bigserial PRIMARY KEY,
  txid              bigint      NOT NULL,
  fingerprint       text        NOT NULL,   -- normalized statement-shape hash
  statement_sample  text,                   -- a sample of the literal statement
  table_name        text        NOT NULL,
  op                char(1)     NOT NULL CHECK (op IN ('I','U','D')),
  pk                jsonb       NOT NULL,
  row_before        jsonb,
  row_after         jsonb,
  committed_at      timestamptz NOT NULL DEFAULT clock_timestamp(),
  db_user           text        NOT NULL DEFAULT current_user,
  application_name  text,
  is_undo           boolean     NOT NULL DEFAULT false,
  undo_of           bigint,                 -- history.id this entry reverses
  tid               tid                     -- physical heap location written (ctid),
                                            -- used to match native SSI predicate-read
                                            -- locks back to logical writes (eter_ssi)
);

CREATE INDEX IF NOT EXISTS history_txid_idx        ON eter.history (txid);
CREATE INDEX IF NOT EXISTS history_table_pk_idx    ON eter.history (table_name, (pk::text));
CREATE INDEX IF NOT EXISTS history_committed_idx   ON eter.history (committed_at);
CREATE INDEX IF NOT EXISTS history_fingerprint_idx ON eter.history (fingerprint);

-- Read/write dependency graph. Phase 1 leaves this empty and preview_undo()
-- derives write-write conflicts directly from history; Phase 2's eter_ssi
-- C extension populates it with real SSI rw-antidependencies + predicate reads.
CREATE TABLE IF NOT EXISTS eter.dependencies (
  txid           bigint NOT NULL,
  depends_on     bigint NOT NULL,   -- this txid has a rw/ww edge on depends_on
  kind           text   NOT NULL CHECK (kind IN ('ww','rw')),
  detail         jsonb,
  PRIMARY KEY (txid, depends_on, kind)
);

-- Forwarded SSI read-set (Phase 3 Inc 6, "collapse the tenant floor"). In two-DB
-- mode the read-set is captured in the tenant (SSI-WAL → eter_ssi.ssi_reads,
-- keyed by reloid) and FORWARDED to the store by the capture sidecar, with the
-- reloid resolved to its canonical table_name first (the store has no tenant
-- catalog). eter.derive_from_read_set() then derives the rw graph here, in the
-- store, so the tenant keeps no dependencies/durable read-set of its own. It is
-- part of the base engine (not the eter_ssi extension), so a plain eter store has it.
CREATE TABLE IF NOT EXISTS eter.read_set (
  reader_xid  bigint  NOT NULL,
  table_name  text    NOT NULL,   -- canonical name (resolved in the tenant pre-forward)
  blk         bigint  NOT NULL,
  "off"       integer NOT NULL,
  locktype    integer NOT NULL,   -- 0=relation, 1=page, 2=tuple
  read_pk     text                -- PK of the read row (resolved eagerly at the reader's commit)
);

-- Deploy / CI markers overlaid on the flight-recorder timeline.
CREATE TABLE IF NOT EXISTS eter.markers (
  id      bigserial PRIMARY KEY,
  label   text NOT NULL,
  at      timestamptz NOT NULL DEFAULT now(),
  source  text NOT NULL DEFAULT 'manual'
);

-- Capture-sidecar bookkeeping (Phase 3). One row per replication slot tracks the
-- last commit LSN durably written into history, so a restarted sidecar resumes
-- exactly once: history rows + this row advance in the same transaction, and the
-- slot is only acknowledged afterwards. Commits at or below last_commit_lsn are
-- skipped on replay.
CREATE TABLE IF NOT EXISTS eter.capture_state (
  slot             text   PRIMARY KEY,
  last_commit_lsn  pg_lsn NOT NULL DEFAULT '0/0',
  updated_at       timestamptz NOT NULL DEFAULT now()
);

-- Undo bookkeeping (Phase 3). eter.undo records each compensating transaction
-- here so the sidecar, which cannot see the session GUCs the trigger oracle read
--, can recognise its own decoded writes and stamp history.is_undo / undo_of.
CREATE TABLE IF NOT EXISTS eter.undo_txn (
  txid     bigint PRIMARY KEY,    -- txid of the compensating transaction
  undo_of  bigint NOT NULL,       -- the target txid it reverses
  at       timestamptz NOT NULL DEFAULT now()
);

-- Schema-change log (Phase 3). DDL is LOGGED, never rewritten (no tombstones, no
-- compatibility views). Destructive DDL (DROP TABLE/COLUMN/…) is the recovery
-- INDEX: it records what was dropped, by whom, in which txid, at what LSN, the
-- storage sidecar restores the pre-event base backup, replays archived WAL to
-- just before snapshot_lsn, and extracts the lost object. needs_snapshot rows
-- are signalled to the sidecar (NOTIFY eter_ddl) so it can archive WAL through
-- the change immediately.
CREATE TABLE IF NOT EXISTS eter.ddl_log (
  id              bigserial PRIMARY KEY,
  txid            bigint      NOT NULL DEFAULT txid_current(),
  command_tag     text        NOT NULL,    -- e.g. 'DROP TABLE', 'ALTER TABLE', 'CREATE TABLE'
  object_type     text,                    -- e.g. 'table', 'table column', 'sequence'
  schema_name     text,
  object_identity text,                    -- fully-qualified identity of the object
  statement       text,                    -- sample of the originating SQL (current_query)
  is_destructive  boolean     NOT NULL DEFAULT false,
  needs_snapshot  boolean     NOT NULL DEFAULT false,
  snapshot_lsn    pg_lsn      NOT NULL DEFAULT pg_current_wal_lsn(),
  committed_at    timestamptz NOT NULL DEFAULT clock_timestamp(),
  -- Externalization (two-DB mode): event triggers can only write the TENANT, so
  -- the durable recovery index is shipped to the store by the capture sidecar's
  -- DDL-log forwarder. src_id holds the tenant row's id on the store copy (NULL on
  -- locally-originated rows), giving the forwarder an idempotent ON CONFLICT key,
  -- so a re-ship after a crash between store-insert and tenant-prune is a no-op.
  src_id          bigint
);

-- src_id was added after the table's first ship; re-applying the engine to an
-- existing DB must migrate it (CREATE TABLE IF NOT EXISTS won't add the column).
ALTER TABLE eter.ddl_log ADD COLUMN IF NOT EXISTS src_id bigint;

CREATE INDEX IF NOT EXISTS ddl_log_txid_idx    ON eter.ddl_log (txid);
CREATE INDEX IF NOT EXISTS ddl_log_object_idx  ON eter.ddl_log (object_identity);
CREATE INDEX IF NOT EXISTS ddl_log_pending_idx ON eter.ddl_log (needs_snapshot) WHERE needs_snapshot;
CREATE UNIQUE INDEX IF NOT EXISTS ddl_log_src_id_idx ON eter.ddl_log (src_id) WHERE src_id IS NOT NULL;

-- Storage-sidecar bookkeeping (Phase 3). The storage sidecar takes pg_basebackup
-- base backups of the tenant and records each one here with the LSN it captures,
-- so object recovery can pick the newest backup taken before a destructive change
-- and replay archived WAL forward from it.
CREATE TABLE IF NOT EXISTS eter.storage_snapshots (
  id          bigserial PRIMARY KEY,
  backup_name text        NOT NULL UNIQUE,  -- e.g. base-2026-07-08T12-00-00-000Z
  lsn         pg_lsn,                       -- backup END (stop) LSN: recovery targets >= this are servable
  wal_start   text,                         -- first WAL segment the backup needs (retention floor)
  kind        text        NOT NULL DEFAULT 'scheduled', -- scheduled|manual
  created_at  timestamptz NOT NULL DEFAULT now(),
  pruned_at   timestamptz                   -- set when retention removed the backup dir (audit trail)
);

-- The catalog predates the base-backup substrate (rows used to record ZFS snapshot
-- names in zfs_name); re-applying the engine to an existing DB must migrate the
-- column rename and the columns added since (CREATE TABLE IF NOT EXISTS won't).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'eter' AND table_name = 'storage_snapshots'
                AND column_name = 'zfs_name') THEN
    ALTER TABLE eter.storage_snapshots RENAME COLUMN zfs_name TO backup_name;
  END IF;
END $$;
ALTER TABLE eter.storage_snapshots ADD COLUMN IF NOT EXISTS wal_start text;
ALTER TABLE eter.storage_snapshots ADD COLUMN IF NOT EXISTS pruned_at timestamptz;

-- Audit of object-level recoveries performed by the storage sidecar.
CREATE TABLE IF NOT EXISTS eter.recovery_log (
  id              bigserial PRIMARY KEY,
  object_identity text        NOT NULL,
  object_type     text        NOT NULL,     -- table|column|rows
  from_snapshot   text        NOT NULL,
  restored_rows   bigint,
  at              timestamptz NOT NULL DEFAULT now()
);

-- Orchestrator job queue (single-entry-point era). Storage operations
-- (recover-*, snapshot, as-of) are minutes-long PITR restores; the orchestrator
-- runs them asynchronously with durable identity here (the meta store). One
-- orchestrator per store: the worker/lease columns exist for crash DETECTION,
-- not for competing workers.
CREATE TABLE IF NOT EXISTS eter.jobs (
  id           bigserial PRIMARY KEY,
  kind         text        NOT NULL,   -- snapshot|recover-table|recover-rows|recover-column|as-of
  args         jsonb       NOT NULL DEFAULT '{}'::jsonb,
  state        text        NOT NULL DEFAULT 'queued'
               CHECK (state IN ('queued','running','succeeded','failed','canceled')),
  submitted_at timestamptz NOT NULL DEFAULT now(),
  started_at   timestamptz,
  finished_at  timestamptz,
  output       jsonb,                  -- structured result (the sidecar's ETER_STORAGE_JSON stdout)
  error        text,
  progress     jsonb,                  -- last structured stderr event from the running sidecar
  worker       text,                   -- orchestrator instance id (host:pid#bootnonce)
  lease_at     timestamptz             -- heartbeat while running
);
CREATE INDEX IF NOT EXISTS jobs_active_idx ON eter.jobs (state) WHERE state IN ('queued','running');

-- ----------------------------------------------------------------------------
-- Statement fingerprinting (pg_stat_statements-style query-shape identity)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION eter._fingerprint(q text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT md5(
    trim(
      regexp_replace(
        regexp_replace(
          regexp_replace(lower(coalesce(q, '')), '''[^'']*''', '?', 'g'),  -- string literals
          '\m\d+(\.\d+)?\M', '?', 'g'),                                     -- numeric literals
        '\s+', ' ', 'g')                                                    -- collapse whitespace
    )
  );
$$;

-- Normalize a table name the way regclass renders it (so 'public.invoices'
-- and 'invoices' compare equal to the stored history.table_name). Falls back to
-- the input unchanged if it does not resolve to a relation.
CREATE OR REPLACE FUNCTION eter._relname(p text)
RETURNS text LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN p::regclass::text;
EXCEPTION WHEN others THEN
  RETURN p;
END;
$$;

-- ----------------------------------------------------------------------------
-- Capture trigger (the reference oracle)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION eter.capture()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_pk_cols   text[];
  v_pk        jsonb;
  v_before    jsonb;
  v_after     jsonb;
  v_op        char(1);
  v_tid       tid;
  v_query     text := current_query();
  v_undo_of   bigint := nullif(current_setting('eter.undo_of', true), '')::bigint;
  v_is_undo   boolean := coalesce(current_setting('eter.in_undo', true), 'off') = 'on';
  k           text;
BEGIN
  SELECT pk_cols INTO v_pk_cols FROM eter.tracked WHERE table_name = TG_RELID::regclass::text;
  IF v_pk_cols IS NULL THEN
    RETURN NULL;  -- not tracked (defensive); nothing to record
  END IF;

  IF TG_OP = 'INSERT' THEN
    v_op := 'I'; v_after := to_jsonb(NEW); v_before := NULL; v_tid := NEW.ctid;
  ELSIF TG_OP = 'UPDATE' THEN
    v_op := 'U'; v_after := to_jsonb(NEW); v_before := to_jsonb(OLD); v_tid := NEW.ctid;
  ELSE
    v_op := 'D'; v_after := NULL; v_before := to_jsonb(OLD); v_tid := OLD.ctid;
  END IF;

  -- Primary key as jsonb (taken from after-image for I/U, before-image for D).
  v_pk := '{}'::jsonb;
  FOREACH k IN ARRAY v_pk_cols LOOP
    v_pk := v_pk || jsonb_build_object(k, coalesce(v_after, v_before) -> k);
  END LOOP;

  INSERT INTO eter.history
    (txid, fingerprint, statement_sample, table_name, op, pk, row_before, row_after,
     application_name, is_undo, undo_of, tid)
  VALUES
    (txid_current(), eter._fingerprint(v_query), left(v_query, 2000),
     TG_RELID::regclass::text, v_op, v_pk, v_before, v_after,
     current_setting('application_name', true), v_is_undo, v_undo_of, v_tid);

  RETURN NULL;  -- AFTER trigger: return value ignored
END;
$$;

-- ----------------------------------------------------------------------------
-- Capture mode + publication helpers (Phase 3)
-- ----------------------------------------------------------------------------
-- How track() installs capture. EterDB captures via ONE mechanism in production:
-- an out-of-process capture sidecar reading logical decoding. The GUC below is
-- unset in normal use ('auto'), and the two named values are TEST OVERRIDES ONLY,
-- not product modes (do not document or expose them):
--   'auto' (unset, the default): sidecar capture. track() requires a live capture
--               sidecar (eter._sidecar_present()); with none it REFUSES rather than
--               silently capturing nothing.
--   'trigger': install the in-DB AFTER-trigger oracle instead. Used by
--               test/capture-diff.sh as the equivalence oracle the sidecar is
--               diffed against; never a deployment path.
--   'both': trigger AND sidecar on the same writes, so capture-diff can compare
--               them byte-for-byte.
-- ('sidecar' is accepted as an explicit synonym for the sidecar setup, bypassing
-- the auto presence check, for harnesses that stand up their own sidecar.)
CREATE OR REPLACE FUNCTION eter._capture_mode()
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT lower(coalesce(nullif(current_setting('eter.capture_mode', true), ''), 'auto'));
$$;

-- Is a live capture sidecar attached to this database? EterDB captures via logical
-- decoding, so "a sidecar is running" == a logical replication slot is currently
-- held by a consumer, with our publication in place. Tenant-local (the slot lives
-- on the tenant, even when history/cursor are externalized to the meta store), so
-- track() can check it synchronously. Precision note: this matches ANY active
-- logical slot alongside eter_pub; if EterDB ever coexists with another logical
-- consumer, tighten to the configured slot name (default 'eter_slot').
CREATE OR REPLACE FUNCTION eter._sidecar_present()
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM pg_replication_slots
                  WHERE slot_type = 'logical' AND active)
     AND EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'eter_pub');
$$;

-- Ensure the logical-decoding publication exists. Best-effort: if the current
-- role lacks privilege, the sidecar (running as a privileged role) reconciles
-- publication membership itself, so we only notice here.
CREATE OR REPLACE FUNCTION eter._ensure_publication()
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'eter_pub') THEN
    EXECUTE 'CREATE PUBLICATION eter_pub';
  END IF;
  -- PG18+: a tracked table is REPLICA IDENTITY FULL, so a STORED generated column
  -- (e.g. Twenty's searchVector) is part of the replica identity. PG then refuses
  -- UPDATE/DELETE unless that generated column is also published, so opt the
  -- publication into publishing stored generated columns. The param + the
  -- pg_publication.pubgencols catalog column are PG18+ only, so the whole check is
  -- gated behind the version and run as dynamic SQL (never parsed on PG16).
  IF current_setting('server_version_num')::int >= 180000 THEN
    EXECUTE $pg18$
      DO $d$ BEGIN
        IF COALESCE((SELECT pubgencols FROM pg_publication WHERE pubname = 'eter_pub'), 'n') <> 's' THEN
          ALTER PUBLICATION eter_pub SET (publish_generated_columns = stored);
        END IF;
      END $d$;
    $pg18$;
  END IF;
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'eter: cannot create publication eter_pub (insufficient privilege), the capture sidecar will create/reconcile it';
END;
$$;

-- ----------------------------------------------------------------------------
-- track / untrack
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION eter.track(tbl regclass)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_pk_cols text[];
  v_name    text := tbl::text;
BEGIN
  -- Resolve primary-key columns.
  SELECT array_agg(a.attname ORDER BY array_position(i.indkey, a.attnum))
    INTO v_pk_cols
  FROM pg_index i
  JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
  WHERE i.indrelid = tbl AND i.indisprimary;

  IF v_pk_cols IS NULL THEN
    RAISE EXCEPTION 'eter.track: table % has no primary key; surgical undo needs row identity. Add a PRIMARY KEY first.', v_name
      USING HINT = 'Tables without a stable key cannot be reversed unambiguously.';
  END IF;

  INSERT INTO eter.tracked (table_name, pk_cols)
  VALUES (v_name, v_pk_cols)
  ON CONFLICT (table_name) DO UPDATE SET pk_cols = EXCLUDED.pk_cols, tracked_at = now();

  -- Install capture. In production this is the sidecar path (logical decoding);
  -- with no sidecar running we REFUSE rather than mark a table tracked while
  -- capturing nothing. 'trigger'/'both' are the capture-diff test overrides.
  EXECUTE format('DROP TRIGGER IF EXISTS eter_capture ON %s', v_name);

  IF eter._capture_mode() = 'auto' AND NOT eter._sidecar_present() THEN
    RAISE EXCEPTION 'eter.track: no capture sidecar detected; cannot track %', v_name
      USING ERRCODE = 'object_not_in_prerequisite_state',
            HINT = 'EterDB captures via logical decoding. Start the control plane (capture sidecar) against this database, then track.';
  END IF;

  IF eter._capture_mode() IN ('trigger', 'both') THEN
    EXECUTE format(
      'CREATE TRIGGER eter_capture AFTER INSERT OR UPDATE OR DELETE ON %s
         FOR EACH ROW EXECUTE FUNCTION eter.capture()', v_name);
  END IF;

  IF eter._capture_mode() IN ('auto', 'sidecar', 'both') THEN
    -- Full before-images for UPDATE/DELETE require FULL identity, and the table
    -- must be a member of the decoded publication. Only ALTER when not already
    -- FULL, re-applying fires the DDL event trigger and bloats eter.ddl_log.
    IF (SELECT relreplident FROM pg_class WHERE oid = tbl) <> 'f' THEN
      EXECUTE format('ALTER TABLE %s REPLICA IDENTITY FULL', v_name);
    END IF;
    PERFORM eter._ensure_publication();
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'eter_pub')
         AND NOT EXISTS (
           SELECT 1 FROM pg_publication_rel pr
           JOIN pg_publication p ON p.oid = pr.prpubid
           WHERE p.pubname = 'eter_pub' AND pr.prrelid = tbl)
      THEN
        EXECUTE format('ALTER PUBLICATION eter_pub ADD TABLE %s', v_name);
      END IF;
    EXCEPTION WHEN insufficient_privilege THEN
      NULL;  -- sidecar reconciles membership with its privileged connection
    END;
  END IF;

  NOTIFY eter_tracked_changed;
END;
$$;

CREATE OR REPLACE FUNCTION eter.untrack(tbl regclass)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format('DROP TRIGGER IF EXISTS eter_capture ON %s', tbl::text);
  BEGIN
    IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'eter_pub')
       AND EXISTS (
         SELECT 1 FROM pg_publication_rel pr
         JOIN pg_publication p ON p.oid = pr.prpubid
         WHERE p.pubname = 'eter_pub' AND pr.prrelid = tbl)
    THEN
      EXECUTE format('ALTER PUBLICATION eter_pub DROP TABLE %s', tbl::text);
    END IF;
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  DELETE FROM eter.tracked WHERE table_name = tbl::text;
  NOTIFY eter_tracked_changed;
END;
$$;

-- Track every ordinary user table that has a primary key AND that the current
-- role owns. Ownership is what CREATE TRIGGER requires, so a table failing this
-- test could never be tracked; on managed Postgres (Supabase, RDS) the tenant
-- role shares the cluster with vendor-internal schemas it does not own, and
-- attempting them would abort the whole call.
CREATE OR REPLACE FUNCTION eter.track_all()
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE r record; n integer := 0;
BEGIN
  FOR r IN
    SELECT c.oid::regclass AS rel
    FROM pg_class c
    JOIN pg_namespace ns ON ns.oid = c.relnamespace
    WHERE c.relkind = 'r'
      AND ns.nspname NOT IN ('pg_catalog','information_schema','eter')
      AND EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = c.oid AND i.indisprimary)
      AND pg_has_role(current_user, c.relowner, 'USAGE')
  LOOP
    PERFORM eter.track(r.rel);
    n := n + 1;
  END LOOP;
  RETURN n;
END;
$$;

-- ----------------------------------------------------------------------------
-- Dependency analysis
-- ----------------------------------------------------------------------------
-- Later writes (by any other transaction) that touched the same (table, pk) as
-- the target transaction. This is the write-write half of the conflict graph,
-- computed exactly from history. Read dependencies are added in Phase 2.
CREATE OR REPLACE FUNCTION eter._ww_conflicts(target_txid bigint)
RETURNS TABLE (txid bigint) LANGUAGE sql STABLE AS $$
  WITH target AS (
    SELECT h.table_name, h.pk, max(h.id) AS max_id
    FROM eter.history h
    WHERE h.txid = target_txid AND NOT h.is_undo
    GROUP BY h.table_name, h.pk
  )
  SELECT DISTINCT later.txid
  FROM eter.history later
  JOIN target t ON t.table_name = later.table_name AND t.pk = later.pk
  WHERE later.id > t.max_id
    AND later.txid <> target_txid
    AND NOT later.is_undo;
$$;

-- ----------------------------------------------------------------------------
-- External-reference surfacing (Case 3 boundary / Act 2 seed)
--   EterDB reverses DATABASE state only. The rows a bad transaction touched
--   usually carry the foreign keys of the external side effects it triggered
--   (Stripe charge ids, message ids, ...). We surface those so the undo screen
--   can state plainly what is NOT reversed, and so a future revert orchestrator
--   has the ground-truth index into the external effects.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION eter._external_refs(p_row jsonb)
RETURNS TABLE ("column" text, value text, kind text) LANGUAGE sql IMMUTABLE AS $$
  SELECT key, val,
         CASE
           WHEN val ~ '^(ch|pi|cus|re|in|sub|seti|pm|txn|card|cs|evt)_[A-Za-z0-9]{6,}$' THEN 'stripe'
           WHEN val ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'              THEN 'email'
           ELSE 'reference'
         END AS kind
  FROM jsonb_each_text(coalesce(p_row, '{}'::jsonb)) AS e(key, val)
  WHERE val IS NOT NULL AND val <> ''
    AND (
      val ~ '^(ch|pi|cus|re|in|sub|seti|pm|txn|card|cs|evt)_[A-Za-z0-9]{6,}$'
      OR val ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
      OR key ~* '(stripe|charge|payment|paymentintent|message|webhook|external|provider|order_number|confirmation|_ref$|_ref_|refid)'
    );
$$;

-- All distinct external references across the rows a transaction touched.
CREATE OR REPLACE FUNCTION eter.external_refs(target_txid bigint)
RETURNS jsonb LANGUAGE sql STABLE AS $$
  WITH refs AS (
    SELECT DISTINCT r."column", r.value, r.kind
    FROM eter.history h
    CROSS JOIN LATERAL eter._external_refs(coalesce(h.row_after, h.row_before)) r
    WHERE h.txid = target_txid AND NOT h.is_undo
  )
  SELECT jsonb_build_object(
    'count', (SELECT count(*) FROM refs),
    'kinds', (SELECT coalesce(jsonb_object_agg(kind, c), '{}'::jsonb)
              FROM (SELECT kind, count(*) c FROM refs GROUP BY kind) k),
    'samples', (SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY s.kind, s."column"), '[]'::jsonb)
                FROM (SELECT * FROM refs LIMIT 50) s)
  );
$$;

-- All later transactions that conflict with the target: write-write (exact, from
-- history) UNION read-write (a later txn that READ what the target wrote, from the
-- persisted SSI graph in eter.dependencies, populated by eter_ssi). The rw
-- half is what no proxy/CDC layer can see and what write-write analysis misses.
-- Return columns changed (added granularity/table_name for precision surfacing),
-- so a re-run over an existing DB must drop the old signature first, CREATE OR
-- REPLACE cannot change a function's OUT-parameter row type.
DROP FUNCTION IF EXISTS eter._all_conflicts(bigint);
CREATE OR REPLACE FUNCTION eter._all_conflicts(target_txid bigint)
RETURNS TABLE (txid bigint, kind text, granularity text, table_name text) LANGUAGE sql STABLE AS $$
  -- write-write is always EXACT (the later txn provably touched the same PKs);
  -- read-write carries the captured granularity so preview can label a dependent
  -- 'exact' (precise tuple match) vs 'over-approx' (page/relation coarsening, the
  -- safe over-approximation a writer's seqscan produces).
  SELECT txid, 'ww', NULL::text, NULL::text FROM eter._ww_conflicts(target_txid)
  UNION
  SELECT d.txid, 'rw', d.detail->>'granularity', d.detail->>'table'
  FROM eter.dependencies d
  WHERE d.depends_on = target_txid AND d.kind = 'rw';
$$;

-- ----------------------------------------------------------------------------
-- preview_undo: build the compensating plan + classify clean vs dependent
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION eter.preview_undo(target_txid bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_ops        jsonb;
  v_conflicts  jsonb;
  v_conf_txids bigint[];
  v_class      text;
  v_count      int;
  v_has_rw     boolean;
  v_precision  jsonb;
BEGIN
  SELECT count(*) INTO v_count
  FROM eter.history WHERE txid = target_txid AND NOT is_undo;

  IF v_count = 0 THEN
    RAISE EXCEPTION 'eter.preview_undo: no tracked writes found for txid %', target_txid;
  END IF;

  -- Compensating operations, newest-first (apply order).
  SELECT jsonb_agg(jsonb_build_object(
            'history_id', h.id,
            'table', h.table_name,
            'original_op', h.op,
            'compensating_op', CASE h.op WHEN 'I' THEN 'DELETE' WHEN 'D' THEN 'INSERT' ELSE 'UPDATE' END,
            'pk', h.pk
         ) ORDER BY h.id DESC)
    INTO v_ops
  FROM eter.history h
  WHERE h.txid = target_txid AND NOT h.is_undo;

  -- Conflicts grouped by transaction, each labelled with PRECISION: 'exact' (a ww
  -- edge, or an rw edge matched to the exact reverted row, granularity 'tuple') vs
  -- 'over-approx' (only page/relation coarsening implicates it, the safe direction;
  -- the writer seqscanned a table the target wrote, so it MIGHT not have read the
  -- reverted rows). This turns the silent over-approximation into an actionable,
  -- labelled signal for the human/orchestrator instead of an undifferentiated
  -- "dependent". The top-level precision summary also lists the coarse (seqscanned)
  -- tables, the product surface flagging "undo is coarse here; add an index".
  WITH per AS (
    SELECT txid,
           array_agg(DISTINCT kind) AS kinds,
           bool_or(kind = 'ww') AS has_ww,
           min(eter._gran_rank(granularity)) FILTER (WHERE kind = 'rw') AS rw_rank
    FROM eter._all_conflicts(target_txid) GROUP BY txid
  ),
  cls AS (
    SELECT txid, kinds,
           CASE WHEN has_ww OR rw_rank = 1 THEN 'exact' ELSE 'over-approx' END AS precision,
           CASE rw_rank WHEN 1 THEN 'tuple' WHEN 2 THEN 'page' WHEN 3 THEN 'relation' END AS rw_granularity
    FROM per
  )
  SELECT jsonb_agg(jsonb_build_object('txid', txid, 'kinds', kinds,
                     'precision', precision, 'rw_granularity', rw_granularity) ORDER BY txid),
         array_agg(txid),
         bool_or('rw' = ANY(kinds)),
         jsonb_build_object(
           'exact_dependents',       count(*) FILTER (WHERE precision = 'exact'),
           'over_approx_dependents', count(*) FILTER (WHERE precision = 'over-approx'),
           'coarse_tables', (
             SELECT coalesce(jsonb_agg(DISTINCT table_name), '[]'::jsonb)
             FROM eter._all_conflicts(target_txid)
             WHERE kind = 'rw' AND granularity IN ('page','relation') AND table_name IS NOT NULL))
    INTO v_conflicts, v_conf_txids, v_has_rw, v_precision
  FROM cls;

  v_class := CASE WHEN v_conf_txids IS NULL OR array_length(v_conf_txids,1) IS NULL
                  THEN 'clean' ELSE 'dependent' END;

  RETURN jsonb_build_object(
    'txid', target_txid,
    'classification', v_class,
    'op_count', v_count,
    'ops', coalesce(v_ops, '[]'::jsonb),
    -- flat list of conflicting txids (back-compat) + detailed edges with kinds
    'conflicts', coalesce(to_jsonb(v_conf_txids), '[]'::jsonb),
    'conflict_edges', coalesce(v_conflicts, '[]'::jsonb),
    -- Read-dependency PRECISION: how many dependents are exact vs only surfaced by
    -- the safe seqscan/page over-approximation, and which tables drove the coarse
    -- edges ("writers seqscan these → undo is coarse here; an index makes it precise").
    'precision', coalesce(v_precision, jsonb_build_object(
       'exact_dependents', 0, 'over_approx_dependents', 0, 'coarse_tables', '[]'::jsonb)),
    -- External side effects this transaction's rows reference. EterDB reverses
    -- DB state only; these (Stripe charges, emails, ...) are NOT undone, Act 2.
    'external_refs', eter.external_refs(target_txid),
    -- Provenance: write-write is always exact; read-dependencies (rw) are
    -- present when eter_ssi has captured + drained the SSI graph (strict mode).
    'dependency_basis', CASE WHEN coalesce(v_has_rw,false)
      THEN 'write-write exact + read-write from persisted SSI graph (strict mode)'
      ELSE 'write-write exact; read-write deps require eter_ssi capture (strict mode), drained on refresh' END
  );
END;
$$;

-- ----------------------------------------------------------------------------
-- coarse_dependencies: the "undo is coarse here" product surface (observe-precision
--   lever 2). Observe captures EVERY read-write transaction's reads, and Postgres
--   coarsens SIREAD locks tuple→page→relation, so a read-write txn that SEQSCANS a
--   table makes the captured rw edges relation-level, every write to that table
--   becomes a candidate dependent (sound over-approximation, but coarse). The same
--   indexes that help performance keep these reads precise (tuple-level), so a
--   managed deployment should flag the tables read-write transactions seqscan: undo
--   dependency analysis is over-approximate there until an index makes the read
--   precise. This reads the derived graph (eter.dependencies) and reports, per
--   table, the coarse rw edges currently surfaced from it.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION eter.coarse_dependencies()
RETURNS jsonb LANGUAGE sql STABLE AS $$
  WITH coarse AS (
    SELECT coalesce(d.detail->>'table', 'reloid:' || (d.detail->>'reloid')) AS tbl,
           d.detail->>'granularity' AS gran,
           d.txid AS reader, d.depends_on AS writer
    FROM eter.dependencies d
    WHERE d.kind = 'rw' AND d.detail->>'granularity' IN ('page','relation')
  )
  SELECT jsonb_build_object(
    'coarse_edge_count', (SELECT count(*) FROM coarse),
    'tables', (
      SELECT coalesce(jsonb_agg(jsonb_build_object(
                'table', pt.tbl,
                'coarse_edges', pt.coarse_edges,
                'readers', pt.readers,
                'over_approx_writers', pt.over_approx_writers,
                'granularities', (
                  SELECT jsonb_object_agg(gg.gran, gg.c)
                  FROM (SELECT gran, count(*) AS c FROM coarse
                        WHERE coarse.tbl = pt.tbl GROUP BY gran) gg)
              ) ORDER BY pt.coarse_edges DESC), '[]'::jsonb)
      FROM (
        SELECT tbl,
               count(*)               AS coarse_edges,
               count(DISTINCT reader)  AS readers,
               count(DISTINCT writer)  AS over_approx_writers
        FROM coarse GROUP BY tbl
      ) pt),
    'hint', 'Tables listed are seqscanned by read-write transactions, so their rw '
            || 'dependencies over-approximate to table level (sound, but coarse). Add an '
            || 'index covering the columns those readers filter on to make the reads '
            || 'match precisely (tuple-level) and shrink the dependent set.'
  );
$$;

-- ----------------------------------------------------------------------------
-- Compensation primitive: reverse a single history row
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION eter._compensate(h eter.history)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_pk_cols  text[];
  v_cols     text[];
  v_setlist  text;
  v_where    text;
  v_collist  text;
  v_rows     bigint;
  v_pk       jsonb;
BEGIN
  SELECT pk_cols INTO v_pk_cols FROM eter.tracked WHERE table_name = h.table_name;
  IF v_pk_cols IS NULL THEN
    RAISE EXCEPTION 'eter: cannot reverse change on untracked table %', h.table_name;
  END IF;

  -- pk equality between target table t and the reconstructed record r
  SELECT string_agg(format('t.%I = r.%I', c, c), ' AND ') INTO v_where
  FROM unnest(v_pk_cols) c;

  -- Columns we may assign on restore: live, non-dropped, NON-GENERATED. A STORED
  -- generated column (e.g. Twenty's searchVector) is recomputed by the engine and
  -- can only be set to DEFAULT, so it must be excluded from both the re-INSERT
  -- column list and the UPDATE SET list.
  SELECT array_agg(a.attname ORDER BY a.attnum) INTO v_cols
  FROM pg_attribute a
  WHERE a.attrelid = h.table_name::regclass AND a.attnum > 0
    AND NOT a.attisdropped AND a.attgenerated = '';

  IF h.op = 'I' THEN
    -- undo an INSERT -> DELETE the row identified by its after-image
    EXECUTE format(
      'DELETE FROM %s t USING jsonb_populate_record(NULL::%s, $1) r WHERE %s',
      h.table_name, h.table_name, v_where) USING h.row_after;
    GET DIAGNOSTICS v_rows = ROW_COUNT;

  ELSIF h.op = 'D' THEN
    -- undo a DELETE -> re-INSERT the before-image (explicit non-generated columns)
    SELECT string_agg(format('%I', c), ', '), string_agg(format('r.%I', c), ', ')
      INTO v_collist, v_setlist FROM unnest(v_cols) c;
    EXECUTE format(
      'INSERT INTO %s (%s) SELECT %s FROM jsonb_populate_record(NULL::%s, $1) r',
      h.table_name, v_collist, v_setlist, h.table_name) USING h.row_before;
    GET DIAGNOSTICS v_rows = ROW_COUNT;

  ELSE
    -- undo an UPDATE -> restore every (non-generated) column from the before-image
    SELECT string_agg(format('%I = r.%I', c, c), ', ') INTO v_setlist FROM unnest(v_cols) c;

    EXECUTE format(
      'UPDATE %s t SET %s FROM jsonb_populate_record(NULL::%s, $1) r WHERE %s',
      h.table_name, v_setlist, h.table_name, v_where) USING h.row_before;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
  END IF;

  -- A compensating write that matches ZERO rows is a SILENT FAILURE: undo would
  -- report success (status=applied, reverted_ops>0) while the data stays exactly
  -- as corrupted. The common cause is a row-level-security policy whose USING
  -- clause filters the row out of the undoing role's view, so the write targets
  -- nothing without raising (found on Supabase, issue #189); a row deleted or
  -- changed out from under us does the same. For undo-of-INSERT (a DELETE) zero
  -- rows could also mean "already gone", but an RLS-bound role cannot tell the
  -- filtered row from the absent one (both are equally invisible), so we treat
  -- every zero-row compensation as a failure and abort the whole undo transaction
  -- rather than commit a false success. Run undo as the table owner or a
  -- BYPASSRLS role (see docs/managed-postgres.md) when RLS is the cause.
  IF v_rows = 0 THEN
    SELECT jsonb_object_agg(c, (CASE WHEN h.op = 'I' THEN h.row_after ELSE h.row_before END) -> c)
      INTO v_pk FROM unnest(v_pk_cols) c;
    RAISE EXCEPTION 'eter.undo: compensating % on % (pk %) matched 0 rows; nothing was reverted',
        CASE h.op WHEN 'I' THEN 'delete' WHEN 'D' THEN 'insert' ELSE 'update' END,
        h.table_name, coalesce(v_pk::text, '?')
      USING HINT = 'A row-level-security policy, a concurrent change, or a row filter is blocking the compensating write. Re-run undo as the table owner or a BYPASSRLS role (see docs/managed-postgres.md).',
            ERRCODE = 'raise_exception';
  END IF;
END;
$$;

-- ----------------------------------------------------------------------------
-- undo: apply the compensating transaction for one txid
-- ----------------------------------------------------------------------------
-- mode:
--   'clean_only' (default) -> refuse if dependent transactions exist
--   'cascade'              -> also reverse the dependent transactions (newest first)
--   'targeted'             -> reverse only this txid, leave dependents (may diverge)
CREATE OR REPLACE FUNCTION eter.undo(target_txid bigint, mode text DEFAULT 'clean_only')
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_plan       jsonb;
  v_class      text;
  v_conflicts  bigint[];
  v_applied    int := 0;
  v_also       int := 0;
  h            eter.history;
  dep_txid     bigint;
BEGIN
  IF mode NOT IN ('clean_only','cascade','targeted') THEN
    RAISE EXCEPTION 'eter.undo: invalid mode %, expected clean_only|cascade|targeted', mode;
  END IF;

  v_plan  := eter.preview_undo(target_txid);
  v_class := v_plan ->> 'classification';
  SELECT array_agg((x)::bigint) INTO v_conflicts
  FROM jsonb_array_elements_text(v_plan -> 'conflicts') x;

  IF v_class = 'dependent' AND mode = 'clean_only' THEN
    RAISE EXCEPTION 'eter.undo: txid % has dependent transactions %, refusing in clean_only mode',
      target_txid, v_conflicts
      USING HINT = 'Re-run with mode => ''cascade'' or ''targeted'' after reviewing the conflict.',
            ERRCODE = 'raise_exception';
  END IF;

  -- Tag everything written during this call as undo activity. The trigger oracle
  -- reads these session GUCs; the capture sidecar instead joins decoded commits
  -- against eter.undo_txn (written below) to stamp is_undo / undo_of.
  PERFORM set_config('eter.in_undo', 'on', true);
  PERFORM set_config('eter.undo_of', target_txid::text, true);
  INSERT INTO eter.undo_txn (txid, undo_of)
  VALUES (txid_current(), target_txid)
  ON CONFLICT (txid) DO NOTHING;

  -- Cascade: reverse dependents first (newest transaction first), each itself
  -- analysed for its own dependents to avoid reverting blind.
  IF mode = 'cascade' AND v_conflicts IS NOT NULL THEN
    FOR dep_txid IN
      SELECT DISTINCT txid FROM eter.history
      WHERE txid = ANY(v_conflicts) AND NOT is_undo
      ORDER BY txid DESC
    LOOP
      FOR h IN SELECT * FROM eter.history
               WHERE txid = dep_txid AND NOT is_undo ORDER BY id DESC LOOP
        PERFORM eter._compensate(h);
        v_also := v_also + 1;
      END LOOP;
    END LOOP;
  END IF;

  -- Reverse the target transaction itself, newest row first.
  FOR h IN SELECT * FROM eter.history
           WHERE txid = target_txid AND NOT is_undo ORDER BY id DESC LOOP
    PERFORM eter._compensate(h);
    v_applied := v_applied + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'txid', target_txid,
    'mode', mode,
    'classification', v_class,
    'reverted_ops', v_applied,
    'cascaded_ops', v_also,
    'status', 'applied'
  );
END;
$$;

-- ----------------------------------------------------------------------------
-- undo_rows: apply a compensating transaction from EXTERNALLY-SUPPLIED history
-- ----------------------------------------------------------------------------
-- Same reversal as eter.undo, but the history rows + the classification plan
-- are passed in (p_rows, p_plan) instead of read from eter.history. This is
-- the cross-DB seam: when durable history is in a separate EterDB-owned
-- store, the revert engine (CLI/server) fetches the plan + rows from that store
-- and calls this in the TENANT DB, so the compensating DML still commits in ONE
-- tenant transaction (atomicity preserved). p_rows is a jsonb array of full
-- eter.history row images (target txn ∪ its conflicts); p_plan is the
-- eter.preview_undo() output computed against the store.
--
-- Deliberately does NOT write eter.undo_txn (that table lives with history in
-- the store); the caller records the returned apply_txid there post-commit. The
-- dependent-refusal RAISE matches eter.undo verbatim so CLI exit codes are
-- unchanged. eter.undo / preview_undo signatures are untouched (this is
-- additive); the co-located path (ETER_META_URL unset) still uses eter.undo.
CREATE OR REPLACE FUNCTION eter.undo_rows(
  p_target_txid bigint,
  p_mode        text,
  p_plan        jsonb,
  p_rows        jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_class      text := p_plan ->> 'classification';
  v_conflicts  bigint[];
  v_applied    int := 0;
  v_also       int := 0;
  h            eter.history;
  dep_txid     bigint;
BEGIN
  IF p_mode NOT IN ('clean_only','cascade','targeted') THEN
    RAISE EXCEPTION 'eter.undo: invalid mode %, expected clean_only|cascade|targeted', p_mode;
  END IF;

  SELECT array_agg((x)::bigint) INTO v_conflicts
  FROM jsonb_array_elements_text(p_plan -> 'conflicts') x;

  IF v_class = 'dependent' AND p_mode = 'clean_only' THEN
    RAISE EXCEPTION 'eter.undo: txid % has dependent transactions %, refusing in clean_only mode',
      p_target_txid, v_conflicts
      USING HINT = 'Re-run with mode => ''cascade'' or ''targeted'' after reviewing the conflict.',
            ERRCODE = 'raise_exception';
  END IF;

  -- Tag undo activity for any local trigger oracle (no-op in sidecar mode, which
  -- is the only mode that reaches this function).
  PERFORM set_config('eter.in_undo', 'on', true);
  PERFORM set_config('eter.undo_of', p_target_txid::text, true);

  -- Cascade: reverse dependents first (newest txn first), from the supplied rows.
  IF p_mode = 'cascade' AND v_conflicts IS NOT NULL THEN
    FOR dep_txid IN
      SELECT DISTINCT (r->>'txid')::bigint AS txid
      FROM jsonb_array_elements(p_rows) r
      WHERE (r->>'txid')::bigint = ANY(v_conflicts)
        AND NOT coalesce((r->>'is_undo')::boolean, false)
      ORDER BY txid DESC
    LOOP
      FOR h IN
        SELECT (jsonb_populate_record(NULL::eter.history, r)).*
        FROM jsonb_array_elements(p_rows) r
        WHERE (r->>'txid')::bigint = dep_txid
          AND NOT coalesce((r->>'is_undo')::boolean, false)
        ORDER BY (r->>'id')::bigint DESC
      LOOP
        PERFORM eter._compensate(h);
        v_also := v_also + 1;
      END LOOP;
    END LOOP;
  END IF;

  -- Reverse the target transaction itself, newest row first.
  FOR h IN
    SELECT (jsonb_populate_record(NULL::eter.history, r)).*
    FROM jsonb_array_elements(p_rows) r
    WHERE (r->>'txid')::bigint = p_target_txid
      AND NOT coalesce((r->>'is_undo')::boolean, false)
    ORDER BY (r->>'id')::bigint DESC
  LOOP
    PERFORM eter._compensate(h);
    v_applied := v_applied + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'txid', p_target_txid,
    'mode', p_mode,
    'classification', v_class,
    'reverted_ops', v_applied,
    'cascaded_ops', v_also,
    'status', 'applied',
    'apply_txid', txid_current()
  );
END;
$$;

-- ----------------------------------------------------------------------------
-- Cohort selection + reversal
--   Select the set of transactions matching time × table × statement-shape ×
--   optional predicate (a jsonb containment match against the after-image).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION eter.select_cohort(
  p_table       text DEFAULT NULL,
  p_fingerprint text DEFAULT NULL,
  p_from        timestamptz DEFAULT NULL,
  p_to          timestamptz DEFAULT NULL,
  p_predicate   jsonb DEFAULT NULL
)
RETURNS TABLE (txid bigint, ops bigint, first_at timestamptz, last_at timestamptz, fingerprint text)
LANGUAGE sql STABLE AS $$
  SELECT h.txid, count(*) AS ops, min(h.committed_at), max(h.committed_at),
         min(h.fingerprint) AS fingerprint
  FROM eter.history h
  WHERE NOT h.is_undo
    AND (p_table       IS NULL OR h.table_name = eter._relname(p_table))
    AND (p_fingerprint IS NULL OR h.fingerprint = p_fingerprint)
    AND (p_from        IS NULL OR h.committed_at >= p_from)
    AND (p_to          IS NULL OR h.committed_at <= p_to)
    AND (p_predicate   IS NULL OR h.row_after @> p_predicate)
  GROUP BY h.txid
  ORDER BY min(h.committed_at);
$$;

CREATE OR REPLACE FUNCTION eter.preview_cohort(
  p_table text DEFAULT NULL, p_fingerprint text DEFAULT NULL,
  p_from timestamptz DEFAULT NULL, p_to timestamptz DEFAULT NULL, p_predicate jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_txids   bigint[];
  v_clean   int := 0;
  v_dep     int := 0;
  t         bigint;
BEGIN
  SELECT array_agg(txid) INTO v_txids
  FROM eter.select_cohort(p_table,p_fingerprint,p_from,p_to,p_predicate);

  IF v_txids IS NULL THEN
    RETURN jsonb_build_object('txn_count',0,'clean',0,'dependent',0,'txids','[]'::jsonb);
  END IF;

  FOREACH t IN ARRAY v_txids LOOP
    IF (eter.preview_undo(t) ->> 'classification') = 'clean'
      THEN v_clean := v_clean + 1; ELSE v_dep := v_dep + 1; END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'txn_count', array_length(v_txids,1),
    'clean', v_clean,
    'dependent', v_dep,
    'txids', to_jsonb(v_txids)
  );
END;
$$;

CREATE OR REPLACE FUNCTION eter.undo_cohort(
  p_table text DEFAULT NULL, p_fingerprint text DEFAULT NULL,
  p_from timestamptz DEFAULT NULL, p_to timestamptz DEFAULT NULL, p_predicate jsonb DEFAULT NULL,
  mode text DEFAULT 'clean_only')
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_txids   bigint[];
  t         bigint;
  v_done    int := 0;
  v_skipped bigint[] := '{}';
BEGIN
  SELECT array_agg(txid ORDER BY txid DESC) INTO v_txids
  FROM eter.select_cohort(p_table,p_fingerprint,p_from,p_to,p_predicate);

  IF v_txids IS NULL THEN
    RETURN jsonb_build_object('reverted_txns',0,'skipped_dependent',0,
                              'skipped_txids','[]'::jsonb,'status','empty','mode',mode);
  END IF;

  -- Reverse newest transactions first so within-cohort dependencies resolve.
  -- In clean_only, a transaction entangled with a LATER write (a legitimate
  -- re-edit of the same row) must not be blindly reverted, that would clobber
  -- the newer value. So skip those and surface them, instead of aborting the
  -- whole cohort on the first one: revert what is safe, report what needs review.
  -- cascade/targeted reverse everything (the operator has opted into the graph).
  FOREACH t IN ARRAY v_txids LOOP
    IF mode = 'clean_only'
       AND (eter.preview_undo(t) ->> 'classification') = 'dependent' THEN
      v_skipped := v_skipped || t;
      CONTINUE;
    END IF;
    PERFORM eter.undo(t, mode);
    v_done := v_done + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'reverted_txns', v_done,
    'skipped_dependent', coalesce(array_length(v_skipped,1),0),
    'skipped_txids', to_jsonb(v_skipped),
    'status','applied','mode',mode);
END;
$$;

-- ----------------------------------------------------------------------------
-- Markers (deploy/CI overlay)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION eter.mark(p_label text, p_source text DEFAULT 'manual', p_at timestamptz DEFAULT now())
RETURNS bigint LANGUAGE sql AS $$
  INSERT INTO eter.markers (label, source, at) VALUES (p_label, p_source, p_at) RETURNING id;
$$;

-- ----------------------------------------------------------------------------
-- Store-side read-dependency derivation (Phase 3 Inc 6)
--   Derive the rw graph from the FORWARDED read-set, in the store. Mirrors
--   eter_ssi.derive_dependencies but matches the relation by canonical
--   table_name (the store has no catalog to map a tenant reloid) and has no ctid
--   to match on (logical-decoding writes carry none), so page/relation targets
--   over-approximate to table level, the safe direction (extra conflict reviews,
--   never a missed dependency). The reader's 32-bit xid is resolved to a 64-bit
--   txid via its own tracked writes in store history.
-- ----------------------------------------------------------------------------

-- Comparable PK text for a write in eter.history: tracked PK column values in
-- key order, comma-joined, matching the read_pk the tenant resolved at read time.
-- Base-engine helper so the store (which has no eter_ssi extension) can derive.
-- Deliberately NOT named eter._pk_text: the eter_ssi extension defines a
-- function of that name, and the engine defining the same name would make
-- CREATE EXTENSION fail ("function is not a member of extension"). Same body,
-- distinct name, zero collision regardless of extension-install freshness.
-- Granularity precision rank (lower = more precise / more trustworthy evidence):
-- a 'tuple' edge means the reader provably read the exact reverted row; 'page' /
-- 'relation' are over-approximations (the safe direction, extra reviews, never a
-- missed dependency). Shared by both derives (most-precise-wins) and preview
-- (exact vs over-approx labelling). Unknown/NULL ranks as coarsest.
CREATE OR REPLACE FUNCTION eter._gran_rank(p_gran text)
RETURNS integer LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_gran WHEN 'tuple' THEN 1 WHEN 'page' THEN 2 WHEN 'relation' THEN 3 ELSE 4 END;
$$;

CREATE OR REPLACE FUNCTION eter._read_set_pk(p_table text, p_pk jsonb)
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT string_agg(p_pk ->> u.col, ',' ORDER BY u.ord)
  FROM eter.tracked t, unnest(t.pk_cols) WITH ORDINALITY AS u(col, ord)
  WHERE t.table_name = p_table;
$$;

CREATE OR REPLACE FUNCTION eter.derive_from_read_set() RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE n integer;
BEGIN
  -- Precompute each writer's comparable PK text ONCE (a MATERIALIZED CTE), not
  -- once per (read × write) pair: the old inline eter._read_set_pk(w...) in the
  -- join predicate, wrapped in an OR, forced a nested loop with a subquery-bearing
  -- function call per pair, O(reads × writes), which does not survive the per-row
  -- read-sets the observe harvest now produces (a single sizeable read is
  -- thousands of rows). Split by match kind so the precise case is a hash join on
  -- (table_name, pk_text); same edges, same over-approximation, just set-based.
  INSERT INTO eter.dependencies (txid, depends_on, kind, detail)
  WITH w AS MATERIALIZED (
    SELECT h.txid, h.table_name, h.committed_at,
           eter._read_set_pk(h.table_name, h.pk) AS pk_text
    FROM eter.history h WHERE NOT h.is_undo
  ),
  r AS MATERIALIZED (
    SELECT DISTINCT ON (xid32) (h.txid % 4294967296)::bigint AS xid32, h.txid, h.committed_at
    FROM eter.history h WHERE NOT h.is_undo ORDER BY xid32, h.txid
  ),
  edges AS (
    -- precise tuple match (PK resolved at read time): hash join on (table, pk).
    -- TIME-ORDER guard (r.committed_at >= w.committed_at): a reader cannot have read
    -- a write that committed AFTER it (READ COMMITTED never sees uncommitted data),
    -- so drop reader-before-writer pairs, they are impossible reads, and keeping
    -- them let a recent scan spuriously "depend on" a table's entire write history.
    SELECT r.txid AS rtxid, w.txid AS wtxid, s.table_name, s.blk, s."off", s.read_pk, 'tuple' AS gran
    FROM eter.read_set s
    JOIN w ON w.table_name = s.table_name AND w.pk_text = s.read_pk
    JOIN r ON r.xid32 = s.reader_xid
    WHERE s.locktype = 2 AND s.read_pk IS NOT NULL AND w.txid <> r.txid
          AND r.committed_at >= w.committed_at
    UNION ALL
    -- over-approximate to table level: unresolved tuple PK, or page/relation lock
    -- (the store has no ctid to pin a block), the safe direction.
    SELECT r.txid, w.txid, s.table_name, s.blk, s."off", s.read_pk,
           CASE s.locktype WHEN 1 THEN 'page' WHEN 0 THEN 'relation' ELSE 'tuple' END
    FROM eter.read_set s
    JOIN w ON w.table_name = s.table_name
    JOIN r ON r.xid32 = s.reader_xid
    WHERE ((s.locktype = 2 AND s.read_pk IS NULL) OR s.locktype = 1 OR s.locktype = 0)
          AND w.txid <> r.txid
          AND r.committed_at >= w.committed_at
  )
  -- Keep the MOST PRECISE evidence per (reader,target): tuple < page < relation.
  -- A single (reader,target) pair can yield several edges (e.g. a precise tuple
  -- match AND a relation over-approximation when the reader both indexed-read the
  -- exact row and seqscanned the table). The stored granularity is what preview's
  -- precision label reads, so it must be deterministic: DISTINCT ON keeps the
  -- best-ranked row per pair instead of letting ON CONFLICT keep an arbitrary one.
  SELECT DISTINCT ON (rtxid, wtxid) rtxid, wtxid, 'rw',
         jsonb_build_object('table', table_name, 'block', blk, 'offset', "off",
                            'pk', read_pk, 'granularity', gran)
  FROM edges
  ORDER BY rtxid, wtxid, eter._gran_rank(gran)
  -- Upgrade an already-stored coarse edge if a later derive finds a precise match
  -- (dependencies accumulate across runs; never downgrade, precise is always more
  -- informative and the safe direction is unchanged).
  ON CONFLICT (txid, depends_on, kind) DO UPDATE
    SET detail = EXCLUDED.detail
    WHERE eter._gran_rank(EXCLUDED.detail->>'granularity')
        < eter._gran_rank(eter.dependencies.detail->>'granularity');
  GET DIAGNOSTICS n = ROW_COUNT;
  -- A reader always reads an already-committed writer, so every forwarded read has
  -- had its chance to match; clear the staging so it does not grow unboundedly.
  TRUNCATE eter.read_set;
  RETURN n;
END;
$$;

-- ----------------------------------------------------------------------------
-- Scope/age the DERIVED read-dependency graph (observe-precision lever 4).
--   rw read-edges (eter.dependencies kind='rw') and the forwarded read-set
--   (eter.read_set) are DERIVED, regenerable artifacts, NOT source history. So
--   unlike eter.history (never pruned: the never-prune-source rule) they may be
--   retention-scoped. A long-lived observe deployment accrues an rw edge for every
--   read-write transaction that ever ran, but the graph only needs to classify
--   recent reverts, so old rw edges can be aged out without weakening any
--   guarantee: ww edges (derived from history) and history itself are untouched,
--   and a months-old surgical undo still works off history alone (preview_undo
--   computes clean / ww-dependent / cascade from history; rw edges only ADD
--   read-derived dependents on top).
--
--   An rw edge's age is its READER's commit time. The reader is the dependent
--   txid (eter.dependencies.txid), and a reader is itself a writer (read-only txns
--   get no xid and never appear), so it has a committed_at in history. Edges whose
--   reader last committed before now()-p_keep are removed; pending eter.read_set
--   rows for those readers are dropped too (matched on the 32-bit reader_xid, and
--   only when EVERY txid sharing that xid is old, conservative against xid reuse).
--   Returns {cutoff, deleted_rw_edges, deleted_read_set}. Safe to call repeatedly
--   (e.g. from a maintenance job); a no-op when nothing is old enough.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION eter.age_read_edges(p_keep interval)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_cutoff timestamptz := now() - p_keep;
  v_edges  bigint;
  v_reads  bigint;
BEGIN
  IF p_keep IS NULL OR p_keep < interval '0' THEN
    RAISE EXCEPTION 'eter.age_read_edges: p_keep must be a non-negative interval';
  END IF;

  -- rw edges whose READER (dependencies.txid) last committed before the cutoff.
  -- ww edges are never considered, they are the history-derived backbone.
  WITH reader_age AS (
    SELECT txid, max(committed_at) AS last_at
    FROM eter.history WHERE NOT is_undo GROUP BY txid
  ),
  del AS (
    DELETE FROM eter.dependencies d
    USING reader_age ra
    WHERE d.kind = 'rw' AND ra.txid = d.txid AND ra.last_at < v_cutoff
    RETURNING 1
  )
  SELECT count(*) INTO v_edges FROM del;

  -- Forwarded read-set rows for readers older than the cutoff. read_set carries
  -- only the 32-bit reader_xid, so group history by xid32 and prune only when the
  -- newest txid sharing that xid is itself old (max < cutoff), never drop a recent
  -- reader's reads because an unrelated old txn happened to reuse its xid.
  WITH reader_age AS (
    SELECT (txid % 4294967296)::bigint AS xid32, max(committed_at) AS last_at
    FROM eter.history WHERE NOT is_undo GROUP BY 1
  ),
  del AS (
    DELETE FROM eter.read_set s
    USING reader_age ra
    WHERE ra.xid32 = s.reader_xid AND ra.last_at < v_cutoff
    RETURNING 1
  )
  SELECT count(*) INTO v_reads FROM del;

  RETURN jsonb_build_object('cutoff', v_cutoff,
                            'deleted_rw_edges', v_edges,
                            'deleted_read_set', v_reads);
END;
$$;

-- ----------------------------------------------------------------------------
-- DDL logging (Phase 3), log destructive schema changes, never rewrite them.
--   Two event triggers: ddl_command_end records every CREATE/ALTER (the audit
--   trail); sql_drop records dropped objects (the destructive recovery index).
--   EterDB's own schema is never logged. Recovery of the dropped object's
--   DATA is the storage sidecar's job (restore the pre-event base backup, replay
--   archived WAL to just before snapshot_lsn, extract), the event triggers can't
--   read data that is already gone, which is exactly why recovery comes from
--   retained backups + WAL, not in-DB tombstones.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION eter._log_ddl_end()
RETURNS event_trigger LANGUAGE plpgsql AS $$
DECLARE r record;
BEGIN
  FOR r IN SELECT * FROM pg_event_trigger_ddl_commands() LOOP
    -- Skip EterDB's own engine objects and anything in pg_catalog.
    IF r.schema_name IS NOT DISTINCT FROM 'eter' OR r.schema_name = 'pg_catalog' THEN
      CONTINUE;
    END IF;
    INSERT INTO eter.ddl_log
      (command_tag, object_type, schema_name, object_identity, statement, is_destructive, needs_snapshot)
    VALUES
      (r.command_tag, r.object_type, r.schema_name, r.object_identity,
       left(current_query(), 2000), false, false);
    -- TRUNCATE fires neither sql_drop NOR pg_event_trigger_ddl_commands(), so it can
    -- only be captured by a per-table AFTER TRUNCATE trigger. Attach that to every
    -- newly-created ordinary table so truncate recovery covers tables made after
    -- DDL logging was enabled.
    IF r.command_tag = 'CREATE TABLE' AND r.object_type = 'table' THEN
      PERFORM eter._attach_truncate_trigger(r.objid::regclass);

      -- Auto-track the new table so `track everything` stays true as the schema
      -- grows. Best-effort: only owned tables with a PK, and NEVER break the
      -- user's CREATE TABLE: a missing sidecar (track() refuses) or any other
      -- failure is swallowed; the table simply stays untracked until a manual
      -- track once capture is available.
      IF eter._auto_track_enabled()
         AND pg_has_role(current_user, (SELECT relowner FROM pg_class WHERE oid = r.objid), 'USAGE')
         AND EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = r.objid AND i.indisprimary)
      THEN
        BEGIN
          PERFORM eter.track(r.objid::regclass);
        EXCEPTION WHEN OTHERS THEN
          NULL;
        END;
      END IF;
    END IF;
  END LOOP;
END;
$$;

-- Per-table AFTER TRUNCATE trigger: TRUNCATE erases rows but drops no object, so
-- it is invisible to the DDL event triggers above. This statement-level trigger
-- records the truncate as a recoverable event (is_destructive + needs_snapshot)
-- with the table identity + the current LSN. Because it fires INSIDE the truncate's
-- transaction (before commit), storage row recovery can replay archived WAL to just
-- before that LSN, leaving the truncate uncommitted (rolled back → rows intact),
-- exactly how drop recovery works.
CREATE OR REPLACE FUNCTION eter._log_truncate()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO eter.ddl_log
    (command_tag, object_type, schema_name, object_identity, statement, is_destructive, needs_snapshot)
  VALUES
    ('TRUNCATE TABLE', 'table', TG_TABLE_SCHEMA,
     TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME, left(current_query(), 2000), true, true);
  PERFORM pg_notify('eter_ddl', 'truncate');
  RETURN NULL;
END;
$$;

-- Attach eter._log_truncate() to rel unless it is an EterDB/system/temp table or
-- already carries the trigger. Idempotent.
CREATE OR REPLACE FUNCTION eter._attach_truncate_trigger(rel regclass)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE nsp text;
BEGIN
  SELECT n.nspname INTO nsp
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE c.oid = rel;
  IF nsp IS NULL OR nsp IN ('eter', 'pg_catalog', 'information_schema')
     OR nsp LIKE 'pg_temp%' OR nsp LIKE 'pg_toast%' THEN
    RETURN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger
                  WHERE tgrelid = rel AND tgname = 'eter_truncate_log' AND NOT tgisinternal) THEN
    EXECUTE format(
      'CREATE TRIGGER eter_truncate_log AFTER TRUNCATE ON %s FOR EACH STATEMENT EXECUTE FUNCTION eter._log_truncate()',
      rel::text);
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION eter._log_sql_drop()
RETURNS event_trigger LANGUAGE plpgsql AS $$
DECLARE r record;
BEGIN
  FOR r IN SELECT * FROM pg_event_trigger_dropped_objects() LOOP
    -- Only original (top-level), non-temporary, non-eter drops are recovery
    -- events; cascade/internal drops and our own schema are ignored.
    IF NOT r.original
       OR r.is_temporary
       OR r.schema_name IS NOT DISTINCT FROM 'eter'
       OR r.schema_name = 'pg_catalog' THEN
      CONTINUE;
    END IF;
    INSERT INTO eter.ddl_log
      (command_tag, object_type, schema_name, object_identity, statement, is_destructive, needs_snapshot)
    VALUES
      (tg_tag, r.object_type, r.schema_name, r.object_identity,
       left(current_query(), 2000), true, true);
  END LOOP;
  -- Signal the storage sidecar to snapshot around the destructive change.
  PERFORM pg_notify('eter_ddl', 'drop');
END;
$$;

-- Install / remove the DDL-logging event triggers (DB-wide; needs the engine
-- owner). Opt-in this increment, alongside sidecar capture; idempotent.
CREATE OR REPLACE FUNCTION eter.enable_ddl_logging()
RETURNS void LANGUAGE plpgsql AS $$
DECLARE c record;
BEGIN
  DROP EVENT TRIGGER IF EXISTS eter_ddl_end;
  DROP EVENT TRIGGER IF EXISTS eter_sql_drop;
  CREATE EVENT TRIGGER eter_ddl_end  ON ddl_command_end EXECUTE FUNCTION eter._log_ddl_end();
  CREATE EVENT TRIGGER eter_sql_drop ON sql_drop        EXECUTE FUNCTION eter._log_sql_drop();
  -- TRUNCATE is invisible to event triggers, so attach the per-table AFTER TRUNCATE
  -- trigger to every existing ordinary table (new tables get it via _log_ddl_end).
  FOR c IN
    SELECT cl.oid FROM pg_class cl JOIN pg_namespace n ON n.oid = cl.relnamespace
     WHERE cl.relkind IN ('r', 'p')
       AND n.nspname NOT IN ('eter', 'pg_catalog', 'information_schema')
       AND n.nspname NOT LIKE 'pg_temp%' AND n.nspname NOT LIKE 'pg_toast%'
       -- Only tables we own; CREATE TRIGGER needs ownership and managed
       -- Postgres puts vendor-owned schemas in the same database.
       AND pg_has_role(current_user, cl.relowner, 'USAGE')
  LOOP
    PERFORM eter._attach_truncate_trigger(c.oid::regclass);
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION eter.disable_ddl_logging()
RETURNS void LANGUAGE plpgsql AS $$
DECLARE t record;
BEGIN
  DROP EVENT TRIGGER IF EXISTS eter_ddl_end;
  DROP EVENT TRIGGER IF EXISTS eter_sql_drop;
  -- Remove the per-table AFTER TRUNCATE triggers we installed.
  FOR t IN
    SELECT tg.tgrelid::regclass::text AS rel FROM pg_trigger tg
     WHERE tg.tgname = 'eter_truncate_log' AND NOT tg.tgisinternal
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS eter_truncate_log ON %s', t.rel);
  END LOOP;
END;
$$;

-- ----------------------------------------------------------------------------
-- Per-database capture-mode override (TEST-ONLY)
--   The engine default is 'auto' (sidecar capture, refuse without one). This
--   primitive pins a per-database override; only 'trigger'/'both' have a use,
--   for test/capture-diff.sh's oracle. Production never calls this. ALTER
--   DATABASE SET applies to NEW sessions.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION eter.set_capture_default(p_mode text)
RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  IF lower(p_mode) NOT IN ('auto','trigger','sidecar','both') THEN
    RAISE EXCEPTION 'eter.set_capture_default: invalid mode %, expected auto|trigger|sidecar|both', p_mode;
  END IF;
  EXECUTE format('ALTER DATABASE %I SET eter.capture_mode = %L', current_database(), lower(p_mode));
  RETURN lower(p_mode);
END;
$$;

-- Auto-track: when on, eter._log_ddl_end() tracks every newly-created owned PK
-- table, so `track everything` stays true as the schema grows. `eter init` turns
-- this on (unless --no-track). Persisted per-database (applies to new sessions),
-- read by the DDL event trigger regardless of which role runs the CREATE.
CREATE OR REPLACE FUNCTION eter.set_auto_track(p_on boolean)
RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format('ALTER DATABASE %I SET eter.auto_track = %L',
                 current_database(), CASE WHEN p_on THEN 'on' ELSE 'off' END);
  RETURN p_on;
END;
$$;

CREATE OR REPLACE FUNCTION eter._auto_track_enabled()
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT lower(coalesce(nullif(current_setting('eter.auto_track', true), ''), 'off')) = 'on';
$$;

-- One-shot capture setup for `eter init`: turn on auto-track, enable DDL logging
-- (so new tables auto-track), and track everything trackable right now. All
-- best-effort so init NEVER fails: no capture sidecar yet -> nothing is tracked
-- and reported as pending; no privilege for event triggers -> ddl_logging false.
-- track_all()'s no-sidecar refusal is all-or-nothing (the check is global), so
-- `tracked` is either every owned PK table or zero.
CREATE OR REPLACE FUNCTION eter.init_capture(p_auto_track boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_tracked int := 0; v_pending int := 0; v_ddl boolean := false;
BEGIN
  IF NOT p_auto_track THEN
    PERFORM eter.set_auto_track(false);
    RETURN jsonb_build_object('tracked',0,'pending',0,'auto_track',false,'ddl_logging',false);
  END IF;

  PERFORM eter.set_auto_track(true);
  BEGIN
    PERFORM eter.enable_ddl_logging();
    v_ddl := true;
  EXCEPTION WHEN OTHERS THEN
    v_ddl := false;  -- event triggers need elevated privilege on some managed PG
  END;
  BEGIN
    v_tracked := eter.track_all();
  EXCEPTION WHEN object_not_in_prerequisite_state THEN
    v_tracked := 0;  -- no capture sidecar yet; tables stay pending
  END;

  SELECT count(*) INTO v_pending
  FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
  WHERE c.relkind = 'r'
    AND ns.nspname NOT IN ('pg_catalog','information_schema','eter')
    AND EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = c.oid AND i.indisprimary)
    AND pg_has_role(current_user, c.relowner, 'USAGE')
    AND NOT EXISTS (SELECT 1 FROM eter.tracked t WHERE t.table_name = c.oid::regclass::text);

  RETURN jsonb_build_object('tracked',v_tracked,'pending',v_pending,
                            'auto_track',true,'ddl_logging',v_ddl);
END;
$$;

-- ----------------------------------------------------------------------------
-- Interim in-DB hardening (Phase 3, "Externalize durable metadata")
--   While any eter.* metadata is still in the tenant DB, lock it away from
--   the tenant role entirely: in the externalized/sidecar model the tenant never
--   touches eter, the sidecars + drain worker write it as a privileged role,
--   and the operator's CLI/server runs preview/undo privileged, so REVOKE ALL
--   (including schema USAGE) is the correct, clean boundary. An event trigger
--   also blocks any non-owner ALTER/DROP of a eter object (belt-and-suspenders
--   over object ownership). Viable because the hosted model (Phase 4) gives
--   tenants a SCOPED connection, not superuser. Externalizing the metadata
--   removes the tamper surface entirely; this is the interim step for deployments
--   still holding some eter.* in-tenant. (Assumes sidecar capture, the tenant
--   does no in-transaction eter writes; do NOT harden a trigger-mode DB.)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION eter._block_eter_ddl()
RETURNS event_trigger LANGUAGE plpgsql AS $$
DECLARE
  v_owner text := pg_get_userbyid((SELECT nspowner FROM pg_namespace WHERE nspname='eter'));
  r record;
BEGIN
  -- The privileged owner (engine install, sidecars, runtime) manages eter
  -- freely; superusers are never event-trigger-constrained anyway.
  IF current_user = v_owner THEN RETURN; END IF;

  IF TG_EVENT = 'sql_drop' THEN
    FOR r IN SELECT * FROM pg_event_trigger_dropped_objects() WHERE schema_name = 'eter' LOOP
      RAISE EXCEPTION 'eter: role % may not DROP EterDB object %', current_user, r.object_identity
        USING ERRCODE = 'insufficient_privilege',
              HINT = 'EterDB metadata is tamper-protected; contact the operator.';
    END LOOP;
  ELSE
    FOR r IN SELECT * FROM pg_event_trigger_ddl_commands() WHERE schema_name = 'eter' LOOP
      RAISE EXCEPTION 'eter: role % may not alter EterDB object %', current_user, r.object_identity
        USING ERRCODE = 'insufficient_privilege',
              HINT = 'EterDB metadata is tamper-protected; contact the operator.';
    END LOOP;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION eter.harden_schema(p_tenant_role text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  -- Full lockout: the tenant role gets no access to the eter schema or its
  -- objects (revoking schema USAGE makes eter.* unreferenceable).
  EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA eter FROM %I', p_tenant_role);
  EXECUTE format('REVOKE ALL ON ALL SEQUENCES IN SCHEMA eter FROM %I', p_tenant_role);
  EXECUTE format('REVOKE ALL ON SCHEMA eter FROM %I', p_tenant_role);
  -- Block any non-owner DDL on eter objects (over and above object ownership).
  DROP EVENT TRIGGER IF EXISTS eter_block_ddl;
  DROP EVENT TRIGGER IF EXISTS eter_block_drop;
  CREATE EVENT TRIGGER eter_block_ddl  ON ddl_command_end EXECUTE FUNCTION eter._block_eter_ddl();
  CREATE EVENT TRIGGER eter_block_drop ON sql_drop        EXECUTE FUNCTION eter._block_eter_ddl();
END;
$$;

CREATE OR REPLACE FUNCTION eter.unharden_schema(p_tenant_role text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  DROP EVENT TRIGGER IF EXISTS eter_block_ddl;
  DROP EVENT TRIGGER IF EXISTS eter_block_drop;
  EXECUTE format('GRANT ALL ON SCHEMA eter TO %I', p_tenant_role);
  EXECUTE format('GRANT ALL ON ALL TABLES IN SCHEMA eter TO %I', p_tenant_role);
END;
$$;
