package main

import "testing"

func TestShouldSnapshotWAL(t *testing.T) {
	const min = 16 * 1024 * 1024 // one WAL segment
	cases := []struct {
		name     string
		walBytes int64
		hasPrior bool
		want     bool
	}{
		{"no prior base always snapshots", 0, false, true},
		{"no prior base even with WAL", 999, false, true},
		{"idle interval below threshold skips", 0, true, false},
		{"light interval below threshold skips", min - 1, true, false},
		{"exactly at threshold snapshots", min, true, true},
		{"heavy interval above threshold snapshots", min * 4, true, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := shouldSnapshotWAL(c.walBytes, min, c.hasPrior); got != c.want {
				t.Errorf("shouldSnapshotWAL(%d, %d, %v) = %v, want %v", c.walBytes, min, c.hasPrior, got, c.want)
			}
		})
	}
}
