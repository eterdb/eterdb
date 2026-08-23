# Contributing to EterDB

Thanks for your interest. EterDB is PostgreSQL 18 with surgical, dependency-aware undo. It is
correctness-critical, so contributions are held to the engine's own bar.

## Ground rules

- **The CLI + dashboard + undo SQL surface is a frozen interface.** Change the substrate
  beneath it, not the documented command/function signatures. `--json` and stable exit codes
  are part of the contract on every CLI command.
- **Every layer is a working mechanism.** No placeholders, no stubs standing in for the thing
  they represent.
- **Never a false clean.** EterDB must never report an undo `clean` while a dependency exists.
  Any change touching dependency capture has to keep the completeness gate green (see below).

## Development

```bash
make build   # the eter CLI is Go (cobra + pgx), needs the Go toolchain
export DATABASE_URL=postgres://eter:eter@localhost:5432/eter   # any Postgres
eter demo up
make test-e2e        # or: bash test/e2e.sh
```

The CLI is in `cli/` (Go); run `go test ./...` and `go build .` in `cli/`
produces the `eter` binary. The sidecars + orchestrator + shared engine client are one
Go module (`sidecars/`): `go build ./... && go vet ./... && go test ./...` there.

## Changes to the engine extension or the core patch

The SSI capture extension (`ext/eter_ssi/`) and the observe-mode patch (`pg/`) must be
re-validated on an assertion build (`--enable-cassert`). A non-assert or `-O0` build silently
hides invariant bugs. After any change there, run at minimum:

- `bash test/ssi.sh`, strict mode at SERIALIZABLE
- `bash test/observe.sh`, observe mode at READ COMMITTED, zero `40001`s
- `bash test/false-clean.sh`, the read-dependency completeness gate (must stay at 100% recall)
- the Postgres `isolation` + `regress` suites against the patched build

See [`pg/README.md`](pg/README.md) for how to build the patched engine and run these.

## Pull requests

- Keep changes focused; describe what you verified and paste the relevant test output.
- If tests fail or a step was skipped, say so plainly.
- **How your PR is merged.** This repository mirrors a private canonical repo, kept in sync with
  [Copybara](https://github.com/google/copybara). An accepted PR is imported into the canonical
  repo, merged there, and projected back here, so it ships in a following sync rather than as a
  direct merge of your branch. Your authorship is preserved on the import. Open the PR here as
  usual; nothing else is needed from you.
- AI-assisted contributions are welcome; EterDB itself was built that way (see "How this was
  built" in the [README](README.md)). The bar is the same either way: the code is yours to stand
  behind, and correctness-critical changes come with the passing test output above.
- By submitting a contribution you agree it is licensed under the Apache License 2.0 (see
  [LICENSE](LICENSE)).
