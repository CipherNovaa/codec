#!/usr/bin/env python3
"""A YouTube video's own page (codec_ytpage.py) and the listing header
(codec_yt.listing_header), offline.

YouTube's replies are stood in for by hand-made ones in their real shapes
(InnerTube `next`, its comments continuation, yt-dlp's read of a channel and
a playlist), so the parsers are checked without the network.

    python3 tests/test_ytpage.py
"""
import os, pathlib, sys, tempfile

HOME = pathlib.Path(tempfile.mkdtemp(prefix="ytpage-"))
os.environ["HOME"] = str(HOME)
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "scripts"))
import codec_ytpage as P
import codec_yt as Y

fails = 0


def check(name, got, want):
    global fails
    ok = got == want
    fails += 0 if ok else 1
    print(f"  {'ok ' if ok else 'FAIL'} {name}: {got!r}" + ("" if ok else f" (want {want!r})"))


def runs(t):
    return {"runs": [{"text": t}]}


def lockup(vid, title):
    return {"lockupViewModel": {
        "contentId": vid, "contentType": "LOCKUP_CONTENT_TYPE_VIDEO",
        "metadata": {"lockupMetadataViewModel": {
            "title": {"content": title},
            "metadata": {"contentMetadataViewModel": {"metadataRows": [
                {"metadataParts": [{"text": {"content": "A Channel"}}]},
                {"metadataParts": [{"text": {"content": "1.2K views"}}, {"text": {"content": "2 days ago"}}]}]}}}}}}


def cont(token):
    return {"continuationItemRenderer": {"continuationEndpoint": {"continuationCommand": {"token": token}}}}


NEXT = {
    "contents": {"twoColumnWatchNextResults": {
        "results": {"results": {"contents": [
            {"videoPrimaryInfoRenderer": {
                "title": runs("A Lecture"),
                "viewCount": {"videoViewCountRenderer": {"viewCount": {"simpleText": "59,722 views"},
                                                         "originalViewCount": "59722"}},
                "dateText": {"simpleText": "Feb 9, 2022"},
                "relativeDateText": {"simpleText": "4 years ago"},
                "videoActions": {"menuRenderer": {"topLevelButtons": [{"segmentedLikeDislikeButtonViewModel": {
                    "likeButtonViewModel": {"likeButtonViewModel": {
                        "toggleButtonViewModel": {"toggleButtonViewModel": {"defaultButtonViewModel": {
                            "buttonViewModel": {"title": "1.6K",
                                                "accessibilityText": "like this video along with 1,684 other people"}}}},
                        "likeStatusEntity": {"likeStatus": "LIKE"}}}}}]}}}},
            {"videoSecondaryInfoRenderer": {
                "owner": {"videoOwnerRenderer": {
                    "title": runs("Open Math Camp"),
                    "thumbnail": {"thumbnails": [{"url": "//yt3.ggpht.com/a=s48"}, {"url": "//yt3.ggpht.com/a=s176"}]},
                    "subscriberCountText": {"simpleText": "4.18K subscribers"},
                    "navigationEndpoint": {"browseEndpoint": {"browseId": "UC" + "m" * 22,
                                                              "canonicalBaseUrl": "/@openMathCamp"}},
                    "badges": [{"metadataBadgeRenderer": {"style": "BADGE_STYLE_TYPE_VERIFIED"}}]}},
                "subscribeButton": {"subscribeButtonRenderer": {"subscribed": True}},
                "attributedDescription": {"content": "Short text"}}},
            {"itemSectionRenderer": {"sectionIdentifier": "comment-item-section",
                                     "contents": [cont("TOP-FALLBACK")]}}]}},
        "secondaryResults": {"secondaryResults": {"results": [
            {"itemSectionRenderer": {"contents": [lockup("r1aaaaaaaaa", "Related one"),
                                                  lockup("r2aaaaaaaaa", "Related two"),
                                                  cont("RELATED-MORE")]}}]}}}},
    "playerOverlays": {"playerOverlayRenderer": {"decoratedPlayerBarRenderer": {"decoratedPlayerBarRenderer": {
        "playerBar": {"multiMarkersPlayerBarRenderer": {"markersMap": [
            {"key": "AUTO_CHAPTERS", "value": {"chapters": [
                {"chapterRenderer": {"title": {"simpleText": "Auto"}, "timeRangeStartMillis": 0}}]}},
            {"key": "DESCRIPTION_CHAPTERS", "value": {"chapters": [
                {"chapterRenderer": {"title": {"simpleText": "Introduction"}, "timeRangeStartMillis": 0,
                                     "thumbnail": {"thumbnails": [{"url": "https://i.ytimg.com/c0.jpg"}]}}},
                {"chapterRenderer": {"title": {"simpleText": "Natural numbers"},
                                     "timeRangeStartMillis": 75000}}]}}]}}}}}},
    "engagementPanels": [{"engagementPanelSectionListRenderer": {
        "panelIdentifier": "engagement-panel-comments-section",
        "header": {"engagementPanelTitleHeaderRenderer": {
            "contextualInfo": runs("106"),
            "menu": {"sortFilterSubMenuRenderer": {"subMenuItems": [
                {"title": "Top", "serviceEndpoint": {"continuationCommand": {"token": "TOP"}}},
                {"title": "Newest", "serviceEndpoint": {"continuationCommand": {"token": "NEW"}}}]}}}}}}],
    "frameworkUpdates": {"entityBatchUpdate": {"mutations": [{"payload": {"macroMarkersListEntity": {
        "markersList": {"markerType": "MARKER_TYPE_HEATMAP", "markers": [
            {"intensityScoreNormalized": 0.1}, {"intensityScoreNormalized": 1.0}]}}}}]}},
}

print("the page")
pg = P.parse_next(NEXT, Y._video_lockup_item)
check("title, views, dates", (pg["title"], pg["views"], pg["date"], pg["ago"]),
      ("A Lecture", 59722, "Feb 9, 2022", "4 years ago"))
check("likes, from the spoken count", (pg["likes"], pg["likesText"]), (1685, "1.6K"))
check("the viewer's rating", pg["rating"], "like")
check("the channel", (pg["channel"], pg["channelId"], pg["channelUrl"], pg["verified"]),
      ("Open Math Camp", "UC" + "m" * 22, "https://www.youtube.com/@openMathCamp", True))
check("its picture, whole and https", pg["avatar"], "https://yt3.ggpht.com/a=s176")
check("followers and followed", (pg["subscribers"], pg["subscribed"]), ("4.18K subscribers", True))
check("the creator's chapters win over YouTube's",
      [(c["title"], c["time"]) for c in pg["chapters"]], [("Introduction", 0.0), ("Natural numbers", 75.0)])
check("…and say so", pg["autoChapters"], False)
check("most replayed", pg["heat"], [0.1, 1.0])
check("related, and where more start", ([r["videoId"] for r in pg["related"]], pg["relatedToken"]),
      (["r1aaaaaaaaa", "r2aaaaaaaaa"], "RELATED-MORE"))
check("comments: count and both orders", (pg["commentsCount"], pg["commentsToken"], pg["commentsNewest"]),
      ("106", "TOP", "NEW"))
bare = P.parse_next({"contents": NEXT["contents"]}, Y._video_lockup_item)
check("no sort menu: the section's own token", bare["commentsToken"], "TOP-FALLBACK")
check("the player's full description", P.parse_player({"videoDetails": {
    "shortDescription": "All of it", "lengthSeconds": "18806"}})["durationS"], 18806.0)

print("comments")


def thread(key, replies_token=None):
    t = {"commentViewModel": {"commentViewModel": {"commentKey": key, "toolbarSurfaceKey": "s-" + key}}}
    if replies_token:
        t["replies"] = {"commentRepliesRenderer": {"contents": [cont(replies_token)]}}
    return {"commentThreadRenderer": t}


def entity(key, author, text, likes="3", replies="0", creator=False, toolbar_key=None):
    return {"entityKey": key, "payload": {"commentEntityPayload": {
        "key": key,
        "properties": {"commentId": "c-" + key, "content": {"content": text},
                       "publishedTime": "5 months ago", "replyLevel": 0,
                       "toolbarStateKey": toolbar_key or ""},
        "author": {"displayName": author, "avatarThumbnailUrl": "https://yt3.ggpht.com/" + key,
                   "isCreator": creator, "channelId": "UC" + key},
        "toolbar": {"likeCountNotliked": likes, "replyCount": replies}}}}


COMMENTS = {
    "onResponseReceivedEndpoints": [
        {"reloadContinuationItemsCommand": {"continuationItems": [
            {"commentsHeaderRenderer": {"countText": {"runs": [{"text": "106"}, {"text": " Comments"}]},
                                        "createRenderer": {"commentSimpleboxRenderer": {"submitButton": {
                                            "buttonRenderer": {"serviceEndpoint": {"createCommentEndpoint": {
                                                "createCommentParams": "NEW-COMMENT"}}}}}}}}]}},
        {"reloadContinuationItemsCommand": {"continuationItems": [
            thread("k1", "REPLIES-1"), thread("k2"), thread("k-missing"), cont("PAGE-2")]}}],
    "frameworkUpdates": {"entityBatchUpdate": {"mutations": [
        entity("k1", "@XanDerPH", "Thank you 2:31", likes="46", replies="2", toolbar_key="t1"),
        entity("k2", "@openMathCamp", "Pinned by me", creator=True),
        {"entityKey": "t1", "payload": {"engagementToolbarStateEntityPayload": {
            "heartState": "TOOLBAR_HEART_STATE_HEARTED", "likeState": "TOOLBAR_LIKE_STATE_LIKED"}}},
        {"entityKey": "s-k1", "payload": {"engagementToolbarSurfaceEntityPayload": {
            "likeCommand": {"innertubeCommand": {"performCommentActionEndpoint": {"action": "LIKE-k1"}}},
            "unlikeCommand": {"innertubeCommand": {"performCommentActionEndpoint": {"action": "UNLIKE-k1"}}},
            "replyCommand": {"innertubeCommand": {"createCommentReplyDialogEndpoint": {"dialog": {
                "commentReplyDialogRenderer": {"replyButton": {"buttonRenderer": {"serviceEndpoint": {
                    "createCommentReplyEndpoint": {"createReplyParams": "REPLY-k1"}}}}}}}}}}}}]}},
}
cm = P.parse_comments(COMMENTS)
check("the count", cm["count"], "106")
check("every comment with its words", [(c["author"], c["text"]) for c in cm["comments"]],
      [("@XanDerPH", "Thank you 2:31"), ("@openMathCamp", "Pinned by me")])
check("likes, replies and where they are", (cm["comments"][0]["likes"], cm["comments"][0]["replies"],
                                             cm["comments"][0]["repliesToken"]), ("46", 2, "REPLIES-1"))
check("the creator's heart", cm["comments"][0]["hearted"], True)
check("the creator", cm["comments"][1]["creator"], True)
check("the next page", cm["next"], "PAGE-2")
check("where a new comment goes", cm["createParams"], "NEW-COMMENT")
c1 = cm["comments"][0]
check("a reply's params, like and unlike", (c1["replyParams"], c1["likeAction"], c1["unlikeAction"]),
      ("REPLY-k1", "LIKE-k1", "UNLIKE-k1"))
check("liked by the account", (c1["liked"], cm["comments"][1]["liked"]), (True, False))
check("counts", (P._count("19,488,193"), P._count("1.2K"), P._count("4.55M"), P._count("")),
      (19488193, 1200, 4550000, 0))

print("a listing's header")
ch = Y.listing_header({"channel": "Open Math Camp", "channel_id": "UC" + "m" * 22,
                       "uploader_id": "@openMathCamp", "channel_follower_count": 4180,
                       "thumbnails": [{"id": "0", "url": "B1", "width": 1060, "height": 175},
                                      {"id": "5", "url": "B5", "width": 2560, "height": 424},
                                      {"id": "7", "url": "A900", "width": 900, "height": 900},
                                      {"id": "avatar_uncropped", "url": "AU"}]},
                      "https://www.youtube.com/@openMathCamp/videos")
check("a channel", (ch["kind"], ch["title"], ch["handle"], ch["followers"], ch["url"]),
      ("channel", "Open Math Camp", "@openMathCamp", 4180, "https://www.youtube.com/channel/UC" + "m" * 22))
check("its picture and widest banner", (ch["avatar"], ch["banner"]), ("AU", "B5"))
pl = Y.listing_header({"title": "testlist", "playlist_count": 1, "channel": "A Channel"},
                      "https://www.youtube.com/playlist?list=PLabc")
check("a playlist", (pl["kind"], pl["title"], pl["count"], pl["owner"], pl["id"]),
      ("playlist", "testlist", 1, "A Channel", "PLabc"))

print("rows")
ch_row = Y.norm({"url": "https://www.youtube.com/channel/UCx", "id": "UCx", "title": "ashens",
                 "channel": "ashens", "uploader_id": "@ashens", "channel_follower_count": 1670000,
                 "thumbnails": [{"url": "//yt3.googleusercontent.com/av=s176"}]})
check("a channel row: its handle and followers", ch_row["subtitle"], "@ashens · 1.7M subscribers")
check("its picture, https", ch_row["artUrl"], "https://yt3.googleusercontent.com/av=s176")
pl_row = Y.norm({"url": "https://www.youtube.com/playlist?list=WL", "id": "WL", "title": "Watch later",
                 "channel": "View full playlist"})
check("yt-dlp's link text isn't a playlist's line", pl_row["subtitle"], "")

print("FAIL" if fails else "all ok")
sys.exit(1 if fails else 0)
