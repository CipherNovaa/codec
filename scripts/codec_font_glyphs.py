#!/usr/bin/env python3
"""codec_font_glyphs.py — fill typographic gaps in codec's MGS pixel fonts.

WHY
---
Subtitles are rendered by libass (mpv locally, ffmpeg burn-in on the hub) in
"MGS1 Codec" (assets/mechui/mgs-codec.ttf) and the HUD face "MGS1 HUD"
(assets/mechui/mgs-hud.ttf); the whole UI is set in them.  Whenever a string
contains a character the face lacks, libass/Qt silently substitute a
*fallback* font for just that character: "ﬂame" renders as a smooth sans "fl"
glued to pixel "AME", "Björk" gets a smooth ö, a "✓" or "▸" in a key hint
becomes a different design altogether.  The v1.35 pass added the composable
gaps (ligatures, curly quotes, ellipsis, dashes, NBSP, acute/grave letters).
This pass hand-draws everything else the UI and European subtitles realistically
need, in each face's own pixel style, so nothing falls back any more.

THE FACES (derived from the files, not assumed)
-----------------------------------------------
Both are TrueType, 1024 upm, drawn on a 64-unit grid (1 design px = 64 units,
16 px per em); every outline is grid-aligned squares, all points on-curve,
outer contours clockwise, holes counter-clockwise.  BOTH ARE UNICASE: a–z are
pixel-identical to A–Z (the original maps É/é, À/à, Ø/ø, Æ/æ to one glyph).
  MGS1 Codec: caps 8 wide x 6 tall (rows 0–5), advance 9 (I/i: 3 wide, adv 4).
      Vertical stems 2–3 px, horizontals 1 px, diagonals 3-px runs stepping
      1 px per row.  Dot unit 2x2 (period, colon, bullet); hyphen 8x2 at rows
      2–3; quotes 2 px wide.  Symbols (○ △ □ ❌ ①–⑨ arrows) are drawn THIN
      (1-px strokes) at cap size; filled ▲▼ are solid.  Cap-size symbols get
      lsb 1–2 / rsb 2 (adv 10–11).  Accent marks are 2 rows (6–7) placed
      DIRECTLY on the letter top (no gap), 1-px strokes, the mark's bottom
      pixel at col 4 of an 8-wide letter (col 2 over the 3-wide I) — this is
      how the original É/À/Í sit, and total height 8 px = hhea ascent.
  MGS1 HUD: caps 5 wide x 5 tall (rows 0–4), advance 6 (I/i: 1 wide at lsb 1,
      adv 4); every stroke 1 px, diagonals 1 px per row.  Period 1x1 at row 0,
      colon dots at rows 1 and 3, hyphen row 2, bullet row 2.  Symbols are
      letter-sized (5x5, adv 6).  Marks: 2 rows (5–6) directly on the letter
      top, bottom pixel at the centre col 2 (col 1 over I); the originals
      already exceed the 384 hhea ascent by one row and nothing clips.

WHAT THIS SCRIPT ADDS (both faces, each in its own style)
--------------------------------------------------------
* Latin-1 Supplement U+00A0–00FF complete, Latin Extended-A U+0100–017F
  complete, plus Ș ș Ț ț ẞ.  Accented letters are TrueType COMPOSITES
  (base glyph + mark glyph) so the base letter stays pixel-identical; the
  marks (diaeresis, circumflex, tilde, ring, cedilla, caron, macron, breve,
  dot above, double acute, ogonek, eng hook) are new outlines drawn once per
  face in ASCII art below.  Stroke letters (Đ Ħ Ł Ŧ) and currency/letter
  hybrids (¢ ¥ ₩ ₽ ‰ µ) are "overlays": the base glyph's pixels are taken
  from the font at run time and OR-ed with the extra pixels, so the base is
  still pixel-identical but no contours overlap.  Lowercase codepoints map to
  the same glyph as the capital (unicase), exactly as the original É/é does.
* General punctuation (‐ ‑ ‒ ― ‖ ‚ „ ‥ † ‡ ‣ ‰ ′ ″ ‹ › ‼ ⁇ ⁈ ⁉ ⁄ ℃ ℉),
  superscript/subscript digits and ⁺ ⁻ ₊ ₋, currency (€ £ ¢ ¥ ¤ ₹ ₩ ₽), maths
  (− ± ≈ ≠ ≡ ≤ ≥ ∞ √ ÷ °), and the UI symbols codec draws (· ● ◐ ◑ ■ ▪ ▫
  ◆ ◇ ◈ ★ ☆ ◂ ▸ ◀ ▶ ▲ ▼ △ ▽ ▴ ▾ ← ↑ → ↓ ↔ ↕ ↺ ↻ ↶ ↷ ⟳ ✓ ✔ ✗ ✕ ♪ ♫ ♥ ⏎ ↵
  ⇧ ␣ ⚠ ❚ ▮ ⏸ ❕).  Deliberately NOT drawn (too small to be convincing /
  mgsSafe's word form is clearer): ⌫ ␡ "DEL".  Out of scope: Greek, Cyrillic,
  CJK, emoji, the private-use icon-font codepoints.
* v1.35 set, unchanged: ligatures ﬀ–ﬆ, ‘ ’ “ ” … – — NBSP and the acute/grave
  letters built from the fonts' own (unnamed) acute/grave mark glyphs.

Every new outline is defined as reviewable ASCII art ('#' ink, '.' empty,
rows top-to-bottom) in CODEC_ART / HUD_ART with its bottom row's y, left
column's x and advance in design pixels.  Bitmaps are traced into merged
clockwise contours (holes counter-clockwise), snapped to the 64-unit grid.

EXCLUDE lists, per face, characters deliberately NOT added (drawings that
don't hold up at that size — they fall back to another font instead).

cmap (every BMP subtable), hmtx, glyf/loca and glyph order are updated;
maxp/hhea/head bounds and the OS/2 unicode-range/first-last-char fields are
recalculated on save.  Existing glyphs and their metrics are never touched;
finalize() sets the version/description name records (credit + CC BY-SA note)
and widens usWinAscent/usWinDescent to the real glyph extent (the clip box
Windows and browsers use) — hhea/typo metrics stay the originals'.
Idempotent: a codepoint already in the cmap is never touched, so re-running
is a no-op.

Usage:  codec_font_glyphs.py [--dry-run] [--backup DIR] [font.ttf ...]
(defaults to the two mechui fonts).  The fonts are compiled into the binary
via qrc — rebuild codec; the installed copy in ~/.local/share/fonts/codec
syncs on codec's next launch; restart codec-serve for the web pages.
See docs/fonts/README.md.
"""
import argparse
import os
import shutil
import sys
import textwrap
from collections import Counter

from fontTools.pens.recordingPen import DecomposingRecordingPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import TTFont

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_FONTS = [os.path.join(REPO, "assets/mechui/mgs-codec.ttf"),
                 os.path.join(REPO, "assets/mechui/mgs-hud.ttf")]
GRID = 64  # the MGS fonts are drawn on a 64-unit pixel grid

# ---------------------------------------------------------------------------
# v1.35 composable set (unchanged)
# ---------------------------------------------------------------------------
# codepoint -> (glyph name, [source chars placed side by side])
SEQUENCES = {
    0xFB00: ("f_f", "ff"),
    0xFB01: ("f_i", "fi"),
    0xFB02: ("f_l", "fl"),
    0xFB03: ("f_f_i", "ffi"),
    0xFB04: ("f_f_l", "ffl"),
    0xFB05: ("longs_t", "st"),   # no long-s in the font: ſt -> s+t
    0xFB06: ("s_t", "st"),
    0x2018: ("quoteleft", "'"),
    0x2019: ("quoteright", "'"),
    0x201C: ("quotedblleft", '"'),
    0x201D: ("quotedblright", '"'),
    0x2026: ("ellipsis", "..."),
    0x2013: ("endash", "-"),
    0x2014: ("emdash", "--"),
    # --- this pass ---
    0x2016: ("dblverticalbar", "||"),
    0x201E: ("quotedblbase", ",,"),
    0x203C: ("exclamdbl", "!!"),
    0x0132: ("IJ", "IJ"),            # Ĳ (and ĳ via ALIASES)
    0x013F: ("Ldot", "L•"),          # Ŀ: L + the font's middle dot
    0x0149: ("napostrophe", "'N"),   # ŉ
    0x2025: ("twodotleader", ".."),
    0x2047: ("questiondbl", "??"), 0x2048: ("questionexclam", "?!"),
    0x2049: ("exclamquestion", "!?"),
    0x2103: ("degreecelsius", "°C"), 0x2109: ("degreefahrenheit", "°F"),
}
NBSP = 0x00A0

# accented letter -> (base char, accent kind) using the font's OWN acute/grave
# marks (v1.35; the originals map upper+lower to one glyph, these are separate)
ACCENTED = {
    "é": ("e", "acute"), "è": ("e", "grave"), "á": ("a", "acute"),
    "à": ("a", "grave"), "í": ("i", "acute"), "ó": ("o", "acute"),
    "ú": ("u", "acute"),
    "É": ("E", "acute"), "È": ("E", "grave"), "Á": ("A", "acute"),
    "À": ("A", "grave"), "Í": ("I", "acute"), "Ó": ("O", "acute"),
    "Ú": ("U", "acute"),
}

# ---------------------------------------------------------------------------
# This pass: composites of base + mark.  One glyph per entry, named
# <base><mark>, mapped from EVERY char in the string (unicase: Ä and ä share).
# "acute"/"grave" are the font's own marks; the rest are drawn below.
# ---------------------------------------------------------------------------
ACCENTS = [
    ("Ìì", "I", "grave"), ("Òò", "O", "grave"), ("Ùù", "U", "grave"),
    ("Ýý", "Y", "acute"), ("Ćć", "C", "acute"), ("Ĺĺ", "L", "acute"),
    ("Ńń", "N", "acute"), ("Ŕŕ", "R", "acute"), ("Śś", "S", "acute"),
    ("Źź", "Z", "acute"),
    ("Ââ", "A", "circumflex"), ("Êê", "E", "circumflex"), ("Îî", "I", "circumflex"),
    ("Ôô", "O", "circumflex"), ("Ûû", "U", "circumflex"), ("Ĉĉ", "C", "circumflex"),
    ("Ĝĝ", "G", "circumflex"), ("Ĥĥ", "H", "circumflex"), ("Ĵĵ", "J", "circumflex"),
    ("Ŝŝ", "S", "circumflex"), ("Ŵŵ", "W", "circumflex"), ("Ŷŷ", "Y", "circumflex"),
    ("Ãã", "A", "tilde"), ("Ññ", "N", "tilde"), ("Õõ", "O", "tilde"),
    ("Ĩĩ", "I", "tilde"), ("Ũũ", "U", "tilde"),
    ("Ää", "A", "dieresis"), ("Ëë", "E", "dieresis"), ("Ïï", "I", "dieresis"),
    ("Öö", "O", "dieresis"), ("Üü", "U", "dieresis"), ("Ÿÿ", "Y", "dieresis"),
    ("Åå", "A", "ring"), ("Ůů", "U", "ring"),
    ("Çç", "C", "cedilla"), ("Ģģ", "G", "cedilla"), ("Ķķ", "K", "cedilla"),
    ("Ļļ", "L", "cedilla"), ("Ņņ", "N", "cedilla"), ("Ŗŗ", "R", "cedilla"),
    ("Şş", "S", "cedilla"), ("Ţţ", "T", "cedilla"),
    ("Čč", "C", "caron"), ("Ďď", "D", "caron"), ("Ěě", "E", "caron"),
    ("Ľľ", "L", "caron"), ("Ňň", "N", "caron"), ("Řř", "R", "caron"),
    ("Šš", "S", "caron"), ("Ťť", "T", "caron"), ("Žž", "Z", "caron"),
    ("Āā", "A", "macron"), ("Ēē", "E", "macron"), ("Īī", "I", "macron"),
    ("Ōō", "O", "macron"), ("Ūū", "U", "macron"),
    ("Ăă", "A", "breve"), ("Ĕĕ", "E", "breve"), ("Ğğ", "G", "breve"),
    ("Ĭĭ", "I", "breve"), ("Ŏŏ", "O", "breve"), ("Ŭŭ", "U", "breve"),
    ("Ċċ", "C", "dotaccent"), ("Ėė", "E", "dotaccent"), ("Ġġ", "G", "dotaccent"),
    ("İ", "I", "dotaccent"), ("Żż", "Z", "dotaccent"),
    ("Őő", "O", "hungarumlaut"), ("Űű", "U", "hungarumlaut"),
    ("Ąą", "A", "ogonek"), ("Ęę", "E", "ogonek"), ("Įį", "I", "ogonek"),
    ("Ųų", "U", "ogonek"),
    ("Ŋŋ", "N", "enghook"),
]
# spacing modifier codepoints that show the mark glyph itself
MARK_CPS = {
    "dieresis": [0x00A8], "macron": [0x00AF], "cedilla": [0x00B8],
    "circumflex": [0x02C6], "caron": [0x02C7], "breve": [0x02D8],
    "dotaccent": [0x02D9], "ring": [0x02DA], "ogonek": [0x02DB],
    "tilde": [0x02DC], "hungarumlaut": [0x02DD],
}
# Œ œ: O then E overlapping by the same amount the font's own Æ overlaps A+E
OE = (0x0152, 0x0153)

# codepoint -> char/glyph whose glyph it simply re-uses (no new outline)
ALIASES = {
    0x00AD: "-",        # soft hyphen
    0x2010: "-", 0x2011: "-", 0x2012: "-",   # hyphen, nb-hyphen, figure dash
    0x2212: "-",        # minus (the hyphen is already the width of +'s bar)
    0x2015: "—",        # horizontal bar
    0x2044: "/", 0x2215: "/",                # fraction / division slash
    0x201A: ",",        # ‚ single low-9 quote
    0x2032: "'", 0x2033: '"',                # prime, double prime
    0x02BC: "'",        # modifier apostrophe
    0x00B7: "•", 0x2219: "•",                # middle dot (the bullet IS period-sized at cap-middle)
    0x0131: "i", 0x017F: "s", 0x0138: "k",   # dotless i, long s, kra (unicase)
    0x0133: "Ĳ",        # ĳ
    0x0140: "Ŀ", 0x0218: "Ş", 0x0219: "Ş", 0x021A: "Ţ", 0x021B: "Ţ",
    0x1E9E: "ß",        # capital sharp s
    0x0110: "Ð", 0x0111: "Ð",                # Đ đ: same barred D as eth (unicase)
    0x2023: "▸",        # triangular bullet
    0x2717: "❌", 0x2715: "❌",               # ballot x, multiplication x
    0x27F3: "↻",        # clockwise gapped circle arrow
    0x25B9: "▸", 0x25C3: "◂",                # white small triangles -> same
    0x2755: "!",        # ❕ (codec draws its own; the HUD face re-uses !)
    0x25AE: "❚",        # black vertical rectangle
    0x21B6: "↺", 0x21B7: "↻",                # semicircle arrows
    0x21B5: "⏎",        # downwards arrow with corner leftwards (= return)
}

# glyph name -> codepoints, for the hand-drawn bitmaps below (shared by both
# faces; a face that lacks the art for a name just reports it)
ART_CPS = {
    "exclamdown": [0x00A1], "cent": [0x00A2], "sterling": [0x00A3],
    "currency": [0x00A4], "yen": [0x00A5], "brokenbar": [0x00A6],
    "section": [0x00A7], "copyright": [0x00A9], "ordfeminine": [0x00AA],
    "guillemotleft": [0x00AB], "logicalnot": [0x00AC], "registered": [0x00AE],
    "degree": [0x00B0], "plusminus": [0x00B1], "acute": [0x00B4],
    "mu": [0x00B5], "paragraph": [0x00B6], "ordmasculine": [0x00BA],
    "guillemotright": [0x00BB], "onequarter": [0x00BC], "onehalf": [0x00BD],
    "threequarters": [0x00BE], "questiondown": [0x00BF], "Eth": [0x00D0, 0x00F0],
    "Thorn": [0x00DE, 0x00FE], "germandbls": [0x00DF], "divide": [0x00F7],
    "Hbar": [0x0126, 0x0127], "Lslash": [0x0141, 0x0142],
    "Tbar": [0x0166, 0x0167],
    "dagger": [0x2020], "daggerdbl": [0x2021], "perthousand": [0x2030],
    "guilsinglleft": [0x2039], "guilsinglright": [0x203A],
    "zerosuperior": [0x2070], "onesuperior": [0x00B9], "twosuperior": [0x00B2],
    "threesuperior": [0x00B3], "foursuperior": [0x2074], "fivesuperior": [0x2075],
    "sixsuperior": [0x2076], "sevensuperior": [0x2077], "eightsuperior": [0x2078],
    "ninesuperior": [0x2079],
    "zeroinferior": [0x2080], "oneinferior": [0x2081], "twoinferior": [0x2082],
    "threeinferior": [0x2083], "fourinferior": [0x2084], "fiveinferior": [0x2085],
    "sixinferior": [0x2086], "seveninferior": [0x2087], "eightinferior": [0x2088],
    "nineinferior": [0x2089],
    "Euro": [0x20AC], "rupee": [0x20B9], "won": [0x20A9], "ruble": [0x20BD],
    "approxequal": [0x2248], "notequal": [0x2260], "lessequal": [0x2264],
    "greaterequal": [0x2265], "infinity": [0x221E], "radical": [0x221A],
    "checkmark": [0x2713], "heavycheckmark": [0x2714], "eighthnote": [0x266A], "beamedeighthnotes": [0x266B],
    "heart": [0x2665], "returnsymbol": [0x23CE], "shiftarrow": [0x21E7],
    "openbox": [0x2423], "warning": [0x26A0],
    "blackcircle": [0x25CF], "circlelefthalfblack": [0x25D0],
    "circlerighthalfblack": [0x25D1], "blacksquare": [0x25A0],
    "blacksmallsquare": [0x25AA], "whitesmallsquare": [0x25AB],
    "blackdiamond": [0x25C6], "whitediamond": [0x25C7],
    "blackstar": [0x2605], "whitestar": [0x2606],
    "triagup": [0x25B2], "triagdn": [0x25BC], "whitetriagup": [0x25B3],
    "whitetriagdn": [0x25BD], "triagrt": [0x25B6], "triaglf": [0x25C0],
    "smalltriagup": [0x25B4], "smalltriagdn": [0x25BE],
    "smalltriagrt": [0x25B8], "smalltriaglf": [0x25C2],
    "arrowleft": [0x2190], "arrowup": [0x2191], "arrowright": [0x2192],
    "arrowdown": [0x2193], "arrowboth": [0x2194], "arrowupdn": [0x2195],
    "arrowcw": [0x21BB], "arrowccw": [0x21BA],
    "plussuperior": [0x207A], "minussuperior": [0x207B],
    "plusinferior": [0x208A], "minusinferior": [0x208B],
    "whitediamondblack": [0x25C8], "heavybar": [0x275A], "pause": [0x23F8],
    "identical": [0x2261],
}


def G(adv, y0, art, x0=0, base=None):
    """One bitmap: rows top-to-bottom ('#' ink), y0 = y of the BOTTOM row,
    x0 = x of the left column, adv = advance — all in design pixels.
    base: a char whose glyph pixels are OR-ed in (overlay; see docstring)."""
    rows = textwrap.dedent(art).strip("\n").split("\n")
    w = max(len(r) for r in rows)
    return dict(adv=adv, y0=y0, x0=x0, rows=[r.ljust(w, ".") for r in rows], base=base)


CODEC_ART = {}  # filled below
HUD_ART = {}    # filled below

# ===========================================================================
# MGS1 Codec art — 8x6 caps, 2–3 px stems / 1 px bars, 2x2 dot, thin symbols
# ===========================================================================
# 3x4 digit set used for super/subscripts and the vulgar fractions (both faces:
# the ™ / ①–⑨ glyphs show the designer draws small numerals thin and tiny)
_DIGITS = {
    "zero": "###/#.#/#.#/###", "one": ".#./##./.#./.#.", "two": "###/..#/#../###",
    "three": "###/.##/..#/###", "four": "#.#/###/..#/..#", "five": "###/##./..#/###",
    "six": "#../###/#.#/###", "seven": "###/..#/..#/..#", "eight": "###/#.#/###/###",
    "nine": "###/#.#/###/..#",
}


def _digits(table, y_sup, y_sub, adv=4):
    for d, a in _DIGITS.items():
        table[d + "superior"] = G(adv, y_sup, a.replace("/", "\n"))
        table[d + "inferior"] = G(adv, y_sub, a.replace("/", "\n"))


def _compose(adv, parts):
    """parts: [(art, x, y0)] -> one G() from their union (art rows top-down)."""
    px = set()
    for a, x, y0 in parts:
        rows = a.split("/")
        px |= {(x + c, y0 + len(rows) - 1 - r) for r, row in enumerate(rows)
               for c, ch in enumerate(row) if ch == "#"}
    xs, ys = [p[0] for p in px], [p[1] for p in px]
    x0, y0, x1, y1 = min(xs), min(ys), max(xs), max(ys)
    rows = ["".join("#" if (x, y) in px else "." for x in range(x0, x1 + 1))
            for y in range(y1, y0 - 1, -1)]
    return G(adv, y0, "\n".join(rows), x0)


def _fractions(table, adv, num_xy, slash, den_xy):
    nx, ny = num_xy
    dx, dy = den_xy
    s = "/".join("".join("#" if (x, y) in slash else "." for x in range(8))
                 for y in range(max(y for _x, y in slash), min(y for _x, y in slash) - 1, -1))
    sy = min(y for _x, y in slash)
    for name, n, d in (("onequarter", "one", "four"), ("onehalf", "one", "two"),
                       ("threequarters", "three", "four")):
        table[name] = _compose(adv, [(_DIGITS[n], nx, ny), (s, 0, sy), (_DIGITS[d], dx, dy)])


C = CODEC_ART
_digits(C, 3, -1)                                   # ⁰–⁹ at rows 3–6, ₀–₉ at rows −1–2
_fractions(C, 9, (0, 3), {(6, 4), (5, 3), (4, 2), (3, 1)}, (5, -1))
C["exclamdown"] = G(8, 0, """
    ###
    ...
    ###
    ###
    ###
    ###""")
C["cent"] = G(9, -1, "....#...\n" * 8, base="C")          # C + a bar through col 4
C["sterling"] = G(9, 0, """
    ..######
    .###....
    ######..
    .###....
    .###....
    ########""")
C["currency"] = G(11, 0, """
    #......#
    .######.
    .#....#.
    .#....#.
    .######.
    #......#""", x0=1)
C["yen"] = G(9, 0, """
    .######.
    ........
    .######.""", base="Y")                               # Y + two bars (rows 2, 0)
C["brokenbar"] = G(3, -1, """
    ##
    ##
    ##
    ..
    ..
    ##
    ##
    ##""")
C["section"] = G(9, 0, """
    .######.
    ##......
    .#####..
    ##...##.
    .#####..
    .....##.
    ######..""")
C["copyright"] = G(11, 0, """
    ..####..
    .#....#.
    #..##..#
    #.#....#
    #.#....#
    #..##..#
    .#....#.
    ..####..""", x0=1)
C["registered"] = G(11, 0, """
    ..####..
    .#....#.
    #.##...#
    #.#.#..#
    #.##...#
    #.#.#..#
    .#....#.
    ..####..""", x0=1)
C["ordfeminine"] = G(5, 3, """
    .##.
    ####
    #..#""")
C["ordmasculine"] = G(5, 3, """
    ####
    #..#
    ####""")
C["guillemotleft"] = G(7, 1, """
    .##.##
    ##.##.
    ##.##.
    .##.##""")
C["guillemotright"] = G(7, 1, """
    ##.##.
    .##.##
    .##.##
    ##.##.""")
C["guilsinglleft"] = G(4, 1, """
    .##
    ##.
    ##.
    .##""")
C["guilsinglright"] = G(4, 1, """
    ##.
    .##
    .##
    ##.""")
C["logicalnot"] = G(9, 0, """
    ########
    ########
    ......##
    ......##""")
C["degree"] = G(5, 3, """
    .##.
    #..#
    .##.""")
C["plusminus"] = G(9, 0, """
    ...##...
    ...##...
    ########
    ########
    ...##...
    ........
    ########""")
C["acute"] = G(6, 4, """
    ..###
    .###.
    ###..""")                                            # mirror of the font's `
C["mu"] = G(9, -1, """
    #......#
    ##......""", base="U")                               # U + stem continuing below
C["paragraph"] = G(9, 0, """
    .#######
    ####.#.#
    ####.#.#
    .###.#.#
    .....#.#
    .....#.#""")
C["questiondown"] = G(9, 0, """
    ...##...
    ........
    ...##...
    .###....
    ###..###
    .######.""")
C["Eth"] = G(9, 3, "######", x0=-1, base="D")            # D + bar through the stem
C["Thorn"] = G(9, 0, """
    ###.....
    #######.
    ###...##
    ###...##
    #######.
    ###.....""")
C["germandbls"] = G(9, 0, """
    .######.
    ###...##
    ###.###.
    ###...##
    ###...##
    ###.###.""")
C["divide"] = G(9, 0, """
    ...##...
    ........
    ########
    ########
    ........
    ...##...""")
C["Hbar"] = G(9, 5, "########", base="H")               # H + bar across the top
C["Lslash"] = G(9, 2, """
    .....#...
    ....#....
    #........""", x0=-1, base="L")                       # L + a stroke through the stem
C["Tbar"] = G(9, 2, "..####..", base="T")               # T + bar across the stem
C["dagger"] = G(9, 0, """
    ...##...
    .######.
    .######.
    ...##...
    ...##...
    ...##...
    ...##...""")
C["daggerdbl"] = G(9, 0, """
    ...##...
    .######.
    .######.
    ...##...
    .######.
    .######.
    ...##...""")
C["perthousand"] = G(12, 0, """
    .........##
    .........##""", base="%")                            # % + a third ring
C["Euro"] = G(9, 0, """
    ..######
    .###....
    ######..
    .###....
    ######..
    ..######""")
C["rupee"] = G(9, 0, """
    ########
    ...###..
    ########
    ...###..
    ..###...
    .###....""")
C["won"] = G(9, 4, "########", base="W")                # W + bar
C["ruble"] = G(9, 1, "#####...", base="P")              # P + bar under the bowl
C["approxequal"] = G(9, 1, """
    .##...##
    #..###..
    ........
    .##...##
    #..###..""")
C["notequal"] = G(9, -1, """
    .......#
    ........
    ........
    ....#...
    ...#....
    ........
    ........
    #.......""", base="=")                               # = + a slash through
C["lessequal"] = G(6, 0, """
    ...##
    ..##.
    .##..
    ..##.
    ...##
    .....
    #####""")
C["greaterequal"] = G(6, 0, """
    ##...
    .##..
    ..##.
    .##..
    ##...
    .....
    #####""")
C["infinity"] = G(9, 1, """
    .##..##.
    #..##..#
    #..##..#
    .##..##.""")
C["radical"] = G(9, 0, """
    .......#
    ......#.
    .....#..
    #...#...
    .#.#....
    ..#.....""")
C["checkmark"] = G(9, 0, """
    .......#
    ......##
    #....##.
    ##..##..
    .####...
    ..##....""")
C["heavycheckmark"] = C["checkmark"]   # the codec check is already 2 px
C["eighthnote"] = G(9, 0, """
    .....##.
    .....#.#
    .....#.#
    .....#..
    .....#..
    ..####..
    ..####..""")
C["beamedeighthnotes"] = G(9, 0, """
    ..######
    ..#....#
    ..#....#
    ..#....#
    ..#....#
    ###..###
    ###..###""")
C["heart"] = G(11, 0, """
    .##..##.
    ########
    ########
    .######.
    ..####..
    ...##...""", x0=1)
C["returnsymbol"] = G(9, 1, """
    .......#
    .......#
    ..#....#
    .#######
    ..#.....""")
C["shiftarrow"] = G(9, 0, """
    ...##...
    ..#..#..
    .#....#.
    ###..###
    ..#..#..
    ..#..#..
    ..####..""")
C["openbox"] = G(9, 0, """
    ##....##
    ##....##
    ########""")
C["warning"] = G(11, 0, """
    ....#....
    ...#.#...
    ..#.#.#..
    ..#.#.#..
    .#.....#.
    .#..#..#.
    #########""", x0=1)
C["blackcircle"] = G(10, 0, """
    ..###..
    .#####.
    #######
    #######
    .#####.
    ..###..""", x0=1)
C["circlelefthalfblack"] = G(10, 0, """
    ..###..
    .##..#.
    ###...#
    ###...#
    .##..#.
    ..###..""", x0=1)
C["circlerighthalfblack"] = G(10, 0, """
    ..###..
    .#..##.
    #...###
    #...###
    .#..##.
    ..###..""", x0=1)
C["blacksquare"] = G(10, 0, "######\n" * 6, x0=2)
C["blacksmallsquare"] = G(6, 1, "####\n" * 4, x0=1)
C["whitesmallsquare"] = G(6, 1, """
    ####
    #..#
    #..#
    ####""", x0=1)
C["blackdiamond"] = G(10, 0, """
    ...#...
    ..###..
    .#####.
    .#####.
    ..###..
    ...#...""", x0=1)
C["whitediamond"] = G(10, 0, """
    ...#...
    ..#.#..
    .#...#.
    .#...#.
    ..#.#..
    ...#...""", x0=1)
C["blackstar"] = G(10, 0, """
    ...#...
    ..###..
    #######
    .#####.
    ..###..
    .##.##.
    #.....#""", x0=1)
C["whitestar"] = G(10, 0, """
    ...#...
    ..#.#..
    ##...##
    .#...#.
    ..###..
    .##.##.
    #.....#""", x0=1)
C["whitetriagdn"] = G(10, 0, """
    #######
    ##...##
    .#...#.
    ..#.#..
    ..###..
    ...#...""", x0=1)
C["triagrt"] = G(9, 0, """
    ##....
    ####..
    ######
    ######
    ####..
    ##....""", x0=1)
C["triaglf"] = G(9, 0, """
    ....##
    ..####
    ######
    ######
    ..####
    ....##""", x0=1)
C["smalltriagrt"] = G(6, 0, """
    #...
    ###.
    ####
    ###.
    #...""", x0=1)
C["smalltriaglf"] = G(6, 0, """
    ...#
    .###
    ####
    .###
    ...#""", x0=1)
C["smalltriagup"] = G(8, 1, """
    ..##..
    .####.
    ######""", x0=1)
C["smalltriagdn"] = G(8, 1, """
    ######
    .####.
    ..##..""", x0=1)
C["arrowboth"] = G(8, 3, """
    .#...#.
    #######
    .#...#.""")
C["arrowupdn"] = G(5, 2, """
    .#.
    ###
    .#.
    ###
    .#.""", x0=1)
C["arrowcw"] = G(10, 0, """
    ..##.#.
    .#..##.
    #...###
    #......
    #.....#
    .#...#.
    ..###..""", x0=1)
C["arrowccw"] = G(10, 0, """
    .#.##..
    .##..#.
    ###...#
    ......#
    #.....#
    .#...#.
    ..###..""", x0=1)
C["plussuperior"] = G(4, 4, ".#.\n###\n.#.")
C["minussuperior"] = G(4, 5, "###")
C["plusinferior"] = G(4, 0, ".#.\n###\n.#.")
C["minusinferior"] = G(4, 1, "###")
C["whitediamondblack"] = G(10, 0, """
    ...#...
    ..#.#..
    .#.#.#.
    .#.#.#.
    ..#.#..
    ...#...""", x0=1)
C["heavybar"] = G(4, 0, "###\n" * 6)
C["pause"] = G(6, 0, "##.##\n" * 6)
C["identical"] = G(9, 1, """
    ########
    ........
    ########
    ........
    ########""")
# marks: drawn over an 8-wide base, bottom pixel at col 4 like the font's acute
C["mark.dieresis"] = G(9, 6, """
    ..##.##.
    ..##.##.""")
C["mark.circumflex"] = G(9, 6, """
    ...##...
    ..#..#..""")
C["mark.caron"] = G(9, 6, """
    ..#..#..
    ...##...""")
C["mark.tilde"] = G(9, 6, """
    ..##..#.
    .#..##..""")
C["mark.ring"] = G(9, 6, """
    ...##...
    ..#..#..
    ...##...""")
C["mark.macron"] = G(9, 7, "..####..")
C["mark.breve"] = G(9, 6, """
    .#....#.
    ..####..""")
C["mark.dotaccent"] = G(9, 6, """
    ...##...
    ...##...""")
C["mark.hungarumlaut"] = G(9, 6, """
    ...#.#..
    ..#.#...""")
C["mark.cedilla"] = G(9, -2, """
    ....#...
    ...##...""")
C["mark.ogonek"] = G(9, -2, """
    .....#..
    ......##""")
C["mark.enghook"] = G(9, -2, """
    ......#.
    ....##..""")

# ===========================================================================
# MGS1 HUD art — 5x5 caps, every stroke 1 px
# ===========================================================================
H = HUD_ART
_digits(H, 2, -1)                                   # ⁰–⁹ at rows 2–5, ₀–₉ at rows −1–2
_fractions(H, 8, (0, 2), {(4, 3), (3, 2), (2, 1)}, (4, -1))
H["exclamdown"] = G(2, 0, "#\n.\n#\n#\n#")
H["cent"] = G(6, -1, "..#..\n" * 7, base="C")
H["sterling"] = G(6, 0, """
    .####
    #....
    ###..
    #....
    #####""")
H["currency"] = G(6, 0, """
    #...#
    .###.
    .#.#.
    .###.
    #...#""")
H["yen"] = G(6, 1, """
    ..#..
    .###.""", base="Y")
H["brokenbar"] = G(2, 0, "#\n#\n.\n#\n#")
H["section"] = G(6, 0, """
    .####
    #....
    .###.
    #...#
    .###.
    ....#
    ####.""")
H["copyright"] = G(8, 0, """
    ..###..
    .#...#.
    #..##.#
    #.#...#
    #..##.#
    .#...#.
    ..###..""")
H["registered"] = G(8, 0, """
    ..###..
    .#...#.
    #.##..#
    #.##..#
    #.#.#.#
    .#...#.
    ..###..""")
H["ordfeminine"] = G(4, 2, """
    .#.
    ###
    #.#""")
H["ordmasculine"] = G(4, 2, """
    ###
    #.#
    ###""")
H["guillemotleft"] = G(5, 1, """
    .#.#
    #.#.
    .#.#""")
H["guillemotright"] = G(5, 1, """
    #.#.
    .#.#
    #.#.""")
H["guilsinglleft"] = G(3, 1, ".#\n#.\n.#")
H["guilsinglright"] = G(3, 1, "#.\n.#\n#.")
H["logicalnot"] = G(6, 1, """
    #####
    ....#""")
H["degree"] = G(4, 2, """
    .#.
    #.#
    .#.""")
H["plusminus"] = G(6, 0, """
    ..#..
    #####
    ..#..
    .....
    #####""")
H["acute"] = G(4, 2, """
    ..#
    .#.
    #..""")
H["mu"] = G(6, -1, """
    #...#
    #....""", base="U")
H["paragraph"] = G(6, 0, """
    .####
    ###.#
    ###.#
    .#..#
    .#..#""")
H["questiondown"] = G(6, 0, """
    ..#..
    .....
    .##..
    #...#
    .###.""")
H["Eth"] = G(6, 2, "###", x0=-1, base="D")
H["Thorn"] = G(6, 0, """
    #....
    ####.
    #...#
    ####.
    #....""")
H["germandbls"] = G(6, 0, """
    .###.
    #...#
    #.##.
    #...#
    #.##.""")
H["divide"] = G(6, 0, """
    ..#..
    .....
    #####
    .....
    ..#..""")
H["Hbar"] = G(6, 4, "#####", base="H")
H["Lslash"] = G(6, 1, """
    ..#
    .#.
    #..""", x0=-1, base="L")
H["Tbar"] = G(6, 2, ".###.", base="T")
H["dagger"] = G(6, 0, """
    ..#..
    #####
    ..#..
    ..#..
    ..#..
    ..#..""")
H["daggerdbl"] = G(6, 0, """
    ..#..
    #####
    ..#..
    ..#..
    #####
    ..#..""")
H["perthousand"] = G(9, 0, """
    ......##
    ......##""", base="%")
H["Euro"] = G(6, 0, """
    .####
    ###..
    #....
    ###..
    .####""")
H["rupee"] = G(6, 0, """
    #####
    ..##.
    #####
    .##..
    #....""")
H["won"] = G(6, 3, "#####", base="W")
H["ruble"] = G(6, 1, "###..", base="P")
H["approxequal"] = G(6, 0, """
    .#..#
    #.##.
    .....
    .#..#
    #.##.""")
H["notequal"] = G(6, 0, """
    ....#
    .....
    ..#..
    .....
    #....""", base="=")
H["lessequal"] = G(4, 0, """
    ..#
    .#.
    #..
    .#.
    ###""")
H["greaterequal"] = G(4, 0, """
    #..
    .#.
    ..#
    .#.
    ###""")
H["infinity"] = G(6, 1, """
    .#.#.
    #.#.#
    .#.#.""")
H["radical"] = G(6, 0, """
    ....#
    ...#.
    ...#.
    #.#..
    .#...""")
H["checkmark"] = G(6, 0, """
    ....#
    ...#.
    #.#..
    .#...""")
# ✔ — the ✓ at the digits' weight (they double their right stem, #..##),
# so a "done" mark beside a year/resolution doesn't read faint
H["heavycheckmark"] = G(6, 0, """
    ....#
    ...##
    #.##.
    ###..
    .#...""")
H["eighthnote"] = G(6, 0, """
    ..##.
    ..#.#
    ..#..
    ..#..
    ###..
    ##...""")
H["beamedeighthnotes"] = G(6, 0, """
    .####
    .#..#
    .#..#
    .#..#
    ##.##
    ##.##""")
H["heart"] = G(6, 0, """
    .#.#.
    #####
    #####
    .###.
    ..#..""")
H["returnsymbol"] = G(6, 1, """
    ....#
    .#..#
    #####
    .#...""")
H["shiftarrow"] = G(6, 0, """
    ..#..
    .#.#.
    #...#
    ##.##
    .#.#.
    .###.""")
H["openbox"] = G(6, 0, """
    #...#
    #####""")
H["warning"] = G(8, 0, """
    ...#...
    ..#.#..
    .#.#.#.
    .#.#.#.
    #.....#
    #..#..#
    #######""")
H["blackcircle"] = G(6, 0, """
    .###.
    #####
    #####
    #####
    .###.""")
H["circlelefthalfblack"] = G(6, 0, """
    .###.
    ##..#
    ##..#
    ##..#
    .###.""")
H["circlerighthalfblack"] = G(6, 0, """
    .###.
    #..##
    #..##
    #..##
    .###.""")
H["blacksquare"] = G(6, 0, "#####\n" * 5)
H["blacksmallsquare"] = G(5, 1, "###\n" * 3, x0=1)
H["whitesmallsquare"] = G(5, 1, """
    ###
    #.#
    ###""", x0=1)
H["blackdiamond"] = G(6, 0, """
    ..#..
    .###.
    #####
    .###.
    ..#..""")
H["whitediamond"] = G(6, 0, """
    ..#..
    .#.#.
    #...#
    .#.#.
    ..#..""")
H["blackstar"] = G(6, 0, """
    ..#..
    #####
    .###.
    .#.#.
    #...#""")
H["whitestar"] = G(6, 0, """
    ..#..
    ##.##
    .#.#.
    .#.#.
    #...#""")
H["triagup"] = G(6, 0, """
    ..#..
    ..#..
    .###.
    .###.
    #####""")
H["triagdn"] = G(6, 0, """
    #####
    .###.
    .###.
    ..#..
    ..#..""")
H["whitetriagdn"] = G(6, 0, """
    #####
    .#.#.
    .#.#.
    ..#..
    ..#..""")
H["triagrt"] = G(6, 0, """
    ##...
    ####.
    #####
    ####.
    ##...""")
H["triaglf"] = G(6, 0, """
    ...##
    .####
    #####
    .####
    ...##""")
H["smalltriagrt"] = G(3, 1, "#.\n##\n#.")
H["smalltriaglf"] = G(3, 1, ".#\n##\n.#")
H["smalltriagup"] = G(4, 1, ".#.\n###")
H["smalltriagdn"] = G(4, 1, "###\n.#.")
H["arrowleft"] = G(6, 0, """
    ..#..
    .#...
    #####
    .#...
    ..#..""")
H["arrowright"] = G(6, 0, """
    ..#..
    ...#.
    #####
    ...#.
    ..#..""")
H["arrowup"] = G(6, 0, """
    ..#..
    .###.
    #.#.#
    ..#..
    ..#..""")
H["arrowdown"] = G(6, 0, """
    ..#..
    ..#..
    #.#.#
    .###.
    ..#..""")
H["arrowboth"] = G(6, 1, """
    .#.#.
    #####
    .#.#.""")
H["arrowupdn"] = G(4, 0, """
    .#.
    ###
    .#.
    ###
    .#.""")
H["arrowcw"] = G(6, 0, """
    ..#.#
    .#.##
    #.###
    #....
    .###.""")
H["arrowccw"] = G(6, 0, """
    #.#..
    ##.#.
    ###.#
    ....#
    .###.""")
H["plussuperior"] = G(4, 3, ".#.\n###\n.#.")
H["minussuperior"] = G(4, 4, "###")
H["plusinferior"] = G(4, 0, ".#.\n###\n.#.")
H["minusinferior"] = G(4, 1, "###")
H["whitediamondblack"] = G(6, 0, """
    ..#..
    .#.#.
    #.#.#
    .#.#.
    ..#..""")
H["heavybar"] = G(3, 0, "##\n" * 5)
H["pause"] = G(4, 0, "#.#\n" * 5)
H["identical"] = G(6, 0, """
    #####
    .....
    #####
    .....
    #####""")
# marks: drawn over a 5-wide base, bottom pixel at the centre col 2 like the
# font's acute; dots float one row clear (the 1-px style has no 2x2 dot)
H["mark.dieresis"] = G(6, 6, ".#.#.")
H["mark.circumflex"] = G(6, 5, """
    ..#..
    .#.#.""")
H["mark.caron"] = G(6, 5, """
    .#.#.
    ..#..""")
H["mark.tilde"] = G(6, 5, """
    .##.#
    #..#.""")
H["mark.ring"] = G(6, 5, """
    ..#..
    .#.#.
    ..#..""")
H["mark.macron"] = G(6, 6, ".###.")
H["mark.breve"] = G(6, 5, """
    #...#
    .###.""")
H["mark.dotaccent"] = G(6, 6, "..#..")
H["mark.hungarumlaut"] = G(6, 5, """
    ..#.#
    .#.#.""")
H["mark.cedilla"] = G(6, -2, """
    ..#..
    .##..""")
H["mark.ogonek"] = G(6, -2, """
    ...#.
    ....#""")
H["mark.enghook"] = G(6, -2, """
    ....#
    ..##.""")


# ---------------------------------------------------------------------------
# bitmap <-> outline helpers
# ---------------------------------------------------------------------------
def bmp_cmaps(font):
    return [t for t in font["cmap"].tables if t.isUnicode() and t.format in (4, 6, 12)]


def glyph_pixels(font, name):
    """Rasterise an existing glyph (composites decomposed) on the design grid
    -> set of (x, y) design pixels.  Non-zero winding at pixel centres."""
    gs = font.getGlyphSet()
    pen = DecomposingRecordingPen(gs)
    gs[name].draw(pen)
    contours, cur = [], []
    for op, args in pen.value:
        if op == "moveTo":
            cur = [args[0]]
        elif op == "lineTo":
            cur.append(args[0])
        elif op in ("qCurveTo", "curveTo"):
            cur.extend(a for a in args if a is not None)
        elif op in ("closePath", "endPath"):
            if cur:
                contours.append(cur)
            cur = []
    pts = [p for c in contours for p in c]
    if not pts:
        return set()
    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
    out = set()
    for gy in range(int(min(ys) // GRID), int(-(-max(ys) // GRID))):
        for gx in range(int(min(xs) // GRID), int(-(-max(xs) // GRID))):
            px, py, w = (gx + .5) * GRID, (gy + .5) * GRID, 0
            for c in contours:
                for i in range(len(c)):
                    x0, y0 = c[i]
                    x1, y1 = c[(i + 1) % len(c)]
                    if (y0 <= py < y1 or y1 <= py < y0) and \
                            x0 + (py - y0) / (y1 - y0) * (x1 - x0) > px:
                        w += 1 if y1 > y0 else -1
            if w:
                out.add((gx, gy))
    return out


def art_pixels(spec):
    rows, y0, x0 = spec["rows"], spec["y0"], spec["x0"]
    h = len(rows)
    return {(x0 + x, y0 + h - 1 - r) for r, row in enumerate(rows)
            for x, ch in enumerate(row) if ch == "#"}


def trace(pixels):
    """Pixel set -> list of closed contours (lists of (x, y) in font units):
    merged shapes, outer contours clockwise (y up), holes counter-clockwise,
    collinear points dropped.  Diagonal-only touching pixels stay separate."""
    edges = Counter()
    for x, y in pixels:  # clockwise square (y up): up, right, down, left
        for a, b in (((x, y), (x, y + 1)), ((x, y + 1), (x + 1, y + 1)),
                     ((x + 1, y + 1), (x + 1, y)), ((x + 1, y), (x, y))):
            if edges[(b, a)]:
                edges[(b, a)] -= 1
            else:
                edges[(a, b)] += 1
    out = {a: [] for a, b in edges if edges[(a, b)]}
    for (a, b), n in edges.items():
        if n:
            out[a].append(b)
    contours = []
    while any(out.values()):
        a = next(k for k, v in out.items() if v)
        start, cur, prev = a, a, None
        pts = []
        while True:
            pts.append(cur)
            nxts = out[cur]
            if prev is None or len(nxts) == 1:
                nxt = nxts[0]
            else:  # 4-way corner: turn RIGHT relative to the incoming direction
                dx, dy = cur[0] - prev[0], cur[1] - prev[1]
                right = (cur[0] + dy, cur[1] - dx)
                nxt = right if right in nxts else nxts[0]
            nxts.remove(nxt)
            prev, cur = cur, nxt
            if cur == start:
                break
        # drop collinear points
        n = len(pts)
        keep = [p for i, p in enumerate(pts)
                if (p[0] - pts[i - 1][0]) * (pts[(i + 1) % n][1] - p[1])
                != (p[1] - pts[i - 1][1]) * (pts[(i + 1) % n][0] - p[0])]
        contours.append([(x * GRID, y * GRID) for x, y in keep])
    return contours


def bitmap_glyph(font, pixels):
    pen = TTGlyphPen(font.getGlyphSet())
    for c in trace(pixels):
        pen.moveTo(c[0])
        for p in c[1:]:
            pen.lineTo(p)
        pen.closePath()
    return pen.glyph()


def find_marks(font):
    """Locate the acute/grave MARK glyphs via the existing Eacute/Agrave
    composites (base at 0,0 + a mark component above it)."""
    glyf, cmap = font["glyf"], font.getBestCmap()
    marks = {}
    for ch, kind in (("É", "acute"), ("À", "grave")):
        name = cmap.get(ord(ch))
        if not name or not glyf[name].isComposite():
            continue
        base = cmap.get(ord({"É": "E", "À": "A"}[ch]))
        for c in glyf[name].components:
            if c.glyphName != base:
                marks[kind] = (c.glyphName, c.x, c.y, base)
    return marks


def add_glyph(font, name, glyph, advance):
    order = font.getGlyphOrder()
    base, n = name, 1
    while name in order:  # never clobber an existing glyph name
        name = f"{base}.{n}"
        n += 1
    glyf = font["glyf"]
    glyph.recalcBounds(glyf)
    font.setGlyphOrder(order + [name])
    glyf.glyphOrder = font.getGlyphOrder()
    glyf.glyphs[name] = glyph
    font["hmtx"][name] = (advance, getattr(glyph, "xMin", 0) if glyph.numberOfContours else 0)
    return name


def map_cp(font, cp, name):
    for t in bmp_cmaps(font):
        t.cmap[cp] = name


# Characters a face deliberately does NOT get: drawings that don't hold up at
# that size. Leaving them out lets Qt/libass fall back to another font, which
# reads better than a pixel smudge ("the weak ones can just fallback").
EXCLUDE = {
    # the 5-px HUD: an outline star, circular arrows and solid down/up
    # triangles all collapse into blobs or a "T"
    "HUD": {0x2606, 0x21BA, 0x21BB, 0x21B6, 0x21B7, 0x27F3,
            0x25B2, 0x25BC, 0x25BD},
    # Codec: H-bar reads as an A
    "Codec": {0x0126, 0x0127},
}

# Font-file finishing that matters OUTSIDE codec (the author reuses these faces):
# credit + licence notes and clip-safe Windows metrics. hhea/typo metrics are
# NOT touched — Qt on Linux lays text out from them and codec's alignment
# (e.g. DetailView's hudDrop from ascents 512/384) depends on them.
VERSION_NOTE = ("Version 1.1; extended for codec 2026: full Latin-1 + Latin "
                "Extended-A, punctuation, super/subscripts, currency, math, UI "
                "symbols")
DESC_NOTE = (" Extended in 2026 for codec (Latin-1, Latin Extended-A, "
             "punctuation, symbols) on the original pixel grid; original glyphs "
             "unchanged. CC BY-SA 4.0, as the original.")


def finalize(font):
    """Idempotent metadata pass. Returns True if anything changed."""
    changed = False
    # Windows / browsers CLIP at usWinAscent/usWinDescent: cover the real
    # extent (accent rows above the caps, cedilla/ogonek hooks below). The
    # originals already drew one row past their 512/64 values.
    glyf = font["glyf"]
    ymax = max((glyf[g].yMax for g in font.getGlyphOrder()
                if hasattr(glyf[g], "yMax") and glyf[g].numberOfContours), default=0)
    ymin = min((glyf[g].yMin for g in font.getGlyphOrder()
                if hasattr(glyf[g], "yMin") and glyf[g].numberOfContours), default=0)
    # composites carry no bounds until recalculated
    for g in font.getGlyphOrder():
        gl = glyf[g]
        if gl.isComposite():
            gl.recalcBounds(glyf)
            ymax, ymin = max(ymax, gl.yMax), min(ymin, gl.yMin)
    os2 = font["OS/2"]
    if os2.usWinAscent < ymax:
        os2.usWinAscent = ymax
        changed = True
    if os2.usWinDescent < -ymin:
        os2.usWinDescent = -ymin
        changed = True
    name = font["name"]
    for rec in list(name.names):
        if rec.nameID == 5 and rec.toUnicode() != VERSION_NOTE:
            name.setName(VERSION_NOTE, 5, rec.platformID, rec.platEncID, rec.langID)
            changed = True
        if rec.nameID == 10 and DESC_NOTE.strip() not in rec.toUnicode():
            name.setName(rec.toUnicode() + DESC_NOTE, 10,
                         rec.platformID, rec.platEncID, rec.langID)
            changed = True
    if font["head"].fontRevision < 1.1:
        font["head"].fontRevision = 1.1
        changed = True
    # Underline / strikeout on the pixel grid (the originals carried generic
    # values: underline +102/51 sat ABOVE the baseline, through the letters'
    # bottom row). Both are "top of the stroke" (OpenType; FreeType -> Qt and
    # browsers agree): underline = one design px, one px clear below the
    # baseline; strikeout = one design px on the capitals' middle row (the
    # upper of the two when the cap height is even).
    px = 64
    post = font["post"]
    if (post.underlinePosition, post.underlineThickness) != (-px, px):
        post.underlinePosition, post.underlineThickness = -px, px
        changed = True
    cap_rows = font["glyf"]["H"].yMax // px
    strike_top = (cap_rows // 2 + 1) * px
    if (os2.yStrikeoutPosition, os2.yStrikeoutSize) != (strike_top, px):
        os2.yStrikeoutPosition, os2.yStrikeoutSize = strike_top, px
        changed = True
    return changed


def process(path, backup, dry):
    font = TTFont(path)
    # A COPY: getBestCmap() hands back the font's live subtable dict, and this
    # mirror gets placeholder entries (EXCLUDE) that must never reach the file.
    cmap = dict(font.getBestCmap())
    hmtx, glyf = font["hmtx"], font["glyf"]
    added, skipped = [], []
    fam = font["name"].getDebugName(1)
    art = CODEC_ART if "Codec" in fam else HUD_ART if "HUD" in fam else {}
    # Excluded characters look "present" to every step below, so none of them
    # is drawn, composed or aliased — they stay unmapped and fall back.
    excluded = EXCLUDE.get("Codec" if "Codec" in fam else "HUD" if "HUD" in fam else "", set())
    for cp in excluded:
        cmap.setdefault(cp, None)
    ref_adv = hmtx[cmap[ord("A")]][0]  # marks are drawn for an A-width base

    def gname(ch):
        return cmap.get(ord(ch))

    def note(cp):
        added.append(f"U+{cp:04X} {chr(cp)}")

    def new_bitmap(name, spec):
        px = art_pixels(spec)
        if spec["base"]:
            b = gname(spec["base"])
            if not b:
                return None
            px |= glyph_pixels(font, b)
        return add_glyph(font, name, bitmap_glyph(font, px), spec["adv"] * GRID)

    # 1. hand-drawn bitmaps -------------------------------------------------
    for name, cps in ART_CPS.items():
        todo = [cp for cp in cps if cp not in cmap]
        if not todo:
            continue
        if name not in art:
            skipped.append(f"{name} (no art for this face)")
            continue
        gn = new_bitmap(name, art[name])
        if not gn:
            skipped.append(f"{name} (base {art[name]['base']!r} missing)")
            continue
        for cp in todo:
            map_cp(font, cp, gn)
            cmap[cp] = gn
            note(cp)

    # 2. marks (drawn at their natural position over an A-width base) --------
    marks = find_marks(font)  # kind -> (glyph, x, y, ref base)
    kinds = {k for _c, _b, k in ACCENTS} | set(MARK_CPS)
    for kind in sorted(kinds - set(marks)):
        spec, cps = art.get("mark." + kind), MARK_CPS.get(kind, [])
        needed = any(ord(ch) not in cmap for chars, _b, k in ACCENTS
                     if k == kind for ch in chars) or any(cp not in cmap for cp in cps)
        if not spec or not needed:
            continue
        gn = new_bitmap(kind + "comb", spec)
        marks[kind] = (gn, 0, 0, cmap[ord("A")])
        for cp in cps:
            if cp not in cmap:
                map_cp(font, cp, gn)
                cmap[cp] = gn
                note(cp)

    def place_mark(base, kind):
        mark, mx, my, ref = marks[kind]
        # keep the mark's position relative to the reference base's centre,
        # re-centred on this base, snapped to the pixel grid
        dx = (hmtx[base][0] - hmtx[ref][0]) / 2
        dx = int(round(dx / GRID)) * GRID
        pen = TTGlyphPen(font.getGlyphSet())
        pen.addComponent(base, (1, 0, 0, 1, 0, 0))
        pen.addComponent(mark, (1, 0, 0, 1, mx + dx, my))
        return pen.glyph()

    # 3. v1.35 acute/grave letters (separate lower/upper glyphs, unchanged) --
    for ch, (b, kind) in ACCENTED.items():
        if ord(ch) in cmap:
            continue
        base = gname(b)
        if not base or kind not in marks:
            skipped.append(f"{ch} (no {kind} mark)")
            continue
        name = add_glyph(font, f"{b}{kind}", place_mark(base, kind), hmtx[base][0])
        map_cp(font, ord(ch), name)
        cmap[ord(ch)] = name
        note(ord(ch))

    # 4. this pass: one composite per (base, mark), every listed char --------
    for chars, b, kind in ACCENTS:
        todo = [ord(ch) for ch in chars if ord(ch) not in cmap]
        if not todo:
            continue
        base = gname(b)
        if not base or kind not in marks:
            skipped.append(f"{chars} (no {kind} mark)")
            continue
        name = add_glyph(font, f"{b}{kind}", place_mark(base, kind), hmtx[base][0])
        for cp in todo:
            map_cp(font, cp, name)
            cmap[cp] = name
            note(cp)

    # 5. side-by-side sequences ------------------------------------------------
    for cp, (name, seq) in SEQUENCES.items():
        if cp in cmap:
            continue
        srcs = [gname(c) for c in seq]
        if not all(srcs):
            skipped.append(f"U+{cp:04X} (no source for {seq!r})")
            continue
        pen, x = TTGlyphPen(font.getGlyphSet()), 0
        for s in srcs:
            pen.addComponent(s, (1, 0, 0, 1, x, 0))
            x += hmtx[s][0]
        name = add_glyph(font, name, pen.glyph(), x)
        map_cp(font, cp, name)
        cmap[cp] = name
        note(cp)

    # Œ: O + E overlapping exactly as the font's own Æ overlaps A + E
    if any(cp not in cmap for cp in OE) and gname("Æ") and glyf[gname("Æ")].isComposite():
        comps = glyf[gname("Æ")].components
        if len(comps) == 2 and gname("O") and gname("E"):
            pen = TTGlyphPen(font.getGlyphSet())
            pen.addComponent(gname("O"), (1, 0, 0, 1, 0, 0))
            pen.addComponent(gname("E"), (1, 0, 0, 1, comps[1].x, 0))
            name = add_glyph(font, "OE", pen.glyph(), hmtx[gname("Æ")][0])
            for cp in OE:
                if cp not in cmap:
                    map_cp(font, cp, name)
                    cmap[cp] = name
                    note(cp)

    if NBSP not in cmap and gname(" "):
        pen = TTGlyphPen(font.getGlyphSet())
        name = add_glyph(font, "uni00A0", pen.glyph(), hmtx[gname(" ")][0])
        map_cp(font, NBSP, name)
        cmap[NBSP] = name
        added.append("U+00A0 NBSP")

    # 6. aliases: re-use an existing glyph for a codepoint ------------------------
    for cp, target in ALIASES.items():
        if cp in cmap:
            continue
        tn = gname(target)
        if not tn:
            skipped.append(f"U+{cp:04X} (alias target {target!r} missing)")
            continue
        map_cp(font, cp, tn)
        cmap[cp] = tn
        note(cp)

    print(f"== {os.path.basename(path)} ({fam})")
    print(f"  added {len(added)}:", " ".join(added) or "(nothing — already complete)")
    if excluded:
        print("  left out (fall back):", " ".join(chr(c) for c in sorted(excluded)))
    if skipped:
        print("  skipped:", "; ".join(skipped))

    meta = finalize(font)
    if meta and not added:
        print("  metadata updated (version/description/win metrics)")
    if (added or meta) and not dry:
        if backup:
            os.makedirs(backup, exist_ok=True)
            dst = os.path.join(backup, os.path.basename(path))
            if not os.path.exists(dst):  # keep the pristine original
                shutil.copy2(path, dst)
        os2 = font["OS/2"]
        os2.recalcUnicodeRanges(font)
        cps = [cp for cp in font.getBestCmap() if 0x20 <= cp != 0xFFFD]
        os2.usFirstCharIndex = min(os2.usFirstCharIndex, min(cps))
        os2.usLastCharIndex = max(os2.usLastCharIndex, min(max(cps), 0xFFFF))
        font.save(path)
    return added


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("fonts", nargs="*", default=DEFAULT_FONTS)
    ap.add_argument("--backup", help="copy originals here before writing")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    for f in a.fonts:
        process(f, a.backup, a.dry_run)


if __name__ == "__main__":
    sys.exit(main())
