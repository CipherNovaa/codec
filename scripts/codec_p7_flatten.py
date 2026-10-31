#!/usr/bin/env python3
"""Flatten DV profile-7 titles to profile 8.1 — losslessly, without re-encoding.

Cast/CAF plays profile 8.1 only. A profile-7 file carries a base layer plus an
ENHANCEMENT LAYER that nothing in this system can use, so codec correctly falls
back to the HDR10 lane: the filename says DV, the file contains DV, and the TV
never sees it. That is how the four largest titles in the library — Gladiator,
Legends of the Fall, Ghost in the Shell, Raiders — sat serving as `hdr10` while
looking perfectly good, and nobody noticed for months.

codec_dv_normalize can convert them, but it ALWAYS re-encodes afterwards: it
exists to repair irregular GOPs, and the nvenc pass is unconditional. For these
titles that is pure loss — measured 2026-09-16, their GOPs are already better
than the normalizer's own 2s target (Ghost in the Shell a flat 1.00s, Legends
0.99s, Gladiator 0.82s). They are professionally authored remuxes; the GOP was
never the problem. Re-encoding them would burn ~2h of GPU each, need 50-70G of
free space nobody has, and LOSE quality to fix a defect they do not have.

So this does only the part they need:

  1. extract the HEVC elementary stream (stream copy — no decode)
  2. dovi_tool -m 5 convert --discard   (drops the EL, rewrites the RPU to 8.1)
  3. remux with the ORIGINAL audio/subtitle tracks, copied

The base layer survives bit for bit. The output is SMALLER, because the layer
being discarded is the one that was never usable. Minutes, not hours, and no GPU.

⚠ Refuses any title whose GOP is not already tight — those genuinely belong to
codec_dv_normalize. This tool is the cheap path, not a replacement.

  codec_p7_flatten.py --scan            list profile-7 titles and their GOPs
  codec_p7_flatten.py --one PATH        flatten one title
  codec_p7_flatten.py --apply [--limit N]  flatten every eligible title
Without --apply or --one it only reports.
"""
import argparse, json, os, shutil, subprocess, sys, time
from pathlib import Path
import codec_paths  # where codec's data lives (~/.local/share/codec)

_FF8 = str(Path.home() / "deps/ffmpeg-n8.1-static/bin")
FFMPEG = f"{_FF8}/ffmpeg" if Path(f"{_FF8}/ffmpeg").exists() else "ffmpeg"
FFPROBE = f"{_FF8}/ffprobe" if Path(f"{_FF8}/ffprobe").exists() else "ffprobe"
DOVI = str(Path.home() / ".local/bin/dovi_tool")
MKVMERGE = shutil.which("mkvmerge") or "mkvmerge"
CFG = Path.home() / ".config/codec/config.json"
LOG = Path.home() / ".cache/codec/p7-flatten.log"
SCRATCH = Path(os.environ.get("CODEC_P7_SCRATCH",
                              str(Path.home() / ".local/share/codec/p7-scratch")))
SCRATCH_FLOOR = 80 * 1024**3      # never run the system disk down
# A GOP this long or longer is NOT what this tool is for — hand it to the
# normalizer instead. The DV lane wants keyframes ~2s apart; these titles come
# in around 1s, so anything past 4s is a different problem.
MAX_GOP_S = 4.0


def log(msg):
    line = f"{time.strftime('%H:%M:%S')} {msg}"
    print(line, flush=True)
    try:
        LOG.parent.mkdir(parents=True, exist_ok=True)
        with LOG.open("a") as f:
            f.write(line + "\n")
    except OSError:
        pass


def run(cmd, timeout=7200):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def is_dual_layer(src):
    """True if the stream carries a DV enhancement layer (profile 7)."""
    try:
        d = run([FFPROBE, "-v", "error", "-select_streams", "v:0", "-show_entries",
                 "stream_side_data=el_present_flag", "-of", "json", str(src)], 120).stdout
        for st in (json.loads(d or "{}").get("streams") or []):
            for sd in st.get("side_data_list", []):
                if sd.get("el_present_flag"):
                    return True
    except Exception:
        pass
    return False


def gop_regular(src, seconds=60):
    """(ok, why) — does this file pass the DV lane's ACTUAL regularity test?

    ⚠ An AVERAGE interval is not the criterion and reading it as one cost a
    wasted conversion. codec_serve's dv_probe requires every keyframe gap to sit
    within 0.05s of the FIRST gap, because the copy lane slices whole GOPs into
    DASH segments and cannot do that on a shifting grid. Ghost in the Shell
    averages 0.95s and looks pristine by that measure, yet carries scene-cut
    keyframes at 0.125s, 0.167s, 0.25s … — it fails, and no profile conversion
    changes that. Such a title needs codec_dv_normalize's re-encode whatever its
    DV profile is.

    Mirrors dv_probe exactly: packet flags, first-gap tolerance 0.05s.
    """
    try:
        out = run([FFPROBE, "-loglevel", "error", "-select_streams", "v:0",
                   "-read_intervals", f"0%{seconds}", "-show_entries",
                   "packet=pts_time,flags", "-of", "csv=p=0", str(src)], 300).stdout
    except Exception:
        return False, "could not read packets"
    ks = sorted(float(l.split(",")[0]) for l in out.splitlines() if ",K" in l)
    if len(ks) < 3:
        return False, "fewer than 3 keyframes in the window"
    gaps = [ks[i + 1] - ks[i] for i in range(len(ks) - 1)]
    first = round(gaps[0], 3)
    if first < 0.4:
        return False, f"GOP {first:.3f}s is below the 0.4s floor"
    bad = [g for g in gaps if abs(g - first) > 0.05]
    if bad:
        return False, (f"GOP irregular — {len(bad)}/{len(gaps)} gaps differ from "
                       f"{first:.3f}s (needs the normalizer's re-encode)")
    return True, f"GOP {first:.3f}s, regular"


def gop_stats(src, seconds=60):
    """(avg, max) keyframe interval — informational only, NOT an eligibility test."""
    try:
        o = run([FFPROBE, "-v", "error", "-select_streams", "v:0",
                 "-read_intervals", f"%+{seconds}", "-show_entries",
                 "frame=key_frame,pts_time", "-of", "csv=p=0", str(src)], 300).stdout
    except Exception:
        return None, None
    prev, gaps = None, []
    for ln in o.splitlines():
        p = ln.split(",")
        if len(p) < 2 or p[0] != "1":
            continue
        try:
            t = float(p[1])
        except ValueError:
            continue
        if prev is not None:
            gaps.append(t - prev)
        prev = t
    if not gaps:
        return None, None
    return sum(gaps) / len(gaps), max(gaps)


def probe_basics(src):
    try:
        o = run([FFPROBE, "-v", "error", "-show_entries",
                 "format=duration:stream=index,codec_type", "-of", "json", str(src)], 180).stdout
        d = json.loads(o)
        streams = d.get("streams") or []
        return {"dur": float(d.get("format", {}).get("duration") or 0),
                "naud": sum(1 for s in streams if s.get("codec_type") == "audio"),
                "nsub": sum(1 for s in streams if s.get("codec_type") == "subtitle")}
    except Exception:
        return {"dur": 0, "naud": 0, "nsub": 0}


def films():
    roots = [r["path"] for r in json.loads(CFG.read_text())["roots"]
             if r.get("kind") == "movies"]
    out = []
    for r in roots:
        for dp, _, fs in os.walk(r):
            if any(x in dp for x in ("_dvnorm", "-trash", "Featurettes", "Extras")):
                continue
            for f in fs:
                if f.lower().endswith(".mkv"):
                    p = os.path.join(dp, f)
                    try:
                        if os.path.getsize(p) > 4 * 1024**3:
                            out.append(p)
                    except OSError:
                        pass
    return sorted(set(out))


def scratch_room(need):
    try:
        SCRATCH.mkdir(parents=True, exist_ok=True)
        free = shutil.disk_usage(SCRATCH).free
    except OSError:
        return False
    return free - need > SCRATCH_FLOOR


def _carry_caches(old_path, new_path, old_stat):
    """Re-key path|size|mtime caches onto the flattened file (crop timeline, DV
    skip decision) and migrate the media_state row, which is keyed on the path
    RELATIVE to /mnt. A flatten changes size, so every one of these is orphaned
    unless carried — the same trap that silently loses resume positions."""
    carried = []
    try:
        import hashlib
        def key(p, st):
            return hashlib.sha1(f"{p}|{st.st_size}|{int(st.st_mtime)}".encode()).hexdigest()
        cdir = Path.home() / ".cache/codec/croptl"
        ns = os.stat(new_path)
        o = cdir / (key(str(old_path), old_stat) + ".json")
        if o.exists():
            shutil.copy2(o, cdir / (key(str(new_path), ns) + ".json"))
            carried.append("crop timeline")
    except Exception:
        pass
    try:
        import sqlite3
        db = codec_paths.DB
        if db.exists():
            rel_old = os.path.relpath(str(old_path), "/mnt")
            rel_new = os.path.relpath(str(new_path), "/mnt")
            c = sqlite3.connect(str(db))
            n = c.execute("UPDATE media_state SET path=? WHERE path=?",
                          (rel_new, rel_old)).rowcount
            c.commit(); c.close()
            if n:
                carried.append(f"{n} media_state row(s)")
    except Exception:
        pass
    return carried


def _in_use(path):
    """Does any of our processes hold `path` open?"""
    target = os.path.realpath(path)
    for fd_dir in Path("/proc").glob("[0-9]*/fd"):
        try:
            for fd in os.listdir(fd_dir):
                try:
                    if os.readlink(os.path.join(fd_dir, fd)) == target:
                        return True
                except OSError:
                    pass
        except OSError:
            pass
    return False


def flatten(src, apply=False):
    src = Path(src)
    name = src.name
    if not is_dual_layer(src):
        return 0, "not profile 7 (no enhancement layer)"
    ok, why = gop_regular(src)
    if not ok:
        return 0, (f"SKIP {why} — a profile conversion alone will NOT put this "
                   f"on the DV lane")
    before = src.stat().st_size
    if not scratch_room(int(before * 2.2)):
        return 0, f"SKIP scratch cannot hold ~{before*2.2/1024**3:.0f}G of working files"
    if not apply:
        avg, _mx = gop_stats(src)          # (was an undefined name: --one without --apply crashed)
        return 0, (f"would flatten: {before/1024**3:.1f}G, GOP {avg:.2f}s avg — "
                   f"lossless P7->8.1, no re-encode")

    b4 = probe_basics(src)
    if b4["dur"] <= 0:
        return 0, "SKIP unreadable duration"
    es = SCRATCH / (src.stem + ".hevc")
    es81 = SCRATCH / (src.stem + ".81.hevc")
    out = SCRATCH / (src.stem + ".p8.mkv")
    for f in (es, es81, out):
        f.unlink(missing_ok=True)
    try:
        log(f"  [1/3] extracting elementary stream (copy, no decode) …")
        r = run([FFMPEG, "-nostdin", "-v", "error", "-i", str(src),
                 "-map", "0:v:0", "-c", "copy", "-bsf:v", "hevc_mp4toannexb",
                 "-f", "hevc", str(es)])
        if r.returncode or not es.exists():
            return 0, f"FAIL extract: {(r.stderr or '')[-200:]}"
        log(f"  [2/3] dovi_tool convert --discard (drop EL, RPU -> 8.1) …")
        r = run([DOVI, "-m", "5", "convert", "--discard", "-i", str(es), "-o", str(es81)])
        if r.returncode or not es81.exists():
            return 0, f"FAIL convert: {(r.stderr or '')[-200:]}"
        es.unlink(missing_ok=True)
        log(f"  [3/3] remuxing with the original audio/subtitle tracks …")
        r = run([MKVMERGE, "-q", "-o", str(out), "--no-video", str(src),
                 "--language", "0:und", str(es81)])
        if r.returncode not in (0, 1) or not out.exists():
            return 0, f"FAIL remux: {(r.stderr or r.stdout or '')[-200:]}"
        # ── verify BEFORE anything irreversible ──────────────────────────────
        af = probe_basics(out)
        problems = []
        if abs(af["dur"] - b4["dur"]) > 1.0:
            problems.append(f"duration {af['dur']:.1f}s vs {b4['dur']:.1f}s")
        if af["naud"] != b4["naud"]:
            problems.append(f"audio tracks {af['naud']} vs {b4['naud']}")
        if af["nsub"] != b4["nsub"]:
            problems.append(f"subtitle tracks {af['nsub']} vs {b4['nsub']}")
        if is_dual_layer(out):
            problems.append("output STILL carries an enhancement layer")
        # Size is NOT the success criterion — the PROFILE is. Profile 7 comes in
        # two shapes: FEL carries a full enhancement layer worth tens of gigabytes,
        # MEL carries a minimal one worth almost nothing. Ghost in the Shell turned
        # out to be MEL: its converted stream came out the same 48.1G as the
        # dual-layer extraction, so requiring the output to SHRINK would have
        # rejected a perfectly good conversion. The point of this tool is to make
        # the title castable as DV; any space returned is a bonus that depends
        # entirely on which shape the source is. Only a substantial GROWTH means
        # something went wrong.
        if out.stat().st_size > before * 1.02:
            problems.append(f"output GREW ({out.stat().st_size/1024**3:.1f}G vs "
                            f"{before/1024**3:.1f}G) — expected same or smaller")
        if problems:
            return 0, "FAIL verify: " + "; ".join(problems)

        new_sz = out.stat().st_size
        old_stat = src.stat()
        # Anything holding the original open (a cast lane, mpv) keeps its
        # blocks after the unlink: the copy below would run the drive to ENOSPC
        # with the title already gone.
        if _in_use(src):
            return 0, "SKIP the file is open (playing or casting) — try again later"
        # Place back. The drive cannot hold both, so the original goes first —
        # only ever after the verify above has passed in full, and the scratch
        # copy remains a complete, verified film throughout the window.
        crumb = out.with_suffix(out.suffix + ".dest")
        crumb.write_text(json.dumps({"dest": str(src), "size": new_sz}))
        local = src.with_name(src.name + ".p8tmp")
        try:
            os.unlink(src)
            shutil.copyfile(out, local)
            if local.stat().st_size != new_sz:
                raise OSError(f"short copy ({local.stat().st_size} vs {new_sz})")
            fd = os.open(local, os.O_RDONLY)     # on disk before it's the only copy
            try:
                os.fsync(fd)
            finally:
                os.close(fd)
            os.replace(local, src)
        except OSError as e:
            local.unlink(missing_ok=True)        # never leave a partial on the full drive
            return 0, (f"FAIL place-back: {e} — the VERIFIED film is at {out} "
                       f"(breadcrumb {crumb.name}); copy it to {src} by hand")
        out.unlink(missing_ok=True)
        crumb.unlink(missing_ok=True)
        es81.unlink(missing_ok=True)
        carried = _carry_caches(src, src, old_stat)
        saved = before - new_sz
        delta = (f"freed {saved/1024**3:.1f}G" if saved > 0.2 * 1024**3
                 else "size ~unchanged (minimal EL — MEL source)")
        return saved, (f"OK profile 7 -> 8.1, lossless, {delta} "
                       f"({before/1024**3:.1f}G -> {new_sz/1024**3:.1f}G)"
                       + (", carried " + " + ".join(carried) if carried else ""))
    finally:
        for f in (es, es81):
            f.unlink(missing_ok=True)
        # A failed run's ~50G output is junk on the system disk — UNLESS a
        # place-back breadcrumb says it is the only copy of the film.
        if out.exists() and not out.with_suffix(out.suffix + ".dest").exists():
            out.unlink(missing_ok=True)


def main():
    ap = argparse.ArgumentParser(description="lossless DV profile 7 -> 8.1")
    ap.add_argument("--scan", action="store_true", help="list profile-7 titles")
    ap.add_argument("--one", metavar="PATH")
    ap.add_argument("--apply", action="store_true", help="actually flatten")
    ap.add_argument("--limit", type=int, default=0)
    a = ap.parse_args()

    if a.one:
        saved, msg = flatten(a.one, a.apply)
        log(f"{Path(a.one).name[:60]}\n    {msg}")
        return 0

    log("scanning for DV profile-7 (dual-layer) titles …")
    cands = []
    for p in films():
        if is_dual_layer(p):
            ok, why = gop_regular(p)
            cands.append((os.path.getsize(p), p, ok, why))
    cands.sort(reverse=True)
    G = 1024**3
    log(f"{len(cands)} profile-7 title(s):")
    total = 0
    for sz, p, ok, why in cands:
        log(f"   {sz/G:6.1f}G  [{'eligible' if ok else 'NEEDS RE-ENCODE'}]  {why}"
            f"  {Path(p).name[:40]}")
        if ok:
            total += sz
    log(f"eligible total: {total/G:.1f}G of source — each shrinks by its EL")
    if not a.apply:
        log("report only — re-run with --apply to flatten")
        return 0
    done = freed = 0
    for sz, p, ok, why in cands:
        if a.limit and done >= a.limit:
            break
        if not ok:
            continue
        log(f"[{done+1}] {Path(p).name[:60]}")
        saved, msg = flatten(p, True)
        log(f"    {msg}")
        freed += saved
        done += 1
    log(f"=== flatten complete: {done} title(s), {freed/G:.1f}G freed ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
