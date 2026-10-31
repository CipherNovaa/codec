# MGS pixel fonts — MGS1 Codec & MGS1 HUD

codec's two type faces, extended in 2026-10 to cover everything codec (and most
Western subtitles) needs, on the original pixel grid. Built to be reused in other
projects.

| File | Family | Use in codec | Characters |
|---|---|---|---|
| `assets/mechui/mgs-codec.ttf` | **MGS1 Codec** | headings, subtitles | 471 |
| `assets/mechui/mgs-hud.ttf` | **MGS1 HUD** | all UI body text | 452 |

Full character sheets: [`mgs-codec-specimen.png`](mgs-codec-specimen.png),
[`mgs-hud-specimen.png`](mgs-hud-specimen.png) (every character at the design size,
labelled with its code point).

## Licence — read before reusing

Both faces are by **Andrew Gleeson**, licensed **CC BY-SA 4.0**
(<https://creativecommons.org/licenses/by-sa/4.0/>). The 2026 extension is a
derivative, so in any project: credit Andrew Gleeson, keep the CC BY-SA 4.0
licence on the font files, and note they were modified. The font files carry this
in their own `name` table (version 1.1 string + description).

## What they cover

- **Basic Latin**, complete.
- **Latin-1 Supplement** (U+00A0–00FF) and **Latin Extended-A** (U+0100–017F),
  complete — every accented letter (é ñ ö å ç ß ł š ž ő …), ¡ ¿ « » ° ± ½ © § ¶ ….
  Also Ș ș Ț ț ẞ and the spacing marks ˆ ˇ ˘ ˙ ˚ ˛ ˜ ˝.
- **Punctuation**: – — ‐ ‒ ― ‘ ’ “ ” ‚ „ … ‥ † ‡ • ‣ ‰ ′ ″ ‹ › ‼ ⁇ ⁈ ⁉ ⁄.
- **Super/subscripts** ⁰–⁹ ₀–₉ ⁺ ⁻ ₊ ₋, fractions ¼ ½ ¾.
- **Currency** € £ ¥ ¢ ₹ ₩ ₽ ¤; **math** − ± × ÷ ≈ ≠ ≡ ≤ ≥ ∞ √ ° ℃ ℉.
- **UI symbols**: · ● ◐ ◑ ■ □ ▪ ▫ ◆ ◇ ★ ♥ ♪ ♫ ✓ ✔ ✗ ✕ ⚠ ⏎ ↵ ⇧ ␣ ⏸ ❚ ◂ ▸ ◀ ▶ ▴ ▾
  ← ↑ → ↓ ↔ ↕ (codec also ☆ ↻ ↺ ⟳ ▲ ▼ ▽ ①–⑨).
- **Ligatures** ﬀ ﬁ ﬂ ﬃ ﬄ ﬅ ﬆ (subtitle text often contains them precomposed).

**Deliberately left out** (they fall back to another font, which reads better than
a pixel smudge at this size): HUD ☆ ↻ ↺ ↶ ↷ ⟳ ▲ ▼ ▽; Codec Ħ ħ. Not covered at
all: Greek, Cyrillic, Vietnamese tone marks, CJK, emoji.

**Both faces are unicase** — a–z are the capitals.

## Design facts (from the files)

- upm 1024, drawn on a **64-unit pixel grid** = 16 design pixels per em. Crisp at
  16 px and its multiples (32, 48 …); other sizes resample.
- **Codec**: caps 6 px tall, stems 2–3 px, hhea ascent 512 / descent −64.
- **HUD**: caps 5 px tall, every stroke 1 px, hhea ascent 384 / descent −64.
- Accent rows sit directly on the capital and reach above the ascent (as the
  originals' É À did); Å © ® go one row higher, cedilla/ogonek hooks two rows
  below the baseline. `usWinAscent/usWinDescent` (the clip box Windows and
  browsers use) cover this; **hhea/typo metrics are the originals'** on purpose —
  Qt lays out from them and codec's alignment depends on them. In a tightly
  `clip`ped box, allow a pixel above and two below.
- **Underline** is one design pixel thick with one pixel of air under the
  baseline (`post` −64/64); **strikeout** is one design pixel on the capitals'
  middle row (OS/2: HUD 192/64, Codec 256/64). The originals carried generic
  values (underline +102 — through the letters).

## Using them elsewhere

- **Web**: `@font-face { font-family: mgshud; src: url(mgs-hud.ttf) }`, sizes in
  multiples of 16 px; `-webkit-font-smoothing: none` / `font-smooth: never` keep the
  pixels hard. WOFF2: `python3 -c "from fontTools.ttLib import TTFont; f=TTFont('mgs-hud.ttf'); f.flavor='woff2'; f.save('mgs-hud.woff2')"`
  (needs `brotli`).
- **Qt/QML**: `FontLoader { source: "…/mgs-hud.ttf" }`, then `font.family:
  loader.name`. ⚠ If the SAME family is also installed system-wide, Qt resolves the
  name through fontconfig and may use the installed copy — keep them identical
  (codec does this itself at startup, see below).
- **libass / mpv / ffmpeg subtitles**: point `fontsdir` / `sub-fonts-dir` at the
  folder and name the family (`FontName=MGS1 Codec`).

## How codec wires them

- Compiled into the binary (qrc) — `FontLoader`s in the QML.
- **Installed copy kept in sync automatically**: at startup, before Qt builds its
  font database, `syncMgsFonts()` (src/main.cpp) rewrites
  `~/.local/share/fonts/codec/mgs-*.ttf` if they differ from the built-in fonts
  and runs `fc-cache`. That copy is what the hub's ffmpeg burn-in, the dashboard
  and other apps use — and what Qt picks for the family name.
- mpv subtitles: `sub-fonts-dir` = `assets/mechui` (src/mpv/mpvengine.cpp).
- Cast receiver / party pages: inlined as data-URI `@font-face` by codec_serve.py
  (restart `codec-serve` after a font change; the TV reloads its receiver on its
  next start).
- `Theme.mgsSafe()` keeps every character **both** faces draw (read from the font
  files with QRawFont) and folds only the rest (⌫ → "DEL", unknown accents →
  base letter) — adding a glyph needs no code change.

## Changing a font

All extension glyphs are **ASCII-art bitmaps in `scripts/codec_font_glyphs.py`**
(per face where they differ), plus composites (base letter + mark) for accents, so
the original letters stay pixel-identical. The script is idempotent and never
touches an existing glyph or metric:

1. Restore the originals if you're redrawing an added glyph:
   `git show <rev>:assets/mechui/mgs-hud.ttf > assets/mechui/mgs-hud.ttf`
   (the pre-extension originals: any commit up to `74cddba`).
2. Edit the art / `EXCLUDE` list, run `scripts/codec_font_glyphs.py`
   (`--dry-run` first), then `scripts/codec_font_specimen.py` for fresh sheets.
3. Rebuild codec (qrc) — the installed copy syncs on next launch.
