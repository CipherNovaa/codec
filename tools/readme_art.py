#!/usr/bin/env python3
"""The README's banners — codec's own type over real frames from real films,
and over a couple of short animated clips.

The MGS faces are pixel fonts on a 16-px grid (docs/fonts/README.md), so every
size here is a multiple of 16 and drawn without antialiasing — the same law
the app follows. Frames are tone-mapped from the films' own 4K HDR
(ffmpeg + libplacebo, bt.2390) by whoever runs this; pass them in a folder.

    python3 tools/readme_art.py <frames-dir> <out-dir>
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

REPO = Path(__file__).resolve().parent.parent
FONTS = REPO / "assets/fonts"
BG = (13, 17, 25)
FG = (231, 236, 243)
STEEL = (166, 177, 199)
DIM = (93, 104, 128)
WARN = (217, 105, 74)


def font(face, k):
    for p in (FONTS / f"mgs-{face}.ttf", Path.home() / f".local/share/fonts/codec/mgs-{face}.ttf"):
        if p.exists():
            return ImageFont.truetype(str(p), 16 * k)
    raise SystemExit(f"mgs-{face}.ttf not found")


def text(d, xy, s, face, k, fill, spacing=0):
    """Draw spaced pixel text; returns the right edge."""
    f = font(face, k)
    x, y = xy
    for ch in s:
        d.text((x, y), ch, font=f, fill=fill)
        x += d.textlength(ch, font=f) + spacing
    return x - spacing


def width(d, s, face, k, spacing=0):
    f = font(face, k)
    return sum(d.textlength(c, font=f) for c in s) + spacing * (len(s) - 1)


def cover(img, w, h, focus=0.5, vfocus=0.5):
    """Scale to cover w×h, crop around a focus point."""
    s = max(w / img.width, h / img.height)
    im = img.resize((round(img.width * s), round(img.height * s)), Image.LANCZOS)
    x = int((im.width - w) * focus)
    y = int((im.height - h) * vfocus)
    return im.crop((x, y, x + w, y + h))


def shade(img, stops, vertical=False):
    """Darken with a gradient: stops = [(pos 0..1, alpha 0..255)]."""
    w, h = img.size
    n = h if vertical else w
    mask = Image.new("L", (w, h))
    px = []
    for i in range(n):
        t = i / max(n - 1, 1)
        for (p0, a0), (p1, a1) in zip(stops, stops[1:]):
            if p0 <= t <= p1:
                u = (t - p0) / max(p1 - p0, 1e-6)
                px.append(round(a0 + (a1 - a0) * u))
                break
        else:
            px.append(stops[-1][1])
    line = Image.new("L", (1, n) if vertical else (n, 1))
    line.putdata(px)
    mask = line.resize((w, h))
    return Image.composite(Image.new("RGB", (w, h), BG), img, mask)


def brackets(d, box, arm, col, t=2):
    x0, y0, x1, y1 = box
    for (x, y, dx, dy) in ((x0, y0, 1, 1), (x1, y0, -1, 1), (x0, y1, 1, -1), (x1, y1, -1, -1)):
        d.rectangle([min(x, x + dx * arm), min(y, y + dy * t), max(x, x + dx * arm), max(y, y + dy * t)], fill=col)
        d.rectangle([min(x, x + dx * t), min(y, y + dy * arm), max(x, x + dx * t), max(y, y + dy * arm)], fill=col)


def grain(img, amount=6):
    noise = Image.effect_noise(img.size, 40).convert("L").point(lambda v: 128 + (v - 128) * amount // 40)
    return Image.blend(img, Image.merge("RGB", (noise,) * 3), 0.035)


def scanlines(img, every=4, alpha=18):
    ov = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(ov)
    for y in range(0, img.height, every):
        d.line([(0, y), (img.width, y)], fill=(0, 0, 0, alpha))
    return Image.alpha_composite(img.convert("RGBA"), ov).convert("RGB")


def hero(frame, out):
    W, H = 2400, 1000
    im = cover(Image.open(frame).convert("RGB"), W, H, 0.5)
    im = shade(im, [(0, 235), (0.38, 150), (0.62, 30), (1, 70)])
    im = shade(im, [(0, 60), (0.55, 0), (0.86, 120), (1, 250)], vertical=True)
    im = grain(scanlines(im))
    d = ImageDraw.Draw(im)
    x = 150
    text(d, (x, 300), "MEDIA SYSTEM  ·  HUB", "hud", 2, STEEL, 8)
    right = text(d, (x - 6, 352), "CODEC", "codec", 12, FG, 44)
    d.rectangle([x, 560, right, 563], fill=STEEL)
    d.rectangle([x, 560, x + 96, 567], fill=FG)
    text(d, (x, 610), "YOUR FILMS. FULL QUALITY. EVERY SCREEN.", "hud", 3, FG, 6)
    text(d, (x, 690), "4K  ·  DOLBY VISION  ·  HDR10  ·  ATMOS  ·  CAST  ·  WATCH PARTY  ·  YOUTUBE", "hud", 2, STEEL, 4)
    # an MGS fan's frequency, bottom right
    s = "PTT  140.85"
    text(d, (W - 150 - width(d, s, "codec", 2, 6), H - 120), s, "codec", 2, DIM, 6)
    s = "DEVELOPER PREVIEW  ·  V1.49"
    text(d, (x, H - 120), s, "hud", 2, DIM, 6)
    brackets(d, (60, 60, W - 61, H - 61), 48, STEEL)
    im.save(out, quality=90, optimize=True, progressive=True)


def section(frame, out, index, title, sub, focus=0.6, tag="", vfocus=0.5):
    im = banner(Image.open(frame).convert("RGB"), index, title, sub, focus, tag, vfocus)
    im.save(out, quality=88, optimize=True, progressive=True)


def section_anim(clip, out, index, title, sub, focus=0.6, tag="", vfocus=0.5, art_w=None):
    """The same banner over every frame of an animated clip (GIF/WebP) -> animated WebP."""
    src = Image.open(clip)
    frames, durations = [], []
    for i in range(getattr(src, "n_frames", 1)):
        src.seek(i)
        frames.append(banner(src.convert("RGB"), index, title, sub, focus, tag, vfocus, still=False, art_w=art_w))
        durations.append(src.info.get("duration", 80) or 80)
    frames[0].save(out, save_all=True, append_images=frames[1:], duration=durations, loop=0,
                   quality=72, method=6)


def banner(img, index, title, sub, focus=0.6, tag="", vfocus=0.5, still=True, art_w=None):
    W, H = 2400, 480
    if art_w:   # a small source fills only the right of the banner, behind the shade
        im = Image.new("RGB", (W, H), BG)
        fade = Image.linear_gradient("L").rotate(90).resize((art_w, H))   # feather the art's left edge in
        fade = fade.point(lambda v: min(255, v * 3))   # 0 at the left edge, solid by a third of the way
        im.paste(cover(img, art_w, H, focus, vfocus), (W - art_w, 0), fade)
    else:
        im = cover(img, W, H, focus, vfocus)
    im = shade(im, [(0, 255), (0.30, 235), (0.62, 60), (1, 110)])
    im = shade(im, [(0, 90), (0.25, 0), (0.8, 0), (1, 150)], vertical=True)
    im = grain(scanlines(im)) if still else scanlines(im)   # no grain on a clip: it would crawl
    d = ImageDraw.Draw(im)
    x = 150
    nx = text(d, (x, 118), index + "  //  ", "hud", 2, STEEL, 6)
    if tag:
        text(d, (nx + 6, 118), tag, "hud", 2, FG, 6)
    right = text(d, (x - 4, 166), title, "codec", 6, FG, 18)
    d.rectangle([x, 286, max(right, x + 480), 287], fill=STEEL)
    d.rectangle([x, 286, x + 64, 291], fill=FG)
    assert width(d, sub, "hud", 3, 5) < W - 300, sub
    text(d, (x, 318), sub, "hud", 3, STEEL, 5)
    brackets(d, (48, 40, W - 49, H - 41), 32, DIM)
    return im


SECTIONS = [
    # file stem, frame, index, title, sub, focus, tag, extra (vfocus / art_w)
    ("03-hdr", "full_dk_4505.png", "03", "DOLBY VISION + HDR", "THE PICTURE THE STUDIO MADE, ON THE SCREEN YOU OWN.", 0.68, "DV · HDR10 · SDR", {}),
    ("04-cast", "full_inter_3300.png", "04", "CASTING", "ITS OWN CAST RECEIVER. NO APP ON THE TV.", 0.6, "4K TO THE TV", {}),
    ("05-party", "full_madmax_1500.png", "05", "WATCH PARTY", "ONE LINK. EVERYONE IN SYNC, AT THEIR BEST.", 0.6, "WEB PLAYER · CHAT", {}),
    ("07-hub", "full_ps_1219.png", "07", "HUB + SATELLITES", "ONE MACHINE SHARES. THE OTHERS JOIN.", 0.62, "HOME · AWAY", {}),
]

# Animated banners: a short clip (GIF/WebP) under the same type, small sources
# placed in the right of the banner.
CLIPS = [
    ("02-collection", "collection.gif", "02", "YOUR COLLECTION", "YOUR OWN DISKS, PRESENTED LIKE A PREMIUM SERVICE.", 0.5, "FILMS · SHOWS", {"vfocus": 0.4, "art_w": 1500}),
    ("06-youtube", "youtube.gif", "06", "YOUTUBE", "YOUR ACCOUNT, OR NO ACCOUNT AT ALL.", 0.5, "TWO WAYS IN", {"vfocus": 0.5, "art_w": 1500}),
    ("01-style", "style.webp", "01", "VISUAL STYLE", "HAND-DRAWN PIXEL CHROME. NOTHING IS A WEB PAGE.", 0.5, "MECH-UI", {"vfocus": 0.25, "art_w": 1500}),
    ("08-hood", "hood.gif", "08", "UNDER THE HOOD", "QT 6 · QML · LIBMPV · PYTHON · FFMPEG", 0.5, "HOW IT WORKS", {"vfocus": 0.35, "art_w": 1600}),
]


def main():
    """Frames are named as in the lists; a missing one is skipped. The shipped
    hero, 03 and 07 were framed by eye from these sources, so a rebuild is
    close to them rather than byte-identical."""
    frames, out = Path(sys.argv[1]), Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    if (frames / "full_sk_7655.5.png").exists():
        hero(frames / "full_sk_7655.5.png", out / "hero.jpg")
    for stem, f, i, t, s, focus, tag, kw in SECTIONS:
        if (frames / f).exists():
            im = banner(Image.open(frames / f).convert("RGB"), i, t, s, focus, tag, **kw)
            im.save(out / f"{stem}.jpg", quality=88, optimize=True, progressive=True)
    for stem, f, i, t, s, focus, tag, kw in CLIPS:
        if (frames / f).exists():
            section_anim(frames / f, out / f"{stem}.webp", i, t, s, focus, tag, **kw)
    print(out)


if __name__ == "__main__":
    main()
