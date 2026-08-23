// Pure mapping: a decoded row change + its tracked-table metadata -> an
// eter.history row (minus is_undo/undo_of, which the store stamps from
// eter.undo_txn). Column values are raw Postgres text (pgoutput delivers tuple
// data in text format) so jsonb_populate_record reconstructs the exact original
// tuple, with no precision loss on timestamps/numerics.
package main

// row is a decoded tuple: column name -> text value (nil = SQL NULL). It maps to
// a JSON object on the way into eter.history.
type row map[string]*string

type rowChange struct {
	op     string // "I" | "U" | "D"
	before row    // OLD image (U/D); nil for I
	after  row    // NEW image (I/U); nil for D
}

type mappedRow struct {
	tableName       string
	op              string
	pk              row
	rowBefore       row
	rowAfter        row
	fingerprint     string
	statementSample string
}

func mapChange(name string, pkCols []string, change rowChange) mappedRow {
	identity := change.after
	if identity == nil {
		identity = change.before
	}
	pk := row{}
	for _, col := range pkCols {
		if identity != nil {
			pk[col] = identity[col]
		} else {
			pk[col] = nil
		}
	}

	var changedCols []string
	if change.op == "U" {
		changedCols = changedColumns(pkCols, change.before, change.after)
	}

	return mappedRow{
		tableName:       name,
		op:              change.op,
		pk:              pk,
		rowBefore:       change.before,
		rowAfter:        change.after,
		fingerprint:     structuralFingerprint(name, change.op, changedCols),
		statementSample: statementSample(name, change.op, changedCols),
	}
}

// changedColumns are the non-PK columns whose value changed between OLD and NEW
// (the UPDATE's shape).
func changedColumns(pkCols []string, before, after row) []string {
	if before == nil || after == nil {
		return nil
	}
	pk := make(map[string]struct{}, len(pkCols))
	for _, c := range pkCols {
		pk[c] = struct{}{}
	}
	var cols []string
	for k, av := range after {
		if _, isPK := pk[k]; isPK {
			continue
		}
		bv := before[k]
		if !strEq(bv, av) {
			cols = append(cols, k)
		}
	}
	return cols
}

func strEq(a, b *string) bool {
	if a == nil || b == nil {
		return a == b
	}
	return *a == *b
}
