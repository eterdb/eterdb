package demotui

import (
	"context"
	"os"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/eterdb/eterdb/cli/internal/client"
	"github.com/eterdb/eterdb/cli/internal/core"
	"github.com/eterdb/eterdb/cli/internal/demo"
)

// stubJobs is a no-op client.JobClient: it only has to be non-nil so the model
// takes the recovery-act branch. The transition test feeds droppedMsg/
// recoveredMsg directly rather than running the jobs, so these are never called.
type stubJobs struct{}

func (stubJobs) SubmitStorageJob(context.Context, string, map[string]any) (int64, error) {
	return 1, nil
}
func (stubJobs) GetJob(context.Context, int64) (map[string]any, error)   { return nil, nil }
func (stubJobs) ListJobs(context.Context, int) ([]map[string]any, error) { return nil, nil }
func (stubJobs) CancelJob(context.Context, int64) error                  { return nil }

// fed advances the model by delivering a message (as the Bubble Tea runtime
// would), asserting the resulting stage and that the scene renders non-empty.
func fed(t *testing.T, m Model, msg tea.Msg, want stage) Model {
	t.Helper()
	next, _ := m.Update(msg)
	nm := next.(Model)
	if nm.stage != want {
		t.Fatalf("after %T: stage = %d, want %d", msg, nm.stage, want)
	}
	if strings.TrimSpace(nm.View()) == "" {
		t.Fatalf("empty view at stage %d", nm.stage)
	}
	return nm
}

// adv presses enter, asserting the model moves to the expected (usually running)
// stage. It does not execute the returned command, so no DB/orchestrator is hit.
func adv(t *testing.T, m Model, want stage) Model {
	t.Helper()
	next, _ := m.advance()
	nm := next.(Model)
	if nm.stage != want {
		t.Fatalf("after enter from %d: stage = %d, want %d", m.stage, nm.stage, want)
	}
	return nm
}

// sampleIncident is representative data so every scene renders with real-shaped
// content (the zeroed incident + its before/after sample).
func sampleData() (*demo.SeedResult, *demo.IncidentResult, []map[string]any, *core.UndoPlan, []demo.InvoiceRow) {
	seed := &demo.SeedResult{Customers: 5, Products: 4, Orders: 20, Invoices: 20}
	inc := &demo.IncidentResult{
		Txid: 1234, Corrupted: 20,
		Before: []demo.InvoiceRow{{ID: 1, Cents: 6300}, {ID: 2, Cents: 7600}},
		After:  []demo.InvoiceRow{{ID: 1, Cents: 0}, {ID: 2, Cents: 0}},
	}
	log := []map[string]any{
		{"txid": int64(1234), "table_name": "invoices", "updates": int64(20)},
		{"txid": int64(1230), "table_name": "orders", "updates": int64(3)},
	}
	plan := &core.UndoPlan{Txid: 1234, Classification: "clean", OpCount: 20}
	restored := []demo.InvoiceRow{{ID: 1, Cents: 6300}, {ID: 2, Cents: 7600}}
	return seed, inc, log, plan, restored
}

// TestStageMachine drives every scene of the walkthrough (both acts) with fed
// messages and enter presses, asserting the full transition graph and that each
// scene renders. It touches no database or orchestrator, so it is deterministic
// and green in CI.
func TestStageMachine(t *testing.T) {
	seed, inc, log, plan, restored := sampleData()
	m := New(context.Background(), "postgres://eter@localhost:5432/eter", nil, stubJobs{})
	m.width = 80
	if m.stage != stageIntro {
		t.Fatalf("initial stage = %d, want intro", m.stage)
	}
	if strings.TrimSpace(m.View()) == "" {
		t.Fatal("empty intro view")
	}

	// Act one: seed → incident → investigate → preview → undo.
	m = adv(t, m, stageSeeding)
	m = fed(t, m, seededMsg{res: seed, snapshot: "demo-auto-01"}, stageSeeded)
	if !strings.Contains(m.View(), "automatic") {
		t.Fatal("seeded scene should note base backups are automatic")
	}
	m = adv(t, m, stageFiring)
	m = fed(t, m, incidentMsg{inc}, stageDamage)
	m = adv(t, m, stageInvestigating)
	m = fed(t, m, logMsg{log}, stageLog)
	m = adv(t, m, stagePreviewing)
	m = fed(t, m, previewMsg{plan}, stagePreview)
	m = adv(t, m, stageUndoing)
	m = fed(t, m, undoneMsg{restored: restored, ops: 20}, stageRestored)

	// Act two (recovery present): drop → recover → done.
	m = adv(t, m, stageDropping)
	m = fed(t, m, droppedMsg{before: 20, exists: false}, stageDropped)
	m = adv(t, m, stageRecovering)
	m = fed(t, m, recoveredMsg{exists: true, rows: 20}, stageDone)
	if strings.Contains(m.View(), "recover-table") == false {
		t.Fatal("final scene should mention recover-table")
	}
}

// TestNoRecoveryEndsAtRestored proves the row story is self-contained: with no
// orchestrator (recover == nil), enter at the restored scene quits rather than
// entering the recovery act.
func TestNoRecoveryEndsAtRestored(t *testing.T) {
	seed, inc, log, plan, restored := sampleData()
	m := New(context.Background(), "postgres://eter@localhost:5432/eter", nil, nil)
	m.width = 80
	m = fed(t, m, seededMsg{res: seed}, stageSeeded)
	m = fed(t, m, incidentMsg{inc}, stageDamage)
	m = fed(t, m, logMsg{log}, stageLog)
	m = fed(t, m, previewMsg{plan}, stagePreview)
	m = fed(t, m, undoneMsg{restored: restored, ops: 20}, stageRestored)
	// enter at restored with no recovery → quit (stage unchanged, tea.Quit cmd).
	next, cmd := m.advance()
	if next.(Model).stage != stageRestored {
		t.Fatalf("stage changed on enter with no recovery: %d", next.(Model).stage)
	}
	if cmd == nil {
		t.Fatal("expected a quit command")
	}
}

// TestErrorScene proves any step's error routes to the error scene and Failed().
func TestErrorScene(t *testing.T) {
	m := New(context.Background(), "postgres://eter@localhost:5432/eter", nil, stubJobs{})
	m.width = 80
	m = fed(t, m, errMsg{err: context.DeadlineExceeded}, stageError)
	if !m.Failed() {
		t.Fatal("Failed() should be true at the error scene")
	}
}

// TestWalkthroughAgainstLiveDB drives act one against a real database. Gated on
// ETER_DEMO_DSN, so it is a no-op without a Postgres to talk to.
//
//	ETER_DEMO_DSN=postgres://eter@127.0.0.1:5599/eter go test ./internal/demotui/ -run Walkthrough -v
func TestWalkthroughAgainstLiveDB(t *testing.T) {
	dsn := os.Getenv("ETER_DEMO_DSN")
	if dsn == "" {
		t.Skip("set ETER_DEMO_DSN to run the live walkthrough integration test")
	}
	ctx := context.Background()
	_ = demo.Down(ctx, dsn)

	c, err := client.NewDirectClient(ctx, dsn)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer c.Close()

	m := New(ctx, dsn, c, nil)
	step := func(cmd tea.Cmd, want stage) {
		t.Helper()
		msg := cmd()
		if e, ok := msg.(errMsg); ok {
			t.Fatalf("engine step errored: %v", e.err)
		}
		next, _ := m.Update(msg)
		m = next.(Model)
		if m.stage != want {
			t.Fatalf("stage = %d, want %d", m.stage, want)
		}
	}

	step(m.seedCmd(), stageSeeded)
	// Invoices are 1:1 with orders; assert the relationship, not a fixed count,
	// so the check survives demoScale changes (issue #182 boosted the seed 1000x).
	if m.seed.Invoices == 0 || m.seed.Invoices != m.seed.Orders {
		t.Fatalf("seeded invoices = %d, orders = %d (want equal, non-zero)", m.seed.Invoices, m.seed.Orders)
	}
	// Firing streams fireProgressMsg heartbeats before the incidentMsg; drive the
	// channel to completion the way the Update loop does.
	cmd := m.fireCmd()
	for {
		msg := cmd()
		if e, ok := msg.(errMsg); ok {
			t.Fatalf("fire errored: %v", e.err)
		}
		next, _ := m.Update(msg)
		m = next.(Model)
		if _, ok := msg.(incidentMsg); ok {
			break
		}
		cmd = m.waitFireCmd()
	}
	if m.stage != stageDamage {
		t.Fatalf("after fire: stage = %d, want %d", m.stage, stageDamage)
	}
	if m.incident.Corrupted != m.seed.Invoices || m.incident.Before[0].Cents == 0 || m.incident.After[0].Cents != 0 {
		t.Fatalf("incident did not zero the amounts: corrupted=%d before=%v after=%v", m.incident.Corrupted, m.incident.Before, m.incident.After)
	}
	step(m.logCmd(), stageLog)
	found := false
	for _, r := range m.log {
		if numOf(r, "txid") == m.incident.Txid {
			found = true
		}
	}
	if !found {
		t.Fatalf("incident txid %d not found in eter log", m.incident.Txid)
	}
	step(m.previewCmd(), stagePreview)
	if m.plan.Classification != "clean" {
		t.Fatalf("classification = %q, want clean", m.plan.Classification)
	}
	step(m.undoCmd(), stageRestored)
	if m.ops != m.incident.Corrupted || m.restored[0].Cents != m.incident.Before[0].Cents {
		t.Fatalf("row not restored: ops=%d corrupted=%d got=%d want=%d", m.ops, m.incident.Corrupted, m.restored[0].Cents, m.incident.Before[0].Cents)
	}
}

// TestRecoveryAgainstLiveStack drives act two (drop a table, recover it) against
// a real orchestrator. Gated on ETER_DEMO_DSN + ETER_URL + ETER_TOKEN.
//
//	ETER_DEMO_DSN=… ETER_URL=http://localhost:4400 ETER_TOKEN=… \
//	  go test ./internal/demotui/ -run Recovery -v
func TestRecoveryAgainstLiveStack(t *testing.T) {
	dsn := os.Getenv("ETER_DEMO_DSN")
	url, token := os.Getenv("ETER_URL"), os.Getenv("ETER_TOKEN")
	if dsn == "" || url == "" || token == "" {
		t.Skip("set ETER_DEMO_DSN + ETER_URL + ETER_TOKEN to run the live recovery test")
	}
	ctx := context.Background()
	_ = demo.Down(ctx, dsn)

	// Match the real two-container wiring: the orchestrator is BOTH the meta-aware
	// history client and the storage-job client (the host cannot reach the
	// in-container meta store directly).
	orch := client.NewHostedClient(url, token)

	m := New(ctx, dsn, orch, orch)
	run := func(cmd tea.Cmd, want stage) {
		t.Helper()
		msg := cmd()
		if e, ok := msg.(errMsg); ok {
			t.Fatalf("step errored: %v", e.err)
		}
		next, _ := m.Update(msg)
		m = next.(Model)
		if m.stage != want {
			t.Fatalf("stage = %d, want %d", m.stage, want)
		}
	}
	// Seed enough to have an orders table to drop, and install the engine via the
	// orchestrator so DDL logging + archiving are on for lossless recovery.
	run(m.seedCmd(), stageSeeded)
	if m.snapshot == "" {
		t.Fatal("seed should have taken an automatic base backup (for lossless table recovery)")
	}
	if _, err := orch.Init(ctx); err != nil {
		t.Fatalf("orchestrator init: %v", err)
	}
	// Jump straight to the recovery act.
	m.stage = stageRestored
	run(m.dropCmd(), stageDropped)
	if m.ordersBefore == 0 {
		t.Fatalf("expected orders before drop, got %d", m.ordersBefore)
	}
	run(m.recoverCmd(), stageDone)
	if m.ordersAfter != m.ordersBefore {
		t.Fatalf("recovered rows = %d, want %d", m.ordersAfter, m.ordersBefore)
	}
}
