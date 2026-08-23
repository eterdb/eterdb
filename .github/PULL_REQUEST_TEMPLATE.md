<!-- Thanks for contributing to EterDB! -->

**What & why**
What does this change and why?

**How it was verified**
Correctness in EterDB is established by reproducible tests, not by who wrote the code.
Which suites did you run, and what was the result? (e.g. `go test ./...`,
`bash test/e2e.sh`, `test/ssi.sh` / `observe.sh` on the patched engine, a storage/e2e suite.)

**Checklist**
- [ ] Targets **PG18** (the sole supported major)
- [ ] Keeps the CLI / undo SQL surface stable (change the substrate, not the surface)
- [ ] Tests added/updated and passing
- [ ] Docs updated if behavior changed
