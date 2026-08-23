package client

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"github.com/eterdb/eterdb/cli/internal/core"
)

// HostedClient talks to the orchestrator's /v1 REST API (what friends use
// against a shared instance). The server runs the same SQL functions
// server-side. (The /v1 wire protocol is the one the retired TS eter-server
// spoke, now served by sidecars/orchestrator, ADR 0004.)
type HostedClient struct {
	baseURL string
	token   string
	http    *http.Client
}

// NewHostedClient builds a hosted-mode transport.
func NewHostedClient(baseURL, token string) *HostedClient {
	return &HostedClient{baseURL: baseURL, token: token, http: &http.Client{}}
}

func (c *HostedClient) call(ctx context.Context, path, method string, body any, out any) error {
	// url.JoinPath percent-escapes a "?" inside path (turning /v1/changes?x=1
	// into /v1/changes%3Fx=1 → 404), so split any query string off first and
	// re-attach it after joining.
	path, query, _ := strings.Cut(path, "?")
	u, err := url.JoinPath(c.baseURL, path)
	if err != nil {
		u = strings.TrimRight(c.baseURL, "/") + "/" + strings.TrimLeft(path, "/")
	}
	if query != "" {
		u += "?" + query
	}
	var reqBody io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return err
		}
		reqBody = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, u, reqBody)
	if err != nil {
		return err
	}
	req.Header.Set("content-type", "application/json")
	req.Header.Set("authorization", "Bearer "+c.token)
	res, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer func() { _ = res.Body.Close() }()
	data, _ := io.ReadAll(res.Body)
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		return fmt.Errorf("orchestrator %d: %s", res.StatusCode, string(data))
	}
	if out != nil {
		return json.Unmarshal(data, out)
	}
	return nil
}

func (c *HostedClient) Init(ctx context.Context) (map[string]any, error) {
	var m map[string]any
	err := c.call(ctx, "/v1/init", http.MethodPost, nil, &m)
	return m, err
}

func (c *HostedClient) Track(ctx context.Context, table string) error {
	return c.call(ctx, "/v1/track", http.MethodPost, map[string]any{"table": table}, nil)
}

// InitCapture is a no-op in hosted mode: the control plane (capture sidecar +
// startup) owns capture setup, so the CLI does not drive it over the wire.
func (c *HostedClient) InitCapture(_ context.Context, _ bool) (map[string]any, error) {
	return map[string]any{"tracked": 0, "pending": 0, "auto_track": false, "managed": true}, nil
}

func (c *HostedClient) TrackAll(ctx context.Context) (int, error) {
	var r struct {
		Tracked int `json:"tracked"`
	}
	err := c.call(ctx, "/v1/track-all", http.MethodPost, nil, &r)
	return r.Tracked, err
}

func (c *HostedClient) Log(ctx context.Context, opts LogOptions) ([]map[string]any, error) {
	q := url.Values{}
	if opts.Table != "" {
		q.Set("table", opts.Table)
	}
	if opts.Since != "" {
		q.Set("since", opts.Since)
	}
	if opts.Limit != 0 {
		q.Set("limit", strconv.Itoa(opts.Limit))
	}
	if opts.IncludeUndo {
		q.Set("includeUndo", "1")
	}
	var rows []map[string]any
	err := c.call(ctx, "/v1/changes?"+q.Encode(), http.MethodGet, nil, &rows)
	return rows, err
}

func (c *HostedClient) Show(ctx context.Context, txid int64) ([]map[string]any, error) {
	var rows []map[string]any
	err := c.call(ctx, fmt.Sprintf("/v1/tx/%d", txid), http.MethodGet, nil, &rows)
	return rows, err
}

func (c *HostedClient) Preview(ctx context.Context, txid int64) (*core.UndoPlan, error) {
	var plan core.UndoPlan
	err := c.call(ctx, "/v1/undo/preview", http.MethodPost, map[string]any{"txid": txid}, &plan)
	return &plan, err
}

func (c *HostedClient) Undo(ctx context.Context, txid int64, mode core.UndoMode) (map[string]any, error) {
	var m map[string]any
	err := c.call(ctx, "/v1/undo", http.MethodPost, map[string]any{"txid": txid, "mode": string(mode)}, &m)
	return m, err
}

func (c *HostedClient) PreviewCohort(ctx context.Context, sel CohortSelector) (map[string]any, error) {
	var m map[string]any
	err := c.call(ctx, "/v1/cohort/preview", http.MethodPost, cohortBody(sel, ""), &m)
	return m, err
}

func (c *HostedClient) UndoCohort(ctx context.Context, sel CohortSelector, mode core.UndoMode) (map[string]any, error) {
	var m map[string]any
	err := c.call(ctx, "/v1/cohort/undo", http.MethodPost, cohortBody(sel, string(mode)), &m)
	return m, err
}

func (c *HostedClient) Mark(ctx context.Context, label string) (int64, error) {
	var r struct {
		ID int64 `json:"id"`
	}
	err := c.call(ctx, "/v1/markers", http.MethodPost, map[string]any{"label": label}, &r)
	return r.ID, err
}

func (c *HostedClient) Markers(ctx context.Context) ([]map[string]any, error) {
	var rows []map[string]any
	err := c.call(ctx, "/v1/markers", http.MethodGet, nil, &rows)
	return rows, err
}

func (c *HostedClient) Status(ctx context.Context) (map[string]any, error) {
	var m map[string]any
	err := c.call(ctx, "/v1/status", http.MethodGet, nil, &m)
	if err != nil {
		return m, err
	}
	if m == nil {
		m = map[string]any{}
	}
	// A successful call means the hosted instance answered → reachable + ready.
	m["mode"] = "hosted"
	m["endpoint"] = c.baseURL
	if _, ok := m["ready"]; !ok {
		m["ready"] = true
	}
	return m, nil
}

func (c *HostedClient) Close() {}

// cohortBody mirrors the TypeScript CohortSelector wire shape (table,
// fingerprint, from, to, predicate) plus an optional mode for undo.
func cohortBody(sel CohortSelector, mode string) map[string]any {
	body := map[string]any{}
	if sel.Table != "" {
		body["table"] = sel.Table
	}
	if sel.Fingerprint != "" {
		body["fingerprint"] = sel.Fingerprint
	}
	if sel.From != "" {
		body["from"] = sel.From
	}
	if sel.To != "" {
		body["to"] = sel.To
	}
	if sel.Predicate != nil {
		body["predicate"] = sel.Predicate
	}
	if mode != "" {
		body["mode"] = mode
	}
	return body
}
