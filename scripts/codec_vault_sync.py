#!/usr/bin/env python3
"""Codec -> myOS vault: watched movies and shows become Inventory notes.

Template follows the author's "Movie & SHOW template mockup" (2026-07): cover art
from the TMDB cache, summary callout, a codec-fed progress bar between
<!-- codec:stats --> markers, ticket/review/links sections. Shows get ONE
note per series (mined-not-mirrored — never per episode) with status and
progress refreshed nightly.

Rules: user prose is never edited. The sync only (1) creates missing notes,
(2) fills an EMPTY `watched:` line, (3) rewrites the marked stats block, and
(4) refreshes machine frontmatter (status:/progress:) on show notes it owns.
Hermes-runnable (stdlib only). Dry-run by default.
"""
import argparse, re, shutil, sqlite3
from datetime import date, datetime, timezone
from pathlib import Path
import codec_paths  # where codec's data lives (~/.local/share/codec)

DB = codec_paths.DB
# Media layer, NOT Inventory — "inventory is for physical items".
MEDIA = Path.home() / "Documents/Obsidian Vault/1 Active/Media"
MOVIES_DIR = MEDIA / "Movies"
TV_DIR = MEDIA / "TV"
INDEX_NOTE = MEDIA / "Movies & TV.md"

EP_RE = re.compile(  # double episodes (S06E14E15) key off the first number, as everywhere
    r"\b(?:S(\d{1,2})E(\d{1,3})(?:[-_. ]?E\d{1,3})*|(\d{1,2})x(\d{2,3}))\b", re.I)
EP_LOOSE_RE = re.compile(r"(?:\bEpisode\s+|-\s+)(\d{1,3})\b", re.I)
VIDEO_EXTS = (".mkv", ".mp4", ".avi", ".m2ts", ".ts", ".mov", ".wmv",
              ".flv", ".webm", ".mpg", ".mpeg", ".iso")

STATS_START, STATS_END = "<!-- codec:stats -->", "<!-- /codec:stats -->"

MOVIE_TEMPLATE = """---
type: inventory
category: Movies
title: "{title}"
year: {year}
director:
rating:
watched: {watched}
owned: true
source: codec
tags:
  - movie
index: "[[Movies & TV]]"
---
---
# {title} ({year})
{art}
> [!abstract] Summary
> {plot}

{stats}

## 🎟 Ticket stub
<!-- raw photo of the ticket — send to Hermes on Discord, or capture with SUPER+/ -->

## ⭐ My review
-

## 👥 Others' reviews
-

## 🔗 Links
- File: `{path}`
- Event note:
- Receipt / purchase:
"""

SHOW_TEMPLATE = """---
type: inventory
category: TV
title: "{title}"
year: {year}
rating:
status: {status}
progress: "{progress}"
watched: {watched}
owned: true
source: codec
tags:
  - tv
index: "[[Movies & TV]]"
---
---
# {title} ({year})
{art}
> [!abstract] Summary
> {plot}

{stats}

## ⭐ My review
-

## 🔗 Links
- Folder: `{path}`
"""

SHOWS_DATAVIEW = """
## Shows

```dataview
TABLE WITHOUT ID file.link AS Show, default(progress, "—") AS Progress, default(status, "—") AS Status, default(rating, "") AS "★"
FROM "1 Active/Inventory"
WHERE type = "inventory" AND category = "TV"
SORT file.name ASC
```
"""


def local_day(last_played):
    """The calendar day a watch happened, in LOCAL time.

    media_state.last_played is UTC by contract (codec_serve._merge_into_hub).
    Slicing the first 10 characters off it gives the UTC date, which for an
    evening viewing is TOMORROW — so a movie watched at 10pm sorts above one
    watched at 11pm the previous night, and 'what did I watch tonight' lands
    under the wrong day. Convert to local before taking the date.
    """
    s = (last_played or "").strip()
    if not s:
        return ""
    try:
        dt = datetime.strptime(s[:19], "%Y-%m-%d %H:%M:%S")
    except ValueError:
        return s[:10]  # unparseable: better the raw date than nothing
    return dt.replace(tzinfo=timezone.utc).astimezone().date().isoformat()


def norm_name(s):
    return re.sub(r"[^a-z0-9]", "", s.lower())


def safe_name(title, year):
    t = re.sub(r'[/\\:*?"<>|]', " ", title).strip()
    return f"{t} ({year})" if year else t


def stats_block(pct, line):
    return (f"{STATS_START}\n"
            f'<progress value="{pct}" max="100"></progress>\n\n'
            f"**{line}**\n"
            f"{STATS_END}")


def movie_stats(pct, plays):
    # Watch count always rides next to the bar (the author 2026-07-18).
    seen = f"watched {plays}×" if plays >= 1 else \
        ("watched" if pct >= 90 else "in progress")
    return stats_block(pct, f"{pct}% · {seen}")


def show_stats(done, total, last, finished, plays=0):
    pct = round(done * 100 / total) if total else 0
    tail = "FINISHED" if finished else (f"up to {last}" if last else "not started")
    if finished and plays >= 2:
        tail += f" · seen {plays}×"
    return stats_block(pct, f"{done}/{total} episodes · {tail}")


def copy_art(src, folder, name, apply):
    """Poster from the codec cache -> vault _art; returns the embed line."""
    if not src or not Path(src).exists():
        return ""
    art_dir = folder / "_art"
    dst = art_dir / f"{name}.jpg"
    if apply:
        art_dir.mkdir(exist_ok=True)
        if not dst.exists():
            shutil.copyfile(src, dst)
    return f"\n![[{dst.name}|360]]\n"


def fill_watched(text, watched):
    m = re.search(r"^watched:\s*$", text, re.M)
    if not m:
        return text, False
    return text[:m.start()] + f"watched: {watched}" + text[m.end():], True


def refresh_stats(text, block):
    """Rewrite the marked stats block; insert one after the summary callout
    (or the H1) when a note has none. Prose is never touched."""
    if STATS_START in text and STATS_END in text:
        pre, rest = text.split(STATS_START, 1)
        _, post = rest.split(STATS_END, 1)
        new = pre + block + post
        return new, new != text
    lines = text.splitlines(keepends=True)
    at = None
    for i, ln in enumerate(lines):
        if ln.startswith("> "):
            at = i + 1
        elif at is not None and not ln.startswith("> "):
            break
    if at is None:
        for i, ln in enumerate(lines):
            if ln.startswith("# "):
                at = i + 1
                break
    if at is None:
        return text, False
    lines.insert(at, "\n" + block + "\n")
    return "".join(lines), True


def set_frontmatter(text, **fields):
    """Update machine-owned frontmatter lines in place (status:/progress:)."""
    changed = False
    for key, val in fields.items():
        pattern = re.compile(rf"^{key}:.*$", re.M)
        if pattern.search(text):
            new = pattern.sub(f"{key}: {val}", text, count=1)
            changed |= new != text
            text = new
    return text, changed


PLOT_PLACEHOLDER = "IMDb synopsis — pulled via"
FM_RE = re.compile(r"\A---\n(.*?)\n---\n", re.S)
MOVIE_SECTIONS = [
    ("## 🎟 Ticket stub", "Ticket stub",
     "<!-- raw photo of the ticket — send to Hermes on Discord, or capture with SUPER+/ -->"),
    ("## ⭐ My review", "My review", "-"),
    ("## 👥 Others' reviews", "Others' reviews", "-"),
    ("## 🔗 Links", "Links", "- Event note:\n- Receipt / purchase:"),
]
TV_SECTIONS = [
    ("## ⭐ My review", "My review", "-"),
    ("## 🔗 Links", "Links", ""),
]


def conform_note(text, kind, meta_row, art_line):
    """Bring one note up to the CURRENT template: fix stale index links, add
    missing frontmatter keys/sections, fill placeholder synopsis + missing
    cover from library metadata. Prose is never rewritten — only known
    placeholders are replaced and only missing structure is added."""
    changes = []
    m = FM_RE.match(text)
    if not m:
        return text, changes
    fm, body = m.group(1), text[m.end():]

    # 1. Stale index pointers from the Inventory era.
    fm2 = re.sub(r'^(index:\s*"?\[\[)(?:Inventory|Movies|TV)(\]\]"?)\s*$',
                 r'\1Movies & TV\2', fm, count=1, flags=re.M)
    if fm2 != fm:
        changes.append("index -> Movies & TV")
        fm = fm2

    title = year = plot = None
    if meta_row:
        _, title, year, plot, _ = meta_row
        if year and re.search(r"^year:\s*$", fm, re.M):
            fm = re.sub(r"^year:\s*$", f"year: {year}", fm, count=1, flags=re.M)
            changes.append("year filled")

    # 2. Missing frontmatter keys (empty — the author's values are his to fill).
    want_keys = ["director", "rating", "watched"] if kind == "movie" \
        else ["rating", "watched"]
    add = [f"{k}:" for k in want_keys
           if not re.search(rf"^{k}:", fm, re.M)]
    if meta_row and not re.search(r"^source:", fm, re.M):
        add.append("source: codec")
    if add:
        fm += "\n" + "\n".join(add)
        changes.append("frontmatter keys: " + ", ".join(a.split(":")[0] for a in add))

    # 3. H1 gains the year (template is "Title (Year)").
    if year:
        h1 = re.search(r"^# (.+)$", body, re.M)
        if h1 and "(" not in h1.group(1):
            body = body[:h1.start(1)] + h1.group(1).rstrip() + f" ({year})" \
                + body[h1.end(1):]
            changes.append("H1 year")

    # 4. Cover art when the note has no image at all.
    if art_line and "![[" not in body:
        h1 = re.search(r"^# .+$", body, re.M)
        if h1:
            body = body[:h1.end()] + "\n" + art_line.strip("\n") + body[h1.end():]
            changes.append("cover art")

    # 5. Placeholder synopsis -> real plot.
    if plot and PLOT_PLACEHOLDER in body:
        body = re.sub(r"^> \*?" + re.escape(PLOT_PLACEHOLDER) + r".*$",
                      "> " + plot.replace("\n", " ")[:400], body, count=1,
                      flags=re.M)
        changes.append("synopsis filled")

    # 6. Drop dead "## Cover" placeholder sections (comment-only) once the
    # note actually has an image.
    if "![[" in body:
        lines = body.splitlines(keepends=True)
        for i, ln in enumerate(lines):
            if re.match(r"^##+\s*(?:🖼\s*)?Cover\s*$", ln.strip()):
                j = i + 1
                while j < len(lines) and not lines[j].startswith("## "):
                    j += 1
                sec = [l.strip() for l in lines[i + 1:j]]
                if all(l in ("", "<!-- cover art -->") for l in sec):
                    body = "".join(lines[:i] + lines[j:])
                    changes.append("dead Cover section removed")
                break

    # 7. Missing template sections, inserted in template order.
    sections = MOVIE_SECTIONS if kind == "movie" else TV_SECTIONS
    for si, (header, key, filler) in enumerate(sections):
        if re.search(rf"^##.*{re.escape(key)}", body, re.M):
            continue
        block = f"\n{header}\n{filler}\n\n" if filler else f"\n{header}\n\n"
        anchor = None
        for later_header, later_key, _ in sections[si + 1:]:
            hm = re.search(rf"^##.*{re.escape(later_key)}.*$", body, re.M)
            if hm:
                anchor = hm.start()
                break
        body = (body[:anchor] + block + body[anchor:]) if anchor is not None \
            else body.rstrip("\n") + "\n" + block
        changes.append(f"+ {key} section")

    # 8. Library path under Links.
    if meta_row:
        label = "File" if kind == "movie" else "Folder"
        if f"- {label}:" not in body:
            lm = re.search(r"^##.*Links.*$", body, re.M)
            if lm:
                body = body[:lm.end()] + f"\n- {label}: `{meta_row[0]}`" \
                    + body[lm.end():]
                changes.append(f"{label} link")

    # Whitespace polish only: one blank line between blocks, headers breathe.
    tidy = re.sub(r"\n{3,}", "\n\n", body)
    tidy = re.sub(r"([^\n])\n(## )", r"\1\n\n\2", tidy)
    if tidy != body:
        body = tidy
        if not changes:
            changes.append("spacing")

    return f"---\n{fm}\n---\n" + body, changes


def episode_no(name):
    m = EP_RE.search(name)
    if m:
        return int(m.group(1) or m.group(3)), int(m.group(2) or m.group(4))
    m = EP_LOOSE_RE.search(re.sub(r"[._]", " ", name))
    return (1, int(m.group(1))) if m else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--path", default="", help="media path that just started "
                    "playing — force-create its note NOW (mid-watch reviews)")
    args = ap.parse_args()
    apply = args.apply
    # Opt-in (Settings ▸ SYSTEM ▸ OBSIDIAN NOTES, experimental): this writes
    # into ~/Documents/Obsidian Vault, Obsidian's default vault name.
    try:
        import json
        cfg = json.loads((Path.home() / ".config/codec/config.json").read_text())
        if not cfg.get("settings", {}).get("vaultNotes", False):
            print("obsidian notes are off (settings.vaultNotes)")
            return
    except (OSError, ValueError):
        return

    db = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    # media_state keys are canonical root-relative paths ("Movies/…"), the
    # metadata table keys absolute paths ("/mnt/Movies/…") — join on suffix.
    state = {p: (pos, dur, wc, comp, local_day(lp))
             for p, pos, dur, wc, comp, lp in db.execute(
                 "SELECT path, position, duration, watch_count, completed,"
                 " last_played FROM media_state")}
    meta = {p: (title, year, plot, poster) for p, title, year, plot, poster
            in db.execute("SELECT path, title, year, plot, poster FROM metadata")}

    def state_for(abs_path):
        for sp, row in state.items():
            # Match on a path-separator boundary, not a raw suffix: 'Movies/A.mkv'
            # must not bind to '/x/OtherMovies/A.mkv'. Anchor with a leading '/'.
            if abs_path == sp or abs_path.endswith("/" + sp):
                return row
        return None

    # Playback-start target: the app fires --path the moment something plays,
    # so the note exists while the author is still watching (nightly is the safety
    # net, not the source of truth).
    target_movie = target_show = None
    target_season = 0
    if args.path:
        from urllib.parse import unquote
        want = unquote(args.path)
        hit = next((p for p in meta
                    if p == want or p.endswith(want) or want.endswith(p)), None)
        if hit:
            if "/tv" in hit.lower():
                for p in meta:
                    if not Path(p).suffix and hit.startswith(p + "/"):
                        target_show = p
                        num = episode_no(Path(hit).name)
                        target_season = num[0] if num else 1
                        break
            else:
                target_movie = hit

    made = filled = statted = kept = conformed = 0
    log = []

    # Library lookups for the conform pass (all titles, watched or not).
    movies_all, shows_all = {}, {}
    for p, (t, y, pl, po) in meta.items():
        if not t:
            continue
        if "/tv" in p.lower():
            if not Path(p).suffix:
                shows_all[norm_name(safe_name(t, y))] = (p, t, y, pl, po)
                shows_all[norm_name(t)] = (p, t, y, pl, po)
        elif p.lower().endswith(VIDEO_EXTS):
            movies_all[norm_name(safe_name(t, y))] = (p, t, y, pl, po)

    # ── Movies ────────────────────────────────────────────────────────────
    # One pass over completed movies (create/fill), then a stats refresh over
    # every movie note that matches ANY state row (partial watches included).
    by_norm = {}  # normalized "title (year)" -> (pct, plays, watched_date)
    for abs_path, (title, year, plot, poster) in meta.items():
        if "/tv" in abs_path.lower() or not title \
                or not abs_path.lower().endswith(VIDEO_EXTS):
            continue
        row = state_for(abs_path)
        is_target = abs_path == target_movie
        if not row and not is_target:
            continue
        pos, dur, wc, comp, lp = row or (0, 0, 0, 0, "")
        pct = 100 if comp else (round(pos * 100 / dur) if dur else 0)
        plays = max(wc, 1 if comp else 0)
        by_norm[norm_name(safe_name(title, year))] = (pct, plays, lp)

        if not comp and not is_target:
            continue
        name = safe_name(title, year)
        note = MOVIES_DIR / f"{name}.md"
        if not note.exists():
            want = norm_name(name)
            for existing in MOVIES_DIR.glob("*.md"):
                if norm_name(existing.stem) == want:
                    note = existing
                    break
        if note.exists():
            continue  # fills/stats handled by the passes below
        made += 1
        log.append(f"  + movie note: {note.name}")
        if apply:
            MOVIES_DIR.mkdir(exist_ok=True)
            note.write_text(MOVIE_TEMPLATE.format(
                title=title, year=year or "",
                watched=(lp or str(date.today())) if comp else "",
                art=copy_art(poster, MOVIES_DIR, name, apply) or "",
                plot=(plot or "").replace("\n", " ")[:400],
                stats=movie_stats(pct, plays), path=abs_path))

    # Conform every movie note to the CURRENT template, then refresh stats.
    for note in sorted(MOVIES_DIR.glob("*.md")):
        mrow = movies_all.get(norm_name(note.stem))
        text = orig = note.read_text()
        art = ""
        if mrow and "![[" not in text:
            art = copy_art(mrow[4], MOVIES_DIR, note.stem, apply)
        text, ch = conform_note(text, "movie", mrow, art)
        if ch:
            conformed += 1
            log.append(f"  ~ conform: {note.name} ({', '.join(ch)})")
        row = by_norm.get(norm_name(note.stem))
        if row:
            pct, plays, lp = row
            if pct >= 90:
                text, did = fill_watched(text, lp or str(date.today()))
                filled += did
                if did:
                    log.append(f"  ~ watched filled: {note.name}")
            text, did = refresh_stats(text, movie_stats(pct, plays))
            statted += did
        elif STATS_START not in text:
            # No codec state (theater visit, pre-codec watch) but a filled
            # watched: date -> the bar reflects the author's own claim.
            if re.search(r"^watched:\s*\S+", text, re.M):
                text, did = refresh_stats(text, movie_stats(100, 1))
                statted += did
                if did:
                    log.append(f"  + stats (from watched:): {note.name}")
        if text != orig:
            if apply:
                note.write_text(text)
        else:
            kept += 1

    # Same conform pass over TV notes (the show loop below owns stats).
    if TV_DIR.exists():
        for note in sorted(TV_DIR.glob("*.md")):
            base = re.sub(r"\s*\(S\d+\)$", "", note.stem)
            mrow = shows_all.get(norm_name(base))
            text = orig = note.read_text()
            art = ""
            if mrow and "![[" not in text:
                art = copy_art(mrow[4], TV_DIR, note.stem, apply)
            text, ch = conform_note(text, "tv", mrow, art)
            if ch:
                conformed += 1
                log.append(f"  ~ conform: {note.name} ({', '.join(ch)})")
            if text != orig and apply:
                note.write_text(text)

    # ── Shows: one note per SEASON (the author's call — per-season reviews);
    # single-season shows keep the plain "Title (Year)" name. ──────────────
    show_dirs = [p for p in meta if "/tv" in p.lower() and not Path(p).suffix]
    for sdir in sorted(show_dirs):
        title, year, plot, poster = meta[sdir]
        if not title:
            continue
        seasons = {}  # season -> [episode paths]
        for p in meta:
            if p.startswith(sdir + "/") and p.lower().endswith(VIDEO_EXTS):
                num = episode_no(Path(p).name)
                seasons.setdefault(num[0] if num else 1, []).append(p)
        if not seasons:
            continue
        multi = len(seasons) > 1
        for se in sorted(seasons):
            eps = seasons[se]
            done, last, last_lp = 0, None, ""
            plays = None  # season rewatch count = fewest plays of any episode
            for p in eps:
                row = state_for(p)
                wc = row[2] if row else 0
                plays = wc if plays is None else min(plays, wc)
                if row and row[3]:  # completed
                    done += 1
                    last_lp = max(last_lp, row[4])
                    num = episode_no(Path(p).name)
                    if num and (last is None or num > last):
                        last = num
            plays = plays or 0
            is_target = sdir == target_show and se == target_season
            if done == 0 and not is_target:
                continue  # untouched seasons stay out of the vault
            total = len(eps)
            finished = done >= total
            last_label = f"S{last[0]:02d}E{last[1]:02d}" if last else ""
            progress = f"{done}/{total}" + (f" · {last_label}" if last_label else "")
            status = "finished" if finished else "watching"
            name = f"{title} (S{se:02d})" if multi else safe_name(title, year)
            name = re.sub(r'[/\\:*?"<>|]', " ", name).strip()
            note = TV_DIR / f"{name}.md"
            if not note.exists() and TV_DIR.exists():
                want = norm_name(name)
                for existing in TV_DIR.glob("*.md"):
                    if norm_name(existing.stem) == want:
                        note = existing
                        break
            if not note.exists():
                made += 1
                log.append(f"  + show note: {note.name} ({progress})")
                if apply:
                    TV_DIR.mkdir(exist_ok=True)
                    note.write_text(SHOW_TEMPLATE.format(
                        title=f"{title} (S{se:02d})" if multi else title,
                        year=year or "", status=status, progress=progress,
                        watched=last_lp if finished else "",
                        art=copy_art(poster, TV_DIR, name, apply) or "",
                        plot=(plot or "").replace("\n", " ")[:400],
                        stats=show_stats(done, total, last_label, finished,
                                         plays),
                        path=sdir))
                continue
            text = orig = note.read_text()
            if "source: codec" in text.split("---", 2)[1]:
                text, _ = set_frontmatter(text, status=status,
                                          progress=f'"{progress}"')
            if finished:
                text, did = fill_watched(text, last_lp or str(date.today()))
                filled += did
            text, did = refresh_stats(text, show_stats(done, total, last_label,
                                                       finished, plays))
            statted += did
            if text != orig:
                log.append(f"  ~ show refresh: {note.name} ({progress})")
                if apply:
                    note.write_text(text)
            else:
                kept += 1

    # ── Index note: add the Shows table once ─────────────────────────────
    if INDEX_NOTE.exists():
        idx = INDEX_NOTE.read_text()
        if 'category = "TV"' not in idx:
            log.append("  + Shows dataview section -> Movies & TV.md")
            if apply:
                INDEX_NOTE.write_text(idx.rstrip() + "\n" + SHOWS_DATAVIEW)

    mode = "APPLIED" if apply else "DRY-RUN"
    print(f"{mode}: {made} created, {conformed} conformed, {filled} "
          f"watched-filled, {statted} stats-refreshed, {kept} untouched")
    for line in log:
        print(line)


if __name__ == "__main__":
    main()
