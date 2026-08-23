// Read-set forwarder (Phase 3 Inc 6, "collapse the tenant floor"). Two-DB only.
//
// SSI read-dependencies are CAPTURED in the tenant (the eter_ssi commit hook
// writes the SSI-WAL; eter.drain_ssi_wal() ingests it into eter.ssi_reads)
// but DERIVED in the store, so the tenant keeps no dependency graph and no durable
// read-set of its own. Each cycle this forwarder only SHIPS the read-set out:
// drain the tenant's SSI-WAL, ship the freshly ingested read targets to the store
// with the reloid resolved to its canonical table_name (the store has no tenant
// catalog), and clear the tenant staging. Derivation itself
// (eter.derive_from_read_set) runs on-demand at PREVIEW time, when the history
// stream has caught up, deriving here continuously would race the (separately
// async) history decode and could truncate a read whose writer has not been decoded yet.
package main

import (
	"context"

	"github.com/jackc/pgx/v5/pgxpool"
)

type readSetForwarder struct {
	tenant  *pgxpool.Pool
	store   *pgxpool.Pool
	enabled bool
	probed  bool // hasDrain probed once
}

func newReadSetForwarder(tenant, store *pgxpool.Pool) *readSetForwarder {
	return &readSetForwarder{tenant: tenant, store: store, enabled: true}
}

// forwardOnce drains + ships once. Disables itself if eter_ssi is not installed
// in the tenant (nothing to forward, ever).
func (f *readSetForwarder) forwardOnce(ctx context.Context) error {
	if !f.enabled {
		return nil
	}
	if !f.probed {
		var ok bool
		if err := f.tenant.QueryRow(ctx,
			"SELECT to_regprocedure('eter.drain_ssi_wal()') IS NOT NULL AS ok").Scan(&ok); err != nil {
			return err
		}
		f.probed = true
		if !ok {
			f.enabled = false
			logInfo("read-set forwarder disabled (eter_ssi not installed in tenant)", nil)
			return nil
		}
	}

	// Drain the SSI-WAL, snapshot the staged reads (reloid → canonical name), and
	// clear the staging, all in one tenant txn so the truncate drops exactly what
	// we took.
	type readRow struct {
		readerXid int64
		tableName string
		blk       int64
		off       int32
		locktype  int32
		readPK    *string
	}
	var rows []readRow
	tx, err := f.tenant.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if _, err := tx.Exec(ctx, "SELECT eter.drain_ssi_wal()"); err != nil {
		return err
	}
	r, err := tx.Query(ctx,
		`SELECT reader_xid, reloid::regclass::text AS table_name, blk, "off", locktype, read_pk
		   FROM eter.ssi_reads`)
	if err != nil {
		return err
	}
	for r.Next() {
		var rr readRow
		if err := r.Scan(&rr.readerXid, &rr.tableName, &rr.blk, &rr.off, &rr.locktype, &rr.readPK); err != nil {
			r.Close()
			return err
		}
		rows = append(rows, rr)
	}
	r.Close()
	if err := r.Err(); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, "TRUNCATE eter.ssi_reads"); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return err
	}
	if len(rows) == 0 {
		return nil
	}

	// Ship to the store's read-set staging (derivation happens at preview time).
	readerXid := make([]int64, len(rows))
	tableName := make([]string, len(rows))
	blk := make([]int64, len(rows))
	off := make([]int32, len(rows))
	locktype := make([]int32, len(rows))
	readPK := make([]*string, len(rows))
	for i, rr := range rows {
		readerXid[i], tableName[i], blk[i] = rr.readerXid, rr.tableName, rr.blk
		off[i], locktype[i], readPK[i] = rr.off, rr.locktype, rr.readPK
	}
	if _, err := f.store.Exec(ctx,
		`INSERT INTO eter.read_set (reader_xid, table_name, blk, "off", locktype, read_pk)
		 SELECT * FROM unnest($1::bigint[], $2::text[], $3::bigint[], $4::int[], $5::int[], $6::text[])`,
		readerXid, tableName, blk, off, locktype, readPK); err != nil {
		return err
	}
	logInfo("forwarded read-set", map[string]any{"reads": len(rows)})
	return nil
}
