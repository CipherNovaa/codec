#!/usr/bin/env python3
"""End-credits detector for TV — where each episode's closing credits begin.

The skip-intro detector's mirror image, so codec can offer UP NEXT when the
credits start instead of at the last frame. Three signals, in order of trust:

    audio    the closing theme a season shares, found exactly the way
             codec_intro.py finds the opening (chromaprint on the episode's
             TAIL, sibling consensus). Precise to a second or two.
    visual   a trailing run of dark frames carrying text, confirmed by
             tesseract reading actual words — for shows that end each episode
             on a different song (The Sopranos) or roll credits over a scene.
    guards   dialogue still going just after a visual candidate pushes it
             past that dialogue; an episode whose credits would run 40 s+
             longer than its season's median is dropped as a scene.

A missed episode costs nothing — the app falls back to autoplay at the end of
the file, exactly as before. An EARLY hit is the expensive error (UP NEXT over
the last scene), so every rule here errs late. Prototype verified by eye on
109 episodes across 14 shows: 85 found, none early.

Results land in the `credits` table; a no-credits result is stored too (start
0, method 'none') so re-runs skip it. Tail fingerprints cache under
~/.cache/codec/fp alongside the intro ones (different key).

    codec_credits.py --all                 every TV show in the configured roots
    codec_credits.py --show "Sopranos"     one show (substring match)
    codec_credits.py --all --recheck       redo episodes that already have a result
    codec_credits.py --show X --dry-run    detect and print, write nothing
"""

import argparse
import hashlib
import json
import re
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import codec_intro as ci                                     # noqa: E402

BIN = Path.home() / "deps/ffmpeg-n8.1-static/bin"
FFMPEG = str(BIN / "ffmpeg") if (BIN / "ffmpeg").exists() else "ffmpeg"
FFPROBE = str(BIN / "ffprobe") if (BIN / "ffprobe").exists() else "ffprobe"
SUB_CACHE = Path.home() / ".cache/codec/subs"
TEXT_SUBS = {"subrip", "ass", "ssa", "mov_text", "webvtt", "text"}

TAIL_S = 360            # how much of each episode's end to examine
MIN_THEME_S = 15.0      # a shared closing stretch shorter than this proves nothing
MAX_CREDITS_S = 330.0   # TV credits longer than this are something else
END_SLACK = 90          # the visual run must reach within this many s of EOF
RUN_GAP = 4             # picture frames tolerated inside a credits run (a logo card)
MIN_RUN = 10            # text-on-dark frames needed before a run counts
OCR_WORDS = 3           # words tesseract must read for a frame to count as credits
GUARD_S = 20            # dialogue this close after a visual candidate = still a scene
OUTLIER_S = 40          # credits this much longer than the season median = a scene
W, H = 320, 180

TS = re.compile(r"(\d+):(\d\d):(\d\d)[.,](\d{1,3})\s*-->\s*(\d+):(\d\d):(\d\d)[.,](\d{1,3})")
# Subtitle lines that are not dialogue: release/caption credits and track tags.
NOT_DIALOGUE = re.compile(r"subtitle|sync|www\.|opensubtitles|corrected by|captions? by|"
                          r"transcript|\bSDH\b|^(english|eng|forced)\b", re.I)


# ── probes ──────────────────────────────────────────────────────────────────

def duration(path: Path) -> float | None:
    try:
        out = subprocess.run([FFPROBE, "-v", "error", "-show_entries", "format=duration",
                              "-of", "json", str(path)], capture_output=True, text=True,
                             timeout=60).stdout
        return float(json.loads(out)["format"]["duration"])
    except (subprocess.TimeoutExpired, ValueError, KeyError):
        return None


def tail_fingerprint(path: Path, dur: float) -> np.ndarray | None:
    """Raw chromaprint of the last TAIL_S seconds, cached like codec_intro's.

    fpcalc can only read from the start of a file, so ffmpeg cuts the tail to a
    small mono WAV first (11025 Hz is chromaprint's own rate)."""
    try:
        st = path.stat()
    except OSError:
        return None
    key = hashlib.sha1(
        f"{path}|{st.st_size}|{int(st.st_mtime)}|tail{TAIL_S}".encode()).hexdigest()
    cached = ci.CACHE / f"{key}.npy"
    if cached.exists():
        return np.load(cached)
    with tempfile.NamedTemporaryFile(suffix=".wav") as wav:
        cut = subprocess.run([FFMPEG, "-v", "error", "-y", "-ss", f"{max(0.0, dur - TAIL_S):.3f}",
                              "-i", str(path), "-t", str(TAIL_S), "-vn", "-ac", "1", "-ar", "11025",
                              "-c:a", "pcm_s16le", wav.name], capture_output=True, timeout=300)
        if cut.returncode != 0:
            return None
        out = subprocess.run(["fpcalc", "-raw", "-length", str(TAIL_S + 5), wav.name],
                             capture_output=True, text=True, timeout=120).stdout
    for line in out.splitlines():
        if line.startswith("FINGERPRINT=") and len(line) > len("FINGERPRINT="):
            fp = np.array([int(x) for x in line[len("FINGERPRINT="):].split(",")], dtype=np.uint32)
            ci.CACHE.mkdir(parents=True, exist_ok=True)
            np.save(cached, fp)
            return fp
    return None


# ── subtitles (the dialogue guard) ──────────────────────────────────────────

def _secs(h, m, s, ms):
    return int(h) * 3600 + int(m) * 60 + int(s) + int(ms.ljust(3, "0")) / 1000


def dialogue_cues(text: str) -> list[tuple[float, float]]:
    """(start, end) of every cue that is somebody talking — not a music note,
    a [SOUND] tag, or a caption credit."""
    cues, cur = [], None
    for line in text.splitlines():
        m = TS.search(line)
        if m:
            cur = [_secs(*m.groups()[:4]), _secs(*m.groups()[4:]), []]
            cues.append(cur)
        elif cur is not None and line.strip():
            cur[2].append(line.strip())
    out = []
    for s, e, body in cues:
        t = re.sub(r"<[^>]+>|\{[^}]+\}", "", " ".join(body)).strip()
        if not t or NOT_DIALOGUE.search(t):
            continue
        if len(re.sub(r"[\[\(][^\]\)]*[\]\)]|[♪♫#*\-–—\s\d]", "", t)) < 2:
            continue
        out.append((s, e))
    return out


def dialogue(path: Path, dur: float) -> list[tuple[float, float]]:
    """Dialogue cues from the best text source on hand: a sidecar .srt, the
    hub's subtitle cache (codec_serve keys it sha1("<src>#<index>"), OCR'd PGS
    included), else the tail of an embedded text track. A track whose cues run
    past the episode belongs to a different cut — it is ignored."""
    cues = []
    for suffix in (".en.srt", ".eng.srt", ".srt"):
        side = path.with_name(path.stem + suffix)
        if side.exists():
            cues = dialogue_cues(side.read_text(errors="ignore"))
            if cues:
                break
    if not cues:
        for i in range(6):
            vtt = SUB_CACHE / (hashlib.sha1(f"{path}#{i}".encode()).hexdigest() + ".vtt")
            if vtt.exists() and vtt.stat().st_size > 0:
                cues = dialogue_cues(vtt.read_text(errors="ignore"))
                if cues:
                    break
    if not cues:
        try:
            streams = json.loads(subprocess.run(
                [FFPROBE, "-v", "error", "-select_streams", "s", "-show_entries",
                 "stream=index,codec_name:stream_tags=language", "-of", "json", str(path)],
                capture_output=True, text=True, timeout=60).stdout).get("streams", [])
        except (subprocess.TimeoutExpired, ValueError):
            streams = []
        text = [s for s in streams if s.get("codec_name") in TEXT_SUBS]
        text.sort(key=lambda s: s.get("tags", {}).get("language", "") not in ("eng", "en"))
        if text:
            start = max(0.0, dur - TAIL_S)
            out = subprocess.run([FFMPEG, "-v", "error", "-ss", f"{start:.2f}", "-i", str(path),
                                  "-map", f"0:{text[0]['index']}", "-f", "srt", "-"],
                                 capture_output=True, text=True, timeout=180).stdout
            # -ss before -i restarts cue times at the seek point
            cues = [(start + a, start + b) for a, b in dialogue_cues(out)]
    if cues and max(e for _, e in cues) > dur - 2:
        return []
    return cues


# ── the visual run ──────────────────────────────────────────────────────────

def tail_frames(path: Path, start: float) -> np.ndarray:
    """1 fps, 320x180 gray over the tail. `-skip_frame bidir` decodes every I
    and P frame (accurate to well under a second) at ~7x the speed of a full
    decode. NOT `nokey`: a static credit crawl compresses so well that it holds
    almost no keyframes, and keyframe-only sampling repeats the last scene
    before it for half a minute."""
    out = subprocess.run([FFMPEG, "-v", "error", "-skip_frame", "bidir", "-ss", f"{start:.2f}",
                          "-i", str(path), "-t", str(TAIL_S), "-an", "-sn",
                          "-vf", f"fps=1,scale={W}:{H},format=gray", "-f", "rawvideo", "-"],
                         capture_output=True, timeout=600).stdout
    a = np.frombuffer(out, dtype=np.uint8)
    return a[: a.size // (W * H) * (W * H)].reshape(-1, H, W)


def label(frame: np.ndarray) -> str:
    """'b' black, 'c' dark background carrying text, 'p' picture.

    Text is measured against the frame's own background: credit type is small
    and often dim (it never passes a fixed bright threshold once scaled down),
    and a dense crawl is judged by its MEDIAN, which stays black however much
    text is on screen."""
    med = float(np.median(frame))
    text = (frame > max(45.0, med + 30.0)).mean()
    if med < 30 and text <= 0.0008 and (frame < 35).mean() > 0.97:
        return "b"
    if med < 30 and 0.0008 < text < 0.45:
        return "c"
    return "p"


def ocr_words(path: Path, t: float) -> int:
    """Words of 3+ letters tesseract reads on the frame at t — the difference
    between credits and a dark final scene, which look the same to a histogram."""
    png = subprocess.run([FFMPEG, "-v", "error", "-ss", f"{t:.2f}", "-i", str(path), "-frames:v", "1",
                          "-vf", "scale=960:-2,format=gray,negate", "-f", "image2pipe",
                          "-vcodec", "png", "-"], capture_output=True, timeout=120).stdout
    if not png:
        return 0
    txt = subprocess.run(["tesseract", "stdin", "stdout", "--psm", "6"], input=png,
                         capture_output=True, timeout=60).stdout.decode(errors="ignore")
    return len(re.findall(r"\b[A-Za-z]{3,}\b", txt))


def first_credit(path: Path, labels: str, start: float, k: int, last: int, budget: int) -> int | None:
    """Walk forward from frame k: the credits begin at the cut to black or the
    first frame tesseract reads words on — whichever comes first."""
    calls = 0
    while k <= last and calls < budget:
        if labels[k] == "b":
            return k
        if labels[k] == "c":
            calls += 1
            if ocr_words(path, start + k) >= OCR_WORDS:
                return k
            k += 3
            continue
        k += 1
    return None


def visual(path: Path, dur: float, cues: list[tuple[float, float]]) -> float | None:
    start = max(0.0, dur - TAIL_S)
    labels = "".join(label(f) for f in tail_frames(path, start))
    if not labels:
        return None
    end = len(labels) - 1
    while end >= 0 and labels[end] == "p":
        end -= 1
    if len(labels) - 1 - end > END_SLACK:
        return None                              # nothing dark near the end
    text_frames, gap, j, run_start = 0, 0, end, None
    while j >= 0:
        if labels[j] in "cb":
            text_frames += labels[j] == "c"
            gap, run_start = 0, j
        else:
            gap += 1
            if gap > RUN_GAP:
                break
        j -= 1
    if run_start is None or text_frames < MIN_RUN:
        return None
    # The run can open inside a dark, wordless final scene; find the real first credit.
    first = first_credit(path, labels, start, run_start, end, budget=14)
    if first is None:
        return None
    # Black alone proves nothing: tesseract must read real words somewhere in the run.
    texty = [x for x in range(first, end + 1) if labels[x] == "c"]
    probes = [texty[len(texty) * q // 4] for q in (1, 2, 3)] if len(texty) >= 4 else texty
    if not probes or max(ocr_words(path, start + x) for x in probes) < OCR_WORDS:
        return None
    at = start + first
    # Dialogue still going just after the candidate means it is a scene: push past
    # it and land again on black or readable text. (A GLOBAL "after the last line"
    # rule fails — post-credit gags, translated end-song lyrics and SDH tags all
    # sit in the subtitles after the credits have started.)
    pushed, moved = at, True
    while moved:
        moved = False
        for a, b in cues:
            if b > pushed and a < pushed + GUARD_S:
                pushed, moved = b + 1.0, True
    if pushed != at:
        k = first_credit(path, labels, start, max(0, int(pushed - start)), end, budget=12)
        return None if k is None else start + k
    return at


# ── a season ────────────────────────────────────────────────────────────────

def detect_season(files: list[Path], verbose: bool = False) -> list[tuple[Path, float | None, str]]:
    durs = {i: duration(p) for i, p in enumerate(files)}
    fps: dict[int, np.ndarray | None] = {}

    def fp(i: int):
        if i not in fps:
            fps[i] = tail_fingerprint(files[i], durs[i]) if durs[i] else None
        return fps[i]

    saved_min, saved_max = ci.MIN_INTRO_S, ci.MAX_INTRO_S
    ci.MIN_INTRO_S, ci.MAX_INTRO_S = MIN_THEME_S, MAX_CREDITS_S   # the matcher reads these
    results = []
    try:
        for i, path in enumerate(files):
            dur = durs[i]
            if not dur:
                results.append((path, None, "unreadable"))
                continue
            at, how = None, "none"
            a = fp(i)
            if a is not None and len(files) >= 3:
                found = []
                for j in ci.partners(i, len(files)):
                    b = fp(j)
                    if b is None:
                        continue
                    seg = ci.common_segment(a, b)
                    if seg and MIN_THEME_S <= seg[1] - seg[0] <= MAX_CREDITS_S:
                        found.append((seg[0], seg[1]))
                rng = ci.consensus(found)
                if rng:
                    at, how = max(0.0, dur - TAIL_S) + rng[0], "audio"
            if at is None:
                v = visual(path, dur, dialogue(path, dur))
                if v is not None:
                    at, how = v, "visual"
            if at is not None and not (5 <= dur - at <= MAX_CREDITS_S):
                at, how = None, how + "-range"
            results.append((path, at, how))
            if verbose:
                print(f"      {path.name[:52]:52s} {how}", flush=True)
    finally:
        ci.MIN_INTRO_S, ci.MAX_INTRO_S = saved_min, saved_max
    # Credits run near-identical lengths within a season; an episode claiming
    # OUTLIER_S more than the median is a scene that looked like credits.
    lens = sorted(durs[i] - at for i, (_, at, _) in enumerate(results) if at is not None)
    if len(lens) >= 3:
        med = lens[len(lens) // 2]
        results = [(p, at, how) if at is None or durs[i] - at <= med + OUTLIER_S
                   else (p, None, how + "-outlier")
                   for i, (p, at, how) in enumerate(results)]
    return results


# ── storage ─────────────────────────────────────────────────────────────────

def open_db() -> sqlite3.Connection:
    db = sqlite3.connect(ci.DB)
    db.execute("""CREATE TABLE IF NOT EXISTS credits (
                      path TEXT PRIMARY KEY,
                      start REAL NOT NULL,
                      method TEXT,
                      updated TEXT)""")
    db.commit()
    return db


def store(db: sqlite3.Connection, path: Path, at: float | None, how: str):
    """A no-credits result is stored as start 0 so the next run skips it."""
    db.execute("INSERT OR REPLACE INTO credits VALUES (?,?,?,?)",
               (str(path), round(at, 2) if at is not None else 0.0, how,
                time.strftime("%Y-%m-%dT%H:%M:%S")))
    db.commit()


# ── main ────────────────────────────────────────────────────────────────────

def scan_show(db, name: str, eps: list[Path], args) -> tuple[int, int]:
    # "unreadable" is not an answer — it is ffprobe timing out while the DV
    # drain or substrip hammered the same drive. Such rows are retried.
    known = set() if args.recheck or db is None else \
        {r[0] for r in db.execute(
            "SELECT path FROM credits WHERE method IS NULL OR method != 'unreadable'")}
    hits = misses = 0
    for season, files in sorted(ci.by_season(eps).items()):
        todo = [p for p in files if str(p) not in known]
        if not todo:
            continue
        label_ = f"{name} S{season:02d}" if season else name
        print(f"  {label_}: {len(todo)}/{len(files)} to check", flush=True)
        # The whole season is analysed even when only one episode is new: audio
        # consensus and the outlier median both need the siblings.
        for path, at, how in detect_season(files, args.verbose):
            if str(path) in known:
                continue
            if at is not None:
                hits += 1
                dur = duration(path) or 0
                print(f"    {path.name[:52]:52s} {ci.mmss(at)}  (-{dur - at:.0f}s, {how})")
            else:
                misses += 1
                print(f"    {path.name[:52]:52s} no credits ({how})")
            if not args.dry_run and how != "unreadable":
                store(db, path, at, how)      # unreadable: try again next run
    return hits, misses


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--show", help="only shows whose folder name contains this")
    ap.add_argument("--all", action="store_true", help="every TV show")
    ap.add_argument("--recheck", action="store_true",
                    help="redo episodes that already have a stored result")
    ap.add_argument("--dry-run", action="store_true", help="detect but do not write")
    ap.add_argument("--verbose", action="store_true", help="print each episode as it is decided")
    args = ap.parse_args()
    if not args.show and not args.all:
        ap.error("give --show NAME or --all")
    if not ci.DB.exists():
        print(f"no codec database at {ci.DB}", file=sys.stderr)
        return 1
    db = None if args.dry_run else open_db()
    if args.dry_run:
        args.recheck = True
    started = time.time()
    hits = misses = 0
    for name, eps in ci.shows(args.show):
        print(f"{name}  ({len(eps)} episodes)", flush=True)
        h, m = scan_show(db, name, eps, args)
        hits += h
        misses += m
    print(f"\n{hits} credits found, {misses} without, in {time.time() - started:.0f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
