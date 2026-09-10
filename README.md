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
  Reverse one bad transaction, or a whole incident's worth, down to the exact rows it touched,
  on a live database, with a clear "is this safe?" answer every time. Even when an agent did it.
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache%202.0-blue.svg" alt="License: Apache 2.0" /></a>
  <img src="https://img.shields.io/badge/PostgreSQL-18-336791.svg" alt="PostgreSQL 18" />
  <a href="https://eterdb.com"><img src="https://img.shields.io/badge/eterdb.com-black.svg" alt="eterdb.com" /></a>
</p>

<p align="center">
  <a href="#quickstart">Quickstart</a> ·
  <a href="#how-it-works">How it works</a> ·
  <a href="#the-eter-cli">CLI</a> ·
  <a href="#for-ai-agents">For AI agents</a> ·
  <a href="#deployment">Deployment</a> ·
  <a href="https://eterdb.com/tech">Architecture</a>
</p>

---

## What is EterDB?

Agents now write most new production database code, and a committed transaction is treated as a
*permanent* one. When a bad `UPDATE` mangles a thousand rows, a migration corrupts a table, or an
agent drops the wrong object, the recovery options are blunt: **backups and PITR roll back the
*whole* database**, losing every unrelated write since, and **branches and forks only protect you
*before* a change ships**.

EterDB reverses one transaction after it has shipped, on a live database. It records the
before/after image of every tracked row, computes a compensating transaction, and applies it
atomically, reversing exactly what that transaction changed and leaving concurrent, unrelated
writes alone. A human or the agent itself can run it.

This repository is the open-source **engine, CLI, and sidecars**. The hosted multi-tenant control
plane is not part of it.

## Quickstart

```bash
brew install eterdb/tap/eter          # or: curl -fsSL https://eterdb.com/install.sh | sh
eter demo
```

`eter demo` starts the container stack (Docker required) and walks the seeded **2:00 PM
incident**: a migration forgets its `WHERE` clause and zeroes every invoice. You investigate with
`eter log`, preview the reversal, and undo it while unrelated writes survive. Act two drops the
`orders` table and recovers it from a base backup.

To point EterDB at your own data instead, see [Deployment](#deployment).

## How it works

**Undo is surgical.** EterDB restores the exact pre-incident state of the rows a transaction
touched; concurrent legitimate writes are untouched. Verified end-to-end in
[`test/e2e.sh`](test/e2e.sh).

**Every undo is checked first.** EterDB looks at what depends on a transaction before reversing
it. A later *write* to the same rows makes the undo **dependent → review**; so does a later
transaction that only *read* them. Either way you see the dependent set and decide.
([How read-capture works →](https://eterdb.com/tech))

**Database state only.** EterDB cannot unsend an email or reverse a charge. It surfaces the
external references (Stripe `ch_…`, message ids) in the rows an undo touches, so you see the
external fallout before you decide.

**It is PostgreSQL 18.** One piece, read-dependency capture, has to be in the engine, and it
ships as a small upstream-tracked patch. Extensions including pgvector, your ORM, and your SQL
dialect all work unchanged.

## The `eter` CLI

A single self-contained Go binary (the engine SQL and the compose stack are embedded), built to
be **agent-usable**: every command takes `--json` and returns a stable exit code.

```bash
brew install eterdb/tap/eter                       # macOS / Linux
curl -fsSL https://eterdb.com/install.sh | sh      # any Unix, prebuilt binary
make build                                         # from source (needs the Go toolchain)
```

```
init · track [table|--all] · log · show · preview · undo [--apply --cascade|--targeted]
cohort · undo-cohort · mark · status · doctor · guide · version · connect · disconnect
demo [up|down] · jobs · snapshot · recover-table · recover-rows · recover-column · as-of
```

```bash
eter connect postgres://eter:eter@localhost:5433/eter   # or --url <orchestrator>
eter doctor                                             # connection, engine, versions, recovery
eter guide                                              # the agent playbook
```

Exit codes: `0` ok · `2` usage · `3` not found · `4` dependent (undo refused) · `5` db ·
`6` config · `7` prerequisite missing · `130` interrupted.

## For AI agents

The agent that made the change can run the reversal itself.

- **The CLI is a stable machine interface.** `--json` on every command, and the exit code carries
  the outcome, so an agent branches on it without parsing prose. Exit `4` is the "this undo is not
  clean, a later transaction depends on it, stop and review" signal.
- **`eter guide`** prints the playbook: investigate with `eter log`, preview with
  `eter preview <txid>`, apply with `eter undo <txid> --apply`.
- **The website is agent-legible.** [eterdb.com/llms.txt](https://eterdb.com/llms.txt) is a
  curated Markdown map ([llms.txt convention](https://llmstxt.org)) of the product and
  architecture, for ingesting without scraping HTML.

## Deployment

EterDB runs as the **two-container stack** in [`docker-compose.yml`](docker-compose.yml):

- **`engine`**: patched PostgreSQL 18 + `eter_ssi`, change capture via logical decoding, WAL
  archiving on. Your application connects here, on `localhost:5433`.
- **`control-plane`**: a separate metadata store (so recovery data survives the tenant having a
  bad day) plus the capture sidecar and the **orchestrator**, the one HTTP entry point (`/v1`,
  `localhost:4400`).

```bash
docker compose up -d                  # from a clone; pulls the images, --build compiles the engine
eter connect --url http://localhost:4400
eter init && eter track --all         # install the engine, capture every table with a primary key
#   ... your app (or an agent) runs, and something goes wrong ...
eter log                              # find the transaction
eter preview <txid>                   # clean vs. dependent, with read dependencies and external refs
eter undo <txid> --apply
```

Read-dependency capture, the part a backup cannot see because a read leaves no row behind, needs
the patched engine, which is why `engine` is an image rather than an extension. `docker/README.md`
has the full container reference; `ext/eter_ssi/README.md` and `pg/README.md` cover building the
patch and the extension yourself.

## Storage & time-travel

The `control-plane` container also runs whole-database time-travel and recovery of dropped
objects, standard PITR (`pg_basebackup` base backups plus archived-WAL replay), no kernel module
and no privileged mode:

```bash
eter recover-table public.widgets     # submits a managed restore job and waits
```

Recovery restores the pre-incident base backup into a throwaway local Postgres, replays WAL to
just before the destructive change, extracts the lost object, and merges it back into the live
database. Exposed as `snapshot`, `recover-table`, `recover-rows`, `recover-column`, and `as-of`.
See [`sidecars/storage/README.md`](sidecars/storage/README.md).

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
docker/                container images + the container bring-up guide
site/                  the public marketing website (static HTML/CSS/JS)
```

## How this was built

EterDB was built with heavy AI assistance (Claude) under human direction and review. The
correctness suites in [`test/`](test/) run from this repository, so every claim above is
reproducible. If one does not hold up, [open an issue](https://github.com/eterdb/eterdb/issues).

## Contributing

Contributions and issues are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) to get started and
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) for community expectations. For anything
security-sensitive, follow [SECURITY.md](SECURITY.md) rather than opening a public issue.

## License

Apache License 2.0: see [LICENSE](LICENSE) and [NOTICE](NOTICE). The observe-mode patch under
`pg/patches/` modifies PostgreSQL source and is governed by the PostgreSQL License where it does
so; all EterDB-original code is Apache-2.0.
