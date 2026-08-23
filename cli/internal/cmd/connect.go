package cmd

import (
	"os"

	"github.com/spf13/cobra"

	"github.com/eterdb/eterdb/cli/internal/config"
	"github.com/eterdb/eterdb/cli/internal/core"
	"github.com/eterdb/eterdb/cli/internal/output"
)

// newConnectCmd probes an instance and, if reachable, saves it as the default
// connection so later commands need no --db/DATABASE_URL. The saved profile is
// the lowest-precedence source (flag > env > profile), so it never overrides an
// explicit connection.
func newConnectCmd(g *globalOpts) *cobra.Command {
	var meta string
	var storageHost, storageSSH, storageSudo, storageEnv string
	cmd := &cobra.Command{
		Use:   "connect [dsn]",
		Short: "validate a connection, show readiness, and save it as the default",
		Long: "Probe an EterDB instance and, if reachable, save it as the default\n" +
			"connection (owner-only file) so later commands need no --db/DATABASE_URL.\n" +
			"For the two-DB architecture, pass --meta <store-dsn> (or set ETER_META_URL)\n" +
			"so reads/preview/history resolve against the durable metadata store.\n" +
			"Precedence stays flag > env > saved profile.",
		Example: "  eter connect postgres://eter:eter@localhost:5432/eter\n" +
			"  eter connect postgres://…/tenant --meta postgres://…/store",
		Args: cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			output.SetJSON(g.json)

			// What to connect to: positional dsn > --db > --url/token > env.
			prof := config.Profile{}
			switch {
			case len(args) == 1:
				prof.DB = args[0]
			case g.db != "":
				prof.DB = g.db
			case g.url != "":
				prof.URL, prof.Token = g.url, g.token
			case os.Getenv("DATABASE_URL") != "":
				prof.DB = os.Getenv("DATABASE_URL")
			case os.Getenv("ETER_URL") != "":
				prof.URL, prof.Token = os.Getenv("ETER_URL"), os.Getenv("ETER_TOKEN")
			}
			if prof.DB == "" && prof.URL == "" {
				return usageErr("nothing to connect to: pass a DSN, --db, --url/--token, or set DATABASE_URL")
			}
			// Store DSN (two-DB): --meta flag, else inherit ETER_META_URL.
			prof.Meta = meta
			if prof.Meta == "" {
				prof.Meta = os.Getenv("ETER_META_URL")
			}
			// Make validation (and the saved profile) resolve against the store.
			if prof.Meta != "" {
				_ = os.Setenv("ETER_META_URL", prof.Meta)
			}
			// Storage host (optional): persist where backup-based recovery runs so
			// `eter recover-*` drives it over ssh, no hand-ssh from the laptop.
			prof.StorageHost, prof.StorageSSH = storageHost, storageSSH
			prof.StorageSudo, prof.StorageEnv = storageSudo, storageEnv

			ctx := cmd.Context()
			resolved, err := config.ResolveClient(ctx, config.Opts{DB: prof.DB, URL: prof.URL, Token: prof.Token})
			if err != nil {
				if config.IsConfigError(err) {
					return fail(core.ExitConfig, err.Error())
				}
				return fail(core.ExitDB, err.Error())
			}
			defer resolved.Client.Close()

			// Reachability + readiness probe before we persist anything.
			s, err := resolved.Client.Status(ctx)
			if err != nil {
				return mapErr(err)
			}
			path, serr := config.SaveProfile(prof)
			if serr != nil {
				return fail(core.ExitConfig, serr.Error())
			}
			s["saved_to"] = path
			output.Emit(s, func() {
				renderStatus(s)
				output.Info("  saved as the default connection → %s", path)
			})
			return nil
		},
	}
	cmd.Flags().StringVar(&meta, "meta", "", "durable metadata store DSN (two-DB; ETER_META_URL)")
	cmd.Flags().StringVar(&storageHost, "storage-host", "", "ssh destination of the storage host, so `eter recover-*` runs there (no hand-ssh)")
	cmd.Flags().StringVar(&storageSSH, "storage-ssh", "", `ssh program + base args (default "ssh"; e.g. "ssh -F ~/.lima/<vm>/ssh.config")`)
	cmd.Flags().StringVar(&storageSudo, "storage-sudo", "", `privilege prefix on the storage host (e.g. "sudo")`)
	cmd.Flags().StringVar(&storageEnv, "storage-env", "", "env file to source on the storage host (default /tmp/eter-twenty.env)")
	return cmd
}

// newDisconnectCmd forgets the saved default connection.
func newDisconnectCmd(g *globalOpts) *cobra.Command {
	return &cobra.Command{
		Use:     "disconnect",
		Short:   "forget the saved default connection",
		Args:    cobra.NoArgs,
		Example: "  eter disconnect",
		RunE: func(cmd *cobra.Command, _ []string) error {
			output.SetJSON(g.json)
			path, err := config.ClearProfile()
			if err != nil {
				return fail(core.ExitConfig, err.Error())
			}
			output.Emit(map[string]any{"ok": true, "cleared": path}, func() {
				output.Info("forgot the saved connection (%s)", path)
			})
			return nil
		},
	}
}
