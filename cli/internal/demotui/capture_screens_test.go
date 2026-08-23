package demotui

// Screenshot harness (not a real test): when CAPTURE_SCREENS is set it renders
// each resting scene of the walkthrough to an ANSI file so the flow can be
// turned into images. Gated on the env var so `go test ./...` and CI never run
// it. Run:  CAPTURE_SCREENS=out go test ./internal/demotui -run CaptureScreens

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/charmbracelet/bubbles/spinner"
	"github.com/muesli/termenv"

	"github.com/charmbracelet/lipgloss"

	"github.com/eterdb/eterdb/cli/internal/core"
	"github.com/eterdb/eterdb/cli/internal/demo"
)

func TestCaptureScreens(t *testing.T) {
	outDir := os.Getenv("CAPTURE_SCREENS")
	if outDir == "" {
		t.Skip("set CAPTURE_SCREENS=<dir> to render the walkthrough scenes")
	}
	// Force full color on a dark terminal so the ANSI carries the real palette
	// even though the test has no TTY.
	lipgloss.SetColorProfile(termenv.TrueColor)
	lipgloss.SetHasDarkBackground(true)

	if err := os.MkdirAll(outDir, 0o755); err != nil {
		t.Fatal(err)
	}

	// Realistic data, matching what the live demo produces.
	before := []demo.InvoiceRow{
		{ID: 1, Cents: 6300}, {ID: 2, Cents: 7600}, {ID: 3, Cents: 8900}, {ID: 4, Cents: 10200},
	}
	zeroed := []demo.InvoiceRow{{ID: 1}, {ID: 2}, {ID: 3}, {ID: 4}}
	seed := &demo.SeedResult{Customers: 5, Products: 4, Orders: 20, Invoices: 20}
	incident := &demo.IncidentResult{Txid: 892, Corrupted: 20, Before: before, After: zeroed}
	logRows := []map[string]any{
		{"txid": int64(892), "table_name": "public.invoices", "updates": int64(20)},
		{"txid": int64(889), "table_name": "public.products", "updates": int64(1)},
		{"txid": int64(888), "table_name": "public.customers", "updates": int64(1)},
		{"txid": int64(887), "table_name": "public.orders", "updates": int64(3)},
		{"txid": int64(884), "table_name": "public.invoices", "inserts": int64(20)},
	}
	plan := &core.UndoPlan{Txid: 892, Classification: "clean", OpCount: 20}

	base := Model{
		width:   90,
		conn:    "postgres://eter@localhost:5433/eter",
		spinner: newSpinner(),
		recover: stubJobs{}, // non-nil so the row story offers act two
	}
	base.seed = seed
	base.incident = incident
	base.log = logRows
	base.plan = plan
	base.snapshot = "demo-auto-20260714T174500Z"

	scenes := []struct {
		name  string
		build func() Model
	}{
		{"01-intro", func() Model { m := base; m.stage = stageIntro; m.logoFrame = 0; return m }},
		{"02-seeding", func() Model { m := base; m.stage = stageSeeding; return m }},
		{"03-seeded", func() Model { m := base; m.stage = stageSeeded; return m }},
		{"04-damage", func() Model { m := base; m.stage = stageDamage; return m }},
		{"05-log", func() Model { m := base; m.stage = stageLog; return m }},
		{"06-preview", func() Model { m := base; m.stage = stagePreview; return m }},
		{"07-restored", func() Model {
			m := base
			m.stage = stageRestored
			m.ops = 20
			m.restored = before // amounts back to their originals
			return m
		}},
		{"08-dropped", func() Model {
			m := base
			m.stage = stageDropped
			m.ordersBefore = 20
			return m
		}},
		{"09-done", func() Model { m := base; m.stage = stageDone; m.ordersAfter = 20; return m }},
	}

	for _, sc := range scenes {
		out := sc.build().View()
		path := filepath.Join(outDir, sc.name+".ansi")
		if err := os.WriteFile(path, []byte(out), 0o644); err != nil {
			t.Fatal(err)
		}
		fmt.Println("wrote", path)
	}
}

func newSpinner() spinner.Model {
	sp := spinner.New()
	sp.Spinner = spinner.Dot
	sp.Style = accentStyle
	return sp
}
