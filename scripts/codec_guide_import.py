#!/usr/bin/env python3
"""Turn a viewing-guide spreadsheet into the guide file codec ships in its qrc.

The first guide is Andrew Carl's "Roadmap to Watching and Not Hating The
X-Files" (andrewcarlcomics.com), which colours every episode: part of the
STORY (the myth arc), a TOP-tier monster of the week, passable, or avoid it.
codec keeps the two that aren't taste — STORY and TOP — and both films, where
the guide places them in the series; the rest of the sheet (notes, season
lines, detours, the reel) is read only to check every row lands.

    scripts/codec_guide_import.py "~/Downloads/X-FILES Roadmap.xlsx"
        → assets/guides/the-x-files.json (checked against the library manifest)

The sheet's fill colour IS the verdict, so this reads the xlsx XML directly
(cell styles → fills); no openpyxl. Every row is matched to a library episode
by its title, not just its number (the sheet numbers S11's "Plus One" as 2), and
the run fails loudly on anything it can't place.
"""
import argparse
import json
import re
import sys
import unicodedata
import urllib.parse
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path
import codec_paths  # where codec's data lives (~/.local/share/codec)

NS = {"m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
REPO = Path(__file__).resolve().parent.parent
MANIFEST = codec_paths.MANIFEST

# fill colour of the row → verdict (the sheet's own KEY row)
VERDICT = {
    "FF00FFFF": "story",   # part of the overall STORY (for better & worse)
    "FF00FF00": "top",     # top-tier MONSTER OF THE WEEK
    "FFFFFF00": "pass",    # passable episode
    "FFF4CCCC": "avoid",   # avoid it
    "FFEAD1DC": "avoid",   # "Born Again": a second pink, same verdict
}
SEASON_WORDS = {"ONE": 1, "TWO": 2, "THREE": 3, "FOUR": 4, "FIVE": 5, "SIX": 6,
                "SEVEN": 7, "EIGHT": 8, "NINE": 9, "TEN": 10, "ELEVEN": 11}


def read_sheet(path):
    """Rows of {col: (text, fillRgb)} from the workbook's first sheet."""
    z = zipfile.ZipFile(path)
    ss = []
    if "xl/sharedStrings.xml" in z.namelist():
        for si in ET.fromstring(z.read("xl/sharedStrings.xml")).findall("m:si", NS):
            ss.append("".join(t.text or "" for t in si.iter("{%s}t" % NS["m"])))
    st = ET.fromstring(z.read("xl/styles.xml"))
    fills = []
    for f in st.find("m:fills", NS):
        pf = f.find("m:patternFill", NS)
        fg = pf.find("m:fgColor", NS) if pf is not None else None
        fills.append(fg.get("rgb") if fg is not None else None)
    xf_fill = [int(x.get("fillId", 0)) for x in st.find("m:cellXfs", NS)]
    sheet = ET.fromstring(z.read("xl/worksheets/sheet1.xml"))
    rows = []
    for r in sheet.find("m:sheetData", NS):
        row = {}
        for c in r:
            col = re.sub(r"\d", "", c.get("r"))
            v = c.find("m:v", NS)
            text = None
            if v is not None:
                text = ss[int(v.text)] if c.get("t") == "s" else v.text
            row[col] = ((text or "").strip(), fills[xf_fill[int(c.get("s", 0))]])
        rows.append(row)
    return rows


def norm(t):
    """A title for matching: no quotes, accents, numbering or punctuation."""
    t = re.sub(r"['\u2019]", "", t)                   # Mind's / Mind’s
    t = unicodedata.normalize("NFKD", t).encode("ascii", "ignore").decode()
    t = t.lower().replace("&", "and")
    t = re.sub(r"\((\d|i+)\)\s*$", "", t)          # "Dreamland (1)"
    t = re.sub(r"[^a-z0-9]+", " ", t)
    return " ".join(w for w in t.split() if w not in ("the", "a", "ii", "2"))


def library_episodes(show):
    """(season, episode) → title, from the hub's library manifest."""
    m = json.loads(MANIFEST.read_text())
    eps = {}
    for e in m["entries"]:
        if e.get("kind") != "episode" or e.get("show") != show:
            continue
        mm = re.match(r"S(\d+)E(\d+)\S* · (.*)", e["title"])
        if mm:
            eps[(int(mm.group(1)), int(mm.group(2)))] = mm.group(3)
    return eps


def build(rows, show):
    lib = library_episodes(show)
    by_title = {}
    for k, t in lib.items():
        by_title.setdefault(norm(t), []).append(k)

    guide = {
        "show": show,
        "tmdbId": "4087",
        "name": "Roadmap to Watching and Not Hating The X-Files",
        "short": "THE ROADMAP",
        "author": "Andrew Carl",
        "site": "andrewcarlcomics.com",
        "key": {
            "story": "Part of the overall STORY (for better & worse)",
            "top": "Top-tier MONSTER OF THE WEEK",
            "pass": "Passable episode",
            "avoid": "Avoid it",
        },
        "sections": [],     # in the guide's own order
        "reel": [],         # the highlight reel, [season, episode]
        "afterword": [],
    }
    section = None
    problems = []
    mode = "body"
    for row in rows[1:]:
        a, fill = row.get("A", ("", None))
        title = row.get("B", ("", None))[0].strip('"').strip()
        kind = row.get("C", ("", None))[0]
        note = re.sub(r";$", "", row.get("D", ("", None))[0]).strip()
        if not a and not title:
            continue
        if fill in ("FF000000", "FF434343") and not title:
            head = a
            if head.startswith("HIGHLIGHT REEL"):
                mode = "reel"
                continue
            if mode != "body":
                if not head.startswith("Picking out"):
                    guide["afterword"].append(head)
                continue
            m = re.match(r"SEASON\s+(\w+)(?:\s*/\s*\d+ MINISERIES)?\s*-\s*(.*)", head)
            if m:
                section = {"type": "season", "season": SEASON_WORDS[m.group(1)],
                           "blurb": m.group(2).strip(), "items": []}
            elif head.startswith("MOVIE"):
                n = sum(1 for s in guide["sections"] if s["type"] == "movie") + 1
                section = {"type": "movie", "tmdbId": ["846", "8836"][n - 1],
                           "blurb": head.split("-", 1)[1].strip(), "items": []}
            elif head.startswith("Spinoff Bonus Detour"):
                m = re.match(r"Spinoff Bonus Detour:\s*(.*?)\s*-\s*(.*)", head)
                series = m.group(1).split(" - ")[0]
                section = {"type": "detour", "series": series.title().replace("The Lone Gunmen", "The Lone Gunmen"),
                           "blurb": m.group(2).strip(), "items": []}
            else:
                problems.append("unplaced heading: " + head)
                continue
            guide["sections"].append(section)
            continue
        v = VERDICT.get(fill)
        if mode == "reel":
            m = re.match(r"s(\d+)\.e(\d+)", a)
            if m:
                guide["reel"].append([int(m.group(1)), int(m.group(2))])
            continue
        if section is None or v is None:
            problems.append(f"row without a section/verdict: {a} {title} ({fill})")
            continue
        if section["type"] == "season" and a == "43230.0":
            # "what? / no. / there are no other episodes" — the sheet's joke
            # row: every unlisted episode of the last season gets its note
            section["rest"] = {"verdict": v, "note": note}
            continue
        item = {"verdict": v, "kind": kind, "note": note}
        if section["type"] == "season":
            s = section["season"]
            nums = [int(float(x)) for x in re.findall(r"\d+(?:\.\d+)?", a)]
            want = (s, nums[0]) if nums else None
            hits = [k for k in by_title.get(norm(title), []) if k[0] == s]
            if want in lib and norm(lib[want]) == norm(title):
                key = want
            elif len(hits) == 1:
                key = hits[0]
            elif want in lib:
                key = want
                problems.append(f"S{s} {a} {title!r}: number only (library: {lib[want]!r})")
            else:
                problems.append(f"S{s} {a} {title!r}: not in the library")
                continue
            item["episode"] = key[1]
            item["title"] = title
            if key != want:
                print(f"  matched by title: S{s} {a} {title!r} → E{key[1]:02d}")
        else:
            item["title"] = title
            if section["type"] == "detour":
                item["episode"] = int(float(a))
        section["items"].append(item)

    # every library episode the guide never mentions (the last season's
    # extras take the joke row's verdict; anything else is reported)
    seen = {(s["season"], i["episode"]) for s in guide["sections"]
            if s["type"] == "season" for i in s["items"]}
    for (s, e), t in sorted(lib.items()):
        if (s, e) in seen:
            continue
        sec = next((x for x in guide["sections"] if x.get("season") == s), None)
        if sec and "rest" in sec:
            continue
        problems.append(f"S{s:02d}E{e:02d} {t!r}: in the library, not in the guide")
    for s, e in guide["reel"]:
        if (s, e) not in seen:
            problems.append(f"reel S{s}E{e}: not a guide episode")
    return guide, problems


KEEP = ("story", "top")


def lean(guide):
    """What codec shows: the STORY and TOP marks, in the guide's order."""
    secs = []
    for s in guide["sections"]:
        if s["type"] == "detour":
            continue
        items = [{k: i[k] for k in ("episode", "verdict") if k in i}
                 for i in s["items"] if i["verdict"] in KEEP]
        if not items and s["type"] != "movie":   # a film keeps its place, rated or not
            continue
        sec = {"type": s["type"]}
        sec.update({k: s[k] for k in ("season", "tmdbId") if k in s})
        sec["items"] = items
        secs.append(sec)
    return {k: guide[k] for k in ("show", "tmdbId", "name", "short", "author", "site")} \
        | {"sections": secs}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("xlsx")
    ap.add_argument("--show", default="The X-Files")
    ap.add_argument("--out", default=str(REPO / "assets/guides/the-x-files.json"))
    a = ap.parse_args()
    guide, problems = build(read_sheet(Path(a.xlsx).expanduser()), a.show)
    for p in problems:
        print("!!", p)
    counts = {}
    for s in guide["sections"]:
        if s["type"] != "detour":
            for i in s["items"]:
                counts[i["verdict"]] = counts.get(i["verdict"], 0) + 1
    print("sections:", len(guide["sections"]), "verdicts:", counts, "reel:", len(guide["reel"]))
    if problems:
        sys.exit("guide not written: fix the rows above")
    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(lean(guide), indent=1, ensure_ascii=False) + "\n")
    print("wrote", out)


if __name__ == "__main__":
    main()
