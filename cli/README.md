# `eter` CLI: Go port

A Go port of the original TypeScript `eter` CLI (the `packages/` tree, since
removed, ADR 0004). The command surface, `--json` shapes, and the stable
exit-code contract are a **frozen interface**, this port reimplements them in Go
without changing them.

The transport (`internal/client`) and rendering (`internal/output`) layers are
kept separate from the command wiring (`internal/cmd`), so the interactive
[Bubble Tea](https://github.com/charmbracelet/bubbletea) walkthrough
(`eter demo`, in `internal/demotui`) drives the exact same client surface as the
scriptable commands.

```bash
eter demo   # watch an incident get reversed; offers to start the Docker stack if it isn't up
```

## Install

The CLI is a single self-contained binary. The engine SQL it applies (`eter init`), the demo
schema (`eter demo up`), and the two-container `docker-compose.yml` (`eter demo` brings the
stack up itself) are embedded (`internal/assets`), so it works from anywhere against a
reachable Postgres, no repo checkout required.

```bash
# macOS / Linux (Homebrew)
brew install eterdb/tap/eter

# any Unix, prebuilt binary from the latest GitHub Release
curl -fsSL https://eterdb.com/install.sh | sh
```

The engine itself ships as container images (`ghcr.io/eterdb/*`), the CLI is the control plane
that talks to it. Point it at a DB or the orchestrator, then `eter doctor` to check the setup.

## Build & run

```bash
cd cli
go build -o eter .            # or: goreleaser release --snapshot --clean (from repo root)
export DATABASE_URL=postgres://eter:eter@localhost:5432/eter
./eter init
./eter demo up
./eter preview <txid>
./eter undo <txid> --apply
```

Embedded SQL is kept in sync with `ext/eter/eter.sql` + `demo/schema.sql` via
`go generate ./internal/assets` (a CI test fails if they drift). `go install ./...` works for
in-repo dev; a released binary is produced by goreleaser (`.goreleaser.yaml`).

## Layout

| Path                  | Responsibility                                               |
| --------------------- | ------------------------------------------------------------ |
| `main.go`             | entry point → `cmd.Execute`                                  |
| `internal/cmd`        | cobra command tree, exit-code mapping, human rendering       |
| `internal/client`     | `EterClient` interface + `DirectClient` (pgx) / `HostedClient` (HTTP) |
| `internal/config`     | transport resolution (`--db` / `ETER_URL`+`ETER_TOKEN` / `DATABASE_URL`) |
| `internal/core`       | shared types (`UndoPlan`, exit codes), engine-SQL path lookup |
| `internal/demo`       | seeded e-commerce incident (`demo up` / `demo down`, + the Seed/FireIncident steps the TUI drives) |
| `internal/demotui`    | interactive `eter demo` walkthrough (Bubble Tea)             |
| `internal/output`     | `--json` vs. human table/prose rendering                     |

## Connection modes

- **Direct:** `--db <postgres-url>` or `DATABASE_URL`. Honours `ETER_META_URL`
  to externalize durable `eter.*` metadata into a separate store (the undo apply
  then runs through `eter.undo_rows`).
- **Hosted:** `--url <server>` + `--token <tenant-token>` or `ETER_URL` /
  `ETER_TOKEN`.

## Exit codes

`0` ok · `2` usage · `3` not found · `4` dependent (undo refused in
`clean_only`) · `5` database error · `6` config error · `7` prerequisite
missing (e.g. `track` refused because no capture sidecar is attached) · `130`
interrupted (Ctrl-C / SIGTERM, the command's context is cancelled so in-flight
work unwinds cleanly).

Errors carry an actionable next-step **hint** where one applies (e.g. a missing
connection points at `eter connect`, a dependent undo at `--cascade/--targeted`).
In `--json` mode the hint rides along as an optional `"hint"` field, additive to
the frozen `{"ok":false,"error":…}` shape.

## Diagnostics

- `eter doctor`, one-shot environment check: resolved connection + mode, engine
  readiness/version, CLI-vs-engine version compatibility, config-file location,
  and whether recovery (the storage sidecar/orchestrator) is reachable. Read-only;
  `--json` for agents.
- `eter version`, CLI version, build revision, and the engine SQL version this
  binary ships (`--json` supported). The bare `--version` flag is unchanged.
- `eter completion <bash|zsh|fish|powershell>`, shell completion script.

## Notes

- `internal/cmd/ETER_AGENT.md` is the agent guide, embedded into the binary
  (via `go:embed`) so `eter guide` works standalone. It is the canonical copy
  since the TypeScript CLI was removed.
- The engine SQL (`ext/eter/eter.sql`) and demo schema (`demo/schema.sql`)
  are located by walking up from the working directory; override with
  `ETER_SQL_FILE` / `ETER_DEMO_SCHEMA`.
