package cmd

import (
	"encoding/json"
	"strconv"
	"strings"

	"github.com/eterdb/eterdb/cli/internal/core"
)

func upper(s string) string { return strings.ToUpper(s) }

func contains(xs []string, want string) bool {
	for _, x := range xs {
		if x == want {
			return true
		}
	}
	return false
}

func joinInts(xs []int64) string {
	parts := make([]string, len(xs))
	for i, x := range xs {
		parts[i] = strconv.FormatInt(x, 10)
	}
	return strings.Join(parts, ", ")
}

func joinStrs(xs []string) string { return strings.Join(xs, ", ") }

// planToMap re-marshals an UndoPlan into a generic map so the undo dry-run can
// spread its fields alongside dry_run/mode, matching the TS `{...plan}` emit.
func planToMap(plan *core.UndoPlan) map[string]any {
	b, _ := json.Marshal(plan)
	var m map[string]any
	_ = json.Unmarshal(b, &m)
	return m
}

// numField reads a numeric field from a decoded JSON map (values are float64).
// txidList formats a txid array field (e.g. skipped_txids) as integer strings. The
// value is []int64 from the direct client, or a []any of numbers after a JSON round-trip.
func txidList(m map[string]any, key string) []string {
	switch arr := m[key].(type) {
	case []int64:
		out := make([]string, len(arr))
		for i, x := range arr {
			out[i] = strconv.FormatInt(x, 10)
		}
		return out
	case []int:
		out := make([]string, len(arr))
		for i, x := range arr {
			out[i] = strconv.Itoa(x)
		}
		return out
	case []any:
		out := make([]string, 0, len(arr))
		for _, e := range arr {
			switch x := e.(type) {
			case float64:
				out = append(out, strconv.FormatInt(int64(x), 10))
			case int64:
				out = append(out, strconv.FormatInt(x, 10))
			case string:
				out = append(out, x)
			}
		}
		return out
	}
	return nil
}

func numField(m map[string]any, key string) float64 {
	switch x := m[key].(type) {
	case float64:
		return x
	case int64:
		return float64(x)
	case int:
		return float64(x)
	case string:
		f, _ := strconv.ParseFloat(x, 64)
		return f
	}
	return 0
}
