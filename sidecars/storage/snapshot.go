// Take a retained base backup of the live tenant and record it (with the WAL
// LSN it captures) so object recovery can pick the newest backup before a
// destructive change and replay archived WAL forward from it.
package main

import (
	"fmt"
	"strings"
	"time"
)

func takeSnapshot(cfg storageConfig, kind string) string {
	pg := newPg(cfg)
	bk := newBackup(cfg)
	// With a WAL archive the backup runs -X none, and the SERVER's backup-stop
	// then blocks until the end-of-backup segment is archived, with a dead
	// archiver, pg_basebackup hangs indefinitely (found by
	// test/storage-lifecycle.sh: not even the post-backup discard path is
	// reached). Probe the archiver FIRST so a down archiver fails the snapshot
	// loudly in ~60s instead. An archiver that dies mid-backup can still hang
	// pg_basebackup, in orchestrated deployments ETER_JOB_TIMEOUT_SEC bounds
	// that; standalone operators see the hang in pg_stat_archiver.
	if cfg.walArchive != "" {
		cur := strings.TrimSpace(pg.liveQuery("SELECT pg_current_wal_lsn()"))
		if !ensureArchivedThrough(cfg, cur) {
			panic(fmt.Errorf("storage: the WAL archiver is not shipping segments (check archive_command / pg_stat_archiver), " +
				"refusing to start a backup: pg_basebackup would block forever waiting for archival, and the result could never be restored"))
		}
	}
	stamp := strings.NewReplacer(":", "-", ".", "-").Replace(time.Now().UTC().Format("2006-01-02T15:04:05.000Z"))
	name := "base-" + stamp
	// The recorded LSN is the backup's END (stop) LSN: a base backup can only serve
	// recovery targets at/after its consistency point, so pickSnapshot's
	// lsn <= target predicate is exact with it.
	endLSN, walStart := bk.create(name)
	// Snapshot catalog is the sidecar's own bookkeeping → the metadata store. The
	// LSN it records belongs to the tenant cluster's WAL.
	pg.metaQuery(fmt.Sprintf(
		`INSERT INTO eter.storage_snapshots (backup_name, lsn, wal_start, kind) VALUES (%s, %s::pg_lsn, %s, %s)`,
		sqlLit(name), sqlLit(endLSN), sqlLit(walStart), sqlLit(kind)))
	return name
}

// scheduledSnapshot is the daemon's per-interval base backup with variable
// cadence: it backs up only when enough WAL has accumulated since the last one
// (a base backup is a full physical copy now, not a free COW snapshot), otherwise
// skips (returns ""). Safe because object recovery replays WAL forward from the
// base, a skipped interval never loses recoverable state, it just means a future
// recovery replays a little more WAL. The first backup (no prior base) is always
// taken, and a backup older than maxBackupAgeHours forces one even below the WAL
// gate so low-write databases don't accumulate unboundedly long replay chains.
func scheduledSnapshot(cfg storageConfig, minWALBytes int64) string {
	pg := newPg(cfg)
	// Latest recorded backup LSN/age come from the store; the WAL diff is computed
	// on the tenant cluster (that's whose WAL the LSN belongs to).
	last := pg.metaQuery(
		"SELECT coalesce((SELECT lsn::text FROM eter.storage_snapshots WHERE lsn IS NOT NULL AND pruned_at IS NULL ORDER BY id DESC LIMIT 1), '')")
	var walBytes int64
	if last != "" {
		walBytes = int64(mustInt(pg.liveQuery(fmt.Sprintf(
			"SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), %s::pg_lsn)::bigint", sqlLit(last)))))
	}
	aged := false
	if last != "" && cfg.maxBackupAgeHours > 0 {
		aged = pg.metaQuery(fmt.Sprintf(
			`SELECT (max(created_at) < now() - interval '%d hours')::text
			   FROM eter.storage_snapshots WHERE pruned_at IS NULL`, cfg.maxBackupAgeHours)) == "true"
	}
	if !shouldSnapshotWAL(walBytes, minWALBytes, last != "") && !aged {
		logMsg("skipping scheduled backup, below WAL threshold",
			map[string]any{"walBytes": walBytes, "minWALBytes": minWALBytes, "sinceLSN": last})
		return ""
	}
	name := takeSnapshot(cfg, "scheduled")
	logMsg("scheduled backup taken", map[string]any{"backup": name, "walBytes": walBytes, "aged": aged})
	return name
}

// shouldSnapshotWAL decides whether a scheduled backup is warranted: always when
// there is no prior base to build on, otherwise only once WAL accumulation since
// the last backup reaches the threshold.
func shouldSnapshotWAL(walBytesSince, minWALBytes int64, hasPrior bool) bool {
	return !hasPrior || walBytesSince >= minWALBytes
}

// pickSnapshot returns the newest recorded (unpruned) base backup, optionally
// constrained to one usable for recovery targets at/before an LSN (e.g. a
// destructive DDL's snapshot_lsn from eter.ddl_log).
func pickSnapshot(cfg storageConfig, beforeLSN string) string {
	pg := newPg(cfg)
	where := "WHERE pruned_at IS NULL"
	if beforeLSN != "" {
		where += fmt.Sprintf(" AND (lsn IS NULL OR lsn <= %s::pg_lsn)", sqlLit(beforeLSN))
	}
	name := pg.metaQuery(fmt.Sprintf(
		"SELECT backup_name FROM eter.storage_snapshots %s ORDER BY id DESC LIMIT 1", where))
	if name == "" {
		panic(fmt.Errorf("storage: no base backup available to recover from"))
	}
	return name
}
