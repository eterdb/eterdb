// Package client provides the transport surface the eter commands drive. Both
// the direct (CLI -> Postgres) and hosted (CLI -> orchestrator) transports
// implement EterClient, so commands stay transport-agnostic. The interface and
// the direct implementation are in the shared sidecars/eterclient package
// (also used by the orchestrator's HTTP handlers); this package aliases them
// and adds the CLI-only hosted transport.
package client

import (
	"context"

	"github.com/eterdb/eterdb/sidecars/eterclient"
)

// CohortSelector picks a cohort of writes by time × table × statement-shape ×
// predicate. A nil/zero field means "unconstrained on that dimension".
type CohortSelector = eterclient.CohortSelector

// LogOptions filters the change log.
type LogOptions = eterclient.LogOptions

// EterClient is the shared surface. Both transports expose the same methods so
// commands never branch on which one is active.
type EterClient = eterclient.EterClient

// DirectClient talks straight to Postgres (tenant + metadata store pools).
type DirectClient = eterclient.DirectClient

// NewDirectClient connects the tenant and (possibly separate) metadata pools.
func NewDirectClient(ctx context.Context, connectionString string) (*DirectClient, error) {
	return eterclient.NewDirectClient(ctx, connectionString)
}

// MetaURL resolves the DSN of the durable metadata store: ETER_META_URL, else
// the tenant DSN, else DATABASE_URL.
func MetaURL(tenantURL string) string { return eterclient.MetaURL(tenantURL) }
