#!/usr/bin/env python3
"""Thumbnails + runtimes for bonus features (featurettes, deleted scenes, promos).

The BONUS FEATURES page lists every extra under a film or show with a frame
from it and its runtime. Extras are never scraped (TMDB has nothing for "Clarice
Meets Lecter"), so both come from the file itself: one ffprobe for the runtime
and transfer, one ffmpeg grab. The frame is picked by ffmpeg's `thumbnail`
filter from a few seconds about a fifth of the way in — a representative frame,
not whatever black frame or cross-fade a fixed timestamp happens to land on.
HDR extras are tone-mapped so they don't come out grey.

Writes ~/.cache/codec/extras.json  {path: {dur, thumb, sig}}  — read by the
app's scanner and by export_library.py — and the JPEGs into the art cache, where
the laptop's pull fetches them like any poster. Idempotent: only new or changed
files (size|mtime) are grabbed, so a settled library costs a directory walk.

  codec_extras.py            fill what's missing
  codec_extras.py --force    re-grab everything
  codec_extras.py --dry-run  list what would be grabbed
"""
import argparse, json, os, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from export_library import (ART_DIR, CFG, EXTRA_THUMB_PREFIX, EXTRAS_INDEX,  # noqa: E402
                            extra_thumb, iter_extras, load_extras_index)

_STATIC = Path.home() / "deps/ffmpeg-n8.1-static/bin"
FFMPEG = str(_STATIC / "ffmpeg") if (_STATIC / "ffmpeg").exists() else "ffmpeg"
FFPROBE = str(_STATIC / "ffprobe") if (_STATIC / "ffprobe").exists() else "ffprobe"
THUMB_W = 480   # 2.5x the row's on-screen thumb at 1440p: sharp, ~25 KB each
TONEMAP = ("zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,"
           "tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p,")


def sig(p: Path) -> str:
    st = p.stat()
    return f"{st.st_size}|{int(st.st_mtime)}"


def probe(p: Path):
    """(duration s, HDR transfer?) — (0, False) when ffprobe can't read it."""
    try:
        r = subprocess.run(
            [FFPROBE, "-v", "error", "-select_streams", "v:0",
             "-show_entries", "format=duration:stream=color_transfer",
             "-of", "json", str(p)],
            capture_output=True, text=True, timeout=60)
        j = json.loads(r.stdout or "{}")
    except (subprocess.TimeoutExpired, ValueError, OSError):
        return 0.0, False
    dur = float((j.get("format") or {}).get("duration") or 0)
    trc = ((j.get("streams") or [{}])[0] or {}).get("color_transfer") or ""
    return dur, trc in ("smpte2084", "arib-std-b67")


def grab(p: Path, out: Path, dur: float, hdr: bool) -> bool:
    at = dur * 0.2 if dur > 30 else dur * 0.4
    tmp = out.with_suffix(".part.jpg")
    scale = (TONEMAP if hdr else "") + f"scale={THUMB_W}:-2"
    # The representative-frame pick first; then simply the next frame after the
    # seek — an image gallery runs at one frame every few seconds, so the 4 s
    # window the pick reads can hold no frame at all.
    for window, vf in ((["-t", "4"], "thumbnail=48," + scale), ([], scale)):
        try:
            r = subprocess.run(
                [FFMPEG, "-nostdin", "-v", "error", "-ss", f"{at:.2f}", "-i", str(p),
                 *window, "-an", "-sn", "-dn", "-vf", vf, "-frames:v", "1",
                 "-q:v", "4", "-y", str(tmp)],
                capture_output=True, text=True, timeout=180)
        except subprocess.TimeoutExpired:
            tmp.unlink(missing_ok=True)
            continue
        if r.returncode == 0 and tmp.exists() and tmp.stat().st_size > 0:
            tmp.replace(out)
            return True
        tmp.unlink(missing_ok=True)
    return False


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--force", action="store_true", help="re-grab every thumbnail")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--jobs", type=int, default=3)
    args = ap.parse_args()

    roots = json.loads(CFG.read_text())["roots"]
    # A root on an unmounted drive walks as empty; its extras must not be
    # forgotten (and their thumbnails deleted) because of it.
    mounted = [r for r in roots if Path(r["path"]).is_dir()]
    if len(mounted) < len(roots):
        print("some roots are missing — keeping their entries", file=sys.stderr)
    old = load_extras_index()
    index, todo = {}, []
    for f, _parent, _rel, _tv in iter_extras(mounted):
        key = str(f)
        prev = old.get(key)
        try:
            s = sig(f)
        except OSError:
            continue
        # A file ffmpeg couldn't grab is remembered as failed, not retried on
        # every F5 — --force (or the file changing) tries it again.
        if (not args.force and prev and prev.get("sig") == s
                and (prev.get("fail")
                     or (prev.get("thumb") and Path(prev["thumb"]).exists()))):
            index[key] = prev
        else:
            todo.append((f, s))
    # Keep entries under roots we couldn't see this time.
    unseen = [r["path"].rstrip("/") + "/" for r in roots if r not in mounted]
    for key, v in old.items():
        if key not in index and any(key.startswith(u) for u in unseen):
            index[key] = v

    print(f"{len(index)} current, {len(todo)} to grab")
    if args.dry_run:
        for f, _ in todo[:40]:
            print("  ", f)
        return 0

    ART_DIR.mkdir(parents=True, exist_ok=True)

    def work(item):
        f, s = item
        dur, hdr = probe(f)
        out = extra_thumb(f)
        ok = grab(f, out, dur, hdr) if dur > 0 else False
        row = {"dur": round(dur, 1), "thumb": str(out) if ok else "", "sig": s}
        if not ok:
            row["fail"] = True
        return str(f), row, ok

    done = failed = 0
    with ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        for key, row, ok in pool.map(work, todo):
            index[key] = row
            done += ok
            failed += not ok
            if not ok:
                print("  no frame:", key, file=sys.stderr)

    tmp = EXTRAS_INDEX.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(index, indent=0, ensure_ascii=False))
    tmp.replace(EXTRAS_INDEX)

    # Thumbnails whose extra is gone (deleted, renamed, re-grabbed elsewhere).
    keep = {Path(v["thumb"]).name for v in index.values() if v.get("thumb")}
    pruned = 0
    for t in ART_DIR.glob(EXTRA_THUMB_PREFIX + "*.jpg"):
        if t.name not in keep:
            t.unlink(missing_ok=True)
            pruned += 1
    print(f"grabbed {done}, failed {failed}, pruned {pruned} — {len(index)} extras indexed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
