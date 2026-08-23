// The tracked-table catalogue the sidecar needs to map decoded relations to
// history rows: relation oid -> (canonical name, primary-key columns). Keyed by
// oid (not name) so search_path / rendering differences never matter, the
// decoded pgoutput Relation message carries the relation oid directly.
package main

import (
	"context"

	"github.com/jackc/pgx/v5/pgxpool"
)

type trackedTable struct {
	// name is the eter.history.table_name to write (canonical regclass text).
	name string
	// pkCols are the primary-key column names, in key order.
	pkCols []string
}

type trackedCatalog map[uint32]trackedTable

func loadTracked(ctx context.Context, pool *pgxpool.Pool) (trackedCatalog, error) {
	rows, err := pool.Query(ctx,
		`SELECT c.oid::int8 AS oid, (c.oid::regclass)::text AS name, t.pk_cols
		   FROM eter.tracked t
		   JOIN pg_class c ON c.oid = to_regclass(t.table_name)`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	cat := trackedCatalog{}
	for rows.Next() {
		var oid int64
		var name string
		var pkCols []string
		if err := rows.Scan(&oid, &name, &pkCols); err != nil {
			return nil, err
		}
		//nolint:gosec // oid is a PostgreSQL OID, uint32 by definition; the int64 scan is just driver widening
		cat[uint32(oid)] = trackedTable{name: name, pkCols: pkCols}
	}
	return cat, rows.Err()
}
