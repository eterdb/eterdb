#!/usr/bin/env bash
#
# lint-harness.sh - guard the local-only harnesses against silent drift on
# shared in-engine contracts.
#
# Why (issue #197): most of the harness suite is local-only and not CI-gated,
# because it builds extensions from source, needs the patched engine, or seeds
# ~1M-row fixtures. So a change to a contract the harnesses share can break an
# arbitrary subset of them, and the breakage surfaces only whenever someone next
# runs that particular script by hand. #188 (capture is sidecar-only) updated six
# scripts and missed test/compat.sh, which then failed every coexist check for
# three days before #192 tripped over it. Auditing for #197 turned up a seventh
# miss in test/parallel-harvest.sh.
#
# This is the cheap half of the answer: a static rule per contract, checked in
# seconds with no database. test/capture-contract.sh is the other half, checking
# the same contract's actual BEHAVIOUR against a live Postgres. Static rules
# catch the script that forgot to opt in; the contract test catches the engine
# changing under scripts that did.
#
#     bash test/lint-harness.sh
#
# Adding a contract: append a RULES entry. Each is @-delimited,
#   <name>@<call regex>@<satisfier regex>@<hint>
# meaning "any file under test/ matching <call regex> must also match
# <satisfier regex>". Exempt a file by adding it to EXEMPT with a reason.
#
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

# --- contracts ---------------------------------------------------------------
RULES=(
  # eter.track refuses when no capture sidecar is attached (#188), so a harness
  # that tracks in-engine must either set the test-only capture_mode override or
  # stand up a real sidecar. Either satisfies the contract: capture-refuse.sh
  # attaches a live pg_recvlogical consumer, capture-diff.sh runs the real
  # eter-capture binary. This exact rule would have caught the compat.sh miss.
  "capture-mode@eter\.track(_all)?\(@eter\.capture_mode|pg_recvlogical|eter-capture|make capture|go run .*capture@a script that calls eter.track must SET eter.capture_mode ('trigger' or 'sidecar'), or stand up a capture sidecar"
)

# Files a rule does not apply to, as <rule>:<path>. Keep each entry justified:
# an exemption is a claim that the contract is met somewhere this check cannot
# see, so it should name where.
EXEMPT=(
  # Driven by test/false-clean.sh, which sets the mode durably on the database
  # (ALTER DATABASE ... SET eter.capture_mode='trigger') before invoking node.
  "capture-mode:test/false-clean/harness.mjs"
)

exempt() { # <rule> <path>
  local e
  for e in ${EXEMPT[@]+"${EXEMPT[@]}"}; do [ "$e" = "$1:$2" ] && return 0; done
  return 1
}

# --- check -------------------------------------------------------------------
# Plain arrays and a read loop, no `mapfile` or `declare -A`: macOS ships bash
# 3.2, and a guard that only runs in CI is the problem this file exists to fix.
FILES=()
while IFS= read -r f; do FILES+=("$f"); done < <(
  git ls-files 'test/*' | grep -E '\.(sh|mjs|js|sql|py)$' | grep -vxE 'test/lint-harness\.sh')

status=0
for rule in "${RULES[@]}"; do
  # Fields are @-delimited: the satisfier is itself an alternation, so `|` is
  # not available as the separator.
  name="${rule%%@*}";       rest="${rule#*@}"
  call="${rest%%@*}";       rest="${rest#*@}"
  satisfier="${rest%%@*}";  hint="${rest#*@}"
  for f in "${FILES[@]}"; do
    [ -f "$f" ] || continue
    exempt "$name" "$f" && continue
    grep -qE "$call" "$f" || continue
    grep -qE "$satisfier" "$f" && continue
    status=1
    echo "== $name: $f =="
    echo "   $hint"
    grep -nE "$call" "$f" | sed 's/^/   /'
    echo
  done
done

if [ "$status" -ne 0 ]; then
  echo "harness-lint: the scripts above call a contract they do not opt into." >&2
  echo "See test/lint-harness.sh for the rule, test/capture-contract.sh for the behaviour." >&2
else
  echo "harness-lint: clean."
fi
exit "$status"
