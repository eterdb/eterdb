// Logical decoding does not carry the originating SQL text, so the trigger
// oracle's query-shape fingerprint (from current_query()) is unavailable. We
// synthesize a STRUCTURAL fingerprint instead, (op, table, changed columns),
// which is a legitimate statement-shape proxy: a batch of writes from the same
// statement touches the same table with the same op and (for UPDATEs) the same
// set of changed columns. This supports cohort-by-shape selection. It is NOT
// byte-comparable to the trigger's SQL-text fingerprint (see test/capture-diff.sh,
// which compares fingerprints by equivalence-class, not literal hash).
package main

import (
	"crypto/md5" //nolint:gosec // non-cryptographic structural fingerprint (see below), not a security primitive
	"encoding/hex"
	"sort"
	"strings"
)

func structuralFingerprint(table, op string, changedCols []string) string {
	cols := append([]string(nil), changedCols...)
	sort.Strings(cols)
	shape := op + "|" + table + "|" + strings.Join(cols, ",")
	sum := md5.Sum([]byte(shape)) //nolint:gosec // structural identity hash for cohort-by-shape, not security
	return hex.EncodeToString(sum[:])
}

func statementSample(table, op string, changedCols []string) string {
	verb := "UPDATE"
	switch op {
	case "I":
		verb = "INSERT"
	case "D":
		verb = "DELETE"
	}
	cols := append([]string(nil), changedCols...)
	sort.Strings(cols)
	suffix := ""
	if len(cols) > 0 {
		suffix = " {" + strings.Join(cols, ", ") + "}"
	}
	return verb + " " + table + suffix + " [captured via logical decoding]"
}
