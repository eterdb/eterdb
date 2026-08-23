// Boot-time crash recovery. A single orchestrator owns the runner lane, so any
// job still marked `running` at boot is an orphan from a previous instance,
// fail it truthfully (a waiting CLI poller then exits with the real story
// instead of hanging). Restore dirs left behind by a killed job still hold a
// full data-dir copy and possibly a live throwaway postmaster: stop the
// postmaster FIRST (by pidfile), then remove the dir.
package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

func bootRecover(ctx context.Context, cfg orchConfig, store jobStore) {
	if n, err := store.FailOrphans(ctx, "orchestrator restarted during execution"); err != nil {
		logMsg("boot: failing orphaned jobs errored", map[string]any{"err": err.Error()})
	} else if n > 0 {
		logMsg("boot: failed orphaned running jobs", map[string]any{"count": n})
	}
	sweepAllRestoreDirs(cfg)
}

// sweepAllRestoreDirs removes leftover restore workdirs under restoreDir,
// ONLY the orchestrator's own job-* dirs (each job's sidecar debris lives
// inside its job-<id> dir). Top-level rec_*/asof_* dirs belong to a
// manually-run `eter-storage recover-*`, which may be legitimately in flight
// while the orchestrator (re)starts, sweeping those would kill its throwaway
// postmaster mid-replay, so they are left to the operator.
func sweepAllRestoreDirs(cfg orchConfig) {
	if cfg.restoreDir == "" {
		return
	}
	entries, err := os.ReadDir(cfg.restoreDir)
	if err != nil {
		return // no restore dir yet, nothing to sweep
	}
	for _, e := range entries {
		if e.IsDir() && strings.HasPrefix(e.Name(), "job-") {
			sweepRestoreDir(cfg, filepath.Join(cfg.restoreDir, e.Name()))
		}
	}
}

// sweepRestoreDir stops any throwaway postmaster still running on dir, then
// removes it. Best-effort, a failed sweep never masks a job result.
func sweepRestoreDir(cfg orchConfig, dir string) {
	if _, err := os.Stat(dir); err != nil {
		return
	}
	stopPostmaster(cfg, dir)
	if err := os.RemoveAll(dir); err != nil {
		logMsg("sweep: could not remove restore dir", map[string]any{"dir": dir, "err": err.Error()})
	} else {
		logMsg("sweep: removed restore dir", map[string]any{"dir": dir})
	}
}

// stopPostmaster ends a throwaway postgres on dir: pg_ctl -m immediate when
// available, else SIGKILL the pid from postmaster.pid.
func stopPostmaster(cfg orchConfig, dir string) {
	pidFile := filepath.Join(dir, "postmaster.pid")
	b, err := os.ReadFile(pidFile) //nolint:gosec // pidFile is inside our own throwaway restore dir
	if err != nil {
		return // no pidfile, nothing running
	}
	pgCtl := "pg_ctl"
	if cfg.pgBinDir != "" {
		pgCtl = strings.TrimSuffix(cfg.pgBinDir, "/") + "/pg_ctl"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	//nolint:gosec // pgCtl is the configured pg_ctl; dir is our own restore workdir
	if err := exec.CommandContext(ctx, pgCtl, "-D", dir, "-m", "immediate", "stop").Run(); err == nil {
		return
	}
	// pg_ctl unavailable or refused, kill the process group leader directly.
	lines := strings.SplitN(string(b), "\n", 2)
	if pid, perr := strconv.Atoi(strings.TrimSpace(lines[0])); perr == nil && pid > 1 {
		_ = syscall.Kill(pid, syscall.SIGKILL)
		logMsg("sweep: killed orphaned postmaster", map[string]any{"dir": dir, "pid": pid})
	} else if err != nil {
		logMsg("sweep: could not stop postmaster", map[string]any{"dir": dir, "err": fmt.Sprint(err)})
	}
}
