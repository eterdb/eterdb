# Security Policy

EterDB is a data-recovery system: a correctness bug in dependency capture can mean silent data
corruption (a "false clean"), so we take reports seriously.

## Reporting a vulnerability

Please **do not** open a public issue for security-sensitive reports. Instead, use GitHub's
private vulnerability reporting ("Report a vulnerability" under the repository's Security tab),
or contact the maintainers privately.

Include, where possible:

- the affected component (engine SQL, `eter_ssi`, the observe patch, a sidecar, or the CLI),
- a minimal reproduction (a SQL/CLI sequence or a failing test),
- the Postgres version and whether you were on stock or the patched build, and
- the impact you observed.

We will acknowledge your report, work with you on a fix, and credit you (unless you prefer
otherwise) when the fix ships.

## Scope notes

- EterDB reverses **database state only**. It does not undo external side effects (charges,
  emails, webhooks); that boundary is by design, not a vulnerability.
- Under load, the read-dependency graph may **over-approximate** (more conflict reviews), the
  safe direction. A report of an *under*-approximation (a missed read dependency / false clean)
  is a genuine security-relevant bug and is exactly what `test/false-clean.sh` guards.
