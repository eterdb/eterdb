package eterclient

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// DirectClient talks straight to Postgres. Used locally, for `eter demo`, and
// in CI. It keeps two pools: the tenant DB (user tables + track/undo apply +
// the SSI/capture surface) and the metadata store (durable eter.* history,
// markers, …). When ETER_META_URL is unset the two pools are the same and the
// behaviour is identical to the single-DB original.
type DirectClient struct {
	pool         *pgxpool.Pool
	metaPool     *pgxpool.Pool
	separate     bool
	endpoint     string // tenant host:port/db (no credentials), for `status`
	metaEndpoint string // store host:port/db when two-DB (separate), else ""
}

func newPool(ctx context.Context, dsn, appName string) (*pgxpool.Pool, error) {
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, err
	}
	if cfg.ConnConfig.RuntimeParams == nil {
		cfg.ConnConfig.RuntimeParams = map[string]string{}
	}
	cfg.ConnConfig.RuntimeParams["application_name"] = appName
	return pgxpool.NewWithConfig(ctx, cfg)
}

// NewDirectClient connects the tenant and (possibly separate) metadata pools.
func NewDirectClient(ctx context.Context, connectionString string) (*DirectClient, error) {
	metaConn := MetaURL(connectionString)
	pool, err := newPool(ctx, connectionString, "eter-cli")
	if err != nil {
		return nil, err
	}
	separate := metaConn != connectionString
	metaPool := pool
	if separate {
		metaPool, err = newPool(ctx, metaConn, "eter-cli-meta")
		if err != nil {
			pool.Close()
			return nil, err
		}
	}
	cc := pool.Config().ConnConfig
	endpoint := fmt.Sprintf("%s:%d/%s", cc.Host, cc.Port, cc.Database)
	metaEndpoint := ""
	if separate {
		mc := metaPool.Config().ConnConfig
		metaEndpoint = fmt.Sprintf("%s:%d/%s", mc.Host, mc.Port, mc.Database)
	}
	return &DirectClient{pool: pool, metaPool: metaPool, separate: separate, endpoint: endpoint, metaEndpoint: metaEndpoint}, nil
}

func (c *DirectClient) Close() {
	c.pool.Close()
	if c.separate {
		c.metaPool.Close()
	}
}

func (c *DirectClient) Init(ctx context.Context) (map[string]any, error) {
	path, err := EterSQLFile()
	if err != nil {
		return nil, err
	}
	sqlBytes, err := os.ReadFile(path) //nolint:gosec // path is an operator-provided SQL file (eter init/apply), not attacker input
	if err != nil {
		return nil, err
	}
	if _, err := c.pool.Exec(ctx, string(sqlBytes)); err != nil {
		return nil, err
	}
	// In two-DB mode the store needs the same engine schema (it runs preview_undo
	// and holds history/markers); apply idempotently there too.
	if c.separate {
		if _, err := c.metaPool.Exec(ctx, string(sqlBytes)); err != nil {
			return nil, err
		}
	}
	return map[string]any{"applied": true}, nil
}

func (c *DirectClient) Track(ctx context.Context, table string) error {
	_, err := c.pool.Exec(ctx, "SELECT eter.track($1::regclass)", table)
	return err
}

func (c *DirectClient) TrackAll(ctx context.Context) (int, error) {
	var n int
	err := c.pool.QueryRow(ctx, "SELECT eter.track_all()").Scan(&n)
	return n, err
}

func (c *DirectClient) InitCapture(ctx context.Context, autoTrack bool) (map[string]any, error) {
	var out map[string]any
	err := c.pool.QueryRow(ctx, "SELECT eter.init_capture($1)", autoTrack).Scan(&out)
	return out, err
}

func (c *DirectClient) Log(ctx context.Context, opts LogOptions) ([]map[string]any, error) {
	var where []string
	var params []any
	if !opts.IncludeUndo {
		where = append(where, "NOT h.is_undo")
	}
	if opts.Table != "" {
		params = append(params, opts.Table)
		where = append(where, fmt.Sprintf("h.table_name = eter._relname($%d)", len(params)))
	}
	if opts.Since != "" {
		params = append(params, opts.Since)
		where = append(where, fmt.Sprintf("h.committed_at >= $%d", len(params)))
	}
	limit := opts.Limit
	if limit == 0 {
		limit = 50
	}
	params = append(params, limit)
	limitIdx := len(params)
	whereClause := ""
	if len(where) > 0 {
		whereClause = "WHERE " + strings.Join(where, " AND ")
	}
	sql := fmt.Sprintf(`
      SELECT h.txid,
             count(*)::int AS ops,
             count(*) FILTER (WHERE h.op='I')::int AS inserts,
             count(*) FILTER (WHERE h.op='U')::int AS updates,
             count(*) FILTER (WHERE h.op='D')::int AS deletes,
             min(h.committed_at) AS first_at,
             max(h.committed_at) AS last_at,
             (array_agg(DISTINCT h.table_name))[1] AS table_name,
             (array_agg(DISTINCT h.fingerprint))[1] AS fingerprint,
             (array_agg(h.statement_sample))[1] AS statement_sample,
             bool_or(h.is_undo) AS is_undo,
             (array_agg(DISTINCT h.application_name))[1] AS application_name
      FROM eter.history h
      %s
      GROUP BY h.txid
      ORDER BY max(h.committed_at) DESC
      LIMIT $%d`, whereClause, limitIdx)
	return c.queryMaps(ctx, c.metaPool, sql, params...)
}

func (c *DirectClient) Show(ctx context.Context, txid int64) ([]map[string]any, error) {
	return c.queryMaps(ctx, c.metaPool,
		`SELECT id, op, table_name, pk, row_before, row_after, committed_at, is_undo, undo_of
       FROM eter.history WHERE txid = $1 ORDER BY id`, txid)
}

// previewRaw returns the raw jsonb plan so the externalized undo path can pass
// the engine's own plan back to undo_rows verbatim.
func (c *DirectClient) previewRaw(ctx context.Context, txid int64) ([]byte, error) {
	// Two-DB: the capture sidecar forwards the SSI read-set into the store; derive
	// the rw graph there ON DEMAND now (preview is rare and runs long after
	// capture, so the history stream has caught up, sound).
	if c.separate {
		if _, err := c.metaPool.Exec(ctx, "SELECT eter.derive_from_read_set()"); err != nil {
			return nil, err
		}
	}
	var b []byte
	err := c.metaPool.QueryRow(ctx, "SELECT eter.preview_undo($1) AS preview_undo", txid).Scan(&b)
	return b, err
}

func (c *DirectClient) Preview(ctx context.Context, txid int64) (*UndoPlan, error) {
	b, err := c.previewRaw(ctx, txid)
	if err != nil {
		return nil, err
	}
	var plan UndoPlan
	if err := json.Unmarshal(b, &plan); err != nil {
		return nil, err
	}
	return &plan, nil
}

// PreviewRaw exposes the engine's own preview_undo JSON verbatim, the
// orchestrator's /v1/undo/preview passes it through untouched so the wire
// carries every field the engine emits (the typed UndoPlan drops fields it
// doesn't know, e.g. the per-op list).
func (c *DirectClient) PreviewRaw(ctx context.Context, txid int64) ([]byte, error) {
	return c.previewRaw(ctx, txid)
}

// Backups lists the storage sidecar's base-backup catalog (meta store),
// newest first, the orchestrator's GET /v1/storage/backups.
func (c *DirectClient) Backups(ctx context.Context) ([]map[string]any, error) {
	return c.queryMaps(ctx, c.metaPool,
		`SELECT id, backup_name, lsn::text AS lsn, wal_start, kind, created_at, pruned_at
		   FROM eter.storage_snapshots ORDER BY id DESC LIMIT 200`)
}

func (c *DirectClient) Undo(ctx context.Context, txid int64, mode UndoMode) (map[string]any, error) {
	// Co-located: history is in the tenant DB, so the in-engine undo reads +
	// applies in one transaction (unchanged behavior).
	if !c.separate {
		var b []byte
		if err := c.pool.QueryRow(ctx, "SELECT eter.undo($1, $2) AS undo", txid, string(mode)).Scan(&b); err != nil {
			return nil, err
		}
		return unmarshalMap(b)
	}
	// Externalized: read the plan + the history rows (target ∪ conflicts) from the
	// store, then apply compensation atomically in the tenant DB via undo_rows.
	planBytes, err := c.previewRaw(ctx, txid)
	if err != nil {
		return nil, err
	}
	var plan UndoPlan
	if err := json.Unmarshal(planBytes, &plan); err != nil {
		return nil, err
	}
	txids := append([]int64{txid}, plan.Conflicts...)
	var rowsJSON []byte
	err = c.metaPool.QueryRow(ctx,
		`SELECT coalesce(jsonb_agg(to_jsonb(h.*)), '[]'::jsonb) FROM eter.history h
        WHERE h.txid = ANY($1) AND NOT h.is_undo`, txids).Scan(&rowsJSON)
	if err != nil {
		return nil, err
	}
	var resBytes []byte
	err = c.pool.QueryRow(ctx,
		"SELECT eter.undo_rows($1::bigint, $2::text, $3::jsonb, $4::jsonb) AS undo_rows",
		txid, string(mode), planBytes, rowsJSON).Scan(&resBytes)
	if err != nil {
		return nil, err
	}
	res, err := unmarshalMap(resBytes)
	if err != nil {
		return nil, err
	}
	// Record the undo marker in the store (best-effort) so the capture sidecar
	// stamps is_undo on the decoded compensating writes.
	if applyTxid, ok := res["apply_txid"]; ok {
		_, _ = c.metaPool.Exec(ctx,
			"INSERT INTO eter.undo_txn (txid, undo_of) VALUES ($1, $2) ON CONFLICT (txid) DO NOTHING",
			int64(toFloat(applyTxid)), txid)
	}
	return res, nil
}

func (c *DirectClient) PreviewCohort(ctx context.Context, sel CohortSelector) (map[string]any, error) {
	// Derive the rw graph from the forwarded read-set FIRST, exactly as the
	// per-txn path does, otherwise observe-mode preview and apply disagree.
	if c.separate {
		if _, err := c.metaPool.Exec(ctx, "SELECT eter.derive_from_read_set()"); err != nil {
			return nil, err
		}
	}
	var b []byte
	err := c.metaPool.QueryRow(ctx,
		"SELECT eter.preview_cohort($1,$2,$3,$4,$5) AS preview_cohort",
		nullStr(sel.Table), nullStr(sel.Fingerprint), nullStr(sel.From), nullStr(sel.To),
		predicateJSON(sel.Predicate)).Scan(&b)
	if err != nil {
		return nil, err
	}
	return unmarshalMap(b)
}

func (c *DirectClient) UndoCohort(ctx context.Context, sel CohortSelector, mode UndoMode) (map[string]any, error) {
	if !c.separate {
		var b []byte
		err := c.pool.QueryRow(ctx,
			"SELECT eter.undo_cohort($1,$2,$3,$4,$5,$6) AS undo_cohort",
			nullStr(sel.Table), nullStr(sel.Fingerprint), nullStr(sel.From), nullStr(sel.To),
			predicateJSON(sel.Predicate), string(mode)).Scan(&b)
		if err != nil {
			return nil, err
		}
		return unmarshalMap(b)
	}
	// Externalized: select the cohort from the store, then drive each txn (newest
	// first) through the orchestrated single-txn undo. In clean_only, skip
	// dependent txns and report them rather than aborting the whole cohort.
	rows, err := c.queryMaps(ctx, c.metaPool,
		`SELECT txid FROM eter.select_cohort($1,$2,$3,$4,$5) ORDER BY txid DESC`,
		nullStr(sel.Table), nullStr(sel.Fingerprint), nullStr(sel.From), nullStr(sel.To),
		predicateJSON(sel.Predicate))
	if err != nil {
		return nil, err
	}
	if len(rows) == 0 {
		return map[string]any{
			"reverted_txns": 0, "skipped_dependent": 0, "skipped_txids": []int64{},
			"status": "empty", "mode": string(mode),
		}, nil
	}
	done := 0
	skipped := []int64{}
	for _, r := range rows {
		id := int64(toFloat(r["txid"]))
		if mode == CleanOnly {
			plan, err := c.Preview(ctx, id)
			if err != nil {
				return nil, err
			}
			if plan.Classification == "dependent" {
				skipped = append(skipped, id)
				continue
			}
		}
		if _, err := c.Undo(ctx, id, mode); err != nil {
			return nil, err
		}
		done++
	}
	return map[string]any{
		"reverted_txns": done, "skipped_dependent": len(skipped), "skipped_txids": skipped,
		"status": "applied", "mode": string(mode),
	}, nil
}

func (c *DirectClient) Mark(ctx context.Context, label string) (int64, error) {
	var id int64
	err := c.metaPool.QueryRow(ctx, "SELECT eter.mark($1, 'cli') AS mark", label).Scan(&id)
	return id, err
}

// Markers lists recorded markers, newest first (mirrors the TS DirectClient's
// markers(); needed by the orchestrator's GET /v1/markers).
func (c *DirectClient) Markers(ctx context.Context) ([]map[string]any, error) {
	return c.queryMaps(ctx, c.metaPool,
		"SELECT id, label, at, source FROM eter.markers ORDER BY at DESC LIMIT 100")
}

func (c *DirectClient) Status(ctx context.Context) (map[string]any, error) {
	out := map[string]any{"mode": "direct", "endpoint": c.endpoint}
	if c.metaEndpoint != "" {
		out["store_endpoint"] = c.metaEndpoint // two-DB: durable metadata store
	}

	// Readiness probe, works on a bare DB (pg_extension always exists), so a
	// connected-but-engine-missing instance reports "not ready" instead of erroring.
	// The engine ships as a SQL script (psql -f) OR as `CREATE EXTENSION eter`, so
	// don't key readiness on pg_extension, key it on the engine's core function
	// being present. eter_ssi (observe capture) IS a real extension.
	probe, err := c.queryMaps(ctx, c.pool, `
      SELECT
        to_regprocedure('eter.preview_undo(bigint)') IS NOT NULL                   AS engine_ready,
        (SELECT extversion FROM pg_extension WHERE extname='eter')                 AS engine_version,
        EXISTS(SELECT 1 FROM pg_extension WHERE extname='eter_ssi')                AS ssi,
        current_setting('eter_observe_mode', true)                                AS observe_mode,
        coalesce(nullif(current_setting('eter.capture_mode', true),''), 'trigger') AS capture_mode`)
	if err != nil {
		return nil, err
	}
	if len(probe) > 0 {
		for k, v := range probe[0] {
			out[k] = v
		}
	}
	ready, _ := out["engine_ready"].(bool)
	out["ready"] = ready
	if !ready {
		out["reason"] = "eter engine not installed (run `eter init`)"
		return out, nil
	}

	// Engine present: tracked config is in the tenant; history/undo in the store.
	tenant, err := c.queryMaps(ctx, c.pool, "SELECT count(*) AS tracked_tables FROM eter.tracked")
	if err != nil {
		return nil, err
	}
	store, err := c.queryMaps(ctx, c.metaPool, `
      SELECT
        (SELECT count(*) FROM eter.history WHERE NOT is_undo) AS changes,
        (SELECT count(DISTINCT txid) FROM eter.history WHERE NOT is_undo) AS transactions,
        (SELECT count(*) FROM eter.history WHERE is_undo) AS undo_records,
        (SELECT min(committed_at) FROM eter.history) AS earliest,
        (SELECT max(committed_at) FROM eter.history) AS latest`)
	if err != nil {
		return nil, err
	}
	if len(tenant) > 0 {
		for k, v := range tenant[0] {
			out[k] = v
		}
	}
	if len(store) > 0 {
		for k, v := range store[0] {
			out[k] = v
		}
	}
	return out, nil
}

// queryMaps runs a query and collects rows into ordered maps (jsonb columns
// decode to map[string]any, timestamps to time.Time).
func (c *DirectClient) queryMaps(ctx context.Context, pool *pgxpool.Pool, sql string, args ...any) ([]map[string]any, error) {
	rows, err := pool.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToMap)
}

func unmarshalMap(b []byte) (map[string]any, error) {
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		return nil, err
	}
	return m, nil
}

func toFloat(v any) float64 {
	switch x := v.(type) {
	case float64:
		return x
	case float32:
		return float64(x)
	case int64:
		return float64(x)
	case int32:
		return float64(x)
	case int:
		return float64(x)
	}
	return 0
}

func nullStr(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func predicateJSON(p map[string]any) any {
	if p == nil {
		return nil
	}
	b, err := json.Marshal(p)
	if err != nil {
		return nil
	}
	return string(b)
}
