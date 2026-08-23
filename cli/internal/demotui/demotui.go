// Package demotui is the interactive `eter demo` walkthrough: a Bubble Tea
// program that narrates the EterDB story end to end: seed a live database,
// fire a production incident, ask EterDB what happened, and surgically reverse
// it, driving the real engine at every step (nothing is faked).
//
// It reuses the same operations as the non-interactive `eter demo up`
// (internal/demo) plus the frozen preview/undo client surface, so the TUI is a
// front-end over the real system, not a separate script.
package demotui

import (
	"context"
	"fmt"
	"time"

	"github.com/charmbracelet/bubbles/spinner"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/jackc/pgx/v5"

	"github.com/eterdb/eterdb/cli/internal/client"
	"github.com/eterdb/eterdb/cli/internal/core"
	"github.com/eterdb/eterdb/cli/internal/demo"
)

type stage int

const (
	stageIntro stage = iota
	stageSeeding
	stageSeeded
	stageFiring
	stageDamage
	stageInvestigating
	stageLog
	stagePreviewing
	stagePreview
	stageUndoing
	stageRestored // row story done (invoices reverted); act two begins here
	stageDropping
	stageDropped
	stageRecovering
	stageDone
	stageError
)

// Messages carrying the result of each async engine step.
type (
	seededMsg struct {
		res      *demo.SeedResult
		snapshot string // base backup EterDB takes automatically when it starts managing the DB
	}
	incidentMsg struct{ res *demo.IncidentResult }
	// fireProgressMsg streams the firing stage's progress so it never reads as
	// stuck while capture drains the (boosted) seed backlog: rows is the running
	// count of changes captured so far; applying flips true once capture has
	// caught up and the migration itself is running.
	fireProgressMsg struct {
		rows     int
		applying bool
	}
	logMsg     struct{ rows []map[string]any }
	previewMsg  struct{ plan *core.UndoPlan }
	undoneMsg   struct {
		restored []demo.InvoiceRow
		ops      int
	}
	droppedMsg struct {
		before int
		exists bool
	}
	recoveredMsg struct {
		exists bool
		rows   int
	}
	logoTickMsg struct{}
	errMsg      struct{ err error }
)

// Model is the walkthrough state machine.
type Model struct {
	ctx     context.Context
	dsn     string
	client  client.EterClient
	recover client.JobClient // orchestrator storage jobs (nil => stop after the row story)

	stage   stage
	spinner spinner.Model
	width   int
	conn    string // sanitized connection URL shown so the demo reads as a real DB

	seed     *demo.SeedResult
	incident *demo.IncidentResult
	log      []map[string]any

	// Firing stage: fireCh streams progress/completion from the drain+fire
	// goroutine; captureRows/applying drive the live "capture catching up…" scene.
	fireCh      chan tea.Msg
	captureRows int
	applying    bool
	plan     *core.UndoPlan
	restored []demo.InvoiceRow
	ops      int

	// Act two: destructive DDL + object recovery.
	ordersBefore int
	snapshot     string
	ordersAfter  int

	logoFrame int // animated intro logo

	err error
}

// logoTick drives the intro's spinning-ring logo animation.
func (m Model) logoTick() tea.Cmd {
	return tea.Tick(110*time.Millisecond, func(time.Time) tea.Msg { return logoTickMsg{} })
}

// New builds the walkthrough model. dsn seeds/samples/drops on the tenant; c is
// the frozen log/preview/undo client (the row story); recover drives the
// orchestrator's storage jobs for the table-recovery act (nil ends the demo
// after the row story).
func New(ctx context.Context, dsn string, c client.EterClient, recover client.JobClient) Model {
	sp := spinner.New()
	sp.Spinner = spinner.Dot
	sp.Style = accentStyle
	return Model{ctx: ctx, dsn: dsn, client: c, recover: recover, stage: stageIntro, spinner: sp,
		conn: connDisplay(dsn), fireCh: make(chan tea.Msg)}
}

// connDisplay renders the DSN as a copy-pasteable connection URL with the
// password stripped, so the seed step can show that the demo is a real,
// reachable database the operator can open in any client.
func connDisplay(dsn string) string {
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		return ""
	}
	at := ""
	if cfg.User != "" {
		at = cfg.User + "@"
	}
	return fmt.Sprintf("postgres://%s%s:%d/%s", at, cfg.Host, cfg.Port, cfg.Database)
}

func (m Model) Init() tea.Cmd { return tea.Batch(m.spinner.Tick, m.logoTick()) }

// Failed reports whether the walkthrough ended on an error, so the caller can
// map it to a non-zero exit code.
func (m Model) Failed() bool { return m.stage == stageError }

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		return m, nil

	case tea.KeyMsg:
		switch msg.String() {
		case "ctrl+c", "q", "esc":
			return m, tea.Quit
		case "enter", " ":
			return m.advance()
		}
		return m, nil

	case seededMsg:
		m.seed = msg.res
		m.snapshot = msg.snapshot
		m.stage = stageSeeded
		return m, nil
	case fireProgressMsg:
		// A progress heartbeat from the firing goroutine; keep reading the channel
		// until it delivers the incident (or an error). The spinner keeps animating
		// via its own tick chain in the default case.
		m.captureRows = msg.rows
		m.applying = msg.applying
		return m, m.waitFireCmd()
	case incidentMsg:
		m.incident = msg.res
		m.stage = stageDamage
		return m, nil
	case logMsg:
		m.log = msg.rows
		m.stage = stageLog
		return m, nil
	case previewMsg:
		m.plan = msg.plan
		m.stage = stagePreview
		return m, nil
	case undoneMsg:
		m.restored = msg.restored
		m.ops = msg.ops
		m.stage = stageRestored
		return m, nil
	case droppedMsg:
		m.ordersBefore = msg.before
		m.stage = stageDropped
		return m, nil
	case recoveredMsg:
		m.ordersAfter = msg.rows
		m.stage = stageDone
		return m, nil
	case logoTickMsg:
		// Only the intro shows the logo; stop ticking once the story starts.
		if m.stage != stageIntro {
			return m, nil
		}
		m.logoFrame++
		return m, m.logoTick()
	case errMsg:
		m.err = msg.err
		m.stage = stageError
		return m, nil

	default:
		var cmd tea.Cmd
		m.spinner, cmd = m.spinner.Update(msg)
		return m, cmd
	}
}

// advance moves the story forward on enter/space, kicking off the next engine
// step. During a running (spinner) stage it is a no-op; on the final stage it
// quits.
func (m Model) advance() (tea.Model, tea.Cmd) {
	switch m.stage {
	case stageIntro:
		m.stage = stageSeeding
		return m, tea.Batch(m.spinner.Tick, m.seedCmd())
	case stageSeeded:
		m.stage = stageFiring
		return m, tea.Batch(m.spinner.Tick, m.fireCmd())
	case stageDamage:
		m.stage = stageInvestigating
		return m, tea.Batch(m.spinner.Tick, m.logCmd())
	case stageLog:
		m.stage = stagePreviewing
		return m, tea.Batch(m.spinner.Tick, m.previewCmd())
	case stagePreview:
		m.stage = stageUndoing
		return m, tea.Batch(m.spinner.Tick, m.undoCmd())
	case stageRestored:
		// Act two needs the orchestrator (base backups + WAL replay). Without it
		// the row story is the whole demo.
		if m.recover == nil {
			return m, tea.Quit
		}
		m.stage = stageDropping
		return m, tea.Batch(m.spinner.Tick, m.dropCmd())
	case stageDropped:
		m.stage = stageRecovering
		return m, tea.Batch(m.spinner.Tick, m.recoverCmd())
	case stageDone, stageError:
		return m, tea.Quit
	}
	return m, nil
}

func (m Model) seedCmd() tea.Cmd {
	return func() tea.Msg {
		r, err := demo.Seed(m.ctx, m.dsn)
		if err != nil {
			return errMsg{err}
		}
		// EterDB protects the database from the moment it starts managing it:
		// base backups are taken AUTOMATICALLY (the storage machinery runs them
		// on a schedule, retain-everything) alongside continuous WAL archiving.
		// Take one here, at setup, so the later table-recovery act restores from
		// a backup that already existed BEFORE anything broke, exactly as it
		// would in production. No operator ever runs a backup by hand; the drop
		// step below deliberately does NOT snapshot.
		snap := ""
		if m.recover != nil {
			out, err := m.runJob("snapshot", map[string]any{"label": "demo-auto"})
			if err != nil {
				return errMsg{err}
			}
			snap, _ = out["snapshot"].(string)
		}
		return seededMsg{res: r, snapshot: snap}
	}
}

// fireCmd launches the drain+fire goroutine and returns its first message. The
// goroutine streams fireProgressMsg heartbeats (with the running captured-row
// count) while capture drains the boosted seed, then an incidentMsg (or errMsg).
// Streaming keeps the scene visibly alive instead of a static "working…" that
// reads as stuck when capture has tens of thousands of rows to catch up on.
func (m Model) fireCmd() tea.Cmd {
	return func() tea.Msg {
		go m.runFire()
		return <-m.fireCh
	}
}

// waitFireCmd reads the next message the firing goroutine emits.
func (m Model) waitFireCmd() tea.Cmd {
	return func() tea.Msg { return <-m.fireCh }
}

// runFire drains the seed through capture (emitting progress), then fires the
// incident and waits for it to land. All output goes through m.fireCh, one
// message at a time (unbuffered: each send blocks until the UI reads it).
func (m Model) runFire() {
	// Drain the seed BEFORE firing, so the incident's own wait isn't racing the
	// ~49k-row seed (issue #182's 1000x boost) plus the setup base backup queued
	// ahead of it. Once capture reaches the seed watermark it has caught up to
	// "now", so the incident is recorded promptly. We report rows captured RELATIVE to
	// this baseline so the gauge starts at zero and grows regardless of any
	// history left over from an earlier demo run in the same meta store.
	base := capturedRows(m.ctx, m.client)
	drained := func() int {
		if n := capturedRows(m.ctx, m.client) - base; n > 0 {
			return n
		}
		return 0
	}
	if m.seed != nil && m.seed.Watermark != 0 {
		deadline := time.Now().Add(120 * time.Second)
		for {
			rows, err := m.client.Show(m.ctx, m.seed.Watermark)
			if err != nil {
				m.fireCh <- errMsg{err}
				return
			}
			if len(rows) > 0 {
				break
			}
			if time.Now().After(deadline) {
				m.fireCh <- errMsg{fmt.Errorf("capture did not catch up within 2m; is the capture sidecar (control plane) running against this database?")}
				return
			}
			m.fireCh <- fireProgressMsg{rows: drained()}
			time.Sleep(400 * time.Millisecond)
		}
	}

	// Capture has caught up; run the migration itself.
	m.fireCh <- fireProgressMsg{rows: drained(), applying: true}
	r, err := demo.FireIncident(m.ctx, m.dsn)
	if err != nil {
		m.fireCh <- errMsg{err}
		return
	}
	// Wait for the incident to land before the log/preview stages read it, so the
	// walkthrough is deterministic instead of racing the capture daemon.
	if err := demo.WaitForCapture(m.ctx, m.client, r.Txid); err != nil {
		m.fireCh <- errMsg{err}
		return
	}
	m.fireCh <- incidentMsg{r}
}

// capturedRows sums the change counts across recent transactions, a live "rows
// captured so far" gauge for the firing scene. Best-effort: 0 on any error.
func capturedRows(ctx context.Context, c client.EterClient) int {
	rows, err := c.Log(ctx, client.LogOptions{Limit: 500})
	if err != nil {
		return 0
	}
	total := 0
	for _, r := range rows {
		if n := numOf(r, "ops"); n > 0 {
			total += int(n)
			continue
		}
		total += int(numOf(r, "inserts") + numOf(r, "updates") + numOf(r, "deletes"))
	}
	return total
}

func (m Model) logCmd() tea.Cmd {
	return func() tea.Msg {
		rows, err := m.client.Log(m.ctx, client.LogOptions{Limit: 5})
		if err != nil {
			return errMsg{err}
		}
		return logMsg{rows}
	}
}

func (m Model) previewCmd() tea.Cmd {
	return func() tea.Msg {
		plan, err := m.client.Preview(m.ctx, m.incident.Txid)
		if err != nil {
			return errMsg{err}
		}
		return previewMsg{plan}
	}
}

func (m Model) undoCmd() tea.Cmd {
	return func() tea.Msg {
		// A clean incident reverses with clean_only; if a dependent slipped in
		// (only when the operator seeded one), cascade so the demo never dead-ends.
		mode := core.CleanOnly
		if m.plan != nil && m.plan.Classification != "clean" {
			mode = core.Cascade
		}
		res, err := m.client.Undo(m.ctx, m.incident.Txid, mode)
		if err != nil {
			return errMsg{err}
		}
		ops := 0
		if v, ok := res["reverted_ops"].(float64); ok {
			ops = int(v)
		} else if v, ok := res["reverted_ops"].(int64); ok {
			ops = int(v)
		}
		restored, err := demo.SampleInvoices(m.ctx, m.dsn, 4)
		if err != nil {
			return errMsg{err}
		}
		return undoneMsg{restored: restored, ops: ops}
	}
}

// runJob submits a storage job to the orchestrator and polls it to a terminal
// state, returning the job's structured output (or an error carrying the
// engine's verbatim message on failure).
func (m Model) runJob(kind string, args map[string]any) (map[string]any, error) {
	id, err := m.recover.SubmitStorageJob(m.ctx, kind, args)
	if err != nil {
		return nil, err
	}
	for {
		job, err := m.recover.GetJob(m.ctx, id)
		if err != nil {
			return nil, err
		}
		switch job["state"] {
		case "succeeded":
			out, _ := job["output"].(map[string]any)
			return out, nil
		case "failed":
			msg, _ := job["error"].(string)
			if msg == "" {
				msg = fmt.Sprintf("%s job failed", kind)
			}
			return nil, fmt.Errorf("%s", msg)
		case "canceled":
			return nil, fmt.Errorf("%s job was canceled", kind)
		}
		select {
		case <-m.ctx.Done():
			return nil, m.ctx.Err()
		case <-time.After(time.Second):
		}
	}
}

// dropCmd drops the orders table (a destructive DDL no row-undo can reverse)
// and confirms it is gone. It deliberately takes NO backup: recovery uses the
// automatic base backup already taken at setup (plus archived WAL), not one
// taken in anticipation of the drop.
func (m Model) dropCmd() tea.Cmd {
	return func() tea.Msg {
		before, err := demo.OrderCount(m.ctx, m.dsn)
		if err != nil {
			return errMsg{err}
		}
		if err := demo.DropOrders(m.ctx, m.dsn); err != nil {
			return errMsg{err}
		}
		exists, err := demo.OrdersExist(m.ctx, m.dsn)
		if err != nil {
			return errMsg{err}
		}
		return droppedMsg{before: before, exists: exists}
	}
}

// recoverCmd runs recover-table through the orchestrator (restore the base
// backup, replay WAL to just before the drop), then confirms the table and its
// rows are back.
func (m Model) recoverCmd() tea.Cmd {
	return func() tea.Msg {
		if _, err := m.runJob("recover-table", map[string]any{"table": "public.orders"}); err != nil {
			return errMsg{err}
		}
		exists, err := demo.OrdersExist(m.ctx, m.dsn)
		if err != nil {
			return errMsg{err}
		}
		rows := 0
		if exists {
			if rows, err = demo.OrderCount(m.ctx, m.dsn); err != nil {
				return errMsg{err}
			}
		}
		return recoveredMsg{exists: exists, rows: rows}
	}
}
