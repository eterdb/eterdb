// Backup/WAL retention, a policy for the recovery substrate, NOT for history.
// eter.history and the undo surface are never pruned (the product premise); base
// backups and archived WAL are re-derivable *infrastructure* whose recovery
// horizon an operator may consciously bound. Both knobs default OFF: out of the
// box every backup and every archived segment is retained, so months-old restore
// always works (the temporal-depth guarantee).
//
// The invariant either knob must preserve: a restore at time T needs one base
// backup at-or-before T plus an unbroken WAL chain from that backup's first
// segment to T. So the OLDEST retained backup anchors the whole horizon, middle
// backups are only replay-speed optimizations, and WAL older than the oldest
// retained backup's start segment is genuinely dead.
package main

import (
	"fmt"
	"strings"
	"time"
)

type catalogBackup struct {
	id        int64
	name      string
	walStart  string
	createdAt time.Time
}

// applyRetention runs one retention pass: prune base backups per the configured
// knobs, then (horizon mode only) drop archived WAL that no retained backup can
// need. No-op when both knobs are unset, the default retains everything.
func applyRetention(cfg storageConfig) {
	if cfg.retainCount <= 0 && cfg.horizonDays <= 0 {
		return
	}
	pg := newPg(cfg)
	bk := newBackup(cfg)
	backups := listUnpruned(pg)
	prune, oldestKeptWALStart := selectPrunable(backups, cfg.retainCount, cfg.horizonDays, time.Now())
	for _, b := range prune {
		bk.remove(cfg.backupDir + "/" + b.name)
		// The catalog row stays (audit trail), pruned_at excludes it from recovery.
		pg.metaQuery(fmt.Sprintf(
			"UPDATE eter.storage_snapshots SET pruned_at = now() WHERE id = %d", b.id))
		logMsg("retention: pruned base backup", map[string]any{"backup": b.name})
	}
	// WAL pruning only in horizon mode: retain-count never touches WAL (the chain
	// back to the oldest backup must stay unbroken for full-depth recovery).
	if cfg.horizonDays > 0 && cfg.walArchive != "" && oldestKeptWALStart != "" {
		sh(fmt.Sprintf("%spg_archivecleanup %s %s",
			pg.bin, q(cfg.walArchive), q(oldestKeptWALStart)))
		logMsg("retention: cleaned WAL archive before oldest retained backup",
			map[string]any{"keepFrom": oldestKeptWALStart})
	}
}

// selectPrunable decides which backups a retention pass removes. backups must be
// ordered oldest-first. Returns the prunable set and the first WAL segment the
// oldest retained backup needs (the archive-cleanup floor).
//
//   - horizonDays > 0: prune the oldest backup only while the NEXT one still
//     anchors the horizon (created at-or-before now-horizon), so at least one
//     backup at-or-before the floor always remains and every T inside the horizon
//     stays recoverable.
//   - retainCount > 0: of what's left, keep the oldest (the anchor) + the N
//     newest; prune the middles. Never affects WAL.
func selectPrunable(backups []catalogBackup, retainCount, horizonDays int, now time.Time) (prune []catalogBackup, oldestKeptWALStart string) {
	kept := append([]catalogBackup(nil), backups...)
	if horizonDays > 0 {
		floor := now.Add(-time.Duration(horizonDays) * 24 * time.Hour)
		for len(kept) > 1 && !kept[1].createdAt.After(floor) {
			prune = append(prune, kept[0])
			kept = kept[1:]
		}
	}
	if retainCount > 0 && len(kept) > retainCount+1 {
		prune = append(prune, kept[1:len(kept)-retainCount]...)
		kept = append(kept[:1], kept[len(kept)-retainCount:]...)
	}
	if len(kept) > 0 {
		oldestKeptWALStart = kept[0].walStart
	}
	return prune, oldestKeptWALStart
}

// listUnpruned reads the live (unpruned) backup catalog from the meta store,
// oldest-first.
func listUnpruned(pg *pgT) []catalogBackup {
	out := pg.metaQuery(
		`SELECT id||'|'||backup_name||'|'||coalesce(wal_start,'')||'|'||extract(epoch from created_at)::bigint
		   FROM eter.storage_snapshots WHERE pruned_at IS NULL ORDER BY id`)
	var backups []catalogBackup
	for _, ln := range strings.Split(out, "\n") {
		if ln == "" {
			continue
		}
		parts := strings.SplitN(ln, "|", 4)
		if len(parts) != 4 {
			continue
		}
		backups = append(backups, catalogBackup{
			id:        int64(mustInt(parts[0])),
			name:      parts[1],
			walStart:  parts[2],
			createdAt: time.Unix(int64(mustInt(parts[3])), 0),
		})
	}
	return backups
}
