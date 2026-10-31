#!/usr/bin/env python3
# Shade what the CRT's glass hides (measured 2026-10-13: L17 R20 T12 B6 of 1280x1024,
# Main.qml crtL..crtB) on the CRT shots -> out/safe-<name>.png
import sys, glob, os
from PIL import Image, ImageDraw
here = os.environ.get("CODEC_SHOTS_DIR") or os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "codec-shots")
for f in sys.argv[1:] or glob.glob(os.path.join(here, "out", "*-crt.png")):
    im = Image.open(f).convert("RGB"); d = ImageDraw.Draw(im)
    W, H = im.size
    d.rectangle([17, 12, W - 1 - 20, H - 1 - 6], outline=(255, 0, 255), width=1)
    # shade what the glass hides
    ov = Image.new("RGBA", im.size, (0, 0, 0, 0)); od = ImageDraw.Draw(ov)
    for box in ([0, 0, W, 12], [0, H - 6, W, H], [0, 0, 17, H], [W - 20, 0, W, H]):
        od.rectangle(box, fill=(255, 0, 255, 90))
    im = Image.alpha_composite(im.convert("RGBA"), ov).convert("RGB")
    im.save(os.path.join(os.path.dirname(f), "safe-" + os.path.basename(f)))
