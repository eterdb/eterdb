package config

import (
	"context"
	"path/filepath"
	"testing"
)

func TestRedact(t *testing.T) {
	cases := []struct {
		in, want string
	}{
		{"postgres://eter:secret@localhost:5432/eter", "postgres://eter:***@localhost:5432/eter"},
		{"postgres://localhost/eter", "postgres://localhost/eter"},
		{"postgres://user@localhost/eter", "postgres://user@localhost/eter"},
		{"not a url", "not a url"},
	}
	for _, c := range cases {
		if got := redact(c.in); got != c.want {
			t.Errorf("redact(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestResolveNoConfig(t *testing.T) {
	t.Setenv("DATABASE_URL", "")
	t.Setenv("ETER_URL", "")
	t.Setenv("ETER_TOKEN", "")
	// Point the profile at a nonexistent path so a real saved connection on the
	// dev's machine can't satisfy the resolve and mask the no-config case.
	t.Setenv("ETER_CONFIG", filepath.Join(t.TempDir(), "none.json"))
	if _, err := ResolveClient(context.Background(), Opts{}); err == nil || !IsConfigError(err) {
		t.Fatalf("expected ConfigError, got %v", err)
	}
}

func TestProfileRoundTripAndPrecedence(t *testing.T) {
	t.Setenv("DATABASE_URL", "")
	t.Setenv("ETER_URL", "")
	t.Setenv("ETER_TOKEN", "")
	t.Setenv("ETER_CONFIG", filepath.Join(t.TempDir(), "config.json"))

	// No profile yet → config error.
	if _, err := ResolveClient(context.Background(), Opts{}); !IsConfigError(err) {
		t.Fatalf("expected ConfigError before save, got %v", err)
	}
	// Save a hosted profile → resolve falls back to it.
	if _, err := SaveProfile(Profile{URL: "http://localhost:4000", Token: "tok"}); err != nil {
		t.Fatalf("save: %v", err)
	}
	r, err := ResolveClient(context.Background(), Opts{})
	if err != nil {
		t.Fatalf("resolve from profile: %v", err)
	}
	defer r.Client.Close()
	if r.Mode != "hosted" {
		t.Fatalf("mode = %q, want hosted (from profile)", r.Mode)
	}
	// An env DATABASE_URL must outrank the saved profile. (Pool is lazy → no DB needed.)
	t.Setenv("DATABASE_URL", "postgres://localhost/eter")
	r2, err := ResolveClient(context.Background(), Opts{})
	if err != nil {
		t.Fatalf("resolve with env: %v", err)
	}
	defer r2.Client.Close()
	if r2.Mode != "direct" {
		t.Fatalf("mode = %q, want direct (env outranks profile)", r2.Mode)
	}
	// Clear → back to config error.
	if _, err := ClearProfile(); err != nil {
		t.Fatalf("clear: %v", err)
	}
	t.Setenv("DATABASE_URL", "")
	if _, err := ResolveClient(context.Background(), Opts{}); !IsConfigError(err) {
		t.Fatalf("expected ConfigError after clear, got %v", err)
	}
}

func TestResolveHosted(t *testing.T) {
	t.Setenv("DATABASE_URL", "")
	r, err := ResolveClient(context.Background(), Opts{URL: "http://localhost:4000", Token: "tok"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	defer r.Client.Close()
	if r.Mode != "hosted" {
		t.Fatalf("mode = %q, want hosted", r.Mode)
	}
}
