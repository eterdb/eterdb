package cmd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The direct proxy must honor --json by flipping the sidecar into structured
// output, "every command takes --json" is part of the frozen CLI contract,
// and hosted mode already gets it via the job runner.
func TestStorageProxyPassesJSONEnv(t *testing.T) {
	dir := t.TempDir()
	out := filepath.Join(dir, "env.out")
	stub := filepath.Join(dir, "stub-storage.sh")
	if err := os.WriteFile(stub, []byte("#!/bin/sh\nprintf '%s' \"${ETER_STORAGE_JSON:-unset}\" > \""+out+"\"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("ETER_STORAGE_BIN", stub)
	t.Setenv("ETER_STORAGE_HOST", "") // stay on the local-binary path
	// Point the profile at a nonexistent path so a dev's saved storage_host
	// can't reroute the proxy to ssh mode.
	t.Setenv("ETER_CONFIG", filepath.Join(dir, "none.json"))

	for _, c := range []struct {
		json bool
		want string
	}{{true, "1"}, {false, "unset"}} {
		if err := runStorageProxy(&globalOpts{json: c.json}, "snapshot", nil); err != nil {
			t.Fatalf("proxy run (json=%v) failed: %v", c.json, err)
		}
		b, err := os.ReadFile(out)
		if err != nil {
			t.Fatal(err)
		}
		if got := strings.TrimSpace(string(b)); got != c.want {
			t.Fatalf("json=%v: sidecar saw ETER_STORAGE_JSON=%q, want %q", c.json, got, c.want)
		}
	}
}
