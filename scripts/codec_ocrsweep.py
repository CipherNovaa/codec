#!/usr/bin/env python3
"""Pre-OCR sweep — OCR bitmap (PGS) subtitles AHEAD of time so the cast subtitle
menu is instant.

A film's PGS/bitmap subtitle is an IMAGE, not text. To hand-render it on the TV
(and so KEEP Dolby Vision / HDR instead of burning it into the picture) the hub
OCRs it to text first — but that OCR has to demux interleaved subtitle blocks out
of the whole ~80 GB file, which is disk-bound and takes minutes the first time.
On demand that is minutes of blank subtitle menu; done ahead of time the text is
already cached and selection is instant.

So this walks the library for films whose subtitle track is bitmap-only and asks
the hub to warm each one's OCR now — ONE at a time (the OCR is disk-heavy) and
only while nothing is casting (the hub refuses mid-cast, protecting the live
stream's disk bandwidth). Text subtitles need no OCR and are skipped entirely.

The hub does the actual OCR (its /subwarm endpoint, the same pgs_ocr_vtt the
subtitle menu uses) — this script never imports codec_serve, so there is one
place where subtitle logic lives and no import-time side effects here.

Runs nightly from codec_refresh.sh. Safe by hand any time — a warmed track is
cached, so a re-run over it returns instantly.

    codec_ocrsweep.py --dry-run     what it would OCR, warms nothing
    codec_ocrsweep.py --limit 3     OCR at most N films this run (default 3)
    codec_ocrsweep.py --drain       clear the WHOLE backlog in one pass (yields
                                    to casts, resumes after — a one-time drain)
    codec_ocrsweep.py --status      backlog + what has been tried
    codec_ocrsweep.py --all-langs   every bitmap track, not just en/und
"""

import argparse
import hashlib
import json
import os
import sqlite3
import subprocess
import sys
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import urlopen
import codec_paths  # where codec's data lives (~/.local/share/codec)

CONFIG = Path.home() / ".config/codec/config.json"
DB = codec_paths.DB
SUB_CACHE = Path.home() / ".cache/codec/subs"     # keep in step with codec_serve
VIDEO_EXT = {".mkv", ".mp4", ".avi", ".m4v", ".mov", ".ts", ".webm"}
FFPROBE = "/usr/bin/ffprobe" if os.path.exists("/usr/bin/ffprobe") else "ffprobe"

# Image-based subtitle codecs — these are the ones that must be OCR'd. Anything
# text (subrip/ass/…) the hub extracts in well under a second, so it is never a
# pre-OCR candidate. An unknown codec is left alone rather than blindly OCR'd.
BITMAP_CODECS = {"hdmv_pgs_subtitle", "pgssub", "pgs",
                 "dvd_subtitle", "dvdsub", "vobsub",
                 "dvb_subtitle", "dvbsub", "xsub"}
# Text subtitle codecs the hub extracts near-instantly (mirrors codec_serve's
# TEXT_SUB_CODECS). A film with one of these in a wanted language needs no
# pre-OCR at all — that track is the instant pick.
TEXT_CODECS = {"subrip", "srt", "ass", "ssa", "mov_text", "webvtt", "text"}

# Languages worth pre-OCRing by default: English and the untagged/unknown that
# is usually the film's main track. Foreign dubs a rip carries "just in case"
# (a Korean PGS on an English film) would each be an 8-minute OCR nobody asked
# for — --all-langs opts into them.
DEFAULT_LANGS = {"en", "eng", "und", "unk", ""}

# A miss (the OCR + external-SRT fallback both found nothing) usually means the
# track genuinely can't be read; back off hard, but retry a couple of times in
# case tesseract/data changes. Indexed by prior failures.
BACKOFF_DAYS = [7, 30]

# --drain pause between retries when the hub is casting or briefly unreachable.
DRAIN_BUSY_WAIT = 60


def roots() -> list[Path]:
    cfg = json.loads(CONFIG.read_text())
    return [Path(r["path"]) for r in cfg.get("roots", []) if Path(r["path"]).is_dir()]


def videos() -> list[Path]:
    out = []
    for root in roots():
        for p in root.rglob("*"):
            if (p.suffix.lower() in VIDEO_EXT and p.is_file()
                    and "sample" not in p.name.lower()):
                out.append(p)
    return sorted(out)


def open_db() -> sqlite3.Connection:
    db = sqlite3.connect(DB)
    # One row per (file, subtitle-stream-index) we have tried to warm.
    db.execute("""CREATE TABLE IF NOT EXISTS ocr_attempts (
                      path TEXT, sidx INTEGER,
                      tries INTEGER DEFAULT 0, last_try TEXT, status TEXT,
                      PRIMARY KEY(path, sidx))""")
    # Cache of the (fast) subtitle-codec probe, keyed by file identity, so a
    # nightly re-scan of an unchanged library is near-instant.
    db.execute("""CREATE TABLE IF NOT EXISTS ocr_probe (
                      path TEXT PRIMARY KEY,
                      size INTEGER, mtime INTEGER, subs TEXT)""")
    db.commit()
    return db


def probe_subs(db, path: Path) -> list[dict]:
    """One dict per subtitle stream: {i, codec, lang, title, forced}. Header-read
    only (fast); cached in ocr_probe by (size, mtime) so an unchanged file on a
    later run skips the probe entirely."""
    try:
        st = path.stat()
    except OSError:
        return []
    row = db.execute("SELECT size, mtime, subs FROM ocr_probe WHERE path=?",
                     (str(path),)).fetchone()
    if row and row[0] == st.st_size and row[1] == int(st.st_mtime):
        try:
            return json.loads(row[2])
        except (ValueError, TypeError):
            pass   # corrupt cache row -> reprobe
    try:
        r = subprocess.run(
            [FFPROBE, "-v", "error", "-select_streams", "s", "-of", "json",
             "-show_entries", "stream=codec_name:stream_disposition=forced"
             ":stream_tags=language,title", str(path)],
            capture_output=True, text=True, timeout=60)
        streams = (json.loads(r.stdout) or {}).get("streams", [])
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError,
            ValueError, TypeError):
        return []   # can't tell -> leave it alone, don't cache the failure
    subs = []
    for i, s in enumerate(streams):
        tags = s.get("tags") or {}
        subs.append({
            "i": i,
            "codec": (s.get("codec_name") or "").lower(),
            "lang": (tags.get("language") or "").lower(),
            "title": tags.get("title") or "",
            "forced": int((s.get("disposition") or {}).get("forced") or 0),
        })
    db.execute("INSERT INTO ocr_probe(path, size, mtime, subs) VALUES(?,?,?,?) "
               "ON CONFLICT(path) DO UPDATE SET size=excluded.size, "
               "mtime=excluded.mtime, subs=excluded.subs",
               (str(path), st.st_size, int(st.st_mtime), json.dumps(subs)))
    db.commit()
    return subs


def pick_bitmap_tracks(subs: list[dict], all_langs: bool,
                       all_tracks: bool) -> list[dict]:
    """Which bitmap tracks of a film to pre-OCR — usually just ONE.

    The whole point is the track the viewer would actually turn on: the primary
    English (or untagged) subtitle. So:
      * if the film already has a TEXT track in a wanted language, that is the
        instant pick — the film needs no OCR at all, return nothing;
      * otherwise take its bitmap tracks in a wanted language, drop forced and
        commentary tracks (nobody opens the subtitle menu for those), and prefer
        a real English full track over untagged/SDH;
      * warm the single best (or all of them under --all)."""
    def wanted(lang):
        return all_langs or lang in DEFAULT_LANGS

    # A servable text track in a wanted language => no OCR needed for this film.
    if any(s["codec"] in TEXT_CODECS and wanted(s["lang"]) for s in subs):
        return []

    cands = [s for s in subs
             if s["codec"] in BITMAP_CODECS and wanted(s["lang"])
             and not s["forced"]
             and "commentary" not in s["title"].lower()
             and "forced" not in s["title"].lower()]
    if not cands:
        return []

    def rank(s):
        eng = 0 if s["lang"] in ("en", "eng") else 1          # English first
        sdh = 1 if "sdh" in s["title"].lower() else 0         # full over SDH
        return (eng, sdh, s["i"])

    cands.sort(key=rank)
    return cands if all_tracks else cands[:1]


def is_cached(rp: str, sidx: int) -> bool:
    """Does the hub already hold this track's VTT? Same key scheme as
    codec_serve.vtt_cached (sha1 of "<realpath>#<index>")."""
    key = hashlib.sha1(f"{rp}#{sidx}".encode()).hexdigest()
    out = SUB_CACHE / f"{key}.vtt"
    try:
        return out.exists() and out.stat().st_size > 0
    except OSError:
        return False


def due(row, max_tries: int) -> bool:
    """Has this (file, track) waited out its backoff?"""
    if row is None:
        return True
    tries, last_try, status = row
    if status == "done":
        return False
    if tries >= max_tries:
        return False
    wait = BACKOFF_DAYS[min(tries, len(BACKOFF_DAYS)) - 1] if tries else 0
    try:
        last = time.mktime(time.strptime(last_try, "%Y-%m-%dT%H:%M:%S"))
    except (TypeError, ValueError):
        return True
    return (time.time() - last) >= wait * 86400


def record(db, path: str, sidx: int, status: str):
    db.execute(
        "INSERT INTO ocr_attempts(path, sidx, tries, last_try, status) "
        "VALUES(?,?,1,?,?) ON CONFLICT(path, sidx) DO UPDATE SET "
        "tries=tries+1, last_try=excluded.last_try, status=excluded.status",
        (path, sidx, time.strftime("%Y-%m-%dT%H:%M:%S"), status))
    db.commit()


def warm(rp: str, sidx: int, hub: str) -> dict:
    """Ask the hub to OCR one track NOW (blocks until it is cached). The hub
    refuses (`busy`) while a cast is live — see codec_serve._serve_subwarm."""
    url = f"{hub}/subwarm?src=" + quote(rp) + f"&i={sidx}"
    with urlopen(url, timeout=2400) as r:      # OCR has a 1800s internal ceiling
        return json.loads(r.read().decode())


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--limit", type=int, default=3,
                    help="most films to OCR this run (default 3)")
    ap.add_argument("--delay", type=float, default=1.0,
                    help="seconds between OCRs (default 1). Unlike codec_subsweep "
                         "there is no external provider to rate-limit — the OCR is "
                         "local and serialized — so this is just a small disk breather.")
    ap.add_argument("--max-tries", type=int, default=3,
                    help="give up on a track after this many misses")
    ap.add_argument("--all-langs", action="store_true",
                    help="consider every language, not just English/untagged")
    ap.add_argument("--all", action="store_true",
                    help="warm every qualifying bitmap track per film, not just "
                         "the single primary one")
    ap.add_argument("--drain", action="store_true",
                    help="OCR the WHOLE backlog in one unattended pass (ignores "
                         "--limit); pauses + resumes on a cast instead of stopping")
    ap.add_argument("--dry-run", action="store_true",
                    help="list candidates; warms nothing, writes no attempts")
    ap.add_argument("--status", action="store_true",
                    help="summarise the backlog and stop")
    ap.add_argument("--hub", default="http://127.0.0.1:8200",
                    help="codec hub base URL (it does the actual OCR)")
    args = ap.parse_args()

    if not DB.exists():
        print(f"no codec database at {DB}", file=sys.stderr)
        return 1
    db = open_db()

    print("scanning library…", flush=True)
    files = videos()
    attempts = {(r[0], r[1]): (r[2], r[3], r[4]) for r in db.execute(
        "SELECT path, sidx, tries, last_try, status FROM ocr_attempts")}

    # A candidate is (path, realpath, sidx, lang): the primary bitmap-only track
    # of a film with no text alternative, not already cached, past its backoff.
    todo, cached_n, skipped_recent, films = [], 0, 0, 0
    for p in files:
        picks = pick_bitmap_tracks(probe_subs(db, p), args.all_langs, args.all)
        if not picks:
            continue
        films += 1
        rp = os.path.realpath(str(p))
        for s in picks:
            sidx = s["i"]
            if is_cached(rp, sidx):
                cached_n += 1
                continue
            if not due(attempts.get((str(p), sidx)), args.max_tries):
                skipped_recent += 1
                continue
            todo.append((p, rp, sidx, s["lang"]))

    # A one-time --drain clears smallest-file-first: the OCR is disk-bound on
    # file size, so the many small TV episodes finish in seconds each and most of
    # the library goes instant within hours, leaving the few big UHD movies as
    # the long tail. (A nightly --limit bite keeps library order — it only does a
    # handful, so ordering barely matters, and it shouldn't starve movies behind
    # a whole TV series.)
    if args.drain:
        def _sz(t):
            try:
                return os.path.getsize(t[1])
            except OSError:
                return 0
        todo.sort(key=_sz)

    print(f"{len(files)} files · {films} bitmap-only films · {len(todo)} tracks"
          f" to OCR · {cached_n} already cached"
          f" · {skipped_recent} waiting out a retry backoff")

    if args.status:
        for status in ("done", "miss", "error", "busy"):
            n = sum(1 for v in attempts.values() if v[2] == status)
            print(f"  {status:6s} {n}")
        return 0

    # --drain: work the WHOLE backlog in one unattended run (a one-time pass to
    # clear the initial pile, so the nightly --limit only ever maintains new
    # additions). Otherwise take a --limit-sized nightly bite.
    batch = todo if args.drain else todo[:args.limit]
    if args.dry_run:
        for p, _rp, sidx, lang in batch:
            print(f"  would OCR: s:{sidx} [{lang or '??'}]  {p.name[:64]}")
        if len(todo) > len(batch):
            print(f"  … and {len(todo) - len(batch)} more beyond --limit")
        return 0
    if not batch:
        print("nothing to do")
        return 0

    done = miss = err = 0
    for i, (p, rp, sidx, lang) in enumerate(batch):
        if i:
            time.sleep(args.delay)
        # The hub refuses (busy) while a cast is live. A nightly bite just STOPS
        # and leaves the rest for next time; a --drain run instead PAUSES and
        # retries the same track, so one cast can't abort the whole unattended
        # pass — it yields the disk to the cast and resumes when it ends. A drain
        # also rides out a transient hub blip (a serve restart = connection
        # refused) the same way, but a per-track HTTP error (a 404 moved file)
        # is recorded and skipped, never retried in a loop.
        while True:
            try:
                res = warm(rp, sidx, args.hub)
            except HTTPError as e:                   # per-request: skip it
                res = {"error": f"http {e.code}"}
            except (URLError, OSError) as e:         # hub unreachable: transient
                res = {"unreachable": str(getattr(e, "reason", e))}
            retry = res.get("busy") or "unreachable" in res
            if not retry:
                break
            if not args.drain:                       # nightly busy/down -> stop
                # A hub that is DOWN says nothing about the tracks: recording
                # an error against each one burned a retry per track, and three
                # bad nights abandoned them for good. Stop like "busy" does.
                print("  ⏸  hub is " + ("casting" if res.get("busy") else
                                        "unreachable") +
                      " — stopping, backlog left for next run", flush=True)
                res = None
                break
            why = "casting" if res.get("busy") else "hub unreachable"
            print(f"  ⏸  {why} — paused {DRAIN_BUSY_WAIT}s, will resume",
                  flush=True)
            time.sleep(DRAIN_BUSY_WAIT)
        if res is None:                              # non-drain busy stop
            break
        if "error" in res or "unreachable" in res:
            err += 1
            record(db, str(p), sidx, "error")
            print(f"  !  s:{sidx} {p.name[:56]}  "
                  f"({res.get('error') or res['unreachable']})", flush=True)
            continue
        if res.get("ok"):
            done += 1
            record(db, str(p), sidx, "done")
            tag = "cached" if res.get("cached") else f"{res.get('ms', 0)//1000}s"
            print(f"  ✓  s:{sidx} {p.name[:56]}  ({tag})", flush=True)
        else:
            miss += 1
            record(db, str(p), sidx, "miss")
            print(f"  –  s:{sidx} {p.name[:56]}  OCR found nothing", flush=True)

    print(f"\n{done} OCR'd, {miss} without text, {err} errors"
          f" ({max(0, len(todo) - len(batch))} left for the next run)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
