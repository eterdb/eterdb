// As-of-T reads: materialize a throwaway copy of the newest base backup taken
// before T, then replay archived WAL up to recovery_target_time = T and promote.
// The copy is a real, queryable Postgres frozen at T; the live database is never
// touched.
package main

import (
	"fmt"
	"os"
)

// asOf returns the rows of query evaluated against the database as it existed at
// T (ISO timestamp). Requires a WAL archive (ETER_WAL_ARCHIVE) the base backups
// pre-date. Returns raw psql -tA output.
func asOf(cfg storageConfig, isoTime, query string) string {
	if cfg.walArchive == "" {
		panic(fmt.Errorf("storage: ETER_WAL_ARCHIVE is required for as-of-T reads"))
	}
	pg := newPg(cfg)
	bk := newBackup(cfg)

	base := pg.metaQuery(fmt.Sprintf(
		`SELECT backup_name FROM eter.storage_snapshots
		  WHERE pruned_at IS NULL AND created_at <= %s::timestamptz ORDER BY id DESC LIMIT 1`, sqlLit(isoTime)))
	if base == "" {
		panic(fmt.Errorf("storage: no base backup at or before %s", isoTime))
	}

	dir := bk.materialize(base, "asof")
	defer func() {
		pg.stopTemp(dir)
		bk.remove(dir)
	}()
	// Drive recovery to the target time, replaying WAL from the archive.
	writeRecoveryTarget(dir, cfg.walArchive, fmt.Sprintf("recovery_target_time = '%s'", isoTime))

	pg.startTemp(dir, cfg.tmpPort)
	return pg.tempQuery(dir, cfg.tmpPort, query)
}

// writeRecoveryTarget configures a restore dir for archive recovery: replay WAL
// from the archive up to targetClause (one or more recovery_target_* GUC lines,
// e.g. `recovery_target_time = '…'`, `recovery_target_lsn = '…'`, or
// `recovery_target = 'immediate'`) and promote once reached. Shared by as-of-T
// reads and object recovery, both stand a throwaway Postgres on the copy that is
// frozen at the target, so the base backup the copy came from is only a *base*
// and its age never bounds how fresh the recovered state is (the archived WAL
// fills everything after it). The archive path is double-quoted inside the
// restore_command shell line (spaces are fine); it must not contain quote
// characters.
func writeRecoveryTarget(dir, archive, targetClause string) {
	trySh("rm -f " + q(dir+"/postmaster.pid")) // stale pid from the base backup
	appendFile(dir+"/postgresql.conf", fmt.Sprintf(
		"\nrestore_command = 'cp \"%s/%%f\" \"%%p\"'\n%s\nrecovery_target_action = 'promote'\n",
		archive, targetClause))
	writeScript(dir+"/recovery.signal", "")
}

func appendFile(path, content string) {
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY|os.O_CREATE, 0o600) //nolint:gosec // path is our own WAL-archive file location
	if err != nil {
		panic(err)
	}
	defer func() { _ = f.Close() }()
	if _, err := f.WriteString(content); err != nil {
		panic(err)
	}
}
