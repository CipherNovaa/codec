import QtQuick

// Full-bleed title page (i from home/library/search): backdrop, poster,
// synopsis + meta, actions, and for shows the episode walk with watched
// ticks + resume bars. Opens on App.detailUri, closes by clearing it.
FocusScope {
    id: dv
    // int-typed return so font.pixelSize (int) bindings don't warn "double to int" (see StatsView.pxi)
    function pxi(v: real): int { return Math.round(v) }
    readonly property bool open: App.detailUri.length > 0
    visible: open || opacity > 0.01
    anchors.fill: parent

    property var info: ({})
    // The CRT inset (Main's crtL/R/T/B): the backdrop runs out to the tube's
    // edge while the page itself stays on the visible glass.
    property int bleedL: 0
    property int bleedR: 0
    property int bleedT: 0
    property int bleedB: 0
    function bx(f) { return (f * width + bleedL) / Math.max(1, width + bleedL + bleedR) }
    property var episodes: []
    property int epIdx: 0
    // The on-page EPISODES list (shows) is OFF for now — "unnecessary …
    // very unfinished, let's see without it". The page still acts on ONE
    // episode (play / queue / watched / the track rows): the one you opened it
    // from, else the show's NEXT UP — exactly the Continue Watching pick (the
    // episode played last if unfinished, else the next unwatched), else the
    // first unwatched. Flip this to bring the list (and j/k/gg/G) back.
    readonly property bool showEpisodes: false
    property double lastG: 0
    // ffprobe tracks for the focused local file (async; audio 7.1/5.1/…, subs).
    property var tracks: ({})
    // -1 = the recommendations row is not engaged, so ⏎ still plays this title.
    // h/l walks into it; ⏎ then opens that title's own page instead.
    property int moreIdx: -1
    readonly property var moreLike: info.moreLike || []
    readonly property bool isShow: (info.kind || "") === "show"
    // Season headings in the EPISODES list, when the show numbers its episodes
    // (the library's grid uses the same labels): episodes per season for the
    // "SEASON 3 // 22" heading.
    readonly property bool epSeasons: episodes.some(e => e.season && e.season !== "OTHER")
    readonly property var seasonCounts: {
        const m = ({})
        for (let i = 0; i < episodes.length; i++)
            m[episodes[i].season] = (m[episodes[i].season] || 0) + 1
        return m
    }
    // Bonus features (featurettes, deleted scenes…) under this title. The BONUS
    // plate takes the keyboard/remote focus with Down (bonusFocus) and opens
    // the BONUS FEATURES page (bonus.open) — B and a click open it directly.
    readonly property int extrasCount: info.extrasCount || 0
    property bool bonusFocus: false
    // the PLAY plate holds the focus whenever nothing else on the spine does —
    // where the page lands, so ⏎ plays
    readonly property bool playFocus: !bonusFocus && moreIdx < 0
    readonly property string playWord: {
        const ep = isShow ? episodes[epIdx] : null
        return (ep ? (ep.pct || 0) > 0.01 && !ep.watched
                   : (info.position || 0) > 60) ? "RESUME" : "PLAY"
    }
    // `direct`: opened straight from the grid (library B / hold-⏎ menu), not
    // from this page — so Back returns to the grid, the way you came in.
    property bool bonusDirect: false
    function openBonus(direct) {
        if (extrasCount <= 0) return
        // (a direct open arrives a turn after the grid's B / menu pick, which
        // made its own sound)
        if (direct !== true) Sfx.play("open")
        bonusDirect = direct === true
        // The plate presses as the page opens (it plays out under the fade).
        if (bonusPlate.visible) bonusPlate.press()
        bonusFocus = false
        bonus.show()
        forceActiveFocus()   // its keys come through this page's handler
    }
    // Back out of the bonus page (Esc / b / h / mouse or remote Back): to this
    // page if that's where it was opened, else all the way back to the grid.
    function leaveBonus() {
        Sfx.play("back")
        if (bonusDirect) close()
        else bonus.hide()
    }
    // Back/Forward history (AppController) reads this to step in and out of
    // the bonus page like any other page.
    Binding { target: App; property: "detailBonus"; value: dv.open && bonus.open }
    Connections {
        target: App
        function onDetailBonusRequested(uri) { dv.openBonusFor(uri) }
    }
    // From elsewhere (the library's hold-⏎ menu): open this title's page
    // already on its bonus features. reload() picks the request up.
    property bool bonusPending: false
    function openBonusFor(path) {
        if (App.detailUri === path) { openBonus(); return }
        bonusPending = true
        App.detailUri = path
    }

    // Same scale idiom as HomeView: every size derives from the window, so the
    // CRT (1280x1024) and the 1440p panel get one design instead of a layout
    // tuned for the small screen and stranded in the corner of the big one.
    readonly property real s: Math.max(0.95, Math.min(width / 1920, 1.35))
    readonly property int gap: Math.round(48 * s)
    // The block is sized from its own content and then centred, rather than
    // stretched to the window — 2000px-wide lines of prose are unreadable.
    // On the CRT the poster is sized off the page's HEIGHT (the 5:4 tube has
    // height to spare and width to guard): ~64% of it, seated on the middle of
    // the text block like DP-3's — the width law left a 335-px poster riding at
    // the top with a void under it.
    readonly property bool onCrt: App.mode === "crt"
    readonly property int posterW: onCrt ? Math.round(height * 0.64 / 1.5)
                                         : Math.round(Math.min(440 * s, width * 0.27))
    // The key row keeps the page's own type scale on the CRT too (24 px made it
    // the loudest line on a page of small type, and two lines tall).
    readonly property real hk: s
    // Where the content block ends as a fraction of the frame — the scrim ramp
    // keys off this so it can never wash out text on a narrower panel.
    readonly property real blockEnd:
        Math.min(1.0, (body.x + body.implicitWidth + Math.round(28 * s))
                      / Math.max(1, width))
    readonly property real blockStart:
        Math.max(0.0, (body.x - Math.round(28 * s)) / Math.max(1, width))
    readonly property int textW:
        Math.max(1, Math.round(Math.min(880 * s, width - posterW - gap
                                         - (onCrt ? 2 * Math.round(32 * s) : Math.round(120 * s)))))

    // MGS typefaces (same as HOME): headings ride mgs-codec, all the "detail"
    // body/value text rides mgs-hud. Fallbacks keep it legible if a face misses.
    FontLoader { id: mgsCodecFont; source: "qrc:/assets/mechui/mgs-codec.ttf" }
    FontLoader { id: mgsHudFont; source: "qrc:/assets/mechui/mgs-hud.ttf" }
    readonly property string codecFont: mgsCodecFont.name || Theme.monoFont
    readonly property string hudFont: mgsHudFont.name || Theme.uiFont
    // integer scale for the mech badge plates / poster frame (nearest-neighbour)
    readonly property int mpx: Math.max(2, Math.round(s * 2))
    // A film's page is one block, and on a short frame (the CRT's visible
    // 942 lines) it ran past the bottom — the key hints under the glass. The
    // MORE LIKE THIS posters are the part that can give: they shrink (to 60%
    // at most) until the block fits. Shows have their own give (the episode
    // list), so they keep full-size posters.
    // (Set after layout, not bound: the row's own height is inside the block's.)
    property real moreKTarget: 1
    property real moreK: moreKTarget
    // growing eases in; shrinking to fit stays instant, as it always was
    Behavior on moreK { enabled: dv.moreKTarget > 1.001
        NumberAnimation { duration: DS.slow; easing.type: Easing.OutCubic } }
    // Growth waits for the page to settle: the track rows arrive a beat after
    // the page opens (an async probe), and growing first would open a film
    // with big posters that then shrink.
    property bool growReady: false
    Timer { id: growSettle; interval: 900; onTriggered: { dv.growReady = true; dv.fitMore() } }
    // A short page also GROWS them (to 1.4×) into the room it leaves, on every
    // screen: a show with a two-line synopsis was a small block floating in
    // the frame ("barren"), and holding MORE LIKE THIS at the foot left
    // a hole in the middle instead ("looks like something's missing"). The
    // posters fill toward a block as tall as the frame allows (fillMargin
    // clear above and below); what they can't fill becomes at most a section
    // break above them (fillGap), and the block centres. A long film page has
    // no room to give and keeps its sizing.
    readonly property int fillMargin: Math.round((onCrt ? 72 : 96) * s)
    function fitMore() {
        let k = 1
        if (moreLike.length > 0) {
            const rest = textCol.height - moreRow.height - fillSpan
            const base = Math.round(190 * s)
            // (the CRT keeps a margin above and below the block: a film's
            // page filled the tube edge to edge, its logo jammed at the top)
            const shrinkRoom = height - (onCrt ? 2 * fillMargin : Math.round(56 * s) + Math.round(16 * s)) - rest
            const growRoom = height - 2 * fillMargin - rest
            if ((!isShow || onCrt) && shrinkRoom < base)
                k = Math.max(0.6, shrinkRoom / base)
            else if (growReady)
                k = Math.max(1, Math.min(1.4, growRoom / base))
        }
        if (Math.abs(k - moreKTarget) > 0.005)
            moreKTarget = k
        Qt.callLater(fitFill)
    }
    property real fillGap: 0
    readonly property real fillSpan: fillGap > 0 ? fillGap + textCol.spacing : 0
    function fitFill() {
        const natural = textCol.height - fillSpan
        const room = height - 2 * fillMargin - natural - textCol.spacing
        const g = Math.max(0, Math.min(Math.round(40 * s), Math.round(room)))
        if (Math.abs(g - fillGap) > 1 || (g === 0) !== (fillGap === 0))
            fillGap = g
    }
    onHeightChanged: Qt.callLater(fitMore)
    onIsShowChanged: Qt.callLater(fitMore)

    // ── Bulletproof text alignment (from the actual font files) ──────────────
    // mgs-hud: unitsPerEm 1024, ascent 384, glyph ink 0..320 (centre 160) above
    //          the baseline.  mgs-codec: ascent 512.  Fractions of the pixelSize:
    readonly property real hudAsc: 384 / 1024      // hud baseline, from the text-box top
    readonly property real hudInkC: 160 / 1024     // hud ink centre, above the baseline
    readonly property real codAsc: 512 / 1024      // codec baseline, from the text-box top
    // A hud run sharing a line with a codec label sits higher (smaller ascent);
    // this topPadding drops it so the two BASELINES meet — no eyeballed nudges.
    function hudDrop(px) { return Math.round(px * (codAsc - hudAsc)) }
    // A drawn separator/symbol centres on the hud ink line, measured from the
    // run's box top: (ascent − inkCentre)·px. Used to place dots level with text.
    function hudInkTop(px) { return px * (hudAsc - hudInkC) }

    // A middot separator DRAWN as a square (the MGS faces have no ·, so a glyph
    // there floats). Drop it into a uniform-hud Row; it self-centres on the text.
    component Dot: Item {
        property int px: 20
        property color ink: Theme.dimFg
        property real drop: 0            // extra downward shift (baseline match)
        implicitWidth: Math.max(3, Math.round(px * 0.24))
        implicitHeight: px
        Rectangle {
            width: Math.max(2, Math.round(parent.px * 0.12)); height: width; radius: width / 2
            color: parent.ink
            x: Math.round((parent.implicitWidth - width) / 2)
            y: Math.round(dv.hudInkTop(parent.px) + parent.drop - height / 2)
        }
    }

    function reload() {
        if (App.detailUri.length === 0) {
            // The page closed (Esc from the bonus page, `i`, playing an extra):
            // the bonus page goes with it. Left open, it kept reloading the
            // whole extras scan on every resume save while the extra played.
            bonus.hide()
            return
        }
        info = MediaLibrary.detail(App.detailUri)
        if (!info.path) { // unknown path (yt etc.) — nothing to show
            bonusPending = false
            App.detailUri = ""
            return
        }
        episodes = info.episodes || []
        epIdx = 0
        moreIdx = -1
        bonusFocus = false   // land on the title (⏎ plays); Down → BONUS FEATURES
        bonus.hide()
        if (bonusPending) {
            bonusPending = false
            Qt.callLater(() => openBonus(true))
        }
        let focus = -1
        for (let i = 0; i < episodes.length; i++)
            if (episodes[i].path === info.focusPath) { focus = i; break }
        if (focus < 0 && isShow)
            focus = nextUpIndex()
        epIdx = Math.max(0, focus)
        epList.positionViewAtIndex(epIdx, ListView.Center)
        // Probe the focused file's tracks (async); clear stale ones first.
        tracks = ({})
        App.probeMedia(dv.currentPath())
        growReady = false
        growSettle.restart()
    }

    Connections {
        target: App
        function onDetailUriChanged() { dv.reload() }
        function onMediaProbed(path, info) {
            if (path !== dv.currentPath()) return
            dv.tracks = info
            // the rows are in: let the poster row grow once they've laid out
            if (!dv.growReady) { growSettle.stop(); Qt.callLater(() => { dv.growReady = true; dv.fitMore() }) }
        }
    }
    // Shows: moving through episodes re-probes the newly focused file.
    // Keep the previous episode's tracks on screen until the new probe returns,
    // rather than blanking them — a cleared→refilled row reflows the column and
    // makes the whole page jump under the episode list on every step.
    onEpIdxChanged: if (isShow) App.probeMedia(currentPath())

    // XMB presence: no pop — it FADES in and out, as if it were always up there
    // and you just turned toward it. Soft symmetric ease, a whisper of settle,
    // and it leaves the same way it arrived.
    opacity: dv.open ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 440; easing.type: Easing.InOutQuad } }
    transform: Translate {
        id: dvSlide
        y: dv.open ? 0 : Math.round(12 * dv.s)
        Behavior on y { NumberAnimation { duration: 440; easing.type: Easing.InOutQuad } }
    }
    onVisibleChanged: if (visible) forceActiveFocus()
    // Reopened inside the close fade, the page never stopped being visible —
    // so take the keys on OPEN too, or they stay with whatever opened it.
    onOpenChanged: if (open) forceActiveFocus()

    // Every way out comes through here (esc, h, the wheel over HOME, a click
    // on the backdrop), so `back` is cued here; one that plays (playCurrent)
    // cues `select`, which outranks it.
    // `away` = leaving for something else (playing, the cast picker) rather
    // than stepping back: only a step back tells HOME (backedOut), which
    // returns to the half info the page was opened from.
    signal backedOut()
    function close(away) {
        const was = open
        if (was) Sfx.play("back")
        if (was && !away) backedOut()
        App.detailUri = ""
    }
    // MORE LIKE THIS is a horizontal strip: its steps pan with the selection
    function morePan() {
        return moreIdx >= 0 && moreLike.length > 1 ? (moreIdx / (moreLike.length - 1) - 0.5) * 0.5 : 0
    }

    // ── Track/codec prettifiers ───────────────────────────────────────────
    // Raw ffprobe codec names (HDMV_PGS_SUBTITLE, EAC3…) are unreadable and
    // repeat per language; these map them to friendly labels, and the *Line
    // helpers dedupe so a wall of "GER HDMV_PGS_SUBTITLE · GER HDMV_PGS…"
    // collapses to a clean language list.
    readonly property var _codecMap: ({
        "HDMV_PGS_SUBTITLE": "PGS", "PGSSUB": "PGS", "DVD_SUBTITLE": "VobSub",
        "SUBRIP": "SRT", "MOV_TEXT": "SRT", "ASS": "ASS", "SSA": "SSA",
        "WEBVTT": "VTT", "DVB_SUBTITLE": "DVB", "DVB_TELETEXT": "Teletext",
        "EAC3": "DD+", "AC3": "DD", "DTS": "DTS", "TRUEHD": "TrueHD",
        "AAC": "AAC", "FLAC": "FLAC", "OPUS": "Opus", "MP3": "MP3", "PCM": "PCM",
        "HEVC": "HEVC", "H264": "H.264", "AVC": "H.264", "AV1": "AV1", "VC1": "VC-1"
    })
    readonly property var _langMap: ({
        "ENG": "English", "FRE": "French", "FRA": "French", "GER": "German",
        "DEU": "German", "SPA": "Spanish", "ITA": "Italian", "DUT": "Dutch",
        "NLD": "Dutch", "DAN": "Danish", "FIN": "Finnish", "NOR": "Norwegian",
        "SWE": "Swedish", "POR": "Portuguese", "RUS": "Russian", "JPN": "Japanese",
        "CHI": "Chinese", "ZHO": "Chinese", "KOR": "Korean", "ARA": "Arabic",
        "POL": "Polish", "CZE": "Czech", "CES": "Czech", "HUN": "Hungarian",
        "TUR": "Turkish", "GRE": "Greek", "ELL": "Greek", "HEB": "Hebrew",
        "THA": "Thai", "HIN": "Hindi", "UKR": "Ukrainian", "RUM": "Romanian",
        "RON": "Romanian", "HRV": "Croatian", "SRP": "Serbian", "IND": "Indonesian",
        "VIE": "Vietnamese", "UND": ""
    })
    // Make arbitrary metadata safe for the MGS faces — ONE rule app-wide:
    // Theme.mgsSafe keeps every character the faces draw (accents, dashes,
    // quotes, super/subscripts since the 2026-10 glyph pass) and folds only
    // what they lack. (This page used to carry its own copy that stripped every
    // accent: "Gert Fröbe" read "GERT FROBE".)
    function mgsSafe(s) {
        return (s === undefined || s === null) ? "" : Theme.mgsSafe(String(s))
    }
    function prettyCodec(c) { c = (c || "").toUpperCase(); return dv._codecMap[c] || c }
    function prettyLang(l) { l = (l || "").toUpperCase(); return dv._langMap[l] !== undefined ? dv._langMap[l] : l }
    // Return arrays of segments (the TrackLine draws its own · separators, so the
    // values must NOT be pre-joined with a font middot the MGS faces don't have).
    function subsArr(subs) {
        if (!subs || !subs.length) return []
        let seen = ({}), out = []
        for (let i = 0; i < subs.length; i++) {
            const lang = dv.prettyLang(subs[i].lang), cod = dv.prettyCodec(subs[i].codec)
            const key = lang + "|" + cod
            if (seen[key]) continue
            seen[key] = true
            out.push(lang ? (cod ? lang + " " + cod : lang) : cod)
        }
        return out
    }
    function audioArr(audio) {
        if (!audio || !audio.length) return []
        let seen = ({}), out = []
        for (let i = 0; i < audio.length; i++) {
            const a = audio[i], lang = dv.prettyLang(a.lang), cod = dv.prettyCodec(a.codec)
            let s = ((a.layout || "") + " " + cod).trim()
            if (lang) s += " " + lang
            if (seen[s]) continue
            seen[s] = true
            out.push(s)
        }
        return out
    }
    function editionLabel(p) {
        const s = (p || "").toUpperCase()
        if (/EXTENDED/.test(s)) return "EXTENDED"
        if (/DIRECTOR/.test(s)) return "DIRECTOR'S CUT"
        if (/UNRATED/.test(s)) return "UNRATED"
        if (/THEATRICAL/.test(s)) return "THEATRICAL"
        if (/REMASTER/.test(s)) return "REMASTERED"
        return ""
    }
    // Opened on the show itself: the Continue Watching card's episode for this
    // show if it has one, else the first episode not yet watched, else the first.
    function nextUpIndex() {
        const cw = MediaLibrary.continueWatching(30)
        for (let c = 0; c < cw.length; c++) {
            if (cw[c].kind !== "episode" || cw[c].heroTitle !== info.title)
                continue
            for (let i = 0; i < episodes.length; i++)
                if (episodes[i].path === cw[c].path) return i
        }
        for (let i = 0; i < episodes.length; i++)
            if (!episodes[i].watched) return i
        return 0
    }
    function currentPath() {
        return isShow ? (episodes[epIdx] ? episodes[epIdx].path : "")
                      : (info.path || "")
    }
    function playCurrent() {
        const p = currentPath()
        if (p.length > 0) { Sfx.play("select"); close(true); App.play(p) }
    }
    Connections {
        target: App
        enabled: App.detailUri.length > 0
        function onQueueAddRequested() { queueCurrent() }
        function onTrailerRequested() { App.playTrailer(info.title || "", String(info.year || "")) }
    }
    function queueCurrent() {
        const p = currentPath()
        if (p.length === 0) {
            Sfx.play("bump")
            return
        }
        Sfx.play("select")
        // the row's second line: the year and the file's own formats (2017 · 4K · DV)
        const sub = [info.year > 0 ? String(info.year) : ""].concat(info.flags || [])
                    .filter(s => s.length > 0).join(" · ")
        Queue.add({uri: p, title: info.title, subtitle: sub, artUrl: info.poster.length > 0
                       ? Theme.art(info.poster) : "",
                   durationS: (info.runtimeMin || 0) * 60, kind: info.kind,
                   sourceId: "library"})
        App.notify("QUEUED · " + info.title)
    }

    function toggleWatched() {
        // A show's page lists no episodes, so w can't mean "the selected one"
        // (it silently flipped the hidden next-up episode): it marks the SHOW,
        // as the library's own menu does.
        if (isShow && !showEpisodes) {
            const all = episodes.length > 0 && episodes.every(e => e.watched)
            App.setWatchedMany(MediaLibrary.episodePaths(info.title || ""), !all)
            App.notify(all ? "SHOW ▸ UNWATCHED" : "SHOW ▸ WATCHED")
            reloadTimer.restart()
            return
        }
        const p = currentPath()
        if (p.length > 0) {
            const target = isShow ? !episodes[epIdx].watched : !info.watched
            App.setWatched(p, target)
            reloadTimer.restart() // let the store settle, then re-pull
        }
    }

    Keys.onPressed: (event) => {
        // The BONUS FEATURES page has the keys while it's up (see BonusFeatures).
        if (bonus.open) {
            if (bonus.handleKey(event)) event.accepted = true
            return
        }
        switch (event.key) {
        case Qt.Key_Down: case Qt.Key_J:
            // The page's SPINE, top to bottom: the title (⏎ plays; where the
            // page lands) → BONUS FEATURES → MORE LIKE THIS (h/l along it).
            // Down walks it. Past the bottom it backs out of the page ONLY over
            // HOME — HOME's XMB walk: up opened this, down goes back. Opened from
            // the library with i there's nothing below, so Down just stops (it
            // used to close the page from the bonus plate, skipping the row).
            // (PLAY and BONUS FEATURES share the top row: ←/→ between them.)
            if (isShow && showEpisodes && epIdx < episodes.length - 1) { epIdx++; Sfx.play("move") }
            else if (moreIdx < 0 && moreLike.length > 0) { bonusFocus = false; moreIdx = 0; Sfx.play("move", morePan()) }
            else if (App.stage === "home") close()   // the bottom — over HOME only
            else Sfx.play("bump")
            break
        case Qt.Key_Up: case Qt.Key_K:
            if (moreIdx >= 0) { moreIdx = -1; bonusFocus = false; Sfx.play("move") }   // back to PLAY
            else if (isShow && showEpisodes && epIdx > 0) { epIdx--; Sfx.play("move") }
            else Sfx.play("bump")   // the top row: nothing above PLAY
            break
        case Qt.Key_P:
            playCurrent(); break   // play from anywhere on the spine
        case Qt.Key_B:
            openBonus(); break
        case Qt.Key_G:
            // vim: gg / G through a show's episode list.
            if (!isShow || !showEpisodes) return
            if (event.modifiers & Qt.ShiftModifier) {
                const was = epIdx
                epIdx = episodes.length - 1
                Sfx.play(epIdx === was ? "bump" : "move")
            } else {
                const now = Date.now()
                if (now - lastG < 450) { const was = epIdx; epIdx = 0; Sfx.play(epIdx === was ? "bump" : "move") }
                lastG = now
            }
            // A 200-row jump outruns the highlight follow (the view stopped
            // around S01E10 with the selection off screen) — place it directly.
            epList.positionViewAtIndex(epIdx, epIdx >= episodes.length - 1
                                              ? ListView.End : ListView.Center)
            break
        case Qt.Key_Return: case Qt.Key_Enter:
            if (bonusFocus)
                openBonus()
            else if (moreIdx >= 0 && moreLike[moreIdx]) {
                Sfx.play("open")
                App.detailUri = moreLike[moreIdx].path   // walk to that title
            } else
                playCurrent()
            break
        case Qt.Key_L: case Qt.Key_Right:
            // along the row you're on: PLAY → BONUS FEATURES, then on into
            // MORE LIKE THIS; along MORE LIKE THIS
            if (moreIdx >= 0) {
                const was = moreIdx
                moreIdx = Math.min(moreLike.length - 1, moreIdx + 1)
                Sfx.play(moreIdx === was ? "bump" : "move", morePan())
            }
            else if (!bonusFocus && extrasCount > 0) { bonusFocus = true; Sfx.play("move") }
            else if (moreLike.length > 0) { bonusFocus = false; moreIdx = 0; Sfx.play("move", morePan()) }
            else Sfx.play("bump")
            break
        case Qt.Key_T:
            App.playTrailer(info.title || "", String(info.year || "")); break
        // The library's grammar: a adds to the queue, q opens/closes the panel.
        case Qt.Key_A: queueCurrent(); break
        case Qt.Key_Q: App.queueOpen = !App.queueOpen; break
        case Qt.Key_W: toggleWatched(); break
        case Qt.Key_C: close(true); App.outputOpen = true; break
        case Qt.Key_H: case Qt.Key_Left:
            if (bonusFocus) { bonusFocus = false; Sfx.play("move") }
            else if (moreIdx >= 0) { moreIdx--; Sfx.play("move", morePan()) }   // back out of the row first
            else close()
            break
        case Qt.Key_I: case Qt.Key_Escape:
            close(); break
        default: return
        }
        event.accepted = true
    }
    Timer { id: reloadTimer; interval: 50; onTriggered: dv.reload() }

    // HOME's XMB walk, the way back: scroll up on HOME opens the info panel,
    // up again this full page — so scrolling DOWN here closes it again. Only
    // over HOME (a page opened from the grid keeps the wheel for its lists),
    // and the scrollable lists still take the wheel first (a Flickable passes
    // it on only past its ends). One step per 120° notch; the trackball ball
    // (pixel deltas) must roll 3 notches' worth, as on HOME.
    WheelHandler {
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        enabled: dv.open && App.stage === "home" && !bonus.open
        property real accum: 0
        onWheel: (e) => {
            const ball = e.pixelDelta.x !== 0 || e.pixelDelta.y !== 0
            accum += e.angleDelta.y
            if (accum > 0) { accum = 0; return }   // up: nothing above the full page
            if (accum <= -(ball ? 360 : 120)) { accum = 0; dv.close() }
        }
    }

    Rectangle { anchors.fill: parent; anchors.leftMargin: -dv.bleedL; anchors.rightMargin: -dv.bleedR
                anchors.topMargin: -dv.bleedT; anchors.bottomMargin: -dv.bleedB; color: Theme.bg }

    Image {
        anchors.fill: parent
        anchors.leftMargin: -dv.bleedL
        anchors.rightMargin: -dv.bleedR
        anchors.topMargin: -dv.bleedT
        anchors.bottomMargin: -dv.bleedB
        source: (info.fanart || "").length > 0 ? Theme.art(info.fanart) : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        // The backdrop is the SAME fanart already showing behind (this title is
        // the one that was selected), so it must NOT slide up on open — cancel the
        // entrance translate here so it sits perfectly still while the content
        // glides in over it. No pop, no re-pull.
        transform: Translate { y: -dvSlide.y }
    }
    // Readability scrim, centred on the block. The content is centred now, so
    // the scrim is opaque UNDER the reading column and feathers out to BOTH
    // margins, where the backdrop is let through equally on each side. Both
    // edges are measured (blockStart/blockEnd) rather than guessed, so it holds
    // whether the block takes 66% of a 16:9 panel or 90% of the 5:4 CRT.
    // (The scrims cover the CRT bleed too; bx() maps a fraction of the page
    // onto the wider bled rectangle.)
    Rectangle {
        anchors.fill: parent
        anchors.leftMargin: -dv.bleedL
        anchors.rightMargin: -dv.bleedR
        anchors.topMargin: -dv.bleedT
        anchors.bottomMargin: -dv.bleedB
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: Theme.withAlpha(Theme.bg, 0.30) }
            GradientStop { position: dv.bx(Math.max(0.02, dv.blockStart - 0.06))
                           color: Theme.withAlpha(Theme.bg, 0.62) }
            GradientStop { position: dv.bx(Math.max(0.06, dv.blockStart))
                           color: Theme.withAlpha(Theme.bg, 0.9) }
            GradientStop { position: dv.bx(Math.min(0.94, dv.blockEnd))
                           color: Theme.withAlpha(Theme.bg, 0.9) }
            GradientStop { position: dv.bx(Math.min(0.98, dv.blockEnd + 0.06))
                           color: Theme.withAlpha(Theme.bg, 0.62) }
            GradientStop { position: 1.0; color: Theme.withAlpha(Theme.bg, 0.30) }
        }
    }
    // Top and foot stay dark: the title sits high and the recommendation strip
    // sits low, and both cross into the part of the frame the horizontal ramp
    // has already let go of.
    Rectangle {
        anchors.fill: parent
        anchors.leftMargin: -dv.bleedL
        anchors.rightMargin: -dv.bleedR
        anchors.topMargin: -dv.bleedT
        anchors.bottomMargin: -dv.bleedB
        gradient: Gradient {
            GradientStop { position: 0.0; color: Theme.withAlpha(Theme.bg, 0.55) }
            GradientStop { position: 0.22; color: "transparent" }
            GradientStop { position: 0.72; color: "transparent" }
            GradientStop { position: 1.0; color: Theme.withAlpha(Theme.bg, 0.72) }
        }
    }
    MouseArea { anchors.fill: parent; onClicked: dv.close() }

    Row {
        id: body
        // Children carry their own widths (dv.posterW / dv.textW), so the Row's
        // implicit width is the real content width. Reading body.width from a
        // child would be a binding loop.
        //
        // Centred: the poster+text cluster sits in the middle of the frame with
        // the backdrop breathing on both margins. Falls back to a small left
        // inset only if the block is somehow wider than the panel (never on the
        // CRT, where it already very nearly fills the width).
        x: Math.max(Math.round(dv.width * (dv.onCrt ? 0.02 : 0.04)),
                    Math.round((dv.width - implicitWidth) / 2))
        // Shows anchor top (the episode list wants the room); movies centre on
        // the whole block, height included, so nothing rides high on a 1440p
        // panel the way it did before.
        // (With the episode list off, a show on the CRT has nothing below its
        // block: it centres like a film — top-anchored it left ~220 px of the
        // tube empty under MORE LIKE THIS.)
        y: dv.fillGap > 0 || dv.moreK > 1.01 ? Math.max(dv.fillMargin, Math.round((dv.height - height) / 2))
         : dv.isShow && (dv.showEpisodes || !dv.onCrt) ? Math.round(96 * dv.s)
                     : Math.max(Math.round(56 * dv.s),
                                Math.round((dv.height - height) / 2))
        spacing: dv.gap

        // ── Poster ────────────────────────────────────────────────────────
        Rectangle {
            id: posterBox
            width: dv.posterW
            height: width * 1.5
            color: "#05080e"
            clip: true
            // Seated a touch lower than the title so the big poster centres nicely
            // against the reading block rather than riding at the very top. (The
            // CRT's taller poster centres on the block exactly.)
            transform: Translate { y: dv.onCrt || dv.fillGap > 0 || dv.moreK > 1.01
                                         ? Math.max(0, Math.round((textCol.height - posterBox.height) / 2))
                                         : Math.round(48 * dv.s) }
            Image {
                anchors.fill: parent   // fills right up to the frame on every edge
                source: (dv.info.poster || "").length > 0
                        ? Theme.art(dv.info.poster) : ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
            }
            // Movie resume bar along the poster foot.
            Rectangle {
                visible: !dv.isShow && (dv.info.duration || 0) > 0
                         && (dv.info.position || 0) > 0
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                height: 4
                width: parent.width * Math.min(1,
                           (dv.info.position || 0) / (dv.info.duration || 1))
                color: Theme.accent
                z: 1
            }
            // Dedicated drawn poster frame (the author's art) — hollow 9-slice, so the
            // poster shows through and it fits any ratio. Lives at
            // assets/mechui/plates/panel-poster.png and hot-reloads on save.
            MechPanel {
                anchors.fill: parent
                kind: "poster"
                px: dv.mpx
                z: 2
            }
        }

        // ── Text column ───────────────────────────────────────────────────
        // Under the BONUS FEATURES page it fades out but keeps its size, so the
        // block (and the poster beside it) stays exactly where it was.
        Column {
            id: textCol
            onHeightChanged: Qt.callLater(dv.fitMore)
            width: dv.textW
            // (a tighter rhythm on the CRT: a film's page is taller than the tube)
            spacing: Math.round((dv.onCrt ? 13 : 18) * dv.s)
            opacity: bonus.open ? 0 : 1
            enabled: !bonus.open
            Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.InOutQuad } }

            // Title: the clearlogo (dynamic title art) when we have it, else the
            // text title. Left-aligned to the column, height-first so squat logos
            // still read big, and capped to the column width.
            Item {
                id: dTitleSlot
                width: parent.width
                height: Math.round(88 * dv.s)
                readonly property bool hasLogo: (dv.info.clearlogo || "").length > 0

                Image {
                    id: dLogo
                    // Baseline-aligned to the slot foot: the logo art is trimmed to
                    // its glyphs, so a bottom anchor lands every title at the same
                    // line regardless of shape (centring floated squat logos high).
                    anchors.left: parent.left
                    anchors.bottom: parent.bottom
                    visible: dTitleSlot.hasLogo
                    source: dTitleSlot.hasLogo ? Theme.art(dv.info.clearlogo) : ""
                    fillMode: Image.PreserveAspectFit
                    horizontalAlignment: Image.AlignLeft
                    asynchronous: true
                    mipmap: true
                    readonly property real asp: sourceSize.height > 0
                                                ? sourceSize.width / sourceSize.height : 3
                    height: Math.min(dTitleSlot.height, dTitleSlot.width / Math.max(asp, 0.1))
                    width: height * asp
                }
                Text {
                    anchors.left: parent.left
                    anchors.bottom: parent.bottom
                    visible: !dTitleSlot.hasLogo
                    width: parent.width
                    text: dv.mgsSafe((dv.info.title || "").toUpperCase())
                    color: Theme.fg
                    font.family: dv.codecFont
                    font.pixelSize: dv.pxi(Math.round(51 * dv.s))
                    font.letterSpacing: Math.round(6 * dv.s)
                    elide: Text.ElideRight
                }
            }

            // Every cell gets the SAME box height + vertical centering, so the ★
            // rating (whose glyph comes from a fallback face with taller metrics)
            // sits level with the rest instead of dropping in a top-aligned Row.
            Row {
                spacing: Math.round(22 * dv.s)
                readonly property int metaH: Math.round(26 * dv.s)
                Text {
                    visible: (dv.info.year || 0) > 0
                    height: parent.metaH; verticalAlignment: Text.AlignVCenter
                    text: String(dv.info.year || "")
                    color: Theme.accent
                    font.family: dv.hudFont
                    font.pixelSize: dv.pxi(Math.round(20 * dv.s))
                    font.letterSpacing: Math.round(2 * dv.s)
                }
                Text {
                    visible: (dv.info.runtimeMin || 0) > 0
                    height: parent.metaH; verticalAlignment: Text.AlignVCenter
                    text: dv.info.runtimeMin + " MIN"
                    color: Theme.dimFg
                    font.family: dv.hudFont
                    font.pixelSize: dv.pxi(Math.round(20 * dv.s))
                    font.letterSpacing: Math.round(2 * dv.s)
                }
                // ★ comes from a fallback face (MGS has no star); baseline-anchor
                // it to the number so it sits level instead of floating.
                Item {
                    visible: (dv.info.rating || 0) > 0
                    height: parent.metaH
                    implicitWidth: rNum.x + rNum.implicitWidth
                    Text {
                        id: rStar
                        x: 0
                        anchors.baseline: rNum.baseline
                        text: "★"
                        color: Theme.dimFg
                        font.family: dv.hudFont
                        font.pixelSize: dv.pxi(Math.round(20 * dv.s))
                    }
                    Text {
                        id: rNum
                        anchors.verticalCenter: parent.verticalCenter
                        x: rStar.implicitWidth + Math.round(6 * dv.s)
                        text: Number(dv.info.rating || 0).toFixed(1)
                        color: Theme.dimFg
                        font.family: dv.hudFont
                        font.pixelSize: dv.pxi(Math.round(20 * dv.s))
                        font.letterSpacing: Math.round(2 * dv.s)
                    }
                }
                Text {
                    height: parent.metaH; verticalAlignment: Text.AlignVCenter
                    text: (dv.info.genres || "").toUpperCase()
                    color: Theme.dimFg
                    font.family: dv.hudFont
                    font.pixelSize: dv.pxi(Math.round(20 * dv.s))
                    font.letterSpacing: Math.round(2 * dv.s)
                }
                Text {
                    visible: !dv.isShow && (dv.info.watched === true)
                    height: parent.metaH; verticalAlignment: Text.AlignVCenter
                    text: "✔ WATCHED"
                    color: Theme.accent
                    font.family: dv.hudFont
                    font.pixelSize: dv.pxi(Math.round(20 * dv.s))
                    font.letterSpacing: Math.round(2 * dv.s)
                }
            }

            // ── Quality badges + watch count ──────────────────────────────
            // Resolution / HDR / REMUX chips, and how many times it's been
            // finished. Shows carry per-file quality on their episodes, so this
            // row is movies-only.
            Flow {
                width: parent.width
                spacing: Math.round(8 * dv.s)
                visible: !dv.isShow

                // Each media flag rides its OWN drawn mech plate (the badges the author
                // drew for HOME). A longer label (7.1 AAC, HEVC, editions) STRETCHES
                // the plate from the middle — 9-slice, so the drawn corners never
                // distort. Formats without a bespoke plate fall back to the generic
                // banded chip (MechChip.badgeKind).
                component Badge: MechChip {
                    plateStyle: "badge"
                    px: dv.mpx
                    ink: "#eef4f8"
                    font.family: dv.hudFont
                    // the HUD face's own 16-px grid: crisp at every scale (mpx·6
                    // drew 12 / 18 px — between its pixels, soft on the laptop/CRT)
                    font.pixelSize: 16
                    font.letterSpacing: Math.round(1 * dv.s)
                }

                Badge {
                    visible: (dv.info.resolution || "").length > 0
                    flag: dv.info.resolution || ""
                    text: dv.info.resolution || ""
                }
                Badge { visible: (dv.info.flags || []).indexOf("HDR10") >= 0; flag: "HDR"; text: "HDR" }
                Badge {
                    visible: (dv.info.qualityLine || "").indexOf("REMUX") >= 0
                    flag: "REMUX"; text: "REMUX"
                }
                Badge {
                    visible: (dv.tracks.videoCodec || "").length > 0
                    flag: dv.prettyCodec(dv.tracks.videoCodec || "")
                    text: dv.prettyCodec(dv.tracks.videoCodec || "")
                }
                Badge {
                    // Probe flags (stream metadata), NOT a filename regex — so a
                    // hidden-DV film (no "DV" token in the name) still badges DV.
                    visible: (dv.info.flags || []).indexOf("DV") >= 0
                    flag: "DV"; text: "DV"
                }
                Badge {
                    visible: !!(dv.tracks.audio && dv.tracks.audio.length > 0)
                    // flag = layout only (7.1 → badge-71), text carries the codec too
                    flag: (dv.tracks.audio && dv.tracks.audio.length > 0)
                          ? (dv.tracks.audio[0].layout || "") : ""
                    text: (dv.tracks.audio && dv.tracks.audio.length > 0)
                          ? ((dv.tracks.audio[0].layout || "") + " "
                             + dv.prettyCodec(dv.tracks.audio[0].codec || "")).trim()
                          : ""
                }
                Badge {
                    // Probe flags (audio stream `profile` carries Atmos), NOT the
                    // filename — so an untagged Atmos track still badges ATMOS.
                    visible: (dv.info.flags || []).indexOf("ATMOS") >= 0
                    flag: "ATMOS"; text: "ATMOS"
                }
                Badge {
                    visible: dv.editionLabel(dv.info.path || "").length > 0
                    flag: dv.editionLabel(dv.info.path || "")
                    text: dv.editionLabel(dv.info.path || "")
                }
                Badge {
                    visible: (dv.info.watchCount || 0) > 0
                    flag: "WATCHED"; text: "WATCHED ×" + (dv.info.watchCount || 0)
                }
                Badge {
                    visible: dv.extrasCount > 0
                    flag: "EXTRAS"; text: "EXTRAS"
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: dv.openBonus()
                    }
                }
            }

            // ── Watch progress bar (movies mid-watch) ─────────────────────
            Column {
                width: parent.width
                spacing: Math.round(6 * dv.s)
                visible: !dv.isShow && (dv.info.pct || 0) > 0.001
                         && (dv.info.watched !== true)
                Item {
                    width: parent.width
                    height: Math.round(14 * dv.s)
                    Text {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: Math.round((dv.info.pct || 0) * 100) + "% WATCHED"
                        color: Theme.accent
                        font.family: dv.hudFont
                        font.pixelSize: dv.pxi(Math.round(16 * dv.s))
                        font.letterSpacing: Math.round(2 * dv.s)
                    }
                    Text {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: App.prettyTime(dv.info.position || 0)
                              + " / " + App.prettyTime(dv.info.duration || 0)
                        color: Theme.dimFg
                        font.family: dv.hudFont
                        font.pixelSize: dv.pxi(Math.round(16 * dv.s))
                    }
                }
                Rectangle {
                    width: parent.width
                    height: Math.round(4 * dv.s)
                    radius: 2
                    color: Theme.surfaceHi
                    Rectangle {
                        width: parent.width * Math.min(1, dv.info.pct || 0)
                        height: parent.height
                        radius: 2
                        color: Theme.accent
                    }
                }
            }

            // ── Tracks (ffprobe: audio layouts, subtitle languages) ───────
            Column {
                width: parent.width
                spacing: Math.round(5 * dv.s)
                visible: (dv.tracks.audio && dv.tracks.audio.length > 0)
                         || (dv.tracks.subs && dv.tracks.subs.length > 0)
                         || (dv.tracks.videoRes || "").length > 0

                // codec LABEL + hud VALUE segments with DRAWN dot separators. The
                // value Flow is baseline-dropped (hudDrop) so its text sits level
                // with the taller-ascent codec label; the dots self-centre on the
                // hud ink line. Bulletproof — no per-row eyeballing.
                component TrackLine: Row {
                    property string tag
                    property var vals: []
                    readonly property int tpx: dv.pxi(Math.round(15 * dv.s))
                    spacing: Math.round(10 * dv.s)
                    visible: vals.length > 0
                    Text {
                        width: Math.round(64 * dv.s)
                        text: parent.tag
                        color: Theme.accent
                        font.family: dv.codecFont
                        font.pixelSize: parent.tpx
                        font.letterSpacing: Math.round(2 * dv.s)
                    }
                    Flow {
                        width: dv.textW - Math.round(84 * dv.s)
                        topPadding: dv.hudDrop(parent.tpx)   // baseline-align hud value with codec label
                        Repeater {
                            model: parent.parent.vals
                            delegate: Row {
                                Dot {
                                    visible: index > 0
                                    px: dv.pxi(Math.round(15 * dv.s))
                                    ink: Theme.withAlpha(Theme.fg, 0.5)
                                    anchors.verticalCenter: undefined
                                }
                                Text {
                                    leftPadding: Math.round(7 * dv.s)
                                    rightPadding: Math.round(7 * dv.s)
                                    text: modelData
                                    color: Theme.withAlpha(Theme.fg, 0.82)
                                    font.family: dv.hudFont
                                    font.pixelSize: dv.pxi(Math.round(15 * dv.s))
                                    font.letterSpacing: Math.round(1 * dv.s)
                                }
                            }
                        }
                    }
                }

                TrackLine {
                    tag: "VIDEO"
                    vals: {
                        let p = []
                        if ((dv.tracks.videoRes || "").length > 0) p.push(dv.tracks.videoRes)
                        if ((dv.tracks.videoCodec || "").length > 0) p.push(dv.tracks.videoCodec)
                        return p
                    }
                }
                TrackLine {
                    tag: "AUDIO"
                    vals: dv.audioArr(dv.tracks.audio)
                }
                TrackLine {
                    tag: "SUBS"
                    vals: dv.subsArr(dv.tracks.subs)
                }
            }

            Text {
                width: parent.width
                textFormat: Text.PlainText   // TMDB plot — render literally, never as rich text
                text: dv.mgsSafe(dv.info.plot)
                color: Theme.withAlpha(Theme.fg, 0.85)
                font.family: dv.hudFont
                font.pixelSize: dv.pxi(Math.round(22 * dv.s))
                lineHeight: 1.35
                wrapMode: Text.Wrap
                maximumLineCount: dv.isShow ? 4 : 10
                elide: Text.ElideRight
            }

            // ── Director + cast ───────────────────────────────────────────
            Row {
                spacing: Math.round(10 * dv.s)
                visible: (dv.info.director || "").length > 0
                Text {
                    text: dv.isShow ? "CREATED BY" : "DIRECTED BY"
                    color: Theme.accent
                    font.family: dv.codecFont
                    font.pixelSize: dv.pxi(Math.round(16 * dv.s))
                    font.letterSpacing: Math.round(3 * dv.s)
                }
                Text {
                    topPadding: dv.hudDrop(dv.pxi(Math.round(16 * dv.s)))   // baseline-align with the codec label
                    text: dv.mgsSafe((dv.info.director || "").toUpperCase())
                    color: Theme.withAlpha(Theme.fg, 0.85)
                    font.family: dv.hudFont
                    font.pixelSize: dv.pxi(Math.round(16 * dv.s))
                    font.letterSpacing: Math.round(2 * dv.s)
                }
            }

            // ── Facts: writer · studio · country · language · box office ──
            // The metadata Kodi shows that codec was missing, in codec's own
            // label/value grammar. Each cell only appears when it has a value.
            Flow {
                width: parent.width
                spacing: Math.round(30 * dv.s)
                visible: factRep.count > 0
                Repeater {
                    id: factRep
                    model: {
                        const i = dv.info, out = []
                        if ((i.writer || "").length) out.push({ k: "WRITTEN BY", v: i.writer })
                        if ((i.studio || "").length) out.push({ k: "STUDIO", v: i.studio })
                        if ((i.country || "").length) out.push({ k: "COUNTRY", v: i.country })
                        if ((i.language || "").length) out.push({ k: "LANGUAGE", v: i.language })
                        const rev = i.revenue || 0, bud = i.budget || 0
                        if (rev > 0 || bud > 0) {
                            const money = n => "$" + Number(n).toLocaleString(Qt.locale("en_US"), "f", 0)
                            // "/" — a NATIVE mgs glyph (◂ floated from a fallback face),
                            // and a plain pairing: the "<" it replaced read as a false
                            // comparison ("$272,742,922 < $19,000,000").
                            let v = rev > 0 && bud > 0 ? money(rev) + "  /  " + money(bud)
                                  : rev > 0 ? money(rev) : money(bud) + " budget"
                            out.push({ k: rev > 0 && bud > 0 ? "REVENUE / BUDGET" : rev > 0 ? "REVENUE" : "BUDGET", v: v })
                        }
                        return out
                    }
                    Column {
                        spacing: Math.round(3 * dv.s)
                        Text {
                            text: modelData.k
                            color: Theme.accent
                            font.family: dv.codecFont
                            font.pixelSize: dv.pxi(Math.round(15 * dv.s))
                            font.letterSpacing: Math.round(2 * dv.s)
                        }
                        Text {
                            text: dv.mgsSafe(modelData.v)
                            color: Theme.withAlpha(Theme.fg, 0.85)
                            font.family: dv.hudFont
                            font.pixelSize: dv.pxi(Math.round(20 * dv.s))
                        }
                    }
                }
            }

            Flow {
                width: parent.width
                spacing: Math.round(26 * dv.s)
                visible: (dv.info.cast || []).length > 0
                Repeater {
                    model: (dv.info.cast || []).slice(0, 8)
                    Column {
                        spacing: 1
                        Text {
                            text: dv.mgsSafe(modelData.name)
                            color: Theme.withAlpha(Theme.fg, 0.9)
                            font.family: dv.hudFont
                            font.pixelSize: dv.pxi(Math.round(20 * dv.s))
                        }
                        Text {
                            visible: (modelData.role || "").length > 0
                            text: dv.mgsSafe(modelData.role)
                            color: Theme.dimFg
                            font.family: dv.hudFont
                            font.pixelSize: dv.pxi(Math.round(15 * dv.s))
                            font.letterSpacing: Math.round(1 * dv.s)
                        }
                    }
                }
            }

            // ── Episodes (shows only; off — see showEpisodes) ──────────────
            Text {
                visible: dv.isShow && dv.showEpisodes
                text: "EPISODES // " + dv.episodes.length
                color: Theme.accent
                font.family: dv.codecFont
                font.pixelSize: dv.pxi(Math.round(18 * dv.s))
                font.letterSpacing: Math.round(4 * dv.s)
            }
            ListView {
                id: epList
                visible: dv.isShow && dv.showEpisodes
                width: parent.width
                // Room for everything above (body.y + column offset) plus
                // the footer hint below — no bleed off the page bottom.
                height: Math.max(Math.round(120 * dv.s),
                                 dv.height - body.y - y - Math.round(64 * dv.s)
                                 - (dv.moreLike.length > 0 ? Math.round(268 * dv.s) : 0)
                                 - (actions.height + parent.spacing))
                clip: true
                spacing: 2
                model: dv.episodes
                currentIndex: dv.epIdx
                section.property: dv.epSeasons ? "season" : ""
                section.criteria: ViewSection.FullString
                section.delegate: Item {
                    required property string section
                    width: epList.width
                    height: Math.round(40 * dv.s)
                    Text {
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: Math.round(6 * dv.s)
                        text: dv.mgsSafe(section) + " // " + (dv.seasonCounts[section] || 0)
                        color: Theme.withAlpha(Theme.accent, 0.85)
                        font.family: dv.codecFont
                        font.pixelSize: dv.pxi(Math.round(15 * dv.s))
                        font.letterSpacing: Math.round(3 * dv.s)
                    }
                }
                // Smooth, damped scroll that keeps the focused episode in a
                // middle band — no snap-to-edge jump on each keypress. The rows
                // draw their own selection; this invisible highlight is what the
                // band-follow tracks (without one, a run of j outran the view
                // and the selection walked off the bottom).
                highlight: Item {}
                highlightFollowsCurrentItem: true
                // The focused episode's track probe lands a beat later and can
                // reflow the column above (a longer AUDIO line), shrinking this
                // list after it scrolled — keep the selection whole when it does.
                onHeightChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)
                highlightRangeMode: ListView.ApplyRange
                preferredHighlightBegin: Math.round(height * 0.32)
                preferredHighlightEnd: Math.round(height * 0.68)
                highlightMoveDuration: 200
                highlightMoveVelocity: -1
                delegate: Rectangle {
                    required property var modelData
                    required property int index
                    readonly property bool selected: dv.epIdx === index
                    width: epList.width
                    height: Math.round(46 * dv.s)
                    radius: 8
                    color: selected ? Theme.surfaceHi : "transparent"
                    Behavior on color { ColorAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                    Rectangle {
                        width: 3; radius: 1.5
                        height: parent.height - 14
                        anchors.verticalCenter: parent.verticalCenter
                        x: 6
                        color: Theme.accent
                        opacity: selected ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                    }
                    Text {
                        x: 22
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 160
                        text: dv.mgsSafe(modelData.title)
                        color: selected ? Theme.fg
                               : modelData.watched ? Theme.dimFg
                                                   : Theme.withAlpha(Theme.fg, 0.85)
                        Behavior on color { ColorAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                        font.family: dv.hudFont
                        font.pixelSize: dv.pxi(Math.round(21 * dv.s))
                        elide: Text.ElideRight
                    }
                    Text {
                        anchors.right: parent.right
                        anchors.rightMargin: Math.round(46 * dv.s)
                        anchors.verticalCenter: parent.verticalCenter
                        visible: modelData.watched
                        text: "✔"
                        color: Theme.accent
                        font.family: dv.hudFont
                        font.pixelSize: dv.pxi(Math.round(21 * dv.s))
                    }
                    // In-progress bar along the row foot.
                    Rectangle {
                        visible: !modelData.watched && modelData.pct > 0.01
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: Math.round(3 * dv.s)
                        x: Math.round(22 * dv.s)
                        height: 2
                        radius: 1
                        width: (parent.width - Math.round(60 * dv.s)) * Math.min(1, modelData.pct)
                        color: Theme.accent
                        opacity: 0.85
                    }
                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        property point prevScene: Qt.point(-9999, -9999)
                        onExited: prevScene = Qt.point(-9999, -9999)
                        onPositionChanged: (mouse) => {
                            const p = mapToItem(null, mouse.x, mouse.y)
                            const moved = Math.abs(p.x - prevScene.x) > 2
                                          || Math.abs(p.y - prevScene.y) > 2
                            prevScene = Qt.point(p.x, p.y)
                            if (App.pointerActive && moved && !epList.moving && dv.epIdx !== index) {
                                dv.epIdx = index
                                if (dv.open) Sfx.play("move")
                            }
                        }
                        onClicked: {
                            if (dv.epIdx === index) dv.playCurrent()
                            else { dv.epIdx = index; Sfx.play("move") }
                        }
                    }
                }
            }

            // a short page's leftover room, at most a section break (fitFill)
            Item { width: 1; height: dv.fillGap; visible: dv.fillGap > 0 }

            // ── Actions: PLAY, and BONUS FEATURES beside it ──────────────
            // The page opens ON the PLAY plate (lit), so ⏎ plays: the info
            // page and then ⏎ again is a quick double-Enter to watch. A
            // title with bonus features shows both; ←/→ walk between them.
            component ActionPlate: Item {
                id: ap
                property string label: ""
                property bool focusLit: false
                signal activated()
                width: apLbl.implicitWidth + Math.round(48 * dv.s)
                height: Math.round(36 * dv.s)
                property bool hover: false
                property real hopY: 0
                readonly property bool lit: focusLit || hover
                // Lighting up (the keys onto it, or the pointer) presses the
                // plate once and hops the label — the STATS row grammar.
                function press() { apBtn.tap(); apHop.restart() }
                onLitChanged: if (lit && dv.open) press()
                SequentialAnimation {
                    id: apHop
                    NumberAnimation { target: ap; property: "hopY"; to: DS.selDip(apBtn.height); duration: 90; easing.type: Easing.OutQuad }
                    NumberAnimation { target: ap; property: "hopY"; to: 0; duration: 260; easing.type: Easing.OutBack }
                }
                MechButton {
                    id: apBtn
                    family: 3
                    px: 2     // the UI's plate scale (dv.mpx drew 4px bevels at 1440p)
                    anchors.fill: parent
                    hot: ap.lit
                    pressed: apMouse.pressed   // held: runs the press-down and stays
                    opacity: ap.lit ? 1 : 0.7
                    Behavior on opacity { NumberAnimation { duration: 120 } }
                }
                // the label's cap ink centred on the plate's dark face
                // (FontMetrics re-read once the codec face loads)
                FontMetrics { id: apFm; font: apLbl.font }
                function capMid() {
                    void apFm.height
                    const r = apFm.tightBoundingRect("H")
                    return apFm.ascent + r.y + r.height / 2
                }
                Text {
                    id: apLbl
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: Math.round(apBtn.faceMid - ap.capMid())
                    text: ap.label
                    // the house selection rule: the lit plate's word brightest,
                    // the other dim (the accent read DIMMER than an idle white)
                    color: ap.lit ? "#f2f7fa" : Theme.dimFg
                    Behavior on color { ColorAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                    font.family: dv.codecFont
                    font.pixelSize: dv.pxi(Math.round(16 * dv.s))
                    font.letterSpacing: Math.round(3 * dv.s)
                    transform: Translate { y: ap.hopY }
                }
                MouseArea {
                    id: apMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: ap.hover = true
                    onExited: ap.hover = false
                    onClicked: ap.activated()
                }
            }
            Row {
                id: actions
                // The plate art has 3 transparent source px down its left side
                // and then a near-black outline px: pull it out by both so its
                // VISIBLE (light) edge sits on the column's left edge.
                x: -4 * 2
                spacing: Math.round(14 * dv.s)
                ActionPlate {
                    id: playPlate
                    label: "▶  " + dv.playWord
                    focusLit: dv.playFocus
                    onActivated: dv.playCurrent()
                }
                ActionPlate {
                    id: bonusPlate
                    visible: dv.extrasCount > 0
                    label: "BONUS FEATURES // " + dv.extrasCount
                    focusLit: dv.bonusFocus
                    onActivated: dv.openBonus()
                }
            }

            // ── More like this ────────────────────────────────────────────
            // TMDB recommendations we actually own come first; the rest are
            // filled by shared genre. A recommendation you can't play is an ad.
            Text {
                visible: dv.moreLike.length > 0
                topPadding: 4
                text: "MORE LIKE THIS // " + dv.moreLike.length
                color: Theme.accent
                font.family: dv.codecFont
                font.pixelSize: dv.pxi(Math.round(18 * dv.s))
                font.letterSpacing: Math.round(4 * dv.s)
            }
            ListView {
                id: moreRow
                visible: dv.moreLike.length > 0
                width: parent.width
                height: Math.round(190 * dv.s * dv.moreK)
                orientation: ListView.Horizontal
                spacing: Math.round(14 * dv.s)
                clip: true
                model: dv.moreLike
                currentIndex: dv.moreIdx
                onCurrentIndexChanged: if (currentIndex >= 0)
                                           positionViewAtIndex(currentIndex, ListView.Contain)
                delegate: Item {
                    required property var modelData
                    required property int index
                    readonly property bool selected: dv.moreIdx === index
                    width: Math.round(118 * dv.s * dv.moreK)
                    height: moreRow.height
                    Rectangle {
                        id: cardBox
                        width: parent.width
                        height: Math.round(172 * dv.s * dv.moreK)
                        radius: 8
                        color: Theme.surfaceHi
                        border.color: selected ? Theme.accent : Theme.border
                        Behavior on border.color { ColorAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                        border.width: selected ? 2 : 1
                        clip: true
                        scale: selected ? 1.05 : 1
                        Behavior on scale { NumberAnimation { duration: 130 } }
                        Image {
                            anchors.fill: parent
                            anchors.margins: 1
                            source: (modelData.poster || "").length > 0
                                    ? Theme.art(modelData.poster) : ""
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                        }
                        // No art? fall back to the title so the card still reads.
                        Text {
                            anchors.centerIn: parent
                            visible: (modelData.poster || "").length === 0
                            width: parent.width - 16
                            text: dv.mgsSafe(modelData.title)
                            color: Theme.dimFg
                            font.family: dv.hudFont
                            font.pixelSize: dv.pxi(Math.round(16 * dv.s))
                            wrapMode: Text.Wrap
                            horizontalAlignment: Text.AlignHCenter
                        }
                    }
                    Text {
                        anchors.top: cardBox.bottom
                        anchors.topMargin: 4 + Math.round(5 * dv.s)   // nudged down 5px
                        width: parent.width
                        text: dv.mgsSafe(modelData.why)
                        color: selected ? Theme.accent : Theme.dimFg
                        Behavior on color { ColorAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                        font.family: dv.hudFont
                        font.pixelSize: dv.pxi(Math.round(14 * dv.s))
                        font.letterSpacing: Math.round(1 * dv.s)
                        elide: Text.ElideRight
                    }
                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        property point prevScene: Qt.point(-9999, -9999)
                        onExited: prevScene = Qt.point(-9999, -9999)
                        onPositionChanged: (mouse) => {
                            const p = mapToItem(null, mouse.x, mouse.y)
                            const moved = Math.abs(p.x - prevScene.x) > 2
                                          || Math.abs(p.y - prevScene.y) > 2
                            prevScene = Qt.point(p.x, p.y)
                            if (App.pointerActive && moved && !moreRow.moving && dv.moreIdx !== index) {
                                dv.moreIdx = index
                                if (dv.open) Sfx.play("move", dv.morePan())
                            }
                        }
                        onClicked: {
                            if (dv.moreIdx === index) { Sfx.play("open"); App.detailUri = modelData.path }
                            else { dv.moreIdx = index; Sfx.play("move", dv.morePan()) }
                        }
                    }
                }
            }

            // Footer hints in the HOME keycap grammar: the KEY in a cap, the
            // action free-standing beside it. Wraps (Flow) on the narrow CRT.
            // Each one is also a button (click = the key).
            Flow {
                topPadding: Math.round(6 * dv.s)
                width: parent.width
                spacing: Math.round(16 * dv.hk)
                Repeater {
                    model: {
                        let m = []
                        if (dv.isShow && dv.showEpisodes) m.push(["j/k", "EP", null])
                        const ep = dv.isShow ? dv.episodes[dv.epIdx] : null
                        const playLbl = (ep ? (ep.pct || 0) > 0.01 && !ep.watched
                                            : (dv.info.position || 0) > 60) ? "RESUME" : "PLAY"
                        // ⏎ says what Enter does where you are on the spine; off the
                        // title, p still plays
                        if (dv.bonusFocus)
                            m.push(["⏎", "BONUS", () => dv.openBonus()], ["p", playLbl, () => dv.playCurrent()])
                        else if (dv.moreIdx >= 0 && dv.moreLike[dv.moreIdx])
                            m.push(["⏎", "OPEN", () => { Sfx.play("open"); App.detailUri = dv.moreLike[dv.moreIdx].path }],
                                   ["p", playLbl, () => dv.playCurrent()])
                        else
                            m.push(["⏎", playLbl, () => dv.playCurrent()])
                        if (dv.moreLike.length > 0)
                            m.push(["h/l", "MORE", () => {
                                const was = dv.moreIdx
                                dv.bonusFocus = false; dv.moreIdx = Math.max(0, dv.moreIdx)
                                if (dv.moreIdx !== was) Sfx.play("move", dv.morePan()) }])
                        if (dv.extrasCount > 0 && !dv.bonusFocus) m.push(["b", "BONUS", () => dv.openBonus()])
                        m.push(["t", "TRAILER", () => App.playTrailer(dv.info.title || "", String(dv.info.year || ""))],
                               ["a", "QUEUE", () => dv.queueCurrent()],
                               ["q", "PANEL", () => { App.queueOpen = !App.queueOpen }],
                               ["w", "WATCHED", () => dv.toggleWatched()],
                               ["c", "CAST", () => { dv.close(true); App.outputOpen = true }],
                               ["i/esc", "CLOSE", () => dv.close()])
                        return m
                    }
                    Item {
                        id: hintRow
                        required property var modelData
                        property bool hover: false
                        width: hintKeys.implicitWidth
                        height: hintKeys.implicitHeight
                        Row {
                            id: hintKeys
                            spacing: Math.round(5 * dv.hk)
                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                width: kc.implicitWidth + Math.round(8 * dv.hk)
                                height: Math.round(16 * dv.hk)
                                radius: Math.round(3 * dv.hk)
                                color: Theme.withAlpha(Theme.bg, 0.45)
                                border.width: 1
                                border.color: Theme.withAlpha(Theme.fg, hintRow.hover ? 0.45 : 0.18)
                                Text {
                                    id: kc
                                    anchors.centerIn: parent
                                    text: hintRow.modelData[0]
                                    color: Theme.withAlpha(Theme.fg, 0.6)
                                    anchors.verticalCenterOffset: Math.max(1, Math.round(dv.hk))   // mgs sits high in its box
                                    font.family: dv.hudFont
                                    font.pixelSize: dv.pxi(Math.round(16 * dv.hk))
                                }
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: hintRow.modelData[1]
                                color: hintRow.hover ? Theme.fg : Theme.dimFg
                                font.family: dv.hudFont
                                font.pixelSize: dv.pxi(Math.round(16 * dv.hk))
                                font.letterSpacing: Math.round(1.5 * dv.hk)
                            }
                        }
                        MouseArea {
                            anchors.fill: parent
                            enabled: hintRow.modelData[2] !== null
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onEntered: hintRow.hover = true
                            onExited: hintRow.hover = false
                            onClicked: hintRow.modelData[2]()
                        }
                    }
                }
            }
        }
    }

    // ── BONUS FEATURES page ───────────────────────────────────────────────
    // Over the text column, top and foot level with the poster beside it.
    BonusFeatures {
        id: bonus
        dv: dv
        x: body.x + dv.posterW + dv.gap
        y: body.y + Math.round(48 * dv.s)
        width: dv.textW
        height: Math.round(dv.posterW * 1.5)
    }
}
