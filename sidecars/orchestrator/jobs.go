// The job subsystem: a durable queue in the meta store (eter.jobs) + one
// serial runner lane that execs the eter-storage binary. Restores are
// full-copy + WAL-replay IO bursts, so single-flight is the correct load
// behavior, and it makes throwaway-port collisions impossible. The lane is
// a capacity-1 channel held by BOTH job execution and the scheduled
// maintenance cycle, so a scheduled backup can never overlap a running
// recovery (or vice versa). Per-job belt-and-braces anyway: each job gets
// its own ETER_RESTORE_DIR (<restore>/job-<id>, so a crash sweep is
// attributable) and a distinct ETER_TMP_PORT (guards against an
// operator-run manual sidecar).
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

func jsonMarshal(v any) ([]byte, error) { return json.Marshal(v) }

// Job is the wire shape of one queued/running/finished storage operation.
type Job struct {
	ID          int64          `json:"id"`
	Kind        string         `json:"kind"`
	Args        map[string]any `json:"args"`
	State       string         `json:"state"`
	SubmittedAt time.Time      `json:"submitted_at"`
	StartedAt   *time.Time     `json:"started_at,omitempty"`
	FinishedAt  *time.Time     `json:"finished_at,omitempty"`
	Output      map[string]any `json:"output,omitempty"`
	Error       string         `json:"error,omitempty"`
	Progress    map[string]any `json:"progress,omitempty"`
}

// jobStore is the persistence seam (pg-backed in production; in-memory fake in
// tests, keeping `go test ./...` hermetic).
type jobStore interface {
	Submit(ctx context.Context, kind string, args map[string]any) (int64, error)
	Get(ctx context.Context, id int64) (*Job, error)
	List(ctx context.Context, state, kind string, limit int) ([]Job, error)
	NextQueued(ctx context.Context) (*Job, error)
	MarkRunning(ctx context.Context, id int64, worker string) (bool, error)
	Heartbeat(ctx context.Context, id int64) error
	SetProgress(ctx context.Context, id int64, p map[string]any) error
	// Finish transitions running→state; false when the row was no longer
	// running (e.g. a cancel raced natural completion).
	Finish(ctx context.Context, id int64, state string, output map[string]any, errMsg string) (bool, error)
	CancelQueued(ctx context.Context, id int64) (bool, error)
	FailOrphans(ctx context.Context, reason string) (int, error)
}

// ---- pg-backed store (meta pool) -------------------------------------------

type pgJobStore struct{ pool *pgxpool.Pool }

// jobsDDL is the eter.jobs schema. The same DDL ships in
// ext/eter/eter.sql for `eter init`; TestJobsDDLMatchesEngineSQL
// fails the build if the two copies drift.
const jobsDDL = `
CREATE TABLE IF NOT EXISTS eter.jobs (
  id           bigserial PRIMARY KEY,
  kind         text        NOT NULL,
  args         jsonb       NOT NULL DEFAULT '{}'::jsonb,
  state        text        NOT NULL DEFAULT 'queued'
               CHECK (state IN ('queued','running','succeeded','failed','canceled')),
  submitted_at timestamptz NOT NULL DEFAULT now(),
  started_at   timestamptz,
  finished_at  timestamptz,
  output       jsonb,
  error        text,
  progress     jsonb,
  worker       text,
  lease_at     timestamptz
);
CREATE INDEX IF NOT EXISTS jobs_active_idx ON eter.jobs (state) WHERE state IN ('queued','running');`

// ensureSchema applies the eter.jobs DDL idempotently at boot so the
// orchestrator works against a store that predates the jobs table.
func (s *pgJobStore) ensureSchema(ctx context.Context) error {
	_, err := s.pool.Exec(ctx, "CREATE SCHEMA IF NOT EXISTS eter;\n"+jobsDDL)
	return err
}

const jobCols = `id, kind, args, state, submitted_at, started_at, finished_at, output, coalesce(error,'') AS error, progress`

func scanJob(row pgx.CollectableRow) (Job, error) {
	var j Job
	err := row.Scan(&j.ID, &j.Kind, &j.Args, &j.State, &j.SubmittedAt, &j.StartedAt, &j.FinishedAt, &j.Output, &j.Error, &j.Progress)
	return j, err
}

func (s *pgJobStore) Submit(ctx context.Context, kind string, args map[string]any) (int64, error) {
	b, err := json.Marshal(args)
	if err != nil {
		return 0, err
	}
	var id int64
	err = s.pool.QueryRow(ctx,
		"INSERT INTO eter.jobs (kind, args) VALUES ($1, $2::jsonb) RETURNING id", kind, string(b)).Scan(&id)
	return id, err
}

func (s *pgJobStore) Get(ctx context.Context, id int64) (*Job, error) {
	rows, err := s.pool.Query(ctx, "SELECT "+jobCols+" FROM eter.jobs WHERE id = $1", id)
	if err != nil {
		return nil, err
	}
	jobs, err := pgx.CollectRows(rows, scanJob)
	if err != nil || len(jobs) == 0 {
		return nil, err
	}
	return &jobs[0], nil
}

func (s *pgJobStore) List(ctx context.Context, state, kind string, limit int) ([]Job, error) {
	if limit <= 0 {
		limit = 50
	}
	var where []string
	var params []any
	if state != "" {
		params = append(params, state)
		where = append(where, fmt.Sprintf("state = $%d", len(params)))
	}
	if kind != "" {
		params = append(params, kind)
		where = append(where, fmt.Sprintf("kind = $%d", len(params)))
	}
	clause := ""
	if len(where) > 0 {
		clause = "WHERE " + strings.Join(where, " AND ")
	}
	params = append(params, limit)
	rows, err := s.pool.Query(ctx, fmt.Sprintf(
		"SELECT %s FROM eter.jobs %s ORDER BY id DESC LIMIT $%d", jobCols, clause, len(params)), params...)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, scanJob)
}

func (s *pgJobStore) NextQueued(ctx context.Context) (*Job, error) {
	rows, err := s.pool.Query(ctx,
		"SELECT "+jobCols+" FROM eter.jobs WHERE state = 'queued' ORDER BY id LIMIT 1")
	if err != nil {
		return nil, err
	}
	jobs, err := pgx.CollectRows(rows, scanJob)
	if err != nil || len(jobs) == 0 {
		return nil, err
	}
	return &jobs[0], nil
}

func (s *pgJobStore) MarkRunning(ctx context.Context, id int64, worker string) (bool, error) {
	tag, err := s.pool.Exec(ctx,
		`UPDATE eter.jobs SET state='running', started_at=now(), worker=$2, lease_at=now()
		  WHERE id=$1 AND state='queued'`, id, worker)
	return tag.RowsAffected() == 1, err
}

func (s *pgJobStore) Heartbeat(ctx context.Context, id int64) error {
	_, err := s.pool.Exec(ctx, "UPDATE eter.jobs SET lease_at=now() WHERE id=$1 AND state='running'", id)
	return err
}

func (s *pgJobStore) SetProgress(ctx context.Context, id int64, p map[string]any) error {
	b, err := json.Marshal(p)
	if err != nil {
		return err
	}
	_, err = s.pool.Exec(ctx,
		"UPDATE eter.jobs SET progress=$2::jsonb WHERE id=$1 AND state='running'", id, string(b))
	return err
}

func (s *pgJobStore) Finish(ctx context.Context, id int64, state string, output map[string]any, errMsg string) (bool, error) {
	var outArg any
	if output != nil {
		b, err := json.Marshal(output)
		if err != nil {
			return false, err
		}
		outArg = string(b)
	}
	tag, err := s.pool.Exec(ctx,
		`UPDATE eter.jobs SET state=$2, finished_at=now(), output=$3::jsonb, error=nullif($4,'')
		  WHERE id=$1 AND state='running'`, id, state, outArg, errMsg)
	return tag.RowsAffected() == 1, err
}

func (s *pgJobStore) CancelQueued(ctx context.Context, id int64) (bool, error) {
	tag, err := s.pool.Exec(ctx,
		"UPDATE eter.jobs SET state='canceled', finished_at=now() WHERE id=$1 AND state='queued'", id)
	return tag.RowsAffected() == 1, err
}

func (s *pgJobStore) FailOrphans(ctx context.Context, reason string) (int, error) {
	tag, err := s.pool.Exec(ctx,
		"UPDATE eter.jobs SET state='failed', finished_at=now(), error=$1 WHERE state='running'", reason)
	return int(tag.RowsAffected()), err
}

// ---- the runner (single-flight lane) ----------------------------------------

type runner struct {
	cfg    orchConfig
	store  jobStore
	wake   chan struct{}
	worker string
	// lane is THE single-flight lane (capacity 1). Job execution block-acquires
	// it; the scheduled maintenance cycle try-acquires and skips when held, so
	// a backup and a recovery can never run concurrently.
	lane chan struct{}

	mu        sync.Mutex
	runningID int64
	cancelFn  context.CancelFunc
	events    map[int64][]map[string]any // last N structured stderr events per job (in-memory, since boot)
}

const (
	eventRing    = 50 // stderr events kept per job
	maxEventJobs = 64 // jobs whose event tails are kept (oldest evicted, bounded memory on a long-lived process)
)

func newRunner(cfg orchConfig, store jobStore) *runner {
	host, _ := os.Hostname()
	return &runner{
		cfg:    cfg,
		store:  store,
		wake:   make(chan struct{}, 1),
		worker: fmt.Sprintf("%s:%d#%d", host, os.Getpid(), time.Now().Unix()),
		lane:   make(chan struct{}, 1),
		events: map[int64][]map[string]any{},
	}
}

// poke nudges the runner after a submit (falls back to the poll ticker).
func (r *runner) poke() {
	select {
	case r.wake <- struct{}{}:
	default:
	}
}

func (r *runner) loop(ctx context.Context) {
	tick := time.NewTicker(2 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-r.wake:
		case <-tick.C:
		}
		for {
			job, err := r.store.NextQueued(ctx)
			if err != nil || job == nil {
				break
			}
			// execute marks the row running itself (after registering the cancel
			// target) and no-ops if the job was canceled while still queued.
			r.execute(ctx, job)
		}
	}
}

// cancelRunning cancels the in-flight job (if any); used by shutdown.
func (r *runner) cancelRunning(reason string) {
	r.mu.Lock()
	cancel := r.cancelFn
	r.mu.Unlock()
	if cancel != nil {
		logMsg("canceling running job", map[string]any{"reason": reason})
		cancel()
	}
}

// cancel cancels job id: queued → canceled in the store; running → signal the
// process (the execute path records the terminal state). Returns whether
// anything was canceled.
func (r *runner) cancel(ctx context.Context, id int64) (bool, error) {
	if ok, err := r.store.CancelQueued(ctx, id); err != nil || ok {
		return ok, err
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.runningID == id && r.cancelFn != nil {
		r.cancelFn()
		return true, nil
	}
	return false, nil
}

// awaitIdle gives a running job's teardown a moment during shutdown.
func (r *runner) awaitIdle(d time.Duration) {
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if len(r.lane) == 0 {
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// jobEvents returns the in-memory structured-stderr tail for a job (jobs run
// since this boot only).
func (r *runner) jobEvents(id int64) []map[string]any {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]map[string]any(nil), r.events[id]...)
}

// recordEvent appends a structured stderr event to job id's ring, evicting the
// oldest job's tail when the map hits maxEventJobs (job ids are monotonic).
func (r *runner) recordEvent(id int64, ev map[string]any) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, seen := r.events[id]; !seen && len(r.events) >= maxEventJobs {
		oldest := id
		for k := range r.events {
			if k < oldest {
				oldest = k
			}
		}
		delete(r.events, oldest)
	}
	ring := append(r.events[id], ev)
	if len(ring) > eventRing {
		ring = ring[len(ring)-eventRing:]
	}
	r.events[id] = ring
}

// argv maps a job's kind+args onto the eter-storage subcommand line. Kinds and
// arg names mirror the CLI verbs 1:1.
func argv(kind string, args map[string]any) ([]string, error) {
	str := func(k string) string { v, _ := args[k].(string); return v }
	switch kind {
	case "snapshot":
		if l := str("label"); l != "" {
			return []string{"snapshot", l}, nil
		}
		return []string{"snapshot"}, nil
	case "recover-table", "recover-rows":
		if str("table") == "" {
			return nil, fmt.Errorf("%s: args.table is required", kind)
		}
		out := []string{kind, str("table")}
		if s := str("snapshot"); s != "" {
			out = append(out, s)
		}
		return out, nil
	case "recover-column":
		if str("table") == "" || str("column") == "" {
			return nil, fmt.Errorf("recover-column: args.table and args.column are required")
		}
		out := []string{kind, str("table"), str("column")}
		if s := str("snapshot"); s != "" {
			out = append(out, s)
		}
		return out, nil
	case "as-of":
		if str("at") == "" || str("sql") == "" {
			return nil, fmt.Errorf("as-of: args.at and args.sql are required")
		}
		return []string{"as-of", str("at"), str("sql")}, nil
	case "cycle":
		return []string{"cycle"}, nil
	}
	return nil, fmt.Errorf("unknown job kind %q", kind)
}

// runContext derives a job/cycle execution context: cancelable, and bounded
// by ETER_JOB_TIMEOUT_SEC when set (a hung pg_basebackup must not wedge the
// lane forever, the heartbeat would keep the job looking healthy).
func (r *runner) runContext(ctx context.Context) (context.Context, context.CancelFunc) {
	if r.cfg.jobTimeoutSec > 0 {
		return context.WithTimeout(ctx, time.Duration(r.cfg.jobTimeoutSec)*time.Second)
	}
	return context.WithCancel(ctx)
}

// execute runs one job to a terminal state. Any error inside is recorded on
// the job, never propagated, the runner lane must survive every job.
//
// Ordering matters for cancel correctness: the lane is acquired and the cancel
// target (runningID/cancelFn) registered BEFORE the store row flips to
// running. A cancel arriving mid-transition then either still catches the row
// queued (CancelQueued wins and MarkRunning below no-ops) or finds the cancel
// target already registered, there is no window where the job is `running`
// but uncancelable.
func (r *runner) execute(ctx context.Context, job *Job) {
	select {
	case r.lane <- struct{}{}: // may wait out a scheduled maintenance cycle
	case <-ctx.Done():
		return
	}
	runCtx, cancel := r.runContext(ctx)
	r.mu.Lock()
	r.runningID = job.ID
	r.cancelFn = cancel
	r.mu.Unlock()
	defer func() {
		cancel()
		r.mu.Lock()
		r.runningID = 0
		r.cancelFn = nil
		r.mu.Unlock()
		<-r.lane
	}()

	if ok, err := r.store.MarkRunning(ctx, job.ID, r.worker); err != nil || !ok {
		return // canceled while queued, or transient store error, the loop re-checks
	}
	logMsg("job started", map[string]any{"job": job.ID, "kind": job.Kind})
	output, errMsg := r.runStorage(runCtx, job)
	state := "succeeded"
	if errMsg != "" {
		state = "failed"
		if runCtx.Err() != nil {
			state = "canceled"
			if errors.Is(runCtx.Err(), context.DeadlineExceeded) {
				state = "failed"
				errMsg = fmt.Sprintf("job timed out after %ds (ETER_JOB_TIMEOUT_SEC)", r.cfg.jobTimeoutSec)
			}
		}
	}
	if _, err := r.store.Finish(context.WithoutCancel(ctx), job.ID, state, output, errMsg); err != nil {
		logMsg("job finish write failed", map[string]any{"job": job.ID, "err": err.Error()})
	}
	logMsg("job finished", map[string]any{"job": job.ID, "state": state})
}

// runStorage execs the sidecar for a persisted job: structured stdout becomes
// the job output, structured stderr lines become progress events, and the
// job's restore dir is swept afterwards no matter what (a SIGKILL'd restore
// leaves a running throwaway postmaster + a full data-dir copy behind).
func (r *runner) runStorage(ctx context.Context, job *Job) (output map[string]any, errMsg string) {
	if r.cfg.backupDir == "" {
		return nil, "storage not configured on the orchestrator (set ETER_BACKUP_DIR)"
	}
	args, err := argv(job.Kind, job.Args)
	if err != nil {
		return nil, err.Error()
	}
	restoreDir := fmt.Sprintf("%s/job-%d", r.cfg.restoreDir, job.ID)
	defer sweepRestoreDir(r.cfg, restoreDir)

	onEvent := func(ev map[string]any) { r.recordEvent(job.ID, ev) }
	env := append(os.Environ(),
		"DATABASE_URL="+r.cfg.databaseURL,
		"ETER_META_URL="+r.cfg.metaURL,
		"ETER_STORAGE_JSON=1",
		"ETER_RESTORE_DIR="+restoreDir,
		fmt.Sprintf("ETER_TMP_PORT=%d", r.cfg.tmpPortBase+int(job.ID%16)),
	)
	return execStorage(ctx, r.cfg.storageBin, args, env, onEvent, func(p map[string]any) {
		_ = r.store.SetProgress(context.WithoutCancel(ctx), job.ID, p)
	}, func() { _ = r.store.Heartbeat(context.WithoutCancel(ctx), job.ID) })
}

// runCycle runs one storage maintenance cycle through the lane WITHOUT a
// persisted job row (eter.storage_snapshots is already the durable record;
// 2880 cycle rows/day in eter.jobs would be noise). Try-acquires the lane and
// skips when a job holds it, a scheduled backup must never contend with a
// running recovery (the next tick retries).
func (r *runner) runCycle(ctx context.Context) {
	select {
	case r.lane <- struct{}{}:
	default:
		return
	}
	runCtx, cancel := r.runContext(ctx)
	r.mu.Lock()
	r.cancelFn = cancel
	r.mu.Unlock()
	defer func() {
		cancel()
		r.mu.Lock()
		r.cancelFn = nil
		r.mu.Unlock()
		<-r.lane
	}()
	if r.cfg.backupDir == "" {
		return
	}
	env := append(os.Environ(),
		"DATABASE_URL="+r.cfg.databaseURL,
		"ETER_META_URL="+r.cfg.metaURL,
		"ETER_STORAGE_JSON=1",
	)
	out, errMsg := execStorage(runCtx, r.cfg.storageBin, []string{"cycle"}, env, nil, nil, nil)
	if errMsg != "" {
		logMsg("scheduled cycle failed", map[string]any{"err": errMsg})
	} else if tb, _ := out["took_backup"].(bool); tb {
		logMsg("scheduled cycle took a backup", out)
	}
}

// bootPreflight execs `eter-storage preflight` once at orchestrator boot:
// enable DDL logging (idempotent) + verify WAL archiving, so recovery is
// lossless in orchestrated deployments too. Failures are logged loudly, never
// fatal, the engine API must come up even when storage is misconfigured, and
// every scheduled cycle re-runs preflight.
func bootPreflight(ctx context.Context, cfg orchConfig) {
	pfCtx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	env := append(os.Environ(),
		"DATABASE_URL="+cfg.databaseURL,
		"ETER_META_URL="+cfg.metaURL,
		"ETER_STORAGE_JSON=1",
	)
	if _, errMsg := execStorage(pfCtx, cfg.storageBin, []string{"preflight"}, env, nil, nil, nil); errMsg != "" {
		logMsg("boot: storage preflight FAILED, recovery may be degraded until this is fixed",
			map[string]any{"err": errMsg})
	} else {
		logMsg("boot: storage preflight ok (DDL logging ensured, WAL archiving verified)", nil)
	}
}

// lineWriter is an io.Writer that invokes fn once per complete line. Used as
// the exec.Cmd's stdout/stderr so cmd.Wait owns the pipe lifecycle: on normal
// exit it waits for the copy goroutines (no lost output), and on cancel
// WaitDelay bounds that wait even if an orphaned grandchild (the throwaway
// postgres, a stray sleep) still holds the pipe open.
type lineWriter struct {
	mu  sync.Mutex
	buf []byte
	fn  func(line string)
}

func (w *lineWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.buf = append(w.buf, p...)
	for {
		i := bytes.IndexByte(w.buf, '\n')
		if i < 0 {
			// Cap a pathological unterminated line at 4 MiB.
			if len(w.buf) > 4<<20 {
				w.fn(string(w.buf))
				w.buf = nil
			}
			return len(p), nil
		}
		w.fn(string(w.buf[:i]))
		w.buf = append([]byte(nil), w.buf[i+1:]...)
	}
}

// execStorage runs the sidecar once: parses structured stderr (logMsg JSON
// lines) into events + throttled progress writes, heartbeats while running,
// and returns the last structured stdout line as the result. SIGTERM on
// cancel, SIGKILL + pipe teardown after 10s grace (WaitDelay).
func execStorage(ctx context.Context, bin string, args, env []string,
	onEvent func(map[string]any), onProgress func(map[string]any), onBeat func()) (map[string]any, string) {
	var mu sync.Mutex
	var lastOut map[string]any
	var stderrTail []string
	lastProgress := time.Time{}

	//nolint:gosec // bin is the configured eter-storage binary; args are built from validated job params
	cmd := exec.CommandContext(ctx, bin, args...)
	cmd.Env = env
	cmd.Cancel = func() error { return cmd.Process.Signal(syscall.SIGTERM) }
	cmd.WaitDelay = 10 * time.Second
	cmd.Stdout = &lineWriter{fn: func(line string) { // last JSON line wins (ETER_STORAGE_JSON=1 emits exactly one)
		var m map[string]any
		if json.Unmarshal([]byte(line), &m) == nil {
			mu.Lock()
			lastOut = m
			mu.Unlock()
		}
	}}
	cmd.Stderr = &lineWriter{fn: func(line string) { // structured events + raw tail for error reporting
		mu.Lock()
		stderrTail = append(stderrTail, line)
		if len(stderrTail) > 20 {
			stderrTail = stderrTail[len(stderrTail)-20:]
		}
		mu.Unlock()
		var ev map[string]any
		if json.Unmarshal([]byte(line), &ev) == nil {
			if onEvent != nil {
				onEvent(ev)
			}
			if onProgress != nil && time.Since(lastProgress) >= time.Second {
				lastProgress = time.Now()
				onProgress(ev)
			}
		}
	}}
	if err := cmd.Start(); err != nil {
		return nil, fmt.Sprintf("could not start %s: %v", bin, err)
	}

	beat := time.NewTicker(15 * time.Second)
	defer beat.Stop()
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	for {
		select {
		case <-beat.C:
			if onBeat != nil {
				onBeat()
			}
		case werr := <-done:
			mu.Lock()
			out := lastOut
			tail := strings.Join(stderrTail, "\n")
			mu.Unlock()
			if werr == nil {
				return out, ""
			}
			if ctx.Err() != nil {
				return out, "canceled"
			}
			return out, fmt.Sprintf("%s %s failed: %v\n%s", bin, strings.Join(args, " "), werr, tail)
		}
	}
}
