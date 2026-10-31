#!/usr/bin/env python3
"""Build the globe textures from real NASA imagery.

Sources (public domain, in assets/globe3d/src/), best-available first:
  day_{A1..D2}.jpg    — BMNG August 500m TILES, 8 x 21600x21600
                        (assembled: the full 86400x43200 mosaic)
  bmng_aug_21k.png    — BMNG August w/ topo+bathy, 21600x10800 (fallback)
  bmng_day_aug.jpg    — BMNG August w/ topo+bathy, 5400x2700   (fallback)
  bmng_day.jpg        — BMNG December w/ topo+bathy, 5400x2700 (fallback)
  night_{A1..D2}.jpg  — Black Marble 2016 500m TILES, 8 x 21600x21600
  blackmarble_2016.jpg — Black Marble 2016 composite, 13500x6750 (fallback)
  dnb_night.jpg       — VIIRS DNB composite 2012, 3600x1800     (fallback)

Outputs (default 4096x2048 — see the W comment below for why; any
width via argv, the sources are pristine up to 16384):
  albedo.png — graded day face (lossless: JPEG chroma subsampling muds
               coastlines at icon scale)
  lights.png — city lights colorized to the approved ember LUT

FRAME: the QML calibration (subsolar texLon = realLon + 140, marker
azimuth α = texλ − 181.3) expects texture column 0 at real longitude
-140°. NASA equirects put column 0 at -180°, so both images are rolled
left by 40° of longitude. Every existing formula keeps working.

The DNB source includes moonlit ice and faint land glow; city light is
isolated by a luminance threshold plus a warmth gate (cities are warm,
ice is neutral-blue) before the ember LUT is applied.

Also prints STARS= / HOME= — real-city marker coordinates for the QML
Repeater3D (r = 50.6).
"""
import numpy as np, math, os, sys
from PIL import Image, ImageEnhance, ImageFilter

Image.MAX_IMAGE_PIXELS = None   # 466MP tiles trip the default guard
SRC = os.path.join(os.path.dirname(__file__), "..", "assets", "globe3d", "src")
OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "globe3d")
# Output width, overridable: ./make_globe_real.py 16384
# 4096 is the shipping default: a clean mip chain at icon scale with a
# 64MB decode that the deferred planetLoader keeps OFF the launch path.
# Bigger is invisible at today's display sizes (the icon samples a
# ~256px mip); the 500m sources make ANY size a pristine downsample,
# so bake 8192/16384 if a large globe view ever ships (main.cpp raises
# the QImageReader ceiling for 16384 already).
W = int(sys.argv[1]) if len(sys.argv) > 1 else 4096
H = W // 2
SHIFT = W * 40 // 360   # 40° of longitude, left

def best(*names):
    for n in names:
        p = os.path.join(SRC, n)
        if os.path.exists(p):
            return p
    raise SystemExit("no source found: " + "/".join(names))

def mosaic(prefix):
    """Assemble the 8-tile 500m grid (A1..D1 top, A2..D2 bottom) into a
    W x H canvas, one 466-megapixel tile in memory at a time."""
    names = [f"{prefix}{c}{r}.jpg" for r in "12" for c in "ABCD"]
    if not all(os.path.exists(os.path.join(SRC, n)) for n in names):
        return None
    tw, th = W // 4, H // 2
    out = Image.new("RGB", (W, H))
    for i, n in enumerate(names):
        tile = Image.open(os.path.join(SRC, n)).convert("RGB")
        out.paste(tile.resize((tw, th), Image.LANCZOS),
                  ((i % 4) * tw, (i // 4) * th))
        del tile
        print("  tile", n, "in")
    return out

# ── day face ────────────────────────────────────────────────────────
day = mosaic("day_")
if day is None:
    day = Image.open(best("bmng_aug_21k.png", "bmng_day_aug.jpg",
                          "bmng_day.jpg")).convert("RGB").resize((W, H), Image.LANCZOS)
day = ImageEnhance.Color(day).enhance(0.96)        # a touch under natural
day = ImageEnhance.Brightness(day).enhance(0.95)   # sit into the dark UI
day = ImageEnhance.Contrast(day).enhance(1.06)     # macro-contrast reads
                                                   # even at icon-mip scale
A = np.asarray(day)
A = np.roll(A, -SHIFT, axis=1)
# PNG on purpose: JPEG's default 4:2:0 chroma subsampling stores color
# at half resolution — visible mud on coastlines at icon scale
Image.fromarray(A, "RGB").save(os.path.join(OUT, "albedo.png"))

# ── night lights ────────────────────────────────────────────────────
ngt = mosaic("night_")
if ngt is None:
    ngt = Image.open(best("blackmarble_2016.jpg", "dnb_night.jpg")) \
        .convert("RGB").resize((W, H), Image.LANCZOS)
N = np.asarray(ngt, dtype=np.float32) / 255.0
del ngt
N = np.roll(N, -SHIFT, axis=1)
L = N.max(axis=2)
warm = np.clip((N[..., 0] - N[..., 2]) * 6.0 + 0.25, 0, 1)  # ice is blue-neutral
del N
v = np.clip((L - 0.16) / 0.84, 0, 1) * warm
v = v ** 0.55          # lift the mids: fine VIIRS grain must survive
                       # mipmap averaging down to icon scale
# dots + heat, from real data: pool TWO blurred copies of the grain
# back under itself — a tight one (metro cores) and a wide one (the
# regional halo) — so night cities read as living ember GLOW at icon
# scale while the individual-dot crispness stays on top
bloom = np.asarray(Image.fromarray(np.uint8(v * 255)).filter(
    ImageFilter.GaussianBlur(W / 820)), dtype=np.float32) / 255.0
halo = np.asarray(Image.fromarray(np.uint8(v * 255)).filter(
    ImageFilter.GaussianBlur(W / 160)), dtype=np.float32) / 255.0
# the molten HEAT bed is capped below full brightness so the crisp
# grain always reads ON TOP of it — glow without mud
heat = np.clip(bloom * 3.0 + halo * 1.8, 0, 0.80)
v = np.clip(v * 1.15 + heat, 0, 1)
r = 255 * np.clip(v * 1.18, 0, 1)
g = 225 * v ** 1.22
b = 160 * v ** 2.00
Image.fromarray(np.dstack([r, g, b]).astype(np.uint8), "RGB").save(
    os.path.join(OUT, "lights.png"))
print("baked albedo.png + lights.png", (W, H))

# ── markers: real cities in the model frame ─────────────────────────
CITIES = [("nyc", 40.71, -74.01), ("la", 34.05, -118.24), ("chi", 41.88, -87.63),
          ("mex", 19.43, -99.13), ("sao", -23.55, -46.63), ("bue", -34.60, -58.38),
          ("lon", 51.51, -0.13), ("par", 48.86, 2.35), ("cai", 30.04, 31.24),
          ("mos", 55.76, 37.62), ("del", 28.61, 77.21), ("sha", 31.23, 121.47),
          ("tok", 35.68, 139.69), ("syd", -33.87, 151.21)]
def pos(lat, lon, r0=50.6):
    # marker azimuth in the TEXTURE's rotation frame: α = texλ − 181.3
    # (matches the empirical front-face law λ_front = 64.3 + 360·turn;
    # coincides with the old eyeball calibration at the rest pose)
    a = math.radians((lon + 140) - 181.3)
    phi = math.radians(lat)
    return (round(r0 * math.cos(phi) * math.sin(a), 1),
            round(r0 * math.sin(phi), 1),
            round(r0 * math.cos(phi) * math.cos(a), 1))
print("STARS=" + ",".join("[%s,%s,%s]" % pos(la, lo) for _, la, lo in CITIES))
print("HOME=", pos(45.5, -122.7))
