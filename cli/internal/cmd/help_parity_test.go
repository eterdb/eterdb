package cmd

import (
	"strings"
	"testing"

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

// TestHelpParity enforces the help-quality contract across the whole command
// tree: every command has a Short, every runnable command carries an Example, and
// no flag ships with an empty usage string. This is the "metadata synchronization"
// idea borrowed from google/agents-cli, adapted to cobra, it stops the two gaps
// we just fixed (empty cohort flag usages, missing examples) from creeping back.
func TestHelpParity(t *testing.T) {
	walk(t, NewRootCmd())
}

func walk(t *testing.T, c *cobra.Command) {
	t.Helper()
	// Skip cobra's auto-generated commands (completion, help) and their children,
	// we don't author their help text.
	switch c.Name() {
	case "completion", "help":
		return
	}

	path := c.CommandPath()
	if strings.TrimSpace(c.Short) == "" {
		t.Errorf("%q: empty Short (every command needs a one-line summary)", path)
	}
	if c.Runnable() && strings.TrimSpace(c.Example) == "" {
		t.Errorf("%q: runnable command has no Example", path)
	}
	c.Flags().VisitAll(func(f *pflag.Flag) {
		switch f.Name {
		case "help", "version": // cobra-provided flags
			return
		}
		if strings.TrimSpace(f.Usage) == "" {
			t.Errorf("%q: flag --%s has an empty usage string", path, f.Name)
		}
	})

	for _, sub := range c.Commands() {
		walk(t, sub)
	}
}
