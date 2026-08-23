# Running EterDB in containers

EterDB ships as **two ordinary unprivileged containers**, including the storage/time-travel
tier. The storage substrate is standard PITR (pg_basebackup base backups + archived-WAL
replay into a throwaway local postgres, see
`docs/adr/0003-storage-substrate-basebackup-pitr.md`), so nothing needs root,
`CAP_SYS_ADMIN`, host devices, or a kernel module. The stack runs anywhere containers
run: a Linux host, macOS Docker Desktop, or a serverless container runtime.

The one real constraint is the **engine**: EterDB's observe mode is a patched Postgres
build, eterDB runs *as* your Postgres, not on top of a managed one.

## The stack: two containers, one command

`docker-compose.yml` is the whole thing, no profiles, no variants:

- **engine**, patched Postgres (observe mode + `eter_ssi`), `eter.capture_mode=sidecar`:
  **no history trigger**; the logical slot is pre-created at first boot so capture is
  gap-free even if the control plane starts late. This is the tenant, and it runs alone.
- **control-plane**, everything else in one container, supervised (supervisord as PID 1,
  each process drops to the `postgres` user):
  - the **metadata store**, a *separate* Postgres cluster owning write history, the
    dependency graph, `ddl_log`, the backup catalog and the job queue. Durable recovery
    metadata has to survive the tenant failing, so it is never inside the tenant; here it
    is a distinct cluster (`eter_meta`, over loopback).
  - the **capture** sidecar (logical decoding → the meta store, off the commit path),
  - the **orchestrator**, the single entry point for the CLI (`/v1` on :4400, no DSNs on
    the client), managed restore jobs (async, single-flight, crash-safe), and the storage
    maintenance scheduler (scheduled base backups + WAL flush after destructive DDL).

```bash
ETER_API_TOKEN=change-me docker compose up -d
eter connect --url http://localhost:4400 --token change-me
eter init && eter track --all
eter preview <txid>                  # rw read-dependencies surface here
eter recover-table public.widgets    # submits a job + waits; eter jobs [id] to follow
# contributors building the images from source instead: add --build
```

By default this **pulls prebuilt images** from GHCR (`pull_policy: missing`), so the first
`up` does not compile Postgres. `--build` compiles the patched engine from source.

Prefer a **no-container dev loop**? The CLI's direct mode runs surgical undo against any
Postgres without this stack at all: `DATABASE_URL=… eter demo up` (see the repo
README / CLAUDE.md). That's the featherweight path; the two containers above are the full
product (observe + recovery on top of surgical undo).

Architectural notes:

- One shared volume (`/var/lib/eter`) carries the storage substrate: the engine archives
  WAL into `wal-archive/`; the control plane keeps `pg_basebackup` base backups in
  `backups/` and materializes throwaway restores next to them. Recovery = copy a base
  backup, replay archived WAL to the target LSN/time in a throwaway postgres, extract,
  restore into the live DB, tear down.
- Why the meta store stays separate even inside one container: the `RequireMetaURL` gate
  compares `host:port/db`, the engine (`engine:5432/eter`) and the meta cluster
  (`localhost:5432/eter_meta`) differ, so metadata survives a tenant it must outlive.
- The engine image provisions the `replication` pg_hba entry + `max_wal_senders` that
  `pg_basebackup` needs.
- Backup/WAL retention defaults to **retain everything** (months-old restore always
  works); `ETER_BACKUP_RETAIN_COUNT` / `ETER_BACKUP_HORIZON_DAYS` are the opt-in bounds,
  see `sidecars/storage/README.md`. This is separate from `eter.history`, which is never
  pruned.
- The two containers map cleanly onto **two hosts** in production: the tenant engine, and
  the control-plane host that also does recovery. Nothing in the stack scales
  horizontally, every process is a pinned singleton, which is exactly why this is a
  compose-shaped deployment, not a Kubernetes-shaped one.

## Images

| File | Image | What it is |
|------|-------|------------|
| `docker/Dockerfile.engine` | `ghcr.io/eterdb/engine:pg18` | Patched Postgres + `eter_ssi` + eter SQL, observe-ready, sidecar capture by default |
| `docker/Dockerfile.control-plane` | `ghcr.io/eterdb/control-plane:pg18` | Engine image + meta Postgres + capture + orchestrator under a supervisor, the whole control plane in one container |

The control-plane image is built `FROM` the engine image (it needs the patched Postgres
server binaries for the meta cluster + throwaway restore instances) and compiles the three
Go daemons (`eter-capture`, `eter-orchestrator`, `eter-storage`) itself. Build the engine
image first.
