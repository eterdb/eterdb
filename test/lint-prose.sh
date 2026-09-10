#!/usr/bin/env bash
#
# lint-prose.sh - guard the repo's prose against AI "tells".
#
# Scans tracked prose (markdown, the website, and code comments/strings) for
# two classes of marker:
#
#   1. em-dashes (U+2014) and en-dashes (U+2013). Use ASCII punctuation
#      instead: a comma, colon, parenthesis, or a plain hyphen for numeric
#      ranges.
#   2. a blocklist of overused filler words and phrases (see WORD_PATTERNS).
#
# The check is intentionally scoped: CLAUDE.md and PLAN.md are internal
# authoring notes and are exempt, and this script exempts itself (it lists the
# forbidden words by definition). test/lint-prose-mutations.sh, test/prose-audit.sh
# and test/prose_audit.md are exempt for the same reason: one carries a sample of
# every marker, one greps for them, one quotes every one it found.
#
# Scope caveat, learned the hard way: FILES comes from `git ls-files`, so a NEW
# file is invisible to this check until it is staged. A local run can report
# clean and CI still fail on the same commit. Run it after `git add -A`. The site's "agent review" blockquotes
# (class="rev-body") are exempt too: they deliberately parody AI tells
# (em-dashes, "honestly", "it's worth noting") as satire, so the markers are
# the point. Everything else that ships or is read by a human is fair game.
#
# Exits non-zero (and prints file:line for every hit) when anything matches,
# so it can gate a pull request in CI. Run it locally the same way:
#
#     bash test/lint-prose.sh
#
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 2

# --- portability -------------------------------------------------------------
# This check must actually RUN on a contributor's machine, not just in CI. It
# previously used `grep -P ... 2>/dev/null` throughout, which made it a FALSE
# GREEN on macOS: BSD grep has no -P, so every invocation exited 2 with the
# error swallowed, and the empty output was indistinguishable from "no hits".
# The script then reported "clean" on a file full of em-dashes. That is the same
# class of silent drift as issue #197, so the rules here are:
#   1. POSIX-ish grep only. `-E` matches the word patterns identically, and the
#      dashes are matched as literal characters via `-F`, so no PCRE is needed.
#   2. Never send grep's stderr to /dev/null, and treat exit >= 2 as a BROKEN
#      CHECK, not as "no matches" (grep: 0 = hit, 1 = no hit, 2 = error).
# It also avoids `mapfile`, which macOS bash 3.2 does not have.

# Run grep, distinguishing "no match" from "the check failed to run", and drop
# exempt lines while we are here. The exemption filter is done INSIDE the
# function on purpose: callers use `hits=$(grep_or_die ...) || exit 2`, and a
# trailing `| grep -vF` at the call site would let pipefail report the filter's
# "no match" (1) instead of this function's "broken" (2), hiding the very
# failure the function exists to surface. Returns 0 (checked) or 2 (broken); it
# cannot exit the script directly, since it runs in a command substitution.
grep_or_die() { # <label> <grep args...>
  local label="$1"; shift
  local out rc
  out="$(grep "$@" 2>&1)"; rc=$?
  if [ "$rc" -ge 2 ]; then
    echo "prose-lint: BROKEN CHECK ($label): grep exited $rc" >&2
    echo "$out" >&2
    return 2
  fi
  if [ "${EXEMPT_ACTIVE:-0}" = 1 ]; then
    printf '%s' "$out" | grep -vF "$EXEMPT_LINE" || true
  else
    printf '%s' "$out"
  fi
  return 0
}

# --- scope -------------------------------------------------------------------
# Prose plus source files that carry human-language comments and strings.
FILES=()
while IFS= read -r _f; do FILES+=("$_f"); done < <(git ls-files \
  '*.md' \
  'site/*.html' 'site/*.js' 'site/*.css' \
  '*.go' '*.sql' '*.sh' '*.c' '*.h' '*.mjs' \
  '*.yml' '*.yaml' '*.toml' '*.sky' \
  'Dockerfile*' 'docker/Dockerfile*' \
  | grep -vxE 'CLAUDE\.md|PLAN\.md|test/lint-prose\.sh|test/lint-prose-mutations\.sh|test/prose-audit\.sh|test/prose_audit\.md')

[ "${#FILES[@]}" -gt 0 ] || { echo "prose-lint: BROKEN CHECK: no files in scope" >&2; exit 2; }

# --- markers -----------------------------------------------------------------
# em-dash (U+2014) and en-dash (U+2013), matched as literal characters with -F.
# The old raw-byte form needed -P; these are the same two characters.
DASH_CHARS=$'—\n–'

# Filler words and phrases. Kept tight and word-boundaried to avoid snagging
# legitimate technical terms; "surgical" (a product term) is deliberately NOT
# here. Patterns are case-insensitive PCRE.
WORD_PATTERNS=(
  '\bhonest(y|ly)?\b'
  '\bseamless(ly)?\b'
  '\bdelv(e|es|ed|ing)\b'
  '\bplethora\b'
  '\bmyriad\b'
  '\bmeticulous(ly)?\b'
  '\btestament\b'
  '\bmoreover\b'
  '\bfurthermore\b'
  '\bnuanced\b'
  '\bholistic\b'
  '\bboasts\b'
  '\btapestry\b'
  '\bbustling\b'
  '\bcutting-edge\b'
  '\bstate-of-the-art\b'
  '\bgame-chang(er|ing)\b'
  "\\bit'?s worth noting\\b"
  '\bat its core\b'
  '\bwhen it comes to\b'
  '\bpeace of mind\b'
  '\bfirst and foremost\b'
  '\blast but not least\b'
  # --- the LLM lexicon (see the note above) ---------------------------------
  # "lands" standing in for written / recorded / merged / shipped / ran /
  # arrived. No exception for a physical landing either: the animation comments
  # that meant it literally now say "stops at" and "settles on", which are more
  # precise anyway. Known cost: this also catches "landing page" and "landing
  # strip". Accepted, because ERE has no lookahead and the site already says
  # "homepage"; if a real need appears, narrow the rule rather than exempt a file.
  '\bland(s|ed|ing)\b'
  # "X lives in Y" for "X is in Y". The bare adjective is untouched: this needs
  # a preposition. "at" is deliberately NOT in the list, because "live at <url>"
  # and "which pane is live at this beat" are ordinary adjective uses.
  '\b(lives|live|lived|living)[[:space:]]+(in|inside|on|under|here|there|outside|alongside|behind|within)\b'
  # Vague motion verbs standing in for a named mechanism.
  '\b(wire|wires|wired|wiring) up\b'
  '\bthread(s|ed|ing)?( it| them| that| this)? through\b'
  '\bcarve[sd]? out\b'
  '\breach(es|ed)? for\b'
  '\blean(s|ed|ing)? on\b'
  # Nouns that gesture at a claim instead of making it.
  '\bthe unlock\b'
  '\bload.bearing\b'
  # Hyphenated too: "blast-radius-independent" slipped a space-anchored rule
  # twice, in site/README.md and sidecars/capture/README.md.
  '\bblast[ -]radius\b'
  '\bdead weight\b'
  '\brounding error\b'
  '\btable stakes\b'
  '\bsurface area\b'
)

# Lines exempt from every marker: the satirical "agent review" blockquotes,
# whose AI tells are intentional. Matched against the offending line's text.
#
# SCOPED to the site HTML that actually contains them (EXEMPT_FILES). It used to
# apply to every file in scope, which made it a repo-wide bypass: any line in any
# .md/.go/.sql/.sh could silence every marker just by containing this string.
# Only site/index.html carries it today, so the narrowing changes no result.
EXEMPT_LINE='class="rev-body"'
EXEMPT_FILES='site/*.html'

status=0

report() { # <label> <grep-output>
  if [ -n "$2" ]; then
    status=1
    echo "== $1 =="
    echo "$2"
    echo
  fi
}

for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue

  # The rev-body exemption applies only to the site HTML that hosts the parody.
  # shellcheck disable=SC2254  # EXEMPT_FILES is a glob on purpose
  case "$f" in
    $EXEMPT_FILES) EXEMPT_ACTIVE=1 ;;
    *)             EXEMPT_ACTIVE=0 ;;
  esac

  hits=$(grep_or_die "em/en dash" -nF "$DASH_CHARS" "$f") || exit 2
  report "em/en dash: $f" "$hits"

  for pat in "${WORD_PATTERNS[@]}"; do
    hits=$(grep_or_die "marker word $pat" -niE "$pat" "$f") || exit 2
    report "marker word ($pat): $f" "$hits"
  done
done

if [ "$status" -ne 0 ]; then
  echo "prose-lint: found AI-tell markers above. Rewrite them (see test/lint-prose.sh header)." >&2
else
  echo "prose-lint: clean."
fi
exit "$status"
