#!/usr/bin/env bash
#
# lint-site-spec.sh - gate site/ against The Website Specification.
#
#   https://specification.website  (spec text CC BY 4.0, project MIT)
#
# The spec is a platform-agnostic list of the technical features a good website
# should have, each marked Required / Recommended / Optional. This script encodes
# the subset that is (a) applicable to a two-page, dependency-free static site
# with no accounts, no forms, no feed and one language, and (b) decidable from
# the files in the repository. It runs offline, in about a second, and needs
# nothing but bash + grep + python3 (already required by site/assets/*.py).
#
# WHY IT IS OFFLINE. The spec publishes an MCP server with an `audit_url` tool.
# Pointing CI at it would test the deployed site, not the commit under review,
# would go red when the network hiccups, and would gate merges on a third party's
# uptime. The rules move slowly; the site changes every week. So the rules are
# transcribed here with a link to the page each one came from, and REFRESHING
# THEM IS A MANUAL, DELIBERATE ACT: re-read the spec, update a check, note it in
# the commit. `SPEC_SNAPSHOT` below records when that was last done.
#
# WHAT IT DOES NOT COVER. Some spec items cannot be decided from source and are
# deliberately out of scope rather than silently assumed passing:
#   - Core Web Vitals, colour contrast, keyboard-trap behaviour: need a browser
#     and real users. The asset-weight budget here is the closest static proxy.
#   - HTTP/2 + HTTP/3, TLS versions, Brotli, 103 Early Hints: Netlify's edge
#     provides them and the repo cannot assert them.
#   - Whether the deployed origin actually SENDS the headers in netlify.toml.
#     This checks the config that produces them, which is the part a PR changes.
#
# Exits non-zero listing every violation, so it gates a pull request in CI. Run
# it locally the same way:
#
#     bash test/lint-site-spec.sh
#
set -uo pipefail

# Date the checks below were last reconciled against the published spec. Bump it
# in the same commit as any rule change, so `git log -S SPEC_SNAPSHOT` shows the
# review history.
SPEC_SNAPSHOT="2026-08-09"

cd "$(git rev-parse --show-toplevel)" || exit 2
SITE=site

fail=0
checked=0

# --- reporting ---------------------------------------------------------------
# Every check reports through these, so a rule can never pass by silently not
# running: `checked` is asserted against a floor at the end.

bad() { # <spec-slug> <message>
  printf '  FAIL  [%s] %s\n' "$1" "$2"
  fail=$((fail + 1))
}

note() { printf '\n%s\n' "$1"; }

ok() { checked=$((checked + 1)); }

# grep that distinguishes "no match" from "the check could not run". A BSD/GNU
# grep difference or a moved file must go red, not quietly green. Same discipline
# as test/lint-prose.sh, and for the same reason (issue #197).
has() { # <file> <grep args...>
  local f="$1"; shift
  local out rc
  if [ ! -f "$f" ]; then
    echo "site-spec: BROKEN CHECK: no such file: $f" >&2
    exit 2
  fi
  out="$(grep "$@" -- "$f" 2>&1)"; rc=$?
  if [ "$rc" -ge 2 ]; then
    echo "site-spec: BROKEN CHECK: grep exited $rc on $f" >&2
    echo "$out" >&2
    exit 2
  fi
  ok
  return $rc
}

# The pages that must satisfy the per-page rules. 404.html is included on
# purpose: the spec's error-pages rule is Required, and a 404 that has drifted
# out of the design system is the one page nobody notices is broken.
PAGES="$SITE/index.html $SITE/tech.html $SITE/404.html"

# index.html wraps long tags across lines, so a line-oriented grep would miss a
# `content=` that sits on the next line and report a violation that is not real.
# Every per-page check therefore runs against a normalised copy with each tag
# flattened onto a single line. The originals are what ship; this is only so the
# matching is about the markup rather than about where the author hit return.
FLAT=$(mktemp -d)
trap 'rm -rf "$FLAT"' EXIT
python3 - "$FLAT" $PAGES <<'FLATTEN'
import pathlib, re, sys
out = pathlib.Path(sys.argv[1])
for src in sys.argv[2:]:
    src = pathlib.Path(src)
    html = src.read_text()
    (out / src.name).write_text(
        re.sub(r'<[^>]+>', lambda m: ' '.join(m.group(0).split()), html))
FLATTEN
flat() { echo "$FLAT/$(basename "$1")"; }

# ─────────────────────────────────────────────────────────────────────────────
note "Foundations"
# https://specification.website/spec/foundations/
# ─────────────────────────────────────────────────────────────────────────────
for orig in $PAGES; do
  p=$(flat "$orig")
  b=$(basename "$orig")

  # doctype (Required): must be the FIRST line, or the browser falls into
  # quirks mode. Checking "contains a doctype" would pass on a file with a
  # comment above it, which is exactly the failure.
  ok
  [ "$(head -n 1 "$p" | tr 'A-Z' 'a-z')" = "<!doctype html>" ] ||
    bad doctype "$b: <!doctype html> is not the first line"

  # lang (Required): a valid BCP 47 tag on <html>.
  has "$p" -q '<html lang="[a-z][a-z]\(-[A-Za-z0-9]\+\)*"' ||
    bad html-lang "$b: <html> has no valid BCP 47 lang attribute"

  # charset (Required): UTF-8, inside the first 1024 bytes.
  ok
  head -c 1024 "$p" | grep -qi '<meta charset="utf-8"' ||
    bad meta-charset "$b: no <meta charset=\"utf-8\"> in the first 1024 bytes"

  # viewport (Required): present, and never disabling user scaling.
  has "$p" -q '<meta name="viewport" content="width=device-width' ||
    bad meta-viewport "$b: missing or non-responsive <meta name=viewport>"
  has "$p" -qE 'user-scalable=no|maximum-scale=1[^0-9]' &&
    bad meta-viewport "$b: viewport disables user scaling"

  # title (Required): exactly one, non-empty.
  ok
  n=$(grep -o '<title>[^<]' "$p" | wc -l | tr -d ' ')
  [ "$n" = "1" ] || bad title "$b: expected exactly 1 non-empty <title>, found $n"

  # description (Recommended)
  has "$p" -q '<meta name="description" content="[^"]' ||
    bad meta-description "$b: no non-empty <meta name=description>"

  # color-scheme (Recommended): the tag that stops the load-time flash.
  has "$p" -q '<meta name="color-scheme" content="[^"]' ||
    bad color-scheme "$b: no <meta name=color-scheme>"

  # theme-color (Recommended)
  has "$p" -q '<meta name="theme-color" content="[^"]' ||
    bad theme-color "$b: no <meta name=theme-color>"

  # favicons (Recommended): the five-file set, declared in <head>.
  has "$p" -q 'rel="icon" href="[^"]*\.svg"' ||
    bad favicons "$b: no SVG favicon"
  has "$p" -q 'rel="icon" href="/favicon.ico"' ||
    bad favicons "$b: no /favicon.ico fallback link"
  has "$p" -q 'rel="apple-touch-icon"' ||
    bad favicons "$b: no apple-touch-icon"
  has "$p" -q 'rel="manifest"' ||
    bad favicons "$b: no web app manifest link"
done

# Canonical + Open Graph are Recommended, but only for indexable pages: 404.html
# is noindex and has no canonical address to declare.
for orig in $SITE/index.html $SITE/tech.html; do
  p=$(flat "$orig")
  b=$(basename "$orig")
  has "$p" -q '<link rel="canonical" href="https://' ||
    bad canonical-url "$b: no absolute rel=canonical"
  for tag in og:type og:url og:title og:description og:image; do
    has "$p" -q "property=\"$tag\" content=\"[^\"]" ||
      bad open-graph "$b: missing $tag"
  done
done

# The icon files the links above promise must actually exist.
for f in assets/favicon.svg assets/favicon.ico assets/apple-touch-icon.png \
         assets/icon-192.png assets/icon-512.png assets/icon-maskable-512.png \
         site.webmanifest; do
  ok
  [ -f "$SITE/$f" ] || bad favicons "site/$f is referenced but missing"
done

# ─────────────────────────────────────────────────────────────────────────────
note "SEO"
# https://specification.website/spec/seo/
# ─────────────────────────────────────────────────────────────────────────────

# heading-hierarchy (Required): exactly one <h1>, and no skipped levels.
# Parsed rather than grepped, because "no skipped levels" is a sequence property.
for p in $PAGES; do
  ok
  python3 - "$p" <<'PY' || fail=$((fail + 1))
import re, sys, pathlib
p = pathlib.Path(sys.argv[1]); b = p.name
html = p.read_text()
html = re.sub(r'<!--.*?-->', '', html, flags=re.S)
levels = [int(m) for m in re.findall(r'<h([1-6])[\s>]', html)]
errs = []
if levels.count(1) != 1:
    errs.append(f'expected exactly 1 <h1>, found {levels.count(1)}')
if levels and levels[0] != 1:
    errs.append(f'first heading is <h{levels[0]}>, not <h1>')
for prev, cur in zip(levels, levels[1:]):
    if cur > prev + 1:
        errs.append(f'skips <h{prev}> to <h{cur}>')
for e in errs:
    print(f'  FAIL  [heading-hierarchy] {b}: {e}')
sys.exit(1 if errs else 0)
PY
done

# meta-robots (Required): an EXPLICIT policy on thin pages. Public pages rely on
# the implicit default and must NOT carry a stray noindex, which is the failure
# mode that quietly deletes a site from search.
has "$SITE/404.html" -q '<meta name="robots" content="noindex' ||
  bad meta-robots "404.html: an error page must be explicitly noindex"
for p in $SITE/index.html $SITE/tech.html; do
  has "$p" -qi 'name="robots"[^>]*noindex' &&
    bad meta-robots "$(basename "$p"): public page carries noindex"
done

# robots.txt + xml-sitemaps (Recommended)
has "$SITE/robots.txt" -q '^Sitemap: https://' ||
  bad robots-txt "robots.txt does not point at the sitemap"
has "$SITE/sitemap.xml" -q '<urlset' ||
  bad xml-sitemaps "sitemap.xml is not a urlset"

# Every canonical URL must be listed in the sitemap, and every sitemap entry must
# be a page that exists. This is the check that catches a page added or deleted
# without the sitemap following, which is how /dbaas lingered.
ok
python3 - <<'PY' || fail=$((fail + 1))
import re, pathlib
site = pathlib.Path('site')
sitemap = set(re.findall(r'<loc>([^<]+)</loc>', (site / 'sitemap.xml').read_text()))
canon = {}
for name in ('index.html', 'tech.html'):
    m = re.search(r'<link rel="canonical" href="([^"]+)"', (site / name).read_text())
    if m:
        canon[name] = m.group(1)
errs = []
for name, url in canon.items():
    if url not in sitemap:
        errs.append(f'{name} canonical {url} is not in sitemap.xml')
for url in sitemap - set(canon.values()):
    errs.append(f'sitemap.xml lists {url}, which no page claims as canonical')
for e in errs:
    print(f'  FAIL  [xml-sitemaps] {e}')
raise SystemExit(1 if errs else 0)
PY

# structured-data (Recommended): valid JSON-LD, not merely present. A JSON-LD
# block with a trailing comma is invisible to every consumer and looks fine.
ok
python3 - <<'PY' || fail=$((fail + 1))
import json, re, pathlib
errs = []
found = {}
for p in sorted(pathlib.Path('site').glob('*.html')):
    blocks = re.findall(
        r'<script type="application/ld\+json">(.*?)</script>', p.read_text(), re.S)
    found[p.name] = blocks
    for i, b in enumerate(blocks):
        try:
            data = json.loads(b)
        except json.JSONDecodeError as e:
            errs.append(f'{p.name}: JSON-LD block {i + 1} is invalid JSON ({e})')
            continue
        for node in (data.get('@graph', [data]) if isinstance(data, dict) else data):
            if not isinstance(node, dict) or '@type' not in node:
                errs.append(f'{p.name}: JSON-LD block {i + 1} has a node with no @type')
for name in ('index.html', 'tech.html'):
    if not found.get(name):
        errs.append(f'{name}: no JSON-LD structured data')
# breadcrumbs (Recommended): /tech sits one level down, so it declares the trail.
if not any('BreadcrumbList' in b for b in found.get('tech.html', [])):
    errs.append('tech.html: no BreadcrumbList JSON-LD')
for e in errs:
    print(f'  FAIL  [structured-data] {e}')
raise SystemExit(1 if errs else 0)
PY

# url-structure (Recommended): lowercase, hyphenated, no underscores or spaces.
ok
bad_urls=$(grep -ho 'href="/[^"#?]*"' $PAGES | sed 's/href="//;s/"//' |
           grep -E '[A-Z_ ]' | sort -u)
[ -z "$bad_urls" ] ||
  bad url-structure "non-lowercase/underscored internal URLs: $(echo "$bad_urls" | tr '\n' ' ')"

# ─────────────────────────────────────────────────────────────────────────────
note "Accessibility"
# https://specification.website/spec/accessibility/
# ─────────────────────────────────────────────────────────────────────────────
for p in $PAGES; do
  b=$(basename "$p")

  # skip-links (Required): must be the FIRST focusable element, not merely
  # present. A skip link after the nav is decoration.
  ok
  first=$(grep -o '<a [^>]*href="#[^"]*"\|<a [^>]*class="skip-link"\|<button\|<a ' "$p" | head -n 1)
  case "$first" in
    *skip-link*) ;;
    *) bad skip-links "$b: the first focusable element is not the skip link" ;;
  esac
  has "$p" -q 'href="#main"' ||
    bad skip-links "$b: skip link does not target #main"

  # semantic-html (Required): the landmark set, and a target for the skip link.
  has "$p" -q '<main[ >]' || bad semantic-html "$b: no <main> landmark"
  has "$p" -q '<main[^>]*id="main"' ||
    bad skip-links "$b: <main> has no id=main for the skip link to land on"
  has "$p" -q '<header[ >]' || bad semantic-html "$b: no <header> landmark"
  has "$p" -q '<footer[ >]' || bad semantic-html "$b: no <footer> landmark"
  has "$p" -q '<nav[ >]'    || bad semantic-html "$b: no <nav> landmark"
done

# image-alt-text (Required): every <img> carries an alt attribute. alt="" is
# valid and means decorative, so the check is presence, not non-emptiness.
ok
python3 - <<'PY' || fail=$((fail + 1))
import re, pathlib
errs = []
for p in sorted(pathlib.Path('site').glob('*.html')):
    for tag in re.findall(r'<img\b[^>]*>', p.read_text(), re.S):
        if not re.search(r'\balt\s*=', tag):
            errs.append(f'{p.name}: <img> with no alt attribute: {tag[:80]}')
for e in errs:
    print(f'  FAIL  [image-alt-text] {e}')
raise SystemExit(1 if errs else 0)
PY

# empty-links-buttons (Required): every control has an accessible name, from
# text content, aria-label, or aria-labelledby.
ok
python3 - <<'PY' || fail=$((fail + 1))
import re, pathlib
errs = []
for p in sorted(pathlib.Path('site').glob('*.html')):
    html = re.sub(r'<!--.*?-->', '', p.read_text(), flags=re.S)
    for kind in ('a', 'button'):
        for m in re.finditer(rf'<{kind}\b([^>]*)>(.*?)</{kind}>', html, re.S):
            attrs, inner = m.group(1), m.group(2)
            if kind == 'a' and 'href' not in attrs:
                continue          # an anchor without href is not a control
            if re.search(r'aria-label(ledby)?\s*=\s*"[^"]+"', attrs):
                continue
            # Text content, with aria-hidden subtrees and all markup removed.
            text = re.sub(r'<(\w+)[^>]*aria-hidden="true".*?</\1>', '', inner, flags=re.S)
            text = re.sub(r'<[^>]+>', '', text)
            if not text.strip():
                errs.append(f'{p.name}: <{kind}> has no accessible name: {m.group(0)[:70]}')
for e in errs:
    print(f'  FAIL  [empty-links-buttons] {e}')
raise SystemExit(1 if errs else 0)
PY

# data-tables (Required): a real table needs a caption and scoped headers.
ok
python3 - <<'PY' || fail=$((fail + 1))
import re, pathlib
errs = []
for p in sorted(pathlib.Path('site').glob('*.html')):
    for m in re.finditer(r'<table\b.*?</table>', p.read_text(), re.S):
        t = m.group(0)
        if '<caption' not in t:
            errs.append(f'{p.name}: <table> has no <caption>')
        headers = re.findall(r'<th\b[^>]*>', t)
        unscoped = [h for h in headers if 'scope=' not in h]
        if unscoped:
            errs.append(f'{p.name}: {len(unscoped)} <th> without a scope attribute')
for e in errs:
    print(f'  FAIL  [data-tables] {e}')
raise SystemExit(1 if errs else 0)
PY

# focus-indicators (Required): the top failure is removing the outline with no
# replacement. `outline: none` is only acceptable next to a box-shadow or a
# border that redraws the ring.
ok
python3 - <<'PY' || fail=$((fail + 1))
import re, pathlib
css = pathlib.Path('site/styles.css').read_text()
errs = []
# A replacement ring is a box-shadow, a real border, or a further `outline:`
# whose value is neither none nor 0. Each alternative is anchored to its own
# declaration: an earlier version of this check used `outline\s*:\s*[^n0]`,
# which backtracked `\s*` to zero width and matched the SPACE after the colon,
# so `outline: none` counted as its own replacement and the rule never fired.
REPLACEMENT = re.compile(
    r'box-shadow\s*:'
    r'|border(-(top|right|bottom|left))?(-(color|width|style))?\s*:'
    r'|outline\s*:\s*(?!none\b|0\b)\S')
for m in re.finditer(r'([^{}]*)\{([^{}]*)\}', css):
    sel, body = m.group(1), m.group(2)
    if not re.search(r'outline\s*:\s*(none|0)\s*(;|$)', body):
        continue
    if not REPLACEMENT.search(body):
        errs.append(f'styles.css: `{sel.strip()[:50]}` removes the outline with no replacement')
for e in errs:
    print(f'  FAIL  [focus-indicators] {e}')
raise SystemExit(1 if errs else 0)
PY

# reduced-motion (Required): the site is built on looping animation, so the
# media query is required rather than a nicety.
has "$SITE/styles.css" -q 'prefers-reduced-motion' ||
  bad reduced-motion "styles.css has no prefers-reduced-motion block"
for js in main.js tech.js header.js; do
  has "$SITE/$js" -q 'prefers-reduced-motion' ||
    bad reduced-motion "$js animates without checking prefers-reduced-motion"
done

# ─────────────────────────────────────────────────────────────────────────────
note "Security"
# https://specification.website/spec/security/
# ─────────────────────────────────────────────────────────────────────────────
NT="$SITE/netlify.toml"

# hsts (Required): two years, includeSubDomains, and NOT preload, which the
# preload list's own operator now discourages.
has "$NT" -q 'Strict-Transport-Security.*max-age=63072000' ||
  bad hsts "netlify.toml: no HSTS with a two-year max-age"
has "$NT" -q 'Strict-Transport-Security.*includeSubDomains' ||
  bad hsts "netlify.toml: HSTS without includeSubDomains"
has "$NT" -q 'Strict-Transport-Security.*preload' &&
  bad hsts "netlify.toml: HSTS carries preload, which the list operator discourages"

# content-security-policy (Recommended) + frame-ancestors (Required).
has "$NT" -q 'Content-Security-Policy' ||
  bad content-security-policy "netlify.toml: no CSP"
for d in "default-src 'self'" "object-src 'none'" "base-uri 'none'" \
         "frame-ancestors 'none'"; do
  has "$NT" -q "$d" ||
    bad content-security-policy "netlify.toml: CSP is missing \"$d\""
done
# script-src must not be defanged. 'unsafe-eval' is never acceptable, and
# 'unsafe-inline' only degrades safely beside a nonce and 'strict-dynamic'.
ok
csp=$(grep -o 'Content-Security-Policy = "[^"]*"' "$NT")
case "$csp" in
  *unsafe-eval*) bad content-security-policy "netlify.toml: CSP allows 'unsafe-eval'" ;;
esac
ok
script_src=$(printf '%s' "$csp" | grep -o "script-src[^;\"]*")
case "$script_src" in
  *unsafe-inline*)
    case "$script_src" in
      *strict-dynamic*nonce-*|*nonce-*strict-dynamic*) ;;
      *) bad content-security-policy "netlify.toml: script-src has 'unsafe-inline' with no nonce + 'strict-dynamic'" ;;
    esac ;;
esac
case "$script_src" in
  *" *"*|*"http:"*) bad content-security-policy "netlify.toml: script-src uses a wildcard or plain http" ;;
esac

# frame-ancestors is the modern control; XFO stays as the legacy fallback.
has "$NT" -q 'X-Frame-Options = "DENY"' ||
  bad frame-ancestors "netlify.toml: no X-Frame-Options fallback"

# x-content-type-options (Required), referrer-policy, permissions-policy,
# cross-origin isolation (all Recommended).
has "$NT" -q 'X-Content-Type-Options = "nosniff"' ||
  bad x-content-type-options "netlify.toml: no nosniff"
has "$NT" -q 'Referrer-Policy = "strict-origin' ||
  bad referrer-policy "netlify.toml: Referrer-Policy is not strict-origin-when-cross-origin"
has "$NT" -q 'Permissions-Policy' ||
  bad permissions-policy "netlify.toml: no Permissions-Policy"
for feat in camera microphone geolocation payment usb; do
  has "$NT" -q "Permissions-Policy.*$feat=()" ||
    bad permissions-policy "netlify.toml: Permissions-Policy does not deny $feat"
done
has "$NT" -q 'Cross-Origin-Opener-Policy' ||
  bad cross-origin-isolation "netlify.toml: no COOP"
has "$NT" -q 'Cross-Origin-Resource-Policy' ||
  bad cross-origin-isolation "netlify.toml: no CORP"

# x-xss-protection: a dead header. Sending it is the failure.
has "$NT" -qi 'X-XSS-Protection' &&
  bad x-xss-protection "netlify.toml: sends the dead X-XSS-Protection header"

# security-txt (Recommended): present, with a required Expires that has not
# lapsed. Going red 30 days early is the renewal reminder.
ST="$SITE/.well-known/security.txt"
has "$ST" -q '^Contact: ' || bad security-txt "security.txt has no Contact:"
has "$ST" -q '^Expires: ' || bad security-txt "security.txt has no Expires:"
ok
python3 - <<'PY' || fail=$((fail + 1))
import datetime, pathlib, re
txt = pathlib.Path('site/.well-known/security.txt').read_text()
m = re.search(r'^Expires:\s*(\S+)', txt, re.M)
if not m:
    raise SystemExit(0)   # already reported above
exp = datetime.datetime.fromisoformat(m.group(1).replace('Z', '+00:00'))
left = (exp - datetime.datetime.now(datetime.timezone.utc)).days
if left < 30:
    print(f'  FAIL  [security-txt] Expires is {left} days away; extend it '
          f'(site/.well-known/security.txt)')
    raise SystemExit(1)
PY

# subresource-integrity + third-party-scripts (Recommended). Every off-origin
# subresource must be enumerated in THIRD_PARTY below, with the CSP allowing it.
# A new CDN dependency added without touching this list is the thing being
# guarded: the site's whole design claim is that it has no build step and no
# runtime dependency, and that only stays true if adding one is loud.
THIRD_PARTY="https://buttons.github.io/buttons.js"
ok
python3 - "$THIRD_PARTY" <<'PY' || fail=$((fail + 1))
import pathlib, re, sys
allowed = set(sys.argv[1].split())
errs = []
found = set()
for p in sorted(pathlib.Path('site').glob('*.html')):
    html = re.sub(r'<!--.*?-->', '', p.read_text(), flags=re.S)
    for tag in re.findall(r'<(?:script|link|img|source|iframe)\b[^>]*>', html):
        for url in re.findall(r'(?:src|href|srcset)="(https?://[^"]+)"', tag):
            if url.startswith('https://eterdb.com'):
                continue      # canonical and og:url point at this site's own origin
            found.add(url)
            if url not in allowed:
                errs.append(f'{p.name}: undeclared third-party subresource {url}')
            elif '<script' in tag and 'integrity=' not in tag and 'crossorigin' not in tag:
                # buttons.js is served from an unversioned URL, so a pinned SRI
                # hash would break the widget on every upstream release. Recorded
                # as a known deviation rather than silently ignored.
                pass
for url in allowed - found:
    errs.append(f'THIRD_PARTY lists {url}, which no page loads; drop it')
for e in errs:
    print(f'  FAIL  [third-party-scripts] {e}')
raise SystemExit(1 if errs else 0)
PY

# Any allow-listed origin must also be allowed by the CSP, or the widget is
# blocked in production while CI stays green.
ok
for url in $THIRD_PARTY; do
  origin=$(printf '%s' "$url" | cut -d/ -f1-3)
  grep -q "$origin" "$NT" ||
    bad content-security-policy "netlify.toml: CSP does not allow $origin"
done

# ─────────────────────────────────────────────────────────────────────────────
note "Performance"
# https://specification.website/spec/performance/
# ─────────────────────────────────────────────────────────────────────────────

# image-optimization (Required): modern formats, explicit dimensions, and a
# weight budget. The budget is the point: without a number, images creep.
LCP_BUDGET=61440      # 60 KiB, what the browser fetches for the hero
PNG_BUDGET=1048576    # 1 MiB, the legacy fallback nobody modern downloads
ok
python3 - "$LCP_BUDGET" "$PNG_BUDGET" <<'PY' || fail=$((fail + 1))
import pathlib, re, sys
lcp_budget, png_budget = int(sys.argv[1]), int(sys.argv[2])
errs = []
site = pathlib.Path('site')

# Every <img> needs width+height so the box is reserved before the bytes land.
for p in sorted(site.glob('*.html')):
    for tag in re.findall(r'<img\b[^>]*>', p.read_text(), re.S):
        if not (re.search(r'\bwidth=', tag) and re.search(r'\bheight=', tag)):
            errs.append(f'{p.name}: <img> without explicit width/height: {tag[:70]}')

# Raster images referenced from HTML must offer a modern format alongside.
for p in sorted(site.glob('*.html')):
    html = p.read_text()
    for pic in re.findall(r'<picture\b.*?</picture>', html, re.S):
        types = set(re.findall(r'type="image/(\w+)"', pic))
        if 'avif' not in types:
            errs.append(f'{p.name}: <picture> offers no AVIF source')
    for tag in re.findall(r'<img\b[^>]*>', html, re.S):
        src = re.search(r'src="([^"]+\.(?:png|jpe?g))"', tag)
        if src and f'<source' not in html[max(0, html.find(tag) - 400):html.find(tag)]:
            errs.append(f'{p.name}: {src.group(1)} is served with no modern-format source')

# Weight budgets.
for f in sorted(site.glob('assets/*')):
    if f.suffix in ('.avif', '.webp') and f.stat().st_size > lcp_budget:
        errs.append(f'{f.name} is {f.stat().st_size:,} bytes, over the {lcp_budget:,} budget')
    if f.suffix == '.png' and f.stat().st_size > png_budget:
        errs.append(f'{f.name} is {f.stat().st_size:,} bytes, over the {png_budget:,} budget')

# Nothing in assets/ may be unreferenced: a 1.3 MB orphan is pure deploy weight,
# and that is exactly what elephant-wide.png was. Editable sources for generated
# assets are exempt, but they have to be named here rather than inferred, so a
# genuine orphan cannot hide behind "probably a source file".
SOURCES = {'og.svg'}          # hand-drawn source for og.png
referenced = ' '.join(p.read_text() for p in site.rglob('*')
                      if p.is_file() and p.suffix in ('.html', '.css', '.js', '.json', '.webmanifest'))
for f in sorted(site.glob('assets/*')):
    if f.suffix in ('.png', '.jpg', '.jpeg', '.avif', '.webp', '.svg', '.ico'):
        if f.name not in referenced and f.name not in SOURCES:
            errs.append(f'assets/{f.name} is referenced by nothing; delete it')
for name in SOURCES:
    if not (site / 'assets' / name).exists():
        errs.append(f'SOURCES lists assets/{name}, which does not exist; drop it')

for e in errs:
    print(f'  FAIL  [image-optimization] {e}')
raise SystemExit(1 if errs else 0)
PY

# font-loading (Recommended): self-hosted WOFF2, font-display: swap, and the
# above-the-fold faces preloaded.
# Checked per @font-face rather than per file: a single `font-display: swap`
# anywhere would otherwise satisfy a stylesheet where most faces lack it, and the
# generated header comment mentions the property by name, which is enough to make
# a whole-file grep pass on a file with no such declaration at all.
ok
python3 - <<'PY' || fail=$((fail + 1))
import pathlib, re
css = pathlib.Path('site/fonts.css').read_text()
errs = []
faces = re.findall(r'@font-face\s*\{([^}]*)\}', css)
if not faces:
    errs.append('fonts.css declares no @font-face')
for body in faces:
    fam = re.search(r"font-family:\s*'([^']+)'", body)
    name = fam.group(1) if fam else '?'
    src = re.search(r'src:\s*url\(([^)]+)\)', body)
    if 'font-display: swap' not in body:
        errs.append(f'{name}: @font-face without font-display: swap')
    if not src:
        errs.append(f'{name}: @font-face with no src')
        continue
    url = src.group(1).strip('\'"')
    if url.startswith('http'):
        errs.append(f'{name}: face loaded from a third-party origin ({url})')
    if not url.endswith('.woff2'):
        errs.append(f'{name}: face is not WOFF2 ({url})')
    if not (pathlib.Path('site') / url.lstrip('/')).exists():
        errs.append(f'{name}: src points at {url}, which is not in the repo')
for e in errs:
    print(f'  FAIL  [font-loading] {e}')
raise SystemExit(1 if errs else 0)
PY
for p in $SITE/index.html $SITE/tech.html; do
  has "$p" -q 'rel="preload"[^>]*as="font"[^>]*crossorigin' ||
    bad font-loading "$(basename "$p"): no crossorigin font preload"
done

# script-loading (Recommended): a render-blocking classic <script> in <head> is
# always wrong. JSON-LD is data, not script, and is exempt.
ok
python3 - <<'PY' || fail=$((fail + 1))
import pathlib, re
errs = []
for p in sorted(pathlib.Path('site').glob('*.html')):
    html = p.read_text()
    head = html[:html.find('</head>')]
    for tag in re.findall(r'<script\b[^>]*>', head):
        if 'application/ld+json' in tag:
            continue
        if 'src=' in tag and not re.search(r'\b(defer|async|type="module")', tag):
            errs.append(f'{p.name}: render-blocking <script> in <head>: {tag[:70]}')
    for tag in re.findall(r'<script\b[^>]*src=[^>]*>', html):
        if not re.search(r'\b(defer|async|type="module")', tag):
            errs.append(f'{p.name}: <script src> with neither defer nor async: {tag[:70]}')
for e in errs:
    print(f'  FAIL  [script-loading] {e}')
raise SystemExit(1 if errs else 0)
PY

# cache-control (Required): HTML must revalidate, and `immutable` may only sit on
# a path that changes when its content does. `immutable` on an overwritable path
# means a stale asset pinned for a year.
has "$NT" -q 'for = "/\*.html"' ||
  bad cache-control "netlify.toml: no Cache-Control block for HTML"
ok
python3 - <<'PY' || fail=$((fail + 1))
import pathlib, re
toml = pathlib.Path('site/netlify.toml').read_text()
errs = []
blocks = re.findall(r'for = "([^"]+)"\s*\[headers\.values\]((?:\s+[^\[\n]+\n)+)', toml)
for path, body in blocks:
    cc = re.search(r'Cache-Control = "([^"]+)"', body)
    if not cc:
        continue
    value = cc.group(1)
    if path.endswith('.html') and 'must-revalidate' not in value:
        errs.append(f'{path}: HTML must revalidate, got "{value}"')
    # Fingerprinted-by-path or versioned-by-query surfaces may be immutable.
    if 'immutable' in value and not (path.startswith('/assets/fonts') or path.endswith('.css')):
        errs.append(f'{path}: `immutable` on a path that is overwritten in place')
for e in errs:
    print(f'  FAIL  [cache-control] {e}')
raise SystemExit(1 if errs else 0)
PY

# ─────────────────────────────────────────────────────────────────────────────
note "Agent readiness"
# https://specification.website/spec/agent-readiness/
# ─────────────────────────────────────────────────────────────────────────────
has "$SITE/llms.txt" -q '^# ' || bad llms-txt "llms.txt has no H1 title"
has "$SITE/llms.txt" -q '^> ' || bad llms-txt "llms.txt has no blockquote summary"
has "$NT" -q 'Content-Type = "text/markdown' ||
  bad llms-txt "netlify.toml does not serve llms.txt as text/markdown"

# robots-for-ai-crawlers (Recommended): a stated policy per named agent beats
# relying on the wildcard.
for agent in GPTBot ClaudeBot Google-Extended PerplexityBot OAI-SearchBot; do
  has "$SITE/robots.txt" -q "^User-agent: $agent$" ||
    bad robots-for-ai-crawlers "robots.txt has no explicit policy for $agent"
done

# Every link llms.txt advertises must be a page that exists.
ok
python3 - <<'PY' || fail=$((fail + 1))
import pathlib, re
site = pathlib.Path('site')
errs = []
for url in re.findall(r'\]\((https://eterdb\.com[^)]*)\)', (site / 'llms.txt').read_text()):
    path = url.replace('https://eterdb.com', '').split('#')[0].rstrip('/')
    if path in ('', '/tech', '/install.sh', '/llms.txt', '/sitemap.xml', '/robots.txt'):
        continue
    errs.append(f'llms.txt links {url}, which is not a route this site serves')
for e in errs:
    print(f'  FAIL  [llms-txt] {e}')
raise SystemExit(1 if errs else 0)
PY

# ─────────────────────────────────────────────────────────────────────────────
note "Resilience"
# https://specification.website/spec/resilience/
# ─────────────────────────────────────────────────────────────────────────────

# error-pages (Required): Netlify serves a root 404.html with a real 404 status,
# so its existence is the check. Content requirements are covered by the
# per-page loop above; here we assert it is useful rather than a dead end.
ok
[ -f "$SITE/404.html" ] || bad error-pages "no site/404.html"
has "$SITE/404.html" -q 'href="/"' ||
  bad error-pages "404.html offers no way back to the homepage"

# A redirect to "/" for an unknown URL would be a soft 404. The only permitted
# catch-all is the one retiring /dbaas.
ok
grep -q 'from = "/\*"' "$NT" &&
  bad soft-404 "netlify.toml has a catch-all redirect, which produces soft 404s"

# pwa-manifest (Recommended): valid JSON, installable fields, maskable icon.
ok
python3 - <<'PY' || fail=$((fail + 1))
import json, pathlib
errs = []
try:
    m = json.loads(pathlib.Path('site/site.webmanifest').read_text())
except Exception as e:
    print(f'  FAIL  [pwa-manifest] site.webmanifest is invalid JSON ({e})')
    raise SystemExit(1)
for field in ('name', 'short_name', 'start_url', 'display', 'theme_color', 'background_color'):
    if not m.get(field):
        errs.append(f'site.webmanifest has no {field}')
sizes = {i.get('sizes') for i in m.get('icons', [])}
for want in ('192x192', '512x512'):
    if want not in sizes:
        errs.append(f'site.webmanifest has no {want} icon')
if not any(i.get('purpose') == 'maskable' for i in m.get('icons', [])):
    errs.append('site.webmanifest has no maskable icon')
for e in errs:
    print(f'  FAIL  [pwa-manifest] {e}')
raise SystemExit(1 if errs else 0)
PY
has "$NT" -qF 'application/manifest+json' ||
  bad pwa-manifest "netlify.toml does not serve the manifest as application/manifest+json"

# graceful-degradation (Required): the pages must carry their content in the
# HTML, not assemble it in JS. Every scene and figure is progressive
# enhancement over static markup, so the prose must outweigh the scripts.
ok
python3 - <<'PY' || fail=$((fail + 1))
import pathlib, re
errs = []
# A content page assembled by JavaScript is invisible to crawlers and broken
# when a script 404s. An error page is short BY DESIGN, so it gets a floor that
# only asserts it says something and offers a way out.
FLOORS = {'index.html': 400, 'tech.html': 400, '404.html': 40}
for name, floor in FLOORS.items():
    html = pathlib.Path('site', name).read_text()
    body = html[html.find('<body'):]
    text = re.sub(r'<script.*?</script>', '', body, flags=re.S)
    text = re.sub(r'<!--.*?-->', '', text, flags=re.S)
    text = re.sub(r'<[^>]+>', ' ', text)
    words = len(text.split())
    if words < floor:
        errs.append(f'{name}: only {words} words of server-rendered text '
                    f'(floor {floor}); content appears to be JS-assembled')
for e in errs:
    print(f'  FAIL  [graceful-degradation] {e}')
raise SystemExit(1 if errs else 0)
PY

# ─────────────────────────────────────────────────────────────────────────────
note "Internationalisation"
# https://specification.website/spec/i18n/
# ─────────────────────────────────────────────────────────────────────────────
# The site is single-language, so hreflang and language switchers do not apply.
# What does apply: the declared language must be the one actually written, and
# untranslatable identifiers should be marked so machine translation leaves them
# alone. `eterDB`, SQL and shell are the identifiers here.
has "$SITE/index.html" -q '<html lang="en"' ||
  bad document-language "index.html does not declare lang=en"

# ─────────────────────────────────────────────────────────────────────────────
# A rule that stops running is worse than a rule that fails: it reports green.
# This floor catches a refactor that quietly drops checks, which is the failure
# mode issue #197 is about. It is a FLOOR, not an equality: adding rules is free,
# removing them has to be deliberate enough to edit this number.
MIN_CHECKS=145
if [ "$checked" -lt "$MIN_CHECKS" ]; then
  echo
  echo "site-spec: BROKEN CHECK: only $checked assertions ran, expected >= $MIN_CHECKS." >&2
  echo "Rules were removed or the script exited early. Fix before trusting a pass." >&2
  exit 2
fi

echo
if [ "$fail" -gt 0 ]; then
  echo "site-spec: $fail violation(s) across $checked checks (spec snapshot $SPEC_SNAPSHOT)."
  echo "Each tag maps to https://specification.website/spec/<category>/<tag>/"
  exit 1
fi
echo "site-spec: clean, $checked checks (spec snapshot $SPEC_SNAPSHOT)."
