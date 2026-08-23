package eterclient

import (
	"context"
	"fmt"
	"os"
	"strings"

	"github.com/jackc/pgx/v5"
)

// CohortSelector picks a cohort of writes by time × table × statement-shape ×
// predicate. A nil/zero field means "unconstrained on that dimension".
type CohortSelector struct {
	Table       string
	Fingerprint string
	From        string
	To          string
	Predicate   map[string]any
}

// LogOptions filters the change log.
type LogOptions struct {
	Table       string
	Since       string
	Limit       int
	IncludeUndo bool
}

// EterClient is the shared surface. Every transport (direct SQL, hosted HTTP)
// and every consumer (CLI commands, orchestrator HTTP handlers) programs
// against it, so none of them branch on which implementation is active.
type EterClient interface {
	Init(ctx context.Context) (map[string]any, error)
	// InitCapture turns on auto-track + DDL logging and tracks everything
	// trackable now (best-effort). Direct mode does the work; hosted mode
	// no-ops because the control plane owns capture setup.
	InitCapture(ctx context.Context, autoTrack bool) (map[string]any, error)
	Track(ctx context.Context, table string) error
	TrackAll(ctx context.Context) (int, error)
	Log(ctx context.Context, opts LogOptions) ([]map[string]any, error)
	Show(ctx context.Context, txid int64) ([]map[string]any, error)
	Preview(ctx context.Context, txid int64) (*UndoPlan, error)
	Undo(ctx context.Context, txid int64, mode UndoMode) (map[string]any, error)
	PreviewCohort(ctx context.Context, sel CohortSelector) (map[string]any, error)
	UndoCohort(ctx context.Context, sel CohortSelector, mode UndoMode) (map[string]any, error)
	Mark(ctx context.Context, label string) (int64, error)
	Markers(ctx context.Context) ([]map[string]any, error)
	Status(ctx context.Context) (map[string]any, error)
	Close()
}

// MetaURL resolves the DSN of the durable metadata store for LOCAL / dev-tool
// callers (the CLI's direct client): ETER_META_URL, else the tenant DSN, else
// DATABASE_URL. When it equals the tenant DSN the store IS the tenant DB, the
// zero-infra single-DB dev/demo shape. Deployment runtimes (the sidecars +
// orchestrator) must instead call RequireMetaURL, which enforces issue #67: a
// separate store is mandatory unless single-DB is explicitly acknowledged.
func MetaURL(tenantURL string) string {
	if v := os.Getenv("ETER_META_URL"); v != "" {
		return v
	}
	if tenantURL != "" {
		return tenantURL
	}
	return os.Getenv("DATABASE_URL")
}

// allowSingleDB reports whether the operator explicitly acknowledged the
// single-DB dev/demo shape (durable metadata co-located in the tenant) via
// ETER_ALLOW_SINGLE_DB.
func allowSingleDB() bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv("ETER_ALLOW_SINGLE_DB"))) {
	case "1", "true", "yes", "on":
		return true
	}
	return false
}

// RequireMetaURL resolves the durable-metadata DSN for a DEPLOYMENT runtime (the
// capture/storage sidecars and the orchestrator). Per issue #67 the store must
// be a SEPARATE database from the tenant so durable history and the backup
// catalog survive the tenant having a very bad day:
//
//   - ETER_META_URL set to a database distinct from the tenant → use it
//     (separate = true).
//   - ETER_META_URL unset, or pointing back at the tenant database → a hard
//     error, UNLESS ETER_ALLOW_SINGLE_DB is set to acknowledge the dev/demo
//     shape, in which case the tenant DSN is returned (separate = false).
//
// The tenant/store comparison is by resolved host:port/database, not raw DSN
// text, so an ETER_META_URL that merely re-spells the tenant DSN is still caught.
func RequireMetaURL(tenantURL string) (metaURL string, separate bool, err error) {
	meta := strings.TrimSpace(os.Getenv("ETER_META_URL"))
	if meta == "" {
		if allowSingleDB() {
			return tenantURL, false, nil
		}
		return "", false, fmt.Errorf("ETER_META_URL is required: point it at a separate " +
			"EterDB-owned Postgres so durable history and the backup catalog survive tenant loss. " +
			"For a single-DB dev/demo where the store IS the tenant, set ETER_ALLOW_SINGLE_DB=1")
	}
	if sameDatabase(meta, tenantURL) {
		if allowSingleDB() {
			return meta, false, nil
		}
		return "", false, fmt.Errorf("ETER_META_URL points at the tenant database, it must be a " +
			"SEPARATE database so durable metadata survives tenant loss. " +
			"For a single-DB dev/demo, set ETER_ALLOW_SINGLE_DB=1")
	}
	return meta, true, nil
}

// sameDatabase reports whether two DSNs resolve to the same host:port/database.
// It compares parsed endpoints rather than raw strings so cosmetically different
// DSNs that name the same database are still recognized as co-located; on a
// parse failure it falls back to string equality.
func sameDatabase(a, b string) bool {
	ca, ea := pgx.ParseConfig(a)
	cb, eb := pgx.ParseConfig(b)
	if ea != nil || eb != nil {
		return a == b
	}
	return strings.EqualFold(ca.Host, cb.Host) && ca.Port == cb.Port && ca.Database == cb.Database
}
