#!/usr/bin/env python3
"""Codec DV Normalizer — a background drain that makes irregular-GOP Dolby Vision
titles cast as REAL Dolby Vision instead of falling back to HDR10.

The problem (see codec-lane-quality-audit): ~9 DV-flagged titles have an irregular
GOP (scene-cut keyframes 2-10s apart). The DV copy-cast lane needs keyframes on a
regular grid, so those titles fall to the HDR10 transcode lane — you get HDR10, not
DV. nvenc can't carry the DV RPU through a re-encode, so the only fix is to re-encode
the base to a CLEAN fixed GOP while preserving the RPU losslessly.

Pipeline per title (validated end-to-end on A History of Violence — casts as DV,
seeks, A/V-synced, DTS audio intact):
  1. extract the HEVC video ES (annexb) from the source
  2. dovi_tool extract-rpu           -> rpu.bin (the DV metadata, lossless)
  3. nvenc re-encode the base: STRICT fixed GOP (keyint=48, forced-IDR every ~2s),
     Main10, PQ/BT2020, high bitrate (default 40 Mbps ≈ near-transparent; nvenc
     even preserves film grain better than default x265 — see the VMAF/visual A/B)
  4. dovi_tool inject-rpu            -> re-inserts the DV RPU into the clean base
  5. mkvmerge: DV video + the ORIGINAL audio & subtitle tracks COPIED losslessly
     (TrueHD/DTS-HD MA kept — never downmixed)
  6. VERIFY: frame count matches the source AND the serve's own dv_probe accepts it
     (preflight lane == 'dv') AND the DV RPU is present. Only then is it "done".

SAFETY INVARIANTS:
  • NEVER reads-modifies-or-deletes an original. Outputs go to a separate staging
    dir (default /mnt/Movies7/_dvnorm). Swapping normalized files into the library
    is a SEPARATE, human decision — this tool never does it.
  • A title is only marked done if the output passes verification; a failed/partial
    output is deleted, the original is untouched, and the drain moves on.
  • Idempotent: an already-normalized+verified title is skipped.

HDR10+ note: three candidates (The Grey, Avatar: Fire and Ash, Enter the Dragon)
carry DV + HDR10+. This keeps the DV RPU (the priority) and drops the HDR10+ dynamic
layer — DV supersedes it on a DV panel.

Usage:
  codec_dv_normalize.py --list                 # show DV-but-HDR10 candidates, no work
  codec_dv_normalize.py --one "<path>"         # normalize one specific title
  codec_dv_normalize.py --limit 1              # GATED first run (do AHoV, then stop)
  codec_dv_normalize.py                        # drain all pending candidates
Options: --bitrate 40M  --outdir <dir>  --keyint 48
"""
import argparse
import filecmp
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

import sys as _sys, os as _os
import codec_paths  # where codec's data lives (~/.local/share/codec)
_sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))
try:
    from codec_ui import yield_io as _yield_io
except ImportError:                       # ui module absent: not worth failing over
    def _yield_io():
        pass

HUB = "http://127.0.0.1:8200"   # runs on the hub itself
_FF8 = str(Path.home() / "deps/ffmpeg-n8.1-static/bin")
FFMPEG = f"{_FF8}/ffmpeg" if Path(f"{_FF8}/ffmpeg").exists() else "ffmpeg"
FFPROBE = f"{_FF8}/ffprobe" if Path(f"{_FF8}/ffprobe").exists() else "ffprobe"
DOVI = str(Path.home() / ".local/bin/dovi_tool")
MKVMERGE = shutil.which("mkvmerge") or "mkvmerge"
# Must reach every root codec indexes, or DV titles sitting in an unscanned root are
# silently never normalized. mergerfs spreads new downloads across Movies5/6/7, so
# omitting Movies7 hid ~a third of everything arriving. Cross-check with
# library_roots() after adding a drive.
ROOTS = ["/mnt/Movies", "/mnt/Movies2", "/mnt/Movies3/Movies",
         "/mnt/Movies4/Movies", "/mnt/Movies5/Movies", "/mnt/Movies6/Movies",
         "/mnt/Movies7/Movies"]
HDR_TRC = {"smpte2084", "arib-std-b67"}
# Scratch lives on the NVMe, NOT in the pool. It used to sit at
# /mnt/Movies7/_dvnorm, which cost Movies7 a 200G mergerfs minfreespace
# reservation to keep room for it — 186G of pool headroom held back so a
# temporary file would fit. Moving it here gives that space back to the library
# and puts the encode on an NVMe instead of a 5400rpm Toshiba.
#
# ⚠ Placement is now always a CROSS-filesystem move (copy + delete) rather than
# a same-drive rename, so a finished title is copied once more, NVMe -> pool.
# That is a few minutes per title and worth the 163G.
# ⚠ The scratch must be reachable UNDER /mnt. verify's preflight_lane() asks the
# hub what lane it would serve the finished file on, and the hub only serves
# /mnt — off it the check returns "ERR:not under /mnt" and EVERY title fails
# verify, discarding a good conversion after ~90min of GPU and skip-listing it.
# That cost four titles on 2026-09-15 (Ghost in the Shell and Raiders, twice
# each) before it was understood, because an earlier fix set this path only in a
# systemd drop-in — and the nightwatch starts the drain via `systemctl start`
# but the idle chain and a manual run do not all share that environment. So the
# default itself must be the /mnt path; env only overrides it deliberately.
# The bytes still land on the NVMe: the /mnt path is a symlink to it, created
# here if missing so a fresh machine cannot silently fall back to the old bug.
_SCRATCH_REAL = os.path.expanduser("~/.local/share/codec/dvnorm-scratch")
_SCRATCH_LINK = "/mnt/Movies7/_dvnorm-scratch"
def _scratch_default():
    try:
        os.makedirs(_SCRATCH_REAL, exist_ok=True)
        if not os.path.exists(_SCRATCH_LINK):
            os.symlink(_SCRATCH_REAL, _SCRATCH_LINK)
        if os.path.realpath(_SCRATCH_LINK) == os.path.realpath(_SCRATCH_REAL):
            return _SCRATCH_LINK
    except OSError:
        pass
    return _SCRATCH_REAL          # degraded: verify will fail loudly, see below
OUTDIR = os.environ.get("CODEC_DVNORM_SCRATCH", _scratch_default())
# The scratch drive is also the SYSTEM drive. Leave this much on it no matter
# what the encode wants — a full / is a broken machine, not a deferred title.
SYSTEM_FLOOR = 80 * 10**9
# When true, the encode target is clamped to the source's OWN measured video
# bitrate, so an output can never need more bits than its input had. Lets a lean
# title be converted for the DV gain without paying disk for bits that carry no
# extra picture. Set from --cap-to-source.
CAP_TO_SOURCE = False
CODEC_CONFIG = Path.home() / ".config/codec/config.json"
# keep this much slack on a drive we relocate a title onto, so filling one up is
# never the side-effect of normalizing another.
PLACE_RESERVE = 30 * 1000**3
# ...and this much on the source drive when keeping a title where it already is.
IN_PLACE_RESERVE = 10 * 1000**3


def log(msg):
    line = f"{time.strftime('%H:%M:%S')} {msg}"
    print(line, flush=True)
    try:
        with open(Path(OUTDIR) / "dvnorm.log", "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def _fsync(path):
    """Flush a file (and its directory entry) to disk before a rename makes it
    the library's copy — ntfs3 + a power cut can otherwise leave a truncated
    file in the title's slot after the scratch copy is already gone."""
    fd = os.open(str(path), os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
    try:
        dfd = os.open(os.path.dirname(os.path.abspath(str(path))), os.O_RDONLY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    except OSError:
        pass


def acquire_lock(wait=0):
    """Refuse to start if another drain instance is already live (prevents two
    drains — e.g. a manual run + a systemd auto-resume — from clobbering each other).
    Stale locks from a dead/power-killed process are reclaimed automatically.

    `wait` (seconds): wait for the holder instead of refusing. The idle chain
    starts the P8 drain and the shrink sweep together; whichever lost the race
    used to log "refusing" and exit 0 — its work silently skipped, and the
    import marker that would have re-armed it already deleted."""
    lock = Path(OUTDIR) / ".drain.lock"
    deadline = time.time() + wait
    said = False
    while True:
        pid = None
        if lock.exists():
            try:
                pid = int(lock.read_text().strip())
            except (ValueError, OSError):
                pid = None
        if pid == os.getpid():
            return True                     # already ours (taken before the scan)
        if not (pid and Path(f"/proc/{pid}").exists()):
            lock.write_text(str(os.getpid()))
            return True
        if time.time() >= deadline:
            log(f"another drain is already running (pid {pid}) — refusing to start")
            return False
        if not said:
            log(f"another drain is running (pid {pid}) — waiting for it to finish")
            said = True
        time.sleep(60)


def release_lock():
    lock = Path(OUTDIR) / ".drain.lock"
    try:
        if lock.exists() and lock.read_text().strip() == str(os.getpid()):
            lock.unlink()
    except OSError:
        pass


# ── probing ─────────────────────────────────────────────────────────────────
def vinfo(src):
    d = run([FFPROBE, "-v", "error", "-select_streams", "v:0", "-show_entries",
             "stream=codec_name,width,height,color_transfer,r_frame_rate,nb_frames",
             "-show_entries", "format=duration", "-of", "json", src]).stdout
    j = json.loads(d or "{}")
    s = (j.get("streams") or [{}])[0]
    fr = s.get("r_frame_rate", "24000/1001")
    return {"codec": s.get("codec_name", ""), "w": int(s.get("width") or 0),
            "h": int(s.get("height") or 0), "trc": s.get("color_transfer", ""),
            "fps": fr, "dur": float((j.get("format") or {}).get("duration") or 0)}


def has_dv_rpu(src):
    """True if the first frame carries a single-layer DV RPU (what dv_probe keys on)."""
    d = run([FFPROBE, "-loglevel", "error", "-select_streams", "v:0",
             "-read_intervals", "%+#1", "-show_frames", "-print_format", "json",
             src]).stdout
    for fr in json.loads(d or "{}").get("frames", []):
        for sd in fr.get("side_data_list", []):
            if sd.get("side_data_type") == "Dolby Vision Metadata" \
                    and sd.get("nlq_method_idc_name", "none") == "none":
                return True
    return False


def is_dual_layer(src):
    """True if the source carries a DV enhancement layer — i.e. profile 7.

    Deliberately NOT has_dv_rpu(): that reads the first frame's RPU and keys on a
    profile-8 field, so it answers False for every P7 title. This reads the
    stream's DOVI configuration record instead, which is the authority on layers.
    """
    d = run([FFPROBE, "-v", "error", "-select_streams", "v:0",
             "-show_entries", "stream_side_data=el_present_flag",
             "-of", "json", src]).stdout
    for st in (json.loads(d or "{}").get("streams") or []):
        for sd in st.get("side_data_list", []):
            if sd.get("el_present_flag"):
                return True
    return False


def duration(src):
    """Container duration in seconds — header only, NO decode, instant. (Frame-exact
    counting via -count_frames decodes the whole movie ~= as slow as the encode, so
    we integrity-check by duration instead; same fps in/out ⇒ same-duration ⇒ same
    frame count, and dovi_tool inject-rpu already fails loudly on a frame mismatch.)"""
    d = run([FFPROBE, "-v", "error", "-show_entries", "format=duration",
             "-of", "csv=p=0", src]).stdout
    m = re.search(r"[\d.]+", d)
    return float(m.group()) if m else 0.0


def preflight_lane(src_path):
    # #38: a source NOT under /mnt has no hub URL — the old split returned the whole
    # absolute path and built a silently-wrong URL that misclassified the title.
    # Make it an explicit error instead.
    # (The old "must be under /mnt" guard is gone: it existed only because this
    # built a hub URL, and a URL cannot address a file the hub does not serve.
    # The direct call has no such limit — and that guard was what made a scratch
    # outside /mnt fatal, which is the whole reason the scratch was symlinked
    # into /mnt in the first place, which is what then broke realpath.)
    # Ask the lane authority DIRECTLY rather than over HTTP.
    #
    # ⚠ The HTTP path cannot see the scratch at all. /mnt/Movies7/_dvnorm-scratch
    # is a symlink onto the NVMe, and the hub's _fold_src resolves every request
    # with realpath() and rejects anything landing outside its root — correctly,
    # that is the traversal guard. So every finished encode was asked about via a
    # URL that 404'd, and "verify failed" was recorded against six titles across
    # two days (Ghost in the Shell, Raiders, Flight, Contagion — several twice),
    # each a GOOD conversion thrown away, ~8h of GPU. Putting the scratch under
    # /mnt by symlink satisfied the string test in this function while still
    # failing the realpath test in the hub.
    #
    # cast_lane_decision IS the authority the endpoint wraps — codec_cast imports
    # codec_serve the same way — so calling it needs no hub, no URL, no /mnt at
    # all, and gives the identical verdict for a file anywhere on disk.
    try:
        import codec_serve as hublib
        # The GPU lanes (DV, HDR10) need NVENC, and the hub module decided that
        # with ONE 15 s test encode at import. If that probe lost to a busy GPU
        # (cast or party lanes holding sessions), every title answers "sdr" —
        # verify then discarded and skip-listed a good encode. Probe again, and
        # if NVENC is still missing say so as an infrastructure ERR (never
        # recorded against the title) rather than a lane.
        if not hublib.NVENC:
            hublib.NVENC = hublib.have_nvenc()
            if not hublib.NVENC:
                return "ERR:NVENC unavailable in this process — every lane would read sdr"
        dec = hublib.cast_lane_decision(src_path, aidx=0)
        return dec.get("lane")
    except Exception as e:
        # Fall back to the hub only if the direct call is unavailable.
        try:
            src = HUB + "/" + urllib.parse.quote(src_path.split("/mnt/", 1)[-1])
            u = HUB + "/hls/preflight?src=" + urllib.parse.quote(src, safe="") + "&aidx=0"
            with urllib.request.urlopen(u, timeout=120) as r:
                return json.load(r).get("lane")
        except Exception as e2:
            return f"ERR:{e} / {e2}"


def out_path(src):
    stem = Path(src).stem
    return str(Path(OUTDIR) / (stem + ".dvnorm.mkv"))


def _src_marker(out):
    """Absolute source path a staging output was produced from, or '' if unknown.
    Guards the idempotent-skip against two sources sharing a filename stem."""
    try:
        return Path(out + ".src").read_text().strip()
    except OSError:
        return ""


# ── candidate detection ─────────────────────────────────────────────────────
# ── failure memory / preflight-skip ──────────────────────────────────────────
# A title that FAILS verify (e.g. 4K60 DV the cast path won't accept — the base
# layer stays HDR10 no matter how clean the GOP is) would otherwise be re-queued
# and burn ~3h re-encoding to fail again on every scan. Remember such files,
# keyed by path + size + mtime, and skip them until the file changes (a
# re-download resets the fingerprint) or --retry-failed is passed. Only a
# VERIFY-FAILED is recorded — a generic ERROR can be transient/a bug, so those
# stay retryable.
SKIPLIST = os.path.join(OUTDIR, ".norm-skip.json")
# written by ~/baytools/codec-idle-chain.sh while it waits to start jobs
CHAIN_STATE = os.path.expanduser("~/.cache/codec/idle-chain.state")


def _sig(src):
    """(size, mtime) fingerprint so a re-downloaded/replaced file isn't skipped."""
    try:
        st = os.stat(src)
        return [st.st_size, int(st.st_mtime)]
    except OSError:
        return None


def _load_skips():
    try:
        with open(SKIPLIST) as f:
            return json.load(f)
    except Exception:
        return {}


def is_skipped(src):
    """True if THIS exact file (same size+mtime) previously failed verify."""
    e = _load_skips().get(os.path.abspath(src))
    return bool(e and e.get("sig") == _sig(src))


def mark_skipped(src, reason):
    d = _load_skips()
    d[os.path.abspath(src)] = {"sig": _sig(src), "reason": reason,
                               "when": time.strftime("%Y-%m-%dT%H:%M:%S")}
    try:
        os.makedirs(OUTDIR, exist_ok=True)
        tmp = SKIPLIST + ".tmp"
        with open(tmp, "w") as f:
            json.dump(d, f, indent=1)
        os.replace(tmp, SKIPLIST)
    except OSError as e:
        log(f"WARN could not record skip for {Path(src).name}: {e}")


def clear_skip(src):
    """Drop a file's skip record (a later success, or --retry-failed clearing)."""
    d = _load_skips()
    if d.pop(os.path.abspath(src), None) is not None:
        try:
            with open(SKIPLIST, "w") as f:
                json.dump(d, f, indent=1)
        except OSError:
            pass


def _drive_root(p):
    """The mount root of a path (/mnt/Movies/... -> /mnt/Movies) so the trash lands
    on the SAME drive as the original (fast, atomic move; not a cross-drive copy)."""
    parts = Path(p).resolve().parts
    if len(parts) >= 3 and parts[1] == "mnt":
        return Path("/mnt") / parts[2]
    return Path(p).parent


def library_roots(kind="movies"):
    """The directories codec ACTUALLY scans, from its own config — the only valid
    places to put a title. Deliberately not ROOTS: ROOTS holds scan roots like
    /mnt/Movies, but codec indexes '/mnt/Movies/UHD Media', so a folder dropped at
    /mnt/Movies/<title> would be normalized and then invisible in the app."""
    try:
        cfg = json.loads(CODEC_CONFIG.read_text())
    except (OSError, ValueError):
        return []
    return [r["path"] for r in cfg.get("roots", [])
            if r.get("kind") == kind and os.path.isdir(r.get("path", ""))]


def _bps(bitrate):
    """'40M' -> 40_000_000. Returns 0 if unparseable."""
    m = re.fullmatch(r"(\d+(?:\.\d+)?)\s*([KMG]?)", str(bitrate).strip(), re.I)
    if not m:
        return 0
    return int(float(m.group(1)) * {"": 1, "K": 10**3, "M": 10**6, "G": 10**9}[m.group(2).upper()])


def _video_bps(src):
    """Measured bitrate of the source's video stream, or 0 if unreported."""
    try:
        out = run([FFPROBE, "-v", "error", "-select_streams", "v:0", "-show_entries",
                   "stream=bit_rate:stream_tags=BPS", "-of", "json", src]).stdout
        st = json.loads(out)["streams"][0]
        return int(st.get("bit_rate") or st.get("tags", {}).get("BPS") or 0)
    except Exception:
        return 0


def _copied_stream_bps(src):
    """Total bitrate of the tracks a normalize COPIES — audio and subtitles.

    The video is re-encoded to a bitrate we choose, so the only unknown left in
    the output size is what rides along untouched. Measuring it turns the space
    check from a multiple of the source into arithmetic. Returns 0 when the
    container does not report per-stream rates, which is the caller's signal to
    fall back to the old source-anchored guess rather than under-estimate."""
    try:
        out = run([FFPROBE, "-v", "error", "-show_streams", "-of", "json", src]).stdout
        streams = json.loads(out).get("streams", [])
    except Exception:
        return 0
    total = 0
    for st in streams:
        if st.get("codec_type") not in ("audio", "subtitle"):
            continue
        br = st.get("bit_rate") or st.get("tags", {}).get("BPS") or 0
        try:
            total += int(br)
        except (TypeError, ValueError):
            pass
    return total


def est_output_size(src, bitrate):
    """Conservative estimate of the normalized file's size, for space checks.

    The base video is re-encoded at a FIXED bitrate and the audio/subtitle tracks are
    copied losslessly, so the floor is (bitrate x duration) and the source size is the
    other reference point. Takes the larger and adds a wide margin: the DV outputs seen
    so far run ~1.35x their source, and a space check that guesses LOW is exactly the
    bug this exists to prevent. Over-estimating only ever defers a title early, which
    is far cheaper than discovering it after two hours of nvenc."""
    try:
        src_sz = os.path.getsize(src)
    except OSError:
        return 0
    dur, vbps = duration(src) or 0, _bps(bitrate)
    # ⚠ Under --cap-to-source the encode is clamped to the source's OWN measured
    # video bitrate "so the output cannot grow" — so the fixed target says
    # nothing about the result, and using it here is not conservative, it is
    # wrong. It refused to place Flight (a 5.4G, ~6 Mbps title) on an estimate
    # of 56G, because 2h x 40 Mbps x 1.35 is what the arithmetic produced; the
    # real output would have been about 7G and fitted on any branch. Five titles
    # sat "unplaceable (no room in the library)" that way while the drain
    # relaunched hourly and rescanned the whole library to reach the same wrong
    # conclusion. The pool was never the constraint.
    # A profile-7 conversion DISCARDS the enhancement layer, so its output is
    # strictly SMALLER than the source — the base layer alone. Applying the
    # growth margin to it asked for space the result cannot use and refused the
    # one operation in this pipeline that GIVES space back: Ghost in the Shell
    # (53.5G) was estimated at 72G and Raiders (48.0G) at 69G, so both sat
    # "unplaceable" while being the titles whose conversion would free ~20G
    # each. The source size is already a strict upper bound here.
    if is_dual_layer(src):
        # The source size IS a true ceiling here — discarding the enhancement
        # layer cannot make the file grow — but a very loose one, because the
        # base layer is also RE-ENCODED at the target bitrate. For Legends of
        # the Fall it was 2.0x the truth: 70G source, 35.2G output, and that
        # gap is what demanded 80G of space for a 35G file and left the title
        # refused for weeks. Same arithmetic as the profile-8 path — the target
        # (clamped to the source's own video bitrate under --cap-to-source)
        # plus the streams copied untouched — with src_sz kept as a hard cap.
        # Predicted Legends at 35.1G against an actual 35.2G.
        vb = _video_bps(src)
        tgt = min(vbps, vb) if (CAP_TO_SOURCE and vb) else vbps
        abps = _copied_stream_bps(src)
        if dur and abps and tgt:
            return int(min(src_sz, (dur * tgt / 8 + dur * abps / 8) * 1.20))
        return src_sz
    if CAP_TO_SOURCE:
        # ⚠ THIRD shape of this mistake, and the most self-contradictory:
        # --cap-to-source clamps the encode to the source's OWN measured video
        # bitrate precisely so the output cannot grow — and this then asked for
        # 1.35x the source. It refused Ghost in the Shell 78G for a file that
        # measures out at 37G, twice in one night, while 52G sat free on its
        # drive. The comment above already says the fixed target tells you
        # nothing here; the answer is the same arithmetic as everywhere else,
        # using whichever bitrate the encode will actually run at.
        vb = _video_bps(src)
        tgt = min(vbps, vb) if vb else vbps
        abps = _copied_stream_bps(src)
        if dur and abps and tgt:
            return int(min(src_sz, (dur * tgt / 8 + dur * abps / 8) * 1.20))
        return int(src_sz * 1.35)
    # The LAST branch still anchored on the source's size, and the same mistake
    # in a third shape. max(src_sz, ...) assumes the output tracks how big the
    # input was; it does not. The video is re-encoded to a bitrate we pick and
    # everything else is copied, so the size is arithmetic: (target + copied) x
    # duration. For a big remux being re-encoded DOWN the source term dominates
    # and invents a shortage out of nothing — Legends of the Fall (70G source,
    # ~45G real output) was asked to find 94G, Raiders (51G, ~36G) 70G. Both sat
    # unplaceable for want of space their own conversion would have GIVEN BACK.
    # Measured against the 27 completed normalizes with per-stream rates: this
    # never under-predicts, median over-shoot 1.59x, and the tightest title
    # still cleared by 19%. Falls back when the container reports no rates.
    abps = _copied_stream_bps(src)
    if dur and abps:
        return int((dur * vbps / 8 + dur * abps / 8) * 1.20)
    return int(max(src_sz, dur * vbps / 8) * 1.35)


def _free(path):
    try:
        return shutil.disk_usage(str(path)).free
    except OSError:
        return 0


def placement_dir(src, need):
    """Where the finished file should land.

    Normally the original's own folder: same path, same DB row, atomic same-drive
    rename. But placement stages the output NEXT TO the original before trashing it,
    and the trash lives on that same drive — so the original's space is never freed and
    a full drive can never accept a bigger file, whatever the ordering. When the source
    drive can't take it, fall back to the library root with the most free space; the
    title keeps its folder and filename and stays in codec's scan, it just lives on a
    different drive.

    Returns (dir, relocating) — or (None, False) if nowhere has room."""
    own = Path(src).parent
    # a small floor on the in-place path too: "it fits" should not mean driving a
    # drive to literally zero free, which is how the legacy drives got fragile.
    if _free(own) >= need + IN_PLACE_RESERVE:
        return own, False
    roots = library_roots("movies")
    # Relocation re-homes a FILM under another drive's movies root. A file that
    # isn't under a movies root (a TV episode — the drive-level ROOTS reach
    # /mnt/Movies/TV) would land there as a fake film named "Season 01" and
    # vanish from its show. Such a file is placed in place or not at all.
    if not any(str(Path(src)).startswith(r.rstrip("/") + "/") for r in roots):
        return None, False
    folder = Path(src).stem if str(own) in roots else own.name
    alts = [r for r in roots
            if _drive_root(r) != _drive_root(own) and _free(r) >= need + PLACE_RESERVE]
    if not alts:
        return None, False
    return Path(max(alts, key=_free)) / folder, True


def _carry_caches(old_path, new_path, old_stat):
    """Re-key the path|size|mtime caches onto the converted file, and move the
    media_state row if the title changed path.

    ⚠ Every normalize orphaned these, even in place: the path is kept but the
    crop-timeline and fingerprint keys also hash size and mtime, which a
    re-encode changes. So every converted film lost its adaptive-zoom data until
    the next crop sweep re-warmed it. Carrying is VALID — a re-encode changes
    neither the frames' letterboxing nor the audio — and codec_p7_flatten has
    done the same since the start. A relocation also changes the path, which
    orphans media_state (resume position, watch count) on top.
    """
    import hashlib, sqlite3
    carried = []
    try:
        ns = os.stat(new_path)
    except OSError:
        return carried
    def k(p, st, extra=""):
        return hashlib.sha1(f"{p}|{st.st_size}|{int(st.st_mtime)}{extra}".encode()).hexdigest()
    try:
        import codec_intro
        fpw = f"|{codec_intro.WINDOW_S}"
    except Exception:
        fpw = "|480"
    for sub, ext, extra, what in (("croptl", ".json", "", "crop timeline"),
                                  ("fp", ".npy", fpw, "intro fingerprint")):
        try:
            d = Path.home() / ".cache/codec" / sub
            o = d / (k(old_path, old_stat, extra) + ext)
            if o.exists():
                shutil.copy2(o, d / (k(new_path, ns, extra) + ext))
                carried.append(what)
        except OSError:
            pass
    rel_old = os.path.relpath(str(old_path), "/mnt")
    rel_new = os.path.relpath(str(new_path), "/mnt")
    db = codec_paths.DB
    if rel_old != rel_new and db.exists():
        try:
            c = sqlite3.connect(str(db))
            # OR REPLACE: a row can already exist at the new path if the scanner
            # indexed the file mid-copy. The OLD row holds the real history, so
            # it wins; a bare UPDATE failed on the UNIQUE path constraint.
            n = c.execute("UPDATE OR REPLACE media_state SET path=? WHERE path=?",
                          (rel_new, rel_old)).rowcount
            c.commit(); c.close()
            if n:
                carried.append("resume state")
        except sqlite3.Error:
            pass
    return carried


def place_normalized(src, out, dest_dir=None):
    """Swap the verified DV output IN for the original, keeping the library path/name
    (so codec serves DV at the same path, DB row unchanged). The original is moved to a
    `_dvnorm-trash/` — REVERSIBLE, never hard-deleted. Ordering guarantees the
    original is only trashed once the DV file is safely staged beside it; on any failure
    the original is restored. Returns the trash path, or raises.

    `dest_dir` (from placement_dir) relocates the title to another library root, for
    when the original's own drive cannot hold the finished file. Folder name and
    filename are preserved, and the original is trashed on its OWN drive — a rename,
    never a copy. The full drive gets its space back when codec-trash-gc reclaims it
    (codec_trash_gc indexes every root by filename, so it finds the replacement on
    the other drive)."""
    orig, newf = Path(src), Path(out)
    ost = orig.stat()          # the caches are keyed on THIS stat
    dest = Path(dest_dir) if dest_dir else orig.parent
    relocating = dest.resolve() != orig.parent.resolve()
    # ⚠ The ORIGINAL's drive, not the destination's. Keyed on dest, a relocation
    # moved the whole original ACROSS drives into the destination's trash — a
    # full-size copy placement headroom never reserved. Monkey Man ran out 12.2G
    # in (2026-09-18): the library was left with a DUPLICATE, a partial sat in
    # trash, and the title was re-encoded from scratch three hours later. For an
    # in-place placement dest IS the original's drive, which is why only
    # relocation ever hit it. On the original's own drive this is a rename:
    # instant, costs no space, and cannot fail halfway.
    trash = _drive_root(orig) / "_dvnorm-trash"
    trash.mkdir(exist_ok=True)
    tdst = trash / orig.name
    n = 1
    while tdst.exists():
        tdst = trash / f"{orig.stem}.dup{n}{orig.suffix}"
        n += 1

    if not relocating:
        staging = orig.with_name(orig.name + ".dvplacing")
        # A partial from a placement that was cut off (the retry path above).
        staging.unlink(missing_ok=True)
        nsz = newf.stat().st_size
        try:
            # 1. bring the DV file next to the original (rename if same fs, else copy+delete)
            shutil.move(str(newf), str(staging))
            if staging.stat().st_size != nsz:
                raise RuntimeError(f"staged DV file truncated in transit "
                                   f"({staging.stat().st_size} vs {nsz}B)")
            # On disk before it becomes the library's only DV copy (the scratch
            # output is already gone) and before the original moves.
            _fsync(staging)
            # 2. original -> trash (same drive => fast + fully reversible)
            os.replace(orig, tdst)
            # 3. staged DV -> the original's EXACT path (same dir => atomic rename)
            os.replace(staging, orig)
            c = _carry_caches(orig, orig, ost)
            if c:
                log(f"    carried {', '.join(c)}")
            return tdst
        except Exception:
            # never leave the library slot empty: if the original was trashed but the
            # place failed, put it back.
            try:
                if not orig.exists() and tdst.exists():
                    os.replace(tdst, orig)
            except Exception:
                pass
            staging.unlink(missing_ok=True)
            raise

    # ── relocating: the source drive is too full to stage the output ──────────
    # Same invariant as above — a complete copy of the title exists at every instant,
    # and the original is not moved until the DV file is sitting at its new home.
    dest.mkdir(parents=True, exist_ok=True)
    final = dest / orig.name
    if final.exists():
        raise RuntimeError(f"destination already holds a file: {final}")
    staging = dest / (orig.name + ".dvplacing")
    staging.unlink(missing_ok=True)          # a cut-off earlier placement
    nsz = newf.stat().st_size
    try:
        # 1. DV output -> the new drive (cross-device: real copy, then unlink)
        shutil.move(str(newf), str(staging))
        if staging.stat().st_size != nsz:
            raise RuntimeError("staged DV file truncated in transit")
        _fsync(staging)
        # 2. into the library slot (same fs as staging => atomic rename)
        os.replace(staging, final)
        # 3. original -> trash on its OWN drive — a same-filesystem rename, so it
        #    is atomic and needs no free space. Still last: the DV copy is already
        #    in its slot before the original moves at all.
        os.replace(orig, tdst)
        c = _carry_caches(orig, final, ost)
        if c:
            log(f"    carried {', '.join(c)}")
        return tdst
    except Exception as e:
        staging.unlink(missing_ok=True)
        try:
            if not orig.exists() and tdst.exists():
                os.replace(tdst, orig)
        except Exception:
            pass
        if final.exists() and orig.exists():
            # both copies survive — a duplicate is recoverable, data loss is not.
            raise RuntimeError(
                f"{e}; DV copy left at {final} while the original is still at {orig} "
                f"— library shows a DUPLICATE until one is removed by hand") from e
        raise


def _file_mbps(src, inf=None):
    """The source's VIDEO bitrate in Mbps — the only thing comparable to --bitrate.

    ⚠ Must NOT be the container total. A 4K remux carries 8-12 Mbps of TrueHD or
    DTS-HD MA, which this pipeline copies through untouched; comparing a 42 Mbps
    total against a 40M VIDEO target says "shrink me" about a title whose video is
    really 32 Mbps, and the re-encode then makes it BIGGER. Measured on A Fistful
    of Dollars: 42.1 total, 32.2 video.

    Uses the video stream's declared bit_rate when the container has one, else
    total minus whatever the audio tracks declare. 0.0 when unknown — a zero can
    never satisfy an "over N" test, so an unmeasurable file is skipped rather than
    swept in on a bad guess."""
    try:
        dur = (inf or vinfo(src))["dur"]
        if dur <= 0:
            return 0.0
        d = run([FFPROBE, "-v", "error", "-show_entries",
                 "stream=codec_type,bit_rate", "-of", "json", src]).stdout
        streams = (json.loads(d or "{}").get("streams") or [])
        for st in streams:
            if st.get("codec_type") == "video" and st.get("bit_rate"):
                return int(st["bit_rate"]) / 1e6
        abits = sum(int(st["bit_rate"]) for st in streams
                    if st.get("codec_type") == "audio" and st.get("bit_rate"))
        total = os.path.getsize(src) * 8 / dur
        return max(0.0, (total - abits) / 1e6)
    except (OSError, ValueError, KeyError):
        return 0.0


def _target_mbps(bitrate):
    """'40M' -> 40.0. The encoder wants ffmpeg's suffix form; selection wants a
    number, and the two must be compared or the sweep can re-encode UPWARD."""
    m = re.match(r"\s*([\d.]+)\s*([kKmM]?)", str(bitrate))
    if not m:
        return 0.0
    v = float(m.group(1))
    return v / 1000.0 if m.group(2) in ("k", "K") else v


def find_candidates(roots=None, over_bitrate=None, include_p7=False, p7_only=False):
    """DV-flagged HDR titles that currently fall to HDR10 (irregular GOP).

    With over_bitrate set the selection changes purpose: instead of titles that
    FAIL to cast as DV, it picks single-layer DV titles that cast perfectly well
    but are fatter than they need to be — the shrink sweep. The lane check is
    skipped there (these already serve as DV; that is the point) and the bitrate
    gate replaces it.

    Profile-7 (dual-layer) titles are rejected by default in both modes, because
    has_dv_rpu() is a profile-8 test. include_p7 admits them: normalize() converts
    P7->P8.1 up front, which is what lets them be re-encoded AND gains them real DV
    casting. Opt-in because each is a multi-hour encode of a 50-70G source.
    """
    cands = []
    for root in (roots or ROOTS):
        for dp, dns, fns in os.walk(root):
            dns[:] = [d for d in dns if not _skip_dir(d)]
            for fn in fns:
                if not fn.lower().endswith((".mkv", ".mp4", ".m4v")):
                    continue
                src = os.path.join(dp, fn)
                inf = vinfo(src)
                if inf["trc"] not in HDR_TRC or inf["codec"] != "hevc":
                    continue
                # A release folder's Sample.mkv is real DV HEVC and sails past
                # the MIN_MAIN_BYTES floor (Carry On's is 363 MB), so size alone
                # cannot tell it from a film — but 117 seconds can. Converting
                # one wastes a full nvenc run and, worse, the placement step
                # would drop it into the library as a title.
                if 0 < inf["dur"] < MIN_FILM_SECONDS:
                    continue
                if p7_only and not is_dual_layer(src):
                    # The P7 job and the P8 drain want different bitrates, so they
                    # must select disjoint sets or every P8 straggler gets done
                    # twice — once at each target.
                    continue
                if not has_dv_rpu(src):
                    # P7 is invisible to has_dv_rpu (profile-8 test). It IS
                    # normalizable — via the convert step in normalize() — but
                    # only opt-in: each one is a multi-hour encode of a 50-70G
                    # source, and the result wants an eye on the TV before the
                    # drain starts doing it unattended.
                    if not (include_p7 and is_dual_layer(src)):
                        continue
                # #38: this title is ALREADY confirmed DV (has_dv_rpu above), so an
                # ERR here (hub unreachable / non-/mnt URL) is a SCAN FAILURE, not
                # "not a candidate". Silently skipping it dropped DV titles that
                # needed normalizing — abort loudly so an incomplete scan can't pass
                # as a clean one.
                if over_bitrate is not None:
                    # Shrink sweep: already-DV titles, selected on fat alone. No
                    # preflight — it costs a hub round-trip per title to answer a
                    # question this mode does not ask.
                    if _file_mbps(src, inf) > over_bitrate:
                        cands.append(src)
                    continue
                lane = preflight_lane(src)
                if str(lane).startswith("ERR:"):
                    raise SystemExit(
                        f"preflight failed for a CONFIRMED DV title — cannot classify:\n"
                        f"  {src}\n  {lane}\n"
                        f"Aborting so a DV title isn't silently skipped. Check the hub "
                        f"({HUB}) is reachable, then re-run.")
                if lane == "hdr10":      # DV present but not served as DV
                    cands.append(src)
    return sorted(cands)


# ── the pipeline ────────────────────────────────────────────────────────────
def clean_orphan_work():
    """Reclaim intermediates from runs that died mid-encode (power loss, kill).
    Work dirs are named '..._<PID>'; a dir whose PID is no longer alive is orphaned
    junk (~75GB). Only removes DEAD-PID dirs, so a concurrently-running drain's own
    work is never touched. Called only on real work runs, never on --status/--list."""
    wd = Path(OUTDIR) / ".work"
    if not wd.exists():
        return
    for d in wd.iterdir():
        m = re.search(r"_(\d+)$", d.name)
        alive = m and Path(f"/proc/{m.group(1)}").exists()
        if not alive:
            log(f"cleanup: reclaiming orphaned work dir {d.name}")
            shutil.rmtree(d, ignore_errors=True)


def normalize(src, bitrate, keyint):
    out = out_path(src)
    partial = out + ".partial"
    # idempotent: already normalized + verified → skip. The .src marker guards a
    # stem collision (two sources → same staging name): only skip when the existing
    # output was produced from THIS source, never inherit another title's output.
    if (Path(out).exists() and _src_marker(out) == os.path.abspath(src)
            and preflight_lane(out) == "dv"):
        log(f"SKIP (already done): {Path(src).name}")
        return "skip"
    inf = vinfo(src)
    if inf["h"] == 0:
        log(f"FAIL probe: {Path(src).name}")
        return "fail"
    # fps parsed defensively: ffprobe emits '0/0' for streams whose rate it can't
    # determine — a bad title must fail on its own, never crash the whole drain.
    try:
        if "/" in inf["fps"]:
            num, den = (int(x) for x in inf["fps"].split("/"))
        else:
            num, den = int(float(inf["fps"])), 1
        fps = num / den if den else 0.0
        if fps <= 0:
            raise ValueError(f"bad frame rate {inf['fps']!r}")
    except (ValueError, ZeroDivisionError, TypeError) as e:
        log(f"FAIL fps {Path(src).name}: {e} — skipped, drain continues")
        return "fail"
    gop_sec = keyint / fps
    mbps = int(re.sub(r"\D", "", bitrate) or 0)   # canonical '<int>M' (validated in main)
    maxrate = f"{mbps * 3 // 2}M"
    bufsize = f"{mbps * 2}M"
    work = Path(OUTDIR) / ".work" / (Path(src).stem[:40] + "_" + str(os.getpid()))
    work.mkdir(parents=True, exist_ok=True)
    es, rpu, base, base_dv = (str(work / n) for n in
                              ("clip.hevc", "rpu.bin", "base.hevc", "base_dv.hevc"))
    t0 = time.time()
    try:
        log(f"[1/6] extract video ES … {Path(src).name}")
        r = run([FFMPEG, "-y", "-v", "error", "-i", src, "-map", "0:v:0",
                 "-c:v", "copy", "-bsf:v", "hevc_mp4toannexb", "-f", "hevc", es])
        if r.returncode:
            raise RuntimeError("ES extract: " + r.stderr[-300:])

        # P7 sources are dual-layer: BL and EL interleaved in one stream, and the
        # EL is a codec-unusable minimal-enhancement stub (measured: dropping it
        # frees 0.0%). Converting to single-layer 8.1 first is what makes the rest
        # of this pipeline — and DV casting — possible at all for these titles.
        # The space comes from the re-encode below, never from the EL.
        if is_dual_layer(src):
            es81 = str(work / "clip_p81.hevc")
            log("[1b/6] DV profile 7 → 8.1 (single-layer, EL discarded) …")
            r = run([DOVI, "-m", "5", "convert", "--discard", "-i", es, "-o", es81])
            if r.returncode or not Path(es81).exists():
                raise RuntimeError("P7→P8.1 convert: " + r.stderr[-300:])
            os.replace(es81, es)   # frees the dual-layer ES immediately

        # The only honest measure of the source's video bitrate: the extracted
        # elementary stream itself. Container arithmetic cannot see TrueHD/DTS-HD
        # MA tracks that declare no bit_rate, so a 4K remux reads ~10 Mbps fatter
        # than its video really is — and selection would then hand us a title the
        # re-encode makes BIGGER. Here the bytes are on disk and free to weigh.
        _dur = duration(src)
        if _dur > 0:
            es_mbps = os.path.getsize(es) * 8 / _dur / 1e6
            if es_mbps < mbps and CAP_TO_SOURCE:
                # The ES is the only honest measure, and it is on disk by now —
                # so clamp here rather than guessing at selection time from a
                # container total that cannot see undeclared lossless audio.
                mbps = max(1, int(es_mbps))
                bitrate = f"{mbps}M"
                maxrate, bufsize = f"{mbps * 3 // 2}M", f"{mbps * 2}M"
                log(f"  capped to source: video measures {es_mbps:.1f} Mbps, "
                    f"encoding at {bitrate} so the output cannot grow")
            elif es_mbps < mbps:
                log(f"  ⚠ measured video is {es_mbps:.1f} Mbps, target {mbps}M — "
                    f"this title WILL GET BIGGER. Worth it for a DV/GOP fix, "
                    f"never for space.")
            else:
                log(f"  video measures {es_mbps:.1f} Mbps → {mbps}M "
                    f"(~{100 * (1 - mbps / es_mbps):.0f}% off the video stream)")

        log("[2/6] extract DV RPU …")
        r = run([DOVI, "extract-rpu", "-i", es, "-o", rpu])
        if r.returncode or not Path(rpu).exists():
            raise RuntimeError("extract-rpu: " + r.stderr[-300:])

        log(f"[3/6] nvenc base: fixed GOP (keyint={keyint}, ~{gop_sec:.3f}s), "
            f"{bitrate}, Main10 …")
        r = run([FFMPEG, "-y", "-v", "error", "-i", es, "-an",
                 "-c:v", "hevc_nvenc", "-preset", "p7", "-tune", "hq",
                 "-rc", "vbr", "-b:v", bitrate, "-maxrate", maxrate,
                 "-bufsize", bufsize, "-pix_fmt", "p010le", "-profile:v", "main10",
                 "-g", str(keyint), "-keyint_min", str(keyint), "-forced-idr", "1",
                 "-force_key_frames", f"expr:gte(t,n_forced*{gop_sec:.5f})",
                 "-color_primaries", "bt2020", "-color_trc", "smpte2084",
                 "-colorspace", "bt2020nc", "-f", "hevc", base])
        if r.returncode:
            raise RuntimeError("nvenc: " + r.stderr[-300:])

        log("[4/6] inject DV RPU …")
        r = run([DOVI, "inject-rpu", "-i", base, "--rpu-in", rpu, "-o", base_dv])
        if r.returncode or not Path(base_dv).exists():
            raise RuntimeError("inject-rpu: " + r.stderr[-300:])

        log("[5/6] mux DV video + original audio/subs (lossless copy) …")
        # ATOMIC OUTPUT: mux to a .partial name, and only rename to the final name
        # AFTER verification passes. So a power loss can never leave a truncated file
        # under the final name that a later resume mistakes for done.
        partial = out + ".partial"
        Path(partial).unlink(missing_ok=True)
        r = run([MKVMERGE, "-o", partial, "--default-duration", f"0:{num}/{den}p",
                 base_dv, "--no-video", src])
        if r.returncode >= 2 or not Path(partial).exists():   # mkvmerge rc 1 = warnings
            raise RuntimeError("mkvmerge: " + (r.stdout + r.stderr)[-300:])

        log("[6/6] verify (duration + dv_probe + DV metadata) …")
        d_src, d_out = duration(src), duration(partial)
        dur_ok = d_src > 0 and abs(d_src - d_out) < 1.0   # truncation would be huge
        lane = preflight_lane(partial)
        dvok = has_dv_rpu(partial)
        ok = dur_ok and (lane == "dv") and dvok
        dt = int(time.time() - t0)
        if ok:
            os.replace(partial, out)   # atomic rename — final name = complete + verified
            try:                       # remember which source this output belongs to
                Path(out + ".src").write_text(os.path.abspath(src))
            except OSError:
                pass
            sz = Path(out).stat().st_size / 1e9
            clear_skip(src)            # a prior failure is resolved — allow future runs
            log(f"✅ DONE {Path(src).name}  ({dt}s, {sz:.1f}GB, lane=dv, "
                f"dur {d_out:.1f}s≈{d_src:.1f}s, audio copied)")
            return "ok"
        Path(partial).unlink(missing_ok=True)
        # An INFRASTRUCTURE failure must not be recorded against the TITLE.
        # "not under /mnt" means the hub could not be asked about this file at
        # all, so nothing was learned about the conversion — which may well be
        # perfect (dur matched, dv=True). Skip-listing there is what turned one
        # misconfiguration into four permanently-excluded titles on 2026-09-15:
        # Ghost in the Shell and Raiders, each destroyed twice, ~6h of GPU.
        # Fail the run, keep the title eligible, and say why.
        # ⚠ ANY "ERR:" is the hub failing to answer, not the file failing. The
        # first version of this guard tested one exact string, and the very next
        # infrastructure failure walked straight through it: on 2026-09-16 the
        # hub returned "ERR:HTTP Error 404: Not Found" — because folders were
        # being renamed underneath it — and Flight and Contagion were discarded
        # and skip-listed with `dur` matching EXACTLY and dv=True on both. Two
        # more good encodes destroyed by the same shape of bug, one day apart.
        # The lane result only ever means something when it is a LANE.
        if isinstance(lane, str) and lane.startswith("ERR:"):
            log(f"❌ CANNOT VERIFY {Path(src).name} — the hub could not be "
                f"asked which lane this output would serve on ({lane}). Nothing "
                f"was learned ABOUT THE FILE, and dur/dv checks above may well "
                f"have passed. NOT skip-listed; fix the hub side and re-run. "
                f"(OUTDIR={OUTDIR})")
            return "fail"
        # Remember it so we don't re-encode for hours to fail again next scan. The
        # usual cause is a source the DV cast path can't accept (e.g. 4K 60fps),
        # which a GOP re-encode can't fix; --retry-failed forces another attempt.
        mark_skipped(src, f"verify-failed (lane={lane}, dv={dvok})")
        log(f"❌ VERIFY FAILED {Path(src).name} (dur {d_out:.1f} vs {d_src:.1f}, "
            f"lane={lane}, dv={dvok}) — output discarded, original untouched (skip-listed)")
        return "fail"
    except Exception as e:
        # Only ever discard THIS run's in-progress partial — never `out`, which is
        # only present when a PRIOR run already produced a verified-good output.
        Path(partial).unlink(missing_ok=True)
        log(f"❌ ERROR {Path(src).name}: {e} — output discarded, original untouched")
        return "fail"
    finally:
        shutil.rmtree(work, ignore_errors=True)


STAGE_NAMES = {1: "extracting video ES", 2: "extracting DV RPU",
               3: "nvenc base encode", 4: "injecting DV RPU",
               5: "muxing (lossless audio)", 6: "verifying"}


HERMES = str(Path.home() / ".local/bin/hermes")


# timestamp and/or status marker that can precede a filename in the log
_LOGPFX = re.compile(
    r"^(?:\d\d:\d\d:\d\d\s+)?"
    r"(?:\[(?:todo|skip)\]|\[\d+/\d+\]|✅\s*DONE|❌\s*(?:VERIFY FAILED|ERROR)"
    r"|↪|⚠|SKIP[^:]*:)?\s*")


# Every container the drain will ever be handed. The key extractor below MUST
# know all of them: a title whose extension is missing here gets the whole log
# LINE as its identity, and since each line carries a different timestamp and
# prefix, that title never compares equal to itself across stages.
_SRC_EXT = ("mkv", "mp4", "m4v", "mov", "ts", "m2ts", "mts", "webm", "avi")
_SRC_EXT_DOT = tuple("." + e for e in _SRC_EXT)
_TITLE_RE = re.compile(r"(.+?\.(?:" + "|".join(_SRC_EXT) + r"))(?=\s|$)", re.I)


def _title_key(s):
    """The BARE source filename in a log line — the title key.

    Used to answer "is this the same title?" across lines written by different
    stages, which prefix it differently ("✅ DONE x.mkv", "   [todo] /mnt/…/x.mkv")
    and quote it as a full path or a bare name depending on the stage. Matching
    a non-greedy match to the first ".mkv" from the START of the line kept
    whichever prefix and path each line carried, so two references to one
    title produced two
    different keys and never compared equal — which is why the pending-queue
    subtraction could not tell a finished title from a waiting one.

    Strip the prefix, then take the basename: same title, same key, always.

    ⚠ This was ".mkv"-ONLY until 2026-09-10, and 46 of the queued titles are
    .mp4. For those it fell through to `s.strip()` — the whole line — so a
    finished mp4 could never cancel its own [todo] entry (the queue would have
    counted it as pending forever, inflating prog_of), and `current` skipped
    every mp4 stage line and named the PREVIOUS title as the one being worked
    on. Keep _SRC_EXT in step with whatever the scanner accepts."""
    body = _LOGPFX.sub("", s.strip())
    # Stage lines read "extract video ES … <path>": the filename follows the
    # ellipsis, and a non-greedy match from the left would otherwise swallow the
    # stage description into the title key.
    if "… " in body:
        body = body.rsplit("… ", 1)[-1]
    m = _TITLE_RE.search(body)
    return os.path.basename(m.group(1).strip()) if m else s.strip()


def _notify(msg):
    """Best-effort Discord ping via the hermes CLI (bot token, no gateway needed).
    Never raises — a normalize run must not break because a ping didn't send."""
    try:
        subprocess.run([HERMES, "send", "--to", "discord", msg], timeout=20,
                       check=False, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)
    except Exception:
        pass


def _pending_queue(lines):
    """(todo_names, when, stale) from the most recent scan recorded in the log.

    Every status surface used to be built purely from ✅/❌ lines — what the
    drain has FINISHED. Nothing read what it still has to DO, so seven titles
    waiting on Movies5/6/7 rendered as "queue clear", which is how a backlog
    became invisible. The scan already writes "found N candidate(s):" followed
    by one [todo]/[skip] line each; this just reads what is already there, so
    the menu stays a log read with no disk scan.

    Titles finished AFTER that scan are subtracted, and a drain that completed
    since is reported as stale — a count from before the last run is a guess,
    and should say so rather than quietly look current."""
    start = None
    for i in range(len(lines) - 1, -1, -1):
        if "candidate(s):" in lines[i]:
            start = i
            break
    if start is None:
        return [], "", False
    when = lines[start].split(" ", 1)[0]
    todo = []
    for l in lines[start + 1:]:
        if "[todo]" not in l:
            if l[:8].count(":") == 2 and "[skip]" not in l:
                break              # next timestamped entry ends the block
            continue
        todo.append(_title_key(l))
    # anything finished after the scan is no longer pending
    done_after = {_title_key(l) for l in lines[start + 1:] if "✅ DONE" in l}
    todo = [t for t in todo if t not in done_after]
    stale = any("drain complete" in l for l in lines[start + 1:])
    return todo, when, stale


def _handoff_pending():
    """Describe a scheduled-but-not-yet-started drain, as (short, long), or ("","").

    A drain is often not launched directly but by a chain script that sleeps
    until another job is out of the way. To every status surface that waiter is
    invisible — the drain simply reads "idle · queue clear" — so genuinely
    queued work looked like no work at all.

    The chain WRITES what it is doing to a state file rather than being guessed
    at from its command line: sniffing /proc for a name meant every new chain
    had to be taught here, and a chain that starts more than the drain had no
    way to say so. The file records the chain's pid, so a stale file left by a
    killed chain is still detectable as dead and ignored."""
    try:
        with open(CHAIN_STATE) as f:
            kv = dict(l.strip().split("=", 1) for l in f if "=" in l)
    except (OSError, ValueError):
        return ("", "")
    pid = kv.get("pid", "")
    if not pid.isdigit() or not os.path.isdir(f"/proc/{pid}"):
        return ("", "")            # the chain died; its file means nothing now
    if kv.get("state") != "waiting":
        return ("", "")            # already fired — the drain's own state is the truth
    on = kv.get("waiting_on", "an earlier job")
    return (f"queued behind {on}",
            f"queued behind {on} → will start {kv.get('starts', 'the drain')} "
            f"(pid {pid}, since {kv.get('since', '?')})")


def status_data():
    """Machine-readable progress — the ONE parser of this tool's log."""
    logp = Path(OUTDIR) / "dvnorm.log"
    lines = logp.read_text(errors="replace").splitlines() if logp.exists() else []
    done = len({_title_key(l) for l in lines if "✅ DONE" in l})
    skip = len(_load_skips())
    todo, when, stale = _pending_queue(lines)
    pid = _drain_running()
    at = batch = 0
    cur = ""
    for l in reversed(lines):
        m = re.search(r"--- \[(\d+)/(\d+)\] ---", l)
        if m:
            at, batch = int(m.group(1)), int(m.group(2))
            break
    # Only the FIRST of the six stage lines carries the filename; the rest just
    # name the stage. Take the newest stage line that actually resolves to a
    # title key — testing for a literal ".mkv" here is what made an .mp4 title
    # report the PREVIOUS film as "current" for its whole multi-hour encode.
    for l in reversed(lines):
        if re.search(r"\[\d/6\]", l):
            k = _title_key(l)
            if k.lower().endswith(_SRC_EXT_DOT):
                cur = k
                break
    stage_no = 0
    for l in reversed(lines):
        m = re.search(r"\[(\d)/6\]", l)
        if m:
            stage_no = int(m.group(1))
            break
    # Every byte this title is laying down, wherever it lands. The MUX writes
    # its output to OUTDIR/*.partial, NOT into .work — so walking .work alone
    # left work_bytes frozen for the whole of stage 5, the stage that moves the
    # most data. The watcher's progress signal is (position, stage, work_bytes),
    # and all three sit still during a mux: a healthy 30 MB/s copy and a wedged
    # one look identical, in both directions. Verified 2026-09-10 at 22:10 —
    # .work unchanged for 25s while the partial grew at 30 MB/s.
    work_bytes = 0
    try:
        for root, _d, files in os.walk(os.path.join(OUTDIR, ".work")):
            for f in files:
                try:
                    work_bytes += os.path.getsize(os.path.join(root, f))
                except OSError:
                    pass
    except OSError:
        pass
    try:
        for f in os.listdir(OUTDIR):
            if f.endswith(".partial"):
                try:
                    work_bytes += os.path.getsize(os.path.join(OUTDIR, f))
                except OSError:
                    pass
    except OSError:
        pass

    # Bytes the stage's own tool has moved, read AND written.
    #
    # Every file-size signal goes blind during a read phase, and stage 4 has a
    # long one: dovi_tool inject-rpu parses the ENTIRE base stream before
    # emitting anything. Measured 2026-09-11 02:55 on Polar Express — seven
    # minutes in, base_dv.hevc still 0 bytes, dovi_tool in D state reading at
    # 60 MB/s with 15.2 of 16.8 GB consumed. Nothing on disk grew, so
    # (position, stage, work_bytes) was frozen solid while the job worked as
    # hard as it can. On a 48 GB title that blindness lasts ~13 minutes, and a
    # genuine wedge inside it would look exactly the same.
    #
    # /proc/<pid>/io moves the instant the tool does anything at all, which is
    # the property a liveness signal actually needs. ⚠ `ps %cpu` does NOT: it
    # is a LIFETIME average and reads ~1% for an IO-bound tool that is pinned.
    io_bytes = 0
    try:
        for d in os.listdir("/proc"):
            if not d.isdigit():
                continue
            try:
                with open(f"/proc/{d}/cmdline", "rb") as f:
                    argv = f.read().decode("utf-8", "replace")
                if OUTDIR not in argv:
                    continue
                if os.path.basename(argv.split("\0")[0]) not in (
                        "ffmpeg", "dovi_tool", "mkvmerge", "ffprobe"):
                    continue
                with open(f"/proc/{d}/io") as f:
                    for line in f:
                        k, _, v = line.partition(":")
                        if k in ("read_bytes", "write_bytes"):
                            io_bytes += int(v)
            except (OSError, ValueError, IndexError):
                continue
    except OSError:
        pass

    # The pre-flight's peak-footprint figure for the title in flight, so the
    # watcher can ask "how much is left to write?" as (plan - on disk) instead
    # of guessing from whatever file happens to be biggest right now.
    plan_need = 0
    for l in reversed(lines):
        if "scratch plan:" in l:
            mm = re.search(r"~(\d+)G peak", l)
            if mm:
                plan_need = int(mm.group(1)) * 10**9
            break
        if re.search(r"--- \[\d+/\d+\] ---", l):
            # Walked past the start of the current title without finding a
            # plan line: this title predates the logging, so say nothing rather
            # than attribute the previous title's plan to it.
            break

    short, long = _handoff_pending()
    return {"name": "DV Normalize", "icon": "⚙", "short": "DV norm",
            "pid": pid, "running": bool(pid),
            "at": at, "total": batch, "done": done, "current": cur,
            "queued": len(todo), "queue_when": when, "queue_stale": stale,
            "skipped": skip, "waiting_on": short, "waiting_long": long,
            # Titles finished against titles known to need doing — a drain's
            # batch position says nothing about the queue waiting behind it.
            "plan_need": plan_need, "io_bytes": io_bytes,
            "prog_at": done, "prog_of": done + len(todo),
            # A title takes hours and moves through six stages; the title
            # counter alone cannot tell "grinding through stage 4 of a 54GB
            # source" from "wedged". These are the finer signals — the stage
            # marker, and the bytes actually on disk in the work directory.
            "stage": stage_no, "work_bytes": work_bytes,
            "next": todo[0] if todo else "",
            "detail": (f"{len(todo)} queued" if todo else f"{skip} skipped")}


def status_line():
    """One compact line (rofi header / Discord) from the log + process state only —
    no disk scan, so a menu popup is instant."""
    logp = Path(OUTDIR) / "dvnorm.log"
    lines = logp.read_text(errors="replace").splitlines() if logp.exists() else []
    done = len({_title_key(l) for l in lines if "✅ DONE" in l})
    skip = len(_load_skips())
    if _drain_running() and lines:
        def _last(pat, grp):
            for l in reversed(lines):
                m = re.search(pat, l)
                if m:
                    return m.group(grp)
            return ""
        pos = _last(r"--- (\[\d+/\d+\]) ---", 1)
        sm = _last(r"\[(\d)/6\]", 1)
        stg = STAGE_NAMES.get(int(sm), "?") if sm else "?"
        cur = ""
        for l in reversed(lines):
            if re.search(r"\[\d/6\]", l) and ".mkv" in l:
                cur = Path(l.split("…")[-1].strip()).stem[:40]  # filename after the "…"
                break
        return f"⚙ {pos} {stg} · {cur}  ·  {done} done · {skip} skipped"
    todo, _when, _stale = _pending_queue(lines)
    pend = _handoff_pending()[0]
    if pend:
        return f"⏳ {len(todo)} queued · {pend} · {done} done · {skip} skipped"
    if todo:
        return f"⏸ {len(todo)} title(s) waiting · {done} done · {skip} skipped"
    return f"✓ idle · queue clear · {done} done · {skip} skipped"


def show_status():
    """Human-readable progress of the drain — for checking on the overnight run."""
    logp = Path(OUTDIR) / "dvnorm.log"
    # _drain_running(), NOT `pgrep -f` — pgrep matches the COMMAND LINE of every
    # process including the shell that invoked us, whose text contains this
    # script's own name, so it reported a finished drain as RUNNING and then
    # printed a stage frozen at whatever the log last wrote. status_line() was
    # fixed for this; show_status() was not, which is how a job that ended at
    # 12:49 was still shown as "[6/6] verifying" hours later.
    running = _drain_running()
    print("═══ DV Normalize — status ═══")
    print(f"  drain process : {'RUNNING' if running else 'idle / not running'}")
    if not logp.exists():
        print("  no log yet (nothing has run)")
        return
    lines = logp.read_text(errors="replace").splitlines()
    done = [l.split("✅ DONE ", 1)[-1] for l in lines if "✅ DONE" in l]
    # A title that later succeeded is NOT failed; dedupe repeated retries by name.
    done_names = {_title_key(d) for d in done}
    seen, failed = set(), []
    for l in lines:
        if "❌" not in l:
            continue
        body = l.split("❌", 1)[-1].strip()
        name = _title_key(re.sub(r"^\s*(VERIFY FAILED|ERROR)\s*", "", body))
        if name in done_names or name in seen:
            continue                   # resolved on a later run, or already listed
        seen.add(name)
        failed.append(body)
    outs = sorted(Path(OUTDIR).glob("*.dvnorm.mkv"))
    print(f"  completed     : {len(done)} verified DV file(s)")
    for d in done[-12:]:
        print(f"      ✓ {d[:78]}")
    if failed:
        print(f"  failed        : {len(failed)}  (skip-listed — --retry-failed to re-attempt)")
        for f in failed[-4:]:
            print(f"      ✗ {f[:78]}")
    print(f"  output files  : {len(outs)} on disk in {OUTDIR}")
    if running:
        # current title + stage from the most recent markers
        cur = next((l.split("normalize ONE: ", 1)[-1] for l in reversed(lines)
                    if "normalize ONE:" in l or "--- [" in l), "")
        st = next((l for l in reversed(lines) if re.search(r"\[\d/6\]", l)), "")
        m = re.search(r"\[(\d)/6\]", st)
        stg = STAGE_NAMES.get(int(m.group(1)), "?") if m else "?"
        stamp = st.split(" ", 1)[0] if st else ""
        print(f"  in progress   : stage [{m.group(1) if m else '?'}/6] {stg}"
              f"  (since {stamp})")
    else:
        # Say WHY it is idle. "drain complete" and "never started" look identical
        # otherwise, and a drain waiting on a handoff looks like nothing at all.
        tail = next((l for l in reversed(lines) if "drain complete" in l), "")
        if tail:
            print(f"  last run      : {tail.strip('= ')}")
        todo, when, stale = _pending_queue(lines)
        if todo:
            print(f"  still to do   : {len(todo)} title(s)  (as of the {when} scan"
                  + (" — STALE, a drain has run since; --list to rescan)" if stale
                     else ")"))
            for t in todo[:12]:
                print(f"      · {t[:74]}")
            if len(todo) > 12:
                print(f"      … and {len(todo) - 12} more")
        pend = _handoff_pending()[1]
        if pend:
            print(f"  queued        : {pend}")
        elif not todo:
            print("  (drain not currently running — start it to continue)")
        else:
            print("  (nothing is scheduled to start it — run --list, then the "
                  "ops panel's drain)")


def _drain_running():
    """The DRAIN process is alive (excluding a --watch/--status reader).

    Reads /proc rather than shelling to `pgrep -af`, which matches the COMMAND
    LINE of every process — including the shell that invoked us, whose command
    text contains this script's own name. That made --status report a finished
    drain as RUNNING, with a stage frozen at whatever it last logged."""
    me = os.getpid()
    for d in os.listdir("/proc"):
        if not d.isdigit() or int(d) == me:
            continue
        try:
            with open(f"/proc/{d}/cmdline", "rb") as f:
                argv = f.read().decode("utf-8", "replace").split("\0")
        except OSError:
            continue
        # argv[0] is the interpreter; the SCRIPT is its own argument, so a shell
        # that merely mentions the name in one long -c string can never match.
        if not any(a.endswith("codec_dv_normalize.py") for a in argv):
            continue
        if any(a.startswith("--watch") or a.startswith("--status")
               or a.startswith("--list") or a.startswith("--check") for a in argv):
            continue
        # A job pointed at a DIFFERENT --outdir is not THIS drain. It writes its
        # own dvnorm.log, so the log we read for position and current title never
        # moves while the process is alive — which renders as a drain frozen on a
        # stale title, and after long enough as a false stall alarm. Hit for real
        # by the A/B clip runs, which use --outdir precisely to stay out of the
        # library's way; nightwatch showed "DV drain working, same title" for a
        # drain that was not running at all.
        outdir = None
        for i, a in enumerate(argv):
            if a == "--outdir" and i + 1 < len(argv):
                outdir = argv[i + 1]
            elif a.startswith("--outdir="):
                outdir = a.split("=", 1)[1]
        if outdir and os.path.abspath(outdir) != os.path.abspath(OUTDIR):
            continue
        return True
    return False


def _active_work():
    wd = Path(OUTDIR) / ".work"
    if not wd.exists():
        return None
    for d in wd.iterdir():
        m = re.search(r"_(\d+)$", d.name)
        if m and Path(f"/proc/{m.group(1)}").exists():
            return d
    return None


_dur_cache = {}


def _source_duration_for_work(wd):
    """Duration (s) of the SOURCE title being encoded in work dir `wd`.
    The raw ES (clip.hevc) carries NO container duration, so the stage-3 bar
    can't size itself from it — match the work dir's stem prefix back to the
    real source file and probe THAT. Memoized (one probe per title)."""
    key = wd.name
    if key in _dur_cache:
        return _dur_cache[key]
    prefix = re.sub(r"_\d+$", "", wd.name)      # strip _<pid> → Path(src).stem[:40]
    dur = 0.0
    for root in ROOTS:
        if dur:
            break
        for dp, _, fns in os.walk(root):
            hit = next((fn for fn in fns
                        if fn.lower().endswith((".mkv", ".mp4", ".m4v"))
                        and Path(fn).stem[:40] == prefix), None)
            if hit:
                dur = duration(os.path.join(dp, hit))
                break
    if dur:                                     # only cache a real answer
        _dur_cache[key] = dur
    return dur


def _bar(frac, width=34):
    frac = max(0.0, min(1.0, frac))
    n = int(round(frac * width))
    return "[" + "█" * n + "░" * (width - n) + f"] {int(frac * 100):3d}%"


def show_watch():
    """Live progress display — redraws in place, polling the drain's on-disk state.
    Read-only: the drain runs untouched. Estimates the nvenc/mux stage % from the
    output file growing toward its expected size. Ctrl+C to stop watching."""
    import time as _t
    logp = Path(OUTDIR) / "dvnorm.log"
    try:
        while True:
            print("\033[2J\033[H", end="")
            running = _drain_running()
            lines = logp.read_text(errors="replace").splitlines() if logp.exists() else []
            done = [l.split("✅ DONE ", 1)[-1] for l in lines if "✅ DONE" in l]
            total = 0
            for l in reversed(lines):
                mt = re.search(r"draining (\d+) title", l)
                if mt:
                    total = int(mt.group(1))
                    break
            print("═══ DV Normalize — live ═══  (Ctrl+C to stop watching, drain keeps running)\n")
            print(f"  {'▶ RUNNING' if running else '■ idle'}    {len(done)} / {total or '?'} titles done")
            if total:
                print(f"  overall {_bar(len(done) / total)}")
            print()
            for d in done[-8:]:
                print(f"    ✓ {d[:72]}")
            st = next((l for l in reversed(lines) if re.search(r"\[\d/6\]", l)), "")
            m = re.search(r"\[(\d)/6\]", st)
            if running and m:
                stg = int(m.group(1))
                # The title name only rides the [1/6] line (… <filename>); the later
                # stage lines don't carry it, so read the most recent [1/6] for it.
                cur = next((l for l in reversed(lines) if "[1/6]" in l), "")
                title = cur.split("… ", 1)[-1].strip() if "… " in cur else ""
                if title:
                    print(f"\n  now: {title[:70]}")
                    print(f"       [{stg}/6] {STAGE_NAMES.get(stg, '?')}")
                else:
                    print(f"\n  now: [{stg}/6] {STAGE_NAMES.get(stg, '?')}")
                wd, frac = _active_work(), None
                try:
                    if wd and stg == 3 and (wd / "base.hevc").exists():
                        # base.hevc grows toward (target bitrate × SOURCE duration)/8.
                        # The raw ES has no duration, so read it from the source title;
                        # read the target bitrate from the [3/6] log line for robustness.
                        dur = _source_duration_for_work(wd)
                        mbr = re.search(r"(\d+)M", st)
                        br = (int(mbr.group(1)) if mbr else 40) * 1e6
                        exp = br * dur / 8
                        frac = (wd / "base.hevc").stat().st_size / exp if exp > 0 else None
                    elif wd and stg == 5 and (wd / "base_dv.hevc").exists():
                        parts = list(Path(OUTDIR).glob("*.partial"))
                        if parts:
                            frac = parts[0].stat().st_size / (wd / "base_dv.hevc").stat().st_size
                except OSError:
                    frac = None
                if frac is not None:
                    print("  " + _bar(frac))
                elif stg == 3:
                    print("  (nvenc encoding — resolving source size for the bar…)")
                else:
                    print("  (this step is quick — no measurable %)")
            if not running:
                print("\n  drain not running.")
                break
            _t.sleep(2)
    except KeyboardInterrupt:
        print("\n(stopped watching — the drain was not affected)")


# ══════════════════════════════════════════════════════════════════════════════
# Batch CLI — check any folder/library, and mass-import (normalize + auto-place)
# ══════════════════════════════════════════════════════════════════════════════
VIDEO_EXTS = (".mkv", ".mp4", ".m4v", ".mov", ".ts")
MIN_MAIN_BYTES = 300 * 1024 * 1024      # ignore samples / featurettes / extras
MIN_FILM_SECONDS = 900                  # 15 min — below this it is a sample or an
                                        # extra, never a feature worth converting
# ⚠ ROOTS are DRIVE-level (/mnt/Movies, /mnt/Movies2) and _dvnorm-trash sits
# directly under them, so without it here the drain re-reads the very originals
# it just discarded. Seen 2026-09-13: The Terminator converted overnight
# (43G -> 24G, original trashed 04:32) and picked straight back up FROM THE
# TRASH at 11:43 — 175G of scratch and hours of nvenc to rebuild a file the
# library already had. Compared lowercased, so keep these lowercase.
SKIP_DIRS = {"_dvnorm", "_dvnorm-trash", "_dvtest", ".work", "_dupes-trash",
             "extras", "featurettes", "sample", "samples",
             "$recycle.bin", "system volume information", "lost+found"}


def _skip_dir(d):
    """A folder no walk should enter: the work/trash dirs above, and an import
    still being copied ("<Title>.importing" — a partial the drain must not
    encode while rsync is writing it)."""
    d = d.lower()
    return d in SKIP_DIRS or d.endswith(".importing")


def _sz(p):
    try:
        return os.path.getsize(p)
    except OSError:
        return 0


def _res_label(h):
    return ("4K" if h >= 1600 else "1080p" if h >= 1000 else
            "720p" if h >= 650 else "SD" if h else "?")


def _fps_num(fr):
    try:
        n, d = str(fr).split("/")
        return round(int(n) / int(d), 3) if int(d) else 0.0
    except Exception:
        try:
            return round(float(fr), 3)
        except Exception:
            return 0.0


def _depth(pix):
    return 12 if "12" in (pix or "") else 10 if "10" in (pix or "") else 8


def _mbps(size, dur, stream_bitrate):
    try:
        if stream_bitrate:
            return round(int(stream_bitrate) / 1e6, 1)
    except (TypeError, ValueError):
        pass
    return round(size * 8 / dur / 1e6, 1) if (size and dur) else 0.0


def _lum(frac):
    try:
        n, d = str(frac).split("/")
        return int(n) / int(d)
    except Exception:
        return 0.0


def _dv_profile_str(prof, compat):
    if prof == 8:
        return "8." + {1: "1", 2: "2", 4: "4"}.get(compat, str(compat))
    return str(prof) if prof is not None else "?"


def probe_title(main):
    """ONE ffprobe (all streams + first frame) + the hub's real cast-lane preflight.
    Everything here is FILE-METADATA truth (ffprobe), never the filename."""
    raw = run([FFPROBE, "-loglevel", "error", "-show_streams", "-show_format",
               "-show_frames", "-read_intervals", "%+#1", "-print_format", "json",
               main]).stdout
    j = json.loads(raw or "{}")
    streams = j.get("streams", [])
    vs = next((s for s in streams if s.get("codec_type") == "video"), {})
    dur = float((j.get("format") or {}).get("duration") or 0)
    size = _sz(main)

    # Dolby Vision — the stream's DOVI configuration record is the authority.
    dv = None
    for sd in vs.get("side_data_list", []):
        if sd.get("side_data_type") == "DOVI configuration record":
            dv = {"profile": _dv_profile_str(sd.get("dv_profile"),
                                             sd.get("dv_bl_signal_compatibility_id")),
                  "level": sd.get("dv_level"), "rpu": bool(sd.get("rpu_present_flag")),
                  "el": bool(sd.get("el_present_flag")), "bl": bool(sd.get("bl_present_flag")),
                  "layers": "dual" if sd.get("el_present_flag") else "single",
                  "compress": sd.get("dv_md_compression", "?")}
    # HDR10 static + HDR10+ dynamic + a DV-RPU fallback, from stream & first frame.
    sds = list(vs.get("side_data_list", []))
    for fr in j.get("frames", []):
        sds += fr.get("side_data_list", [])
    mastering = maxcll = maxfall = max_nits = None
    hdr10plus = frame_dv = False
    for sd in sds:
        t = sd.get("side_data_type", "")
        if t == "Mastering display metadata":
            mastering, max_nits = True, round(_lum(sd.get("max_luminance", "0/1")))
        elif t == "Content light level metadata":
            maxcll, maxfall = sd.get("max_content"), sd.get("max_average")
        elif "Dynamic Metadata" in t or "2094" in t or "HDR10+" in t:
            hdr10plus = True
        elif "Dolby Vision" in t:
            frame_dv = True
    if dv is None and frame_dv:
        dv = {"profile": "?", "level": None, "rpu": True, "el": False, "bl": True,
              "layers": "single", "compress": "?"}

    trc = vs.get("color_transfer", "")
    tags = []
    if dv:
        tags.append("DV" + (dv["profile"] if dv["profile"] != "?" else ""))
    if hdr10plus:
        tags.append("HDR10+")
    if trc == "smpte2084" and not hdr10plus:
        tags.append("HDR10")
    if trc == "arib-std-b67":
        tags.append("HLG")
    hdr_label = "·".join(tags) if tags else "SDR"

    audio, subs = [], []
    for s in streams:
        ct = s.get("codec_type")
        if ct == "audio":
            ch = int(s.get("channels") or 0)
            blob = ((s.get("profile") or "") + " " +
                    ((s.get("tags") or {}).get("title") or "")).lower()
            audio.append({"codec": s.get("codec_name", "?"), "ch": ch,
                          "layout": {8: "7.1", 6: "5.1", 2: "2.0", 1: "1.0"}.get(ch, f"{ch}ch"),
                          "lang": (s.get("tags") or {}).get("language", ""),
                          "title": (s.get("tags") or {}).get("title", ""),
                          "atmos": "atmos" in blob,
                          "dtsx": "dts:x" in blob or "dts-x" in blob,
                          "mbps": _mbps(0, 0, s.get("bit_rate"))})
        elif ct == "subtitle":
            subs.append({"codec": s.get("codec_name", "?"),
                         "lang": (s.get("tags") or {}).get("language", ""),
                         "forced": bool((s.get("disposition") or {}).get("forced")),
                         "default": bool((s.get("disposition") or {}).get("default"))})
    a0 = audio[0] if audio else None
    audio_short = "—"
    if a0:
        audio_short = f"{a0['codec']} {a0['layout']}"
        audio_short += " Atmos" if a0["atmos"] else " DTS:X" if a0["dtsx"] else ""
        if len(audio) > 1:
            audio_short += f" +{len(audio) - 1}"

    lane = preflight_lane(main)
    return {"main": main, "sizeGB": round(size / 1e9, 1), "dur": dur,
            "codec": vs.get("codec_name", ""), "vprofile": vs.get("profile", ""),
            "w": int(vs.get("width") or 0), "h": int(vs.get("height") or 0),
            "res": _res_label(int(vs.get("height") or 0)), "pix": vs.get("pix_fmt", ""),
            "depth": _depth(vs.get("pix_fmt", "")), "fps": _fps_num(vs.get("r_frame_rate", "")),
            "primaries": vs.get("color_primaries", ""), "trc": trc,
            "matrix": vs.get("color_space", ""), "mbps": _mbps(size, dur, vs.get("bit_rate")),
            "dv": dv, "mastering": mastering, "max_nits": max_nits, "maxcll": maxcll,
            "maxfall": maxfall, "hdr10plus": hdr10plus, "hdr": hdr_label, "lane": lane,
            # ⚠ A dual-layer (profile 7) title also reports dv + lane hdr10, but the
            # normalizer CANNOT take it: find_candidates gates on has_dv_rpu(), a
            # profile-8 test. Counting P7 here is what made --check promise 9
            # stragglers that the drain then narrowed to 2. Keep them separate so
            # the number --check prints is the number the drain will actually do.
            "dual_layer": bool(dv and dv.get("el")),
            "needs_norm": bool(dv and lane == "hdr10" and not dv.get("el")),
            "audio": audio,
            "audio_short": audio_short, "subs": subs}


def print_detail(name, p):
    """Expanded per-title metadata block — every fine difference, from the file."""
    dv, total = p["dv"], int(p["dur"])
    hms = f"{total // 3600}:{(total % 3600) // 60:02d}:{total % 60:02d}"
    print(f"▐ {name}")
    print(f"    file    : {p['main']}")
    print(f"    size    : {p['sizeGB']} GB · {hms} · ~{p['mbps']} Mb/s overall")
    print(f"    video   : {p['codec'].upper()} {p['vprofile']} · {p['depth']}-bit "
          f"({p['pix']}) · {p['w']}×{p['h']} ({p['res']}) · {p['fps']} fps")
    print(f"    color   : {p['primaries'] or '?'} / {p['trc'] or '?'} / {p['matrix'] or '?'}")
    if dv:
        print(f"    DV      : profile {dv['profile']} · level {dv['level']} · "
              f"{dv['layers']}-layer (BL={'y' if dv['bl'] else 'n'} "
              f"EL={'y' if dv['el'] else 'n'} RPU={'y' if dv['rpu'] else 'n'}) · "
              f"md-compress {dv['compress']}")
    else:
        print("    DV      : none")
    h10 = []
    if p["mastering"]:
        h10.append(f"mastering {p['max_nits']} nits")
    if p["maxcll"] is not None:
        h10.append(f"MaxCLL {p['maxcll']}")
    if p["maxfall"] is not None:
        h10.append(f"MaxFALL {p['maxfall']}")
    print(f"    HDR10   : {' · '.join(h10) if h10 else 'no static metadata'}"
          + ("   · HDR10+ dynamic: yes" if p["hdr10plus"] else ""))
    warn = "   ⚠ DV present but serves as HDR10 — NEEDS NORMALIZE" if p["needs_norm"] else ""
    print(f"    ▶ CAST  : lane = {str(p['lane']).upper()}{warn}")
    for i, a in enumerate(p["audio"], 1):
        ex = " Atmos" if a["atmos"] else " DTS:X" if a["dtsx"] else ""
        lang = f" [{a['lang']}]" if a["lang"] else ""
        br = f" · {a['mbps']} Mb/s" if a["mbps"] else ""
        ttl = f" — {a['title']}" if a["title"] else ""
        print(f"    audio {i} : {a['codec']} {a['layout']}{ex}{lang}{br}{ttl}")
    if p["subs"]:
        ss = ", ".join((s["lang"] or s["codec"]) + ("(forced)" if s["forced"] else "")
                       for s in p["subs"][:10])
        print(f"    subs    : {len(p['subs'])} track(s) — {ss}")
    print()


def discover_titles(dirs):
    """[(name, main_video_path)] for each title under dirs. A title = a directory
    that directly holds video file(s) (main = the largest, > MIN_MAIN_BYTES); a bare
    video file sitting in a scan dir is its own title. Extras/samples/staging pruned."""
    uniq = {}
    for base in dirs:
        base = os.path.abspath(base)
        if os.path.isfile(base):
            uniq[base] = Path(base).stem
            continue
        if not os.path.isdir(base):
            continue
        for dp, dns, fns in os.walk(base):
            dns[:] = [d for d in dns
                      if not _skip_dir(d) and not d.startswith(".")]
            vids = [os.path.join(dp, f) for f in fns
                    if f.lower().endswith(VIDEO_EXTS)
                    and _sz(os.path.join(dp, f)) >= MIN_MAIN_BYTES]
            if not vids:
                continue
            main = max(vids, key=_sz)
            uniq[main] = (Path(dp).name if os.path.abspath(dp) != base
                          else Path(main).stem)
    return sorted(((n, m) for m, n in uniq.items()), key=lambda x: x[0].lower())


def _err_probe(main, err):
    """Full-shape probe dict for a title whose ffprobe failed — carries every key
    the --check formatters read, so one unprobeable file can't KeyError the audit."""
    return {"main": main, "sizeGB": 0, "dur": 0, "codec": "?", "vprofile": "",
            "w": 0, "h": 0, "res": "?", "pix": "", "depth": "?", "fps": "?",
            "primaries": "", "trc": "", "matrix": "", "mbps": 0, "dv": None,
            "mastering": None, "max_nits": None, "maxcll": None, "maxfall": None,
            "hdr10plus": False, "hdr": "ERR", "lane": "ERR", "needs_norm": False,
            "dual_layer": False,
            "audio": [], "audio_short": "—", "subs": [], "err": err}


def _probe_all(titles, workers=6):
    from concurrent.futures import ThreadPoolExecutor
    out = {}
    with ThreadPoolExecutor(max_workers=workers) as ex:
        futs = {ex.submit(probe_title, m): m for _, m in titles}
        for fut, m in futs.items():
            try:
                out[m] = fut.result()
            except Exception as e:
                out[m] = _err_probe(m, str(e))
    return [(n, out[m]) for n, m in titles]


def cmd_check(dirs, details=False):
    dirs = dirs or ROOTS
    titles = discover_titles(dirs)
    print(f"CHECK — {len(titles)} title(s) under: {', '.join(dirs)}\n")
    if not titles:
        print("  (no video titles found)")
        return
    results = _probe_all(titles)
    results.sort(key=lambda r: (0 if r[1]["needs_norm"]
                                else 1 if r[1]["lane"] == "dv" else 2,
                                r[0].lower()))
    head = (f"{'LANE':<6}{'NEEDS':<7}{'RES':<7}{'HDR':<13}{'DEPTH':<6}{'SIZE':>7}  "
            f"{'AUDIO':<20} TITLE")
    if not details:
        print(head)
        print("-" * (len(head) + 22))
    n_ready = n_norm = n_nondv = n_p7 = 0
    tot = 0.0
    for name, p in results:
        if p["needs_norm"]:
            need, n_norm = "NORM!", n_norm + 1
        elif p["dual_layer"] and p["lane"] == "hdr10":
            need, n_p7 = "P7!", n_p7 + 1
        elif p["lane"] == "dv":
            need, n_ready = "dv-ok", n_ready + 1
        else:
            need, n_nondv = "-", n_nondv + 1
        tot += p["sizeGB"]
        if details:
            print_detail(name, p)
        else:
            print(f"{str(p['lane']):<6}{need:<7}{p['res']:<7}{p['hdr']:<13}"
                  f"{str(p['depth']) + 'bit':<6}{p['sizeGB']:>6.1f}G  "
                  f"{p['audio_short'][:20]:<20} {name[:46]}")
    if not details:
        print("-" * (len(head) + 22))
    print(f"summary: {n_ready} DV-ready · {n_norm} NEED-NORMALIZE · "
          f"{n_p7} P7-dual-layer · {n_nondv} not-DV   ({tot:.0f}GB total)")
    if n_p7:
        print(f"  ⚠ {n_p7} title(s) are DV profile 7 (dual-layer). They serve as HDR10 "
              f"and the normalizer cannot take them — has_dv_rpu() is a profile-8 "
              f"test. They need a P7→P8.1 convert first.")
    if n_norm:
        print(f"\n  → normalize the {n_norm} straggler(s):  python3 "
              f"~/Projects/codec/scripts/codec_dv_normalize.py --dir '{dirs[0]}'")


def _verified_move(src, dst_dir, apply):
    """Move a file OR directory into dst_dir, cross-filesystem SAFE. On a different
    filesystem the copy is verified BYTE-FOR-BYTE (content, not just size — a
    same-length but corrupt copy must never pass) before the source is removed.
    Never removes the source unless the copy verified. Returns the destination path."""
    dst = os.path.join(dst_dir, os.path.basename(src.rstrip("/")))
    if not apply:
        return dst
    os.makedirs(dst_dir, exist_ok=True)
    if os.path.exists(dst):
        raise RuntimeError(f"destination already exists: {dst}")
    same_fs = (os.stat(os.path.dirname(os.path.abspath(src))).st_dev
               == os.stat(dst_dir).st_dev)
    if same_fs:
        os.rename(src, dst)
        return dst
    if os.path.isdir(src):
        shutil.copytree(src, dst)
        log("  cross-fs copy — verifying every file byte-for-byte before removing source …")
        for dp, _, fns in os.walk(src):
            rel = os.path.relpath(dp, src)
            for f in fns:
                s = os.path.join(dp, f)
                d = os.path.join(dst, rel, f)
                if not os.path.isfile(d):           # missing dest ≠ size-0 match
                    raise RuntimeError(f"copy verify FAILED — dest missing {d} — source kept")
                if not filecmp.cmp(s, d, shallow=False):
                    raise RuntimeError(f"copy verify FAILED — content mismatch {s} — source kept")
        shutil.rmtree(src)
    else:
        tmp = dst + ".partial"
        if os.path.exists(tmp):
            os.remove(tmp)
        shutil.copy2(src, tmp)
        log("  cross-fs copy — verifying byte-for-byte before removing source …")
        if not filecmp.cmp(src, tmp, shallow=False):   # content, not just byte count
            os.remove(tmp)
            raise RuntimeError(f"copy verify FAILED (content): {src} — source kept")
        if os.path.exists(dst):                         # fail closed: appeared mid-copy
            os.remove(tmp)
            raise RuntimeError(f"destination appeared mid-copy: {dst} — source kept")
        os.rename(tmp, dst)
        os.remove(src)
    return dst


def cmd_import(src_dir, dest, apply, bitrate, keyint, include_nondv,
               no_normalize=False):
    if not dest:
        print("--import needs --dest <library root>  (where to place the titles)")
        return
    if not os.path.isdir(src_dir):
        print(f"not a directory: {src_dir}")
        return
    titles = discover_titles([src_dir])
    print(f"IMPORT — {len(titles)} title(s)   {src_dir}  →  {dest}"
          f"   [{'APPLY' if apply else 'DRY-RUN'}]\n")
    results = _probe_all(titles)
    plan = []
    for name, p in results:
        parent = os.path.dirname(p["main"])
        unit = (parent if os.path.abspath(parent) != os.path.abspath(src_dir)
                else p["main"])           # move the title FOLDER, or the bare file
        if p["needs_norm"] and not no_normalize:
            plan.append(["normalize+place", name, p, unit])
        elif p["lane"] == "dv" or include_nondv:
            plan.append(["place", name, p, unit])
        elif p["needs_norm"]:                       # --no-normalize: leave it be
            plan.append(["skip (needs norm)", name, p, unit])
        else:
            plan.append(["skip (not DV)", name, p, unit])
    for act, name, p, _ in plan:
        print(f"  [{act:16}] {str(p['lane']):<6} {p['hdr']:<11} "
              f"{p['sizeGB']:>6.1f}G  {name[:46]}")
    n_norm = sum(1 for r in plan if r[0].startswith("normalize"))
    n_place = sum(1 for r in plan if r[0] == "place")
    n_skip = sum(1 for r in plan if r[0].startswith("skip"))
    print(f"\nplan: {n_place} place · {n_norm} normalize+place · {n_skip} skip"
          + ("" if apply else
             "   (DRY-RUN — nothing changed; re-run with --apply to execute)"))
    if not apply:
        return
    if not acquire_lock():          # every --apply import serializes (place-only too)
        return
    try:
        clean_orphan_work()
        for act, name, p, unit in plan:
            try:
                if act.startswith("skip"):
                    continue
                if act.startswith("normalize"):
                    log(f"=== import: normalize {name} ===")
                    res = normalize(p["main"], bitrate, keyint)
                    op = out_path(p["main"])
                    done = (Path(op).exists()
                            and _src_marker(op) == os.path.abspath(p["main"])
                            and preflight_lane(op) == "dv")
                    if res != "ok" and not done:
                        log(f"  ↳ {name}: normalize did not verify ({res}); NOT placed")
                        continue
                    placed = _verified_move(op, dest, True)
                    log(f"  ↳ placed normalized DV → {placed}")
                else:
                    placed = _verified_move(unit, dest, True)
                    log(f"placed {name} → {placed}")
            except Exception as e:
                log(f"❌ import {name}: {e}")
    finally:
        release_lock()


def main():
    global OUTDIR, CAP_TO_SOURCE
    ap = argparse.ArgumentParser()
    ap.add_argument("--status", action="store_true",
                    help="print drain progress once and exit (safe anytime)")
    ap.add_argument("--status-json", dest="status_json", action="store_true",
                    help="machine-readable progress for the dashboard")
    ap.add_argument("--status-line", dest="status_line", action="store_true",
                    help="print ONE compact status line and exit (for menus/pings)")
    ap.add_argument("--watch", action="store_true",
                    help="live progress display, redraws in place (safe anytime)")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--one", metavar="PATH")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--wait-lock", dest="wait_lock", type=float, default=0,
                    metavar="HOURS",
                    help="if another drain holds the lock, wait up to HOURS for it "
                         "(then scan) instead of refusing — for the unattended units")
    ap.add_argument("--retry-failed", dest="retry_failed", action="store_true",
                    help="re-attempt titles previously skip-listed after a verify "
                         "failure (e.g. after a code fix or a re-download)")
    ap.add_argument("--clear-skips", dest="clear_skips", action="store_true",
                    help="empty the verify-failure skip-list so every title is "
                         "re-queued on the next run, then exit")
    ap.add_argument("--no-place", dest="no_place", action="store_true",
                    help="after a verified normalize, DON'T swap the DV file into the "
                         "library — leave it staged in OUTDIR, original untouched "
                         "(default: auto-place + move original to _dvnorm-trash)")
    ap.add_argument("--bitrate", default="40M")
    ap.add_argument("--only", action="append", metavar="PATH",
                    help="normalize exactly these files (repeatable), bypassing the "
                         "scan. For a CURATED production run: --one skips placement "
                         "entirely (it is a test path), while this goes through the "
                         "real batch loop — scratch pre-check, placement pre-check, "
                         "verify-or-discard, original to _dvnorm-trash")
    ap.add_argument("--cap-to-source", dest="cap_to_source", action="store_true",
                    help="clamp the encode target to the source's own measured "
                         "video bitrate, so an output can never grow. Lets a lean "
                         "title be converted for the DV gain without paying disk "
                         "for bits that carry no extra picture")
    ap.add_argument("--p7-only", dest="p7_only", action="store_true",
                    help="select ONLY profile-7 dual-layer titles (implies "
                         "--include-p7). Its own ops job, because P7 wants a "
                         "different target than the profile-8 drain")
    ap.add_argument("--include-p7", dest="include_p7", action="store_true",
                    help="also select DV profile-7 (dual-layer) titles; they are "
                         "converted to single-layer 8.1 before the re-encode, which "
                         "also gains them real DV casting")
    ap.add_argument("--over-bitrate", dest="over_bitrate", type=float,
                    metavar="MBPS",
                    help="shrink sweep: instead of titles that fail to cast as "
                         "DV, select single-layer DV titles whose VIDEO bitrate "
                         "exceeds MBPS and re-encode them down to --bitrate "
                         "(video-vs-video; lossless audio is copied through "
                         "untouched and must not count toward either side)")
    ap.add_argument("--keyint", type=int, default=48)
    ap.add_argument("--outdir", default=OUTDIR)
    ap.add_argument("--check", nargs="*", metavar="DIR",
                    help="audit lane/HDR for every title under DIR(s) (files OR folders, "
                         "drag-and-drop friendly), or the whole library if none given; "
                         "READ-ONLY (no encode, no move)")
    ap.add_argument("--details", "-l", action="store_true",
                    help="with --check: expanded per-title metadata (DV profile/level, "
                         "layers, mastering nits, MaxCLL/FALL, every audio/sub track)")
    ap.add_argument("--dir", metavar="DIR",
                    help="normalize the DV-but-HDR10 titles under DIR instead of the "
                         "fixed library roots")
    ap.add_argument("--import", dest="imp", metavar="DIR",
                    help="check DIR, normalize the stragglers, then PLACE the DV-ready "
                         "titles into --dest (DRY-RUN unless --apply)")
    ap.add_argument("--dest", metavar="LIBROOT",
                    help="library root to place imported titles into (with --import)")
    ap.add_argument("--apply", action="store_true",
                    help="actually move files on --import (default: dry-run plan only)")
    ap.add_argument("--include-nondv", action="store_true",
                    help="on --import, also place non-DV (HDR10/SDR) titles")
    ap.add_argument("--no-normalize", action="store_true",
                    help="on --import, skip (don't encode) the needs-normalize titles "
                         "— just place the already-DV-ready ones")
    a = ap.parse_args()
    _yield_io()   # background work never blocks NFS or playback
    bm = re.fullmatch(r"\s*(\d+)\s*[Mm]?\s*", a.bitrate or "")
    if not bm or int(bm.group(1)) <= 0:
        print(f"--bitrate must be integer Mbps (e.g. 40 or 40M); got {a.bitrate!r}")
        return
    a.bitrate = f"{int(bm.group(1))}M"
    OUTDIR = a.outdir
    CAP_TO_SOURCE = a.cap_to_source
    # OUTDIR is only WRITTEN by the encode paths. Read-only commands (--check,
    # --status, --watch, --import dry-run) must work even when the staging drive is
    # unplugged — so only create it when we're actually going to encode.
    read_only = (a.status or a.status_line or a.watch or a.clear_skips
                 or a.check is not None or (a.imp and not a.apply))
    if not read_only:
        Path(OUTDIR).mkdir(parents=True, exist_ok=True)

    if a.clear_skips:
        try:
            Path(SKIPLIST).unlink(missing_ok=True)
            print("skip-list cleared — all titles re-queue on the next run")
        except OSError as e:
            print(f"could not clear skip-list: {e}")
        return

    if a.status_json:
        print(json.dumps(status_data()))
        return

    if a.status_line:
        print(status_line())
        return

    if a.status:
        show_status()
        return

    if a.watch:
        show_watch()
        return

    if a.check is not None:
        cmd_check(a.check, a.details)
        return

    if a.imp:
        cmd_import(a.imp, a.dest, a.apply, a.bitrate, a.keyint, a.include_nondv,
                   a.no_normalize)
        return

    if a.one:
        if not acquire_lock():
            return
        try:
            clean_orphan_work()
            log(f"=== normalize ONE: {a.one} ===")
            normalize(a.one, a.bitrate, a.keyint)
        finally:
            release_lock()
        return

    roots = [a.dir] if a.dir else ROOTS
    # Waiting units take the lock BEFORE scanning: a scan made before hours of
    # waiting would be stale by the time it ran (the other drain may have done
    # those very titles).
    if a.wait_lock and not a.list and not acquire_lock(wait=a.wait_lock * 3600):
        return
    # ⚠ --list is a QUERY and must not touch the shared log. Every status surface
    # — the rofi ops panel, nightwatch's hourly beat — reads the most recent
    # "found N candidate(s):" block out of dvnorm.log as THE live queue. Writing a
    # listing there plants a backlog the enabled drain will never do: listing with
    # --include-p7 put 4 phantom P7 titles in front of nightwatch, and the service
    # (which runs without that flag) could never clear them. Queries print; only
    # real runs write the log.
    emit = print if a.list else log
    if a.only:
        pass                      # the curated path announces itself below
    elif a.over_bitrate is not None:
        # Guard the one way this mode can waste a whole night: a sweep whose
        # floor sits at or below the encode target matches titles that are
        # already lean and spends hours making them BIGGER.
        tgt = _target_mbps(a.bitrate)
        if a.over_bitrate <= tgt:
            raise SystemExit(
                f"--over-bitrate {a.over_bitrate}M is not above the encode "
                f"target ({tgt}M): every match would be re-encoded UPWARD. "
                f"Raise --over-bitrate or lower --bitrate.")
        emit(f"scanning for DV titles whose VIDEO is over {a.over_bitrate} Mbps "
             f"in {', '.join(roots)} … (shrink sweep -> {a.bitrate} video)")
    else:
        emit(f"scanning for DV-but-HDR10 candidates in {', '.join(roots)} …"
             + ("  (including profile-7 dual-layer)" if a.include_p7 else ""))
    if a.only:
        cands = []
        for f in a.only:
            if not os.path.exists(f):
                raise SystemExit(f"--only: no such file: {f}")
            cands.append(os.path.abspath(f))
        emit(f"curated run: {len(cands)} explicit title(s), scan bypassed")
    else:
        cands = find_candidates(roots, a.over_bitrate,
                                a.include_p7 or a.p7_only, a.p7_only)
    emit(f"found {len(cands)} candidate(s):")

    def _state(c):
        if Path(out_path(c)).exists() and preflight_lane(out_path(c)) == "dv":
            # A finished, VERIFIED output (the final name is only ever an atomic
            # rename after verify) still in OUTDIR while its source is still a
            # candidate means the PLACEMENT never happened — the drain was
            # stopped, killed or power-cut mid-copy. Calling that DONE stranded
            # it for good (and its partial .dvplacing beside the original).
            if not a.no_place and _src_marker(out_path(c)) == os.path.abspath(c):
                return "place"
            return "DONE"
        if is_skipped(c) and not a.retry_failed:
            return "skip"        # previously verify-failed, file unchanged
        return "todo"

    states = {c: _state(c) for c in cands}
    for c in cands:
        emit(f"   [{states[c]}] {c}")
    if a.list:
        return
    todo = [c for c in cands if states[c] in ("todo", "place")]
    if a.limit:
        todo = todo[:a.limit]
    if not acquire_lock():
        return
    try:
        clean_orphan_work()
        log(f"=== draining {len(todo)} title(s) (bitrate={a.bitrate}) ===")
        if todo:
            _notify(f"🎬 codec: normalizing {len(todo)} DV title(s)…")
        tally = {"ok": 0, "fail": 0, "skip": 0}
        deferred = 0
        no_room = 0
        for i, c in enumerate(todo, 1):
            place_only = states.get(c) == "place"
            # Space pre-check: DV normalize writes ~2x the source (extracted ES +
            # a fresh nvenc encode) into OUTDIR before muxing. Defer cleanly instead
            # of crash-filling the disk with ENOSPC (-28) and re-looping forever.
            try:
                # Scratch need is driven by DURATION, not by source size.
                # The work dir holds the extracted source video plus THREE
                # copies at the fixed output bitrate — the nvenc base, the same
                # again with the RPU injected, and the muxed output — and those
                # three are (bitrate x duration), which has almost nothing to do
                # with how large the source happens to be.
                #
                # A flat multiple of source size is therefore wrong in BOTH
                # directions, measured against tonight's runs: 6x gave 102G for
                # Indiana Jones whose real peak was ~120G (an UNDER-estimate,
                # the dangerous way to be wrong) and 326G for Shawshank whose
                # real peak was ~145G — over-conservative enough that it
                # deferred two titles which would have fitted comfortably.
                #
                # 10% margin on top, because guessing low is the failure this
                # check exists to prevent.
                src_sz = os.path.getsize(c)
                dur_s = duration(c) or 0
                per_copy = dur_s * _bps(a.bitrate) / 8
                need = int(src_sz + 3 * per_copy * 1.1) if dur_s else int(src_sz * 6.0)
                # Never count the system floor as available scratch.
                free = max(0, shutil.disk_usage(OUTDIR).free - SYSTEM_FLOOR)
            except OSError:
                need, free = 0, 1 << 60
            if place_only:
                need = 0                     # nothing left to encode
            if free < need:
                deferred = len(todo) - i + 1
                log(f"⏸ DEFERRING {deferred} title(s) — need ~{need // 10**9}G scratch for "
                    f"{Path(c).stem[:45]}, only {free // 10**9}G usable on {OUTDIR} "
                    f"(after a {SYSTEM_FLOOR // 10**9}G system-drive floor). "
                    f"Free space or add a drive, then re-run.")
                _notify(f"⏸ codec normalize PAUSED — out of scratch space on {OUTDIR} "
                        f"({free // 10**9}G free, need ~{need // 10**9}G). "
                        f"{deferred} DV title(s) deferred until there's room.")
                break
            # Destination pre-check. The scratch check above only guards the ENCODE.
            # Placement stages the finished file next to the original and the trash is
            # on that same drive, so the original's space is never reclaimed — a
            # near-full drive can never accept a bigger file, whatever the ordering.
            # Establish where it will land BEFORE burning hours of nvenc on a
            # placement that cannot succeed (Inglourious Basterds, 2026-09-09).
            place_to = None
            if not a.no_place:
                need_out = est_output_size(c, a.bitrate)
                place_to, relocating = placement_dir(c, need_out)
                if place_to is None:
                    no_room += 1
                    log(f"⏭ NO ROOM TO PLACE {Path(c).stem[:45]} — output is ~"
                        f"{need_out // 10**9}G, its drive {_drive_root(c)} has "
                        f"{_free(_drive_root(c)) // 10**9}G free and no other library "
                        f"root can take it. Skipped BEFORE encoding — free space and re-run.")
                    _notify(f"⏭️ codec: **{Path(c).stem[:40]}** can't be normalized — "
                            f"nowhere to put the ~{need_out // 10**9}G result.")
                    continue
                if relocating:
                    log(f"↷ {_drive_root(c)} can't hold the ~{need_out // 10**9}G output "
                        f"— will place into {place_to.parent} instead")
            # Publish the pre-flight's own arithmetic. The watcher needs to
            # know how much this title still has to write, and it was deriving
            # that from the largest file in the work dir — which is the SOURCE
            # ES early on, and has almost nothing to do with the size of the
            # three (bitrate x duration) copies that follow. For Zombieland:
            # Double Tap that heuristic said 12G a copy where the real answer
            # was 28G: a 2.4x under-estimate, the dangerous direction. One model
            # of "how much room does this title need", computed here, read
            # there.
            log(f"    scratch plan: ~{need // 10**9}G peak, "
                f"{int(per_copy) // 10**9}G per copy, {free // 10**9}G free")
            log(f"--- [{i}/{len(todo)}] ---")
            if place_only:
                log(f"placing a finished output that was never placed: {Path(c).name}")
                res = "ok"
            else:
                res = normalize(c, a.bitrate, a.keyint)
            tally[res] = tally.get(res, 0) + 1
            name = Path(c).stem
            if res == "ok":
                placed = None
                if not a.no_place:
                    try:
                        placed = place_normalized(c, out_path(c), place_to)
                        log(f"↪ placed DV into library; original → {placed}")
                    except Exception as e:
                        log(f"⚠ place FAILED for {name}: {e} — DV output kept in {OUTDIR}, "
                            f"original untouched (place manually)")
                if placed:
                    _notify(f"✅ codec [{i}/{len(todo)}]: **{name}** is now DV in the library "
                            f"(original moved to _dvnorm-trash — reversible)")
                else:
                    _notify(f"✅ codec [{i}/{len(todo)}]: **{name}** normalized "
                            f"(DV output staged in {OUTDIR}; not placed)")
            elif res == "fail":
                _notify(f"⏭️ codec [{i}/{len(todo)}]: **{name}** skipped (can't cast as DV — skip-listed)")
        log(f"=== drain complete: {tally['ok']} ok, {tally['fail']} failed, "
            f"{tally['skip']} skipped"
            + (f", {deferred} deferred (no scratch)" if deferred else "")
            + (f", {no_room} unplaceable (no room in the library)" if no_room else "")
            + " ===")
        if todo:
            _notify(f"🏁 codec normalize done — {tally['ok']} ok, "
                    f"{tally['fail']} skipped. {status_line()}")
    finally:
        release_lock()


if __name__ == "__main__":
    main()
