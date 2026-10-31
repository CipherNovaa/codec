#!/usr/bin/env python3
"""codec_dupes — find titles the library holds more than one copy of, compare the
copies on every axis that matters, and let a HUMAN remove the ones they choose.

Why it is built this way
------------------------
This tool never decides on its own. That is deliberate, and it is not timidity:

  * Identity by filename is unsafe. "Blade Runner" and "Blade Runner: The Final
    Cut" normalize to the same string. Grouping is therefore by codec's tmdb_id,
    which is a real database identity — and even that only became trustworthy on
    2026-09-09, when 119 Kodi-imported episode rows turned out to be carrying the
    ids of actual films (a Castlevania episode held Star Wars'). A tool that had
    trusted those ids would have offered to delete the Star Wars trilogy.

  * "Better" is not a single number. A weighted score always ends up trading
    something away silently. Indiana Jones and the Last Crusade is the proof:
    the 17.0G copy has Dolby Vision, the 11.1G copy has the TrueHD Atmos track.
    Neither dominates. A score would have picked one and quietly binned the other.

So the rule is DOMINANCE, not scoring: a copy is only ever marked redundant when
another copy is at least as good on EVERY axis and strictly better on at least
one. Anything else is reported as a trade-off and left entirely to you.

Byte-for-byte comparison is deliberately absent for the general case — two encodes
of one film are never byte-identical, which is the whole point. What it does
instead is compare stream inventories, match runtimes, verify the keeper actually
decodes, and (for copies whose flags are identical) hash sampled chunks of the
VIDEO STREAM, which is what tells you whether two files are the same encode in
different containers.

  codec_dupes.py                  # report only — never touches anything
  codec_dupes.py --verify         # + decode-check every copy (slower, thorough)
  codec_dupes.py --apply          # interactive: asks per group, moves to trash
"""
import argparse
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
from pathlib import Path
import codec_paths  # where codec's data lives (~/.local/share/codec)

DB = codec_paths.DB
CFG = Path.home() / ".config/codec/config.json"
_FF8 = Path.home() / "deps/ffmpeg-n8.1-static/bin"
FFPROBE = str(_FF8 / "ffprobe") if (_FF8 / "ffprobe").exists() else "ffprobe"
FFMPEG = str(_FF8 / "ffmpeg") if (_FF8 / "ffmpeg").exists() else "ffmpeg"
VIDEO_EXTS = (".mkv", ".mp4", ".m2ts", ".m4v")
TRASH_NAME = "_dupes-trash"

# An edition marker means a DIFFERENT CUT, not a duplicate. TMDB gives every cut of
# a film the same id, so this is the only thing standing between "you have two
# copies" and "you have the theatrical and the extended".
EDITION_RE = re.compile(
    r"\b(extended|director'?s|unrated|theatrical|uncut|remastered|imax|"
    r"final\s*cut|special\s*edition|ultimate|redux|assembly\s*cut)\b", re.I)
LOSSLESS = {"truehd", "flac", "mlp", "pcm_s16le", "pcm_s24le", "pcm_bluray", "dts"}
# The subtitle languages actually used here. Track COUNT is a bad axis: a UHD remux
# routinely carries 27-56 PGS tracks, and on Inglourious Basterds 794 MB of those
# 843 MB are languages nobody in this house reads. Counting them made a disc with
# every European language look "better" than one with clean English subs, so what
# is compared is English tracks only. "und" is included because an untagged track
# is usually the English one, and over-counting here only makes the tool warier.
KEEP_LANGS = {"eng", "en", "und", ""}


def run(cmd, timeout=120):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def biggest_video(p):
    """The feature file for a title — a title may be a folder or a bare file."""
    if os.path.isfile(p):
        return p
    best, bs = None, 0
    for r, _, fs in os.walk(p):
        for f in fs:
            if f.lower().endswith(VIDEO_EXTS):
                fp = os.path.join(r, f)
                try:
                    s = os.path.getsize(fp)
                except OSError:
                    continue
                if s > bs:
                    bs, best = s, fp
    return best


def has_dv(path):
    """A single-layer DV RPU on the first frame — the same signal the cast lane
    keys on. Not inferable from the filename: files advertising DoVi in their name
    routinely have no RPU at all."""
    try:
        out = run([FFPROBE, "-loglevel", "error", "-select_streams", "v:0",
                   "-read_intervals", "%+#1", "-show_frames", "-print_format", "json",
                   path], timeout=40).stdout
        return any(sd.get("side_data_type") in
                   ("Dolby Vision RPU Data", "Dolby Vision Metadata")
                   for fr in (json.loads(out or "{}").get("frames") or [])
                   for sd in (fr.get("side_data_list") or []))
    except Exception:
        return False


def probe(path):
    """Everything needed to compare two copies, in one ffprobe call plus the DV one."""
    out = run([FFPROBE, "-v", "error", "-show_streams", "-show_format",
               "-print_format", "json", path], timeout=90).stdout
    j = json.loads(out or "{}")
    fmt = j.get("format") or {}
    streams = j.get("streams") or []
    v = next((s for s in streams if s.get("codec_type") == "video"), {})
    auds = [s for s in streams if s.get("codec_type") == "audio"]
    subs = [s for s in streams if s.get("codec_type") == "subtitle"]

    def atmos(s):
        p = (s.get("profile") or "").lower()
        t = ((s.get("tags") or {}).get("title") or "").lower()
        return "atmos" in p or "joc" in p or "atmos" in t

    return {
        "path": path,
        "size": os.path.getsize(path),
        "dur": float(fmt.get("duration") or 0),
        "vcodec": v.get("codec_name", ""),
        "w": int(v.get("width") or 0),
        "h": int(v.get("height") or 0),
        "depth": int((v.get("bits_per_raw_sample") or 0) or 0),
        "res": res_class(int(v.get("width") or 0), int(v.get("height") or 0)),
        "hdr": v.get("color_transfer") in ("smpte2084", "arib-std-b67"),
        "dv": has_dv(path),
        "ch": max([int(a.get("channels") or 0) for a in auds], default=0),
        "atmos": any(atmos(a) for a in auds),
        "lossless": any((a.get("codec_name") or "").lower() in LOSSLESS
                        or "ma" in (a.get("profile") or "").lower() for a in auds),
        "naud": len(auds),
        "nsub": len(subs),
        "nsub_keep": sum(1 for x in subs
                         if ((x.get("tags") or {}).get("language") or "").lower()
                         in KEEP_LANGS),
        "acodecs": sorted({(a.get("codec_name") or "?") +
                           (f"/{a.get('channels')}ch" if a.get("channels") else "")
                           for a in auds}),
    }


# ── the comparison ───────────────────────────────────────────────────────────
# Every axis is "higher is better" and INDEPENDENT. Size is deliberately NOT an
# axis: a bigger file is not a better one, and treating it as one is how a bloated
# upscale beats a clean remux.
AXES = [("dv", "Dolby Vision"), ("hdr", "HDR"), ("res", "resolution"),
        ("ch", "audio channels"), ("atmos", "Atmos"), ("lossless", "lossless audio"),
        ("nsub_keep", "English subtitle tracks")]


def res_class(w, h):
    """Resolution CLASS, not exact pixels.

    Scope and letterbox crops move the stored height by tens of pixels with no
    bearing on quality: Rain Man's two copies are 3840x2076 and 3840x2080, and the
    Incredible Hulk's are 1606 vs 1632 tall. Comparing raw height made the crop a
    "resolution advantage" and blocked two otherwise unambiguous verdicts. Bucket by
    the long edge, the way a release is actually labelled."""
    m = max(w, h)
    for edge, cls in ((3840, 2160), (2560, 1440), (1920, 1080), (1280, 720)):
        if m >= edge - 64:          # tolerate a slightly cropped width too
            return cls
    return m


def dominates(a, b):
    """True when `a` is at least as good as `b` everywhere and better somewhere."""
    ge = all(int(a[k]) >= int(b[k]) for k, _ in AXES)
    gt = any(int(a[k]) > int(b[k]) for k, _ in AXES)
    return ge and gt


def wins(a, b):
    return [label for k, label in AXES if int(a[k]) > int(b[k])]


def decode_ok(path, dur, samples=4):
    """Decode short windows spread across the file, including one hard against the
    end. Truncated downloads — the failure that actually bites — read fine at the
    start and die at the tail, so a header check proves nothing."""
    if dur <= 0:
        return None, "unknown duration"
    pts = [dur * f for f in (0.02, 0.35, 0.7, 0.97)][:samples]
    for t in pts:
        r = run([FFMPEG, "-v", "error", "-xerror", "-ss", f"{t:.2f}", "-t", "4",
                 "-i", path, "-f", "null", "-"], timeout=180)
        if r.returncode != 0:
            return False, f"decode failed at {t/60:.0f}m: {(r.stderr or '').strip()[:90]}"
    return True, "decodes at start, middle and end"


def stream_md5(path, dur, chunks=3):
    """MD5 of COPIED video packets from sampled windows. Container-independent, so
    it answers the only question flags cannot: are these the same encode?"""
    hs = []
    for f in (0.1, 0.5, 0.85)[:chunks]:
        r = run([FFMPEG, "-v", "error", "-ss", f"{dur*f:.2f}", "-t", "6", "-i", path,
                 "-map", "0:v:0", "-c", "copy", "-f", "md5", "-"], timeout=120)
        hs.append((r.stdout or "").strip().replace("MD5=", "") or "?")
    return hs


def load_groups():
    """Movie-root titles sharing a tmdb_id. Grouping on the id rather than on a
    normalized filename is the whole safety story — see the module docstring."""
    roots = [r["path"] for r in json.loads(CFG.read_text())["roots"]
             if r["kind"] == "movies"]
    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    groups = {}
    for path, title, year, tid in con.execute(
            "SELECT path,title,year,tmdb_id FROM metadata "
            "WHERE tmdb_id IS NOT NULL AND tmdb_id != ''"):
        if "/" in tid:                      # composite id == an episode, not a film
            continue
        if not any(path.startswith(r + "/") for r in roots):
            continue
        if not os.path.exists(path):
            continue
        groups.setdefault(tid, {"title": title, "year": year, "paths": []})
        groups[tid]["paths"].append(path)
    return {k: v for k, v in groups.items() if len(v["paths"]) > 1}, con


def title_dir(p):
    """The folder that represents the title (what gets trashed), not the video file."""
    roots = [r["path"] for r in json.loads(CFG.read_text())["roots"]
             if r["kind"] == "movies"]
    q = Path(p)
    for parent in [q] + list(q.parents):
        if str(parent.parent) in roots:
            return parent
    return q


def analyse(group, verify=False):
    """Probe every copy, then classify the group. Returns (copies, verdict, note)."""
    copies = []
    for p in group["paths"]:
        v = biggest_video(p)
        if not v:
            continue
        info = probe(v)
        info["title_path"] = str(title_dir(v))
        info["editions"] = sorted({m.group(0).lower()
                                   for m in EDITION_RE.finditer(Path(info["title_path"]).name)})
        if verify:
            info["decode_ok"], info["decode_note"] = decode_ok(v, info["dur"])
        copies.append(info)
    if len(copies) < 2:
        return copies, "incomplete", "could not read every copy"

    # different CUTS are not duplicates — two independent signals, either is enough
    durs = [c["dur"] for c in copies if c["dur"]]
    if durs and (max(durs) - min(durs)) > 300:
        return copies, "different-cuts", (
            f"runtimes differ by {(max(durs)-min(durs))/60:.0f} min — different versions")
    edits = {tuple(c["editions"]) for c in copies}
    if len(edits) > 1:
        return copies, "different-cuts", (
            "edition markers differ: " +
            " vs ".join("/".join(e) or "(none)" for e in sorted(edits)))

    copies.sort(key=lambda c: -c["size"])
    best = copies[0]
    redundant = [c for c in copies[1:] if dominates(best, c)]
    if len(redundant) == len(copies) - 1:
        return copies, "dominated", ""
    return copies, "tradeoff", "no copy is better on every axis"


def fmt(c):
    tags = [t for t, on in (("DV", c["dv"]), ("HDR", c["hdr"]), ("ATMOS", c["atmos"]),
                            ("lossless", c["lossless"])) if on]
    tags.append(f"{c['ch']}ch")
    return (f"{c['size']/1024**3:6.1f}G  {c['w']}x{c['h']:<5} "
            f"{c['dur']/60:5.0f}m  {','.join(tags):32} "
            f"{c['naud']}a/{c['nsub']}s({c['nsub_keep']}en)")


def main():
    ap = argparse.ArgumentParser(description="find and review duplicate titles")
    ap.add_argument("--verify", action="store_true",
                    help="decode-check every copy (start/middle/end) — slower")
    ap.add_argument("--apply", action="store_true",
                    help="interactively offer to trash redundant copies")
    ap.add_argument("--deep", action="store_true",
                    help="hash sampled video packets when copies look identical")
    a = ap.parse_args()
    if a.apply:
        a.verify = True                 # never offer a removal without a decode check

    groups, con = load_groups()
    if not groups:
        print("no duplicate titles found.")
        return
    print(f"═══ {len(groups)} title(s) held more than once ═══\n")

    actions = []
    for tid, g in sorted(groups.items(), key=lambda kv: kv[1]["title"] or ""):
        copies, verdict, note = analyse(g, verify=a.verify)
        print(f"── {g['title']} ({g['year']})   tmdb:{tid}")
        if not copies:
            print("     (unreadable)\n")
            continue
        best = copies[0]
        for c in copies:
            mark = "KEEP " if c is best and verdict == "dominated" else "     "
            print(f"  {mark}{fmt(c)}")
            print(f"        {Path(c['title_path']).name[:84]}")
            if a.verify and c.get("decode_ok") is False:
                print(f"        ⚠ {c['decode_note']}")
            elif a.verify and c.get("decode_ok") is True:
                # Say so out loud. A verification that only speaks on failure is
                # indistinguishable from one that never ran.
                print(f"        ✔ {c['decode_note']}")
            # media_state is the one table keyed RELATIVE to /mnt
            # ("Movies5/Movies/…"); an absolute path never matched.
            rel = os.path.relpath(c["path"], "/mnt") \
                if c["path"].startswith("/mnt/") else c["path"]
            hist = con.execute("SELECT play_count,last_play_at FROM media_state "
                               "WHERE path=?", (rel,)).fetchone()
            if hist and hist[0]:
                print(f"        ▸ watched {hist[0]}x (last {hist[1]})")

        if verdict == "dominated":
            losers = copies[1:]
            for l in losers:
                print(f"     → redundant: {best['size']/1024**3:.1f}G copy wins on "
                      f"{', '.join(wins(best, l)) or 'every axis equally'}")
            if a.verify and best.get("decode_ok") is not True:
                print("     ✗ NOT offering removal — the copy to keep did not verify")
            else:
                actions.append((g["title"], best, losers))
        elif verdict == "different-cuts":
            print(f"     ⊘ left alone — {note}")
        elif verdict == "tradeoff":
            for other in copies[1:]:
                w = wins(other, best)
                if w:
                    print(f"     ⚖ the {other['size']/1024**3:.1f}G copy is better on: "
                          f"{', '.join(w)}")
            print("     ⊘ your call — no copy dominates")
            if a.deep and all(c["dv"] == best["dv"] and c["hdr"] == best["hdr"]
                              and c["h"] == best["h"] for c in copies):
                print("     hashing video packets to see if these are the same encode…")
                hs = [stream_md5(c["path"], c["dur"]) for c in copies]
                same = all(h == hs[0] for h in hs[1:])
                print(f"     {'✔ IDENTICAL video stream' if same else '✗ different encodes'}")
        print()

    if not a.apply:
        print(f"{len(actions)} group(s) have a clearly redundant copy.")
        print("Nothing has been touched. Re-run with --apply to review them one by one.")
        return

    print("═══ review ═══  (nothing is deleted — copies move to a trash folder)\n")
    freed = 0
    for title, best, losers in actions:
        print(f"{title}")
        print(f"   keep  {fmt(best)}")
        for l in losers:
            print(f"   trash {fmt(l)}")
        ans = input("   remove the redundant copy? [y/N] ").strip().lower()
        if ans != "y":
            print("   skipped\n")
            continue
        for l in losers:
            src = Path(l["title_path"])
            # Two copies in ONE folder (a 2160p added beside the 1080p) share a
            # title folder — moving it trashed the copy being kept as well.
            # Then only the redundant FILE goes.
            if Path(best["path"]).resolve().is_relative_to(src.resolve()):
                src = Path(l["path"])
            drive = Path("/mnt") / Path(src).resolve().parts[2]
            trash = drive / TRASH_NAME
            trash.mkdir(exist_ok=True)
            dst = trash / src.name
            n = 1
            while dst.exists():
                dst = trash / f"{src.name}.dup{n}"
                n += 1
            shutil.move(str(src), str(dst))
            freed += l["size"]
            print(f"   → moved to {dst}")
        print()
    print(f"reclaimed {freed/1024**3:.1f} GB into {TRASH_NAME}/ "
          f"(still on disk — delete those folders when you are happy)")


if __name__ == "__main__":
    main()
