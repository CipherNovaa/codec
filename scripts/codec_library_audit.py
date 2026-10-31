#!/usr/bin/env python3
"""Check the library against itself: is each file what codec says it is?

Identification is a chain of guesses — a folder name is parsed into a title, a
title is searched on TMDB, and TMDB's TOP HIT is taken as the answer. Every
link fails quietly. A wrong match looks exactly like a right one: poster,
plot, cast, all confidently wrong.

So this asks questions the guesses can't answer for themselves:

  RUNTIME   the strongest signal by far. TMDB says how long the film is and
            the file knows how long it is. Drunken Master II was matched to
            Drunken Master III — both 1994, so the year could not break the
            tie — and the runtimes differed by 11 minutes. This finds that
            class without knowing anything about either film.
  YEAR      the folder says one year and TMDB another.
  MISSING   no metadata at all: nothing to show on a detail page.
  TITLE     release junk left in the title (EXTENDED, REPACK, a group tag) —
            it breaks the TMDB search AND makes two copies of one film look
            like two different films, which is how a duplicate hides.
  EPISODES  files in a show that carry no episode number.

Read-only. Nothing here writes to the library.

    python3 scripts/codec_library_audit.py [--probe-limit N]
"""
import argparse
import json
import os
import re
import sqlite3
import subprocess
import sys
from pathlib import Path
import codec_paths  # where codec's data lives (~/.local/share/codec)

DB = codec_paths.DB
CFG = Path.home() / ".config/codec/config.json"
MANIFEST = codec_paths.MANIFEST
DURCACHE = Path.home() / ".cache/codec/durations.json"

# Tokens that are about the RELEASE, not the film. A title still carrying one
# of these is a title TMDB will struggle with.
JUNK = re.compile(
    r"\b(EXTENDED|UNRATED|REPACK|PROPER|REMASTERED|DIRECTORS?[ .]CUT|UNCUT|"
    r"INTERNATIONAL[ .]CUT|THEATRICAL|IMAX|RARBG|YTS|YIFY|"
    r"x26[45]|HEVC|AVC|BluRay|WEB-?DL)\b", re.I)
# ⚠ Group names that are also ordinary English words cannot be matched
# case-insensitively: "SILENCE" flagged The Silence of the Lambs. Only ever
# as an all-caps token.
JUNK_GROUPS = re.compile(r"\b(TIGOLE|BOKUTOX|SAMPA|BANDI|SILENCE|SWTYBLZ|FGT|IAMABLE)\b")

RUNTIME_TOLERANCE = 0.08   # 8% — PAL speedup and credits live inside this
RUNTIME_FLOOR_MIN = 6      # ...but never flag less than 6 minutes of drift

# A release that DECLARES an alternate cut is expected to disagree with TMDB,
# which stores one runtime — usually the theatrical. Every runtime "mismatch"
# in this library on the first run was one of these: Troy DC (196m vs 163),
# Leon EXTENDED (133 vs 111), Donnie Darko DC, Exorcist DC, Taken 2 UNRATED
# EXTENDED. Five false alarms bury the one real miss, which is how an audit
# stops being read.
#
# ⚠⚠ BUT THEY ARE SORTED, NEVER SUPPRESSED. Suppressing "declared cut AND
# longer than TMDB" was tried and it hid the one genuine miss this whole check
# was written for: the Drunken Master II folder says "International Cut", and
# the wrong match (Drunken Master III, 91m) was 10 minutes SHORTER than the
# file — which is exactly the shape of a legitimate extended cut. A filter
# that quiets the noise by the same rule the signal obeys is a filter that
# reports success while measuring nothing.
CUT_RE = re.compile(
    r"\b(DC|EXTENDED|UNRATED|UNCUT|DIRECTORS?[ .]?CUT|FINAL[ .]CUT|"
    r"INTERNATIONAL[ .]?CUT|ULTIMATE|SPECIAL[ .]EDITION|REDUX|"
    r"THE[ .]VERSION[ .]YOU|CRITERION|REMASTERED)\b", re.I)


def durations(paths, limit=0):
    """path -> seconds, cached. ffprobe is the only way to know."""
    try:
        cache = json.loads(DURCACHE.read_text())
    except (OSError, ValueError):
        cache = {}
    todo = [p for p in paths if os.path.exists(p)
            and f"{p}|{os.path.getsize(p)}" not in cache]
    if limit:
        todo = todo[:limit]
    for i, p in enumerate(todo, 1):
        print(f"\r  probing {i}/{len(todo)}…", end="", file=sys.stderr, flush=True)
        try:
            o = subprocess.run(
                ["/usr/bin/ffprobe", "-v", "error", "-show_entries",
                 "format=duration", "-of", "csv=p=0", p],
                capture_output=True, text=True, timeout=60).stdout.strip()
            cache[f"{p}|{os.path.getsize(p)}"] = float(o) if o else 0.0
        except Exception:
            cache[f"{p}|{os.path.getsize(p)}"] = 0.0
    if todo:
        print(file=sys.stderr)
        try:
            DURCACHE.parent.mkdir(parents=True, exist_ok=True)
            DURCACHE.write_text(json.dumps(cache))
        except OSError:
            pass
    return {p: cache.get(f"{p}|{os.path.getsize(p)}", 0.0)
            for p in paths if os.path.exists(p)}


def check_config():
    """config.json is device-local and rewritten by the app on exit, so nothing
    else validates it — yet a satellite that loses hubTailnet/syncUrl silently
    stops roaming (reachableHub keeps every hub URL on the dead LAN base) and
    hubBase() falls back to the satellite itself. Return a list of contract
    warnings. Empty on the hub or a well-formed satellite."""
    warns = []
    try:
        cfg = json.loads(CFG.read_text())
    except FileNotFoundError:
        return ["config.json missing — codec never ran, or wrong home dir"]
    except (json.JSONDecodeError, OSError) as e:
        return [f"config.json unreadable ({e})"]
    settings = cfg.get("settings", cfg)  # tolerate either shape
    # A satellite is a config that points at a remote library.
    is_satellite = bool(cfg.get("remoteLibrary") or settings.get("remoteLibrary"))
    if is_satellite:
        if not (cfg.get("hubTailnet") or settings.get("hubTailnet")):
            warns.append("satellite has NO hubTailnet — roaming casts/playback "
                         "will fail (every hub URL stays on the dead LAN base)")
        if not (cfg.get("syncUrl") or settings.get("syncUrl")):
            warns.append("satellite has NO syncUrl — hubBase() falls back to "
                         "127.0.0.1, so the satellite tries to serve itself")
    return warns


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--probe-limit", type=int, default=0,
                    help="cap how many files get a duration probe this run")
    ap.add_argument("--json", action="store_true",
                    help="one line of JSON for the UI instead of the report")
    args = ap.parse_args()

    man = json.loads(MANIFEST.read_text())["entries"]
    db = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    meta = {r[0]: {"title": r[1], "year": r[2], "runtime": r[3], "plot": r[4],
                   "poster": r[5], "tmdb": r[6]}
            for r in db.execute("SELECT path,title,year,runtime_min,plot,poster,"
                                "tmdb_id FROM metadata")}
    from urllib.parse import urlparse, unquote

    def real(e):
        return "/mnt" + unquote(urlparse(e["url"]).path)

    movies = [e for e in man if e["kind"] == "movie"]
    paths = [real(e) for e in movies]
    dur = durations(paths, args.probe_limit)

    findings = {"runtime": [], "cut": [], "year": [], "missing": [], "title": []}
    for e in movies:
        p = real(e)
        m = meta.get(p)
        if not m or not (m["plot"] or m["poster"]):
            findings["missing"].append((e["title"], p))
            continue
        # RUNTIME — the check that identifies a wrong film without knowing
        # anything about either of them.
        want = (m["runtime"] or 0) * 60
        got = dur.get(p, 0)
        if want and got:
            drift = abs(want - got) / 60
            declared_cut = bool(CUT_RE.search(os.path.basename(os.path.dirname(p))))
            if drift > max(RUNTIME_FLOOR_MIN, want * RUNTIME_TOLERANCE / 60):
                bucket = "cut" if (declared_cut and got > want) else "runtime"
                findings[bucket].append(
                    (e["title"], f"tmdb {m['runtime']}m vs file {got/60:.0f}m",
                     drift, p))
        # YEAR — the folder said one thing, TMDB another.
        # ⚠ the LAST year token, not the first — "Blade.Runner.2049.2017"
        # has the film's own name in it, and taking the first reported a
        # 32-year discrepancy on a correctly matched film.
        years = re.findall(r"\b(19[3-9]\d|20[0-4]\d)\b",
                           os.path.basename(os.path.dirname(p)))
        if years and m["year"] and abs(int(years[-1]) - m["year"]) > 1:
            findings["year"].append(
                (e["title"], f"folder {years[-1]} vs tmdb {m['year']}", p))
        # TITLE — release junk survived into the name.
        j = JUNK.search(e["title"]) or JUNK_GROUPS.search(e["title"])
        if j:
            findings["title"].append((e["title"], j.group(0), p))

    eps = [e for e in man if e["kind"] == "episode"]
    noep = [e for e in eps if not re.search(r"S\d{2}E\d{2}", e.get("title", ""))]
    cfg_warns = check_config()

    if args.json:
        # The app shows a headline, not a wall of text — and it must be able
        # to say "nothing wrong" as confidently as it says "3 problems".
        print(json.dumps({
            "movies": len(movies), "episodes": len(eps),
            "runtime": len(findings["runtime"]), "cuts": len(findings["cut"]),
            "year": len(findings["year"]), "missing": len(findings["missing"]),
            "title": len(findings["title"]), "unnumbered": len(noep),
            "config": cfg_warns,
            "urgent": sum(len(v) for k, v in findings.items() if k != "cut")
                      + len(noep) + len(cfg_warns),
            "worst": (sorted(findings["runtime"], key=lambda x: -x[2])[0][0]
                      if findings["runtime"] else ""),
        }))
        return 0

    print(f"\nLIBRARY AUDIT — {len(movies)} movies, {len(eps)} episodes, "
          f"{len([e for e in man if e['kind']=='extra'])} extras\n")

    print(f"── RUNTIME MISMATCH ({len(findings['runtime'])}) "
          "— likely the WRONG FILM ──")
    for t, cmp_, drift, p in sorted(findings["runtime"], key=lambda x: -x[2]):
        print(f"  {t[:34]:36s} {cmp_:26s} {drift:.0f}m off")
    print(f"\n── explained by a declared cut ({len(findings['cut'])}) "
          "— listed, not hidden ──")
    for t, cmp_, drift, p in sorted(findings["cut"], key=lambda x: -x[2]):
        print(f"  {t[:34]:36s} {cmp_:26s} {drift:.0f}m  "
              f"{CUT_RE.search(os.path.basename(os.path.dirname(p))).group(0)}")
    print(f"\n── YEAR MISMATCH ({len(findings['year'])}) ──")
    for t, cmp_, p in findings["year"]:
        print(f"  {t[:34]:36s} {cmp_}")
    print(f"\n── NO METADATA ({len(findings['missing'])}) ──")
    for t, p in findings["missing"][:15]:
        print(f"  {t[:34]:36s} {os.path.basename(p)[:52]}")
    print(f"\n── RELEASE JUNK IN TITLE ({len(findings['title'])}) "
          "— breaks search AND hides duplicates ──")
    for t, tok, p in findings["title"]:
        print(f"  {t[:44]:46s} ({tok})")
    print(f"\n── EPISODES WITH NO NUMBER ({len(noep)}) ──")
    shows = {}
    for e in noep:
        shows[e.get("show", "?")] = shows.get(e.get("show", "?"), 0) + 1
    for s, n in sorted(shows.items(), key=lambda x: -x[1]):
        print(f"  {s[:34]:36s} {n}")
    print(f"\n── CONFIG CONTRACT ({len(cfg_warns)}) ──")
    for w in cfg_warns:
        print(f"  ⚠ {w}")

    urgent = sum(len(v) for k, v in findings.items() if k != "cut") + len(noep) \
        + len(cfg_warns)
    print(f"\n{urgent} thing(s) worth a look"
          + (f", {len(findings['cut'])} explained by a declared cut" if findings["cut"] else "")
          + ".\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
