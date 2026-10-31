#!/usr/bin/env python3
"""Make direct-playable mp4s FASTSTART so they don't freeze the Chromecast (#233).

The problem: a compatible-codec mp4 (h264 + AAC etc.) is CAST by direct-play — the
hub serves the raw file with HTTP Range and the TV plays it with zero transcode.
But if the file's `moov` index box sits AFTER `mdat` (non-faststart — the default
for a lot of RARBG/older mp4 rips, and every Sopranos episode), the CAF receiver
can't begin playback until it has the whole file, so the cast just freezes (the
Cowboy Bebop movie-night bug). 67 of 82 library mp4s were shipped this way.

The fix is LOSSLESS and touches no bitrate: `ffmpeg -c copy -movflags +faststart`
rewrites the container with `moov` at the front. Video and audio streams are copied
verbatim; only the box order changes. Afterwards the title direct-plays natively
(the best seek + zero server load), permanently.

Two uses, one code path:
  * one-time batch  — `codec_faststart.py`  fixes the whole library now.
  * self-healing    — codec_reconcile.sh calls it on every library update, so a
                      newly-added non-faststart mp4 fixes itself. The header check
                      skips already-faststart files instantly, so a settled library
                      re-scans in seconds.

Safety: writes a sibling temp file (same filesystem → atomic rename), never
truncates the original; skips if free space < filesize; re-probes + re-checks
faststart on the temp before the swap; preserves mtime + mode. Stdlib + ffmpeg only.

Run --dry-run first to see exactly which files would be rewritten.
"""
import argparse, json, os, shutil, struct, subprocess, sys, time
from pathlib import Path

CFG = Path.home() / ".config/codec/config.json"

# Pinned static ffmpeg if present, else system — a stream COPY is version-agnostic,
# but stay consistent with codec_serve.py (which pins 8.1 for the tonemap path).
_FF8 = str(Path.home() / "deps/ffmpeg-n8.1-static/bin")
FFMPEG = f"{_FF8}/ffmpeg" if os.path.exists(f"{_FF8}/ffmpeg") else "/usr/bin/ffmpeg"
FFPROBE = f"{_FF8}/ffprobe" if os.path.exists(f"{_FF8}/ffprobe") else "/usr/bin/ffprobe"

# Faststart only means anything for ISO-BMFF containers with a moov/mdat split.
# .webm is Matroska (no moov) and .mkv/.avi/.ts etc. are laned anyway, so the
# direct-play freeze is purely an mp4-family problem.
FASTSTART_EXTS = {".mp4", ".m4v", ".mov"}
# Kept in SYNC with codec_cast.py (DIRECT_VIDEO / SAFE_AUDIO): a file only
# direct-plays — and so only NEEDS faststart — when the TV can decode it as-is.
# A non-faststart HEVC mp4 goes through a transcode lane regardless, so rewriting
# it would be a pointless touch of the author's media; we skip those.
DIRECT_VIDEO = {"h264", "avc1", "vp8", "vp9"}
SAFE_AUDIO = {"aac", "mp3", "opus", "vorbis", "flac"}


def faststart_state(path):
    """Walk the top-level ISO-BMFF boxes by header only (a handful of tiny reads,
    never the payload) and report box order:
      'fast'  moov appears before mdat  → direct-plays fine
      'slow'  mdat appears before moov  → the freeze; needs the rewrite
      'n/a'   not parseable as ISO-BMFF / neither box found (leave it alone)
    """
    try:
        size = path.stat().st_size
        with open(path, "rb") as f:
            off = 0
            while off + 8 <= size:
                f.seek(off)
                hdr = f.read(8)
                if len(hdr) < 8:
                    break
                box_size = struct.unpack(">I", hdr[:4])[0]
                box_type = hdr[4:8]
                header = 8
                if box_size == 1:                 # 64-bit extended size
                    ext = f.read(8)
                    if len(ext) < 8:
                        break
                    box_size = struct.unpack(">Q", ext)[0]
                    header = 16
                elif box_size == 0:               # box runs to EOF (must be last)
                    box_size = size - off
                if box_type == b"moov":
                    return "fast"                 # moov reached before any mdat
                if box_type == b"mdat":
                    return "slow"                 # mdat reached before any moov
                if box_size < header:             # malformed → don't touch
                    return "n/a"
                off += box_size
    except OSError:
        return "n/a"
    return "n/a"


def direct_compatible(path):
    """True iff the TV could direct-play this file (so faststart actually matters).
    ffprobe the video + audio codecs against the direct-play sets. Runs ONLY on
    non-faststart files, so the whole library isn't probed."""
    try:
        out = subprocess.run(
            [FFPROBE, "-v", "error", "-show_entries",
             "stream=codec_type,codec_name", "-of", "json", str(path)],
            capture_output=True, text=True, timeout=60)
        streams = json.loads(out.stdout or "{}").get("streams", [])
    except (OSError, ValueError, subprocess.SubprocessError):
        return False
    vids = [s.get("codec_name", "").lower() for s in streams
            if s.get("codec_type") == "video"]
    auds = [s.get("codec_name", "").lower() for s in streams
            if s.get("codec_type") == "audio"]
    # cover art / thumbnail "video" streams (mjpeg/png) aren't the main track;
    # require the primary video codec to be direct-playable.
    main_vids = [v for v in vids if v not in ("mjpeg", "png", "bmp", "gif")]
    if not main_vids or any(v not in DIRECT_VIDEO for v in main_vids):
        return False
    if auds and any(a not in SAFE_AUDIO for a in auds):
        return False
    return True


def remux_faststart(path, verbose=False):
    """Losslessly rewrite `path` with moov at the front. Returns 'fixed',
    'skipped-space', or 'failed'. Never leaves the original in a bad state."""
    st = path.stat()
    # Not a video suffix: the library scan indexes *.mp4, so a ".tmp.mp4" seen
    # mid-remux (or left by a killed run) became a phantom title. ffmpeg is
    # told the format with -f mp4.
    tmp = path.with_name(path.name + ".faststart.part")
    try:
        free = shutil.disk_usage(path.parent).free
    except OSError:
        free = 0
    if free < int(st.st_size * 1.1):
        print(f"  SKIP (low disk: need ~{st.st_size>>20}MB) {path}", file=sys.stderr)
        return "skipped-space"
    tmp.unlink(missing_ok=True)
    cmd = [FFMPEG, "-nostdin", "-loglevel", "error", "-y", "-i", str(path),
           "-map", "0", "-c", "copy", "-ignore_unknown",
           "-movflags", "+faststart", "-f", "mp4", str(tmp)]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=3600)
    except (OSError, subprocess.SubprocessError) as e:
        tmp.unlink(missing_ok=True)
        print(f"  FAIL (ffmpeg: {e}) {path}", file=sys.stderr)
        return "failed"
    # Validate the rewrite before swapping: it exists, is a sane size (a copy is
    # ~same bytes), it actually became faststart, and it still probes as video.
    ok = (r.returncode == 0 and tmp.exists()
          and tmp.stat().st_size >= int(st.st_size * 0.9)
          and faststart_state(tmp) == "fast"
          and direct_compatible(tmp))
    if not ok:
        tmp.unlink(missing_ok=True)
        err = (r.stderr or "").strip().replace("\n", " ")[:200]
        print(f"  FAIL (validation; rc={r.returncode} {err}) {path}", file=sys.stderr)
        return "failed"
    # Preserve mode + mtime so the library doesn't see the title as "just added"
    # (sort-by-date) and nothing re-triggers off a changed timestamp.
    try:
        shutil.copymode(path, tmp)
    except OSError:
        pass
    # On disk BEFORE the rename makes it the only copy (ntfs3 + a power cut
    # could otherwise leave a truncated file at the title's path).
    try:
        fd = os.open(tmp, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    except OSError as e:
        tmp.unlink(missing_ok=True)
        print(f"  FAIL (flush: {e}) {path}", file=sys.stderr)
        return "failed"
    os.replace(tmp, path)                 # atomic on the same filesystem
    try:
        os.utime(path, (st.st_atime, st.st_mtime))
    except OSError:
        pass
    if verbose:
        print(f"  fixed {path}")
    return "fixed"


def iter_media(paths, verbose=False):
    """Yield every faststart-eligible file under the given roots/paths."""
    for base in paths:
        base = Path(base)
        if base.is_file():
            if base.suffix.lower() in FASTSTART_EXTS:
                yield base
            continue
        if not base.is_dir():
            if verbose:
                print(f"  (root not mounted/present, skipped) {base}", file=sys.stderr)
            continue
        for f in base.rglob("*"):
            if (f.suffix.lower() in FASTSTART_EXTS
                    and "sample" not in f.name.lower() and f.is_file()):
                yield f


def load_roots():
    try:
        return [r["path"] for r in json.loads(CFG.read_text())["roots"]]
    except (OSError, ValueError, KeyError) as e:
        sys.exit(f"can't read library roots from {CFG}: {e}")


def main():
    ap = argparse.ArgumentParser(description="faststart-remux direct-play mp4s (#233)")
    ap.add_argument("--path", action="append", default=[],
                    help="file or dir to process (repeatable); default = all library roots")
    ap.add_argument("--dry-run", action="store_true",
                    help="report what would be rewritten, change nothing")
    ap.add_argument("--limit", type=int, default=0, help="cap files rewritten (testing)")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    roots = args.path or load_roots()
    scanned = fast = slow_incompat = fixed = failed = skipped = 0
    todo = []
    for f in iter_media(roots, args.verbose):
        scanned += 1
        state = faststart_state(f)
        if state != "slow":
            fast += 1                    # 'fast' or 'n/a' — nothing to do
            continue
        if not direct_compatible(f):
            slow_incompat += 1           # non-faststart but laned anyway — leave it
            continue
        todo.append(f)

    print(f"scanned {scanned} mp4/m4v/mov · {fast} already-ok · "
          f"{slow_incompat} non-faststart-but-laned · {len(todo)} to fix")
    for f in todo:
        if args.dry_run:
            print(f"  WOULD FIX  {f}")
            continue
        if args.limit and fixed >= args.limit:
            print(f"  (--limit {args.limit} reached, stopping)")
            break
        res = remux_faststart(f, args.verbose)
        if res == "fixed":
            fixed += 1
        elif res == "skipped-space":
            skipped += 1
        else:
            failed += 1

    if not args.dry_run:
        print(f"done: {fixed} fixed, {failed} failed, {skipped} skipped (low disk)")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
