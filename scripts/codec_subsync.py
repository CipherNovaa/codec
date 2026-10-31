#!/usr/bin/env python3
"""Subtitle timing — a fetched subtitle is only as good as its clock.

A sidecar that reads well can still be half a second late (a different
encode's leader), ten seconds out (another cut's studio logos) or drifting a
frame a minute (PAL timing on a 23.976 film). None of that is visible in the
file; all of it is visible on the screen. This module measures the subtitle
against the film's own AUDIO (ffsubsync — voice activity on both sides, then
the shift and framerate ratio that best lines them up) and, when the fit is
confident and the correction is worth it, re-times the file in place.

    the raw file is kept     ~/.cache/codec/subs/sync/<key>.raw.<ext>
    the verdict is kept      ~/.cache/codec/subs/sync/<key>.json
    the swap is atomic       written beside the sidecar, then os.replace()
    it yields                nice 19 + idle ionice: the cast's reader wins

ffsubsync lives in its own venv (like pgsrip): ~/.venvs/ffsubsync. Measured
here (2026-10-12): ~0.9 s per minute of film cold (the time is READING the
container — a 4K HEVC mkv must be demuxed end to end for its audio), a few
seconds warm; a 25-minute short came back −0.52 s, a stretched-and-shifted
copy of it came back 0.959 × and −2.44 s (the stretch undone exactly), and a
107-minute feature's nightly-fetched sidecar turned out to be 9.7 s late.

    codec_subsync.py <video> [<sub>]        re-time one (sub = the sidecar)
    codec_subsync.py --sweep [--limit N]    every sidecar not yet measured
    codec_subsync.py --status <sub>         the kept verdict
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

FFS = Path.home() / ".venvs/ffsubsync/bin/ffsubsync"
_FF8 = Path.home() / "deps/ffmpeg-n8.1-static/bin"
FFPROBE = str(_FF8 / "ffprobe") if (_FF8 / "ffprobe").exists() else "/usr/bin/ffprobe"
SUB_CACHE = Path.home() / ".cache/codec/subs"
SYNC_DIR = SUB_CACHE / "sync"
CONFIG = Path.home() / ".config/codec/config.json"

SUB_EXT = (".srt", ".ass", ".ssa")
VIDEO_EXT = {".mkv", ".mp4", ".avi", ".m4v", ".mov", ".ts", ".webm"}

# A correction smaller than this isn't worth touching the file for (a frame
# is 42 ms; nobody reads a 100 ms shift) — and a ratio this close to 1 is
# noise, not PAL.
MIN_OFFSET = 0.15
MIN_SCALE = 0.002
# ffsubsync's score grows with the film; a confident fit scored ~35-45 per
# second of film here, a failed one came back NEGATIVE. Below this rate the
# file is left alone rather than moved by a guess.
MIN_RATE = 8.0
# A film doesn't need a 20 s correction: that is the wrong cut, which the
# fetcher's own duration check should have refused. Over this the verdict is
# "suspect" and the file is left alone (the raw is what plays).
MAX_OFFSET = 30.0
TIMEOUT = 1500

_LOCK = threading.Lock()      # one measurement at a time on this box
_RX_SCORE = re.compile(r"score:\s*(-?[\d.]+)")
_RX_OFF = re.compile(r"offset seconds:\s*(-?[\d.]+)")
_RX_SCALE = re.compile(r"framerate scale factor:\s*([\d.]+)")


def available():
    """ffsubsync is installed in its venv."""
    return FFS.exists()


def _key(sub_path):
    return hashlib.sha1(str(sub_path).encode("utf-8")).hexdigest()[:20]


def record_path(sub_path):
    return SYNC_DIR / (_key(sub_path) + ".json")


def read_record(sub_path):
    """The kept verdict for this sidecar, or None."""
    try:
        return json.loads(record_path(sub_path).read_text())
    except (OSError, ValueError):
        return None


def _write_record(sub_path, rec):
    SYNC_DIR.mkdir(parents=True, exist_ok=True)
    tmp = record_path(sub_path).with_suffix(".tmp")
    tmp.write_text(json.dumps(rec, indent=1))
    os.replace(tmp, record_path(sub_path))


def duration(video):
    """The film's length in seconds, 0 when unknown."""
    try:
        r = subprocess.run([FFPROBE, "-v", "error", "-show_entries", "format=duration",
                            "-of", "csv=p=0", str(video)],
                           capture_output=True, text=True, timeout=60)
        return float(r.stdout.strip() or 0)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return 0.0


def parse(log, rc=0):
    """ffsubsync's three answers out of its log: {score, offset, scale, ran}.
    `ran` is False when the tool never got to a verdict (a crash, a missing
    audio stream, a subtitle it couldn't parse)."""
    m_s, m_o, m_k = _RX_SCORE.search(log), _RX_OFF.search(log), _RX_SCALE.search(log)
    if rc != 0 or not (m_s and m_o and m_k):
        return {"ran": False, "score": 0.0, "offset": 0.0, "scale": 1.0, "rc": rc}
    return {"ran": True, "score": float(m_s.group(1)), "offset": float(m_o.group(1)),
            "scale": float(m_k.group(1)), "rc": rc}


def verdict(m, dur):
    """What to do with a measurement: ("apply" | "keep" | "failed" | "suspect"),
    and why in a word or two. `dur` is the film's length (0 = unknown; the
    rate test is then skipped and only the sign of the score counts)."""
    if not m.get("ran"):
        return "failed", "no verdict"
    score = m["score"]
    if score <= 0:
        return "failed", "no fit"
    if dur > 0 and score / dur < MIN_RATE:
        return "failed", "weak fit"
    off, scale = m["offset"], m["scale"]
    if abs(off) > MAX_OFFSET:
        return "suspect", "wrong cut?"
    if abs(off) < MIN_OFFSET and abs(scale - 1.0) < MIN_SCALE:
        return "keep", "in sync"
    return "apply", "re-timed"


def sub_encoding(sub_path):
    """The subtitle's text encoding, named for ffsubsync. Left to infer, it
    guessed VISCII (Vietnamese, which Python has no codec for) for an old
    cp1252 sidecar and crashed — Justice League never got a verdict. Same
    order the hub reads a download in: UTF-16 by its mark, UTF-8, cp1252,
    then latin-1, which decodes anything."""
    try:
        b = Path(sub_path).read_bytes()
    except OSError:
        return "utf-8"
    if b.startswith((b"\xff\xfe", b"\xfe\xff")):
        return "utf-16"
    for enc in ("utf-8-sig", "cp1252"):
        try:
            b.decode(enc)
            return enc
        except UnicodeDecodeError:
            pass
    return "latin-1"


def measure(video, sub_path, out_path, timeout=TIMEOUT):
    """Run ffsubsync (idle priority) writing the re-timed file to out_path."""
    cmd = ["nice", "-n", "19"]
    if shutil.which("ionice"):
        cmd += ["ionice", "-c3"]
    cmd += [str(FFS), str(video), "-i", str(sub_path), "-o", str(out_path),
            "--encoding", sub_encoding(sub_path), "--output-encoding", "utf-8"]
    if _FF8.exists():
        cmd += ["--ffmpeg-path", str(_FF8)]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"ran": False, "score": 0.0, "offset": 0.0, "scale": 1.0, "rc": -1,
                "error": "timeout"}
    m = parse((r.stdout or "") + (r.stderr or ""), r.returncode)
    if not m["ran"]:
        tail = ((r.stderr or "") + (r.stdout or "")).strip().splitlines()[-3:]
        m["error"] = " | ".join(t.strip()[:120] for t in tail)
    return m


def describe(rec):
    """One readout line for a verdict: '−9.7 S' / '0.959 ×' / 'IN SYNC'."""
    if not rec:
        return ""
    v = rec.get("verdict")
    if v == "apply":
        parts = []
        off = rec.get("offset", 0.0)
        if abs(off) >= MIN_OFFSET:
            parts.append(("+" if off > 0 else "−") + f"{abs(off):.1f} S")
        sc = rec.get("scale", 1.0)
        if abs(sc - 1.0) >= MIN_SCALE:
            parts.append(f"{sc:.3f} ×")
        return " · ".join(parts)
    return {"keep": "IN SYNC", "failed": "NO FIT", "suspect": "WRONG CUT?"}.get(v, "")


def sync(video, sub_path, dur=None, force=False, timeout=TIMEOUT):
    """Measure the sidecar against the film and re-time it in place when the
    fit is confident and the correction worth it. Returns the record:
      {verdict: apply|keep|failed|suspect|skipped, reason, score, offset,
       scale, applied: bool, when, sub, video, raw}
    Idempotent: a sidecar already judged at its current mtime is left alone
    (force=True re-measures)."""
    video, sub_path = Path(video), Path(sub_path)
    if not available():
        return {"verdict": "skipped", "reason": "ffsubsync not installed", "applied": False}
    if sub_path.suffix.lower() not in SUB_EXT or not sub_path.is_file() or not video.is_file():
        return {"verdict": "skipped", "reason": "no such file", "applied": False}
    try:
        mtime = sub_path.stat().st_mtime
    except OSError:
        return {"verdict": "skipped", "reason": "no such file", "applied": False}
    old = read_record(sub_path)
    if old and not force and abs(old.get("sub_mtime", -1) - mtime) < 1.0:
        old["cached"] = True
        return old
    if dur is None:
        dur = duration(video)
    with _LOCK:
        SYNC_DIR.mkdir(parents=True, exist_ok=True)
        key = _key(sub_path)
        raw = SYNC_DIR / f"{key}.raw{sub_path.suffix.lower()}"
        # ffsubsync writes the format the OUTPUT's extension names: the tmp
        # keeps the sidecar's (a ".tmp" produced no file and no error)
        out = sub_path.with_name(f".{sub_path.stem}.sync-{os.getpid()}{sub_path.suffix.lower()}")
        rec = {"video": str(video), "sub": str(sub_path), "when": time.strftime("%Y-%m-%dT%H:%M:%S"),
               "dur": round(dur, 1), "applied": False, "raw": str(raw)}
        try:
            m = measure(video, sub_path, out, timeout=timeout)
            rec.update({"score": m["score"], "offset": round(m["offset"], 3),
                        "scale": round(m["scale"], 4)})
            if m.get("error"):
                rec["error"] = m["error"]
            v, why = verdict(m, dur)
            rec["verdict"], rec["reason"] = v, why
            if v == "apply" and out.is_file() and out.stat().st_size > 0:
                shutil.copy2(sub_path, raw)          # the raw, kept for forensics
                os.replace(out, sub_path)            # the swap, atomic
                rec["applied"] = True
        finally:
            try:
                out.unlink()
            except OSError:
                pass
        try:
            rec["sub_mtime"] = sub_path.stat().st_mtime
        except OSError:
            rec["sub_mtime"] = mtime
        _write_record(sub_path, rec)
    return rec


# ── the sweep: every sidecar in the library not yet measured ─────────────────

def _roots():
    try:
        cfg = json.loads(CONFIG.read_text())
    except (OSError, ValueError):
        return []
    return [Path(r["path"]) for r in cfg.get("roots", []) if Path(r["path"]).is_dir()]


def sidecar_of(video):
    """The subtitle beside a video that the fetcher would have written —
    the same four names the nightly sweep looks for, else None."""
    base = os.path.splitext(str(video))[0]
    for ext in (".en.srt", ".srt", ".en.ass", ".ass"):
        p = Path(base + ext)
        if p.is_file() and p.stat().st_size > 0:
            return p
    return None


def _extras_re():
    """The library exporter's one rule for "this is a featurette" — fetched
    subtitles beside extras are other titles' files (the fetch sweep skips
    them now), so there is nothing to re-time there."""
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    try:
        from export_library import EXTRAS_RE
        return EXTRAS_RE
    except Exception:
        return None


def pairs():
    """(video, sidecar) for every video in the library roots with one,
    featurettes and other extras left out."""
    out = []
    xre = _extras_re()
    for root in _roots():
        for p in sorted(root.rglob("*")):
            if xre and xre.search("/" + p.relative_to(root).as_posix()):
                continue
            if (p.suffix.lower() in VIDEO_EXT and p.is_file()
                    and "sample" not in p.name.lower()):
                s = sidecar_of(p)
                if s:
                    out.append((p, s))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("video", nargs="?", help="the film")
    ap.add_argument("sub", nargs="?", help="the subtitle (default: its sidecar)")
    ap.add_argument("--sweep", action="store_true", help="every sidecar not yet measured")
    ap.add_argument("--limit", type=int, default=0, help="most files this run (sweep)")
    ap.add_argument("--dry-run", action="store_true", help="list, touch nothing")
    ap.add_argument("--force", action="store_true", help="re-measure a judged file")
    ap.add_argument("--status", action="store_true", help="print the kept verdict")
    a = ap.parse_args()

    if a.status:
        rec = read_record(a.video) if a.video else None
        print(json.dumps(rec, indent=1) if rec else "no verdict kept")
        return 0
    if not available():
        print(f"ffsubsync is not installed ({FFS})", file=sys.stderr)
        return 1
    if a.sweep:
        todo = [(v, s) for v, s in pairs()
                if a.force or not (read_record(s) and
                                   abs(read_record(s).get("sub_mtime", -1) - s.stat().st_mtime) < 1.0)]
        if a.limit:
            todo = todo[:a.limit]
        print(f"{len(todo)} sidecars to measure")
        for v, s in todo:
            if a.dry_run:
                print(f"  would measure: {s.name}")
                continue
            t0 = time.time()
            rec = sync(v, s, force=a.force)
            print(f"  {rec.get('verdict','?'):8s} {describe(rec) or rec.get('reason',''):16s}"
                  f" {int(time.time()-t0):4d}s  {s.name[:70]}", flush=True)
        return 0
    if not a.video:
        ap.print_help()
        return 2
    video = Path(a.video)
    sub = Path(a.sub) if a.sub else sidecar_of(video)
    if not sub:
        print("no sidecar beside that video", file=sys.stderr)
        return 1
    rec = sync(video, sub, force=a.force)
    print(json.dumps(rec, indent=1))
    return 0 if rec.get("verdict") in ("apply", "keep") else 1


if __name__ == "__main__":
    sys.exit(main())
