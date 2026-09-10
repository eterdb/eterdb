// Package assets embeds the SQL the CLI needs to be self-contained, the engine
// script applied by `eter init` and the demo schema used by `eter demo up`. The
// files are committed copies of ext/eter/eter.sql and demo/schema.sql (kept
// in sync by `go generate ./internal/assets`), because go:embed cannot reach files
// outside this module's directory.
//
// Callers get a filesystem *path* (not bytes) so the existing readers,
// demo.Up and the shared DirectClient.Init, which both os.ReadFile a path, work
// unchanged: when the repo copy isn't on disk (an installed binary run outside the
// source tree) we materialize the embedded copy into the user cache dir and return
// that path.
package assets

import (
	"crypto/sha256"
	_ "embed"
	"os"
	"path/filepath"
)

//go:generate go run ./sync

//go:embed eter.sql
var eterSQL []byte

//go:embed demo-schema.sql
var demoSchema []byte

//go:embed docker-compose.yml
var dockerCompose []byte

// EterSQL returns the embedded engine SQL bytes.
func EterSQL() []byte { return eterSQL }

// DemoSchema returns the embedded demo schema bytes.
func DemoSchema() []byte { return demoSchema }

// DockerCompose returns the embedded two-container stack definition.
func DockerCompose() []byte { return dockerCompose }

// MaterializeEterSQL writes the embedded engine SQL to the user cache dir and
// returns its path (idempotent: rewrites only when missing or stale).
func MaterializeEterSQL() (string, error) {
	return materialize("eter.sql", eterSQL)
}

// MaterializeDemoSchema writes the embedded demo schema to the user cache dir and
// returns its path.
func MaterializeDemoSchema() (string, error) {
	return materialize("demo-schema.sql", demoSchema)
}

// MaterializeDockerCompose writes the embedded docker-compose.yml to the user
// cache dir and returns its path, so `eter demo` can bring the stack up itself
// when run from an installed binary with no source checkout.
func MaterializeDockerCompose() (string, error) {
	return materialize("docker-compose.yml", dockerCompose)
}

// materialize writes content to <cache>/eter/<name>, atomically, only when the
// existing file is absent or has different content, and returns the path.
func materialize(name string, content []byte) (string, error) {
	base, err := os.UserCacheDir()
	if err != nil {
		// No cache dir (e.g. no HOME): fall back to a temp dir so init/demo still work.
		base = os.TempDir()
	}
	dir := filepath.Join(base, "eter")
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return "", err
	}
	path := filepath.Join(dir, name)
	//nolint:gosec // path is our own cache dir joined with a fixed asset name, not attacker input
	if existing, err := os.ReadFile(path); err == nil && sha256.Sum256(existing) == sha256.Sum256(content) {
		return path, nil // already current
	}
	tmp, err := os.CreateTemp(dir, name+".*")
	if err != nil {
		return "", err
	}
	tmpName := tmp.Name()
	if _, err := tmp.Write(content); err != nil {
		_ = tmp.Close()
		_ = os.Remove(tmpName)
		return "", err
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmpName)
		return "", err
	}
	if err := os.Rename(tmpName, path); err != nil {
		_ = os.Remove(tmpName)
		return "", err
	}
	return path, nil
}
