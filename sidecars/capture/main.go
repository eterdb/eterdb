// EterDB capture sidecar (Phase 3).
//
// Consumes the main DB's logical replication slot (pgoutput) and writes the same
// eter.history rows the Phase 1/2 AFTER-trigger oracle produced, but
// out-of-process and off the commit hot path. The main DB carries no history
// triggers in sidecar mode (eter.track installs REPLICA IDENTITY FULL +
// publication membership instead).
//
// Fidelity: pgoutput delivers tuple column values in Postgres text format, which
// we store as-is, so jsonb_populate_record reconstructs the exact original tuple
// with no precision loss. Representation differs from the trigger's to_jsonb
// (e.g. text "100" vs number 100) but undo is unaffected, _compensate already
// reconstructs rows via jsonb_populate_record.
package main

import (
	"context"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/jackc/pglogrepl"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgproto3"
	"github.com/jackc/pgx/v5/pgxpool"
)

type pendingChange struct {
	table  string
	pkCols []string
	change rowChange
}

type pendingTxn struct {
	xid         int64
	committedAt string
	changes     []pendingChange
}

func main() {
	cfg, err := loadConfig()
	if err != nil {
		logError("fatal", map[string]any{"err": err.Error()})
		os.Exit(1)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Tenant connection: slot/publication/tracked + the decode stream all come from
	// the tenant DB. search_path so eter.tracked names and eter.* objects resolve
	// regardless of role.
	tenantPool, err := newPool(ctx, cfg.connectionString, "eter-capture")
	if err != nil {
		logError("fatal", map[string]any{"err": err.Error()})
		os.Exit(1)
	}
	// Metadata-store connection: history + its exactly-once cursor (capture_state)
	// + undo_txn. Same pool when ETER_META_URL is unset (single-DB), a separate
	// pool when history is externalized.
	metaPool := tenantPool
	if cfg.metaSeparate() {
		metaPool, err = newPool(ctx, cfg.metaURL, "eter-capture-meta")
		if err != nil {
			logError("fatal", map[string]any{"err": err.Error()})
			os.Exit(1)
		}
	}

	for _, step := range []func() error{
		func() error { return ensurePublication(ctx, tenantPool, cfg.publication) },
		func() error { return ensureSlot(ctx, tenantPool, cfg.slot) },
		func() error { return ensureCaptureState(ctx, metaPool, cfg.slot) },
		func() error { return reconcileMembership(ctx, tenantPool, cfg.publication) },
	} {
		if err := step(); err != nil {
			logError("fatal", map[string]any{"err": err.Error()})
			os.Exit(1)
		}
	}

	catalog, err := loadTracked(ctx, tenantPool)
	if err != nil {
		logError("fatal", map[string]any{"err": err.Error()})
		os.Exit(1)
	}
	store := &historyStore{pool: metaPool, slot: cfg.slot}
	logInfo("bootstrapped", map[string]any{
		"slot": cfg.slot, "publication": cfg.publication,
		"tracked": len(catalog), "metaSeparate": cfg.metaSeparate(),
	})

	// The catalog is read by the replication loop and rewritten by refresh, guard it.
	var mu sync.RWMutex
	getTracked := func(oid uint32) (trackedTable, bool) {
		mu.RLock()
		defer mu.RUnlock()
		t, ok := catalog[oid]
		return t, ok
	}

	// Mirror the tracked-table catalog into the store (two-DB mode): the store's
	// eter.derive_from_read_set needs tracked.pk_cols to compare read PKs. The
	// tenant keeps its own copy for capture + the undo apply path.
	syncTrackedToStore := func(cat trackedCatalog) error {
		if !cfg.metaSeparate() {
			return nil
		}
		for _, t := range cat {
			if _, err := metaPool.Exec(ctx,
				`INSERT INTO eter.tracked (table_name, pk_cols) VALUES ($1, $2)
				 ON CONFLICT (table_name) DO UPDATE SET pk_cols = EXCLUDED.pk_cols, tracked_at = now()`,
				t.name, t.pkCols); err != nil {
				return err
			}
		}
		return nil
	}
	// Refresh the catalogue + publication when the tracked set changes (NOTIFY
	// from eter.track/untrack), with a slow poll backstop in case a NOTIFY is
	// missed (e.g. across a reconnect).
	refresh := func() error {
		if err := reconcileMembership(ctx, tenantPool, cfg.publication); err != nil {
			return err
		}
		cat, err := loadTracked(ctx, tenantPool)
		if err != nil {
			return err
		}
		mu.Lock()
		catalog = cat
		mu.Unlock()
		return syncTrackedToStore(cat)
	}
	if err := syncTrackedToStore(catalog); err != nil {
		logError("initial tracked sync failed", map[string]any{"err": err.Error()})
	}

	// LISTEN for tracked-set changes on a dedicated connection.
	go listenTracked(ctx, cfg.connectionString, refresh)
	// Poll backstop.
	go ticker(ctx, cfg.reconcile, func() {
		if err := refresh(); err != nil {
			logError("reconcile failed", map[string]any{"err": err.Error()})
		}
	})

	// Two-DB forwarders: keep durable eter data out of the tenant. The read-set
	// forwarder derives the SSI rw graph in the store; the DDL-log forwarder ships
	// the destructive-DDL recovery index to the store. Single-DB mode leaves rw
	// derivation to the eter_ssi bgworker and keeps ddl_log in the one DB.
	if cfg.metaSeparate() {
		rsf := newReadSetForwarder(tenantPool, metaPool)
		ddl := newDdlLogForwarder(tenantPool, metaPool)
		go ticker(ctx, cfg.forward, func() {
			if err := rsf.forwardOnce(ctx); err != nil {
				logError("forward failed", map[string]any{"err": err.Error()})
			}
			if err := ddl.forwardOnce(ctx); err != nil {
				logError("ddl forward failed", map[string]any{"err": err.Error()})
			}
		})
	}

	// Replication stream with auto-resubscribe on disconnect.
	go func() {
		for ctx.Err() == nil {
			if err := streamOnce(ctx, cfg, store, getTracked); err != nil && ctx.Err() == nil {
				logError("replication stream error; resubscribing", map[string]any{"err": err.Error()})
			} else if ctx.Err() == nil {
				logWarn("replication stream ended; resubscribing", nil)
			}
			if ctx.Err() == nil {
				time.Sleep(time.Second)
			}
		}
	}()
	logInfo("capture sidecar running", nil)

	sigch := make(chan os.Signal, 1)
	signal.Notify(sigch, syscall.SIGINT, syscall.SIGTERM)
	sig := <-sigch
	logInfo("shutting down", map[string]any{"sig": sig.String()})
	cancel()
	time.Sleep(200 * time.Millisecond) // let in-flight loops observe ctx
	tenantPool.Close()
	if cfg.metaSeparate() {
		metaPool.Close()
	}
	os.Exit(0)
}

func newPool(ctx context.Context, dsn, appName string) (*pgxpool.Pool, error) {
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, err
	}
	cfg.ConnConfig.RuntimeParams["search_path"] = "public, eter"
	cfg.ConnConfig.RuntimeParams["application_name"] = appName
	return pgxpool.NewWithConfig(ctx, cfg)
}

// listenTracked opens a dedicated connection, LISTENs for tracked-set changes,
// and calls refresh on each notification. Returns (and lets the poll backstop
// carry on) on any connection error or context cancellation.
func listenTracked(ctx context.Context, dsn string, refresh func() error) {
	connCfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		logError("listen config failed", map[string]any{"err": err.Error()})
		return
	}
	connCfg.RuntimeParams["search_path"] = "public, eter"
	conn, err := pgx.ConnectConfig(ctx, connCfg)
	if err != nil {
		logError("listen connect failed", map[string]any{"err": err.Error()})
		return
	}
	defer func() { _ = conn.Close(context.Background()) }()
	if _, err := conn.Exec(ctx, "LISTEN eter_tracked_changed"); err != nil {
		logError("listen failed", map[string]any{"err": err.Error()})
		return
	}
	for ctx.Err() == nil {
		if _, err := conn.WaitForNotification(ctx); err != nil {
			if ctx.Err() == nil {
				logError("listen wait failed", map[string]any{"err": err.Error()})
			}
			return
		}
		if err := refresh(); err != nil {
			logError("refresh failed", map[string]any{"err": err.Error()})
		}
	}
}

func ticker(ctx context.Context, d time.Duration, fn func()) {
	t := time.NewTicker(d)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			fn()
		}
	}
}

// streamOnce opens a replication connection and consumes the pgoutput stream
// until it errors or the context is cancelled. flowControl is emulated: the slot
// is only advanced (acknowledged) once a commit is durably written.
func streamOnce(ctx context.Context, cfg captureConfig, store *historyStore, getTracked func(uint32) (trackedTable, bool)) error {
	replCfg, err := pgconn.ParseConfig(cfg.connectionString)
	if err != nil {
		return err
	}
	replCfg.RuntimeParams["replication"] = "database"
	replCfg.RuntimeParams["application_name"] = "eter-capture"
	conn, err := pgconn.ConnectConfig(ctx, replCfg)
	if err != nil {
		return err
	}
	defer func() { _ = conn.Close(context.Background()) }()

	pluginArgs := []string{"proto_version '1'", "publication_names '" + cfg.publication + "'"}
	// startLSN 0 → the server resumes from the slot's confirmed_flush_lsn; any
	// re-delivered commit is filtered by the store's LSN cursor (exactly-once).
	if err := pglogrepl.StartReplication(ctx, conn, cfg.slot, 0,
		pglogrepl.StartReplicationOptions{PluginArgs: pluginArgs}); err != nil {
		return err
	}

	relations := map[uint32]*pglogrepl.RelationMessage{}
	var txn *pendingTxn
	clientPos := pglogrepl.LSN(0)
	const standbyTimeout = 10 * time.Second
	nextStandby := time.Now().Add(standbyTimeout)

	for {
		if ctx.Err() != nil {
			return nil
		}
		if time.Now().After(nextStandby) {
			if err := pglogrepl.SendStandbyStatusUpdate(ctx, conn,
				pglogrepl.StandbyStatusUpdate{WALWritePosition: clientPos}); err != nil {
				return err
			}
			nextStandby = time.Now().Add(standbyTimeout)
		}

		rctx, rcancel := context.WithDeadline(ctx, nextStandby)
		raw, err := conn.ReceiveMessage(rctx)
		rcancel()
		if err != nil {
			if pgconn.Timeout(err) {
				continue // deadline to send the next standby update
			}
			if ctx.Err() != nil {
				return nil
			}
			return err
		}

		cd, ok := raw.(*pgproto3.CopyData)
		if !ok {
			continue // relation/type/origin/keepalive non-CopyData, nothing to do
		}
		switch cd.Data[0] {
		case pglogrepl.PrimaryKeepaliveMessageByteID:
			pkm, err := pglogrepl.ParsePrimaryKeepaliveMessage(cd.Data[1:])
			if err != nil {
				return err
			}
			if pkm.ReplyRequested {
				nextStandby = time.Time{} // send a status update on the next iteration
			}
		case pglogrepl.XLogDataByteID:
			xld, err := pglogrepl.ParseXLogData(cd.Data[1:])
			if err != nil {
				return err
			}
			acked, err := handleLogical(ctx, xld.WALData, relations, &txn, store, getTracked, &clientPos)
			if err != nil {
				return err
			}
			if acked {
				nextStandby = time.Time{} // acknowledge the durable commit promptly
			}
		}
	}
}

// handleLogical parses one pgoutput message and folds it into the pending txn.
// On a commit it persists the batch and, if written, advances clientPos to the
// commit's end LSN (returning acked=true so the caller acknowledges promptly).
func handleLogical(ctx context.Context, data []byte, relations map[uint32]*pglogrepl.RelationMessage,
	txn **pendingTxn, store *historyStore, getTracked func(uint32) (trackedTable, bool),
	clientPos *pglogrepl.LSN) (bool, error) {

	msg, err := pglogrepl.Parse(data)
	if err != nil {
		return false, err
	}
	switch m := msg.(type) {
	case *pglogrepl.RelationMessage:
		relations[m.RelationID] = m
	case *pglogrepl.BeginMessage:
		*txn = &pendingTxn{xid: int64(m.Xid), committedAt: m.CommitTime.UTC().Format("2006-01-02T15:04:05.000Z")}
	case *pglogrepl.InsertMessage:
		appendChange(*txn, relations, getTracked, m.RelationID, "I", nil, m.Tuple)
	case *pglogrepl.UpdateMessage:
		appendChange(*txn, relations, getTracked, m.RelationID, "U", m.OldTuple, m.NewTuple)
	case *pglogrepl.DeleteMessage:
		appendChange(*txn, relations, getTracked, m.RelationID, "D", m.OldTuple, nil)
	case *pglogrepl.CommitMessage:
		t := *txn
		*txn = nil
		if t == nil {
			return false, nil
		}
		batch := commitBatch{
			txid:         t.xid,
			committedAt:  t.committedAt,
			commitEndLSN: m.TransactionEndLSN.String(),
		}
		for _, c := range t.changes {
			batch.rows = append(batch.rows, mapChange(c.table, c.pkCols, c.change))
		}
		written, err := store.writeCommit(ctx, batch)
		if err != nil {
			return false, err
		}
		if written && len(batch.rows) > 0 {
			logInfo("committed", map[string]any{"txid": batch.txid, "rows": len(batch.rows), "lsn": batch.commitEndLSN})
		}
		*clientPos = m.TransactionEndLSN
		return true, nil
	}
	return false, nil
}

func appendChange(txn *pendingTxn, relations map[uint32]*pglogrepl.RelationMessage,
	getTracked func(uint32) (trackedTable, bool), relID uint32, op string, oldT, newT *pglogrepl.TupleData) {
	if txn == nil {
		return
	}
	tracked, ok := getTracked(relID)
	if !ok {
		return // not tracked (defensive, publication should already exclude it)
	}
	rel := relations[relID]
	txn.changes = append(txn.changes, pendingChange{
		table:  tracked.name,
		pkCols: tracked.pkCols,
		change: rowChange{op: op, before: tupleToRow(rel, oldT), after: tupleToRow(rel, newT)},
	})
}

// tupleToRow folds a decoded tuple into a name->text map. Unchanged-TOAST columns
// ('u') carry no value in the NEW image; with REPLICA IDENTITY FULL the full
// before-image still carries them, and undo reconstructs via jsonb_populate_record.
func tupleToRow(rel *pglogrepl.RelationMessage, t *pglogrepl.TupleData) row {
	if t == nil || rel == nil {
		return nil
	}
	m := row{}
	for i, col := range t.Columns {
		if i >= len(rel.Columns) {
			break
		}
		name := rel.Columns[i].Name
		switch col.DataType {
		case pglogrepl.TupleDataTypeNull, pglogrepl.TupleDataTypeToast:
			m[name] = nil
		default: // text (or binary, unused), store the raw value
			v := string(col.Data)
			m[name] = &v
		}
	}
	return m
}
