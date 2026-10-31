#!/usr/bin/env python3
"""codec_ytpage — a YouTube video's own page, as codec shows it.

What youtube.com's watch page shows beside the player, read from InnerTube
(`next` for the page, `player` for the full description and length) and
Return YouTube Dislike (the dislike count YouTube stopped showing):

  video(yt, vid)        the page: channel (picture, subscribers, followed),
                        views, date, likes + dislikes, the viewer's rating,
                        description, chapters, the most-replayed curve,
                        RELATED, and where its COMMENTS start
  comments(yt, token)   a page of comments (or a thread's replies) and the
                        token for the next
  related(yt, token)    the next page of RELATED

`yt` is codec_yt (its signed innertube() and the shared row parsers). The
parsers below take plain dicts, so tests feed them by hand.
"""
import json
import re
import urllib.request
from concurrent.futures import ThreadPoolExecutor

_POOL = ThreadPoolExecutor(max_workers=6)


def _txt(t):
    if not isinstance(t, dict):
        return ""
    return t.get("simpleText") or "".join(r.get("text", "") for r in t.get("runs") or [])


def _first(o, key):
    """The first value stored under `key` anywhere in `o` (depth first)."""
    stack = [o]
    while stack:
        x = stack.pop()
        if isinstance(x, dict):
            if key in x:
                return x[key]
            stack.extend(reversed(list(x.values())))
        elif isinstance(x, list):
            stack.extend(reversed(x))
    return None


def _thumb(thumbs):
    """The largest of a thumbnails list, as an https URL."""
    t = (thumbs or {}).get("thumbnails") if isinstance(thumbs, dict) else thumbs
    if not t:
        return ""
    u = t[-1].get("url", "")
    return "https:" + u if u.startswith("//") else u


def _count(text):
    """'19,488,193' / '1.2K' / '4.55M' -> int (0 when there's no number)."""
    m = re.search(r"([\d.,]+)\s*([KMB])?", text or "")
    if not m:
        return 0
    n = m.group(1).replace(",", "")
    try:
        v = float(n)
    except ValueError:
        return 0
    return int(v * {"K": 1e3, "M": 1e6, "B": 1e9}.get(m.group(2) or "", 1))


def _token(o):
    """A continuation's token, from the continuationItemRenderer in `o`."""
    c = _first(o, "continuationCommand")
    return (c or {}).get("token", "")


# ── the page ────────────────────────────────────────────────────────────────
def parse_next(d, lockup):
    """The watch page's own facts from an InnerTube `next` reply. `lockup`
    turns a related video's card into a row (codec_yt._video_lockup_item)."""
    out = {}
    results = (((d.get("contents") or {}).get("twoColumnWatchNextResults") or {})
               .get("results") or {}).get("results", {}).get("contents") or []
    pi = next((c["videoPrimaryInfoRenderer"] for c in results if "videoPrimaryInfoRenderer" in c), {})
    si = next((c["videoSecondaryInfoRenderer"] for c in results if "videoSecondaryInfoRenderer" in c), {})

    out["title"] = _txt(pi.get("title"))
    vc = ((pi.get("viewCount") or {}).get("videoViewCountRenderer") or {})
    out["viewsText"] = _txt(vc.get("viewCount"))
    out["views"] = int(vc.get("originalViewCount") or 0) or _count(out["viewsText"])
    out["isLive"] = bool(vc.get("isLive"))
    out["date"] = _txt(pi.get("dateText"))
    out["ago"] = _txt(pi.get("relativeDateText"))

    # likes: the like button's title ("19M") and its spoken count
    like = _first(pi, "likeButtonViewModel") or {}
    bvm = _first(like, "defaultButtonViewModel") or {}
    bvm = (bvm.get("buttonViewModel") or {})
    out["likesText"] = bvm.get("title") or ""
    m = re.search(r"along with ([\d,]+)", bvm.get("accessibilityText") or "")
    out["likes"] = int(m.group(1).replace(",", "")) + 1 if m else _count(out["likesText"])
    status = (_first(like, "likeStatusEntity") or {}).get("likeStatus") or "INDIFFERENT"
    out["rating"] = {"LIKE": "like", "DISLIKE": "dislike"}.get(status, "")

    # the channel
    owner = ((si.get("owner") or {}).get("videoOwnerRenderer") or {})
    out["channel"] = _txt(owner.get("title"))
    out["avatar"] = _thumb(owner.get("thumbnail"))
    out["subscribers"] = _txt(owner.get("subscriberCountText"))
    be = ((owner.get("navigationEndpoint") or {}).get("browseEndpoint") or {})
    out["channelId"] = be.get("browseId", "")
    base = be.get("canonicalBaseUrl") or ("/channel/" + out["channelId"] if out["channelId"] else "")
    out["channelUrl"] = "https://www.youtube.com" + base if base else ""
    out["verified"] = any(
        "VERIFIED" in ((b.get("metadataBadgeRenderer") or {}).get("style") or "")
        for b in owner.get("badges") or [])
    sub = ((si.get("subscribeButton") or {}).get("subscribeButtonRenderer") or {})
    out["subscribed"] = bool(sub.get("subscribed"))
    out["description"] = ((si.get("attributedDescription") or {}).get("content") or "")

    # chapters: the creator's own, else YouTube's automatic ones
    out["chapters"] = []
    markers = _first(d.get("playerOverlays") or {}, "markersMap") or []
    for want in ("DESCRIPTION_CHAPTERS", "AUTO_CHAPTERS"):
        for mk in markers:
            if mk.get("key") != want:
                continue
            for c in (mk.get("value") or {}).get("chapters") or []:
                cr = c.get("chapterRenderer") or {}
                out["chapters"].append({
                    "title": _txt(cr.get("title")),
                    "time": int(cr.get("timeRangeStartMillis") or 0) / 1000.0,
                    "thumb": _thumb(cr.get("thumbnail"))})
        if out["chapters"]:
            out["autoChapters"] = want == "AUTO_CHAPTERS"
            break

    # the most-replayed curve (0..1 per slice of the video)
    out["heat"] = []
    for mu in (((d.get("frameworkUpdates") or {}).get("entityBatchUpdate") or {})
               .get("mutations") or []):
        ml = ((mu.get("payload") or {}).get("macroMarkersListEntity") or {}).get("markersList") or {}
        if ml.get("markerType") == "MARKER_TYPE_HEATMAP":
            out["heat"] = [round(float(x.get("intensityScoreNormalized") or 0), 3)
                           for x in ml.get("markers") or []]

    # RELATED — the column beside the player
    sec = ((((d.get("contents") or {}).get("twoColumnWatchNextResults") or {})
            .get("secondaryResults") or {}).get("secondaryResults") or {})
    out["related"] = [r for r in (lockup(lv) for lv in _all(sec, "lockupViewModel")) if r]
    out["relatedToken"] = _token(_all(sec, "continuationItemRenderer")[-1:])

    # COMMENTS — where they start, how many, and the sort orders
    out["commentsCount"] = ""
    out["commentsToken"] = ""
    out["commentsNewest"] = ""
    for e in d.get("engagementPanels") or []:
        r = e.get("engagementPanelSectionListRenderer") or {}
        if r.get("panelIdentifier") != "engagement-panel-comments-section":
            continue
        h = ((r.get("header") or {}).get("engagementPanelTitleHeaderRenderer") or {})
        out["commentsCount"] = _txt(h.get("contextualInfo"))
        for it in (_first(h, "subMenuItems") or []):
            tok = ((it.get("serviceEndpoint") or {}).get("continuationCommand") or {}).get("token", "")
            if it.get("title", "").lower().startswith("top"):
                out["commentsToken"] = tok
            elif it.get("title", "").lower().startswith("new"):
                out["commentsNewest"] = tok
    if not out["commentsToken"]:
        for c in results:
            isr = c.get("itemSectionRenderer") or {}
            if isr.get("sectionIdentifier") == "comment-item-section":
                out["commentsToken"] = _token(isr)
    return out


def _all(o, key):
    out, stack = [], [o]
    while stack:
        x = stack.pop()
        if isinstance(x, dict):
            if key in x:
                out.append(x[key])
            stack.extend(reversed(list(x.values())))
        elif isinstance(x, list):
            stack.extend(reversed(x))
    return out


def parse_player(p):
    """The player reply's full description (the page's is cut short) and
    the video's length."""
    vd = p.get("videoDetails") or {}
    return {"fullDescription": vd.get("shortDescription") or "",
            "durationS": float(vd.get("lengthSeconds") or 0),
            "isLiveNow": bool(vd.get("isLive")),
            "keywords": vd.get("keywords") or []}


def ryd(vid, timeout=4):
    """{likes, dislikes} from Return YouTube Dislike (an estimate, from its
    users' votes and YouTube's old public counts), or {} when it's away."""
    try:
        req = urllib.request.Request(
            "https://returnyoutubedislikeapi.com/votes?videoId=" + vid,
            headers={"User-Agent": "codec media player"})
        r = json.loads(urllib.request.urlopen(req, timeout=timeout).read())
        return {"dislikes": int(r.get("dislikes") or 0), "rydLikes": int(r.get("likes") or 0)}
    except Exception:
        return {}


def video(yt, vid):
    """The whole page for one video. The page, the full description and the
    dislike count are fetched at once (~1 s, the page's own read)."""
    f_next = _POOL.submit(yt.innertube, "next", {"videoId": vid}, False)
    f_player = _POOL.submit(yt.innertube, "player", {"videoId": vid}, False)
    f_ryd = _POOL.submit(ryd, vid)
    page = parse_next(f_next.result(timeout=25), yt._video_lockup_item)
    page["videoId"] = vid
    try:
        pl = parse_player(f_player.result(timeout=25))
        if pl["fullDescription"]:
            page["description"] = pl["fullDescription"]
        page["durationS"] = pl["durationS"]
        page["isLive"] = page["isLive"] or pl["isLiveNow"]
    except Exception:
        page.setdefault("durationS", 0.0)
    page.update(f_ryd.result(timeout=10))
    page.setdefault("dislikes", -1)
    return page


# ── comments ────────────────────────────────────────────────────────────────
def parse_comments(d):
    """A page of comments (or replies) from a `next` continuation reply:
    {comments: [...], next: token, count: "106"}."""
    ents, toolbars, surfaces = {}, {}, {}
    for mu in (((d.get("frameworkUpdates") or {}).get("entityBatchUpdate") or {})
               .get("mutations") or []):
        p = mu.get("payload") or {}
        if "commentEntityPayload" in p:
            ents[mu.get("entityKey") or p["commentEntityPayload"].get("key")] = p["commentEntityPayload"]
        elif "engagementToolbarStateEntityPayload" in p:
            toolbars[mu.get("entityKey")] = p["engagementToolbarStateEntityPayload"]
        elif "engagementToolbarSurfaceEntityPayload" in p:
            surfaces[mu.get("entityKey")] = p["engagementToolbarSurfaceEntityPayload"]
    items, count, create = [], "", ""
    for ep in d.get("onResponseReceivedEndpoints") or []:
        act = ep.get("reloadContinuationItemsCommand") or ep.get("appendContinuationItemsAction") or {}
        for it in act.get("continuationItems") or []:
            if "commentsHeaderRenderer" in it:
                h = it["commentsHeaderRenderer"]
                count = _txt(h.get("countText")).replace(" Comments", "")
                # where a new comment goes (the header's own comment box)
                create = (_first(h.get("createRenderer") or {}, "createCommentParams") or "")
            else:
                items.append(it)
    out, nxt = [], ""
    for it in items:
        if "continuationItemRenderer" in it:
            nxt = _token(it)
            continue
        thread = it.get("commentThreadRenderer")
        vm = (thread or {}).get("commentViewModel") or it.get("commentViewModel") or {}
        vm = vm.get("commentViewModel") or vm
        e = ents.get(vm.get("commentKey"))
        if not e:
            continue
        pr, au, tb = e.get("properties") or {}, e.get("author") or {}, e.get("toolbar") or {}
        state = toolbars.get(pr.get("toolbarStateKey")) or {}
        surface = surfaces.get(vm.get("toolbarSurfaceKey")) or {}
        replies_tok = ""
        if thread:
            replies_tok = _token((thread.get("replies") or {}).get("commentRepliesRenderer") or {})
        out.append({
            "id": pr.get("commentId", ""),
            "author": au.get("displayName", ""),
            "avatar": au.get("avatarThumbnailUrl", ""),
            "channelId": au.get("channelId", ""),
            "creator": bool(au.get("isCreator")),
            "verified": bool(au.get("isVerified")),
            "text": (pr.get("content") or {}).get("content", ""),
            "published": pr.get("publishedTime", ""),
            "likes": tb.get("likeCountNotliked") or "",
            "replies": _count(tb.get("replyCount") or "0"),
            "repliesToken": replies_tok,
            "hearted": state.get("heartState") == "TOOLBAR_HEART_STATE_HEARTED",
            "pinned": bool(vm.get("pinnedText")),
            "reply": int(pr.get("replyLevel") or 0) > 0,
            # the account's own hand on it: reply, like / unlike
            "replyParams": _first(surface.get("replyCommand") or {}, "createReplyParams") or "",
            "likeAction": ((_first(surface.get("likeCommand") or {}, "performCommentActionEndpoint") or {})
                           .get("action", "")),
            "unlikeAction": ((_first(surface.get("unlikeCommand") or {}, "performCommentActionEndpoint") or {})
                             .get("action", "")),
            "liked": state.get("likeState") == "TOOLBAR_LIKE_STATE_LIKED",
        })
    return {"comments": out, "next": nxt, "count": count, "createParams": create}


def post(yt, text, params, reply=False):
    """A comment, or a reply to one, posted as the account (its channel —
    the page id rides on every signed call). Returns YouTube's id for it."""
    if reply:
        r = yt.innertube("comment/create_comment_reply", {"commentText": text, "createReplyParams": params})
    else:
        r = yt.innertube("comment/create_comment", {"commentText": text, "createCommentParams": params})
    cid = _first(r, "commentId") or ""
    if not cid and not _first(r, "createCommentAction") and not _first(r, "createCommentReplyAction"):
        raise RuntimeError("youtube didn't take the comment")
    return cid


def like_comment(yt, action):
    """LIKE (or UNLIKE) a comment: its toolbar's own perform-action token."""
    yt.innertube("comment/perform_comment_action", {"actions": [action]})


def comments(yt, token):
    return parse_comments(yt.innertube("next", {"continuation": token}, False))


def related(yt, token):
    """The next page of RELATED: {rows, next}."""
    d = yt.innertube("next", {"continuation": token}, False)
    items = []
    for ep in d.get("onResponseReceivedEndpoints") or []:
        act = ep.get("appendContinuationItemsAction") or ep.get("reloadContinuationItemsCommand") or {}
        items += act.get("continuationItems") or []
    rows = [r for r in (yt._video_lockup_item(lv) for lv in _all(items, "lockupViewModel")) if r]
    return {"rows": rows, "next": _token(_all(items, "continuationItemRenderer")[-1:])}
