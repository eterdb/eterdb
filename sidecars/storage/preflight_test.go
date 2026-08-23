package main

import "testing"

func TestArchiveStatus(t *testing.T) {
	cases := []struct {
		name        string
		archiveMode string
		walLevel    string
		walArchive  bool
		wantLevel   string
	}{
		{"archive dir unset warns (snapshot-only)", "off", "replica", false, "warn"},
		{"archive dir unset warns even if archiving on", "on", "replica", false, "warn"},
		{"archive set but archive_mode off errors", "off", "replica", true, "error"},
		{"archive set but wal_level minimal errors", "on", "minimal", true, "error"},
		{"archive set + archiving on + replica is ok", "on", "replica", true, "ok"},
		{"archive set + archiving on + logical is ok", "on", "logical", true, "ok"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			level, msg := archiveStatus(c.archiveMode, c.walLevel, c.walArchive)
			if level != c.wantLevel {
				t.Errorf("archiveStatus(%q,%q,%v) level = %q, want %q", c.archiveMode, c.walLevel, c.walArchive, level, c.wantLevel)
			}
			if (level == "ok") != (msg == "") {
				t.Errorf("level %q should have %s message, got %q", level, map[bool]string{true: "no", false: "a"}[level == "ok"], msg)
			}
		})
	}
}
