// Postgres orchestration: talk to the live DB over its DSN, and spin throwaway
// "recovery" instances on materialized base-backup copies to extract lost objects.
//
// Privilege: in the normal (unprivileged) deployment the sidecar and the
// throwaway postgres are the same OS user, nothing is wrapped. ETER_PG_OS_USER
// exists for legacy host layouts where the sidecar runs as root: the postgres
// *server* (pg_ctl/postgres) cannot run as root, so it is wrapped in
// sudo -u <user>. psql/pg_dump are *clients*, they connect to the restore dir's
// unix socket (trust auth) and can run as whoever the sidecar is.
package main

import (
	"crypto/sha256"
	"fmt"
	"net/url"
	"strings"
	"time"
)

// sockDir returns a SHORT unix-socket directory for the recovery instance rooted at
// dir. A restore dir can be arbitrarily deep (e.g. a long macOS $TMPDIR mktemp path),
// and a Unix-domain socket path is capped at ~103 bytes, so the socket must NOT live
// under it - otherwise the throwaway postgres fails to start with "could not create
// any Unix-domain sockets". Keyed by a hash of dir so every caller derives the same
// path from the same dir with no extra plumbing; created in startTemp, removed in
// stopTemp. /tmp is the conventional (short, writable) home for a PG socket.
func sockDir(dir string) string {
	h := sha256.Sum256([]byte(dir))
	return fmt.Sprintf("/tmp/eter-rec-%x", h[:6])
}

type pgT struct {
	cfg        storageConfig
	user       string
	db         string
	serverWrap string
	bin        string // bindir prefix, e.g. "/usr/libexec/postgresql16/"
}

func newPg(cfg storageConfig) *pgT {
	u, err := url.Parse(cfg.databaseURL)
	if err != nil {
		panic(fmt.Errorf("storage: invalid DATABASE_URL: %w", err))
	}
	user := "postgres"
	if u.User != nil && u.User.Username() != "" {
		user = u.User.Username()
	}
	db := strings.TrimPrefix(u.Path, "/")
	if db == "" {
		db = user
	}
	serverWrap := ""
	if cfg.pgOSUser != "" {
		serverWrap = "sudo -u " + cfg.pgOSUser + " "
	}
	bin := ""
	if cfg.pgBinDir != "" {
		bin = strings.TrimSuffix(cfg.pgBinDir, "/") + "/"
	}
	return &pgT{cfg: cfg, user: user, db: db, serverWrap: serverWrap, bin: bin}
}

// ---- live DB (over the configured DSN) ----
func (p *pgT) liveQuery(sql string) string {
	return sh(p.bin + "psql " + q(p.cfg.databaseURL) + " -tAqc " + q(sql))
}
func (p *pgT) liveScript(file string) {
	sh(p.bin + "psql " + q(p.cfg.databaseURL) + " -v ON_ERROR_STOP=1 -f " + q(file))
}

// tryLiveQuery runs a query against the live DB without panicking on failure,
// returns (ok, output). For best-effort preflight steps (e.g. enabling DDL logging,
// which needs engine-owner privileges the DSN may lack).
func (p *pgT) tryLiveQuery(sql string) (bool, string) {
	return trySh(p.bin + "psql " + q(p.cfg.databaseURL) + " -tAqc " + q(sql))
}

// ---- metadata store (storage_snapshots / recovery_log) ----
// Same as the tenant DB unless ETER_META_URL externalizes the metadata.
func (p *pgT) metaQuery(sql string) string {
	return sh(p.bin + "psql " + q(p.cfg.metaURL) + " -tAqc " + q(sql))
}

// ---- throwaway instance on a materialized restore dir ----
func (p *pgT) startTemp(dir string, port int) {
	trySh("rm -f " + q(dir+"/postmaster.pid")) // stale pid from the base backup
	sd := sockDir(dir)
	sh("mkdir -p " + q(sd))
	// hot_standby=on so we can connect during archive recovery (as-of-T PITR);
	// self-contained (-X stream) copies come up as a primary immediately. The socket
	// is in a short dir (sd), never under the possibly-deep data dir (see sockDir).
	opts := fmt.Sprintf("-p %d -c listen_addresses='' -c unix_socket_directories=%s "+
		"-c archive_mode=off -c hot_standby=on", port, sd)
	timeout := p.cfg.recoveryTimeoutSec
	if timeout <= 0 {
		timeout = 300
	}
	if ok, out := trySh(fmt.Sprintf("%s%spg_ctl -D %s -l %s -o %s -w -t %d start",
		p.serverWrap, p.bin, q(dir), q(dir+"/recover.log"), q(opts), timeout)); !ok {
		_, logTail := trySh("tail -30 " + q(dir+"/recover.log"))
		panic(fmt.Errorf("storage: recovery instance failed to start: %s\n--- recover.log ---\n%s", strings.TrimSpace(out), strings.TrimSpace(logTail)))
	}
	p.awaitPrimary(dir, port)
}

// awaitPrimary blocks until the instance has left recovery (WAL replay finished
// and the PITR target reached + promoted), so queries observe the intended
// state. Bounded by cfg.recoveryTimeoutSec, replay from an aged base is
// legitimately slower than a COW clone's crash recovery ever was.
func (p *pgT) awaitPrimary(dir string, port int) {
	timeout := p.cfg.recoveryTimeoutSec
	if timeout <= 0 {
		timeout = 300
	}
	for i := 0; i < timeout*4; i++ {
		ok, out := trySh(fmt.Sprintf("%spsql -h %s -p %d -U %s -d %s -tAqc %s",
			p.bin, q(sockDir(dir)), port, q(p.user), q(p.db), q("SELECT pg_is_in_recovery()")))
		if ok && strings.TrimSpace(out) == "f" {
			return
		}
		time.Sleep(250 * time.Millisecond)
	}
	panic(fmt.Errorf("storage: recovery instance never left recovery (PITR target unreachable?)"))
}

func (p *pgT) stopTemp(dir string) {
	trySh(p.serverWrap + p.bin + "pg_ctl -D " + q(dir) + " -m immediate stop")
	trySh("rm -rf " + q(sockDir(dir))) // remove the short socket dir created in startTemp
}

func (p *pgT) tempQuery(dir string, port int, sql string) string {
	return sh(fmt.Sprintf("%spsql -h %s -p %d -U %s -d %s -tAqc %s",
		p.bin, q(sockDir(dir)), port, q(p.user), q(p.db), q(sql)))
}

// dumpTable dumps one relation (schema + data) from the restored copy into a SQL file.
func (p *pgT) dumpTable(dir string, port int, ident, outFile string) {
	sh(fmt.Sprintf("%spg_dump -h %s -p %d -U %s -d %s --no-owner --no-acl -t %s -f %s",
		p.bin, q(sockDir(dir)), port, q(p.user), q(p.db), q(ident), q(outFile)))
}

// copyOut copies selected columns of a relation from the restored copy into a client-side CSV.
func (p *pgT) copyOut(dir string, port int, selectSQL, outFile string) {
	copyCmd := fmt.Sprintf(`\copy (%s) TO %s CSV`, selectSQL, strings.ReplaceAll(outFile, "'", "''"))
	sh(fmt.Sprintf("%spsql -h %s -p %d -U %s -d %s -c %s",
		p.bin, q(sockDir(dir)), port, q(p.user), q(p.db), q(copyCmd)))
}
