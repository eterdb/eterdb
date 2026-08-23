// Package config resolves which transport the CLI should use from flags and
// environment, mirroring the TypeScript resolveClient precedence.
package config

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/eterdb/eterdb/cli/internal/client"
)

// ConfigError signals a missing/invalid connection configuration (exit 6).
type ConfigError struct{ msg string }

func (e *ConfigError) Error() string { return e.msg }

func newConfigError(format string, args ...any) *ConfigError {
	return &ConfigError{msg: fmt.Sprintf(format, args...)}
}

// IsConfigError reports whether err is a ConfigError.
func IsConfigError(err error) bool {
	var ce *ConfigError
	return errors.As(err, &ce)
}

// Resolved holds the chosen transport and a human description of it.
type Resolved struct {
	Mode     string // "direct" | "hosted"
	Client   client.EterClient
	Describe string
}

// Opts are the global connection flags.
type Opts struct {
	DB    string
	URL   string
	Token string
}

// ResolveClient chooses the transport. Precedence:
//  1. --db <url> flag                  -> direct mode
//  2. ETER_URL + ETER_TOKEN            -> hosted mode (friends, shared instance)
//  3. DATABASE_URL                     -> direct mode (local / bring-your-own)
//  4. saved profile (`eter connect`)   -> direct or hosted (lowest precedence)
func ResolveClient(ctx context.Context, o Opts) (*Resolved, error) {
	db := o.DB
	if db == "" {
		db = os.Getenv("DATABASE_URL")
	}
	u := o.URL
	if u == "" {
		u = os.Getenv("ETER_URL")
	}
	token := o.Token
	if token == "" {
		token = os.Getenv("ETER_TOKEN")
	}

	if o.DB != "" {
		c, err := client.NewDirectClient(ctx, o.DB)
		if err != nil {
			return nil, err
		}
		return &Resolved{Mode: "direct", Client: c, Describe: "direct -> " + redact(o.DB)}, nil
	}
	if u != "" && token != "" {
		return &Resolved{Mode: "hosted", Client: client.NewHostedClient(u, token), Describe: "hosted -> " + u}, nil
	}
	if db != "" {
		c, err := client.NewDirectClient(ctx, db)
		if err != nil {
			return nil, err
		}
		return &Resolved{Mode: "direct", Client: c, Describe: "direct -> " + redact(db)}, nil
	}
	// Lowest precedence: a connection saved by `eter connect`.
	if prof, err := LoadProfile(); err == nil && prof != nil {
		if prof.DB != "" {
			// Surface the saved store DSN (two-DB) unless the env already set one,
			// so the client's metadata pool resolves to the store.
			if prof.Meta != "" && os.Getenv("ETER_META_URL") == "" {
				_ = os.Setenv("ETER_META_URL", prof.Meta)
			}
			c, err := client.NewDirectClient(ctx, prof.DB)
			if err != nil {
				return nil, err
			}
			return &Resolved{Mode: "direct", Client: c, Describe: "direct (saved) -> " + redact(prof.DB)}, nil
		}
		if prof.URL != "" && prof.Token != "" {
			return &Resolved{Mode: "hosted", Client: client.NewHostedClient(prof.URL, prof.Token), Describe: "hosted (saved) -> " + prof.URL}, nil
		}
	}
	return nil, newConfigError(
		"No connection configured. Run `eter connect <url>`, set DATABASE_URL (direct mode) or ETER_URL + ETER_TOKEN (hosted mode), or pass --db <url>.")
}

// redact masks the password in a connection URL, preserving the rest of the
// string verbatim (no percent re-encoding). Non-URL strings pass through.
func redact(raw string) string {
	schemeEnd := strings.Index(raw, "://")
	if schemeEnd < 0 {
		return raw
	}
	rest := raw[schemeEnd+3:]
	authEnd := strings.IndexByte(rest, '/')
	authority := rest
	tail := ""
	if authEnd >= 0 {
		authority = rest[:authEnd]
		tail = rest[authEnd:]
	}
	at := strings.LastIndexByte(authority, '@')
	if at < 0 {
		return raw // no userinfo → nothing to redact
	}
	userinfo, host := authority[:at], authority[at:]
	colon := strings.IndexByte(userinfo, ':')
	if colon < 0 {
		return raw // user without password
	}
	return raw[:schemeEnd+3] + userinfo[:colon] + ":***" + host + tail
}
