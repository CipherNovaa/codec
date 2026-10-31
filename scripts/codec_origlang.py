#!/usr/bin/env python3
"""Cache each film's ORIGINAL language from TMDB.

Needed because "strip the audio tracks I don't speak" is a different rule from
"keep English". Measured 2026-09-09: of 86.9 GB of non-English audio in this
library, the three largest buckets are Japanese (22.8 GB), Indonesian (13.0 GB)
and Thai (1.4 GB) — Akira, Jin-Roh, The Raid and Ong Bak. Those are the ORIGINALS.
A pass that kept only English would have destroyed the soundtrack of exactly the
films worth owning.

codec.db's `language` column cannot answer this: it holds TMDB's spoken_languages
as DISPLAY NAMES ("English / Spanish"), and only 100 of 242 movies have one.
original_language is a single authoritative ISO code and it is one field on the
movie detail we already know how to fetch.

Written to a cache rather than a new codec.db column deliberately — the schema is
read by the running app, and this is only needed by the strip tool. If it ever
becomes load-bearing it belongs in codec_tmdb.py's save(), not here.

  codec_origlang.py            # fill anything missing
  codec_origlang.py --refresh  # re-fetch everything
"""
import json
import os
import sqlite3
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path
import codec_keys  # codec's own TMDB / fanart.tv keys, or the person's (scripts/codec_keys.py)
import codec_paths  # where codec's data lives (~/.local/share/codec)

DB = codec_paths.DB
CFG = Path.home() / ".config/codec/config.json"
CACHE = Path.home() / ".cache/codec/origlang.json"


def main():
    refresh = "--refresh" in sys.argv
    cfg = json.loads(CFG.read_text())
    key = codec_keys.tmdb_key(cfg.get("settings", {}))
    if not key:
        sys.exit("no TMDB key (codec carries none, config settings.tmdbApiKey)")
    movie_roots = [r["path"] for r in cfg["roots"] if r["kind"] == "movies"]

    cache = {}
    if CACHE.exists() and not refresh:
        try:
            cache = json.loads(CACHE.read_text())
        except ValueError:
            cache = {}

    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    want = {}
    for path, tid in con.execute(
            "SELECT path,tmdb_id FROM metadata WHERE tmdb_id IS NOT NULL AND tmdb_id!=''"):
        if "/" in tid:                       # composite id == an episode
            continue
        if not any(path.startswith(r + "/") for r in movie_roots):
            continue
        want[str(tid)] = path

    todo = [t for t in want if t not in cache]
    print(f"movies with a tmdb id: {len(want)}   cached: {len(want)-len(todo)}   to fetch: {len(todo)}")
    ok = fail = 0
    for i, tid in enumerate(todo, 1):
        url = f"https://api.themoviedb.org/3/movie/{tid}?api_key={key}"
        try:
            d = json.load(urllib.request.urlopen(url, timeout=20))
            cache[tid] = {"orig": (d.get("original_language") or "").lower(),
                          "title": d.get("title") or ""}
            ok += 1
            if i % 25 == 0 or i == len(todo):
                print(f"  [{i}/{len(todo)}] {cache[tid]['orig']:>3}  {cache[tid]['title'][:44]}")
        except Exception as e:
            fail += 1
            print(f"  FAIL {tid}: {e}", file=sys.stderr)
        time.sleep(0.05)

    CACHE.parent.mkdir(parents=True, exist_ok=True)
    tmp = CACHE.with_suffix(".tmp")
    tmp.write_text(json.dumps(cache, indent=1))
    os.replace(tmp, CACHE)                   # atomic — never a half-written cache
    print(f"\nfetched {ok}, failed {fail}; cache now holds {len(cache)} film(s) -> {CACHE}")

    import collections
    dist = collections.Counter(v["orig"] for v in cache.values())
    print("\noriginal languages in the library:")
    for lang, n in dist.most_common():
        print(f"  {lang or '??':>3}  {n}")
    print("\nnon-English originals (their native track must NEVER be stripped):")
    for tid, v in sorted(cache.items(), key=lambda kv: kv[1]["orig"]):
        if v["orig"] not in ("en", ""):
            print(f"  {v['orig']}  {v['title'][:56]}")


if __name__ == "__main__":
    main()
