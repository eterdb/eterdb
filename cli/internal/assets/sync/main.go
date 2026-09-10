// Command sync refreshes the committed asset copies under cli/internal/assets
// from their canonical sources (ext/eter/eter.sql, demo/schema.sql, the
// repo-root docker-compose.yml). Run via `go generate ./internal/assets` from
// the cli module. Maintainer-only, it walks up from the assets dir to find the
// repo root, so it is a no-op outside the repo.
package main

import (
	"fmt"
	"os"
	"path/filepath"
)

// copies maps a source path (repo-root-relative) to its committed asset filename.
var copies = map[string]string{
	filepath.Join("ext", "eter", "eter.sql"): "eter.sql",
	filepath.Join("demo", "schema.sql"):      "demo-schema.sql",
	"docker-compose.yml":                     "docker-compose.yml",
}

func main() {
	root, err := repoRoot()
	if err != nil {
		fmt.Fprintf(os.Stderr, "assets sync: %v\n", err)
		os.Exit(1)
	}
	dest := filepath.Join(root, "cli", "internal", "assets")
	for src, name := range copies {
		b, err := os.ReadFile(filepath.Join(root, src)) //nolint:gosec // dev-only generator; src is a fixed in-repo path
		if err != nil {
			fmt.Fprintf(os.Stderr, "assets sync: read %s: %v\n", src, err)
			os.Exit(1)
		}
		//nolint:gosec // committed source assets are world-readable by design (0644)
		if err := os.WriteFile(filepath.Join(dest, name), b, 0o644); err != nil {
			fmt.Fprintf(os.Stderr, "assets sync: write %s: %v\n", name, err)
			os.Exit(1)
		}
		fmt.Printf("synced %s -> cli/internal/assets/%s (%d bytes)\n", src, name, len(b))
	}
}

// repoRoot walks up from the working directory looking for the repo marker
// (a go.mod at cli/ alongside an ext/ dir).
func repoRoot() (string, error) {
	dir, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "ext", "eter", "eter.sql")); err == nil {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", fmt.Errorf("repo root not found (no ext/eter/eter.sql above %s)", dir)
		}
		dir = parent
	}
}
