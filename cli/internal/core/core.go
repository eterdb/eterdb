// Package core holds the CLI-side shared surface: the stable process exit
// codes, plus aliases to the engine types that moved to the shared
// sidecars/eterclient package (one Go implementation now feeds the CLI's
// direct mode and the orchestrator). The CLI surface this backs is a frozen
// interface, the aliases keep every existing import site compiling unchanged.
package core

import (
	"path/filepath"

	"github.com/eterdb/eterdb/cli/internal/assets"
	"github.com/eterdb/eterdb/sidecars/eterclient"
)

// UndoMode selects how dependent transactions are handled when reverting.
type UndoMode = eterclient.UndoMode

const (
	CleanOnly = eterclient.CleanOnly
	Cascade   = eterclient.Cascade
	Targeted  = eterclient.Targeted
)

// Stable process exit codes so agents can branch on outcome.
const (
	ExitOK          = 0
	ExitUsage       = 2
	ExitNotFound    = 3
	ExitDependent   = 4 // undo refused: dependent transactions exist (needs cascade/targeted)
	ExitDB          = 5
	ExitConfig      = 6
	ExitPrereq      = 7 // refused: a prerequisite is missing (e.g. no capture sidecar for track)
	ExitInterrupted = 130 // SIGINT/SIGTERM: clean shutdown (128 + signal number)
)

// Engine result shapes (see sidecars/eterclient/types.go).
type (
	ExternalRef      = eterclient.ExternalRef
	ExternalRefs     = eterclient.ExternalRefs
	ConflictEdge     = eterclient.ConflictEdge
	PrecisionSummary = eterclient.PrecisionSummary
	UndoPlan         = eterclient.UndoPlan
)

// FindRepoFile locates a repo-relative file (e.g. ext/eter/eter.sql).
func FindRepoFile(rel, envOverride string) (string, error) {
	return eterclient.FindRepoFile(rel, envOverride)
}

// EterSQLFile is the path to the eter engine SQL applied by `eter init`. Resolution
// is env override (ETER_SQL_FILE) -> repo walk -> the embedded copy materialized to
// the user cache dir, so an installed binary run outside the repo still works.
func EterSQLFile() (string, error) {
	if p, err := eterclient.EterSQLFile(); err == nil {
		return p, nil
	}
	return assets.MaterializeEterSQL()
}

// DemoSchemaFile is the path to the e-commerce demo schema (CLI-only). Same
// resolution chain as EterSQLFile (env override ETER_DEMO_SCHEMA -> repo -> embedded).
func DemoSchemaFile() (string, error) {
	if p, err := FindRepoFile(filepath.Join("demo", "schema.sql"), "ETER_DEMO_SCHEMA"); err == nil {
		return p, nil
	}
	return assets.MaterializeDemoSchema()
}
