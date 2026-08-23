// Daemon preflight: ensure the two prerequisites for LOSSLESS recovery are in
// place before the snapshot loop starts.
//
//  1. DDL logging ON, so every destructive DROP/TRUNCATE records its LSN in
//     eter.ddl_log; recovery replays archived WAL to just before it. The sidecar
//     can enable this itself (idempotent), so it does.
//  2. WAL archiving ON, recovery replays *archived* WAL. The sidecar cannot turn
//     archive_mode on (that needs a server restart), so it verifies and fails loudly
//     on a misconfiguration that would silently make recovery lossy.
package main

import (
	"fmt"
	"strings"
)

// archiveStatus evaluates WAL-archiving readiness for lossless recovery from the
// live server's archive_mode / wal_level and whether a WAL archive dir is
// configured. level is "ok" | "warn" | "error".
func archiveStatus(archiveMode, walLevel string, walArchiveSet bool) (level, msg string) {
	switch {
	case !walArchiveSet:
		return "warn", "ETER_WAL_ARCHIVE unset, object recovery will be backup-only; " +
			"rows written between the base backup and a drop/truncate are NOT recovered " +
			"(backups embed their own WAL via -X stream so they stay startable). " +
			"Configure a WAL archive for lossless recovery."
	case archiveMode != "on":
		return "error", fmt.Sprintf("ETER_WAL_ARCHIVE is set but archive_mode=%q (need 'on'), "+
			"WAL is not being archived, so recovery cannot replay past the base snapshot. "+
			"Set archive_mode=on + an archive_command and restart Postgres.", archiveMode)
	case walLevel == "minimal":
		return "error", "wal_level=minimal, WAL archiving/replay unavailable. " +
			"Set wal_level=replica (or higher) and restart Postgres."
	default:
		return "ok", ""
	}
}

// preflight ensures DDL logging is on and verifies WAL archiving. Panics on a hard
// archiving misconfiguration (ETER_WAL_ARCHIVE set but the server isn't archiving).
func preflight(cfg storageConfig) {
	pg := newPg(cfg)

	// Ensure DDL logging (idempotent). Best-effort: a non-superuser DSN can't install
	// event triggers, so warn rather than crash.
	if ok, out := pg.tryLiveQuery("SELECT eter.enable_ddl_logging()"); ok {
		logMsg("preflight: DDL logging ensured on", nil)
	} else {
		logMsg("preflight WARNING: could not enable DDL logging, destructive DROP/TRUNCATE "+
			"LSNs won't be recorded, so recovery falls back to snapshot-only. Enable it as the "+
			"engine owner: SELECT eter.enable_ddl_logging();", map[string]any{"err": strings.TrimSpace(out)})
	}

	// The durable bookkeeping (history, backup catalog, recovery log) exists to
	// survive the tenant having a very bad day, it must not BE in the tenant.
	if cfg.metaURL == cfg.databaseURL {
		logMsg("preflight WARNING: single-DB mode acknowledged (ETER_ALLOW_SINGLE_DB), the metadata "+
			"store IS the tenant database. Fine for dev/demo; in any real deployment point ETER_META_URL "+
			"at a separate EterDB-owned Postgres so history and the backup catalog survive tenant loss.", nil)
	}

	level, msg := archiveStatus(
		strings.TrimSpace(pg.liveQuery("SHOW archive_mode")),
		strings.TrimSpace(pg.liveQuery("SHOW wal_level")),
		cfg.walArchive != "",
	)
	switch level {
	case "ok":
		logMsg("preflight: WAL archiving on, lossless recovery available", nil)
	case "warn":
		logMsg("preflight WARNING: "+msg, nil)
	case "error":
		panic(fmt.Errorf("storage preflight: %s", msg))
	}

	// The backup dir is where every base backup is written, fail before the first
	// cycle if it can't be written, not inside it.
	if ok, out := trySh("mkdir -p " + q(cfg.backupDir) + " && touch " + q(cfg.backupDir+"/.eter_write_test") +
		" && rm -f " + q(cfg.backupDir+"/.eter_write_test")); !ok {
		panic(fmt.Errorf("storage preflight: ETER_BACKUP_DIR %s is not writable: %s", cfg.backupDir, strings.TrimSpace(out)))
	}

	// Plain-format pg_basebackup does not map user tablespaces into the backup
	// dir without per-tablespace mapping flags, recovery of objects in them
	// would fail. Warn, don't block: the default tablespaces are fine.
	if n := mustInt(pg.liveQuery(
		"SELECT count(*) FROM pg_tablespace WHERE spcname NOT IN ('pg_default','pg_global')")); n > 0 {
		logMsg("preflight WARNING: user tablespaces present, plain-format base backups don't map them; "+
			"objects stored in user tablespaces are NOT recoverable by this sidecar",
			map[string]any{"tablespaces": n})
	}
}
