<p align="center">
  <a href="https://eterdb.com">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset=".github/assets/logo-dark.svg" />
      <img src=".github/assets/logo-light.svg" alt="EterDB" width="132" height="132" />
    </picture>
  </a>
</p>

<h1 align="center">EterDB</h1>

<p align="center">
  <strong>PostgreSQL 18 with surgical, dependency-aware undo of live transactions.</strong><br />
  Reverse a single bad transaction, or a whole incident's worth, down to the exact rows it
  touched, on a live database, with a clear "is this safe?" answer every time. Even when an agent did it.
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache%202.0-blue.svg" alt="License: Apache 2.0" /></a>
  <img src="https://img.shields.io/badge/PostgreSQL-18-336791.svg" alt="PostgreSQL 18" />
  <img src="https://img.shields.io/badge/status-closed%20alpha-orange.svg" alt="Status: closed alpha" />
  <a href="https://eterdb.com"><img src="https://img.shields.io/badge/eterdb.com-black.svg" alt="eterdb.com" /></a>
</p>

<p align="center">
  <a href="#quickstart">Quickstart</a> ·
  <a href="#how-it-works">How it works</a> ·
  <a href="#the-eter-cli">CLI</a> ·
  <a href="#for-ai-agents">For AI agents</a> ·
  <a href="#read-dependency-capture">Read-dependency capture</a> ·
  <a href="#storage--time-travel">Storage &amp; time-travel</a> ·
  <a href="#repository-layout">Layout</a> ·
  <a href="https://eterdb.com">Website</a>
</p>

---

## What is EterDB?

Agents now write most new production databases, and a committed transaction is treated as a
*permanent* one. When a bad `UPDATE` mangles a thousand rows, a migration corrupts a table, or an
agent drops the wrong object, your options are blunt: **backups and PITR roll back the *whole*
database** (losing every unrelated write since), and **branches/forks only protect you *before* a
change ships**.

EterDB reverses one transaction after it has shipped, on a live database, and a human or the
agent itself can run it. It computes a compensating transaction from recorded before/after row
images and applies it atomically, reversing exactly what that transaction changed and leaving
concurrent, unrelated writes alone.

This repository is the **open-source engine, CLI, and sidecars**. It contains three things that
work together:

- **`eter` engine**: a SQL extension that records row-level history and performs surgical,
  dependency-checked `undo` (single transaction or a whole cohort).
- **Read-dependency capture**: a loadable C extension (`eter_ssi`) plus a small, upstream-tracked
  Postgres patch. Together they record a later transaction that merely **read** the rows you are
  about to undo. A read leaves no row behind, so CDC and proxies cannot see this one.
- **Storage / time-travel sidecars**: ordinary unprivileged containers that add base backups,
  as-of-time reads, and recovery of dropped tables, columns, and rows via standard PITR.

The hosted, multi-tenant control plane is not part of this repository.

## How it works

**Undo is surgical.** EterDB records the before/after image of every tracked row, then computes a
compensating transaction and applies it atomically. A *clean* undo restores the exact pre-incident
state; concurrent legitimate writes survive untouched. Verified end-to-end in
[`test/e2e.sh`](test/e2e.sh).

**Every undo is checked first.** EterDB looks at what depends on the transaction before reversing
it. A later *write* to the same rows makes the undo **dependent → review**, and so does a later
transaction that only *read* the rows. Either way you see the dependent set and choose what to do
with it. ([How the read-capture works →](https://eterdb.com/tech))

**Database state only.** EterDB cannot unsend an email or refund a charge. It surfaces the
external references (Stripe `ch_…`, message ids, …) found in the rows an undo touches, so you see
the external fallout before you decide.

**It is PostgreSQL 18.** Read-dependency capture is the one piece that has to be in the engine,
and it ships as a small, upstream-tracked patch. Extensions including pgvector, your ORM and your
SQL dialect all work unchanged.

## Quickstart

Surgical undo runs on stock Postgres, with no custom engine build. This is the seeded "2:00 PM
incident": one buggy transaction corrupts every invoice, and you reverse it while unrelated writes
survive.

```bash
git clone https://github.com/eterdb/eterdb.git && cd eterdb
cp .env.example .env
make build                       # the eter CLI is Go (cobra + pgx), needs the Go toolchain

docker compose up -d                    # stock Postgres (pgvector image) + the eter engine SQL
export DATABASE_URL=postgres://eter:eter@localhost:5433/eter   # engine published on 5433

eter demo up                 # seeds data, fires the incident, prints the incident txid
eter preview <incident-txid> # clean vs. dependent, plus any external references
eter undo <incident-txid> --apply
```

`undo` **previews by default** and only mutates with `--apply`. The `make …` targets are thin
wrappers over the Go CLI (see the `Makefile`); `cd cli && go run . <cmd>` works identically.

**Point it at your own database**, surgical undo works on any stock Postgres:

```bash
export DATABASE_URL=postgres://USER:PASS@HOST:5432/DBNAME
eter init           # install the engine (idempotent)
eter track --all    # capture every table with a primary key
# ... your app (or agent) runs ...
eter log            # browse recorded transactions
```

The full end-to-end suite runs against any psql:
`ETER_PSQL="psql '$DATABASE_URL' -tAc" make test-e2e`.

## The `eter` CLI

The CLI is a single self-contained Go binary (the engine SQL it installs is embedded), designed to
be **agent-usable**: every command takes `--json` and returns stable exit codes.

```bash
# macOS / Linux (Homebrew)
brew install eterdb/tap/eter

# any Unix: download the right prebuilt binary from the latest release
curl -fsSL https://eterdb.com/install.sh | sh

# or build from source (needs the Go toolchain)
make build
```

```bash
eter connect postgres://eter:eter@localhost:5432/eter   # or --url <orchestrator>
eter doctor                                             # connection, engine, versions, recovery
eter guide                                              # the agent playbook
```

```
init · track [table|--all] · log · show · preview · undo [--apply --cascade|--targeted]
cohort · undo-cohort · mark · status · doctor · version · connect · disconnect · jobs
demo up|down · guide · snapshot · recover-table · recover-rows · recover-column · as-of
```

Exit codes: `0` ok · `2` usage · `3` not found · `4` dependent (undo refused) · `5` db ·
`6` config · `130` interrupted.

## For AI agents

The agent that made the change can run the reversal itself.

- **The CLI is a stable machine interface.** Every `eter` command takes `--json` and returns
  stable exit codes (`0` ok · `2` usage · `3` not found · `4` dependent/undo refused · `5` db ·
  `6` config · `130` interrupted), so an agent can branch on the outcome without parsing prose. In
  particular, exit `4` is the "this undo is not clean, a later transaction depends on it, stop and
  review" signal.
- **`eter guide`** prints the agent playbook: how to investigate an incident (`eter log`), preview
  a reversal (`eter preview <txid>`, clean vs. dependent plus external references), and apply it
  (`eter undo <txid> --apply`). Undo previews by default and only mutates with `--apply`.
- **The website is agent-legible too.** [eterdb.com](https://eterdb.com) publishes an
  [`/llms.txt`](https://eterdb.com/llms.txt) curated map ([llms.txt convention](https://llmstxt.org)),
  served as Markdown so a coding assistant can ingest the product and architecture in a token-efficient
  form instead of scraping HTML.

## Read-dependency capture

On stock Postgres, EterDB captures write-write dependencies with in-transaction triggers.
Capturing **read** dependencies as well takes the patched engine plus the `eter_ssi` extension.

The easy path is the **containerized stack** (two containers, engine + control-plane), which pulls
the published images (or builds the patched engine for you with `--build`):

```bash
ETER_API_TOKEN=change-me docker compose up -d   # engine + control-plane (capture + orchestrator + meta)
eter connect --url http://localhost:4400 --token change-me
eter demo up
eter preview <incident-txid>   # read dependencies now surface alongside writes
```

To build the pieces yourself instead:

1. **`eter_ssi`**: the loadable C extension that captures the read-dependency graph. See
   [`ext/eter_ssi/README.md`](ext/eter_ssi/README.md).
   ```bash
   make -C ext/eter_ssi PG_CONFIG=$(which pg_config) install
   psql "$DATABASE_URL" -c "CREATE EXTENSION eter_ssi;"
   ```
2. **The observe-mode core patch**: `pg/patches/0001-eter-observe-mode-pg18.patch`. Build a
   patched Postgres per [`pg/README.md`](pg/README.md), then run `bash test/observe.sh`.

For how observe mode captures reads without changing your application's behavior, see
[eterdb.com/tech](https://eterdb.com/tech).

## Storage & time-travel

Whole-database time-travel and recovery of dropped objects, packaged as **ordinary unprivileged
containers**. It's standard PITR, `pg_basebackup` base backups plus archived-WAL replay, with no
kernel module, no privileged mode, and no host requirements: it runs anywhere containers run. The
storage machinery is part of the **control-plane** container the stack already runs, so there's no
extra service to start:

```bash
ETER_API_TOKEN=change-me docker compose up -d
eter recover-table public.widgets   # submits a managed restore job + waits
```

Recovery restores the pre-incident base backup, replays archived WAL to just before the destructive
change in a throwaway local Postgres, extracts the lost object, and restores it into the live
database, exposed through the CLI as `snapshot`, `recover-table`, `recover-rows`,
`recover-column`, and `as-of`. See [`sidecars/storage/README.md`](sidecars/storage/README.md).

The **orchestrator** (`sidecars/orchestrator/`) is the single HTTP entry point (`/v1`) with managed,
async restore jobs; point the CLI at it with `--url`. In the container stack it runs inside the
control-plane container.

> Observe mode is a patched Postgres build, so EterDB *replaces* your database rather than running
> *on* managed Postgres (RDS/Aurora/Cloud SQL). Full container details are in
> [`docker/README.md`](docker/README.md).

## Repository layout

```
ext/eter/              the engine: track / preview_undo / undo / cohort / external-refs (the frozen SQL surface)
ext/eter_ssi/          C extension: native SSI read-dependency capture + drain background worker
pg/                    the observe-mode core patch (PG18) + build / validation notes
cli/                   the agent-usable `eter` CLI (Go, cobra + pgx)
sidecars/capture/      logical-decoding change capture into eter.history (Go)
sidecars/storage/      base backups + WAL-replay PITR: object recovery, as-of-T reads (Go)
sidecars/orchestrator/ the single HTTP entry point: /v1 API + async restore jobs (Go)
sidecars/eterclient/   the shared Go engine client (tenant + meta-store pools)
demo/                  the seeded e-commerce "2:00 PM incident"
test/                  end-to-end + correctness suites (e2e, ssi, observe, false-clean, …)
docker/                container images + the incremental container bring-up (see docker/README.md)
site/                  the public marketing website (static HTML/CSS/JS)
```

## How this was built

EterDB was built with heavy AI assistance (Claude) under human direction and review.

The correctness suites in [`test/`](test/) run from this repository, so every claim above is
reproducible. If one of them does not hold up,
[open an issue](https://github.com/eterdb/eterdb/issues).

## Contributing

Contributions and issues are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) to get started, and
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) for community expectations. For anything
security-sensitive, please follow [SECURITY.md](SECURITY.md) rather than opening a public issue.

## License

Apache License 2.0: see [LICENSE](LICENSE) and [NOTICE](NOTICE). The observe-mode patch under
`pg/patches/` modifies PostgreSQL source and is governed by the PostgreSQL License where it does so;
all EterDB-original code is Apache-2.0.
