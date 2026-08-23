package assets

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

// TestEmbeddedAssetsInSync guards against the committed copies drifting from their
// canonical sources. It only runs in the repo (where the sources exist); an
// installed/module-cache build skips it. Regenerate with `go generate ./internal/assets`.
func TestEmbeddedAssetsInSync(t *testing.T) {
	root := repoRoot(t)
	if root == "" {
		t.Skip("canonical sources not present (installed build), skipping drift check")
	}
	cases := []struct {
		src      string
		embedded []byte
	}{
		{filepath.Join("ext", "eter", "eter.sql"), eterSQL},
		{filepath.Join("demo", "schema.sql"), demoSchema},
	}
	for _, c := range cases {
		want, err := os.ReadFile(filepath.Join(root, c.src))
		if err != nil {
			t.Fatalf("read %s: %v", c.src, err)
		}
		if !bytes.Equal(want, c.embedded) {
			t.Errorf("%s differs from its committed asset copy, run `go generate ./internal/assets`", c.src)
		}
	}
}

// TestMaterializeRoundTrips writes the embedded SQL to a temp cache dir and checks
// the returned path holds exactly the embedded bytes.
func TestMaterializeRoundTrips(t *testing.T) {
	t.Setenv("XDG_CACHE_HOME", t.TempDir()) // UserCacheDir honours this on Linux
	path, err := MaterializeEterSQL()
	if err != nil {
		t.Fatalf("materialize: %v", err)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read materialized: %v", err)
	}
	if !bytes.Equal(got, eterSQL) {
		t.Fatalf("materialized content != embedded content")
	}
}

func repoRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		return ""
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "ext", "eter", "eter.sql")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return ""
		}
		dir = parent
	}
}
