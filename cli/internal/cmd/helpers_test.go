package cmd

import (
	"errors"
	"testing"

	"github.com/eterdb/eterdb/cli/internal/core"
	"github.com/eterdb/eterdb/cli/internal/output"
)

func TestPickMode(t *testing.T) {
	output.SetJSON(false)
	if m, err := pickMode(false, false); err != nil || m != core.CleanOnly {
		t.Errorf("default = (%q,%v), want clean_only", m, err)
	}
	if m, err := pickMode(true, false); err != nil || m != core.Cascade {
		t.Errorf("cascade = (%q,%v)", m, err)
	}
	if m, err := pickMode(false, true); err != nil || m != core.Targeted {
		t.Errorf("targeted = (%q,%v)", m, err)
	}
	if _, err := pickMode(true, true); err == nil {
		t.Error("expected error for cascade+targeted")
	}
}

func TestParseTxid(t *testing.T) {
	output.SetJSON(false)
	if v, err := parseTxid("743"); err != nil || v != 743 {
		t.Errorf("parseTxid(743) = (%d,%v)", v, err)
	}
	if _, err := parseTxid("abc"); err == nil {
		t.Error("expected error for non-numeric txid")
	}
}

func TestMapErr(t *testing.T) {
	output.SetJSON(false)
	cases := []struct {
		msg  string
		want int
	}{
		{"dependent transactions exist", core.ExitDependent},
		{"no tracked writes found for txid 5", core.ExitNotFound},
		{"connection refused", core.ExitDB},
	}
	for _, c := range cases {
		err := mapErr(errString(c.msg))
		var ee *exitError
		if !asExit(err, &ee) || ee.code != c.want {
			t.Errorf("mapErr(%q) code = %v, want %d", c.msg, err, c.want)
		}
	}
}

type errString string

func (e errString) Error() string { return string(e) }

func asExit(err error, target **exitError) bool {
	ee := &exitError{}
	if errors.As(err, &ee) {
		*target = ee
		return true
	}
	return false
}
