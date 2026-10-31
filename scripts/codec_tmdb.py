#!/usr/bin/env python3
"""Scrape TMDB metadata + posters for library items codec.db doesn't cover.

Walks the same media roots the app scans (movies: biggest video per folder;
tv: show dirs + SxxEyy episodes), finds items whose metadata row is missing or
incomplete, and fills them from TMDB: title/year/plot/rating/runtime/genres +
poster cached into ~/.cache/codec/art. Rows written with source='tmdb';
existing Kodi-imported rows are only touched with --refresh.

API key: codec's own (codec_keys.py), or settings.tmdbApiKey, or --key.
Stdlib only (Hermes-runnable). Run --dry-run first to see the worklist.
"""
import argparse, hashlib, json, os, re, sqlite3, subprocess, sys, time
import codec_keys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import urlopen, Request
import codec_paths  # where codec's data lives (~/.local/share/codec)

DB = codec_paths.DB
CFG = Path.home() / ".config/codec/config.json"
ART = Path.home() / ".cache/codec/art"
# Shared with codec_library_audit.py — same file, same "path|size" key, so a
# probe either script pays for is a probe the other one gets free.
DURCACHE = Path.home() / ".cache/codec/durations.json"
_FF8 = str(Path.home() / "deps/ffmpeg-n8.1-static/bin")
FFPROBE = f"{_FF8}/ffprobe" if Path(f"{_FF8}/ffprobe").exists() else "ffprobe"
API = "https://api.themoviedb.org/3"
IMG = "https://image.tmdb.org/t/p/w500"
FAN = "https://image.tmdb.org/t/p/w1280"
# Episode stills become the detail-page BACKGROUND (a full-bleed frame), so pull
# them at native resolution rather than the w500 poster size.
STILL = "https://image.tmdb.org/t/p/original"

VIDEO_EXTS = {".mkv", ".mp4", ".avi", ".m2ts", ".ts", ".mov", ".wmv",
              ".flv", ".webm", ".mpg", ".mpeg", ".iso"}
YEAR_RE = re.compile(r"\b(19[3-9]\d|20[0-4]\d)\b")
TOKEN_RE = re.compile(
    r"\b(2160p|1080p|720p|480p|UHD|BluRay|Blu-Ray|BDRip|WEB-?DL|WEBRip|WEB|HDTV|"
    r"REMUX|x26[45]|H ?26[45]|HEVC|AVC|DTS|DDP?|AAC|AC3|TrueHD|Atmos|10bit|8bit|"
    r"HDR10?|DV|YTS|YIFY|RARBG)\b", re.I)
# A double episode may be spelled S04E03-E04 (the dash gives a word boundary, so it
# already parsed) or S06E14E15 with no separator at all — there the trailing \b lands
# between two word characters and the whole match fails, so the file looked like it had
# no episode number and was skipped. Absorb any extra E-numbers and key off the FIRST,
# which is what the hyphenated form already did.
EP_RE = re.compile(
    r"\b(?:S(\d{1,2})E(\d{1,3})(?:[-_. ]?E\d{1,3})*|(\d{1,2})x(\d{2,3}))\b", re.I)
# Directories whose contents are ABOUT the show rather than part of it. Kept in
# step with library.cpp and export_library.py — all three walk the media roots
# independently, so a rule that only lives in one of them is a rule the other
# two break. Without it this scraper spends 154 TMDB lookups asking what
# episode "Gag Reel" is.
# ⚠ Matched on the DIRECTORY, never on "this file has no episode number":
# plenty of real episodes don't have one (Berserk numbers its files
# "Berserk - 01").
EXTRAS_RE = re.compile(
    r"/(featurettes?|extras?|behind[ .]the[ .]scenes|deleted[ .]scenes|bonus"
    r"|interviews?|trailers?|making[ .]of)/", re.I)
# Anime-style names with no season marker ("Berserk - 11 [...]",
# "....Episode.01.Long.Shot...."): take the number, assume season 1.
# ⚠ ANCHORED on purpose. The obvious pattern — "a dash then a number" —
# matched "Implanted Memories - 25 Years of The X-Files" and filed a
# featurette as S01E25. The number must END the name or be followed by a
# bracket; never by another word. "Episode N" keeps its keyword form, which
# is unambiguous.
EP_LOOSE_RE = re.compile(r"\bEpisode\s+(\d{1,3})\b", re.I)
EP_DASH_RE = re.compile(r"-\s+(\d{1,3})\s*(?=[\[(]|$)")


SEASON_DIR_RE = re.compile(r"^s(?:eason)?[\s._]*0*(\d{1,2})$", re.I)


def episode_number(name, path=None):
    """(season, episode) from a filename, or None. `path` (the full episode path)
    lets a loose-numbered episode take its season from an enclosing Season N folder."""
    m = EP_RE.search(name)
    if m:
        return int(m.group(1) or m.group(3)), int(m.group(2) or m.group(4))
    flat = re.sub(r"[._]", " ", name)
    m = EP_LOOSE_RE.search(flat) or EP_DASH_RE.search(flat)
    if not m:
        return None
    # #33 (scraper half): derive the season from an enclosing "Season N"/"S0N" folder
    # instead of hardcoding 1 (matches the C++ looseEpisode). Hardcoding 1 fetched
    # S01's metadata for a S02+ loose episode and wrote it on that file's row.
    season = 1
    if path:
        for comp in str(path).replace("\\", "/").split("/"):
            sm = SEASON_DIR_RE.match(comp.strip())
            if sm:
                season = int(sm.group(1))   # deepest match wins
    return (season, int(m.group(1)))


# Trailing edition/format markers. Deliberately conservative: "EXTENDED" and
# "UNRATED" are here because no film's title ends on them, while words that DO
# appear in real titles (e.g. "Final Cut" as part of a name) are not.
EDITION_TAIL_RE = re.compile(
    r"[\s\-–—]*\b("
    r"imax|open\s*matte|remastered|remaster|extended(\s+cut)?|unrated|uncut|"
    r"repack|proper|director'?s\s+cut|special\s+edition|theatrical(\s+cut)?|"
    r"anniversary\s+edition|ai[\s\-]?remaster(ed)?|upscaled"
    r")\s*$", re.I)


def parse(raw):
    """Scene name -> (clean title, year). Same rules as the app's parser."""
    s = re.sub(r"[\[\]()]", " ", raw.replace(".", " ").replace("_", " "))
    year, cut = "", -1
    for m in YEAR_RE.finditer(s):
        year, cut = m.group(1), m.start(1)
    # #36 (scraper half): an implausibly-FUTURE year token is part of the TITLE, not
    # a release year ("Blade Runner 2049"). Drop it so the title keeps its number and
    # the search isn't run for the wrong film. Without this the scraper searched
    # year=2049 (no hit) -> retried yearless -> matched Blade Runner (1982) and wrote
    # a sticky source='tmdb' row that OVERRODE the C++ scanner's correct parse.
    if year and int(year) > datetime.now().year + 1:
        year, cut = "", -1
    if cut <= 0:
        t = TOKEN_RE.search(s)
        cut = t.start() if t else -1
    title = (s[:cut] if cut > 0 else s).strip(" -–—")
    # Edition and format markers that sit BETWEEN the title and the year survive
    # the cut above, and TMDB has no film by that name: "Tenet IMAX 2020" was
    # searched as "Tenet IMAX", found nothing, and the film ended up with no row
    # at all — displayed by filename as "Tenet IMAX", no poster, no art. Strip
    # them off the tail, repeatedly, so "Tenet IMAX" -> "Tenet" and
    # "Oblivion Open Matte" -> "Oblivion". Only TRAILING, and only markers no
    # real title ends on; anything ambiguous is left alone, because a wrong
    # strip searches for the wrong film, which is worse than not searching.
    while True:
        stripped = EDITION_TAIL_RE.sub("", title).strip(" -–—")
        if stripped == title or not stripped:
            break
        title = stripped
    return " ".join(title.split()) or raw, year


def biggest_video(d: Path):
    best, size = None, -1
    for f in d.rglob("*"):
        if f.suffix.lower() in VIDEO_EXTS and "sample" not in f.name.lower():
            st = f.stat().st_size
            if st > size:
                best, size = f, st
    return best


def _tmdb_season_counts(tmdb, sid, _cache={}):
    """{season_number: episode_count} for a show, season 0 excluded."""
    if sid not in _cache:
        d = tmdb.get(f"/tv/{sid}")
        _cache[sid] = {int(x["season_number"]): int(x.get("episode_count") or 0)
                       for x in (d.get("seasons") or [])
                       if int(x.get("season_number", 0)) >= 1}
    return _cache[sid]


def _disk_season_counts(show_dir, _cache={}):
    """{season_number: episode_count} as the FILES are actually laid out —
    counted the way TMDB counts: specials (season 0) and extras folders left
    out, a REPACK beside the original counted once, and a double-episode file
    (S06E14E15) counted as the episodes it holds."""
    if show_dir not in _cache:
        eps = set()
        for f in Path(show_dir).rglob("*"):
            if f.suffix.lower() not in VIDEO_EXTS:
                continue
            if EXTRAS_RE.search("/" + str(f.relative_to(show_dir))):
                continue
            n = episode_number(f.name, str(f))
            if not n or n[0] < 1:
                continue
            last = n[1]
            m = re.search(r"S\d{1,2}E\d{1,3}((?:[-_. ]?E\d{1,3})+)", f.name, re.I)
            if m:
                last = max([n[1]] + [int(x) for x in re.findall(r"\d{1,3}", m.group(1))])
            for e in range(n[1], last + 1):
                eps.add((n[0], e))
        counts = {}
        for season, _e in eps:
            counts[season] = counts.get(season, 0) + 1
        _cache[show_dir] = counts
    return _cache[show_dir]


def remap_episode(tmdb, sid, show_dir, se, ep):
    """Map a DISK (season, episode) onto TMDB's numbering, or None to use it as is.

    A release can split a show differently from TMDB. Batman: The Animated
    Series ships as 65+20 across two season folders; TMDB files the same 85
    episodes as 60+10+10+5. Everything past disk S01E60 is then wrong — and
    only the tail 404s. Disk S02E01-E10 resolve to REAL TMDB episodes that are
    simply not the ones in those files, so they save cleanly and look correct:
    fifteen visible failures, ten silent wrong matches.

    When the two layouts disagree, position in air order is the thing both
    sides agree on, so the episode is located by its ABSOLUTE number instead.
    When they agree, nothing changes.
    """
    try:
        disk = _disk_season_counts(show_dir)
        tm = _tmdb_season_counts(tmdb, sid)
        if not disk or not tm or disk == tm:
            return None                      # same shape — trust the numbering
        # Remapping by absolute position is only sound when the disk holds the
        # SAME episodes as TMDB, split differently (Batman TAS: 65+20 vs
        # 60+10+10+5). A show with only Season 3 on disk, a missing episode,
        # or a gap would shift every later episode onto the wrong TMDB entry —
        # saved with a tmdb id, so never re-queued. Then keep the numbering.
        if sum(disk.values()) != sum(tm.values()) \
                or sorted(disk) != list(range(1, max(disk) + 1)):
            return None
        absolute = sum(disk.get(x, 0) for x in sorted(disk) if x < se) + ep
        run = 0
        for season in sorted(tm):
            if run + tm[season] >= absolute:
                return season, absolute - run
            run += tm[season]
    except Exception:
        pass
    return None


class Tmdb:
    def __init__(self, key, delay=0.25):
        self.key, self.delay, self.calls = key, delay, 0

    def get(self, path, **params):
        params["api_key"] = self.key
        time.sleep(self.delay)
        self.calls += 1
        with urlopen(f"{API}{path}?{urlencode(params)}", timeout=15) as r:
            return json.loads(r.read())

    def search(self, kind, query, year=""):
        """kind: 'movie'|'tv'. Try with year, then without, then first-3-words.

        ⚠ Takes TMDB's top hit, which is a RANKING, not an identification. Two
        real misses here: "The X-Files - Fight the Future" ranks the making-of
        documentary above the film, and "Drunken Master II" ranks Drunken
        Master III above it (the actual entry is "The Legend of Drunken
        Master", the international title — so the right answer does not even
        contain the words searched for). Both are 1994, so the year cannot
        break the tie. That is what OVERRIDES exist for.

        Movies go through pick_movie(), which cross-checks the runtime and can
        walk past a grossly wrong top hit; shows and episodes still take it
        neat."""
        hits = self.search_all(kind, query, year)
        return hits[0] if hits else None

    def search_all(self, kind, query, year=""):
        """Every candidate for the first query in the ladder that hits, in
        TMDB's ranked order. search() is this, truncated to one."""
        tries = [(query, year)] if year else []
        tries += [(query, ""), (" ".join(query.split()[:3]), "")]
        seen = set()
        for q, y in tries:
            if not q or (q, y) in seen:
                continue
            seen.add((q, y))
            params = {"query": q}
            if y:
                params["year" if kind == "movie" else "first_air_date_year"] = y
            res = self.get(f"/search/{kind}", **params).get("results", [])
            if res:
                return res
        return []


def file_minutes(path):
    """The file's real runtime in minutes, cached — 0 if it can't be known.

    Cached under the audit's "path|size" key so re-encoding a title (which
    changes the size) invalidates it, and so a scrape and an audit share one
    probe. 0 on any failure: an unknown runtime must never veto a match."""
    try:
        key = f"{path}|{os.path.getsize(path)}"
    except OSError:
        return 0.0
    try:
        cache = json.loads(DURCACHE.read_text())
    except (OSError, ValueError):
        cache = {}
    if key not in cache:
        try:
            o = subprocess.run(
                [FFPROBE, "-v", "error", "-show_entries", "format=duration",
                 "-of", "csv=p=0", path],
                capture_output=True, text=True, timeout=60).stdout.strip()
            cache[key] = float(o) if o else 0.0
        except Exception:
            cache[key] = 0.0
        try:
            DURCACHE.parent.mkdir(parents=True, exist_ok=True)
            DURCACHE.write_text(json.dumps(cache))
        except OSError:
            pass
    return (cache.get(key) or 0.0) / 60.0


def wrong_kind_of_thing(file_min, tmdb_min):
    """True only when the runtimes say these are different KINDS of thing —
    a 27-minute making-of matched to a 121-minute feature, a trailer, an
    episode matched to a film.

    ⚠ Deliberately blind to alternate cuts, and NOT a general match validator.
    codec_library_audit.py already learned the hard version of this lesson: the
    wrong Drunken Master match was 10 minutes SHORTER than the file, which is
    exactly the shape of a legitimate extended cut, so no threshold can tell
    them apart. This catches only the gross case; everything subtler still
    needs an OVERRIDE, and the audit still reports the near misses."""
    if not file_min or not tmdb_min:
        return False
    lo, hi = sorted((float(file_min), float(tmdb_min)))
    return lo < 0.6 * hi and hi - lo > 25


def pick_movie(tmdb, path, title, year, tries=3):
    """Detail for the best search hit that the FILE's runtime does not refute.

    TMDB's top hit is a ranking, not an identification (see Tmdb.search), and a
    wrong one is expensive: the id is persisted and everything keyed on it —
    logos, credits, recommendations — inherits the mistake. Costs no extra API
    call in the normal case: the first candidate's detail is the one we wanted
    anyway, and we only reach for another when the runtime refutes it."""
    cands = tmdb.search_all("movie", title, year)
    if not cands:
        raise LookupError("no match")
    best = None
    mins = 0.0
    for c in cands[:tries]:
        d = tmdb.get(f"/movie/{c['id']}", append_to_response=APPEND)
        if best is None:
            best = d
            mins = file_minutes(path)   # probe once, and only if there IS a hit
        if not wrong_kind_of_thing(mins, d.get("runtime")):
            return d
        print(f"  ~ {d.get('title')!r} runs {d.get('runtime')}m but the file "
              f"runs {round(mins)}m — rejected, trying the next hit")
    print(f"  ! nothing TMDB offers runs anywhere near {round(mins)}m — kept "
          f"{best.get('title')!r}; pin it in tmdb-overrides.json if it's wrong")
    return best


# ── when the search is simply wrong ─────────────────────────────────────────
# path substring -> TMDB id. Checked before searching, so a film whose real
# entry is filed under a different title (or that loses the ranking to a
# documentary or a sequel) can be pinned once instead of renaming the folder
# on disk every time the scraper runs.
OVERRIDES = Path.home() / ".config/codec/tmdb-overrides.json"


def overrides():
    try:
        return json.loads(OVERRIDES.read_text())
    except (OSError, ValueError):
        return {}


def override_for(path, table):
    for frag, tid in table.items():
        if frag.lower() in str(path).lower():
            return str(tid)
    return ""


def _decodable(head):
    """True if these leading bytes are a format Qt decodes everywhere
    (JPEG or PNG) without an optional imageformat plugin."""
    return head[:3] == b"\xff\xd8\xff" or head[:8] == b"\x89PNG\r\n\x1a\n"


def _normalize_art(data):
    """CDNs (Cloudflare Polish) hand back WebP/AVIF even for a .jpg URL. A
    satellite may lack Qt's webp/avif imageformat plugin, so that art renders
    blank there while it's fine on the hub. Keep JPEG/PNG as-is; transcode
    anything else to JPEG so the cache is plugin-independent. Falls back to
    the raw bytes if it can't decode (better a hub-only image than none)."""
    if not data or _decodable(data):
        return data
    try:
        import io
        from PIL import Image
        im = Image.open(io.BytesIO(data))
        im.load()
        if im.mode not in ("RGB", "L"):
            im = im.convert("RGB")
        buf = io.BytesIO()
        im.save(buf, format="JPEG", quality=90)
        return buf.getvalue()
    except Exception:
        return data


def cache_image(url):
    if not url:
        return ""
    ART.mkdir(parents=True, exist_ok=True)
    dst = ART / (hashlib.sha1(url.encode()).hexdigest() + ".jpg")
    if dst.exists():
        # Self-heal art cached before this normalize pass (a WebP/AVIF body
        # saved as .jpg) so it stops rendering blank on plugin-less satellites.
        try:
            with open(dst, "rb") as fh:
                head = fh.read(16)
            if not _decodable(head):
                fixed = _normalize_art(dst.read_bytes())
                if _decodable(fixed[:16]):
                    dst.write_bytes(fixed)
        except Exception:
            pass
        return str(dst)
    # Don't advertise webp -> Cloudflare Polish serves the original JPEG.
    req = Request(url, headers={"Accept": "image/jpeg,image/png,image/*;q=0.8",
                                "User-Agent": "codec-tmdb"})
    with urlopen(req, timeout=20) as r:
        dst.write_bytes(_normalize_art(r.read()))
    return str(dst)


def genres_text(d):
    return " / ".join(g["name"] for g in d.get("genres", []))


def build_worklist(meta, refresh, over=None):
    """Yield (path, kind, title, year, show_dir) for items needing a scrape."""
    over = over or {}

    def needs(p, kind="movie"):
        row = meta.get(p)
        if row is None:
            return True
        if refresh:
            return True
        # An OVERRIDE that disagrees with the stored id means the pin was added
        # (or corrected) after this row was scraped. Without this the row looks
        # COMPLETE — right shape, wrong film — so every check below passes and
        # editing tmdb-overrides.json did nothing; only a whole-library
        # --refresh could repair it. This is what left "The X-Files: Fight the
        # Future" filed as its 27-minute making-of documentary.
        if kind == "movie":
            pinned = override_for(p, over)
            if pinned and pinned != (row["tmdb_id"] or ""):
                return True
        # An EPISODE's id is COMPOSITE — "show/season/ep" is what the episode branch
        # writes. A bare integer means the row came from somewhere else: a Kodi import
        # matched the EPISODE TITLE against the MOVIE database, so Seinfeld's "The Deal"
        # was filed as a film and a Castlevania episode became Star Wars. Nothing below
        # catches it, because a Kodi row HAS a plot and a poster and therefore looks
        # complete — which is how 119 episodes kept a stranger's tmdb_id through every
        # nightly run since the July import. The composite shape is a structural
        # invariant of our own scraper. An EMPTY id on a foreign row is the same
        # defect wearing different clothes — 89 more episodes sat unscraped that way,
        # also carrying a plot and a poster and so also looking complete. Gated on
        # source != "tmdb" so a row WE wrote can never re-queue itself forever.
        if kind == "episode" and row["source"] != "tmdb" \
                and "/" not in (row["tmdb_id"] or ""):
            return True
        poster = row["poster"]
        # Re-fetch art that WAS cached but whose file is now gone (cache cleared,
        # a bad/partial download, art dir wiped). Safe for EVERY kind because it
        # requires a non-empty poster path — so it can never loop on a title TMDB
        # simply has no art for (those keep poster=""). This is the case that made
        # the "grab art"/Update Library button look dead: the scrape ran but a
        # tmdb row with a missing poster was skipped, so the title stayed art-less
        # forever (#239).
        if poster and not Path(poster).exists():
            return True
        # A MOVIE/SHOW tmdb row with no poster at all is anomalous (TMDB nearly
        # always has one) → re-fetch. Episodes legitimately lack stills, so an
        # empty episode poster must NOT trigger a forever re-scrape.
        if not poster and kind != "episode":
            return True
        # A tmdb-sourced row is otherwise as complete as it will get (some titles
        # have no overview upstream) — don't re-scrape it forever.
        return row["source"] != "tmdb" and not (row["plot"] and row["poster"])

    roots = json.loads(CFG.read_text())["roots"]
    for root in roots:
        rp = Path(root["path"])
        if not rp.is_dir():
            continue
        if root.get("kind") == "tv":
            for show_dir in sorted(p for p in rp.iterdir() if p.is_dir()):
                if needs(str(show_dir), "show"):
                    yield str(show_dir), "show", *parse(show_dir.name), None
                for f in sorted(show_dir.rglob("*")):
                    if EXTRAS_RE.search("/" + str(f.relative_to(show_dir))):
                        continue
                    if f.suffix.lower() in VIDEO_EXTS and "sample" not in f.name.lower() \
                            and needs(str(f), "episode"):
                        yield str(f), "episode", f.name, "", str(show_dir)
        else:
            for entry in sorted(rp.iterdir()):
                if entry.name in ("$RECYCLE.BIN", "System Volume Information", "Config.Msi"):
                    continue
                # mirrors library.cpp: a temp file, or a torrent import still
                # being copied ("<Title>.importing"), is not a title yet
                if entry.name.lower().endswith((".tmp", ".importing")):
                    continue
                if entry.is_dir():
                    vid, raw = biggest_video(entry), entry.name
                elif entry.suffix.lower() in VIDEO_EXTS:
                    vid, raw = entry, entry.stem
                else:
                    continue
                if vid and needs(str(vid), "movie"):
                    yield str(vid), "movie", *parse(raw), None


COLS = ["title", "year", "plot", "rating", "votes", "runtime_min", "genres",
        "premiered", "imdb_id", "tmdb_id", "poster", "fanart",
        "poster_url", "fanart_url", "credits", "director", "similar",
        "source", "updated"]

# Credits/recommendations ride along on the SAME detail request via
# append_to_response, so richer detail pages cost zero extra API calls.
APPEND = "credits,recommendations"


def credit_fields(d):
    """(cast, director, similar) from a detail response with APPEND.
    cast: "Name|Character;…" top-billed. director: movie director / show creator.
    similar: TMDB ids of recommendations, resolved against our own library later."""
    cr = d.get("credits") or {}
    cast_list = ";".join(
        f"{c.get('name', '')}|{c.get('character') or c.get('roles', [{}])[0].get('character', '')}"
        for c in (cr.get("cast") or [])[:10] if c.get("name"))
    director = ", ".join(
        c["name"] for c in (cr.get("crew") or [])
        if c.get("job") == "Director" and c.get("name"))
    if not director:                      # tv: no Director crew, use creators
        director = ", ".join(c["name"] for c in (d.get("created_by") or [])
                             if c.get("name"))
    similar = ",".join(str(r["id"]) for r in
                       ((d.get("recommendations") or {}).get("results") or [])[:20]
                       if r.get("id"))
    return cast_list, director, similar


def save(db, path, **f):
    f.setdefault("source", "tmdb")
    f["updated"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    # A CHANGED tmdb_id means this row was matched to the WRONG title before, so
    # its clearlogo is that other title's art — and fanart's "__none__" marker
    # (stamped against the wrong id, which genuinely had no logo) would block a
    # refetch forever. Clear both so the logo pass picks the row up again.
    # clearlogo/clearlogo_url are not in COLS, so the upsert below leaves them.
    # The art FILE stays: it is content-hashed and other rows may share it.
    new_id = f.get("tmdb_id") or ""
    was = db.execute("SELECT tmdb_id FROM metadata WHERE path=?", (path,)).fetchone()
    if was and (was[0] or "") and (was[0] or "") != new_id:
        # The full-detail facts belong to the old match too, and they are not in
        # COLS either: NULL them so codec_metadata_backfill (which selects
        # `studio IS NULL`) fetches the right film's studio/budget/writer.
        db.execute("UPDATE metadata SET clearlogo='', clearlogo_url='', "
                   "studio=NULL, revenue=NULL, budget=NULL, country=NULL, "
                   "language=NULL, writer=NULL WHERE path=?", (path,))
    db.execute(
        f"INSERT INTO metadata (path,{','.join(COLS)}) "
        f"VALUES (?,{','.join('?' * len(COLS))}) "
        "ON CONFLICT(path) DO UPDATE SET "
        + ",".join(f"{c}=excluded.{c}" for c in COLS),
        [path] + [f.get(c) for c in COLS])
    db.commit()


def backfill_credits(db, tmdb, limit=0):
    """Fill cast/director/similar on rows that were scraped before those columns
    existed. Targeted UPDATE, never save(): save() writes every column, so a
    partial dict would blank plot/poster/rating on 457 good rows."""
    rows = [(p, t) for p, t in db.execute(
        "SELECT path, tmdb_id FROM metadata"
        " WHERE tmdb_id IS NOT NULL AND tmdb_id != ''"
        "   AND (credits IS NULL OR credits = '')")
        if "/" not in (t or "")]          # skip episodes (id is show/season/ep)
    if limit:
        rows = rows[:limit]
    print(f"credits backfill: {len(rows)} row(s)")
    ok = fails = 0
    for path, tid in rows:
        kind = "tv" if not Path(path).suffix else "movie"   # show rows are dirs
        try:
            d = tmdb.get(f"/{kind}/{tid}", append_to_response=APPEND)
            cast_list, director, similar = credit_fields(d)
            db.execute("UPDATE metadata SET credits=?, director=?, similar=?"
                       " WHERE path=?", (cast_list, director, similar, path))
            db.commit()
            ok += 1
            print(f"  [{ok}/{len(rows)}] {d.get('title') or d.get('name')}: "
                  f"{len(cast_list.split(';')) if cast_list else 0} cast"
                  f"{', dir ' + director if director else ''}")
        except Exception as e:
            fails += 1
            print(f"  FAIL {path}: {e}", file=sys.stderr)
    print(f"credits: {ok} filled, {fails} failed ({tmdb.calls} API calls)")



def live_media_paths(roots):
    """Every path that SHOULD carry a metadata row right now: movie video files,
    show directories, and episode files. Same enumeration the scraper/exporter
    use, so the sets line up exactly."""
    live = set()
    for root in roots:
        rp = Path(root["path"])
        if not rp.is_dir():
            continue
        if root.get("kind") == "tv":
            for show_dir in (p for p in rp.iterdir() if p.is_dir()):
                live.add(str(show_dir))
                for f in show_dir.rglob("*"):
                    if EXTRAS_RE.search("/" + str(f.relative_to(show_dir))):
                        continue
                    if f.suffix.lower() in VIDEO_EXTS and "sample" not in f.name.lower():
                        live.add(str(f))
        else:
            for entry in rp.iterdir():
                if entry.name in ("$RECYCLE.BIN", "System Volume Information", "Config.Msi"):
                    continue
                # mirrors library.cpp: a temp file, or a torrent import still
                # being copied ("<Title>.importing"), is not a title yet
                if entry.name.lower().endswith((".tmp", ".importing")):
                    continue
                if entry.is_dir():
                    v = biggest_video(entry)
                    if v:
                        live.add(str(v))
                elif entry.suffix.lower() in VIDEO_EXTS:
                    live.add(str(entry))
    return live


def prune_orphans(db):
    """Delete metadata rows whose file is gone, plus their now-unreferenced
    cached posters. GUARDED: if ANY configured root is missing or empty, a drive
    is unmounted — abort entirely rather than treat every path under it as
    'deleted' and wipe the table. Only rows UNDER a present root are considered,
    so a removed-from-config root is left untouched."""
    def on_mounted_volume(path):
        """True if `path` sits on a dedicated mount (its own device), not the
        root filesystem. An unmounted media drive collapses onto '/'."""
        cur = Path(path).resolve()
        while cur != cur.parent:
            if os.path.ismount(str(cur)):
                return str(cur) != "/"
            cur = cur.parent
        return False

    roots = json.loads(CFG.read_text())["roots"]
    present = []
    for root in roots:
        rp = Path(root["path"])
        if not rp.is_dir():
            print(f"prune: ABORT — root missing ({root['path']}); drive unmounted?",
                  file=sys.stderr)
            return
        # A root with content is trustworthy. An EMPTY root is fine only if its
        # drive is genuinely mounted (a legit empty root like an unused TV dir);
        # empty AND not on a mount = the drive fell out → abort before we treat
        # every path under it as deleted.
        if not any(rp.iterdir()) and not on_mounted_volume(rp):
            print(f"prune: ABORT — root empty and not on a mount ({root['path']}); "
                  "a drive is likely unmounted", file=sys.stderr)
            return
        present.append(str(rp))

    live = live_media_paths(roots)
    rows = list(db.execute("SELECT path, poster FROM metadata"))
    gone = [(pth, pos) for pth, pos in rows
            if any(pth.startswith(r) for r in present) and pth not in live]
    if not gone:
        print("prune: nothing to remove")
        return

    surviving_art = {pos for pth, pos in rows
                     if pos and pth not in {g[0] for g in gone}}
    removed_art = 0
    for pth, pos in gone:
        db.execute("DELETE FROM metadata WHERE path=?", (pth,))
        if pos and pos not in surviving_art and os.path.exists(pos):
            try:
                os.remove(pos); removed_art += 1
            except OSError:
                pass
    db.commit()
    print(f"prune: removed {len(gone)} orphan row(s), {removed_art} poster(s)")
    for pth, _ in gone[:8]:
        print(f"  - {Path(pth).name}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--key", default="")
    ap.add_argument("--credits", action="store_true",
                    help="backfill cast/director/similar on existing rows")
    ap.add_argument("--prune", action="store_true",
                    help="also remove metadata rows whose file is gone (guarded)")
    ap.add_argument("--limit", type=int, default=0,
                    help="cap rows processed (use with --credits for a test run)")
    ap.add_argument("--refresh", action="store_true",
                    help="re-scrape rows that already look complete")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    cfg = json.loads(CFG.read_text())
    key = args.key or codec_keys.tmdb_key(cfg.get("settings", {}))
    if not key:
        sys.exit("no TMDB key (codec carries none, config settings.tmdbApiKey, or --key)")

    db = sqlite3.connect(DB, timeout=30)
    db.execute("""CREATE TABLE IF NOT EXISTS metadata (
        path TEXT PRIMARY KEY, title TEXT, year INTEGER, plot TEXT,
        rating REAL, votes INTEGER, runtime_min INTEGER, genres TEXT,
        premiered TEXT, imdb_id TEXT, tmdb_id TEXT,
        poster TEXT, fanart TEXT, poster_url TEXT, fanart_url TEXT,
        credits TEXT, director TEXT, similar TEXT,
        clearlogo TEXT, clearlogo_url TEXT, revenue INTEGER, budget INTEGER,
        studio TEXT, country TEXT, language TEXT, writer TEXT,
        source TEXT, updated TEXT)""")
    # Add any missing column in place. These "extended" columns
    # (clearlogo/revenue/budget/studio/country/language/writer) were previously
    # created ONLY by the C++ app, so export_library — Python — crashed on a
    # fresh or Python-only DB where the app had never run. Ensuring them here
    # (any writer runs before the exporter in codec-refresh) closes that gap.
    have = {r[1] for r in db.execute("PRAGMA table_info(metadata)")}
    for col, typ in (("credits", "TEXT"), ("director", "TEXT"),
                     ("similar", "TEXT"), ("clearlogo", "TEXT"),
                     ("clearlogo_url", "TEXT"), ("revenue", "INTEGER"),
                     ("budget", "INTEGER"), ("studio", "TEXT"),
                     ("country", "TEXT"), ("language", "TEXT"),
                     ("writer", "TEXT")):
        if col not in have:
            db.execute(f"ALTER TABLE metadata ADD COLUMN {col} {typ}")
    db.commit()
    meta = {r[0]: {"plot": r[1], "poster": r[2], "tmdb_id": r[3], "title": r[4],
                   "source": r[5]}
            for r in db.execute("SELECT path,plot,poster,tmdb_id,title,source FROM metadata")}

    if args.credits:
        backfill_credits(db, Tmdb(key), args.limit)
        return

    over = overrides()
    work = list(build_worklist(meta, args.refresh, over))
    # An override key is a PATH substring, not a title. One written in
    # "Title (Year)" style matches nothing and is a SILENT no-op — say so,
    # rather than leaving the owner to wonder why the pin never took.
    known = [w[0] for w in work] + list(meta)
    for frag in over:
        if not any(frag.lower() in k.lower() for k in known):
            print(f"  ! override {frag!r} matches no path on disk "
                  "(the key is a path substring, not a title) — ignored")
    if args.dry_run:
        for path, kind, title, year, _ in work:
            print(f"{kind:8} {title!r} ({year or '?'}) <- {path}")
        print(f"-- {len(work)} items need scraping")
        return

    tmdb = Tmdb(key)
    show_ids = {}   # show_dir -> tmdb id (for episode lookups)
    for p, info in meta.items():
        if info["tmdb_id"] and not Path(p).suffix:  # show rows are directories
            show_ids[p] = info["tmdb_id"]
    ok = fails = 0

    def done(path, kind, label):
        nonlocal ok
        ok += 1
        print(f"  [{ok}/{len(work)}] {kind}: {label}")

    for path, kind, title, year, show_dir in work:
        try:
            if kind == "movie":
                pinned = override_for(path, over)
                if pinned:
                    d = tmdb.get(f"/movie/{pinned}", append_to_response=APPEND)
                else:
                    d = pick_movie(tmdb, path, title, year)
                cast_list, director, similar = credit_fields(d)
                save(db, path, credits=cast_list, director=director, similar=similar,
                     title=d["title"],
                     year=int((d.get("release_date") or "0")[:4] or 0),
                     plot=d.get("overview", ""), rating=d.get("vote_average"),
                     votes=d.get("vote_count"), runtime_min=d.get("runtime"),
                     genres=genres_text(d), premiered=d.get("release_date", ""),
                     imdb_id=d.get("imdb_id", ""), tmdb_id=str(d["id"]),
                     poster=cache_image(IMG + d["poster_path"] if d.get("poster_path") else ""),
                     poster_url=IMG + d["poster_path"] if d.get("poster_path") else "",
                     fanart=cache_image(FAN + d["backdrop_path"] if d.get("backdrop_path") else ""),
                     fanart_url=FAN + d["backdrop_path"] if d.get("backdrop_path") else "")
                done(path, kind, d["title"])
            elif kind == "show":
                hit = tmdb.search("tv", title, year)
                if not hit:
                    raise LookupError("no match")
                d = tmdb.get(f"/tv/{hit['id']}", append_to_response=APPEND)
                show_ids[path] = str(d["id"])
                cast_list, director, similar = credit_fields(d)
                save(db, path, credits=cast_list, director=director, similar=similar,
                     title=d["name"],
                     year=int((d.get("first_air_date") or "0")[:4] or 0),
                     plot=d.get("overview", ""), rating=d.get("vote_average"),
                     votes=d.get("vote_count"), genres=genres_text(d),
                     premiered=d.get("first_air_date", ""), tmdb_id=str(d["id"]),
                     poster=cache_image(IMG + d["poster_path"] if d.get("poster_path") else ""),
                     poster_url=IMG + d["poster_path"] if d.get("poster_path") else "",
                     fanart=cache_image(FAN + d["backdrop_path"] if d.get("backdrop_path") else ""),
                     fanart_url=FAN + d["backdrop_path"] if d.get("backdrop_path") else "")
                done(path, kind, d["name"])
            else:  # episode
                num = episode_number(title, path)
                sid = show_ids.get(show_dir)
                if not sid and show_dir:
                    # Show row exists (e.g. from Kodi) but carries no TMDB id —
                    # resolve it once by its known title.
                    known = meta.get(show_dir, {}).get("title") or parse(Path(show_dir).name)[0]
                    hit = tmdb.search("tv", known.replace(":", ""))
                    if hit:
                        sid = show_ids[show_dir] = str(hit["id"])
                if not num or not sid:
                    raise LookupError("no episode number" if not num else "show has no tmdb id")
                se, ep = num
                mapped = remap_episode(tmdb, sid, show_dir, se, ep)
                if mapped:
                    se, ep = mapped
                d = tmdb.get(f"/tv/{sid}/season/{se}/episode/{ep}")
                save(db, path, title=d.get("name", ""), plot=d.get("overview", ""),
                     rating=d.get("vote_average"), votes=d.get("vote_count"),
                     runtime_min=d.get("runtime"), premiered=d.get("air_date", ""),
                     tmdb_id=f"{sid}/{se}/{ep}",
                     poster=cache_image(STILL + d["still_path"] if d.get("still_path") else ""),
                     poster_url=STILL + d["still_path"] if d.get("still_path") else "")
                done(path, kind, f"S{se:02d}E{ep:02d} {d.get('name', '')}")
        except Exception as e:
            fails += 1
            print(f"  FAIL {kind}: {title!r} ({path}): {e}", file=sys.stderr)

    print(f"scraped {ok}/{len(work)} ({fails} failed, {tmdb.calls} API calls)")
    if args.prune:
        prune_orphans(db)
    if ok:
        print("next: python3 ~/Projects/codec/scripts/export_library.py  # refresh laptop manifest")


if __name__ == "__main__":
    main()
