#!/usr/bin/env python3
"""Bootstrap codec clearlogos from Kodi's cached fanart.tv artwork.

Kodi (Arctic Fuse) already downloaded clearlogos for ~355 movies. This maps
codec's tmdb_id -> Kodi uniqueid(tmdb) -> Kodi art(clearlogo) url -> Kodi's
Thumbnails cache file, copies the PNG into codec's own art cache, and sets
metadata.clearlogo. Idempotent: only fills rows that don't already have one.

Native fanart.tv fetching (in codec-serve) covers titles Kodi lacks and future
imports; this gives an instant, offline, library-wide bootstrap with no
re-download. Kodi's own file->movie mapping is dirty, so we join on tmdb_id
(which both sides store reliably), never on file path.
"""
import glob
import hashlib
import os
import shutil
import sqlite3
import sys
import codec_paths  # where codec's data lives (~/.local/share/codec)

HOME = os.path.expanduser("~")
KODI_DB_DIR = os.path.join(HOME, ".kodi/userdata/Database")
THUMBS = os.path.join(HOME, ".kodi/userdata/Thumbnails")
CODEC_DB = str(codec_paths.DB)
ART_DIR = os.path.join(HOME, ".cache/codec/art")
# A movie is a video FILE, a show a directory. Never use splitext — release dir
# names contain dots ("...EAC3 5.1 Silence") that fake an extension.
VID = (".mkv", ".mp4", ".avi", ".m4v", ".ts", ".mov", ".wmv", ".webm",
       ".mpg", ".mpeg", ".m2ts", ".iso")


def latest(pattern):
    files = sorted(glob.glob(os.path.join(KODI_DB_DIR, pattern)))
    return files[-1] if files else None


def main():
    vdb, tdb = latest("MyVideos*.db"), latest("Textures*.db")
    if not vdb or not tdb:
        print("Kodi DBs not found under", KODI_DB_DIR, file=sys.stderr)
        return 1
    if not os.path.exists(CODEC_DB):
        print("codec DB not found:", CODEC_DB, file=sys.stderr)
        return 1
    os.makedirs(ART_DIR, exist_ok=True)

    # (kind, tmdb_id) -> clearlogo url. Movie and TV tmdb ids are SEPARATE
    # namespaces, so keep them apart or a movie logo lands on a show that happens
    # to share the numeric id.
    kv = sqlite3.connect("file:%s?mode=ro" % vdb, uri=True)
    maps = {"movie": {}, "tvshow": {}}
    for mt in ("movie", "tvshow"):
        for tmdb, url in kv.execute(
            "SELECT u.value, a.url FROM art a "
            "JOIN uniqueid u ON u.media_id=a.media_id AND u.media_type=? "
            "  AND u.type='tmdb' "
            "WHERE a.media_type=? AND a.type='clearlogo' AND a.url<>''",
            (mt, mt),
        ):
            if tmdb and url:
                maps[mt].setdefault(str(tmdb).strip(), url)
    kv.close()

    kt = sqlite3.connect("file:%s?mode=ro" % tdb, uri=True)

    def cached(url):
        row = kt.execute(
            "SELECT cachedurl FROM texture WHERE url=?", (url,)
        ).fetchone()
        if not row:
            return None
        p = os.path.join(THUMBS, row[0])
        return p if os.path.exists(p) else None

    cc = sqlite3.connect(CODEC_DB)
    todo = cc.execute(
        "SELECT path, tmdb_id FROM metadata "
        "WHERE tmdb_id IS NOT NULL AND tmdb_id<>'' "
        "AND (clearlogo IS NULL OR clearlogo='')"
    ).fetchall()

    n_ok = n_uncached = n_nourl = 0
    for path, tmdb in todo:
        kind = "movie" if path.lower().endswith(VID) else "tvshow"
        url = maps[kind].get(str(tmdb).strip())
        if not url:
            n_nourl += 1
            continue
        src = cached(url)
        if not src:
            n_uncached += 1
            continue
        ext = os.path.splitext(src)[1] or ".png"
        dst = os.path.join(ART_DIR, hashlib.sha1(url.encode()).hexdigest() + ext)
        try:
            if not os.path.exists(dst):
                shutil.copyfile(src, dst)
        except OSError as e:
            print("copy failed:", e, file=sys.stderr)
            continue
        cc.execute(
            "UPDATE metadata SET clearlogo=?, clearlogo_url=? WHERE path=?",
            (dst, url, path),
        )
        n_ok += 1
    cc.commit()
    kt.close()
    cc.close()
    print(
        "clearlogo bootstrap: set %d  |  matched-but-uncached %d  |  "
        "no-kodi-logo %d  |  candidates %d" % (n_ok, n_uncached, n_nourl, len(todo))
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
