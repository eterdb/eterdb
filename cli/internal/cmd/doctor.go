package cmd

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/spf13/cobra"

	"github.com/eterdb/eterdb/cli/internal/config"
	"github.com/eterdb/eterdb/cli/internal/core"
	"github.com/eterdb/eterdb/cli/internal/output"
)

// newDoctorCmd is a one-shot environment diagnosis: it resolves the connection,
// probes engine readiness/version, checks the CLI-vs-engine version, reports the
// config-file location, and shows whether recovery (storage sidecar) is reachable.
// It's the diagnostic superset of `status`, safe, read-only, and agent-friendly
// via --json. Exit 0 when healthy; ExitConfig/ExitDB on a hard problem.
func newDoctorCmd(g *globalOpts) *cobra.Command {
	return &cobra.Command{
		Use:     "doctor",
		Short:   "diagnose the environment: connection, engine, versions, recovery prerequisites",
		Args:    cobra.NoArgs,
		Example: "  eter doctor\n  eter doctor --json",
		RunE: func(cmd *cobra.Command, _ []string) error {
			output.SetJSON(g.json)
			ctx := cmd.Context()
			if ctx == nil {
				ctx = context.Background()
			}

			report := map[string]any{}
			var warnings []string
			code := core.ExitOK

			// CLI + shipped engine version.
			report["cli"] = map[string]any{
				"version":        version,
				"engine_sql":     version,
				"build_revision": buildRevision(),
			}

			// Config file location.
			cfgPath := config.ProfilePath()
			cfgExists := false
			if cfgPath != "" {
				if _, err := os.Stat(cfgPath); err == nil {
					cfgExists = true
				}
			}
			report["config_file"] = map[string]any{"path": cfgPath, "exists": cfgExists}

			// Connection resolution + reachability.
			conn := map[string]any{"source": connectionSource(g)}
			var status map[string]any
			resolved, rerr := config.ResolveClient(ctx, config.Opts{DB: g.db, URL: g.url, Token: g.token})
			if rerr != nil {
				conn["ok"] = false
				conn["error"] = rerr.Error()
				if config.IsConfigError(rerr) {
					code = core.ExitConfig
				} else {
					code = core.ExitDB
				}
			} else {
				defer resolved.Client.Close()
				conn["ok"] = true
				conn["mode"] = resolved.Mode
				conn["describe"] = resolved.Describe
				if s, serr := resolved.Client.Status(ctx); serr != nil {
					conn["reachable"] = false
					conn["error"] = cleanPgMessage(serr.Error())
					code = core.ExitDB
				} else {
					conn["reachable"] = true
					status = s
				}
			}
			report["connection"] = conn

			// Engine health + CLI-vs-engine version compatibility.
			if status != nil {
				ready, _ := status["ready"].(bool)
				eng := map[string]any{
					"ready":             ready,
					"installed_version": output.Fmt(status["engine_version"]),
					"observe_mode":      output.Fmt(status["observe_mode"]),
					"capture_mode":      output.Fmt(status["capture_mode"]),
					"ssi":               status["ssi"],
				}
				if !ready {
					eng["reason"] = output.Fmt(status["reason"])
					warnings = append(warnings, "engine not installed, run `eter init`")
					if code == core.ExitOK {
						code = core.ExitDB
					}
				} else {
					installed := output.Fmt(status["engine_version"])
					shipped := version
					switch {
					case installed == "":
						// Default path: the engine is a SQL script, not CREATE EXTENSION,
						// so pg_extension reports no version. Informational, not a warning.
						eng["version_note"] = "installed via SQL script (pg_extension reports no version)"
					case installed != shipped:
						warnings = append(warnings, fmt.Sprintf(
							"engine version mismatch: CLI ships %s, database has %s, run `eter init` to sync",
							shipped, installed))
					}
				}
				report["engine"] = eng
			}

			// Recovery prerequisites (storage sidecar / orchestrator reachability).
			report["recovery"] = recoveryReport(g)

			report["warnings"] = warnings
			report["ok"] = code == core.ExitOK && len(warnings) == 0

			output.Emit(report, func() { renderDoctor(report) })
			if code != core.ExitOK {
				return &exitError{code: code, printed: true}
			}
			return nil
		},
	}
}

// connectionSource names which precedence slot supplies the connection, mirroring
// config.ResolveClient (flag > env > saved profile) so `doctor` explains *why* it
// connected where it did.
func connectionSource(g *globalOpts) string {
	if g.db != "" {
		return "--db flag"
	}
	u, token := g.url, g.token
	fromFlags := u != "" && token != ""
	if u == "" {
		u = os.Getenv("ETER_URL")
	}
	if token == "" {
		token = os.Getenv("ETER_TOKEN")
	}
	switch {
	case fromFlags:
		return "--url/--token flags"
	case u != "" && token != "":
		return "ETER_URL/ETER_TOKEN env"
	case os.Getenv("DATABASE_URL") != "":
		return "DATABASE_URL env"
	default:
		if prof, _ := config.LoadProfile(); prof != nil {
			return "saved profile"
		}
		return "none"
	}
}

// recoveryReport describes where `eter recover-*`/`snapshot` would execute and
// whether that path is configured, reusing the same routing as hostedForStorage.
func recoveryReport(g *globalOpts) map[string]any {
	if hostedForStorage(g) != nil {
		return map[string]any{"mode": "orchestrator (hosted jobs)"}
	}
	prof, _ := config.LoadProfile()
	if host := os.Getenv("ETER_STORAGE_HOST"); host != "" {
		return map[string]any{"mode": "storage host (ssh)", "storage_host": host}
	}
	if prof != nil && prof.StorageHost != "" {
		return map[string]any{"mode": "storage host (ssh)", "storage_host": prof.StorageHost}
	}
	bin := storageBin()
	r := map[string]any{"mode": "local sidecar", "storage_bin": bin}
	if path, err := exec.LookPath(bin); err == nil {
		r["storage_bin_found"] = true
		r["storage_bin_path"] = path
	} else {
		r["storage_bin_found"] = false
	}
	return r
}

// renderDoctor prints the human-readable diagnosis (stderr, like `status`).
func renderDoctor(r map[string]any) {
	glyph := func(ok bool) string {
		if ok {
			return "✓"
		}
		return "✗"
	}

	output.Info("EterDB doctor")
	output.Info("%s", strings.Repeat("-", 13))

	if cli, ok := r["cli"].(map[string]any); ok {
		output.Info("cli        eter %s (engine %s, build %s)",
			output.Fmt(cli["version"]), output.Fmt(cli["engine_sql"]), output.Fmt(cli["build_revision"]))
	}

	if cfg, ok := r["config_file"].(map[string]any); ok {
		path := output.Fmt(cfg["path"])
		if path == "" {
			path = "(no config dir)"
		}
		if exists, _ := cfg["exists"].(bool); exists {
			output.Info("config     ✓ %s", path)
		} else {
			output.Info("config     · %s (none saved)", path)
		}
	}

	if conn, ok := r["connection"].(map[string]any); ok {
		if connOk, _ := conn["ok"].(bool); !connOk {
			output.Info("connection ✗ %s, %s", output.Fmt(conn["source"]), output.Fmt(conn["error"]))
		} else {
			reachable, _ := conn["reachable"].(bool)
			output.Info("connection %s %s (%s)", glyph(reachable), output.Fmt(conn["describe"]), output.Fmt(conn["source"]))
			if !reachable {
				output.Info("           %s", output.Fmt(conn["error"]))
			}
		}
	}

	if eng, ok := r["engine"].(map[string]any); ok {
		if ready, _ := eng["ready"].(bool); !ready {
			output.Info("engine     ✗ %s", output.Fmt(eng["reason"]))
		} else {
			line := "eter installed"
			if v := output.Fmt(eng["installed_version"]); v != "" {
				line = "eter " + v
			}
			if note := output.Fmt(eng["version_note"]); note != "" {
				line += " (" + note + ")"
			}
			if b, _ := eng["ssi"].(bool); b {
				line += " · eter_ssi present"
			}
			output.Info("engine     ✓ %s", line)
			output.Info("           observe=%s · capture=%s", output.Fmt(eng["observe_mode"]), output.Fmt(eng["capture_mode"]))
		}
	}

	if rec, ok := r["recovery"].(map[string]any); ok {
		line := output.Fmt(rec["mode"])
		if bin := output.Fmt(rec["storage_bin"]); bin != "" {
			found, _ := rec["storage_bin_found"].(bool)
			state := "not on PATH"
			if found {
				state = "found"
			}
			line += " · " + bin + " " + state
		}
		if host := output.Fmt(rec["storage_host"]); host != "" {
			line += " · " + host
		}
		output.Info("recovery   %s", line)
	}

	if warns, ok := r["warnings"].([]string); ok && len(warns) > 0 {
		output.Info("")
		for _, w := range warns {
			output.Info("⚠ %s", w)
		}
	}
}
