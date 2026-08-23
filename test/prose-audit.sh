#!/usr/bin/env bash
#
# prose-audit.sh - count sentence-architecture markers in the repo's prose.
#
# Companion to test/lint-prose.sh, which GATES what can be matched exactly: dash
# characters, the filler blocklist, and the LLM lexicon ("lands", "lives in",
# "blast radius", "load-bearing" and the rest). This one COUNTS what needs
# judgement: the recurring sentence shapes catalogued in test/prose_audit.md
# against https://github.com/anthropics/claude-code/issues/77136, plus the
# lexicon terms that have legitimate uses here and so cannot be gated.
#
# The division of labour is the point. A word with no legitimate use in this
# repo belongs in lint-prose.sh, where CI stops it. A word that is sometimes
# right ("deliberately lossy" is doing work; "deliberately boring" was posturing)
# belongs here, where a human reads the delta.
#
# It reports, it does not gate. Every family below has legitimate instances, so
# a hard zero would be wrong and a budget would need a baseline nobody maintains.
# Run it before and after a prose change and read the delta:
#
#     bash test/prose-audit.sh
#
# Two scopes are printed per family:
#   all     every tracked file lint-prose.sh scans (186 files: prose plus source
#           comments and strings)
#   md+site markdown plus the three site pages, the prose a reader actually sees
#
# Exits 0 unless the scan itself breaks (grep error, empty scope), which exits 2
# for the same reason lint-prose.sh does: a check that silently reports nothing
# is worse than no check.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

ALL=()
while IFS= read -r f; do ALL+=("$f"); done < <(git ls-files \
  '*.md' 'site/*.html' 'site/*.js' 'site/*.css' \
  '*.go' '*.sql' '*.sh' '*.c' '*.h' '*.mjs' \
  | grep -vxE 'test/prose_audit\.md|test/prose-audit\.sh')

PROSE=()
while IFS= read -r f; do PROSE+=("$f"); done < <(git ls-files '*.md' 'site/*.html' \
  | grep -vxE 'test/prose_audit\.md')

[ "${#ALL[@]}" -gt 0 ] && [ "${#PROSE[@]}" -gt 0 ] || {
  echo "prose-audit: BROKEN CHECK: no files in scope" >&2; exit 2; }

# <label>@<extended regex>. Kept as families rather than one blob so a delta
# points at which habit moved.
FAMILIES=(
  'antithesis tail (", not X" / ", never X")@, (not|never) (a|an|the|because|by|for|to|just|only|from|in|on|at|with|one|its|your|what|how|where)\b'
  'negation lead ("X is not a Y")@\b(is|are|was|were|isn.t|aren.t|wasn.t|weren.t) not (a|an|the) '
  'cleft emphasis ("X is what Y", "which is why")@\b(is|are) (exactly |precisely )?what\b|\bwhich is why\b|\bthat.s why\b'
  'appositive verdict ("the point", "the catch", "the price")@\bthe (point|catch|price|trick|answer|question|failure mode|standing risk|escape hatch)\b|\bload.bearing\b'
  'defensive "real X"@\breal (postgres|ssi|c extension|architecture|system)\b|\b(undo|analysis|capture) is real\b'
  'metaphor@brain surgery|dirty hack|a moat|very bad day'
  # "deliberately" and "genuinely" were candidates and are deliberately absent:
  # 44 and 10 uses, nearly all marking real intent in code comments, so their
  # volume drowns the signal. What is left is register rather than meaning.
  'LLM lexicon (judgement calls)@\bthe shape of\b|\bof the same shape\b|\b(connection|deployment) story\b|\bposture\b|\bunder the hood\b|\bfirst-class\b|\b(sits|sat) (in|on|at|somewhere)\b'
)

count() { # <regex> <file...>
  local re="$1"; shift
  local out rc
  out="$(grep -inE "$re" "$@" 2>&1)"; rc=$?
  if [ "$rc" -ge 2 ]; then
    echo "prose-audit: BROKEN CHECK: grep exited $rc" >&2
    echo "$out" >&2
    return 2
  fi
  [ -n "$out" ] && printf '%s\n' "$out" | wc -l | tr -d ' ' || echo 0
  return 0
}

printf '%-56s %6s %8s\n' 'family' 'all' 'md+site'
for entry in "${FAMILIES[@]}"; do
  label="${entry%%@*}"
  re="${entry#*@}"
  a=$(count "$re" "${ALL[@]}")   || exit 2
  p=$(count "$re" "${PROSE[@]}") || exit 2
  printf '%-56s %6s %8s\n' "$label" "$a" "$p"
done

echo
echo "scope: ${#ALL[@]} tracked files (all), ${#PROSE[@]} (md+site)"
echo "reading: test/prose_audit.md"
