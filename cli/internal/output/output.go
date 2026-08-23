// Package output centralises CLI rendering. Every command supports --json for
// agent/script consumption; in human mode it prints a compact fixed-width table
// and writes prose hints to stderr (keeping stdout clean for piping).
package output

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"
)

var jsonMode bool

// SetJSON toggles machine-readable output for the whole process.
func SetJSON(on bool) { jsonMode = on }

// IsJSON reports whether JSON output is active.
func IsJSON() bool { return jsonMode }

// Emit prints data as indented JSON in --json mode, otherwise runs humanRender.
func Emit(data any, humanRender func()) {
	if jsonMode {
		b, _ := json.MarshalIndent(data, "", "  ")
		fmt.Fprintln(os.Stdout, string(b))
		return
	}
	if humanRender != nil {
		humanRender()
	}
}

// Info writes a prose line to stderr, suppressed in --json mode.
func Info(format string, args ...any) {
	if !jsonMode {
		fmt.Fprintf(os.Stderr, format+"\n", args...)
	}
}

// Fmt renders a scalar/JSON value for table cells the way the TS CLI does.
func Fmt(v any) string {
	if v == nil {
		return ""
	}
	switch x := v.(type) {
	case string:
		return x
	case time.Time:
		return x.UTC().Format("2006-01-02 15:04:05Z")
	case []byte:
		return string(x)
	case fmt.Stringer:
		return x.String()
	case float64, float32, int, int32, int64, bool:
		return fmt.Sprintf("%v", x)
	default:
		b, err := json.Marshal(x)
		if err != nil {
			return fmt.Sprintf("%v", x)
		}
		return string(b)
	}
}

// Table prints a minimal fixed-width table for the given columns.
func Table(rows []map[string]any, columns []string) {
	if len(rows) == 0 {
		fmt.Fprintln(os.Stdout, "(no rows)")
		return
	}
	widths := make([]int, len(columns))
	for i, c := range columns {
		widths[i] = len(c)
	}
	for _, r := range rows {
		for i, c := range columns {
			if w := len(Fmt(r[c])); w > widths[i] {
				widths[i] = w
			}
		}
	}
	line := func(cells []string) string {
		padded := make([]string, len(cells))
		for i, c := range cells {
			padded[i] = c + strings.Repeat(" ", widths[i]-len(c))
		}
		return strings.Join(padded, "  ")
	}
	fmt.Fprintln(os.Stdout, line(columns))
	dashes := make([]string, len(columns))
	for i, w := range widths {
		dashes[i] = strings.Repeat("-", w)
	}
	fmt.Fprintln(os.Stdout, strings.Join(dashes, "  "))
	for _, r := range rows {
		cells := make([]string, len(columns))
		for i, c := range columns {
			cells[i] = Fmt(r[c])
		}
		fmt.Fprintln(os.Stdout, line(cells))
	}
}
