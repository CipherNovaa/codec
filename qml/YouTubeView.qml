import QtQuick

// YouTube browser — same skeleton as LibraryView (list + pane, "/" search,
// hjkl) plus tabs, multi-select (space), and queueing (a/A). Playlists and
// channels drill in with ⏎; esc walks back out. h/l are ←/→ (the tabs).
FocusScope {
    id: yt

    property bool searchMode: false
    property double lastG: 0
    // Multi-select: videoId -> true. Object reassigned on change for binding.
    property var sel: ({})
    property bool everOpened: false
    // ── Search filters: a submenu in the shared ContextMenu ───────────────
    // f opens FILTERS (one row per group, showing its current value); picking
    // a group opens its options; picking an option applies it (the search
    // re-runs) and returns to FILTERS. Esc in an option list steps back up.
    // Sort/date/type/length/live are YouTube's own (codec_yt.py
    // search_params); ORDER reverses what is loaded — YouTube only sorts down.
    readonly property var filterGroups: [
        { key: "sort", label: "SORT", opts: [["", "RELEVANCE"], ["date", "UPLOAD DATE"], ["views", "VIEW COUNT"], ["rating", "RATING"]] },
        { key: "date", label: "UPLOADED", opts: [["", "ANY TIME"], ["hour", "LAST HOUR"], ["today", "TODAY"], ["week", "THIS WEEK"], ["month", "THIS MONTH"], ["year", "THIS YEAR"]] },
        { key: "type", label: "TYPE", opts: [["", "ANY"], ["video", "VIDEO"], ["channel", "CHANNEL"], ["playlist", "PLAYLIST"], ["movie", "MOVIE"]] },
        { key: "duration", label: "LENGTH", opts: [["", "ANY"], ["short", "UNDER 4 MIN"], ["medium", "4 – 20 MIN"], ["long", "OVER 20 MIN"]] },
        { key: "live", label: "LIVE", opts: [["", "ANY"], ["1", "LIVE NOW ONLY"]] },
        { key: "order", label: "ORDER", opts: [["", "DESCENDING"], ["asc", "ASCENDING"]] }
    ]
    property var filterGroup: null
    // A channel's page: what it lists — its uploads or its playlists (the
    // FILTERS menu's SHOW row, only inside a channel)
    readonly property var showGroup: ({ key: "view", label: "SHOW",
                                        opts: [["videos", "VIDEOS"], ["shorts", "SHORTS"],
                                               ["streams", "LIVE"], ["playlists", "PLAYLISTS"]] })
    // The FILTERS menu's rows, parallel to its entries: {g} a group, {header},
    // {reset}
    property var filterRows: []
    property bool ctxStepBack: false

    function filterValue(g) {
        if (g.key === "view") return YouTube.channelView
        if (g.key === "order") return YouTube.reversed ? "asc" : ""
        const v = YouTube.filters[g.key]
        if (g.key === "live") return v ? "1" : ""
        return v ? String(v) : ""
    }
    function filterLabel(g) {
        const v = filterValue(g)
        const o = g.opts.find(o => o[0] === v)
        return o ? o[1] : g.opts[0][1]
    }
    function setFilter(g, v) {
        if (g.key === "view") {
            if (v !== YouTube.channelView) { YouTube.setChannelView(v); list.currentIndex = 0 }
            return
        }
        if (g.key === "order") { YouTube.reversed = (v === "asc"); return }
        let f = Object.assign({}, YouTube.filters)
        if (v === "") delete f[g.key]
        else f[g.key] = (g.key === "live") ? true : v
        YouTube.filters = f
    }
    // On a search every row filters it. Anywhere else the menu says which
    // rows act on what's listed (ORDER; a channel's SHOW) and which wait for
    // the next search — the old title "FILTERS · APPLY TO SEARCH" read as if
    // they filtered the page in front of you.
    function openFilters() {
        ctxMode = "filters"
        const onSearch = YouTube.tab === "search" && !YouTube.drilled
        const channel = YouTube.channelView !== ""
        let rows = []
        if (onSearch) {
            for (const g of filterGroups) rows.push({ g: g })
        } else {
            rows.push({ header: channel ? "THIS CHANNEL" : "THIS LIST" })
            if (channel) rows.push({ g: showGroup })
            for (const g of filterGroups) if (g.key === "order") rows.push({ g: g })
            rows.push({ header: "SEARCHES ONLY" })
            for (const g of filterGroups) if (g.key !== "order") rows.push({ g: g })
        }
        rows.push({ reset: true })
        filterRows = rows
        ctx.openMenu(onSearch ? "SEARCH FILTERS" : "FILTERS",
                     rows.map(r => r.header ? ({ header: true, label: r.header })
                                   : r.reset ? ({ label: "RESET FILTERS", hint: "" })
                                   : ({ label: r.g.label, hint: filterLabel(r.g) })),
                     Qt.Key_F)
    }
    function openFilterGroup(g) {
        filterGroup = g
        ctxMode = "filteropt"
        const cur = filterValue(g)
        ctx.openMenu("FILTERS · " + g.label,
                     g.opts.map(o => ({ label: o[1], hint: o[0] === cur ? "●" : "" })),
                     Qt.Key_F)
    }
    // Bumped when the watch DB changes (only while this view is up — a resume
    // save every few seconds mid-film must not re-query every row behind the
    // player) so the rows' resume bars stay current.
    property int storeRev: 0
    // Tilt wheel steps between the tab sections, like Left/Right (detected
    // app-wide in AppController::eventFilter so it never blocks scrolling).
    Connections {
        target: App
        enabled: yt.visible && !ctx.visible && !App.searchOpen
                 && !App.queueOpen && !App.outputOpen
        function onTiltStep(dir) { if (page.open) page.stepSection(dir); else yt.cycleTab(dir) }
    }
    // Pixel scale for every plate here — rows, tabs and the search art — so
    // their 1px lines all match (the rows rode STATS's height/360 law, 4 at
    // 1440p: a bevel twice as thick as the tabs' beside it).
    readonly property int platePx: 2
    // Row height: tall enough that a 16:9 thumbnail sits wholly inside the
    // plate's dark face, clear of its top rim and the lit band at the bottom.
    readonly property int rowH: 78
    Connections {
        target: Store
        enabled: yt.visible
        function onUpdated() { yt.storeRev++ }
    }

    function escapeHtml(t) {
        return t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
                .replace(/"/g, "&quot;")
    }

    // Description text -> RichText with clickable links and timestamps.
    // Works on the RAW text: each plain run and each link's shown text is
    // escaped on its own, so truncating a long URL can never cut an entity in
    // half, and the href carries the real URL (only http(s) and ts: links).
    // links read by colour; the one under the pointer gets its underline
    // (RichText honours the inline style; `hovered` is that link's href)
    function linkStyle(href, hovered) {
        return href === hovered ? ' style="text-decoration:underline"'
                                : ' style="text-decoration:none"'
    }
    function linkify(raw, hovered) {
        if (!raw) return ""
        const re = /(https?:\/\/[^\s<>"]+[^\s<>".,;:!?)\]'])|(^|[\s(\-–])((?:\d{1,2}:)?\d{1,2}:\d{2})(?=[\s).,\-–]|$)/gm
        let out = "", last = 0, m
        while ((m = re.exec(raw)) !== null) {
            if (m[1]) {
                out += escapeHtml(raw.slice(last, m.index))
                const url = m[1]
                const shown = url.length > 60 ? url.slice(0, 57) + "…" : url
                out += '<a href="' + escapeHtml(url) + '"' + linkStyle(url, hovered) + '>'
                       + escapeHtml(shown) + '</a>'
            } else {
                out += escapeHtml(raw.slice(last, m.index) + m[2])
                out += '<a href="ts:' + m[3] + '"' + linkStyle("ts:" + m[3], hovered) + '>'
                       + m[3] + '</a>'
            }
            last = re.lastIndex
        }
        out += escapeHtml(raw.slice(last))
        return out.replace(/\n/g, "<br>")
    }

    function isYouTubeUrl(u) {
        return /^https?:\/\/((www|m|music)\.)?(youtube\.com|youtu\.be)\//.test(u)
    }

    // A YouTube link stays in codec (videos play, channels and playlists open
    // here); anything else goes to the default browser. A timestamp seeks
    // the video when it is the one playing.
    function followLink(link) {
        const href = link.replace(/&quot;/g, '"').replace(/&lt;/g, "<")
                         .replace(/&gt;/g, ">").replace(/&amp;/g, "&")
        if (href.indexOf("ts:") === 0) {
            const parts = href.slice(3).split(":").map(Number)
            let secs = 0
            for (const n of parts) secs = secs * 60 + n
            const cur = plate.cur
            if (cur && Engine.path.indexOf(cur.videoId) >= 0 && !Engine.idle) {
                App.seekTo(secs)
                App.toPlayer()
            } else if (cur && cur.kind === "video") {
                App.playItem(Object.assign({}, cur, { uri: cur.uri + "&t=" + secs + "s" }))
            }
            return
        }
        if (!isYouTubeUrl(href)) {
            Qt.openUrlExternally(href)
            return
        }
        if (/\/(watch|shorts\/|live\/|embed\/)|youtu\.be\//.test(href)
                && !/[?&]list=/.test(href)) {
            App.playItem({ uri: href, title: "", kind: "video", sourceId: "youtube" })
        } else {
            YouTube.openUrl(href)
            list.currentIndex = 0
        }
    }

    // FOR YOU first ("for you is first, swapping playlists and for you");
    // a playlist pinned as a tab (hold-⏎ ▸ PIN AS A TAB) comes after PLAYLISTS
    readonly property var tabs: ["search", "rec", "subs", "watchlater", "history", "playlists"]
                                .concat(YouTube.pins.map(p => "pin:" + p.url))
    readonly property var tabLabels: ["SEARCH", "FOR YOU", "SUBS", "WATCH LATER", "HISTORY", "PLAYLISTS"]
                                     .concat(YouTube.pins.map(p => pinLabel(p.title)))
    function pinLabel(t) {
        t = Theme.mgsSafe(String(t || "")).toUpperCase()
        return t.length > 18 ? t.slice(0, 17).trim() + "…" : t
    }
    // the playlist a row or listing is, as a pin's url
    function pinUrl(it) {
        return it && it.kind === "playlist" ? (it.uri || "") : ""
    }

    function entered() {
        storeRev++
        takeFocus()
        if (!everOpened) {
            everOpened = true
            YouTube.openTab("rec")
        }
    }
    onVisibleChanged: if (visible) entered()
    // On-demand Loader: created already visible, so visible never CHANGES on
    // the first visit — run the entry here too (the STATS fix). everOpened
    // keeps the first tab from opening twice.
    Component.onCompleted: if (visible) entered()

    // Keys back to the rail. yt is a FocusScope: forceActiveFocus() on it
    // re-enters whichever child last held focus — and when that child is the
    // filter bar or the search field that just HID, focus lands on an
    // invisible item and every key (j/k, Enter, the remote) goes nowhere.
    // Clear those children first, so the scope itself takes the keys.
    function takeFocus() {
        searchInput.focus = false
        if (page.open) {
            page.forceActiveFocus()
            return
        }
        page.focus = false          // a closed page is a hidden child too
        yt.forceActiveFocus()
    }

    property alias videoPage: page

    // ── A drilled listing's header (YtListingHeader) ─────────────────────
    // ↑ from the first row walks onto its plates (railZone "header"); inside
    // a channel ←/→ walk the channel's own tabs instead of the strip's.
    property string railZone: "rows"
    property int headAct: 0
    property int followRev: 0
    readonly property var channelViews: ["videos", "shorts", "streams", "playlists"]
    readonly property var headerPlates: {
        const h = YouTube.header
        // codec's own lists: NOTIFICATIONS clears, ALL CHANNELS selects
        // (several at once — unsubscribe a batch)
        if (h.url === "codec:notifications")
            return [{key: "nclear", kind: "icon", icon: "trash", label: "CLEAR ALL"},
                    {key: "select", kind: "icon", icon: "check", label: "SELECT"}]
        if (h.url === "codec:channels")
            return [{key: "select", kind: "icon", icon: "check", label: "SELECT"}]
        if (h.kind !== "channel" && h.kind !== "playlist") return []
        let p = []
        if (h.kind === "playlist" || YouTube.channelView !== "playlists")
            p.push({key: "all", label: "▶  PLAY ALL"}, {key: "shuffle", label: "SHUFFLE"})
        if (h.kind === "channel") {
            const f = (followRev, YouTube.isFollowing(h.url))
            p.push(f ? {key: "sub", label: "SUBSCRIBED", on: true}
                     : {key: "sub", kind: "pill", label: "SUBSCRIBE"})
        }
        if (h.kind === "playlist" && h.url) {
            const pinned = (YouTube.pins, YouTube.isPinned(h.url))
            p.push({key: "pin", label: pinned ? "PINNED" : "PIN AS A TAB", on: pinned})
        }
        return p
    }
    Connections {
        target: YouTube
        function onFollowingChanged() { yt.followRev++ }
        function onListingChanged() { if (yt.headerPlates.length === 0) yt.railZone = "rows" }
        function onTabChanged() { yt.railZone = "rows"; yt.trackDepth() }
        // a marked selection belongs to the list it was made in
        function onContextChanged() { yt.sel = ({}); yt.selecting = false }
        function onModelReset() {
            if (yt.restoreRow < 0) return
            const r = yt.restoreRow
            yt.restoreRow = -1
            Qt.callLater(() => {
                list.currentIndex = Math.max(0, Math.min(r, list.count - 1))
                list.positionViewAtIndex(list.currentIndex, ListView.Center)
            })
        }
    }

    // Back returns to the row it left: the row is kept for every listing
    // drilled into (the parent replays from its first page, so a row past
    // that lands on the last one loaded)
    property var depthStack: []
    property int lastDepth: 0
    property string lastTab: ""
    property int restoreRow: -1
    function trackDepth() {
        const d = YouTube.depth
        if (YouTube.tab !== lastTab) { depthStack = []; restoreRow = -1 }
        else if (d > lastDepth) depthStack = depthStack.concat([list.currentIndex])
        else if (d < lastDepth && depthStack.length > d) {
            // the row this level was left from (back several at once: the
            // tab again from inside a channel's playlist)
            restoreRow = depthStack[d]
            depthStack = depthStack.slice(0, d)
        }
        lastDepth = d
        lastTab = YouTube.tab
        sel = ({})
        selecting = false
    }
    function headerDo(key) {
        const h = YouTube.header
        if (key === "nclear") {
            Sfx.play("open")
            ctxMode = "nclear"
            ctx.openMenu("CLEAR ALL NOTIFICATIONS?",
                         [{label: "YES, CLEAR THEM", hint: "hides every one on YouTube"}, {label: "CANCEL"}])
            return
        }
        if (key === "select") {
            railZone = "rows"
            if (selecting) { Sfx.play("back"); stopSelecting() } else startSelecting()
            return
        }
        Sfx.play("select")
        if (key === "all" || key === "shuffle") {
            App.notify(key === "all" ? "PLAY ALL · READING THE LIST…" : "SHUFFLE · READING THE LIST…")
            YouTube.playAll(key === "shuffle")
        } else if (key === "sub") {
            if (YouTube.isFollowing(h.url)) YouTube.unsubscribe(h.url, h.title)
            else YouTube.subscribe(h.url, h.title)
        } else if (key === "pin") {
            if (YouTube.isPinned(h.url)) {
                YouTube.unpin(h.url)
                App.notify("UNPINNED · " + pinLabel(h.title))
            } else {
                YouTube.pin(h.url, h.title)
                App.notify("PINNED AS A TAB · " + pinLabel(h.title))
            }
        }
    }
    // PLAY ALL / SHUFFLE's videos: the first plays, the rest follow it in
    // the queue — ahead of what was queued already, which carries on after
    function playAllRows(rows, shuffle) {
        rows = rows.slice()
        if (shuffle)
            for (let i = rows.length - 1; i > 0; i--) {
                const j = Math.floor(Math.random() * (i + 1))
                const t = rows[i]; rows[i] = rows[j]; rows[j] = t
            }
        if (rows.length === 0) { App.notify("NOTHING TO PLAY HERE"); return }
        for (let i = rows.length - 1; i > 0; i--) Queue.addFront(rows[i])
        App.playItem(rows[0])
        App.notify((shuffle ? "SHUFFLED · " : "PLAYING ALL · ") + rows.length
                   + (rows.length === 1 ? " VIDEO" : " VIDEOS"))
    }
    function stepChannelView(dir) {
        const i = channelViews.indexOf(YouTube.channelView)
        const n = i + dir
        if (i < 0 || n < 0 || n >= channelViews.length) { Sfx.play("bump"); return }
        Sfx.play("move")
        YouTube.setChannelView(channelViews[n])
        list.currentIndex = 0
    }
    // A video's own page (YouTubePage): i on a video row, hold-⏎ ▸ VIDEO
    // PAGE, or a click on the big still.
    function openPage(it) {
        if (!it || it.kind !== "video" || !it.videoId) { Sfx.play("bump"); return }
        Sfx.play("open")
        searchMode = false
        page.openItem(it)
    }

    // ── Select mode ──────────────────────────────────────────────────────
    // v (or ␣ on a row, or hold-⏎ ▸ SELECT SEVERAL) starts it: ⏎ / ␣ choose
    // rows, hold-⏎ (or the bar's ACTIONS) acts on what's chosen — queue, save,
    // remove, unsubscribe, hide — esc ends it. `sel`: a row's key -> the row.
    property bool selecting: false
    function selKey(it) { return it.videoId || it.uri || "" }
    function selCount() { return Object.keys(sel).length }
    function selItems() { return Object.keys(sel).map(k => sel[k]) }
    function chooseable(it) {
        return it && selKey(it).length > 0 && (it.kind === "video" || it.kind === "channel"
                                              || it.kind === "playlist")
    }
    function startSelecting() {
        if (selecting) return
        selecting = true
        railZone = "rows"
        Sfx.play("open")
    }
    function stopSelecting() {
        if (!selecting && selCount() === 0) return
        selecting = false
        sel = ({})
    }
    function toggleSel() {
        const it = YouTube.itemAt(list.currentIndex)
        if (!chooseable(it)) {
            Sfx.play("bump")
            return
        }
        selecting = true
        Sfx.play("select")
        let s = sel
        const k = selKey(it)
        if (s[k]) delete s[k]
        else s[k] = it
        sel = Object.assign({}, s)
        list.incrementCurrentIndex()
    }
    function chooseAll() {
        let s = ({})
        for (let i = 0; i < list.count; i++) {
            const it = YouTube.itemAt(i)
            if (chooseable(it)) s[selKey(it)] = it
        }
        sel = s
        selecting = true
        Sfx.play("select")
    }

    Connections {
        target: App
        enabled: yt.visible && !ctx.visible && !App.searchOpen
                 && !App.queueOpen && !App.outputOpen
        function onQueueAddRequested() {
            if (page.open) { const r = page.rowItem(); Queue.add(r); App.notify("QUEUED · " + r.title) }
            else yt.queueCurrent()
        }
        function onYoutubeSearchRequested() {
            if (page.open) page.close()
            Sfx.play("move", yt.tabPan(0))  // the remote's SEARCH: onto the SEARCH tab
            yt.searchMode = true
            searchInput.forceActiveFocus()
        }
    }
    function queueCurrent() {
        const it = YouTube.itemAt(list.currentIndex)
        if (it.kind === "video") {
            Sfx.play("select")
            Queue.add(it)
            App.notify("QUEUED · " + it.title)
        } else Sfx.play("bump")
    }

    // the chosen videos in the list's own order
    function chosenVideos() {
        let out = []
        for (let i = 0; i < list.count; i++) {
            const it = YouTube.itemAt(i)
            if (it.kind === "video" && sel[selKey(it)]) out.push(it)
        }
        return out
    }
    function queueSelected() {
        const vids = chosenVideos()
        if (vids.length === 0) { Sfx.play("bump"); return }
        Sfx.play("select")
        for (const v of vids) Queue.add(v)
        App.notify("QUEUED · " + vids.length + (vids.length === 1 ? " VIDEO" : " VIDEOS"))
        stopSelecting()
    }

    // hold-⏎ in select mode: what can be done to what's chosen, here
    property var batchConfirm: null      // {act, label} waiting on YES
    function openBatch() {
        const items = selItems()
        if (items.length === 0) {
            Sfx.play("bump")
            App.notify("NOTHING CHOSEN YET — ⏎ CHOOSES A ROW")
            return
        }
        Sfx.play("open")
        const vids = chosenVideos()
        const chans = items.filter(i => i.kind === "channel")
        const notifs = items.filter(i => i.hideToken)
        const local = YouTube.account.mode === "local"
        const inList = YouTube.currentPlaylist()
        const inWl = inList === "WL" || (YouTube.tab === "watchlater" && !YouTube.drilled)
        const here = !YouTube.drilled
        let acts = []
        if (vids.length > 0) {
            acts.push({label: "PLAY THEM", act: "b_play", hint: vids.length + " in order"})
            acts.push({label: "QUEUE THEM", act: "b_queue"})
            if (!inWl) acts.push({label: "ADD TO WATCH LATER", act: "b_wl"})
            acts.push({label: "ADD TO PLAYLIST…", act: "b_pl"})
            if (inWl) acts.push({label: "REMOVE FROM WATCH LATER", act: "b_wlrm", confirm: true})
            else if (inList === "LL" || inList === "liked")
                acts.push({label: "REMOVE FROM LIKED VIDEOS", act: "b_unlike", confirm: true})
            else if (inList.length > 0)
                acts.push({label: "REMOVE FROM THIS PLAYLIST", act: "b_plrm", confirm: true})
            if (local && YouTube.tab === "history" && here)
                acts.push({label: "REMOVE FROM HISTORY", act: "b_histrm", confirm: true})
            if (local && YouTube.tab === "rec" && here)
                acts.push({label: "NOT INTERESTED", act: "b_hide"})
        }
        if (chans.length > 0) {
            const followed = chans.filter(c => YouTube.isFollowing(c.uri)).length
            if (followed > 0)
                acts.push({label: "UNSUBSCRIBE", act: "b_unsub", hint: followed + (followed === 1 ? " channel" : " channels"),
                           confirm: true})
            if (followed < chans.length)
                acts.push({label: "SUBSCRIBE", act: "b_sub", hint: (chans.length - followed) + " more"})
        }
        if (notifs.length > 0)
            acts.push({label: "HIDE THESE NOTIFICATIONS", act: "b_nhide", confirm: true})
        acts.push({label: "CHOOSE ALL " + list.count, act: "b_all"})
        acts.push({label: "CLEAR THE CHOICE", act: "b_clear"})
        ctxMode = "batch"
        ctxActions = acts
        ctx.openMenu(items.length + " CHOSEN", acts)
    }
    function batchDo(a) {
        const items = selItems()
        const vids = chosenVideos()
        const n = vids.length
        switch (a.act) {
        case "b_play": playAllRows(vids, false); stopSelecting(); return
        case "b_queue": queueSelected(); return
        case "b_wl": YouTube.batch("wl_add", vids); return
        case "b_pl":
            batchForPicker = vids
            saveWithWl = false
            ctxItem = vids[0] || ({})
            App.notify("FETCHING PLAYLISTS…")
            YouTube.fetchPlaylists()
            return
        case "b_all": chooseAll(); return
        case "b_clear": sel = ({}); return
        }
        // the ones that take something away ask first
        if (a.confirm && !(batchConfirm && batchConfirm.act === a.act)) {
            batchConfirm = a
            ctxMode = "confirm"
            const what = a.act === "b_unsub" ? a.hint : items.length + (items.length === 1 ? " item" : " items")
            ctx.openMenu((a.label + " · " + what + "?").toUpperCase(),
                         [{label: "YES, " + a.label}, {label: "CANCEL"}])
            return
        }
        batchConfirm = null
        switch (a.act) {
        case "b_wlrm": YouTube.batch("wl_remove", vids); break
        case "b_unlike": YouTube.batch("unlike", vids); break
        case "b_plrm": YouTube.batch("pl_remove", vids, YouTube.currentPlaylist()); break
        case "b_histrm": YouTube.batch("history_remove", vids); break
        case "b_hide": YouTube.batch("hide", vids); break
        case "b_unsub": YouTube.batch("unsubscribe", items.filter(i => i.kind === "channel")); break
        case "b_sub": YouTube.batch("subscribe", items.filter(i => i.kind === "channel")); break
        case "b_nhide": YouTube.batch("notif_hide", items.filter(i => i.hideToken)); break
        }
    }
    // hold-⏎ on a comment on a video's page: LIKE, REPLY, its replies
    property var ctxComment: null
    function openCommentMenu(c) {
        ctxComment = c
        ctxMode = "comment"
        const acct = YouTube.account.mode === "account" && YouTube.account.state === "connected"
        let acts = []
        if (acct && c.likeAction)
            acts.push(c.liked ? {label: "UNLIKE", act: "unlike"} : {label: "LIKE", act: "like", hint: "▲ " + (c.likes || "0")})
        if (acct && c.replyParams) acts.push({label: "REPLY…", act: "reply"})
        if (c.repliesToken && !c.reply)
            acts.push({label: "REPLIES", act: "replies", hint: c.replies + ""})
        acts.push({label: "COPY THE WORDS", act: "copy"})
        ctxActions = acts
        ctx.openMenu(String(c.author || "COMMENT").toUpperCase(), acts)
    }

    // ADD TO PLAYLIST… from select mode: the picker's choice takes them all
    property var batchForPicker: null
    // a NEW PLAYLIST made from select mode: the first video made it, the
    // rest join once it exists
    property var batchForNew: null
    readonly property var batchWords: ({
        wl_add: "ADDED TO WATCH LATER", wl_remove: "REMOVED FROM WATCH LATER",
        pl_add: "ADDED TO THE PLAYLIST", pl_remove: "REMOVED FROM THE PLAYLIST",
        subscribe: "SUBSCRIBED", unsubscribe: "UNSUBSCRIBED", unlike: "REMOVED FROM LIKED VIDEOS",
        history_remove: "REMOVED FROM HISTORY", hide: "WON'T BE SUGGESTED",
        notif_hide: "NOTIFICATIONS HIDDEN" })

    function openCurrent() {
        if (list.count === 0) { emptyAction(); return }
        const it = YouTube.itemAt(list.currentIndex)
        // a video plays (select); a playlist or a channel drills in (open)
        Sfx.play(it.kind === "video" ? "select" : it.kind ? "open" : "bump")
        if (it.kind === "video")
            App.playItem(it)
        else
            YouTube.openItem(list.currentIndex)
    }

    // ⏎ on a list with nothing in it takes the way out its message names:
    // Settings ▸ YOUTUBE (connect, import, codec's own lists), or another try
    // once the browser is signed in again.
    readonly property string emptyHint: {
        const k = YouTube.errorKind
        if (k === "local" || k === "nobrowser"
                || (YouTube.error.length === 0 && YouTube.note.indexOf("SETTINGS") >= 0))
            return "⏎ SETTINGS ▸ YOUTUBE"
        if (k === "signedout" || k === "expired") return "⏎ TRY AGAIN"
        return ""
    }
    function emptyAction() {
        if (emptyHint.indexOf("SETTINGS") >= 0) {
            Sfx.play("open")
            App.openSection("settings:youtube")
        } else if (emptyHint.length > 0) {
            Sfx.play("select")
            YouTube.refreshAccount()
            YouTube.refresh()
        } else {
            Sfx.play("bump")
        }
    }

    // the channel a row belongs to, by name (its line's first part)
    function channelName(it) {
        return String(it.channel || (it.kind === "channel" ? it.title : "")
                      || (it.subtitle || "").split(" · ")[0] || "")
    }

    // ── Hold-Enter context menu ────────────────────────────────────────────
    property var ctxItem: ({})
    property var ctxActions: []
    property var ctxPlaylists: []
    property string ctxMode: "main" // main | playlists
    // the video page's SAVE: the playlist picker with WATCH LATER on top
    property bool saveWithWl: false
    property bool refreshOnRated: false
    function openSave(it) {
        ctxItem = it
        saveWithWl = true
        App.notify("FETCHING PLAYLISTS…")
        YouTube.fetchPlaylists()
    }

    Timer {
        id: holdTimer
        interval: 480
        // in select mode the hold acts on what's chosen
        onTriggered: yt.selecting ? yt.openBatch() : yt.openContext()
    }

    function openContext() { openContextFor(YouTube.itemAt(list.currentIndex), false) }
    // `fromPage`: the video page's MORE — the listing's own rows (remove from
    // this playlist, not interested here…) don't apply to it
    function openContextFor(it, fromPage) {
        if (!it || !it.uri)
            return
        Sfx.play("open")
        ctxItem = it
        ctxMode = "main"
        saveWithWl = false
        let acts = []
        const local = YouTube.account.mode === "local"
        const inList = fromPage ? "" : YouTube.currentPlaylist()
        const here = !fromPage && !YouTube.drilled
        const subAct = (it.channelUrl && it.channelUrl.length > 0)
            ? (YouTube.isFollowing(it.channelUrl)
               ? {label: "UNSUBSCRIBE", act: "unsub", hint: channelName(it)}
               : {label: "SUBSCRIBE", act: "sub", hint: channelName(it)})
            : null
        const inNotifs = !fromPage && YouTube.currentUrl() === "codec:notifications"
        if (it.kind === "video") {
            if (!fromPage)
                acts.push({label: "VIDEO PAGE", act: "page", hint: "i"})
            if (inNotifs && it.hideToken) {
                acts.push({label: "HIDE THIS NOTIFICATION", act: "nhide"})
                acts.push({label: "CLEAR ALL NOTIFICATIONS", act: "nclear", hint: "hides them on YouTube"})
            }
            acts.push({label: "PLAY NEXT", act: "next", hint: "queue front"})
            acts.push({label: "QUEUE", act: "queue"})
            if (it.channelUrl && it.channelUrl.length > 0)
                acts.push({label: "GO TO CHANNEL", act: "channel"})
            if (subAct) acts.push(subAct)
            if ((YouTube.tab === "watchlater" && here) || inList === "WL")
                acts.push({label: "REMOVE FROM WATCH LATER", act: "wlrm"})
            else
                acts.push({label: "ADD TO WATCH LATER", act: "wl"})
            acts.push({label: "ADD TO PLAYLIST…", act: "pl"})
            if (inList === "LL" || inList === "liked")
                acts.push({label: "REMOVE FROM LIKED VIDEOS", act: "unlike"})
            else if (inList.length > 0 && inList !== "WL")
                acts.push({label: "REMOVE FROM THIS PLAYLIST", act: "plrm"})
            // codec's own lists: what YouTube's account pages do there
            if (local && YouTube.tab === "rec" && here)
                acts.push({label: "NOT INTERESTED", act: "hide", hint: "never suggest it"})
            if (local && YouTube.tab === "history" && here)
                acts.push({label: "REMOVE FROM HISTORY", act: "histrm"})
            if (Cast.targetId === "" && Cast.deviceCount > 0)
                acts.push({label: "CAST TO…", act: "cast"})
            if (App.deviceRole !== "HUB")   // on the hub it's this machine's own queue
                acts.push({label: "SEND TO HUB QUEUE", act: "hub", hint: "other devices"})
            acts.push({label: "DOWNLOAD TO LIBRARY", act: "dl", hint: "offline copy"})
            acts.push({label: "COPY LINK", act: "copy"})
            if (!fromPage)
                acts.push({label: "SELECT SEVERAL", act: "select", hint: "v"})
        } else {
            acts.push({label: it.kind === "list" ? "OPEN" : "OPEN " + it.kind.toUpperCase(), act: "open"})
            if (it.kind === "channel" && subAct) acts.push(subAct)
            if (it.kind === "playlist")
                acts.push(YouTube.isPinned(it.uri)
                          ? {label: "UNPIN ITS TAB", act: "unpin"}
                          : {label: "PIN AS A TAB", act: "pin", hint: "beside PLAYLISTS"})
            if (it.uri === "codec:notifications" && YouTube.account.mode !== "local")
                acts.push({label: "CLEAR ALL NOTIFICATIONS", act: "nclear", hint: "hides them on YouTube"})
            if (it.uri.indexOf("codec:") !== 0)
                acts.push({label: "COPY LINK", act: "copy"})
            if (!fromPage && chooseable(it))
                acts.push({label: "SELECT SEVERAL", act: "select", hint: "v"})
        }
        ctxActions = acts
        // a row with no usable title (some feed entries arrive without one)
        // still names itself — by its channel line, else its kind
        const name = [it.title, it.subtitle, it.kind].find(t => t && String(t).trim().length > 0) || ""
        ctx.openMenu(String(name).toUpperCase(), acts)
    }

    function ctxDo(index) {
        Sfx.play("select")
        if (ctxMode === "filters") {
            const r = filterRows[index]
            if (!r) return
            if (r.g) {
                openFilterGroup(r.g)
            } else {
                YouTube.filters = ({})
                YouTube.reversed = false
                openFilters()
            }
            return
        }
        if (ctxMode === "filteropt") {
            const g = filterGroup
            if (!g || !g.opts[index]) return
            setFilter(g, g.opts[index][0])
            openFilters()
            return
        }
        if (ctxMode === "comment") {
            if (ctxActions[index] && ctxComment) page.commentAct(ctxActions[index].act, ctxComment)
            return
        }
        if (ctxMode === "batch") {
            if (ctxActions[index]) batchDo(ctxActions[index])
            return
        }
        if (ctxMode === "confirm") {
            if (index === 0 && batchConfirm) batchDo(batchConfirm)
            else batchConfirm = null
            return
        }
        if (ctxMode === "nclear") {
            if (index === 0) {
                App.notify("CLEARING NOTIFICATIONS…")
                YouTube.clearNotifications()
            }
            return
        }
        if (ctxMode === "playlists" && batchForPicker) {
            // select mode's ADD TO PLAYLIST…: the playlist takes them all
            const p = ctxPlaylists[index - 1]
            if (p) YouTube.batch("pl_add", batchForPicker, p.id)
            batchForPicker = null
            return
        }
        if (ctxMode === "playlists") {
            // SAVE's picker leads with WATCH LATER; then NEW PLAYLIST (typed)
            if (saveWithWl && index === 0) {
                YouTube.addToWatchLater(ctxItem.videoId, ctxItem.title, ctxItem)
                return
            }
            const p = ctxPlaylists[index - (saveWithWl ? 2 : 1)]
            if (p)
                YouTube.addToPlaylist(ctxItem.videoId, p.id, p.title, ctxItem)
            return
        }
        const a = ctxActions[index] ? ctxActions[index].act : ""
        switch (a) {
        case "page": openPage(ctxItem); break
        case "select":
            startSelecting()
            if (!sel[selKey(ctxItem)]) toggleSel()
            break
        case "nhide": YouTube.batch("notif_hide", [ctxItem]); break
        case "nclear":
            ctxMode = "nclear"
            ctx.openMenu("CLEAR ALL NOTIFICATIONS?",
                         [{label: "YES, CLEAR THEM", hint: "hides every one on YouTube"}, {label: "CANCEL"}])
            break
        case "pin":
            YouTube.pin(ctxItem.uri, ctxItem.title)
            App.notify("PINNED AS A TAB · " + pinLabel(ctxItem.title))
            break
        case "unpin":
            YouTube.unpin(ctxItem.uri)
            App.notify("UNPINNED · " + pinLabel(ctxItem.title))
            break
        case "unlike":
            refreshOnRated = true          // the list reloads once it's done
            YouTube.rate(ctxItem, "")
            App.notify("REMOVED FROM LIKED VIDEOS · " + ctxItem.title.toUpperCase())
            break
        case "next": Queue.addFront(ctxItem); App.notify("PLAYS NEXT · " + ctxItem.title); break
        case "queue": Queue.add(ctxItem); App.notify("QUEUED · " + ctxItem.title); break
        case "channel": YouTube.openUrl(ctxItem.channelUrl); break
        case "wl": YouTube.addToWatchLater(ctxItem.videoId, ctxItem.title, ctxItem); break
        case "wlrm": YouTube.removeFromWatchLater(ctxItem.videoId, ctxItem.title); break
        case "sub": YouTube.subscribe(ctxItem.channelUrl, channelName(ctxItem)); break
        case "unsub": YouTube.unsubscribe(ctxItem.channelUrl, channelName(ctxItem)); break
        case "plrm":
            YouTube.removeFromPlaylist(ctxItem.videoId, YouTube.currentPlaylist(), ctxItem.title)
            break
        case "hide": YouTube.notInterested(ctxItem); break
        case "histrm": YouTube.removeFromHistory(ctxItem); break
        case "pl":
            saveWithWl = false
            App.notify("FETCHING PLAYLISTS…")
            YouTube.fetchPlaylists()
            break
        case "cast": App.outputOpen = true; break
        case "hub": App.sendToHubQueue(ctxItem); break
        case "dl": App.ytDownload(ctxItem.videoId, ctxItem.title); break
        case "copy": App.copyText(ctxItem.uri); break
        case "open": YouTube.openItem(list.currentIndex); break
        }
    }

    Connections {
        target: YouTube
        function onActionDone(message) {
            App.notify(message)
            // A removal changes the listing we're looking at — refresh it.
            if ((message.indexOf("REMOVED FROM WATCH LATER") === 0
                    && YouTube.tab === "watchlater" && !YouTube.drilled)
                    || message.indexOf("REMOVED FROM THE PLAYLIST") === 0)
                YouTube.refresh()
        }
        function onActionFailed(message) { App.notify("YOUTUBE · " + message.toUpperCase()) }
        function onPageReply(kind, data) {
            if (kind === "all") {
                if (data.ok === false) App.notify("YOUTUBE · " + String(data.error || "couldn't read the list").toUpperCase())
                else yt.playAllRows(data.entries || [], data.shuffle === true)
            }
            if (kind === "batch") {
                if (data.ok === false) {
                    App.notify("YOUTUBE · " + String(data.error || "that didn't take").toUpperCase())
                    return
                }
                App.notify((yt.batchWords[data.action] || "DONE") + " · " + data.count)
                yt.stopSelecting()
                // what left this list: show it gone
                if (["wl_remove", "pl_remove", "unlike", "history_remove", "hide", "notif_hide"].indexOf(data.action) >= 0
                        || (data.action === "unsubscribe" && YouTube.currentUrl() === "codec:channels"))
                    YouTube.refresh()
            }
            if (kind === "notif_clear") {
                App.notify(data.ok === false ? "YOUTUBE · " + String(data.error || "couldn't clear them").toUpperCase()
                                             : "NOTIFICATIONS CLEARED · " + (data.hidden || 0))
                if (YouTube.currentUrl() === "codec:notifications" || YouTube.tab === "subs") YouTube.refresh()
            }
            if (kind === "rated" && yt.refreshOnRated) {
                yt.refreshOnRated = false
                YouTube.refresh()
            }
        }
        function onPlaylistCreated(playlistId, title) {
            if (yt.batchForNew && yt.batchForNew.length > 0)
                YouTube.batch("pl_add", yt.batchForNew, playlistId)
            yt.batchForNew = null
        }
        function onPlaylistsReady(playlists) {
            // Only meaningful mid-flow: the user just picked "add to playlist".
            if (!ctx.visible && yt.ctxItem.videoId) {
                yt.ctxPlaylists = playlists.filter(p => p.id !== "WL" && p.id !== "LL")
                yt.ctxMode = "playlists"
                ctx.openMenu((yt.saveWithWl ? "SAVE · " : "ADD TO PLAYLIST · ") + yt.ctxItem.title.toUpperCase(),
                             (yt.saveWithWl ? [{label: "WATCH LATER"}] : [])
                             .concat([{label: "NEW PLAYLIST…", input: true,
                                       placeholder: "NAME IT  ·  ⏎ MAKES IT  ·  ESC BACK"}])
                             .concat(yt.ctxPlaylists.map(p => ({label: p.title}))))
            }
        }
    }

    function back() {
        Sfx.play("back")
        if (YouTube.goBack())
            return
        App.goHome()
    }

    // UI sounds (Sfx): cued from the keys, the tilt wheel and the mouse only —
    // a page of rows arriving (a tab, a search, a channel) resets the list
    // silently. A rail step that couldn't go (an empty or one-row list) bumps.
    function sfxStep(was) { Sfx.play(list.currentIndex === was ? "bump" : "move") }
    // PgUp/PgDn: a screenful of rows, like the library's grid
    function page(d) {
        const was = list.currentIndex
        const row = list.currentItem ? list.currentItem.height + list.spacing : 0
        const rows = row > 0 ? Math.max(1, Math.floor(list.height / row)) : 8
        list.currentIndex = Math.max(0, Math.min(list.count - 1, list.currentIndex + d * rows))
        sfxStep(was)
    }
    // a tab's pan by where it sits in the strip: the SEARCH box (tabs[0]) is last
    function tabPan(i) {
        const n = tabs.length
        return ((i === 0 ? n - 1 : i - 1) / Math.max(1, n - 1) - 0.5) * 0.5
    }

    function cycleTab(dir) {
        // Typing in the search box counts as standing on the SEARCH tab, and
        // leaving it hands the keys back to the rail (tilt from the field used
        // to skip a tab and leave j/k typing into the box).
        const cur = searchMode ? 0 : Math.max(0, tabs.indexOf(YouTube.tab))
        const next = (cur + dir + tabs.length) % tabs.length
        Sfx.play("move", tabPan(next))
        if (tabs[next] === "search") {
            searchMode = true
            searchInput.forceActiveFocus()
        } else {
            searchMode = false
            takeFocus()
            YouTube.openTab(tabs[next])
        }
    }

    Keys.onReleased: (event) => {
        if (searchMode || event.isAutoRepeat || page.open || railZone === "header")
            return
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            // Quick tap = open (in select mode: choose); the hold already
            // opened the menu.
            if (holdTimer.running) {
                holdTimer.stop()
                if (selecting) toggleSel()
                else openCurrent()
            }
            event.accepted = true
        }
    }

    // The header's plates: ←/→ walk them, ⏎ acts, ↓ goes back to the rows.
    // Returns false for a key that isn't the header's (the rail handles it).
    function headerKey(event) {
        switch (event.key) {
        case Qt.Key_Left: case Qt.Key_H:
            if (headAct > 0) { headAct--; Sfx.play("move") } else Sfx.play("bump")
            return true
        case Qt.Key_Right: case Qt.Key_L:
            if (headAct < headerPlates.length - 1) { headAct++; Sfx.play("move") } else Sfx.play("bump")
            return true
        case Qt.Key_Down: case Qt.Key_J:
            railZone = "rows"
            Sfx.play("move")
            return true
        case Qt.Key_Up: case Qt.Key_K:
            Sfx.play("bump")
            return true
        case Qt.Key_Return: case Qt.Key_Enter:
            if (!event.isAutoRepeat && headerPlates[headAct]) headerDo(headerPlates[headAct].key)
            return true
        }
        return false
    }

    Keys.onPressed: (event) => {
        if (searchMode || page.open)
            return
        const was = list.currentIndex
        if (railZone === "header" && headerKey(event)) { event.accepted = true; return }
        switch (event.key) {
        case Qt.Key_Down: case Qt.Key_J: list.incrementCurrentIndex(); sfxStep(was); break
        case Qt.Key_Up: case Qt.Key_K:
            if (list.currentIndex <= 0 && headerPlates.length > 0) {
                railZone = "header"
                headAct = Math.min(headAct, headerPlates.length - 1)
                Sfx.play("move")
            } else { list.decrementCurrentIndex(); sfxStep(was) }
            break
        case Qt.Key_PageDown: page(1); break
        case Qt.Key_PageUp: page(-1); break
        case Qt.Key_Return: case Qt.Key_Enter:
            if (!event.isAutoRepeat)
                holdTimer.restart() // action fires on release; hold = menu
            break
        case Qt.Key_Escape:
            if (selecting || selCount() > 0) { Sfx.play("back"); stopSelecting() }
            else back()
            break
        case Qt.Key_V:
            if (selecting) { Sfx.play("back"); stopSelecting() }
            else startSelecting()
            break
        // D-pad Left/Right walk the tab rail (the "sections") — same as [ / ],
        // which a remote can't send. h/l are vim's ←/→ and only WALK, as in
        // Settings (l used to play the row and h to step back out — the author:
        // "navigation only"). Drill-in/back are OK/⏎ and Back/esc.
        // inside a channel they walk ITS tabs (VIDEOS · SHORTS · LIVE ·
        // PLAYLISTS); [ ] and the tilt still walk the strip's
        case Qt.Key_Left: case Qt.Key_H:
            if (YouTube.channelView !== "") stepChannelView(-1); else cycleTab(-1)
            break
        case Qt.Key_Right: case Qt.Key_L:
            if (YouTube.channelView !== "") stepChannelView(1); else cycleTab(1)
            break
        case Qt.Key_Space: toggleSel(); break
        case Qt.Key_A:
            if (event.modifiers & Qt.ShiftModifier) queueSelected()
            else queueCurrent()
            break
        case Qt.Key_Q: App.queueOpen = !App.queueOpen; break
        case Qt.Key_F: Sfx.play("open"); openFilters(); break
        case Qt.Key_I: openPage(YouTube.itemAt(list.currentIndex)); break
        case Qt.Key_F5: YouTube.refresh(); break
        case Qt.Key_C: App.outputOpen = true; break
        case Qt.Key_BracketLeft: cycleTab(-1); break
        case Qt.Key_BracketRight: cycleTab(1); break
        case Qt.Key_G:
            if (event.modifiers & Qt.ShiftModifier) {
                list.currentIndex = list.count - 1
                sfxStep(was)
            } else {
                const now = Date.now()
                if (now - lastG < 450) { list.currentIndex = 0; sfxStep(was) }
                lastG = now
            }
            break
        case Qt.Key_D:
            if (event.modifiers & Qt.ControlModifier) {
                list.currentIndex = Math.min(list.count - 1, list.currentIndex + 8)
                sfxStep(was)
            }
            else return
            break
        case Qt.Key_U:
            if (event.modifiers & Qt.ControlModifier) {
                list.currentIndex = Math.max(0, list.currentIndex - 8)
                sfxStep(was)
            }
            else return
            break
        case Qt.Key_Slash:
            Sfx.play("move", tabPan(0))     // onto the SEARCH tab (the box)
            searchMode = true
            searchInput.forceActiveFocus()
            break
        case Qt.Key_P: App.toPlayer(); break
        case Qt.Key_X: App.stopPlayback(); break
        default:
            return
        }
        event.accepted = true
    }

    // ── Frame geometry ────────────────────────────────────────────────────
    // Same two regions as the library: a rail of results and one plate of art.
    // The rail gets more here than there — a YouTube title is a sentence, and
    // a poster is not, so the reading column has to be wider than a sheet of
    // posters needs to be.
    readonly property real railW: Math.round(width * 0.50)
    // where the top strip has room for the tabs (set by Main; the fallbacks
    // are the strip's own inset for a view shown on its own)
    property real stripX: 200
    property real stripMidY: -20
    property real stripRight: width - 400
    readonly property bool onCrt: App.mode === "crt"
    // The rail's left gutter: 28, but on the CRT 8 — the tube's glass edge is
    // already a frame, and 28 more left a dead band beside the rows;
    // there the rows' visible edge lands level with CODEC in the strip.
    readonly property int gutter: onCrt ? 8 : 28
    readonly property real sheetW: railW - gutter - 28 // the gutter + 28 to the plate
    // The row plates' visible edge sits inside the column: the plate art has 3
    // transparent px and a near-black outline px at each end (at platePx). The search
    // box's LIGHT line ends on the rows' last bevel pixel (its own dark outline
    // overhangs, like the rows') — and the header rule ends with it (Main.qml).
    readonly property int rowEdgeIn: 4 * platePx
    readonly property real ruleW: sheetW - rowEdgeIn
    // where a tab label's HUD capital ink middle sits under its Text's top
    // (FontMetrics re-read once the MGS face loads)
    FontMetrics { id: tabFm; font.family: Theme.codecFont; font.pixelSize: 22 }
    FontMetrics { id: tabFm16; font.family: Theme.codecFont; font.pixelSize: 16 }
    function tabCapMid() { return capMid(tabFm) }
    function capMid(fm) {
        void fm.height
        const r = fm.tightBoundingRect("H")
        return fm.ascent + r.y + r.height / 2
    }

    // ── Art plate ─────────────────────────────────────────────────────────
    Item {
        id: plate
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: parent.width - yt.railW
        clip: true

        readonly property var cur: list.currentItem
        property string descVid: ""
        property string descText: ""

        // Fetch the description when the selection settles on a video.
        readonly property string curVid:
            cur && cur.kind === "video" ? cur.videoId : ""
        onCurVidChanged: descDebounce.restart()
        Timer {
            id: descDebounce
            interval: 350
            onTriggered: if (plate.curVid.length > 0 && plate.curVid !== plate.descVid)
                             YouTube.describe(plate.curVid)
        }
        Connections {
            target: YouTube
            function onDescribed(videoId, text) {
                // The worker answers concurrently now, so replies can arrive
                // out of order: a late reply for a row already left behind
                // must not replace the selected row's description.
                if (videoId !== plate.curVid)
                    return
                plate.descVid = videoId
                plate.descText = text
            }
        }

        // The still runs at its OWN aspect inside a drawn FRAME. Cropping a
        // 16:9 frame into a portrait plate would take a third of the picture
        // off both sides — on a thumbnail, which is composed to be read at a
        // glance, that is the part that carries the meaning — so the picture
        // fills the frame's window exactly: no crop at all.
        // The frame's OUTER edge sits level with the first row's plate (top)
        // and mirrors the rail's gutter: the rows stand 36 px in from the
        // screen's left, the frame 36 px in from its right (and 36 px past the
        // rows' visible edge on its left — the plate starts there).
        // EDIT (live, no bake): assets/mechui/plates/yt-thumb-frame.png —
        // The author's to draw. A hollow 9-slice, 32x32 art drawn at platePx (2x):
        // the outer 10 art px of each side are CORNERS (drawn 1:1), only the
        // runs between them stretch; the picture shows through the
        // transparent middle and starts `frameIn` art px in from the edge.
        // Grow the art? Keep it square-ish, update frameSlice / frameIn here.
        readonly property int frameSlice: 10   // corner size in art px (all four sides)
        readonly property int frameIn: 5       // art px from the outer edge to the picture
        Item {
            id: still
            readonly property int margin: yt.onCrt ? 16 : 36
            readonly property int inset: plate.frameIn * yt.platePx
            anchors.top: parent.top
            anchors.left: parent.left
            // whole art px: MechSlice floors to its px grid, and a remainder
            // would leave a sliver of picture past the frame's right edge
            width: Math.floor((parent.width - margin) / yt.platePx) * yt.platePx
            height: Math.round((width - 2 * inset) * 9 / 16 / yt.platePx) * yt.platePx + 2 * inset

            // The picture before: it holds the frame while the next one loads,
            // so moving down the rail never shows an empty frame — the next
            // fades in over it (art), and then takes its place here.
            Image {
                id: artBack
                anchors.fill: parent
                anchors.margins: still.inset
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                cache: true
                visible: art.settling || art.status === Image.Ready
            }
            Timer {
                id: artSettle
                interval: DS.slow
                onTriggered: artBack.source = art.source
            }
            Image {
                id: art
                anchors.fill: parent
                anchors.margins: still.inset
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                cache: true
                // Rung ladder, best first. The row thumbnails are 320px wide,
                // which is a blurred mess blown up to a 900px plate; maxres
                // exists for most uploads and hq for the rest, and YouTube
                // answers 404 rather than serving a placeholder, so falling
                // down the list on error lands on something real.
                property int rung: 0
                readonly property string vid: plate.cur ? plate.cur.videoId : ""
                // Keyed on the ITEM, not on the video id: a playlist or a
                // channel has no id at all, so watching `vid` alone left the
                // plate frozen on whatever loaded first while the selection
                // walked a whole page of playlists underneath it.
                readonly property var item: plate.cur
                function url(r) {
                    const c = plate.cur
                    if (!c) return ""
                    // A playlist row carries the PLAYLIST id in videoId ("LL"
                    // for Liked videos), so keying the ladder off a non-empty
                    // id alone asked ytimg for four thumbnails of a video that
                    // does not exist and 404'd all the way down. The ladder is
                    // for videos; everything else has only the art the search
                    // gave us. Rung 4 is that art, and it is also where a video
                    // lands when even mqdefault is missing.
                    if (c.kind !== "video" || c.videoId.length === 0 || r > 3)
                        return c.artUrl
                    const names = ["maxresdefault", "sddefault", "hqdefault", "mqdefault"]
                    return "https://i.ytimg.com/vi/" + c.videoId + "/" + names[r] + ".jpg"
                }
                onItemChanged: { rung = 0; source = url(0) }
                Component.onCompleted: source = url(0)
                onStatusChanged: {
                    if (status === Image.Error && rung <= 3) {
                        rung++
                        source = url(rung)
                    } else if (status === Image.Ready) {
                        artSettle.restart()
                    } else if (status !== Image.Loading) {
                        // a row with no picture: nothing of the last one to hold
                        artSettle.stop()
                        artBack.source = ""
                    }
                }
                // still on its way (a missing rung retries the next one)
                readonly property bool settling: status === Image.Loading
                                                 || (status === Image.Error && rung <= 3)
                // the frame and its picture land TOGETHER: the frame
                // waits for the first picture, then holds while the next loads
                // over the last; a row with no picture at all gets the frame
                // with its glyph once that's known
                readonly property bool landed: plate.cur !== null && (status === Image.Ready
                    || (settling && artBack.status === Image.Ready) || !settling)
                opacity: status === Image.Ready ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: DS.slow } }
            }

            Text {
                anchors.centerIn: parent
                visible: art.status !== Image.Ready && !art.settling
                text: plate.cur && plate.cur.kind === "playlist" ? "󰲸"
                      : (plate.cur && plate.cur.kind === "channel" ? "󰀄" : "󰗃")
                color: Theme.withAlpha(Theme.border, 0.6)
                font.family: Theme.monoFont
                font.pixelSize: 64
            }

            // Live badge, at plate scale, on the picture's foot (it lands
            // with the picture and its frame)
            Rectangle {
                visible: plate.cur ? plate.cur.isLive === true : false
                opacity: stillFrame.opacity
                anchors.left: art.left
                anchors.bottom: art.bottom
                anchors.leftMargin: 24
                anchors.bottomMargin: 24
                width: liveBig.width + 18
                height: 24
                radius: 3
                color: "#cc1f1f"
                MechStatus {
                    id: liveBig
                    anchors.centerIn: parent
                    label: "LIVE"; ink: "#ffffff"; px: Math.round(DS.tLabel * 2)
                }
            }

            // (The still used to dissolve into the rail and the page; framed,
            // it's the picture, whole.)
            MechSlice {
                id: stillFrame
                anchors.fill: parent
                opacity: art.landed ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: DS.slow } }
                source: "qrc:/assets/mechui/yt-thumb-frame.png"
                px: yt.platePx
                artL: plate.frameSlice; artR: plate.frameSlice
                artT: plate.frameSlice; artB: plate.frameSlice
            }
            // a click on the still opens the video's page (a playlist or a
            // channel drills in, as ⏎ does)
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    const it = YouTube.itemAt(list.currentIndex)
                    if (it.kind === "video") yt.openPage(it)
                    else yt.openCurrent()
                }
            }
        }

        // The CRT's 5:4 plate is far taller than a 16:9 still: under the still
        // and its few lines of text the column stood empty ("tons of
        // dead space"). The still's own colours carry on down the plate as an
        // ambient glow — a 32-px decode stretched over the plate IS the blur,
        // for free — under a scrim that keeps the text on near-black.
        Image {
            visible: yt.onCrt
            z: -1
            anchors.fill: parent
            source: visible ? art.source : ""
            sourceSize.width: 32
            fillMode: Image.PreserveAspectCrop
            smooth: true
            asynchronous: true
            opacity: status === Image.Ready ? 0.9 : 0
            Behavior on opacity { NumberAnimation { duration: DS.slow } }
        }
        Rectangle {
            visible: yt.onCrt
            z: -1
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0.0; color: Theme.withAlpha(Theme.bg, 0.40) }
                GradientStop { position: 0.45; color: Theme.withAlpha(Theme.bg, 0.66) }
                GradientStop { position: 1.0; color: Theme.withAlpha(Theme.bg, 0.86) }
            }
            // and it melts into the rail on the left, like the still does
            Rectangle {
                anchors.fill: parent
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: Theme.bg }
                    GradientStop { position: 0.14; color: Theme.withAlpha(Theme.bg, 0.30) }
                    GradientStop { position: 0.42; color: "transparent" }
                }
            }
        }

        // ── The selected result ───────────────────────────────────────────
        Column {
            id: plateInfo
            // the words stand under the PICTURE: level with its left edge
            // inside the frame (the 13% indent was for the old dissolve)
            anchors.left: parent.left
            anchors.leftMargin: still.inset
            anchors.right: parent.right
            anchors.rightMargin: still.margin + still.inset
            anchors.top: still.bottom
            anchors.topMargin: DS.s5
            anchors.bottomMargin: 40
            spacing: DS.s3
            opacity: plate.cur ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: DS.base } }

            property real yOff: 0
            transform: Translate { y: plateInfo.yOff }
            Connections {
                target: list
                function onCurrentIndexChanged() { deal.restart() }
            }
            NumberAnimation {
                id: deal
                target: plateInfo; property: "yOff"; from: 10; to: 0
                duration: DS.grand; easing.type: Easing.Bezier
                easing.bezierCurve: DS.enterCurve
            }

            Text {
                visible: plate.cur ? plate.cur.kind !== "video" : false
                text: plate.cur ? Theme.mgsSafe(plate.cur.kind.toUpperCase() + "   ·   ⏎ OPEN") : ""
                color: Theme.accent
                font.family: Theme.hudFont
                font.pixelSize: DS.tLabel * 2
                font.letterSpacing: DS.trackLabel * 2
            }

            Text {
                width: parent.width
                text: Theme.mgsSafe(plate.cur ? plate.cur.title : "")
                color: Theme.fg
                font.family: Theme.codecFont
                // the CRT's title is the plate's headline: the codec face at 32
                font.pixelSize: yt.onCrt ? 32 : DS.tHead
                lineHeight: yt.onCrt ? 1.15 : 1
                wrapMode: Text.Wrap
                maximumLineCount: 3
                elide: Text.ElideRight
            }

            Text {
                width: parent.width
                text: {
                    if (!plate.cur) return ""
                    let s = plate.cur.subtitle
                    if (plate.cur.published.length > 0)
                        s += "   ·   " + plate.cur.published.toUpperCase()
                    return Theme.mgsSafe(s)
                }
                color: Theme.dimFg
                font.family: Theme.hudFont
                font.pixelSize: yt.onCrt ? 32 : Math.round(DS.tMeta * 2)
                font.letterSpacing: 1
                maximumLineCount: 2
                wrapMode: Text.Wrap
                elide: Text.ElideRight
            }

            Text {
                visible: yt.selCount() > 0
                text: Theme.mgsSafe(yt.selCount() + " CHOSEN — HOLD ⏎ TO ACT ON THEM")
                color: Theme.accent
                font.family: Theme.hudFont
                font.pixelSize: Math.round(DS.tLabel * 2)
                font.letterSpacing: DS.trackLabel * 2
            }

            // Description. Bounded by what the plate has left rather than by a
            // guessed line count — a two-line title and a three-line title
            // leave different amounts of room, and the constant is always
            // wrong for one of them.
            Flickable {
                width: Math.min(parent.width, 660)
                height: Math.max(0, Math.min(descBody.height,
                                             plate.height - (still.height + DS.s5)
                                             - plateInfo.spacing * 4 - y - 46))
                visible: plate.curVid.length > 0
                         && plate.descVid === plate.curVid
                         && plate.descText.length > 0
                contentHeight: descBody.height
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                Text {
                    id: descBody
                    // Untrusted text: escaped FIRST, then only URLs and
                    // timestamps become anchors (yt.linkify) — no markup from
                    // the description itself ever reaches the renderer.
                    // RichText, not StyledText: StyledText always underlines a link
                    textFormat: Text.RichText
                    linkColor: Theme.accent
                    onLinkActivated: (link) => { Sfx.play("select"); yt.followLink(link) }
                    width: parent.width
                    // the MGS HUD face, like the library's plot (it carries the
                    // accents / dashes / quotes now; mgsSafe folds the rest BEFORE
                    // linkify escapes, so the anchors see the final text)
                    text: yt.linkify(Theme.mgsSafe(plate.descText), hoveredLink)
                    HoverHandler {
                        cursorShape: descBody.hoveredLink.length > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
                    }
                    color: Theme.withAlpha(Theme.fg, 0.75)
                    font.family: Theme.hudFont
                    font.pixelSize: 31
                    lineHeight: 1.32
                    wrapMode: Text.Wrap
                }
            }
        }
    }

    Column {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: yt.sheetW
        anchors.margins: 28
        anchors.leftMargin: yt.gutter
        // the first row's plate edge level with the still's top (the tabs went
        // up to the strip and left 20 px of air here — the author)
        anchors.topMargin: -3   // the plate's light line, not its transparent px
        spacing: 16

        // Where you are, when the tab alone doesn't say it: a channel or a
        // playlist drilled into, a search's query. (The top strip's crumb said
        // this; the strip carries the tabs now.)
        ShadowText {
            width: parent.width
            visible: YouTube.context.length > 0 && (YouTube.drilled || YouTube.tab === "search")
                     && !listHeader.visible
            text: Theme.mgsSafe((YouTube.tab === "search" && !YouTube.drilled
                                 ? "SEARCH" : yt.tabLabels[Math.max(0, yt.tabs.indexOf(YouTube.tab))])
                                + "  //  " + YouTube.context.toUpperCase())
            color: Theme.accent
            font.family: Theme.codecFont
            font.pixelSize: 16
            font.letterSpacing: 3
            elide: Text.ElideRight
        }

        YtListingHeader {
            id: listHeader
            width: parent.width
            height: implicitHeight
            header: YouTube.header
            view: YouTube.channelView
            plates: yt.headerPlates
            lit: yt.railZone === "header" ? yt.headAct : -1
            live: yt.visible
            platePx: yt.platePx
            onCrt: yt.onCrt
            onPlateClicked: (i) => { yt.railZone = "header"; yt.headAct = i; yt.headerDo(yt.headerPlates[i].key) }
            onViewClicked: (v) => {
                if (v === YouTube.channelView) return
                Sfx.play("move")
                YouTube.setChannelView(v)
                list.currentIndex = 0
            }
        }

        // ── Select mode's bar ───────────────────────────────────────────────
        // what's chosen, and the mouse's way to the same things the keys do
        Item {
            width: parent.width
            height: yt.selecting ? 44 : 0
            visible: yt.selecting
            Rectangle {
                anchors.fill: parent
                color: Theme.withAlpha(Theme.surfaceHi, 0.55)
                border.color: Theme.border
                border.width: 1
            }
            Row {
                x: 10
                anchors.verticalCenter: parent.verticalCenter
                spacing: 12
                IconPlate {
                    anchors.verticalCenter: parent.verticalCenter
                    icon: "check"; on: true; px: yt.platePx; live: false
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    // the CRT's narrow rail keeps the count only
                    text: (yt.onCrt ? "" : "SELECT  ·  ") + yt.selCount() + " CHOSEN"
                    color: Theme.fg
                    font.family: Theme.codecFont
                    font.pixelSize: 16
                    font.letterSpacing: 2
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !yt.onCrt
                    text: Theme.mgsSafe("⏎ CHOOSES   ·   HOLD ⏎ ACTS   ·   ESC DONE")
                    color: Theme.dimFg
                    font.family: Theme.hudFont
                    font.pixelSize: 16
                    font.letterSpacing: 1
                }
            }
            Row {
                anchors.right: parent.right
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8
                YtAction { kind: "icon"; icon: "plus"; label: "ALL"; labelPx: 16; live: yt.visible
                           onClicked: yt.chooseAll() }
                YtAction { kind: "icon"; icon: "menu"; label: yt.onCrt ? "ACT" : "ACTIONS"; labelPx: 16; live: yt.visible
                           onClicked: yt.openBatch() }
                YtAction { kind: "icon"; icon: "close"; label: "DONE"; labelPx: 16; live: yt.visible
                           onClicked: { Sfx.play("back"); yt.stopSelecting() } }
            }
        }

        // ── QUERYING strip ────────────────────────────────────────────────
        // Its own line under the header, never on top of the rows: centred in
        // the list it landed across whatever titles were there. A next-page
        // fetch shows only at the foot of the list.
        Item {
            width: parent.width
            height: 14
            visible: YouTube.loading && !YouTube.appending
            Text {
                id: qLbl
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "QUERYING"
                color: Theme.accent
                font.family: Theme.hudFont
                font.pixelSize: 16
                font.letterSpacing: 4
            }
            Item {
                anchors.left: qLbl.right
                anchors.leftMargin: 12
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                height: 2
                clip: true
                Rectangle { anchors.fill: parent; color: Theme.surfaceHi }
                Rectangle {
                    width: 64; height: 2
                    color: Theme.accent
                    SequentialAnimation on x {
                        running: YouTube.loading && !YouTube.appending
                        loops: Animation.Infinite
                        NumberAnimation { from: -64; to: Math.max(0, qLbl.parent.width - qLbl.width - 12); duration: 900; easing.type: Easing.InOutQuad }
                    }
                }
            }
        }

        // ── Result rail ───────────────────────────────────────────────────
        // No panel around it. The slab was there to separate the list from the
        // detail slab beside it; with the detail gone to the plate there is
        // nothing to separate it FROM, and a border drawn around a whole
        // region is just a box that costs 20px of reading width.
        Item {
            width: parent.width
            height: parent.height - y - hints.height

            ListView {
                id: list
                anchors.fill: parent
                    model: YouTube
                    // the Settings rows' fan-in (Cascade): a tab, a search, a
                    // channel — every new page of rows — and entering YouTube
                    property int cascadeRev: 0
                    property double cascadeAt: 0
                    function fanIn() { cascadeAt = Date.now(); cascadeRev++ }
                    Connections {
                        target: YouTube
                        function onModelReset() { list.fanIn() }
                    }
                    Connections {
                        target: yt
                        function onVisibleChanged() { if (yt.visible) list.fanIn() }
                    }
                    // A view built while its model is still empty keeps
                    // currentIndex at -1 and never advances on its own, so the
                    // first thing you saw was a page with nothing selected and an
                    // empty half-screen beside it. Claim row 0 the moment there
                    // is a row 0.
                    // Past the end too: Qt keeps the index across a model reset,
                    // so row 40 of HISTORY entered PLAYLISTS (12) on nothing —
                    // the plate blank, Enter dead (the library clamps the same way).
                    onCountChanged: if (count > 0 && (currentIndex < 0 || currentIndex >= count))
                                        currentIndex = 0
                    clip: true
                    // Scrolling feel. Keyboard / remote: the list starts moving
                    // two rows BEFORE the edge and glides (180 ms), so holding j
                    // flows instead of shoving one row per 90 ms at the bottom.
                    // Mouse: no range — hover selecting a row near the edge must
                    // never scroll the list out from under the cursor.
                    highlightRangeMode: App.pointerActive ? ListView.NoHighlightRange
                                                          : ListView.ApplyRange
                    preferredHighlightBegin: 2 * yt.rowH
                    preferredHighlightEnd: height - 2 * yt.rowH
                    highlightMoveDuration: 180
                    highlightResizeDuration: 0
                    // rows (and their thumbnails) are built a screen ahead, so
                    // they're there before you scroll to them instead of popping in
                    cacheBuffer: Math.max(0, 2 * height)   // height is <0 before layout
                    // NO wrap: these feeds go on (FOR YOU never ends) — at the
                    // last row while the next page was still on its way, j
                    // jumped back to row 0 and lost your place ("looping
                    // back up to the top"). The end bumps; gg is the way up.
                    keyNavigationWraps: false
                    // Infinite scroll: nearing the end pulls the next page.
                    onCurrentIndexChanged: {
                        if (count > 0 && currentIndex >= count - 15)
                            YouTube.fetchMore() // prefetch well before the
                                                // edge — fast j-scrolling
                                                // must never hit a wall
                    }
                    // The wheel scrolls without moving the selection, so the
                    // index trigger above never fired and the feed jammed at
                    // the end of what was loaded. Watch the scroll position too.
                    onContentYChanged: {
                        if (count > 0 && contentHeight > 0
                                && contentY + height > contentHeight - 15 * yt.rowH)
                            YouTube.fetchMore()
                    }
                    footer: Item {
                        width: list.width
                        height: YouTube.appending ? 40 : 0
                        Text {
                            anchors.centerIn: parent
                            visible: YouTube.appending
                            text: "LOADING MORE"
                            color: Theme.dimFg
                            font.family: Theme.hudFont
                            font.pixelSize: 16
                            font.letterSpacing: 4
                        }
                    }

                    // No sliding highlight: every row carries its own plate,
                    // exactly like the STATS rows (button family 3 at the
                    // integer pixel scale) — the selected row's plate rides the
                    // lit art and presses once, and its title hops.
                    // An invisible highlight still has a job: the ListView
                    // scrolls to keep the HIGHLIGHT in view, so without one
                    // j/k walked the selection straight off the screen.
                    highlight: Item {}

                    delegate: Item {
                        required property string title
                        required property string subtitle
                        required property string artUrl
                        required property string kind
                        required property string videoId
                        required property string published
                        required property bool isLive
                        required property bool isShort
                        required property string uri
                        required property int index
                        readonly property bool selected: yt.sel[videoId.length > 0 ? videoId : uri] !== undefined

                        width: list.width
                        height: yt.rowH

                        id: rowDel
                        // the Settings rows' fan: the plate fades where it is, the
                        // thumbnail and words rise into it
                        Cascade { id: fan; view: list }
                        opacity: fan.op
                        readonly property bool isCur: ListView.isCurrentItem
                        YtRow {
                            anchors.fill: parent
                            title: rowDel.title; subtitle: rowDel.subtitle
                            artUrl: rowDel.artUrl; kind: rowDel.kind
                            videoId: rowDel.videoId; published: rowDel.published
                            isLive: rowDel.isLive; isShort: rowDel.isShort; uri: rowDel.uri
                            isCur: rowDel.isCur && yt.railZone === "rows"
                            live: yt.visible
                            platePx: yt.platePx
                            storeRev: yt.storeRev
                            fanDy: fan.dy
                        }

                        // Select mode's ✓ — the pack's check button, pressed
                        // in once chosen; only while choosing (never as
                        // decoration on an ordinary row)
                        IconPlate {
                            anchors.right: parent.right
                            anchors.rightMargin: 18
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.verticalCenterOffset: -2
                            visible: (yt.selecting || selected) && kind !== "list"
                            icon: selected ? "check" : "blank"
                            on: selected
                            lit: rowDel.isCur && !selected
                            live: yt.visible
                            px: yt.platePx
                        }

                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            // Hover selects (scene-movement filtered so rows
                            // sliding under a parked cursor don't steal it);
                            // a click on the selected row opens — web idiom.
                            // pointerActive = keyboard was the last input →
                            // hover may not write (boundary-proof guard).
                            property point prevScene: Qt.point(-9999, -9999)
                            onExited: prevScene = Qt.point(-9999, -9999)
                            onPositionChanged: (mouse) => {
                                const p = mapToItem(null, mouse.x, mouse.y)
                                const moved = Math.abs(p.x - prevScene.x) > 2
                                              || Math.abs(p.y - prevScene.y) > 2
                                prevScene = Qt.point(p.x, p.y)
                                if (App.pointerActive && moved && !list.moving) {
                                    if (list.currentIndex !== index || yt.railZone !== "rows") Sfx.play("move")
                                    yt.railZone = "rows"
                                    list.currentIndex = index
                                }
                            }
                            onClicked: (mouse) => {
                                // select mode (or ctrl+click): a click chooses
                                if (yt.selecting || (mouse.modifiers & Qt.ControlModifier)) {
                                    list.currentIndex = index
                                    yt.railZone = "rows"
                                    yt.toggleSel()
                                    list.currentIndex = index
                                } else if (list.currentIndex === index) yt.openCurrent()
                                else { Sfx.play("move"); list.currentIndex = index }
                            }
                            onDoubleClicked: { if (!yt.selecting) { list.currentIndex = index; yt.openCurrent() } }
                        }
                    }

                    // An empty list says what would fill it (codec's own
                    // lists name it; otherwise, search), a failed one why —
                    // and either way what ⏎ does about it (emptyAction).
                    Column {
                        anchors.centerIn: parent
                        width: parent.width - 80
                        spacing: 14
                        visible: list.count === 0 && !YouTube.loading
                        Text {
                            width: parent.width
                            text: Theme.mgsSafe(YouTube.error.length > 0 ? "⚠ " + YouTube.error
                                                : YouTube.note.length > 0 ? YouTube.note
                                                : "press / to search youtube")
                            color: YouTube.error.length > 0 ? Theme.warning : Theme.dimFg
                            font.family: Theme.hudFont
                            font.pixelSize: YouTube.error.length > 0 ? 24 : 26
                            font.letterSpacing: YouTube.error.length > 0 ? 0 : 2
                            wrapMode: Text.Wrap
                            horizontalAlignment: Text.AlignHCenter
                        }
                        Text {
                            width: parent.width
                            visible: yt.emptyHint.length > 0
                            text: Theme.mgsSafe(yt.emptyHint)
                            color: Theme.accent
                            font.family: Theme.codecFont
                            font.pixelSize: 22
                            font.letterSpacing: 3
                            horizontalAlignment: Text.AlignHCenter
                        }
                    }
                }
            }

        // Hints. Bounded by the rail — unbounded it ran out over the plate.
        KeyHints {
            id: hints
            width: parent.width
            px: 13
            model: {
                // The CRT reads its legend at 24 px: the walk, the doors and ?
                // (the rest is in ? HELP and hold-⏎'s menu).
                if (yt.onCrt)
                    return [["j/k", "MOVE"], ["⏎", "PLAY"], ["/", "SEARCH"],
                            ["esc", "BACK"], ["?", "HELP"]]
                if (yt.selecting)
                    return [["j/k", "MOVE"], ["⏎ · ␣", "CHOOSE"], ["hold-⏎", "ACT ON THEM"],
                            ["A", "QUEUE THEM"], ["esc · v", "DONE"], ["?", "HELP"]]
                let m = [["j/k", "MOVE"], ["⏎", "PLAY"], ["i", "PAGE"], ["hold-⏎", "MENU"], ["v", "SELECT"],
                         ["a/A", "QUEUE"], ["q", "PANEL"], ["c", "OUTPUT"], ["h/l", "TABS"],
                         ["/", "SEARCH"], ["f", "FILTER"], ["esc", "BACK"]]
                if (Engine.path.length > 0 && !Engine.idle) m.push(["p", "PLAYER"], ["x", "STOP"])
                m.push(["?", "HELP"])
                return m
            }
        }
    }

    // The tabs, UP IN THE TOP STRIP where the crumb was. The rail
    // (half the screen) couldn't hold five hexagons and the search box on
    // the laptop or the CRT — they slid behind ◀ ▶; the strip runs the
    // width of the screen and is exactly a plate tall. Main places it
    // (stripX / stripMidY / stripRight: where the crumb began, the strip's
    // ink line, the right-hand readouts) and the rail gets the row back.
    // The tabs are hexagon plates (MechButton family 7) — the current tab
    // rides the lit art, presses once and its label hops when it becomes
    // current. SEARCH has no plate of its own: the search box IS that tab.
    Item {
        id: tabBar
        x: yt.stripX
        y: Math.round(yt.stripMidY - tabFace.faceMid)
        width: Math.max(0, yt.stripRight - yt.stripX)
        height: 40          // the tab plates; the search box is their face's height
        // the plate's dark face (the label's line) — read off a probe plate
        MechButton { id: tabFace; visible: false; family: 7; px: yt.platePx; width: 80; height: 40 }
        // Where the strip is short of the ~960 px the full-size bar takes (the
        // CRT's glass), the tabs go compact: labels at the codec face's 16-px
        // grid and slimmer padding — all five still fit, no arrows.
        readonly property bool compact: width < 960
        readonly property int labelPx: compact ? 16 : 22
        readonly property int basePad: compact ? 44 : 56
        // Where the strip is roomy (DP-3) the tabs LENGTHEN until the search
        // box ends on the rows' right edge — the bar as long as the rail it
        // switches ("could be longer there"). Never shorter than natural.
        FontMetrics { id: tabLblFm; font.family: Theme.codecFont; font.pixelSize: tabBar.labelPx; font.letterSpacing: 2 }
        readonly property real inkSum: {
            void tabLblFm.height
            let t = 0
            for (let i = 1; i < yt.tabLabels.length; i++) t += tabLblFm.tightBoundingRect(yt.tabLabels[i]).width
            return t
        }
        readonly property int nTabs: yt.tabLabels.length - 1
        readonly property real target: yt.gutter + yt.sheetW - (yt.rowEdgeIn - searchBox.texPx)
                                        - x - searchBox.idleWidth - 12
        readonly property real natural: inkSum + nTabs * basePad + (nTabs - 1) * 4
        readonly property int labelPad: basePad + Math.max(0, Math.floor((target - natural) / nTabs))

        // The tab hexagons SLIDE when they don't all fit beside the search
        // box — the CRT's 1280 px and a window cut HISTORY and FOR YOU off
        // entirely (WATCH LATER half under the box). The current tab is
        // always brought into view, ◂ ▸ show there is more, and a wheel or
        // a drag moves the strip. Wide screens: everything fits, no change.
        ListView {
            id: tabRow
            orientation: ListView.Horizontal
            spacing: 4
            anchors.left: parent.left
            // packed left, the search box right after them; only a window
            // too narrow for them all still slides them (◀ ▶)
            width: Math.max(0, Math.min(contentWidth, parent.width - searchBox.width - 12))
            anchors.top: parent.top
            height: 40
            clip: true
            interactive: contentWidth > width + 1
            boundsBehavior: Flickable.StopAtBounds
            cacheBuffer: 2000
            model: yt.tabs.length - 1
            readonly property int curIdx: yt.tabs.indexOf(YouTube.tab) - 1
            readonly property bool moreLeft: contentX > 2
            readonly property bool moreRight: contentX < contentWidth - width - 2
            property bool glide: false
            Behavior on contentX {
                enabled: tabRow.glide
                NumberAnimation { duration: 180; easing.type: Easing.OutQuad }
            }
            // bring the current tab fully into view (with a little air so
            // its neighbour's edge shows there is more beyond)
            function reveal(animated) {
                const it = itemAtIndex(curIdx)
                if (!it || contentWidth <= width)
                    return
                const air = 28
                let x = contentX
                if (it.x - air < contentX)
                    x = it.x - air
                else if (it.x + it.width + air > contentX + width)
                    x = it.x + it.width + air - width
                x = Math.max(0, Math.min(x, contentWidth - width))
                glide = animated
                contentX = x
                glide = false
            }
            onCurIdxChanged: Qt.callLater(reveal, true)
            onWidthChanged: Qt.callLater(reveal, false)
            onContentWidthChanged: Qt.callLater(reveal, false)
            function step(dir) {
                glide = true
                contentX = Math.max(0, Math.min(contentX + dir * width * 0.6,
                                                contentWidth - width))
                glide = false
            }
            delegate: Item {
                id: tabItem
                required property int index
                readonly property int ti: index + 1
                readonly property bool current: yt.tabs[ti] === YouTube.tab
                property bool hover: false
                property real hopY: 0
                // the hexagon's points take 20px a side; the label keeps clear of
                // them. An EVEN width: the plate floors to whole art px (2), and
                // an odd one lost its last column (uneven gaps between tabs).
                // The label's INK box (FontMetrics re-read once the face loads):
                // implicitWidth also carries the letterSpacing and side bearing
                // after the last letter, which pulled every label left.
                FontMetrics { id: tabInk; font: tabLbl.font }
                readonly property rect ink: (tabInk.height, tabInk.tightBoundingRect(tabLbl.text))
                width: 2 * Math.ceil((ink.width + tabBar.labelPad) / 2)
                height: 40
                // Same life as the rows (and STATS): the plate presses once
                // and the label dips with it — 6px, STATS's ~13% of a plate's
                // height on this 40px tab — then springs back; brightness and
                // label colour FADE over 200 ms instead of snapping.
                onCurrentChanged: if (current && yt.visible) { plateBtn.tap(); hop.restart() }
                SequentialAnimation {
                    id: hop
                    NumberAnimation { target: tabItem; property: "hopY"; to: DS.selDip(plateBtn.height); duration: 90; easing.type: Easing.OutQuad }
                    NumberAnimation { target: tabItem; property: "hopY"; to: 0; duration: 260; easing.type: Easing.OutBack }
                }
                // the hexagon plate: selecting a tab taps it (press frames
                // p0→p1→p2, the label hops with it); a mouse press holds it down.
                // Family 7 = the tabs' own copy of the HOME hexagon (4), so its
                // art can be recoloured alone — see tools/README.md.
                MechButton {
                    id: plateBtn
                    family: 7
                    px: yt.platePx
                    anchors.fill: parent
                    pressed: tabMouse.pressed
                    hot: tabItem.current || tabItem.hover
                    opacity: tabItem.current ? 1 : (tabItem.hover ? 0.9 : 0.55)
                    Behavior on opacity { NumberAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                }
                Text {
                    id: tabLbl
                    // centred on the letters' ink
                    x: Math.round(tabItem.width / 2 - (tabItem.ink.x + tabItem.ink.width / 2))
                    // centred on the plate's DARK FACE (the lighter foot is
                    // below it). The search box is sized to this face — same
                    // top, same centre — so it's also the SEARCH text's line.
                    y: Math.round(plateBtn.faceMid - (tabBar.compact ? yt.capMid(tabFm16) : yt.tabCapMid()))
                    text: yt.tabLabels[tabItem.ti]
                    color: tabItem.current ? Theme.accent : Theme.dimFg
                    Behavior on color { ColorAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                    // the codec face at the SEARCH label's size (16 compact)
                    font.family: Theme.codecFont
                    font.pixelSize: tabBar.labelPx
                    font.letterSpacing: 2
                    transform: Translate { y: tabItem.hopY }
                }
                MouseArea {
                    id: tabMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: tabItem.hover = true
                    onExited: tabItem.hover = false
                    onClicked: { Sfx.play("move", yt.tabPan(tabItem.ti)); YouTube.openTab(yt.tabs[tabItem.ti]) }
                }
            }

        }
        // ◀ ▶ — more tabs off this side; a click slides the strip
        Item {
            visible: tabRow.moreLeft
            anchors.left: tabRow.left
            anchors.top: tabRow.top
            width: 56
            height: 40
            // the cut tab dissolves into the page instead of ending on a hard edge
            Rectangle {
                anchors.fill: parent
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: Theme.bg }
                    GradientStop { position: 0.5; color: Theme.withAlpha(Theme.bg, 0.9) }
                    GradientStop { position: 1.0; color: "transparent" }
                }
            }
            Text {
                anchors.left: parent.left
                anchors.leftMargin: 2
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: -3   // the hexagon face, above its foot
                text: "◀"
                color: tabMoreL.containsMouse ? Theme.accent : Theme.fg
                font.family: Theme.hudFont
                font.pixelSize: 20
            }
            MouseArea {
                id: tabMoreL
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: tabRow.step(-1)
            }
        }
        Item {
            visible: tabRow.moreRight
            anchors.right: tabRow.right
            anchors.top: tabRow.top
            width: 56
            height: 40
            // the cut tab dissolves into the page instead of ending on a hard edge
            Rectangle {
                anchors.fill: parent
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 1.0; color: Theme.bg }
                    GradientStop { position: 0.5; color: Theme.withAlpha(Theme.bg, 0.9) }
                    GradientStop { position: 0.0; color: "transparent" }
                }
            }
            Text {
                anchors.right: parent.right
                anchors.rightMargin: 2
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: -3   // the hexagon face, above its foot
                text: "▶"
                color: tabMoreR.containsMouse ? Theme.accent : Theme.fg
                font.family: Theme.hudFont
                font.pixelSize: 20
            }
            MouseArea {
                id: tabMoreR
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: tabRow.step(1)
            }
        }

        SearchField {
            id: searchBox
            anchors.left: tabRow.right
            anchors.leftMargin: 12
            idlePx: tabBar.labelPx
            anchors.top: parent.top
            readonly property bool open: yt.searchMode || searchInput.text.length > 0
            // Idle it reads "SEARCH" like MOVIES/TV, collapsed to fit it; typing,
            // it opens into a field — top-aligned with the tabs (the box is
            // their hexagon face's height, so it shares their text line).
            width: open ? texPx * Math.round(Math.min(implicitWidth, parent.width * 0.52) / texPx)
                        : idleWidth
            Behavior on width {
                NumberAnimation { duration: DS.base; easing.type: Easing.Bezier
                                  easing.bezierCurve: DS.moveCurve }
            }
            lit: yt.searchMode || YouTube.tab === "search"
            idleShown: !open
            idleInk: YouTube.tab === "search" ? Theme.accent : Theme.dimFg

            MouseArea {
                anchors.fill: parent
                visible: !yt.searchMode
                cursorShape: Qt.PointingHandCursor
                onClicked: { Sfx.play("move", yt.tabPan(0)); yt.searchMode = true; searchInput.forceActiveFocus() }
            }

            TextInput {
                id: searchInput
                anchors.fill: parent
                anchors.leftMargin: searchBox.textX
                anchors.rightMargin: searchBox.textRight
                verticalAlignment: TextInput.AlignVCenter
                color: Theme.fg
                font.family: searchBox.typeFont
                font.pixelSize: searchBox.typePx
                clip: true
                visible: searchBox.open
                enabled: yt.searchMode
                // Losing focus any other way (a click on a row) must end
                // search mode too, or the rail ignores every key after.
                onActiveFocusChanged: if (!activeFocus) yt.searchMode = false
                // the query the box opened with — leaving by arrow runs only a
                // NEW one (an old query left in the box isn't re-searched)
                property string openedWith: ""
                onEnabledChanged: if (enabled) { openedWith = text; yt.suggestIdx = -1; YouTube.suggest(text) }
                onTextChanged: { yt.suggestIdx = -1; suggestTimer.restart() }
                Keys.onPressed: (event) => {
                    // the list under the box (suggestPanel): ↓ into it, ↑ back
                    // out of it, ⏎ searches the lit row, ⇧DEL forgets a recent one
                    const rows = yt.suggestRows
                    if (event.key === Qt.Key_Down && rows.length > 0 && yt.suggestIdx < rows.length - 1) {
                        yt.suggestIdx++
                        Sfx.play("move")
                        event.accepted = true
                        return
                    }
                    if (event.key === Qt.Key_Up && yt.suggestIdx >= 0) {
                        yt.suggestIdx--
                        Sfx.play("move")
                        event.accepted = true
                        return
                    }
                    if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && yt.suggestIdx >= 0) {
                        yt.pickSuggestion(yt.suggestIdx)
                        event.accepted = true
                        return
                    }
                    if (event.key === Qt.Key_Delete && (event.modifiers & Qt.ShiftModifier)
                            && yt.suggestIdx >= 0 && rows[yt.suggestIdx].recent) {
                        Sfx.play("back")
                        YouTube.forgetSearch(rows[yt.suggestIdx].text)
                        yt.suggestIdx = Math.min(yt.suggestIdx, rows.length - 2)
                        event.accepted = true
                        return
                    }
                    if (event.key === Qt.Key_Escape) {
                        Sfx.play("back")
                        yt.searchMode = false
                        yt.takeFocus()
                        event.accepted = true
                    } else if (text.length === 0 && (event.key === Qt.Key_Left
                                                     || event.key === Qt.Key_Right)) {
                        // The remote's D-pad sends the same arrows as a keyboard,
                        // and it can't type. An EMPTY box is the SEARCH tab, so
                        // sideways walks on to the next tab (cycleTab counts an
                        // open box as standing on SEARCH and hands the keys back) —
                        // just leaving put you back on the tab you came from, and
                        // the next press re-opened the box: open/close forever.
                        // With text, left/right move the cursor like any field.
                        yt.cycleTab(event.key === Qt.Key_Right ? 1 : -1)
                        event.accepted = true
                    } else if (event.key === Qt.Key_Up || event.key === Qt.Key_Down) {
                        // up/down always leave (a one-line field has no use for
                        // them). A query typed since the box opened runs, like Enter.
                        if (text.length > 0 && text !== openedWith) {
                            YouTube.search(text)
                            list.currentIndex = 0
                        }
                        // down onto the rail = a move; a new query running = a select
                        Sfx.play(text.length > 0 && text !== openedWith ? "select" : "move")
                        yt.searchMode = false
                        yt.takeFocus()
                        event.accepted = true
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        // ⏎ on an empty box runs nothing — it just leaves
                        Sfx.play(text.length > 0 ? "select" : "back")
                        if (text.length > 0)
                            YouTube.search(text)
                        yt.searchMode = false
                        yt.takeFocus()
                        list.currentIndex = 0
                        event.accepted = true
                    }
                }
            }
        }
    }


    // ── The search box's list ─────────────────────────────────────────
    // Empty, it offers RECENT searches; typing, YouTube's own suggestions
    // (after any recent ones that match). ↓ from the field walks into it (the
    // remote can't type — recent searches are its way to search again), ⏎
    // searches the lit row, ↑ off its top is the field again, ⇧DEL forgets
    // a recent one.
    property int suggestIdx: -1
    readonly property var suggestRows: {
        const q = searchInput.text.trim().toLowerCase()
        const rec = YouTube.recentSearches
        let rows = []
        if (q.length === 0) {
            for (const r of rec.slice(0, 8)) rows.push({ text: r, recent: true })
            return rows
        }
        for (const r of rec)
            if (rows.length < 3 && r.toLowerCase().indexOf(q) >= 0 && r.toLowerCase() !== q)
                rows.push({ text: r, recent: true })
        for (const g of YouTube.suggestions)
            if (rows.length < 9 && !rows.some(x => x.text.toLowerCase() === g.toLowerCase()))
                rows.push({ text: g, recent: false })
        return rows
    }
    Timer { id: suggestTimer; interval: 120; onTriggered: YouTube.suggest(searchInput.text) }
    function pickSuggestion(i) {
        const r = suggestRows[i]
        if (!r) return
        Sfx.play("select")
        searchInput.text = r.text
        YouTube.search(r.text)
        suggestIdx = -1
        searchMode = false
        takeFocus()
        list.currentIndex = 0
    }

    Item {
        id: suggestPanel
        visible: yt.searchMode && yt.suggestRows.length > 0
        x: tabBar.x + searchBox.x
        y: tabBar.y + searchBox.y + searchBox.height + 6
        width: Math.max(searchBox.width, 560)
        height: sugCol.height + 16
        z: 50
        Rectangle {
            anchors.fill: parent
            color: Theme.withAlpha(Theme.bg, 0.97)
            border.color: Theme.border
            border.width: 1
        }
        Column {
            id: sugCol
            x: 8; y: 8
            width: parent.width - 16
            Repeater {
                model: yt.suggestRows
                delegate: Item {
                    id: sg
                    required property var modelData
                    required property int index
                    readonly property bool lit: yt.suggestIdx === index
                    width: sugCol.width
                    height: 44
                    MechButton {
                        family: 3
                        px: yt.platePx
                        anchors.fill: parent
                        hot: sg.lit
                        visible: sg.lit
                    }
                    Text {
                        id: sgIcon
                        x: 16
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.verticalCenterOffset: -3
                        text: sg.modelData.recent ? "󰋚" : "󰍉"
                        color: sg.lit ? Theme.accent : Theme.dimFg
                        font.family: Theme.monoFont
                        font.pixelSize: 20
                    }
                    Text {
                        anchors.left: sgIcon.right
                        anchors.leftMargin: 14
                        anchors.right: parent.right
                        anchors.rightMargin: 16
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.verticalCenterOffset: -3
                        text: sg.modelData.text
                        color: sg.lit ? "#f2f7fa" : Theme.fg
                        opacity: sg.lit ? 1 : 0.75
                        font.family: searchBox.typeFont
                        font.pixelSize: searchBox.typePx
                        elide: Text.ElideRight
                    }
                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onEntered: yt.suggestIdx = sg.index
                        onClicked: yt.pickSuggestion(sg.index)
                    }
                }
            }
            Text {
                visible: yt.suggestIdx >= 0 && yt.suggestRows[yt.suggestIdx] !== undefined
                         && yt.suggestRows[yt.suggestIdx].recent === true
                width: parent.width
                horizontalAlignment: Text.AlignRight
                topPadding: 4
                rightPadding: 8
                text: "⇧DEL FORGETS IT"
                color: Theme.dimFg
                font.family: Theme.hudFont
                font.pixelSize: 16
                font.letterSpacing: 2
            }
        }
    }

    YouTubePage {
        id: page
        anchors.fill: parent
        yt: yt
    }

    ContextMenu {
        id: ctx
        anchors.fill: parent
        onPicked: (index) => yt.ctxDo(index)
        // NEW PLAYLIST… named: made with the video in it
        onTyped: (index, text) => {
            if (yt.ctxMode !== "playlists") return
            if (yt.batchForPicker) {
                // select mode: the first video makes it, the rest join it
                yt.batchForNew = yt.batchForPicker.slice(1)
                YouTube.createPlaylist(text, yt.batchForPicker[0])
                yt.batchForPicker = null
            } else YouTube.createPlaylist(text, yt.ctxItem)
        }
        onClosed: {
            // A pick that opened a submenu leaves the menu up — keep its keys.
            if (ctx.visible)
                return
            // Esc in a filter's option list steps back up to FILTERS (f shuts
            // the whole menu).
            if (yt.ctxMode === "filteropt" && !ctx.toggledShut) {
                yt.openFilters()
                return
            }
            yt.takeFocus()
        }
    }
}
