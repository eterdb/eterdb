package main

import (
	"context"
	"fmt"
	"sort"
	"sync"
	"time"

	"github.com/eterdb/eterdb/sidecars/eterclient"
)

// fakeClient implements eterclient.EterClient (and optionally errors) for
// handler tests, no database.
type fakeClient struct {
	err     error // returned by every method when set
	preview *eterclient.UndoPlan
}

func (f *fakeClient) Init(ctx context.Context) (map[string]any, error) {
	return map[string]any{"applied": true}, f.err
}
func (f *fakeClient) Track(ctx context.Context, table string) error { return f.err }
func (f *fakeClient) TrackAll(ctx context.Context) (int, error)     { return 3, f.err }
func (f *fakeClient) InitCapture(ctx context.Context, autoTrack bool) (map[string]any, error) {
	return map[string]any{"tracked": 3}, f.err
}
func (f *fakeClient) Log(ctx context.Context, opts eterclient.LogOptions) ([]map[string]any, error) {
	if f.err != nil {
		return nil, f.err
	}
	return []map[string]any{{"txid": 1, "limit_seen": opts.Limit, "include_undo": opts.IncludeUndo}}, nil
}
func (f *fakeClient) Show(ctx context.Context, txid int64) ([]map[string]any, error) {
	return []map[string]any{{"txid": txid}}, f.err
}
func (f *fakeClient) Preview(ctx context.Context, txid int64) (*eterclient.UndoPlan, error) {
	if f.err != nil {
		return nil, f.err
	}
	if f.preview != nil {
		return f.preview, nil
	}
	return &eterclient.UndoPlan{Txid: txid, Classification: "clean"}, nil
}
func (f *fakeClient) Undo(ctx context.Context, txid int64, mode eterclient.UndoMode) (map[string]any, error) {
	if f.err != nil {
		return nil, f.err
	}
	return map[string]any{"txid": txid, "mode": string(mode)}, nil
}
func (f *fakeClient) PreviewCohort(ctx context.Context, sel eterclient.CohortSelector) (map[string]any, error) {
	if f.err != nil {
		return nil, f.err
	}
	return map[string]any{"table": sel.Table}, nil
}
func (f *fakeClient) UndoCohort(ctx context.Context, sel eterclient.CohortSelector, mode eterclient.UndoMode) (map[string]any, error) {
	if f.err != nil {
		return nil, f.err
	}
	return map[string]any{"table": sel.Table, "mode": string(mode)}, nil
}
func (f *fakeClient) Mark(ctx context.Context, label string) (int64, error) { return 7, f.err }
func (f *fakeClient) Markers(ctx context.Context) ([]map[string]any, error) {
	return []map[string]any{}, f.err
}
func (f *fakeClient) Status(ctx context.Context) (map[string]any, error) {
	return map[string]any{"ready": true}, f.err
}
func (f *fakeClient) Close() {}

// memStore is an in-memory jobStore (hermetic tests, CI has no database).
type memStore struct {
	mu   sync.Mutex
	next int64
	jobs map[int64]*Job
}

func newMemStore() *memStore { return &memStore{jobs: map[int64]*Job{}} }

func (m *memStore) Submit(ctx context.Context, kind string, args map[string]any) (int64, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.next++
	m.jobs[m.next] = &Job{ID: m.next, Kind: kind, Args: args, State: "queued", SubmittedAt: time.Now()}
	return m.next, nil
}

func (m *memStore) Get(ctx context.Context, id int64) (*Job, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	j, ok := m.jobs[id]
	if !ok {
		return nil, nil
	}
	cp := *j
	return &cp, nil
}

func (m *memStore) List(ctx context.Context, state, kind string, limit int) ([]Job, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if limit <= 0 {
		limit = 50
	}
	var out []Job
	for _, j := range m.jobs {
		if state != "" && j.State != state {
			continue
		}
		if kind != "" && j.Kind != kind {
			continue
		}
		out = append(out, *j)
	}
	sort.Slice(out, func(i, k int) bool { return out[i].ID > out[k].ID })
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

func (m *memStore) NextQueued(ctx context.Context) (*Job, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var best *Job
	for _, j := range m.jobs {
		if j.State == "queued" && (best == nil || j.ID < best.ID) {
			best = j
		}
	}
	if best == nil {
		return nil, nil
	}
	cp := *best
	return &cp, nil
}

func (m *memStore) MarkRunning(ctx context.Context, id int64, worker string) (bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	j, ok := m.jobs[id]
	if !ok || j.State != "queued" {
		return false, nil
	}
	now := time.Now()
	j.State, j.StartedAt = "running", &now
	return true, nil
}

func (m *memStore) Heartbeat(ctx context.Context, id int64) error { return nil }

func (m *memStore) SetProgress(ctx context.Context, id int64, p map[string]any) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if j, ok := m.jobs[id]; ok && j.State == "running" {
		j.Progress = p
	}
	return nil
}

func (m *memStore) Finish(ctx context.Context, id int64, state string, output map[string]any, errMsg string) (bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	j, ok := m.jobs[id]
	if !ok || j.State != "running" {
		return false, nil
	}
	now := time.Now()
	j.State, j.FinishedAt, j.Output, j.Error = state, &now, output, errMsg
	return true, nil
}

func (m *memStore) CancelQueued(ctx context.Context, id int64) (bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	j, ok := m.jobs[id]
	if !ok || j.State != "queued" {
		return false, nil
	}
	now := time.Now()
	j.State, j.FinishedAt = "canceled", &now
	return true, nil
}

func (m *memStore) FailOrphans(ctx context.Context, reason string) (int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	n := 0
	for _, j := range m.jobs {
		if j.State == "running" {
			now := time.Now()
			j.State, j.FinishedAt, j.Error = "failed", &now, reason
			n++
		}
	}
	return n, nil
}

// waitState polls until job id reaches a state (test helper).
func (m *memStore) waitState(id int64, want string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		j, _ := m.Get(context.Background(), id)
		if j != nil && j.State == want {
			return nil
		}
		time.Sleep(10 * time.Millisecond)
	}
	j, _ := m.Get(context.Background(), id)
	got := "<missing>"
	if j != nil {
		got = j.State + " err=" + j.Error
	}
	return fmt.Errorf("job %d never reached %q (last: %s)", id, want, got)
}
