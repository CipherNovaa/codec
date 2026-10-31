#!/usr/bin/env python3
"""Nightly subtitle sweep — fills in what shift+S would have to be pressed for.

`shift+S` in the player already finds and saves a subtitle beside the video.
This does the same thing unattended for everything in the library that has no
subtitle at all, so the answer to "why are there no subs on this one" is
usually "there already are".

The whole design is about NOT hammering the providers, because a library sweep
is exactly the shape of traffic that gets an IP blocked:

    conservative candidates  only files with no sidecar AND no embedded
                             English track are even considered
    a budget per run         --limit (default 40), never the whole backlog
    a pause between calls    --delay (default 3s)
    memory of failures       tries are recorded; a file is retried at
                             widening intervals and dropped after --max-tries

Runs from codec_refresh.sh at 07:30. Safe to run by hand any time — finding a
subtitle is idempotent (an existing sidecar returns immediately).

    codec_subsweep.py --dry-run        what it would fetch, no network at all
    codec_subsweep.py --limit 10       a small bite
    codec_subsweep.py --status         backlog + what has been tried
"""

import argparse
import json
import os
import re
import sqlite3
import subprocess
import sys
import time
from pathlib import Path
import codec_paths  # where codec's data lives (~/.local/share/codec)

CONFIG = Path.home() / ".config/codec/config.json"
DB = codec_paths.DB
VIDEO_EXT = {".mkv", ".mp4", ".avi", ".m4v", ".mov", ".ts", ".webm"}

# Featurettes, deleted scenes, trailers: no provider carries subtitles for
# them, so a "match" is always another title's file — a deleted scene called
# "Revelations" got the whole X-Files episode, one 168 KB file landed beside
# four unrelated extras. The library exporter's rule is THE rule for "this is
# an extra" (it must stay one regex, see export_library.EXTRAS_RE).
sys.path.insert(0, str(Path(__file__).resolve().parent))
try:
    from export_library import EXTRAS_RE
except Exception:                      # never let the sweep die over this
    EXTRAS_RE = None

# Retry schedule in days, indexed by how many times we have already failed.
# A miss usually means the provider has nothing for that release, so backing
# off hard is right — but a new upload can appear, hence the retries at all.
BACKOFF_DAYS = [3, 14, 60]


def roots() -> list[Path]:
    cfg = json.loads(CONFIG.read_text())
    return [Path(r["path"]) for r in cfg.get("roots", []) if Path(r["path"]).is_dir()]


def is_extra(p: Path, root: Path) -> bool:
    try:
        rel = p.relative_to(root).as_posix()
    except ValueError:
        rel = p.as_posix()
    return bool(EXTRAS_RE and EXTRAS_RE.search("/" + rel))


def videos() -> list[Path]:
    out = []
    for root in roots():
        for p in root.rglob("*"):
            if (p.suffix.lower() in VIDEO_EXT and p.is_file()
                    and "sample" not in p.name.lower() and not is_extra(p, root)):
                out.append(p)
    return sorted(out)


SUB_DIRS = ("Subs", "subs", "Subtitles", "subtitles", "Sub")


def release_english(p: Path) -> bool:
    """The release shipped its own English track: Subs/ beside a film, or a
    season pack's Subs/<episode file name>/ (RARBG's 2_English.srt). Those
    are timed to this exact file; fetching over them got Sopranos season 1
    episodes swapped (August). Same English test as the hub's candidates."""
    for name in SUB_DIRS:
        sd = p.parent / name
        if not sd.is_dir():
            continue
        for d in (sd, sd / p.stem):
            try:
                files = list(d.iterdir())
            except OSError:
                continue
            for f in files:
                n = f.name.lower()
                if (n.endswith((".srt", ".ass")) and f.is_file()
                        and f.stat().st_size > 0
                        and (".en." in n or ".eng." in n or "english" in n
                             or n.startswith("eng") or re.match(r"^\d+[_. ]?eng", n))):
                    return True
        return False
    return False


def has_embedded_english(path: Path) -> bool:
    """True if the file already carries a subtitle track we would accept.

    Deliberately generous: an untagged text track counts as "has subs". This
    errs towards NOT downloading, which is the safe direction — a needless
    fetch costs provider goodwill, a needless skip costs nothing but a shift+S.
    """
    try:
        r = subprocess.run(
            ["/usr/bin/ffprobe", "-v", "error", "-select_streams", "s",
             "-show_entries", "stream=codec_name:stream_tags=language",
             "-of", "csv=p=0", str(path)],
            capture_output=True, text=True, timeout=60)
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return True  # can't tell -> leave it alone
    for line in r.stdout.splitlines():
        parts = [x.strip() for x in line.split(",") if x.strip()]
        if not parts:
            continue
        lang = parts[1].lower() if len(parts) > 1 else ""
        if not lang or lang.startswith("en") or lang in ("und", "unk"):
            return True
    return False


def fetch(path: Path, hub: str) -> tuple[str, str]:
    """Ask the hub to find and save a subtitle beside `path`.

    Deliberately the hub's /subfind rather than importing codec_serve: it is
    the same endpoint shift+S uses (same providers, same API-key config, same
    idempotence), it keeps this script free of the hub's import-time side
    effects, and there is only one place where subtitle logic lives.
    """
    import urllib.parse
    import urllib.request
    url = f"{hub}/subfind?src=" + urllib.parse.quote(str(path))
    with urllib.request.urlopen(url, timeout=180) as r:
        res = json.loads(r.read().decode())
    if not res.get("ok"):
        if res.get("retry"):
            # the providers were unreachable: an outage, not a miss — it
            # must not spend one of the file's retries
            raise OSError(res.get("error") or "providers unreachable")
        return "", ""
    # a new file is re-timed against the film's audio by the hub's own
    # queue (codec_subsync) — nothing for the sweep to wait on
    return res.get("sub", ""), res.get("name", "")


def open_db() -> sqlite3.Connection:
    db = sqlite3.connect(DB)
    db.execute("""CREATE TABLE IF NOT EXISTS sub_attempts (
                      path TEXT PRIMARY KEY,
                      tries INTEGER DEFAULT 0,
                      last_try TEXT,
                      status TEXT)""")
    db.commit()
    return db


def due(row, max_tries: int) -> bool:
    """Has this file waited out its backoff?"""
    if row is None:
        return True
    tries, last_try, status = row
    if status == "found":
        return False
    if tries >= max_tries:
        return False
    wait = BACKOFF_DAYS[min(tries, len(BACKOFF_DAYS)) - 1] if tries else 0
    try:
        last = time.mktime(time.strptime(last_try, "%Y-%m-%dT%H:%M:%S"))
    except (TypeError, ValueError):
        return True
    return (time.time() - last) >= wait * 86400


def record(db, path: Path, status: str):
    db.execute(
        "INSERT INTO sub_attempts(path, tries, last_try, status) VALUES(?,1,?,?) "
        "ON CONFLICT(path) DO UPDATE SET tries=tries+1, last_try=excluded.last_try,"
        " status=excluded.status",
        (str(path), time.strftime("%Y-%m-%dT%H:%M:%S"), status))
    db.commit()


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--limit", type=int, default=40,
                    help="most files to fetch this run (default 40)")
    ap.add_argument("--delay", type=float, default=3.0,
                    help="seconds between provider calls (default 3)")
    ap.add_argument("--max-tries", type=int, default=3,
                    help="give up on a file after this many misses")
    ap.add_argument("--dry-run", action="store_true",
                    help="list candidates; touches no network and writes nothing")
    ap.add_argument("--status", action="store_true",
                    help="summarise the backlog and stop")
    ap.add_argument("--hub", default="http://127.0.0.1:8200",
                    help="codec hub base URL (it does the actual fetching)")
    args = ap.parse_args()

    if not DB.exists():
        print(f"no codec database at {DB}", file=sys.stderr)
        return 1
    db = open_db()

    print("scanning library…", flush=True)
    files = videos()
    attempts = {r[0]: (r[1], r[2], r[3])
                for r in db.execute("SELECT path, tries, last_try, status FROM sub_attempts")}

    missing, skipped_recent = [], 0
    for p in files:
        base = os.path.splitext(str(p))[0]
        if any(os.path.isfile(base + e) and os.path.getsize(base + e) > 0
               for e in (".en.srt", ".srt", ".en.ass", ".ass")):
            continue
        if release_english(p) or has_embedded_english(p):
            continue
        if not due(attempts.get(str(p)), args.max_tries):
            skipped_recent += 1
            continue
        missing.append(p)

    print(f"{len(files)} files · {len(missing)} without subtitles and due"
          f" · {skipped_recent} waiting out a retry backoff")

    if args.status:
        for status in ("found", "miss", "error"):
            n = sum(1 for v in attempts.values() if v[2] == status)
            print(f"  {status:6s} {n}")
        return 0

    todo = missing[:args.limit]
    if args.dry_run:
        for p in todo:
            print(f"  would fetch: {p.name}")
        if len(missing) > len(todo):
            print(f"  … and {len(missing) - len(todo)} more beyond --limit")
        return 0
    if not todo:
        print("nothing to do")
        return 0

    found = miss = err = 0
    for i, p in enumerate(todo):
        if i:
            time.sleep(args.delay)
        try:
            sub, name = fetch(p, args.hub)
        except Exception as e:                       # provider/network wobble
            err += 1
            record(db, p, "error")
            print(f"  !  {p.name[:60]}  ({e})", flush=True)
            continue
        if sub:
            found += 1
            record(db, p, "found")
            print(f"  ✓  {p.name[:60]}  ←  {name}", flush=True)
        else:
            miss += 1
            record(db, p, "miss")
            print(f"  –  {p.name[:60]}  nothing found", flush=True)

    print(f"\n{found} found, {miss} without, {err} errors"
          f" ({len(missing) - len(todo)} left for the next run)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
