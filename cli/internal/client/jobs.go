// Job methods on the hosted transport (orchestrator-only surface). Deliberately
// NOT part of EterClient, that interface is frozen; storage jobs exist only
// where an orchestrator does.

package client

import (
	"context"
	"net/http"
	"strconv"
)

// JobClient is the async-job surface the orchestrator adds on top of the /v1
// protocol. Only *HostedClient implements it; commands feature-detect with a
// type assertion.
type JobClient interface {
	SubmitStorageJob(ctx context.Context, kind string, args map[string]any) (int64, error)
	GetJob(ctx context.Context, id int64) (map[string]any, error)
	ListJobs(ctx context.Context, limit int) ([]map[string]any, error)
	CancelJob(ctx context.Context, id int64) error
}

// SubmitStorageJob enqueues a storage operation (POST /v1/storage/<kind>) and
// returns the job id.
func (c *HostedClient) SubmitStorageJob(ctx context.Context, kind string, args map[string]any) (int64, error) {
	if args == nil {
		args = map[string]any{}
	}
	var r struct {
		JobID int64 `json:"job_id"`
	}
	err := c.call(ctx, "/v1/storage/"+kind, http.MethodPost, args, &r)
	return r.JobID, err
}

func (c *HostedClient) GetJob(ctx context.Context, id int64) (map[string]any, error) {
	var m map[string]any
	err := c.call(ctx, "/v1/jobs/"+strconv.FormatInt(id, 10), http.MethodGet, nil, &m)
	return m, err
}

func (c *HostedClient) ListJobs(ctx context.Context, limit int) ([]map[string]any, error) {
	var rows []map[string]any
	err := c.call(ctx, "/v1/jobs?limit="+strconv.Itoa(limit), http.MethodGet, nil, &rows)
	return rows, err
}

func (c *HostedClient) CancelJob(ctx context.Context, id int64) error {
	return c.call(ctx, "/v1/jobs/"+strconv.FormatInt(id, 10)+"/cancel", http.MethodPost, nil, nil)
}
