#!/usr/bin/env python3
"""The SUPER+SHIFT+M panel: every long job and every drive, at a glance.

Replaces a stack of four differently-shaped status blocks with one instrument.
The jobs and the drives are the same question asked twice — "how far along, how
much room left" — so they are drawn the same way and can be compared without
re-reading the units each time.

Detail still belongs to each tool (`--status` on any of them); this is the view
you open to decide whether you need the detail at all.
"""
import json
import os
import subprocess
import shutil
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path

# resolve(), not abspath(): the codec_* tools are symlinked into ~/.local/bin,
# and abspath does not follow a symlink — this would then add ~/.local/bin to
# the path and fail to import codec_ui, but only once linked, not here.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import codec_ui as u                                          # noqa: E402

# Every right-hand column is VALUE then DELTA, both fixed width, so the numbers
# form a column and the bracketed changes form another. A job has no delta, but
# still reserves its width — otherwise the jobs' bars and the drives' bars end
# at different places and the panel stops reading as one instrument.
VAL_W, DELTA_W = 10, 8


def _right(value, d=None):
    return value.rjust(VAL_W) + (u.delta(d, DELTA_W) if d is not None
                                 else " " * DELTA_W)

S = Path(__file__).resolve().parent
PY = "/usr/bin/python3"
TOOLS = [("codec_substrip.py", "strip"),
         ("codec_dv_normalize.py", "dvnorm"),
         ("codec_cropwarm.py", "cropwarm")]
CHAIN_STATE = Path.home() / ".cache/codec/idle-chain.state"
SAMPLE = Path.home() / ".cache/codec/storage-sample.json"

# codec's own MGS face on the rofi title line. Installed to ~/.local/share/fonts
# /codec; set to "" to go back to plain Iosevka throughout.
#
# The TITLE ONLY, deliberately. These faces are display faces with no box-drawing
# or block glyphs and gaps in their punctuation — the same reason the app wraps
# dynamic text in mgsSafe(). Rendering the bars or the labels in one would drop
# characters silently, so everything load-bearing stays on Iosevka.
TITLE_FONT = "MGS1 Codec"
TITLE = "CODEC SIDE OPS"


_JOBS_CACHE = {}


def _job(script):
    """A tool's status, or None. A tool that fails to report must not take the
    panel down with it — the whole point is to be readable when things are odd.

    Cached for the life of one render: the panel and the storage sampler both
    want the strip pass's in-flight byte count, and spawning an interpreter
    twice to ask the same question twice would also let the two answers differ
    by however long the second one took."""
    if script in _JOBS_CACHE:
        return _JOBS_CACHE[script]
    _JOBS_CACHE[script] = None
    try:
        r = subprocess.run([PY, str(S / script), "--status-json"],
                           capture_output=True, text=True, timeout=25)
        _JOBS_CACHE[script] = json.loads(r.stdout.strip())
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    return _JOBS_CACHE[script]


def _chain():
    try:
        kv = dict(l.strip().split("=", 1)
                  for l in CHAIN_STATE.read_text().splitlines() if "=" in l)
    except (OSError, ValueError):
        return None
    pid = kv.get("pid", "")
    if not pid.isdigit() or not os.path.isdir(f"/proc/{pid}") \
            or kv.get("state") != "waiting":
        return None
    return kv



def _roots():
    """Library drives, from codec's own config — not a hardcoded list, so a drive
    added to codec appears here without touching this file."""
    seen = []
    try:
        cfg = json.loads((Path.home() / ".config/codec/config.json").read_text())
        for r in cfg.get("roots", []):
            p = r.get("path", "")
            parts = p.split(os.sep)
            mnt = os.sep.join(parts[:3]) if len(parts) > 2 else p
            if mnt.startswith("/mnt/") and mnt not in seen and os.path.isdir(mnt):
                seen.append(mnt)
    except (OSError, ValueError):
        pass
    return sorted(seen)
# ── live system counters ─────────────────────────────────────────────────────
# All of these are DELTAS against the previous render. A counter's absolute
# value says nothing ("this drive has read 1.4 billion sectors"); the rate is
# the whole point, and the rate needs two samples.
def _diskstats():
    """{major:minor -> (read_bytes, written_bytes)} for every block device."""
    out = {}
    try:
        with open("/proc/diskstats") as f:
            for line in f:
                p = line.split()
                if len(p) > 9:
                    out[f"{p[0]}:{p[1]}"] = (int(p[5]) * 512, int(p[9]) * 512)
    except OSError:
        pass
    return out


def _devkey(mount):
    try:
        st = os.stat(mount)
        return f"{os.major(st.st_dev)}:{os.minor(st.st_dev)}"
    except OSError:
        return ""


def _cpu():
    """(busy_jiffies, total_jiffies) from /proc/stat."""
    try:
        with open("/proc/stat") as f:
            p = [int(x) for x in f.readline().split()[1:]]
        return sum(p) - p[3] - (p[4] if len(p) > 4 else 0), sum(p)
    except (OSError, ValueError, IndexError):
        return None


def _gpu():
    """NVENC is what the DV drain lives on, so encoder load is the number that
    says whether a normalize is really working or merely running. 25ms."""
    try:
        r = subprocess.run(
            ["nvidia-smi", "--query-gpu=utilization.gpu,utilization.encoder,"
             "utilization.decoder,temperature.gpu,memory.used,memory.total",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=4)
        v = [int(x.strip()) for x in r.stdout.strip().split(",")]
        return dict(zip(("gpu", "enc", "dec", "temp", "vram", "vram_max"), v))
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


def _proc_started(pid):
    """When a pid began, so a job can say how long it has been at it."""
    try:
        return os.stat(f"/proc/{pid}").st_mtime
    except OSError:
        return None


def _drive_temps():
    """{block device -> °C} for the library drives, from hwmon.

    hwmon, NOT smartctl: smartctl needs root here, and — more importantly — a
    SMART query can SPIN UP a sleeping drive. Something a 2s dashboard does to
    seven drives must never have that side effect. The drivetemp module reads
    the temperature the drive already reports, costs nothing, and needs no
    privileges once loaded.

    Empty until `modprobe drivetemp` has run; the panel simply omits the column.
    """
    out = {}
    try:
        for h in os.listdir("/sys/class/hwmon"):
            base = f"/sys/class/hwmon/{h}"
            try:
                with open(f"{base}/name") as f:
                    if f.read().strip() != "drivetemp":
                        continue
                dev = os.path.realpath(f"{base}/device")
                # .../block/sdc  — the block name is the child of "block"
                blk = next((p for p in dev.split(os.sep)), None)
                parts = dev.split(os.sep)
                if "block" in parts:
                    blk = parts[parts.index("block") + 1]
                else:
                    blk = next((n for n in os.listdir(f"{dev}/block")), None)
                with open(f"{base}/temp1_input") as f:
                    out[blk] = int(f.read().strip()) / 1000.0
            except (OSError, ValueError, IndexError, StopIteration):
                continue
    except OSError:
        pass
    return out


def _blockdev(mount):
    """The whole-disk name behind a mount ("sdc" for /mnt/Movies on sdc2) —
    temperature is a property of the DRIVE, not of the partition."""
    try:
        st = os.stat(mount)
        link = os.path.realpath(
            f"/sys/dev/block/{os.major(st.st_dev)}:{os.minor(st.st_dev)}")
        parts = link.split(os.sep)
        if "block" in parts:
            return parts[parts.index("block") + 1]
    except OSError:
        pass
    return ""


# ── torrents (qBittorrent Web API, on the Mint laptop) ───────────────────────
# Config lives OUTSIDE the repo at ~/.config/codec/qbit.json so a password is
# never committed:  {"host": "192.168.0.210", "port": 8080,
#                    "user": "admin", "pass": "…"}
# Absent config = no panel, silently. This is an optional source on another
# machine; the dashboard must be exactly as useful without it.
QBIT_CFG = Path.home() / ".config/codec/qbit.json"

# The previous sample, held IN THIS PROCESS. Rates are per-instance by nature:
# a --watch window redrawing every 2s and a one-shot panel open share one cache
# file, and if both wrote their rate state to it each would compute its rates
# against the other's timing and get nonsense — a live watch would silently
# lose its disk and CPU readings the moment someone opened the menu. Only the
# DAILY BASELINE is genuinely shared, because it is the same number for
# everyone. (Found the hard way: a Watch live window left open from an earlier
# build was overwriting every test sample here.)
_LAST = {}
_QBIT_SID = {}
# The session cookie, cached on disk. Held only in memory it was useless to a
# ONE-SHOT render — each menu open and each panel run logged in again, filling
# the laptop's qBittorrent log with "WebAPI login success" lines. Mode 600: it
# is a live session credential, not a preference.
QBIT_SID_FILE = Path.home() / ".cache/codec/qbit-sid"


def _qbit_cfg():
    try:
        c = json.loads(QBIT_CFG.read_text())
        return c if c.get("host") else None
    except (OSError, ValueError):
        return None


def _qbit(down_until=0):
    """(torrents, transfer, down_until) — downloading torrents and global rates.

    A dead host must never cost the panel its refresh: the laptop is asleep far
    more often than not, and a 2s redraw that blocks for a second on a closed
    port is worse than no torrent panel at all. So: short timeouts, and on any
    failure a 60-second backoff carried in the sample file — which is what makes
    it cheap for the one-shot renders (a menu open) as well as for --watch,
    since each of those is a fresh process with no memory of the last attempt."""
    cfg = _qbit_cfg()
    if not cfg or time.time() < down_until:
        return [], None, down_until
    base = f"http://{cfg['host']}:{cfg.get('port', 8080)}"

    def call(path, data=None):
        """(headers, body). Reads the body HERE rather than handing back the
        response: closing it in a `with` and returning the object leaves the
        caller holding a closed stream, and every read comes back empty."""
        req = urllib.request.Request(
            base + path,
            data=urllib.parse.urlencode(data).encode() if data else None,
            # qBittorrent rejects cross-site requests without a matching Referer.
            headers={"Referer": base, "Origin": base,
                     **({"Cookie": _QBIT_SID["sid"]} if "sid" in _QBIT_SID else {})})
        with urllib.request.urlopen(req, timeout=2.5) as r:
            return r.getheaders(), r.read()
    if "sid" not in _QBIT_SID:
        try:
            v = QBIT_SID_FILE.read_text().strip()
            if v:
                _QBIT_SID["sid"] = v
        except OSError:
            pass
    try:
        if "sid" not in _QBIT_SID and cfg.get("user"):
            hdrs, _ = call("/api/v2/auth/login",
                           {"username": cfg["user"], "password": cfg.get("pass", "")})
            for k, v in hdrs:
                if k.lower() == "set-cookie" and "SID" in v.split("=", 1)[0]:  # 4.x SID=, 5.x QBT_SID_<port>=
                    _QBIT_SID["sid"] = v.split(";")[0]
                    try:
                        QBIT_SID_FILE.parent.mkdir(parents=True, exist_ok=True)
                        QBIT_SID_FILE.write_text(_QBIT_SID["sid"])
                        os.chmod(QBIT_SID_FILE, 0o600)
                    except OSError:
                        pass
        # No filter. "downloading" omits state=moving — qBittorrent's term for
        # a COMPLETED torrent whose files are being relocated to their save
        # path — and those are precisely the ones writing to the library drives
        # right now, so the filter hid the most relevant rows on the panel.
        tor = json.loads(call("/api/v2/torrents/info")[1])
        xfer = json.loads(call("/api/v2/transfer/info")[1])
        return tor, xfer, 0
    except Exception:                      # urllib raises a wide family here
        # A stale cookie looks exactly like an unreachable host from here, so
        # drop it: the next call logs in again rather than backing off forever.
        _QBIT_SID.pop("sid", None)
        try:
            QBIT_SID_FILE.unlink(missing_ok=True)
        except OSError:
            pass
        return [], None, time.time() + 60


def _move_progress(t):
    """(copied_bytes, fraction) for a torrent qBittorrent is RELOCATING, or None.

    Measured in ALLOCATED BLOCKS, not st_size. qBittorrent preallocates the
    destination to its final length before writing a byte, so st_size reads
    100% from the first second of a copy — a percentage that is never wrong and
    never useful. st_blocks is what is actually on disk: American History X
    measured 9.11G of 9.1G by size and 7.34G by blocks while writing at
    46 MB/s.

    That mattered beyond the display. The stall watchdog keys off these same
    bytes, and a size that never changes during a healthy copy looks exactly
    like a wedged move — a 57G transfer would have sat "unchanged" past the ten
    minute threshold and been restarted mid-copy.

    The API has no move-progress field of its own; the destination is this
    machine's pool (the laptop mounts it over NFS), so the blocks on disk are
    the honest answer and cost nothing to read locally. path_map in qbit.json
    translates the laptop's view of a save path to ours."""
    cfg = _qbit_cfg() or {}
    save, size = t.get("save_path", ""), t.get("size", 0)
    for their, ours in (cfg.get("path_map") or {}).items():
        if save.startswith(their):
            save = ours + save[len(their):]
            break
    else:
        return None
    # The destination is named after the CONTENT PATH's last component, not the
    # torrent's display name — they differ whenever a single-file torrent is
    # named one thing and its file another ("Jaws 1975 UHD BluRay …" vs
    # "Jaws (1975).mkv"). Using the name reported 0 bytes for a title that was
    # already fully in the library, which then read as a stalled move.
    leaf = os.path.basename(t.get("content_path", "").rstrip("/")) \
        or t.get("name", "")
    dest = os.path.join(save, leaf)
    if not os.path.exists(dest):
        return 0, 0.0                       # not started — queued behind another
    n = 0
    try:
        if os.path.isfile(dest):
            n = os.stat(dest).st_blocks * 512
        else:
            for root, _d, files in os.walk(dest):
                for f in files:
                    try:
                        n += os.stat(os.path.join(root, f)).st_blocks * 512
                    except OSError:
                        pass
    except OSError:
        return None
    # Allocation can edge past the logical size (filesystem overhead), and a bar
    # over 100% reads as a bug rather than as rounding.
    return n, (min(1.0, n / size) if size else 0.0)


def torrents_panel(w, M):
    """What is touching disk, then what is transferring, then counts.

    "Moving" is qBittorrent's own state for a finished torrent being relocated
    to its save path — copying tens of gigabytes onto the pool — and it is the
    reason a library drive's free space drops with no codec job running. It
    outranks a download here for that reason: it is the row that explains the
    STORAGE panel above it.

    Of 256 torrents, 206 have never started. That is a queue, not a status, and
    it gets a number rather than 206 identical zeros."""
    tor, xfer = M["torrents"], M["xfer"]
    if not _qbit_cfg() or (not tor and not xfer):
        return []
    # The one actually copying leads its group. Moves are serialised — exactly
    # one runs — so burying it under four that have not started is the wrong way
    # round for the row you are watching.
    moving = sorted((t for t in tor if t.get("state") == "moving"),
                    key=lambda t: -((_move_progress(t) or (0, 0))[1]))
    dling = sorted((t for t in tor if t.get("state") != "moving"
                    and t.get("dlspeed", 0) > 0), key=lambda x: -x["dlspeed"])
    # Stalled earns a row: it is trying and failing, which you may want to act
    # on. Paused does not — it is stopped because someone stopped it, so it is
    # news to nobody and only crowds out the rows that are actually doing
    # something. (Newer qBittorrent says "stopped" where older said "paused".)
    stalled = [t for t in tor if t.get("state") != "moving"
               and t.get("dlspeed", 0) == 0 and 0 < t.get("progress", 0) < 1
               and not any(x in t.get("state", "").lower()
                           for x in ("paused", "stopped"))]
    rest = len(tor) - len(moving) - len(dling) - len(stalled)

    bits = []
    if xfer:
        bits.append(f"↓{u.human(xfer.get('dl_info_speed', 0))}/s "
                    f"↑{u.human(xfer.get('up_info_speed', 0))}/s")
    if moving:
        bits.append(f"{len(moving)} moving files")
    bits += [f"{len(dling)} downloading", f"{rest + len(stalled)} idle"]
    out = [u.rule("TORRENTS", w, " · ".join(bits))]

    # Finished-but-not-yet-imported: sitting on the laptop, waiting for the pull.
    ready = [t for t in tor if t.get("progress", 0) >= 1.0
             and t.get("content_path", "").startswith(
                 (_qbit_cfg() or {}).get("complete", "/home/seth/downloads/complete"))]
    running, cur = _import_state()
    if ready or running:
        gb = sum(t.get("size", 0) for t in ready) / 1024**3
        if running:
            out.append(f"  {u.c('⇩ IMPORT', u.GOOD)} "
                       f"{u.c('pulling ' + (cur[:w - 26] or '…'), u.TEXT)}")
        else:
            out.append(f"  {u.c('⇩ IMPORT', u.WARN)} "
                       f"{u.c(f'{len(ready)} title(s) / {gb:.0f}G waiting to import', u.TEXT)}")


    def row(t, kind):
        prog, size = t.get("progress", 0), t.get("size", 0)
        got = t.get("completed", 0) or int(prog * size)
        _ = size
        eta = t.get("eta", 0)
        if kind == "moving":
            glyph, col = u.c("⇄", u.ACCENT), u.ACCENT
            mv = _move_progress(t)
            if mv is not None:
                got, prog = mv[0], mv[1]
                rate = M["move_rate"].get(t.get("hash", t.get("name", "")))
                # Stalled describes the QUEUE, and only a move that has actually
                # started can be the one holding it up. A title at zero bytes is
                # waiting its turn — which is not a fault and must not be
                # painted as one.
                idle_for = M["queue_idle"] if got > 0 else 0
                if size and got >= size * 0.999:
                    # Every byte is at the destination. qBittorrent has not
                    # acknowledged the move, but the title IS in the library —
                    # calling that STALLED sends you looking for a problem that
                    # has already been solved.
                    glyph, col = u.c("✓", u.GOOD), u.GOOD
                    tail = u.c("in library".rjust(22), u.GOOD)
                elif idle_for > 300:
                    # Not moving and not changing. Say so loudly: a wedged move
                    # blocks every move behind it, and the panel showing a calm
                    # "queued to move" for ninety minutes is how this went
                    # unnoticed in the first place.
                    glyph, col = u.c("!", u.HOT), u.HOT
                    tail = u.c(f"STALLED {u.dur(idle_for)}".rjust(22), u.HOT)
                elif rate:
                    left = max(0, size - got) / rate if size else None
                    tail = (u.c(f"⇄{u.human(rate)}/s".rjust(10), u.ACCENT)
                            + u.c((f"eta {u.dur(left)}" if left else "").rjust(12),
                                  u.DIM))
                else:
                    tail = u.c(("copying" if 0 < prog < 0.999
                                else "queued to move" if prog <= 0
                                else "finishing").rjust(22), u.ACCENT)
            else:
                tail = u.c("moving files".rjust(22), u.ACCENT)
        elif kind == "dl":
            glyph, col = u.c("↓", u.GOOD), u.GOOD
            tail = (u.c(f"↓{u.human(t.get('dlspeed', 0))}/s".rjust(10), u.GOOD)
                    # qBittorrent's own ETA: it knows piece availability, and
                    # 8640000 is its "unknown" sentinel.
                    + u.c((f"eta {u.dur(eta)}" if 0 < eta < 8640000
                           else "").rjust(12), u.DIM))
        else:
            glyph, col = u.c("·", u.DIM), u.DIM
            tail = u.c(t.get("state", "").rjust(22), u.DIM)
        out.append(u.row(f"{glyph} {t.get('name', '?')[:17]}", prog,
                         _right(f"{prog * 100:.0f}%") + tail, w, lab_w=20, col=col))
        sub = f"{u.human(got)} of {u.human(size)}"
        if kind != "moving":
            sub += f" · {t.get('num_seeds', 0)} seeds"
        out.append(f"       {u.c('└', u.DIM)} {u.c(sub, u.DIM)}")

    for t in moving[:5]:
        row(t, "moving")
    for t in dling[:5]:
        row(t, "dl")
    for t in sorted(stalled, key=lambda x: -x["progress"])[:2]:
        row(t, "idle")
    return out


IMPORT_LOG = Path.home() / ".cache/codec/qbit-import.log"
IMPORT_LOCK = Path.home() / ".cache/codec/qbit-import.lock"


def _import_state():
    """(running, current, waiting, gb_pending) for the laptop→library import.

    This is the step that replaced qBittorrent's own file move, so it is now the
    only thing standing between a finished download and the library. It gets a
    row of its own: a pipeline nobody can see is a pipeline nobody notices has
    stopped."""
    running, cur = False, ""
    try:
        pid = IMPORT_LOCK.read_text().strip()
        running = pid.isdigit() and os.path.isdir(f"/proc/{pid}")
    except OSError:
        pass
    if running:
        try:
            for line in reversed(IMPORT_LOG.read_text(errors="replace").splitlines()):
                if "pulling" in line:
                    cur = line.split("pulling", 1)[-1].strip()
                    break
        except OSError:
            pass
    return running, cur


def _measure():
    """Everything the panel draws, sampled ONCE and compared to the previous
    render. Rates need two samples, so the whole of the last render is kept.

    Deltas in free space are cumulative against a DAILY baseline — that is the
    counter you watch fill. Everything else (disk throughput, CPU, write rate)
    is instantaneous against the previous render, because a rate is only
    meaningful over a short window."""
    now = time.time()
    today = datetime.fromtimestamp(now).strftime("%Y-%m-%d")
    shared = {}
    try:
        shared = json.loads(SAMPLE.read_text())
    except (OSError, ValueError):
        pass
    # In-process history wins for rates; the file is only the fallback for a
    # one-shot run, which has no history of its own.
    first = not _LAST
    prev = _LAST or shared
    dt = now - prev.get("t", 0) if prev.get("t") else 0
    fresh = 0.5 < dt < 300           # too old to be a rate, too close to divide

    rows, free_now, tot, used = [], {}, 0, 0
    for m in _roots():
        try:
            st = os.statvfs(m)
        except OSError:
            continue
        size, free = st.f_blocks * st.f_frsize, st.f_bavail * st.f_frsize
        tot += size
        used += size - free
        free_now[m] = free
        rows.append({"mount": m, "name": os.path.basename(m),
                     "frac": (size - free) / size if size else 0, "free": free})

    base = shared.get("base") or {}
    if base.get("day") != today or not base.get("free"):
        base = {"day": today, "t": now, "free": dict(free_now)}
    bf = base["free"]

    temps = _drive_temps()
    ds, pds = _diskstats(), prev.get("disk") or {}
    for r in rows:
        r["cum"] = free_now[r["mount"]] - bf[r["mount"]] if r["mount"] in bf else 0
        r["temp"] = temps.get(_blockdev(r["mount"]))
        k = _devkey(r["mount"])
        r["io"] = (0, 0)
        if fresh and k in ds and k in pds:
            r["io"] = ((ds[k][0] - pds[k][0]) / dt, (ds[k][1] - pds[k][1]) / dt)

    live = ((_job("codec_substrip.py") or {}).get("live") or [None])[0]
    wrate = None
    if fresh and prev.get("live") is not None and live is not None and live > prev["live"]:
        wrate = (live - prev["live"]) / dt

    tor, xfer, qdown = _qbit(shared.get("qbit_down_until", 0))
    # Per-torrent copied bytes, with the time they last CHANGED. A move that is
    # "queued" and a move that wedged an hour ago look identical in a single
    # sample — this is the only way the panel can tell them apart, and telling
    # them apart is the difference between a calm queue and 210 GB going
    # nowhere behind a hung NFS commit.
    seen = shared.get("moves") or {}
    moves, move_prev, move_rate = {}, {}, {}
    queue_moved = False
    for t in tor:
        if t.get("state") != "moving":
            continue
        mv = _move_progress(t)
        if mv is None:
            continue
        h, got = t.get("hash", t.get("name", "")), mv[0]
        was = seen.get(h)
        moves[h] = [now, got] if (not was or was[1] != got) else was
        # Rate against the PREVIOUS RENDER (not the last change), so a copy
        # reports throughput the way a download does. Without it a move that has
        # just begun is indistinguishable from one that never will: both show
        # 0 bytes, and only one of them is a problem.
        if not was or was[1] != got:
            queue_moved = True
        pv = (shared.get("move_prev") or {}).get(h)
        if pv and 0.5 < now - pv[0] < 300 and got > pv[1]:
            move_rate[h] = (got - pv[1]) / (now - pv[0])
        move_prev[h] = [now, got]

    # ONE clock for the whole queue, not one per move. Moves are serialised:
    # exactly one copies and the rest sit at zero bytes until their turn, so a
    # per-move timer marks every waiting title STALLED the moment it has waited
    # — which is what the panel did, painting four rows red while the head was
    # copying at 13 MB/s.
    if queue_moved or not moves:
        queue_since = now
    else:
        queue_since = shared.get("queue_since") or now

    cpu, pc = _cpu(), prev.get("cpu")
    cpu_frac = None
    if cpu and pc and cpu[1] > pc[1]:
        cpu_frac = (cpu[0] - pc[0]) / (cpu[1] - pc[1])

    # A ring of pool-free readings on a TIME axis, not a per-render one. Samples
    # were appended once per render, so a --watch ticking every 2s and a menu
    # opened twice an hour wrote into the same series and the sparkline's width
    # meant nothing — 14 marks could be 28 seconds or half a day. One sample per
    # 15s, 40 kept, is a ~10 minute window whatever is drawing it.
    hist = [h for h in (shared.get("hist") or [])
            if isinstance(h, list) and len(h) == 2][-39:]
    if not hist or now - hist[-1][0] >= 15:
        hist = hist + [[now, tot - used]]
    span = now - hist[0][0] if len(hist) > 1 else 0

    state = {"t": now, "free": free_now, "live": live, "disk": ds, "cpu": cpu}
    _LAST.clear()
    _LAST.update(state)
    try:
        SAMPLE.parent.mkdir(parents=True, exist_ok=True)
        # A long-lived instance publishes only what is shared. Its own rate
        # state stays in memory, where no other instance can disturb it and it
        # cannot disturb theirs.
        # moves/move_prev are SHARED, not per-instance: which torrent is copying
        # and how many bytes have landed is one global fact every instance
        # observes identically. They were dropped by an earlier refactor that
        # rewrote this write — which silently disabled the dashboard's stall
        # detection entirely, since `seen` was then always empty and every move
        # looked freshly changed on every render.
        out = {"base": base, "hist": hist, "qbit_down_until": qdown,
               "moves": moves, "move_prev": move_prev,
               "queue_since": queue_since}
        if first:
            out.update(state)
        else:
            out.update({k: shared.get(k) for k in state if k in shared})
        # MERGE, never replace. Several instances share this file — a --watch
        # redrawing every 2s, a menu open, the panel — and a long-lived one
        # holds whatever version of this module it started with. A wholesale
        # write means an older instance silently deletes every key added since
        # it launched: a watch window opened at 17:41 wiped `moves` and
        # `move_prev` on every tick, which disabled both the copy rate and the
        # stall detection while the source code looked correct.
        merged = dict(shared)
        merged.update(out)
        SAMPLE.write_text(json.dumps(merged))
    except OSError:
        pass

    return {"rows": rows, "tot": tot, "used": used, "hist": hist,
            "net": sum(r["cum"] for r in rows), "wrate": wrate,
            "since": datetime.fromtimestamp(base["t"]).strftime("%H:%M"),
            "cpu": cpu_frac, "gpu": _gpu(), "now": now, "span": span,
            "torrents": tor, "xfer": xfer, "moves": moves,
            "move_rate": move_rate, "queue_idle": now - queue_since}


# ── panels ───────────────────────────────────────────────────────────────────
def jobs_panel(w, M):
    out = [u.rule("JOBS", w, datetime.now().strftime("%H:%M:%S"))]
    ch = _chain()
    for script, _ in TOOLS:
        d = _job(script)
        if not d:
            out.append(f"  {u.c(script.ljust(13), u.DIM)}{u.c('status unavailable', u.HOT)}")
            continue
        at, of = d.get("prog_at", 0), d.get("prog_of", 0)
        frac = (at / of) if of else None
        if d["running"]:
            state, col = u.c("▶", u.GOOD), u.GOOD
        elif ch:
            state, col = u.c("⏸", u.WARN), u.WARN
        elif frac is not None and frac >= 1.0:
            state, col = u.c("✓", u.GOOD), u.GOOD
        else:
            state, col = u.c("·", u.DIM), u.DIM

        # Whole-pass ETA from observed pace, not from a guessed per-title cost:
        # elapsed divided by titles finished IS this machine's rate for this
        # queue, on these drives, with whatever else is competing right now.
        eta = ""
        if d["running"] and d.get("started") and at > 0 and of > at:
            el = M["now"] - d["started"]
            if el > 60:
                eta = f"eta {u.dur(el / at * (of - at))}"
        out.append(u.row(f"{state} {d['short']}", frac,
                         _right(f"{at}/{of}" if of else "idle") +
                         u.c(eta.rjust(12), u.DIM), w, lab_w=13, col=col))

        bits = [d.get("current")] if d["running"] else []
        if d.get("detail"):
            bits.append(d["detail"])
        if d["running"] and d.get("started"):
            bits.append(f"running {u.dur(M['now'] - d['started'])}")
        if not d["running"] and d.get("next"):
            bits.append(f"next: {d['next']}")
        note = " · ".join(b for b in bits if b)
        if note:
            out.append(f"     {u.c('└', u.DIM)} {u.c(note[:w - 8], u.DIM)}")

        live = d.get("live")
        if live and d["running"]:
            at_b, of_b, _nm = live
            feta = ""
            if M["wrate"] and of_b > at_b:
                feta = f"eta {u.dur((of_b - at_b) / M['wrate'])}"
            lab = f"       ↳ {u.rate(M['wrate'])}" if M["wrate"] else "       ↳ writing"
            out.append(u.row(lab, (at_b / of_b) if of_b else None,
                             _right(f"{u.human(at_b)} of {u.human(of_b)}") +
                             u.c(feta.rjust(12), u.DIM),
                             w, lab_w=18, col=u.STEEL))
    if ch:
        out.append("")
        out.append(f"  {u.c('⏳ queued', u.WARN)} — after {ch.get('waiting_on', '?')}: "
                   f"{u.c(ch.get('starts', '?'), u.TEXT)}")
    return out


def storage_panel(w, M):
    tot, used = M["tot"], M["used"]
    out = [u.rule("STORAGE", w,
                  f"{u.human(tot - used)} free of {u.human(tot)}"
                  + (f"   {u.delta(M['net']).strip()} since {M['since']}"
                     if M["net"] else ""))]
    for r in M["rows"]:
        rd, wr = r["io"]
        # Only a drive doing something says so. Seven idle "0/s" columns is the
        # noise this panel exists to cut.
        io = ""
        if u.rate(rd):
            io += u.c(f"↑{u.rate(rd)}", u.STEEL)
        if u.rate(wr):
            io += ("  " if io else "") + u.c(f"↓{u.rate(wr)}", u.ACCENT)
        pad = max(0, 16 - len(u._plain(io)))
        t = r.get("temp")
        # A drive's temperature only earns its column when it is worth looking
        # at; 38°C on a spinning disk is not news, 50°C is.
        tcol = (u.c(f"{t:.0f}°C".rjust(6),
                    u.HOT if t >= 50 else u.WARN if t >= 45 else u.DIM)
                if t else " " * 6)
        out.append(u.row(r["name"], r["frac"],
                         _right(f"{u.human(r['free'])} free", r["cum"])
                         + "  " + " " * pad + io + tcol, w, lab_w=13))
    if M["rows"]:
        # Name what the sparkline is. An unlabelled squiggle is decoration:
        # it was drawing pool free space and read as anything at all.
        out.append(u.rule("", w))
        # Same right-hand width as a drive row (value+delta+io+temp), so the
        # summary bar ends exactly where the bars it summarises end.
        out.append(u.row("TOTAL", used / tot if tot else 0,
                         _right(f"{u.human(tot - used)} free", M["net"])
                         + "  " + u.spark([h[1] for h in M["hist"]], 14)
                         + u.c((f" {u.dur(M['span'])}" if M["span"] > 30
                                else "").ljust(8), u.DIM),
                         w, lab_w=13, col=u.ACCENT))
    return out


def system_panel(w, M):
    g, cpu = M["gpu"], M["cpu"]
    if not g and cpu is None:
        return []
    out = [u.rule("SYSTEM", w)]
    left = u.row("CPU", cpu, _right(f"{cpu * 100:.0f}%") if cpu is not None else "",
                 w // 2 + 4, lab_w=6, bar_w=max(10, w // 2 - 26))
    if g:
        # NVENC is what the DV drain lives on, so encoder load is what says
        # whether a normalize is really working or merely running.
        vram = g["vram"] / 1024.0
        right = "   ".join([
            f'{u.c("GPU", u.TEXT)} {u.bar(g["gpu"] / 100, 10, u.pressure(g["gpu"] / 100))}'
            f' {str(g["gpu"]).rjust(3)}%',
            f'{u.c("enc", u.DIM)} {str(g["enc"]).rjust(3)}%',
            u.c(f'{g["temp"]}°C', u.pressure(g["temp"] / 90.0)),
            u.c(f'{vram:.1f}G vram', u.DIM),
        ])
        out.append(left + "   " + right)
    else:
        out.append(left)
    return out


def render(w=None):
    w = w or u.width()
    _JOBS_CACHE.clear()
    # Measure FIRST: the jobs panel is drawn above the storage panel but wants
    # the write rate that sampling storage derives.
    M = _measure()
    parts = ["", *jobs_panel(w, M), "", *storage_panel(w, M)]
    tp = torrents_panel(w, M)
    if tp:
        parts += ["", *tp]
    return "\n".join(parts + ["", *system_panel(w, M), ""])


def rofi_header(w=54):
    """The menu header: the same instrument, shrunk to fit above the choices.

    Pango markup rather than ANSI, but the identical bar code — a header drawn
    by a second implementation is a header that drifts out of step with the
    panel it heads."""
    u.set_mode("pango")
    _JOBS_CACHE.clear()
    M = _measure()
    lines, ch = [], _chain()
    if TITLE_FONT:
        lines.append(
            f'<span font_family="{TITLE_FONT}" size="x-large" '
            f'color="{u.HEX[u.ACCENT]}">{TITLE}</span>'
            f'<span color="{u.HEX[u.DIM]}">   '
            + datetime.now().strftime("%H:%M") + "</span>")
        lines.append("")
    for script, _ in TOOLS:
        d = _job(script)
        if not d:
            continue
        at, of = d.get("prog_at", 0), d.get("prog_of", 0)
        frac = (at / of) if of else None
        if d["running"]:
            glyph, col = "▶", u.GOOD
        elif ch:
            glyph, col = "⏸", u.WARN
        elif frac is not None and frac >= 1.0:
            glyph, col = "✓", u.GOOD
        else:
            glyph, col = "·", u.DIM
        lines.append(u.row(f"{u.c(glyph, col)} {d['short']}", frac,
                           _right(f"{at}/{of}" if of else "idle"), w,
                           lab_w=12, col=col))
    tot, used = M["tot"], M["used"]
    if tot:
        lines.append("")
        lines.append(u.row("STORAGE", used / tot,
                           _right(f"{u.human(tot - used)} free", M["net"]),
                           w, lab_w=12, col=u.ACCENT))
        if M["net"]:
            lines.append(u.c(f"                since {M['since']}", u.DIM))
    return "\n".join(lines)


def main():
    a = sys.argv[1:]
    if a and a[0] == "--rofi":
        print(rofi_header(int(a[1]) if len(a) > 1 else 54))
        return
    if a and a[0] == "--watch":
        # Re-exec when this file changes. A watch holds whatever version it
        # started with, so every fix landed while one is open leaves it showing
        # stale behaviour — twice today it was still painting rows STALLED that
        # the current code does not. Restarting itself costs one frame.
        me = Path(__file__).resolve()
        try:
            stamp = me.stat().st_mtime
        except OSError:
            stamp = 0
        try:
            while True:
                try:
                    if me.stat().st_mtime != stamp:
                        sys.stdout.write("\033[H\033[J" +
                                         u.c("  reloading…\n", u.DIM))
                        sys.stdout.flush()
                        os.execv(sys.executable, [sys.executable, str(me), *a])
                except OSError:
                    pass
                # ⚠ Fit the frame to the WINDOW. \033[H\033[J clears correctly,
                # but if the render is taller than the terminal the write itself
                # scrolls, "home" is no longer the top of the frame, and every
                # tick stacks a new panel below the last instead of replacing it
                # — which is exactly what a 40-line panel does in a 35-line
                # window. Truncating from the BOTTOM keeps JOBS, the part being
                # watched, and drops the tail that overflowed.
                rows = shutil.get_terminal_size((80, 24)).lines
                body = render().split("\n")
                tail = u.c("  (ctrl-c to quit)", u.DIM)
                if len(body) + 2 > rows:
                    body = body[:max(1, rows - 3)]
                    tail = u.c(f"  … {rows}-row window, panel trimmed · "
                               "ctrl-c to quit", u.DIM)
                sys.stdout.write("\033[H\033[J" + "\n".join(body) + "\n" + tail + "\n")
                sys.stdout.flush()
                time.sleep(2)
        except KeyboardInterrupt:
            print()
        return
    print(render())


if __name__ == "__main__":
    main()
