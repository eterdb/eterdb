// Package cmd wires the eter command tree. It is a direct Go port of the
// TypeScript CLI (commander -> cobra): the same commands, flags, JSON shapes,
// and the stable exit-code contract (0 ok · 2 usage · 3 not found · 4 dependent
// · 5 db · 6 config · 7 prerequisite missing). The CLI surface is a frozen
// interface; this changes the
// implementation language beneath it, not the surface.
package cmd

import (
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"regexp"
	"strconv"
	"strings"
	"syscall"

	"github.com/spf13/cobra"

	"github.com/eterdb/eterdb/cli/internal/client"
	"github.com/eterdb/eterdb/cli/internal/config"
	"github.com/eterdb/eterdb/cli/internal/core"
	"github.com/eterdb/eterdb/cli/internal/output"
)

// version is the CLI version. It defaults to the in-repo dev string and is
// overridden at release time via -ldflags "-X …/internal/cmd.version=<tag>".
var version = "0.1.0-alpha.1"

//go:embed ETER_AGENT.md
var agentGuide string

// exitError carries a process exit code out of a command's RunE. Once a command
// has printed its own diagnostic (via fail), it sets printed so main does not
// print again.
type exitError struct {
	code    int
	message string
	printed bool
}

func (e *exitError) Error() string { return e.message }

// globalOpts holds the persistent connection/output flags.
type globalOpts struct {
	json  bool
	db    string
	url   string
	token string
}

var (
	dependentRe = regexp.MustCompile(`dependent transactions`)
	noSidecarRe = regexp.MustCompile(`no capture sidecar detected`)
	notFoundRe  = regexp.MustCompile(`(?i)no tracked writes|no .* found`)
	connFailRe  = regexp.MustCompile(`(?i)failed to connect|connection refused|could not connect|no such host|server closed the connection`)
	pgNoiseRe   = regexp.MustCompile(`\s*\(SQLSTATE \w+\)\s*$`)
)

// cleanPgMessage makes a raised engine error read as a sentence, not a driver dump:
// it strips pgx's "ERROR: " prefix and "(SQLSTATE …)" suffix and the engine's internal
// "eter.undo:" qualifier.
func cleanPgMessage(msg string) string {
	msg = pgNoiseRe.ReplaceAllString(msg, "")
	msg = strings.TrimPrefix(msg, "ERROR: ")
	msg = strings.TrimPrefix(msg, "eter.undo: ")
	return strings.TrimSpace(msg)
}

// fail prints the error in the active output mode and returns an exitError.
func fail(code int, message string) error {
	return failWithHint(code, message, "")
}

// failWithHint is fail plus an actionable "next step" line. In JSON mode the hint
// rides along as an optional "hint" field (additive to the frozen {"ok":false,
// "error":…} shape); in human mode it prints as an indented second line on stderr.
func failWithHint(code int, message, hint string) error {
	if output.IsJSON() {
		body := map[string]any{"ok": false, "error": message}
		if hint != "" {
			body["hint"] = hint
		}
		b, _ := json.MarshalIndent(body, "", "  ")
		fmt.Fprintln(os.Stdout, string(b))
	} else {
		fmt.Fprintf(os.Stderr, "error: %s\n", message)
		if hint != "" {
			fmt.Fprintf(os.Stderr, "  %s\n", hint)
		}
	}
	return &exitError{code: code, message: message, printed: true}
}

// usageErr is a recoverable operator mistake (bad flag combo) → exit 2.
func usageErr(message string) error {
	return fail(core.ExitUsage, message)
}

// withClient resolves the transport, runs fn, and maps errors to exit codes.
func withClient(cmd *cobra.Command, g *globalOpts, fn func(ctx context.Context, c client.EterClient) error) error {
	output.SetJSON(g.json)
	ctx := cmd.Context()
	if ctx == nil {
		ctx = context.Background()
	}
	resolved, err := config.ResolveClient(ctx, config.Opts{DB: g.db, URL: g.url, Token: g.token})
	if err != nil {
		if config.IsConfigError(err) {
			// The ConfigError message already spells out the remedies, so it needs no
			// extra hint.
			return fail(core.ExitConfig, err.Error())
		}
		return failWithHint(core.ExitDB, err.Error(),
			"check the database is reachable and DATABASE_URL/--db is correct (try `eter doctor`).")
	}
	defer resolved.Client.Close()
	if err := fn(ctx, resolved.Client); err != nil {
		return mapErr(err)
	}
	return nil
}

// mapErr translates an action error to the documented exit code.
func mapErr(err error) error {
	var ue *exitError
	if errors.As(err, &ue) {
		return err // already classified + printed
	}
	// A cancelled context means the operator interrupted us (SIGINT/SIGTERM), report
	// it as a clean shutdown, not a database error.
	if errors.Is(err, context.Canceled) {
		return failWithHint(core.ExitInterrupted, "interrupted", "")
	}
	msg := err.Error()
	switch {
	case dependentRe.MatchString(msg):
		return failWithHint(core.ExitDependent, cleanPgMessage(msg),
			"A later transaction wrote or read what this one wrote. Reverse them together with "+
				"--cascade, or just this one with --targeted.")
	case noSidecarRe.MatchString(msg):
		return failWithHint(core.ExitPrereq, cleanPgMessage(msg),
			"EterDB captures via logical decoding. Start the control plane (capture sidecar) against this database, then track.")
	case notFoundRe.MatchString(msg):
		return failWithHint(core.ExitNotFound, cleanPgMessage(msg),
			"`eter log` lists recent transactions.")
	case connFailRe.MatchString(msg):
		return failWithHint(core.ExitDB, cleanPgMessage(msg),
			"check the database is reachable and DATABASE_URL/--db is correct (try `eter doctor`).")
	default:
		return fail(core.ExitDB, cleanPgMessage(msg))
	}
}

func pickMode(cascade, targeted bool) (core.UndoMode, error) {
	if cascade && targeted {
		return "", usageErr("choose only one of --cascade / --targeted")
	}
	if cascade {
		return core.Cascade, nil
	}
	if targeted {
		return core.Targeted, nil
	}
	return core.CleanOnly, nil
}

func parseTxid(s string) (int64, error) {
	v, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return 0, usageErr(fmt.Sprintf("invalid txid %q", s))
	}
	return v, nil
}

// renderExternalRefs prints the external-reference warning (human mode).
func renderExternalRefs(refs core.ExternalRefs) {
	if refs.Count == 0 {
		return
	}
	kinds := ""
	first := true
	for k, n := range refs.Kinds {
		if !first {
			kinds += ", "
		}
		kinds += fmt.Sprintf("%d %s", n, k)
		first = false
	}
	output.Info("⚠ %d external reference(s) in the affected rows (%s).", refs.Count, kinds)
	output.Info("  EterDB reverses database state only, these are NOT undone (e.g. Stripe charges, emails).")
	limit := refs.Samples
	if len(limit) > 5 {
		limit = limit[:5]
	}
	for _, r := range limit {
		output.Info("  - %s: %s [%s]", r.Column, r.Value, r.Kind)
	}
	if refs.Count > 5 {
		output.Info("  …and %d more.", refs.Count-5)
	}
}

// NewRootCmd builds the eter command tree.
func NewRootCmd() *cobra.Command {
	g := &globalOpts{}

	root := &cobra.Command{
		Use:           "eter",
		Short:         "EterDB, see and surgically reverse live Postgres transactions",
		Version:       version,
		SilenceErrors: true,
		SilenceUsage:  true,
	}
	root.SetVersionTemplate("{{.Version}}\n")
	root.PersistentFlags().BoolVar(&g.json, "json", false, "machine-readable JSON output (for agents/scripts)")
	root.PersistentFlags().StringVar(&g.db, "db", "", "Postgres connection string (direct mode)")
	root.PersistentFlags().StringVar(&g.url, "url", "", "orchestrator base URL (hosted mode)")
	root.PersistentFlags().StringVar(&g.token, "token", "", "orchestrator API token (hosted mode)")

	root.AddCommand(
		newConnectCmd(g),
		newDisconnectCmd(g),
		newInitCmd(g),
		newTrackCmd(g),
		newLogCmd(g),
		newShowCmd(g),
		newPreviewCmd(g),
		newUndoCmd(g),
		newCohortCmd(g),
		newUndoCohortCmd(g),
		newMarkCmd(g),
		newStatusCmd(g),
		newDoctorCmd(g),
		newVersionCmd(g),
		newDemoCmd(g),
		newGuideCmd(),
		newJobsCmd(g),
	)
	root.AddCommand(storageCommands(g)...) // recovery via the orchestrator (jobs) or the sidecar proxy
	return root
}

// Execute runs the CLI and returns the process exit code.
func Execute(ctx context.Context, args []string) int {
	// Ctrl-C / SIGTERM cancels the command's context so in-flight work (undo,
	// recovery) unwinds cleanly instead of leaving a stack trace; exit 130.
	ctx, stop := signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)
	defer stop()

	root := NewRootCmd()
	root.SetArgs(args)
	err := root.ExecuteContext(ctx)
	if err == nil {
		return core.ExitOK
	}
	var ee *exitError
	if errors.As(err, &ee) {
		if !ee.printed {
			fmt.Fprintf(os.Stderr, "error: %s\n", ee.message)
		}
		return ee.code
	}
	// An interrupt that didn't pass through mapErr (e.g. cobra internals): report it
	// as a clean shutdown rather than a usage error.
	if ctx.Err() != nil && errors.Is(err, context.Canceled) {
		fmt.Fprintln(os.Stderr, "interrupted")
		return core.ExitInterrupted
	}
	// cobra flag/argument parse error: it already wrote a diagnostic to stderr.
	fmt.Fprintf(os.Stderr, "error: %s\n", err.Error())
	return core.ExitUsage
}
