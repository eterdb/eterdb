// Thin shell helpers. The storage sidecar is an orchestrator: the real work is
// done by pg_basebackup / pg_ctl / pg_dump / psql, which it composes.
//
// Failures abort the current command: sh panics with the captured stderr, which
// main() recovers into a single error line + non-zero exit. Cleanup defers
// (restore-dir teardown, temp-file removal) run during the panic unwind, so a
// failed recovery never leaks a restore dir or a throwaway Postgres.
package main

import (
	"bytes"
	"fmt"
	"os/exec"
	"strings"
)

func sh(cmd string) string {
	//nolint:gosec,noctx // internal storage orchestration; cmd from trusted templates, synchronous helper
	c := exec.Command("sh", "-c", cmd)
	var stdout, stderr bytes.Buffer
	c.Stdout = &stdout
	c.Stderr = &stderr
	if err := c.Run(); err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = err.Error()
		}
		panic(fmt.Errorf("command failed: %s\n%s", cmd, msg))
	}
	return strings.TrimSpace(stdout.String())
}

// trySh runs cmd, returning success + output instead of panicking.
func trySh(cmd string) (bool, string) {
	//nolint:gosec,noctx // internal storage orchestration; cmd from trusted templates, synchronous helper
	c := exec.Command("sh", "-c", cmd)
	var stdout, stderr bytes.Buffer
	c.Stdout = &stdout
	c.Stderr = &stderr
	if err := c.Run(); err != nil {
		out := strings.TrimSpace(stderr.String())
		if out == "" {
			out = strings.TrimSpace(stdout.String())
		}
		if out == "" {
			out = err.Error()
		}
		return false, out
	}
	return true, strings.TrimSpace(stdout.String())
}

// q shell-single-quotes a value for safe interpolation into a command line.
func q(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// sqlLit quotes a value as a SQL string literal for SQL passed to psql -c. Use
// it for every value interpolated into psql-executed SQL (the TS sidecar
// interpolated some recovery-audit values unquoted, see ADR 0001).
func sqlLit(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "''") + "'"
}
