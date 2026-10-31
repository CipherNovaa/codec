import QtQuick

// Playback OSD + keys. The video itself lives in Main.qml's persistent
// dock so it can keep playing while browsing.
FocusScope {
    id: player

    readonly property bool osdVisible: osdTimer.running || Engine.paused

    // Subtitles and the OSD both live at the bottom of the frame, so with the
    // controls up the text used to read straight THROUGH the panel. Lift the
    // subtitles instead of hiding them: you generally open the OSD to seek,
    // which is exactly the moment you still want to read the line.
    onOsdVisibleChanged: App.setSubtitleLift(osdVisible)
    Component.onCompleted: App.setSubtitleLift(osdVisible)
    property string autoplayTitle: ""
    property bool autoplayActive: false
    property bool autoplayAsking: false
    // Tell App when a prompt owns Enter, so the remote's OK (and a wheel-
    // click) accepts it instead of pausing under it.
    Binding {
        target: App; property: "playerPrompt"
        value: player.visible && (player.autoplayActive || player.introActive)
    }
    // The overlay was raised at the END CREDITS (App.creditsUpNext), not at the
    // last frame: dismissing it keeps the credits playing instead of leaving,
    // and the countdown is longer — there's credits left to decide in.
    property bool creditsMode: false
    // Live streams: the chat rail opens itself when a live stream starts
    // (the YouTube ritual) and "c" toggles it; on anything else "c" keeps
    // its subtitle-delay job.
    property bool chatOpen: false
    // The chat FEED runs for the whole live stream, panel open or not, so
    // "c" shows a chat that is already loaded instead of reconnecting from
    // empty every time. The panel is only the view of it.
    function setChat(on) {
        chatOpen = on
        if (on && App.liveNow) LiveChat.open(Engine.path)   // no-op if already streaming
    }
    Connections {
        target: App
        function onLiveNowChanged() {
            if (App.liveNow) {
                LiveChat.open(Engine.path)
                player.chatOpen = true
                App.notify("LIVE ▸ c toggles chat")
            } else {
                player.chatOpen = false
                LiveChat.close()
            }
        }
    }
    // A different live stream straight after another (liveNow stays true):
    // follow it. Same stream reloading (DVR) is a no-op in LiveChat.open.
    Connections {
        target: Engine
        function onPathChanged() {
            if (App.liveNow) LiveChat.open(Engine.path)
            // A prompt belongs to the title it was raised for. A title changed
            // from elsewhere (MPRIS, an "Open with codec", the party) left the
            // old UP NEXT / "still watching?" over the new film, the OSD
            // suppressed and most keys swallowed. Quietly: the new title is
            // already the answer, so neither go nor dismiss is sent.
            autoplayTimer.stop()
            player.autoplayActive = false
            player.autoplayAsking = false
            player.creditsMode = false
        }
    }

    // Netflix-style SKIP INTRO. A named chapter is the authority when the rip
    // has one; almost none do, so the fallback is the offline audio-fingerprint
    // range from scripts/codec_intro.py (App.introRange).
    readonly property var introChapter: {
        const ch = Engine.chapters
        for (let i = 0; ch && i < ch.length; ++i) {
            const t = (ch[i].title || "").toLowerCase()
            if (/\b(op|opening|intro|avant)\b/.test(t) || t === "prologue") {
                const start = ch[i].time || 0
                const end = i + 1 < ch.length ? ch[i + 1].time : start + 90
                if (end - start > 5 && end - start < 240)
                    return { start: start, end: end, chaptered: true }
            }
        }
        const r = App.introRange
        if (r && r.end > r.start)
            return { start: r.start, end: r.end, chaptered: false }
        return null
    }
    readonly property bool introActive: introChapter !== null
        && Engine.position >= introChapter.start + 0.5
        && Engine.position < introChapter.end - 1.5

    onVisibleChanged: if (visible) { forceActiveFocus(); pokeOsd() }

    function pokeOsd() { osdTimer.restart() }

    // ── Volume: 0–200%, VLC-style ─────────────────────────────────────────
    // 0–100 is the SYSTEM volume (what the volume keys move); past that the
    // player boosts on top of a full system volume — mpv's own volume, 100→200.
    // A step fills the system first, then the boost; down drains the boost first.
    // Boost writes are ABSOLUTE (mpv applies volume asynchronously: relative adds
    // stacked on a stale read could leave mpv under 100 — invisibly quieter).
    readonly property int volBoost: Math.max(0, Math.round(Engine.volume - 100))
    readonly property int volLevel: SysVol.volume + (SysVol.volume >= 100 ? volBoost : 0)
    // The boost "gets hotter": amber at the start of it → orange → red at 200
    // (t 0..1). The gauge's boost segments each take their own spot on the ramp;
    // the number and glyph take the current level's.
    function heatColor(t) {
        const stops = [[0.0, 0xe0, 0xa2, 0x3f],   // osdWarn amber
                       [0.5, 0xe8, 0x72, 0x2c],   // orange
                       [1.0, 0xdc, 0x33, 0x2a]]   // red
        t = Math.max(0, Math.min(1, t))
        let i = 0
        while (i < stops.length - 2 && t > stops[i + 1][0]) i++
        const a = stops[i], b = stops[i + 1]
        const f = (t - a[0]) / (b[0] - a[0])
        return Qt.rgba((a[1] + (b[1] - a[1]) * f) / 255, (a[2] + (b[2] - a[2]) * f) / 255,
                       (a[3] + (b[3] - a[3]) * f) / 255, 1)
    }
    readonly property color volHeat: heatColor((volLevel - 100) / 100)
    function volStep(d) {
        // No system volume to drive (no wpctl, the sink gone, a satellite
        // without PipeWire): the keys and wheel move the player's own volume,
        // as they did before the OSD became the system's.
        // A DETENT at 100% ("a little cushion at 100"): a step that would
        // cross it — either way, keys or wheel — stops ON it, and the next step
        // goes on through. Stepping from 97 used to land on a 2% boost, and
        // back down from 102 on 97: never quite the unboosted 100.
        const cur = SysVol.available ? volLevel : Math.round(Engine.volume)
        const to = cur + d
        if ((cur < 100 && to > 100) || (cur > 100 && to < 100))
            d = 100 - cur
        if (d === 0)
            return
        if (!SysVol.available) {
            Engine.addVolume(d)
            return
        }
        if (d > 0) {
            const toFull = Math.max(0, 100 - SysVol.volume)
            const sys = Math.min(d, toFull)
            // Turning UP always un-mutes: step() does it on its way up; a
            // boost-only step needs it said (set-mute 0 — a `toggle` here raced
            // step()'s own un-mute and could leave the sink muted).
            // reaching full: set it outright (a relative step can land a hair short)
            if (sys > 0 && sys === toFull) SysVol.setLevel(100)
            else if (sys > 0) SysVol.step(sys)
            else if (SysVol.muted) SysVol.setMuted(false)
            const extra = Math.min(d - sys, 100 - volBoost)
            if (extra > 0 && sys === toFull) {
                // the boost rides an EXACT full system volume, not a "100" that
                // is really 99.6
                if (sys === 0 && volBoost === 0) SysVol.setLevel(100)
                Engine.setVolume(100 + volBoost + extra)
            }
        } else if (d < 0) {
            const fromBoost = Math.min(-d, volBoost)
            if (fromBoost > 0) Engine.setVolume(100 + volBoost - fromBoost)
            if (-d - fromBoost > 0) SysVol.step(d + fromBoost)
        }
    }
    // a boost only ever rides a FULL system volume: turned down any other way
    // (the volume keys), it goes — nothing surprises you later at 200%
    Connections {
        target: SysVol
        function onChanged() {
            if (SysVol.volume < 100 && player.volBoost > 0)
                Engine.setVolume(100)
        }
    }
    // Scroll anywhere on the player = SYSTEM volume, 2% a notch, and the OSD
    // wakes to show it (it was only live over a VISIBLE OSD — but scrolling
    // never moves the pointer, so the OSD was usually asleep and the wheel did
    // nothing). The chat list, being above, keeps its own scrolling.
    // TouchPad too: Qt labels every scroll on this desktop a touchpad.
    WheelHandler {
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        enabled: player.visible && !App.queueOpen
        property real accum: 0
        onWheel: (e) => {
            // Never over the chat rail: a wheel there scrolls the chat, and
            // the overflow at its top/bottom edge used to land here and crank
            // the volume. Decided by position, not by delivery order.
            if (chatPanel.visible && chatPanel.open) {
                const c = chatPanel.mapFromItem(player, e.x, e.y)
                if (c.x >= 0 && c.y >= 0 && c.x < chatPanel.width && c.y < chatPanel.height)
                    return
            }
            player.pokeOsd()
            accum += e.angleDelta.y
            while (accum >= 120) { player.volStep(2); accum -= 120 }
            while (accum <= -120) { player.volStep(-2); accum += 120 }
        }
    }
    // While the player is up and codec has focus, codec SHOWS system volume
    // changes (the volume keys pop this OSD's indicator) and quickshell's own
    // popup stands aside (SysVol keeps $XDG_RUNTIME_DIR/codec-osd-active fresh).
    Binding {
        target: SysVol
        property: "ownsOsd"
        value: player.visible && Qt.application.state === Qt.ApplicationActive
    }
    Connections {
        target: SysVol
        enabled: player.visible
        function onChangedExternally() { player.pokeOsd() }
    }

    // Live-editable mech-UI asset URL: file:// off disk in a dev build (hot-reloads
    // on save via heroDevRev), else the baked qrc. Same contract as the queue.
    function devSrc(rel) {
        var d = App.heroDevPath(rel)
        return d !== "" ? d + "?v=" + App.heroDevRev : "qrc:/assets/mechui/" + rel + ".png"
    }

    // Fixed OSD palette — the OSD is deliberately OFF pywal: steady colours
    // that never shift with the wallpaper. Steel matches the cast overlay's bar.
    readonly property color osdFg:    "#e7ecf3"   // primary text / moving parts
    readonly property color osdDim:   "#9aa4b2"   // labels, secondary metadata
    // Text in the MGS Codec face, centred on its capitals: unlike the HUD face
    // (whose caps sit dead in the middle of its line box) the Codec face seats
    // them a 32nd of an em low, so a box-centred label sits off its neighbours.
    // Measured from the loaded face (Main.qml StripText's trick: reading
    // fm.height re-runs it once the FontLoader is done).
    component CodecText: ShadowText {
        id: ct
        font.family: Theme.codecFont
        FontMetrics { id: ctFm; font: ct.font }
        readonly property real inkMid: {
            void ctFm.height
            const r = ctFm.tightBoundingRect("H")
            return r.y + r.height / 2
        }
        anchors.verticalCenter: parent ? parent.verticalCenter : undefined
        anchors.verticalCenterOffset: Math.round(height / 2 - (baselineOffset + inkMid))
    }
    // An episode's own name in quotes — "Show  S01E03 · Name (1994)" reads
    // Show  S01E03 · "Name" (1994) — as the library and the miniplayer show it
    // (Main.qml pipTitleOf, the same pattern).
    function quoteEpisode(t) {
        const m = /^(.*\bS\d+E\d+\S*) · (.+?)( \(\d{4}\))?$/.exec(t || "")
        return m ? m[1] + ' · "' + m[2] + '"' + (m[3] || "") : (t || "")
    }
    readonly property color osdSteel: "#a6b1c7"   // seek bar + accent pops
    readonly property color osdWarn:  "#e0a23f"   // muted / attention
    readonly property color osdLine:  "#3a4553"   // ticks, hairline borders
    // Glassy plate like the home wheel buttons — the OSD base + texture render at
    // this opacity so the video bleeds through; text stays solid. Lower = glassier.
    property real glass: App.glassLevel
    // Seek-bar fill/playhead: a film's position over its length, or — live —
    // the playhead within YouTube's DVR window (1 = at the live edge).
    readonly property real barFrac: App.liveNow
        ? (App.liveWindow > 0 ? Math.max(0, Math.min(1, App.livePos / App.liveWindow)) : 1)
        : (Engine.duration > 0 ? Math.min(1, Engine.position / Engine.duration) : 0)
    // A broadcast's age, the way YouTube says it: "37 MIN", "2 HR 14 MIN",
    // "3 DAYS" for the 24/7 kind.
    function liveAge(s) {
        const m = Math.floor(s / 60)
        if (m < 60) return m + " MIN"
        const h = Math.floor(m / 60)
        if (h < 48) return h + " HR " + (m % 60) + " MIN"
        return Math.floor(h / 24) + " DAYS"
    }

    // Chapter markers make chapterStep exact; a fingerprinted range is a plain
    // timestamp, so seek to it directly.
    function skipIntro() {
        if (!introChapter)
            return
        // Both branches land on the same timestamp; the party path has to go
        // through App so everyone else skips the intro too.
        if (introChapter.chaptered && !App.partyDriving)
            Engine.chapterStep(1)
        else
            App.seekTo(introChapter.end)
    }

    function cancelAutoplay() {
        autoplayActive = false
        autoplayAsking = false
        autoplayTimer.stop()
        if (creditsMode) { creditsMode = false; App.creditsDismiss() }
        else App.autoplayCancel()
    }
    function goAutoplay() {
        autoplayTimer.stop()
        autoplayActive = false
        if (creditsMode) { creditsMode = false; App.creditsGo() }
        else App.autoplayGo()
    }

    Timer { id: osdTimer; interval: 2600 }

    Timer {
        id: autoplayTimer
        interval: player.creditsMode ? 10000 : 5000
        onTriggered: player.goAutoplay()
    }

    Connections {
        target: App
        function onAutoplayCountdown(title) {
            // #nav: the countdown overlay owns the keyboard (Space/Enter/Esc =
            // cancel/go), but an open queue sidebar holds & re-grabs focus, so those
            // keys silently hit the queue and the countdown auto-advanced anyway.
            // Close the queue (it auto-refocuses the player) so the keys land here.
            if (App.queueOpen) { App.queueOpen = false; Sfx.hush() }   // the app's close, not a press: no back
            player.forceActiveFocus()
            player.creditsMode = false
            player.autoplayTitle = title
            player.autoplayAsking = false
            player.autoplayActive = true
            autoplayTimer.restart()
        }
        function onCreditsUpNext(title, ask) {
            if (App.queueOpen) { App.queueOpen = false; Sfx.hush() }   // the app's close, not a press: no back
            player.forceActiveFocus()
            player.creditsMode = true
            player.autoplayTitle = title
            player.autoplayAsking = ask
            player.autoplayActive = true
            if (!ask) autoplayTimer.restart()
        }
        function onAutoplayAsk(title) {
            if (App.queueOpen) { App.queueOpen = false; Sfx.hush() }   // the app's close, not a press: no back
            player.forceActiveFocus()
            player.creditsMode = false
            player.autoplayTitle = title
            player.autoplayActive = true
            player.autoplayAsking = true
        }
    }

    Keys.onPressed: (event) => {
        // Autoplay overlay owns the keyboard while visible.
        // UI sounds: only the prompts (UP NEXT / still watching? / SKIP INTRO),
        // the chat rail and leaving — never transport.
        if (autoplayActive) {
            switch (event.key) {
            case Qt.Key_Space: case Qt.Key_Escape: Sfx.play("back"); cancelAutoplay(); break
            case Qt.Key_Return: case Qt.Key_Enter: Sfx.play("select"); goAutoplay(); break
            default: break
            }
            event.accepted = true
            return
        }
        pokeOsd()
        switch (event.key) {
        case Qt.Key_Return: case Qt.Key_Enter:
            // On a live stream with chat open, ⏎ drops into the compose box
            // (no intro to skip on a live stream anyway).
            if (App.liveNow && player.chatOpen) chatPanel.startCompose()
            else if (player.introActive) { Sfx.play("select"); player.skipIntro() }
            else return
            break
        // Transport goes through App, not the engine: in a watch party these
        // keys move EVERYONE's screen, and only App knows that.
        case Qt.Key_Space: App.playPause(); break
        case Qt.Key_K: App.playPause(); break
        case Qt.Key_End: if (App.liveNow) App.goLive(); else return; break   // live: jump to the live edge
        case Qt.Key_H:
        case Qt.Key_Left: App.seekBy(event.modifiers & Qt.ShiftModifier ? -60 : -App.seekStep); break
        case Qt.Key_L:
        case Qt.Key_Right: App.seekBy(event.modifiers & Qt.ShiftModifier ? 60 : App.seekStep); break
        case Qt.Key_Up: App.seekBy(60); break
        case Qt.Key_Down: App.seekBy(-60); break
        case Qt.Key_J: App.seekBy(-60); break
        // chapter step is solo-only: in a party it would move just this screen
        // and the follow loop would drag it back (desync). Gate on partyDriving.
        case Qt.Key_PageUp: if (!App.partyDriving) Engine.chapterStep(1); break
        case Qt.Key_PageDown: if (!App.partyDriving) Engine.chapterStep(-1); break
        // n/b = next/prev item, same muscle memory as the cast remote.
        case Qt.Key_N:
            if (event.modifiers & Qt.ShiftModifier) App.playerPrev()
            else App.playerNext()
            break
        case Qt.Key_B: App.playerPrev(); break
        case Qt.Key_Z: Engine.cycleZoomMode(); break
        case Qt.Key_A: Engine.cycleAudio(); break
        case Qt.Key_S:
            // ctrl-S = grab the current frame → ~/Pictures/codec; shift-S = fetch
            // subtitles online (beside the file); plain s = cycle subtitle track.
            if (event.modifiers & Qt.ControlModifier) App.screenshot()
            else if (event.modifiers & Qt.ShiftModifier) App.findSubtitles()
            else Engine.cycleSub()
            break
        case Qt.Key_M: if (SysVol.available) SysVol.toggleMute(); else Engine.toggleMute(); break
        // One volume everywhere: 9/0/m drive the SYSTEM volume (what the
        // volume keys change), shown on the OSD indicator — and past 100 the
        // player's own boost, up to 200 (volStep).
        case Qt.Key_9: player.volStep(-5); break
        case Qt.Key_0: player.volStep(5); break
        case Qt.Key_BracketLeft: Engine.multiplySpeed(1 / 1.1); break
        case Qt.Key_BracketRight: Engine.multiplySpeed(1.1); break
        case Qt.Key_Backspace: Engine.resetSpeed(); break
        case Qt.Key_Comma: if (!App.partyDriving) Engine.frameStep(true); break
        case Qt.Key_Period: if (!App.partyDriving) Engine.frameStep(false); break
        case Qt.Key_X: Engine.addSubDelay(0.1); break
        case Qt.Key_C:
            if (App.liveNow) { Sfx.play(chatOpen ? "back" : "open"); setChat(!chatOpen) }
            else Engine.addSubDelay(-0.1)
            break
        // w = watch party overlay OVER the video: start/manage a synced remote
        // watch without leaving playback (this screen stays the leader clock).
        // Toggle, not set: if the overlay ever loses focus while visible
        // (a stage change under it), `w` still gets you out.
        case Qt.Key_W: App.partyOpen = !App.partyOpen; break
        // q = queue overlay OVER the video (matches every browse view);
        // only p/esc leave the player. One mental model everywhere.
        case Qt.Key_Q: App.queueOpen = !App.queueOpen; break
        // silent: the film only moves into the miniplayer (the author — a sound is
        // for closing it / stopping, which AppController::stopPlayback cues)
        case Qt.Key_P: case Qt.Key_Escape: App.leavePlayer(); break
        default:
            return
        }
        event.accepted = true
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        // Item-level blank cursor: the app-wide override sometimes doesn't
        // take on Wayland until the pointer moves — this one always wins
        // while the OSD is asleep.
        cursorShape: player.osdVisible ? Qt.ArrowCursor : Qt.BlankCursor
        onPositionChanged: player.pokeOsd()
        onDoubleClicked: App.playPause()
    }

    // ── Live chat rail (live streams only; "c" toggles) ───────────────────
    // Declared before the OSD so the transient OSD rides over its bottom
    // edge instead of hiding underneath.
    LiveChatPanel {
        id: chatPanel
        width: Math.min(380, parent.width * 0.3)
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.topMargin: 24
        // Ends ABOVE the OSD while it is up (the compose box sat under the
        // bar), and drops back to the bottom when it hides.
        anchors.bottomMargin: player.osdVisible && !player.autoplayActive
                              ? osd.height + player.osdFoot + 12 : 24
        Behavior on anchors.bottomMargin { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
        open: player.chatOpen && !App.queueOpen && player.visible
        // Composing ends → hand the keyboard back to the player.
        onComposeEnded: player.forceActiveFocus()
    }

    // ── Bottom OSD ─────────────────────────────────────────────────────────
    // Low on every screen — it rode too high (the author, 2026-10-13) — and lowest
    // and widest on the CRT, where the chrome already stops at the tube's
    // measured glass edge (Main's crtL..crtB), so a hair more is enough.
    readonly property bool onCrt: App.mode === "crt"
    readonly property int osdSide: onCrt ? 8 : 24
    readonly property int osdFoot: onCrt ? 8 : 12
    Panel {
        id: osd
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: player.osdSide
        anchors.rightMargin: player.osdSide
        anchors.bottomMargin: player.osdFoot
        height: osdCol.height + 32
        color: Qt.rgba(0.043, 0.063, 0.094, 0.84 * player.glass)   // fixed dark base (no pywal)
        border.width: 0   // the osd-tex 9-slice is the frame; no Panel hairline under it
        opacity: player.osdVisible && !player.autoplayActive ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 160 } }
        // Faded out = out of the scene. At opacity 0 it was still drawn: its
        // seek bar and clock follow the playhead, so a hidden OSD kept asking
        // for frames between the film's own (a 24 fps film presented at 32-65
        // a second) — and under FreeSync the panel refreshes when we present,
        // so the film's cadence came out uneven.
        visible: opacity > 0

        // Live-editable OSD plate — a 9-SLICE, so the frame you draw wraps the bar
        // ONCE: corners stay pixel-crisp, the edge lines stretch along each side,
        // the flat center stretches to fill the body. EDIT:
        // assets/mechui/plates/osd-tex.png (64x64). Keep detail in the outer ~8px
        // (corners); keep the edges a clean straight run and the center flat/thin,
        // or they smear when stretched. A dev build hot-reloads on Ctrl-S (relaunch
        // codec once first). border{8} must match the painted corner size.
        BorderImage {
            anchors.fill: parent
            source: (App.heroDevRev, player.devSrc("osd-tex"))
            smooth: false
            opacity: player.glass
            border { left: 8; right: 8; top: 8; bottom: 8 }
            horizontalTileMode: BorderImage.Stretch
            verticalTileMode: BorderImage.Stretch
        }

        Column {
            id: osdCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 16
            spacing: 10

            Item {
                id: titleRow
                width: parent.width
                // A logo stands proud of the line rather than making the plate a
                // whole logo taller; the row grows only as far as keeps it the
                // same 10+ px clear of the plate's frame above and the seek bar
                // below (see midY).
                height: logoWanted ? Math.max(22, Math.round(osdLogo.height) - 11) : 22

                // The title: a library film's or show's LOGO — the detail page's
                // title art — with its year or "S01E03 · Name" beside it; the
                // words for anything else (YouTube, a file from outside the
                // library, a title with no logo, a logo that fails to load).
                readonly property string logoSrc: App.playingLogo !== ""
                                                  ? Theme.art(App.playingLogo) : ""
                readonly property bool logoWanted: App.osdTitleLogo && logoSrc !== ""
                                                   && osdLogo.status !== Image.Error

                // THE LINE: every element on this row centres on it. Not the
                // row's middle: the plate's drawn frame sits 4 px inside its edge
                // and the seek track 19 px into the next row, so the row's middle
                // put a logo 7 px under the frame and 15 px over the bar. 3.5 px
                // lower splits the room evenly, for words and logos alike. (The
                // HUD face seats its capitals exactly in the middle of its line
                // box, so a box centred here is ink centred here.)
                readonly property real midY: height / 2 + 3.5
                // Where the title starts: past the widest glyph (▶, 5 HUD pixels;
                // ⏸ is 3) — a fixed column, so play/pause never nudges the title
                // sideways — and a clear gap.
                readonly property real titleX: Math.round(playGlyph.font.pixelSize * 320 / 1024) + 18

                // Play/pause: the HUD face's own glyph at 3x its pixel grid
                // (48 px = 3 screen px a font pixel), crisp, and big enough to
                // read as the state of the whole bar rather than a speck.
                ShadowText {
                    id: playGlyph
                    x: 0
                    y: Math.round(titleRow.midY - height / 2)
                    text: Engine.paused ? "⏸" : "▶"
                    color: player.osdSteel
                    font.family: Theme.hudFont
                    font.pixelSize: 48
                }
                ShadowText {
                    id: titleText
                    x: titleRow.titleX
                    y: Math.round(titleRow.midY - height / 2)
                    visible: !titleRow.logoWanted
                    text: Theme.mgsSafe(player.quoteEpisode(Engine.mediaTitle))
                    color: player.osdFg
                    font.family: Theme.hudFont
                    font.pixelSize: 32          // 2x the HUD grid: crisp
                    elide: Text.ElideRight
                    width: osd.width - meta.width - titleRow.titleX - 110
                }
                Image {
                    id: osdLogo
                    x: titleRow.titleX
                    y: Math.round(titleRow.midY - height / 2)
                    source: titleRow.logoSrc
                    visible: titleRow.logoWanted
                    asynchronous: true
                    mipmap: true
                    fillMode: Image.PreserveAspectFit
                    horizontalAlignment: Image.AlignLeft
                    readonly property real asp: sourceSize.height > 0
                                                ? sourceSize.width / sourceSize.height : 3
                    // The guest dock's rule (fitLogo): a long wordmark sits
                    // lower, a squat block logo taller — half to all of hMax,
                    // so every title carries about the same weight — and never
                    // wider than the room the readouts leave.
                    readonly property real hMax: 50
                    readonly property real fitH: Math.max(hMax * 0.5,
                        Math.min(hMax, hMax * Math.sqrt(2.2 / Math.max(asp, 0.1))))
                    width: Math.round(Math.min(fitH * asp, osd.width * 0.42, 440))
                    height: Math.round(width / Math.max(asp, 0.1))
                    opacity: status === Image.Ready ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                    // No drop-shadow layer: the OSD plate is already dark under
                    // it, and a MultiEffect layer drew NOTHING in the offscreen
                    // renderer — a title that can vanish isn't worth a shadow.
                }
                // Beside the logo: the year, or the episode — on the line, at
                // the readout's size (the ELAPSED value's), dimmed as its caption.
                ShadowText {
                    id: logoLine
                    x: osdLogo.x + osdLogo.width + 20
                    y: Math.round(titleRow.midY - height / 2)
                    visible: titleRow.logoWanted && App.playingLogoLine !== ""
                    opacity: osdLogo.opacity
                    text: Theme.mgsSafe(App.playingLogoLine)
                    color: player.osdDim
                    font.family: Theme.hudFont
                    font.pixelSize: Math.round(DS.tBody * 2)
                    elide: Text.ElideRight
                    width: Math.max(0, Math.min(implicitWidth,
                                    osd.width - meta.width - x - 110))
                }
                // Right-click the title: the logo and the words swap, live, and
                // the choice is kept (App.osdTitleLogo). Only where there's a
                // logo to swap; a left click still falls through to the player.
                MouseArea {
                    enabled: titleRow.logoSrc !== "" && osdLogo.status !== Image.Error
                    acceptedButtons: Qt.RightButton
                    x: titleRow.titleX
                    y: Math.min(0, osdLogo.y)
                    height: Math.max(titleRow.height, titleRow.logoWanted ? osdLogo.height : 0)
                    width: titleRow.logoWanted
                           ? (logoLine.visible ? logoLine.x + logoLine.width : osdLogo.x + osdLogo.width) - x
                           : Math.min(titleText.implicitWidth, titleText.width)
                    onClicked: { App.toggleOsdTitleLogo(); player.pokeOsd() }
                }

                Row {
                    id: meta
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.verticalCenterOffset: titleRow.midY - titleRow.height / 2
                    spacing: 14
                    // The picture: its size in the HUD face, its range (HDR) in
                    // the codec face — the words that are a STATE rather than a
                    // number wear the mark's face, same as the cast receiver's
                    // dock (the author, 2026-10-11). Same colour, cap height matched.
                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: Engine.videoInfo.length > 0
                        spacing: 0
                        readonly property var vi: String(Engine.videoInfo).split(" · ")
                        ShadowText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: Theme.mgsSafe(parent.vi[0] + (parent.vi.length > 1 ? " · " : ""))
                            color: player.osdDim
                            font.family: Theme.hudFont
                            font.pixelSize: 22
                        }
                        ShadowText {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: parent.vi.length > 1
                            text: Theme.mgsSafe(parent.vi.slice(1).join(" · "))
                            color: player.osdDim
                            font.family: Theme.codecFont
                            font.pixelSize: 16
                        }
                    }
                    ShadowText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: ["FIT", "ZOOM", "STRETCH"][Engine.zoomMode] || "FIT"
                        color: player.osdDim
                        font.family: Theme.codecFont
                        font.pixelSize: 16
                    }
                    ShadowText {
                        anchors.verticalCenter: parent.verticalCenter
                        // While following a party the speed isn't yours — it's
                        // a percent or two of nudge closing the gap to everyone
                        // else, and showing it as "1.05×" just reads as broken.
                        visible: Math.abs(Engine.speed - 1.0) > 0.01
                                 && !App.partyFollowing
                        text: Theme.mgsSafe(Engine.speed.toFixed(2) + "×")
                        color: player.osdSteel
                        font.family: Theme.hudFont
                        font.pixelSize: 22
                    }
                    // The header chip is hidden in the player, so the fact that
                    // your keys are moving everyone's screen lives here.
                    MechStatus {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: App.partyFollowing || App.partyHosting
                        label: "PARTY" + (App.partyPeers > 1
                               ? " · " + (App.partyPeers - 1) + " WITH YOU" : "")
                        ink: player.osdSteel; px: 22
                    }
                    // LIVE breathes at the live edge. Rewound, it reads how far
                    // behind (dimmed) and a click — or End — jumps back to live.
                    Item {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: App.liveNow
                        readonly property bool behind: App.liveBehind > 12
                        implicitWidth: liveChip.implicitWidth
                        implicitHeight: liveChip.implicitHeight
                        width: implicitWidth; height: implicitHeight
                        MechStatus {
                            id: liveChip
                            label: parent.behind ? "\u2212" + App.prettyTime(App.liveBehind) + "  GO LIVE"
                                                 : "LIVE"
                            ink: parent.behind ? player.osdDim : "#e5484d"
                            px: 22
                            pulse: !parent.behind
                        }
                        MouseArea {
                            anchors.fill: parent
                            enabled: parent.behind
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { player.pokeOsd(); App.goLive() }
                        }
                    }
                    ShadowText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: Theme.mgsSafe("A:" + Engine.audioText + "  S:" + Engine.subText)
                        color: player.osdDim
                        font.family: Theme.hudFont
                        font.pixelSize: 22
                    }
                    // SYSTEM volume (the volume keys' sink): glyph · 10-step
                    // gauge · number. The glyph is a button (mute); the wheel
                    // anywhere on the OSD steps it. Volume keys pop the OSD.
                    // BOOSTED past 100 (VLC-style): the number counts on to 200
                    // and the indicator heats up — the gauge's segments fill again,
                    // one per 10% of boost, amber → orange → red (heatColor).
                    Row {
                        id: volInd
                        spacing: 8
                        anchors.verticalCenter: parent.verticalCenter
                        visible: SysVol.available
                        ShadowText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: SysVol.muted || SysVol.volume === 0 ? "󰝟"
                                  : SysVol.volume >= 70 ? "󰕾" : SysVol.volume >= 30 ? "󰖀" : "󰕿"
                            color: SysVol.muted ? player.osdWarn
                                 : player.volLevel > 100 ? player.volHeat : player.osdSteel
                            font.family: Theme.monoFont
                            font.pixelSize: 18
                            MouseArea {
                                anchors.fill: parent
                                anchors.margins: -6
                                cursorShape: Qt.PointingHandCursor
                                onClicked: { player.pokeOsd(); SysVol.toggleMute() }
                            }
                        }
                        Row {
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2
                            Repeater {
                                model: 10
                                delegate: Rectangle {
                                    required property int index
                                    width: 5; height: 12
                                    antialiasing: false
                                    color: SysVol.muted ? player.osdLine
                                         : player.volLevel - 100 >= (index + 1) * 10 - 5
                                           ? player.heatColor(index / 9)
                                         : SysVol.volume >= (index + 1) * 10 - 5 ? player.osdSteel
                                         : player.osdLine
                                }
                            }
                        }
                        ShadowText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: SysVol.muted ? "MUTE" : String(player.volLevel)
                            color: SysVol.muted ? player.osdWarn
                                 : player.volLevel > 100 ? player.volHeat : player.osdDim
                            font.family: Theme.hudFont
                            font.pixelSize: 22
                        }
                    }
                }
            }

            Item {
                id: seekArea
                width: parent.width
                height: 22

                Rectangle {
                    id: track
                    y: 9
                    width: parent.width
                    height: 4
                    radius: 2
                    // Cast-overlay seek bar, FIXED colours (no pywal in the OSD, per
                    // The author): #a6b1c7 steel for the bar + ring, a white square head.
                    // Track is a dim wash of the same steel; fill is solid steel.
                    color: Qt.rgba(0.651, 0.694, 0.780, 0.20)
                }
                Rectangle {
                    y: track.y
                    width: track.width * player.barFrac
                    height: 4
                    radius: 2
                    color: "#a6b1c7"
                }
                // Chapter markers (Plex-style ticks; c/C skips between them).
                Repeater {
                    model: Engine.chapters
                    delegate: Item {
                        required property var modelData
                        // Whole-pixel: a 1px hairline on a half pixel renders
                        // as a 2px grey smear, which is what makes crisp marks
                        // go muddy.
                        x: Engine.duration > 0
                           ? Math.round(track.width * Math.min(
                                 1, (modelData.time || 0) / Engine.duration))
                           : -10
                        visible: Engine.duration > 0 && !App.liveNow && (modelData.time || 0) > 1
                        // Above AND below the slot. One tick under the bar read
                        // as debris resting on it; a matched pair reads as a
                        // graduation ON a scale — the same mark a gauge uses.
                        // Straddling it as a single tall block is what turned a
                        // forty-chapter film into a picket fence, so the track
                        // stays clear between them.
                        // Same colour as the slot they mark. Near-white pips
                        // made the marks louder than the bar itself, which is
                        // backwards — the bar is the instrument, the chapters
                        // are a graduation on it.
                        Rectangle {
                            x: -1          // centre a 2px mark on the tick
                            y: track.y - height - 2
                            width: 2; height: 5
                            color: player.osdLine
                            antialiasing: false
                        }
                        Rectangle {
                            x: -1
                            y: track.y + track.height + 2
                            width: 2; height: 5
                            color: player.osdLine
                            antialiasing: false
                        }
                    }
                }
                // Playhead — the cast overlay's square head (#tbdot): a near-white
                // square with a 2px accent ring around it, the accent's one
                // appearance on the bar. A square index mark reads machined-to-a-
                // scale, not a media-app dot. Whole-pixel x so the ring stays crisp.
                Rectangle {
                    id: playhead
                    width: 17; height: 17; radius: 0
                    color: "#a6b1c7"             // the 2px steel ring
                    antialiasing: false
                    visible: Engine.duration > 0 || App.liveNow
                    y: Math.round(track.y + track.height / 2 - height / 2)
                    x: Math.round(track.width * player.barFrac - width / 2)
                    Rectangle {
                        anchors.centerIn: parent
                        width: 13; height: 13; radius: 0
                        color: "#f4f7fb"         // white core (kept)
                        antialiasing: false
                    }
                }
                MouseArea {
                    id: seekHover
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: (mouse) => {
                        player.pokeOsd()
                        App.seekPct(100 * mouse.x / width)
                    }
                    onPositionChanged: player.pokeOsd()
                }

                // Hover bubble: time + chapter name under the cursor.
                Rectangle {
                    visible: seekHover.containsMouse && (Engine.duration > 0 || App.liveWindow > 0)
                    x: Math.max(0, Math.min(parent.width - width,
                                            seekHover.mouseX - width / 2))
                    y: -height - 8
                    width: hoverTip.width + 20
                    height: hoverTip.height + 10
                    radius: 6
                    color: Qt.rgba(0.043, 0.063, 0.094, 0.95)
                    border.color: player.osdLine
                    border.width: 1
                    Row {
                        id: hoverTip
                        anchors.centerIn: parent
                        // the moment under the cursor and the chapter it falls
                        // in: the time in the HUD face, the name in the Codec face
                        readonly property real at: Engine.duration * seekHover.mouseX
                                                   / Math.max(1, seekHover.width)
                        readonly property string chapter: {
                            if (App.liveNow)
                                return ""
                            let name = ""
                            const ch = Engine.chapters
                            if (ch && ch.length > 0)
                                for (let i = 0; i < ch.length; ++i)
                                    if ((ch[i].time || 0) <= at)
                                        name = ch[i].title || ("CHAPTER " + (i + 1))
                            return name
                        }
                        ShadowText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: {
                                if (App.liveNow) {
                                    const f = seekHover.mouseX / Math.max(1, seekHover.width)
                                    const b = (1 - f) * App.liveWindow
                                    return Theme.mgsSafe(b < 12 ? "LIVE"
                                           : "\u2212" + App.prettyTime(b) + " BEHIND LIVE")
                                }
                                return Theme.mgsSafe(App.prettyTime(hoverTip.at))
                                       + (hoverTip.chapter ? "  ·  " : "")
                            }
                            color: player.osdFg
                            font.family: Theme.hudFont
                            font.pixelSize: 20
                            font.letterSpacing: 1
                        }
                        CodecText {
                            visible: hoverTip.chapter !== ""
                            text: Theme.mgsSafe(hoverTip.chapter.toUpperCase())
                            color: player.osdFg
                            font.pixelSize: 16
                            font.letterSpacing: 1
                        }
                    }
                }
            }

            // ── the readout ──────────────────────────────────────────────
            // Horizontal, and mirrored: label outboard, value inboard, same
            // sizes at both ends. Beside rather than above keeps the bar
            // shallow (every pixel the OSD grows is a pixel of film it covers)
            // and matched sizes keep it balanced — the blown-up ELAPSED that
            // was here read as a clock bolted to the left corner rather than
            // part of the bar.
            Item {
                width: parent.width
                height: 20

                component Field: Row {
                    property alias label: lbl.text
                    property alias value: val.text
                    property color valueColor: player.osdFg
                    property bool labelFirst: true
                    spacing: 9
                    ShadowText {
                        id: lbl
                        visible: parent.labelFirst
                        color: player.osdDim
                        font.family: Theme.hudFont
                        font.pixelSize: 18
                        font.letterSpacing: 2
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    ShadowText {
                        id: val
                        color: parent.valueColor
                        font.family: Theme.hudFont
                        font.pixelSize: Math.round(DS.tBody * 2)
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    ShadowText {
                        visible: !parent.labelFirst
                        text: lbl.text
                        color: player.osdDim
                        font.family: Theme.hudFont
                        font.pixelSize: 18
                        font.letterSpacing: 2
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                Field {
                    id: elapsed
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    label: "ELAPSED"
                    // Live: how long YOU have been watching (the stream clock
                    // means nothing here); LIVE FOR on the right is its age.
                    value: Theme.mgsSafe(App.prettyTime(App.liveNow ? App.liveWatched
                                                                    : Engine.position))
                }

                // Chapter takes the middle, and only when there is one — an
                // empty centred slot is what made the old row read as three
                // numbers floating in space.
                CodecText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: Math.max(0, parent.width - elapsed.width - remain.width - 60)
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideMiddle
                    text: {
                        const ch = Engine.chapters
                        if (!ch || ch.length === 0)
                            return ""
                        let cur = ""
                        for (let i = 0; i < ch.length; ++i)
                            if ((ch[i].time || 0) <= Engine.position)
                                cur = ch[i].title || ""
                        cur = cur.trim()
                        if (!cur || /^\(?unnamed\)?$/i.test(cur))
                            return ""
                        return Theme.mgsSafe(cur.toUpperCase())
                    }
                    color: player.osdDim
                    font.pixelSize: 16          // the Codec grid at 1x: crisp
                    font.letterSpacing: 1
                }

                Field {
                    id: remain
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    // Live reads "LIVE FOR 2 HR 14 MIN" (label first); a film is
                    // mirrored: value inboard, label out. Unknown age = hidden.
                    visible: !App.liveNow || App.liveFor > 0
                    labelFirst: App.liveNow
                    label: App.liveNow ? "LIVE FOR" : "REMAINING"
                    value: Theme.mgsSafe(App.liveNow ? player.liveAge(App.liveFor)
                                       : "\u2212" + App.prettyTime(
                                             Math.max(0, Engine.duration - Engine.position)))
                }
            }
        }
    }

    // ── Skip intro pill (chapter-driven, independent of the OSD) ──────────
    Rectangle {
        visible: player.introActive && !player.autoplayActive
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.rightMargin: player.osdSide + 18
        // sits just above the OSD while it's up (a fixed margin overlapped the
        // bar wherever it is taller), and drops back down when it hides
        anchors.bottomMargin: player.osdVisible ? osd.height + player.osdFoot + 16 : 64
        Behavior on anchors.bottomMargin { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
        width: skipRow.width + 36
        height: 42
        radius: 8
        color: Theme.surface
        border.color: Theme.accent
        border.width: 1
        opacity: 0.95

        Row {
            id: skipRow
            anchors.centerIn: parent
            spacing: 10
            ShadowText {
                text: "SKIP INTRO"
                color: Theme.fg
                font.family: Theme.hudFont
                font.pixelSize: 24
                font.letterSpacing: 3
                anchors.verticalCenter: parent.verticalCenter
            }
            ReturnGlyph {
                width: 10; height: 9
                color: Theme.accent
                anchors.verticalCenter: parent.verticalCenter
            }
        }
        MouseArea { anchors.fill: parent; onClicked: { Sfx.play("select"); player.skipIntro() } }
    }

    // ── Autoplay: countdown / continue-ask (also UP NEXT at the credits) ──
    // Sized by its content (a fixed height clipped the type), the countdown on
    // its own line, and the two choices below it as real buttons — the mouse
    // works too, not only the keys.
    Panel {
        id: upNext
        visible: player.autoplayActive
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 64          // the OSD hides while this is up — no room to keep
        width: Math.min(860, parent.width - 120)   // room for "show  S01E02 · episode name"
        height: upCol.implicitHeight + 40
        color: Theme.withAlpha(Theme.bg, 0.92)
        active: true

        Column {
            id: upCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 20
            spacing: 12

            ShadowText {
                text: player.autoplayAsking ? "CONTINUE WATCHING?"
                    : player.creditsMode ? "UP NEXT" : "NEXT EPISODE"
                color: player.autoplayAsking ? Theme.warning : Theme.accent
                font.family: Theme.codecFont
                font.pixelSize: 14
                font.letterSpacing: 4
            }
            ShadowText {
                width: parent.width
                text: Theme.mgsSafe(player.autoplayTitle)
                color: Theme.fg
                font.family: Theme.hudFont
                font.pixelSize: 34
                elide: Text.ElideRight
            }
            // Mechanical countdown: the bar fills over the countdown.
            Item {
                visible: !player.autoplayAsking
                width: parent.width
                height: 3
                Rectangle { anchors.fill: parent; color: Theme.surfaceHi }
                Rectangle {
                    height: parent.height
                    color: Theme.accent
                    width: 0
                    NumberAnimation on width {
                        running: player.autoplayActive && !player.autoplayAsking
                        from: 0
                        to: upCol.width
                        duration: autoplayTimer.interval
                    }
                }
            }
            // Boxed keycaps in the same grammar as every other view's keytips,
            // each one clickable: [label, keycap, action].
            Row {
                anchors.right: parent.right
                spacing: 18
                Repeater {
                    model: player.autoplayAsking ? [["CONTINUE", "⏎", "go"], ["STOP", "␣", "cancel"]]
                                                 : [["CANCEL", "␣", "cancel"], ["NOW", "⏎", "go"]]
                    Item {
                        id: choice
                        required property var modelData
                        width: choiceRow.implicitWidth + 12
                        height: choiceRow.implicitHeight + 8
                        Rectangle {
                            anchors.fill: parent
                            radius: 4
                            color: choiceMouse.containsMouse ? Theme.withAlpha(Theme.accent, 0.18) : "transparent"
                        }
                        Row {
                            id: choiceRow
                            anchors.centerIn: parent
                            spacing: 6
                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                width: pc.implicitWidth + 10
                                height: pc.implicitHeight + 6
                                radius: 3
                                color: Theme.withAlpha(Theme.bg, 0.45)
                                border.width: 1
                                border.color: Theme.withAlpha(Theme.fg, 0.18)
                                ShadowText {
                                    id: pc
                                    anchors.centerIn: parent
                                    text: choice.modelData[1]
                                    color: Theme.withAlpha(Theme.fg, 0.6)
                                    font.family: Theme.hudFont   // ⏎ / ␣ — the HUD draws both
                                    font.pixelSize: 26
                                }
                            }
                            ShadowText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: Theme.mgsSafe(choice.modelData[0])
                                color: choiceMouse.containsMouse ? Theme.fg : Theme.dimFg
                                font.family: Theme.hudFont
                                font.pixelSize: 19
                                font.letterSpacing: 1.5
                            }
                        }
                        MouseArea {
                            id: choiceMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            // the same cue as its key: ⏎ go = select, ␣ cancel = back
                            onClicked: {
                                Sfx.play(choice.modelData[2] === "go" ? "select" : "back")
                                choice.modelData[2] === "go" ? player.goAutoplay()
                                                             : player.cancelAutoplay()
                            }
                        }
                    }
                }
            }
        }
    }
}
