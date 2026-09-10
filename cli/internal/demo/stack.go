package demo

// The containerized EterDB stack (docker-compose.yml: engine + control-plane).
// An installed `eter` (brew / tarball) has no source checkout, so it carries the
// compose file embedded, materializes it to the user cache dir, and drives
// `docker compose` against it under a dedicated project name. `eter demo` uses
// this to bring the stack up itself instead of telling the operator to run
// `docker compose up` in a directory they do not have.

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/eterdb/eterdb/cli/internal/assets"
)

// composeProject isolates the demo's containers/volumes/network from any other
// compose project on the host, and gives StackDown a precise target.
const composeProject = "eterdb-demo"

// EnginePort and OrchPort are the host ports the demo stack publishes. The
// compose file reads the same env vars (ETER_DEMO_ENGINE_PORT /
// ETER_DEMO_ORCH_PORT), so overriding one here and passing the environment
// through to `docker compose` keeps the two in step.
func EnginePort() string { return envOr("ETER_DEMO_ENGINE_PORT", "5433") }
func OrchPort() string   { return envOr("ETER_DEMO_ORCH_PORT", "4400") }

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// PreflightPorts checks the demo's host ports before bring-up. If something is
// already listening on the engine port and it is NOT this demo's own stack, that
// process shadows the container: the demo seeds one database while capture in
// the control plane watches another, and the walkthrough hangs at "0 rows
// captured" with no hint why. Fail loudly instead.
func PreflightPorts(ctx context.Context) error {
	if StackRunning(ctx) {
		return nil // our own stack is already up; compose will reconcile it
	}
	for _, p := range []struct{ name, port string }{
		{"engine", EnginePort()},
		{"orchestrator", OrchPort()},
	} {
		if tcpBusy(ctx, p.port) {
			return fmt.Errorf(
				"localhost:%s (the demo %s port) is already in use, and it isn't the demo stack; "+
					"stop whatever holds it, or pick free ports: "+
					"ETER_DEMO_ENGINE_PORT=15433 ETER_DEMO_ORCH_PORT=14400 eter demo",
				p.port, p.name)
		}
	}
	return nil
}

// tcpBusy reports whether something accepts a connection on localhost:port.
func tcpBusy(ctx context.Context, port string) bool {
	d := net.Dialer{Timeout: 700 * time.Millisecond}
	c, err := d.DialContext(ctx, "tcp", net.JoinHostPort("localhost", port))
	if err != nil {
		return false
	}
	_ = c.Close()
	return true
}

// DockerStatus reports whether the demo can drive Docker on this host.
type DockerStatus struct {
	OK     bool
	Reason string // populated when !OK: a one-line, user-facing explanation
}

// CheckDocker probes for `docker`, the Compose v2 plugin, and a responsive
// daemon without touching any containers. Cheap enough to call on every start.
func CheckDocker(ctx context.Context) DockerStatus {
	if _, err := exec.LookPath("docker"); err != nil {
		return DockerStatus{Reason: "docker is not installed or not on PATH"}
	}
	if out, err := runDocker(ctx, "compose", "version"); err != nil {
		return DockerStatus{Reason: "the Docker Compose v2 plugin is not available (`docker compose version` failed): " + firstLine(out)}
	}
	if out, err := runDocker(ctx, "info", "--format", "{{.ServerVersion}}"); err != nil {
		return DockerStatus{Reason: "the Docker daemon is not responding (is Docker Desktop running?): " + firstLine(out)}
	}
	return DockerStatus{OK: true}
}

// StackUp materializes the embedded compose file and runs `docker compose up -d
// --wait` under the demo project, streaming progress to w. It blocks until both
// containers report healthy (the compose healthchecks gate that) or the wait
// times out. The first run also pulls the images, which can take a few minutes.
func StackUp(ctx context.Context, w io.Writer) error {
	composePath, err := assets.MaterializeDockerCompose()
	if err != nil {
		return fmt.Errorf("write compose file: %w", err)
	}
	// --wait blocks on the healthchecks; --wait-timeout covers a cold image pull
	// on a slow link plus the engine's ~90s health gate and the control plane's
	// ~120s one.
	return streamDocker(ctx, w,
		"compose", "-p", composeProject, "-f", composePath,
		"up", "-d", "--wait", "--wait-timeout", "600")
}

// StackDown stops and removes the demo stack (containers, network, and the named
// volumes, so the next run starts clean). Best-effort: a missing project is not
// an error to `docker compose down`.
func StackDown(ctx context.Context, w io.Writer) error {
	composePath, err := assets.MaterializeDockerCompose()
	if err != nil {
		return fmt.Errorf("write compose file: %w", err)
	}
	return streamDocker(ctx, w,
		"compose", "-p", composeProject, "-f", composePath, "down", "-v")
}

// StackRunning reports whether the demo project currently has a running
// container, so `eter demo down` knows whether there is a stack to tear down.
func StackRunning(ctx context.Context) bool {
	out, err := runDocker(ctx, "compose", "-p", composeProject, "ls", "--format", "json")
	if err != nil {
		return false
	}
	// `docker compose ls` lists only running projects; a name match is enough.
	return bytes.Contains(out, []byte(`"`+composeProject+`"`))
}

// runDocker runs `docker <args...>` and returns its combined output. All call
// sites pass fixed subcommands plus paths from our own cache dir.
func runDocker(ctx context.Context, args ...string) ([]byte, error) {
	//nolint:gosec // fixed docker subcommands; the only non-literal arg is our cache-dir compose path
	return exec.CommandContext(ctx, "docker", args...).CombinedOutput()
}

// streamDocker runs `docker <args...>` with output streamed to w.
func streamDocker(ctx context.Context, w io.Writer, args ...string) error {
	//nolint:gosec // fixed docker subcommands; the only non-literal arg is our cache-dir compose path
	cmd := exec.CommandContext(ctx, "docker", args...)
	cmd.Stdout = w
	cmd.Stderr = w
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("docker %s: %w", args[0], err)
	}
	return nil
}

func firstLine(b []byte) string {
	s := strings.TrimSpace(string(b))
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	return strings.TrimSpace(s)
}
