package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func testCfg(t *testing.T) orchConfig {
	t.Helper()
	wd, _ := os.Getwd()
	dir := t.TempDir()
	return orchConfig{
		databaseURL: "postgres://fake/fake",
		metaURL:     "postgres://fake/fake",
		storageBin:  filepath.Join(wd, "testdata", "fake-storage.sh"),
		backupDir:   dir,
		restoreDir:  filepath.Join(dir, ".restore"),
		tmpPortBase: 5599,
	}
}

func startRunner(t *testing.T, cfg orchConfig, store jobStore) (*runner, context.CancelFunc) {
	t.Helper()
	r := newRunner(cfg, store)
	ctx, cancel := context.WithCancel(context.Background())
	go r.loop(ctx)
	return r, cancel
}

func TestJobSucceeds(t *testing.T) {
	store := newMemStore()
	r, stop := startRunner(t, testCfg(t), store)
	defer stop()
	id, _ := store.Submit(context.Background(), "recover-table", map[string]any{"table": "public.w"})
	r.poke()
	if err := store.waitState(id, "succeeded", 5*time.Second); err != nil {
		t.Fatal(err)
	}
	j, _ := store.Get(context.Background(), id)
	if j.Output == nil || j.Output["snapshot"] != "base-fake" {
		t.Fatalf("structured output not captured: %+v", j.Output)
	}
	if len(r.jobEvents(id)) == 0 {
		t.Fatal("no structured stderr events captured")
	}
}

func TestJobFailureCapturesStderr(t *testing.T) {
	t.Setenv("FAKE_FAIL", "1")
	store := newMemStore()
	r, stop := startRunner(t, testCfg(t), store)
	defer stop()
	id, _ := store.Submit(context.Background(), "snapshot", nil)
	r.poke()
	if err := store.waitState(id, "failed", 5*time.Second); err != nil {
		t.Fatal(err)
	}
	j, _ := store.Get(context.Background(), id)
	if !strings.Contains(j.Error, "boom: simulated failure") {
		t.Fatalf("stderr tail not surfaced in error: %q", j.Error)
	}
}

func TestSingleFlightSerializes(t *testing.T) {
	t.Setenv("FAKE_SLEEP", "1")
	store := newMemStore()
	r, stop := startRunner(t, testCfg(t), store)
	defer stop()
	id1, _ := store.Submit(context.Background(), "snapshot", nil)
	id2, _ := store.Submit(context.Background(), "snapshot", nil)
	r.poke()
	// While job 1 runs (1s sleep), job 2 must still be queued.
	if err := store.waitState(id1, "running", 3*time.Second); err != nil {
		t.Fatal(err)
	}
	if j2, _ := store.Get(context.Background(), id2); j2.State != "queued" {
		t.Fatalf("second job should be queued while first runs, got %s", j2.State)
	}
	if err := store.waitState(id2, "succeeded", 10*time.Second); err != nil {
		t.Fatal(err)
	}
}

func TestCancelQueued(t *testing.T) {
	store := newMemStore()
	cfg := testCfg(t)
	r := newRunner(cfg, store) // runner NOT started, job stays queued
	id, _ := store.Submit(context.Background(), "snapshot", nil)
	ok, err := r.cancel(context.Background(), id)
	if err != nil || !ok {
		t.Fatalf("cancel of a queued job should succeed (ok=%v err=%v)", ok, err)
	}
	j, _ := store.Get(context.Background(), id)
	if j.State != "canceled" {
		t.Fatalf("state = %s, want canceled", j.State)
	}
}

func TestCancelRunning(t *testing.T) {
	t.Setenv("FAKE_SLEEP", "30")
	store := newMemStore()
	r, stop := startRunner(t, testCfg(t), store)
	defer stop()
	id, _ := store.Submit(context.Background(), "snapshot", nil)
	r.poke()
	if err := store.waitState(id, "running", 3*time.Second); err != nil {
		t.Fatal(err)
	}
	ok, err := r.cancel(context.Background(), id)
	if err != nil || !ok {
		t.Fatalf("cancel of a running job should signal it (ok=%v err=%v)", ok, err)
	}
	if err := store.waitState(id, "canceled", 15*time.Second); err != nil {
		t.Fatal(err)
	}
}

func TestBootOrphanRecovery(t *testing.T) {
	store := newMemStore()
	cfg := testCfg(t)
	// Simulate a job left running by a crashed instance + its restore debris.
	id, _ := store.Submit(context.Background(), "recover-table", map[string]any{"table": "t"})
	_, _ = store.MarkRunning(context.Background(), id, "dead-instance")
	orphanDir := filepath.Join(cfg.restoreDir, "job-999")
	// A manually-run sidecar recovery may be legitimately IN FLIGHT while the
	// orchestrator (re)boots, its rec_*/asof_* dirs must be left alone.
	manualRec := filepath.Join(cfg.restoreDir, "rec_manual1")
	manualAsof := filepath.Join(cfg.restoreDir, "asof_manual1")
	for _, d := range []string{orphanDir, manualRec, manualAsof} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	bootRecover(context.Background(), cfg, store)
	j, _ := store.Get(context.Background(), id)
	if j.State != "failed" {
		t.Fatalf("orphan not failed at boot: %s", j.State)
	}
	if _, err := os.Stat(orphanDir); !os.IsNotExist(err) {
		t.Fatalf("orphan restore dir not swept: %v", err)
	}
	for _, d := range []string{manualRec, manualAsof} {
		if _, err := os.Stat(d); err != nil {
			t.Fatalf("manual sidecar restore dir %s must NOT be swept at boot: %v", d, err)
		}
	}
}

// The scheduler's cycle and the runner's jobs share ONE lane: a job submitted
// while a cycle runs must wait for it (never overlap), and a cycle ticked
// while a job runs must skip immediately.
func TestCycleAndJobShareTheLane(t *testing.T) {
	t.Setenv("FAKE_SLEEP", "1")
	store := newMemStore()
	r, stop := startRunner(t, testCfg(t), store)
	defer stop()
	cycleDone := make(chan struct{})
	go func() { r.runCycle(context.Background()); close(cycleDone) }()
	time.Sleep(200 * time.Millisecond) // let the (slow) cycle take the lane
	id, _ := store.Submit(context.Background(), "snapshot", nil)
	r.poke()
	time.Sleep(300 * time.Millisecond)
	if j, _ := store.Get(context.Background(), id); j.State != "queued" {
		t.Fatalf("job should wait for the cycle to release the lane, got %s", j.State)
	}
	<-cycleDone
	if err := store.waitState(id, "succeeded", 10*time.Second); err != nil {
		t.Fatal(err)
	}
}

func TestCycleSkipsWhileJobRuns(t *testing.T) {
	t.Setenv("FAKE_SLEEP", "2")
	store := newMemStore()
	r, stop := startRunner(t, testCfg(t), store)
	defer stop()
	id, _ := store.Submit(context.Background(), "snapshot", nil)
	r.poke()
	if err := store.waitState(id, "running", 3*time.Second); err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	r.runCycle(context.Background())
	if d := time.Since(start); d > 500*time.Millisecond {
		t.Fatalf("runCycle should skip instantly while a job holds the lane (took %v)", d)
	}
}

func TestJobTimeoutFailsJob(t *testing.T) {
	t.Setenv("FAKE_SLEEP", "30")
	cfg := testCfg(t)
	cfg.jobTimeoutSec = 1
	store := newMemStore()
	r, stop := startRunner(t, cfg, store)
	defer stop()
	id, _ := store.Submit(context.Background(), "snapshot", nil)
	r.poke()
	if err := store.waitState(id, "failed", 20*time.Second); err != nil {
		t.Fatal(err)
	}
	j, _ := store.Get(context.Background(), id)
	if !strings.Contains(j.Error, "timed out") {
		t.Fatalf("timeout not surfaced as the failure reason: %q", j.Error)
	}
}

// events must stay bounded on a long-lived orchestrator: one ring per job,
// oldest job evicted past maxEventJobs.
func TestEventRingsBounded(t *testing.T) {
	r := newRunner(testCfg(t), newMemStore())
	for id := int64(1); id <= maxEventJobs+10; id++ {
		r.recordEvent(id, map[string]any{"msg": "x"})
	}
	if len(r.events) != maxEventJobs {
		t.Fatalf("events map should be capped at %d jobs, has %d", maxEventJobs, len(r.events))
	}
	if len(r.jobEvents(1)) != 0 {
		t.Fatal("oldest job's events should have been evicted")
	}
	if len(r.jobEvents(maxEventJobs+10)) != 1 {
		t.Fatal("newest job's events should be present")
	}
}

// The eter.jobs DDL ships in two places by design (ext/eter/eter.sql
// for `eter init`, jobsDDL for orchestrator boot against an older store); this
// guard fails the build if they drift.
func TestJobsDDLMatchesEngineSQL(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("..", "..", "ext", "eter", "eter.sql"))
	if err != nil {
		t.Fatalf("engine SQL not readable: %v", err)
	}
	sql := string(b)
	start := strings.Index(sql, "CREATE TABLE IF NOT EXISTS eter.jobs")
	if start < 0 {
		t.Fatal("eter.jobs DDL missing from the engine SQL")
	}
	const endMark = "WHERE state IN ('queued','running');"
	end := strings.Index(sql[start:], endMark)
	if end < 0 {
		t.Fatal("jobs_active_idx DDL missing from the engine SQL")
	}
	engine := sql[start : start+end+len(endMark)]
	if normalizeSQL(engine) != normalizeSQL(jobsDDL) {
		t.Fatalf("eter.jobs DDL drifted between ext/eter/eter.sql and jobs.go:\n engine: %s\n orch:   %s",
			normalizeSQL(engine), normalizeSQL(jobsDDL))
	}
}

// normalizeSQL strips -- comments and collapses whitespace so the drift guard
// compares structure, not formatting.
func normalizeSQL(s string) string {
	lines := strings.Split(s, "\n")
	for i, ln := range lines {
		if j := strings.Index(ln, "--"); j >= 0 {
			lines[i] = ln[:j]
		}
	}
	return strings.Join(strings.Fields(strings.Join(lines, " ")), " ")
}

func TestArgvValidation(t *testing.T) {
	cases := []struct {
		kind string
		args map[string]any
		ok   bool
	}{
		{"snapshot", nil, true},
		{"snapshot", map[string]any{"label": "pre-migration"}, true},
		{"recover-table", map[string]any{"table": "public.w"}, true},
		{"recover-table", map[string]any{}, false},
		{"recover-column", map[string]any{"table": "t", "column": "c"}, true},
		{"recover-column", map[string]any{"table": "t"}, false},
		{"as-of", map[string]any{"at": "2026-07-09", "sql": "SELECT 1"}, true},
		{"as-of", map[string]any{"at": "2026-07-09"}, false},
		{"nonsense", nil, false},
	}
	for _, c := range cases {
		_, err := argv(c.kind, c.args)
		if (err == nil) != c.ok {
			t.Errorf("argv(%s, %v): err=%v, want ok=%v", c.kind, c.args, err, c.ok)
		}
	}
}
