#!/usr/bin/env python3
"""Write codec's Cast receiver as ONE static page, for a permanent public home.

A TV that runs codec's receiver loads it from the https address its Cast App
ID is registered to. Until now that was the author's own hub (its Funnel), so every
TV showing codec's face depended on the author's desktop being on — and wouldn't
work for anyone else's hub. The page needs nothing from where it's served:
every request it makes goes to addresses the cast hands it (the film's
stream, the party's state, the remote's command address), and its fonts,
plates, badges and hls.js are all inside it. So it can live anywhere static
(codec's own site on GitHub Pages).

This builds the page from the SAME code codec-serve uses (so the two never
drift), with codec's own steel palette instead of one desktop's wallpaper and
the default caption style (a cast sends its own per LOAD anyway), and none of
this machine's settings — it runs with an empty home folder.

    scripts/codec_receiver_export.py [out.html]    (default build/cast-receiver/index.html)

Then: host it at a public https address, register that address in the Google
Cast developer console (a Custom Receiver), and put the App ID and address in
scripts/codec_keys.py (CODEC_CAST_APP, CODEC_RECEIVER_URL).
"""
import hashlib
import os
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent


def main():
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE.parent / "build/cast-receiver/index.html"
    with tempfile.TemporaryDirectory() as home:
        os.environ["HOME"] = home              # none of this machine's settings
        sys.path.insert(0, str(HERE))
        import codec_serve as cs
        cs._party_accent = lambda: ("#a6b1c7", "#0d1119")   # codec's fixed steel palette
        page = cs._party_receiver()
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(page)
    print(f"wrote {out} — {len(page) // 1024} KB, sha256 {hashlib.sha256(page).hexdigest()[:16]}")


if __name__ == "__main__":
    main()
