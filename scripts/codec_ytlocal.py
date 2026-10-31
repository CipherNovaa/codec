#!/usr/bin/env python3
"""codec_ytlocal — YouTube without an account: codec's own lists.

The way codec does YouTube when no browser login is connected (Settings ▸
YOUTUBE ▸ CODEC'S OWN, where a new install starts). codec keeps the channels
you follow, your Watch Later, your playlists and what you watched itself, in
DATA/youtube.json, and builds the feeds from YouTube's public pages:

  SUBS      every followed channel's public feed (its 15 newest, ~65 ms a
            channel, fetched together), lengths from the channel's own page
  FOR YOU   YouTube's suggestions beside what you watched last, and what's
            new from the channels you follow — less what you've seen
  the rest  the lists themselves

Nothing here signs in, so nothing here can get an account flagged. The
worker (codec_yt.py) owns the instance: Local(codec_yt) hands it the row
parsers and the InnerTube call it shares with the signed-in path.
"""
import csv
import io
import json
import random
import re
import secrets
import threading
import time
import urllib.request
import xml.etree.ElementTree as ET
import zipfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import codec_paths

STORE = codec_paths.DATA / "youtube.json"
_EMPTY = {"v": 1, "subs": [], "watchlater": [], "playlists": [], "history": [], "hidden": [],
          "liked": [], "disliked": []}
# LIKE puts a video on a list of its own, shown first in PLAYLISTS (as an
# account's "Liked videos" is)
LIKED_ID = "liked"
_ROW_KEYS = ("uri", "title", "subtitle", "artUrl", "durationS", "kind", "videoId",
             "channelUrl", "published", "isShort", "channel", "ts")
_HISTORY_CAP = 2000
_UA = "Mozilla/5.0 (X11; Linux x86_64; rv:132.0) Gecko/20100101 Firefox/132.0"
_NS = {"a": "http://www.w3.org/2005/Atom", "yt": "http://www.youtube.com/xml/schemas/2015",
       "media": "http://search.yahoo.com/mrss/"}
# A channel page's Videos tab (InnerTube browse params youtube.com sends).
_VIDEOS_TAB = "EgZ2aWRlb3PyBgQKAjoA"


def ago(ts, now=None):
    """'3 days ago' — YouTube's own wording, from a timestamp."""
    s = max(0, int((now or time.time()) - ts))
    for size, unit in ((31536000, "year"), (2592000, "month"), (604800, "week"),
                       (86400, "day"), (3600, "hour"), (60, "minute")):
        if s >= size:
            n = s // size
            return f"{n} {unit}{'s' if n != 1 else ''} ago"
    return "just now"


def views(n):
    """9393005 → '9.4M views' (YouTube's short form)."""
    n = int(n or 0)
    for size, suf in ((1_000_000_000, "B"), (1_000_000, "M"), (1_000, "K")):
        if n >= size:
            v = n / size
            return f"{v:.1f}".rstrip("0").rstrip(".") + f"{suf} views" if v < 10 \
                else f"{int(v)}{suf} views"
    return f"{n} view{'s' if n != 1 else ''}"


def channel_id_of(url):
    m = re.search(r"/channel/(UC[\w-]{22})", url or "")
    return m.group(1) if m else ""


def _iso_ts(s):
    from datetime import datetime
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except (ValueError, AttributeError):
        return 0.0


class Local:
    def __init__(self, yt):
        self.yt = yt                       # codec_yt: innertube, row parsers, fmt_dur
        self._lock = threading.RLock()
        self._data = None
        self._mtime = 0.0
        self._rss = {}                     # channel id -> (ts, rows)
        self._lens = {}                    # channel id -> (ts, {videoId: seconds})
        self._related = {}                 # video id -> (ts, rows)
        self._rec = None                   # (ts, pool)
        self._pool = ThreadPoolExecutor(max_workers=16)
        # channel feeds are tiny and many (265 read in 1.2 s at 48 at once,
        # 2.9 s at 16)
        self._feeds = ThreadPoolExecutor(max_workers=48)

    # ── the store ───────────────────────────────────────────────────────────
    def _read(self):
        """The store as on disk (re-read only when another process wrote it —
        the hub and the app's worker share it on one machine)."""
        try:
            m = STORE.stat().st_mtime
        except OSError:
            m = 0.0
        if self._data is None or m != self._mtime:
            try:
                d = json.loads(STORE.read_text())
            except (OSError, ValueError):
                d = {}
            self._data = {k: d.get(k, v if not isinstance(v, list) else []) for k, v in _EMPTY.items()}
            self._mtime = m
        return self._data

    def _write(self):
        STORE.parent.mkdir(parents=True, exist_ok=True)
        tmp = STORE.with_suffix(".part")
        tmp.write_text(json.dumps(self._data, indent=1))
        tmp.replace(STORE)
        self._mtime = STORE.stat().st_mtime

    def snapshot(self):
        with self._lock:
            d = self._read()
            return {"following": len(d["subs"]), "watchlater": len(d["watchlater"]),
                    "playlists": len(d["playlists"]), "history": len(d["history"])}

    @staticmethod
    def _row(item):
        r = {k: item[k] for k in _ROW_KEYS if k in item and item[k] not in (None, "")}
        r.setdefault("kind", "video")
        vid = r.get("videoId", "")
        if vid and r["kind"] == "video":
            r["uri"] = f"https://www.youtube.com/watch?v={vid}"
            r.setdefault("artUrl", f"https://i.ytimg.com/vi/{vid}/mqdefault.jpg")
        r.pop("isLive", None)              # liveness is a fact about now
        return r

    def video_row(self, video_id):
        """A row for a bare video id (Takeout lists, a write that came without
        one), from the video's own page."""
        d = self.yt.innertube("player", {"videoId": video_id}, need_auth=False)
        vd = d.get("videoDetails") or {}
        mf = (d.get("microformat") or {}).get("playerMicroformatRenderer") or {}
        dur = float(vd.get("lengthSeconds") or 0)
        ch = vd.get("author") or ""
        return self._row({
            "videoId": video_id, "title": vd.get("title") or "(untitled)", "kind": "video",
            "subtitle": " · ".join(x for x in (ch, self.yt.fmt_dur(dur),
                                               views(vd["viewCount"]) if vd.get("viewCount") else "") if x),
            "durationS": dur, "channel": ch,
            "channelUrl": ("https://www.youtube.com/channel/" + vd["channelId"]) if vd.get("channelId") else "",
            "published": ago(_iso_ts(mf.get("publishDate", ""))) if mf.get("publishDate") else ""})

    # ── following ───────────────────────────────────────────────────────────
    def following(self):
        with self._lock:
            return [dict(s) for s in self._read()["subs"]]

    def resolve_channel(self, url_or_id):
        """A channel's permanent id (UC…) from any link to it: /channel/UC…,
        /@handle, /c/name, /user/name."""
        s = (url_or_id or "").strip()
        if re.fullmatch(r"UC[\w-]{22}", s):
            return s
        cid = channel_id_of(s)
        if cid:
            return cid
        if s.startswith("@"):
            s = "https://www.youtube.com/" + s
        r = self.yt.innertube("navigation/resolve_url", {"url": s}, need_auth=False)
        return ((r.get("endpoint") or {}).get("browseEndpoint") or {}).get("browseId", "")

    def subscribe(self, url_or_id, title=""):
        cid = self.resolve_channel(url_or_id)
        if not cid:
            raise RuntimeError("couldn't find that channel")
        if not title:
            try:
                title = self._feed(cid, fresh=True)[1] or ""
            except Exception:
                title = ""
        with self._lock:
            d = self._read()
            if not any(s["id"] == cid for s in d["subs"]):
                d["subs"].insert(0, {"id": cid, "title": title or cid,
                                     "url": "https://www.youtube.com/channel/" + cid,
                                     "added": int(time.time())})
                self._write()
        self._rec = None
        return {"id": cid, "title": title or cid}

    def unsubscribe(self, url_or_id):
        cid = self.resolve_channel(url_or_id)
        with self._lock:
            d = self._read()
            gone = [s for s in d["subs"] if s["id"] == cid]
            d["subs"] = [s for s in d["subs"] if s["id"] != cid]
            self._write()
        self._rec = None
        return {"id": cid, "title": gone[0]["title"] if gone else ""}

    # ── a channel's public feed ─────────────────────────────────────────────
    def _feed(self, cid, fresh=False):
        """(rows, channel title) — the channel's 15 newest uploads from its
        public feed, cached 15 minutes."""
        hit = self._rss.get(cid)
        if hit and not fresh and time.time() - hit[0] < 900:
            return hit[1], hit[2]
        req = urllib.request.Request(
            "https://www.youtube.com/feeds/videos.xml?channel_id=" + cid,
            headers={"User-Agent": _UA})
        root = ET.fromstring(urllib.request.urlopen(req, timeout=15).read())
        title = root.findtext("a:title", "", _NS)
        rows = []
        for e in root.findall("a:entry", _NS):
            vid = e.findtext("yt:videoId", "", _NS)
            if not vid:
                continue
            link = (e.find("a:link", _NS).get("href") if e.find("a:link", _NS) is not None else "")
            stats = e.find("media:group/media:community/media:statistics", _NS)
            n = int(stats.get("views", 0)) if stats is not None else 0
            rows.append({
                "videoId": vid, "kind": "video",
                "uri": f"https://www.youtube.com/watch?v={vid}",
                "title": e.findtext("a:title", "", _NS) or "(untitled)",
                "artUrl": f"https://i.ytimg.com/vi/{vid}/mqdefault.jpg",
                "channel": title, "channelUrl": "https://www.youtube.com/channel/" + cid,
                "ts": _iso_ts(e.findtext("a:published", "", _NS)),
                "isShort": "/shorts/" in link, "views": n, "durationS": 0.0})
        self._rss[cid] = (time.time(), rows, title)
        return rows, title

    def _lengths(self, cid):
        """{videoId: seconds} for a channel's recent uploads, from its Videos
        tab (the public feed carries no lengths). Cached 30 minutes."""
        hit = self._lens.get(cid)
        if hit and time.time() - hit[0] < 1800:
            return hit[1]
        out = {}
        try:
            d = self.yt.innertube("browse", {"browseId": cid, "params": _VIDEOS_TAB},
                                  need_auth=False)
            for lv in self.yt.find_all(d, "lockupViewModel"):
                r = self.yt._video_lockup_item(lv)
                if r and r.get("durationS"):
                    out[r["videoId"]] = r["durationS"]
        except Exception:
            pass
        self._lens[cid] = (time.time(), out)
        return out

    def _finish(self, rows):
        """Lengths for the rows about to be shown, then each row's line."""
        cids = {channel_id_of(r.get("channelUrl", "")) for r in rows if not r.get("durationS")
                and not r.get("isShort")}
        lens = {}
        for got in self._pool.map(self._lengths, [c for c in cids if c]):
            lens.update(got)
        out = []
        for r in rows:
            r = dict(r)
            if not r.get("durationS"):
                r["durationS"] = float(lens.get(r["videoId"], 0))
            if r.get("ts"):
                r["published"] = ago(r["ts"])
            if not r.get("subtitle"):
                r["subtitle"] = " · ".join(x for x in (
                    r.get("channel", ""), self.yt.fmt_dur(r["durationS"]),
                    views(r["views"]) if r.get("views") else "") if x)
            r.pop("views", None)
            out.append(r)
        return out

    def subs_page(self, start, n=40, fresh=False):
        with self._lock:
            subs = list(self._read()["subs"])
            hidden = set(self._read()["hidden"])
        if not subs:
            return [], False, ("NO CHANNELS FOLLOWED YET — HOLD ⏎ ON A VIDEO ▸ SUBSCRIBE, "
                               "OR IMPORT AN ACCOUNT'S IN SETTINGS")
        pool = []

        def one(s):
            try:
                return self._feed(s["id"], fresh)[0]
            except Exception:
                return []
        for rows in self._feeds.map(one, subs):
            pool += rows
        pool = [r for r in pool if r["videoId"] not in hidden]
        pool.sort(key=lambda r: -r.get("ts", 0))
        return self._finish(pool[start:start + n]), len(pool) > start + n, ""

    # ── FOR YOU ─────────────────────────────────────────────────────────────
    def related(self, video_id):
        """YouTube's suggestions beside a video (its watch page's column),
        cached an hour."""
        hit = self._related.get(video_id)
        if hit and time.time() - hit[0] < 3600:
            return hit[1]
        rows = []
        try:
            d = self.yt.innertube("next", {"videoId": video_id}, need_auth=False)
            for lv in self.yt.find_all(d, "lockupViewModel"):
                r = self.yt._video_lockup_item(lv)
                if r:
                    rows.append(r)
        except Exception:
            pass
        self._related[video_id] = (time.time(), rows)
        if len(self._related) > 300:
            self._related.pop(next(iter(self._related)))
        return rows

    def rec_page(self, start, n=40, fresh=False):
        with self._lock:
            d = self._read()
            hist = [h.get("videoId") for h in d["history"] if h.get("videoId")]
            subs = list(d["subs"])
            hidden = set(d["hidden"])
        if fresh or not self._rec or time.time() - self._rec[0] > 1200:
            # The newest watches lead; two older ones keep it from narrowing
            # to whatever was watched last.
            seeds = hist[:6] + random.sample(hist[6:80], min(2, max(0, len(hist[6:80]))))
            lists = list(self._pool.map(self.related, seeds))
            new = []
            for rows in self._feeds.map(lambda s: self._safe_feed(s["id"]), subs[:300]):
                new += [r for r in rows[:2] if not r.get("isShort")
                        and time.time() - r.get("ts", 0) < 14 * 86400]
            new.sort(key=lambda r: -r.get("ts", 0))
            lists.append(new[:30])
            seen = set(hist) | hidden
            pool, i = [], 0
            while any(i < len(l) for l in lists):     # one from each, in turn
                for l in lists:
                    if i < len(l):
                        r = l[i]
                        if r["videoId"] not in seen and not r.get("isShort"):
                            seen.add(r["videoId"])
                            pool.append(r)
                i += 1
            self._rec = (time.time(), pool)
        pool = self._rec[1]
        if not pool:
            return [], False, "FOR YOU FILLS IN AS YOU WATCH — SEARCH FOR SOMETHING TO START"
        return self._finish(pool[start:start + n]), len(pool) > start + n, ""

    def _safe_feed(self, cid):
        try:
            return self._feed(cid)[0]
        except Exception:
            return []

    # ── the lists ───────────────────────────────────────────────────────────
    def list_page(self, name, start, n=40):
        notes = {"watchlater": "NOTHING SAVED FOR LATER — HOLD ⏎ ON A VIDEO ▸ ADD TO WATCH LATER",
                 "history": "NOTHING WATCHED YET",
                 "playlists": "NO PLAYLISTS YET — HOLD ⏎ ON A VIDEO ▸ ADD TO PLAYLIST ▸ NEW PLAYLIST"}
        with self._lock:
            d = self._read()
            if name == "playlists":
                rows = [self._playlist_row(p) for p in d["playlists"]]
                if d["liked"]:
                    rows.insert(0, self._playlist_row({"id": LIKED_ID, "title": "Liked videos",
                                                       "rows": d["liked"]}))
            else:
                rows = [dict(r) for r in d[name]]
        for r in rows:
            if r.get("watchedAt") and name == "history":
                r["published"] = "watched " + ago(r["watchedAt"])
        return rows[start:start + n], len(rows) > start + n, ("" if rows else notes.get(name, ""))

    @staticmethod
    def _playlist_row(p):
        first = p["rows"][0] if p["rows"] else {}
        count = len(p["rows"])
        return {"uri": "codec:playlist:" + p["id"], "title": p["title"], "kind": "playlist",
                "subtitle": f"PLAYLIST · {count} video{'s' if count != 1 else ''}",
                "artUrl": first.get("artUrl", ""), "durationS": 0.0, "videoId": "",
                "channelUrl": "", "published": "", "isLive": False}

    def playlist_page(self, pid, start, n=40):
        with self._lock:
            d = self._read()
            if pid == LIKED_ID:
                rows = d["liked"]
                return [dict(r) for r in rows[start:start + n]], len(rows) > start + n, "Liked videos"
            p = next((p for p in d["playlists"] if p["id"] == pid), None)
        if not p:
            raise RuntimeError("that playlist is gone")
        return [dict(r) for r in p["rows"][start:start + n]], len(p["rows"]) > start + n, p["title"]

    def playlist_count(self, pid):
        with self._lock:
            d = self._read()
            if pid == LIKED_ID:
                return len(d["liked"])
            p = next((p for p in d["playlists"] if p["id"] == pid), None)
            return len(p["rows"]) if p else 0

    def playlists_flat(self):
        with self._lock:
            return [{"title": p["title"], "id": p["id"]} for p in self._read()["playlists"]]

    # ── writes ──────────────────────────────────────────────────────────────
    def _put(self, lst, row, cap=None):
        lst[:] = [r for r in lst if r.get("videoId") != row["videoId"]]
        lst.insert(0, row)
        if cap:
            del lst[cap:]

    def wl_add(self, item):
        with self._lock:
            self._put(self._read()["watchlater"], self._row(item))
            self._write()

    def wl_remove(self, video_id):
        with self._lock:
            d = self._read()
            d["watchlater"] = [r for r in d["watchlater"] if r.get("videoId") != video_id]
            self._write()

    def pl_create(self, title, item=None):
        pid = "cpl" + secrets.token_hex(5)
        with self._lock:
            self._read()["playlists"].insert(0, {
                "id": pid, "title": (title or "").strip() or "NEW PLAYLIST",
                "rows": [self._row(item)] if item else [], "created": int(time.time())})
            self._write()
        return pid

    def pl_add(self, pid, item):
        with self._lock:
            p = next((p for p in self._read()["playlists"] if p["id"] == pid), None)
            if not p:
                raise RuntimeError("that playlist is gone")
            row = self._row(item)
            if not any(r.get("videoId") == row["videoId"] for r in p["rows"]):
                p["rows"].append(row)        # a playlist plays in the order built
            self._write()
            return p["title"]

    def pl_remove(self, pid, video_id):
        with self._lock:
            p = next((p for p in self._read()["playlists"] if p["id"] == pid), None)
            if p:
                p["rows"] = [r for r in p["rows"] if r.get("videoId") != video_id]
                self._write()

    def pl_delete(self, pid):
        with self._lock:
            d = self._read()
            d["playlists"] = [p for p in d["playlists"] if p["id"] != pid]
            self._write()

    def history_add(self, item):
        row = self._row(item)
        if not row.get("videoId"):
            return
        row["watchedAt"] = int(time.time())
        with self._lock:
            self._put(self._read()["history"], row, _HISTORY_CAP)
            self._write()
        if self._rec:                       # FOR YOU drops what was just watched
            self._rec = (self._rec[0], [r for r in self._rec[1] if r["videoId"] != row["videoId"]])

    def history_remove(self, video_id):
        with self._lock:
            d = self._read()
            d["history"] = [r for r in d["history"] if r.get("videoId") != video_id]
            self._write()

    def rating(self, video_id):
        """"like", "dislike" or "" — what LIKE / DISLIKE last said of it."""
        with self._lock:
            d = self._read()
            if any(r.get("videoId") == video_id for r in d["liked"]):
                return "like"
            return "dislike" if video_id in d["disliked"] else ""

    def rate(self, item, status):
        """LIKE / DISLIKE / neither: a liked video joins Liked videos."""
        row = self._row(item)
        vid = row.get("videoId")
        if not vid:
            return
        with self._lock:
            d = self._read()
            d["liked"] = [r for r in d["liked"] if r.get("videoId") != vid]
            d["disliked"] = [v for v in d["disliked"] if v != vid]
            if status == "like":
                d["liked"].insert(0, row)
            elif status == "dislike":
                d["disliked"].append(vid)
                del d["disliked"][:-5000]
            self._write()

    def hide(self, video_id):
        """NOT INTERESTED: never suggest it again."""
        with self._lock:
            d = self._read()
            if video_id not in d["hidden"]:
                d["hidden"].append(video_id)
                del d["hidden"][:-5000]
                self._write()
        if self._rec:
            self._rec = (self._rec[0], [r for r in self._rec[1] if r["videoId"] != video_id])

    # ── import ──────────────────────────────────────────────────────────────
    def import_from(self, cookiefile, progress=None):
        """Copy a signed-in account's subscriptions, playlists and Watch Later
        into codec's own lists (nothing on the account changes). Returns
        {following, playlists, watchlater} — what was added."""
        from yt_dlp import YoutubeDL

        def flat(url, limit):
            ydl = YoutubeDL({"quiet": True, "no_warnings": True, "skip_download": True,
                             "extract_flat": "in_playlist", "socket_timeout": 20,
                             "playlist_items": f"1-{limit}", "cookiefile": str(cookiefile)})
            return list((ydl.extract_info(url, download=False) or {}).get("entries") or [])

        say = progress or (lambda m: None)
        added = {"following": 0, "playlists": 0, "watchlater": 0}
        say("READING SUBSCRIPTIONS…")
        chans = flat("https://www.youtube.com/feed/channels", 5000)
        say("READING WATCH LATER…")
        wl = [self._row(self.yt.norm(e)) for e in flat(":ytwatchlater", 2000)]
        say("READING PLAYLISTS…")
        wanted = []
        for e in flat("https://www.youtube.com/feed/playlists", 500):
            u = e.get("url") or ""
            pid = u.split("list=", 1)[1].split("&", 1)[0] if "list=" in u else ""
            if pid and pid not in ("WL", "LL"):
                wanted.append((e.get("title") or pid, u))

        def one(w):
            rows = [self._row(self.yt.norm(v)) for v in flat(w[1], 2000) if v.get("id")]
            return w[0], [r for r in rows if r.get("videoId")]
        with ThreadPoolExecutor(max_workers=6) as ex:
            lists = list(ex.map(one, wanted))
        with self._lock:
            d = self._read()
            have = {s["id"] for s in d["subs"]}
            for c in chans:
                cid = c.get("channel_id") or c.get("id") or ""
                if cid.startswith("UC") and cid not in have:
                    have.add(cid)
                    d["subs"].append({"id": cid, "title": c.get("title") or cid,
                                      "url": "https://www.youtube.com/channel/" + cid,
                                      "added": int(time.time())})
                    added["following"] += 1
            have = {r.get("videoId") for r in d["watchlater"]}
            for r in wl:
                if r.get("videoId") and r["videoId"] not in have:
                    have.add(r["videoId"])
                    d["watchlater"].append(r)
                    added["watchlater"] += 1
            titles = {p["title"] for p in d["playlists"]}
            for title, rows in lists:
                if title in titles:
                    continue
                d["playlists"].append({"id": "cpl" + secrets.token_hex(5), "title": title,
                                       "rows": rows, "created": int(time.time())})
                added["playlists"] += 1
            self._write()
        self._rec = None
        return added

    # ── a Google Takeout ────────────────────────────────────────────────────
    @staticmethod
    def find_takeout():
        """The newest Google Takeout here — takeout-*.zip, or an unpacked
        Takeout folder — in Downloads or the home folder; None if there's none."""
        home = Path.home()
        found = []
        for d in (home / "Downloads", home):
            if not d.is_dir():
                continue
            found += [p for p in d.glob("takeout*.zip")] + [p for p in d.glob("Takeout") if p.is_dir()]
        return max(found, key=lambda p: p.stat().st_mtime) if found else None

    def import_takeout(self, path=None, progress=None):
        """Subscriptions and playlists (Watch later among them) from a Google
        Takeout of YouTube: a .zip or its unpacked folder. Takeout lists only
        video ids, so each video's title and length are looked up (16 at once).
        Returns {following, playlists, watchlater}."""
        say = progress or (lambda m: None)
        src = Path(path) if path else self.find_takeout()
        if not src or not src.exists():
            raise RuntimeError("no Google Takeout found in Downloads — get one at "
                               "takeout.google.com (YouTube only)")
        files = {}                         # path inside -> text
        if src.is_dir():
            for f in src.rglob("*.csv"):
                files[str(f.relative_to(src))] = f.read_text(encoding="utf-8-sig", errors="replace")
        else:
            with zipfile.ZipFile(src) as z:
                for n in z.namelist():
                    if n.lower().endswith(".csv"):
                        files[n] = z.read(n).decode("utf-8-sig", errors="replace")
        chans, lists = [], []              # [(id, title)], [(title, [video ids])]
        vid_re = re.compile(r"[\w-]{11}")
        for name, text in files.items():
            low = name.replace("\\", "/").lower()
            rows = list(csv.reader(io.StringIO(text)))
            if low.endswith("subscriptions.csv"):
                for r in rows:
                    if r and re.fullmatch(r"UC[\w-]{22}", r[0].strip()):
                        chans.append((r[0].strip(), (r[2] if len(r) > 2 else "").strip()))
            elif "/playlists/" in low and not low.endswith("/playlists.csv"):
                title = re.sub(r"(?i)-videos?\.csv$|\.csv$", "", name.replace("\\", "/").rsplit("/", 1)[-1])
                ids = [r[0].strip() for r in rows if r and vid_re.fullmatch(r[0].strip())]
                if ids:
                    lists.append((title, ids))
        if not chans and not lists:
            raise RuntimeError(f"no YouTube subscriptions or playlists in {src.name}")
        need = sorted({v for _, ids in lists for v in ids})
        say(f"LOOKING UP {len(need)} VIDEOS…")

        def look(v):
            try:
                return v, self.video_row(v)
            except Exception:
                return v, None
        rows = dict(self._pool.map(look, need))
        added = {"following": 0, "playlists": 0, "watchlater": 0}
        with self._lock:
            d = self._read()
            have = {x["id"] for x in d["subs"]}
            for cid, title in chans:
                if cid not in have:
                    have.add(cid)
                    d["subs"].append({"id": cid, "title": title or cid,
                                      "url": "https://www.youtube.com/channel/" + cid,
                                      "added": int(time.time())})
                    added["following"] += 1
            titles = {p["title"] for p in d["playlists"]}
            for title, ids in lists:
                got = [rows[v] for v in ids if rows.get(v)]
                if title.lower() in ("watch later", "watch-later"):
                    have_wl = {r.get("videoId") for r in d["watchlater"]}
                    for r in got:
                        if r["videoId"] not in have_wl:
                            have_wl.add(r["videoId"])
                            d["watchlater"].append(r)
                            added["watchlater"] += 1
                elif title not in titles and got:
                    titles.add(title)
                    d["playlists"].append({"id": "cpl" + secrets.token_hex(5), "title": title,
                                           "rows": got, "created": int(time.time())})
                    added["playlists"] += 1
            self._write()
        self._rec = None
        return added
