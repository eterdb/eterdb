// DDL-log forwarder (Phase 3, externalize eter.ddl_log). Two-DB only.
//
// eter.ddl_log is the destructive-DDL recovery INDEX (what was dropped, by
// whom, in which txid, at what LSN). It is CAPTURED in the tenant, event triggers
// can only fire inside the cluster whose DDL they watch, so the write is
// irreducibly tenant-local, but its DURABLE home is the store, like history. Each
// cycle this forwarder ships the freshly logged rows to the store (preserving the
// tenant's own txid / snapshot_lsn / committed_at, which correlate with the tenant
// cluster's WAL) and prunes the tenant copy, so the tenant keeps no durable
// recovery index of its own.
//
// Durability: ship to the store FIRST, prune the tenant SECOND. A crash in between
// just re-ships next cycle, idempotent via the store's ddl_log_src_id_idx
// (ON CONFLICT (src_id) DO NOTHING), so no row is ever duplicated or lost.
package main

import (
	"context"

	"github.com/jackc/pgx/v5/pgxpool"
)

type ddlLogForwarder struct {
	tenant *pgxpool.Pool
	store  *pgxpool.Pool
}

func newDdlLogForwarder(tenant, store *pgxpool.Pool) *ddlLogForwarder {
	return &ddlLogForwarder{tenant: tenant, store: store}
}

// forwardOnce ships newly logged tenant DDL rows to the store, then prunes them
// locally.
func (f *ddlLogForwarder) forwardOnce(ctx context.Context) error {
	type ddlRow struct {
		id            int64
		txid          int64
		commandTag    string
		objectType    *string
		schemaName    *string
		objectIdent   *string
		statement     *string
		isDestructive bool
		needsSnapshot bool
		snapshotLSN   string
		committedAt   string
	}
	r, err := f.tenant.Query(ctx,
		`SELECT id, txid, command_tag, object_type, schema_name,
		        object_identity, statement, is_destructive, needs_snapshot,
		        snapshot_lsn::text, committed_at::text
		   FROM eter.ddl_log
		  ORDER BY id`)
	if err != nil {
		return err
	}
	var rows []ddlRow
	for r.Next() {
		var d ddlRow
		if err := r.Scan(&d.id, &d.txid, &d.commandTag, &d.objectType, &d.schemaName,
			&d.objectIdent, &d.statement, &d.isDestructive, &d.needsSnapshot,
			&d.snapshotLSN, &d.committedAt); err != nil {
			r.Close()
			return err
		}
		rows = append(rows, d)
	}
	r.Close()
	if err := r.Err(); err != nil {
		return err
	}
	if len(rows) == 0 {
		return nil
	}

	n := len(rows)
	id := make([]int64, n)
	txid := make([]int64, n)
	commandTag := make([]string, n)
	objectType := make([]*string, n)
	schemaName := make([]*string, n)
	objectIdent := make([]*string, n)
	statement := make([]*string, n)
	isDestructive := make([]bool, n)
	needsSnapshot := make([]bool, n)
	snapshotLSN := make([]string, n)
	committedAt := make([]string, n)
	for i, d := range rows {
		id[i], txid[i], commandTag[i] = d.id, d.txid, d.commandTag
		objectType[i], schemaName[i], objectIdent[i] = d.objectType, d.schemaName, d.objectIdent
		statement[i], isDestructive[i], needsSnapshot[i] = d.statement, d.isDestructive, d.needsSnapshot
		snapshotLSN[i], committedAt[i] = d.snapshotLSN, d.committedAt
	}

	// Idempotent ship: src_id = the tenant's id, deduped by ddl_log_src_id_idx.
	if _, err := f.store.Exec(ctx,
		`INSERT INTO eter.ddl_log
		   (src_id, txid, command_tag, object_type, schema_name, object_identity,
		    statement, is_destructive, needs_snapshot, snapshot_lsn, committed_at)
		 SELECT * FROM unnest(
		   $1::bigint[], $2::bigint[], $3::text[], $4::text[], $5::text[], $6::text[],
		   $7::text[], $8::bool[], $9::bool[], $10::pg_lsn[], $11::timestamptz[])
		 ON CONFLICT (src_id) WHERE src_id IS NOT NULL DO NOTHING`,
		id, txid, commandTag, objectType, schemaName, objectIdent,
		statement, isDestructive, needsSnapshot, snapshotLSN, committedAt); err != nil {
		return err
	}

	// Durably in the store now → prune what we shipped (transient tenant staging).
	maxID := rows[len(rows)-1].id
	if _, err := f.tenant.Exec(ctx, "DELETE FROM eter.ddl_log WHERE id <= $1", maxID); err != nil {
		return err
	}
	logInfo("forwarded ddl-log", map[string]any{"rows": len(rows)})
	return nil
}
