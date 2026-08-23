// Object-level recovery: what a trigger/CDC oracle can never do. Materialize a
// throwaway copy of the base backup taken before the destructive change, replay
// archived WAL to just before it, stand a throwaway Postgres on the copy, extract
// the lost object, and restore it into the live database, then throw the copy
// away. No tombstones, no rewriting the live schema.
package main

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

func randTag() string {
	b := make([]byte, 4)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

// qi quotes an SQL identifier (column/relation names from real schemas may be
// mixed-case or reserved, e.g. InvenTree's "IPN"). Object identifiers (ident)
// themselves are deliberately interpolated into SQL/psql scripts as-is: they
// come from the operator's own command line, and the operator already holds
// the DSN, qi exists for real-world column names, not as an injection
// boundary.
func qi(s string) string { return `"` + strings.ReplaceAll(s, `"`, `""`) + `"` }

// requirePK fails a PK-dependent recovery early with an actionable message
// instead of letting an empty column list surface as a Postgres syntax error
// (e.g. `ON CONFLICT () DO NOTHING`).
func requirePK(pk []col, ident, purpose string) {
	if len(pk) == 0 {
		panic(fmt.Errorf("storage: %s has no primary key; cannot %s", ident, purpose))
	}
}

// withRestore materializes a throwaway copy of base backup snap, stands a
// throwaway Postgres on it, and runs fn against that copy. When replayToLSN is
// non-empty AND a WAL archive is configured, the copy is driven forward by
// archive recovery to just BEFORE that LSN (the destructive DDL's LSN,
// recovery_target_inclusive=off) and promoted, so the object is extracted as it
// was one instant before the drop, regardless of how stale the base backup is.
// With an archive but no replay target (explicit-snapshot recovery) it recovers
// to the backup's own consistency point (recovery_target='immediate'), an
// archive-configured backup carries no WAL of its own (-X none), so archive
// recovery is mandatory for it to start at all. Without a WAL archive the backup
// is self-contained (-X stream) and comes up frozen at the backup (rows written
// between the backup and the drop are then unrecoverable, the staleness the
// daemon warns of).
func withRestore(cfg storageConfig, snap, replayToLSN string, fn func(pg *pgT, dir string, port int) int) int {
	bk := newBackup(cfg)
	pg := newPg(cfg)
	dir := bk.materialize(snap, "rec")
	defer func() {
		pg.stopTemp(dir)
		bk.remove(dir)
	}()
	if cfg.walArchive != "" {
		target := "recovery_target = 'immediate'"
		if replayToLSN != "" {
			// The drop/truncate we replay to may sit in the current, not-yet-archived
			// WAL segment (archive_command only ships COMPLETED segments). Force a
			// switch + wait so the copy can actually fetch WAL up to the target,
			// otherwise its recovery never reaches the target and it fails to start.
			ensureArchivedThrough(cfg, replayToLSN)
			logMsg("replaying WAL to just before drop", map[string]any{"base": snap, "targetLSN": replayToLSN})
			target = fmt.Sprintf("recovery_target_lsn = '%s'\nrecovery_target_inclusive = off", replayToLSN)
		}
		writeRecoveryTarget(dir, cfg.walArchive, target)
	} else if replayToLSN != "" {
		logMsg("no ETER_WAL_ARCHIVE: recovering as-of the base backup; writes after it and before the drop are NOT recovered",
			map[string]any{"base": snap})
	}
	pg.startTemp(dir, cfg.tmpPort)
	return fn(pg, dir, cfg.tmpPort)
}

func logRecovery(pg *pgT, ident, typ, snap string, rows int) {
	// Recovery audit is the sidecar's own bookkeeping → the metadata store.
	pg.metaQuery(fmt.Sprintf(
		`INSERT INTO eter.recovery_log (object_identity, object_type, from_snapshot, restored_rows)
		 VALUES (%s, %s, %s, %d)`,
		sqlLit(ident), sqlLit(typ), sqlLit(snap), rows))
}

// recoverTable recovers a dropped (or truncated) table: dump it from the
// restored copy, restore to live.
func recoverTable(cfg storageConfig, ident, fromSnap string) (int, string) {
	snap, replayLSN := pickForRecovery(cfg, fromSnap, ident, "")
	return withRestore(cfg, snap, replayLSN, func(pg *pgT, dir string, port int) int {
		dump := fmt.Sprintf("/tmp/eter_rec_%s.sql", randTag())
		defer func() { _ = os.Remove(dump) }()
		pg.dumpTable(dir, port, ident, dump)
		stripEterTriggers(dump)
		pg.liveScript(dump)
		rows := mustInt(pg.liveQuery("SELECT count(*) FROM " + ident))
		logRecovery(pg, ident, "table", snap, rows)
		return rows
	}), snap
}

// recoverRows restores truncated rows into a still-present table without
// disturbing rows written after the truncate: dump the restored copy into a
// staging table and INSERT only the primary keys that are now missing.
func recoverRows(cfg storageConfig, ident, fromSnap string) (int, string) {
	// TRUNCATE records its LSN in eter.ddl_log (_log_ddl_end), so, like a drop,
	// restore the base backup at/before it and replay WAL to just before the
	// truncate: the copy then holds every pre-truncate row, INCLUDING ones written
	// after the base backup. ON CONFLICT DO NOTHING keeps post-truncate writes.
	snap, replayLSN := pickForRecoveryTruncate(cfg, fromSnap, ident)
	return withRestore(cfg, snap, replayLSN, func(pg *pgT, dir string, port int) int {
		pk := pkColumns(pg, dir, port, ident)
		requirePK(pk, ident, "restore rows without clobbering post-truncate writes (dedupe is by PK)")
		cols := allColumns(pg, dir, port, ident)
		csv := fmt.Sprintf("/tmp/eter_rows_%s.csv", randTag())
		defer func() { _ = os.Remove(csv) }()
		selCols := make([]string, len(cols))
		for i, c := range cols {
			selCols[i] = qi(c.name)
		}
		pg.copyOut(dir, port, fmt.Sprintf("SELECT %s FROM %s", strings.Join(selCols, ","), ident), csv)

		stageCols := make([]string, len(cols))
		for i, c := range cols {
			stageCols[i] = qi(c.name) + " " + c.typ
		}
		onConflict := make([]string, len(pk))
		for i, c := range pk {
			onConflict[i] = qi(c.name)
		}
		script := fmt.Sprintf("/tmp/eter_rows_%s.sql", randTag())
		defer func() { _ = os.Remove(script) }()
		writeScript(script, fmt.Sprintf(`BEGIN;
CREATE TEMP TABLE _eter_stage (%s);
\copy _eter_stage FROM '%s' CSV
INSERT INTO %s SELECT * FROM _eter_stage
  ON CONFLICT (%s) DO NOTHING;
COMMIT;
`, strings.Join(stageCols, ", "), csv, ident, strings.Join(onConflict, ",")))
		pg.liveScript(script)
		rows := mustInt(pg.liveQuery("SELECT count(*) FROM " + ident))
		logRecovery(pg, ident, "rows", snap, rows)
		return rows
	}), snap
}

// recoverColumn recovers a dropped column: re-add it, then restore each row's
// value (matched by primary key) from the restored copy. Rows inserted after the
// drop simply stay NULL.
func recoverColumn(cfg storageConfig, ident, column, fromSnap string) (int, string) {
	snap, replayLSN := pickForRecovery(cfg, fromSnap, ident, column)
	return withRestore(cfg, snap, replayLSN, func(pg *pgT, dir string, port int) int {
		colType := pg.tempQuery(dir, port, fmt.Sprintf(
			`SELECT format_type(atttypid, atttypmod) FROM pg_attribute
			  WHERE attrelid = %s::regclass AND attname = %s AND NOT attisdropped`,
			sqlLit(ident), sqlLit(column)))
		if colType == "" {
			panic(fmt.Errorf("storage: column %s.%s not found in snapshot %s", ident, column, snap))
		}
		pk := pkColumns(pg, dir, port, ident)
		requirePK(pk, ident, "match rows to repopulate the column")

		csv := fmt.Sprintf("/tmp/eter_col_%s.csv", randTag())
		script := fmt.Sprintf("/tmp/eter_col_%s.sql", randTag())
		defer func() { _ = os.Remove(csv) }()
		defer func() { _ = os.Remove(script) }()

		selParts := make([]string, 0, len(pk)+1)
		for _, c := range pk {
			selParts = append(selParts, qi(c.name))
		}
		selParts = append(selParts, qi(column))
		pg.copyOut(dir, port, fmt.Sprintf("SELECT %s FROM %s", strings.Join(selParts, ", "), ident), csv)

		stageParts := make([]string, 0, len(pk)+1)
		for _, c := range pk {
			stageParts = append(stageParts, qi(c.name)+" "+c.typ)
		}
		stageParts = append(stageParts, qi(column)+" "+colType)
		joinPreds := make([]string, len(pk))
		for i, c := range pk {
			joinPreds[i] = fmt.Sprintf("t.%s = s.%s", qi(c.name), qi(c.name))
		}
		writeScript(script, fmt.Sprintf(`BEGIN;
ALTER TABLE %s ADD COLUMN IF NOT EXISTS %s %s;
CREATE TEMP TABLE _eter_stage (%s);
\copy _eter_stage FROM '%s' CSV
UPDATE %s t SET %s = s.%s FROM _eter_stage s WHERE %s;
COMMIT;
`, ident, qi(column), colType, strings.Join(stageParts, ", "), csv,
			ident, qi(column), qi(column), strings.Join(joinPreds, " AND ")))
		pg.liveScript(script)
		rows := mustInt(pg.liveQuery(fmt.Sprintf("SELECT count(*) FROM %s WHERE %s IS NOT NULL", ident, qi(column))))
		logRecovery(pg, ident, "column", snap, rows)
		return rows
	}), snap
}

type col struct {
	name string
	typ  string
}

func pkColumns(pg *pgT, dir string, port int, ident string) []col {
	return parseCols(pg.tempQuery(dir, port, fmt.Sprintf(
		`SELECT a.attname || chr(9) || format_type(a.atttypid, a.atttypmod)
		   FROM pg_index i JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
		  WHERE i.indrelid = %s::regclass AND i.indisprimary
		  ORDER BY array_position(i.indkey, a.attnum)`, sqlLit(ident))))
}

func allColumns(pg *pgT, dir string, port int, ident string) []col {
	return parseCols(pg.tempQuery(dir, port, fmt.Sprintf(
		`SELECT attname || chr(9) || format_type(atttypid, atttypmod)
		   FROM pg_attribute WHERE attrelid = %s::regclass AND attnum > 0 AND NOT attisdropped
		  ORDER BY attnum`, sqlLit(ident))))
}

func parseCols(out string) []col {
	var cols []col
	for _, l := range strings.Split(out, "\n") {
		if l == "" {
			continue
		}
		parts := strings.SplitN(l, "\t", 2)
		c := col{name: parts[0]}
		if len(parts) > 1 {
			c.typ = parts[1]
		}
		cols = append(cols, c)
	}
	return cols
}

// destructiveLSN finds the tenant-WAL LSN recorded for the most recent destructive
// event matching whereExtra (an eter.ddl_log predicate) against target (its quote-
// stripped object_identity). Object recovery must restore the backup taken BEFORE
// the event, "newest backup" is wrong on a live system whose storage daemon
// backs up on a timer and may have taken one AFTER it. Identity match strips
// quoting so camel-case Twenty columns (e.g. "closeDate") compare cleanly.
//
// The durable home is the store (the capture sidecar's forwarder ships ddl_log there
// and prunes the tenant copy), so prefer it. Fall back to the TENANT ddl_log for rows
// not yet forwarded, the pre-forward window, or a deployment running the storage
// sidecar without the capture forwarder. Both carry the same snapshot_lsn, which is
// the timeline recovery replays. (Single-DB: metaURL == databaseURL, so the first
// read already covers it.) Returns "" if no such event is recorded.
func destructiveLSN(cfg storageConfig, whereExtra, target string) string {
	pg := newPg(cfg)
	query := fmt.Sprintf(
		`SELECT coalesce((
		   SELECT snapshot_lsn::text FROM eter.ddl_log
		    WHERE is_destructive AND %s AND replace(object_identity, '"', '') = %s
		    ORDER BY id DESC LIMIT 1), '')`,
		whereExtra, sqlLit(target))
	if lsn := pg.metaQuery(query); lsn != "" {
		return lsn
	}
	return pg.liveQuery(query)
}

// dropSnapshotLSN resolves the LSN of the most recent DROP of ident (a column drop
// when column != "", else a table drop). Table drops filter command_tag='DROP TABLE'
// so a TRUNCATE (also object_type='table', is_destructive) is never mistaken for one.
func dropSnapshotLSN(cfg storageConfig, ident, column string) string {
	if column != "" {
		return destructiveLSN(cfg, "object_type = 'table column'", ident+"."+column)
	}
	return destructiveLSN(cfg, "object_type = 'table' AND command_tag = 'DROP TABLE'", ident)
}

// truncateLSN resolves the LSN of the most recent TRUNCATE of ident.
func truncateLSN(cfg storageConfig, ident string) string {
	return destructiveLSN(cfg, "command_tag = 'TRUNCATE TABLE'", ident)
}

// pickForRecovery resolves how to recover a dropped object: the base backup to
// restore, and the LSN to replay archived WAL forward to (empty = none). With no
// explicit snapshot it reads the object's recorded destructive-DROP LSN and
// returns (newest snapshot at/before that LSN, that LSN), so withRestore can
// replay to just before the drop, making the base snapshot's age irrelevant to
// data completeness. Falls back to the newest snapshot with no replay LSN when
// the DROP wasn't logged. An explicit snapshot recovers exactly at that snapshot
// (no replay), the caller override.
func pickForRecovery(cfg storageConfig, fromSnap, ident, column string) (snap, replayLSN string) {
	if fromSnap != "" {
		return fromSnap, ""
	}
	replayLSN = dropSnapshotLSN(cfg, ident, column)
	return pickSnapshot(cfg, replayLSN), replayLSN
}

// pickForRecoveryTruncate is pickForRecovery for row recovery: the base snapshot and
// the TRUNCATE LSN to replay archived WAL forward to. Falls back to the newest
// snapshot with no replay LSN when the truncate wasn't logged (DDL logging off).
func pickForRecoveryTruncate(cfg storageConfig, fromSnap, ident string) (snap, replayLSN string) {
	if fromSnap != "" {
		return fromSnap, ""
	}
	replayLSN = truncateLSN(cfg, ident)
	return pickSnapshot(cfg, replayLSN), replayLSN
}

// stripEterTriggers removes CREATE TRIGGER statements for EterDB-managed triggers
// (eter_* names) from a pg_dump file. The live engine re-attaches these
// automatically, e.g. eter_truncate_log via the DDL-logging event trigger when the
// recovered table's CREATE TABLE replays, so keeping the dumped copy would collide
// ("trigger ... already exists").
func stripEterTriggers(file string) {
	b, err := os.ReadFile(file) //nolint:gosec // file is a dump we just wrote to our own scratch dir
	if err != nil {
		panic(err)
	}
	lines := strings.Split(string(b), "\n")
	out := lines[:0]
	for _, ln := range lines {
		if strings.HasPrefix(strings.TrimSpace(ln), "CREATE TRIGGER eter_") {
			continue
		}
		out = append(out, ln)
	}
	//nolint:gosec // file is our own scratch dump path, not user-supplied
	if err := os.WriteFile(file, []byte(strings.Join(out, "\n")), 0o600); err != nil {
		panic(err)
	}
}

// ensureArchivedThrough forces the tenant to archive WAL through the segment that
// holds targetLSN, so a WAL-replay recovery instance can reach it. archive_command
// only ships COMPLETED segments, so a drop/truncate that just happened sits in the
// current (open) segment; without a switch the restore can't fetch WAL up to the
// target and its recovery never starts. Returns whether the segment is confirmed
// in the archive; trivially true when no archive is configured (nothing to ship).
func ensureArchivedThrough(cfg storageConfig, targetLSN string) bool {
	if targetLSN == "" || cfg.walArchive == "" {
		return true
	}
	pg := newPg(cfg)
	seg := strings.TrimSpace(pg.liveQuery(fmt.Sprintf("SELECT pg_walfile_name(%s::pg_lsn)", sqlLit(targetLSN))))
	if archivedAtOrPast(pg, seg) {
		return true
	}
	pg.liveQuery("SELECT pg_switch_wal()")
	for i := 0; i < 120; i++ { // up to ~60s for the archiver to ship the switched segment
		if archivedAtOrPast(pg, seg) {
			return true
		}
		time.Sleep(500 * time.Millisecond)
	}
	logMsg("WARNING: recovery-target WAL segment not archived yet, recovery may fail",
		map[string]any{"segment": seg, "targetLSN": targetLSN})
	return false
}

// archivedAtOrPast reports whether the tenant's archiver has shipped a WAL segment
// at or beyond seg. WAL filenames on one timeline sort lexicographically by LSN.
func archivedAtOrPast(pg *pgT, seg string) bool {
	last := strings.TrimSpace(pg.liveQuery("SELECT coalesce(last_archived_wal, '') FROM pg_stat_archiver"))
	return last != "" && last >= seg
}

func writeScript(path, content string) {
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		panic(err)
	}
}

func mustInt(s string) int {
	n, err := strconv.Atoi(strings.TrimSpace(s))
	if err != nil {
		return 0
	}
	return n
}
