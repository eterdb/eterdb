// The history-store writer. This is the single, narrow seam between decoding and
// persistence: today it writes eter.history in the main DB; relocating to a
// physically separate history store later is a change here and nowhere else.
//
// Each committed transaction is written atomically with an advance of
// eter.capture_state.last_commit_lsn, and only then is the slot acknowledged
// (in main.go). On restart the slot resumes from the confirmed-flush LSN; any
// re-delivered commit is filtered here by the LSN cursor, making writes
// exactly-once.
package main

import (
	"context"
	"encoding/json"

	"github.com/jackc/pgx/v5/pgxpool"
)

type commitBatch struct {
	txid         int64
	committedAt  string // ISO timestamp of the commit
	commitEndLSN string // pg_lsn cursor: WAL position just past this commit
	rows         []mappedRow
}

type historyStore struct {
	pool *pgxpool.Pool
	slot string
}

// writeCommit persists a committed transaction. Returns false if already applied
// (skipped).
func (s *historyStore) writeCommit(ctx context.Context, batch commitBatch) (bool, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return false, err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	// Serialize cursor advancement; also gives us the current cursor.
	var last string
	err = tx.QueryRow(ctx,
		"SELECT last_commit_lsn FROM eter.capture_state WHERE slot = $1 FOR UPDATE", s.slot).Scan(&last)
	if err != nil && !isNoRows(err) {
		return false, err
	}
	if last == "" {
		last = "0/0"
	}
	var done bool
	if err := tx.QueryRow(ctx,
		"SELECT $1::pg_lsn <= $2::pg_lsn AS done", batch.commitEndLSN, last).Scan(&done); err != nil {
		return false, err
	}
	if done {
		return false, tx.Rollback(ctx)
	}

	// is_undo / undo_of: the trigger oracle read session GUCs; the sidecar
	// instead joins the compensating transaction against eter.undo_txn.
	var undoOf *string
	err = tx.QueryRow(ctx, "SELECT undo_of FROM eter.undo_txn WHERE txid = $1", batch.txid).Scan(&undoOf)
	var isUndo bool
	switch {
	case err == nil:
		isUndo = true
	case isNoRows(err):
		// no matching undo_txn row: this is a normal write, isUndo stays false
	default:
		return false, err
	}

	// Insert in decode (= execution) order so bigserial history.id reflects
	// intra-transaction ordering, which undo relies on (applies id DESC).
	for _, r := range batch.rows {
		pkJSON, err := json.Marshal(r.pk)
		if err != nil {
			return false, err
		}
		if _, err := tx.Exec(ctx,
			`INSERT INTO eter.history
			   (txid, fingerprint, statement_sample, table_name, op, pk,
			    row_before, row_after, committed_at, application_name, is_undo, undo_of)
			 VALUES ($1,$2,$3,$4,$5,$6::jsonb,$7::jsonb,$8::jsonb,$9,'eter-capture',$10,$11)`,
			batch.txid, r.fingerprint, r.statementSample, r.tableName, r.op,
			string(pkJSON), jsonOrNil(r.rowBefore), jsonOrNil(r.rowAfter),
			batch.committedAt, isUndo, undoOf); err != nil {
			return false, err
		}
	}

	if _, err := tx.Exec(ctx,
		"UPDATE eter.capture_state SET last_commit_lsn = $2, updated_at = now() WHERE slot = $1",
		s.slot, batch.commitEndLSN); err != nil {
		return false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return false, err
	}
	return true, nil
}

// jsonOrNil marshals a row to a JSON string, or returns a nil interface (SQL
// NULL) when the row image is absent (INSERT has no before, DELETE no after).
func jsonOrNil(r row) any {
	if r == nil {
		return nil
	}
	b, err := json.Marshal(r)
	if err != nil {
		return nil
	}
	return string(b)
}
