-- eter_ssi: strict-mode SSI dependency capture (version in eter_ssi.control).
-- Requires the eter engine (eter.sql) to be applied first.
-- \echo Use "CREATE EXTENSION eter_ssi" to load this file. \quit

-- Raw SIREAD predicate-lock targets drained from the SSI-WAL, keyed by the
-- reader transaction's (32-bit) xid. Physical targets: relation oid + heap
-- block + tuple offset, plus the lock granularity (0=relation,1=page,2=tuple).
CREATE TABLE IF NOT EXISTS eter.ssi_reads (
  reader_xid  bigint NOT NULL,
  reloid      bigint NOT NULL,
  blk         bigint NOT NULL,
  "off"       integer NOT NULL,
  locktype    integer NOT NULL,
  read_pk     text                 -- PK of the read row, resolved EAGERLY at the
                                    -- reader's PRE_COMMIT (eter_ssi.c) while
                                    -- the tuple is still live; NULL for non-tuple
                                    -- (page/relation) targets or if unresolvable.
);
-- Upgrade path for clusters created before read_pk existed.
ALTER TABLE eter.ssi_reads ADD COLUMN IF NOT EXISTS read_pk text;
CREATE INDEX IF NOT EXISTS ssi_reads_reloid_idx ON eter.ssi_reads (reloid, blk);

-- Ingest the append-only SSI-WAL (written off the commit path by the C hook)
-- into eter.ssi_reads, then truncate it. Returns rows ingested.
CREATE FUNCTION eter.drain_ssi_wal() RETURNS integer
  AS 'MODULE_PATHNAME', 'eter_ssi_drain' LANGUAGE C;

-- Helpers to pull block/offset out of a ctid recorded in eter.history.tid.
CREATE OR REPLACE FUNCTION eter._tid_block(t tid) RETURNS bigint
  LANGUAGE sql IMMUTABLE AS $$ SELECT split_part(trim(both '()' from t::text), ',', 1)::bigint $$;
CREATE OR REPLACE FUNCTION eter._tid_off(t tid) RETURNS integer
  LANGUAGE sql IMMUTABLE AS $$ SELECT split_part(trim(both '()' from t::text), ',', 2)::integer $$;

-- Resolve a SIREAD tuple target (reloid, block, offset) to the row's primary key
-- as comma-joined text in index-key order. Implemented in C (reads the physical
-- tuple under SnapshotAny, in the drain transaction, never a user commit). This
-- is what lets reads match writes by (table, pk) instead of ctid, so a read
-- dependency is found even when the write was captured by logical decoding
-- (history.tid is NULL, logical decoding has no ctid). See eter_ssi.c.
CREATE OR REPLACE FUNCTION eter.resolve_pk(reloid bigint, blk bigint, "off" integer)
  RETURNS text AS 'MODULE_PATHNAME', 'eter_ssi_resolve_pk' LANGUAGE C;

-- The comparable PK text for a write in eter.history: the tracked PK column
-- values, in key order, joined by commas, matching resolve_pk's output.
CREATE OR REPLACE FUNCTION eter._pk_text(p_table text, p_pk jsonb)
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT string_agg(p_pk ->> u.col, ',' ORDER BY u.ord)
  FROM eter.tracked t, unnest(t.pk_cols) WITH ORDINALITY AS u(col, ord)
  WHERE t.table_name = p_table;
$$;

-- Derive read-dependency edges: a reader R that read a tuple version writer W
-- produced depends on W. Edge (R, W, 'rw'). Matching is by primary key, the read
-- tuple's PK (eter.ssi_reads.read_pk, resolved EAGERLY at the reader's
-- PRE_COMMIT while the tuple was still live), the write's PK from
-- eter.history.pk, so it holds whether the write was captured by the trigger
-- oracle (ctid present) OR by the logical-decoding sidecar (ctid NULL), and is
-- SOUND because the PK is captured before any vacuum can reuse the read's slot
-- (drain-time resolution raced vacuum, the false-clean the harness found). ctid
-- matching remains a fallback when the PK could not be resolved at capture (the
-- relation/tuple was already gone, or an expression PK). Granularity: tuple =
-- exact PK (or ctid); page = same heap block; relation = same table. Whenever a
-- target can't be pinned precisely we over-approximate to table level (extra
-- conflict reviews, the safe direction, never a missed dependency). The reader's
-- 32-bit xid is resolved to a 64-bit txid via its own tracked writes.
CREATE OR REPLACE FUNCTION eter.derive_dependencies() RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE n integer;
BEGIN
  -- Precompute each writer's reloid + comparable PK text ONCE (MATERIALIZED CTE),
  -- not once per (read × write) pair. The old inline eter._pk_text(w...) in the
  -- join predicate (wrapped in an OR) forced a nested loop with a subquery-bearing
  -- function call per pair, O(reads × writes), which collapses under the per-row
  -- read-sets the observe harvest now produces. Split by match kind so the precise
  -- case is a hash join on (reloid, pk_text); identical edges/over-approximation.
  INSERT INTO eter.dependencies (txid, depends_on, kind, detail)
  WITH w AS MATERIALIZED (
    SELECT h.txid, h.tid, h.committed_at, h.table_name,
           h.table_name::regclass::oid::bigint AS reloid,
           eter._pk_text(h.table_name, h.pk) AS pk_text
    FROM eter.history h WHERE NOT h.is_undo
  ),
  r AS MATERIALIZED (
    SELECT DISTINCT ON (xid32) (h.txid % 4294967296)::bigint AS xid32, h.txid, h.committed_at
    FROM eter.history h WHERE NOT h.is_undo ORDER BY xid32, h.txid
  ),
  edges AS (
    -- precise tuple match: hash join on (reloid, pk_text). TIME-ORDER guard
    -- (r.committed_at >= w.committed_at): a reader cannot have read a write that
    -- committed after it, so drop reader-before-writer pairs (impossible reads),
    -- this stops a recent scan from spuriously depending on a table's whole history.
    SELECT r.txid AS rtxid, w.txid AS wtxid, w.table_name, s.reloid, s.blk, s."off", s.read_pk, 'tuple' AS gran
    FROM eter.ssi_reads s
    JOIN w ON w.reloid = s.reloid AND w.pk_text = s.read_pk
    JOIN r ON r.xid32 = s.reader_xid
    WHERE s.locktype = 2 AND s.read_pk IS NOT NULL AND w.txid <> r.txid
          AND r.committed_at >= w.committed_at
    UNION ALL
    -- over-approximate to table level: tuple read with unresolved PK, or a
    -- relation-level lock, matches every write to the relation (safe direction).
    SELECT r.txid, w.txid, w.table_name, s.reloid, s.blk, s."off", s.read_pk,
           CASE s.locktype WHEN 0 THEN 'relation' ELSE 'tuple' END
    FROM eter.ssi_reads s
    JOIN w ON w.reloid = s.reloid
    JOIN r ON r.xid32 = s.reader_xid
    WHERE ((s.locktype = 2 AND s.read_pk IS NULL) OR s.locktype = 0) AND w.txid <> r.txid
          AND r.committed_at >= w.committed_at
    UNION ALL
    -- page-level: block match where the write has a ctid, else table level.
    SELECT r.txid, w.txid, w.table_name, s.reloid, s.blk, s."off", s.read_pk, 'page'
    FROM eter.ssi_reads s
    JOIN w ON w.reloid = s.reloid AND (w.tid IS NULL OR eter._tid_block(w.tid) = s.blk)
    JOIN r ON r.xid32 = s.reader_xid
    WHERE s.locktype = 1 AND w.txid <> r.txid
          AND r.committed_at >= w.committed_at
  )
  -- Keep the MOST PRECISE evidence per (reader,target): tuple < page < relation
  -- (DISTINCT ON + ORDER BY rank). A pair can produce edges at several
  -- granularities; the stored one drives preview's exact-vs-over-approx label, so
  -- it must be deterministic, not whichever duplicate ON CONFLICT happened to keep.
  SELECT DISTINCT ON (rtxid, wtxid) rtxid, wtxid, 'rw',
         jsonb_build_object('table', table_name, 'reloid', reloid, 'block', blk,
                            'offset', "off", 'pk', read_pk, 'granularity', gran)
  FROM edges
  ORDER BY rtxid, wtxid, eter._gran_rank(gran)
  -- Upgrade a stored coarse edge when a later refresh finds a precise match
  -- (dependencies accumulate across refresh cycles); never downgrade.
  ON CONFLICT (txid, depends_on, kind) DO UPDATE
    SET detail = EXCLUDED.detail
    WHERE eter._gran_rank(EXCLUDED.detail->>'granularity')
        < eter._gran_rank(eter.dependencies.detail->>'granularity');
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$$;

-- One call to refresh the persisted graph from freshly committed transactions.
CREATE OR REPLACE FUNCTION eter.refresh_dependencies() RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE drained integer; derived integer;
BEGIN
  drained := eter.drain_ssi_wal();
  derived := eter.derive_dependencies();
  -- A reader always reads an already-committed writer, so every read in
  -- ssi_reads has had its chance to match a write. Clear them now so the table
  -- (and the derive join) does not grow unboundedly under the background worker.
  TRUNCATE eter.ssi_reads;
  RETURN jsonb_build_object('drained', drained, 'derived_edges', derived);
END;
$$;
