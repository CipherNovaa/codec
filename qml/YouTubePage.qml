import QtQuick

// A YouTube video's own page — `i` on a video, hold-⏎ ▸ VIDEO PAGE, or a
// click on the big still: what youtube.com's watch page shows, on codec's
// plates. Laid out as YouTube lays it out: on the LEFT the picture, its
// title, the channel (picture, subscribers, SUBSCRIBE), views and date,
// likes against the dislikes YouTube hides (Return YouTube Dislike), the
// action plates and the description; on the RIGHT, the full height,
// CHAPTERS · COMMENTS · RELATED (codec_ytpage.py reads them all).
//
// The page opens on PLAY (so i then ⏎ plays). ←/→ walk the plates and,
// past the last one, cross to the sections on the right (and back past the
// first section); ↑/↓ go down the column you're in — the plates, the
// description; the section tabs, their rows. A related video opens its own
// page on top; esc walks back down the pages, then out.
FocusScope {
    id: pg
    property var yt                       // the YouTubeView: its menu, rows, links
    readonly property bool onCrt: App.mode === "crt"
    readonly property int platePx: 2
    readonly property int rowH: 78

    // ── what's open ──────────────────────────────────────────────────────
    property var stack: []                // rows opened, the shown one last
    readonly property bool open: stack.length > 0
    readonly property var item: open ? stack[stack.length - 1] : ({})
    readonly property string vid: item.videoId || ""
    visible: open
    property var page: ({})               // the worker's page (empty while it loads)
    property bool loading: false
    property string error: ""
    // each page's parts, so walking back down the stack is instant
    property var cache: ({})

    property var comments: []
    property string commentsNext: ""
    property string commentsSort: "top"   // top | newest
    property bool commentsLoading: false
    property string commentsWant: ""      // the token asked for (replies race)
    // a comment's replies, while open: {parent, rows, next, want}
    property var thread: null
    property int threadFrom: 0
    property string commentsCreate: ""   // where a new comment goes (createParams)
    property var related: []
    property string relatedNext: ""
    property bool relatedLoading: false

    // ── the walk ─────────────────────────────────────────────────────────
    // left column: actions · desc;  right column: tabs · body
    property string zone: "actions"
    property int act: 0
    // the section shown on the right; kept from page to page (a lecture's
    // CHAPTERS, then its related, stay where you left them)
    property string section: "related"
    readonly property var sections: {
        let s = []
        if ((page.chapters || []).length > 0) s.push("chapters")
        s.push("comments", "related")
        return s
    }
    readonly property string shownSection: sections.indexOf(section) >= 0 ? section : "related"
    readonly property var bodyRows: shownSection === "chapters" ? (page.chapters || [])
                                  : shownSection === "comments" ? commentRows
                                  : related
    // COMMENTS opens on a card to write one (a thread: under the comment it
    // answers); comments off, or not read yet: no card
    readonly property bool canComment: YouTube.account.mode === "account"
                                       && YouTube.account.state === "connected"
    readonly property var commentRows: {
        if (thread) {
            const card = { kind: "compose", reply: true, parent: thread.parent }
            return thread.parent.replyParams || !canComment
                ? [thread.rows[0], card].concat(thread.rows.slice(1)) : thread.rows
        }
        if (!page.commentsToken || (comments.length === 0 && commentsLoading)) return comments
        return [{ kind: "compose", reply: false }].concat(comments)
    }
    // The list's model holds only places in bodyRows: a page of comments or
    // related arriving APPENDS rows (a JS array as the model rebuilt the list
    // and dropped the selection back to the top). A new section, thread,
    // order or video starts it over.
    ListModel { id: bodyModel }
    readonly property string bodyKey: vid + "/" + shownSection + "/" + commentsSort + "/"
                                      + (thread ? thread.parent.id : "")
    onBodyKeyChanged: syncBody(true)
    onBodyRowsChanged: syncBody(false)
    function syncBody(reset) {
        if (reset || bodyModel.count > bodyRows.length) bodyModel.clear()
        while (bodyModel.count < bodyRows.length) bodyModel.append({ i: bodyModel.count })
    }

    function sectionLabel(s) {
        if (s === "chapters") return "CHAPTERS // " + (page.chapters || []).length
        if (s === "comments") return page.commentsCount ? "COMMENTS // " + page.commentsCount : "COMMENTS"
        return s.toUpperCase()
    }

    // ── facts the plates read ────────────────────────────────────────────
    property int followRev: 0
    Connections { target: YouTube; function onFollowingChanged() { pg.followRev++ } }
    readonly property string channelUrl: page.channelId
        ? "https://www.youtube.com/channel/" + page.channelId : (item.channelUrl || "")
    readonly property string channelName: page.channel || (yt ? yt.channelName(item) : "")
    readonly property bool subscribed: (followRev, channelUrl.length > 0
                                        && YouTube.isFollowing(channelUrl))
    readonly property string rating: page.rating || ""
    readonly property bool playingThis: vid.length > 0 && !Engine.idle
                                        && Engine.path.indexOf(vid) >= 0
    property int storeRev: 0
    Connections { target: Store; enabled: pg.open; function onUpdated() { pg.storeRev++ } }
    readonly property string playWord: playingThis ? "PLAYING"
        : (storeRev, Store.resumePct(item.uri || "")) > 0.01 ? "RESUME" : "PLAY"
    readonly property string descText: page.description || ""

    // The row to play, queue, save or rate: what the list knew, with what the
    // page learned (codec's own lists keep it whole).
    function rowItem() {
        let r = Object.assign({}, item)
        r.kind = "video"
        r.sourceId = "youtube"
        r.uri = "https://www.youtube.com/watch?v=" + vid
        if (page.title) r.title = page.title
        if (page.channel) r.channel = page.channel
        if (channelUrl) r.channelUrl = channelUrl
        if (page.durationS > 0) r.durationS = page.durationS
        if (!r.artUrl) r.artUrl = "https://i.ytimg.com/vi/" + vid + "/mqdefault.jpg"
        if (!r.subtitle && page.channel) r.subtitle = page.channel
        return r
    }

    function fmtTime(s) {
        s = Math.max(0, Math.floor(s))
        const h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60), sec = s % 60
        const mm = h > 0 && m < 10 ? "0" + m : "" + m
        return (h > 0 ? h + ":" : "") + mm + ":" + (sec < 10 ? "0" : "") + sec
    }
    function fmtCount(n) {
        if (n >= 1e9) return (n / 1e9).toFixed(n < 1e10 ? 1 : 0).replace(/\.0$/, "") + "B"
        if (n >= 1e6) return (n / 1e6).toFixed(n < 1e7 ? 1 : 0).replace(/\.0$/, "") + "M"
        if (n >= 1e3) return (n / 1e3).toFixed(n < 1e4 ? 1 : 0).replace(/\.0$/, "") + "K"
        return "" + n
    }

    // ── opening and leaving ──────────────────────────────────────────────
    function openItem(it) {
        if (!it || !it.videoId) return
        if (open && it.videoId === vid) return
        if (open) remember()
        stack = stack.concat([it])
        show()
        forceActiveFocus()
    }
    // the shown page's parts, kept for the walk back
    function remember() {
        if (!open) return
        let c = Object.assign({}, cache)
        c[vid] = { page: page, comments: comments, commentsNext: commentsNext,
                   commentsSort: commentsSort, commentsCreate: commentsCreate,
                   related: related, relatedNext: relatedNext }
        cache = c
    }
    function show() {
        const c = cache[vid]
        thread = null
        composing = null
        composeText.focus = false
        commentsCreate = ""
        zone = "actions"
        act = 0
        error = ""
        commentsLoading = false
        commentsWant = ""
        relatedLoading = false
        if (c && c.page && c.page.title) {
            page = c.page
            comments = c.comments; commentsNext = c.commentsNext; commentsSort = c.commentsSort
            commentsCreate = c.commentsCreate || ""
            related = c.related; relatedNext = c.relatedNext
            loading = false
        } else {
            page = ({}); comments = []; commentsNext = ""; commentsSort = "top"
            related = []; relatedNext = ""
            loading = true
            YouTube.fetchPage(vid)
        }
        bodyList.currentIndex = 0
        topDesc()
        fanIn.restart()
    }
    function close() {
        remember()
        stack = []
        if (yt) yt.takeFocus()
    }
    function back() {
        Sfx.play("back")
        if (thread) {                       // a comment's replies: back to the comments
            thread = null
            bodyList.currentIndex = threadFrom
            return
        }
        if (stack.length > 1) {
            remember()
            stack = stack.slice(0, -1)
            show()
            return
        }
        close()
    }
    function reload() {
        Sfx.play("select")
        let c = Object.assign({}, cache)
        delete c[vid]
        cache = c
        show()
    }

    Connections {
        target: YouTube
        enabled: pg.open
        // a click on a tab up in the strip leaves the page
        function onTabChanged() { pg.close() }
        function onPageReply(kind, data) { pg.onReply(kind, data) }
    }

    function onReply(kind, d) {
        if (kind === "video") {
            if (d.ok === false) {
                if (!loading) return
                loading = false
                error = d.error || "couldn't read the page"
                return
            }
            if (d.videoId !== vid) return
            loading = false
            page = d
            related = d.related || []
            relatedNext = d.relatedToken || ""
            // the first comments come along now — the tab reads its count and
            // opens on them at once
            if (d.commentsToken) loadComments(d.commentsToken)
        } else if (kind === "comments") {
            if (!d.token || d.token !== commentsWant) return
            commentsLoading = false
            commentsWant = ""
            if (d.ok === false) return
            const rows = d.comments || []
            if (thread && thread.want === d.token) {
                thread = { parent: thread.parent, rows: thread.rows.concat(rows),
                           next: d.next || "", want: "" }
            } else if (!thread) {
                comments = comments.concat(rows)
                commentsNext = d.next || ""
            }
            if (d.createParams) commentsCreate = d.createParams
        } else if (kind === "related") {
            if (d.videoId !== vid) return
            relatedLoading = false
            if (d.ok === false) return
            const seen = {}
            for (const r of related) seen[r.videoId] = true
            related = related.concat((d.rows || []).filter(r => !seen[r.videoId]))
            relatedNext = d.next || ""
        } else if (kind === "comment") {
            posting = false
            if (d.ok === false) {
                App.notify("YOUTUBE · " + String(d.error || "the comment didn't go").toUpperCase())
                return
            }
            App.notify(d.reply ? "REPLY POSTED" : "COMMENT POSTED")
            composing = null
            composeText.text = ""
            composeText.focus = false
            forceActiveFocus()
            if (d.videoId !== vid) return
            if (d.reply && thread && thread.parent.id === d.parentId)
                thread = Object.assign({}, thread, { rows: [thread.rows[0], d.comment].concat(thread.rows.slice(1)) })
            else if (!d.reply)
                comments = [d.comment].concat(comments)
        } else if (kind === "comment_like" && d.ok === false) {
            App.notify("YOUTUBE · " + String(d.error || "that didn't take").toUpperCase())
        } else if (kind === "rated" && d.ok === false) {
            App.notify("YOUTUBE · " + String(d.error || "that didn't take").toUpperCase())
            if (d.videoId === vid || !d.videoId) reload()
        }
    }

    function loadComments(token) {
        if (!token || commentsLoading) return
        commentsLoading = true
        commentsWant = token
        YouTube.fetchComments(vid, token)
    }
    // the rows' end is near: the next page of what's shown
    function moreBody() {
        if (shownSection === "comments") {
            if (thread) {
                if (thread.next && !commentsLoading) {
                    thread = Object.assign({}, thread, { want: thread.next })
                    loadComments(thread.next)
                }
            } else loadComments(commentsNext)
        } else if (shownSection === "related" && relatedNext && !relatedLoading) {
            relatedLoading = true
            YouTube.fetchRelated(vid, relatedNext)
        }
    }
    function sortComments(how) {
        if (how === commentsSort) return
        const tok = how === "newest" ? page.commentsNewest : page.commentsToken
        if (!tok) { Sfx.play("bump"); return }
        Sfx.play("select")
        commentsSort = how
        thread = null
        comments = []
        commentsNext = ""
        commentsLoading = false
        loadComments(tok)
        bodyList.currentIndex = 0
    }
    function openThread(c) {
        if (!c || !c.repliesToken) { Sfx.play("bump"); return }
        Sfx.play("open")
        threadFrom = bodyList.currentIndex
        // the comment itself heads its replies, as YouTube shows a thread
        thread = { parent: c, rows: [c], next: "", want: c.repliesToken }
        commentsLoading = false
        loadComments(c.repliesToken)
        bodyList.currentIndex = 0
    }

    // ── what the plates do ───────────────────────────────────────────────
    // PLAY on a plate; SUBSCRIBE as YouTube's red pill (SUBSCRIBED back on a
    // plate); the rest are pixel icon buttons with their count or word —
    // LIKE ▲ and DISLIKE ▼ stay pressed in once set (YtAction)
    readonly property var actions: {
        let a = [{ key: "play", kind: "plate", label: "▶  " + playWord }]
        if (channelUrl.length > 0)
            a.push(subscribed ? { key: "sub", kind: "plate", label: "SUBSCRIBED", on: true }
                              : { key: "sub", kind: "pill", label: "SUBSCRIBE" })
        a.push({ key: "like", kind: "icon", icon: "up", on: rating === "like",
                 label: page.likes > 0 ? fmtCount(page.likes) : "LIKE" })
        a.push({ key: "dislike", kind: "icon", icon: "down", on: rating === "dislike",
                 label: page.dislikes !== undefined && page.dislikes >= 0 ? fmtCount(page.dislikes) : "DISLIKE" })
        a.push({ key: "save", kind: "icon", icon: "plus", label: "SAVE" })
        a.push({ key: "more", kind: "icon", icon: "menu", label: "MORE" })
        return a
    }
    function doAction(key) {
        switch (key) {
        case "play": play(); break
        case "sub":
            Sfx.play("select")
            if (subscribed) YouTube.unsubscribe(channelUrl, channelName)
            else YouTube.subscribe(channelUrl, channelName)
            break
        case "like": rate(rating === "like" ? "" : "like"); break
        case "dislike": rate(rating === "dislike" ? "" : "dislike"); break
        case "save": Sfx.play("open"); yt.openSave(rowItem()); break
        case "more": yt.openContextFor(rowItem(), true); break
        }
    }
    function openChannel() {
        if (channelUrl.length === 0) { Sfx.play("bump"); return }
        Sfx.play("open")
        const url = item.channelUrl || channelUrl
        close()
        YouTube.openUrl(url)
    }
    function play() {
        Sfx.play("select")
        if (playingThis) App.toPlayer()
        else App.playItem(rowItem())
    }
    function playAt(secs) {
        Sfx.play("select")
        if (playingThis) { App.seekTo(secs); App.toPlayer() }
        else App.playItem(Object.assign(rowItem(), { uri: "https://www.youtube.com/watch?v=" + vid
                                                           + "&t=" + Math.floor(secs) + "s" }))
    }
    // LIKE / DISLIKE / neither — shown at once, put back if YouTube says no
    function rate(status) {
        Sfx.play("select")
        let p = Object.assign({}, page)
        if (p.rating === "like") p.likes = Math.max(0, (p.likes || 0) - 1)
        if (p.rating === "dislike" && p.dislikes > 0) p.dislikes--
        if (status === "like") p.likes = (p.likes || 0) + 1
        if (status === "dislike" && p.dislikes >= 0) p.dislikes++
        p.rating = status
        page = p
        YouTube.rate(rowItem(), status)
        App.notify((status === "like" ? "LIKED · " : status === "dislike" ? "DISLIKED · "
                    : "RATING REMOVED · ") + String(p.title || item.title || "").toUpperCase())
    }

    // A link in the description or a comment: a timestamp plays this video
    // from there, another YouTube video opens its page, the rest go where
    // the list's links go (yt.followLink).
    function followLink(link) {
        const href = link.replace(/&quot;/g, '"').replace(/&lt;/g, "<")
                         .replace(/&gt;/g, ">").replace(/&amp;/g, "&")
        if (href.indexOf("ts:") === 0) {
            let secs = 0
            for (const n of href.slice(3).split(":").map(Number)) secs = secs * 60 + n
            playAt(secs)
            return
        }
        const m = /(?:[?&]v=|youtu\.be\/|\/shorts\/|\/live\/)([\w-]{11})/.exec(href)
        if (yt.isYouTubeUrl(href) && m && !/[?&]list=/.test(href)) {
            Sfx.play("open")
            openItem({ videoId: m[1], title: "", kind: "video",
                       uri: "https://www.youtube.com/watch?v=" + m[1] })
            return
        }
        Sfx.play("select")
        if (yt.isYouTubeUrl(href)) close()
        yt.followLink(link)
    }

    // ── keys ─────────────────────────────────────────────────────────────
    Timer { id: holdTimer; interval: 480; onTriggered: pg.holdBody() }
    function holdBody() {
        const r = bodyRows[bodyList.currentIndex]
        if (shownSection === "related" && r) yt.openContextFor(r, false)
        else if (shownSection === "comments" && r && r.kind !== "compose") yt.openCommentMenu(r)
        else Sfx.play("bump")
    }

    // ── writing ──────────────────────────────────────────────────────────
    // composing: {reply, parent} while the composer is up
    property var composing: null
    property bool posting: false
    function startCompose(card) {
        if (!canComment) {
            Sfx.play("open")
            close()
            App.openSection("settings:youtube")
            return
        }
        const params = card.reply ? (card.parent.replyParams || "") : commentsCreate
        if (!params) { Sfx.play("bump"); App.notify("YOUTUBE ISN'T TAKING COMMENTS HERE"); return }
        Sfx.play("open")
        composing = { reply: card.reply === true, parent: card.parent || null, params: params }
        composeText.forceActiveFocus()
    }
    function postCompose() {
        const text = composeText.text.trim()
        if (!composing || text.length === 0 || posting) { Sfx.play("bump"); return }
        Sfx.play("select")
        posting = true
        YouTube.postComment(vid, text, composing.params, composing.reply,
                            composing.parent ? composing.parent.id : "")
    }
    function cancelCompose() {
        Sfx.play("back")
        composing = null
        composeText.focus = false        // a hidden field must not keep the keys
        forceActiveFocus()
    }
    // the comment menu's picks (YouTubeView.openCommentMenu)
    function commentAct(act, c) {
        if (act === "like" || act === "unlike") {
            const like = act === "like"
            const token = like ? c.likeAction : c.unlikeAction
            if (!token) { Sfx.play("bump"); return }
            Sfx.play("select")
            // shown at once (the count is YouTube's text — a number moves by one)
            const n = parseInt(c.likes || "0")
            const upd = Object.assign({}, c, { liked: like,
                likes: isNaN(n) || /[KM]/.test(c.likes || "") ? c.likes : String(Math.max(0, n + (like ? 1 : -1))) })
            if (thread) thread = Object.assign({}, thread, { rows: thread.rows.map(x => x.id === c.id ? upd : x) })
            comments = comments.map(x => x.id === c.id ? upd : x)
            YouTube.likeComment(vid, c.id, token, like)
        } else if (act === "reply") {
            if (!thread || thread.parent.id !== c.id) {
                if (c.repliesToken) openThread(c)
                else thread = { parent: c, rows: [c], next: "", want: "" }
            }
            startCompose({ reply: true, parent: c })
        } else if (act === "replies") {
            openThread(c)
        } else if (act === "copy") {
            App.copyText(c.text || "")
            App.notify("COPIED")
        }
    }
    function goRight() {                  // into the sections column
        zone = bodyRows.length > 0 ? "body" : "tabs"
        if (bodyList.currentIndex < 0 || bodyList.currentIndex >= bodyRows.length)
            bodyList.currentIndex = 0
        Sfx.play("move")
    }
    function goLeft() {                   // back to the plates
        zone = "actions"
        act = actions.length - 1
        Sfx.play("move")
    }
    function stepSection(dir) {
        const i = sections.indexOf(shownSection)
        const n = i + dir
        if (n < 0) { goLeft(); return }
        if (n >= sections.length) { Sfx.play("bump"); return }
        Sfx.play("move")
        section = sections[n]
        thread = null
        bodyList.currentIndex = 0
        if (zone === "body" && bodyRows.length === 0) zone = "tabs"
        bodyList.fanIn()
    }
    function actBody() {
        const r = bodyRows[bodyList.currentIndex]
        if (!r) { Sfx.play("bump"); return }
        if (shownSection === "chapters") playAt(r.time)
        else if (shownSection === "comments") {
            if (r.kind === "compose") startCompose(r)
            else if (thread) Sfx.play("bump")
            else openThread(r)
        }
        else { Sfx.play("open"); openItem(r) }
    }
    function scrollDesc(lines) {
        const max = Math.max(0, descFlick.contentHeight - descFlick.height)
        const to = Math.max(0, Math.min(max, descFlick.target + lines * descLine))
        if (to === descFlick.target) return false
        descFlick.target = to
        descFlick.contentY = to
        return true
    }
    function topDesc() { descFlick.target = 0; descFlick.contentY = 0 }
    function pageBody(dir) {
        if (zone === "desc") {
            Sfx.play(scrollDesc(dir * Math.max(1, Math.floor(descFlick.height / descLine) - 1)) ? "move" : "bump")
            return
        }
        if (zone !== "body") { Sfx.play("bump"); return }
        const was = bodyList.currentIndex
        const per = Math.max(1, Math.floor(bodyList.height / (bodyList.currentItem
                                                              ? bodyList.currentItem.height : rowH)))
        bodyList.currentIndex = Math.max(0, Math.min(bodyRows.length - 1, was + dir * per))
        Sfx.play(bodyList.currentIndex === was ? "bump" : "move")
    }

    Keys.onReleased: (event) => {
        if (event.isAutoRepeat) return
        if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && holdTimer.running) {
            holdTimer.stop()
            actBody()
            event.accepted = true
        }
    }
    Keys.onPressed: (event) => {
        const k = event.key
        if (k === Qt.Key_Escape) { back(); event.accepted = true; return }
        if (k === Qt.Key_I) { Sfx.play("back"); close(); event.accepted = true; return }
        switch (k) {
        case Qt.Key_Up: case Qt.Key_K:
            if (zone === "desc") {
                if (!scrollDesc(-1)) zone = "actions"
                Sfx.play("move")
            } else if (zone === "body") {
                if (bodyList.currentIndex <= 0) zone = "tabs"
                else bodyList.decrementCurrentIndex()
                Sfx.play("move")
            } else Sfx.play("bump")
            break
        case Qt.Key_Down: case Qt.Key_J:
            if (zone === "actions") {
                if (descText.length > 0) { zone = "desc"; Sfx.play("move") } else Sfx.play("bump")
            } else if (zone === "desc") Sfx.play(scrollDesc(1) ? "move" : "bump")
            else if (zone === "tabs") {
                if (bodyRows.length > 0) { zone = "body"; Sfx.play("move") } else Sfx.play("bump")
            } else {
                const was = bodyList.currentIndex
                bodyList.incrementCurrentIndex()
                Sfx.play(bodyList.currentIndex === was ? "bump" : "move")
            }
            break
        case Qt.Key_Left: case Qt.Key_H:
            if (zone === "actions") {
                if (act > 0) { act--; Sfx.play("move") } else Sfx.play("bump")
            } else if (zone === "desc") Sfx.play("bump")
            else stepSection(-1)
            break
        case Qt.Key_Right: case Qt.Key_L:
            if (zone === "actions") {
                if (act < actions.length - 1) { act++; Sfx.play("move") } else goRight()
            } else if (zone === "desc") goRight()
            else stepSection(1)
            break
        case Qt.Key_BracketLeft: stepSection(-1); break
        case Qt.Key_BracketRight: stepSection(1); break
        case Qt.Key_Return: case Qt.Key_Enter:
            if (event.isAutoRepeat) break
            if (zone === "actions") { if (actions[act]) doAction(actions[act].key) }
            else if (zone === "tabs") {
                if (bodyRows.length > 0) { zone = "body"; Sfx.play("move") } else Sfx.play("bump")
            } else if (zone === "desc") Sfx.play("bump")
            // a related video or a comment: hold = its menu
            else if (shownSection === "related" || shownSection === "comments") holdTimer.restart()
            else actBody()
            break
        case Qt.Key_PageDown: pageBody(1); break
        case Qt.Key_PageUp: pageBody(-1); break
        case Qt.Key_G:
            if (zone === "body") {
                bodyList.currentIndex = (event.modifiers & Qt.ShiftModifier) ? bodyRows.length - 1 : 0
                Sfx.play("move")
            }
            break
        case Qt.Key_F:
            if (shownSection === "comments" && !thread) sortComments(commentsSort === "top" ? "newest" : "top")
            else Sfx.play("bump")
            break
        case Qt.Key_A: {
            const r = zone === "body" && shownSection === "related" ? bodyRows[bodyList.currentIndex] : rowItem()
            if (r) { Sfx.play("select"); Queue.add(r); App.notify("QUEUED · " + r.title) }
            break
        }
        case Qt.Key_F5: reload(); break
        case Qt.Key_Q: App.queueOpen = !App.queueOpen; break
        case Qt.Key_C: App.outputOpen = true; break
        case Qt.Key_P: App.toPlayer(); break
        case Qt.Key_X: App.stopPlayback(); break
        default:
            return          // ? HELP, volume, … are the app's
        }
        event.accepted = true
    }

    // ── the backdrop ─────────────────────────────────────────────────────
    Rectangle { anchors.fill: parent; color: Theme.bg }
    // The still's own colours wash the page (a 32-px decode stretched over it
    // IS the blur, for free), under a scrim that keeps the words on near-black
    Image {
        anchors.fill: parent
        source: pg.open ? "https://i.ytimg.com/vi/" + pg.vid + "/mqdefault.jpg" : ""
        sourceSize.width: 32
        fillMode: Image.PreserveAspectCrop
        smooth: true
        asynchronous: true
        opacity: status === Image.Ready ? 0.8 : 0
        Behavior on opacity { NumberAnimation { duration: DS.slow } }
    }
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: Theme.withAlpha(Theme.bg, 0.62) }
            GradientStop { position: 0.45; color: Theme.withAlpha(Theme.bg, 0.82) }
            GradientStop { position: 1.0; color: Theme.withAlpha(Theme.bg, 0.92) }
        }
    }

    readonly property int gutter: onCrt ? 8 : 28
    readonly property int rightM: onCrt ? 16 : 36
    readonly property int colGap: onCrt ? 20 : 40
    readonly property int frameSlice: 10
    readonly property int frameIn: 5
    // the left column: the picture's width (whole art px)
    readonly property int leftW: Math.floor(width * (onCrt ? 0.46 : 0.42) / platePx) * platePx
    readonly property int descLine: Math.round(descBody.font.pixelSize * descBody.lineHeight)

    // pages arrive with the rows' deal: the left column settles into place
    property real dealY: 0
    NumberAnimation {
        id: fanIn
        target: pg; property: "dealY"; from: 10; to: 0
        duration: DS.grand; easing.type: Easing.Bezier; easing.bezierCurve: DS.enterCurve
    }

    // ── LEFT: the picture, the facts, the plates, the description ───────
    Item {
        id: still
        x: pg.gutter
        y: -3
        readonly property int inset: pg.frameIn * pg.platePx
        width: pg.leftW
        height: Math.round((width - 2 * inset) * 9 / 16 / pg.platePx) * pg.platePx + 2 * inset
        // the last page's picture holds the frame while this one loads (a
        // related video opened on top), then this one fades in over it
        Image {
            id: artBack
            anchors.fill: parent
            anchors.margins: still.inset
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            visible: art.settling || art.status === Image.Ready
        }
        Timer { id: artSettle; interval: DS.slow; onTriggered: artBack.source = art.source }
        Image {
            id: art
            anchors.fill: parent
            anchors.margins: still.inset
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            property int rung: 0
            function url(r) {
                if (!pg.open) return ""
                const names = ["maxresdefault", "sddefault", "hqdefault", "mqdefault"]
                return r > 3 ? (pg.item.artUrl || "")
                             : "https://i.ytimg.com/vi/" + pg.vid + "/" + names[r] + ".jpg"
            }
            readonly property string forVid: pg.vid
            onForVidChanged: { rung = 0; source = url(0) }
            onStatusChanged: {
                if (status === Image.Error && rung <= 3) { rung++; source = url(rung) }
                else if (status === Image.Ready) artSettle.restart()
            }
            readonly property bool settling: status === Image.Loading
                                             || (status === Image.Error && rung <= 3)
            // the frame lands WITH its picture, never before it
            readonly property bool landed: pg.open && (status === Image.Ready
                || (settling && artBack.status === Image.Ready) || !settling)
            opacity: status === Image.Ready ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: DS.slow } }
        }
        // the length on the picture's corner (LIVE in red), landing with it
        Rectangle {
            opacity: pageFrame.opacity
            readonly property bool live: pg.item.isLive === true || pg.page.isLive === true
            visible: live || pg.page.durationS > 0 || pg.item.durationS > 0
            anchors.right: art.right
            anchors.bottom: art.bottom
            anchors.margins: 14
            width: lenTxt.implicitWidth + 16
            height: lenTxt.implicitHeight + 8
            radius: 3
            color: live ? "#cc1f1f" : Theme.withAlpha("#000000", 0.8)
            Text {
                id: lenTxt
                anchors.centerIn: parent
                text: parent.live ? "LIVE" : pg.fmtTime(pg.page.durationS || pg.item.durationS || 0)
                color: "#ffffff"
                font.family: Theme.hudFont
                font.pixelSize: pg.onCrt ? 16 : 32
                font.letterSpacing: 1
            }
        }
        // how far into it you are — codec's own resume point
        Rectangle {
            anchors.left: art.left
            anchors.bottom: art.bottom
            height: 6
            width: art.width * (pg.storeRev, Store.resumePct(pg.item.uri || ""))
            visible: width > 2
            opacity: pageFrame.opacity
            color: "#cc1f1f"
        }
        MechSlice {
            id: pageFrame
            anchors.fill: parent
            opacity: art.landed ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: DS.slow } }
            source: "qrc:/assets/mechui/yt-thumb-frame.png"
            px: pg.platePx
            artL: pg.frameSlice; artR: pg.frameSlice
            artT: pg.frameSlice; artB: pg.frameSlice
        }
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: pg.play()
        }
    }

    Column {
        id: facts
        x: pg.gutter + still.inset
        anchors.top: still.bottom
        anchors.topMargin: pg.onCrt ? 12 : 22
        width: pg.leftW - 2 * still.inset
        spacing: pg.onCrt ? 10 : 16
        transform: Translate { y: pg.dealY }

        Text {
            width: parent.width
            text: Theme.mgsSafe(pg.page.title || pg.item.title || "")
            color: Theme.fg
            font.family: Theme.codecFont
            font.pixelSize: pg.onCrt ? 16 : 32
            lineHeight: 1.15
            wrapMode: Text.Wrap
            maximumLineCount: pg.onCrt ? 3 : 2
            elide: Text.ElideRight
        }

        // the channel: its picture, name and followers — a click opens it
        Item {
            width: parent.width
            height: avatar.height
            Rectangle {
                id: avatar
                width: pg.onCrt ? 44 : 64
                height: width
                color: Theme.surfaceHi
                border.color: Theme.border
                border.width: 1
                Image {
                    anchors.fill: parent
                    anchors.margins: 1
                    source: pg.page.avatar || ""
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    opacity: status === Image.Ready ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: DS.base } }
                }
            }
            Column {
                anchors.left: avatar.right
                anchors.leftMargin: 16
                anchors.right: parent.right
                anchors.verticalCenter: avatar.verticalCenter
                spacing: 6
                Text {
                    width: parent.width
                    text: Theme.mgsSafe(pg.channelName + (pg.page.verified ? "  ✓" : ""))
                    color: chMouse.containsMouse ? Theme.accent : Theme.fg
                    font.family: Theme.hudFont
                    font.pixelSize: pg.onCrt ? 24 : 32
                    elide: Text.ElideRight
                    MouseArea {
                        id: chMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: pg.openChannel()
                    }
                }
                Text {
                    width: parent.width
                    visible: text.length > 0
                    text: Theme.mgsSafe(((pg.page.subscribers || "")
                                         + (pg.subscribed ? "   ·   FOLLOWED" : "")).toUpperCase())
                    color: pg.subscribed ? Theme.accent : Theme.dimFg
                    font.family: Theme.hudFont
                    font.pixelSize: pg.onCrt ? 16 : 20
                    font.letterSpacing: 2
                    elide: Text.ElideRight
                }
            }
        }

        // views · the date · how long ago
        Text {
            width: parent.width
            visible: text.length > 0
            text: Theme.mgsSafe([pg.page.viewsText, pg.page.date, pg.page.ago]
                                .filter(x => x && x.length > 0).join("   ·   ").toUpperCase())
            color: Theme.dimFg
            font.family: Theme.hudFont
            font.pixelSize: pg.onCrt ? 16 : 20
            font.letterSpacing: 2
            wrapMode: Text.Wrap
        }

        // likes against dislikes, the bar YouTube used to draw
        Item {
            visible: (pg.page.likes || 0) > 0 && pg.page.dislikes !== undefined
                     && pg.page.dislikes >= 0
            width: Math.min(parent.width, plates.childrenRect.width - 16)
            height: 4
            readonly property real share: (pg.page.likes || 0)
                / Math.max(1, (pg.page.likes || 0) + Math.max(0, pg.page.dislikes || 0))
            Rectangle { anchors.fill: parent; color: Theme.withAlpha(Theme.fg, 0.18) }
            Rectangle {
                width: parent.width * parent.share
                height: parent.height
                color: Theme.accent
                Behavior on width { NumberAnimation { duration: DS.base } }
            }
        }

        // ── the plates ────────────────────────────────────────────────
        Flow {
            id: plates
            // the plate art's transparent px + outline: its light edge on the column's
            x: -8
            width: parent.width + 16
            spacing: 10
            Repeater {
                model: pg.actions
                delegate: YtAction {
                    required property var modelData
                    required property int index
                    kind: modelData.kind
                    label: modelData.label
                    icon: modelData.icon || ""
                    on: modelData.on === true
                    lit: pg.zone === "actions" && pg.act === index
                    live: pg.open
                    platePx: pg.platePx
                    labelPx: pg.onCrt ? 16 : 20
                    onClicked: { pg.zone = "actions"; pg.act = index; pg.doAction(modelData.key) }
                }
            }
        }

        Text {
            visible: pg.loading || pg.error.length > 0
            width: parent.width
            text: Theme.mgsSafe(pg.error.length > 0 ? "⚠ " + pg.error.toUpperCase() + "   ·   F5 TRY AGAIN"
                                                      : "READING THE PAGE…")
            color: pg.error.length > 0 ? Theme.warning : Theme.accent
            font.family: Theme.hudFont
            font.pixelSize: 16
            font.letterSpacing: 3
            wrapMode: Text.Wrap
        }
    }

    // the description, under it all: links and timestamps live; ↓ from the
    // plates reads down it
    Flickable {
        id: descFlick
        x: pg.gutter + still.inset
        anchors.top: facts.bottom
        anchors.topMargin: pg.onCrt ? 14 : 24
        anchors.bottom: hints.top
        anchors.bottomMargin: 12
        width: facts.width
        contentHeight: descBody.height
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        // where the keys are scrolling to (contentY runs behind it, eased)
        property real target: 0
        onMovementEnded: target = contentY
        Behavior on contentY { enabled: !descFlick.moving; NumberAnimation { duration: 140; easing.type: Easing.OutQuad } }
        Text {
            id: descBody
            width: parent.width
            textFormat: Text.RichText
            linkColor: Theme.accent
            onLinkActivated: (link) => pg.followLink(link)
            // Untrusted text: escaped FIRST, then only URLs and timestamps
            // become anchors (yt.linkify)
            text: pg.yt ? pg.yt.linkify(Theme.mgsSafe(pg.descText), hoveredLink) : ""
            HoverHandler {
                cursorShape: descBody.hoveredLink.length > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
            }
            color: Theme.withAlpha(Theme.fg, pg.zone === "desc" ? 0.92 : 0.66)
            Behavior on color { ColorAnimation { duration: DS.selFade } }
            font.family: Theme.hudFont
            font.pixelSize: pg.onCrt ? 16 : 24
            lineHeight: 1.32
            wrapMode: Text.Wrap
        }
    }
    // more of it below: the column fades out instead of stopping on a cut line
    Rectangle {
        anchors.left: descFlick.left
        anchors.right: descFlick.right
        anchors.bottom: descFlick.bottom
        height: 48
        visible: descFlick.contentHeight - descFlick.contentY > descFlick.height + 2
        gradient: Gradient {
            GradientStop { position: 0.0; color: "transparent" }
            GradientStop { position: 1.0; color: Theme.withAlpha(Theme.bg, 0.95) }
        }
    }

    // ── RIGHT: chapters · comments · related, the full height ───────────
    Item {
        id: right
        x: pg.gutter + pg.leftW + pg.colGap
        width: pg.width - x - pg.rightM
        anchors.top: parent.top
        anchors.topMargin: -3
        anchors.bottom: hints.top
        anchors.bottomMargin: 8

        // the section tabs — the strip's hexagons
        Row {
            id: secTabs
            spacing: 4
            height: 40
            Repeater {
                model: pg.sections
                delegate: YtHexTab {
                    required property string modelData
                    label: pg.sectionLabel(modelData)
                    current: pg.shownSection === modelData
                    focused: pg.zone === "tabs"
                    live: pg.open
                    platePx: pg.platePx
                    labelPx: pg.onCrt ? 16 : 22
                    pad: pg.onCrt ? 40 : 56
                    onClicked: {
                        pg.zone = "tabs"
                        if (!current) {
                            Sfx.play("move")
                            pg.section = modelData
                            pg.thread = null
                            bodyList.currentIndex = 0
                            bodyList.fanIn()
                        }
                    }
                }
            }
        }

        // what the open section is about, beside the tabs: the comments'
        // order (f), a thread's author, chapters YouTube made itself
        Text {
            anchors.right: parent.right
            anchors.left: secTabs.right
            anchors.leftMargin: 16
            anchors.verticalCenter: secTabs.verticalCenter
            anchors.verticalCenterOffset: -3
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideLeft
            visible: text.length > 0
            text: {
                if (pg.shownSection === "comments") {
                    if (pg.thread) return Theme.mgsSafe("REPLIES TO " + String(pg.thread.parent.author).toUpperCase() + "   ·   ESC BACK")
                    return pg.commentsSort === "top" ? "TOP FIRST   ·   F NEWEST" : "NEWEST FIRST   ·   F TOP"
                }
                if (pg.shownSection === "chapters" && pg.page.autoChapters) return "CHAPTERS YOUTUBE MADE"
                return ""
            }
            color: sortMouse.containsMouse ? Theme.accent : Theme.dimFg
            font.family: Theme.hudFont
            font.pixelSize: 16
            font.letterSpacing: 2
            MouseArea {
                id: sortMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    if (pg.thread) pg.back()
                    else if (pg.shownSection === "comments")
                        pg.sortComments(pg.commentsSort === "top" ? "newest" : "top")
                }
            }
        }

        ListView {
            id: bodyList
            anchors.top: secTabs.bottom
            anchors.topMargin: 16
            anchors.bottom: parent.bottom
            width: parent.width
            model: bodyModel
            clip: true
            spacing: pg.shownSection === "comments" ? 6 : 0
            highlight: Item {}
            highlightRangeMode: App.pointerActive ? ListView.NoHighlightRange : ListView.ApplyRange
            preferredHighlightBegin: pg.rowH
            preferredHighlightEnd: height - 2 * pg.rowH
            highlightMoveDuration: 180
            highlightResizeDuration: 0
            cacheBuffer: Math.max(0, height)
            keyNavigationWraps: false
            // the rows fan in (Cascade) on a new section or page
            property int cascadeRev: 0
            property double cascadeAt: 0
            function fanIn() { cascadeAt = Date.now(); cascadeRev++ }
            onCurrentIndexChanged: if (count > 0 && currentIndex >= count - 6) pg.moreBody()
            onContentYChanged: if (contentHeight > 0 && contentY + height > contentHeight - 4 * pg.rowH) pg.moreBody()

            delegate: Loader {
                id: bodyDel
                required property int index
                readonly property var modelData: pg.bodyRows[index] || ({})
                readonly property bool isCur: ListView.isCurrentItem && pg.zone === "body"
                width: bodyList.width
                Cascade { id: fan; view: bodyList }
                opacity: fan.op
                readonly property real fanDy: fan.dy
                sourceComponent: pg.shownSection === "comments" ? commentRow
                               : pg.shownSection === "chapters" ? chapterRow : videoRow
                MouseArea {
                    anchors.fill: parent
                    z: -1          // a link inside a comment takes its own click
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    property point prevScene: Qt.point(-9999, -9999)
                    onExited: prevScene = Qt.point(-9999, -9999)
                    onPositionChanged: (mouse) => {
                        const p = mapToItem(null, mouse.x, mouse.y)
                        const moved = Math.abs(p.x - prevScene.x) > 2 || Math.abs(p.y - prevScene.y) > 2
                        prevScene = Qt.point(p.x, p.y)
                        if (App.pointerActive && moved && !bodyList.moving
                                && (bodyList.currentIndex !== bodyDel.index || pg.zone !== "body")) {
                            Sfx.play("move")
                            pg.zone = "body"
                            bodyList.currentIndex = bodyDel.index
                        }
                    }
                    onClicked: {
                        pg.zone = "body"
                        bodyList.currentIndex = bodyDel.index
                        pg.actBody()
                    }
                    onPressAndHold: {
                        pg.zone = "body"
                        bodyList.currentIndex = bodyDel.index
                        pg.holdBody()
                    }
                }
            }

            Text {
                anchors.centerIn: parent
                width: parent.width - 80
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                visible: bodyList.count === 0 && text.length > 0
                text: {
                    if (pg.loading) return ""
                    if (pg.shownSection === "comments")
                        return pg.commentsLoading ? "READING THE COMMENTS…"
                             : pg.page.commentsToken ? "NO COMMENTS YET" : "COMMENTS ARE OFF HERE"
                    if (pg.shownSection === "related") return pg.relatedLoading ? "" : "NOTHING RELATED"
                    return ""
                }
                color: Theme.dimFg
                font.family: Theme.hudFont
                font.pixelSize: 24
                font.letterSpacing: 2
            }
            footer: Item {
                width: bodyList.width
                height: (pg.commentsLoading || pg.relatedLoading) && bodyList.count > 0 ? 40 : 0
                Text {
                    anchors.centerIn: parent
                    visible: parent.height > 0
                    text: "LOADING MORE"
                    color: Theme.dimFg
                    font.family: Theme.hudFont
                    font.pixelSize: 16
                    font.letterSpacing: 4
                }
            }
        }
    }

    // ── The composer: a comment, or a reply, as the account ─────────────
    // over the top of the right column; ⏎ posts, ⇧⏎ starts a new line, esc
    // puts it away (the words stay for the next time it opens)
    Item {
        id: composer
        visible: pg.composing !== null
        x: right.x
        y: right.y + 56
        width: right.width
        height: compCol.height + 28
        z: 5
        Rectangle {
            anchors.fill: parent
            color: Theme.bg
            border.color: Theme.border
            border.width: 1
        }
        MouseArea { anchors.fill: parent }       // clicks stay on the composer
        Row {
            x: 18; y: 14
            spacing: 16
            Rectangle {
                width: 44; height: 44
                color: Theme.surfaceHi
                border.color: Theme.border
                border.width: 1
                Image {
                    anchors.fill: parent
                    anchors.margins: 1
                    source: YouTube.account.photo || ""
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                }
            }
            Column {
                id: compCol
                width: composer.width - 18 - 44 - 16 - 24
                spacing: 10
                Text {
                    width: parent.width
                    text: Theme.mgsSafe(((pg.composing && pg.composing.reply)
                                         ? "REPLYING TO " + String(pg.composing.parent ? pg.composing.parent.author : "")
                                         : "COMMENTING")
                                        + " AS " + String(YouTube.account.handle || YouTube.account.name || "YOU")).toUpperCase()
                    color: Theme.accent
                    font.family: Theme.codecFont
                    font.pixelSize: 16
                    font.letterSpacing: 2
                    elide: Text.ElideRight
                }
                // the words, in the typing face (Departure Mono, as every box)
                Item {
                    width: parent.width
                    height: Math.max(composeText.font.pixelSize * 2.6, Math.min(composeText.contentHeight + 8, 260))
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: -6
                        color: Theme.withAlpha(Theme.surfaceHi, 0.5)
                        border.color: composeText.activeFocus ? Theme.accent : Theme.border
                        border.width: 1
                    }
                    Flickable {
                        id: compFlick
                        anchors.fill: parent
                        contentHeight: composeText.contentHeight
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        TextEdit {
                            id: composeText
                            width: compFlick.width
                            color: Theme.fg
                            font.family: "Departure Mono"
                            font.pixelSize: 22
                            wrapMode: TextEdit.Wrap
                            selectByMouse: true
                            onCursorRectangleChanged: {
                                if (cursorRectangle.y + cursorRectangle.height > compFlick.contentY + compFlick.height)
                                    compFlick.contentY = cursorRectangle.y + cursorRectangle.height - compFlick.height
                                else if (cursorRectangle.y < compFlick.contentY)
                                    compFlick.contentY = cursorRectangle.y
                            }
                            Keys.onPressed: (event) => {
                                if (event.key === Qt.Key_Escape) {
                                    pg.cancelCompose(); event.accepted = true
                                } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                                           && !(event.modifiers & Qt.ShiftModifier)) {
                                    if (!event.isAutoRepeat) pg.postCompose()
                                    event.accepted = true
                                }
                            }
                            Text {
                                visible: composeText.text.length === 0
                                text: pg.composing && pg.composing.reply ? "YOUR REPLY…" : "SAY SOMETHING…"
                                color: Theme.dimFg
                                font.family: Theme.hudFont
                                font.pixelSize: 20
                                font.letterSpacing: 1
                            }
                        }
                    }
                }
                Item {
                    width: parent.width
                    height: 40
                    Text {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: Theme.mgsSafe(pg.posting ? "POSTING…" : "⏎ POSTS   ·   ⇧⏎ NEW LINE   ·   ESC PUTS IT AWAY")
                        color: pg.posting ? Theme.accent : Theme.dimFg
                        font.family: Theme.hudFont
                        font.pixelSize: 16
                        font.letterSpacing: 1
                    }
                    Row {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 10
                        YtAction { kind: "icon"; icon: "close"; label: "CANCEL"; labelPx: 16; live: composer.visible
                                   onClicked: pg.cancelCompose() }
                        YtAction { kind: "icon"; icon: "mail"; label: "POST"; labelPx: 16; live: composer.visible
                                   onClicked: pg.postCompose() }
                    }
                }
            }
        }
    }

    Component {
        id: videoRow
        YtRow {
            readonly property var r: parent ? parent.modelData : ({})
            height: pg.rowH
            title: r.title || ""; subtitle: r.subtitle || ""
            artUrl: r.artUrl || ""; kind: "video"
            videoId: r.videoId || ""; published: r.published || ""
            isLive: r.isLive === true; isShort: r.isShort === true; uri: r.uri || ""
            isCur: parent ? parent.isCur : false
            live: pg.open
            platePx: pg.platePx
            storeRev: pg.storeRev
            fanDy: parent ? parent.fanDy : 0
        }
    }
    Component {
        id: chapterRow
        YtRow {
            readonly property var r: parent ? parent.modelData : ({})
            height: pg.rowH
            title: r.title || ""
            badge: pg.fmtTime(r.time || 0)
            artUrl: r.thumb || ""
            kind: "chapter"
            isCur: parent ? parent.isCur : false
            live: pg.open
            platePx: pg.platePx
            fanDy: parent ? parent.fanDy : 0
        }
    }
    // A comment: its author's picture, who and when, the words (all of them
    // on the lit card), its likes and replies. A timestamp in it plays this
    // video from there; ⏎ opens its replies.
    Component {
        id: commentRow
        Item {
            id: cm
            readonly property var c: parent ? parent.modelData : ({})
            readonly property bool isCur: parent ? parent.isCur : false
            readonly property bool card: c.kind === "compose"
            height: card ? 64 : Math.max(84, body.implicitHeight + 34)
            MechButton {
                family: 3
                px: pg.platePx
                anchors.fill: parent
                hot: cm.isCur
                opacity: cm.isCur ? 1 : 0.45
                Behavior on opacity { NumberAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
            }
            // the card that writes one: ⏎ opens the composer
            Row {
                visible: cm.card
                x: 22 + (cm.c.reply ? 56 : 0)
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: -2
                spacing: 16
                transform: Translate { y: cm.parent ? cm.parent.fanDy : 0 }
                IconPlate {
                    anchors.verticalCenter: parent.verticalCenter
                    icon: "mail"
                    lit: cm.isCur
                    live: pg.open && cm.card
                    px: pg.platePx
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: Theme.mgsSafe(!pg.canComment ? "COMMENTING NEEDS A YOUTUBE ACCOUNT   ·   ⏎ SETTINGS ▸ YOUTUBE"
                                        : cm.c.reply ? "REPLY TO " + String(cm.c.parent ? cm.c.parent.author : "").toUpperCase() + "…"
                                        : "ADD A COMMENT…")
                    color: cm.isCur ? "#f2f7fa" : Theme.dimFg
                    font.family: Theme.codecFont
                    font.pixelSize: pg.onCrt ? 16 : 20
                    font.letterSpacing: 2
                }
            }
            Row {
                id: body
                visible: !cm.card
                // a reply sits in under the comment it answers
                x: 22 + (cm.c.reply ? 56 : 0)
                y: 14
                spacing: 16
                transform: Translate { y: cm.parent ? cm.parent.fanDy : 0 }
                Rectangle {
                    width: 44; height: 44
                    color: Theme.surfaceHi
                    border.color: Theme.border
                    border.width: 1
                    Image {
                        anchors.fill: parent
                        anchors.margins: 1
                        source: cm.c.avatar || ""
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                    }
                }
                Column {
                    width: cm.width - body.x - 44 - 16 - 40
                    spacing: 8
                    Text {
                        width: parent.width
                        // U+200E: the line reads left to right even when the
                        // name is Arabic or Hebrew (its first letter set the
                        // whole line's direction: "3 MONTHS AGO · <name>")
                        // and U+2068…U+2069 isolate the name: its digits
                        // otherwise pulled the "3" of "3 MONTHS AGO" into it
                        text: "\u200E" + Theme.mgsSafe((cm.c.pinned ? "PINNED   ·   " : "")
                                                       + "\u2068" + (cm.c.author || "") + "\u2069"
                                                       + "   ·   " + String(cm.c.published || "").toUpperCase())
                        // a right-to-left name or comment would right-align the
                        // whole line (Qt follows the text's own direction)
                        horizontalAlignment: Text.AlignLeft
                        color: cm.c.creator ? Theme.accent : Theme.dimFg
                        opacity: cm.isCur ? 1 : 0.8
                        font.family: Theme.hudFont
                        font.pixelSize: 16
                        font.letterSpacing: 1
                        elide: Text.ElideRight
                    }
                    Text {
                        width: parent.width
                        textFormat: Text.RichText
                        linkColor: Theme.accent
                        onLinkActivated: (link) => pg.followLink(link)
                        text: pg.yt ? pg.yt.linkify(Theme.mgsSafe(cm.c.text || ""), hoveredLink) : ""
                        horizontalAlignment: Text.AlignLeft
                        color: Theme.fg
                        opacity: cm.isCur ? 1 : 0.7
                        Behavior on opacity { NumberAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                        font.family: Theme.hudFont
                        font.pixelSize: pg.onCrt ? 16 : 24
                        lineHeight: 1.25
                        wrapMode: Text.Wrap
                        maximumLineCount: cm.isCur ? 40 : 4
                        elide: Text.ElideRight
                    }
                    Text {
                        color: cm.c.liked ? Theme.accent : Theme.dimFg
                        text: Theme.mgsSafe("▲ " + (cm.c.likes || "0") + (cm.c.liked ? " · LIKED" : "")
                                            + (cm.c.hearted ? "   ·   ♥ BY THE CREATOR" : "")
                                            + (cm.c.replies > 0 && !pg.thread
                                               ? "   ·   " + cm.c.replies + (cm.c.replies === 1 ? " REPLY" : " REPLIES")
                                                 + (cm.isCur ? "   ⏎" : "") : ""))
                        opacity: cm.isCur ? 1 : 0.7
                        font.family: Theme.hudFont
                        font.pixelSize: 16
                        font.letterSpacing: 1
                    }
                }
            }
        }
    }

    KeyHints {
        id: hints
        x: pg.gutter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 6
        width: pg.width - pg.gutter - pg.rightM
        px: 13
        model: {
            if (pg.onCrt)
                return [["j/k", "MOVE"], ["⏎", pg.zone === "body" ? "OPEN" : "DO"], ["esc", "BACK"], ["?", "HELP"]]
            let m = [["j/k", "MOVE"], ["h/l", pg.zone === "actions" ? "PLATES" : "SECTIONS"]]
            if (pg.zone === "actions") m.push(["⏎", "DO"])
            else if (pg.zone === "body" && pg.shownSection === "chapters") m.push(["⏎", "PLAY FROM THERE"])
            else if (pg.zone === "body" && pg.shownSection === "comments") m.push(["⏎", "REPLIES"])
            else if (pg.zone === "body") m.push(["⏎", "ITS PAGE"], ["hold-⏎", "MENU"])
            if (pg.shownSection === "comments" && pg.zone !== "actions" && pg.zone !== "desc") m.push(["f", "ORDER"])
            m.push(["a", "QUEUE"], ["F5", "RELOAD"], ["esc", "BACK"], ["i", "CLOSE"], ["?", "HELP"])
            return m
        }
    }
}
