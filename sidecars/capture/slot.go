// Slot / publication / capture-state bootstrap and reconciliation, run over an
// ordinary (non-replication) connection by a privileged role. These are
// idempotent and safe to call on every startup and on every tracked-set change.
package main

import (
	"context"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"
)

func ensurePublication(ctx context.Context, pool *pgxpool.Pool, publication string) error {
	var exists int
	err := pool.QueryRow(ctx, "SELECT 1 FROM pg_publication WHERE pubname = $1", publication).Scan(&exists)
	switch {
	case err == nil:
		// already present
	case isNoRows(err):
		// Created empty; reconcileMembership() adds the tracked tables explicitly so
		// eter.* writes are never decoded back into history.
		if _, err := pool.Exec(ctx, "CREATE PUBLICATION "+quoteIdent(publication)); err != nil {
			return err
		}
		logInfo("created publication", map[string]any{"publication": publication})
	default:
		return err
	}
	return ensurePublishGeneratedColumns(ctx, pool, publication)
}

// ensurePublishGeneratedColumns opts the publication into publishing STORED
// generated columns on PG18+. A tracked table is REPLICA IDENTITY FULL, so a
// stored generated column (e.g. Twenty's searchVector) is part of the replica
// identity; PG18 then refuses UPDATE/DELETE unless that column is also published.
// The parameter and pg_publication.pubgencols are PG18+ only, so we gate on the
// server version before touching either.
func ensurePublishGeneratedColumns(ctx context.Context, pool *pgxpool.Pool, publication string) error {
	var verNum int
	if err := pool.QueryRow(ctx, "SELECT current_setting('server_version_num')::int").Scan(&verNum); err != nil {
		return err
	}
	if verNum < 180000 {
		return nil
	}
	var gencols string
	if err := pool.QueryRow(ctx, "SELECT pubgencols FROM pg_publication WHERE pubname = $1", publication).Scan(&gencols); err != nil {
		return err
	}
	if gencols == "s" {
		return nil
	}
	_, err := pool.Exec(ctx, "ALTER PUBLICATION "+quoteIdent(publication)+" SET (publish_generated_columns = stored)")
	return err
}

func ensureSlot(ctx context.Context, pool *pgxpool.Pool, slot string) error {
	var exists int
	err := pool.QueryRow(ctx, "SELECT 1 FROM pg_replication_slots WHERE slot_name = $1", slot).Scan(&exists)
	if err == nil {
		return nil
	}
	if !isNoRows(err) {
		return err
	}
	if _, err := pool.Exec(ctx, "SELECT pg_create_logical_replication_slot($1, 'pgoutput')", slot); err != nil {
		return err
	}
	logInfo("created logical slot", map[string]any{"slot": slot})
	return nil
}

func ensureCaptureState(ctx context.Context, pool *pgxpool.Pool, slot string) error {
	_, err := pool.Exec(ctx,
		"INSERT INTO eter.capture_state (slot) VALUES ($1) ON CONFLICT (slot) DO NOTHING", slot)
	return err
}

// reconcileMembership syncs publication membership + REPLICA IDENTITY FULL to
// eter.tracked: adds tracked tables that are missing, drops members no longer
// tracked.
func reconcileMembership(ctx context.Context, pool *pgxpool.Pool, publication string) error {
	type rel struct {
		oid  int64
		name string
	}
	loadRels := func(sql string, args ...any) ([]rel, error) {
		rows, err := pool.Query(ctx, sql, args...)
		if err != nil {
			return nil, err
		}
		defer rows.Close()
		var out []rel
		for rows.Next() {
			var r rel
			if err := rows.Scan(&r.oid, &r.name); err != nil {
				return nil, err
			}
			out = append(out, r)
		}
		return out, rows.Err()
	}

	// Tracked tables resolvable to a live relation, with their canonical names and
	// current replica identity (so we only ALTER when it isn't already FULL).
	var tracked []rel
	replFull := map[int64]bool{}
	trows, err := pool.Query(ctx,
		`SELECT c.oid::int8 AS oid, (c.oid::regclass)::text AS name, c.relreplident::text
		   FROM eter.tracked t
		   JOIN pg_class c ON c.oid = to_regclass(t.table_name)`)
	if err != nil {
		return err
	}
	for trows.Next() {
		var r rel
		var ri string
		if err := trows.Scan(&r.oid, &r.name, &ri); err != nil {
			trows.Close()
			return err
		}
		tracked = append(tracked, r)
		replFull[r.oid] = ri == "f"
	}
	trows.Close()
	if err := trows.Err(); err != nil {
		return err
	}
	members, err := loadRels(
		`SELECT pr.prrelid::int8 AS oid, (pr.prrelid::regclass)::text AS name
		   FROM pg_publication_rel pr
		   JOIN pg_publication p ON p.oid = pr.prpubid
		  WHERE p.pubname = $1`, publication)
	if err != nil {
		return err
	}

	trackedOids := map[int64]bool{}
	for _, t := range tracked {
		trackedOids[t.oid] = true
	}
	memberOids := map[int64]bool{}
	for _, m := range members {
		memberOids[m.oid] = true
	}

	for _, t := range tracked {
		// REPLICA IDENTITY FULL is required for full before-images on UPDATE/DELETE,
		// but only ALTER when it isn't already FULL, re-applying it every reconcile
		// fires the DDL event trigger and floods eter.ddl_log on schemas with many
		// tables (e.g. a Twenty workspace has dozens).
		if !replFull[t.oid] {
			if _, err := pool.Exec(ctx, "ALTER TABLE "+t.name+" REPLICA IDENTITY FULL"); err != nil {
				return err
			}
		}
		if !memberOids[t.oid] {
			if _, err := pool.Exec(ctx, "ALTER PUBLICATION "+quoteIdent(publication)+" ADD TABLE "+t.name); err != nil {
				return err
			}
			logInfo("publication +table", map[string]any{"publication": publication, "table": t.name})
		}
	}
	for _, m := range members {
		if !trackedOids[m.oid] {
			if _, err := pool.Exec(ctx, "ALTER PUBLICATION "+quoteIdent(publication)+" DROP TABLE "+m.name); err != nil {
				return err
			}
			logInfo("publication -table", map[string]any{"publication": publication, "table": m.name})
		}
	}
	return nil
}

func quoteIdent(name string) string {
	return `"` + strings.ReplaceAll(name, `"`, `""`) + `"`
}
