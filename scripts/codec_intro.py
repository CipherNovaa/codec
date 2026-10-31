#!/usr/bin/env python3
"""Skip-intro detector — finds each episode's opening titles by audio fingerprint.

Most rips carry no chapter markers, so codec's chapter-driven SKIP INTRO pill
never fires. This finds the intro the way a human does: the opening is the one
stretch of audio that every episode of a season has in common.

    fpcalc -raw   ->  ~8 fingerprints/sec, 32 bits each (chromaprint)
    vote          ->  the frame offset at which two episodes line up
    verify        ->  the run of frames whose fingerprints differ by <=10 bits
    consensus     ->  keep a range only if several sibling episodes agree

Per-episode ranges, not one range per season: cold opens vary in length, so
episode 3's theme can start two minutes after episode 1's.

Results land in the `intros` table; codec reads them at file load. Re-runs are
cheap — fingerprints are cached under ~/.cache/codec/fp.

    codec_intro.py --all                 every TV show in the configured roots
    codec_intro.py --show "X-Men 97"     one show (substring match)
    codec_intro.py --all --recheck       ignore stored results and redo them
"""

import argparse
import hashlib
import json
import re
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
import codec_paths  # where codec's data lives (~/.local/share/codec)

# chromaprint emits one fingerprint per 4096-sample frame at 11025 Hz with a
# 2/3 overlap -> 1365-sample hop. Every time<->frame conversion uses this.
FPS = 11025.0 / 1365.0

WINDOW_S = 480      # how much of each episode to fingerprint (intros live here)
BIT_TOL = 10        # frames differing by <= this many of 32 bits count as equal
DENSITY = 0.85      # a run may contain gaps, but must stay this similar overall
EDGE_W = 12         # ~1.5s: the window each end must sustain before it counts
EDGE_D = 0.50
MIN_INTRO_S = 10.0
MAX_INTRO_S = 210.0
MIN_VARIETY = 2.5   # mean bit-change between consecutive frames of a match
PAIRS = 4           # sibling episodes each one is matched against
AGREE = 2           # how many of those must agree before we store a range
AGREE_TOL_S = 4.0   # ranges within this many seconds are the same range

CONFIG = Path.home() / ".config/codec/config.json"
DB = codec_paths.DB
CACHE = Path.home() / ".cache/codec/fp"
VIDEO_EXT = {".mkv", ".mp4", ".avi", ".m4v", ".mov", ".ts", ".webm"}
EPISODE_RE = re.compile(r"[Ss](\d{1,2})[\s._-]*[Ee](\d{1,3})|(\d{1,2})x(\d{1,2})")

POPCOUNT = np.array([bin(i).count("1") for i in range(256)], dtype=np.uint8)


# ── fingerprints ────────────────────────────────────────────────────────────

def fingerprint(path: Path) -> np.ndarray | None:
    """Raw chromaprint fingerprint of the first WINDOW_S seconds, cached.

    Cache key includes size+mtime, so a re-rip invalidates itself.
    """
    try:
        st = path.stat()
    except OSError:
        return None
    key = hashlib.sha1(
        f"{path}|{st.st_size}|{int(st.st_mtime)}|{WINDOW_S}".encode()).hexdigest()
    cached = CACHE / f"{key}.npy"
    if cached.exists():
        return np.load(cached)

    try:
        out = subprocess.run(
            ["fpcalc", "-raw", "-length", str(WINDOW_S), str(path)],
            capture_output=True, text=True, timeout=300).stdout
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None
    for line in out.splitlines():
        if line.startswith("FINGERPRINT="):
            body = line[len("FINGERPRINT="):]
            if not body:
                return None
            fp = np.array([int(x) for x in body.split(",")], dtype=np.uint32)
            CACHE.mkdir(parents=True, exist_ok=True)
            np.save(cached, fp)
            return fp
    return None


def hamming(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    """Per-frame bit distance between two equal-length fingerprint runs."""
    return POPCOUNT[(a ^ b).view(np.uint8).reshape(-1, 4)].sum(axis=1)


# ── matching ────────────────────────────────────────────────────────────────

def candidate_shifts(a: np.ndarray, b: np.ndarray, top: int = 12) -> list[int]:
    """Frame offsets worth verifying, by voting on coarse fingerprint matches.

    Scanning every shift with full Hamming distance is O(n^2) and far too slow
    for a whole library. The top 16 bits of a chromaprint frame are its coarse
    shape and survive re-encoding, so an inverted index over them nominates a
    handful of plausible alignments in one pass.
    """
    index: dict[int, list[int]] = {}
    for i, h in enumerate(b >> 16):
        index.setdefault(int(h), []).append(i)
    votes: dict[int, int] = {}
    for i, h in enumerate(a >> 16):
        hits = index.get(int(h))
        if not hits or len(hits) > 40:   # a hash this common carries no signal
            continue
        for j in hits:
            votes[j - i] = votes.get(j - i, 0) + 1
    ranked = sorted(votes.items(), key=lambda kv: -kv[1])[:top]
    # Neighbouring shifts are the same alignment off by a frame; keep the peaks.
    peaks: list[int] = []
    for shift, _ in ranked:
        if all(abs(shift - p) > 3 for p in peaks):
            peaks.append(shift)
    return peaks


def longest_dense_run(good: np.ndarray, density: float) -> tuple[int, int]:
    """Longest window whose similar-frame fraction is at least `density`.

    A strictly contiguous run is too brittle — a single loud frame of dialogue
    over the theme splits a 60-second intro into two useless halves. Scoring
    each frame +1/-1 around the density target turns this into "longest
    subarray with a non-negative sum", which is exact and linear.
    """
    v = np.where(good, 1.0 - density, -density)
    prefix = np.concatenate(([0.0], np.cumsum(v)))
    stack = [0]
    for i in range(1, len(prefix)):
        if prefix[i] < prefix[stack[-1]]:
            stack.append(i)
    best = (0, 0)
    for j in range(len(prefix) - 1, -1, -1):
        while stack and prefix[j] >= prefix[stack[-1]]:
            i = stack.pop()
            if j - i > best[1] - best[0]:
                best = (i, j)
    return best


def common_segment(a: np.ndarray, b: np.ndarray) -> tuple[float, float, float] | None:
    """The shared stretch of audio between two episodes, in A's timeline.

    Returns (start_s, end_s, seconds_matched) or None.
    """
    n_min = int(MIN_INTRO_S * FPS)
    best = None
    for shift in candidate_shifts(a, b):
        # A shift means b[i + shift] lines up with a[i]; clamp i to where both
        # sides exist. (Getting this sign backwards verifies the mirror image
        # of the real alignment and finds nothing at all.)
        lo_i = max(0, -shift)
        hi_i = min(len(a), len(b) - shift)
        span = hi_i - lo_i
        if span < n_min:
            continue
        x, y, off = a[lo_i:hi_i], b[lo_i + shift:hi_i + shift], lo_i
        good = hamming(x, y) <= BIT_TOL
        lo, hi = longest_dense_run(good, DENSITY)
        # Erode both ends until they sustain a match, then land exactly on a
        # matching frame. Without this the run trails off into sparse
        # coincidental hits and the pill seeks past real content — the end of
        # the range is what we jump to, so overshooting it is the costly error.
        while hi - lo > EDGE_W and good[max(lo, hi - EDGE_W):hi].mean() < EDGE_D:
            hi -= 1
        while hi - lo > EDGE_W and good[lo:lo + EDGE_W].mean() < EDGE_D:
            lo += 1
        while lo < hi and not good[lo]:
            lo += 1
        while hi > lo and not good[hi - 1]:
            hi -= 1
        if hi - lo < n_min:
            continue
        # Quiet passages match other quiet passages: room tone fingerprints are
        # nearly constant, so two unrelated scenes can "agree" for a minute.
        # A theme tune changes constantly; measure that directly and drop
        # matches whose audio barely moves. (Across the library this separates
        # cleanly — real intros sit near 4.2, the one silence match at 1.7.)
        seg = x[lo:hi]
        if len(seg) > 3 and hamming(seg[:-1], seg[1:]).mean() < MIN_VARIETY:
            continue
        if best is None or hi - lo > best[2]:
            best = (off + lo, off + hi, hi - lo)
    if best is None:
        return None
    return best[0] / FPS, best[1] / FPS, best[2] / FPS


def consensus(ranges: list[tuple[float, float]]) -> tuple[float, float] | None:
    """Keep a range only when several sibling matches independently agree.

    One pair agreeing proves nothing — two episodes can share a music bed, a
    distributor sting, or silence. Clustering by start time and demanding AGREE
    members is what keeps false intros out of the player.
    """
    best = None
    for i, (s, e) in enumerate(ranges):
        group = [(s2, e2) for s2, e2 in ranges
                 if abs(s2 - s) <= AGREE_TOL_S and abs(e2 - e) <= AGREE_TOL_S]
        if len(group) >= AGREE and (best is None or len(group) > len(best)):
            best = group
    if best is None:
        return None
    return (float(np.median([g[0] for g in best])),
            float(np.median([g[1] for g in best])))


# ── library walk ────────────────────────────────────────────────────────────

def tv_roots() -> list[Path]:
    cfg = json.loads(CONFIG.read_text())
    return [Path(r["path"]) for r in cfg.get("roots", [])
            if r.get("kind") == "tv" and Path(r["path"]).is_dir()]


def shows(filter_name: str | None) -> list[tuple[str, list[Path]]]:
    """(show name, episode paths) for each show directory under the TV roots."""
    found = []
    for root in tv_roots():
        for d in sorted(root.iterdir()):
            if not d.is_dir() or d.name.startswith("."):
                continue
            if filter_name and filter_name.lower() not in d.name.lower():
                continue
            eps = sorted(p for p in d.rglob("*")
                         if p.suffix.lower() in VIDEO_EXT and p.is_file())
            if eps:
                found.append((d.name, eps))
    return found


def by_season(eps: list[Path]) -> dict[int, list[Path]]:
    """Group episodes by parsed season. Intros change between seasons — often
    a different length, sometimes a different theme — so seasons never mix."""
    out: dict[int, list[Path]] = {}
    for p in eps:
        m = EPISODE_RE.search(p.name)
        season = int(m.group(1) or m.group(3)) if m else 0
        out.setdefault(season, []).append(p)
    return out


def partners(i: int, count: int) -> list[int]:
    """Indices of the siblings episode i is matched against — spread across the
    season rather than adjacent, so a two-part story can't fake a consensus."""
    if count <= 1:
        return []
    step = max(1, count // (PAIRS + 1))
    picks = [(i + step * k) % count for k in range(1, PAIRS + 1)]
    return list(dict.fromkeys(j for j in picks if j != i))


# ── storage ─────────────────────────────────────────────────────────────────

def open_db() -> sqlite3.Connection:
    db = sqlite3.connect(DB)
    db.execute("""CREATE TABLE IF NOT EXISTS intros (
                      path TEXT PRIMARY KEY,
                      start REAL NOT NULL,
                      end REAL NOT NULL,
                      method TEXT,
                      updated TEXT)""")
    db.commit()
    return db


def store(db: sqlite3.Connection, path: Path, rng: tuple[float, float] | None):
    """A no-intro result is recorded too — an empty row is what stops the next
    run from re-fingerprinting a show that genuinely has no opening titles."""
    now = time.strftime("%Y-%m-%dT%H:%M:%S")
    if rng is None:
        db.execute("INSERT OR REPLACE INTO intros VALUES (?,0,0,'none',?)",
                   (str(path), now))
    else:
        db.execute("INSERT OR REPLACE INTO intros VALUES (?,?,?,'chroma',?)",
                   (str(path), round(rng[0], 2), round(rng[1], 2), now))
    db.commit()


def mmss(t: float) -> str:
    return f"{int(t) // 60}:{int(t) % 60:02d}"


# ── main ────────────────────────────────────────────────────────────────────

def scan_show(db, name: str, eps: list[Path], args) -> tuple[int, int]:
    known = {r[0] for r in db.execute("SELECT path FROM intros")} if not args.recheck else set()
    hits = misses = 0
    for season, files in sorted(by_season(eps).items()):
        todo = [p for p in files if str(p) not in known]
        if not todo:
            continue
        label = f"{name} S{season:02d}" if season else name
        if len(files) < 2:
            print(f"  {label}: single episode, nothing to compare")
            continue
        print(f"  {label}: {len(todo)}/{len(files)} to check", flush=True)

        fps: dict[int, np.ndarray | None] = {}

        def get(i: int):
            if i not in fps:
                fps[i] = fingerprint(files[i])
            return fps[i]

        for i, path in enumerate(files):
            if str(path) in known:
                continue
            a = get(i)
            if a is None:
                print(f"    ! no audio fingerprint: {path.name}")
                continue
            found = []
            for j in partners(i, len(files)):
                b = get(j)
                if b is None:
                    continue
                seg = common_segment(a, b)
                if seg and MIN_INTRO_S <= seg[1] - seg[0] <= MAX_INTRO_S:
                    found.append((seg[0], seg[1]))
                if args.verbose:
                    print(f"      vs {files[j].name[:40]:40s} "
                          f"{('%s-%s' % (mmss(seg[0]), mmss(seg[1]))) if seg else '-'}")
            rng = consensus(found)
            if rng:
                hits += 1
                print(f"    {path.name[:52]:52s} {mmss(rng[0])} → {mmss(rng[1])}"
                      f"  ({rng[1] - rng[0]:.0f}s)")
            else:
                misses += 1
                print(f"    {path.name[:52]:52s} no intro")
            if not args.dry_run:
                store(db, path, rng)
    return hits, misses


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--show", help="only shows whose folder name contains this")
    ap.add_argument("--all", action="store_true", help="every TV show")
    ap.add_argument("--recheck", action="store_true",
                    help="redo episodes that already have a stored result")
    ap.add_argument("--dry-run", action="store_true", help="detect but do not write")
    ap.add_argument("--verbose", action="store_true", help="show every pair match")
    args = ap.parse_args()
    if not args.show and not args.all:
        ap.error("give --show NAME or --all")

    if not DB.exists():
        print(f"no codec database at {DB}", file=sys.stderr)
        return 1

    db = open_db()
    started = time.time()
    hits = misses = 0
    for name, eps in shows(args.show):
        print(f"{name}  ({len(eps)} episodes)", flush=True)
        h, m = scan_show(db, name, eps, args)
        hits += h
        misses += m
    print(f"\n{hits} intros found, {misses} without, "
          f"in {time.time() - started:.0f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
