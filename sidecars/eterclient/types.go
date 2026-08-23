// Package eterclient is the shared Go engine client: the transport-agnostic
// EterClient surface, the DirectClient two-pool implementation (tenant +
// metadata store), and the undo plan/result shapes the engine returns. It is
// the single Go implementation behind both the eter CLI's direct mode and the
// orchestrator's HTTP API (mirroring what @eterdb/core + the TS DirectClient
// used to be). Moved here from cli/internal/{core,client}, the CLI re-exports
// these types by alias, so its frozen surface is unchanged.
package eterclient

import (
	"fmt"
	"os"
	"path/filepath"
)

// UndoMode selects how dependent transactions are handled when reverting.
type UndoMode string

const (
	CleanOnly UndoMode = "clean_only"
	Cascade   UndoMode = "cascade"
	Targeted  UndoMode = "targeted"
)

// ExternalRef is a foreign key into an external system (Stripe charge, email,
// message id) found in the rows an undo would touch. Surfaced, never reversed.
type ExternalRef struct {
	Column string `json:"column"`
	Value  string `json:"value"`
	Kind   string `json:"kind"`
}

// ExternalRefs summarises the external references in the affected rows.
type ExternalRefs struct {
	Count   int            `json:"count"`
	Kinds   map[string]int `json:"kinds"`
	Samples []ExternalRef  `json:"samples"`
}

// ConflictEdge describes one later transaction that conflicts with the target.
type ConflictEdge struct {
	Txid          int64    `json:"txid"`
	Kinds         []string `json:"kinds"` // ww = later write to same rows; rw = later read of what target wrote (SSI)
	Precision     string   `json:"precision,omitempty"`
	RWGranularity *string  `json:"rw_granularity,omitempty"`
}

// PrecisionSummary is the observe-mode over-approximation surfaced to the user.
type PrecisionSummary struct {
	ExactDependents      int      `json:"exact_dependents"`
	OverApproxDependents int      `json:"over_approx_dependents"`
	CoarseTables         []string `json:"coarse_tables"`
}

// UndoPlan is the classification + plan returned by eter.preview_undo(txid).
type UndoPlan struct {
	Txid            int64            `json:"txid"`
	Classification  string           `json:"classification"`
	OpCount         int              `json:"op_count"`
	Conflicts       []int64          `json:"conflicts"`
	ConflictEdges   []ConflictEdge   `json:"conflict_edges"`
	Precision       PrecisionSummary `json:"precision"`
	ExternalRefs    ExternalRefs     `json:"external_refs"`
	DependencyBasis string           `json:"dependency_basis"`
}

// FindRepoFile locates a repo-relative file (e.g. ext/eter/eter.sql).
// Honours an explicit env override, otherwise walks up from the working
// directory and then the executable directory looking for the file. This keeps
// a binary usable from anywhere inside the repo without an install step.
func FindRepoFile(rel, envOverride string) (string, error) {
	if envOverride != "" {
		if v := os.Getenv(envOverride); v != "" {
			return v, nil
		}
	}
	var roots []string
	if wd, err := os.Getwd(); err == nil {
		roots = append(roots, wd)
	}
	if exe, err := os.Executable(); err == nil {
		roots = append(roots, filepath.Dir(exe))
	}
	for _, start := range roots {
		dir := start
		for {
			cand := filepath.Join(dir, rel)
			if _, err := os.Stat(cand); err == nil {
				return cand, nil
			}
			parent := filepath.Dir(dir)
			if parent == dir {
				break
			}
			dir = parent
		}
	}
	return "", fmt.Errorf("could not locate %s (set %s to override)", rel, envOverride)
}

// EterSQLFile is the path to the eter engine SQL applied by init.
func EterSQLFile() (string, error) {
	return FindRepoFile(filepath.Join("ext", "eter", "eter.sql"), "ETER_SQL_FILE")
}
