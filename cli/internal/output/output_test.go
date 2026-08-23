package output

import (
	"testing"
	"time"
)

func TestFmt(t *testing.T) {
	cases := []struct {
		in   any
		want string
	}{
		{nil, ""},
		{"hello", "hello"},
		{int64(42), "42"},
		{true, "true"},
		{map[string]any{"id": float64(1)}, `{"id":1}`},
		{time.Date(2026, 6, 23, 14, 0, 0, 0, time.UTC), "2026-06-23 14:00:00Z"},
	}
	for _, c := range cases {
		if got := Fmt(c.in); got != c.want {
			t.Errorf("Fmt(%v) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestSetJSON(t *testing.T) {
	t.Cleanup(func() { SetJSON(false) })
	SetJSON(true)
	if !IsJSON() {
		t.Fatal("expected JSON mode on")
	}
	SetJSON(false)
	if IsJSON() {
		t.Fatal("expected JSON mode off")
	}
}
