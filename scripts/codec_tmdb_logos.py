#!/usr/bin/env python3
"""Fetch clearlogos from TMDB for codec titles still missing one — mainly TV
shows. Some shows were imported WITHOUT a tmdb_id, so this resolves one by title
search first (and stores it, which also unlocks the metadata backfill for them),
then pulls the logo from /{kind}/{id}/images — TMDB indexes logos for movies AND
shows by tmdb_id, no TheTVDB id needed. English logos preferred.
"""
import hashlib
import json
import os
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import codec_keys  # codec's own TMDB / fanart.tv keys, or the person's (scripts/codec_keys.py)
import codec_paths  # where codec's data lives (~/.local/share/codec)


def trim_logo(path):
    """Trim the logo canvas to its glyphs so codec baseline-aligns titles
    consistently. Idempotent; best-effort."""
    try:
        subprocess.run(
            ["mogrify", "-bordercolor", "none", "-border", "1",
             "-fuzz", "4%", "-trim", "+repage", path],
            stderr=subprocess.DEVNULL, timeout=15,
        )
    except Exception:
        pass


def has_alpha(path):
    """A clearlogo MUST be transparent art — one with NO alpha channel, or one
    whose alpha is entirely OPAQUE (RGBA text on an opaque plate), renders as a
    slab over the spotlight. Refuse both: %[channels] must end in 'a' AND
    %[opaque] must not be 'True' (channel presence alone is not transparency).
    Fail-open on error, but WARN — a broken identify else silently accepts every
    logo and the white-box gate becomes a no-op."""
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

CFG = os.path.expanduser("~/.config/codec/config.json")
DB = str(codec_paths.DB)
ART = os.path.expanduser("~/.cache/codec/art")
IMG = "https://image.tmdb.org/t/p/original"
API = "https://api.themoviedb.org/3"
# A show is a DIRECTORY; a movie is a video FILE. Never splitext — release dir
# names contain dots ("...EAC3 5.1 Silence") that fake an extension.
VID = (".mkv", ".mp4", ".avi", ".m4v", ".ts", ".mov", ".wmv", ".webm",
       ".mpg", ".mpeg", ".m2ts", ".iso")


def get(path, key, **params):
    params["api_key"] = key
    qs = "&".join("%s=%s" % (k, urllib.parse.quote(str(v))) for k, v in params.items())
    url = "%s%s?%s" % (API, path, qs)
    # Two API calls per title (search + images) over a large logo-less set trips
    # TMDB's rate window fast. Retry a 429 with backoff (honouring Retry-After)
    # instead of letting it bubble up as a hard fail — otherwise the first
    # rate-limit poisons the rest of the run and fetches almost nothing.
    for attempt in range(5):
        try:
            with urllib.request.urlopen(url, timeout=15) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code == 429 and attempt < 4:
                try:
                    wait = int(e.headers.get("Retry-After") or 0)
                except (TypeError, ValueError):
                    wait = 0
                wait = min(max(wait, 2 ** attempt), 30)
                print("  rate limited; sleeping %ss" % wait, file=sys.stderr)
                time.sleep(wait)
                continue
            raise


def pick(logos):
    # Skip .svg: TMDB's logos endpoint can return SVG file_paths, but we always
    # store as <sha1>.png — an SVG saved under a .png name is a broken image.
    def ok(l):
        fp = l.get("file_path") or ""
        return fp and not fp.lower().endswith(".svg")
    en = [l for l in logos if l.get("iso_639_1") == "en" and ok(l)]
    if en:
        return en[0]["file_path"]
    any_fp = [l for l in logos if ok(l)]
    return any_fp[0]["file_path"] if any_fp else None


def main():
    key = codec_keys.tmdb_key()
    if not key:
        sys.exit("no TMDB key (codec carries none, config settings.tmdbApiKey)")
    os.makedirs(ART, exist_ok=True)
    db = sqlite3.connect(DB, timeout=30)
    rows = [
        (p, t, title, yr)
        for p, t, title, yr in db.execute(
            "SELECT path, tmdb_id, title, year FROM metadata"
            " WHERE (clearlogo IS NULL OR clearlogo='')"
        )
        if "/" not in (t or "")  # movies + shows, never episodes
    ]
    print("tmdb logo fetch: %d titles" % len(rows))
    ok = none = fails = resolved = 0
    for path, tid, title, yr in rows:
        kind = "movie" if path.lower().endswith(VID) else "tv"
        try:
            if not tid:
                if not title:
                    none += 1
                    continue
                res = get("/search/%s" % kind, key, query=title)
                hits = res.get("results") or []
                if not hits:
                    none += 1
                    time.sleep(0.25)
                    continue
                # Disambiguate by year: a generic or remade title returns
                # several hits, and hits[0] is not always the right one — the
                # chosen id is persisted as tmdb_id, so a wrong pick poisons the
                # logo (and everything else keyed on tmdb_id) permanently.
                # Prefer the hit whose release year matches; else the first.
                want = str(yr)[:4] if yr else ""
                chosen = next(
                    (h for h in hits if want and
                     (h.get("release_date") or h.get("first_air_date") or "")[:4] == want),
                    hits[0])
                tid = str(chosen["id"])
                db.execute("UPDATE metadata SET tmdb_id=? WHERE path=?", (tid, path))
                db.commit()
                resolved += 1
            d = get("/%s/%s/images" % (kind, tid), key)
            fp = pick(d.get("logos") or [])
            if not fp:
                none += 1
                time.sleep(0.2)
                continue
            url = IMG + fp
            dst = os.path.join(ART, hashlib.sha1(url.encode()).hexdigest() + ".png")
            if not os.path.exists(dst):
                # Don't advertise webp -> the CDN (Cloudflare Polish) serves
                # the original PNG, not a webp a plugin-less satellite can't
                # decode. Logos keep their alpha, so we never transcode here.
                req = urllib.request.Request(
                    url, headers={"Accept": "image/png,image/*;q=0.8",
                                  "User-Agent": "codec-tmdb-logos"})
                with urllib.request.urlopen(req, timeout=30) as lr:
                    data = lr.read()
                # Atomic: an interrupted/truncated fetch must not leave a broken
                # PNG cached under the final name forever (it is never re-fetched
                # once the file exists).
                tmp_png = dst + ".part"
                with open(tmp_png, "wb") as f:
                    f.write(data)
                os.replace(tmp_png, dst)
                trim_logo(dst)
            if not has_alpha(dst):
                try:
                    os.remove(dst)
                except OSError:
                    pass
                none += 1
                time.sleep(0.2)
                continue
            db.execute(
                "UPDATE metadata SET clearlogo=?, clearlogo_url=? WHERE path=?",
                (dst, url, path),
            )
            db.commit()
            ok += 1
        except urllib.error.HTTPError as e:
            if e.code == 404:
                none += 1
            elif e.code == 429:
                # get() already retried the API calls; a 429 still reaching here
                # is the image CDN rate-limiting the download. Back off so we
                # don't keep hammering it, and don't count it as a hard fail.
                print("  rate limited (image cdn); sleeping 5s", file=sys.stderr)
                time.sleep(5)
            else:
                fails += 1
                print("  HTTP %s: %s" % (e.code, path), file=sys.stderr)
        except Exception as e:
            fails += 1
            print("  FAIL %s: %s" % (path, e), file=sys.stderr)
        time.sleep(0.25)
    print(
        "tmdb logos: %d fetched, %d resolved-id, %d none, %d failed"
        % (ok, resolved, none, fails)
    )


if __name__ == "__main__":
    main()
