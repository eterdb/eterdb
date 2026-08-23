#!/usr/bin/env bash
#
# lint-site-spec-mutations.sh - prove test/lint-site-spec.sh can actually fail.
#
# A green check that cannot go red is worse than no check: it reports a pass
# while asserting nothing. That is the issue #197 failure class, and a linter
# made of ~60 greps is exactly where it hides, because a pattern that stops
# matching looks identical to a site that stopped violating.
#
# So: for every rule lint-site-spec.sh enforces, break the thing that rule is
# about, and require the linter to notice. One mutation per rule. If any
# mutation slips through, this script fails and names it.
#
# It works on a COPY: site/ is snapshotted to a temp dir up front and restored
# after each mutation, including on interrupt. It never touches git, so it is
# safe to run with uncommitted work in the tree. (An earlier version restored
# with `git checkout -- site/`, which reverted the working tree to HEAD and
# threw away exactly the changes under test. Hence the snapshot.)
#
# Takes about a minute. Run it after changing lint-site-spec.sh, and add a
# mutation whenever you add a rule:
#
#     bash test/lint-site-spec-mutations.sh
#
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 2

# Dependencies are deliberately limited to what a bare CI runner has: bash,
# coreutils, perl, and python3's standard library. Nothing here may need a pip
# install. The asset-generation scripts under site/assets/ DO need Pillow, but
# they are not a build step and are never run from CI.
for tool in perl python3; do
  command -v "$tool" >/dev/null || { echo "mutations: needs $tool" >&2; exit 2; }
done

BACKUP=$(mktemp -d)
cp -a site "$BACKUP/site"
restore() { rm -rf site && cp -a "$BACKUP/site" site; }
trap 'restore; rm -rf "$BACKUP"' EXIT INT TERM

caught=0
missed=0

# try <label> <shell command that breaks one rule>
#
# A mutation that fails to APPLY is reported separately from one that applies
# and goes unnoticed. Without that split, a typo in a mutation reads as a
# passing test, which is the same lie this script exists to catch.
try() {
  local label="$1"; shift
  if ! eval "$@" >/dev/null 2>&1; then
    printf 'BROKEN  %-38s mutation did not apply\n' "$label"
    missed=$((missed + 1)); restore; return
  fi
  local out rc
  out=$(bash test/lint-site-spec.sh 2>&1); rc=$?
  restore
  if [ "$rc" -ne 0 ]; then
    # Exit 1 prints a FAIL line; exit 2 is the linter's own "BROKEN CHECK"
    # guard, which fires when a file it needs has gone missing. Both count as
    # caught, so report whichever line the run produced.
    printf 'caught  %-38s %s\n' "$label" \
      "$(printf '%s' "$out" | grep -m1 -E 'FAIL|BROKEN CHECK' | sed 's/^ *FAIL  //')"
    caught=$((caught + 1))
  else
    printf 'MISSED  %-38s linter stayed green\n' "$label"
    missed=$((missed + 1))
  fi
}

# perl -0pi wrapper. NOTE: the replacement side of s/// interpolates, so a
# pattern containing @ (say "@type") silently becomes an empty array splice and
# matches nothing. Use the py() helper for anything with an @ in it.
P() { perl -0pi -e "$1" "$2"; }

# Literal string replace, for patterns perl would interpolate.
py() { # <file> <needle> <replacement>
  python3 -c 'import pathlib,sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
if sys.argv[2] not in s: raise SystemExit(1)
p.write_text(s.replace(sys.argv[2], sys.argv[3]))' "$@"
}

echo "Mutating site/, one rule at a time. Every line must say 'caught'."
echo

# ── Foundations ──────────────────────────────────────────────────────────────
try "doctype removed"          'P "s/^<!doctype html>\n//" site/index.html'
try "lang attr removed"        'P "s/<html lang=\"en\">/<html>/" site/index.html'
try "charset removed"          'P "s|<meta charset=\"utf-8\" />||" site/index.html'
try "viewport scaling disabled" 'P "s/initial-scale=1/initial-scale=1, user-scalable=no/" site/index.html'
try "title emptied"            'P "s|<title>[^<]*</title>|<title></title>|" site/tech.html'
try "two titles"               'P "s|<title>|<title>x</title><title>|" site/tech.html'
try "description dropped"      'P "s|<meta name=\"description\"|<meta name=\"desc\"|" site/tech.html'
try "color-scheme dropped"     'P "s|<meta name=\"color-scheme\" content=\"light\" />||" site/tech.html'
try "theme-color dropped"      'P "s|<meta name=\"theme-color\"[^>]*>||" site/tech.html'
try "favicon.ico link gone"    'P "s|<link rel=\"icon\" href=\"/favicon.ico\" sizes=\"32x32\" />||" site/index.html'
try "apple-touch-icon gone"    'P "s|<link rel=\"apple-touch-icon\"[^>]*>||" site/index.html'
try "manifest link gone"       'P "s|<link rel=\"manifest\"[^>]*>||" site/index.html'
try "icon file deleted"        'rm site/assets/icon-512.png'
try "canonical dropped"        'P "s|<link rel=\"canonical\"[^>]*/>||" site/tech.html'
try "og:image dropped"         'P "s|property=\"og:image\" content|property=\"og:img\" content|" site/tech.html'

# ── SEO ──────────────────────────────────────────────────────────────────────
try "heading level skipped"    'P "s|<h3>Then, the ZFS era</h3>|<h5>Then, the ZFS era</h5>|" site/tech.html'
try "second h1 added"          'P "s|<h2>1\. Trans|<h1>1. Trans|" site/tech.html'
try "noindex on homepage"      'P "s|<title>|<meta name=\"robots\" content=\"noindex\"><title>|" site/index.html'
try "404 made indexable"       'P "s|content=\"noindex, follow\"|content=\"index, follow\"|" site/404.html'
try "sitemap/canonical drift"  'P "s|https://eterdb.com/tech|https://eterdb.com/technical|" site/sitemap.xml'
try "broken JSON-LD"           'py site/tech.html "\"BreadcrumbList\"," "\"BreadcrumbList\",,"'
try "breadcrumbs removed"      'P "s/BreadcrumbList/ItemList/" site/tech.html'
try "uppercase internal URL"   'P "s|href=\"/tech\"|href=\"/Tech\"|" site/index.html'
try "robots.txt loses sitemap" 'P "s|Sitemap: https://eterdb.com/sitemap.xml||" site/robots.txt'

# ── Accessibility ────────────────────────────────────────────────────────────
try "skip link removed"        'P "s|<a class=\"skip-link\" href=\"#main\">Skip to main content</a>||" site/index.html'
try "skip link not first"      'P "s|(<a class=\"skip-link\"[^<]*</a>)|<a href=\"/x\">x</a>\$1|" site/index.html'
try "main id removed"          'P "s|<main id=\"main\">|<main>|" site/index.html'
try "main landmark removed"    'P "s|<main class=\"doc\" id=\"main\">|<div id=\"main\">|" site/tech.html'
try "img alt removed"          'P "s| alt=\"A small elephant[^\"]*\"||" site/index.html'
try "button label removed"     'P "s| aria-label=\"Menu\"||" site/index.html'
try "table caption removed"    'P "s|<caption>[^<]*</caption>||" site/tech.html'
try "th scope removed"         'P "s|<th scope=\"col\">|<th>|g" site/tech.html'
try "focus outline killed"     'printf "\n.x:focus { outline: none; }\n" >> site/styles.css'
try "reduced-motion dropped"   'P "s/prefers-reduced-motion/prefers-motion/g" site/styles.css'

# ── Security ─────────────────────────────────────────────────────────────────
try "HSTS removed"             'P "s|    Strict-Transport-Security = \"[^\"]*\"\n||" site/netlify.toml'
try "HSTS preload added"       'P "s|includeSubDomains\"|includeSubDomains; preload\"|" site/netlify.toml'
try "CSP removed"              'P "s|    Content-Security-Policy = \"[^\"]*\"\n||" site/netlify.toml'
try "CSP unsafe-eval"          'P "s|script-src .self.|script-src '\''self'\'' '\''unsafe-eval'\''|" site/netlify.toml'
try "CSP unsafe-inline script" 'P "s|script-src .self.|script-src '\''self'\'' '\''unsafe-inline'\''|" site/netlify.toml'
try "CSP script wildcard"      'P "s|script-src .self.|script-src '\''self'\'' *|" site/netlify.toml'
try "frame-ancestors gone"     'P "s|frame-ancestors .none.; ||" site/netlify.toml'
try "X-Frame-Options gone"     'P "s|    X-Frame-Options = \"DENY\"\n||" site/netlify.toml'
try "nosniff gone"             'P "s|    X-Content-Type-Options = \"nosniff\"\n||" site/netlify.toml'
try "COOP removed"             'P "s|    Cross-Origin-Opener-Policy = \"[^\"]*\"\n||" site/netlify.toml'
try "CORP removed"             'P "s|    Cross-Origin-Resource-Policy = \"[^\"]*\"\n||" site/netlify.toml'
try "dead XSS header added"    'P "s|    X-Frame-Options|    X-XSS-Protection = \"1; mode=block\"\n    X-Frame-Options|" site/netlify.toml'
try "permissions camera on"    'P "s|camera=\(\)|camera=(self)|" site/netlify.toml'
try "referrer weakened"        'P "s|Referrer-Policy = \"strict-origin-when-cross-origin\"|Referrer-Policy = \"unsafe-url\"|" site/netlify.toml'
try "security.txt expired"     'P "s|Expires: 2027|Expires: 2026|" site/.well-known/security.txt'
try "security.txt deleted"     'rm site/.well-known/security.txt'
try "undeclared CDN script"    'P "s|<script src=\"/main.js\" defer>|<script src=\"https://cdn.jsdelivr.net/npm/x.js\"></script><script src=\"/main.js\" defer>|" site/index.html'
try "CSP drops allowed origin" 'P "s| https://buttons.github.io||g" site/netlify.toml'

# ── Performance ──────────────────────────────────────────────────────────────
try "font from third party"    'P "s|/assets/fonts/inter-latin.woff2|https://fonts.gstatic.com/x.woff2|" site/fonts.css'
try "font-display dropped"     'py site/fonts.css "  font-display: swap;
" ""'
try "font preloads removed"    'P "s|<link rel=\"preload\" href=\"/assets/fonts/[^>]*/>||g" site/index.html'
try "render-blocking script"   'P "s|</head>|<script src=\"/x.js\"></script></head>|" site/index.html'
try "script loses defer"       'P "s|<script src=\"/main.js\" defer>|<script src=\"/main.js\">|" site/index.html'
try "img width/height removed" 'P "s| width=\"2400\" height=\"626\"||" site/index.html'
try "picture avif dropped"     'P "s|<source srcset=\"/assets/elephant-biplane.avif\" type=\"image/avif\" />||" site/index.html'
# Random bytes rather than a re-encoded image: the budget rule stats the file,
# it does not decode it, and generating a genuinely large WebP would put Pillow
# on this script's dependency list. It is not on a CI runner by default, and the
# mutation silently failing to apply is how this step first went red.
try "asset over budget"        'head -c 102400 /dev/urandom > site/assets/elephant-biplane.webp'
try "orphaned asset added"     'cp site/assets/og.png site/assets/orphan.png'
try "HTML cached immutable"    'P "s|max-age=0, must-revalidate|max-age=31536000, immutable|" site/netlify.toml'
try "assets go immutable"      'P "s|public, max-age=86400, stale-while-revalidate=604800|public, max-age=31536000, immutable|" site/netlify.toml'

# ── Agent readiness ──────────────────────────────────────────────────────────
try "llms.txt ctype dropped"   'P "s|text/markdown; charset=utf-8|text/plain|" site/netlify.toml'
try "AI crawler policy gone"   'P "s|User-agent: ClaudeBot\n||" site/robots.txt'

# ── Resilience ───────────────────────────────────────────────────────────────
try "404 page deleted"         'rm site/404.html'
try "404 gutted"               'python3 -c "import pathlib
p = pathlib.Path(\"site/404.html\"); s = p.read_text()
i, j = s.find(\"<main\"), s.find(\"</main>\")
p.write_text(s[:i] + \"<main id=\\\"main\\\"><h1>404</h1></main>\" + s[j + 7:])"'
try "catch-all redirect"       'printf "\n[[redirects]]\n  from = \"/*\"\n  to = \"/\"\n  status = 302\n" >> site/netlify.toml'
try "manifest invalid JSON"    'P "s|\"name\": \"eterDB\",|\"name\": \"eterDB\",,|" site/site.webmanifest'
try "maskable icon dropped"    'P "s|\"purpose\": \"maskable\"|\"purpose\": \"any\"|" site/site.webmanifest'
try "manifest ctype dropped"   'P "s|application/manifest\+json|text/html|" site/netlify.toml'
try "content JS-assembled"     'python3 -c "import pathlib
p = pathlib.Path(\"site/tech.html\"); s = p.read_text(); i = s.find(\"<main\")
p.write_text(s[:i] + \"<main class=\\\"doc\\\" id=\\\"main\\\"><h1>x</h1></main></body></html>\")"'

echo
if [ "$missed" -gt 0 ]; then
  echo "mutations: $caught caught, $missed NOT caught."
  echo "A rule above asserts nothing. Fix the rule, not this file."
  exit 1
fi
echo "mutations: all $caught mutations caught."
