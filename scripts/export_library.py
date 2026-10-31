#!/usr/bin/env python3
"""Export the local library as a remote manifest for LAN clients (e.g. laptop).

Walks the same media roots the app scans, joins codec.db metadata, and rewrites
each on-disk path to an HTTP URL served by codec-serve.service (http.server over
/mnt on :8200). A client with `"remoteLibrary": "<manifest>"` in its config
loads this instead of scanning a filesystem and streams over the LAN — no mount,
no server-side app running. Stdlib only (Hermes-runnable).
"""
import argparse, hashlib, json, os, re, sqlite3, socket, subprocess, sys
from datetime import datetime
from pathlib import Path
from urllib.parse import quote, urlparse
import codec_paths  # where codec's data lives (~/.local/share/codec)

DB = codec_paths.DB
CFG = Path.home() / ".config/codec/config.json"
ART_DIR = Path.home() / ".cache/codec/art"
EXTRAS_INDEX = Path.home() / ".cache/codec/extras.json"
VIDEO_EXTS = {".mkv", ".mp4", ".avi", ".m2ts", ".ts", ".mov", ".wmv",
              ".flv", ".webm", ".mpg", ".mpeg", ".iso"}

YEAR_RE = re.compile(r"\b(19[3-9]\d|20[0-4]\d)\b")
QUAL_RE = re.compile(r"\b(2160p|1080p|720p|480p)\b", re.I)
HDR_RE = re.compile(r"\b(HDR|HDR10\+?|DV|DoVi|Dolby ?Vision)\b", re.I)
TOKEN_RE = re.compile(
    r"\b(2160p|1080p|720p|480p|UHD|BluRay|Blu-Ray|BDRip|WEB-?DL|WEBRip|WEB|HDTV|"
    r"REMUX|x26[45]|H ?26[45]|HEVC|AVC|DTS|DDP?|AAC|AC3|TrueHD|Atmos|10bit|8bit|"
    r"HDR10?|DV|YTS|YIFY|RARBG)\b", re.I)
# A double episode (S06E14E15, S01E01-E02) keys off the FIRST number — same
# pattern as codec_tmdb.EP_RE and library.cpp's episodeRe; keep all three equal.
EP_RE = re.compile(
    r"\b(?:S(\d{1,2})E(\d{1,3})(?:[-_. ]?E\d{1,3})*|(\d{1,2})x(\d{2,3}))\b", re.I)
# Plenty of shows number episodes without SxxExx — "Berserk - 01",
# "Patlabor ... Episode.01". codec_tmdb.py has understood these all along
# (episode_number()), so the SCRAPER knew they were episodes 1..25 while the
# manifest and the app labelled them by filename. Three walkers, three notions
# of what an episode is; this is the one that was actually disagreeing.
# ⚠ ANCHORED on purpose. The obvious pattern — "a dash then a number" —
# matched "Implanted Memories - 25 Years of The X-Files" and filed a
# featurette as S01E25. The number must END the name or be followed by a
# bracket; never by another word. "Episode N" keeps its keyword form, which
# is unambiguous.
EP_LOOSE_RE = re.compile(r"\bEpisode\s+(\d{1,3})\b", re.I)
EP_DASH_RE = re.compile(r"-\s+(\d{1,3})\s*(?=[\[(]|$)")


SEASON_DIR_RE = re.compile(r"^s(?:eason)?[\s._]*0*(\d{1,2})$", re.I)


# When the torrent importer placed each title (codec_qbit_import.py writes it) —
# codec's NEW mark. Mirrors library.cpp applyArrivals so the laptop marks the
# same titles: a key is the placed file or folder, anything at or under it
# arrived then.
ARRIVALS = codec_paths.ARRIVALS


def load_arrivals():
    try:
        return {k: int(v) for k, v in json.loads(ARRIVALS.read_text()).items()}
    except (OSError, ValueError, TypeError, AttributeError):
        return {}


def arrived_for(path, led):
    s, best = str(path), 0
    for k, t in led.items():
        if s == k or s.startswith(k + "/"):
            best = max(best, t)
    return best


def last_episode_in(name):
    """The last episode a double-episode name carries ("S09E19-E20" → 20), 0
    for a single one. Mirrors library.cpp lastEpisodeIn."""
    m = EP_RE.search(name)
    if not m or not m.group(1):
        return 0
    eps = re.findall(r"E(\d{1,3})", m.group(0), re.I)
    return int(eps[-1]) if len(eps) > 1 else 0


def without_part_one(name):
    """"The Truth (1)" → "The Truth" (library.cpp withoutPartOne)."""
    return re.sub(r"\s*\((?:1|Part 1|I)\)\s*$", "", name, flags=re.I) or name


def episode_number(name, path=None):
    """(season, episode) from a filename, or None. Same rule as the scraper.
    `path` (full episode path) lets a loose episode take its season from a
    Season N folder instead of hardcoding 1 (matches looseEpisode / the scraper)."""
    m = EP_RE.search(name)
    if m:
        return int(m.group(1) or m.group(3)), int(m.group(2) or m.group(4))
    flat = re.sub(r"[._]", " ", name)
    m = EP_LOOSE_RE.search(flat) or EP_DASH_RE.search(flat)
    if not m:
        return None
    season = 1
    if path:
        for comp in str(path).replace("\\", "/").split("/"):
            sm = SEASON_DIR_RE.match(comp.strip())
            if sm:
                season = int(sm.group(1))
    return (season, int(m.group(1)))
# Directories whose contents are ABOUT the show rather than part of it. They
# were being walked like any other: a file with no SxxExx still gets added,
# so one boxed set arrived with 181 featurettes sitting next to 226 episodes.
# ⚠ Matched on the DIRECTORY, never on "this file has no episode number" —
# plenty of real episodes don't (Berserk numbers its files "Berserk - 01"),
# and dropping those would delete a third of the shows in this library.
EXTRAS_RE = re.compile(
    r"/(featurettes?|extras?|behind[ .]the[ .]scenes|deleted[ .]scenes|bonus"
    r"|interviews?|trailers?|making[ .]of)/", re.I)

# ── what the FILE is, not what its name claims ──────────────────────────────
# A release name is a claim and it is often silent: 26 films in this library
# are real HDR10 — PQ transfer, bt2020 primaries, 10-bit — and say nothing
# about it in the filename, so they showed as plain "4K". That label is what
# you read when deciding which copy of a film to keep, and it nearly cost a
# better Interstellar during a drive import.
#
# Cached by path|size|mtime and SHARED with the C++ scanner (library.cpp), so
# whichever runs first pays for the probe and the other gets it free.
PROBE_CACHE = Path.home() / ".cache/codec/videoprobe.json"
_probe = None


def probe_cache():
    global _probe
    if _probe is None:
        try:
            _probe = json.loads(PROBE_CACHE.read_text())
        except (OSError, ValueError):
            _probe = {}
    return _probe


def save_probe_cache():
    try:
        PROBE_CACHE.parent.mkdir(parents=True, exist_ok=True)
        PROBE_CACHE.write_text(json.dumps(probe_cache()))
    except OSError:
        pass


def probe_video(p):
    """{"w","h","hdr","dv","ch","atmos"} for a video file, or {} if unreadable.

    Field-for-field mirror of probeVideo() in library.cpp — both sides write
    the same cache entries, and both re-probe entries cached before the
    audio/DV fields existed (no "ch" key)."""
    try:
        st = os.stat(p)
    except OSError:
        return {}
    key = f"{p}|{st.st_size}|{int(st.st_mtime)}"
    c = probe_cache()
    if key in c and "ch" in c[key]:
        return c[key]
    out = {"w": 0, "h": 0, "hdr": False, "dv": False, "ch": 0, "atmos": False}
    try:
        o = subprocess.run(
            ["/usr/bin/ffprobe", "-v", "error", "-show_streams",
             "-of", "json", str(p)],
            capture_output=True, text=True, timeout=45).stdout
        for s in json.loads(o).get("streams") or []:
            t = s.get("codec_type")
            if t == "video" and not out["w"]:
                out["w"] = s.get("width") or 0
                out["h"] = s.get("height") or 0
                out["hdr"] = s.get("color_transfer") in ("smpte2084", "arib-std-b67")
                out["dv"] = any(
                    "DOVI" in (d.get("side_data_type") or "").upper()
                    or "DOLBY VISION" in (d.get("side_data_type") or "").upper()
                    for d in s.get("side_data_list") or [])
            elif t == "audio" and not out["ch"]:
                out["ch"] = s.get("channels") or 0
                out["atmos"] = "atmos" in (s.get("profile") or "").lower()
    except Exception:
        pass
    c[key] = out
    return out


def probe_flags(pv):
    """Media-flag chips from the probe alone — mirrors probeFlags() in
    library.cpp: 4K and 1080p are badged, DV supersedes HDR10, object audio
    supersedes the channel count. Empty when the file couldn't be read.

    ⚠ This MUST stay in step with probeFlags() in library.cpp. The satellite
    takes its flags from this manifest rather than computing them, so a change
    made in only one of the two gives the desktop a badge the laptop lacks —
    the silent-contract failure mode.
    """
    f = []
    if not pv.get("w"):
        return f
    q = quality_of(pv["w"], pv.get("h", 0))
    if q == "2160p":
        f.append("4K")
    elif q == "1080p":
        f.append("1080p")
    if pv.get("dv"):
        f.append("DV")
    elif pv.get("hdr"):
        f.append("HDR10")
    if pv.get("atmos"):
        f.append("ATMOS")
    elif pv.get("ch", 0) >= 8:
        f.append("7.1")
    elif pv.get("ch", 0) >= 6:
        f.append("5.1")
    return f


def quality_of(width, height=0):
    """⚠ NEITHER dimension alone is enough, and both mistakes are real here.

    Judge on height only and a 4K scope film (3840x1600) reads as 1080p. Judge
    on WIDTH only and a pillarboxed 1080p transfer reads as 720p — this
    library has four of those (Ninja Scroll 1460x1080, Macross Plus 1512x1080,
    MADOX-01 1440x1080, Blair Witch 1472x1072), and the width-only version of
    this function quietly demoted every one of them.

    So take whichever dimension claims the HIGHER class: a frame is 1080p if
    it is either 1080 tall or ~1920 wide, whatever its aspect."""
    if width >= 3200 or height >= 1700:
        return "2160p"
    if width >= 1700 or height >= 950:
        return "1080p"
    if width >= 1200 or height >= 650:
        return "720p"
    return "480p" if (width or height) else ""


def lan_ip():
    return codec_paths.lan_ip()


def _with_year(sub, year):
    """`sub` ("1993 · 1080p") with its year token replaced by `year` — or the
    year put first when it carries none. Mirrors library.cpp withYear()."""
    parts = [p for p in sub.split(" · ") if p]
    for i, p in enumerate(parts):
        if len(p) == 4 and p.isdigit() and int(p) > 1800:
            parts[i] = str(year)
            return " · ".join(parts)
    return " · ".join([str(year)] + parts)


def parse(raw, vid=None):
    """Title/year/subtitle for one library item.

    `vid` is the actual video file. When it can be probed, the FILE decides
    resolution and dynamic range and the filename only supplies the title,
    year and REMUX tag. The name still fills in whatever the probe can't
    reach (an unreadable file, a drive that has spun down)."""
    base = raw.replace(".", " ").replace("_", " ")
    # Detect quality/HDR on a copy keeping bracket contents; the title drops
    # [bracketed] release junk whole (group tags, "[Dual Audio]", "[1080p]").
    flat = re.sub(r"[\[\]()]", " ", base)
    s = re.sub(r"[()]", " ", re.sub(r"\[[^\]]*\]", "", base))
    year, cut = "", -1
    for m in YEAR_RE.finditer(s):
        year, cut = m.group(1), m.start(1)
    # #36: an implausibly-future year is part of the TITLE ("Blade Runner 2049"),
    # not a release year — drop it so the title keeps its number (matches the C++
    # scanner + scraper). Only affects entries with no scraped DB row.
    if year and int(year) > datetime.now().year + 1:
        year, cut = "", -1
    q = QUAL_RE.search(flat)
    quality = q.group(1).lower() if q else ""
    hdr = bool(HDR_RE.search(flat))
    remux = "remux" in flat.lower()
    if vid:
        pv = probe_video(vid)
        if pv.get("w"):
            quality = quality_of(pv["w"], pv.get("h", 0)) or quality
            hdr = bool(pv.get("hdr"))
    if cut <= 0:
        t = TOKEN_RE.search(s)
        cut = t.start() if t else -1
    title = (s[:cut] if cut > 0 else s).strip(" -–—")
    title = " ".join(title.split()) or raw
    sub = []
    if year: sub.append(year)
    if quality: sub.append("4K" if quality == "2160p" else quality)
    if hdr: sub.append("HDR")
    if remux: sub.append("REMUX")
    return title, year, " · ".join(sub)


def biggest_video(d: Path):
    best, size = None, -1
    for f in d.rglob("*"):
        if f.suffix.lower() in VIDEO_EXTS and "sample" not in f.name.lower():
            try:
                st = f.stat().st_size
            except OSError:
                continue  # dangling symlink / vanished file — skip, not abort
            # Deterministic on size ties: rglob yield order is arbitrary, so a
            # bare `st > size` let the chosen file (and the whole entry's
            # URL/flags) flip between identical exports. Break ties by path.
            if st > size or (st == size and (best is None or str(f) < str(best))):
                best, size = f, st
    return best


# ── bonus features ──────────────────────────────────────────────────────────
# Featurettes, deleted scenes, promos: anything under an EXTRAS_RE folder inside
# a film's or a show's folder. Each one is labelled for the BONUS FEATURES page
# with a clean title, a group (the folders under the extras folder: "Deleted
# Scenes", "Promos / TV Spots", "Season 3 / Deleted Scenes") and a sort key.
#
# ⚠ MIRRORED in src/library.cpp (extraTitle / extraGroup / extraSortKey). The hub
# scans with the C++ side and the laptop reads this manifest, so the two must
# label every extra identically — change one, change both.
EXTRAS_DIR_RE = re.compile(
    r"^(featurettes?|extras?|behind[ .]the[ .]scenes|deleted[ .]scenes|bonus"
    r"|interviews?|trailers?|making[ .]of)$", re.I)
SEASON_TAG_RE = re.compile(
    r"(?:^|[^a-z0-9])s(\d{1,2})(?:e\d+)?(?=$|[^a-z0-9])|season[\s._-]*(\d{1,2})", re.I)
# Release junk a few extras carry in brackets: "Trailer (1080p BluRay x265)".
EXTRA_JUNK_RE = re.compile(
    r"\s*[\[(][^\[\]()]*\b(?:2160p|1080p|720p|480p|x26[45]|hevc|bluray|web-?dl|webrip)\b"
    r"[^\[\]()]*[\])]", re.I)
# Thumbnails live in the art cache under this prefix (codec_extras.py writes
# them; the laptop's pull fetches them like any poster).
EXTRA_THUMB_PREFIX = "extra-"


def _tidy(s):
    # U+A789 is the "colon" Windows-safe rips use in file names ("1883꞉ The Road").
    s = s.replace("꞉", ":").replace("：", ":")
    if " " not in s and re.search(r"[._]", s):
        s = re.sub(r"[._]+", " ", s)
    s = EXTRA_JUNK_RE.sub("", s)
    return re.sub(r"\s+", " ", s).strip()


def extra_title(stem):
    """'01) Clarice Meets Lecter' -> '01 Clarice Meets Lecter'."""
    t = re.sub(r"^(\d{1,3})\)\s*", r"\1 ", _tidy(stem))
    return t or stem


def extra_group(rel_dir, tv=False):
    """(label, season, root) for an extra's folder, relative to its title folder.

    The folders BELOW the extras folder name the group; with none, the extras
    folder itself does ("Featurettes"). Folders above it are the release name,
    except on a show, where they carry the season."""
    comps = [c for c in rel_dir.replace("\\", "/").split("/") if c]
    k = next((i for i, c in enumerate(comps) if EXTRAS_DIR_RE.match(c)), None)
    if k is None:
        return "Bonus", 0, True
    post = comps[k + 1:]
    label = " / ".join(_tidy(c) for c in post) if post else _tidy(comps[k])
    season = 0
    if tv:
        for c in comps[:k]:
            m = SEASON_TAG_RE.search(c)
            if m:
                season = int(m.group(1) or m.group(2))
    if season:
        label = f"Season {season} / {label}"
    return label, season, not post


def extra_sort_key(parent_sort, rel_dir, stem, tv=False):
    """Season, then the extras folder's own files, then each sub-group A-Z,
    then file name — compared NUMERICALLY by the app (QCollator)."""
    label, season, root = extra_group(rel_dir, tv)
    return f"{parent_sort} ~{season:03d}{0 if root else 1} {label.lower()} | {stem.lower()}"


def extra_thumb(path):
    """Where codec_extras.py keeps this extra's thumbnail (may not exist yet)."""
    h = hashlib.sha1(str(path).encode("utf-8")).hexdigest()[:24]
    return ART_DIR / f"{EXTRA_THUMB_PREFIX}{h}.jpg"


def movie_extras(movie_dir: Path, main: Path):
    """Every extra inside a film's folder, as (path, rel_dir) — sorted."""
    out = []
    for f in sorted(movie_dir.rglob("*")):
        if f.suffix.lower() not in VIDEO_EXTS or "sample" in f.name.lower() or f == main:
            continue
        rel = str(f.relative_to(movie_dir))
        if EXTRAS_RE.search("/" + rel):
            out.append((f, str(Path(rel).parent)))
    return out


def iter_extras(roots):
    """(path, parent_path, rel_dir, tv) for every extra under the library roots."""
    for root in roots:
        rp = Path(root["path"])
        if not rp.is_dir():
            continue
        if root.get("kind", "movies") == "tv":
            for show_dir in sorted(p for p in rp.iterdir() if p.is_dir()):
                for f in sorted(show_dir.rglob("*")):
                    if f.suffix.lower() not in VIDEO_EXTS or "sample" in f.name.lower():
                        continue
                    rel = str(f.relative_to(show_dir))
                    if EXTRAS_RE.search("/" + rel):
                        yield f, show_dir, str(Path(rel).parent), True
        else:
            for entry in sorted(rp.iterdir()):
                if not entry.is_dir():
                    continue
                main = biggest_video(entry)
                if main:
                    for f, rel_dir in movie_extras(entry, main):
                        yield f, main, rel_dir, False


def load_extras_index():
    """codec_extras.py's {path: {dur, thumb}} — runtimes and thumbnails."""
    try:
        return json.loads(EXTRAS_INDEX.read_text())
    except (OSError, ValueError):
        return {}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url-base", default="")
    ap.add_argument("--path-prefix", default=codec_paths.serve_root())
    ap.add_argument("--out", default=str(codec_paths.MANIFEST))
    args = ap.parse_args()
    url_base = args.url_base or f"http://{lan_ip()}:8200"
    # lan_ip() returns 127.0.0.1 when its LAN probe fails (network down / tailnet
    # only). A manifest stamped with loopback is useless the instant it's rsynced
    # to a satellite — every URL then points the satellite at itself. Refuse to
    # write one (exit non-zero) so the nightly chain keeps the last good manifest
    # instead of overwriting it with a poisoned copy that still passes size checks.
    if not args.url_base and urlparse(url_base).hostname in ("127.0.0.1", "localhost", "::1"):
        print("export_library: LAN IP unresolved (loopback) — refusing to write "
              "a manifest with an unreachable urlBase", file=sys.stderr)
        return 2

    db = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    try:
        meta = {r[0]: r for r in db.execute(
            "SELECT path,title,year,plot,rating,runtime_min,genres,poster,fanart,"
            "credits,director,similar,tmdb_id,clearlogo,revenue,budget,studio,"
            "country,language,writer,premiered FROM metadata")}
    except sqlite3.OperationalError:
        # A brand-new DB (no scrape or C++ run yet) is missing the extended
        # columns. Export the titles WITHOUT metadata rather than crashing the
        # nightly refresh; the next scrape adds the columns and the following
        # export is complete. Same graceful degradation as the intros guard.
        meta = {}
    # Opening-title ranges (codec_intro.py). The laptop has no media files to
    # fingerprint, so the manifest is the only way it can offer SKIP INTRO.
    try:
        intros = {r[0]: (r[1], r[2]) for r in db.execute(
            "SELECT path, start, end FROM intros WHERE end - start >= 5")}
    except sqlite3.OperationalError:
        intros = {}
    # End-credits starts (codec_credits.py) ride the manifest for the same
    # reason — the laptop's UP NEXT fires at the credits from these numbers.
    try:
        credits = {r[0]: r[1] for r in db.execute(
            "SELECT path, start FROM credits WHERE start > 0")}
    except sqlite3.OperationalError:
        credits = {}
    roots = json.loads(CFG.read_text())["roots"]

    # Refuse to overwrite the manifest if a media drive looks unmounted: a
    # partial walk would drop every title on that drive and, once rsynced,
    # make them vanish from the laptop. A root with content is trustworthy; an
    # empty root is fine only if its drive is genuinely mounted.
    def on_mounted_volume(path):
        cur = Path(path).resolve()
        while cur != cur.parent:
            if os.path.ismount(str(cur)):
                return str(cur) != "/"
            cur = cur.parent
        return False
    for root in roots:
        rp = Path(root["path"])
        if not rp.is_dir() or (not any(rp.iterdir()) and not on_mounted_volume(rp)):
            print(f"❌ export ABORT — root missing/unmounted ({root['path']}); "
                  "manifest left untouched", file=sys.stderr)
            sys.exit(3)

    def to_url(p: str) -> str:
        # Strip the prefix only on a path-separator boundary, so '/mntcache/x'
        # isn't mangled to 'cache/x' (then '…:8200cache/x'). A path outside the
        # prefix keeps a leading slash so the URL is at least well-formed.
        pre = args.path_prefix.rstrip("/")
        if p == pre or p.startswith(pre + "/"):
            rel = p[len(pre):]
        else:
            rel = p
        if not rel.startswith("/"):
            rel = "/" + rel
        return url_base + quote(rel)

    def art_url(p) -> str:
        # #10: remote art to the hub's /art endpoint (basename-keyed from ART_DIR,
        # where TMDB posters/fanart/logos are cached) so a SATELLITE — which has no
        # local copy — can load them, the same way `url` is remoted. loadManifest
        # skips its on-disk existence check for these http URLs. Empty stays empty;
        # a non-ART_DIR path simply 404s on the satellite (same as before).
        p = (p or "").strip()
        if not p:
            return ""
        return url_base + "/art?f=" + quote(os.path.basename(p))

    def _yr(v):
        # metadata.year may be an int, "2004", or "2004-05-01"; the manifest
        # carries a plain int so the C++ side reads it with QJsonValue::toInt().
        try:
            return int(str(v)[:4]) if v else 0
        except (ValueError, TypeError):
            return 0

    extras_index = load_extras_index()

    def extra_row(f, parent, rel_dir, parent_title, parent_sort, tv):
        # A bonus feature. `parent` is the film's main video or the show folder:
        # it is that entry's URL here and its path on the hub, which is how both
        # sides hang an extra off the right title. Never scraped, so its art is
        # the frame codec_extras.py grabbed, and its runtime comes from there too.
        ix = extras_index.get(str(f)) or {}
        thumb = ix.get("thumb") or ""
        return {
            "kind": "extra", "title": extra_title(f.stem), "show": parent_title,
            "parent": to_url(str(parent)),
            "group": extra_group(rel_dir, tv)[0],
            "sortKey": extra_sort_key(parent_sort, rel_dir, f.stem, tv),
            "url": to_url(str(f)), "subtitle": "",
            "durationS": ix.get("dur") or 0,
            "poster": art_url(thumb) if thumb and Path(thumb).exists() else "",
            "added": int(f.stat().st_mtime),
            "year": 0, "plot": "", "rating": 0, "runtimeMin": 0, "genres": "",
            "flags": [],
        }

    entries = []
    arrivals = load_arrivals()
    for root in roots:
        rp = Path(root["path"]); kind = root.get("kind", "movies")
        if not rp.is_dir():
            continue
        if kind == "tv":
            for show_dir in sorted(p for p in rp.iterdir() if p.is_dir()):
                sm = meta.get(str(show_dir))
                show_title = sm[1] if sm else parse(show_dir.name)[0]
                show_sort = show_title.lower()
                # A show folder is not a file, so its chips are read off the
                # biggest episode in it — same rule as the C++ scanner, and
                # every episode below inherits them.
                sv = biggest_video(show_dir)
                show_flags = probe_flags(probe_video(sv)) if sv else []
                entries.append({
                    "kind": "show", "title": show_title, "show": show_title,
                    # Shows omitted `added`, so loadManifest pinned every show to
                    # epoch 0 on satellites (bottom of any "recently added" sort).
                    "added": int(show_dir.stat().st_mtime),
                    "sortKey": show_sort, "url": to_url(str(show_dir)),
                    "subtitle": "", "year": _yr(sm[2]) if sm else 0,
                    "plot": sm[3] if sm else "",
                    "rating": sm[4] if sm else 0, "runtimeMin": 0,
                    "genres": sm[6] if sm else "", "poster": art_url(sm[7] if sm else ""),
                    "fanart": art_url(sm[8] if sm else ""),
                    # detail-page extras — the laptop reads this manifest, so
                    # without these its detail pages lose cast + more-like-this
                    "credits": (sm[9] or "") if sm else "",
                    "director": (sm[10] or "") if sm else "",
                    "similar": (sm[11] or "") if sm else "",
                    "tmdbId": (sm[12] or "") if sm else "",
                    "clearlogo": art_url(sm[13] if sm else ""),
                    "revenue": (sm[14] or 0) if sm else 0,
                    "budget": (sm[15] or 0) if sm else 0,
                    "studio": (sm[16] or "") if sm else "",
                    "country": (sm[17] or "") if sm else "",
                    "language": (sm[18] or "") if sm else "",
                    "writer": (sm[19] or "") if sm else "",
                    "flags": show_flags,
                })
                for f in sorted(show_dir.rglob("*")):
                    if f.suffix.lower() not in VIDEO_EXTS or "sample" in f.name.lower():
                        continue
                    # Kept, not discarded. The model only ever renders
                    # movie/show/episode, so "extra" is invisible today — and
                    # it means a special-features section later is a matter of
                    # rendering data that is already here, not re-walking every
                    # drive to find it again.
                    rel = str(f.relative_to(show_dir))
                    if EXTRAS_RE.search("/" + rel):
                        entries.append(extra_row(f, show_dir, str(Path(rel).parent),
                                                 show_title, show_sort, True))
                        continue
                    en = episode_number(f.stem, f)
                    two_part = False
                    if en:
                        se, ep = en
                        label = f"S{se:02d}E{ep:02d}"; sk = f"{show_sort} {se:04d} {ep:04d}"
                        # one file, two episodes: "S09E19-20" (mirrors library.cpp)
                        last = last_episode_in(f.stem)
                        if last > ep:
                            label += f"-{last:02d}"
                            two_part = True
                    else:
                        label, sk = parse(f.stem)[0], f"{show_sort} {f.stem.lower()}"
                    fm = meta.get(str(f))
                    if fm and fm[1]:
                        label += f" · {without_part_one(fm[1]) if two_part else fm[1]}"
                    # The episode's OWN air year (its TMDB first-air date), not the
                    # show's first year on every row — X-Files S11 read "1993".
                    # Mirrors library.cpp's join (withYear).
                    ep_year = _yr((fm[20] or "")[:4]) if fm and len(fm) > 20 else 0
                    ep_sub = parse(f.stem, f)[2]
                    if ep_year:
                        ep_sub = _with_year(ep_sub, ep_year)
                    intro = intros.get(str(f))
                    entries.append({
                        "kind": "episode",
                        "title": label, "show": show_title,
                        "sortKey": sk, "url": to_url(str(f)),
                        # #4: the episode's OWN resolution/HDR line + probe flags
                        # (cache-backed), not the show's year-as-subtitle and the
                        # biggest-episode's flags — mirrors the hub's per-episode
                        # probe (#35) so the satellite's search line + format facet
                        # agree with the hub instead of badging a show as a block.
                        "subtitle": ep_sub,
                        "year": ep_year or (_yr(sm[2]) if sm else 0),
                        "plot": fm[3] if fm else "", "rating": 0, "runtimeMin": 0,
                        "genres": "", "poster": art_url(fm[7] if fm else ""),
                        "added": int(f.stat().st_mtime),
                        "arrived": arrived_for(f, arrivals),
                        "introStart": intro[0] if intro else 0,
                        "introEnd": intro[1] if intro else 0,
                        "creditsStart": credits.get(str(f), 0),
                        "flags": probe_flags(probe_video(f)),
                    })
        else:
            for entry in sorted(rp.iterdir()):
                if entry.name in ("$RECYCLE.BIN", "System Volume Information", "Config.Msi"):
                    continue
                # mirrors library.cpp: a temp file, or a torrent import still
                # being copied ("<Title>.importing"), is not a title yet
                if entry.name.lower().endswith((".tmp", ".importing")):
                    continue
                if entry.is_dir():
                    vid = biggest_video(entry); raw = entry.name
                elif entry.suffix.lower() in VIDEO_EXTS:
                    vid, raw = entry, entry.stem
                else:
                    continue
                if not vid:
                    continue
                title, year, sub = parse(raw, vid)
                m = meta.get(str(vid))
                if m and m[1]:
                    title = m[1]
                entries.append({
                    "added": int(Path(vid).stat().st_mtime),
                    "arrived": arrived_for(vid, arrivals),
                    "kind": "movie", "title": title, "show": "",
                    "sortKey": title.lower(), "url": to_url(str(vid)), "subtitle": sub,
                    "year": _yr(m[2]) if (m and m[2]) else _yr(year),
                    "plot": m[3] if m else "", "rating": m[4] if m else 0,
                    "runtimeMin": m[5] if m else 0, "genres": m[6] if m else "",
                    "poster": art_url(m[7] if m else ""),
                    "fanart": art_url(m[8] if m else ""),
                    "credits": (m[9] or "") if m else "",
                    "director": (m[10] or "") if m else "",
                    "similar": (m[11] or "") if m else "",
                    "tmdbId": (m[12] or "") if m else "",
                    "clearlogo": art_url(m[13] if m else ""),
                    "revenue": (m[14] or 0) if m else 0,
                    "budget": (m[15] or 0) if m else 0,
                    "studio": (m[16] or "") if m else "",
                    "country": (m[17] or "") if m else "",
                    "language": (m[18] or "") if m else "",
                    "writer": (m[19] or "") if m else "",
                    "flags": probe_flags(probe_video(vid)),
                })
                if entry.is_dir():
                    for f, rel_dir in movie_extras(entry, vid):
                        entries.append(extra_row(f, vid, rel_dir, title,
                                                 title.lower(), False))

    out = Path(args.out); out.parent.mkdir(parents=True, exist_ok=True)
    save_probe_cache()
    # Atomic write: a crash mid-write must not truncate the live manifest that
    # the app and the satellite pull read.
    tmp_out = out.with_suffix(out.suffix + ".tmp")
    tmp_out.write_text(json.dumps({"urlBase": url_base, "entries": entries}, indent=1))
    tmp_out.replace(out)
    kinds = {}
    for e in entries:
        kinds[e["kind"]] = kinds.get(e["kind"], 0) + 1
    print(f"wrote {out} — {len(entries)} entries {kinds} (base {url_base})")


if __name__ == "__main__":
    sys.exit(main() or 0)
