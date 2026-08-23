package main

import (
	"strings"
	"testing"
)

// PK-dependent recoveries (recover-rows dedupe, recover-column row matching)
// must fail early with an actionable message on a PK-less table, not surface a
// Postgres syntax error from an empty column list (`ON CONFLICT () DO NOTHING`).
func TestRequirePKPanicsOnPKlessTable(t *testing.T) {
	defer func() {
		r := recover()
		if r == nil {
			t.Fatal("requirePK should panic for a table with no primary key")
		}
		msg := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(toString(r)), "storage:"))
		if !strings.Contains(msg, "public.nopk") || !strings.Contains(msg, "no primary key") {
			t.Fatalf("panic message not actionable: %v", r)
		}
	}()
	requirePK(nil, "public.nopk", "restore rows without clobbering post-truncate writes (dedupe is by PK)")
}

func TestRequirePKPassesWithPK(t *testing.T) {
	requirePK([]col{{name: "id", typ: "integer"}}, "public.t", "match rows")
}

func toString(v any) string {
	if err, ok := v.(error); ok {
		return err.Error()
	}
	if s, ok := v.(string); ok {
		return s
	}
	return ""
}
