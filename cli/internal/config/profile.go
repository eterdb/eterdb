package config

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// Profile is the persisted default connection written by `eter connect`. It is
// the lowest-precedence source (flag > env > profile), so an explicit --db or
// DATABASE_URL always wins. Meta is the durable metadata store DSN (ETER_META_URL)
// for the two-DB architecture, the tenant holds no durable eter data, so reads /
// preview / history all resolve against the store.
type Profile struct {
	DB    string `json:"db,omitempty"`
	Meta  string `json:"meta,omitempty"`
	URL   string `json:"url,omitempty"`
	Token string `json:"token,omitempty"`
	// Storage host (optional): where backup-based recovery runs. When set,
	// `eter snapshot`/`recover-*` drive the storage sidecar there over ssh instead of
	// execing a local binary, so recovery works from a laptop with no hand-ssh.
	StorageHost string `json:"storage_host,omitempty"` // ssh destination
	StorageSSH  string `json:"storage_ssh,omitempty"`  // ssh program + base args (default "ssh")
	StorageSudo string `json:"storage_sudo,omitempty"` // privilege prefix on the host (e.g. "sudo")
	StorageEnv  string `json:"storage_env,omitempty"`  // env file to source on the host
}

// ProfilePath is $ETER_CONFIG, else $XDG_CONFIG_HOME/eter/config.json, else
// ~/.config/eter/config.json. Empty when no home can be determined.
func ProfilePath() string {
	if p := os.Getenv("ETER_CONFIG"); p != "" {
		return p
	}
	base := os.Getenv("XDG_CONFIG_HOME")
	if base == "" {
		home, err := os.UserHomeDir()
		if err != nil || home == "" {
			return ""
		}
		base = filepath.Join(home, ".config")
	}
	return filepath.Join(base, "eter", "config.json")
}

// LoadProfile reads the saved profile; returns (nil, nil) when none exists or it
// carries no connection.
func LoadProfile() (*Profile, error) {
	path := ProfilePath()
	if path == "" {
		return nil, nil
	}
	b, err := os.ReadFile(path) //nolint:gosec // path is the operator's own profile file location
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var p Profile
	if err := json.Unmarshal(b, &p); err != nil {
		return nil, err
	}
	if p.DB == "" && p.URL == "" {
		return nil, nil
	}
	return &p, nil
}

// SaveProfile writes the profile owner-only (it can hold a password/token, like
// ~/.pgpass or a kubeconfig) and returns the path written.
func SaveProfile(p Profile) (string, error) {
	path := ProfilePath()
	if path == "" {
		return "", newConfigError("cannot determine a config path (set ETER_CONFIG or HOME)")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return "", err
	}
	b, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return "", err
	}
	if err := os.WriteFile(path, append(b, '\n'), 0o600); err != nil {
		return "", err
	}
	return path, nil
}

// ClearProfile removes the saved profile (no error when absent).
func ClearProfile() (string, error) {
	path := ProfilePath()
	if path == "" {
		return "", nil
	}
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return "", err
	}
	return path, nil
}
