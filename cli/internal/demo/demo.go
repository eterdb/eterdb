// Package demo stands up (and tears down) the seeded e-commerce incident used
// to try EterDB: a single transaction whose buggy UPDATE corrupts every invoice
// amount, optionally followed by a later legitimate write that forces the
// conflict-review (dependent) path.
//
// The flow is factored into named steps (Seed, FireIncident, SampleInvoices)
// so both the non-interactive `eter demo up` and the interactive `eter demo`
// Bubble Tea walkthrough drive the exact same engine operations.
package demo

import (
	"context"
	"fmt"
	"os"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/eterdb/eterdb/cli/internal/client"
	"github.com/eterdb/eterdb/cli/internal/core"
)

// Demo data volume. The incident is far more convincing at scale: the runaway
// migration zeroes (and the surgical undo restores) tens of thousands of
// invoices, not a handful. These are the historical 5/4/20 baseline shape
// multiplied by demoScale (issue #182), so the row counts the walkthrough
// narrates, and the history/undo it exercises, are ~1000x larger.
const demoScale = 1000

const (
	demoCustomers = 5 * demoScale  // 5,000
	demoProducts  = 4 * demoScale  // 4,000
	demoOrders    = 20 * demoScale // 20,000 (invoices are 1:1 with orders)
)

// Result is the JSON payload reported by `eter demo up`.
type Result struct {
	IncidentTxid      int64  `json:"incident_txid"`
	InvoicesCorrupted int    `json:"invoices_corrupted"`
	DependentTxid     *int64 `json:"dependent_txid"`
	Pgvector          bool   `json:"pgvector"`
	DashboardHint     string `json:"dashboard_hint"`
}

// InvoiceRow is one invoice sampled for the before/after narration the TUI shows
// (the raw dollars an operator watches get corrupted, then restored).
type InvoiceRow struct {
	ID      int64  `json:"id"`
	OrderID int64  `json:"order_id"`
	Cents   int64  `json:"cents"`
	Status  string `json:"status"`
	Stripe  string `json:"stripe_charge_id"`
}

// SeedResult summarises the baseline data planted before the incident.
type SeedResult struct {
	Customers int  `json:"customers"`
	Products  int  `json:"products"`
	Orders    int  `json:"orders"`
	Invoices  int  `json:"invoices"`
	Pgvector  bool `json:"pgvector"`
	// Watermark is the txid of the last seed write. The ~49k-row seed (issue
	// #182's 1000x boost) is captured asynchronously by the sidecar, so callers
	// wait for capture to reach this txid BEFORE firing the incident, draining
	// the seed out of the pipeline so the incident's own capture wait measures
	// only the incident, not the seed queued ahead of it.
	Watermark int64 `json:"-"`
}

// IncidentResult carries the incident: the destructive transaction's id, how
// many invoices it corrupted, and a before/after sample of the same rows.
type IncidentResult struct {
	Txid      int64        `json:"incident_txid"`
	Corrupted int          `json:"invoices_corrupted"`
	Before    []InvoiceRow `json:"before"`
	After     []InvoiceRow `json:"after"`
}

// demoPool forces search_path to public so demo tables never land in the eter
// engine schema (which happens when the connecting role is itself named "eter").
//
// The demo runs against the control plane: capture is the sidecar (logical
// decoding), which fills eter.history asynchronously into the meta store. So the
// demo's writes (seed, incident) go to the tenant through this pool, but reads
// (log, preview, undo) go through a meta-aware client, and WaitForCapture bridges
// the async gap before the first read. There is no trigger pin; capture is the
// same path a real deployment uses.
func demoPool(ctx context.Context, dsn string) (*pgxpool.Pool, error) {
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, err
	}
	if cfg.ConnConfig.RuntimeParams == nil {
		cfg.ConnConfig.RuntimeParams = map[string]string{}
	}
	cfg.ConnConfig.RuntimeParams["application_name"] = "eter-demo"
	cfg.ConnConfig.RuntimeParams["search_path"] = "public, eter"
	return pgxpool.NewWithConfig(ctx, cfg)
}

// WaitForCapture blocks until txid's writes have been captured into eter.history
// (the meta store, in the two-DB control-plane shape), so a log/preview right
// after an incident is deterministic under async sidecar capture. Best-effort
// with a bounded timeout: returns nil once the rows land, or an error the caller
// can surface as "capture never arrived (is the control plane running?)".
func WaitForCapture(ctx context.Context, c interface {
	Show(context.Context, int64) ([]map[string]any, error)
}, txid int64) error {
	return WaitForCaptureTimeout(ctx, c, txid, 20*time.Second)
}

// WaitForCaptureTimeout is WaitForCapture with a caller-chosen bound. Draining the
// seed backlog (SeedResult.Watermark) needs a longer window than the incident wait,
// since the whole boosted seed decodes ahead of it.
func WaitForCaptureTimeout(ctx context.Context, c interface {
	Show(context.Context, int64) ([]map[string]any, error)
}, txid int64, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	delay := 100 * time.Millisecond
	for {
		rows, err := c.Show(ctx, txid)
		if err != nil {
			return err
		}
		if len(rows) > 0 {
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("capture did not arrive for txid %d within %s; is the capture sidecar (control plane) running against this database?", txid, timeout)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(delay):
		}
		if delay < 2*time.Second {
			delay *= 2
		}
	}
}

// waitForSeedDrain blocks until capture has caught up through the seed watermark,
// so a subsequently-fired incident isn't queued behind the (boosted) seed backlog.
// No-op if there is no watermark (e.g. trigger mode, where capture is synchronous).
func waitForSeedDrain(ctx context.Context, dsn string, sr *SeedResult) error {
	if sr == nil || sr.Watermark == 0 {
		return nil
	}
	c, err := client.NewDirectClient(ctx, dsn)
	if err != nil {
		return err
	}
	defer c.Close()
	return WaitForCaptureTimeout(ctx, c, sr.Watermark, 120*time.Second)
}

// seed installs the engine + schema, plants the baseline data, and starts
// tracking everything BEFORE any incident, so the incident is captured. It runs
// on a caller-provided pool so Up (and the TUI) can reuse a single connection.
func seed(ctx context.Context, pool *pgxpool.Pool) (*SeedResult, error) {
	eterSQL, err := core.EterSQLFile()
	if err != nil {
		return nil, err
	}
	schemaSQL, err := core.DemoSchemaFile()
	if err != nil {
		return nil, err
	}
	eterBytes, err := os.ReadFile(eterSQL) //nolint:gosec // SQL path resolved from repo layout / ETER_SQL_FILE, operator-controlled
	if err != nil {
		return nil, err
	}
	schemaBytes, err := os.ReadFile(schemaSQL) //nolint:gosec // demo schema path resolved from repo layout / ETER_DEMO_SCHEMA
	if err != nil {
		return nil, err
	}

	// 1. Engine + schema.
	if _, err := pool.Exec(ctx, string(eterBytes)); err != nil {
		return nil, err
	}
	if _, err := pool.Exec(ctx, string(schemaBytes)); err != nil {
		return nil, err
	}

	// pgvector is optional: add the embedding column only if the extension is
	// available, so the demo runs anywhere but showcases compatibility where it can.
	hasVector := false
	if _, err := pool.Exec(ctx, "CREATE EXTENSION IF NOT EXISTS vector"); err == nil {
		if _, err := pool.Exec(ctx, "ALTER TABLE public.products ADD COLUMN IF NOT EXISTS embedding vector(3)"); err == nil {
			hasVector = true
		}
	}

	// 2. Seed baseline data (each statement is its own committed transaction).
	//    Sizes are demoScale-multiplied (issue #182); the first few rows keep the
	//    recognizable names the original demo used so a spot check still reads well.
	if _, err := pool.Exec(ctx, `
      INSERT INTO public.customers (name, email)
      SELECT COALESCE(n.name, 'Customer ' || g),
             COALESCE(n.email, 'customer' || g || '@example.com')
      FROM generate_series(1, $1) g
      LEFT JOIN (VALUES
        (1,'Ada Lovelace','ada@example.com'),
        (2,'Alan Turing','alan@example.com'),
        (3,'Grace Hopper','grace@example.com'),
        (4,'Katherine Johnson','katherine@example.com'),
        (5,'Edsger Dijkstra','edsger@example.com')) AS n(id,name,email) ON n.id = g`,
		demoCustomers); err != nil {
		return nil, err
	}
	if _, err := pool.Exec(ctx, `
      INSERT INTO public.products (name, price_cents)
      SELECT COALESCE(n.name, 'Product ' || g),
             COALESCE(n.price, 5000 + (g % 40) * 1000)
      FROM generate_series(1, $1) g
      LEFT JOIN (VALUES
        (1,'Mechanical keyboard',12000),
        (2,'Standing desk',38000),
        (3,'Monitor 27"',29000),
        (4,'Webcam',8000)) AS n(id,name,price) ON n.id = g`,
		demoProducts); err != nil {
		return nil, err
	}
	if hasVector {
		// Give every product a deterministic little embedding (the first four match
		// the original hand-picked vectors) so the pgvector compatibility claim is
		// exercised across the whole boosted catalogue, not just four rows.
		if _, err := pool.Exec(ctx, `UPDATE public.products SET embedding = CASE id
          WHEN 1 THEN '[0.1,0.2,0.3]'::vector WHEN 2 THEN '[0.4,0.1,0.9]'::vector
          WHEN 3 THEN '[0.2,0.7,0.2]'::vector WHEN 4 THEN '[0.9,0.1,0.1]'::vector
          ELSE ('[' || (id % 10) / 10.0 || ',' || (id % 7) / 10.0 || ',' || (id % 3) / 10.0 || ']')::vector
          END`); err != nil {
			return nil, err
		}
	}
	if _, err := pool.Exec(ctx, `
      INSERT INTO public.orders (customer_id, status, total_cents)
      SELECT (1 + (g % $1)), 'placed', 5000 + (g * 1300)
      FROM generate_series(1, $2) g`, demoCustomers, demoOrders); err != nil {
		return nil, err
	}
	if _, err := pool.Exec(ctx, `
      INSERT INTO public.invoices (order_id, amount_cents, status, stripe_charge_id)
      SELECT id, total_cents, 'issued',
             'ch_' || substr(md5(random()::text || id::text), 1, 24)
      FROM public.orders`); err != nil {
		return nil, err
	}

	// 3. Track everything BEFORE the incident so it is captured.
	if _, err := pool.Exec(ctx, "SELECT eter.track_all()"); err != nil {
		return nil, err
	}
	if _, err := pool.Exec(ctx, "SELECT eter.mark('demo seeded', 'demo')"); err != nil {
		return nil, err
	}

	// 3b. A little normal business activity AFTER capture is on, so `eter log`
	// shows real traffic the incident stands out against (and unrelated rows
	// that must survive the undo). Each statement is its own transaction; all are
	// UPDATEs so the headline row counts below stay the seed baseline.
	for _, q := range []string{
		"UPDATE public.orders SET status = 'shipped' WHERE id <= 3",
		"UPDATE public.customers SET email = 'ada@lovelace.dev' WHERE id = 1",
	} {
		if _, err := pool.Exec(ctx, q); err != nil {
			return nil, err
		}
	}
	// The last seed write returns its txid: capture recording this in history means
	// the whole seed ahead of it has drained too (logical decoding is commit-ordered).
	var watermark int64
	if err := pool.QueryRow(ctx, `
      WITH upd AS (UPDATE public.products SET price_cents = 12500 WHERE id = 1 RETURNING 1)
      SELECT txid_current()::bigint FROM upd LIMIT 1`).Scan(&watermark); err != nil {
		return nil, err
	}

	res := &SeedResult{Pgvector: hasVector, Watermark: watermark}
	for _, c := range []struct {
		table string
		dst   *int
	}{
		{"public.customers", &res.Customers},
		{"public.products", &res.Products},
		{"public.orders", &res.Orders},
		{"public.invoices", &res.Invoices},
	} {
		if err := pool.QueryRow(ctx, "SELECT count(*) FROM "+c.table).Scan(c.dst); err != nil {
			return nil, err
		}
	}
	return res, nil
}

// sampleInvoices returns the first `limit` invoices by id, the rows the
// before/after narration follows across the incident and the undo.
func sampleInvoices(ctx context.Context, pool *pgxpool.Pool, limit int) ([]InvoiceRow, error) {
	rows, err := pool.Query(ctx, `
      SELECT id, order_id, amount_cents, status, stripe_charge_id
      FROM public.invoices ORDER BY id LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []InvoiceRow
	for rows.Next() {
		var r InvoiceRow
		if err := rows.Scan(&r.ID, &r.OrderID, &r.Cents, &r.Status, &r.Stripe); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// fireIncident is THE incident: one transaction, one destructive statement. A
// migration meant to clear draft amounts forgets its WHERE clause and zeroes
// EVERY invoice. This is deliberately lossy: the original amounts are gone, so
// no forward UPDATE can recompute them; only the before-image EterDB captured
// (or a point-in-time restore) brings them back. It samples the same rows before
// and after so the caller can show the damage.
func fireIncident(ctx context.Context, pool *pgxpool.Pool) (*IncidentResult, error) {
	before, err := sampleInvoices(ctx, pool, 4)
	if err != nil {
		return nil, err
	}
	if _, err := pool.Exec(ctx, "SELECT eter.mark('migration: reset draft amounts', 'demo')"); err != nil {
		return nil, err
	}
	var txid int64
	if err := pool.QueryRow(ctx, `
      WITH upd AS (UPDATE public.invoices SET amount_cents = 0 RETURNING 1)
      SELECT txid_current()::bigint FROM upd LIMIT 1`).Scan(&txid); err != nil {
		return nil, err
	}
	// Count the corrupted rows from the user table, not eter.history: the incident
	// zeroed every invoice, so this equals the rows it touched, and unlike a
	// history read it does not depend on synchronous capture.
	var corrupted int
	if err := pool.QueryRow(ctx, "SELECT count(*) FROM public.invoices").Scan(&corrupted); err != nil {
		return nil, err
	}
	after, err := sampleInvoices(ctx, pool, 4)
	if err != nil {
		return nil, err
	}
	return &IncidentResult{Txid: txid, Corrupted: corrupted, Before: before, After: after}, nil
}

// Seed opens a demo pool and plants the baseline data (schema + rows + tracking),
// stopping short of the incident. Used by the interactive walkthrough.
func Seed(ctx context.Context, dsn string) (*SeedResult, error) {
	pool, err := demoPool(ctx, dsn)
	if err != nil {
		return nil, err
	}
	defer pool.Close()
	// The caller (the interactive walkthrough) drains the seed through capture with
	// its own meta-aware client before firing the incident; Seed just plants the
	// data and reports the watermark txid to drain to (SeedResult.Watermark).
	return seed(ctx, pool)
}

// FireIncident opens a demo pool and fires the destructive zero-out transaction,
// returning the txid and a before/after sample. Used by the interactive walkthrough.
func FireIncident(ctx context.Context, dsn string) (*IncidentResult, error) {
	pool, err := demoPool(ctx, dsn)
	if err != nil {
		return nil, err
	}
	defer pool.Close()
	return fireIncident(ctx, pool)
}

// SampleInvoices opens a demo pool and returns the first `limit` invoices. The
// interactive walkthrough re-samples after the undo to show the rows restored.
func SampleInvoices(ctx context.Context, dsn string, limit int) ([]InvoiceRow, error) {
	pool, err := demoPool(ctx, dsn)
	if err != nil {
		return nil, err
	}
	defer pool.Close()
	return sampleInvoices(ctx, pool, limit)
}

// OrderCount returns the number of rows in public.orders, used by the recovery
// act to show the table gone (0 / missing) and then restored.
func OrderCount(ctx context.Context, dsn string) (int, error) {
	pool, err := demoPool(ctx, dsn)
	if err != nil {
		return 0, err
	}
	defer pool.Close()
	var n int
	if err := pool.QueryRow(ctx, "SELECT count(*) FROM public.orders").Scan(&n); err != nil {
		return 0, err
	}
	return n, nil
}

// OrdersExist reports whether the public.orders table is present. The recovery
// act uses it to prove the table was really dropped, then really restored.
func OrdersExist(ctx context.Context, dsn string) (bool, error) {
	pool, err := demoPool(ctx, dsn)
	if err != nil {
		return false, err
	}
	defer pool.Close()
	var exists bool
	if err := pool.QueryRow(ctx,
		"SELECT to_regclass('public.orders') IS NOT NULL").Scan(&exists); err != nil {
		return false, err
	}
	return exists, nil
}

// DropOrders drops the public.orders table (a destructive DDL "incident" that no
// row-level undo can reverse; only object recovery from a base backup can).
func DropOrders(ctx context.Context, dsn string) error {
	pool, err := demoPool(ctx, dsn)
	if err != nil {
		return err
	}
	defer pool.Close()
	// invoices references orders; CASCADE drops the FK, and the recovery test
	// path (drop-cascade) shows recover-table restores the parent table cleanly.
	_, err = pool.Exec(ctx, "DROP TABLE public.orders CASCADE")
	return err
}

// Up seeds the schema + data and fires the incident.
func Up(ctx context.Context, dsn string, dependent bool) (*Result, error) {
	pool, err := demoPool(ctx, dsn)
	if err != nil {
		return nil, err
	}
	defer pool.Close()

	// 1-3. Engine, schema, seed data, tracking.
	sr, err := seed(ctx, pool)
	if err != nil {
		return nil, err
	}

	// 4. A little legitimate background traffic (unrelated rows, must survive undo).
	if _, err := pool.Exec(ctx, "UPDATE public.orders SET status = 'shipped' WHERE id <= 5"); err != nil {
		return nil, err
	}

	// 4b. Drain the seed backlog through capture before the incident, so the
	//     incident's capture wait (step 7) measures only the incident, not the
	//     ~49k-row seed (issue #182) queued ahead of it in the async pipeline.
	if err := waitForSeedDrain(ctx, dsn, sr); err != nil {
		return nil, err
	}

	// 5. THE INCIDENT.
	inc, err := fireIncident(ctx, pool)
	if err != nil {
		return nil, err
	}

	// 6. Optional dependent follow-up: a later legitimate write to one corrupted
	//    invoice, creating a write-write conflict so undo is classified dependent.
	var dependentTxid *int64
	if dependent {
		var dep int64
		if err := pool.QueryRow(ctx, `
          WITH upd AS (UPDATE public.invoices SET status='paid' WHERE id=1 RETURNING 1)
          SELECT txid_current()::bigint FROM upd LIMIT 1`).Scan(&dep); err != nil {
			return nil, err
		}
		dependentTxid = &dep
	}

	// Wait for the capture sidecar to record the incident (and any dependent) into
	// the meta store, so a subsequent `eter preview`/`log` is deterministic under
	// async capture. A meta-aware client reads history wherever the sidecar writes.
	waitTxid := inc.Txid
	if dependentTxid != nil {
		waitTxid = *dependentTxid
	}
	c, err := client.NewDirectClient(ctx, dsn)
	if err != nil {
		return nil, err
	}
	defer c.Close()
	if err := WaitForCapture(ctx, c, waitTxid); err != nil {
		return nil, err
	}

	return &Result{
		IncidentTxid:      inc.Txid,
		InvoicesCorrupted: inc.Corrupted,
		DependentTxid:     dependentTxid,
		Pgvector:          sr.Pgvector,
		DashboardHint:     "Run: eter preview " + strconv.FormatInt(inc.Txid, 10),
	}, nil
}

// Down drops the demo schema and clears captured history.
func Down(ctx context.Context, dsn string) error {
	pool, err := demoPool(ctx, dsn)
	if err != nil {
		return err
	}
	defer pool.Close()

	if _, err := pool.Exec(ctx, "DROP TABLE IF EXISTS public.invoices, public.orders, public.products, public.customers CASCADE"); err != nil {
		return err
	}
	if _, err := pool.Exec(ctx, "TRUNCATE eter.history, eter.dependencies, eter.markers, eter.tracked, eter.capture_state, eter.undo_txn"); err != nil {
		return err
	}
	// Sidecar-aware teardown (no-op in trigger mode): drop the logical slot so it
	// stops retaining WAL and the next demo starts from a clean cursor.
	_, err = pool.Exec(ctx, `DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name='eter_slot' AND NOT active) THEN
        PERFORM pg_drop_replication_slot('eter_slot');
      END IF;
      IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname='eter_pub') THEN
        DROP PUBLICATION eter_pub;
      END IF;
    EXCEPTION WHEN OTHERS THEN NULL; END $$;`)
	return err
}
