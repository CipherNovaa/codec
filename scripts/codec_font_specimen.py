#!/usr/bin/env python3
"""codec_font_specimen.py — a full character sheet for the MGS pixel fonts.

Renders EVERY mapped character of a font, exactly as FreeType rasterises it at
the design size (16 ppem, monochrome, no hinting — one design pixel = one
pixel), scaled up nearest-neighbour, in a labelled grid grouped by Unicode
block. The sheet is the quick answer to "does the font have X?" when using the
faces in another project. Regenerate after any change to the fonts:

  codec_font_specimen.py                       # both mechui fonts -> docs/fonts/
  codec_font_specimen.py font.ttf --out sheet.png --scale 4
"""
import argparse
import os

import freetype
from fontTools.ttLib import TTFont
from PIL import Image, ImageDraw, ImageFont

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FONTS = {"mgs-codec.ttf": "mgs-codec-specimen.png",
         "mgs-hud.ttf": "mgs-hud-specimen.png"}
LABEL_FONT = "/usr/share/fonts/TTF/DejaVuSansMono.ttf"
BLOCKS = [  # (first, last, name) — only blocks the faces touch
    (0x0020, 0x007F, "Basic Latin"), (0x00A0, 0x00FF, "Latin-1 Supplement"),
    (0x0100, 0x017F, "Latin Extended-A"), (0x0180, 0x024F, "Latin Extended-B"),
    (0x02B0, 0x02FF, "Spacing modifiers"), (0x1E00, 0x1EFF, "Latin Extended Additional"),
    (0x2000, 0x206F, "General Punctuation"), (0x2070, 0x209F, "Super/subscripts"),
    (0x20A0, 0x20CF, "Currency"), (0x2100, 0x214F, "Letterlike"),
    (0x2190, 0x21FF, "Arrows"), (0x2200, 0x22FF, "Math operators"),
    (0x2300, 0x23FF, "Misc technical"), (0x2400, 0x243F, "Control pictures"),
    (0x2460, 0x24FF, "Enclosed alphanumerics"), (0x25A0, 0x25FF, "Geometric shapes"),
    (0x2600, 0x26FF, "Misc symbols"), (0x2700, 0x27BF, "Dingbats"),
    (0x27C0, 0x27FF, "Misc math / arrows"), (0xFB00, 0xFB4F, "Ligatures"),
    (0xFFF0, 0xFFFF, "Specials"),
]


def render(path, out, scale=4, cols=16):
    cmap = TTFont(path).getBestCmap()
    face = freetype.Face(path)
    face.set_pixel_sizes(0, 16)
    # BASIC layout: with freetype-py loaded in the same process, PIL's raqm
    # layout drew only each label's first letter.
    basic = ImageFont.Layout.BASIC
    small = ImageFont.truetype(LABEL_FONT, 11, layout_engine=basic)
    head = ImageFont.truetype(LABEL_FONT, 15, layout_engine=basic)
    cell_w, cell_h = 20 * scale, 26 * scale
    rows = []  # (block name, [codepoints])
    for lo, hi, name in BLOCKS:
        cps = [cp for cp in sorted(cmap) if lo <= cp <= hi]
        if cps:
            rows.append((name, cps))
    height = 60 + sum(30 + -(-len(c) // cols) * cell_h for _n, c in rows)
    img = Image.new("RGB", (cols * cell_w + 20, height), (16, 20, 24))
    d = ImageDraw.Draw(img)
    fam = TTFont(path)["name"].getDebugName(4)
    d.text((10, 10), f"{fam} — {len(cmap)} characters · 16 ppem ×{scale}",
           fill=(220, 230, 235), font=head)
    y = 50
    for name, cps in rows:
        d.text((10, y), f"{name} ({len(cps)})", fill=(130, 170, 210), font=head)
        y += 30
        for i, cp in enumerate(cps):
            cx, cy = 10 + (i % cols) * cell_w, y + (i // cols) * cell_h
            d.rectangle((cx, cy, cx + cell_w - 4, cy + cell_h - 4), outline=(40, 46, 54))
            face.load_char(chr(cp), freetype.FT_LOAD_RENDER | freetype.FT_LOAD_TARGET_MONO
                           | freetype.FT_LOAD_NO_HINTING)
            bm, g = face.glyph.bitmap, face.glyph
            base_y = cy + 6 * scale + 10 * scale   # baseline 10 design px down
            for r in range(bm.rows):
                for c in range(bm.width):
                    byte = bm.buffer[r * bm.pitch + c // 8]
                    if byte & (0x80 >> (c % 8)):
                        x0 = cx + 4 * scale + (g.bitmap_left + c) * scale
                        y0 = base_y + (r - g.bitmap_top) * scale
                        d.rectangle((x0, y0, x0 + scale - 1, y0 + scale - 1),
                                    fill=(236, 238, 222))
            d.text((cx + 3, cy + cell_h - 18), f"{cp:04X}", fill=(110, 120, 130), font=small)
        y += -(-len(cps) // cols) * cell_h
    img.save(out, optimize=True)
    print(f"wrote {out} ({len(cmap)} chars)")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("font", nargs="?")
    ap.add_argument("--out")
    ap.add_argument("--scale", type=int, default=4)
    a = ap.parse_args()
    if a.font:
        render(a.font, a.out or os.path.splitext(a.font)[0] + "-specimen.png", a.scale)
        return
    os.makedirs(os.path.join(REPO, "docs/fonts"), exist_ok=True)
    for src, dst in FONTS.items():
        render(os.path.join(REPO, "assets/mechui", src),
               os.path.join(REPO, "docs/fonts", dst), a.scale)


if __name__ == "__main__":
    main()
