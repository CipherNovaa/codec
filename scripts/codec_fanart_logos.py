#!/usr/bin/env python3
"""Fetch movie clearlogos from fanart.tv for codec titles missing one (the ~359
Kodi didn't cover). Uses the project key in ~/.config/codec/config.json, keyed by
tmdb_id, downloads into codec's own art cache, sets metadata.clearlogo.

Idempotent (only fills empty clearlogo). Movies only — fanart.tv's TV endpoint
needs a TheTVDB id we don't store. English logos preferred, HD preferred.
"""
import hashlib
import json
import os
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.request
import codec_keys  # codec's own TMDB / fanart.tv keys, or the person's (scripts/codec_keys.py)
import codec_paths  # where codec's data lives (~/.local/share/codec)

CFG = os.path.expanduser("~/.config/codec/config.json")


def trim_logo(path):
    """fanart.tv logos ship on a fixed 800x310 canvas with the artwork floated
    anywhere inside. Trim to the actual glyphs so codec can baseline-align every
    title consistently (see HomeView titleSlot). Idempotent; best-effort."""
    try:
        subprocess.run(
            ["mogrify", "-bordercolor", "none", "-border", "1",
             "-fuzz", "4%", "-trim", "+repage", path],
            stderr=subprocess.DEVNULL, timeout=15,
        )
    except Exception:
        pass


def has_alpha(path):
    """A clearlogo MUST be transparent art. One with NO alpha channel — or one
    whose alpha channel is entirely OPAQUE (RGBA white text on an opaque plate)
    — renders as a slab over the spotlight (the Mr. Robot white-box glitch), so
    we refuse it. identify %[channels] gives the channel string ('srgba' has
    alpha) and %[opaque] is 'True' when nothing in the image is transparent —
    presence of the channel alone is NOT enough. Fail-open on a probe error, but
    WARN: a missing/slow ImageMagick would otherwise silently accept every logo,
    turning the one white-box safeguard into a no-op library-wide."""
    try:
        out = subprocess.run(["identify", "-format", "%[channels]|%[opaque]", path],
                             capture_output=True, text=True, timeout=15).stdout.strip()
        chan, _, opaque = out.partition("|")
        if not chan.split()[0].lower().endswith("a"):
            return False
        return opaque.strip().lower() != "true"
    except Exception as e:
        print(f"  has_alpha: identify failed ({e}) — accepting logo UNCHECKED",
              file=sys.stderr)
        return True
DB = str(codec_paths.DB)
ART = os.path.expanduser("~/.cache/codec/art")
BASE = "https://webservice.fanart.tv/v3/movies/"
UA = {"User-Agent": "codec/1.0 (+https://github.com/codec)"}
# A movie is a video FILE (a show is a directory). Never use splitext — release
# dir names contain dots ("...EAC3 5.1 Silence") that fake an extension.
VID = (".mkv", ".mp4", ".avi", ".m4v", ".ts", ".mov", ".wmv", ".webm",
       ".mpg", ".mpeg", ".m2ts", ".iso")


def pick_logo(d):
    for key in ("hdmovielogo", "movielogo"):
        arr = d.get(key) or []
        en = [a for a in arr if a.get("lang") == "en" and a.get("url")]
        if en:
            return en[0]["url"]
        any_url = [a for a in arr if a.get("url")]
        if any_url:
            return any_url[0]["url"]
    return None


# fanart.tv is community-sourced: plenty of titles simply have no logo. Without a
# marker we'd re-query every one of them on every reconcile (~0.3s each = tens of
# seconds wasted forever). Stamp clearlogo_url with this sentinel when there's
# nothing to fetch, and skip it next time. clearlogo stays empty (so DetailView
# still falls back to the text title). `--force` clears the marks to retry.
NONE_SENTINEL = "__none__"


def main():
    force = "--force" in sys.argv[1:]
    if not os.path.exists(CFG):
        sys.exit("no config: " + CFG)
    s = codec_keys.settings()
    if not codec_keys.fanart_enabled(s):
        print("fanart.tv artwork is off (settings.fanartArt)")
        return
    key = codec_keys.fanart_query(s)
    if not key:
        sys.exit("no fanart.tv key (codec carries none, config settings.fanartApiKey)")
    os.makedirs(ART, exist_ok=True)
    db = sqlite3.connect(DB, timeout=30)

    def mark_none(p):
        db.execute("UPDATE metadata SET clearlogo_url=? WHERE path=?",
                   (NONE_SENTINEL, p))
        db.commit()

    if force:
        db.execute("UPDATE metadata SET clearlogo_url='' WHERE clearlogo_url=?",
                   (NONE_SENTINEL,))
        db.commit()
    rows = [
        (p, t)
        for p, t in db.execute(
            "SELECT path, tmdb_id FROM metadata WHERE tmdb_id IS NOT NULL"
            " AND tmdb_id!='' AND (clearlogo IS NULL OR clearlogo='')"
            " AND COALESCE(clearlogo_url,'')!=?", (NONE_SENTINEL,)
        )
        if "/" not in (t or "") and p.lower().endswith(VID)  # movies only
    ]
    print("fanart logo fetch: %d movies" % len(rows))
    ok = none = fails = 0
    for path, tid in rows:
        try:
            req = urllib.request.Request("%s%s?%s" % (BASE, tid, key), headers=UA)
            with urllib.request.urlopen(req, timeout=15) as r:
                d = json.load(r)
            logo = pick_logo(d)
            if not logo:
                none += 1
                mark_none(path)
                time.sleep(0.25)
                continue
            dst = os.path.join(ART, hashlib.sha1(logo.encode()).hexdigest() + ".png")
            if not os.path.exists(dst):
                with urllib.request.urlopen(
                    urllib.request.Request(logo, headers=UA), timeout=30
                ) as lr:
                    data = lr.read()
                with open(dst, "wb") as f:
                    f.write(data)
                trim_logo(dst)
            if not has_alpha(dst):
                try:
                    os.remove(dst)
                except OSError:
                    pass
                none += 1
                mark_none(path)
                time.sleep(0.3)
                continue
            db.execute(
                "UPDATE metadata SET clearlogo=?, clearlogo_url=? WHERE path=?",
                (dst, logo, path),
            )
            db.commit()
            ok += 1
            if ok % 20 == 0:
                print("  %d ok / %d" % (ok, len(rows)))
        except urllib.error.HTTPError as e:
            if e.code == 404:
                none += 1
                mark_none(path)
            elif e.code == 429:
                print("  rate limited; sleeping 5s", file=sys.stderr)
                time.sleep(5)
            else:
                fails += 1
                print("  HTTP %s: %s" % (e.code, path), file=sys.stderr)
        except Exception as e:
            fails += 1
            print("  FAIL %s: %s" % (path, e), file=sys.stderr)
        time.sleep(0.3)
    print("fanart logos: %d fetched, %d none-available, %d failed" % (ok, none, fails))


if __name__ == "__main__":
    main()
