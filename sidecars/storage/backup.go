// Base-backup primitives, the temporal storage substrate. Plain pg_basebackup
// directories + the archived WAL between them; recovery materializes a throwaway
// copy and replays WAL to the target (standard PITR). No COW filesystem, no
// kernel module, no privilege, runs in an unprivileged container. (ADR 0003;
// replaces the ZFS-COW substrate.)
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"regexp"
)

type backupT struct {
	cfg storageConfig
}

func newBackup(cfg storageConfig) *backupT { return &backupT{cfg: cfg} }

// create takes a base backup of the live tenant into <backupDir>/<name> and
// returns the backup's end (stop) LSN, the earliest point a recovery from this
// base can target, plus the first WAL segment it needs (the retention floor).
//
// With a WAL archive configured the backup carries no WAL (-X none): recovery
// always replays from the archive anyway, and duplicating segments into every
// backup would complicate WAL retention. pg_basebackup returns BEFORE the
// end-of-backup segment is archived, so create forces it out (ensureArchivedThrough);
// if the segment cannot be confirmed archived, create DISCARDS the backup and
// panics, a -X none base without that segment is unrestorable, and recording
// it would poison pickSnapshot with a backup that can never reach consistency.
// Without an archive the WAL is streamed into the backup (-X stream) so the
// degraded backup-only mode still yields startable copies.
func (b *backupT) create(name string) (endLSN, walStart string) {
	pg := newPg(b.cfg)
	dir := b.cfg.backupDir + "/" + name
	sh("mkdir -p " + q(b.cfg.backupDir))
	walMethod := "stream"
	if b.cfg.walArchive != "" {
		walMethod = "none"
	}
	// -c fast: immediate checkpoint (the default spread checkpoint would stretch a
	// snapshot to minutes). Plain format: the backup dir is a ready-to-copy PGDATA.
	sh(fmt.Sprintf("%spg_basebackup -d %s -D %s -Fp -c fast -X %s --no-password",
		pg.bin, q(b.cfg.databaseURL), q(dir), walMethod))
	endLSN, walStart = readBackupWAL(dir)
	if !ensureArchivedThrough(b.cfg, endLSN) {
		// A -X none backup whose end-of-backup segment never reached the archive
		// can never replay to consistency, discard it rather than let the caller
		// record an unrestorable base in the catalog.
		trySh("rm -rf " + q(dir))
		panic(fmt.Errorf("storage: backup %s discarded, its end-of-backup WAL segment was not archived within ~60s "+
			"(archiver down or lagging; check archive_command / pg_stat_archiver), so the backup could never be restored", name))
	}
	return endLSN, walStart
}

// materialize copies base backup name into a throwaway restore dir (under
// restoreDir, prefixed by tag) and returns it. The copy is what the throwaway
// Postgres runs on, the retained backup itself is never touched.
func (b *backupT) materialize(name, tag string) string {
	src := b.cfg.backupDir + "/" + name
	if _, err := os.Stat(src); err != nil {
		panic(fmt.Errorf("storage: base backup %s not found at %s (pruned or wrong ETER_BACKUP_DIR?)", name, src))
	}
	dir := fmt.Sprintf("%s/%s_%s", b.cfg.restoreDir, tag, randTag())
	sh("mkdir -p " + q(b.cfg.restoreDir))
	sh("cp -a " + q(src) + " " + q(dir))
	sh("chmod 700 " + q(dir))
	if b.cfg.pgOSUser != "" {
		// Root-run sidecar with an unprivileged postgres user: hand the copy over.
		sh("chown -R " + q(b.cfg.pgOSUser) + " " + q(dir))
	}
	return dir
}

// remove tears a restore dir down (best-effort, a failed teardown never masks
// the recovery result).
func (b *backupT) remove(dir string) {
	trySh("rm -rf " + q(dir))
}

// readBackupWAL extracts the WAL coordinates of a completed base backup from the
// files pg_basebackup writes into it: the end (stop) LSN from backup_manifest's
// WAL-Ranges, and the first needed WAL segment's filename from backup_label.
func readBackupWAL(dir string) (endLSN, walStart string) {
	manifest, err := os.ReadFile(dir + "/backup_manifest") //nolint:gosec // dir is our own backup directory
	if err != nil {
		panic(fmt.Errorf("storage: base backup has no readable backup_manifest: %w", err))
	}
	label, err := os.ReadFile(dir + "/backup_label") //nolint:gosec // dir is our own backup directory
	if err != nil {
		panic(fmt.Errorf("storage: base backup has no readable backup_label: %w", err))
	}
	endLSN = manifestEndLSN(manifest)
	walStart = labelStartSegment(label)
	return endLSN, walStart
}

// manifestEndLSN parses backup_manifest (JSON) and returns the end LSN of the
// backup's WAL range, the backup's consistency point.
func manifestEndLSN(manifest []byte) string {
	var m struct {
		WALRanges []struct {
			StartLSN string `json:"Start-LSN"`
			EndLSN   string `json:"End-LSN"`
		} `json:"WAL-Ranges"`
	}
	if err := json.Unmarshal(manifest, &m); err != nil || len(m.WALRanges) == 0 || m.WALRanges[0].EndLSN == "" {
		//nolint:errorlint // err is nil on the len==0 / empty-LSN branches; %w would render "%!w(<nil>)"
		panic(fmt.Errorf("storage: backup_manifest has no WAL-Ranges end LSN (err=%v)", err))
	}
	return m.WALRanges[0].EndLSN
}

var labelStartFileRe = regexp.MustCompile(`START WAL LOCATION: [0-9A-Fa-f/]+ \(file ([0-9A-F]+)\)`)

// labelStartSegment parses backup_label and returns the WAL segment filename the
// backup's recovery starts from, everything at/after it must be retained for
// the backup to stay restorable.
func labelStartSegment(label []byte) string {
	m := labelStartFileRe.FindSubmatch(label)
	if m == nil {
		panic(fmt.Errorf("storage: backup_label has no START WAL LOCATION file"))
	}
	return string(m[1])
}
