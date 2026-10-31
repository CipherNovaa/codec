import QtQuick

// Slide-in queue panel (toggled with q from any browse view). Playback is
// never interrupted — this is pure queue surgery: j/k select, J/K move,
// d remove, ⏎ play now, S shuffle, r repeat, C clear, w save, o load,
// t send the whole queue to the hub for another device.
FocusScope {
    id: qs
    // The remote can't send the Shift+J/K / d / C these keys use: CH+/CH- move
    // the selected item, STOP removes it, holding STOP clears the queue.
    Connections {
        target: App
        enabled: App.queueOpen
        function onRemoteQueueAction(action) {
            const i = qlist.currentIndex
            if (action === "up" && i > 0) {
                Queue.moveItem(i, i - 1); qlist.currentIndex = i - 1; Sfx.play("move")
            } else if (action === "down" && i >= 0 && i < qlist.count - 1) {
                Queue.moveItem(i, i + 1); qlist.currentIndex = i + 1; Sfx.play("move")
            } else if (action === "remove" && i >= 0) {
                Queue.removeAt(i); Sfx.play("select")
            } else if (action === "clear") {
                Queue.clear(); Sfx.play("select")
            } else Sfx.play("bump")     // moved past an end, or nothing to remove
        }
    }

    // UI sounds (Sfx): the panel opening / closing plays open / back however it
    // was toggled (q from any view, the remote's MENU, esc here) — caught here,
    // never at start-up. Keys and the mouse cue explicitly; a queue changing
    // under the list (the hub inbox arriving) stays silent.
    property bool sfxReady: false
    Component.onCompleted: sfxReady = true
    Connections {
        target: App
        function onQueueOpenChanged() { if (qs.sfxReady) Sfx.play(App.queueOpen ? "open" : "back") }
    }
    function sfxStep(was) { Sfx.play(qlist.currentIndex === was ? "bump" : "move") }
    // a queue command: nothing to act on in an empty queue
    function sfxAct() { Sfx.play(qlist.count > 0 ? "select" : "bump") }

    property double slideX: App.queueOpen ? 0 : width + 40
    property string mode: "list" // list | save | load
    // Glassy plates like the home wheel buttons — the panel + its row plates render
    // at this opacity so the backdrop bleeds through, while the text stays fully
    // opaque. 1.0 = solid (old look), lower = glassier.
    property real glass: App.glassLevel
    property var savedNames: []
    property int loadIdx: 0
    property double lastG: 0

    // Row sizing — the plates hug the 2-line text (title + subtitle) with even
    // padding, measured off a hidden sample so the height tracks the real font
    // metrics rather than a magic number. rowUnitH also drives the panel height
    // in Main (queuePanel.rowUnitH) so it still fits ~10 rows.
    readonly property int rowPadV: 9    // the plate's face keeps its pre-2026-10 size (thin bevel)
    readonly property int rowGapV: 8
    // The family-3 plate's dark label recess is top-weighted (thin top bezel,
    // thicker bottom band), so its centre sits ~4px above the plate centre.
    // Text rides this offset to sit on the DARK recess only, not the bottom band.
    readonly property int rowTextRise: 4
    readonly property int rowPlateH: Math.ceil(rowMeasure.implicitHeight) + rowPadV * 2
    readonly property int rowUnitH: rowPlateH + rowGapV
    // Everything in the panel that ISN'T the row list — the column's 18px top +
    // bottom margins, all above the list (header, now-playing), the footer and
    // its 12px gap — measured off the layout, so Main can size the panel to
    // WHOLE rows exactly (a hard-coded 154 drifted 9px short: the list was
    // always a sliver under N rows and the top row showed cut off).
    readonly property int listChrome: 18 + 18 + listBox.y + footer.height + 12
    Column {
        id: rowMeasure
        visible: false
        spacing: 3
        Text { text: "Ag"; font.family: Theme.hudFont; font.pixelSize: 26 }
        Text { text: "Ag"; font.family: Theme.hudFont; font.pixelSize: 18 }
    }

    onVisibleChanged: if (visible) { mode = "list"; forceActiveFocus(); qlist.fanIn() }

    // Priority when open: the queue must own the keyboard so q/esc always close
    // it ("uncloseable at times"). If the stage view or an overlay behind
    // steals focus while the queue is up, grab it straight back. activeFocus stays
    // true while a child (the save/load input) is focused, so this only fires on a
    // real external steal. callLater avoids re-entrancy with the stealer.
    // …except from an overlay raised OVER the open queue (help, the party, the
    // cast remote, the output picker): grabbing it back left those keyboard-dead.
    property bool yieldFocus: false
    onActiveFocusChanged: if (App.queueOpen && !activeFocus && !yieldFocus)
                              Qt.callLater(qs.forceActiveFocus)

    function fmtTotal(s) {
        s = Math.floor(s)
        if (s <= 0) return ""
        const h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60)
        return h > 0 ? h + "H " + m + "M" : m + " MIN"
    }

    function leaveSubMode() {
        mode = "list"
        saveInput.focus = false // FocusScope keeps the child focused otherwise
        qs.forceActiveFocus()
    }

    // Live-editable mech-UI asset URL: file:// off disk in a dev build (hot-reloads
    // on save via heroDevRev), else the baked qrc. Same contract as MechBar.
    function devSrc(rel) {
        var d = App.heroDevPath(rel)
        return d !== "" ? d + "?v=" + App.heroDevRev : "qrc:/assets/mechui/" + rel + ".png"
    }

    Keys.onPressed: (event) => {
        if (mode === "load") {
            switch (event.key) {
            case Qt.Key_Down: case Qt.Key_J:
                Sfx.play(savedNames.length > 1 ? "move" : "bump")
                loadIdx = (loadIdx + 1) % savedNames.length; break
            case Qt.Key_Up: case Qt.Key_K:
                Sfx.play(savedNames.length > 1 ? "move" : "bump")
                loadIdx = (loadIdx + savedNames.length - 1) % savedNames.length; break
            case Qt.Key_Return: case Qt.Key_Enter:
                if (savedNames.length > 0) {
                    Sfx.play("select")
                    Queue.loadSaved(savedNames[loadIdx])
                    App.notify("QUEUE ▸ " + savedNames[loadIdx].toUpperCase())
                }
                leaveSubMode(); break
            case Qt.Key_Escape: case Qt.Key_O: case Qt.Key_Q: case Qt.Key_H:
                Sfx.play("back")
                leaveSubMode(); break
            default: return
            }
            event.accepted = true
            return
        }
        if (mode === "save")
            return // the input has focus
        const was = qlist.currentIndex
        switch (event.key) {
        case Qt.Key_Down: case Qt.Key_J:
            if (event.modifiers & Qt.ShiftModifier) {
                Queue.moveItem(qlist.currentIndex, qlist.currentIndex + 1)
                qlist.currentIndex = Math.min(qlist.count - 1, qlist.currentIndex + 1)
            } else {
                qlist.incrementCurrentIndex()
            }
            sfxStep(was)
            break
        case Qt.Key_Up: case Qt.Key_K:
            if (event.modifiers & Qt.ShiftModifier) {
                Queue.moveItem(qlist.currentIndex, qlist.currentIndex - 1)
                qlist.currentIndex = Math.max(0, qlist.currentIndex - 1)
            } else {
                qlist.decrementCurrentIndex()
            }
            sfxStep(was)
            break
        case Qt.Key_D:
            // vim: ctrl+d = half page; plain d keeps its delete job.
            if (event.modifiers & Qt.ControlModifier) {
                qlist.currentIndex = Math.min(qlist.count - 1, qlist.currentIndex + 8)
                sfxStep(was)
            } else {
                sfxAct()
                Queue.removeAt(qlist.currentIndex)
            }
            break
        case Qt.Key_U:
            if (event.modifiers & Qt.ControlModifier) {
                qlist.currentIndex = Math.max(0, qlist.currentIndex - 8)
                sfxStep(was)
            }
            else return
            break
        case Qt.Key_G:
            if (event.modifiers & Qt.ShiftModifier) {
                qlist.currentIndex = qlist.count - 1
                sfxStep(was)
            } else {
                const now = Date.now()
                if (now - lastG < 450) { qlist.currentIndex = 0; sfxStep(was) }
                lastG = now
            }
            break
        // (l no longer plays: h/l are navigation keys — ⏎ plays)
        case Qt.Key_Return: case Qt.Key_Enter:
            sfxAct()
            App.playQueued(qlist.currentIndex); break
        case Qt.Key_S:
            if (event.modifiers & Qt.ShiftModifier) { sfxAct(); Queue.shuffle() }
            else return
            break
        case Qt.Key_R: Sfx.play("select"); Queue.cycleRepeat(); break
        case Qt.Key_C:
            // c = cut the selected item, C = clear the whole queue.
            sfxAct()
            if (event.modifiers & Qt.ShiftModifier) Queue.clear()
            else Queue.removeAt(qlist.currentIndex)
            break
        case Qt.Key_W:
            if (Queue.count > 0) {
                Sfx.play("open")
                mode = "save"
                saveInput.text = ""
                saveInput.forceActiveFocus()
            } else Sfx.play("bump")
            break
        case Qt.Key_O:
            savedNames = Queue.savedQueues()
            if (savedNames.length === 0) { Sfx.play("bump"); App.notify("NO SAVED QUEUES"); break }
            Sfx.play("open")
            loadIdx = 0
            mode = "load"
            break
        case Qt.Key_T:   // a satellite's queue → the hub (the hub IS the hub)
            if (App.deviceRole === "HUB") return
            sfxAct(); App.sendQueueToHub(); break
        case Qt.Key_P:
            // p from the queue = straight to the viewport, panel away.
            App.queueOpen = false
            App.toPlayer()
            break
        case Qt.Key_Q: case Qt.Key_Escape: case Qt.Key_H:
            App.queueOpen = false; break
        default:
            return
        }
        event.accepted = true
    }

    Panel {
        anchors.fill: parent
        anchors.margins: 0
        color: Theme.withAlpha(Theme.bg, 0.96 * qs.glass)
        // The painted queue-tex 9-slice IS the frame now, so drop Panel's own
        // rounded accent hairline + tick strip — they drew a SECOND, brighter,
        // rounded outline outside the (glassed) texture frame (the author spotted it).
        active: false
        border.width: 0

        // Live-editable panel plate — a 9-SLICE, so the frame you draw wraps the
        // panel ONCE: corners stay pixel-crisp, the edge lines stretch along each
        // side, the center fill stretches to fill the body. EDIT:
        // assets/mechui/plates/queue-tex.png (64x64). Keep detail in the outer ~8px
        // (corners); keep the edges a clean straight run and the center flat, or
        // they smear when stretched. A dev build hot-reloads on Ctrl-S (relaunch
        // codec once first).
        BorderImage {
            anchors.fill: parent
            source: (App.heroDevRev, qs.devSrc("queue-tex"))
            smooth: false
            opacity: qs.glass
            border { left: 8; right: 8; top: 8; bottom: 8 }
            horizontalTileMode: BorderImage.Stretch
            verticalTileMode: BorderImage.Stretch
        }

        Column {
            anchors.fill: parent
            // Narrower side margins so the row plates extend further out
            // horizontally; keep the top/bottom breathing room.
            anchors.topMargin: 18
            anchors.bottomMargin: 18
            anchors.leftMargin: 4
            anchors.rightMargin: 4
            spacing: 12

            // Header — QUEUE title + item/duration count, both vertically centred
            // in a taller bar so they sit a touch lower and read as one row.
            Item {
                width: parent.width
                height: 38
                ShadowText {
                    // Line up with the row content (the "NN" index sits 16px into
                    // each plate) so the header reads as the column's title.
                    x: 16
                    anchors.verticalCenter: parent.verticalCenter
                    text: "QUEUE"
                    color: Theme.dimFg
                    font.family: Theme.codecFont
                    font.pixelSize: 24
                    font.letterSpacing: 5
                }
                ShadowText {
                    anchors.right: parent.right
                    anchors.rightMargin: 16   // mirror QUEUE's 16px inset so the
                                              // header sits within the row content
                    anchors.verticalCenter: parent.verticalCenter
                    text: Queue.count + " ITEMS" + (Queue.totalDuration > 0
                          ? "   " + qs.fmtTotal(Queue.totalDuration) : "")
                    color: Theme.dimFg
                    font.family: Theme.hudFont
                    font.pixelSize: 20
                    font.letterSpacing: 1
                }
            }

            // Now playing — a LIVE-EDITABLE display frame (assets/mechui/plates/
            // queue-now.png; the author is still polishing it, hot-reloads via MechSlice's
            // dev override). Its 9-slice geometry matches the buttons (l6 r6 t4 b4,
            // px2) so the edges align. The ▶ + title render ON TOP, in the frame's
            // transparent middle — the frame is only a border, never over the text.
            Item {
                width: parent.width
                height: qs.rowPlateH          // same size as a button row plate
                visible: Engine.path.length > 0 && !Engine.idle
                MechSlice {
                    source: "qrc:/assets/mechui/queue-now.png"
                    opacity: qs.glass
                    artL: 6
                    artR: 6
                    artT: 4
                    artB: 4
                    px: 2
                    // btn-3 (the rows) carries 3px transparent L/R padding inside
                    // its art; queue-now.png is drawn edge-to-edge, so inset the
                    // frame by that padding (3 art px × px2 = 6px) to line the
                    // visible plate up with the button rows. Top/bottom are flush.
                    anchors.fill: parent
                    anchors.leftMargin: 6
                    anchors.rightMargin: 6
                }
                ShadowText {
                    x: 20                    // just right of the row number column
                    anchors.verticalCenter: parent.verticalCenter
                    text: "▶"
                    color: Theme.fg          // same as the title, not accent
                    font.family: Theme.hudFont
                    font.pixelSize: 24   // sized down to sit with the text
                }
                ShadowText {
                    x: 48
                    width: parent.width - 62
                    anchors.verticalCenter: parent.verticalCenter
                    text: Theme.mgsSafe(Engine.mediaTitle)
                    color: Theme.fg
                    font.family: Theme.hudFont
                    font.pixelSize: 24
                    elide: Text.ElideRight
                }
            }

            // Save-as input (w) — a lit plate in the row grammar (was a rounded
            // web-app box); the typed name rides the dark recess like a row title.
            Item {
                width: parent.width
                height: qs.rowPlateH
                visible: qs.mode === "save"
                MechButton {
                    family: 6
                    px: 2
                    hot: true
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    height: qs.rowPlateH
                }
                TextInput {
                    id: saveInput
                    x: 16
                    width: parent.width - 32
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.verticalCenterOffset: -qs.rowTextRise
                    color: Theme.fg
                    font.family: Theme.hudFont
                    font.pixelSize: 20
                    clip: true
                    Keys.onPressed: (event) => {
                        if (event.key === Qt.Key_Escape) {
                            Sfx.play("back")
                            qs.leaveSubMode()
                            event.accepted = true
                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                            Sfx.play(text.trim().length > 0 ? "select" : "back")
                            if (text.trim().length > 0) {
                                Queue.saveAs(text.trim())
                                App.notify("QUEUE SAVED · " + text.trim().toUpperCase())
                            }
                            qs.leaveSubMode()
                            event.accepted = true
                        }
                    }
                    ShadowText {
                        anchors.fill: parent
                        verticalAlignment: Text.AlignVCenter
                        visible: saveInput.text.length === 0
                        text: Theme.mgsSafe("queue name — ⏎ save · esc cancel")
                        color: Theme.dimFg
                        font: saveInput.font
                    }
                }
            }

            // Saved-queue picker (o) — plate rows in the same grammar as the queue
            // (was rounded web-app boxes); the highlighted name rides the lit plate.
            Column {
                width: parent.width
                spacing: qs.rowGapV
                visible: qs.mode === "load"
                Repeater {
                    model: qs.mode === "load" ? qs.savedNames : []
                    delegate: Item {
                        required property string modelData
                        required property int index
                        readonly property bool sel: qs.loadIdx === index
                        width: parent.width
                        height: qs.rowPlateH
                        MechButton {
                            family: 6
                            px: 2
                            hot: parent.sel
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            height: qs.rowPlateH
                        }
                        ShadowText {
                            x: 16
                            width: parent.width - 32
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.verticalCenterOffset: -qs.rowTextRise
                            text: Theme.mgsSafe(modelData)
                            color: parent.sel ? Theme.accent : Theme.fg
                            Behavior on color { ColorAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                            font.family: Theme.hudFont
                            font.pixelSize: 24
                            elide: Text.ElideRight
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                Sfx.play("select")
                                Queue.loadSaved(modelData)
                                App.notify("QUEUE ▸ " + modelData.toUpperCase())
                                qs.leaveSubMode()
                            }
                        }
                    }
                }
            }

            // List + a minimal scroll rail, wrapped in an Item so the rail can
            // overlay the list (a Column child can't overlay its sibling).
            Item {
                id: listBox
                width: parent.width
                height: parent.height - y - footer.height - 12
                visible: qs.mode !== "load"

                ListView {
                id: qlist
                anchors.fill: parent
                model: Queue
                // the Settings rows' fan-in (Cascade)
                property int cascadeRev: 0
                property double cascadeAt: 0
                function fanIn() { cascadeAt = Date.now(); cascadeRev++ }
                clip: true
                keyNavigationWraps: true
                // Snap scrolling to whole rows so a half-button is never shown
                //. ApplyRange keeps the current row inside the viewport and
                // scrolls in row-sized steps; SnapToItem lands flicks on a row edge.
                snapMode: ListView.SnapToItem
                highlightRangeMode: ListView.ApplyRange
                preferredHighlightBegin: 0
                preferredHighlightEnd: height - qs.rowUnitH
                // Selection is the STATS top-10 grammar now (lit plate per row),
                // not a sliding highlight rectangle — see the delegate's MechButton.

                delegate: Item {
                    id: qrow
                    required property string title
                    required property string subtitle
                    required property double durationS
                    required property int index

                    width: qlist.width
                    height: qs.rowUnitH
                    Cascade { id: fan; view: qlist }
                    opacity: fan.op

                    // Ported from the STATS rows: the current row rides the LIT
                    // plate art; moving the selection onto it presses the plate
                    // (3-frame) and bounces the content down-and-back once.
                    readonly property bool selected: ListView.isCurrentItem
                    property real hopY: 0
                    // The current row stays on the lit plate for as long as it is
                    // selected (the timed fade back to the idle plate lost
                    // track of where you were). A selection MOVING cross-fades over
                    // DS.selFade (the STATS feel) — never a fade while it stays put.
                    property real litOpacity: 0
                    Behavior on litOpacity { NumberAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                    SequentialAnimation {
                        id: hopAnim
                        NumberAnimation { target: qrow; property: "hopY"; to: DS.selDip(btn.height); duration: 90; easing.type: Easing.OutQuad }
                        NumberAnimation { target: qrow; property: "hopY"; to: 0; duration: 260; easing.type: Easing.OutBack }
                    }
                    onSelectedChanged: {
                        if (selected) {
                            litOpacity = 1
                            if (qs.visible) { btn.tap(); hopAnim.restart() }
                        } else {
                            litOpacity = 0
                            // reset the bounce: fast nav through a long queue can
                            // deselect a row mid-hop, leaving hopY != 0 → its text
                            // sits shifted (misaligns only on a long queue).
                            hopAnim.stop()
                            hopY = 0
                        }
                    }

                    // idle plate (always) + the hover/lit plate on top, cross-faded
                    // via litOpacity so selection fades out instead of snapping off.
                    MechButton {
                        family: 6
                        px: 2
                        hot: false
                        opacity: qs.glass
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        height: qs.rowPlateH
                    }
                    MechButton {
                        id: btn
                        family: 6
                        px: 2
                        hot: true
                        opacity: qrow.litOpacity * qs.glass
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        height: qs.rowPlateH
                    }

                    // content sits ON the plate and rides its press (hopY)
                    Item {
                        anchors.fill: parent
                        transform: Translate { y: qrow.hopY + fan.dy }

                        ShadowText {
                            x: 16
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.verticalCenterOffset: -qs.rowTextRise
                            text: (index + 1).toString().padStart(2, "0")
                            // Current row is LIT (bright fg), the rest muted. Marking
                            // "you are here" by brightness, not the accent hue — the
                            // pywal accent can resolve dim, which read as the current
                            // row being DARKER than the others (should be lit).
                            color: qrow.selected ? Theme.fg : Theme.dimFg
                            Behavior on color { ColorAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                            font.family: Theme.hudFont
                            font.pixelSize: 22
                        }

                        Column {
                            x: 48
                            width: parent.width - 62
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.verticalCenterOffset: -qs.rowTextRise
                            spacing: 3
                            ShadowText {
                                width: parent.width
                                text: Theme.mgsSafe(title)
                                // Current row LIT (bright fg), the rest muted —
                                // "you are here" by brightness, not the (possibly
                                // dim) accent hue.
                                color: qrow.selected ? Theme.fg : Theme.dimFg
                                Behavior on color { ColorAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                                font.family: Theme.hudFont
                                font.pixelSize: 26
                                elide: Text.ElideRight
                            }
                            // Subtitle with drawn dot separators between fields
                            // (mgs-hud has no middot glyph). Splits on 2+ spaces;
                            // falls back to the plain string if that doesn't yield a
                            // sane 2–5 field split, so it never mangles the metadata.
                            Row {
                                width: parent.width
                                spacing: 7
                                clip: true
                                visible: subtitle.length > 0
                                Repeater {
                                    model: {
                                        // fields are joined with " · " (library.cpp) — split
                                        // on the middot; fall back to the whole string if that
                                        // yields no sane multi-field split.
                                        const parts = String(subtitle).split(/\s*·\s*/).filter(s => s.length > 0)
                                        return (parts.length >= 2 && parts.length <= 6) ? parts : [String(subtitle)]
                                    }
                                    delegate: Row {
                                        required property int index
                                        required property string modelData
                                        spacing: 7
                                        Rectangle {
                                            visible: index > 0
                                            anchors.verticalCenter: parent.verticalCenter
                                            anchors.verticalCenterOffset: 1   // align to the hud glyph centre
                                            width: 3; height: 3; radius: 1.5
                                            color: Theme.withAlpha(Theme.dimFg, 0.7)
                                        }
                                        ShadowText {
                                            text: Theme.mgsSafe(modelData)
                                            color: Theme.dimFg
                                            font.family: Theme.hudFont
                                            font.pixelSize: 18
                                            font.letterSpacing: 1
                                        }
                                    }
                                }
                            }
                        }
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
                            if (App.pointerActive && moved && !qlist.moving) {
                                if (qlist.currentIndex !== index) Sfx.play("move")
                                qlist.currentIndex = index
                            }
                        }
                        onClicked: {
                            Sfx.play(qlist.currentIndex === index ? "select" : "move")
                            if (qlist.currentIndex === index) App.playQueued(index)
                            else qlist.currentIndex = index
                        }
                        onDoubleClicked: { Sfx.play("select"); App.playQueued(index) }
                    }
                }

                ShadowText {
                    anchors.centerIn: parent
                    visible: qlist.count === 0
                    text: Theme.mgsSafe("QUEUE EMPTY")
                    color: Theme.dimFg
                    font.family: Theme.hudFont
                    font.pixelSize: 24
                    font.letterSpacing: 2
                }
                }

                // Minimal scroll rail — a thin right-edge indicator, shown only
                // when the queue overflows the visible list. Tracks the list's
                // own visibleArea (no controls import, matches the mech chrome).
                Rectangle {
                    id: scrollRail
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    // Sit in the narrow gap between the (wider) row plates and the
                    // panel frame.
                    anchors.rightMargin: -2
                    width: 2
                    radius: width / 2
                    color: Theme.withAlpha(Theme.fg, 0.08)
                    visible: qlist.contentHeight > qlist.height + 1
                    Rectangle {
                        width: parent.width
                        radius: width / 2
                        color: Theme.withAlpha(Theme.fg, 0.42)
                        height: Math.max(18, scrollRail.height * qlist.visibleArea.heightRatio)
                        y: qlist.visibleArea.yPosition * scrollRail.height
                    }
                }

            }

            // Footer: repeat status + boxed keytips. The old hint was one
            // right-aligned mono line that ELIDED on the narrow panel (it
            // truncated to "w…"); boxed keycaps wrap across the width instead.
            Column {
                id: footer
                width: parent.width
                spacing: 8
                ShadowText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: ["REPEAT OFF", "REPEAT ALL", "REPEAT ONE"][Queue.repeatMode]
                    color: Queue.repeatMode > 0 ? Theme.accent : Theme.dimFg
                    font.family: Theme.hudFont
                    font.pixelSize: 18
                    font.letterSpacing: 2
                }
                KeyHints {
                    width: parent.width
                    px: 12
                    crtGrow: false               // two rows of five fill the 420-px panel already
                    perRow: 5                    // two centred rows of five
                    // ⇧ before MOVE flags that move is Shift+J/K (vs plain j/k select).
                    model: [["⏎", "PLAY"], ["d", "DEL"], ["⇧", "SHIFT"], ["J/K", "MOVE"], ["S", "SHUF"],
                            ["r", "REP"], ["C", "CLEAR"], ["w", "SAVE"], ["o", "LOAD"]]
                           .concat(App.deviceRole === "HUB" ? [] : [["t", "→HUB"]])
                }
            }
        }
    }
}
