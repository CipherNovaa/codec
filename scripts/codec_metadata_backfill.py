#!/usr/bin/env python3
"""Backfill richer TMDB metadata onto existing codec rows: revenue, budget,
studio, country, language, writer — the fields the full detail screen was
missing (Kodi shows them; codec didn't store them).

Reuses the TMDB key from ~/.config/codec/config.json and the same detail request
codec_tmdb.py already makes, so credits ride along for the writer at no extra
call. Targeted UPDATE only — never touches columns codec_tmdb.py owns. Idempotent:
fills rows whose `studio` is still NULL — never attempted. A title TMDB lists no
studio for is written as '' and so asked about once, not on every run. Kind
(movie vs tv) is inferred from the path exactly as codec_tmdb.py's credits
backfill does (show rows are dirs).

Runs from codec_reconcile.sh (F5 / a new import) and the nightly refresh: a
scrape only fills the columns codec_tmdb.py owns, so before it was wired in, every
title imported (or MOVED — a shuffle to another drive is a new row) after the
one-off backfill had no budget/revenue/studio on its detail page (2026-10-07:
63 of 387 rows had them).
"""
import json
import os
import sqlite3
import sys
import time
import urllib.parse
import urllib.request
import codec_keys  # codec's own TMDB / fanart.tv keys, or the person's (scripts/codec_keys.py)
import codec_paths  # where codec's data lives (~/.local/share/codec)

CFG = os.path.expanduser("~/.config/codec/config.json")
DB = str(codec_paths.DB)
API = "https://api.themoviedb.org/3"
# A show is a DIRECTORY; a movie is a video FILE. Never use splitext — release
# dir names contain dots ("...EAC3 5.1 Silence") that fool it into a fake ext.
VID = (".mkv", ".mp4", ".avi", ".m4v", ".ts", ".mov", ".wmv", ".webm",
       ".mpg", ".mpeg", ".m2ts", ".iso", ".flv")  # #5: .flv was missing -> a .flv
# movie was inferred as TV (kind = movie if ...endswith(VID) else tv) and scraped
# against /tv, silently losing revenue/budget/studio/etc on its detail page.


def get(path, key, **params):
    params["api_key"] = key
    q = "&".join("%s=%s" % (k, urllib.parse.quote(str(v))) for k, v in params.items())
    with urllib.request.urlopen("%s%s?%s" % (API, path, q), timeout=15) as r:
        return json.load(r)


def meta_fields(d, kind):
    pc = d.get("production_companies") or []
    nets = d.get("networks") or []
    studio = (nets[0].get("name") if kind == "tv" and nets
              else (pc[0].get("name") if pc else "")) or ""
    countries = [c.get("name", "") for c in (d.get("production_countries") or [])]
    if not countries:
        countries = d.get("origin_country") or []
    langs = [l.get("english_name", "") for l in (d.get("spoken_languages") or [])]
    ws, seen = [], set()
    for c in (d.get("credits") or {}).get("crew") or []:
        if (c.get("job") in ("Writer", "Screenplay", "Story")
                and c.get("name") and c["name"] not in seen):
            seen.add(c["name"])
            ws.append(c["name"])
    return {
        "revenue": int(d.get("revenue") or 0),
        "budget": int(d.get("budget") or 0),
        "studio": studio,
        "country": " / ".join(c for c in countries if c),
        "language": " / ".join(l for l in langs if l),
        "writer": ", ".join(ws[:2]),
    }


def main():
    if not os.path.exists(CFG):
        sys.exit("no config: " + CFG)
    key = codec_keys.tmdb_key()
    if not key:
        sys.exit("no TMDB key (codec carries none, config settings.tmdbApiKey)")
    db = sqlite3.connect(DB, timeout=30)
    rows = [
        (p, t)
        for p, t in db.execute(
            "SELECT path, tmdb_id FROM metadata"
            " WHERE tmdb_id IS NOT NULL AND tmdb_id != ''"
            "   AND studio IS NULL"
        )
        if "/" not in (t or "")  # skip episodes (id is show/season/ep)
    ]
    print("meta backfill: %d rows" % len(rows))
    ok = fails = 0
    for path, tid in rows:
        kind = "movie" if path.lower().endswith(VID) else "tv"
        try:
            d = get("/%s/%s" % (kind, tid), key, append_to_response="credits")
            f = meta_fields(d, kind)
            db.execute(
                "UPDATE metadata SET revenue=?, budget=?, studio=?, country=?,"
                " language=?, writer=? WHERE path=?",
                (f["revenue"], f["budget"], f["studio"], f["country"],
                 f["language"], f["writer"], path),
            )
            db.commit()
            ok += 1
            if ok % 25 == 0:
                print("  %d/%d" % (ok, len(rows)))
        except Exception as e:
            fails += 1
            print("  FAIL %s: %s" % (path, e), file=sys.stderr)
        time.sleep(0.2)
    print("meta backfill done: %d filled, %d failed" % (ok, fails))


if __name__ == "__main__":
    main()
