package cmd

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"
	"unicode/utf8"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/mattn/go-isatty"
	"github.com/spf13/cobra"

	"github.com/eterdb/eterdb/cli/internal/client"
	"github.com/eterdb/eterdb/cli/internal/core"
	"github.com/eterdb/eterdb/cli/internal/demo"
	"github.com/eterdb/eterdb/cli/internal/demotui"
	"github.com/eterdb/eterdb/cli/internal/output"
)

func newInitCmd(g *globalOpts) *cobra.Command {
	var noTrack bool
	cmd := &cobra.Command{
		Use:     "init",
		Short:   "install the eter engine and start capturing all tables",
		Args:    cobra.NoArgs,
		Example: "  eter init\n  eter init --no-track",
		RunE: func(cmd *cobra.Command, _ []string) error {
			// Pin the engine SQL path (env override -> repo walk -> embedded copy
			// materialized to the cache dir) so direct-mode Init, which resolves via
			// ETER_SQL_FILE, works from an installed binary outside the repo too.
			// Best-effort: hosted mode applies the SQL server-side and needs no local file.
			if p, err := core.EterSQLFile(); err == nil {
				_ = os.Setenv("ETER_SQL_FILE", p)
			}
			return withClient(cmd, g, func(ctx context.Context, c client.EterClient) error {
				r, err := c.Init(ctx)
				if err != nil {
					return err
				}
				// Set up capture by default: auto-track new tables + track every
				// existing owned PK table. Best-effort: with no capture sidecar
				// running yet, tables are reported pending, not tracked.
				cap, err := c.InitCapture(ctx, !noTrack)
				if err != nil {
					return err
				}
				out := map[string]any{"ok": true}
				for k, v := range r {
					out[k] = v
				}
				for k, v := range cap {
					out[k] = v
				}
				output.Emit(out, func() {
					tracked, _ := cap["tracked"].(float64)
					pending, _ := cap["pending"].(float64)
					output.Info("eter engine installed; tracking %d table(s).", int64(tracked))
					if pending > 0 {
						output.Info("%d table(s) pending: start the control plane (capture sidecar), then `eter track --all`.", int64(pending))
					}
				})
				return nil
			})
		},
	}
	cmd.Flags().BoolVar(&noTrack, "no-track", false, "install the engine only; do not auto-track tables")
	return cmd
}

func newTrackCmd(g *globalOpts) *cobra.Command {
	var all bool
	cmd := &cobra.Command{
		Use:     "track [table]",
		Short:   "start capturing changes on a table (or --all tables with a primary key)",
		Args:    cobra.MaximumNArgs(1),
		Example: "  eter track public.orders\n  eter track --all",
		RunE: func(cmd *cobra.Command, args []string) error {
			return withClient(cmd, g, func(ctx context.Context, c client.EterClient) error {
				if all {
					n, err := c.TrackAll(ctx)
					if err != nil {
						return err
					}
					output.Emit(map[string]any{"ok": true, "tracked": n},
						func() { output.Info("tracking %d table(s).", n) })
					return nil
				}
				if len(args) == 1 {
					if err := c.Track(ctx, args[0]); err != nil {
						return err
					}
					output.Emit(map[string]any{"ok": true, "tracked": args[0]},
						func() { output.Info("tracking %s.", args[0]) })
					return nil
				}
				return usageErr("specify a table or --all")
			})
		},
	}
	cmd.Flags().BoolVar(&all, "all", false, "track every user table that has a primary key")
	return cmd
}

func newLogCmd(g *globalOpts) *cobra.Command {
	var (
		table       string
		since       string
		limit       int
		includeUndo bool
	)
	cmd := &cobra.Command{
		Use:     "log",
		Short:   "list recent change transactions (newest first)",
		Args:    cobra.NoArgs,
		Example: "  eter log\n  eter log --table public.invoices --limit 20",
		RunE: func(cmd *cobra.Command, _ []string) error {
			return withClient(cmd, g, func(ctx context.Context, c client.EterClient) error {
				rows, err := c.Log(ctx, client.LogOptions{Table: table, Since: since, Limit: limit, IncludeUndo: includeUndo})
				if err != nil {
					return err
				}
				output.Emit(rows, func() {
					if len(rows) == 0 {
						output.Info("no changes recorded yet.")
						return
					}
					output.Table(rows, []string{"txid", "table_name", "inserts", "updates", "deletes", "last_at", "application_name"})
				})
				return nil
			})
		},
	}
	cmd.Flags().StringVar(&table, "table", "", "filter to one table")
	cmd.Flags().StringVar(&since, "since", "", "only changes at/after this timestamp")
	cmd.Flags().IntVar(&limit, "limit", 50, "max transactions")
	cmd.Flags().BoolVar(&includeUndo, "include-undo", false, "include undo records")
	return cmd
}

func newShowCmd(g *globalOpts) *cobra.Command {
	return &cobra.Command{
		Use:     "show <txid>",
		Short:   "show the individual row changes in a transaction",
		Args:    cobra.ExactArgs(1),
		Example: "  eter show 8123456",
		RunE: func(cmd *cobra.Command, args []string) error {
			txid, err := parseTxid(args[0])
			if err != nil {
				return err
			}
			return withClient(cmd, g, func(ctx context.Context, c client.EterClient) error {
				rows, err := c.Show(ctx, txid)
				if err != nil {
					return err
				}
				output.Emit(rows, func() {
					output.Table(rows, []string{"id", "op", "table_name", "pk", "committed_at", "is_undo"})
				})
				return nil
			})
		},
	}
}

func newPreviewCmd(g *globalOpts) *cobra.Command {
	return &cobra.Command{
		Use:     "preview <txid>",
		Short:   "preview the undo plan for a transaction (clean vs dependent), never mutates",
		Args:    cobra.ExactArgs(1),
		Example: "  eter preview 8123456",
		RunE: func(cmd *cobra.Command, args []string) error {
			txid, err := parseTxid(args[0])
			if err != nil {
				return err
			}
			return withClient(cmd, g, func(ctx context.Context, c client.EterClient) error {
				plan, err := c.Preview(ctx, txid)
				if err != nil {
					return err
				}
				output.Emit(plan, func() { renderPreview(plan, txid) })
				return nil
			})
		},
	}
}

func renderPreview(plan *core.UndoPlan, txid int64) {
	output.Info("txid %d: %s (%d row change(s))", plan.Txid, upper(plan.Classification), plan.OpCount)
	output.Info("basis: %s", plan.DependencyBasis)
	if plan.Classification == "dependent" {
		for _, e := range plan.ConflictEdges {
			how := "wrote the affected rows"
			if contains(e.Kinds, "rw") {
				if contains(e.Kinds, "ww") {
					how = "wrote AND read the affected rows"
				} else {
					how = "READ what this txn wrote (SSI read-dependency)"
				}
			}
			tag := ""
			if e.Precision == "over-approx" {
				gran := "coarse"
				if e.RWGranularity != nil && *e.RWGranularity != "" {
					gran = *e.RWGranularity
				}
				tag = fmt.Sprintf("  [over-approx: %s, writer seqscanned the table, may not have read the reverted rows]", gran)
			}
			output.Info("  - txid %d later %s%s", e.Txid, how, tag)
		}
		if len(plan.ConflictEdges) == 0 {
			output.Info("conflicts with later transactions: %s", joinInts(plan.Conflicts))
		}
		p := plan.Precision
		if p.OverApproxDependents > 0 {
			output.Info("precision: %d exact, %d over-approx (coarse) dependent(s)", p.ExactDependents, p.OverApproxDependents)
			if len(p.CoarseTables) > 0 {
				output.Info("  coarse tables (seqscanned by writers → undo is coarse here): %s", joinStrs(p.CoarseTables))
			}
			output.Info("  -> an index on the columns those readers filter on makes the dependency precise")
		}
	}
	renderExternalRefs(plan.ExternalRefs)
	if plan.Classification == "clean" {
		output.Info("-> safe one-click undo: eter undo %d --apply", txid)
	} else {
		output.Info("-> needs review: eter undo %d --apply --cascade  (or --targeted)", txid)
	}
}

func newUndoCmd(g *globalOpts) *cobra.Command {
	var apply, cascade, targeted bool
	cmd := &cobra.Command{
		Use:     "undo <txid>",
		Short:   "reverse a transaction. Previews by default; pass --apply to execute.",
		Args:    cobra.ExactArgs(1),
		Example: "  eter undo 8123456\n  eter undo 8123456 --apply\n  eter undo 8123456 --apply --cascade",
		RunE: func(cmd *cobra.Command, args []string) error {
			txid, err := parseTxid(args[0])
			if err != nil {
				return err
			}
			mode, err := pickMode(cascade, targeted)
			if err != nil {
				return err
			}
			return withClient(cmd, g, func(ctx context.Context, c client.EterClient) error {
				if !apply {
					plan, err := c.Preview(ctx, txid)
					if err != nil {
						return err
					}
					out := planToMap(plan)
					out["dry_run"] = true
					out["mode"] = string(mode)
					output.Emit(out, func() {
						output.Info("DRY RUN, nothing changed. txid %d is %s.", txid, upper(plan.Classification))
						renderExternalRefs(plan.ExternalRefs)
						output.Info("would run mode=%s; re-run with --apply to execute.", mode)
					})
					return nil
				}
				res, err := c.Undo(ctx, txid, mode)
				if err != nil {
					return err
				}
				out := map[string]any{"ok": true}
				for k, v := range res {
					out[k] = v
				}
				output.Emit(out, func() {
					msg := fmt.Sprintf("reverted txid %d (%d op(s)", txid, int(numField(res, "reverted_ops")))
					if cascaded := int(numField(res, "cascaded_ops")); cascaded > 0 {
						msg += fmt.Sprintf(", +%d cascaded", cascaded)
					}
					output.Info("%s).", msg)
				})
				return nil
			})
		},
	}
	cmd.Flags().BoolVar(&apply, "apply", false, "actually execute (default is a dry-run preview)")
	cmd.Flags().BoolVar(&cascade, "cascade", false, "also reverse dependent transactions")
	cmd.Flags().BoolVar(&targeted, "targeted", false, "reverse only this transaction, keep dependents")
	return cmd
}

// cohortFlags binds the shared cohort selector flags to a command.
type cohortFlags struct {
	table, fingerprint, since, until, where string
}

func (cf *cohortFlags) bind(cmd *cobra.Command) {
	cmd.Flags().StringVar(&cf.table, "table", "", "restrict the cohort to this table")
	cmd.Flags().StringVar(&cf.fingerprint, "fingerprint", "", "restrict to writes matching this statement fingerprint")
	cmd.Flags().StringVar(&cf.since, "since", "", "only writes at/after this timestamp")
	cmd.Flags().StringVar(&cf.until, "until", "", "only writes at/before this timestamp")
	cmd.Flags().StringVar(&cf.where, "where", "", `predicate as jsonb containment, e.g. '{"status":"issued"}'`)
}

func (cf *cohortFlags) selector() (client.CohortSelector, error) {
	sel := client.CohortSelector{Table: cf.table, Fingerprint: cf.fingerprint, From: cf.since, To: cf.until}
	if cf.where != "" {
		var p map[string]any
		if err := json.Unmarshal([]byte(cf.where), &p); err != nil {
			return sel, usageErr(fmt.Sprintf("--where must be valid JSON: %v", err))
		}
		sel.Predicate = p
	}
	return sel, nil
}

func newCohortCmd(g *globalOpts) *cobra.Command {
	cf := &cohortFlags{}
	cmd := &cobra.Command{
		Use:     "cohort",
		Short:   "preview a cohort of writes (time × table × statement-shape × predicate)",
		Args:    cobra.NoArgs,
		Example: "  eter cohort --table public.invoices --since '2026-07-11 14:00'\n  eter cohort --table public.invoices --where '{\"status\":\"issued\"}'",
		RunE: func(cmd *cobra.Command, _ []string) error {
			sel, err := cf.selector()
			if err != nil {
				return err
			}
			return withClient(cmd, g, func(ctx context.Context, c client.EterClient) error {
				r, err := c.PreviewCohort(ctx, sel)
				if err != nil {
					return err
				}
				output.Emit(r, func() {
					output.Info("cohort: %s txns (%s clean, %s dependent)",
						output.Fmt(r["txn_count"]), output.Fmt(r["clean"]), output.Fmt(r["dependent"]))
				})
				return nil
			})
		},
	}
	cf.bind(cmd)
	return cmd
}

func newUndoCohortCmd(g *globalOpts) *cobra.Command {
	cf := &cohortFlags{}
	var apply, cascade, targeted bool
	cmd := &cobra.Command{
		Use:     "undo-cohort",
		Short:   "reverse a cohort of writes. Previews by default; pass --apply to execute.",
		Args:    cobra.NoArgs,
		Example: "  eter undo-cohort --table public.invoices --since '2026-07-11 14:00'\n  eter undo-cohort --table public.invoices --since '2026-07-11 14:00' --apply",
		RunE: func(cmd *cobra.Command, _ []string) error {
			sel, err := cf.selector()
			if err != nil {
				return err
			}
			mode, err := pickMode(cascade, targeted)
			if err != nil {
				return err
			}
			return withClient(cmd, g, func(ctx context.Context, c client.EterClient) error {
				if !apply {
					r, err := c.PreviewCohort(ctx, sel)
					if err != nil {
						return err
					}
					out := map[string]any{"dry_run": true, "mode": string(mode)}
					for k, v := range r {
						out[k] = v
					}
					output.Emit(out, func() {
						output.Info("DRY RUN, cohort of %s txns (%s dependent). Re-run with --apply.",
							output.Fmt(r["txn_count"]), output.Fmt(r["dependent"]))
					})
					return nil
				}
				r, err := c.UndoCohort(ctx, sel, mode)
				if err != nil {
					return err
				}
				out := map[string]any{"ok": true}
				for k, v := range r {
					out[k] = v
				}
				output.Emit(out, func() {
					skipped := int(numField(r, "skipped_dependent"))
					if skipped == 0 {
						output.Info("reverted cohort: %s transaction(s).", output.Fmt(r["reverted_txns"]))
						return
					}
					// Name the skipped dependents so the operator can drill in without
					// hunting for a txid, the whole point of the moat.
					ids := txidList(r, "skipped_txids")
					idStr := strings.Join(ids, ", ")
					if len(ids) > 6 {
						idStr = strings.Join(ids[:6], ", ") + fmt.Sprintf(", …(+%d)", len(ids)-6)
					}
					noun, pron := "dependent txn", "it"
					if skipped != 1 {
						noun, pron = "dependent txns", "them"
					}
					output.Info("reverted cohort: %s transaction(s); skipped %d %s: %s",
						output.Fmt(r["reverted_txns"]), skipped, noun, idStr)
					output.Info("  Something downstream read %s, inspect with `eter preview <txid>`, then "+
						"revert with --cascade (also undo the readers) or --targeted (just these).", pron)
				})
				return nil
			})
		},
	}
	cf.bind(cmd)
	cmd.Flags().BoolVar(&apply, "apply", false, "actually execute")
	cmd.Flags().BoolVar(&cascade, "cascade", false, "also reverse transactions that read the cohort's writes")
	cmd.Flags().BoolVar(&targeted, "targeted", false, "reverse only the cohort, keep dependents")
	return cmd
}

func newMarkCmd(g *globalOpts) *cobra.Command {
	return &cobra.Command{
		Use:     "mark <label>",
		Short:   "drop a deploy/CI marker on the timeline",
		Args:    cobra.ExactArgs(1),
		Example: "  eter mark 'deploy v1.4.2'",
		RunE: func(cmd *cobra.Command, args []string) error {
			return withClient(cmd, g, func(ctx context.Context, c client.EterClient) error {
				id, err := c.Mark(ctx, args[0])
				if err != nil {
					return err
				}
				output.Emit(map[string]any{"ok": true, "id": id},
					func() { output.Info("marker #%d added.", id) })
				return nil
			})
		},
	}
}

// eterMascot is EterDB's brand mark, rendered from the logo SVG (site/assets/
// favicon.svg) to braille: the green roundel with the undo-"e" (a bar into a
// rewind loop with an arrowhead) knocked out in negative space. Drawn on the
// left of `eter status`, fastfetch-style, with the info table on the right.
// Each braille glyph is a single display column so the columns stay aligned.
var eterMascot = []string{
	`     ⣀⣤⣤⣤⣤⣤⣤⣀`,
	`  ⢀⣴⣾⣿⣿⣿⣿⣿⣿⣿⣿⣷⣦⡀`,
	` ⢠⣿⣿⣿⡿⠋⠉⣀⣀⠉⠙⢿⣿⣿⣿⡄`,
	` ⣿⣿⣿⡏ ⣴⣿⣿⣿⣿⣦ ⢹⣿⣿⣿`,
	` ⣿⣿⣿        ⢀⣀⣿⣿⣿`,
	` ⢿⣿⣿⣇ ⠻⣿⣿⣿⣿⠉⠉⢸⣿⣿⡿`,
	`  ⠙⢿⣿⣿⣿⣶⣶⣶⣶⣾⣿⣿⣿⡿⠋`,
	`     ⠉⠛⠛⠛⠛⠛⠛⠉`,
}

// logoStyle tints the mark EterDB green. lipgloss disables colour when the output
// is not a terminal (piped, NO_COLOR), so `--json` and pipes stay clean.
var logoStyle = lipgloss.NewStyle().Foreground(lipgloss.AdaptiveColor{Light: "#1f7a44", Dark: "#5fd38a"})

// renderStatus prints the readiness-led human view fastfetch-style: the EterDB
// brand mark on the left, an info table (lead with "ready ✓", then endpoint/
// engine/mode/history) on the right. JSON mode emits the full map verbatim.
func renderStatus(s map[string]any) {
	count := func(v any) string {
		if f := output.Fmt(v); f != "" {
			return f
		}
		return "0"
	}
	mode := output.Fmt(s["mode"])
	endpoint := output.Fmt(s["endpoint"])

	// Build the right-hand info table.
	var info []string
	add := func(label, format string, args ...any) {
		if label == "" {
			info = append(info, fmt.Sprintf(format, args...))
			return
		}
		info = append(info, fmt.Sprintf("%-9s %s", label, fmt.Sprintf(format, args...)))
	}

	if ready, _ := s["ready"].(bool); !ready {
		reason := output.Fmt(s["reason"])
		if reason == "" {
			reason = "not ready"
		}
		add("", "EterDB, not ready ✗")
		add("", "%s", strings.Repeat("-", 18))
		if endpoint != "" {
			add("endpoint", "%s (%s)", endpoint, mode)
		}
		add("reason", "%s", reason)
		renderFastfetch(eterMascot, info)
		return
	}

	add("", "EterDB, ready ✓")
	add("", "%s", strings.Repeat("-", 16))
	if endpoint != "" {
		add("endpoint", "%s (%s)", endpoint, mode)
	}
	if store := output.Fmt(s["store_endpoint"]); store != "" {
		add("store", "%s (durable metadata; two-DB)", store)
	}
	// The engine ships as a SQL script (not CREATE EXTENSION), so engine_version is
	// usually empty, don't render "eter engine" under the "engine" label (doubled).
	engine := "eter"
	if ev := output.Fmt(s["engine_version"]); ev != "" {
		engine = "eter " + ev
	}
	if b, _ := s["ssi"].(bool); b {
		engine += " · eter_ssi present"
	}
	add("engine", "%s", engine)
	observe := output.Fmt(s["observe_mode"])
	switch observe {
	case "on":
		observe = "observe (READ COMMITTED)"
	case "", "off":
		observe = "strict / standard"
	}
	if capMode := output.Fmt(s["capture_mode"]); capMode != "" {
		add("mode", "%s · capture: %s", observe, capMode)
	} else {
		add("mode", "%s", observe)
	}
	add("history", "%s tracked tables · %s changes across %s txns · %s undos",
		count(s["tracked_tables"]), count(s["changes"]), count(s["transactions"]), count(s["undo_records"]))
	if e, l := output.Fmt(s["earliest"]), output.Fmt(s["latest"]); e != "" || l != "" {
		add("window", "%s → %s", e, l)
	}
	renderFastfetch(eterMascot, info)
}

// renderFastfetch prints an ASCII logo on the left and an info table on the right,
// row-aligned (the logo's lines and the info's lines are zipped, each padded to the
// logo width). Whichever side is shorter is padded with blanks.
func renderFastfetch(logo, info []string) {
	// Width in runes (the logo uses box-drawing glyphs that are multi-byte but one
	// display column), so %-*s pads to a consistent visual width.
	width := 0
	for _, l := range logo {
		if n := utf8.RuneCountInString(l); n > width {
			width = n
		}
	}
	rows := len(logo)
	if len(info) > rows {
		rows = len(info)
	}
	for i := 0; i < rows; i++ {
		left := ""
		if i < len(logo) {
			left = logo[i]
		}
		right := ""
		if i < len(info) {
			right = info[i]
		}
		// Pad to the logo width BEFORE colouring, so the ANSI codes don't throw
		// off the fixed-width alignment; lipgloss no-ops the colour off a TTY.
		output.Info("  %s   %s", logoStyle.Render(fmt.Sprintf("%-*s", width, left)), right)
	}
}

func newStatusCmd(g *globalOpts) *cobra.Command {
	return &cobra.Command{
		Use:     "status",
		Short:   "instance readiness, engine health, and capture counts",
		Args:    cobra.NoArgs,
		Example: "  eter status\n  eter status --json",
		RunE: func(cmd *cobra.Command, _ []string) error {
			return withClient(cmd, g, func(ctx context.Context, c client.EterClient) error {
				s, err := c.Status(ctx)
				if err != nil {
					return err
				}
				output.Emit(s, func() { renderStatus(s) })
				return nil
			})
		},
	}
}

func newDemoCmd(g *globalOpts) *cobra.Command {
	demoCmd := &cobra.Command{
		Use:   "demo",
		Short: "interactive walkthrough: watch an incident happen and get reversed",
		Long: "Run with no subcommand for the guided, interactive walkthrough (Bubble Tea).\n" +
			"Two acts against the live stack: a bad migration reversed row-by-row with undo,\n" +
			"then a dropped table recovered from a base backup. Drives the real engine and\n" +
			"orchestrator at every step.\n\n" +
			"  eter demo            interactive walkthrough (needs a terminal + the stack)\n" +
			"  eter demo up         non-interactive: seed + fire the incident (for scripts/agents)\n" +
			"  eter demo down       tear the demo down",
		Args:    cobra.NoArgs,
		Example: "  docker compose up -d && eter demo",
		RunE: func(cmd *cobra.Command, _ []string) error {
			return runDemoTUI(cmd, g)
		},
	}

	var dependent bool
	up := &cobra.Command{
		Use:     "up",
		Short:   "create the demo schema + data and fire the 2:00 PM incident",
		Args:    cobra.NoArgs,
		Example: "  eter demo up\n  eter demo up --dependent",
		RunE: func(cmd *cobra.Command, _ []string) error {
			output.SetJSON(g.json)
			cs := requireConnString(g)
			r, err := demo.Up(cmd.Context(), cs, dependent)
			if err != nil {
				return fail(core.ExitDB, err.Error())
			}
			output.Emit(r, func() {
				output.Info("Demo ready. The incident corrupted %d invoices in one transaction (txid %d).",
					r.InvoicesCorrupted, r.IncidentTxid)
				output.Info("Try it:  eter preview %d", r.IncidentTxid)
				output.Info("Then:    eter undo %d --apply", r.IncidentTxid)
				if r.DependentTxid != nil {
					output.Info("A dependent write (txid %d) was added, preview will show DEPENDENT.", *r.DependentTxid)
				}
			})
			return nil
		},
	}
	up.Flags().BoolVar(&dependent, "dependent", false, "also add a later write that forces the conflict-review path")

	down := &cobra.Command{
		Use:     "down",
		Short:   "tear the demo down (containerized stack, or just the schema + history)",
		Args:    cobra.NoArgs,
		Example: "  eter demo down",
		RunE: func(cmd *cobra.Command, _ []string) error {
			output.SetJSON(g.json)
			ctx := cmd.Context()

			// If `eter demo` brought up the containerized stack, `down -v` removes
			// it wholesale (containers + volumes), which subsumes the SQL teardown.
			if g.url == "" && os.Getenv("ETER_URL") == "" && demo.StackRunning(ctx) {
				if err := demo.StackDown(ctx, os.Stderr); err != nil {
					return fail(core.ExitDB, "stopping the stack: "+err.Error())
				}
				output.Emit(map[string]any{"ok": true, "stack": "removed"},
					func() { output.Info("demo stack stopped and removed.") })
				return nil
			}

			// Bring-your-own-Postgres: drop the demo schema + captured history in place.
			cs := requireConnString(g)
			if err := demo.Down(ctx, cs); err != nil {
				return fail(core.ExitDB, err.Error())
			}
			output.Emit(map[string]any{"ok": true}, func() { output.Info("demo torn down.") })
			return nil
		},
	}

	demoCmd.AddCommand(up, down)
	return demoCmd
}

// runDemoTUI drives the interactive Bubble Tea walkthrough. It needs a real
// terminal and a direct database connection; in --json / non-TTY contexts it
// points the caller at the scriptable `eter demo up` instead.
func runDemoTUI(cmd *cobra.Command, g *globalOpts) error {
	if g.json {
		return failWithHint(core.ExitUsage, "the interactive demo has no JSON form",
			"use `eter demo up --json` for the scriptable, non-interactive demo.")
	}
	if !isatty.IsTerminal(os.Stdout.Fd()) || !isatty.IsTerminal(os.Stdin.Fd()) {
		return failWithHint(core.ExitUsage, "the interactive demo needs a terminal",
			"run `eter demo up` for the non-interactive walkthrough.")
	}
	cs := requireConnString(g)
	ctx := cmd.Context()
	if ctx == nil {
		ctx = context.Background()
	}

	// The whole walkthrough runs through the orchestrator (base backups + WAL
	// replay for recovery, AND meta-aware history reads for the row story), which
	// the stack always runs. Resolve it (flags, env, then the compose default);
	// if it is unreachable this offers to bring the containerized stack up. It
	// runs first so that bring-up also satisfies the tenant probe below.
	orch, err := demoOrchestrator(ctx, g)
	if err != nil {
		return err
	}

	// Preflight: the tenant must be reachable (the walkthrough seeds + samples it
	// directly). History READS, though, go through the orchestrator, not this
	// probe: in the two-container stack history is in the meta store, which the
	// host cannot reach directly, so a host DirectClient would read an empty
	// tenant-local eter.history and every log/preview/undo would come up blank.
	probe, err := client.NewDirectClient(ctx, cs)
	if err != nil {
		return failWithHint(core.ExitDB, cleanPgMessage(err.Error()),
			"is the database reachable? try `eter doctor` (or `docker compose up -d`).")
	}
	probe.Close()

	m := demotui.New(ctx, cs, orch, orch)
	final, err := tea.NewProgram(m, tea.WithContext(ctx)).Run()
	if err != nil {
		return fail(core.ExitDB, err.Error())
	}
	if fm, ok := final.(demotui.Model); ok && fm.Failed() {
		return &exitError{code: core.ExitDB, message: "demo failed", printed: true}
	}
	return nil
}

// demoOrchestrator resolves and verifies the orchestrator the walkthrough runs
// through: --url/--token, then ETER_URL/ETER_TOKEN, then the compose default
// (http://localhost:4400 + ETER_API_TOKEN). If it is unreachable AND the caller
// did not point at a specific orchestrator, it offers to bring the containerized
// stack up with Docker (the compose file is embedded, so this works from an
// installed binary with no checkout), then re-probes.
func demoOrchestrator(ctx context.Context, g *globalOpts) (*client.HostedClient, error) {
	explicit := g.url != "" || os.Getenv("ETER_URL") != ""
	url := firstNonEmpty(g.url, os.Getenv("ETER_URL"), "http://localhost:"+demo.OrchPort())
	token := firstNonEmpty(g.token, os.Getenv("ETER_TOKEN"), os.Getenv("ETER_API_TOKEN"))

	hc := client.NewHostedClient(url, token)
	if _, err := hc.Status(ctx); err == nil {
		return hc, nil
	}

	// Pointed at a specific orchestrator, or no stdin to prompt on: don't touch Docker.
	if explicit || !isatty.IsTerminal(os.Stdin.Fd()) {
		return nil, failWithHint(core.ExitDB,
			"the interactive demo needs the EterDB control plane (orchestrator at "+url+")",
			"start the stack with `docker compose up -d`, or run `eter demo` in a terminal to have it started for you")
	}

	if d := demo.CheckDocker(ctx); !d.OK {
		return nil, failWithHint(core.ExitDB,
			"the EterDB stack isn't running (orchestrator at "+url+"), and it can't be started automatically",
			d.Reason+"; install Docker, or start a stack yourself and pass --url")
	}

	// A process squatting the engine's host port would shadow the container and
	// hang the walkthrough at "0 rows captured"; catch it before bringing anything up.
	if err := demo.PreflightPorts(ctx); err != nil {
		return nil, fail(core.ExitDB, err.Error())
	}

	output.Info("The EterDB stack isn't running (orchestrator at %s).", url)
	if !confirmYes("Start it with Docker now?") {
		return nil, failWithHint(core.ExitDB,
			"the interactive demo needs the EterDB control plane",
			"re-run `eter demo` and answer yes, or bring it up with `docker compose up -d`")
	}

	output.Info("Starting the stack (docker compose up -d); the first run pulls images and can take a few minutes...")
	if err := demo.StackUp(ctx, os.Stderr); err != nil {
		return nil, fail(core.ExitDB, "bringing the stack up: "+err.Error())
	}

	// `--wait` already gated on the compose healthchecks; give the orchestrator a
	// few extra seconds to answer /v1/status after its port opens.
	var lastErr error
	for i := 0; i < 15; i++ {
		_, lastErr = hc.Status(ctx)
		if lastErr == nil {
			output.Info("Stack is up. Stop it later with:  eter demo down")
			return hc, nil
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(2 * time.Second):
		}
	}
	return nil, fail(core.ExitDB, "the stack started but the orchestrator never became ready: "+lastErr.Error())
}

// firstNonEmpty returns the first non-empty string, or "".
func firstNonEmpty(vs ...string) string {
	for _, v := range vs {
		if v != "" {
			return v
		}
	}
	return ""
}

// confirmYes asks a yes/no question on stdin, defaulting to yes on an empty line
// or an unreadable stdin. Callers must check for a TTY first.
func confirmYes(question string) bool {
	fmt.Fprint(os.Stderr, question+" [Y/n] ")
	line, err := bufio.NewReader(os.Stdin).ReadString('\n')
	if err != nil {
		return true
	}
	switch strings.ToLower(strings.TrimSpace(line)) {
	case "", "y", "yes":
		return true
	default:
		return false
	}
}

func newGuideCmd() *cobra.Command {
	return &cobra.Command{
		Use:     "guide",
		Short:   "print the agent usage guide (how Claude should drive eter)",
		Args:    cobra.NoArgs,
		Example: "  eter guide",
		RunE: func(_ *cobra.Command, _ []string) error {
			fmt.Fprint(os.Stdout, agentGuide)
			return nil
		},
	}
}

// demoDefaultDSN is the connection the compose stack exposes for the engine: host
// port 5433 by default (ETER_DEMO_ENGINE_PORT overrides, matched by the compose
// file), POSTGRES_USER/PASSWORD/DB defaulted to eter/eter/eter. The demo falls
// back to it so `eter demo` needs zero config; --db or DATABASE_URL still
// override. The "password" is the published compose default, not a secret.
func demoDefaultDSN() string {
	return "postgres://eter:eter@localhost:" + demo.EnginePort() + "/eter" //nolint:gosec // compose default, documented, not a credential
}

// requireConnString resolves a direct DSN for the demo commands (which need a
// real Postgres connection, not the hosted transport): --db, then DATABASE_URL,
// then the compose default.
func requireConnString(g *globalOpts) string {
	if g.db != "" {
		return g.db
	}
	if cs := os.Getenv("DATABASE_URL"); cs != "" {
		return cs
	}
	return demoDefaultDSN()
}
