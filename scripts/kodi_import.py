#!/usr/bin/env python3
"""Seed Codec's metadata from an existing Kodi library (one-time import).

Reads Kodi's MyVideos DB and writes into Codec's codec.db:
  - `metadata` rows keyed by the *on-disk* file path (title, year, plot,
    rating, runtime, genres, ids, poster/fanart URLs + locally cached art)
  - watched/resume state merged into `media_state` (never clobbers state
    Codec has already written for a file)

Kodi DBs rot: this library holds duplicate movie rows from old rescans whose
idFile points at the wrong file. So the importer trusts only what can be
verified: a Kodi file row counts only if its path exists on disk, and
title+year matching is used to associate metadata with Codec's library.

Stdlib only — Hermes-runnable. Network is used only to cache artwork
(--no-art skips it; the player itself never touches the network).
"""

import argparse
import difflib
import hashlib
import json
import re
import sqlite3
import sys
import unicodedata
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path
from urllib.request import Request, urlopen
import codec_paths  # where codec's data lives (~/.local/share/codec)

KODI_DB = Path.home() / ".kodi/userdata/Database/MyVideos131.db"
CODEC_DB = codec_paths.DB
ART_DIR = Path.home() / ".cache/codec/art"

VIDEO_EXTS = {".mkv", ".mp4", ".avi", ".m2ts", ".ts", ".mov", ".wmv",
              ".flv", ".webm", ".mpg", ".mpeg", ".iso"}


def norm_title(s: str) -> str:
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode()
    s = s.lower()
    s = re.sub(r"\bvol(ume)?\b\.?", "vol", s)      # Vol. / Volume -> vol
    s = re.sub(r"\bpart\b\.?", "part", s)
    s = re.sub(r"[^a-z0-9]+", " ", s)
    return " ".join(s.split())


def year_of(premiered: str) -> int:
    m = re.match(r"(\d{4})", premiered or "")
    return int(m.group(1)) if m else 0


# --- Codec-side scene-name parsing (mirror of library.cpp, kept simple) ----
YEAR_RE = re.compile(r"\b(19[3-9]\d|20[0-4]\d)\b")
TOKEN_RE = re.compile(
    r"\b(2160p|1080p|720p|480p|UHD|BluRay|Blu-Ray|BDRip|WEB-?DL|WEBRip|WEB|HDTV|"
    r"REMUX|x26[45]|H ?26[45]|HEVC|AVC|DTS|DDP?|AAC|AC3|TrueHD|Atmos|10bit|8bit|"
    r"HDR10?|DV|YTS|YIFY|RARBG)\b", re.I)


def parse_scene(raw: str):
    s = re.sub(r"[\[\]()]", " ", raw.replace(".", " ").replace("_", " "))
    year, cut = 0, -1
    for m in YEAR_RE.finditer(s):
        year, cut = int(m.group(1)), m.start(1)
    if cut <= 0:
        t = TOKEN_RE.search(s)
        cut = t.start() if t else -1
    title = (s[:cut] if cut > 0 else s).strip(" -–—")
    return " ".join(title.split()), year


def scan_codec_library(roots):
    """(norm_title, year) -> primary video path, mirroring the app's scanner."""
    out = {}
    for root in roots:
        rp = Path(root["path"])
        if root.get("kind") == "tv" or not rp.is_dir():
            continue
        for entry in sorted(rp.iterdir()):
            if entry.name in ("$RECYCLE.BIN", "System Volume Information", "Config.Msi"):
                continue
            if entry.is_dir():
                best, size = None, -1
                for f in entry.rglob("*"):
                    if f.suffix.lower() in VIDEO_EXTS and "sample" not in f.name.lower():
                        st = f.stat().st_size
                        if st > size:
                            best, size = f, st
                raw = entry.name
            elif entry.suffix.lower() in VIDEO_EXTS:
                best, raw = entry, entry.stem
            else:
                continue
            if best is None:
                continue
            title, year = parse_scene(raw)
            out[(norm_title(title), year)] = str(best)
    return out


def fetch(url: str, dest: Path) -> bool:
    try:
        req = Request(url, headers={"User-Agent": "codec-kodi-import/1.0"})
        with urlopen(req, timeout=30) as r, open(dest, "wb") as f:
            f.write(r.read())
        return True
    except Exception as e:
        print(f"  art fail: {url[:60]}… ({e})", file=sys.stderr)
        return False


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--kodi-db", default=str(KODI_DB))
    ap.add_argument("--codec-db", default=str(CODEC_DB))
    ap.add_argument("--no-art", action="store_true", help="skip artwork download")
    ap.add_argument("--fanart", action="store_true", help="also cache fanart (bigger)")
    args = ap.parse_args()

    kodi = sqlite3.connect(f"file:{args.kodi_db}?mode=ro", uri=True)
    kodi.row_factory = sqlite3.Row

    codec = sqlite3.connect(args.codec_db)
    codec.execute("""CREATE TABLE IF NOT EXISTS metadata (
        path TEXT PRIMARY KEY, title TEXT, year INTEGER, plot TEXT,
        rating REAL, votes INTEGER, runtime_min INTEGER, genres TEXT,
        premiered TEXT, imdb_id TEXT, tmdb_id TEXT,
        poster TEXT, fanart TEXT, poster_url TEXT, fanart_url TEXT,
        source TEXT, updated TEXT)""")
    codec.execute("""CREATE TABLE IF NOT EXISTS media_state (
        path TEXT PRIMARY KEY, position REAL DEFAULT 0, duration REAL DEFAULT 0,
        aid INTEGER DEFAULT -1, sid INTEGER DEFAULT -1, speed REAL DEFAULT 1.0,
        zoom_mode INTEGER DEFAULT -1, watch_count INTEGER DEFAULT 0,
        completed INTEGER DEFAULT 0, last_played TEXT, last_mode TEXT DEFAULT '')""")

    cfg = Path.home() / ".config/codec/config.json"
    roots = json.loads(cfg.read_text())["roots"] if cfg.exists() else []
    lib = scan_codec_library(roots)
    lib_by_title = {}
    for (nt, yr), path in lib.items():
        lib_by_title.setdefault(nt, []).append((yr, path))

    # ---- movies ----
    movies = kodi.execute("""
        SELECT m.idMovie, m.idFile, m.c00 AS title, m.c01 AS plot,
               m.c11 AS runtime_s, m.c14 AS genres, m.premiered,
               p.strPath || f.strFilename AS kodi_path,
               f.playCount, f.lastPlayed
        FROM movie m
        JOIN files f ON m.idFile = f.idFile
        JOIN path  p ON f.idPath = p.idPath""").fetchall()

    ratings = {(r["media_id"]): (r["rating"], r["votes"]) for r in kodi.execute(
        "SELECT media_id, rating, votes FROM rating WHERE media_type='movie'")}
    uids = {}
    for r in kodi.execute("SELECT media_id, value, type FROM uniqueid WHERE media_type='movie'"):
        uids.setdefault(r["media_id"], {})[r["type"]] = r["value"]
    art = {}
    for r in kodi.execute("SELECT media_id, type, url FROM art WHERE media_type='movie'"):
        art.setdefault(r["media_id"], {})[r["type"]] = r["url"]
    bookmarks = {r["idFile"]: r["timeInSeconds"] for r in kodi.execute(
        "SELECT idFile, timeInSeconds FROM bookmark WHERE type=1")}

    now = datetime.now(timezone.utc).isoformat(timespec="seconds")
    matched, unmatched, watched_n, resume_n = 0, [], 0, 0
    downloads = []

    # Group duplicate movie rows by (title, year); prefer the row whose file
    # really exists on disk (dup rows from old rescans point at wrong files).
    groups = {}
    for row in movies:
        key = (norm_title(row["title"]), year_of(row["premiered"]))
        groups.setdefault(key, []).append(row)

    for (nt, yr), rows in groups.items():
        rows.sort(key=lambda r: Path(r["kodi_path"]).is_file(), reverse=True)
        best = rows[0]
        disk_ok = Path(best["kodi_path"]).is_file()

        # Associate with Codec's library: exact title+year, then title with
        # closest year, then fuzzy title.
        path = lib.get((nt, yr))
        if path is None and nt in lib_by_title:
            cands = lib_by_title[nt]
            cands.sort(key=lambda c: abs(c[0] - yr))
            path = cands[0][1]
        if path is None:
            fuzzy = difflib.get_close_matches(nt, lib_by_title.keys(), n=1, cutoff=0.88)
            if fuzzy:
                cands = sorted(lib_by_title[fuzzy[0]], key=lambda c: abs(c[0] - yr))
                path = cands[0][1]
        if path is None and disk_ok:
            path = best["kodi_path"]  # trust the verified Kodi path itself
        if path is None:
            unmatched.append(f"{best['title']} ({yr})")
            continue
        matched += 1

        a = art.get(best["idMovie"], {})
        poster_url = a.get("poster", "")
        fanart_url = a.get("fanart", "")
        poster_file = fanart_file = ""
        if poster_url and not args.no_art:
            poster_file = str(ART_DIR / (hashlib.sha1(poster_url.encode()).hexdigest() + ".jpg"))
            downloads.append((poster_url, Path(poster_file)))
        if fanart_url and args.fanart:
            fanart_file = str(ART_DIR / (hashlib.sha1(fanart_url.encode()).hexdigest() + ".jpg"))
            downloads.append((fanart_url, Path(fanart_file)))

        rating, votes = ratings.get(best["idMovie"], (None, None))
        ids = uids.get(best["idMovie"], {})
        runtime_min = int(best["runtime_s"] or 0) // 60
        codec.execute("""INSERT INTO metadata (path,title,year,plot,rating,votes,
            runtime_min,genres,premiered,imdb_id,tmdb_id,poster,fanart,
            poster_url,fanart_url,source,updated)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,'kodi',?)
            ON CONFLICT(path) DO UPDATE SET title=excluded.title,
            year=excluded.year, plot=excluded.plot, rating=excluded.rating,
            votes=excluded.votes, runtime_min=excluded.runtime_min,
            genres=excluded.genres, premiered=excluded.premiered,
            imdb_id=excluded.imdb_id, tmdb_id=excluded.tmdb_id,
            poster=excluded.poster, fanart=excluded.fanart,
            poster_url=excluded.poster_url, fanart_url=excluded.fanart_url,
            source='kodi', updated=excluded.updated""",
            (path, best["title"], yr, best["plot"], rating, votes,
             runtime_min, best["genres"], best["premiered"],
             ids.get("imdb", ""), ids.get("tmdb", ""),
             poster_file, fanart_file, poster_url, fanart_url, now))

    # ---- TV: shows keyed by their on-disk show directory, episodes by file ----
    tv_roots = [Path(r["path"]) for r in roots if r.get("kind") == "tv"]

    def show_dir_of(fpath: Path):
        for root in tv_roots:
            try:
                rel = fpath.relative_to(root)
            except ValueError:
                continue
            return str(root / rel.parts[0])
        return None

    show_art = {}
    for r in kodi.execute("SELECT media_id, type, url FROM art WHERE media_type='tvshow'"):
        show_art.setdefault(r["media_id"], {})[r["type"]] = r["url"]
    ep_art = {}
    for r in kodi.execute("SELECT media_id, type, url FROM art WHERE media_type='episode'"):
        ep_art.setdefault(r["media_id"], {})[r["type"]] = r["url"]
    show_ratings = {r["media_id"]: (r["rating"], r["votes"]) for r in kodi.execute(
        "SELECT media_id, rating, votes FROM rating WHERE media_type='tvshow'")}

    shows = {r["idShow"]: r for r in kodi.execute(
        "SELECT idShow, c00 AS title, c01 AS plot, c08 AS genres, c05 AS premiered FROM tvshow")}
    show_dirs = {}   # idShow -> on-disk dir (from any existing episode path)
    eps_n, shows_n = 0, 0

    episodes = kodi.execute("""
        SELECT e.idEpisode, e.idShow, e.c00 AS title, e.c01 AS plot,
               e.c12 AS season, e.c13 AS episode,
               p.strPath || f.strFilename AS fpath
        FROM episode e
        JOIN files f ON e.idFile = f.idFile
        JOIN path  p ON f.idPath = p.idPath""").fetchall()

    for ep in episodes:
        fp = Path(ep["fpath"])
        if not fp.is_file():
            continue
        sdir = show_dir_of(fp)
        if sdir and ep["idShow"] in shows:
            show_dirs.setdefault(ep["idShow"], sdir)
        thumb_url = ep_art.get(ep["idEpisode"], {}).get("thumb", "")
        thumb_file = ""
        if thumb_url and not args.no_art:
            thumb_file = str(ART_DIR / (hashlib.sha1(thumb_url.encode()).hexdigest() + ".jpg"))
            downloads.append((thumb_url, Path(thumb_file)))
        codec.execute("""INSERT INTO metadata (path,title,year,plot,poster,poster_url,
            source,updated) VALUES (?,?,?,?,?,?,'kodi',?)
            ON CONFLICT(path) DO UPDATE SET title=excluded.title,
            plot=excluded.plot, poster=excluded.poster,
            poster_url=excluded.poster_url, updated=excluded.updated""",
            (str(fp), ep["title"], 0, ep["plot"], thumb_file, thumb_url, now))
        eps_n += 1

    for sid, sdir in show_dirs.items():
        s = shows[sid]
        a = show_art.get(sid, {})
        poster_url = a.get("poster", "")
        fanart_url = a.get("fanart", "")
        poster_file = ""
        if poster_url and not args.no_art:
            poster_file = str(ART_DIR / (hashlib.sha1(poster_url.encode()).hexdigest() + ".jpg"))
            downloads.append((poster_url, Path(poster_file)))
        rating, votes = show_ratings.get(sid, (None, None))
        codec.execute("""INSERT INTO metadata (path,title,year,plot,rating,votes,
            genres,premiered,poster,fanart,poster_url,fanart_url,source,updated)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,'kodi',?)
            ON CONFLICT(path) DO UPDATE SET title=excluded.title,
            plot=excluded.plot, rating=excluded.rating, votes=excluded.votes,
            genres=excluded.genres, premiered=excluded.premiered,
            poster=excluded.poster, poster_url=excluded.poster_url,
            fanart_url=excluded.fanart_url, updated=excluded.updated""",
            (sdir, s["title"], year_of(s["premiered"]), s["plot"], rating, votes,
             s["genres"], s["premiered"], poster_file, "", poster_url, fanart_url, now))
        shows_n += 1

    print(f"tv: {shows_n} shows, {eps_n} episodes")

    # Watched/resume: taken straight from Kodi's files table by ON-DISK path —
    # immune to this DB's scrambled movie->file associations, and it covers
    # episodes too. Never clobbers state Codec already wrote.
    for r in kodi.execute("""
            SELECT f.idFile, f.playCount, f.lastPlayed,
                   p.strPath || f.strFilename AS fpath
            FROM files f JOIN path p ON f.idPath = p.idPath
            WHERE f.playCount > 0
               OR f.idFile IN (SELECT idFile FROM bookmark WHERE type=1)"""):
        if not Path(r["fpath"]).is_file():
            continue
        play_count = r["playCount"] or 0
        resume = bookmarks.get(r["idFile"], 0)
        cur = codec.execute(
            "SELECT position, watch_count FROM media_state WHERE path=?",
            (r["fpath"],)).fetchone()
        if play_count > 0:
            watched_n += 1
            if cur is None:
                codec.execute("""INSERT INTO media_state
                    (path, watch_count, completed, last_played)
                    VALUES (?,?,1,?)""", (r["fpath"], play_count, r["lastPlayed"]))
            else:
                codec.execute("""UPDATE media_state SET
                    watch_count=MAX(watch_count,?), completed=1 WHERE path=?""",
                    (play_count, r["fpath"]))
        if resume > 0 and (cur is None or (cur[0] or 0) == 0):
            resume_n += 1
            codec.execute("""INSERT INTO media_state (path, position)
                VALUES (?,?) ON CONFLICT(path) DO UPDATE SET
                position=excluded.position WHERE media_state.position=0""",
                (r["fpath"], resume))

    codec.commit()

    if downloads:
        ART_DIR.mkdir(parents=True, exist_ok=True)
        todo = [(u, d) for u, d in downloads if not d.exists()]
        print(f"caching art: {len(todo)} new / {len(downloads)} total …")
        with ThreadPoolExecutor(8) as ex:
            ok = sum(ex.map(lambda t: fetch(*t), todo))
        print(f"  downloaded {ok}/{len(todo)}")

    print(f"movies: {matched} matched, {len(unmatched)} unmatched"
          f" · watched imported: {watched_n} · resume points: {resume_n}")
    if unmatched:
        print("unmatched (no file on disk + no library match):")
        for t in sorted(unmatched):
            print(f"  - {t}")


if __name__ == "__main__":
    main()
