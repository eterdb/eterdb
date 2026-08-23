#!/usr/bin/env python3
"""One-off generator for the self-hosted web fonts and site/fonts.css.

This is NOT a build step. The site ships the WOFF2 files and the generated
stylesheet, committed; this script exists so both are reproducible. Run it by
hand when a weight or family changes:

    python3 site/assets/generate-fonts.py

Why self-hosted at all: the spec's font-loading and third-party-scripts rules
both say to serve fonts from your own origin, and the site's stated design is
dependency-free. Pulling fonts from fonts.googleapis.com meant two extra
origins, two DNS+TLS handshakes on the critical path, a render-blocking
stylesheet from a third party, and every visitor's IP handed to Google.

Google serves ONE variable font file per family+subset and repeats it across
every weight declaration in the CSS API response. Downloading the response
verbatim gets five byte-identical copies of Inter. This script hashes the
payloads, keeps one file per unique body, and emits a single @font-face per
family+subset with a `font-weight` range covering what the site uses.
"""

import hashlib
import json
import pathlib
import re
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
FONT_DIR = HERE / "fonts"
CSS_OUT = HERE.parent / "fonts.css"

# Keep in sync with the font-family stacks in styles.css.
FAMILIES = "Inter:wght@400;500;600;700;800&family=JetBrains+Mono:wght@400;500;600"
API = f"https://fonts.googleapis.com/css2?family={FAMILIES}&display=swap"

# A modern UA is required, or the API answers with legacy TTF instead of WOFF2.
UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0 Safari/537.36"
)

# Latin is the site's content; latin-ext costs little and covers European
# accents in names and quotations. The other subsets Google offers (Cyrillic,
# Greek, Vietnamese) are never rendered here, so they are not downloaded.
SUBSETS = ("latin", "latin-ext")

HEADER = """/* eterDB web fonts, self-hosted. GENERATED, do not edit by hand.

   Regenerate with:  python3 site/assets/generate-fonts.py

   One file per family+subset: Google ships Inter and JetBrains Mono as variable
   fonts, so a single payload covers every weight the site asks for and the
   font-weight range below tells the browser so.

   font-display: swap keeps text readable while a face loads, and the
   unicode-range split means a page that renders no latin-ext glyph never
   downloads the latin-ext file. */
"""


def fetch_css() -> str:
    req = urllib.request.Request(API, headers={"User-Agent": UA})
    with urllib.request.urlopen(req) as r:
        return r.read().decode()


def main() -> None:
    css = fetch_css()
    # Each face in the API response is preceded by a `/* subset */` comment.
    blocks = re.findall(r"/\*\s*([\w-]+)\s*\*/\s*@font-face\s*\{(.*?)\}", css, re.S)

    # (family, subset) -> {weights, unicode_range, url}
    faces: dict[tuple[str, str], dict] = {}
    for subset, body in blocks:
        if subset not in SUBSETS:
            continue
        family = re.search(r"font-family:\s*'([^']+)'", body).group(1)
        weight = int(re.search(r"font-weight:\s*(\d+)", body).group(1))
        url = re.search(r"url\((https://[^)]+\.woff2)\)", body).group(1)
        rng = re.search(r"unicode-range:\s*([^;]+);", body).group(1).strip()

        face = faces.setdefault(
            (family, subset), {"weights": set(), "range": rng, "urls": set()}
        )
        face["weights"].add(weight)
        face["urls"].add(url)

    FONT_DIR.mkdir(parents=True, exist_ok=True)
    for stale in FONT_DIR.glob("*.woff2"):
        stale.unlink()

    out = [HEADER]
    manifest = []
    for (family, subset), face in sorted(faces.items()):
        bodies = {}
        for url in sorted(face["urls"]):
            with urllib.request.urlopen(url) as r:
                blob = r.read()
            bodies[hashlib.sha256(blob).hexdigest()] = blob
        if len(bodies) != 1:
            raise SystemExit(
                f"{family}/{subset}: expected one variable payload, got {len(bodies)}. "
                "Google may have switched to static instances; this script needs updating."
            )
        blob = next(iter(bodies.values()))

        slug = family.lower().replace(" ", "-")
        name = f"{slug}-{subset}.woff2"
        (FONT_DIR / name).write_bytes(blob)
        manifest.append((name, len(blob)))

        lo, hi = min(face["weights"]), max(face["weights"])
        weight = str(lo) if lo == hi else f"{lo} {hi}"
        out.append(
            f"@font-face {{\n"
            f"  font-family: '{family}';\n"
            f"  font-style: normal;\n"
            f"  font-weight: {weight};\n"
            f"  font-display: swap;\n"
            f"  src: url('/assets/fonts/{name}') format('woff2');\n"
            f"  unicode-range: {face['range']};\n"
            f"}}\n"
        )

    CSS_OUT.write_text("\n".join(out))

    total = sum(size for _, size in manifest)
    for name, size in manifest:
        print(f"{name:34} {size:>8,} bytes")
    print(f"{'TOTAL':34} {total:>8,} bytes")
    print(f"wrote {CSS_OUT.relative_to(HERE.parent.parent)}")
    print(json.dumps({n: s for n, s in manifest}, indent=2))


if __name__ == "__main__":
    main()
