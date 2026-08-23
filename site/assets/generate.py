#!/usr/bin/env python3
"""One-off asset generator for the icon set and the modern image formats.

This is NOT a build step. The site ships the generated files, committed; this
script exists so they are reproducible rather than mystery binaries. Run it by
hand after changing the logo mark or the hero photographs:

    python3 -m pip install pillow
    python3 site/assets/generate.py

It produces, next to itself:

  favicon.ico             multi-resolution 16/32/48, the root fallback crawlers ask for
  apple-touch-icon.png    180x180, iOS home screen (opaque, iOS no longer rounds transparency)
  icon-192.png            web app manifest, "any"
  icon-512.png            web app manifest, "any"
  icon-maskable-512.png   web app manifest, "maskable", mark inside the 80% safe zone
  *.avif / *.webp         modern encodings of the two hero photographs

The mark is the same geometry as favicon.svg: a filled disc, an undo arrow
sweeping counter-clockwise out of a horizontal bar, and a triangular arrowhead.
Kept in sync by hand; favicon.svg remains the source of truth for shape.
"""

import pathlib

from PIL import Image, ImageDraw

HERE = pathlib.Path(__file__).resolve().parent

DISC = "#0a0a0a"
INK = "#ffffff"
SS = 8  # supersample factor, downsampled with LANCZOS for anti-aliasing


def draw_mark(px: int, inset: float = 0.0) -> Image.Image:
    """Render the logo mark at px*px.

    `inset` shrinks the 24-unit artwork inside the canvas, as a fraction of the
    canvas. The maskable icon uses 0.1 on each side so the whole mark sits in
    the 80% safe zone Android crops against.
    """
    n = px * SS
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # Map the 24x24 viewBox onto the inset area.
    pad = n * inset
    scale = (n - 2 * pad) / 24.0

    def p(x, y):
        return (pad + x * scale, pad + y * scale)

    def box(cx, cy, r):
        return [p(cx - r, cy - r), p(cx + r, cy + r)]

    d.ellipse(box(12, 12, 11), fill=DISC)

    stroke = max(1, round(1.9 * scale))
    # The bar, then the 315-degree counter-clockwise sweep. PIL measures angles
    # clockwise from 3 o'clock in screen coordinates, so 45 -> 360 traces the
    # same path as the SVG's `A5.5 5.5 0 1 0` arc.
    d.line([p(6.5, 12), p(17.5, 12)], fill=INK, width=stroke)
    d.arc(box(12, 12, 5.5), 45, 360, fill=INK, width=stroke)
    d.polygon([p(18.3, 13.4), p(17.2, 17.4), p(14.3, 14.5)], fill=INK)

    return img.resize((px, px), Image.LANCZOS)


def flatten(img: Image.Image) -> Image.Image:
    """Composite onto the disc colour. iOS renders apple-touch-icon opaque."""
    bg = Image.new("RGB", img.size, DISC)
    bg.paste(img, mask=img.split()[3])
    return bg


def main() -> None:
    # The ICO carries 48/32/16 so browsers and crawlers hitting /favicon.ico
    # get a sharp icon at every size they ask for.
    draw_mark(48).save(HERE / "favicon.ico", sizes=[(48, 48), (32, 32), (16, 16)])
    flatten(draw_mark(180)).save(HERE / "apple-touch-icon.png")
    draw_mark(192).save(HERE / "icon-192.png")
    draw_mark(512).save(HERE / "icon-512.png")
    # Maskable: the disc must bleed to the edges, the mark stays in the middle
    # 80%, so a circle or squircle crop never clips it.
    maskable = Image.new("RGB", (512, 512), DISC)
    inner = draw_mark(512, inset=0.1)
    maskable.paste(inner, mask=inner.split()[3])
    maskable.save(HERE / "icon-maskable-512.png")

    # Modern encodings for the hero photograph. Quality picked to sit under the
    # budget test/lint-site-spec.sh enforces while staying visually clean: the
    # AVIF is 44 dB PSNR against the PNG at 5% of its bytes.
    for name, quality in (("elephant-biplane", 55),):
        src = Image.open(HERE / f"{name}.png")
        src.save(HERE / f"{name}.avif", quality=quality)
        src.save(HERE / f"{name}.webp", quality=quality + 20, method=6)

    for f in sorted(HERE.iterdir()):
        if f.is_file() and f.suffix in {".ico", ".png", ".avif", ".webp"}:
            print(f"{f.name:28} {f.stat().st_size:>9,} bytes")


if __name__ == "__main__":
    main()
