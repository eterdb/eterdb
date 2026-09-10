package demo

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/eterdb/eterdb/cli/internal/assets"
)

func TestFirstLine(t *testing.T) {
	cases := map[string]string{
		"":                 "",
		"one line":         "one line",
		"first\nsecond":    "first",
		"  spaced  \nmore": "spaced",
		"trailing\n":       "trailing",
	}
	for in, want := range cases {
		if got := firstLine([]byte(in)); got != want {
			t.Errorf("firstLine(%q) = %q, want %q", in, got, want)
		}
	}
}

// TestCheckDockerMissing points PATH at an empty dir so `docker` cannot resolve,
// and checks CheckDocker reports that cleanly rather than panicking.
func TestCheckDockerMissing(t *testing.T) {
	t.Setenv("PATH", t.TempDir())
	st := CheckDocker(context.Background())
	if st.OK {
		t.Fatal("CheckDocker reported OK with no docker on PATH")
	}
	if st.Reason == "" {
		t.Fatal("CheckDocker gave no reason")
	}
}

// TestStackComposeMaterializes checks the embedded compose file is written to
// disk with the shape StackUp/StackDown depend on.
func TestStackComposeMaterializes(t *testing.T) {
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	path, err := assets.MaterializeDockerCompose()
	if err != nil {
		t.Fatalf("materialize: %v", err)
	}
	if filepath.Base(path) != "docker-compose.yml" {
		t.Errorf("unexpected filename: %s", path)
	}
	b, err := os.ReadFile(path) //nolint:gosec // test-controlled temp path
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	for _, want := range []string{"ghcr.io/eterdb/engine", "ghcr.io/eterdb/control-plane", "4400"} {
		if !bytes.Contains(b, []byte(want)) {
			t.Errorf("materialized compose missing %q", want)
		}
	}
}
