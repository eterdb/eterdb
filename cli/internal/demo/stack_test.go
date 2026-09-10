package demo

import (
	"bytes"
	"context"
	"net"
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
	for _, want := range []string{"ghcr.io/eterdb/engine", "ghcr.io/eterdb/control-plane", "ETER_DEMO_ENGINE_PORT"} {
		if !bytes.Contains(b, []byte(want)) {
			t.Errorf("materialized compose missing %q", want)
		}
	}
}

func TestPortOverrides(t *testing.T) {
	if EnginePort() != "5433" || OrchPort() != "4400" {
		t.Fatalf("defaults changed: engine=%s orch=%s", EnginePort(), OrchPort())
	}
	t.Setenv("ETER_DEMO_ENGINE_PORT", "15433")
	t.Setenv("ETER_DEMO_ORCH_PORT", "14400")
	if EnginePort() != "15433" || OrchPort() != "14400" {
		t.Fatalf("override ignored: engine=%s orch=%s", EnginePort(), OrchPort())
	}
}

// TestPreflightPortsBusy binds a real listener on an ephemeral port and checks
// PreflightPorts refuses it (no demo project is running in the test env).
func TestPreflightPortsBusy(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer ln.Close()
	_, port, _ := net.SplitHostPort(ln.Addr().String())

	t.Setenv("ETER_DEMO_ENGINE_PORT", port)
	err = PreflightPorts(context.Background())
	if err == nil {
		t.Fatal("PreflightPorts accepted a port with a live listener")
	}
	if !bytes.Contains([]byte(err.Error()), []byte(port)) {
		t.Errorf("error should name the busy port %s: %v", port, err)
	}
}

// TestPreflightPortsFree points both ports at almost-certainly-free ephemeral
// numbers and checks PreflightPorts passes.
func TestPreflightPortsFree(t *testing.T) {
	for _, k := range []string{"ETER_DEMO_ENGINE_PORT", "ETER_DEMO_ORCH_PORT"} {
		ln, _ := net.Listen("tcp", "127.0.0.1:0")
		_, p, _ := net.SplitHostPort(ln.Addr().String())
		ln.Close() // free it again
		t.Setenv(k, p)
	}
	if err := PreflightPorts(context.Background()); err != nil {
		t.Fatalf("PreflightPorts rejected free ports: %v", err)
	}
}
