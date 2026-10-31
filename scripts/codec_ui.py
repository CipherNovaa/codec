#!/usr/bin/env python3
"""Shared terminal look for codec's ops tools.

The SUPER+SHIFT+M panel began as a DV-normalize utility and grew into the place
every long job is watched from. Each tool had grown its own idea of a status
block, so the combined view was four dialects stacked — a table here, a bare
percentage there. This is the one visual language they all speak.

Percentages are the thing being fixed. "97%" and "86%" are the same shape of
answer and take the same effort to read; a bar is read at a glance and shows
which drive is the problem without comparing digits.
"""
import os
import re
import shutil
import subprocess
import sys

def yield_io():
    """Drop this process (and everything it spawns) to idle IO priority.

    codec's long jobs and the NFS server share the same spindles. A strip pass
    reading and writing ~50 MB/s starved nfsd badly enough that its socket
    backed up 23 MB and every nfsd thread sat blocked — which wedged the
    laptop's mount, which hung seven torrent moves for ninety minutes. The jobs
    are background work by definition; nothing should ever wait behind them.

    Idle class only means anything under BFQ or CFQ, which these drives use.
    Children inherit it, so the ffmpeg and mkvmerge this spawns are covered
    without being launched specially. Best-effort: never worth failing a job.
    """
    try:
        subprocess.run(["ionice", "-c", "3", "-p", str(os.getpid())],
                       check=False, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=5)
    except (OSError, subprocess.SubprocessError):
        pass


# ── palette ──────────────────────────────────────────────────────────────────
# Codec's chrome is fixed steel with a single warm accent; the terminal follows.
# 256-colour, not truecolor: this shows up over ssh and in tmux too.
STEEL, DIM, TEXT = 66, 240, 250
GOOD, WARN, HOT, ACCENT = 108, 179, 167, 143

# The same palette as hex, for surfaces that take Pango markup rather than ANSI
# — the rofi header draws the identical bars, and two palettes would drift.
HEX = {66: "#5f8787", 240: "#585858", 250: "#bcbcbc",
       108: "#87af87", 179: "#d7af5f", 167: "#d75f5f", 143: "#afaf5f"}
MODE = "ansi"          # or "pango"


def set_mode(m):
    global MODE
    MODE = m


def _tty():
    if os.environ.get("NO_COLOR"):
        return False
    if os.environ.get("CODEC_UI_COLOR") == "1":
        return True
    return sys.stdout.isatty()


def _esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def c(s, col, bold=False):
    """Colour `s`, or return it untouched when the output is not a terminal —
    a status piped into a log or a notification must not carry escape codes."""
    if MODE == "pango":
        return f'<span color="{HEX.get(col, "#bcbcbc")}">{_esc(s)}</span>'
    if not _tty():
        return s
    return f"\033[{'1;' if bold else ''}38;5;{col}m{s}\033[0m"


def width(default=78):
    try:
        return max(60, min(shutil.get_terminal_size().columns, 110))
    except OSError:
        return default


# ── bars ─────────────────────────────────────────────────────────────────────
_EIGHTHS = " ▏▎▍▌▋▊▉█"


def bar(frac, w=28, col=None, track=DIM):
    """A proportional bar with EIGHTH-character resolution.

    Whole blocks alone quantise to 1/w — on a 28-wide bar every drive between
    82% and 85% draws identically, which defeats the point of drawing it. The
    partial-block glyphs give 8x that for free, so two drives a percent apart
    actually look a percent apart."""
    frac = 0.0 if frac is None else max(0.0, min(1.0, frac))
    total_eighths = int(round(frac * w * 8))
    full, rem = divmod(total_eighths, 8)
    full = min(full, w)
    head = "█" * full + (_EIGHTHS[rem] if rem and full < w else "")
    return c(head, col if col is not None else STEEL) + c("─" * (w - len(head)), track)


def pressure(frac):
    """Colour by how close to full — the only judgement the bar makes."""
    if frac is None:
        return DIM
    return HOT if frac >= 0.95 else WARN if frac >= 0.85 else GOOD


def human(n):
    """Bytes as a short human string. Always 1 decimal below 10 units so a
    column of these stays the same width and reads as a column."""
    n = float(n)
    for unit in ("B", "K", "M", "G", "T"):
        if abs(n) < 1024 or unit == "T":
            return f"{n:.0f}{unit}" if (n >= 10 or unit == "B") else f"{n:.1f}{unit}"
        n /= 1024.0


def delta(n, width=8):
    """A change in the FREE figure it sits beside: +4.2G / −320M.

    Words ("freed 4.2G") disambiguated the sign but cost half the column, and
    the sign is only ever ambiguous in isolation. Placed immediately after the
    number it modifies, +/− needs no convention: the free figure went up, or it
    went down. Green up, amber down, same as everywhere else.

    The width is reserved even when there is no change — a column that appears
    and disappears between refreshes makes the panel twitch, which reads as
    noise rather than as information."""
    if not n:
        return " " * width
    return c(f"{'+' if n > 0 else '−'}{human(abs(n))}".rjust(width),
             GOOD if n > 0 else WARN)


_SPARK = "▁▂▃▄▅▆▇█"


def spark(vals, w=8):
    """A sparkline of the last `w` values, scaled to their OWN range.

    Absolute scaling would draw every sample at the same height: pool free
    space moves by gigabytes against a terabyte axis. What is worth seeing is
    the SHAPE — climbing, falling, sawtoothing as remuxes land — so the range
    is the window's own min..max, and a flat window draws flat."""
    v = [x for x in vals if x is not None][-w:]
    if len(v) < 2:
        return " " * w
    lo, hi = min(v), max(v)
    # Pad BEFORE colouring, never after: rjust on an already-escaped string
    # measures the escape codes and adds no padding at all.
    body = ("─" * len(v)).rjust(w) if hi == lo else "".join(
        _SPARK[min(7, int((x - lo) / (hi - lo) * 7.999))] for x in v).rjust(w)
    return c(body, DIM if hi == lo else STEEL)


def dur(secs):
    """A duration at two units of precision — "2h 14m", never "2h 14m 08s".
    The third unit is noise at every scale this panel shows."""
    if secs is None or secs < 0:
        return ""
    secs = int(secs)
    if secs < 60:
        return f"{secs}s"
    if secs < 3600:
        return f"{secs // 60}m {secs % 60:02d}s"
    if secs < 86400:
        return f"{secs // 3600}h {(secs % 3600) // 60:02d}m"
    return f"{secs // 86400}d {(secs % 86400) // 3600:02d}h"


def rate(bps):
    """Bytes/sec, or blank. Below 512 KB/s is idle noise on these drives —
    a drive ticking over at 40 KB/s is not doing work worth reporting."""
    if not bps or bps < 512 * 1024:
        return ""
    return f"{human(bps)}/s"


# ── frames ───────────────────────────────────────────────────────────────────
def rule(title="", w=None, right=""):
    """A titled rule. The title sits INSIDE the line rather than above it, so a
    stack of panels reads as one instrument instead of separate printouts."""
    w = w or width()
    if not title and not right:
        return c("─" * w, DIM)          # a plain divider, not an empty label
    left = f"── {title} " if title else "── "
    tail = f" {right} ──" if right else "──"
    # _plain: `right` routinely carries colour (a delta), and measuring the raw
    # string makes the rule short by exactly the length of the escape codes —
    # which is why the STORAGE rule stopped reaching the edge once it grew one.
    fill = max(0, w - len(left) - len(_plain(tail)))
    return c(left, STEEL) + c("─" * fill, DIM) + c(tail, STEEL)


def row(label, frac, right, w=None, lab_w=11, bar_w=None, col=None):
    """One metered line: label, bar, value. The value is right-aligned so the
    column of numbers lines up under itself."""
    w = w or width()
    bar_w = bar_w or max(12, w - lab_w - len(_plain(right)) - 6)
    # Pad on the DRAWN width. A label carrying its own colour (a ▶ state glyph,
    # say) is far longer as a string than on screen, so ljust() sees a string
    # already past the target and pads nothing — the bar then starts flush
    # against the text and that one row falls out of the column.
    pad = " " * max(0, lab_w - len(_plain(label)))
    # A label may arrive already styled (a coloured state glyph). Colouring it
    # again would nest ANSI harmlessly but ESCAPE the markup in pango mode,
    # printing the tags instead of applying them.
    styled = "\033" in label or "<span" in label
    return (f"  {label if styled else c(label, TEXT)}{pad}"
            f"{bar(frac, bar_w, col if col is not None else pressure(frac))}"
            f"  {right}")


def _plain(s):
    """Length of `s` as DRAWN — escape codes take columns in the string but none
    on screen, so padding computed on the raw string is silently wrong."""
    if MODE == "pango":                     # markup takes no columns either
        return re.sub(r"<[^>]+>", "", s)
    out, i = [], 0
    while i < len(s):
        if s[i] == "\033":
            while i < len(s) and s[i] != "m":
                i += 1
            i += 1
            continue
        out.append(s[i])
        i += 1
    return "".join(out)
