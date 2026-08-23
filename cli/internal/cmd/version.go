package cmd

import (
	"runtime/debug"

	"github.com/spf13/cobra"

	"github.com/eterdb/eterdb/cli/internal/output"
)

// buildRevision returns the VCS commit the binary was built from (best effort,
// from the embedded build info; "unknown" when built without VCS stamping).
func buildRevision() string {
	info, ok := debug.ReadBuildInfo()
	if !ok {
		return "unknown"
	}
	for _, s := range info.Settings {
		if s.Key == "vcs.revision" {
			if len(s.Value) > 12 {
				return s.Value[:12]
			}
			return s.Value
		}
	}
	return "unknown"
}

// newVersionCmd prints CLI + engine version detail. The root still carries the
// bare `--version` flag (frozen); this subcommand adds the engine version and
// build revision, and honours --json. The engine SQL ships embedded in this
// binary, so it carries the same release version as the CLI (there is no
// independent engine version; it is cut with the release, not the filename).
func newVersionCmd(g *globalOpts) *cobra.Command {
	return &cobra.Command{
		Use:     "version",
		Short:   "print the CLI version, build revision, and shipped engine version",
		Args:    cobra.NoArgs,
		Example: "  eter version\n  eter version --json",
		RunE: func(_ *cobra.Command, _ []string) error {
			output.SetJSON(g.json)
			info := map[string]any{
				"cli":            version,
				"engine_sql":     version,
				"build_revision": buildRevision(),
			}
			output.Emit(info, func() {
				output.Info("eter %s (engine %s, build %s)", version, version, buildRevision())
			})
			return nil
		},
	}
}
