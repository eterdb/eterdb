package cmd

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/eterdb/eterdb/cli/internal/client"
	"github.com/eterdb/eterdb/cli/internal/config"
	"github.com/eterdb/eterdb/cli/internal/core"
	"github.com/eterdb/eterdb/cli/internal/output"
)

// resolveDirectDSN returns the tenant DSN with the CLI's precedence
// (flag > env > saved profile) so the storage sidecar sees the same database the
// rest of the CLI talks to, including when the user connected via `eter connect`.
func resolveDirectDSN(g *globalOpts) string {
	if g.db != "" {
		return g.db
	}
	if v := os.Getenv("DATABASE_URL"); v != "" {
		return v
	}
	if p, err := config.LoadProfile(); err == nil && p != nil {
		return p.DB
	}
	return ""
}

// resolveMetaURL returns the durable store DSN (two-DB) with env > saved-profile
// precedence, so the storage sidecar writes its bookkeeping to the same store the
// rest of the CLI uses.
func resolveMetaURL() string {
	if v := os.Getenv("ETER_META_URL"); v != "" {
		return v
	}
	if p, err := config.LoadProfile(); err == nil && p != nil {
		return p.Meta
	}
	return ""
}

// The recovery commands (snapshot / recover-table / recover-rows / recover-column)
// present under the single `eter` surface, but the work they do, restore a base
// backup, replay WAL, extract the dropped object, happens where the backups and
// WAL archive live, not in the thin client transports. So these subcommands PROXY
// to the storage sidecar binary (`eter-storage`), which runs on the EterDB
// storage host and reads its config from the environment (DATABASE_URL /
// ETER_META_URL / ETER_BACKUP_DIR / …). This keeps one command surface for humans
// and agents while honouring where recovery actually executes.
//
// Override the binary with ETER_STORAGE_BIN (tests / non-PATH installs).
func storageBin() string {
	if b := os.Getenv("ETER_STORAGE_BIN"); b != "" {
		return b
	}
	return "eter-storage"
}

// shQuote single-quotes s for a POSIX shell (so args survive an ssh re-parse).
func shQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// storageOpt resolves a storage setting with precedence env > saved profile > default.
func storageOpt(env string, prof *config.Profile, profVal func(*config.Profile) string, def string) string {
	if v := os.Getenv(env); v != "" {
		return v
	}
	if prof != nil {
		if v := profVal(prof); v != "" {
			return v
		}
	}
	return def
}

// runStorageRemote runs the storage sidecar on a REMOTE host over ssh, so
// `eter recover-column …` works from a laptop without the operator hand-ssh-ing in.
// The recovery itself still executes where the backups + WAL archive live; we just
// drive it remotely. The remote command sources the host's env file so the sidecar
// gets the host-correct DSNs + backup/PG config, then execs the remote binary
// (${ETER_STORAGE_BIN:-eter-storage}).
// Each knob resolves env > saved profile (`eter connect --storage-*`) > default:
//
//	ETER_STORAGE_HOST / storage_host  ssh destination (set ⇒ remote mode)
//	ETER_STORAGE_SSH  / storage_ssh   ssh program + base args (default "ssh")
//	ETER_STORAGE_SUDO / storage_sudo  privilege prefix on the host (default none)
//	ETER_STORAGE_ENV  / storage_env   env file to source (default /tmp/eter-twenty.env)
func runStorageRemote(host string, prof *config.Profile, sub string, args []string, jsonOut bool) error {
	sshProg := storageOpt("ETER_STORAGE_SSH", prof, func(p *config.Profile) string { return p.StorageSSH }, "ssh")
	envFile := storageOpt("ETER_STORAGE_ENV", prof, func(p *config.Profile) string { return p.StorageEnv }, "/tmp/eter-twenty.env")

	quoted := make([]string, 0, len(args)+1)
	for _, p := range append([]string{sub}, args...) {
		quoted = append(quoted, shQuote(p))
	}
	jsonEnv := ""
	if jsonOut {
		jsonEnv = "export ETER_STORAGE_JSON=1; " // --json: the sidecar emits the structured result line
	}
	inner := fmt.Sprintf(`. %s 2>/dev/null; %sexec "${ETER_STORAGE_BIN:-eter-storage}" %s`,
		shQuote(envFile), jsonEnv, strings.Join(quoted, " "))
	remote := "sh -c " + shQuote(inner)
	if sudo := storageOpt("ETER_STORAGE_SUDO", prof, func(p *config.Profile) string { return p.StorageSudo }, ""); sudo != "" {
		remote = sudo + " " + remote
	}

	tokens := strings.Fields(sshProg)
	cmdArgs := append(append([]string{}, tokens[1:]...), host, remote)
	//nolint:gosec,noctx // ssh program + host come from the operator's own profile; foreground passthrough exec
	c := exec.Command(tokens[0], cmdArgs...)
	c.Stdout, c.Stderr, c.Stdin = os.Stdout, os.Stderr, os.Stdin
	c.Env = os.Environ()
	if err := c.Run(); err != nil {
		ee := &exec.ExitError{}
		if errors.As(err, &ee) {
			return &exitError{code: ee.ExitCode(), message: fmt.Sprintf("eter %s failed (on %s)", sub, host), printed: true}
		}
		return fail(core.ExitConfig, fmt.Sprintf(
			"could not reach the storage host via %q: %v\n"+
				"  Check ETER_STORAGE_HOST/ETER_STORAGE_SSH can ssh to the EterDB storage host.", sshProg, err))
	}
	return nil
}

// runStorageProxy execs the storage sidecar with `sub` + args, streaming stdio,
// and maps its outcome onto the CLI's exit-code contract. When ETER_STORAGE_HOST is
// set it drives the sidecar over ssh instead (recovery still runs where the
// backups + WAL archive live).
func runStorageProxy(g *globalOpts, sub string, args []string) error {
	prof, _ := config.LoadProfile()
	if host := storageOpt("ETER_STORAGE_HOST", prof, func(p *config.Profile) string { return p.StorageHost }, ""); host != "" {
		return runStorageRemote(host, prof, sub, args, g.json)
	}
	bin := storageBin()
	//nolint:gosec,noctx // bin is our own storage sidecar path; sub/args CLI-validated; foreground passthrough exec
	c := exec.Command(bin, append([]string{sub}, args...)...)
	c.Stdout = os.Stdout
	c.Stderr = os.Stderr
	c.Stdin = os.Stdin
	c.Env = os.Environ()
	// The sidecar reads DATABASE_URL from the env; surface the resolved connection
	// (flag/env/saved profile) so `eter recover-column …` works the same whether the
	// user passed --db, exported DATABASE_URL, or ran `eter connect`.
	if dsn := resolveDirectDSN(g); dsn != "" {
		c.Env = append(c.Env, "DATABASE_URL="+dsn)
	}
	if meta := resolveMetaURL(); meta != "" {
		c.Env = append(c.Env, "ETER_META_URL="+meta)
	}
	if g.json {
		// --json works on every CLI command: the sidecar swaps its human result
		// line for the structured one (same shape hosted mode returns as job output).
		c.Env = append(c.Env, "ETER_STORAGE_JSON=1")
	}

	err := c.Run()
	if err == nil {
		return nil
	}
	ee := &exec.ExitError{}
	if errors.As(err, &ee) {
		// The sidecar already wrote its own diagnostic to stderr; just carry the code.
		return &exitError{code: ee.ExitCode(), message: fmt.Sprintf("eter %s failed", sub), printed: true}
	}
	// Could not start the binary at all (not on PATH on this machine, etc.).
	return fail(core.ExitConfig, fmt.Sprintf(
		"could not run the storage sidecar (%q): %v\n"+
			"  Recovery runs where the base backups + WAL archive live. Drive it "+
			"remotely by setting ETER_STORAGE_HOST=<ssh-host> (recommended for a "+
			"laptop), or run on the storage host / point ETER_STORAGE_BIN at the "+
			"eter-storage binary.", bin, err))
}

// hostedForStorage decides whether storage commands go through the
// orchestrator's job API instead of the local-binary/ssh proxy. Explicit
// direct signals win (the proxy path stays byte-for-byte what it was):
// --db, ETER_STORAGE_HOST/ETER_STORAGE_BIN (env or saved profile), or a
// DATABASE_URL-only setup. Otherwise the same precedence as ResolveClient:
// --url/ETER_URL+token, then the saved URL profile.
func hostedForStorage(g *globalOpts) *client.HostedClient {
	if g.db != "" {
		return nil
	}
	if os.Getenv("ETER_STORAGE_HOST") != "" || os.Getenv("ETER_STORAGE_BIN") != "" {
		return nil
	}
	prof, _ := config.LoadProfile()
	if prof != nil && prof.StorageHost != "" {
		return nil
	}
	u, token := g.url, g.token
	if u == "" {
		u = os.Getenv("ETER_URL")
	}
	if token == "" {
		token = os.Getenv("ETER_TOKEN")
	}
	if u != "" && token != "" {
		return client.NewHostedClient(u, token)
	}
	if os.Getenv("DATABASE_URL") != "" {
		return nil
	}
	if prof != nil && prof.DB == "" && prof.URL != "" && prof.Token != "" {
		return client.NewHostedClient(prof.URL, prof.Token)
	}
	return nil
}

// storageJobArgs maps a storage subcommand's positional args onto the
// orchestrator job-args shape (mirrors the sidecar argv 1:1).
func storageJobArgs(sub string, args []string) (map[string]any, error) {
	at := func(i int) string {
		if i < len(args) {
			return args[i]
		}
		return ""
	}
	out := map[string]any{}
	switch sub {
	case "snapshot":
		if at(0) != "" {
			out["label"] = at(0)
		}
	case "recover-table", "recover-rows":
		if at(0) == "" {
			return nil, fmt.Errorf("usage: %s <schema.table> [snapshot]", sub)
		}
		out["table"] = at(0)
		if at(1) != "" {
			out["snapshot"] = at(1)
		}
	case "recover-column":
		if at(0) == "" || at(1) == "" {
			return nil, fmt.Errorf("usage: recover-column <schema.table> <column> [snapshot]")
		}
		out["table"], out["column"] = at(0), at(1)
		if at(2) != "" {
			out["snapshot"] = at(2)
		}
	case "as-of":
		if at(0) == "" || at(1) == "" {
			return nil, fmt.Errorf("usage: as-of <iso-time> <sql>")
		}
		out["at"], out["sql"] = at(0), strings.Join(args[1:], " ")
	default:
		return nil, fmt.Errorf("unknown storage command %q", sub)
	}
	return out, nil
}

// renderJobResult prints the same human line the sidecar prints locally,
// reconstructed from the job's structured output, one UX in both modes.
func renderJobResult(sub string, args []string, out map[string]any) {
	get := func(k string) string { v, _ := out[k].(string); return v }
	rows := int64(0)
	if f, ok := out["rows"].(float64); ok {
		rows = int64(f)
	}
	at := func(i int) string {
		if i < len(args) {
			return args[i]
		}
		return ""
	}
	switch sub {
	case "snapshot":
		fmt.Println(get("snapshot"))
	case "recover-table":
		fmt.Printf("✓ recovered table %s, %d row(s) restored from snapshot %s\n", at(0), rows, get("snapshot"))
	case "recover-rows":
		fmt.Printf("✓ recovered rows in %s, %d row(s) present, later writes preserved (from snapshot %s)\n", at(0), rows, get("snapshot"))
	case "recover-column":
		fmt.Printf("✓ recovered column %q on %s, %d row(s) restored by primary key, from snapshot %s\n", at(1), at(0), rows, get("snapshot"))
	case "as-of":
		fmt.Println(get("result"))
	}
}

// runStorageJob drives a storage command through the orchestrator: submit,
// then poll the job to a terminal state (unless --no-wait). Failed jobs feed
// the recorded error text through mapErr, preserving the exit-code contract.
func runStorageJob(g *globalOpts, hc *client.HostedClient, sub string, args []string, noWait bool) error {
	output.SetJSON(g.json)
	ctx := context.Background()
	jobArgs, err := storageJobArgs(sub, args)
	if err != nil {
		return fail(core.ExitUsage, err.Error())
	}
	id, err := hc.SubmitStorageJob(ctx, sub, jobArgs)
	if err != nil {
		return mapErr(err)
	}
	if noWait {
		output.Emit(map[string]any{"job_id": id, "state": "queued"}, func() {
			fmt.Printf("submitted job %d, follow with: eter jobs %d\n", id, id)
		})
		return nil
	}
	output.Info("job %d (%s) submitted, waiting…", id, sub)
	for {
		job, err := hc.GetJob(ctx, id)
		if err != nil {
			return mapErr(err)
		}
		switch job["state"] {
		case "succeeded":
			out, _ := job["output"].(map[string]any)
			output.Emit(job, func() { renderJobResult(sub, args, out) })
			return nil
		case "failed":
			msg, _ := job["error"].(string)
			if msg == "" {
				msg = fmt.Sprintf("job %d failed", id)
			}
			return mapErr(errors.New(msg))
		case "canceled":
			return fail(core.ExitDB, fmt.Sprintf("job %d was canceled", id))
		}
		time.Sleep(2 * time.Second)
	}
}

// newStorageProxyCmd builds one storage subcommand. Recovery args are
// positional (the sidecar takes no dash-flags), so normal flag parsing stays on
// and the root's --db/--json continue to work before the subcommand. In
// orchestrator mode (resolved hosted transport) the command submits a job and
// waits; in direct mode it proxies to the sidecar binary/ssh exactly as before.
func newStorageProxyCmd(g *globalOpts, use, short, example string) *cobra.Command {
	var noWait bool
	cmd := &cobra.Command{
		Use:     use,
		Short:   short,
		Args:    cobra.ArbitraryArgs,
		Example: example,
		RunE: func(cmd *cobra.Command, args []string) error {
			if hc := hostedForStorage(g); hc != nil {
				return runStorageJob(g, hc, cmd.Name(), args, noWait)
			}
			return runStorageProxy(g, cmd.Name(), args)
		},
	}
	cmd.Flags().BoolVar(&noWait, "no-wait", false,
		"submit the job and return its id immediately (orchestrator mode only)")
	return cmd
}

// storageCommands returns the recovery subcommands surfaced under `eter`.
func storageCommands(g *globalOpts) []*cobra.Command {
	return []*cobra.Command{
		newStorageProxyCmd(g, "snapshot [label]",
			"take a retained base backup of the database (storage host)",
			"  eter snapshot\n  eter snapshot pre-migration"),
		newStorageProxyCmd(g, "recover-table <schema.table> [snapshot]",
			"recover a dropped/truncated table from a backup (storage host)",
			"  eter recover-table public.invoices\n  eter recover-table public.invoices pre-migration"),
		newStorageProxyCmd(g, "recover-rows <schema.table> [snapshot]",
			"restore rows from a backup, preserving later writes (storage host)",
			"  eter recover-rows public.invoices"),
		newStorageProxyCmd(g, "recover-column <schema.table> <column> [snapshot]",
			"re-add a dropped column and repopulate it by PK (storage host)",
			"  eter recover-column public.invoices tax_rate"),
		newStorageProxyCmd(g, "as-of <iso-time> <sql>",
			"run sql against the DB as it was at time iso (PITR read, storage host)",
			"  eter as-of 2026-07-11T14:00:00Z 'select count(*) from public.invoices'"),
	}
}
