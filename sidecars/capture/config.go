// Capture-sidecar configuration. All values come from the environment so the
// sidecar is deployable beside any EterDB-managed Postgres.
package main

import (
	"fmt"
	"os"
	"strconv"
	"time"

	"github.com/eterdb/eterdb/sidecars/eterclient"
)

type captureConfig struct {
	// connectionString is the DSN of the tenant DB the sidecar decodes
	// (slot/publication/tracked are here).
	connectionString string
	// metaURL is the DSN of the metadata store that holds eter.history /
	// capture_state / undo_txn. Required (ETER_META_URL), a SEPARATE EterDB-owned
	// store keeps history off the tenant it decodes (PLAN.md "Externalize durable
	// metadata"); single-DB dev/demo must opt in via ETER_ALLOW_SINGLE_DB, in which
	// case it equals connectionString. The decode stream still comes from
	// connectionString.
	metaURL string
	// slot is the logical replication slot name (pgoutput plugin).
	slot string
	// publication whose member tables are decoded.
	publication string
	// reconcile is the backstop interval for reconciling publication membership
	// with eter.tracked, in case a NOTIFY is missed.
	reconcile time.Duration
	// forward is the interval for the two-DB read-set forwarder (drain SSI-WAL →
	// store → derive). Only runs when the metadata store is separate.
	forward time.Duration
}

func loadConfig() (captureConfig, error) {
	conn := os.Getenv("DATABASE_URL")
	if conn == "" {
		return captureConfig{}, fmt.Errorf("capture sidecar: DATABASE_URL is required")
	}
	// Durable history must not be in the tenant it decodes, ETER_META_URL is a
	// hard requirement (issue #67); single-DB dev/demo opts in via ETER_ALLOW_SINGLE_DB.
	meta, _, err := eterclient.RequireMetaURL(conn)
	if err != nil {
		return captureConfig{}, fmt.Errorf("capture sidecar: %w", err)
	}
	return captureConfig{
		connectionString: conn,
		metaURL:          meta,
		slot:             envOr("ETER_SLOT", "eter_slot"),
		publication:      envOr("ETER_PUBLICATION", "eter_pub"),
		reconcile:        time.Duration(envMs("ETER_RECONCILE_MS", 5000)) * time.Millisecond,
		forward:          time.Duration(envMs("ETER_FORWARD_MS", 1000)) * time.Millisecond,
	}, nil
}

func (c captureConfig) metaSeparate() bool { return c.metaURL != c.connectionString }

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func envMs(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}
