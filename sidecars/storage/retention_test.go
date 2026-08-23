package main

import (
	"testing"
	"time"
)

func mkBackups(now time.Time, agesDays ...int) []catalogBackup {
	var out []catalogBackup
	for i, age := range agesDays {
		out = append(out, catalogBackup{
			id:        int64(i + 1),
			name:      "base-" + string(rune('a'+i)),
			walStart:  "000000010000000000000" + string(rune('1'+i)) + "00",
			createdAt: now.Add(-time.Duration(age) * 24 * time.Hour),
		})
	}
	return out
}

func names(bs []catalogBackup) []string {
	var out []string
	for _, b := range bs {
		out = append(out, b.name)
	}
	return out
}

func eq(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// Default (both knobs off): nothing is ever pruned.
func TestSelectPrunableDefaultKeepsAll(t *testing.T) {
	now := time.Now()
	backups := mkBackups(now, 90, 60, 30, 1)
	prune, oldest := selectPrunable(backups, 0, 0, now)
	if len(prune) != 0 {
		t.Fatalf("default policy pruned %v, want none", names(prune))
	}
	if oldest != backups[0].walStart {
		t.Fatalf("oldest kept walStart = %q, want %q", oldest, backups[0].walStart)
	}
}

// retainCount keeps the oldest (the horizon anchor) + the N newest.
func TestSelectPrunableRetainCount(t *testing.T) {
	now := time.Now()
	backups := mkBackups(now, 90, 60, 30, 10, 1)
	prune, oldest := selectPrunable(backups, 2, 0, now)
	if !eq(names(prune), []string{"base-b", "base-c"}) {
		t.Fatalf("retain-count pruned %v, want [base-b base-c]", names(prune))
	}
	if oldest != backups[0].walStart {
		t.Fatalf("retain-count must keep the oldest backup's WAL floor, got %q", oldest)
	}
}

func TestSelectPrunableRetainCountNoExcess(t *testing.T) {
	now := time.Now()
	backups := mkBackups(now, 30, 1)
	prune, _ := selectPrunable(backups, 2, 0, now)
	if len(prune) != 0 {
		t.Fatalf("retain-count pruned %v with nothing in excess", names(prune))
	}
}

// horizonDays prunes the oldest only while the NEXT backup still anchors the
// horizon, at least one backup at-or-before now()-D always remains.
func TestSelectPrunableHorizon(t *testing.T) {
	now := time.Now()
	backups := mkBackups(now, 90, 60, 30, 1)
	prune, oldest := selectPrunable(backups, 0, 45, now)
	// base-a (90d) prunable because base-b (60d) still anchors the 45d horizon;
	// base-b must stay (base-c at 30d is INSIDE the horizon and can't anchor it).
	if !eq(names(prune), []string{"base-a"}) {
		t.Fatalf("horizon pruned %v, want [base-a]", names(prune))
	}
	if oldest != backups[1].walStart {
		t.Fatalf("WAL floor should move to base-b's walStart, got %q", oldest)
	}
}

func TestSelectPrunableHorizonKeepsSoleAnchor(t *testing.T) {
	now := time.Now()
	backups := mkBackups(now, 90, 30)
	prune, _ := selectPrunable(backups, 0, 45, now)
	if len(prune) != 0 {
		t.Fatalf("horizon pruned the only backup anchoring it: %v", names(prune))
	}
}

// Both knobs combined: horizon trims the tail, retain-count trims the middle.
func TestSelectPrunableCombined(t *testing.T) {
	now := time.Now()
	backups := mkBackups(now, 90, 80, 20, 10, 5, 1)
	prune, oldest := selectPrunable(backups, 1, 45, now)
	// Horizon(45): base-a prunable (base-b at 80d still anchors); base-b stays.
	// RetainCount(1) on [b,c,d,e,f]: keep b (anchor) + f (newest) → prune c,d,e.
	if !eq(names(prune), []string{"base-a", "base-c", "base-d", "base-e"}) {
		t.Fatalf("combined pruned %v, want [base-a base-c base-d base-e]", names(prune))
	}
	if oldest != backups[1].walStart {
		t.Fatalf("WAL floor should be base-b's walStart, got %q", oldest)
	}
}

func TestSelectPrunableEmpty(t *testing.T) {
	prune, oldest := selectPrunable(nil, 3, 30, time.Now())
	if len(prune) != 0 || oldest != "" {
		t.Fatalf("empty catalog: got prune=%v oldest=%q", names(prune), oldest)
	}
}
