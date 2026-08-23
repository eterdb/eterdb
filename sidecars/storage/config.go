// Storage-sidecar configuration (env-driven).
package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"

	"github.com/eterdb/eterdb/sidecars/eterclient"
)

type storageConfig struct {
	// databaseURL is the DSN of the live (tenant) DB: PK extraction, the WAL/LSN, restores.
	databaseURL string
	// metaURL is the DSN of the EterDB-owned metadata store holding durable eter
	// bookkeeping (storage_snapshots, recovery_log, and the ddl_log recovery
	// index). Required (ETER_META_URL), a SEPARATE database keeps these out of the
	// tenant DB (PLAN "Externalize durable metadata"); single-DB dev/demo must opt
	// in via ETER_ALLOW_SINGLE_DB, in which case it equals databaseURL. ddl_log is CAPTURED by
	// tenant event triggers but its durable home is the store, the capture
	// sidecar forwards it there and prunes the tenant copy, so the daemon reads
	// the destructive-DDL signal from the store (metaURL), correlated with the
	// tenant cluster's LSN/snapshots.
	metaURL string
	// backupDir holds the retained pg_basebackup base backups (one subdir per
	// backup, named base-<stamp>). The recovery substrate: plain files on any
	// filesystem, no COW, no kernel module, no privilege.
	backupDir string
	// restoreDir is the workdir where recovery materializes throwaway copies of a
	// base backup (one rec_<tag>/asof_<tag> subdir per recovery, removed after).
	// Defaults to <backupDir>/.restore.
	restoreDir string
	// walArchive is the WAL archive directory the tenant's archive_command ships
	// completed segments to. Required for lossless recovery and as-of-T reads;
	// without it recovery degrades to backup-only (writes after the base backup
	// are not recovered).
	walArchive string
	// pgOSUser, when set, wraps throwaway-server commands in sudo -u <user> and
	// chowns restore dirs, for host layouts where the sidecar runs as root but
	// postgres must not. Empty (the default, and the unprivileged-container case):
	// the sidecar and the throwaway postgres are the same OS user, no sudo.
	pgOSUser string
	// tmpPort is the base TCP-less port for throwaway recovery instances.
	tmpPort int
	// pgBinDir holds the PG binaries (pg_ctl/pg_dump/psql/pg_basebackup), if not on
	// PATH, e.g. "/usr/local/pgsql/bin" in the engine image. Must match the
	// tenant's major version (the throwaway server replays the tenant's WAL).
	pgBinDir string
	// snapshotMinWALBytes is the variable-cadence threshold: the daemon attempts a
	// base backup every interval but SKIPS it unless at least this many bytes of WAL
	// have accumulated since the last one. With WAL-replay recovery the gate bounds
	// only how much WAL a recovery replays (a speed knob), never completeness, and
	// a base backup is now a full physical copy, so the default is deliberately
	// coarse (1 GiB, vs one 16 MiB segment under ZFS-COW).
	snapshotMinWALBytes int64
	// maxBackupAgeHours forces a scheduled base backup once the newest one is older
	// than this even below the WAL gate, so low-write databases don't accumulate
	// unboundedly long replay chains. 0 disables.
	maxBackupAgeHours int
	// retainCount, when >0, prunes middle base backups keeping the oldest (the
	// anchor of the whole recovery horizon) + the N newest. Never touches WAL.
	// 0 (default) retains every backup.
	retainCount int
	// horizonDays, when >0, is the explicit opt-out of infinite recovery depth:
	// backups are pruned oldest-first while at least one backup at-or-before
	// now()-horizon remains, then archived WAL older than the oldest retained
	// backup's first needed segment is removed (pg_archivecleanup). 0 (default)
	// retains everything, months-old restore always works.
	horizonDays int
	// recoveryTimeoutSec bounds how long a throwaway instance may take to finish
	// WAL replay and leave recovery. Replay from an aged base is legitimately
	// slower than a COW clone's crash recovery ever was.
	recoveryTimeoutSec int
}

func loadConfig() storageConfig {
	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		panic(fmt.Errorf("storage sidecar: DATABASE_URL is required"))
	}
	backupDir := os.Getenv("ETER_BACKUP_DIR")
	if backupDir == "" {
		panic(fmt.Errorf("storage sidecar: ETER_BACKUP_DIR is required (e.g. /var/lib/eter/backups)"))
	}
	backupDir = strings.TrimSuffix(backupDir, "/")
	// The durable bookkeeping (backup catalog, recovery log, ddl_log index) exists
	// to survive the tenant having a very bad day, it must NOT be in the tenant.
	// ETER_META_URL is a hard requirement (issue #67); single-DB dev/demo opts in
	// explicitly via ETER_ALLOW_SINGLE_DB.
	metaURL, _, err := eterclient.RequireMetaURL(databaseURL)
	if err != nil {
		panic(fmt.Errorf("storage sidecar: %w", err))
	}
	restoreDir := os.Getenv("ETER_RESTORE_DIR")
	if restoreDir == "" {
		restoreDir = backupDir + "/.restore"
	}
	return storageConfig{
		databaseURL: databaseURL,
		metaURL:     metaURL,
		backupDir:   backupDir,
		restoreDir:  strings.TrimSuffix(restoreDir, "/"),
		walArchive:  strings.TrimSuffix(os.Getenv("ETER_WAL_ARCHIVE"), "/"),
		pgOSUser:    os.Getenv("ETER_PG_OS_USER"),
		tmpPort:     envInt("ETER_TMP_PORT", 5599),
		pgBinDir:    os.Getenv("ETER_PG_BINDIR"),
		// 1 GiB: bounds recovery replay time, not completeness.
		snapshotMinWALBytes: envInt64("ETER_SNAPSHOT_MIN_WAL_BYTES", 1024*1024*1024),
		maxBackupAgeHours:   envInt("ETER_BACKUP_MAX_AGE_HOURS", 24),
		retainCount:         envInt("ETER_BACKUP_RETAIN_COUNT", 0),
		horizonDays:         envInt("ETER_BACKUP_HORIZON_DAYS", 0),
		recoveryTimeoutSec:  envInt("ETER_RECOVERY_TIMEOUT_SEC", 300),
	}
}

func envInt(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

func envInt64(key string, def int64) int64 {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil {
			return n
		}
	}
	return def
}
