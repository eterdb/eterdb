// EterDB orchestrator (eter-orchestrator), the single HTTP entry point for the
// eter CLI, and the manager for long-running storage operations.
//
// It serves the same /v1/* wire protocol the (retired) TS eter-server spoke,
// so the CLI's hosted transport works unchanged (`eter connect --url …`), and
// adds an async job subsystem for the storage sidecar's minutes-long PITR
// restores: POST /v1/storage/* enqueues a job, GET /v1/jobs/{id} reports it,
// one serial runner lane executes them (restores are full-copy IO bursts,
// serializing is the correct behavior, and it makes throwaway-port collisions
// impossible). It also schedules the storage maintenance loop (`eter-storage
// cycle`) through that same lane, replacing `eter-storage daemon` in
// orchestrated deployments, run one or the other, never both.
//
// Engine work (preview/undo/cohort/…) is delegated to the shared
// eterclient.DirectClient (tenant + meta-store pools); storage work is
// delegated to the eter-storage binary. The orchestrator itself owns only the
// HTTP surface, the job queue (eter.jobs in the meta store), and scheduling.
package main

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/eterdb/eterdb/sidecars/eterclient"
)

type orchConfig struct {
	databaseURL string // tenant DSN (required)
	metaURL     string // meta-store DSN (ETER_META_URL, required; tenant only under ETER_ALLOW_SINGLE_DB)
	host        string
	port        int
	apiToken    string // optional bearer token guarding /v1/*
	storageBin  string // eter-storage binary (PATH or absolute)
	// scheduleIntervalSec drives the storage maintenance loop (eter-storage
	// cycle) through the job lane; 0 disables (then run `eter-storage daemon`
	// yourself, or no scheduled backups happen).
	scheduleIntervalSec int
	// jobTimeoutSec bounds one job/cycle execution (ETER_JOB_TIMEOUT_SEC,
	// default 1h; 0 = unbounded). Without it a hung pg_basebackup wedges the
	// single-flight lane forever while the heartbeat keeps the job looking
	// healthy, every later job queues and scheduled backups silently stop.
	jobTimeoutSec int
	tmpPortBase   int    // per-job throwaway-postgres port base
	backupDir     string // ETER_BACKUP_DIR, required for storage jobs, not for the API
	restoreDir    string // per-job restore workdirs go under here
	pgBinDir      string // for stopping orphaned throwaway postmasters
}

func loadOrchConfig() (orchConfig, error) {
	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		return orchConfig{}, fmt.Errorf("orchestrator: DATABASE_URL is required")
	}
	// The job queue + durable metadata are in the store, which must NOT be the
	// tenant DB, ETER_META_URL is a hard requirement (issue #67); single-DB
	// dev/demo opts in explicitly via ETER_ALLOW_SINGLE_DB.
	metaURL, _, err := eterclient.RequireMetaURL(dbURL)
	if err != nil {
		return orchConfig{}, fmt.Errorf("orchestrator: %w", err)
	}
	backupDir := strings.TrimSuffix(os.Getenv("ETER_BACKUP_DIR"), "/")
	restoreDir := strings.TrimSuffix(os.Getenv("ETER_RESTORE_DIR"), "/")
	if restoreDir == "" && backupDir != "" {
		restoreDir = backupDir + "/.restore"
	}
	return orchConfig{
		databaseURL:         dbURL,
		metaURL:             metaURL,
		host:                envOr("ETER_HOST", "0.0.0.0"),
		port:                envInt("ETER_PORT", 4400),
		apiToken:            os.Getenv("ETER_API_TOKEN"),
		storageBin:          envOr("ETER_STORAGE_BIN", "eter-storage"),
		scheduleIntervalSec: envInt("ETER_SCHEDULE_INTERVAL_SEC", 30),
		jobTimeoutSec:       envInt("ETER_JOB_TIMEOUT_SEC", 3600),
		tmpPortBase:         envInt("ETER_TMP_PORT", 5599),
		backupDir:           backupDir,
		restoreDir:          restoreDir,
		pgBinDir:            os.Getenv("ETER_PG_BINDIR"),
	}, nil
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func envInt(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

func logMsg(msg string, extra map[string]any) {
	line := map[string]any{"ts": time.Now().UTC().Format(time.RFC3339Nano), "comp": "orchestrator", "msg": msg}
	for k, v := range extra {
		line[k] = v
	}
	b, _ := jsonMarshal(line)
	_, _ = os.Stderr.Write(append(b, '\n'))
}

func main() {
	cfg, err := loadOrchConfig()
	if err != nil {
		logMsg("fatal", map[string]any{"err": err.Error()})
		os.Exit(1)
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// Engine client: the same two-pool DirectClient the CLI's direct mode uses.
	client, err := eterclient.NewDirectClient(ctx, cfg.databaseURL)
	if err != nil {
		logMsg("fatal: cannot connect the engine client", map[string]any{"err": err.Error()})
		os.Exit(1)
	}
	defer client.Close()

	// The job store gets its own meta pool (the DDL + queue are in the store).
	metaPool, err := pgxpool.New(ctx, cfg.metaURL)
	if err != nil {
		logMsg("fatal: cannot connect the meta store", map[string]any{"err": err.Error()})
		os.Exit(1)
	}
	defer metaPool.Close()
	store := &pgJobStore{pool: metaPool}
	if err := store.ensureSchema(ctx); err != nil {
		logMsg("fatal: cannot ensure eter.jobs schema", map[string]any{"err": err.Error()})
		os.Exit(1)
	}

	// Crash recovery BEFORE accepting work: fail orphaned running jobs, sweep
	// leftover restore dirs (incl. their throwaway postmasters).
	bootRecover(ctx, cfg, store)

	// Storage preflight (DDL logging on + WAL archiving verified). Orchestrated
	// deployments replace `eter-storage daemon`, which used to be the only
	// thing that ran preflight, so without this, destructive-DDL LSNs would
	// never be recorded and recovery would silently degrade to backup-only.
	// Async: an API-only boot must not block on it, and the scheduled cycle
	// re-runs preflight anyway.
	if cfg.backupDir != "" {
		go bootPreflight(ctx, cfg)
	}

	run := newRunner(cfg, store)
	go run.loop(ctx)
	if cfg.scheduleIntervalSec > 0 {
		go scheduleLoop(ctx, cfg, run)
	}

	srv := &http.Server{
		Addr:    fmt.Sprintf("%s:%d", cfg.host, cfg.port),
		Handler: newServer(cfg, client, store, run).routes(),
		// Bound how long a client may take to send request headers, so a slow
		// (or malicious, Slowloris-style) peer cannot pin a connection open.
		ReadHeaderTimeout: 10 * time.Second,
	}
	go func() {
		<-ctx.Done()
		// Stop accepting; cancel any running job (a human resubmits, simpler
		// than draining a minutes-long restore on shutdown).
		run.cancelRunning("orchestrator shutting down")
		shCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(shCtx)
	}()
	if cfg.metaURL == cfg.databaseURL {
		logMsg("WARNING: single-DB mode acknowledged (ETER_ALLOW_SINGLE_DB), the metadata store "+
			"IS the tenant database. Fine for dev/demo; in any real deployment point ETER_META_URL "+
			"at a separate EterDB-owned Postgres so history and the backup catalog survive tenant loss.", nil)
	}
	logMsg("orchestrator listening", map[string]any{
		"addr": srv.Addr, "meta_separate": cfg.metaURL != cfg.databaseURL,
		"schedule_interval_sec": cfg.scheduleIntervalSec, "storage_configured": cfg.backupDir != ""})
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		logMsg("fatal: listen", map[string]any{"err": err.Error()})
		os.Exit(1)
	}
	run.awaitIdle(10 * time.Second)
}
