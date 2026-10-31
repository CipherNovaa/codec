import QtQuick

// Library browser. NORMAL mode = hjkl navigation; "/" enters SEARCH mode.
// TV section drills show -> episodes. Video keeps playing in the PiP dock.
FocusScope {
    id: lib

    // The menu's BONUS FEATURES: Main opens this title's detail page straight
    // onto its bonus page (the detail page is Main's, not ours).
    signal bonusRequested(string path)

    property bool searchMode: false
    property double lastG: 0
    // Multi-select: path -> true (space toggles; menu actions apply to all).
    property var sel: ({})

    function selCount() { return Object.keys(sel).length }

    function toggleSel() {
        const c = list.currentItem
        if (!c || c.kind === "show")
            return
        const p = MediaLibrary.pathAt(list.currentIndex)
        if (!p) return
        let s = sel
        if (s[p]) delete s[p]
        else s[p] = true
        sel = Object.assign({}, s)
        Sfx.play("select")   // the mark (the step on after it rides along)
        list.incrementCurrentIndex()
    }

    // C++ clears the query on its own (opening a show, switching section);
    // the box kept showing the old text over an unfiltered list, and retyping
    // the same text then fired nothing. Follow the library's query.
    Connections {
        target: MediaLibrary
        function onQueryChanged() {
            if (searchInput.text !== MediaLibrary.query)
                searchInput.text = MediaLibrary.query
        }
    }
    onVisibleChanged: if (visible) { forceActiveFocus(); ensureSelection() }
    // On-demand Loader: created already visible, so visible never CHANGES on
    // the first visit — run the entry here too (the STATS fix).
    Component.onCompleted: if (visible) { forceActiveFocus(); ensureSelection() }
    // A valid selection or none at all: -1 (a view built on an empty model) and
    // PAST THE END both leave nothing lit and the d-pad dead — Up/Left/OK do
    // nothing and only a mouse hover revived it. Past-the-end was the common one:
    // the index is shared across sections and Qt doesn't clamp it on a model
    // reset, so leaving MOVIES on title 28 entered TV SHOWS (14) on "28".
    function ensureSelection() {
        if (list.count > 0 && (list.currentIndex < 0 || list.currentIndex >= list.count))
            list.currentIndex = 0
        stepOffHeading(true)
    }
    // A season heading (an opened show) is never the selection: step on past it
    // in the direction of travel, or back off the end. Called on every index
    // change AND after resets — opening a show re-sets row 0, which is a heading,
    // and an unchanged index fires no change signal.
    function stepOffHeading(down) {
        if (!epMode || list.currentIndex < 0
                || MediaLibrary.kindAt(list.currentIndex) !== "season")
            return false
        let n = list.currentIndex + (down ? 1 : -1)
        if (n < 0 || n >= list.count) n = list.currentIndex + (down ? -1 : 1)
        if (n < 0 || n >= list.count) return false
        list.currentIndex = n
        return true
    }

    // ── UI sounds (Sfx) ───────────────────────────────────────────────────
    // Cued where the hand acts — the walk below (keys, the tilt wheel, the
    // remote's d-pad), ⏎, esc, the pointer — never off the index itself: a
    // reset, a new section, or the filter re-running as you type re-seat it
    // in silence. The pointer ticks only while the grid has the floor.
    readonly property bool sfxFloor: visible && App.detailUri === "" && !App.searchOpen
                                     && !App.queueOpen && !App.outputOpen && !ctx.visible
    // the selection's column as a gentle pan (a one-column list sits centre)
    function sfxPan() {
        return lib.cols > 1 ? ((list.currentIndex % lib.cols) / (lib.cols - 1) - 0.5) * 0.5 : 0
    }
    // a step: `move` when the selection went somewhere, `bump` at an edge (a
    // season heading it stepped onto and back off counts as nowhere)
    function sfxStep(was) { Sfx.play(list.currentIndex === was ? "bump" : "move", sfxPan()) }

    // A new section starts at its first title — an index carried over from the
    // other section never pointed at anything meaningful.
    Connections {
        target: MediaLibrary
        function onSectionChanged() { list.currentIndex = 0; lib.ensureSelection() }
        function onModelReset() { Qt.callLater(lib.ensureSelection) }
    }

    // ── Sheet movement ────────────────────────────────────────────────────
    // Written out rather than using GridView's own move* calls so a partial
    // bottom row still reaches its last tile: moveCurrentIndexDown() refuses
    // to move at all when the cell below is empty, which strands the final
    // one-to-four films in a 446-item library where j simply stops working.
    function rowDown() {
        const was = list.currentIndex
        const n = list.currentIndex + lib.cols
        if (n < list.count) list.currentIndex = n
        else if (list.currentIndex < list.count - 1) list.currentIndex = list.count - 1
        sfxStep(was)
    }
    function rowUp() {
        const was = list.currentIndex
        const n = list.currentIndex - lib.cols
        if (n >= 0) list.currentIndex = n
        sfxStep(was)
    }
    // Tilt wheel = Left/Right (detected app-wide in AppController::eventFilter,
    // discrete clicks only — trackball ball-scroll never counts as a tilt).
    Connections {
        target: App
        enabled: lib.visible && App.detailUri === "" && !App.searchOpen
                 && !App.queueOpen && !App.outputOpen && !ctx.visible
        function onTiltStep(dir) { lib.sideStep(dir) }
    }
    // Remote: REC / return = add the selection to the queue; TRAILER spare =
    // its trailer — the a / t keys' jobs, for a remote that can't type them.
    Connections {
        target: App
        enabled: lib.visible && App.detailUri === "" && !App.searchOpen
                 && !App.queueOpen && !App.outputOpen && !ctx.visible
        function onQueueAddRequested() {
            const it = lib.currentItemMap()
            if (it.uri) { Queue.add(it); Sfx.play("select"); App.notify("QUEUED · " + it.title) }
            else Sfx.play("bump")
        }
        function onTrailerRequested() {
            const c = list.currentItem
            if (c && c.kind === "movie") App.playTrailer(c.title, c.subtitle)
            else App.notify("NO TRAILER FOR THIS ONE")
        }
    }
    function sideStep(d) {
        const was = list.currentIndex
        const n = list.currentIndex + d
        if (n >= 0 && n < list.count) list.currentIndex = n
        sfxStep(was)
    }
    function page(d) {
        const was = list.currentIndex
        const rows = Math.max(1, Math.floor(list.height / Math.max(1, list.cellHeight)))
        const n = list.currentIndex + d * rows * lib.cols
        list.currentIndex = Math.max(0, Math.min(list.count - 1, n))
        sfxStep(was)
    }

    // ⏎ / click / wheel-click / the remote's OK on a card. A film opens its
    // INFO page (Enter there plays) — the info page is a film's default
    // selection, not straight to play (the author, 2026-10-07; hold-⏎ ▸ PLAY still
    // plays directly). TV keeps its flow: a show drills into its episodes and
    // an episode plays.
    function openCurrent() {
        const kind = MediaLibrary.kindAt(list.currentIndex)
        const path = MediaLibrary.pathAt(list.currentIndex)
        if (kind === "show") {
            Sfx.play("open")   // down a level, into its episodes
            MediaLibrary.showFilter = MediaLibrary.titleAt(list.currentIndex)
            list.currentIndex = 0
        } else if (kind === "movie" && !epMode) {
            if (path.length > 0) { Sfx.play("open"); App.detailUri = path }
        } else if (path.length > 0) {   // an episode — or a film the guide places
            Sfx.play("select")
            App.play(path)
        }
    }

    // Current row as a MediaItem-shaped map (for the queue).
    function currentItemMap() {
        const c = list.currentItem
        if (!c || c.kind === "show")
            return {}
        return {
            uri: MediaLibrary.pathAt(list.currentIndex),
            title: c.kind === "episode" ? c.show + "  " + c.title
                   : c.title.replace(/^FILM · /, ""),   // a film the guide places
            subtitle: c.subtitle,
            artUrl: c.poster.length > 0 ? Theme.art(c.poster) : "",
            durationS: c.runtimeMin * 60,
            kind: c.kind,
            sourceId: "library",
        }
    }

    function back() {
        Sfx.play("back")   // every rung below does something: query, show, home
        if (MediaLibrary.query.length > 0) {
            MediaLibrary.query = ""
            searchInput.text = ""
        } else if (MediaLibrary.showFilter.length > 0) {
            MediaLibrary.showFilter = ""
            list.currentIndex = 0
        } else {
            App.goHome()
        }
    }

    // ── Hold-Enter context menu (also reused as the genre picker) ─────────
    property var ctxItem: ({})
    property var ctxActions: []
    property var ctxGenres: []
    property var ctxFilterRows: []  // the (f) FILTER menu rows (formats + genres)
    property string ctxMode: "item" // item | filter | confirmDelete

    function cycleSort() {
        const order = ["title", "rating", "year"]
        const next = order[(order.indexOf(MediaLibrary.sortMode) + 1) % order.length]
        MediaLibrary.sortMode = next
        list.currentIndex = 0
        App.notify("SORT ▸ " + next.toUpperCase())
    }

    // ── The show's viewing guide (Library: guideMode / guideInfo) ──
    // Andrew Carl's X-Files roadmap: m cuts the show to the episodes it calls
    // part of the story (MYTH) and the TOP-tier monsters of the week (MYTH +
    // TOP) and back, f lists it, and the chain follows. Inside the cut each
    // row's mark stands where its resolution was.
    readonly property var guide: (MediaLibrary.totalCount, epMode && MediaLibrary.hasGuide
                                  ? MediaLibrary.guideInfo(MediaLibrary.showFilter) : ({}))
    readonly property bool hasGuide: guide.modes !== undefined
    readonly property var verdictWord: ({ story: "MYTH", top: "TOP" })
    function guideLabel(mode) {
        for (const m of (guide.modes || []))
            if (m.mode === mode) return m.label
        return ""
    }
    // The first row whose title has `t` (the shot harness's SEL) or whose
    // path is `p`; false when none.
    function selectRow(t, p) {
        // the model's count, not the view's (it lags a reset)
        for (let i = 0; i < MediaLibrary.rowCount(); i++)
            if ((p && MediaLibrary.pathAt(i) === p)
                    || (t && MediaLibrary.titleAt(i).indexOf(t) >= 0)) {
                list.currentIndex = i
                return true
            }
        return false
    }
    // Change cut, keeping the selected episode when the new cut has it.
    function setGuideMode(mode) {
        const keep = MediaLibrary.pathAt(list.currentIndex)
        MediaLibrary.guideMode = mode
        if (!keep || !selectRow("", keep))
            list.currentIndex = 0
        ensureSelection()
        const m = (guide.modes || []).find(x => x.mode === mode)
        App.notify(m ? m.label + " · " + m.count : "")
    }
    function cycleGuide() {
        const modes = (guide.modes || []).map(m => m.mode)
        if (modes.length === 0) return
        setGuideMode(modes[(modes.indexOf(MediaLibrary.guideMode) + 1) % modes.length])
    }

    function fmtLabel(f) { return f === "DV" ? "DOLBY VISION" : f === "EXTRAS" ? "HAS EXTRAS" : f }

    // The (f) FILTER menu — one place, two groups: FORMAT facets (DV/HDR10/4K/
    // ATMOS, only those present) and GENRE. A pick narrows the wall to that facet;
    // format + genre compose (e.g. Dolby Vision AND Action). ALL clears both.
    function openFilterPicker() {
        ctxMode = "filter"
        const formats = MediaLibrary.availableFormats()
        const genres = MediaLibrary.allGenres()
        const none = MediaLibrary.genreFilter.length === 0
                     && MediaLibrary.flagFilter.length === 0
        let rows = []
        // an opened show with a guide: its cuts lead the menu
        if (hasGuide) {
            rows.push({header: true, label: guide.short + " · " + guide.author.toUpperCase()})
            for (const m of guide.modes)
                rows.push({label: m.label, kind: "guide", value: m.mode,
                           hint: MediaLibrary.guideMode === m.mode ? "● " + m.count : String(m.count)})
            rows.push({header: true, label: "FILES"})
        }
        rows.push({label: "ALL", kind: "all", hint: none ? "● active" : "clear"})
        // EXTRAS rides the same facet (one at a time, composes with genre) but
        // is about the title, not the file — so it gets its own heading.
        const files = formats.filter(f => f !== "EXTRAS")
        if (files.length > 0) {
            rows.push({header: true, label: "FORMAT"})
            for (const f of files)
                rows.push({label: fmtLabel(f), kind: "format", value: f,
                           hint: MediaLibrary.flagFilter === f ? "● active" : ""})
        }
        if (formats.indexOf("EXTRAS") >= 0) {
            rows.push({header: true, label: "BONUS FEATURES"})
            rows.push({label: fmtLabel("EXTRAS"), kind: "format", value: "EXTRAS",
                       hint: MediaLibrary.flagFilter === "EXTRAS" ? "● active" : ""})
        }
        if (genres.length > 0) {
            rows.push({header: true, label: "GENRE"})
            for (const g of genres)
                rows.push({label: g.toUpperCase(), kind: "genre", value: g,
                           hint: MediaLibrary.genreFilter === g ? "● active" : ""})
        }
        ctxFilterRows = rows
        Sfx.play("open")
        ctx.openMenu("FILTER", rows, Qt.Key_F)   // f again shuts it, like c and the display picker
    }

    Timer {
        id: holdTimer
        interval: 480
        onTriggered: lib.openContext()
    }

    function openContext() {
        const c = list.currentItem
        if (!c)
            return
        Sfx.play("open")
        ctxMode = "item"
        let acts = []
        // Selection menu: actions fan out over everything space-marked.
        if (selCount() > 0) {
            const n = selCount()
            acts.push({label: "MARK " + n + " WATCHED", act: "selWatched"})
            acts.push({label: "MARK " + n + " UNWATCHED", act: "selUnwatched"})
            acts.push({label: "QUEUE " + n, act: "selQueue"})
            acts.push({label: "CLEAR SELECTION", act: "selClear"})
            ctxActions = acts
            ctx.openMenu(n + " SELECTED", acts)
            return
        }
        // Whole-show menu ("imported it, already watched 3 seasons").
        if (c.kind === "show") {
            ctxItem = {title: c.title, show: c.title, uri: c.path}
            if (c.extrasCount > 0)
                acts.push({label: "BONUS FEATURES", act: "bonus", hint: String(c.extrasCount)})
            acts.push({label: "MARK ENTIRE SHOW WATCHED", act: "showWatched"})
            acts.push({label: "MARK ENTIRE SHOW UNWATCHED", act: "showUnwatched"})
            ctxActions = acts
            ctx.openMenu(c.title.toUpperCase(), acts)
            return
        }
        ctxItem = currentItemMap()
        const watched = c.completed
        if (c.kind === "movie")   // Enter opens a film's info page; this skips it
            acts.push({label: "PLAY", act: "play", hint: "skip the info page"})
        acts.push({label: "PLAY NEXT", act: "next", hint: "queue front"})
        acts.push({label: "QUEUE", act: "queue"})
        if (c.kind === "movie")
            acts.push({label: "PLAY TRAILER", act: "trailer"})
        if (c.extrasCount > 0)
            acts.push({label: "BONUS FEATURES", act: "bonus", hint: String(c.extrasCount)})
        acts.push({label: watched ? "MARK UNWATCHED" : "MARK WATCHED",
                   act: watched ? "unwatched" : "watched"})
        if (c.kind === "episode" && MediaLibrary.showFilter.length > 0)
            acts.push({label: "MARK WATCHED UP TO HERE", act: "watchedUpTo",
                       hint: "this + all before"})
        if (Cast.deviceCount > 0)
            acts.push({label: "CAST TO…", act: "cast"})
        // the hub's queue is THIS machine's: sending to it means nothing here
        if (App.deviceRole !== "HUB")
            acts.push({label: "SEND TO HUB QUEUE", act: "hub", hint: "other devices"})
        acts.push({label: "COPY PATH", act: "copy"})
        // Local files only — a manifest satellite can't delete the hub's media.
        if ((c.kind === "movie" || c.kind === "episode")
                && ctxItem.uri && ctxItem.uri.charAt(0) === "/")
            acts.push({label: "DELETE FILE", act: "delete", hint: "from disk"})
        ctxActions = acts
        ctx.openMenu(ctxItem.title.toUpperCase(), acts)
    }

    // Destructive, so it never fires on the first pick: DELETE FILE re-opens the
    // menu asking to confirm. A stray hold-⏎ can't wipe a movie.
    function confirmDelete() {
        ctxMode = "confirmDelete"
        Sfx.play("open")
        ctxActions = [{label: "DELETE — CANNOT BE UNDONE", act: "delYes", hint: "permanent"},
                      {label: "CANCEL", act: "delNo"}]
        ctx.openMenu("DELETE " + ctxItem.title.toUpperCase() + "?", ctxActions)
    }

    function ctxDo(index) {
        Sfx.play("select")   // a pick (the menu never picks a heading)
        if (ctxMode === "filter") {
            const r = ctxFilterRows[index]
            if (!r || r.header) return
            if (r.kind === "guide") {
                setGuideMode(r.value)
                return
            }
            if (r.kind === "all") {
                MediaLibrary.genreFilter = ""
                MediaLibrary.flagFilter = ""
                App.notify("FILTER ▸ ALL")
            } else if (r.kind === "format") {
                MediaLibrary.flagFilter = r.value
                App.notify("FILTER ▸ " + fmtLabel(r.value))
            } else if (r.kind === "genre") {
                MediaLibrary.genreFilter = r.value
                App.notify("FILTER ▸ " + r.value.toUpperCase())
            }
            list.currentIndex = 0
            return
        }
        if (ctxMode === "confirmDelete") {
            ctxMode = "item"
            const yes = ctxActions[index] && ctxActions[index].act === "delYes"
            if (yes) App.deleteMedia(ctxItem.uri)
            return
        }
        const a = ctxActions[index] ? ctxActions[index].act : ""
        switch (a) {
        case "selWatched": App.setWatchedMany(Object.keys(sel), true); sel = ({}); break
        case "selUnwatched": App.setWatchedMany(Object.keys(sel), false); sel = ({}); break
        case "selQueue": {
            let n = 0
            for (const p of Object.keys(sel)) { Queue.add({uri: p, title: p.split("/").pop()}); n++ }
            sel = ({})
            App.notify("QUEUED · " + n + " ITEMS")
            break
        }
        case "selClear": sel = ({}); break
        case "showWatched": App.setWatchedMany(MediaLibrary.episodePaths(ctxItem.show), true); break
        case "showUnwatched": App.setWatchedMany(MediaLibrary.episodePaths(ctxItem.show), false); break
        case "watchedUpTo": {
            let paths = []
            for (let i = 0; i <= list.currentIndex; i++)
                if (MediaLibrary.kindAt(i) === "episode")
                    paths.push(MediaLibrary.pathAt(i))
            App.setWatchedMany(paths, true)
            break
        }
        case "play": App.play(ctxItem.uri); break
        case "next": Queue.addFront(ctxItem); App.notify("PLAYS NEXT · " + ctxItem.title); break
        case "queue": Queue.add(ctxItem); App.notify("QUEUED · " + ctxItem.title); break
        case "trailer": App.playTrailer(list.currentItem.title, list.currentItem.subtitle); break
        case "bonus": lib.bonusRequested(ctxItem.uri); break
        case "watched": App.setWatched(ctxItem.uri, true); break
        case "unwatched": App.setWatched(ctxItem.uri, false); break
        case "cast": App.outputOpen = true; break
        case "hub": App.sendToHubQueue(ctxItem); break
        case "copy": App.copyText(ctxItem.uri); break
        case "delete": Qt.callLater(confirmDelete); break // re-open to confirm
        }
    }

    Keys.onReleased: (event) => {
        if (searchMode || event.isAutoRepeat)
            return
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (holdTimer.running) {
                holdTimer.stop()
                openCurrent()
            }
            event.accepted = true
        }
    }

    Keys.onPressed: (event) => {
        if (searchMode)
            return // the input has focus; scope only sees what it ignores
        switch (event.key) {
        // j/k step a ROW, h/l step a COLUMN. Rotating a list is exactly where
        // the last pass shipped three bugs at once: only the arrow keys got
        // fixed and the LETTER keys kept the vertical-list meaning, so `l`
        // still confirmed on something you were supposed to walk sideways.
        case Qt.Key_Down: case Qt.Key_J: rowDown(); break
        case Qt.Key_Up: case Qt.Key_K: rowUp(); break
        case Qt.Key_Right: sideStep(1); break
        case Qt.Key_Left: sideStep(-1); break
        case Qt.Key_Return: case Qt.Key_Enter:
            if (!event.isAutoRepeat)
                holdTimer.restart() // tap = open on release, hold = menu
            break
        // h/l are vim's ←/→ and only WALK — never open, play or leave, as in
        // Settings (in a show's episode list l used to PLAY the episode and h
        // to back out; "navigation only"). ⏎ opens, esc goes back.
        case Qt.Key_L: sideStep(1); break
        case Qt.Key_I: {
            const p = MediaLibrary.pathAt(list.currentIndex)
            if (p.length > 0) {
                Sfx.play("open")
                App.detailUri = p
            }
            break
        }
        case Qt.Key_H: sideStep(-1); break
        case Qt.Key_Escape: back(); break
        case Qt.Key_G:
            if (event.modifiers & Qt.ShiftModifier) {
                const was = list.currentIndex
                list.currentIndex = list.count - 1
                sfxStep(was)
            } else {
                const now = Date.now()
                if (now - lastG < 450) { const was = list.currentIndex; list.currentIndex = 0; sfxStep(was) }
                lastG = now
            }
            break
        case Qt.Key_D:
            if (event.modifiers & Qt.ControlModifier) page(1)
            else return
            break
        case Qt.Key_U:
            if (event.modifiers & Qt.ControlModifier) page(-1)
            else return
            break
        case Qt.Key_PageDown: page(1); break
        case Qt.Key_PageUp: page(-1); break
        case Qt.Key_Home: { const was = list.currentIndex; list.currentIndex = 0; sfxStep(was); break }
        case Qt.Key_End: { const was = list.currentIndex; list.currentIndex = list.count - 1; sfxStep(was); break }
        case Qt.Key_Slash:
            Sfx.play("open")
            searchMode = true
            searchInput.forceActiveFocus()
            break
        case Qt.Key_P: App.toPlayer(); break
        case Qt.Key_X: App.stopPlayback(); break
        case Qt.Key_Space: toggleSel(); break
        case Qt.Key_A: {
            const it = currentItemMap()
            if (it.uri) { Queue.add(it); Sfx.play("select"); App.notify("QUEUED · " + it.title) }
            else Sfx.play("bump")
            break
        }
        case Qt.Key_Q: App.queueOpen = !App.queueOpen; break
        case Qt.Key_C: App.outputOpen = true; break
        // Toggle, not set: if the overlay ever loses focus while visible
        // (a stage change under it), `w` still gets you out.
        // `e` — take over what another codec has open, at the moment it
        // reached; that screen stops. Returns without accepting when nothing
        // is playing elsewhere, so the key stays free for anything later.
        case Qt.Key_E:
            if (!App.nowElsewhere || App.partyLive) return
            App.resumeHere(); break
        case Qt.Key_W: App.partyOpen = !App.partyOpen; break
        case Qt.Key_B: {
            // Straight to the title's BONUS FEATURES (its detail page, opened
            // on the bonus list — Esc steps back to the page, then the grid).
            const c = list.currentItem
            if (c && c.extrasCount > 0) {
                Sfx.play("open")   // here: the detail page opens it a turn later, silently
                lib.bonusRequested(c.path)
            }
            break
        }
        case Qt.Key_T: {
            const c = list.currentItem
            if (c && c.kind === "movie")
                App.playTrailer(c.title, c.subtitle)
            break
        }
        case Qt.Key_R:
            if (event.modifiers & Qt.ControlModifier) {
                const row = MediaLibrary.randomRow()
                if (row >= 0) { list.currentIndex = row; openCurrent() }
            } else return
            break
        case Qt.Key_O: Sfx.play("select"); cycleSort(); break
        case Qt.Key_M:     // the show's guide: every episode ↔ myth + top
            if (!hasGuide) return
            Sfx.play("select"); cycleGuide(); break
        case Qt.Key_F: openFilterPicker(); break
        case Qt.Key_F5: App.updateLibrary(); break
        default:
            return
        }
        event.accepted = true
    }

    // ── Frame geometry ────────────────────────────────────────────────────
    // Two regions, not two panels. The left is a contact sheet, the right is
    // one plate of art running edge to edge. The old layout was a list slab
    // beside a detail slab: both grey, both full-bleed, and the only picture
    // on screen was a 380px poster boxed inside the second one. Home already
    // settled this — art owns the frame.
    readonly property real railW: Math.round(width * 0.48)
    // The left gutter: 28, but 16 on the CRT, whose glass edge is already a
    // frame (YouTube's rows had a dead band beside them). 16, not YouTube's 8:
    // a poster has no transparent plate edge, so this lands it level with
    // CODEC in the strip, as the row plates' visible edges are there.
    readonly property int gutter: App.mode === "crt" ? 16 : 28
    readonly property real sheetW: railW - gutter - 28 // the gutter + 28 to the plate
    readonly property bool epMode: MediaLibrary.showFilter.length > 0
    // Inside a show, its clearlogo heads the list (top left) instead of riding
    // the art plate on every episode; "" = no logo, the plain name stays.
    readonly property string showLogo: (MediaLibrary.totalCount, epMode
                                        ? MediaLibrary.showLogo(MediaLibrary.showFilter) : "")
    // ...in a taller header row
    readonly property bool logoHeader: showLogo.length > 0
    // Columns come from the sheet's real width so a poster holds its size on a
    // 1280-wide CRT instead of shrinking to a thumbnail.
    readonly property int cols: epMode ? 1 : Math.max(3, Math.round(sheetW / 176))

    // How far the stage sits below the global header — the art bleeds UP by this
    // much so the backdrop runs to the true top of the screen (behind the header
    // text), the same trick HomeView uses. Set from Main.qml.
    property real topBleed: 0

    // ── Art plate ─────────────────────────────────────────────────────────
    Item {
        id: plate
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: -lib.topBleed   // bleed the art up behind the header
        anchors.bottom: parent.bottom
        width: parent.width - lib.railW
        clip: true

        // Selection moves under j/k faster than an image can load, so the
        // source is settled before it is swapped — otherwise every keypress
        // starts a decode that is stale by the time it finishes and the plate
        // strobes through the whole library.
        property string want: ""
        property string src: ""
        Timer {
            id: settle
            interval: 190
            onTriggered: plate.src = plate.want
        }
        function pick() {
            const c = list.currentItem
            let s = ""
            if (c) s = c.fanart.length > 0 ? c.fanart : c.poster
            want = s.length > 0 ? Theme.art(s) : ""
            if (want !== src) settle.restart()
        }
        Connections {
            target: list
            function onCurrentItemChanged() { plate.pick() }
        }

        property bool useA: true
        onSrcChanged: {
            if (src.length === 0) { imgA.source = ""; imgB.source = ""; return }
            const hidden = useA ? imgB : imgA
            if (String(hidden.source) === src) { useA = !useA; return }
            hidden.source = src
        }
        Image {
            id: imgA
            anchors.fill: parent
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: true
            opacity: plate.useA ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: DS.grand; easing.type: Easing.InOutQuad } }
            onStatusChanged: if (status === Image.Ready && !plate.useA) plate.useA = true
        }
        Image {
            id: imgB
            anchors.fill: parent
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: true
            opacity: plate.useA ? 0 : 1
            Behavior on opacity { NumberAnimation { duration: DS.grand; easing.type: Easing.InOutQuad } }
            onStatusChanged: if (status === Image.Ready && plate.useA) plate.useA = false
        }

        // The plate dissolves into the sheet instead of butting against it —
        // a hard vertical seam here reads as two windows, which is exactly the
        // thing being removed.
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                orientation: Gradient.Horizontal
                // LEFT edge: dissolve the seam where the art meets the sheet
                // (softened + widened so it no longer reads as a hard cut).
                // RIGHT edge: a matching dissolve into the screen edge so the art
                // fades on BOTH sides instead of butting the frame on the left only.
                GradientStop { position: 0.0; color: Theme.bg }
                GradientStop { position: 0.18; color: Theme.withAlpha(Theme.bg, 0.30) }
                GradientStop { position: 0.42; color: "transparent" }
                GradientStop { position: 0.88; color: "transparent" }
                GradientStop { position: 1.0; color: Theme.withAlpha(Theme.bg, 0.9) }
            }
        }
        // Text ground. The block sits low and the art keeps its upper two
        // thirds: the reference boards are mostly empty with one dense corner.
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                // Top: the art now EXTENDS to the very top of the screen —
                // only a gentle wash so it doesn't hard-edge into the top bar,
                // feathering to clear by ~24%. The art reads all the way up now.
                GradientStop { position: 0.0; color: Theme.withAlpha(Theme.bg, 0.30) }
                GradientStop { position: 0.10; color: Theme.withAlpha(Theme.bg, 0.10) }
                GradientStop { position: 0.24; color: "transparent" }
                GradientStop { position: 0.46; color: "transparent" }
                GradientStop { position: 0.74; color: Theme.withAlpha(Theme.bg, 0.80) }
                GradientStop { position: 1.0; color: Theme.withAlpha(Theme.bg, 0.97) }
            }
        }

        // Nothing selected yet, or a row with no art at all.
        ShadowText {
            anchors.centerIn: parent
            visible: plate.src.length === 0
            text: "󰿎"
            color: Theme.withAlpha(Theme.border, 0.5)
            font.family: Theme.monoFont
            font.pixelSize: 90
        }

        // ── The selected title ────────────────────────────────────────────
        Column {
            id: plateInfo
            readonly property var cur: list.currentItem
            // Centred horizontally, and BOTTOM-anchored WAY down so the last
            // element (the resume bar / synopsis) lines up with the key-tips at the
            // plate foot. The 7-line clip bounds the block, so the logo only shifts
            // a little between short/long plots. Responsive fractions, no per-display
            // branch.
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(plate.width - 96, 880)
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Math.round(plate.height * 0.045)
            spacing: DS.s3
            opacity: cur ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: DS.base } }

            // Re-enters on every change of selection so the plate reads as a
            // card being dealt, not a label being retyped.
            property real yOff: 0
            transform: Translate { y: plateInfo.yOff }
            Connections {
                target: list
                function onCurrentIndexChanged() { deal.restart() }
            }
            ParallelAnimation {
                id: deal
                NumberAnimation { target: plateInfo; property: "yOff"; from: 10; to: 0
                                  duration: DS.grand; easing.type: Easing.Bezier
                                  easing.bezierCurve: DS.enterCurve }
            }

            // Title art (clearlogo) — CENTRED and sized RELATIVE to the plate so it
            // scales with the display (CRT included) and reads as the focal element;
            // the height-first fit still caps any wide logo on width. The text title
            // (centred) falls back when a film has no logo.
            Item {
                id: titleSlot
                width: parent.width
                // Inside a show the list header carries its logo, so an episode's
                // plate opens on its own meta · name · plot.
                visible: !lib.epMode
                height: Math.round(Math.min(plate.height * 0.13, 150))
                readonly property bool hasLogo: !!(plateInfo.cur && plateInfo.cur.clearlogo
                                                    && plateInfo.cur.clearlogo.length > 0)
                Image {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    visible: titleSlot.hasLogo
                    source: titleSlot.hasLogo ? Theme.art(plateInfo.cur.clearlogo) : ""
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true; mipmap: true
                    readonly property real asp: sourceSize.height > 0 ? sourceSize.width / sourceSize.height : 3
                    height: Math.min(titleSlot.height, titleSlot.width / Math.max(asp, 0.1))
                    width: height * asp
                }
                ShadowText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    visible: !titleSlot.hasLogo
                    // No logo → this slot is always the SHOW/film identity: the show
                    // name for an episode (its own name rides the quoted codec line
                    // below), the title otherwise.
                    text: plateInfo.cur ? (plateInfo.cur.kind === "episode"
                                           ? plateInfo.cur.show : plateInfo.cur.title) : ""
                    color: Theme.fg
                    font.family: Theme.codecFont
                    font.pixelSize: DS.tView
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                }
            }

            // Episode name — which episode you're on, in quotes, on its own
            // codec-face title line, ABOVE the meta line: inside a show the list
            // header carries the logo, so the name is this plate's headline.
            // Episode-only (movies/shows have no per-item name here).
            ShadowText {
                anchors.horizontalCenter: parent.horizontalCenter
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                // (a film the guide places wears the same line: "FILM · Name")
                visible: plateInfo.cur ? plateInfo.cur.kind === "episode"
                                         || (lib.epMode && plateInfo.cur.kind === "movie") : false
                // The episode model title is "S01E01 · Name" — quote just the NAME
                // (the SxxExx code already rides each list row at left). Fall back to
                // the whole label for an episode with no scraped name.
                text: {
                    if (!plateInfo.cur) return ""
                    var t = plateInfo.cur.title, i = t.indexOf(" · ")
                    return '"' + Theme.mgsSafe(i >= 0 ? t.substring(i + 3) : t) + '"'
                }
                color: Theme.fg
                font.family: Theme.codecFont
                font.pixelSize: 40
                font.letterSpacing: DS.trackHead
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
            }

            // Meta line: rating ★, year, the textured format badges (driven off the
            // item's `flags` — 4K/HDR/DV/ATMOS/audio, each MechChip picks its plate),
            // runtime, and a WATCHED ×N badge. Every text cell shares the badge box
            // height so plates and type sit level.
            Row {
                id: metaRow
                anchors.horizontalCenter: parent.horizontalCenter
                readonly property int metaPx: Math.round(DS.tMeta * 2)
                spacing: Math.round(metaPx * 0.9)
                readonly property int metaH: metaPx + 8
                // where the meta words' cap ink centres in their metaH cell — the
                // badges seat their LABEL on it (a fixed lift left them 1.5 px
                // above the words: 24 px is off the HUD face's 16-px grid)
                FontMetrics { id: metaFm; font.family: Theme.hudFont; font.pixelSize: metaRow.metaPx }
                readonly property real inkMid: {
                    void metaFm.height
                    const r = metaFm.tightBoundingRect("H")
                    return (metaH - metaFm.height) / 2 + metaFm.ascent + r.y + r.height / 2
                }
                Item {
                    visible: plateInfo.cur ? plateInfo.cur.rating > 0 : false
                    height: parent.metaH
                    implicitWidth: rNum.x + rNum.implicitWidth
                    ShadowText {
                        id: rStar
                        // Was baseline-pinned to the number and read too high;
                        // drop it onto the number's optical centre.
                        anchors.baseline: rNum.baseline
                        text: "★"; color: Theme.accent
                        font.family: Theme.hudFont
                        font.pixelSize: metaRow.metaPx
                    }
                    ShadowText {
                        id: rNum
                        anchors.verticalCenter: parent.verticalCenter
                        x: rStar.implicitWidth + 6
                        text: plateInfo.cur ? plateInfo.cur.rating.toFixed(1) : ""
                        color: Theme.accent
                        font.family: Theme.hudFont
                        font.pixelSize: metaRow.metaPx
                        font.letterSpacing: 1
                    }
                }
                ShadowText {
                    // #3: prefer the AUTHORITATIVE model year (TMDB > container tag >
                    // name). Shows almost never carry a year token in the folder name,
                    // so the old subtitle-first-token derivation left them blank even
                    // when the real year is known; a wrong filename year showed wrong.
                    // Fall back to a 4-digit first subtitle token only when year==0.
                    readonly property string yr: {
                        if (!plateInfo.cur) return ""
                        if (plateInfo.cur.year > 0) return String(plateInfo.cur.year)
                        var t = String(plateInfo.cur.subtitle).split(/\s*·\s*/)[0] || ""
                        return /^\d{4}$/.test(t) ? t : ""
                    }
                    visible: yr.length > 0
                    height: parent.metaH; verticalAlignment: Text.AlignVCenter
                    text: yr
                    color: Theme.dimFg
                    font.family: Theme.hudFont
                    font.pixelSize: metaRow.metaPx
                    font.letterSpacing: 1
                }
                Repeater {
                    // NEW when it just arrived, the file's format flags, then
                    // EXTRAS when the title has bonus features (a fact about the
                    // title, not the file).
                    model: plateInfo.cur
                           ? (plateInfo.cur.isNew ? ["NEW"] : [])
                                 .concat(plateInfo.cur.flags || [])
                                 .concat(plateInfo.cur.extrasCount > 0 ? ["EXTRAS"] : [])
                           : []
                    // Wrapper keeps the badge on the row's baseline: MechChip seats
                    // its label low in the plate, so centre the plate and lift it so
                    // the badge label sits level with the ★/year/runtime text.
                    delegate: Item {
                        required property string modelData
                        height: metaRow.metaH
                        width: badge.width
                        MechChip {
                            id: badge
                            y: Math.round(metaRow.inkMid - height / 2 - labelDrop)
                            plateStyle: "badge"
                            px: 2
                            flag: parent.modelData
                            text: parent.modelData
                            ink: "#eef4f8"
                            font.family: Theme.hudFont
                            font.pixelSize: 16   // the HUD face's own grid: crisp
                            font.letterSpacing: 1
                        }
                    }
                }
                ShadowText {
                    height: parent.metaH; verticalAlignment: Text.AlignVCenter
                    visible: plateInfo.cur ? plateInfo.cur.runtimeMin > 0 : false
                    text: plateInfo.cur ? plateInfo.cur.runtimeMin + " MIN" : ""
                    color: Theme.dimFg
                    font.family: Theme.hudFont
                    font.pixelSize: metaRow.metaPx
                    font.letterSpacing: 1
                }
                // WATCHED ×N — now a textured badge (fixes the mono-font pass miss
                // AND adds the play count), mirroring the detail page.
                Item {
                    visible: plateInfo.cur ? (plateInfo.cur.completed
                                              || (plateInfo.cur.watchCount || 0) > 0) : false
                    height: metaRow.metaH
                    width: visible ? wBadge.width : 0
                    MechChip {
                        id: wBadge
                        y: Math.round(metaRow.inkMid - height / 2 - labelDrop)
                        plateStyle: "badge"
                        px: 2
                        flag: "WATCHED"
                        text: Theme.mgsSafe("WATCHED" + ((plateInfo.cur && plateInfo.cur.watchCount > 0)
                                                         ? "  ×" + plateInfo.cur.watchCount : ""))
                        ink: "#eef4f8"
                        font.family: Theme.hudFont
                        font.pixelSize: 16   // the HUD face's own grid: crisp
                        font.letterSpacing: 1
                    }
                }
            }

            // Genres — the show's/film's tags. Hidden on an episode: you're already
            // inside the show, so the episode plate stays logo · meta · name · plot.
            ShadowText {
                anchors.horizontalCenter: parent.horizontalCenter
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                visible: plateInfo.cur ? (plateInfo.cur.genres.length > 0
                                          && plateInfo.cur.kind !== "episode") : false
                text: plateInfo.cur ? plateInfo.cur.genres.toUpperCase() : ""
                color: Theme.dimFg
                font.family: Theme.hudFont
                font.pixelSize: Math.round(DS.tLabel * 2)
                font.letterSpacing: DS.trackLabel * 2
                maximumLineCount: 1
                elide: Text.ElideRight
            }

            // Synopsis — a gentle auto-scroll instead of a hard "…" cap, so the
            // whole plot can be read. Clipped to ~5 lines; when it overflows, a
            // marquee holds at the top, slow-scrolls to the bottom, holds, resets.
            Item {
                id: plotBox
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.min(parent.width, 760)
                // Cap by the REAL line height. mgs-hud renders shorter than its
                // pixelSize, so a pixel estimate over-counted (~9 lines showed,
                // pushing the block too tall / the logo too high). contentHeight /
                // lineCount is the true per-line, so N here is exactly N lines.
                readonly property int maxLines: 7
                readonly property real realLineH: plotText.lineCount > 0
                        ? plotText.contentHeight / plotText.lineCount : 30
                visible: plateInfo.cur ? plateInfo.cur.plot.length > 0 : false
                height: visible ? Math.round(realLineH * Math.min(plotText.lineCount, maxLines)) : 0
                clip: true
                readonly property real overflow: Math.max(0, plotText.contentHeight - height)
                ShadowText {
                    id: plotText
                    width: parent.width
                    text: Theme.mgsSafe(plateInfo.cur ? plateInfo.cur.plot : "")
                    color: Theme.fg
                    opacity: 0.80
                    font.family: Theme.hudFont
                    font.pixelSize: Math.round(DS.tBody * 2)
                    lineHeight: 1.32
                    wrapMode: Text.Wrap
                }
                SequentialAnimation {
                    id: plotScroll
                    running: lib.visible && plotBox.overflow > 2   // not behind other stages (the Loader latches)
                    loops: Animation.Infinite
                    PauseAnimation { duration: 2400 }
                    NumberAnimation { target: plotText; property: "y"; from: 0
                                      to: -plotBox.overflow
                                      duration: Math.max(1, plotBox.overflow) * 45
                                      easing.type: Easing.InOutQuad }
                    PauseAnimation { duration: 2400 }
                    NumberAnimation { target: plotText; property: "y"; to: 0
                                      duration: 800; easing.type: Easing.InOutQuad }
                }
                Connections {
                    target: list
                    function onCurrentIndexChanged() { plotText.y = 0; plotScroll.restart() }
                }
            }

            // Resume, shown where the eye already is rather than as a hairline
            // buried in a 52px row.
            Item {
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.min(parent.width, 760)
                height: plateInfo.cur && plateInfo.cur.resumePct > 0.01
                        && !plateInfo.cur.completed ? 18 : 0
                visible: height > 0
                Rectangle {
                    width: parent.width; height: 2; y: 8
                    color: Theme.withAlpha(Theme.border, 0.8)
                }
                Rectangle {
                    width: parent.width * (plateInfo.cur ? plateInfo.cur.resumePct : 0)
                    height: 2; y: 8
                    color: Theme.accent
                }
            }
        }
    }

    Column {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: lib.sheetW
        anchors.margins: 28
        anchors.leftMargin: lib.gutter
        anchors.topMargin: 20
        spacing: 16

        // Header row: [show logo] count + search
        Item {
            width: parent.width
            // a show's logo gets a taller row; reserved from the path alone, so
            // the list doesn't jump when the image lands
            height: lib.logoHeader ? hdrLogo.boxH : searchBox.height

            Image {
                id: hdrLogo
                readonly property int boxH: 72
                readonly property int boxW: 420
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                visible: lib.showLogo.length > 0
                source: visible ? Theme.art(lib.showLogo) : ""
                fillMode: Image.PreserveAspectFit
                asynchronous: true; mipmap: true
                // decode at 2x the box, not the file (some logos are 12000 px wide)
                sourceSize.height: boxH * 2
                // height-first fit, capped on width (same rule as the art plate);
                // the LOADED size — with sourceSize set, sourceSize reads back as set
                readonly property real asp: implicitHeight > 0 ? implicitWidth / implicitHeight : 3
                height: Math.min(boxH, boxW / Math.max(asp, 0.1))
                width: visible ? Math.round(height * asp) : 0
            }

            // The rail is narrower than the old full-width header, so the count
            // line takes what the search box leaves rather than running under
            // it — the overlap the last pass kept finding.
            ShadowText {
                id: hdrCount
                anchors.left: hdrLogo.visible ? hdrLogo.right : parent.left
                anchors.leftMargin: hdrLogo.visible ? 32 : 0
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - searchBox.width - 16 - (hdrLogo.visible ? hdrLogo.width + 32 : 0)
                elide: Text.ElideRight
                // What is counted, in its own word — "373 FILMS", "14 SHOWS",
                // "11 SEASONS · 217 EPISODES" — and "23 OF 373" only while a
                // search or filter narrows it. (It used to read "217 / 1359
                // ENTRIES": this list against every row in the library.)
                // The longest form that fits: beside a show's logo on a narrow
                // rail (the CRT) "11 SEASONS · 217 EPISODES" elided to "1…" —
                // it drops the season count first, then gives the room up to
                // the logo (SEASON n // count under it still says how many).
                FontMetrics { id: hdrCountFm; font: hdrCount.font }
                function line(full) {
                    // tight separators: the 28px type has to fit beside the search
                    const sep = "  ·  "
                    // a guide's cut counts its episodes (its films ride along)
                    const cut = lib.hasGuide && MediaLibrary.guideMode.length > 0
                                ? lib.guide.modes.find(x => x.mode === MediaLibrary.guideMode) : null
                    const shown = cut ? cut.count : list.count - MediaLibrary.headerRows
                    const noun = lib.epMode ? "EPISODES"
                               : MediaLibrary.section === "tv" ? "SHOWS" : "FILMS"
                    const total = (MediaLibrary.totalCount, lib.epMode
                                   ? MediaLibrary.countOf("episode", MediaLibrary.showFilter)
                                   : MediaLibrary.countOf(MediaLibrary.section === "tv" ? "show" : "movie"))
                    const narrowed = MediaLibrary.query.length > 0 || shown < total
                    let s = MediaLibrary.scanning ? "SCANNING…"
                            : (narrowed ? shown + " OF " + total : String(total)) + " " + noun
                    if (full && lib.epMode && !narrowed && MediaLibrary.headerRows > 1)
                        s = MediaLibrary.headerRows + " SEASONS" + sep + s
                    if (full && lib.epMode && lib.showLogo.length === 0)
                        s = MediaLibrary.showFilter.toUpperCase() + sep + s
                    if (lib.hasGuide && MediaLibrary.guideMode.length > 0)
                        s += sep + lib.guideLabel(MediaLibrary.guideMode)
                    if (MediaLibrary.sortMode !== "title")
                        s += sep + "SORT " + MediaLibrary.sortMode.toUpperCase()
                    if (MediaLibrary.genreFilter.length > 0)
                        s += sep + MediaLibrary.genreFilter.toUpperCase()
                    if (MediaLibrary.flagFilter.length > 0)
                        s += sep + MediaLibrary.flagFilter   // short (DV/HDR10/4K/ATMOS)
                    return Theme.mgsSafe(s)
                }
                readonly property string fullLine: line(true)
                readonly property string shortLine: line(false)
                function fits(t) { return hdrCountFm.advanceWidth(t) <= width }
                text: (hdrCountFm.height, width, fits(fullLine)) ? fullLine
                      : fits(shortLine) || !hdrLogo.visible ? shortLine : ""
                color: Theme.dimFg
                font.family: Theme.codecFont
                font.pixelSize: 28
                font.letterSpacing: 2
            }

            SearchField {
                id: searchBox
                anchors.right: parent.right
                anchors.rightMargin: -texPx   // the art's 1px dark outline overhangs: the light line ends with the rule
                anchors.verticalCenter: parent.verticalCenter
                // Like YouTube's: idle it's just "SEARCH", collapsed to fit; searching
                // (or holding a query) it opens into the field, animated.
                readonly property bool open: lib.searchMode || searchInput.text.length > 0
                width: open ? texPx * Math.round(Math.min(implicitWidth, parent.width * 0.5) / texPx)
                            : idleWidth
                Behavior on width {
                    NumberAnimation { duration: DS.base; easing.type: Easing.Bezier
                                      easing.bezierCurve: DS.moveCurve }
                }
                lit: lib.searchMode
                idleShown: !open

                MouseArea {   // like YouTube's: the box itself opens the search
                    anchors.fill: parent
                    visible: !lib.searchMode
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { Sfx.play("open"); lib.searchMode = true; searchInput.forceActiveFocus() }
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
                    enabled: lib.searchMode
                    onTextChanged: { MediaLibrary.query = text; list.currentIndex = 0 }
                    Keys.onPressed: (event) => {
                        if (event.key === Qt.Key_Escape) {
                            Sfx.play("back")
                            text = ""
                            MediaLibrary.query = ""
                            lib.searchMode = false
                            lib.forceActiveFocus()
                            event.accepted = true
                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                                   || event.key === Qt.Key_Up || event.key === Qt.Key_Down
                                   || (text.length === 0 && (event.key === Qt.Key_Left
                                                             || event.key === Qt.Key_Right))) {
                            // The remote's D-pad sends the same arrows as a keyboard,
                            // and it can't type: up/down always leave (a one-line field
                            // has no use for them), and with NO query left/right do too.
                            // With text, left/right move the cursor like any field.
                            // (The filter is live, so leaving keeps the results.)
                            // ⏎ settles the query; an arrow just steps off the field.
                            Sfx.play(event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                                     ? "select" : "move")
                            lib.searchMode = false
                            lib.forceActiveFocus()
                            event.accepted = true
                        }
                    }
                }
            }
        }

        // ── Contact sheet ─────────────────────────────────────────────────
        // A GridView, not a ListView, because the thing being browsed is 446
        // PICTURES. A stack of 52px text rows is a file manager; a sheet of
        // posters is a library, and the poster is how anyone actually finds a
        // film. One column and short cells when a show is open — an episode
        // has no art of its own, so a wall of identical stills would be worse
        // than the line of text it replaced.
        Item {
            id: sheet
            width: parent.width
            // Derived from the hint block, not a hand-tuned constant: the hint
            // wraps to two lines on a narrow rail, and a fixed 34 pushed the
            // bottom row of posters under it.
            height: parent.height - y - hints.height

            // Staged entrance. Not decoration: it reads as the sheet powering
            // up, and gives the eye a moment to find it before the tiles
            // arrive. One-shot on view show — deliberately NOT on data
            // arrival, or the whole thing twitches every time the library
            // finishes enriching something.
            property real reveal: 0
            NumberAnimation on reveal {
                id: revealAnim
                running: false
                from: 0; to: 1
                // Own pace now (was DS.grand): long enough that the per-tile
                // stagger reads as a DEAL rather than a single fade. Tunable.
                duration: 780
                easing.type: Easing.Bezier
                easing.bezierCurve: DS.enterCurve
            }
            Connections {
                target: lib
                function onVisibleChanged() {
                    if (lib.visible) { sheet.reveal = 0; revealAnim.restart() }
                }
            }
            Component.onCompleted: revealAnim.restart()

            GridView {
                id: list
                // An opened show's EPISODE LIST fans in like the Settings rows
                // (Cascade) — on opening the show and on entering the library;
                // the poster grids keep their card deal.
                property int cascadeRev: 0
                property double cascadeAt: 0
                function fanIn() { cascadeAt = Date.now(); cascadeRev++ }
                Connections {
                    target: MediaLibrary
                    // at once, not later: the rows the reset is about to build
                    // must find the fan already called, or they draw for a frame
                    // and then vanish to fan in (a flash)
                    function onSectionChanged() { if (lib.epMode) list.fanIn() }
                    function onGuideModeChanged() { if (lib.epMode) list.fanIn() }
                }
                Connections {
                    target: lib
                    function onVisibleChanged() { if (lib.visible && lib.epMode) list.fanIn() }
                }
                anchors.fill: parent
                model: MediaLibrary
                // A view built while its model is still empty keeps
                // currentIndex at -1 and never advances on its own, so the
                // first thing you saw was a page with nothing selected and an
                // empty half-screen beside it. Claim row 0 the moment there
                // is a row 0.
                onCountChanged: lib.ensureSelection()
                clip: true
                cellWidth: Math.floor(width / lib.cols)
                // Poster is 2:3. The extra 10px is the gutter, kept in the
                // cell so the tiles have air without a margin fighting the
                // cell arithmetic.
                cellHeight: lib.epMode ? 52
                                       : Math.round((cellWidth - 10) * 1.5) + 10
                // An opened show starts with a season heading, whose text sits at
                // the FOOT of its 52px cell (air between seasons) — at the very top
                // that air doubled the gap under the header. Tuck it away.
                topMargin: lib.epMode && MediaLibrary.headerRows > 0 ? -20 : 0
                keyNavigationWraps: false
                highlightMoveDuration: 0
                cacheBuffer: 800
                // The sheet no longer fades/slides as one block — each TILE deals
                // in on its own (see the delegate's dealT), staggered in reading
                // order like dealing dossier cards onto the table.
                opacity: 1

                // Selection has to stay off the edges of the viewport or you
                // are always looking at the last row you can see. vim's
                // scrolloff, one row of it — and it has to be in the direction
                // of TRAVEL, so walking down keeps a row of what is coming and
                // walking back up keeps a row of where you have been.
                // Contain only scrolls when the probe row is off screen, so
                // asking for it first and the real row second can never leave
                // the selection outside the viewport.
                property int lastIdx: 0
                onCurrentIndexChanged: {
                    // A season heading (an opened show) is never selected: step
                    // on past it in the direction of travel, or back off the end.
                    // The nested change does the scrolloff, so the heading still
                    // scrolls into view above the first episode when walking up.
                    if (lib.stepOffHeading(currentIndex >= lastIdx))
                        return
                    // A pointer hover lands on a tile that's already in view, so
                    // never reposition for it — positionViewAtIndex would slide
                    // new tiles under the stationary cursor and cascade the view to
                    // the extreme in a single tick ("way too jumpy"). The
                    // mouse scrolls via the wheel or the gentle edge auto-scroll
                    // below; the keyboard keeps its scrolloff.
                    if (App.pointerActive) { lastIdx = currentIndex; return }
                    const probe = currentIndex
                          + (currentIndex >= lastIdx ? lib.cols : -lib.cols)
                    if (probe >= 0 && probe < count)
                        positionViewAtIndex(probe, GridView.Contain)
                    positionViewAtIndex(currentIndex, GridView.Contain)
                    lastIdx = currentIndex
                }

                // Cursor-driven scrolling — smooth + slow. When the pointer sits in
                // the top/bottom margin the sheet scrolls at a gentle, proximity-
                // ramped rate (nearer the edge = a touch faster). cursorY is the
                // VIEWPORT-relative pointer Y, fed by the tiles below (a HoverHandler
                // on a Flickable reports CONTENT coords, which broke this). cursorStale
                // climbs each tick and resets whenever a tile reports the pointer —
                // so when the pointer leaves the sheet the scroll can't run away.
                property real cursorY: -1e4
                property int cursorStale: 99
                property real scrollVel: 0   // eased current velocity (the glide)
                // The view's real scroll range. NOT 0..contentHeight-height: an
                // opened show's -20 topMargin moves the top to contentY 20, and
                // clamping to 0 scrolled the tucked heading air back in (the gap
                // under the header that "popped into place" on the next key).
                readonly property real minY: originY - topMargin
                readonly property real maxY: Math.max(minY, originY + contentHeight
                                                      + bottomMargin - height)
                // Target velocity from edge proximity — nearer the edge = faster.
                // scrollVel chases this with easing (below) so the motion accelerates
                // in and DECELERATES to a stop instead of snapping on/off.
                readonly property real targetVel: {
                    if (!App.pointerActive || cursorStale > 3) return 0
                    const Z = 120         // edge margin that arms the scroll
                    const maxV = 10       // px/tick target at the very edge
                    if (cursorY >= 0 && cursorY < Z && contentY > minY)
                        return -maxV * (1 - cursorY / Z)
                    if (cursorY <= height && cursorY > height - Z && contentY < maxY)
                        return maxV * (1 - (height - cursorY) / Z)
                    return 0
                }
                Timer {
                    interval: 16
                    repeat: true
                    running: lib.visible
                    onTriggered: {
                        list.cursorStale++
                        // vim-smoothscroll glide: exponentially ease the live
                        // velocity toward the target, so entering the edge floats up
                        // and leaving it coasts to a stop over ~1s (floaty).
                        list.scrollVel += (list.targetVel - list.scrollVel) * 0.08
                        if (Math.abs(list.scrollVel) < 0.05) { list.scrollVel = 0; return }
                        if (list.moving) return   // don't fight a wheel flick
                        list.contentY = Math.max(list.minY, Math.min(list.maxY,
                                                 list.contentY + list.scrollVel))
                    }
                }

                delegate: Item {
                    id: tile
                    required property string title
                    required property string subtitle
                    required property string show
                    required property string kind
                    required property double resumePct
                    required property bool completed
                    required property string plot
                    required property double rating
                    required property int runtimeMin
                    required property string genres
                    required property string poster
                    required property string fanart
                    required property string clearlogo
                    required property var flags
                    required property int watchCount
                    required property int year   // #3: needed for the plate's authoritative year
                    required property int extrasCount   // bonus features → EXTRAS badge
                    required property string verdict     // the show's guide: story | top | ""
                    required property bool isNew         // just arrived, not started (NEW)
                    required property string path
                    required property int index
                    readonly property bool selected: lib.sel[path] === true
                    readonly property bool current: list.currentIndex === index

                    width: list.cellWidth
                    height: list.cellHeight

                    // Card-deal entrance: as sheet.reveal sweeps 0->1, each tile
                    // deals in on its own — staggered by index (reading order) and
                    // flying up from a stack (down-left, tilted, small -> settled)
                    // like dealing dossier cards onto the table. dealT=1 at rest,
                    // so hover/selection are untouched. Index is capped so the
                    // off-screen tiles still finish by reveal=1 (not visible anyway).
                    readonly property real dealT: {
                        if (lib.epMode) return 1          // episode rows fan in instead
                        var d = Math.min(index, 34) * 0.018
                        return Math.max(0, Math.min(1, (sheet.reveal - d) / 0.30))
                    }
                    Cascade { id: fan; view: list }
                    opacity: lib.epMode ? fan.op : dealT
                    transform: [
                        Translate { y: (1 - tile.dealT) * 22; x: (1 - tile.dealT) * -14 },
                        Rotation { origin.x: tile.width / 2; origin.y: tile.height / 2
                                   angle: (1 - tile.dealT) * -7 },
                        Scale { origin.x: tile.width / 2; origin.y: tile.height / 2
                                xScale: 0.80 + 0.20 * tile.dealT
                                yScale: 0.80 + 0.20 * tile.dealT }
                    ]

                    // ── Season heading (an opened show) ───────────────────
                    // "SEASON 3 // 22" — the BONUS FEATURES page's section grammar.
                    // Not a row: no plate, never selected, the mouse passes it by.
                    readonly property bool isHeader: kind === "season"
                    ShadowText {
                        visible: lib.epMode && tile.isHeader
                        x: 6
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 12
                        text: Theme.mgsSafe(tile.title) + (tile.subtitle.length > 0 ? " // " + tile.subtitle : "")
                        color: Theme.withAlpha(Theme.accent, 0.85)
                        font.family: Theme.codecFont
                        font.pixelSize: 20
                        font.letterSpacing: 4
                    }

                    // ── Episode row (one column) ──────────────────────────
                    // Selection rides the SHARED mech grammar (MechSelectRow): the
                    // idle + lit family-6 plate cross-fade with a tap + hop on
                    // select — the exact plate the queue / output picker / party
                    // rows use, in place of the old bespoke rect. Content lives in a
                    // SIBLING that rides plate.hopY so it bounces with the plate.
                    Item {
                        visible: lib.epMode && !tile.isHeader
                        anchors.fill: parent
                        anchors.rightMargin: 10
                        anchors.bottomMargin: 2

                        MechSelectRow {
                            id: epPlate
                            anchors.fill: parent
                            selected: tile.current
                            glass: App.glassLevel
                            armed: lib.epMode
                        }
                        Item {
                            id: epContent
                            anchors.fill: parent
                            // the Settings rows' fan: the plate fades where it is,
                            // only the words rise into it
                            transform: Translate { y: epPlate.hopY + fan.dy }
                            // Centre text + resume bar in the plate's dark button face
                            // (measured y-band between the top bevel and the mid-tone
                            // foot): the ink lands dead-centre of the dark part.
                            readonly property int titlePx: 26
                            readonly property int subPx: 22
                            // The STATS / YouTube spotlight: the selected row reads
                            // at full strength, the rest step back to half, and the
                            // change FADES (DS.selFade) as the selection moves.
                            readonly property real textDim: tile.current ? 1 : 0.5
                            // The middle of the plate's DARK FACE (MechButton reads it off
                            // the art). Text is centred on THAT, not on the plate (whose
                            // lighter foot pulled the eye's centre low). epContent fills
                            // the same box as the plate, so it's the same coordinate.
                            readonly property real faceMid: epPlate.faceMid
                            // where a HUD capital's ink middle sits under a Text's top
                            // (FontMetrics re-read once the MGS face loads)
                            function capMid(fm) {
                                void fm.height
                                const r = fm.tightBoundingRect("H")
                                return fm.ascent + r.y + r.height / 2
                            }
                            FontMetrics { id: epTitleFm; font.family: Theme.hudFont; font.pixelSize: epContent.titlePx }
                            FontMetrics { id: epSubFm; font.family: Theme.hudFont; font.pixelSize: epContent.subPx }

                            // LEFT: episode code · name — all mgs-hud, with a drawn dot
                            // on the ink line (a text · would float off a fallback face).
                            Row {
                                id: epTitleRow
                                x: 24
                                width: parent.width - 150
                                clip: true
                                y: Math.round(epContent.faceMid - epContent.capMid(epTitleFm))
                                opacity: epContent.textDim
                                Behavior on opacity { NumberAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                                readonly property var parts: {
                                    var t = tile.title, i = t.indexOf(" · ")
                                    return i >= 0 ? [t.substring(0, i), t.substring(i + 3)] : [t, ""]
                                }
                                ShadowText {
                                    text: Theme.mgsSafe(epTitleRow.parts[0])
                                    color: Theme.fg
                                    font.family: Theme.hudFont
                                    font.pixelSize: epContent.titlePx
                                }
                                // the font's own · (it has one now): same face, size and
                                // line as the words, so it sits mid-cap by construction
                                ShadowText {
                                    visible: epTitleRow.parts[1].length > 0
                                    text: "·"
                                    leftPadding: Math.round(epContent.titlePx * 0.3)
                                    rightPadding: Math.round(epContent.titlePx * 0.3)
                                    color: tile.current ? Theme.withAlpha(Theme.fg, 0.55)
                                                        : Theme.withAlpha(Theme.fg, 0.4)
                                    Behavior on color { ColorAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                                    font.family: Theme.hudFont
                                    font.pixelSize: epContent.titlePx
                                }
                                ShadowText {
                                    visible: epTitleRow.parts[1].length > 0
                                    text: Theme.mgsSafe(epTitleRow.parts[1])
                                    color: Theme.fg
                                    font.family: Theme.hudFont
                                    font.pixelSize: epContent.titlePx
                                }
                            }

                            // RIGHT: year · resolution — mgs-hud + drawn dot; a mono ✓
                            // leads it when the episode is finished (the nerd glyph the
                            // MGS faces don't carry).
                            Row {
                                id: epSubRow
                                anchors.right: parent.right
                                anchors.rightMargin: tile.selected ? 40 : 16
                                y: Math.round(epContent.faceMid - epContent.capMid(epSubFm))
                                opacity: epContent.textDim
                                Behavior on opacity { NumberAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                                // in a guide's cut, its mark takes the resolution's
                                // place in the codec face: "1993 · MYTH", "1993 · TOP"
                                readonly property bool mark: lib.hasGuide && MediaLibrary.guideMode.length > 0
                                                             && tile.verdict.length > 0
                                readonly property var parts: {
                                    var t = tile.subtitle, i = t.indexOf(" · ")
                                    var p = i >= 0 ? [t.substring(0, i), t.substring(i + 3)] : [t, ""]
                                    if (mark)
                                        p[1] = lib.verdictWord[tile.verdict] || p[1]
                                    return p
                                }
                                // the codec face at the year's CAP height (its caps are
                                // 384/1024 of the em, the HUD face's 320), its cap middle
                                // seated on the HUD words' beside it
                                readonly property int markPx: Math.round(epContent.subPx * 320 / 384)
                                FontMetrics { id: epMarkFm; font.family: Theme.codecFont; font.pixelSize: epSubRow.markPx }
                                readonly property color ink: tile.completed ? Theme.accent : Theme.dimFg
                                // Completed ✔ — the HUD face's own heavy check (digit
                                // weight), on the same line as the year/res, so it sits
                                // on their baseline by construction (the mono icon
                                // glyph rode high).
                                ShadowText {
                                    visible: tile.completed
                                    text: "✔"
                                    rightPadding: Math.round(epContent.subPx * 0.4)
                                    color: Theme.accent
                                    font.family: Theme.hudFont
                                    font.pixelSize: epContent.subPx
                                }
                                // NEW (just arrived, not started) leads the line in the
                                // codec face, as a guide's mark sits — never beside ✔
                                ShadowText {
                                    visible: tile.isNew
                                    text: "NEW"
                                    rightPadding: Math.round(epContent.subPx * 0.5)
                                    y: Math.round(epContent.capMid(epSubFm) - epContent.capMid(epMarkFm))
                                    color: Theme.accent
                                    font.family: Theme.codecFont
                                    font.pixelSize: epSubRow.markPx
                                    font.letterSpacing: 0
                                }
                                ShadowText {
                                    text: Theme.mgsSafe(epSubRow.parts[0])
                                    color: epSubRow.ink
                                    font.family: Theme.hudFont
                                    font.pixelSize: epContent.subPx
                                }
                                ShadowText {
                                    visible: epSubRow.parts[1].length > 0
                                    text: "·"
                                    leftPadding: Math.round(epContent.subPx * 0.3)
                                    rightPadding: Math.round(epContent.subPx * 0.3)
                                    color: Theme.withAlpha(epSubRow.ink, 0.75)
                                    font.family: Theme.hudFont
                                    font.pixelSize: epContent.subPx
                                }
                                ShadowText {
                                    visible: epSubRow.parts[1].length > 0
                                    y: epSubRow.mark ? Math.round(epContent.capMid(epSubFm)
                                                                  - epContent.capMid(epMarkFm)) : 0
                                    text: Theme.mgsSafe(epSubRow.parts[1])
                                    color: epSubRow.ink
                                    font.family: epSubRow.mark ? Theme.codecFont : Theme.hudFont
                                    font.pixelSize: epSubRow.mark ? epSubRow.markPx : epContent.subPx
                                    font.letterSpacing: 0
                                }
                            }

                            // Resume bar — lifted off the plate foot to sit inside the
                            // dark recess with the text, with a small gap above the
                            // bright bottom edge so it doesn't blend in when the row lit.
                            Rectangle {
                                visible: tile.resumePct > 0.01 && !tile.completed
                                anchors.bottom: parent.bottom
                                anchors.bottomMargin: 15
                                x: 24
                                height: 2
                                width: (parent.width - 48) * tile.resumePct
                                color: Theme.accent
                                opacity: 0.85 * epContent.textDim
                                Behavior on opacity { NumberAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                            }
                        }
                    }

                    // ── Poster tile ───────────────────────────────────────
                    Item {
                        visible: !lib.epMode
                        anchors.fill: parent
                        anchors.margins: 5

                        // Unselected art is held back so the selection reads
                        // without a border doing the work. A sheet where every
                        // tile is at full strength has no focus at all.
                        opacity: tile.current ? 1 : 0.45
                        Behavior on opacity { NumberAnimation { duration: DS.base } }

                        // Selected tile lifts. 1.04 is the whole gesture —
                        // enough to separate it from the sheet, small enough
                        // that it never crosses into its neighbour's cell.
                        scale: tile.current ? 1.04 : 1.0
                        Behavior on scale {
                            NumberAnimation { duration: DS.base; easing.type: Easing.Bezier
                                              easing.bezierCurve: DS.enterCurve }
                        }

                        Rectangle {
                            id: card
                            anchors.fill: parent
                            radius: 8
                            color: Theme.surface
                            border.width: tile.current ? 2 : 1
                            border.color: tile.current ? Theme.accent
                                                       : Theme.withAlpha(Theme.border, 0.7)
                            clip: true
                            Behavior on border.color { ColorAnimation { duration: DS.quick } }

                            Image {
                                id: art
                                anchors.fill: parent
                                anchors.margins: 1
                                source: tile.poster.length > 0 ? Theme.art(tile.poster) : ""
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                cache: true
                                sourceSize.height: 480
                                opacity: status === Image.Ready ? 1 : 0
                                Behavior on opacity { NumberAnimation { duration: DS.slow } }
                            }

                            // No art yet, or none to be had. The title has to
                            // appear somewhere or the tile is an empty box.
                            Column {
                                anchors.centerIn: parent
                                width: parent.width - 24
                                spacing: 8
                                visible: art.status !== Image.Ready
                                ShadowText {
                                    text: tile.kind === "show" ? "󰉋" : "󰿎"
                                    color: Theme.border
                                    font.family: Theme.monoFont
                                    font.pixelSize: 26
                                    anchors.horizontalCenter: parent.horizontalCenter
                                }
                                ShadowText {
                                    width: parent.width
                                    text: Theme.mgsSafe(tile.title)
                                    color: Theme.dimFg
                                    horizontalAlignment: Text.AlignHCenter
                                    font.family: Theme.hudFont
                                    font.pixelSize: DS.tMeta * 2
                                    wrapMode: Text.Wrap
                                    maximumLineCount: 4
                                    elide: Text.ElideRight
                                }
                            }

                            // Resume, along the foot of the poster.
                            Rectangle {
                                visible: tile.resumePct > 0.01 && !tile.completed
                                         && tile.kind !== "show"
                                anchors.bottom: parent.bottom
                                anchors.bottomMargin: 1
                                anchors.left: parent.left
                                anchors.leftMargin: 1
                                height: 3
                                width: (parent.width - 2) * tile.resumePct
                                color: Theme.accent
                            }

                            // Classified card-back: the tile flies in FACE-DOWN
                            // (near-black), then wipes off left-to-right to reveal
                            // the poster once the card has LANDED and the art is
                            // decoded — so a still-loading poster holds its back
                            // instead of popping. An accent read-head leads the
                            // wipe. Only the entry deal, not scroll-ins.
                            Item {
                                id: cardBack
                                anchors.fill: parent
                                anchors.margins: 1
                                property bool inDeal: false
                                property real w: 0
                                readonly property bool artDone: art.status === Image.Ready
                                    || art.status === Image.Error || tile.poster.length === 0
                                readonly property bool armed: inDeal && tile.dealT > 0.5 && artDone
                                onArmedChanged: if (armed) wipeAnim.restart()
                                Component.onCompleted: {
                                    inDeal = tile.dealT < 0.9   // entry only, not scroll
                                    if (armed) wipeAnim.restart()
                                }
                                NumberAnimation {
                                    id: wipeAnim
                                    target: cardBack; property: "w"
                                    from: 0; to: 1; duration: 340; easing.type: Easing.OutCubic
                                }
                                visible: inDeal && w < 0.999
                                Rectangle {  // the near-black back, retracting right
                                    anchors.right: parent.right
                                    anchors.top: parent.top
                                    anchors.bottom: parent.bottom
                                    width: parent.width * (1 - cardBack.w)
                                    color: "#060810"
                                }
                                Rectangle {  // accent read-head leading the wipe
                                    x: parent.width * cardBack.w - width
                                    width: 2; height: parent.height
                                    color: Theme.accent
                                    opacity: 0.9
                                    visible: cardBack.w > 0.03 && cardBack.w < 0.97
                                }
                            }
                        }

                        // NEW: arrived in the last 14 days and not started yet
                        // (the importer's ledger) — the format badges' plate and
                        // ink. Gives the corner up to the multi-select tick.
                        MechChip {
                            visible: tile.isNew && !tile.selected && !lib.epMode
                            anchors.top: parent.top
                            anchors.left: parent.left
                            anchors.margins: 6
                            plateStyle: "badge"
                            px: list.cellWidth >= 120 ? 2 : 1   // 2 = the meta line's badges
                            flag: "NEW"
                            text: "NEW"
                            ink: "#eef4f8"
                            font.family: Theme.hudFont
                            font.pixelSize: 8 * px    // the HUD face's own grid: crisp
                            font.letterSpacing: px > 1 ? 1 : 0
                        }

                        // Watched: a corner mark, not a badge across the art.
                        Rectangle {
                            visible: tile.completed
                            anchors.top: parent.top
                            anchors.right: parent.right
                            anchors.margins: 6
                            width: 17; height: 17; radius: 8.5
                            color: Theme.withAlpha(Theme.bg, 0.62)
                            border.width: 1
                            border.color: Theme.withAlpha(Theme.accent, 0.55)
                            ShadowText {
                                anchors.centerIn: parent
                                text: "✔"
                                color: Theme.withAlpha(Theme.accent, 0.85)
                                font.family: Theme.hudFont
                                font.pixelSize: 20
                            }
                        }

                        // Multi-select register tick (space)
                        Rectangle {
                            visible: tile.selected
                            anchors.top: parent.top
                            anchors.left: parent.left
                            anchors.margins: 6
                            width: 18; height: 18; radius: 3
                            color: Theme.accent
                            ShadowText {
                                anchors.centerIn: parent
                                text: "󰄬"
                                color: Theme.bg
                                font.pixelSize: 10
                            }
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        enabled: !tile.isHeader   // a season heading isn't a row
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        // Hover selects (movement-filtered), click on the
                        // selected tile opens — same idiom as YouTubeView.
                        // App.pointerActive is the real guard: the scene
                        // filter resets at delegate boundaries, so tiles
                        // sliding under a parked cursor during KEY scroll
                        // still "moved" — but the last input being a key
                        // means the pointer doesn't own selection at all.
                        property point prevScene: Qt.point(-9999, -9999)
                        onExited: prevScene = Qt.point(-9999, -9999)
                        onPositionChanged: (mouse) => {
                            // Feed the edge auto-scroll the VIEWPORT-relative pointer
                            // Y (through contentItem's -contentY offset), and mark it
                            // fresh. Fires even when the pointer is still and the
                            // sheet slides under it, so a held-at-edge scroll sustains.
                            list.cursorY = mapToItem(list, mouse.x, mouse.y).y
                            list.cursorStale = 0
                            const p = mapToItem(null, mouse.x, mouse.y)
                            const moved = Math.abs(p.x - prevScene.x) > 2
                                          || Math.abs(p.y - prevScene.y) > 2
                            prevScene = Qt.point(p.x, p.y)
                            if (App.pointerActive && moved && !list.moving
                                    && list.currentIndex !== tile.index) {
                                list.currentIndex = tile.index
                                if (lib.sfxFloor) Sfx.play("move", lib.sfxPan())
                            }
                        }
                        onClicked: {
                            if (list.currentIndex === tile.index) lib.openCurrent()
                            else { list.currentIndex = tile.index; Sfx.play("move", lib.sfxPan()) }
                        }
                        onDoubleClicked: { list.currentIndex = tile.index; lib.openCurrent() }
                    }
                }

                ShadowText {
                    anchors.centerIn: parent
                    visible: list.count === 0 && !MediaLibrary.scanning
                    // nothing narrowing the list = the section is simply empty:
                    // say where films come from (a new install lands here)
                    text: Theme.mgsSafe(MediaLibrary.query === "" && MediaLibrary.genreFilter === ""
                                        && MediaLibrary.flagFilter === ""
                          ? (MediaLibrary.section === "tv" ? "no shows yet" : "no films yet")
                            + " - add a media path in settings ▸ library"
                          : "no match")
                    color: Theme.dimFg
                    font.family: Theme.hudFont
                    font.pixelSize: 26
                    font.letterSpacing: 2
                }
            }
        }

        // Hints. Bounded by the rail: unbounded, the line ran straight out
        // over the art plate, which is the exact class of overlap this pass
        // exists to remove.
        KeyHints {
            id: hints
            width: parent.width
            px: 13
            model: {
                // ⏎ (tap) selects/plays — folded onto SELECT so there's no separate
                // PLAY box, which keeps the row on one line. hold-⏎ = MENU.
                let m = lib.cols === 1
                        ? [["j/k", "MOVE"], ["esc", "BACK"]]
                        : [["j/k", "ROW"], ["h/l", "COLUMN"], ["esc", "BACK"]]
                // The CRT reads its legend at 24 px, so it keeps the walk and
                // the doors out: the rest is one ? away (and in hold-⏎'s menu).
                if (App.mode === "crt") {
                    m.push(["⏎", "SELECT"], ["/", "SEARCH"], ["?", "HELP"])
                    return m
                }
                m.push(["hold-⏎", "MENU"], ["⏎", "SELECT"])
                // a show with a guide: m cuts it to the guide's MYTH + TOP
                // (the CRT's short legend leaves it to ? and f)
                if (lib.hasGuide) m.push(["m", "ROADMAP"])
                m.push(["o", "SORT"], ["f", "FILTER"],
                       ["a", "QUEUE"], ["q", "PANEL"], ["c", "OUTPUT"], ["/", "SEARCH"])
                if (MediaLibrary.section === "movies") m.push(["t", "TRAILER"])
                // (b BONUS is NOT listed here: shown only on titles with extras,
                // it wrapped the row to two lines and the grid — sized off this
                // footer — jumped on every step. The EXTRAS badge marks them;
                // ? HELP lists the key.)
                if (Engine.path.length > 0 && !Engine.idle) m.push(["p", "PLAYER"], ["x", "STOP"])
                m.push(["?", "HELP"])
                return m
            }
        }
    }

    ContextMenu {
        id: ctx
        anchors.fill: parent
        topBleed: lib.topBleed   // dim the header strip too (stage sits below it)
        onPicked: (index) => lib.ctxDo(index)
        // closed() fires AFTER picked(): a pick that opened the detail page
        // (BONUS FEATURES) must keep the keys there, not hand them back to the
        // grid hidden behind it.
        onClosed: if (App.detailUri.length === 0) lib.forceActiveFocus()
    }
}
