# eterDB, marketing site

The public website for eterDB: explains the product and why it matters in the agent era. It's a
**dependency-free static site** (HTML/CSS/JS, no build step, no framework), designed to drop
straight onto Netlify. There is no email capture, the only calls to action are the repo and
`/tech`. Fonts are self-hosted; the single third-party runtime dependency is the GitHub star
widget, and `test/lint-site-spec.sh` fails the build if a second one appears.

Design: clean, minimal, **light + monochrome**. Color is reserved for the data the agent
touches (red = destruction, amber = tainted, green = recovery) so the show-don't-tell does
the talking.

```
site/
├── index.html      # the whole page (hero + scenario sections, vs-Supabase, postgres, closing CTA)
├── tech.html       # "How it works", illustrated, first-principles deep-dive (for HN/dev readers)
├── 404.html        # error page, real 404 status via Netlify, noindex, links back into the site
├── tech.js         # the interactive figures for tech.html (hand-built canvas explorables)
├── styles.css      # design system: CSS-variable tokens (spacing/type/radii/shadows) + components
├── fonts.css       # GENERATED @font-face block for the self-hosted WOFF2 (see assets/generate-fonts.py)
├── main.js         # the scene engine (Terminal + Table controllers) + scenarios, reveal
├── header.js       # global sticky header: logo spin, burger menu, GitHub star count, shared by all pages
├── netlify.toml    # publish config + security headers + caching + /tech → /tech.html rewrite
├── site.webmanifest# PWA manifest: name, icons (incl. maskable), theme colours
├── llms.txt        # curated Markdown map of the site for AI agents (llms.txt convention)
├── robots.txt      # allow all crawlers, named AI agents stated explicitly, point to the sitemap
├── sitemap.xml     # the two real pages (home, /tech)
├── .well-known/
│   └── security.txt# RFC 9116 disclosure contact; the Expires date is CI-checked
└── assets/         # icon set, hero art (AVIF/WebP/PNG), Open Graph image, self-hosted fonts
```

## Conformance (`test/lint-site-spec.sh`)

The site is gated in CI against [The Website Specification](https://specification.website), a
platform-agnostic list of the technical features a site should have. `test/lint-site-spec.sh`
encodes the subset that applies to a two-page static site with no accounts, forms or feed, and
that is decidable from the files in the repo, about 148 assertions across foundations, SEO,
accessibility, security, performance, agent-readiness, resilience and i18n.

It runs **offline**, against the commit rather than the deployed origin, so it needs no network
and cannot go red because a third party changed. The spec also publishes an MCP server with an
`audit_url` tool; that audits what is live, which is the wrong question for a pull request.
`SPEC_SNAPSHOT` in the script records when the rules were last reconciled with the published
spec, and refreshing them is a deliberate act.

`test/lint-site-spec-mutations.sh` runs alongside it and breaks one thing per rule, requiring
the linter to notice all 72. Add a mutation whenever you add a rule; a grep that quietly stops
matching reports the same green as a site that stopped violating.

Three rules there are worth knowing before editing the site:

- **No undeclared third-party subresources.** Every off-origin URL must be listed in the
  script's `THIRD_PARTY` and allowed by the CSP in `netlify.toml`. The one entry is the GitHub
  star widget. Fonts were moved off the Google CDN to satisfy this.
- **No orphaned assets.** Anything in `assets/` that nothing references fails the build. A
  1.3 MB unreferenced hero PNG is what motivated it.
- **Weight budgets.** Modern-format images are capped at 60 KiB; the hero is 24 KB of AVIF
  against a 501 KB PNG fallback.

## Generated assets

Two scripts, neither of which is a build step. The outputs are committed; the scripts exist so
they are reproducible. Both need `python3 -m pip install pillow`.

```bash
python3 site/assets/generate.py         # favicon.ico, apple-touch/PWA icons, hero AVIF + WebP
python3 site/assets/generate-fonts.py   # WOFF2 files + fonts.css, from the Google Fonts CSS API
```

`generate-fonts.py` deduplicates: Google serves one variable font per family and subset and
repeats it across every weight, so a naive download is 797 KB of mostly identical bytes against
177 KB deduped.

## Agent-facing files (`llms.txt`)

AI answer engines (Perplexity, ChatGPT Search, Claude, Gemini) waste context tokens on a page's
navbars, hydration, and boilerplate. A root Markdown file gives them a clean, high-signal path:

- **`llms.txt`** is a curated map, a dense factual description of EterDB plus links to the real
  pages (`/`, `/tech`) and the source/install URLs, each with a blurb. It's the
  AI-equivalent of a sitemap.

`netlify.toml` serves it with `Content-Type: text/markdown; charset=utf-8`. Keep it in sync with
the product story in [`index.html`](index.html), [`tech.html`](tech.html), and the repo
[`README.md`](../README.md) when facts change; keep `sitemap.xml` in sync if a page is added or
removed.

## The technical page (`/tech`)

`tech.html` is the credibility page for a technical audience (HN, dev directories): the real
architecture, built up **from first principles** like an explorable explanation. Nine sections:
the transaction as the unit of undo, the shape of the system, write capture via logical decoding
(MVCC + versions), the read-dependency a backup can't see (`ctid`, slot reuse, the read-time PK
fix), on-demand graph derivation + blast-radius modes, base-backup + WAL-replay time travel
(including the ZFS→PITR change, why the COW substrate was replaced, ADR 0003), deployment, and
a known-limits section (observe-mode overhead, compatibility matrix, known sharp edges). Content
is drawn from `PLAN.md`, `performance_report.md`, and `compatibility_report.md`; keep it in sync
when those change.

**One rule governs where a Postgres concept is explained: the section that needs it, and nowhere
earlier** (issue #209). The page has no primer up front and no glossary box. Row versions,
`xmin`/`xmax` and `VACUUM` are introduced in §3 because the before-image is the first thing that
needs them; heap pages, line pointers and `ctid` are introduced in §4 immediately above the slot-reuse
bug they explain; isolation levels, SSI, predicate locks and rw-edges are defined inline in §4's
prose at first use. A concept that a section only forward-references belongs in the later section
instead. The figures follow the same rule, so `basics` deliberately says nothing about pages or
row versions.

The diagrams are **self-driving and dependency-free**, hand-built `<canvas>` animations in
[`tech.js`](tech.js): every figure is a timed loop that tells its story on its own, with no
buttons, toggles, steppers or sliders (issue #162; hover remains as an optional detail layer on
`arch` and `scaling`). This page used to pull Mermaid from a CDN; it no longer pulls any runtime
dependency. Each figure is a `<figure class="fig" data-fig="NAME">` holding a `.fig-canvas`;
`tech.js` renders it as a pure function of loop time, updates a live readout that narrates the
current scene, animates only while the figure is on screen, and respects
`prefers-reduced-motion` (a static, fully-informative end-state, no auto-play). The nine figures:
`basics`, `mvcc`, `ctid`, `wal`, `arch`, `reads`, `graph`, `pitr`, `scaling`.

## The scene engine

The whole site is **agent-driven**: every animated section is a pair, a **terminal** (the
agent acts) next to a **table** (the data reacts). `main.js` is a small engine, not hand-coded
animations:

- **`makeTerminal(body)`**, types agent messages (`msg`) and tool calls + results (`tool`).
- **`makeTable(panel, def)`**, a generic data grid with operations the scenarios drive:
  `corrupt`, `heal`, `del`, `undel`, `dropAll`, `restoreAll`, `taint`, `dropColumn`,
  `addColumn`, `asOf`/`live` (time-travel), `cohort`.
- **`SCENES`**, a registry where each scenario is ~15 declarative lines (schema, rows, and a
  `run(term, table)` script). Add or edit one without touching the engine.

Scenes (all on the patched-undo narrative, each verified-real in the repo, all mounted on the
homepage): **hero** (drop a live table) · **overwrite** (bad UPDATE → value recovery) ·
**delete** (greedy DELETE → resurrection) · **column** (migration drops a column → recover it)
· **downstream** (the read-dependency moat, revert a bad write *and* what read it). The
homepage's time-travel, extensions, and provision sections were pruned 2026-07-13; the
"Serverless eterDB" page (`/dbaas`) was deleted 2026-08-03 (issue #210), and `netlify.toml`
301s the old URL to `/`.

A scene mounts to the DOM via `<div class="scene" data-scene="scene-id">` containing a
`.term` and a `.panel`; it auto-plays (looping) when scrolled into view, and renders a static
end-state under `prefers-reduced-motion`.

## Design tokens

`styles.css` opens with a `:root` token layer, spacing scale (`--s-1…--s-10`, 4px base),
type scale (`--fs-*`), radii (`--r-*`), shadows (`--shadow-*`), and semantic state colors
(`--ok-*`, `--bad-*`, `--warn-*`, `--past-*`). Components reference the tokens rather than
hardcoded values, so spacing/type/buttons stay consistent and new sections can't drift. No
framework, no build step.

## Local preview

No build needed, serve the folder with anything:

```bash
cd site
python3 -m http.server 8080   # → http://localhost:8080
# or: npx serve .
```

## Deploy to Netlify

The `netlify.toml` here sets `publish = "."`, so point Netlify at this directory.

**Option A, drag & drop:** drop the `site/` folder into the Netlify dashboard.

**Option B, Git (recommended):**
1. New site from Git → pick this repo.
2. **Base directory:** `site`
3. **Publish directory:** `site` (or `.` with base set), Netlify reads `netlify.toml`.
4. **Build command:** leave empty.

## Editing content

Everything is in `index.html`. The product narrative is kept in sync with the repo's
[`README.md`](../README.md), update those and this together so the story stays accurate.
