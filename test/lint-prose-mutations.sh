#!/usr/bin/env bash
#
# lint-prose-mutations.sh - prove test/lint-prose.sh can actually fail.
#
# Sibling of test/lint-site-spec-mutations.sh, and it exists for the same reason:
# a guard nobody has seen reject anything is indistinguishable from a guard that
# silently passes. lint-prose.sh was a false green on macOS once already (BSD
# grep has no -P; see its header), so its rules get a positive test.
#
# Two directions per run:
#   POSITIVE  a sample containing the marker MUST match some pattern
#   NEGATIVE  a legitimate phrase MUST NOT match any pattern
#
# It reads the pattern list out of lint-prose.sh rather than restating it, so a
# rule added there without a sample here shows up as an uncovered pattern.
# Add a sample with every rule.
#
#     bash test/lint-prose-mutations.sh
#
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
exec python3 - "$@" <<'PY'
import re, sys

src = open('test/lint-prose.sh').read()
block = src[src.index('WORD_PATTERNS=('):]
block = block[:block.index('\n)')]
# Single-quoted entries are literal. Double-quoted ones go through bash's own
# unescaping first, so "\\b" reaches grep as "\b" and must be unescaped here too.
pats = []
for q, body in re.findall(r"^\s*(['\"])(.+?)\1\s*$", block, re.M):
    pats.append(body.replace('\\\\', '\\') if q == '"' else body)
if not pats:
    print("prose-mutations: BROKEN CHECK: no patterns parsed out of lint-prose.sh", file=sys.stderr)
    sys.exit(2)
rx = [(p, re.compile(p.replace('[[:space:]]', r'\s'), re.I)) for p in pats]

POSITIVE = [
    ("honesty",        "Let me be honest about the cost."),
    ("seamless",       "A seamless migration path."),
    ("delve",          "We delve into the details."),
    ("plethora",       "A plethora of options."),
    ("myriad",         "Myriad configurations."),
    ("meticulous",     "Meticulously tested."),
    ("testament",      "A testament to the design."),
    ("moreover",       "Moreover, it is fast."),
    ("furthermore",    "Furthermore, it scales."),
    ("nuanced",        "A nuanced tradeoff."),
    ("holistic",       "A holistic approach."),
    ("boasts",         "It boasts full coverage."),
    ("tapestry",       "A rich tapestry of features."),
    ("bustling",       "A bustling ecosystem."),
    ("cutting-edge",   "Cutting-edge storage."),
    ("state-of-art",   "State-of-the-art capture."),
    ("game-changing",  "A game-changing feature."),
    ("worth noting",   "It's worth noting the lag."),
    ("at its core",    "At its core it is Postgres."),
    ("when it comes",  "When it comes to undo, it wins."),
    ("peace of mind",  "Backups for peace of mind."),
    ("first foremost", "First and foremost, correctness."),
    ("last not least", "Last but not least, the CLI."),
    # --- LLM lexicon ---
    ("lands",          "The change lands in the store."),
    ("landed",         "The fix landed yesterday."),
    ("lives in",       "The undo logic lives in the engine."),
    ("live inside",    "Predicate locks live inside the backend."),
    ("blast radius",   "That is the blast radius."),
    ("blast-radius",   "Not yet blast-radius-independent of the main DB."),
    ("load-bearing",   "This rule is load-bearing."),
    ("dead weight",    "It was all dead weight."),
    ("rounding error", "A rounding error at most."),
    ("the unlock",     "Instrumentation is the unlock."),
    ("wire up",        "We wire up the sidecar."),
    ("leans on",       "It leans on SSI."),
    ("thread through", "Thread it through the planner."),
    ("carve out",      "Carve out a seam."),
    ("reach for",      "Reach for the simpler tool."),
    ("surface area",   "Small surface area."),
    ("table stakes",   "That is table stakes."),
]

# Legitimate phrasing the gate must leave alone. The adjective uses of "live"
# are the ones that made "at" unsafe as a gated preposition.
NEGATIVE = [
    "The demo is live at localhost:4400.",
    "Which pane is live at each beat.",
    "Reverse one transaction on a live database.",
    "The engine is in the first container.",
    "History is stored in the meta store.",
    "The fix shipped in 1.26.6.",
    "Surgical, dependency-aware undo.",
]

fails = 0
for label, text in POSITIVE:
    if not any(r.search(text) for _, r in rx):
        print(f"NOT CAUGHT [{label}]: {text}"); fails += 1
for text in NEGATIVE:
    hits = [p for p, r in rx if r.search(text)]
    if hits:
        print(f"FALSE POSITIVE: {text!r} matched {hits}"); fails += 1

covered = {p for _, text in POSITIVE for p, r in rx if r.search(text)}
uncovered = [p for p, _ in rx if p not in covered]
for p in uncovered:
    print(f"UNCOVERED PATTERN (add a sample): {p}"); fails += 1

if fails:
    print(f"prose-mutations: {fails} problem(s) above.", file=sys.stderr); sys.exit(1)
print(f"prose-mutations: all {len(POSITIVE)} markers caught, "
      f"{len(NEGATIVE)} legitimate phrases untouched, {len(rx)} patterns covered.")
PY
