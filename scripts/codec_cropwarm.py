#!/usr/bin/env python3
"""codec_cropwarm — work out, ahead of time, where each film changes shape.

Some films change aspect partway through. Top Gun: Maverick is 2.39:1 for most of
its runtime and ~1.90:1 IMAX for the whole final act; Interstellar and the Nolan
Batmans do the same. One zoom cannot serve them — the scale that fills the scope
sections pushes 21% of every IMAX shot off the screen, and the scale that respects
IMAX leaves the scope sections letterboxed. The receiver needs a TIMELINE so it
can change the zoom exactly when the film does.

Building that timeline is a full-film decode: ~17 minutes for a 131-minute 4K
remux even scanning keyframes only through a downscale. That cannot happen while
someone is waiting to press play, so it happens here, once per file, cached on
disk under ~/.cache/codec/croptl keyed on path+size+mtime.

Most of a library never changes aspect, and finding that out is cheap — six probes,
about thirty seconds. So every film gets the cheap question first and only the ones
that answer "yes" pay for the full scan. In this library that is a handful of IMAX
titles rather than 250 films.

  codec_cropwarm.py            # warm anything not already done
  codec_cropwarm.py --status   # what is warmed, what changes aspect
  codec_cropwarm.py --limit 3
"""
import argparse
import importlib.util
import json
import re
import os
import sys
import time
from pathlib import Path

import sys as _sys, os as _os
_sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))
try:
    from codec_ui import yield_io as _yield_io
except ImportError:                       # ui module absent: not worth failing over
    def _yield_io():
        pass

CFG = Path.home() / ".config/codec/config.json"
LOG = Path.home() / ".cache/codec/cropwarm.log"


def _serve():
    """codec_serve owns the measurement code; import it without starting a server."""
    spec = importlib.util.spec_from_file_location(
        "cs", str(Path.home() / "Projects/codec/scripts/codec_serve.py"))
    m = importlib.util.module_from_spec(spec)
    argv, sys.argv = sys.argv, ["codec_serve"]
    try:
        spec.loader.exec_module(m)
    except SystemExit:
        pass
    finally:
        sys.argv = argv
    return m


def log(msg):
    line = f"{time.strftime('%F %T')} {msg}"
    print(line, flush=True)
    try:
        LOG.parent.mkdir(parents=True, exist_ok=True)
        with open(LOG, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


def _running():
    """PID of a live warm, or 0. Reads /proc — `pgrep -f` would also match the shell
    that invoked it, whose command text contains this script's name."""
    me = os.getpid()
    for d in os.listdir("/proc"):
        if not d.isdigit() or int(d) == me:
            continue
        try:
            argv = open(f"/proc/{d}/cmdline", "rb").read().decode("utf-8", "replace").split("\0")
        except OSError:
            continue
        # argv[0] must be the INTERPRETER, not merely some process that has the
        # script path in its arguments. `timeout 900 python3 codec_cropwarm.py`
        # leaves a live `timeout` whose argv contains the path — it forks rather
        # than execs — and matching that made the tool refuse to start against
        # its own wrapper. (setsid/nohup exec through and leave nothing behind,
        # which is why the chain never hit this.)
        if "python" not in os.path.basename(argv[0] if argv else "") :
            continue
        if any(x.endswith("codec_cropwarm.py") for x in argv) \
                and not any(x.startswith("--status") for x in argv):
            return int(d)
    return 0


FILMCOUNT = Path.home() / ".cache/codec/film-count.json"
# What --pending-json last measured. status_data cannot afford the library walk
# itself (the rofi header calls it on every open), but it must not therefore
# LIE: `done` counts scan lines, so a film measured twice pushes it past the
# film count and the clamp then pins the readout at 100% while real films sit
# unmeasured. Tonight that read 264/264 with three unscanned. nightwatch asks
# for --pending-json at least every ten minutes, so this is warm in practice.
PENDING = Path.home() / ".cache/codec/crop-pending.json"
PENDING_TTL = 3600
# A film still being written is not a film to measure. The import rsyncs
# --inplace straight to the final name, so a half-transferred title is a
# perfectly ordinary-looking file in a library root: at 04:51 on 2026-09-11 the
# pending list held Expendables (2010) at 45.96G with an mtime of 0 seconds ago
# while rsync was still pulling it. Measuring that costs a decode and produces a
# timeline keyed to a size and mtime that are about to change — orphaned the
# moment the transfer finishes. Two minutes of quiet is enough: rsync touches
# the file continuously, and a settled film is picked up on the next pass.
SETTLE_S = 120


def _film_total(ttl=600):
    """How many films exist, cached. The true answer is a walk of every library
    root across seven drives — fine once, wasteful every five seconds behind a
    --watch. Ten minutes is far shorter than the sweep it is the denominator
    for, and a stale count only ever misreports the backlog by a title or two."""
    try:
        d = json.loads(FILMCOUNT.read_text())
        if time.time() - d["t"] < ttl:
            return int(d["n"])
    except (OSError, ValueError, KeyError):
        pass
    try:
        n = len(films())
        FILMCOUNT.parent.mkdir(parents=True, exist_ok=True)
        FILMCOUNT.write_text(json.dumps({"t": time.time(), "n": n}))
        return n
    except OSError:
        return 0


def status_data(total_films=None):
    """Machine-readable progress — the ONE parser of this tool's log.

    `total_films` is passed in rather than counted here: the true denominator is
    a walk of every library root, which the rofi header cannot afford. The
    dashboard supplies it when it has already paid for the walk; without it the
    caller gets the batch's own totals and no false precision."""
    lines = LOG.read_text(errors="replace").splitlines() if LOG.exists() else []
    done = sum(1 for l in lines if "one aspect (" in l or " segments in " in l)
    varies = sum(1 for l in lines if " segments in " in l)
    pid = _running()
    at = batch = 0
    cur = ""
    for l in reversed(lines):
        m = re.search(r"\[(\d+)/(\d+)\] (.+)$", l)
        if m:
            at, batch, cur = int(m.group(1)), int(m.group(2)), m.group(3).strip()
            # "CHANGES ASPECT — full scan …  <name>" / "one aspect (31s)  <name>":
            # the film is what follows the ellipsis or the timing, not the whole
            # progress sentence.
            if "… " in cur:
                cur = cur.rsplit("… ", 1)[-1].strip()
            elif ")  " in cur:
                cur = cur.rsplit(")  ", 1)[-1].strip()
            break
    films = _film_total() if total_films is None else total_films
    # The honest figure when a walk is fresh; the clamped scan-line count only
    # as a fallback.
    measured = _measured(films)
    prog_at = measured if measured is not None else min(done, films)
    return {"name": "Crop warm", "icon": "⛶", "short": "Crop warm",
            "pid": pid, "running": bool(pid),
            "started": (os.stat(f"/proc/{pid}").st_mtime if pid else None),
            "at": at, "total": batch, "done": done, "current": cur,
            "varies": varies,
            "films": films,
            # Films measured against films that exist — the sweep's real shape,
            # not progress through whichever handful this run was handed.
            #
            # Clamped, because `done` counts SCAN LINES: a film re-keyed by
            # croptl_repair or re-measured after substrip rewrote it is counted
            # twice, and tonight that put it at 271 against 263 films. A readout
            # reading 271/263 looks like a bug in the tool rather than what it
            # is. Anything needing the true outstanding count must ask
            # --pending-json, which walks the library and tests for the
            # timeline file itself.
            "prog_at": prog_at,
            "prog_of": films,
            "detail": f"{varies} change aspect"}


def _unmeasured(films_list, serve):
    """Films with no timeline yet AND not still being written.

    Shared by the sweep and --pending-json so the two can never disagree about
    what work exists — a count that includes a file the sweep will skip would
    make the watcher start a sweep that does nothing."""
    now = time.time()
    out = []
    for p in films_list:
        if serve._timeline_path(p).exists():
            continue
        try:
            if now - os.stat(p).st_mtime < SETTLE_S:
                continue        # still landing
        except OSError:
            continue
        out.append(p)
    return out


def _measured(total_films):
    """Films that actually have a timeline, from the last --pending-json walk.

    Returns None when there is no fresh measurement, and the caller falls back
    to the clamped scan-line count — never worse than before, and honest when
    it can be. Films imported since the walk are simply unmeasured, so the
    measured figure stays valid while the denominator grows."""
    try:
        d = json.loads(PENDING.read_text())
        measured = int(d["films"]) - int(d["pending"])
    except (OSError, ValueError, KeyError, TypeError):
        return None
    # A STALE walk still beats the scan-line fallback. Age makes this figure
    # UNDERSTATE what is measured (films warmed since the walk are missing from
    # it), which shows work that may already be done — harmless, the sweep
    # checks each film itself. The fallback fails the other way: `done` counts
    # scan lines and a re-keyed or re-measured film is counted twice, so it
    # exceeds the film count and min(done, films) clamps to EXACTLY films. A
    # stale cache therefore read "327/327 complete" while nine films sat
    # unmeasured, and nothing would ever start a sweep for them because nothing
    # reported work. Hiding work is the one direction this must never fail in.
    return max(0, min(measured, total_films))


def status_line():
    d = status_data()
    # prog_at, not `done`. `done` counts SCAN LINES, so a film measured twice
    # inflates it — it read "271 film(s) measured" against a 264-film library.
    at, of = d["prog_at"], d["prog_of"]
    if d["running"]:
        return (f"⛶ scanning · {d['current'][:38]} · "
                f"{at}/{of} done, {d['varies']} change aspect")
    if at:
        left = of - at
        return (f"⛶ idle · {at}/{of} film(s) measured, "
                f"{d['varies']} change aspect"
                + (f", {left} waiting" if left else ""))
    return "⛶ idle"


def films():
    roots = [r["path"] for r in json.loads(CFG.read_text())["roots"]
             if r["kind"] == "movies"]
    out = []
    for r in roots:
        for dp, _, fs in os.walk(r):
            if any(x in dp for x in ("_dvnorm", "-trash", "Featurettes", "Extras")):
                continue
            for f in fs:
                if f.lower().endswith((".mkv", ".mp4", ".m4v")):
                    p = os.path.join(dp, f)
                    try:
                        if os.path.getsize(p) > 2 * 1024**3:   # features, not clips
                            out.append(p)
                    except OSError:
                        pass
    return sorted(set(out))


# Cam-tier markers. These releases are a camera pointed at a screen, so nothing
# about their framing is a property of the FILM.
# Deliberately conservative. A bare "ts" was tried and matched every .ts
# transport-stream file, which is a legitimate container — under-matching here
# costs one wasted scan, over-matching silently skips a real film.
CAM_RE = re.compile(r"telesync|hdts|hdcam|camrip|\bcam\b", re.I)


def main():
    ap = argparse.ArgumentParser(description="pre-compute crop timelines")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--status", action="store_true")
    ap.add_argument("--status-json", dest="status_json", action="store_true",
                    help="machine-readable progress for the dashboard")
    ap.add_argument("--pending-json", dest="pending_json", action="store_true",
                    help="{'pending': N, 'films': M} — films with no timeline "
                         "yet. Needs the library walk, so it is NOT part of "
                         "--status-json (which the rofi header calls on every "
                         "open); ask for it explicitly when you can afford it.")
    ap.add_argument("--status-line", dest="status_line", action="store_true",
                    help="one line, for the rofi header")
    ap.add_argument("--match", action="append", default=None, metavar="TEXT",
                    help="only films whose path contains TEXT (repeatable) — lets the "
                         "known variable-aspect titles be warmed first")
    a = ap.parse_args()
    _yield_io()   # background work never blocks NFS or playback
    # The one-liner must be instant — the menu header calls it on every open — so it
    # reads the log and the cache directory, never the library or ffprobe.
    if a.status_json:
        print(json.dumps(status_data()))
        return
    if a.status_line:
        print(status_line())
        return

    m = _serve()
    fl = films()

    if a.pending_json:
        # (writes PENDING as a side effect — see _measured)
        # The HONEST measure of outstanding work: a film with no timeline file.
        # status_data's `done` counts SCAN LINES in the log, so a film measured
        # twice — re-keyed after a repair, or re-measured after substrip rewrote
        # it — inflates it past the film count. `films - done` then goes
        # NEGATIVE and reads as "nothing to do" while real films sit unscanned.
        out = {"pending": len(_unmeasured(fl, m)), "films": len(fl)}
        try:
            PENDING.parent.mkdir(parents=True, exist_ok=True)
            PENDING.write_text(json.dumps({"t": time.time(), **out}))
        except OSError:
            pass
        print(json.dumps(out))
        return

    if a.status:
        warm = varies = cold = 0
        changing = []
        for p in fl:
            f = m._timeline_path(p)
            if not f.exists():
                cold += 1
                continue
            warm += 1
            try:
                tl = json.loads(f.read_text())
            except ValueError:
                tl = None
            # No segments = measured and flat, not un-measured. (These files
            # now carry a "src" too, so they are truthy where "{}" was not.)
            if tl and tl.get("segments"):
                varies += 1
                changing.append((len(tl["segments"]), p))
        # A header + a live process line, same shape as the other jobs. Without
        # them this block was a bare table that ran into the previous job's
        # output in the combined view, and an actively-scanning warm was
        # indistinguishable from a cold cache — it read as a missing job.
        print("═══ Crop warm — status ═══")
        pid = _running()
        print(f"  process          : {f'RUNNING (pid {pid})' if pid else 'idle / not running'}")
        if pid:
            cur = ""
            for l in reversed(LOG.read_text(errors="replace").splitlines()
                              if LOG.exists() else []):
                if "] " in l and ("full scan" in l or "one aspect" in l or "CHANGES" in l):
                    cur = l.split("] ", 1)[-1].strip()
                    break
            if cur:
                print(f"  in progress      : {cur[:70]}")
        print(f"  films            : {len(fl)}")
        print(f"  warmed           : {warm}")
        print(f"  not yet scanned  : {cold}")
        print(f"  CHANGE aspect    : {varies}")
        for n, p in sorted(changing, reverse=True):
            print(f"      {n:>3} segments  {Path(p).name[:66]}")
        return

    # Nothing stopped two warms running at once, and now that a chain script can
    # start one unattended, two could overlap and spend hours decoding the same
    # films in parallel — each finishing a scan the other had already begun.
    other = _running()
    if other:
        log(f"another crop warm is already running (pid {other}) — refusing to start")
        return

    if a.match:
        low = [x.lower() for x in a.match]
        fl = [p for p in fl if any(x in p.lower() for x in low)]
    todo = _unmeasured(fl, m)
    # A camcorder recording wobbles, so cropdetect reads the drift as a genuinely
    # changing aspect and escalates to the expensive full scan — and the timeline
    # it produces is worse than none, since adaptive zoom would then chase the
    # camera shake. Seen on a TELESYNC of a film still in cinemas: flagged
    # CHANGES ASPECT within seconds and settled in for a ~13 minute scan.
    skipped_cam = [p for p in todo if CAM_RE.search(Path(p).name)]
    todo = [p for p in todo if p not in set(skipped_cam)]
    for p in skipped_cam:
        # Write the empty timeline the "one aspect" path writes, so the film
        # counts as MEASURED. Skipping without it leaves the file permanently
        # unmeasured, and nightwatch starts the sweep whenever it sees unmeasured
        # films — a loop that starts a scan to measure the one thing the scan
        # refuses to measure.
        try:
            m.CROPTL_DIR.mkdir(parents=True, exist_ok=True)
            m._timeline_path(p).write_text("{}")
        except OSError:
            pass
        log(f"  skipping cam-tier release (no meaningful crop): {Path(p).name[:58]}")
    if a.limit:
        todo = todo[:a.limit]
    log(f"=== crop warm: {len(todo)} of {len(fl)} film(s) not yet scanned ===")
    varies = flat = 0
    for i, p in enumerate(todo, 1):
        name = Path(p).name[:58]
        try:
            t0 = time.time()
            if not m.aspect_varies(p):
                flat += 1
                try:
                    m.CROPTL_DIR.mkdir(parents=True, exist_ok=True)
                    m._timeline_path(p).write_text("{}")   # one aspect: nothing to do
                except OSError:
                    pass
                log(f"[{i}/{len(todo)}] one aspect ({time.time()-t0:.0f}s)  {name}")
                continue
            log(f"[{i}/{len(todo)}] CHANGES ASPECT — full scan …  {name}")
            tl = m.build_crop_timeline(p)
            if tl:
                varies += 1
                segs = tl["segments"]
                log(f"    {len(segs)} segments in {time.time()-t0:.0f}s: " +
                    ", ".join(f"{s['scale']}x@{int(s['t'])//60}:{int(s['t'])%60:02d}"
                              for s in segs[:6]) + (" …" if len(segs) > 6 else ""))
            else:
                flat += 1
                log(f"    resolved to one aspect after the full scan ({time.time()-t0:.0f}s)")
        except Exception as e:
            log(f"[{i}/{len(todo)}] FAILED {name}: {e}")
    log(f"=== done: {varies} changing aspect, {flat} single-aspect ===")


if __name__ == "__main__":
    main()
