// EterDB storage sidecar (Phase 3), base-backup + WAL-replay (PITR) temporal
// storage. Runs unprivileged: no COW filesystem, no kernel module, no root.
//
//	snapshot [kind]                 take + record a retained pg_basebackup base backup
//	list                            list recorded backups
//	recover-table   <ident> [snap]  restore a dropped/truncated table
//	recover-rows    <ident> [snap]  restore truncated rows (keep newer writes)
//	recover-column  <ident> <col> [snap]   re-add + repopulate a dropped column
//	as-of <iso> <sql>               run sql against the DB as it was at time iso
//	daemon [intervalSec]            periodic base backups + WAL flush after a destructive DDL
//	cycle                           ONE daemon iteration (for an external scheduler, e.g. the orchestrator)
//	preflight                       ensure DDL logging on + verify WAL archiving (what daemon does at start)
//
// An orchestrator over pg_basebackup / pg_ctl / pg_dump / psql, no
// storage-engine surgery.
//
// ETER_STORAGE_JSON=1 switches the result lines on stdout to single-line JSON
// objects (machine consumers, e.g. the orchestrator's job runner); unset, the
// human output is unchanged.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"time"
)

func logMsg(msg string, extra map[string]any) {
	line := map[string]any{"ts": time.Now().UTC().Format(time.RFC3339Nano), "comp": "storage", "msg": msg}
	for k, v := range extra {
		line[k] = v
	}
	b, _ := json.Marshal(line)
	_, _ = os.Stderr.Write(append(b, '\n'))
}

func daemon(intervalSec int) {
	cfg := loadConfig()
	preflight(cfg) // ensure DDL logging on + WAL archiving verified before we start
	pg := newPg(cfg)
	logMsg("storage daemon started", map[string]any{"intervalSec": intervalSec})
	// The scheduled base backups are the recovery BASE, not the whole substrate: a
	// dropped column/table is recovered by restoring the latest backup taken BEFORE
	// the change (pickForRecovery constrains by the DROP's ddl_log.snapshot_lsn) and,
	// when a WAL archive is configured, replaying archived WAL forward to just before
	// the drop's LSN. So with archiving on, the cadence bounds only how much WAL a
	// recovery replays (a speed knob), NOT how stale the recovered data can be: writes
	// between the base backup and the drop are fully recovered. Without an archive it
	// degrades to backup-only recovery, where the cadence bounds staleness.
	// NOTE: run EITHER this daemon OR the orchestrator's scheduler (which execs
	// `eter-storage cycle` on the same cadence), never both. Double-scheduling is
	// duplicate backups (cost), not corruption.
	for {
		func() {
			defer func() {
				if r := recover(); r != nil {
					logMsg("backup cycle failed", map[string]any{"err": fmt.Sprint(r)})
				}
			}()
			cycleOnce(cfg, pg)
		}()
		time.Sleep(time.Duration(intervalSec) * time.Second)
	}
}

// cycleOnce is one stateless maintenance iteration, shared by the in-process
// daemon loop and the standalone `cycle` subcommand (run by an external
// scheduler such as the orchestrator). Two steps, both safe to repeat:
//
//  1. Force the WAL segment holding the newest destructive DDL out to the
//     archive, so recovery works immediately even if the archiver was lagging.
//     ddl_log's durable home is the metadata store (the capture sidecar's
//     forwarder ships tenant event-trigger rows there and prunes the tenant
//     copy; single-DB: same table), so read the signal from the store.
//     ensureArchivedThrough early-returns when the segment is already shipped,
//     so re-processing the same row every cycle is a cheap no-op. It
//     deliberately does NOT take a post-DDL backup: that copy would be taken
//     AFTER the drop committed, so it can never be the recovery source, under
//     ZFS it was a free boundary marker, as a full copy it would be pure cost.
//  2. Attempt a scheduled base backup, VARIABLE cadence: skipped unless at
//     least cfg.snapshotMinWALBytes of WAL accumulated since the last one, or
//     the newest backup aged past cfg.maxBackupAgeHours (scheduledSnapshot). A
//     base backup is a full physical copy, so idle periods must not cut
//     needless bases, recovery just replays a little more WAL. A taken backup
//     triggers a retention pass.
func cycleOnce(cfg storageConfig, pg *pgT) (tookBackup bool, archivedLSN string) {
	archivedLSN = pg.metaQuery(
		"SELECT coalesce((SELECT snapshot_lsn::text FROM eter.ddl_log WHERE is_destructive ORDER BY id DESC LIMIT 1), '')")
	if archivedLSN != "" {
		ensureArchivedThrough(cfg, archivedLSN)
	}
	if scheduledSnapshot(cfg, cfg.snapshotMinWALBytes) != "" {
		applyRetention(cfg)
		tookBackup = true
	}
	return tookBackup, archivedLSN
}

func main() {
	defer func() {
		if r := recover(); r != nil {
			logMsg("fatal", map[string]any{"err": fmt.Sprint(r)})
			os.Exit(1)
		}
	}()

	args := os.Args[1:]
	cmd := ""
	var rest []string
	if len(args) > 0 {
		cmd = args[0]
		rest = args[1:]
	}
	at := func(i int) string {
		if i < len(rest) {
			return rest[i]
		}
		return ""
	}

	// ETER_STORAGE_JSON=1: machine consumers (the orchestrator's job runner) get a
	// single JSON result line on stdout; unset, the human output is unchanged.
	jsonOut := os.Getenv("ETER_STORAGE_JSON") == "1"
	emit := func(obj map[string]any, human string) {
		if jsonOut {
			b, _ := json.Marshal(obj)
			fmt.Println(string(b))
		} else {
			fmt.Println(human)
		}
	}

	switch cmd {
	case "snapshot":
		kind := at(0)
		if kind == "" {
			kind = "manual"
		}
		name := takeSnapshot(loadConfig(), kind)
		emit(map[string]any{"snapshot": name}, name)
	case "list":
		fmt.Println(newPg(loadConfig()).metaQuery(
			"SELECT id||' '||kind||' '||coalesce(lsn::text,'-')||' '||backup_name||CASE WHEN pruned_at IS NULL THEN '' ELSE ' (pruned)' END FROM eter.storage_snapshots ORDER BY id"))
	case "recover-table":
		if at(0) == "" {
			panic(fmt.Errorf("usage: recover-table <schema.table> [snapshot]"))
		}
		rows, snap := recoverTable(loadConfig(), at(0), at(1))
		emit(map[string]any{"rows": rows, "snapshot": snap},
			fmt.Sprintf("✓ recovered table %s, %d row(s) restored from snapshot %s", at(0), rows, snap))
	case "recover-rows":
		if at(0) == "" {
			panic(fmt.Errorf("usage: recover-rows <schema.table> [snapshot]"))
		}
		rows, snap := recoverRows(loadConfig(), at(0), at(1))
		emit(map[string]any{"rows": rows, "snapshot": snap},
			fmt.Sprintf("✓ recovered rows in %s, %d row(s) present, later writes preserved (from snapshot %s)", at(0), rows, snap))
	case "recover-column":
		if at(0) == "" || at(1) == "" {
			panic(fmt.Errorf("usage: recover-column <schema.table> <column> [snapshot]"))
		}
		rows, snap := recoverColumn(loadConfig(), at(0), at(1), at(2))
		emit(map[string]any{"rows": rows, "snapshot": snap},
			fmt.Sprintf("✓ recovered column %q on %s, %d row(s) restored by primary key, from snapshot %s", at(1), at(0), rows, snap))
	case "as-of":
		if at(0) == "" || at(1) == "" {
			panic(fmt.Errorf("usage: as-of <iso-time> <sql>"))
		}
		out := asOf(loadConfig(), at(0), joinFrom(rest, 1))
		obj := map[string]any{"result": out}
		// Cap the structured result (it is stored in the jobs table): 1 MiB is plenty
		// for an as-of read surfaced through the API.
		if len(out) > 1<<20 {
			obj = map[string]any{"result": out[:1<<20], "truncated": true}
		}
		emit(obj, out)
	case "cycle":
		cfg := loadConfig()
		// Each cycle is a fresh process (the orchestrator execs it), so the
		// lossless-recovery prerequisites are re-ensured here the way the daemon
		// ensures them at start, otherwise orchestrated deployments would never
		// enable DDL logging and recovery would silently degrade to backup-only.
		preflight(cfg)
		tookBackup, archivedLSN := cycleOnce(cfg, newPg(cfg))
		emit(map[string]any{"took_backup": tookBackup, "archived_lsn": archivedLSN},
			fmt.Sprintf("cycle: took_backup=%v archived_lsn=%s", tookBackup, archivedLSN))
	case "preflight":
		preflight(loadConfig())
		emit(map[string]any{"preflight": "ok"}, "preflight ok")
	case "daemon":
		interval := 30
		if at(0) != "" {
			if n, err := strconv.Atoi(at(0)); err == nil {
				interval = n
			}
		}
		daemon(interval)
	default:
		fmt.Fprintln(os.Stderr, "commands: snapshot|list|recover-table|recover-rows|recover-column|as-of|cycle|preflight|daemon")
		os.Exit(2)
	}
}

// joinFrom joins rest[i:] with single spaces (the as-of SQL may contain spaces
// when passed as multiple argv words).
func joinFrom(rest []string, i int) string {
	out := ""
	for j := i; j < len(rest); j++ {
		if j > i {
			out += " "
		}
		out += rest[j]
	}
	return out
}
