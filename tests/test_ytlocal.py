#!/usr/bin/env python3
"""codec's own YouTube lists (codec_ytlocal.py), offline.

The store, the writes, the feeds built from followed channels and from what
was watched — with YouTube's pages stood in for, and the row parsers the
worker shares (codec_yt.py) read against a real lockup card's shape.

    python3 tests/test_ytlocal.py
"""
import os, pathlib, sys, tempfile, time, types

HOME = pathlib.Path(tempfile.mkdtemp(prefix="ytlocal-"))
os.environ["HOME"] = str(HOME)
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "scripts"))
import codec_ytlocal as L
import codec_yt as Y

fails = 0


def check(name, got, want):
    global fails
    ok = got == want
    fails += 0 if ok else 1
    print(f"  {'ok ' if ok else 'FAIL'} {name}: {got!r}" + ("" if ok else f" (want {want!r})"))


def row(vid, title=None, ch="Chan", cid="UCaaaaaaaaaaaaaaaaaaaaaa", ts=0.0, short=False):
    return {"videoId": vid, "title": title or vid, "kind": "video", "channel": ch,
            "channelUrl": "https://www.youtube.com/channel/" + cid, "ts": ts,
            "isShort": short, "durationS": 0.0, "views": 1200}


# a stand-in for codec_yt: nothing reaches YouTube
calls = []
stub = types.SimpleNamespace(
    fmt_dur=Y.fmt_dur, find_all=Y.find_all, _video_lockup_item=Y._video_lockup_item,
    norm=Y.norm,
    innertube=lambda ep, body, need_auth=False: (calls.append((ep, body)) or
                                                 {"endpoint": {"browseEndpoint": {"browseId": "UC" + "r" * 22}}}))
loc = L.Local(stub)

print("words")
now = 1_800_000_000
check("ago days", L.ago(now - 3 * 86400, now), "3 days ago")
check("ago one hour", L.ago(now - 3700, now), "1 hour ago")
check("ago just now", L.ago(now - 5, now), "just now")
check("views M", L.views(9_393_005), "9.4M views")
check("views K big", L.views(60_123), "60K views")
check("views one", L.views(1), "1 view")
check("long ago", Y._long_ago("5h ago"), "5 hours ago")
check("long ago kept", Y._long_ago("3 weeks ago"), "3 weeks ago")

print("following")
cid1, cid2 = "UC" + "a" * 22, "UC" + "b" * 22
got = loc.subscribe("https://www.youtube.com/channel/" + cid1, "Alpha")
check("subscribe by link, no lookup", (got["id"], calls), (cid1, []))
loc.subscribe(cid2, "Beta")
loc.subscribe("https://www.youtube.com/@gamma", "Gamma")
check("a handle is looked up", calls[-1][0], "navigation/resolve_url")
loc.subscribe(cid1, "Alpha again")
check("no duplicates", [s["title"] for s in loc.following()], ["Gamma", "Beta", "Alpha"])
loc.unsubscribe(cid2)
check("unsubscribe", [s["id"] for s in loc.following()], ["UC" + "r" * 22, cid1])

print("lists")
loc.wl_add(row("v1", "One"))
loc.wl_add(row("v2", "Two"))
loc.wl_add(row("v1", "One"))
rows, more, note = loc.list_page("watchlater", 0)
check("watch later newest first, no repeats", [r["videoId"] for r in rows], ["v1", "v2"])
check("a stored row is a watch link", rows[0]["uri"], "https://www.youtube.com/watch?v=v1")
loc.wl_remove("v2")
check("removed", [r["videoId"] for r in loc.list_page("watchlater", 0)[0]], ["v1"])
pid = loc.pl_create("  LECTURES ", row("v3"))
loc.pl_add(pid, row("v4"))
loc.pl_add(pid, row("v3"))
prow = loc.list_page("playlists", 0)[0][0]
check("playlist row", (prow["title"], prow["kind"], prow["uri"], prow["subtitle"]),
      ("LECTURES", "playlist", "codec:playlist:" + pid, "PLAYLIST · 2 videos"))
check("playlist plays in the order built", [r["videoId"] for r in loc.playlist_page(pid, 0)[0]], ["v3", "v4"])
loc.pl_remove(pid, "v3")
check("removed from playlist", [r["videoId"] for r in loc.playlist_page(pid, 0)[0]], ["v4"])
check("flat list for the picker", loc.playlists_flat(), [{"title": "LECTURES", "id": pid}])
check("empty history says so", loc.list_page("history", 0)[2], "NOTHING WATCHED YET")
for v in ("h1", "h2", "h1"):
    loc.history_add(row(v))
check("history newest first", [r["videoId"] for r in loc.list_page("history", 0)[0]], ["h1", "h2"])
check("history marks when", loc.list_page("history", 0)[0][0]["published"], "watched just now")
check("live-ness isn't stored", "isLive" in L.Local._row(dict(row("z"), isLive=True)), False)

print("LIKE and DISLIKE")
check("unrated", loc.rating("v1"), "")
loc.rate(row("v1", "One"), "like")
loc.rate(row("v5", "Five"), "like")
check("liked", loc.rating("v1"), "like")
first = loc.list_page("playlists", 0)[0][0]
check("Liked videos leads PLAYLISTS", (first["title"], first["uri"], first["subtitle"]),
      ("Liked videos", "codec:playlist:" + L.LIKED_ID, "PLAYLIST · 2 videos"))
check("newest like first", [r["videoId"] for r in loc.playlist_page(L.LIKED_ID, 0)[0]], ["v5", "v1"])
check("its count", loc.playlist_count(L.LIKED_ID), 2)
loc.rate(row("v1", "One"), "dislike")
check("a dislike takes the like back", (loc.rating("v1"), loc.playlist_count(L.LIKED_ID)), ("dislike", 1))
loc.rate(row("v1", "One"), "")
loc.rate(row("v5", "Five"), "")
check("neither", (loc.rating("v1"), loc.rating("v5")), ("", ""))
check("no likes, no Liked videos", [r["title"] for r in loc.list_page("playlists", 0)[0]], ["LECTURES"])
check("a playlist's count", loc.playlist_count(pid), 1)

print("the store")
loc2 = L.Local(stub)
check("another process reads the same lists", loc2.snapshot(),
      {"following": 2, "watchlater": 1, "playlists": 1, "history": 2})

print("SUBS")
t = time.time()
feeds = {"UC" + "r" * 22: [row("s1", ts=t - 100, cid="UC" + "r" * 22, ch="Gamma"),
                           row("s2", ts=t - 9000, cid="UC" + "r" * 22, ch="Gamma", short=True)],
         cid1: [row("s3", ts=t - 50, cid=cid1, ch="Alpha")]}
loc._feed = lambda cid, fresh=False: (feeds.get(cid, []), "")
loc._lengths = lambda cid: {"s1": 754.0, "s3": 61.0}
rows, more, note = loc.subs_page(0)
check("newest first across channels", [r["videoId"] for r in rows], ["s3", "s1", "s2"])
check("lengths filled from the channel page", rows[0]["subtitle"], "Alpha · 1:01 · 1.2K views")
check("a short keeps its tag, no length", (rows[2]["isShort"], rows[2]["durationS"]), (True, 0.0))
loc.hide("s1")
check("NOT INTERESTED leaves the feed", [r["videoId"] for r in loc.subs_page(0)[0]], ["s3", "s2"])

print("FOR YOU")
loc.related = lambda vid: {"h1": [row("r1"), row("h2"), row("r2")],
                           "h2": [row("r3"), row("r1"), row("r4", short=True)]}.get(vid, [])
rows, more, note = loc.rec_page(0, fresh=True)
ids = [r["videoId"] for r in rows]
check("suggestions take turns, seen and repeats dropped", ids[:3], ["r1", "r3", "s3"])
check("watched, hidden and shorts never suggested", any(v in ids for v in ("h1", "h2", "s1", "r4")), False)
loc.history_add(row("r1"))
check("watching drops it at once", "r1" in [r["videoId"] for r in loc.rec_page(0)[0]], False)
empty = L.Local(stub)
empty._read()["history"].clear()
empty._read()["subs"].clear()
check("nothing to go on says so", empty.rec_page(0, fresh=True)[2][:12], "FOR YOU FILL")

print("a lockup card")
lv = {"contentId": "zYGPZs7ovsA", "contentType": "LOCKUP_CONTENT_TYPE_VIDEO",
      "contentImage": {"thumbnailViewModel": {"overlays": [{"thumbnailBottomOverlayViewModel": {
          "badges": [{"thumbnailBadgeViewModel": {"text": "4:58"}}]}}]}},
      "metadata": {"lockupMetadataViewModel": {
          "title": {"content": "Batman vs Superman"},
          "image": {"decoratedAvatarViewModel": {"rendererContext": {"commandContext": {"onTap": {
              "innertubeCommand": {"browseEndpoint": {"browseId": "UCx",
                                                      "canonicalBaseUrl": "/@FlashbackFM"}}}}}}},
          "metadata": {"contentMetadataViewModel": {"metadataRows": [
              {"metadataParts": [{"text": {"content": "Flashback FM"}}]},
              {"metadataParts": [{"text": {"content": "10M"}}, {"text": {"content": "9y ago"}}]}]}}}}}
r = Y._video_lockup_item(lv)
check("lockup → row", (r["videoId"], r["title"], r["durationS"], r["channelUrl"], r["published"]),
      ("zYGPZs7ovsA", "Batman vs Superman", 298.0, "https://www.youtube.com/@FlashbackFM", "9 years ago"))
check("lockup line", r["subtitle"], "Flashback FM · 4:58 · 10M views")
check("a playlist lockup isn't a video", Y._video_lockup_item(dict(lv, contentType="LOCKUP_CONTENT_TYPE_PLAYLIST")), None)

print("a Google Takeout")
import zipfile
tk = HOME / "Downloads"
tk.mkdir()
base = "Takeout/YouTube and YouTube Music/"
with zipfile.ZipFile(tk / "takeout-20261017T000000Z-001.zip", "w") as z:
    z.writestr(base + "subscriptions/subscriptions.csv",
               "\ufeffChannel Id,Channel Url,Channel Title\n"
               "UC" + "t" * 22 + ",http://www.youtube.com/channel/UC" + "t" * 22 + ",Tee\n"
               + cid1 + ",http://www.youtube.com/channel/" + cid1 + ",Alpha\n")
    z.writestr(base + "playlists/playlists.csv", "Playlist Id,Playlist Title (Original)\nPLx,Lectures\n")
    z.writestr(base + "playlists/Lectures-videos.csv",
               "Video Id,Playlist Video Creation Timestamp\nAAAAAAAAAAA,2024-01-01T00:00:00+00:00\n"
               "BBBBBBBBBBB,2024-01-02T00:00:00+00:00\n")
    # the older layout: a header block, a blank line, then the videos
    z.writestr(base + "playlists/Watch later.csv",
               "Playlist Id,Channel Id,Time Created\nWL,UCz,2020\n\nVideo Id,Time Added\nCCCCCCCCCCC,2021\n")
check("finds the newest in Downloads", loc.find_takeout().name, "takeout-20261017T000000Z-001.zip")
loc.video_row = lambda v: L.Local._row({"videoId": v, "title": "T-" + v, "kind": "video"})
before = loc.snapshot()
added = loc.import_takeout()
check("takeout: what it added", added, {"following": 1, "playlists": 1, "watchlater": 1})
lec = [p for p in loc._read()["playlists"] if p["title"] == "Lectures"][0]
check("its playlist, titled and in order", [r["title"] for r in lec["rows"]], ["T-AAAAAAAAAAA", "T-BBBBBBBBBBB"])
check("watch later joins codec's", "CCCCCCCCCCC" in [r["videoId"] for r in loc._read()["watchlater"]], True)
check("again adds nothing", loc.import_takeout(), {"following": 0, "playlists": 0, "watchlater": 0})

print("FAIL" if fails else "all ok")
sys.exit(1 if fails else 0)
