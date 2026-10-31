import QtQuick

// SETTINGS — the system's own page, on the mech grammar every other screen
// already wears: eight sections on the YouTube hexagon tabs, rows on the output
// picker's plates, values in the codec face, and on a wide screen a readout
// panel beside the rows that shows what the selected setting does — a live
// caption sample, the miniplayer's corner, the remote's key map.
//
//   PLAYBACK  — audio device + language, night mode, seek step, autoplay, sleep
//   SUBTITLES — captions here and on a cast TV (size / font / colour / box)
//   DISPLAY   — the display + mode, HDR, miniplayer corner, theme, glass, home motion
//   CAST      — default TV, output now, device search, party name
//   LIBRARY   — hub + links, sync, auto-update, update / rescan / audit, media roots
//   YOUTUBE   — the account (a browser's login) or codec's own lists, import, engine
//   REMOTE    — what each configurable OFA key does (10 spares + 4 colours)
//   SYSTEM    — debug log, editor, version, quit
//
// One walk: ↑/↓ (j/k) rows · ←/→ step a value either way (every cycle takes a
// direction now) · ⏎ applies / toggles / runs · ↑ off the first row lands on
// the tab strip, where ←/→ change section — so a remote (arrows + OK) reaches
// everything a keyboard does. [ ] switch sections from anywhere. Every row and
// tab is also a mouse target; ◂ ▸ on a row are buttons.
FocusScope {
    id: settings

    // ── Sections ───────────────────────────────────────────────────────────
    readonly property var sections: ["playback", "subtitles", "display", "cast", "library", "youtube", "remote", "system"]
    readonly property var sectionLabels: ["PLAYBACK", "SUBTITLES", "DISPLAY", "CAST", "LIBRARY", "YOUTUBE", "REMOTE", "SYSTEM"]
    property string section: "playback"
    readonly property int sectionIdx: sections.indexOf(section)
    property int sectionDir: 1          // which way the last switch went → slide direction
    property int idx: 0
    property int rowCount: 0
    property bool tabFocus: false       // ↑ off row 0: the tab strip has the arrows
    property bool editing: false        // a text field has the keys
    property int cascadeRev: 0          // bumped on entry / section switch → rows cascade in
    property double lastG: 0
    readonly property var devices: Engine.audioDevices
    property var roots: App.mediaRoots()
    property string defaultTv: App.getSetting("lastCastTarget", "")
    property var links: ({})
    property real glass: App.glassLevel
    property bool quitArmed: false
    // the selected row (for the readout panel) — re-read whenever the walk moves
    property var selRow: null
    function refreshSel() { selRow = tabFocus ? null : rowAt(idx) }
    onIdxChanged: {
        refreshSel()
        if (grabbed && rowAt(idx) !== grabbed) applyGrab()   // moving off a grabbed row applies it
    }
    onTabFocusChanged: refreshSel()
    onRowCountChanged: refreshSel()

    // ── Geometry ───────────────────────────────────────────────────────────
    // The page is drawn for a 1080p-class screen (a 1240 column beside a 600
    // readout). A bigger screen scales every LENGTH and TYPE size by k, so the
    // page fills it as it fills 1080p — 1.33 at 2560×1440 ("wasting tons
    // of screen space"), 2 at 4K; never below 1 (the CRT keeps its sizes).
    // TEXTURES keep their whole-pixel art scale (platePx, the switch, the
    // section tabs' hexagons): plates grow longer and taller, never blurrier.
    // The CRT is the exception that went the other way: its pixels are about
    // DP-3's size, so k=1 drew the page ~25% smaller there than on the desk
    // panel, over an empty lower half. It takes DP-3's physical size (1.25 at
    // 1280x1024, bounded by its height); the widths still share its glass.
    readonly property bool onCrt: App.mode === "crt"
    readonly property real k: onCrt ? Math.max(1, Math.min(1.333, height / 750))
                                    : Math.max(1, Math.min(width / 1924, height / 1040))
    function u(n) { return Math.round(n * k) }
    readonly property int platePx: 2
    readonly property int rowH: u(50)
    // the plate art's 3 transparent px + outline px at each end (at platePx)
    readonly property int rowEdgeIn: 4 * platePx
    // the page column starts at the header's inset (28), like the library and
    // YouTube; Main's header rule ends with it (ruleW)
    // (8 on the CRT: its glass edge is the frame — the YouTube/library gutter)
    readonly property int colX: onCrt ? 8 : 28
    // The readout panel lives beside the rows. Where there's room each takes
    // its designed (k-scaled) width; where there isn't — the CRT's glass — they
    // SHARE it, about 60/40, rather than the readout vanishing ("the
    // right side indicators are gone" on the CRT). Only a window too narrow
    // for a 340-px readout beside 420 px of rows drops it.
    readonly property int panelGap: u(28)
    readonly property int avail: width - colX - 28 - panelGap
    readonly property bool wide: avail >= 760
    readonly property int panelW: wide ? Math.min(u(600), Math.max(340, Math.round(avail * 0.4))) : 0
    readonly property int colW: wide ? Math.min(u(1240), avail - panelW) : Math.min(u(1240), width - 56)
    // Main's header rule runs as far as the tabs do
    readonly property real ruleW: (tabsSpan ? colW + panelGap + panelW : colW) - rowEdgeIn
    // a value never pushes its label off the row: past this it ends in "…"
    readonly property int valueMaxW: Math.round(colW * 0.6)
    // The section tabs (fixed art size) ride above the rows; when they need
    // more than the row column (the CRT) they span the readout's width too and
    // the readout starts under them instead of beside them.
    // (the tabs live in the top strip now, so they never span the readout)
    readonly property bool tabsSpan: false
    // where the top strip has room for the section tabs (set by Main, as for
    // YouTube's; the fallbacks are for a view shown on its own)
    property real stripX: 200
    property real stripMidY: -20
    property real stripRight: width - 400

    // The rows' two-line label (HUD 30 over HUD 18) centred on its INK — the
    // output picker's maths, so the two screens' rows read identically.
    readonly property int lineGap: -2
    FontMetrics { id: rowTitleFm; font.family: Theme.hudFont; font.pixelSize: settings.u(30) }
    FontMetrics { id: rowSubFm; font.family: Theme.hudFont; font.pixelSize: settings.u(18) }
    readonly property real inkShift: {
        void rowTitleFm.height; void rowSubFm.height
        const r = rowTitleFm.tightBoundingRect("H")
        const inkTop = rowTitleFm.ascent + r.y
        const inkBottom = rowTitleFm.height + lineGap + rowSubFm.ascent
        return (rowTitleFm.height + lineGap + rowSubFm.height) / 2 - (inkTop + inkBottom) / 2
    }
    // where a codec-face capital's ink middle sits under its Text's top
    FontMetrics { id: valFm; font.family: Theme.codecFont; font.pixelSize: settings.u(22) }
    function capMid(fm) {
        void fm.height
        const r = fm.tightBoundingRect("H")
        return fm.ascent + r.y + r.height / 2
    }
    // the value words' seat on the plate face (codec 22, ink-centred)
    readonly property int valDrop: Math.round(valFm.height / 2 - capMid(valFm))

    function devSrc(rel) {
        var d = App.heroDevPath(rel)
        return d !== "" ? d + "?v=" + App.heroDevRev : "qrc:/assets/mechui/" + rel + ".png"
    }
    // a caption font LABEL (MGS CODEC / MGS HUD / SANS / SERIF / MONO) → a family
    function captionFamily(label) {
        if (label === "MGS CODEC") return Theme.codecFont
        if (label === "MGS HUD") return Theme.hudFont
        if (label === "SERIF") return "serif"
        if (label === "MONO") return Theme.monoFont
        return "sans-serif"
    }

    // ── Entry ──────────────────────────────────────────────────────────────
    function entered() {
        forceActiveFocus()
        tabFocus = false
        editing = false
        quitArmed = false
        refreshRoots()
        App.refreshPaired()
        App.refreshSharing()
        links = App.hubLinks()
        defaultTv = App.getSetting("lastCastTarget", "")
        App.checkHub()
        // asked to open on a section (an empty YouTube list's ⏎ → YOUTUBE)
        const jump = App.takeSettingsJump()
        if (jump.length > 0 && sections.indexOf(jump) >= 0 && jump !== section) {
            openSection(jump)
            return
        }
        if (section === "youtube") { YouTube.findProfiles(); YouTube.refreshAccount() }
        reindex()
        if (section === "playback") syncDeviceIdx()
        // the cascade reads the rows' effective visibility — settled a tick later
        Qt.callLater(function() { settings.cascadeRev++ })
        refreshSel()
    }
    onVisibleChanged: { if (visible) entered(); else applyGrab() }
    // Built by an on-demand Loader that is already showing: visible never
    // CHANGES on the first visit, so run the entry from here too.
    Component.onCompleted: if (visible) entered()

    Connections {
        target: App
        function onMediaRootsChanged() { settings.refreshRoots() }
        function onSettingsJumpRequested() {
            const jump = App.takeSettingsJump()
            if (jump.length > 0 && settings.sections.indexOf(jump) >= 0) settings.openSection(jump)
        }
    }
    function refreshRoots() { roots = App.mediaRoots(); reindexLater() }
    function syncDeviceIdx() {
        for (let i = 0; i < devices.length; i++)
            if (devices[i].name === Engine.audioDevice) { idx = i; return }
    }

    // ── Rows: numbered by position, not by hand ────────────────────────────
    // Each section is a Column of SettingRows (some from Repeaters). The walk
    // index is assigned by walking the column: a row that hides, a device that
    // appears, a root added — the numbering follows, nothing is hand-counted.
    function sectionItem(s) {
        return s === "playback" ? secPlayback : s === "subtitles" ? secSubtitles
             : s === "display" ? secDisplay : s === "cast" ? secCast
             : s === "library" ? secLibrary : s === "youtube" ? secYoutube
             : s === "remote" ? secRemote : secSystem
    }
    function reindex() {
        const col = sectionItem(section)
        let n = 0
        for (let i = 0; i < col.children.length; ++i) {
            const c = col.children[i]
            if (c.isRow !== true) continue
            c.rowIndex = (c.shown && c.selectable) ? n++ : -1
        }
        rowCount = n
        if (idx > n - 1) idx = Math.max(0, n - 1)
        refreshSel()
    }
    function reindexLater() { Qt.callLater(reindex) }
    function rowAt(i) {
        const col = sectionItem(section)
        for (let k = 0; k < col.children.length; ++k) {
            const c = col.children[k]
            if (c.isRow === true && c.rowIndex === i) return c
        }
        return null
    }
    // ── Changing a value: ⏎ GRABS, ←/→ adjust, ⏎ APPLIES, Esc puts it back ──
    // ←/→ are the SECTIONS everywhere (the author reached for them to change tabs and
    // flipped a media root instead). A value changes only on purpose: ⏎ on a
    // many-valued row grabs it — its arrows light, ←/→ step it LIVE (the
    // sample, the readout follow), ⏎ applies, Esc steps it back to where it
    // was. Leaving the row any other way (↑/↓, a section, the stage) applies.
    // Two-state rows (`instant`: a media root's MOVIES/TV, FRAME RATE), switches,
    // actions and fields act on ⏎ at once, as before.
    property Item grabbed: null
    property string grabFrom: ""
    property int grabNet: 0
    function grab(r) { grabbed = r; grabFrom = r.value; grabNet = 0; sfx("open") }
    function applyGrab() { grabbed = null }
    function cancelGrab() {
        const r = grabbed
        if (!r) return
        // step back the way it came until it reads what it did (a wrap or an
        // end stop can't fool a count — the value itself is the test)
        const back = grabNet > 0 ? -1 : 1
        for (let n = 0; n < 64 && r.value !== grabFrom; n++) r.step(back)
        grabbed = null
    }
    function stepGrab(dir) {
        if (!grabbed) return
        const r = grabbed, was = r.value
        r.step(dir)
        grabNet += dir
        sfx(r.value === was ? "bump" : "move")   // an end stop that didn't give = bump
    }
    function activateRow() {
        const r = rowAt(idx)
        if (!r) return
        if (r.kind === "cycle" && !r.instant) grab(r)
        else { sfxActivate(r); r.activated() }
    }

    // ── UI sounds (Sfx) ────────────────────────────────────────────────────
    // Played where the walk happens, never from a watcher, so the page's own
    // moves (a section opening on row 0, the device row found on entry) stay
    // silent: the selection or a grabbed value moving `move`, a step that
    // couldn't `bump`, ⏎ / a click `select`, a grab or a field opening `open`,
    // esc — a grab put back, a field let go, home — `back`. Only while
    // Settings has the floor (the queue, search, the output picker own it).
    readonly property bool sfxLive: visible && !App.queueOpen && !App.searchOpen && !App.outputOpen
    function sfx(cue, pan) { if (sfxLive) Sfx.play(cue, pan || 0) }
    // the section tabs run left to right: a switch pans to where it landed
    function tabPan() { return (sectionIdx / Math.max(1, sections.length - 1) - 0.5) * 0.5 }
    // a row that acts at once; UI SOUNDS plays its own preview (sfxOwn)
    function sfxActivate(r) { if (!r.sfxOwn) sfx(r.kind === "text" ? "open" : "select") }
    // a walk step: moved, or stood at an end
    function sfxWalk(was, wasTab) { sfx(idx !== was || tabFocus !== wasTab ? "move" : "bump") }
    // the pointer put the selection on another row
    function sfxPoint(i) { if (i !== idx || tabFocus) sfx("move") }

    function switchSection(dir) {
        const n = sections.length
        sectionDir = dir
        section = sections[((sectionIdx + dir) % n + n) % n]
        sfx("move", tabPan())
    }
    function openSection(s) {
        sectionDir = sections.indexOf(s) >= sectionIdx ? 1 : -1
        section = s
    }
    onSectionChanged: {
        applyGrab()
        idx = 0
        editing = false
        quitArmed = false
        reindex()
        if (section === "playback") syncDeviceIdx()
        if (section === "library") { links = App.hubLinks() }
        if (section === "youtube") { YouTube.findProfiles(); YouTube.refreshAccount() }
        Qt.callLater(function() { settings.cascadeRev++ })
        slideAnim.restart()
        pageFlick.contentY = 0
    }

    // ── The walk: one place for every input ───────────────────────────────
    // ↑ off the first row lands on the section tabs; ←/→ step a value, or
    // the section while the tabs hold the selection.
    function navUp() {
        const was = idx, wasTab = tabFocus
        if (idx === 0 || rowCount === 0) tabFocus = true
        else idx = Math.max(0, idx - 1)
        sfxWalk(was, wasTab)
    }
    function navDown() {
        const was = idx, wasTab = tabFocus
        if (tabFocus) tabFocus = false
        else idx = Math.min(rowCount - 1, idx + 1)
        sfxWalk(was, wasTab)
    }
    function navSide(dir) {
        if (grabbed) stepGrab(dir)
        else switchSection(dir)
    }

    // ── The mouse as a remote ──────────────────────────────────────────────
    // The wheel = ↑/↓, a row a notch (the home screen's rule); the tilt
    // wheel's side clicks = the SECTION tabs, like YouTube's tabs (the author,
    // 2026-10-13: "the mouse wheel side clicks should be moving between tabs
    // like YouTube") — never a value, which stays on ←/→ and the ◂ ▸ arrows.
    // The trackball's ball (wheel held) = ↑/↓, and rolled sideways = the
    // tabs too, once it has rolled three notches' worth (a drift while
    // clicking never steps). Wheel click = OK and the thumb buttons = Back
    // come app-wide (AppController::eventFilter).
    Connections {
        target: App
        enabled: settings.visible && !settings.editing && !App.queueOpen
                 && !App.searchOpen && !App.outputOpen
        function onTiltStep(dir) { settings.switchSection(dir) }
    }
    WheelHandler {
        // ⚠ TouchPad too: Qt's Wayland backend labels every scroll on this
        // desktop a touchpad, the trackball's wheel included (HomeView).
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        enabled: settings.visible && !settings.editing
        property real accum: 0
        onWheel: (e) => {
            const ball = e.pixelDelta.x !== 0 || e.pixelDelta.y !== 0
            accum += e.angleDelta.y
            const need = ball ? 360 : 120
            if (accum >= need) settings.navUp()
            else if (accum <= -need) settings.navDown()
            else return
            accum = 0
        }
    }
    WheelHandler {
        // the ball rolled clearly SIDEWAYS = the section tabs, as the tilt
        // does (a tilt click comes via App.tiltStep, consumed app-wide)
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        enabled: settings.visible && !settings.editing
        orientation: Qt.Horizontal
        property real accum: 0
        onWheel: (e) => {
            if (e.pixelDelta.x === 0 && e.pixelDelta.y === 0)
                return
            if (Math.abs(e.angleDelta.x) <= 2 * Math.abs(e.angleDelta.y))
                return // a vertical roll's drift, not a sideways one
            accum += e.angleDelta.x
            if (Math.abs(accum) < 360)
                return
            settings.switchSection(accum > 0 ? -1 : 1)
            accum = 0
        }
    }

    // ── Keys ───────────────────────────────────────────────────────────────
    Keys.onPressed: (event) => {
        if (editing)
            return
        switch (event.key) {
        case Qt.Key_Down: case Qt.Key_J:
            applyGrab()
            navDown()
            break
        case Qt.Key_Up: case Qt.Key_K:
            applyGrab()
            navUp()
            break
        // h/l are vim's ←/→ here as on every other screen — the SECTION, or a
        // grabbed value. (h used to LEAVE Settings, beside Esc — "that's
        // a navigation key".)
        case Qt.Key_Left: case Qt.Key_H:
            navSide(-1)
            break
        case Qt.Key_Right: case Qt.Key_L:
            navSide(1)
            break
        case Qt.Key_PageUp: switchSection(-1); break       // the remote's CH ▲/▼, a keyboard's PgUp/PgDn
        case Qt.Key_PageDown: switchSection(1); break
        case Qt.Key_BracketLeft: switchSection(-1); break
        case Qt.Key_BracketRight: switchSection(1); break
        case Qt.Key_Return: case Qt.Key_Enter: case Qt.Key_Space:
            if (grabbed) { sfx("select"); applyGrab() }
            else if (tabFocus) { sfx("select"); tabFocus = false }
            else activateRow()
            break
        case Qt.Key_A:
            if (section === "library") pathBrowser.open("")
            else return
            break
        case Qt.Key_D: {
            const r = rowAt(idx)
            if (section === "library" && r && r.rootIndex !== undefined && r.rootIndex >= 0) {
                sfx("select"); App.removeMediaRoot(r.rootIndex)
            } else if (section === "library" && r && r.deviceId) {
                sfx("select"); App.removePaired(r.deviceId)
            } else return
            break
        }
        case Qt.Key_T: {
            const r = rowAt(idx)
            if (section === "library" && r && r.rootIndex !== undefined && r.rootIndex >= 0) {
                sfx("select"); App.toggleMediaRootKind(r.rootIndex)
            } else return
            break
        }
        case Qt.Key_R:
            if (section === "library") { sfx("select"); App.checkHub() }
            else return
            break
        case Qt.Key_G: {
            // vim: gg / G to the ends of the walk.
            const was = idx, wasTab = tabFocus
            if (event.modifiers & Qt.ShiftModifier) {
                idx = Math.max(0, rowCount - 1); tabFocus = false
            } else {
                const now = Date.now()
                if (now - lastG < 450) { idx = 0; tabFocus = false }
                lastG = now
            }
            if (idx !== was || tabFocus !== wasTab) sfx("move")
            break
        }
        case Qt.Key_Q: App.queueOpen = !App.queueOpen; break
        case Qt.Key_P: App.toPlayer(); break
        case Qt.Key_X: App.stopPlayback(); break
        case Qt.Key_Escape:
            sfx("back")   // a grab put back, or home
            if (grabbed) cancelGrab()
            else App.goHome()
            break
        default: return
        }
        event.accepted = true
    }

    // ── One row ────────────────────────────────────────────────────────────
    // A plate (MechSelectRow, bleeding to the column edge like the output
    // picker's), the two-line label on its dark face, and on the right the
    // row's instrument: ◂ VALUE ▸ for a cycle, a pixel switch for a toggle, a
    // verb (or a filling bar while it works) for an action, a status dot for
    // a readout, the current text for a field. The content rides the plate's
    // press (hopY) and the row's entrance cascade.
    component SettingRow: Item {
        id: row
        readonly property bool isRow: true
        property string label: ""
        property string sub: ""
        property string help: ""            // the readout panel's longer word (sub when empty)
        property string value: ""
        property string kind: "cycle"       // cycle | toggle | action | status | text | pick
        property bool lit: true             // dim value ink when a feature is off
        property bool on: false             // toggle: the switch position
        property bool busy: false           // action: a bar fills while it works
        property bool pulse: false          // status: the dot breathes (probing)
        property bool dot: true             // status: show the dot at all
        property color valueColor: Theme.accent
        property color swatch: "transparent" // a small colour square before the label (remote colours)
        property bool selectable: kind !== "status"
        // a two-state cycle: ⏎ flips it at once (nothing to preview)
        property bool instant: false
        property bool sfxOwn: false         // plays its own cue when it acts (UI SOUNDS)
        readonly property bool grabbed: settings.grabbed === row
        // A conditional row sets `shown`, not `visible`: `visible` reads the
        // EFFECTIVE visibility, which is false for every row of a section that
        // has only just been switched to (its column's binding hasn't settled),
        // so a walk numbered on it came up empty for a frame.
        property bool shown: true
        visible: shown
        onShownChanged: settings.reindexLater()
        property int rowIndex: -1
        property int rootIndex: -1          // media-root rows (d removes, t flips)
        property string deviceId: ""        // paired-device rows (d removes)
        property int keySlot: -1            // remote rows: which OFA key (the key map lights it)
        property string editText: ""        // text rows: the field's live contents
        property string placeholder: ""
        readonly property bool sel: selectable && !settings.tabFocus && settings.idx === rowIndex
        signal step(int dir)
        signal activated
        signal committed(string text)
        width: parent ? parent.width : 0
        height: settings.rowH

        // the value flashes bright when it changes (then settles to its ink)
        property real flashT: 0
        property bool ready: false
        Component.onCompleted: ready = true
        onValueChanged: if (ready && visible) flash.restart()
        NumberAnimation { id: flash; target: row; property: "flashT"; from: 1; to: 0
                          duration: DS.grand; easing.type: Easing.OutCubic }
        // the arrow on the side you stepped kicks outward
        property real kickX: 0
        onStep: (dir) => { kickAnim.stop(); kickX = 4 * dir; kickAnim.restart() }
        NumberAnimation { id: kickAnim; target: row; property: "kickX"; to: 0
                          duration: DS.slow; easing.type: Easing.OutBack }

        // entrance: rows cascade in DS.stagger apart when a section shows
        property real inY: 0
        Connections {
            target: settings
            function onCascadeRevChanged() {
                if (row.visible && row.parent && row.parent.visible) cascade.restart()
            }
        }
        SequentialAnimation {
            id: cascade
            PauseAnimation { duration: Math.min(DS.staggerMax, Math.max(0, row.rowIndex) * DS.stagger) }
            ParallelAnimation {
                NumberAnimation { target: row; property: "opacity"; from: 0; to: 1
                                  duration: DS.base; easing.type: Easing.OutQuad }
                NumberAnimation { target: row; property: "inY"; from: 10; to: 0
                                  duration: DS.slow; easing.type: Easing.OutCubic }
            }
        }

        MechSelectRow {
            id: plate
            bleed: true
            anchors.fill: parent
            selected: row.sel
            hovered: row.selectable && rowMouse.containsMouse
            glass: settings.glass
            armed: settings.visible
            opacity: row.selectable ? 1 : 0.55     // a readout sits lower than a control
        }
        Item {
            id: face
            anchors.fill: parent
            // centred on the plate's dark face, not the row (its lighter foot is below)
            transform: Translate { y: plate.hopY + plate.faceMid - plate.height / 2 + row.inY }

            Rectangle {   // colour-key swatch (REMOTE's RED / GREEN / YELLOW / BLUE)
                id: swatchRect
                visible: row.swatch.a > 0
                x: settings.u(16)
                anchors.verticalCenter: parent.verticalCenter
                width: 7 * settings.platePx; height: width
                color: row.swatch
                border.width: settings.platePx; border.color: "#222034"
                antialiasing: false
            }
            Column {
                id: labelCol
                x: swatchRect.visible ? swatchRect.x + swatchRect.width + settings.u(12) : settings.u(16)
                spacing: settings.lineGap
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: settings.inkShift
                width: instrument.x - x - settings.u(16)
                Text {
                    width: parent.width
                    text: Theme.mgsSafe(row.label)
                    color: row.sel ? Theme.fg : (row.selectable ? Theme.dimFg : Theme.withAlpha(Theme.fg, 0.75))
                    Behavior on color { ColorAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                    font.family: Theme.hudFont
                    font.pixelSize: settings.u(30)
                    font.letterSpacing: settings.u(2)
                    elide: Text.ElideRight
                    style: Text.Raised; styleColor: "#000000"
                }
                Text {
                    width: parent.width
                    visible: row.sub.length > 0
                    text: Theme.mgsSafe(row.sub)
                    color: Theme.dimFg
                    font.family: Theme.hudFont
                    font.pixelSize: settings.u(18)
                    font.letterSpacing: settings.u(1)
                    elide: Text.ElideRight
                    style: Text.Raised; styleColor: "#000000"
                }
            }

            // ── the instrument, right-aligned ──
            Item {
                id: instrument
                anchors.right: parent.right
                anchors.rightMargin: settings.u(16)
                anchors.verticalCenter: parent.verticalCenter
                // the one visible instrument's width (an explicit pick — a
                // childrenRect would loop through the right anchors)
                width: cycleBox.visible ? cycleBox.width
                     : toggleBox.visible ? toggleBox.width
                     : actionBox.visible ? actionBox.width
                     : statusBox.visible ? statusBox.width
                     : textBox.visible ? textBox.width : 0
                height: parent.height

                // cycle: ◂ VALUE ▸ (arrows only while the row is selected / hovered)
                Row {
                    id: cycleBox
                    visible: row.kind === "cycle" || row.kind === "pick"
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: settings.u(10)
                    // the arrows: lit while GRABBED (←/→ adjust), there under the
                    // pointer (click to step); a merely selected row hides them —
                    // its ←/→ are the sections
                    readonly property bool arrows: row.kind === "cycle" && (row.grabbed || rowMouse.containsMouse)
                    Text {
                        text: "◂"
                        opacity: cycleBox.arrows ? (arrowLMouse.containsMouse || row.grabbed ? 1 : 0.55) : 0
                        Behavior on opacity { NumberAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                        color: row.grabbed ? Theme.accent : Theme.fg
                        font.family: Theme.hudFont
                        font.pixelSize: settings.u(26)
                        anchors.verticalCenter: parent.verticalCenter
                        transform: Translate { x: Math.min(0, row.kickX) }
                        MouseArea {
                            id: arrowLMouse
                            anchors.fill: parent; anchors.margins: -6
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            enabled: cycleBox.arrows
                            onClicked: { settings.idx = row.rowIndex; settings.tabFocus = false
                                         if (row.grabbed) settings.stepGrab(-1); else { settings.sfx("select"); row.step(-1) } }
                        }
                    }
                    Text {
                        text: Theme.mgsSafe(row.value)
                        width: Math.min(implicitWidth, settings.valueMaxW)
                        elide: Text.ElideRight
                        color: row.grabbed ? Theme.fg : Theme.mix(row.lit ? row.valueColor : Theme.dimFg, Theme.fg, row.flashT)
                        font.family: Theme.codecFont
                        font.pixelSize: settings.u(22)
                        font.letterSpacing: settings.u(2)
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.verticalCenterOffset: settings.valDrop
                    }
                    Text {
                        text: "▸"
                        opacity: cycleBox.arrows ? (arrowRMouse.containsMouse || row.grabbed ? 1 : 0.55) : 0
                        Behavior on opacity { NumberAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                        color: row.grabbed ? Theme.accent : Theme.fg
                        font.family: Theme.hudFont
                        font.pixelSize: settings.u(26)
                        anchors.verticalCenter: parent.verticalCenter
                        transform: Translate { x: Math.max(0, row.kickX) }
                        MouseArea {
                            id: arrowRMouse
                            anchors.fill: parent; anchors.margins: -6
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            enabled: cycleBox.arrows
                            onClicked: { settings.idx = row.rowIndex; settings.tabFocus = false
                                         if (row.grabbed) settings.stepGrab(1); else { settings.sfx("select"); row.step(1) } }
                        }
                    }
                }

                // toggle: a pixel switch + its word
                Row {
                    id: toggleBox
                    visible: row.kind === "toggle"
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: settings.u(12)
                    Text {
                        text: Theme.mgsSafe(row.value.length > 0 ? row.value : (row.on ? "ON" : "OFF"))
                        width: Math.min(implicitWidth, settings.valueMaxW)
                        elide: Text.ElideRight
                        color: Theme.mix(row.on ? row.valueColor : Theme.dimFg, Theme.fg, row.flashT)
                        font.family: Theme.codecFont
                        font.pixelSize: settings.u(22)
                        font.letterSpacing: settings.u(2)
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.verticalCenterOffset: settings.valDrop
                    }
                    PixelSwitch {
                        on: row.on
                        px: settings.platePx
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                // action: the verb, or a bar filling while it works
                Row {
                    id: actionBox
                    visible: row.kind === "action"
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: settings.u(14)
                    MechBar {
                        visible: row.busy
                        px: settings.platePx
                        maxWidth: settings.u(150)
                        darkTrack: true
                        anchors.verticalCenter: parent.verticalCenter
                        // an instrument filling, over and over, until the job lands
                        SequentialAnimation on value {
                            running: row.busy && row.visible
                            loops: Animation.Infinite
                            NumberAnimation { from: 0; to: 1; duration: 1400; easing.type: Easing.InOutQuad }
                            PauseAnimation { duration: 220 }
                        }
                    }
                    Text {
                        text: Theme.mgsSafe(row.busy ? "WORKING" : (row.value.length > 0 ? row.value : "RUN"))
                        color: row.busy ? Theme.accent
                             : Theme.mix(row.sel ? Theme.fg : Theme.dimFg, Theme.fg, row.flashT)
                        Behavior on color { ColorAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                        font.family: Theme.codecFont
                        font.pixelSize: settings.u(22)
                        font.letterSpacing: settings.u(2)
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.verticalCenterOffset: settings.valDrop
                    }
                }

                // status: a readout, dot + word
                MechStatus {
                    id: statusBox
                    visible: row.kind === "status"
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    label: row.value
                    ink: row.lit ? row.valueColor : Theme.dimFg
                    px: settings.u(20)
                    dot: row.dot
                    pulse: row.pulse
                }

                // text: the current text; editing swaps in a field (below)
                Text {
                    id: textBox
                    visible: row.kind === "text" && !row.editingNow
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.verticalCenterOffset: settings.valDrop
                    text: Theme.mgsSafe(row.value.length > 0 ? row.value : "—")
                    width: Math.min(implicitWidth, settings.valueMaxW)
                    elide: Text.ElideRight
                    color: Theme.mix(row.lit ? row.valueColor : Theme.dimFg, Theme.fg, row.flashT)
                    font.family: Theme.codecFont
                    font.pixelSize: settings.u(22)
                    font.letterSpacing: settings.u(2)
                }
            }

            // text rows: the field, over the label while editing
            Rectangle {
                visible: row.editingNow
                anchors.left: labelCol.left
                anchors.right: parent.right
                anchors.rightMargin: settings.u(16)
                anchors.verticalCenter: parent.verticalCenter
                height: settings.u(36)
                color: Theme.withAlpha("#181c23", 0.92)
                border.width: settings.platePx
                border.color: Theme.accent
                antialiasing: false
                TextInput {
                    id: fieldInput
                    anchors.fill: parent
                    anchors.leftMargin: settings.u(12)
                    anchors.rightMargin: settings.u(12)
                    verticalAlignment: TextInput.AlignVCenter
                    color: Theme.fg
                    // what you TYPE shows its case (a key, a path) — Departure
                    // Mono, as in every search field
                    font.family: "Departure Mono"
                    font.pixelSize: settings.u(22)
                    clip: true
                    selectByMouse: true
                    Keys.onPressed: (event) => {
                        if (event.key === Qt.Key_Escape) {
                            settings.sfx("back")
                            row.endEdit()
                            event.accepted = true
                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                            const t = text
                            settings.sfx("select")
                            row.endEdit()
                            row.committed(t)
                            event.accepted = true
                        }
                    }
                    Text {
                        anchors.fill: parent
                        verticalAlignment: Text.AlignVCenter
                        visible: fieldInput.text.length === 0
                        text: Theme.mgsSafe(row.placeholder)
                        color: Theme.dimFg
                        font: fieldInput.font
                    }
                }
            }
        }
        property bool editingNow: false
        function beginEdit() {
            settings.idx = rowIndex; settings.tabFocus = false
            fieldInput.text = row.editText
            editingNow = true
            settings.editing = true
            fieldInput.forceActiveFocus()
        }
        function endEdit() {
            editingNow = false
            settings.editing = false
            // The FocusScope remembers its focused child — drop the field's
            // focus explicitly or every later key silently types into it.
            fieldInput.focus = false
            settings.forceActiveFocus()
        }

        MouseArea {
            id: rowMouse
            anchors.fill: parent
            // the ◂ ▸ buttons sit inside; they take their own clicks (z above)
            z: -1
            enabled: row.selectable
            hoverEnabled: true
            // Rows appearing/moving under a parked cursor (section switch,
            // keyboard walk) must not steal the selection — pointer only.
            onEntered: if (App.pointerActive) { settings.sfxPoint(row.rowIndex); settings.idx = row.rowIndex; settings.tabFocus = false }
            onPositionChanged: if (App.pointerActive) { settings.sfxPoint(row.rowIndex); settings.idx = row.rowIndex; settings.tabFocus = false }
            // a click is ⏎: grabs a many-valued row (again: applies), acts on the rest
            onClicked: {
                settings.idx = row.rowIndex; settings.tabFocus = false
                if (row.grabbed) { settings.sfx("select"); settings.applyGrab() }
                else if (row.kind === "cycle" && !row.instant) settings.grab(row)
                else { settings.sfxActivate(row); row.activated() }
            }
        }
    }

    // A heading: what the rows under it are about, so a section reads as
    // groups at a glance (the author, 2026-10-13: audio devices blended in as if
    // each were a setting). The library's season headings' face — the codec
    // font tracked out, accent, shadowed — and a hairline running on to the
    // row's end; a quiet note may sit at the right. Never a row: no isRow, so
    // the walk (keys, wheel, remote) steps straight past it.
    component SettingHeading: Item {
        id: head
        readonly property bool isHeading: true
        property string label: ""
        property string note: ""
        property bool shown: true
        visible: shown
        width: parent ? parent.width : 0
        height: settings.u(46)
        ShadowText {
            id: headText
            x: settings.rowEdgeIn + settings.u(6)
            anchors.bottom: parent.bottom
            anchors.bottomMargin: settings.u(8)
            text: Theme.mgsSafe(head.label)
            color: Theme.withAlpha(Theme.accent, 0.85)
            font.family: Theme.codecFont
            font.pixelSize: settings.u(20)
            font.letterSpacing: settings.u(4)
        }
        // the middle of the codec capitals (6 of the face's 16 pixel rows,
        // sitting on the baseline): the hairline runs through it
        readonly property real capMidY: headText.y + headText.baselineOffset
                                        - headText.font.pixelSize * 384 / 1024 / 2
        Rectangle {
            x: headText.x + headText.width + settings.u(16)
            width: Math.max(0, (noteText.visible ? noteText.x - settings.u(16) : head.width - settings.rowEdgeIn) - x)
            y: Math.round(head.capMidY - height / 2)
            height: settings.platePx
            color: Theme.withAlpha(Theme.accent, 0.22)
            antialiasing: false
        }
        ShadowText {
            id: noteText
            visible: head.note.length > 0
            anchors.right: parent.right
            anchors.rightMargin: settings.rowEdgeIn + settings.u(6)
            y: Math.round(head.capMidY - height / 2)
            text: Theme.mgsSafe(head.note)
            color: Theme.dimFg
            font.family: Theme.hudFont
            font.pixelSize: settings.u(18)
            font.letterSpacing: settings.u(2)
        }
    }

    // A remote key's row (REMOTE ▸ TOUCHSCREEN KEYS / COLOUR KEYS): slot
    // 0-9 the touchscreen's spares, 10-13 the four colours.
    component RemoteKeyRow: SettingRow {
        property int slotNo: 0
        readonly property var entry: App.remoteMap[slotNo] || ({})
        readonly property bool colourKey: slotNo >= 10
        keySlot: slotNo
        label: entry.name || ""
        sub: colourKey ? "colour key — a free slot"
           : (entry.printed && entry.printed !== entry.label
                ? "printed " + entry.printed + " on the touchscreen"
                : "touchscreen key")
        help: (colourKey ? "One of the remote's four colour keys. " : "One of the ten keys on the remote's touchscreen page. ")
              + "←/→ walks the jobs it can do: SCREEN MODE, SUBTITLES and AUDIO TRACK drive the TV during a cast and the local player otherwise; RESUME needs a hold."
        value: entry.label || ""
        lit: entry.action !== "none"
        swatch: colourKey ? ["#c8503c", "#5aa864", "#e0c040", "#4a7fd0"][slotNo - 10] : "transparent"
        onStep: (dir) => App.stepRemoteSlot(slotNo, dir)
        onActivated: App.stepRemoteSlot(slotNo, 1)
    }

    // A pixel toggle: a dark well with a steel knob that slides across, on the
    // art grid (every edge a whole art pixel). Fixed steel — hardware doesn't
    // repaint with the wallpaper.
    component PixelSwitch: Item {
        id: sw
        property bool on: false
        property int px: 2
        width: 22 * px
        height: 12 * px
        Rectangle {   // outline + well
            anchors.fill: parent
            color: "#222034"
            antialiasing: false
            Rectangle {
                x: sw.px; y: sw.px
                width: parent.width - 2 * sw.px; height: parent.height - 2 * sw.px
                color: sw.on ? "#566c78" : "#181c23"
                Behavior on color { ColorAnimation { duration: DS.base } }
                antialiasing: false
            }
        }
        Rectangle {   // the knob
            y: sw.px
            x: sw.on ? sw.width - sw.px - width : sw.px
            Behavior on x { NumberAnimation { duration: DS.base; easing.type: Easing.OutCubic } }
            width: 10 * sw.px; height: 10 * sw.px
            color: sw.on ? "#aecbd9" : "#566c78"
            Behavior on color { ColorAnimation { duration: DS.base } }
            antialiasing: false
            Rectangle {   // a lit top edge on the knob, the plates' bevel
                x: sw.px; y: sw.px
                width: parent.width - 2 * sw.px; height: sw.px
                color: sw.on ? "#eef4f8" : "#aecbd9"
                antialiasing: false
            }
        }
    }

    // The readout's caption sample: a small screen with a film's dusk on it, the
    // caption drawn over the bottom as the player / receiver would.
    component SampleScreen: Rectangle {
        id: screen
        property string tag: ""
        property bool lit: true
        width: parent ? parent.width : 0
        height: Math.round(width * 9 / 16 * 0.62)
        color: "#0b0d12"
        border.width: settings.platePx
        border.color: lit ? Theme.accent : "#222034"
        Behavior on border.color { ColorAnimation { duration: DS.selFade } }
        antialiasing: false
        clip: true
        // a film's dusk: a warm band low, cold above — something for the ink to sit on
        Rectangle {
            anchors.fill: parent; anchors.margins: settings.platePx
            gradient: Gradient {
                GradientStop { position: 0.0; color: "#1a2030" }
                GradientStop { position: 0.55; color: "#2b2a33" }
                GradientStop { position: 1.0; color: "#4a3a2c" }
            }
        }
        Text {
            x: settings.u(10); y: settings.u(8)
            text: screen.tag
            color: screen.lit ? Theme.accent : Theme.dimFg
            font.family: Theme.hudFont
            font.pixelSize: settings.u(18)
            font.letterSpacing: settings.u(2)
        }
    }

    // The readout's remote key: a drawn touchscreen cap carrying the printed
    // word and the job it does; lit when its row is selected.
    component KeyCap: Rectangle {
        id: cap
        property int slot: 0
        property int litSlot: -1
        property color swatch: "transparent"
        readonly property var entry: App.remoteMap[slot] || ({})
        readonly property bool lit: litSlot === slot
        height: settings.u(46)
        color: lit ? "#566c78" : "#181c23"
        Behavior on color { ColorAnimation { duration: DS.selFade } }
        border.width: settings.platePx
        border.color: lit ? Theme.fg : "#222034"
        antialiasing: false
        Rectangle {
            visible: cap.swatch.a > 0
            x: settings.u(8); y: settings.u(8)
            width: 5 * settings.platePx; height: width
            color: cap.swatch
            antialiasing: false
        }
        // the job the key does; above it, in small, what the touchscreen
        // PRINTS on it when that's a different word (a remapped key)
        readonly property string printed: cap.entry.printed && cap.entry.printed.length > 0 ? cap.entry.printed : (cap.entry.name || "")
        readonly property bool remapped: printed !== (cap.entry.label || "")
        Column {
            anchors.centerIn: parent
            spacing: -2
            Text {
                visible: cap.remapped
                anchors.horizontalCenter: parent.horizontalCenter
                text: Theme.mgsSafe(cap.printed)
                color: cap.lit ? Theme.fg : Theme.dimFg
                font.family: Theme.hudFont
                font.pixelSize: settings.u(16)
                font.letterSpacing: settings.u(1)
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: Theme.mgsSafe(cap.entry.label || "")
                color: cap.lit ? Theme.fg : (cap.entry.action === "none" ? Theme.withAlpha(Theme.dimFg, 0.5) : Theme.accent)
                font.family: Theme.hudFont
                font.pixelSize: settings.u(cap.remapped ? 18 : 20)
                font.letterSpacing: settings.u(1)
            }
        }
    }

    // ── Tab strip: the sections on hexagon plates, UP IN THE TOP STRIP where
    // the crumb was — YouTube's tabs' place and grammar ("give settings
    // the same treatment so it doesn't appear so different"). Main places it;
    // the rows and the readout take the room it left.
    Item {
        id: strip
        x: settings.stripX
        y: Math.round(settings.stripMidY - tabFace.faceMid)
        width: Math.max(0, settings.stripRight - settings.stripX)
        height: 40
        MechButton { id: tabFace; visible: false; family: 7; px: settings.platePx; width: 80; height: 40 }
        // Short of the ~1030 px the full-size seven take (the CRT's glass):
        // compact — labels at the codec face's 16-px grid, slimmer padding.
        readonly property bool compact: width < 1030
        readonly property int labelPx: compact ? 16 : 22
        readonly property int basePad: compact ? 40 : 56
        // Where the strip is roomy (DP-3) the tabs LENGTHEN until the bar ends
        // on the rows' right edge below it — a bar the length of the column it
        // switches, not a stub at the left of a wide page ("could be
        // longer there"). Never shorter than their natural size.
        FontMetrics { id: tabLblFm; font.family: Theme.codecFont; font.pixelSize: strip.labelPx; font.letterSpacing: 2 }
        readonly property real inkSum: {
            void tabLblFm.height
            let t = 0
            for (const l of settings.sectionLabels) t += tabLblFm.tightBoundingRect(l).width
            return t
        }
        readonly property int nTabs: settings.sectionLabels.length
        readonly property real target: settings.colX + settings.colW - settings.rowEdgeIn - x
        readonly property real natural: inkSum + nTabs * basePad + (nTabs - 1) * 4
        readonly property int labelPad: basePad + Math.max(0, Math.floor((target - natural) / nTabs))

        ListView {
            id: tabRow
            orientation: ListView.Horizontal
            spacing: 4
            anchors.left: parent.left
            width: Math.min(contentWidth, parent.width)
            anchors.top: parent.top
            height: 40
            clip: true
            interactive: contentWidth > width + 1
            boundsBehavior: Flickable.StopAtBounds
            model: settings.sections.length
            readonly property bool moreLeft: contentX > 2
            readonly property bool moreRight: contentX < contentWidth - width - 2
            property bool glide: false
            Behavior on contentX {
                enabled: tabRow.glide
                NumberAnimation { duration: 180; easing.type: Easing.OutQuad }
            }
            // bring the current tab fully into view (the CRT cuts the strip)
            function reveal(animated) {
                const it = itemAtIndex(settings.sectionIdx)
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
            function slide(dir) {
                glide = true
                contentX = Math.max(0, Math.min(contentWidth - width, contentX + dir * width * 0.6))
                glide = false
            }
            Connections {
                target: settings
                function onSectionChanged() { Qt.callLater(tabRow.reveal, true) }
            }
            onWidthChanged: Qt.callLater(reveal, false)
            onContentWidthChanged: Qt.callLater(reveal, false)

            delegate: Item {
                id: tabItem
                required property int index
                readonly property bool current: settings.sectionIdx === index
                readonly property bool focused: current && settings.tabFocus
                property bool hover: false
                property real hopY: 0
                FontMetrics { id: tabInk; font: tabLbl.font }
                readonly property rect ink: (tabInk.height, tabInk.tightBoundingRect(tabLbl.text))
                // an EVEN width: the plate floors to whole art px
                width: 2 * Math.ceil((ink.width + strip.labelPad) / 2)
                height: 40
                onCurrentChanged: if (current && settings.visible) { plateBtn.tap(); hop.restart() }
                SequentialAnimation {
                    id: hop
                    NumberAnimation { target: tabItem; property: "hopY"; to: DS.selDip(plateBtn.height); duration: 90; easing.type: Easing.OutQuad }
                    NumberAnimation { target: tabItem; property: "hopY"; to: 0; duration: 260; easing.type: Easing.OutBack }
                }
                MechButton {
                    id: plateBtn
                    family: 7
                    px: settings.platePx
                    anchors.fill: parent
                    pressed: tabMouse.pressed
                    hot: tabItem.current || tabItem.hover
                    opacity: tabItem.current ? 1 : (tabItem.hover ? 0.9 : 0.55)
                    Behavior on opacity { NumberAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                }
                Text {
                    id: tabLbl
                    x: Math.round(tabItem.width / 2 - (tabItem.ink.x + tabItem.ink.width / 2))
                    y: Math.round(plateBtn.faceMid - settings.capMid(tabInk))
                    text: settings.sectionLabels[tabItem.index]
                    color: tabItem.focused ? Theme.fg : tabItem.current ? Theme.accent : Theme.dimFg
                    Behavior on color { ColorAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                    font.family: Theme.codecFont
                    font.pixelSize: strip.labelPx
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
                    onClicked: { settings.openSection(settings.sections[tabItem.index]); settings.tabFocus = false
                                 settings.sfx("select", settings.tabPan()) }
                }
            }
        }
        // ◀ ▶ — more tabs off this side; a click slides the strip
        Item {
            visible: tabRow.moreLeft
            anchors.left: tabRow.left
            anchors.top: tabRow.top
            width: 56; height: 40
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
                anchors.left: parent.left; anchors.leftMargin: 2
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: -3
                text: "◀"
                color: tabMoreL.containsMouse ? Theme.accent : Theme.fg
                font.family: Theme.hudFont; font.pixelSize: 20
            }
            MouseArea {
                id: tabMoreL
                anchors.fill: parent; hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: tabRow.slide(-1)
            }
        }
        Item {
            visible: tabRow.moreRight
            anchors.right: tabRow.right
            anchors.top: tabRow.top
            width: 56; height: 40
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
                anchors.right: parent.right; anchors.rightMargin: 2
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: -3
                text: "▶"
                color: tabMoreR.containsMouse ? Theme.accent : Theme.fg
                font.family: Theme.hudFont; font.pixelSize: 20
            }
            MouseArea {
                id: tabMoreR
                anchors.fill: parent; hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: tabRow.slide(1)
            }
        }
    }

    // ── The rows: scroll when they don't fit (the CRT's 1024 lines), keeping
    // the selected row in view; otherwise they stand still.
    Flickable {
        id: pageFlick
        anchors.top: parent.top
        anchors.topMargin: 0           // the view's top, as YouTube's rows (the tabs went up)
        anchors.left: parent.left
        anchors.bottom: footHints.top
        anchors.bottomMargin: settings.u(10)   // the rows end above the legend
        width: settings.colX + settings.colW + 16
        contentWidth: width
        contentHeight: Math.max(height, page.y + page.height + 16)
        clip: true
        // Never scrolled by hand: the wheel WALKS the rows (above) and the page
        // follows the selection (follow()). Interactive, the Flickable took the
        // wheel first on the CRT, where the page overflows, and scrolled it out
        // from under the selection instead.
        interactive: false
        readonly property bool overflows: page.height + 16 > height
        boundsBehavior: Flickable.StopAtBounds
        Behavior on contentY { NumberAnimation { duration: DS.base; easing.type: Easing.OutQuad } }

        function findSel(item) {
            for (let i = 0; i < item.children.length; ++i) {
                const c = item.children[i]
                if (!c.visible)
                    continue
                if (c.isRow === true && c.sel === true)
                    return c
                const hit = findSel(c)
                if (hit)
                    return hit
            }
            return null
        }
        function follow() {
            if (!overflows) { contentY = 0; return }
            if (settings.tabFocus) { contentY = 0; return }
            const it = findSel(page)
            if (!it)
                return
            // the first row of a group brings its heading into view with it
            let topItem = it
            const kids = it.parent ? it.parent.children : []
            let at = -1
            for (let k = 0; k < kids.length; ++k) if (kids[k] === it) { at = k; break }
            for (let k = at - 1; k >= 0; --k) {
                const c = kids[k]
                if (!c.visible) continue
                if (c.isHeading === true) topItem = c
                break
            }
            const top = topItem.mapToItem(page, 0, 0).y + page.y
            const bot = it.mapToItem(page, 0, 0).y + page.y + it.height
            let y = contentY
            if (top - 24 < y)
                y = top - 24
            else if (bot + 24 > y + height)
                y = bot + 24 - height
            const end = contentHeight - height
            // near the end, go all the way — the key hints live below the last row
            contentY = Math.max(0, y > end - 120 ? end : Math.min(y, end))
        }
        Connections {
            target: settings
            function onIdxChanged() { Qt.callLater(pageFlick.follow) }
            function onTabFocusChanged() { Qt.callLater(pageFlick.follow) }
        }
        onHeightChanged: Qt.callLater(follow)

    Column {
        id: page
        x: settings.colX
        // Every section opens on a heading, and a heading carries ~28u of air
        // above its words (to part it from the group before). At the page's top
        // that air was just a gap under the tabs: the page rises by it, so the
        // first heading's capitals meet the readout panel's top edge — the
        // rows start where YouTube's do.
        y: -settings.u(26)
        width: settings.colW
        spacing: settings.u(14)

        // ── The section pages: one shows; a switch slides it in ────────────
        Item {
            id: pages
            width: parent.width
            height: secPlayback.visible ? secPlayback.height
                  : secSubtitles.visible ? secSubtitles.height
                  : secDisplay.visible ? secDisplay.height
                  : secCast.visible ? secCast.height
                  : secLibrary.visible ? secLibrary.height
                  : secRemote.visible ? secRemote.height : secSystem.height
            property real slideX: 0
            transform: Translate { x: pages.slideX }
            ParallelAnimation {
                id: slideAnim
                NumberAnimation { target: pages; property: "opacity"; from: 0.4; to: 1
                                  duration: DS.slow; easing.type: Easing.OutCubic }
                NumberAnimation { target: pages; property: "slideX"
                                  from: settings.sectionDir * 36; to: 0
                                  duration: DS.slow; easing.type: Easing.Bezier
                                  easing.bezierCurve: DS.enterCurve }
            }

            // ════ PLAYBACK ════════════════════════════════════════════════
            Column {
                id: secPlayback
                visible: settings.section === "playback"
                width: parent.width
                spacing: settings.u(6)
                Component.onCompleted: settings.reindexLater()

                SettingHeading {
                    label: "SOUND OUTPUT"
                    note: settings.devices.length + (settings.devices.length === 1 ? " DEVICE" : " DEVICES")
                }
                Repeater {
                    model: settings.devices
                    onItemAdded: settings.reindexLater()
                    onItemRemoved: settings.reindexLater()
                    delegate: SettingRow {
                        required property var modelData
                        required property int index
                        readonly property bool current: modelData.name === Engine.audioDevice
                        kind: "pick"
                        label: modelData.name === "auto" ? "DEFAULT OUTPUT" : (modelData.description || modelData.name)
                        sub: modelData.name === "auto" ? "follow the system's output" : modelData.name
                        help: modelData.name === "auto"
                              ? "codec plays through whatever the system calls its default output, and follows it when that changes. ⏎ picks it."
                              : "codec sends its sound straight to this device, whatever the system default is. ⏎ picks it."
                        value: current ? "ACTIVE" : ""
                        onActivated: App.setAudioDevice(modelData.name)
                    }
                }
                SettingHeading { label: "AUDIO" }
                SettingRow {
                    label: "AUDIO LANGUAGE"
                    sub: "default track language (a per-film pick still wins)"
                    help: "The audio track codec starts a film on when it has a choice. A track you pick on a particular film is remembered for that film and beats this."
                    value: App.audioLanguageLabel
                    onStep: (dir) => App.cycleAudioLanguage(dir)
                    onActivated: App.cycleAudioLanguage(1)
                }
                SettingRow {
                    kind: "toggle"
                    label: "NIGHT MODE"
                    sub: "dialogue up, booms down"
                    help: "Compresses the dynamic range of the sound: dialogue comes up, explosions and the score come down. For late nights and thin walls. Applies to this screen right away."
                    on: App.nightMode
                    onActivated: App.toggleNightMode()
                }
                SettingHeading { label: "WATCHING" }
                SettingRow {
                    label: "SEEK STEP"
                    sub: "h/l and the arrow keys in the player"
                    help: "How far one press of ←/→ (or h/l) moves in the player. The remote's ◀◀ ▶▶ step by this too."
                    value: App.seekStep + " S"
                    onStep: (dir) => App.cycleSeekStep(dir)
                    onActivated: App.cycleSeekStep(1)
                }
                SettingRow {
                    kind: "toggle"
                    label: "AUTOPLAY NEXT EPISODE"
                    sub: "a countdown between episodes"
                    help: "When an episode ends, the next one is lined up with a short countdown you can cancel. Off, playback stops at the end of each episode."
                    on: App.autoplayNext
                    onActivated: App.toggleAutoplay()
                }
                SettingRow {
                    id: sleepRow
                    label: "SLEEP TIMER"
                    sub: App.sleepMinutes > 0 ? "stops playback and darkens the displays when it lands"
                                              : "off · 30 · 60 min — the remote's SLEEP key, too"
                    help: "Arms a timer that stops playback and darkens the displays when it runs out, after a 3-2-1 you can still cancel. The remote's SLEEP key cycles the same timer."
                    property double now: Date.now()
                    Timer { interval: 1000; repeat: true; running: App.sleepMinutes > 0 && settings.visible
                            onTriggered: sleepRow.now = Date.now() }
                    value: {
                        if (App.sleepMinutes <= 0) return "OFF"
                        const left = Math.max(0, Math.round((App.sleepEndsAt - now) / 1000))
                        const m = Math.floor(left / 60), s = left % 60
                        return App.sleepMinutes + " MIN  ·  " + m + ":" + (s < 10 ? "0" : "") + s + " LEFT"
                    }
                    lit: App.sleepMinutes > 0
                    onStep: (dir) => App.remoteSleepCycle(dir)
                    onActivated: App.remoteSleepCycle(1)
                }
            }

            // ════ SUBTITLES ═══════════════════════════════════════════════
            Column {
                id: secSubtitles
                visible: settings.section === "subtitles"
                onVisibleChanged: if (visible) App.probeSubTiming()
                width: parent.width
                spacing: settings.u(6)
                Component.onCompleted: settings.reindexLater()

                SettingHeading { label: "THIS SCREEN"; note: "APPLIED LIVE" }
                SettingRow {
                    label: "CAPTION SIZE"
                    sub: "subtitles in the local player"
                    help: "The size of subtitles in the local player, relative to the picture. The sample on the right follows it."
                    value: App.subtitleScale <= 0.35 ? "XXXXS"
                         : App.subtitleScale <= 0.45 ? "XXXS"
                         : App.subtitleScale <= 0.57 ? "XXS"
                         : App.subtitleScale <= 0.72 ? "XS"
                         : App.subtitleScale <= 0.9 ? "SMALL"
                         : App.subtitleScale <= 1.1 ? "MEDIUM"
                         : App.subtitleScale <= 1.35 ? "LARGE" : "XL"
                    onStep: (dir) => App.cycleSubtitleSize(dir)
                    onActivated: App.cycleSubtitleSize(1)
                }
                SettingRow {
                    label: "CAPTION FONT"
                    sub: "the subtitle typeface"
                    help: "The face subtitles are drawn in on this screen. The MGS faces are codec's own; SANS, SERIF and MONO are the system's."
                    value: App.localCaptionFontLabel
                    onStep: (dir) => App.cycleLocalCaptionFont(dir)
                    onActivated: App.cycleLocalCaptionFont(1)
                }
                SettingRow {
                    label: "CAPTION COLOUR"
                    sub: "the subtitle ink"
                    help: "The colour subtitles are drawn in on this screen. Yellow and amber read well over bright scenes; white is the classic."
                    value: App.localCaptionColorName
                    valueColor: App.localCaptionColorHex
                    onStep: (dir) => App.cycleLocalCaptionColor(dir)
                    onActivated: App.cycleLocalCaptionColor(1)
                }
                SettingRow {
                    kind: "toggle"
                    label: "CAPTION BACKGROUND"
                    sub: "boxed, or outlined over the picture"
                    help: "BOXED sets subtitles on a dark band, the easiest read over a bright scene. OUTLINED draws them straight on the picture with a dark edge."
                    on: App.localCaptionBg
                    value: App.localCaptionBg ? "BOXED" : "OUTLINED"
                    onActivated: App.toggleLocalCaptionBg()
                }
                SettingRow {
                    kind: "toggle"
                    label: "SUB FILE STYLING"
                    sub: "a styled .ass file: codec's look, or its own"
                    help: "A styled subtitle file (.ass) carries its own fonts and colours. CODEC'S draws every subtitle in the face, colour and size above — one look for the whole library. ITS OWN keeps the file's styling, which sign-heavy anime subs are made for."
                    on: !App.subHonourStyle
                    value: App.subHonourStyle ? "ITS OWN" : "CODEC'S"
                    onActivated: App.toggleSubHonourStyle()
                }
                SettingHeading { label: "TELEVISION"; note: "EVERY CAST, LIVE" }
                SettingRow {
                    label: "CAST CAPTION SIZE"
                    sub: "percent of the receiver's own size"
                    help: "How big captions are on a television you cast to, as a percentage of the receiver's accessibility size — which reads BIG on a film, so the default is under 100."
                    value: App.castCaptionScale + "%"
                    onStep: (dir) => App.cycleCastCaptionScale(dir)
                    onActivated: App.cycleCastCaptionScale(1)
                }
                SettingRow {
                    label: "CAST CAPTION FONT"
                    sub: "the typeface on the TV"
                    help: "The face captions are drawn in on a cast television — the same face whether the film rides the Dolby Vision lane, the HDR10 lane or the adaptive stream. Applied live to a running cast."
                    value: App.castCaptionFontLabel
                    onStep: (dir) => App.cycleCastCaptionFont(dir)
                    onActivated: App.cycleCastCaptionFont(1)
                }
                SettingRow {
                    label: "CAST CAPTION COLOUR"
                    sub: "the ink on the TV"
                    help: "The colour captions are drawn in on a cast television. Applied live to a running cast."
                    value: App.castCaptionColorName
                    valueColor: App.castCaptionColorHex
                    onStep: (dir) => App.cycleCastCaptionColor(dir)
                    onActivated: App.cycleCastCaptionColor(1)
                }
                SettingRow {
                    kind: "toggle"
                    label: "CAST CAPTION BACKGROUND"
                    sub: "boxed, or outlined over the picture"
                    help: "BOXED puts the TV's captions on a dark band, the easiest read over busy scenes. OUTLINED draws them straight on the picture with a dark edge."
                    on: App.castCaptionBg
                    value: App.castCaptionBg ? "BOXED" : "OUTLINED"
                    onActivated: App.toggleCastCaptionBg()
                }
                SettingHeading { label: "FETCHING & TIMING" }
                SettingRow {
                    kind: "status"
                    label: "SUBTITLE SOURCES"
                    sub: "fetched from SubSource; OpenSubtitles joins with a key (settings.osApiKey)"
                    readonly property bool keyed: ("" + App.getSetting("osApiKey", "")).length > 0
                    value: keyed ? "SUBSOURCE + OPENSUBTITLES" : "SUBSOURCE ONLY"
                    valueColor: Theme.dimFg
                }
                SettingRow {
                    kind: "status"
                    label: "SUBTITLE TIMING"
                    sub: "a fetched subtitle is measured against the film's audio"
                    help: "Every subtitle the hub fetches is lined up against the film's own audio (ffsubsync): a late file, a PAL frame rate, a different leader all come out right, and the raw file is kept. X and C nudge a file by hand; the nudge is remembered per film. Shift+S twice fetches the next-best release."
                    value: App.subTimingStatus.length ? App.subTimingStatus : "…"
                    valueColor: Theme.dimFg
                }
            }

            // ════ DISPLAY ═════════════════════════════════════════════════
            Column {
                id: secDisplay
                visible: settings.section === "display"
                width: parent.width
                spacing: settings.u(6)
                Component.onCompleted: settings.reindexLater()

                SettingHeading { label: "SCREEN" }
                SettingRow {
                    kind: "action"
                    label: "DISPLAY"
                    sub: "which screen codec is on — ⏎ opens the chooser"
                    help: "The display codec lives on, and the mode that comes with it (HD, or the CRT with its safe area). ⏎ opens the display chooser codec starts with."
                    value: (App.display.length > 0 ? App.display.toUpperCase() + "  ·  " : "") + App.mode.toUpperCase()
                    onActivated: App.backToChooser()
                }
                SettingRow {
                    kind: "toggle"
                    label: "HDR OUTPUT"
                    sub: "PQ passthrough on HDR panels (HD mode)"
                    help: "On an HDR-capable panel, HDR10 and Dolby Vision films put the display into HDR for the film and hand it back afterwards. ENGAGED means it is in HDR right now."
                    on: App.hdrDirect
                    value: App.hdrEngaged ? "ENGAGED" : (App.hdrDirect ? "ON" : "OFF")
                    onActivated: App.toggleHdrDirect()
                }
                SettingRow {
                    label: "HDR PEAK BRIGHTNESS"
                    sub: "auto reads the panel's EDID"
                    help: "The peak brightness the HDR tone curve is aimed at. AUTO reads the panel's own figure from its EDID; set a number if the panel lies or you want it dimmer."
                    value: App.hdrPeakLabel
                    lit: App.hdrDirect
                    onStep: (dir) => App.cycleHdrPeak(dir)
                    onActivated: App.cycleHdrPeak(1)
                }
                SettingRow {
                    label: "FRAME RATE"
                    sub: App.frameRateMode === "display"
                         ? "menus move at the screen's own refresh rate"
                         : "menus move at 60 frames a second, whatever the screen"
                    help: "How fast codec's menus and animations draw. MATCH DISPLAY follows whatever screen codec is on: 170 Hz, a 60 Hz CRT, a laptop panel. STANDARD 60 holds 60 everywhere and uses a little less power. Films always play at their own frame rate. Takes effect when codec restarts."
                    value: (App.frameRateMode === "display" ? "MATCH DISPLAY" : "STANDARD 60")
                           + (App.frameRatePending ? "  ·  ON RESTART" : "")
                    lit: App.frameRateMode === "display"
                    instant: true   // two states: ⏎ flips it
                    onStep: (dir) => App.toggleFrameRate()
                    onActivated: App.toggleFrameRate()
                }
                SettingHeading { label: "LOOK" }
                SettingRow {
                    label: "MINIPLAYER CORNER"
                    sub: "where the dock rests while you browse (ctrl + h/j/k/l moves it too)"
                    help: "Leave the player and the film keeps going in a dock in this corner. Drag it anywhere, or press ctrl with h/j/k/l; the corner is remembered."
                    readonly property int corner: App.pipLeft ? (App.pipTop ? 2 : 1) : (App.pipTop ? 3 : 0)
                    value: ["BOTTOM RIGHT", "BOTTOM LEFT", "TOP LEFT", "TOP RIGHT"][corner]
                    function setCorner(c) {
                        App.pipLeft = (c === 1 || c === 2)
                        App.pipTop = (c === 2 || c === 3)
                    }
                    onStep: (dir) => setCorner(((corner + dir) % 4 + 4) % 4)
                    onActivated: setCorner((corner + 1) % 4)
                }
                SettingRow {
                    kind: "toggle"
                    label: "THEME"
                    sub: App.mechPalette ? "fixed mech palette — steady, ignores the wallpaper"
                                         : "colours pulled from the wallpaper (pywal)"
                    help: "MECH keeps the fixed steel palette the plates are drawn for. PYWAL takes the accent from the desktop wallpaper, so the ink follows your walls."
                    on: App.mechPalette
                    value: App.mechPalette ? "MECH" : "PYWAL"
                    onActivated: App.toggleMechPalette()
                }
                SettingRow {
                    label: "GLASS EFFECT"
                    sub: "how solid the menu / queue / OSD / picker plates are"
                    help: "The translucency of the menu, queue, OSD and picker plates. 100% is solid steel; lower lets the picture show through. The home wheel is tuned separately."
                    value: Math.round(App.glassLevel * 100) + "% SOLID"
                    onStep: (dir) => App.cycleGlassLevel(-dir)   // → more solid, ← more glass
                    onActivated: App.cycleGlassLevel(1)
                }
                SettingHeading { label: "HOME SCREEN" }
                SettingRow {
                    label: "SPOTLIGHT INTERVAL"
                    sub: "how long each home backdrop holds"
                    help: "The home screen cycles through your library's backdrops. This is how long each one holds; HOLD stops the cycling."
                    value: App.spotlightSeconds > 0 ? App.spotlightSeconds + " S" : "HOLD"
                    lit: App.spotlightSeconds > 0
                    onStep: (dir) => App.cycleSpotlightSeconds(dir)
                    onActivated: App.cycleSpotlightSeconds(1)
                }
                SettingRow {
                    label: "SYNOPSIS REVEAL"
                    sub: App.redactionStyle === "redact" ? "black censor bars decode in place (codec signature)"
                       : App.redactionStyle === "light" ? "light bars decode in place"
                       : App.redactionStyle === "type" ? "plain typewriter reveal, no bars"
                       : "shown instantly, no animation"
                    help: "How a synopsis appears when you land on a title: decoded out from under censor bars (codec's signature), typed out, or just shown."
                    value: App.redactionStyle === "redact" ? "REDACTED"
                         : App.redactionStyle === "light" ? "LIGHT"
                         : App.redactionStyle === "type" ? "TYPE" : "OFF"
                    lit: App.redactionStyle !== "off"
                    onStep: (dir) => App.cycleRedactionStyle(dir)
                    onActivated: App.cycleRedactionStyle(1)
                }
                SettingRow {
                    label: "ATTRACT MODE"
                    sub: "backdrop slideshow when idle"
                    help: "Left alone this long, codec dims into a slideshow of your library's art. Any key wakes it."
                    value: App.attractMinutes > 0 ? "AFTER " + App.attractMinutes + " MIN" : "OFF"
                    lit: App.attractMinutes > 0
                    onStep: (dir) => App.cycleAttractDelay(dir)
                    onActivated: App.cycleAttractDelay(1)
                }
            }

            // ════ CAST ════════════════════════════════════════════════════
            Column {
                id: secCast
                visible: settings.section === "cast"
                width: parent.width
                spacing: settings.u(6)
                Component.onCompleted: settings.reindexLater()

                function tvName(id) {
                    for (let i = 0; i < Cast.deviceCount; i++) {
                        const d = Cast.deviceAt(i)
                        if (d.id === id) return ("" + d.name).toUpperCase()
                    }
                    return ""
                }
                function stepDefaultTv(dir) {
                    const n = Cast.deviceCount
                    if (n === 0) { App.notify("NO CAST DEVICES FOUND YET"); return }
                    let at = n   // n = "first found"
                    for (let i = 0; i < n; i++)
                        if (Cast.deviceAt(i).id === settings.defaultTv) at = i
                    at = ((at + dir) % (n + 1) + (n + 1)) % (n + 1)
                    settings.defaultTv = at === n ? "" : Cast.deviceAt(at).id
                    App.putSetting("lastCastTarget", settings.defaultTv)
                }

                SettingHeading { label: "TELEVISION" }
                SettingRow {
                    label: "DEFAULT TV"
                    sub: "what the remote's CAST key flings to · " + Cast.deviceCount + " device(s) on the network"
                    help: "The television the remote's CAST key sends a title to. FIRST FOUND lets codec pick: a Sony / Bravia on the network, else the only device. Casting to a TV from the picker makes it the default too."
                    value: {
                        void Cast.deviceCount
                        if (settings.defaultTv === "") return "FIRST FOUND"
                        const n = secCast.tvName(settings.defaultTv)
                        return n.length > 0 ? n : "NOT ON THIS NETWORK"
                    }
                    lit: settings.defaultTv === "" || secCast.tvName(settings.defaultTv).length > 0
                    onStep: (dir) => secCast.stepDefaultTv(dir)
                    onActivated: secCast.stepDefaultTv(1)
                }
                SettingRow {
                    kind: "action"
                    label: "OUTPUT"
                    sub: "where playback goes right now — ⏎ opens the picker (c)"
                    help: "Where a title plays when you press play: this machine, or a cast device. Switching mid-play hands the film over with its position."
                    value: Cast.targetId === "" ? "THIS MACHINE" : Cast.targetName.toUpperCase()
                    onActivated: App.outputOpen = true
                }
                SettingRow {
                    id: scanRow
                    kind: "action"
                    label: "SEARCH FOR DEVICES"
                    sub: "look for cast devices on the LAN again"
                    help: "Searches the network for cast devices again. A device mDNS can't see can be added by IP address in the output picker's ADD DEVICE row."
                    value: "SCAN"
                    onActivated: { busy = true; Cast.rescan(); scanGuard.restart() }
                    Timer { id: scanGuard; interval: 15000; onTriggered: scanRow.busy = false }
                    Connections {
                        target: Cast
                        function onScanFinished(found) {
                            scanRow.busy = false
                            App.notify(found > 0 ? "FOUND " + found + " NEW DEVICE(S)" : "NOTHING NEW")
                        }
                    }
                }
                SettingHeading { label: "WATCH PARTY" }
                SettingRow {
                    kind: "text"
                    label: "PARTY NAME"
                    sub: "who this screen is in a watch party"
                    help: "The name this screen shows up as in a watch party's room and invite text. Empty uses the hub's host name, or this machine's name."
                    value: App.partyName.toUpperCase()
                    editText: App.getSetting("partyName", "")
                    placeholder: "a name  ·  ⏎ keep  ·  esc cancel  ·  empty = default"
                    onActivated: beginEdit()
                    onCommitted: (text) => App.setPartyName(text)
                }
            }

            // ════ LIBRARY ═════════════════════════════════════════════════
            Column {
                id: secLibrary
                visible: settings.section === "library"
                width: parent.width
                spacing: settings.u(6)
                Component.onCompleted: settings.reindexLater()

                readonly property bool checking: App.hubStatus.indexOf("checking") >= 0
                readonly property bool online: App.hubStatus.indexOf("ONLINE") >= 0
                readonly property bool offline: App.hubStatus.indexOf("OFFLINE") >= 0
                readonly property bool satellite: App.deviceRole === "SATELLITE"

                SettingHeading { label: "HUB" }
                SettingRow {
                    kind: "status"
                    label: "HUB"
                    sub: App.hubStatus
                    // a satellite reads the LINK (which road answers); the hub
                    // itself reads whether codec-serve answers
                    value: secLibrary.satellite && App.hubLink === "away" ? "AWAY"
                         : secLibrary.satellite && App.hubLink === "tailnet" ? "TAILNET"
                         : secLibrary.satellite && App.hubLink === "fastroad" ? "FAST ROAD"
                         : secLibrary.satellite && App.hubLink === "funnel" ? "FUNNEL"
                         : secLibrary.satellite && App.hubLink === "lan" ? "LAN"
                         : !secLibrary.satellite && App.sharing === "off" ? "NOT SHARING"
                         : secLibrary.checking ? "CHECKING"
                         : secLibrary.online ? "ONLINE"
                         : secLibrary.offline ? "OFFLINE" : "UNKNOWN"
                    valueColor: !secLibrary.satellite && App.sharing === "off" ? Theme.dimFg
                              : (secLibrary.offline || App.hubLink === "away") ? Theme.warning : Theme.accent
                    lit: secLibrary.online || secLibrary.offline || secLibrary.checking || App.hubLink !== ""
                    pulse: secLibrary.checking || App.hubLink === "away"
                }
                SettingRow {
                    kind: "status"
                    shown: secLibrary.satellite
                    label: "ART CACHE"
                    sub: "posters, backdrops and logos kept on this machine — what the library shows from, hub or no hub"
                    readonly property var info: (settings.cascadeRev, App.artCacheInfo())
                    value: info.files + " FILES  ·  " + Math.round(info.bytes / 1048576) + " MB"
                    valueColor: Theme.dimFg
                    dot: false
                }
                SettingRow {
                    kind: "status"
                    // the roads to a hub — a satellite's, or a hub that shares
                    shown: secLibrary.satellite || App.sharing === "on"
                    label: "LINKS"
                    // the hub SERVES its roads; a satellite REACHES the hub over them
                    sub: {
                        const l = settings.links
                        const road = l.direct && l.direct.length > 0 ? l.direct
                                   : (l.funnel && l.funnel.length > 0 ? l.funnel : "not set")
                        if (!secLibrary.satellite)
                            return "LAN :8200   ·   FUNNEL :8299   ·   FAST ROAD " + road
                        const lan = l.lan && l.lan.length > 0 ? l.lan : "not set"
                        const tn = l.tailnet && l.tailnet.length > 0 ? l.tailnet : "not set"
                        return "LAN " + lan + "   ·   TAILNET " + tn + "   ·   FAST ROAD " + road
                    }
                    help: secLibrary.satellite
                          ? "The roads to the hub. LAN when at home; the tailnet (Tailscale) from anywhere the hub can be reached privately; the fast road is the public door party guests use. Which one answers is probed every 30 s — the strip's HUB chip shows it."
                          : "The doors this hub serves: :8200 on the LAN (private, every hub call), :8299 the read-only Funnel surface, and the fast road the party invite hops onto."
                    value: {
                        const l = settings.links
                        let n = secLibrary.satellite ? (l.lan && l.lan.length > 0 ? 1 : 0) : 2
                        if (secLibrary.satellite && l.tailnet && l.tailnet.length > 0) n++
                        if ((l.direct && l.direct.length > 0) || (l.funnel && l.funnel.length > 0)) n++
                        const roads = n + " ROAD" + (n === 1 ? "" : "S")
                        if (!secLibrary.satellite) return roads
                        // the key to the public door: how long this machine's browse token lasts
                        return roads + "  ·  " + (l.token ? "KEY " + l.tokenDays + " D" : "NO KEY")
                    }
                    valueColor: Theme.dimFg
                    dot: false
                }
                SettingRow {
                    kind: "action"
                    label: "SYNC WITH HUB NOW"
                    sub: secLibrary.satellite ? "pull the library + art from the hub" : "re-check hub health"
                    help: secLibrary.satellite
                          ? "Fetches the hub's library manifest and any art this machine is missing, then checks the hub answers. The nightly refresh does this on its own."
                          : "Checks that codec-serve answers on this machine and refreshes the hub line above."
                    value: "SYNC"
                    busy: secLibrary.checking
                    onActivated: { App.checkHub(); settings.links = App.hubLinks() }
                }
                // Who may use this hub (scripts/codec_pairing.py): every device
                // on the network, or only those you've let join.
                SettingHeading {
                    label: "SHARING"
                    shown: App.deviceRole === "HUB"
                    note: App.sharing === "on" && !App.lanOpen ? "D REMOVES A DEVICE" : ""
                }
                SettingRow {
                    kind: "toggle"
                    shown: App.deviceRole === "HUB"
                    label: "SHARE THIS LIBRARY"
                    on: App.sharing === "on"
                    lit: App.sharing !== "unsupported"
                    sub: App.sharing === "on" ? "the TV, laptops and phones can use this hub, even with codec closed"
                       : App.sharing === "busy" ? "starting..."
                       : App.sharing === "unsupported" ? "needs systemd to run in the background"
                       : "only this machine plays this library"
                    help: "On, this machine runs codec's server in the background: it casts to the TV, a laptop can browse and play this library, a phone can drive it, and parties can be hosted — even while codec itself is closed. It announces itself on this network so another codec can find it. Off, the server stops and only this machine plays this library."
                    onActivated: App.toggleSharing()
                }
                SettingRow {
                    kind: "text"
                    shown: App.deviceRole === "HUB" && App.sharing === "on"
                    label: "HUB NAME"
                    property string hubName: "" + App.getSetting("hubName", "")
                    sub: "what a laptop or phone sees when it looks for this hub"
                    help: "The name this hub goes by on the network: in the list a new laptop sees under USE A CODEC HUB, in \"NOW PRESS ALLOW ON …\", and on a browser's join page. Empty, it's this machine's own name. A new name is announced within a few seconds."
                    value: hubName.length > 0 ? hubName.toUpperCase() : App.machineName().toUpperCase()
                    valueColor: hubName.length > 0 ? Theme.accent : Theme.dimFg
                    editText: hubName
                    placeholder: "a name  ·  empty = " + App.machineName() + "  ·  esc cancel"
                    onActivated: beginEdit()
                    onCommitted: (text) => { hubName = text.trim().slice(0, 40); App.putSetting("hubName", hubName) }
                }
                SettingRow {
                    kind: "toggle"
                    shown: App.deviceRole === "HUB" && App.sharing === "on"
                    label: "TRUSTED NETWORK"
                    sub: App.lanOpen ? "every device on this network can use this hub"
                                     : "only devices you've let join"
                    help: "On, anything on this network can browse, play and cast from this hub without joining — how codec always worked, and right for a home network you trust. Off, a device must ask to join first and you allow it here, on this screen; a TV is let in while something is cast to it, and party guests use their invite. Paired devices keep working either way."
                    on: App.lanOpen
                    onActivated: App.toggleLanOpen()
                }
                Repeater {
                    model: App.deviceRole === "HUB" && App.sharing === "on" ? App.pairedDevices : []
                    onItemAdded: settings.reindexLater()
                    onItemRemoved: settings.reindexLater()
                    delegate: SettingRow {
                        required property var modelData
                        kind: "status"
                        selectable: true
                        dot: false
                        deviceId: modelData.id
                        label: (modelData.name || modelData.id).toUpperCase()
                        sub: (modelData.kind || "device") + "  ·  joined "
                             + new Date(modelData.added * 1000).toLocaleDateString(Qt.locale(), "d MMM yyyy")
                        help: "A device you let join. It has a key of its own; d removes it and the key stops working at once (it can ask to join again)."
                        value: "PAIRED"
                    }
                }
                SettingRow {
                    kind: "status"
                    shown: App.deviceRole === "HUB" && App.sharing === "on" && App.pairedDevices.length === 0
                    dot: false
                    label: "NO DEVICES JOINED"
                    sub: "a laptop asks from its own codec — the request shows up here, on this screen"
                    value: ""
                }
                SettingHeading { label: "UPDATES" }
                SettingRow {
                    label: "AUTO-UPDATE"
                    sub: App.autoUpdate === "live" ? "watches folders — new files appear instantly"
                       : App.autoUpdate === "launch" ? "scans + fetches art on every launch"
                       : "manual only — UPDATE LIBRARY below, or F5"
                    help: "How codec notices new files. LIVE watches the media folders and adds a title the moment it lands. ON LAUNCH scans when codec starts. OFF leaves it to UPDATE LIBRARY (or F5)."
                    value: App.autoUpdate === "live" ? "LIVE" : App.autoUpdate === "launch" ? "ON LAUNCH" : "OFF"
                    lit: App.autoUpdate !== "off"
                    onStep: (dir) => App.cycleAutoUpdate(dir)
                    onActivated: App.cycleAutoUpdate(1)
                }
                SettingRow {
                    kind: "action"
                    label: "UPDATE LIBRARY"
                    sub: App.libraryUpdating
                         ? (App.libraryNewCount > 0 ? "enriching " + App.libraryNewCount + " new title(s)…" : "updating…")
                         : "scan disk + fetch any missing art now"
                    help: "Scans the media folders, adds what's new, drops what's gone, and fetches posters, logos and synopses for anything missing them. Retries titles a slow scrape left out."
                    busy: App.libraryUpdating
                    onActivated: App.updateLibrary()
                }
                SettingRow {
                    kind: "action"
                    label: "RESCAN LIBRARY"
                    sub: MediaLibrary.scanning ? "scanning…" : "re-read media folders + hub (no art fetch)"
                    help: "Re-reads the media folders and the hub's manifest without fetching any art — the quick one."
                    value: (MediaLibrary.totalCount, MediaLibrary.countOf("movie") + " FILMS  ·  "
                            + MediaLibrary.countOf("show") + " SHOWS")
                    busy: MediaLibrary.scanning
                    onActivated: {
                        App.pullLibrary()
                        MediaLibrary.rescan()
                        App.notify("RESCANNING LIBRARY…")
                    }
                }
                SettingRow {
                    kind: "action"
                    label: "AUDIT LIBRARY"
                    sub: App.libraryAuditResult !== "" ? App.libraryAuditResult
                                                       : "check every file IS what codec says it is (read-only)"
                    help: "Probes every file and compares what's really inside (resolution, HDR, Dolby Vision, audio) with what the library claims. Read-only; the result reads on the row."
                    busy: App.libraryAuditing
                    onActivated: App.auditLibrary()
                }
                // Art and details the way Kodi's scrapers get them: codec carries
                // its own keys (scripts/codec_keys.py), so there's nothing to sign
                // up for — and, as in Kodi, a person can bring their own.
                // (a satellite's posters and details come from its hub)
                SettingHeading { label: "METADATA"; shown: !secLibrary.satellite }
                SettingRow {
                    id: tmdbRow
                    shown: !secLibrary.satellite
                    kind: "text"
                    label: "TMDB"
                    property var carried: App.artKeys()
                    property string own: "" + App.getSetting("tmdbApiKey", "")
                    sub: "posters, backdrops, plots, cast and title logos"
                    help: "The Movie Database is where codec gets every film's and show's poster, backdrop, plot, cast and title logo. codec carries its own key, so there's nothing to sign up for. To use your own TMDB key instead, ⏎ and paste it; clear the field to go back to codec's. This product uses the TMDB API but is not endorsed or certified by TMDB."
                    value: own.length > 0 ? "YOUR KEY" : (carried.codecTmdb ? "CODEC'S KEY" : "NO KEY")
                    valueColor: own.length > 0 || carried.codecTmdb ? Theme.accent : Theme.warning
                    editText: own
                    placeholder: "paste your own TMDB key  ·  empty = codec's  ·  esc cancel"
                    onActivated: beginEdit()
                    onCommitted: (text) => { own = text.trim(); App.putSetting("tmdbApiKey", own) }
                }
                SettingRow {
                    id: fanartRow
                    shown: !secLibrary.satellite
                    kind: "toggle"
                    label: "FANART.TV ARTWORK"
                    property bool artOn: App.getSetting("fanartArt", true) !== false
                    sub: artOn ? "title logos for films, from fanart.tv" : "off — title logos from TMDB only"
                    help: "fanart.tv is where most films' title logos come from (the clearlogo on the home screen, the info page and the player). Off, codec asks TMDB alone, which has fewer of them. Shows always come from TMDB."
                    on: artOn
                    onActivated: { artOn = !artOn; App.putSetting("fanartArt", artOn) }
                }
                SettingRow {
                    kind: "text"
                    shown: fanartRow.artOn && !secLibrary.satellite
                    label: "FANART.TV PERSONAL KEY"
                    property string personal: "" + App.getSetting("fanartPersonalKey", "")
                    sub: "optional — new artwork in about 2 days instead of 7"
                    help: "Optional, as in Kodi. fanart.tv hands new artwork to apps a week after it's uploaded; with your own personal key (free, from your fanart.tv profile) it reaches you in about 48 hours. ⏎ and paste it; clear the field to remove it."
                    value: personal.length > 0 ? "SET" : "OPTIONAL"
                    valueColor: personal.length > 0 ? Theme.accent : Theme.dimFg
                    editText: personal
                    placeholder: "paste your fanart.tv personal key  ·  esc cancel"
                    onActivated: beginEdit()
                    onCommitted: (text) => { personal = text.trim(); App.putSetting("fanartPersonalKey", personal) }
                }
                SettingHeading {
                    label: "MEDIA PATHS"
                    note: settings.roots.length === 0 ? "NONE YET — A ADDS ONE"
                                                      : "⏎ MOVIES OR TV  ·  D REMOVES  ·  A ADDS"
                }
                Repeater {
                    model: settings.roots
                    onItemAdded: settings.reindexLater()
                    onItemRemoved: settings.reindexLater()
                    delegate: SettingRow {
                        required property var modelData
                        required property int index
                        rootIndex: index
                        label: App.prettyPath(modelData.path)
                        sub: (modelData.kind === "tv" ? "episodes, by show" : "one film per folder")
                        help: "A folder codec scans. MOVIES expects one film per folder; TV expects show folders with season folders of episodes. ⏎ flips it; d removes this path (the files stay)."
                        value: (modelData.kind || "movies").toUpperCase()
                        instant: true   // MOVIES / TV: ⏎ (or t) flips it, never an arrow
                        onStep: (dir) => App.toggleMediaRootKind(index)
                        onActivated: App.toggleMediaRootKind(index)
                    }
                }
                SettingRow {
                    id: addRootRow
                    kind: "action"
                    label: "ADD MEDIA PATH"
                    sub: "browse to a folder of films or shows"
                    help: "Opens codec's folder browser: walk to the folder, USE THIS FOLDER, then say what it contains — MOVIES or TV SHOWS (codec suggests one from what's inside)."
                    value: "BROWSE"
                    onActivated: pathBrowser.open("")
                }
            }

            // ════ YOUTUBE ═════════════════════════════════════════════════
            // How codec reaches YouTube: through a browser's own login (the
            // way yt-dlp does — YouTube's feeds, Watch Later, history), or on
            // codec's own lists with no account at all. codec_ytaccount.py
            // finds the browsers; codec_ytlocal.py keeps the lists.
            Column {
                id: secYoutube
                visible: settings.section === "youtube"
                width: parent.width
                spacing: settings.u(6)
                Component.onCompleted: settings.reindexLater()
                readonly property var acct: YouTube.account
                readonly property bool local: acct.mode === "local"
                readonly property string st: acct.state || ""
                readonly property var signedIn: YouTube.profiles.filter(p => p.signedIn && p.name)
                function folder(spec) { const i = (spec || "").indexOf(":"); return i < 0 ? "" : spec.slice(i + 1) }

                SettingHeading { label: "ACCOUNT" }
                SettingRow {
                    kind: "status"
                    label: secYoutube.local ? "CODEC'S OWN LISTS"
                         : (secYoutube.acct.name || (secYoutube.st === "nobrowser" ? "NO ACCOUNT" : "YOUTUBE ACCOUNT"))
                    sub: {
                        const a = secYoutube.acct, b = a.browser || "the browser"
                        switch (secYoutube.st) {
                        case "local": {
                            const l = a.local || {}
                            return (l.following || 0) + " channels · " + (l.playlists || 0) + " playlists · "
                                 + (l.watchlater || 0) + " saved for later"
                        }
                        case "connected": return "through " + b + (a.handle ? " · " + a.handle : "")
                        case "expired": return b + "'s YouTube sign-in has run out — open youtube.com in " + b
                        case "signedout": return b + " isn't signed into YouTube — sign in there, or pick another below"
                        case "nobrowser": return "no browser here is signed into YouTube"
                        case "offline": return "couldn't reach YouTube to ask — " + (a.name ? "last seen as " + a.name : "try again")
                        case "noengine": return a.error || "yt-dlp is missing"
                        }
                        return "asking YouTube…"
                    }
                    help: "Who YouTube is in codec. Through a browser's login codec shows YouTube's own feeds — For You, your subscriptions, Watch Later, history and playlists — and what you watch counts on your account, as it does on youtube.com. With codec's own lists there's no account at all: codec keeps the channels you follow, Watch Later, playlists and history itself, and builds the feeds from YouTube's public pages."
                    value: ({local: "NO ACCOUNT", connected: "CONNECTED", expired: "SIGN IN AGAIN",
                             signedout: "SIGNED OUT", nobrowser: "NONE", offline: "OFFLINE",
                             noengine: "NO ENGINE"})[secYoutube.st] || "…"
                    valueColor: secYoutube.st === "connected" || secYoutube.st === "local" ? Theme.accent : Theme.warning
                    pulse: secYoutube.st === ""
                }

                SettingHeading {
                    label: "SIGN IN THROUGH A BROWSER"
                    note: YouTube.findingProfiles ? "LOOKING…" : (YouTube.profiles.length + " FOUND")
                }
                Repeater {
                    model: YouTube.profiles
                    onItemAdded: settings.reindexLater()
                    onItemRemoved: settings.reindexLater()
                    delegate: SettingRow {
                        required property var modelData
                        readonly property bool current: !secYoutube.local
                            && secYoutube.folder(modelData.spec) === secYoutube.folder(secYoutube.acct.spec)
                        kind: "action"
                        label: modelData.label + " · " + String(modelData.profileName || "").toUpperCase()
                        sub: modelData.name ? "signed in as " + modelData.name
                           : modelData.locked ? "signed in, but its keyring wouldn't open"
                           : modelData.expired ? "its YouTube sign-in has run out"
                           : modelData.offline ? "signed in (couldn't reach YouTube to ask who)"
                           : "not signed into YouTube"
                        selectable: modelData.signedIn && !modelData.locked
                        value: current ? "CONNECTED" : (selectable ? "CONNECT" : "—")
                        help: "codec borrows this browser's YouTube login — the same way yt-dlp does, so nothing new to sign up for or type in. It reads only YouTube's and Google's cookies, and only on this machine. To use a different account, sign into YouTube in that browser (or another profile), then LOOK AGAIN."
                        onActivated: if (!current) YouTube.connectProfile(modelData.spec)
                    }
                }
                SettingRow {
                    kind: "status"
                    shown: YouTube.profiles.length === 0 && !YouTube.findingProfiles
                    label: "NO BROWSER FOUND"
                    sub: "codec looks in Firefox, Zen, LibreWolf, Floorp, Chrome, Chromium, Brave, Vivaldi and Edge"
                    value: "—"
                    dot: false
                }
                SettingRow {
                    kind: "action"
                    label: "CODEC'S OWN LISTS"
                    sub: "no account — codec keeps your subscriptions, Watch Later, playlists and history"
                    help: "YouTube with no account: nothing signs in, so nothing can be flagged. SUBSCRIBE on any video's or channel's menu (hold ⏎) follows a channel; Watch Later, playlists and history are kept by codec on this machine. FOR YOU is built from YouTube's suggestions beside what you've watched, and what's new from the channels you follow."
                    value: secYoutube.local ? "IN USE" : "USE"
                    onActivated: if (!secYoutube.local) YouTube.useLocal()
                }
                SettingRow {
                    kind: "action"
                    label: "LOOK AGAIN"
                    sub: "after signing into YouTube in a browser"
                    help: "Searches this machine's browsers again, and asks YouTube again who the connected one is."
                    value: "SEARCH"
                    busy: YouTube.findingProfiles
                    onActivated: { YouTube.findProfiles(); YouTube.refreshAccount() }
                }

                SettingHeading { label: "CODEC'S OWN LISTS"; shown: secYoutube.local }
                SettingRow {
                    kind: "action"
                    shown: secYoutube.local && secYoutube.signedIn.length > 0
                    readonly property var from: secYoutube.signedIn.length > 0 ? secYoutube.signedIn[0] : ({})
                    label: "IMPORT FROM " + String(from.name || "").toUpperCase()
                    sub: YouTube.importStatus.length > 0 ? YouTube.importStatus.toLowerCase()
                         : "its subscriptions, playlists and Watch Later, copied into codec"
                    help: "Copies this account's subscriptions, playlists and Watch Later into codec's own lists. The account itself is only read — nothing on YouTube changes. Run it again any time: what codec already has is kept, what's new is added."
                    value: "IMPORT"
                    busy: YouTube.importStatus.length > 0
                    onActivated: if (!busy) YouTube.importAccount(from.spec)
                }

                SettingRow {
                    kind: "action"
                    shown: secYoutube.local
                    label: "IMPORT A GOOGLE TAKEOUT"
                    sub: YouTube.importStatus.length > 0 && YouTube.takeout.length > 0 ? YouTube.importStatus.toLowerCase()
                         : YouTube.takeout.length > 0 ? YouTube.takeout
                         : "none in Downloads — takeout.google.com, YouTube only"
                    help: "No browser signed in? Google Takeout (takeout.google.com) hands you your YouTube subscriptions and playlists as a download. Choose only \"YouTube and YouTube Music\", let it land in Downloads, then LOOK AGAIN and IMPORT: codec reads the newest takeout-….zip (or an unpacked Takeout folder) and copies them in, Watch later included."
                    selectable: YouTube.takeout.length > 0
                    value: YouTube.takeout.length > 0 ? "IMPORT" : "—"
                    busy: YouTube.importStatus.length > 0
                    onActivated: if (!busy) YouTube.importTakeout()
                }

                SettingHeading { label: "ENGINE" }
                SettingRow {
                    kind: "status"
                    readonly property var eng: secYoutube.acct.engine || ({})
                    label: "YT-DLP"
                    sub: secYoutube.st === "noengine" ? (secYoutube.acct.error || "not installed")
                         : eng.js ? "with " + eng.js + " for YouTube's checks"
                         : "needs a JavaScript runtime (deno) for YouTube's checks"
                    help: "codec plays and lists YouTube through yt-dlp. Since late 2025 yt-dlp needs a JavaScript runtime (deno, node or bun) to pass YouTube's checks — without one, many videos won't play."
                    value: secYoutube.st === "noengine" ? "MISSING" : (eng.ytdlp || "…")
                    valueColor: secYoutube.st !== "noengine" && eng.js ? Theme.accent : Theme.warning
                }
            }

            // ════ REMOTE ══════════════════════════════════════════════════
            Column {
                id: secRemote
                visible: settings.section === "remote"
                width: parent.width
                spacing: settings.u(6)
                Component.onCompleted: settings.reindexLater()

                SettingHeading { label: "TOUCHSCREEN KEYS"; note: "←/→ CHANGES A KEY'S JOB" }
                Repeater {
                    model: 10
                    onItemAdded: settings.reindexLater()
                    delegate: RemoteKeyRow { required property int index; slotNo: index }
                }
                SettingHeading { label: "COLOUR KEYS" }
                Repeater {
                    model: 4
                    onItemAdded: settings.reindexLater()
                    delegate: RemoteKeyRow { required property int index; slotNo: 10 + index }
                }
            }

            // ════ SYSTEM ══════════════════════════════════════════════════
            Column {
                id: secSystem
                visible: settings.section === "system"
                width: parent.width
                spacing: settings.u(6)
                Component.onCompleted: settings.reindexLater()

                SettingHeading { label: "INTERFACE" }
                SettingRow {
                    kind: "toggle"
                    label: "UI SOUNDS"
                    sub: Sfx.enabled ? Sfx.pack.toUpperCase() + " · " + Sfx.level + "%" : ""
                    help: "Short cues as you move through codec's menus: a tick when the selection moves, a bump at the end of a row, a sound for enter, for back, and for a panel opening. Never while a film just plays. Which sound, and how loud it plays, are the SOUND dials in the home screen's GARAGE editor."
                    on: Sfx.enabled
                    sfxOwn: true
                    onActivated: {
                        Sfx.enabled = !Sfx.enabled
                        if (Sfx.enabled) Sfx.preview("select")
                    }
                }
                SettingHeading { label: "DEVELOPER" }
                SettingRow {
                    kind: "toggle"
                    label: "DEBUG LOG"
                    sub: CLog.enabled ? "~/.cache/codec/logs/" : "every step, app + workers + hub"
                    help: "Writes a step-by-step log of the app, the cast workers and the hub to ~/.cache/codec/logs/. For chasing a bug; off, nothing is written."
                    on: CLog.enabled
                    onActivated: CLog.enabled = !CLog.enabled
                }
                SettingRow {
                    kind: "toggle"
                    label: "GARAGE EDITOR"
                    sub: App.editorEnabled ? "(experimental) ` opens the style editor on HOME / STATS"
                                           : "(experimental) off — lighter home, ` does nothing"
                    help: "(Experimental) The live style editor — ` on HOME or STATS opens it and every plate, ink and motion dial can be retuned. Off by default; off, the editor layer isn't built at all, which makes the home screen a little lighter."
                    on: App.editorEnabled
                    onActivated: App.toggleEditorEnabled()
                }
                SettingRow {
                    id: vaultRow
                    kind: "toggle"
                    label: "OBSIDIAN NOTES"
                    property bool vaultOn: App.getSetting("vaultNotes", false) === true
                    sub: vaultOn ? "(experimental) what you watch becomes notes in your vault"
                                 : "(experimental) off"
                    help: "(Experimental, not finished) Films and shows you watch become notes in an Obsidian vault at ~/Documents/Obsidian Vault/1 Active/Media — a note the moment a film starts (for a review mid-watch), its stats refreshed nightly. Your own writing in a note is never changed."
                    on: vaultOn
                    onActivated: { App.putSetting("vaultNotes", !vaultOn); vaultOn = !vaultOn }
                }
                SettingHeading { label: "CODEC" }
                SettingRow {
                    kind: "status"
                    label: "CODEC v" + App.version
                    sub: App.deviceRole === "HUB" ? "this machine serves the library"
                                                  : "streams from the hub"
                    value: App.deviceRole
                    valueColor: Theme.dimFg
                }
                SettingRow {
                    kind: "action"
                    label: "QUIT CODEC"
                    sub: settings.quitArmed ? "press again to quit" : "stops playback, hands the display back, exits"
                    help: "Exits codec: playback stops, the display leaves HDR if it was in it, a hosted party ends. ⏎ twice — the first arms it."
                    value: settings.quitArmed ? "SURE?" : "QUIT"
                    valueColor: settings.quitArmed ? Theme.warning : Theme.dimFg
                    Timer { id: quitDisarm; interval: 3000; onTriggered: settings.quitArmed = false }
                    onActivated: {
                        if (settings.quitArmed) App.quit()
                        else { settings.quitArmed = true; quitDisarm.restart() }
                    }
                }
            }
        }

    }
    }

    // rows scrolled up under the strip dissolve into the page instead of
    // ending on a hard edge (the CRT, where the page scrolls)
    Rectangle {
        anchors.left: pageFlick.left
        anchors.top: pageFlick.top
        width: pageFlick.width
        height: 28
        visible: pageFlick.contentY > 1
        gradient: Gradient {
            GradientStop { position: 0.0; color: Theme.bg }
            GradientStop { position: 1.0; color: "transparent" }
        }
    }

    // The legend: a FOOTER, not the page's last item (scrolled to the bottom
    // it rode a row above the version stamp — the author), on the line every other
    // view's legend sits on — the library's and YouTube's, measured: their
    // words end 20 px off the bottom. (On the version stamp's own baseline it
    // read too low — the stamp sits where its MOVE offset parked it.)
    KeyHints {
        id: footHints
        x: settings.colX
        width: settings.colW
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 12
        px: 13
        // the legend says what the keys do NOW: walking, or a value grabbed
        model: settings.grabbed
              ? [["←/→", "ADJUST"], ["⏎", "APPLY"], ["esc", "CANCEL"]]
              : settings.tabFocus
              ? [["←/→", "SECTION"], ["↓", "ROWS"], ["⏎", "SELECT"], ["esc", "BACK"]]
              : settings.section === "library"
              ? [["↑/↓", "ROW"], ["←/→", "SECTION"], ["⏎", "CHANGE"], ["a", "ADD PATH"],
                 ["d", "REMOVE"], ["esc", "BACK"]]
              : [["↑/↓", "ROW"], ["←/→", "SECTION"], ["⏎", "CHANGE"], ["esc", "BACK"]]
    }

    // ── The readout panel: what the selected setting does, shown ───────────
    // Beside the rows on a wide screen (the CRT has no room — the rows are the
    // page there). A section's own instrument on top — the caption sample, the
    // screen with the dock in its corner, the remote's keys — and under it the
    // selected row's longer word.
    Item {
        id: readout
        visible: settings.wide
        x: settings.colX + settings.colW + settings.panelGap
        y: 0
        width: settings.panelW
        height: Math.min(parent.height - y - 28, readoutBody.implicitHeight + settings.u(44))

        Panel {
            anchors.fill: parent
            color: Theme.withAlpha(Theme.bg, 0.96 * settings.glass)
            active: false
            border.width: 0
            radius: 0
        }
        BorderImage {
            anchors.fill: parent
            source: (App.heroDevRev, settings.devSrc("queue-tex"))
            smooth: false
            opacity: settings.glass
            border { left: 8; right: 8; top: 8; bottom: 8 }
            horizontalTileMode: BorderImage.Stretch
            verticalTileMode: BorderImage.Stretch
        }

        Column {
            id: readoutBody
            anchors.fill: parent
            anchors.margins: settings.u(22)
            spacing: settings.u(16)

            Item {   // header: the section (the "READOUT" tag beside it went — the author)
                width: parent.width
                height: settings.u(18)
                Text {
                    text: settings.sectionLabels[settings.sectionIdx]
                    color: Theme.accent
                    font.family: Theme.codecFont
                    font.pixelSize: settings.u(14)
                    font.letterSpacing: settings.u(5)
                }
            }

            // ── SUBTITLES: a caption sample on a screen, this one and the TV ──
            Column {
                visible: settings.section === "subtitles"
                width: parent.width
                spacing: settings.u(10)
                readonly property bool castSide: settings.selRow !== null && settings.selRow.label.indexOf("CAST") === 0
                SampleScreen {
                    tag: "THIS SCREEN"
                    lit: !parent.castSide
                    Rectangle {   // BOXED: mpv's opaque box
                        anchors.centerIn: localCap
                        width: localCap.width + settings.u(20); height: localCap.height + settings.u(10)
                        color: "#000000"; opacity: App.localCaptionBg ? 0.65 : 0
                        Behavior on opacity { NumberAnimation { duration: DS.base } }
                    }
                    Text {
                        id: localCap
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: Math.round(parent.height * 0.08)
                        width: parent.width - settings.u(40)
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                        text: "You're gonna need a bigger boat."
                        color: App.localCaptionColorHex
                        font.family: settings.captionFamily(App.localCaptionFontLabel)
                        font.pixelSize: Math.max(10, Math.round(26 * settings.k * App.subtitleScale))
                        style: App.localCaptionBg ? Text.Normal : Text.Outline; styleColor: "#000000"
                        Behavior on font.pixelSize { NumberAnimation { duration: DS.base; easing.type: Easing.OutCubic } }
                    }
                }
                SampleScreen {
                    tag: "TELEVISION"
                    lit: parent.castSide
                    Rectangle {   // BOXED: the dark band the receiver draws
                        anchors.centerIn: tvCap
                        width: tvCap.width + settings.u(20); height: tvCap.height + settings.u(10)
                        color: "#000000"; opacity: App.castCaptionBg ? 0.75 : 0
                        Behavior on opacity { NumberAnimation { duration: DS.base } }
                    }
                    Text {
                        id: tvCap
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: Math.round(parent.height * 0.08)
                        width: parent.width - settings.u(40)
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                        text: "You're gonna need a bigger boat."
                        color: App.castCaptionColorHex
                        font.family: settings.captionFamily(App.castCaptionFontLabel)
                        font.pixelSize: Math.max(10, Math.round(32 * settings.k * App.castCaptionScale / 100))
                        style: App.castCaptionBg ? Text.Normal : Text.Outline; styleColor: "#000000"
                        Behavior on font.pixelSize { NumberAnimation { duration: DS.base; easing.type: Easing.OutCubic } }
                    }
                }
            }

            // ── DISPLAY: the screen, with the dock resting in its corner ──
            Rectangle {
                visible: settings.section === "display"
                width: parent.width
                height: Math.round(width * 9 / 16)
                color: "#0b0d12"
                border.width: settings.platePx
                border.color: App.hdrEngaged ? Theme.accent : "#566c78"
                antialiasing: false
                Rectangle {   // the top strip's place
                    x: settings.u(14); y: settings.u(12)
                    width: parent.width - settings.u(28); height: settings.platePx
                    color: "#222034"
                }
                Text {
                    anchors.centerIn: parent
                    text: Theme.mgsSafe((App.display.length > 0 ? App.display.toUpperCase() : "DISPLAY")
                                        + "\n" + App.mode.toUpperCase()
                                        + (App.hdrDirect ? "  ·  HDR" : ""))
                    horizontalAlignment: Text.AlignHCenter
                    color: Theme.dimFg
                    font.family: Theme.hudFont
                    font.pixelSize: settings.u(24)
                    font.letterSpacing: settings.u(2)
                    lineHeight: 1.2
                }
                Rectangle {   // the miniplayer dock
                    id: dockMini
                    readonly property int m: settings.u(14)
                    width: Math.round(parent.width * 0.26); height: Math.round(width * 9 / 16)
                    x: App.pipLeft ? m : parent.width - m - width
                    y: App.pipTop ? m + settings.u(10) : parent.height - m - height
                    Behavior on x { NumberAnimation { duration: DS.slow; easing.type: Easing.OutCubic } }
                    Behavior on y { NumberAnimation { duration: DS.slow; easing.type: Easing.OutCubic } }
                    color: "#181c23"
                    border.width: settings.platePx; border.color: Theme.accent
                    antialiasing: false
                    Text {
                        anchors.centerIn: parent
                        text: "▶"
                        color: Theme.accent
                        font.family: Theme.hudFont
                        font.pixelSize: settings.u(22)
                    }
                }
            }

            // ── REMOTE: the touchscreen's keys, the selected one lit ──
            Column {
                visible: settings.section === "remote"
                width: parent.width
                spacing: settings.u(10)
                id: keyMap
                readonly property int litSlot: settings.selRow !== null && settings.selRow.keySlot !== undefined ? settings.selRow.keySlot : -1
                Grid {   // the touchscreen page: 10 spares, two across
                    columns: 2
                    columnSpacing: settings.u(8); rowSpacing: settings.u(8)
                    width: parent.width
                    Repeater {
                        model: 10
                        KeyCap { required property int index; slot: index; litSlot: keyMap.litSlot; width: (keyMap.width - settings.u(8)) / 2 }
                    }
                }
                Row {   // the four colour keys below the screen
                    spacing: settings.u(8)
                    width: parent.width
                    Repeater {
                        model: 4
                        KeyCap {
                            required property int index
                            slot: 10 + index
                            litSlot: keyMap.litSlot
                            width: (keyMap.width - settings.u(24)) / 4
                            swatch: ["#c8503c", "#5aa864", "#e0c040", "#4a7fd0"][index]
                        }
                    }
                }
            }

            // ── CAST: the chosen television ──
            Rectangle {
                visible: settings.section === "cast"
                width: parent.width
                height: Math.round(width * 9 / 16 * 0.7)
                color: "#0b0d12"
                border.width: settings.platePx
                border.color: Cast.targetId !== "" ? Theme.accent : "#566c78"
                antialiasing: false
                Column {
                    anchors.centerIn: parent
                    spacing: settings.u(6)
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: Theme.mgsSafe(settings.defaultTv === "" ? "FIRST FOUND"
                                            : (secCast.tvName(settings.defaultTv) || "NOT ON THIS NETWORK"))
                        color: Theme.fg
                        font.family: Theme.codecFont
                        font.pixelSize: settings.u(26)
                        font.letterSpacing: settings.u(3)
                    }
                    MechStatus {
                        anchors.horizontalCenter: parent.horizontalCenter
                        label: Cast.targetId === "" ? "OUTPUT · THIS MACHINE" : "OUTPUT · " + Cast.targetName.toUpperCase() + " · " + Cast.castState
                        ink: Cast.targetId === "" ? Theme.dimFg : Theme.accent
                        px: settings.u(20)
                        dot: Cast.targetId !== ""
                    }
                }
            }

            // ── LIBRARY: the counts ──
            Row {
                visible: settings.section === "library"
                width: parent.width
                spacing: settings.u(24)
                Repeater {
                    // re-read when the library changes (a satellite's manifest lands after launch)
                    model: (MediaLibrary.totalCount,
                            [{ n: MediaLibrary.countOf("movie"), w: "FILMS" },
                             { n: MediaLibrary.countOf("show"), w: "SHOWS" },
                             { n: settings.roots.length, w: "PATHS" }])
                    Column {
                        required property var modelData
                        spacing: -4
                        Text {
                            text: "" + modelData.n
                            color: Theme.fg
                            font.family: Theme.codecFont
                            font.pixelSize: settings.u(44)
                            font.letterSpacing: settings.u(2)
                        }
                        Text {
                            text: modelData.w
                            color: Theme.dimFg
                            font.family: Theme.hudFont
                            font.pixelSize: settings.u(20)
                            font.letterSpacing: settings.u(2)
                        }
                    }
                }
            }

            // ── YOUTUBE: who it is ──
            Row {
                visible: settings.section === "youtube"
                width: parent.width
                spacing: settings.u(16)
                readonly property var acct: YouTube.account
                Rectangle {   // the account's picture in a steel frame
                    visible: (parent.acct.photo || "").length > 0 && parent.acct.mode === "account"
                    width: settings.u(76); height: width
                    color: "#181c23"
                    border.width: settings.platePx; border.color: Theme.withAlpha(Theme.accent, 0.5)
                    antialiasing: false
                    Image {
                        anchors.fill: parent
                        anchors.margins: settings.platePx
                        source: parent.visible ? parent.parent.acct.photo : ""
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        smooth: true
                    }
                }
                Column {
                    width: parent.width - x
                    spacing: -2
                    anchors.verticalCenter: parent.verticalCenter
                    Text {
                        width: parent.width
                        text: Theme.mgsSafe(parent.parent.acct.mode === "local" ? "CODEC'S OWN"
                              : (parent.parent.acct.name || "NOT CONNECTED").toUpperCase())
                        color: Theme.fg
                        font.family: Theme.codecFont
                        font.pixelSize: settings.u(30)
                        font.letterSpacing: settings.u(3)
                        // a long name steps down to fit (the CRT's narrow readout)
                        fontSizeMode: Text.HorizontalFit
                        minimumPixelSize: settings.u(16)
                        elide: Text.ElideRight
                    }
                    Text {
                        width: parent.width
                        text: {
                            const a = parent.parent.acct
                            if (a.mode === "local") {
                                const l = a.local || {}
                                return (l.following || 0) + " CHANNELS · " + (l.playlists || 0) + " PLAYLISTS"
                            }
                            return a.browser ? "THROUGH " + a.browser : ""
                        }
                        color: Theme.dimFg
                        font.family: Theme.hudFont
                        font.pixelSize: settings.u(22)
                        font.letterSpacing: settings.u(2)
                        elide: Text.ElideRight
                    }
                }
            }

            // ── SYSTEM: the build ──
            Column {
                visible: settings.section === "system"
                width: parent.width
                spacing: -2
                Text {
                    text: "CODEC"
                    color: Theme.fg
                    font.family: Theme.codecFont
                    font.pixelSize: settings.u(44)
                    font.letterSpacing: settings.u(6)
                }
                Text {
                    text: Theme.mgsSafe("v " + App.version + "   ·   " + App.deviceRole)
                    color: Theme.dimFg
                    font.family: Theme.hudFont
                    font.pixelSize: settings.u(22)
                    font.letterSpacing: settings.u(2)
                }
            }

            // ── PLAYBACK: the device the sound goes to ──
            Column {
                visible: settings.section === "playback"
                width: parent.width
                spacing: settings.u(2)
                Text {
                    text: "SOUND"
                    color: Theme.dimFg
                    font.family: Theme.hudFont
                    font.pixelSize: settings.u(18)
                    font.letterSpacing: settings.u(2)
                }
                Text {
                    width: parent.width
                    text: {
                        const d = settings.devices
                        for (let i = 0; i < d.length; i++)
                            if (d[i].name === Engine.audioDevice)
                                return Theme.mgsSafe(d[i].name === "auto" ? "DEFAULT OUTPUT" : (d[i].description || d[i].name))
                        return "DEFAULT OUTPUT"
                    }
                    color: Theme.fg
                    font.family: Theme.hudFont
                    font.pixelSize: settings.u(28)
                    font.letterSpacing: settings.u(1)
                    wrapMode: Text.WordWrap
                }
                Row {   // three lamps: lit accent when on, dim steel when off
                    spacing: settings.u(18)
                    topPadding: settings.u(6)
                    MechStatus { label: "NIGHT MODE"; ink: App.nightMode ? Theme.accent : Theme.withAlpha(Theme.dimFg, 0.6); px: settings.u(18) }
                    MechStatus { label: "AUTOPLAY"; ink: App.autoplayNext ? Theme.accent : Theme.withAlpha(Theme.dimFg, 0.6); px: settings.u(18) }
                    MechStatus { label: "SLEEP"; ink: App.sleepMinutes > 0 ? Theme.accent : Theme.withAlpha(Theme.dimFg, 0.6); px: settings.u(18); pulse: App.sleepMinutes > 0 }
                }
            }

            Rectangle {   // a seam between the instrument and the word
                visible: settings.selRow !== null
                width: parent.width; height: settings.platePx
                color: "#222034"
                antialiasing: false
            }

            // ── the selected row's longer word ──
            Column {
                width: parent.width
                spacing: settings.u(4)
                visible: settings.selRow !== null
                Text {
                    width: parent.width
                    text: Theme.mgsSafe(settings.selRow ? settings.selRow.label : "")
                    color: Theme.fg
                    font.family: Theme.hudFont
                    font.pixelSize: settings.u(28)
                    font.letterSpacing: settings.u(2)
                    elide: Text.ElideRight
                }
                Text {
                    width: parent.width
                    text: Theme.mgsSafe(settings.selRow ? (settings.selRow.help.length > 0 ? settings.selRow.help : settings.selRow.sub) : "")
                    color: Theme.dimFg
                    font.family: Theme.hudFont
                    font.pixelSize: settings.u(22)
                    font.letterSpacing: settings.u(1)
                    wrapMode: Text.WordWrap
                    lineHeight: 1.15
                }
            }
            Text {
                visible: settings.selRow === null
                width: parent.width
                text: Theme.mgsSafe(settings.tabFocus ? "←/→ changes the section · ↓ back to the rows"
                                                      : "")
                color: Theme.dimFg
                font.family: Theme.hudFont
                font.pixelSize: settings.u(22)
                font.letterSpacing: settings.u(1)
                wrapMode: Text.WordWrap
            }
        }
    }

    // ADD MEDIA PATH — codec's folder browser (CHOOSE MEDIA PATHS uses it too)
    FolderBrowser {
        id: pathBrowser
        anchors.fill: parent
        k: settings.k
        z: 50
        onPicked: (path, kind) => { App.addMediaRoot(path, kind); settings.forceActiveFocus() }
        onClosed: settings.forceActiveFocus()
    }
}
