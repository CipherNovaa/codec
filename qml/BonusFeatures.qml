import QtQuick

// BONUS FEATURES — a film's or a show's featurettes, deleted scenes and promos,
// grouped by the folders they came in. It lives INSIDE the detail page, in the
// text column (the poster stays put beside it), opened from the page's BONUS
// plate, B, or Down onto the plate then ⏎.
//
// DetailView forwards its keys here while this is open (handleKey) instead of
// moving focus: a hidden FocusScope child keeping focus is how every key died
// in v1.35. Rows are the YouTube/STATS plate rows — one family-3 plate per row,
// hot on the current one, the frame sitting inside the plate's dark face.
Item {
    id: bf
    required property var dv            // the DetailView: scale, fonts, info, close()
    property bool open: false
    property var rows: []
    property int idx: 0
    property double lastG: 0
    readonly property int count: rows.length
    // Same plate law as the YouTube rows: fixed row, the UI's 2x plate scale
    // (the old height/360 law drew 4px bevels beside everything else's 2px).
    readonly property int platePx: 2
    readonly property int rowH: 78
    // The plate art carries 3 transparent source px down each side, then a
    // near-black outline px; pull the rows out by both so the VISIBLE (light)
    // edge lines up with the headings.
    readonly property int plateInset: 4 * platePx

    visible: opacity > 0.01
    opacity: open ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.InOutQuad } }

    // rows per group, for the section headers ("DELETED SCENES // 22")
    readonly property var groupCounts: {
        const m = ({})
        for (let i = 0; i < rows.length; i++)
            m[rows[i].group] = (m[rows[i].group] || 0) + 1
        return m
    }

    function load() {
        const keep = rows[idx] ? rows[idx].path : ""
        rows = MediaLibrary.bonusFeatures(dv.info.path || "")
        idx = 0
        for (let i = 0; i < rows.length; i++)
            if (rows[i].path === keep) { idx = i; break }
    }
    function show() {
        rows = []
        load()
        open = true
        list.positionViewAtIndex(idx, ListView.Beginning)
    }
    function hide() { open = false }

    function current() { return rows[idx] || null }
    // a key/remote step: `move` when it went somewhere, `bump` held at an end
    function walk(to) { const was = idx; idx = to; Sfx.play(idx === was ? "bump" : "move") }
    function playCurrent() {
        const r = current()
        if (!r) return
        Sfx.play("select")   // outranks the page's own `back` as it closes
        dv.close()
        App.play(r.path)
    }
    function queueCurrent() {
        const r = current()
        if (!r) return
        Queue.add({uri: r.path, title: (dv.info.title || "") + " / " + r.title,
                   artUrl: (r.thumb || "").length > 0 ? Theme.art(r.thumb) : "",
                   durationS: r.durationS || 0, kind: "extra", sourceId: "library"})
        App.notify("QUEUED · " + r.title)
    }
    function toggleWatched() {
        const r = current()
        if (!r) return
        App.setWatched(r.path, !r.watched)
        reloadTimer.restart()   // let the store settle, then re-pull
    }
    Timer { id: reloadTimer; interval: 50; onTriggered: bf.load() }
    // Resume bars stay current while the page is up (a play elsewhere, a sync).
    Connections {
        target: Store
        enabled: bf.open
        function onUpdated() { reloadTimer.restart() }
    }

    // "8:12", "1:58:38"
    function runtime(s) {
        s = Math.round(s || 0)
        if (s <= 0) return ""
        const h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60), sec = s % 60
        const mm = h > 0 ? String(m).padStart(2, "0") : String(m)
        return (h > 0 ? h + ":" : "") + mm + ":" + String(sec).padStart(2, "0")
    }

    // Keys while open. Returns true when the key was ours.
    function handleKey(event) {
        switch (event.key) {
        case Qt.Key_Down: case Qt.Key_J:
            walk(Math.min(count - 1, idx + 1)); return true
        case Qt.Key_Up: case Qt.Key_K:
            walk(Math.max(0, idx - 1)); return true
        case Qt.Key_PageDown:
            walk(Math.min(count - 1, idx + 6)); return true
        case Qt.Key_PageUp:
            walk(Math.max(0, idx - 6)); return true
        case Qt.Key_G:
            if (event.modifiers & Qt.ShiftModifier) {
                walk(count - 1)
            } else {
                const now = Date.now()
                if (now - lastG < 450) walk(0)
                lastG = now
            }
            return true
        case Qt.Key_Return: case Qt.Key_Enter:
            playCurrent(); return true
        // The library's grammar: a adds to the queue, q opens/closes the panel.
        case Qt.Key_A: queueCurrent(); return true
        case Qt.Key_Q: App.queueOpen = !App.queueOpen; return true
        case Qt.Key_W: toggleWatched(); return true
        // Back the way you came: to the title's page, or to the grid when
        // this was opened straight from it (DetailView.leaveBonus). Esc is
        // also what the mouse's and the remote's Back send.
        case Qt.Key_B: case Qt.Key_H: case Qt.Key_Left: case Qt.Key_Escape:
            dv.leaveBonus(); return true
        case Qt.Key_I:
            dv.close(); return true
        }
        return false
    }

    // A click between rows must not fall through to the detail page's
    // click-anywhere-to-close layer behind.
    MouseArea { anchors.fill: parent; enabled: bf.open }

    // ── Header ────────────────────────────────────────────────────────────
    Column {
        id: head
        width: parent.width
        spacing: Math.round(10 * dv.s)
        // The title's clearlogo, like the page it came from (smaller — this is
        // a sub-page); its text title when it has none.
        Item {
            width: parent.width
            height: Math.round(64 * bf.dv.s)
            readonly property bool hasLogo: (bf.dv.info.clearlogo || "").length > 0
                                            && headLogo.status !== Image.Error
            Image {
                id: headLogo
                visible: parent.hasLogo
                height: parent.height
                width: Math.min(parent.width, implicitWidth * (height / Math.max(1, implicitHeight)))
                source: (bf.dv.info.clearlogo || "").length > 0 ? Theme.art(bf.dv.info.clearlogo) : ""
                fillMode: Image.PreserveAspectFit
                horizontalAlignment: Image.AlignLeft
                asynchronous: true
                smooth: true
            }
            Text {
                visible: !parent.hasLogo
                anchors.bottom: parent.bottom
                width: parent.width
                text: Theme.mgsSafe((bf.dv.info.title || "").toUpperCase())
                color: Theme.fg
                font.family: bf.dv.codecFont
                font.pixelSize: bf.dv.pxi(Math.round(30 * bf.dv.s))
                font.letterSpacing: Math.round(3 * bf.dv.s)
                elide: Text.ElideRight
            }
        }
        Text {
            text: "BONUS FEATURES // " + bf.count
            color: Theme.accent
            font.family: dv.codecFont
            font.pixelSize: dv.pxi(Math.round(18 * dv.s))
            font.letterSpacing: Math.round(4 * dv.s)
        }
    }

    // ── Rows ──────────────────────────────────────────────────────────────
    ListView {
        id: list
        anchors.top: head.bottom
        anchors.topMargin: Math.round(14 * dv.s)
        x: -bf.plateInset
        width: parent.width + bf.plateInset
        // A short list ends where its last row does and the footer follows it
        // up; a long one fills the space down to the poster's foot and scrolls.
        readonly property int room: bf.height - head.height - anchors.topMargin
                                    - hints.height - Math.round(10 * dv.s)
        height: Math.max(0, Math.min(contentHeight, room))
        clip: true
        model: bf.rows
        currentIndex: bf.idx
        // the Settings rows' fan-in (Cascade)
        property int cascadeRev: 0
        property double cascadeAt: 0
        function fanIn() { cascadeAt = Date.now(); cascadeRev++ }
        property bool hadRows: false
        onCountChanged: { if (count > 0 && !hadRows) fanIn(); hadRows = count > 0 }
        // The plates are the selection; this invisible highlight is what keeps
        // the ListView scrolling the current row into view (without one, j/k
        // walks the selection off the screen — the v1.35 YouTube lesson).
        highlight: Item {}
        highlightFollowsCurrentItem: true
        highlightRangeMode: ListView.ApplyRange
        preferredHighlightBegin: Math.round(height * 0.25)
        preferredHighlightEnd: Math.round(height * 0.75)
        highlightMoveDuration: 160
        highlightMoveVelocity: -1

        section.property: "group"
        section.criteria: ViewSection.FullString
        section.delegate: Item {
            required property string section
            width: list.width
            height: Math.round(44 * bf.dv.s)
            Text {
                x: bf.plateInset
                anchors.bottom: parent.bottom
                anchors.bottomMargin: Math.round(8 * bf.dv.s)
                text: Theme.mgsSafe(section.toUpperCase()) + " // " + (bf.groupCounts[section] || 0)
                color: Theme.withAlpha(Theme.accent, 0.85)
                font.family: bf.dv.codecFont
                font.pixelSize: bf.dv.pxi(Math.round(15 * bf.dv.s))
                font.letterSpacing: Math.round(3 * bf.dv.s)
            }
        }

        delegate: Item {
            id: row
            required property var modelData
            required property int index
            readonly property bool isCur: bf.idx === index
            // Selection feel = the STATS / YouTube rows': the WHOLE row's
            // content dips with the plate's press (DS.selDip), the spotlight
            // fades (DS.selFade).
            property real hopY: 0
            readonly property real textDim: isCur ? 1 : 0.5
            width: list.width
            height: bf.rowH
            Cascade { id: fan; view: list }
            opacity: fan.op
            onIsCurChanged: if (isCur && bf.open) { plate.tap(); hop.restart() }
            SequentialAnimation {
                id: hop
                NumberAnimation { target: row; property: "hopY"; to: DS.selDip(plate.height); duration: 90; easing.type: Easing.OutQuad }
                NumberAnimation { target: row; property: "hopY"; to: 0; duration: 260; easing.type: Easing.OutBack }
            }

            MechButton {
                id: plate
                family: 3
                px: bf.platePx
                hot: row.isCur
                anchors.fill: parent
                anchors.topMargin: 1
                anchors.bottomMargin: 1
                opacity: row.isCur ? 1 : 0.55
                Behavior on opacity { NumberAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
            }

            Row {
                x: 26
                transform: Translate { y: row.hopY + fan.dy }
                // thumbnail + text centred on the plate's dark face
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: Math.round(plate.y + plate.faceMid - parent.height / 2)
                spacing: 14

                Rectangle {
                    width: 92; height: 52; radius: 2
                    color: Theme.surfaceHi
                    clip: true
                    anchors.verticalCenter: parent.verticalCenter
                    Image {
                        anchors.fill: parent
                        source: (row.modelData.thumb || "").length > 0
                                ? Theme.art(row.modelData.thumb) : ""
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        sourceSize.width: 184
                    }
                    // codec's own resume point along the frame's foot
                    Rectangle {
                        visible: !row.modelData.watched && row.modelData.pct > 0.01
                        anchors.left: parent.left
                        anchors.bottom: parent.bottom
                        height: 4
                        width: parent.width * Math.min(1, row.modelData.pct)
                        color: Theme.accent
                    }
                }

                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 5
                    width: list.width - 200
                    Text {
                        width: parent.width
                        text: Theme.mgsSafe(row.modelData.title)
                        color: Theme.fg
                        opacity: row.textDim
                        Behavior on opacity { NumberAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                        font.family: Theme.hudFont
                        font.pixelSize: 30
                        elide: Text.ElideRight
                    }
                    Text {
                        width: parent.width
                        text: bf.runtime(row.modelData.durationS)
                              + (!row.modelData.watched && row.modelData.pct > 0.01
                                 ? "   " + Math.round(row.modelData.pct * 100) + "% WATCHED" : "")
                        color: Theme.dimFg
                        opacity: row.textDim
                        Behavior on opacity { NumberAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                        font.family: Theme.hudFont
                        font.pixelSize: 24
                        font.letterSpacing: 2
                        elide: Text.ElideRight
                    }
                }
            }
            Text {
                anchors.right: parent.right
                anchors.rightMargin: 24
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: -11
                visible: row.modelData.watched === true
                text: "✔"
                color: Theme.accent
                font.family: Theme.hudFont
                font.pixelSize: 40
            }

            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                // Hover selects only on real pointer movement (rows sliding under
                // a parked cursor must not steal the selection).
                property point prevScene: Qt.point(-9999, -9999)
                onExited: prevScene = Qt.point(-9999, -9999)
                onPositionChanged: (mouse) => {
                    const p = mapToItem(null, mouse.x, mouse.y)
                    const moved = Math.abs(p.x - prevScene.x) > 2
                                  || Math.abs(p.y - prevScene.y) > 2
                    prevScene = Qt.point(p.x, p.y)
                    if (App.pointerActive && moved && !list.moving && bf.idx !== row.index) {
                        bf.idx = row.index
                        if (bf.open) Sfx.play("move")
                    }
                }
                onClicked: {
                    if (bf.idx === row.index) bf.playCurrent()
                    else { bf.idx = row.index; Sfx.play("move") }
                }
            }
        }
    }

    // ── Footer: every keycap is a button ──────────────────────────────────
    Flow {
        id: hints
        anchors.top: list.bottom
        anchors.topMargin: Math.round(10 * dv.s)
        width: parent.width
        spacing: Math.round(16 * dv.s)
        Repeater {
            model: [["j/k", "MOVE", null],
                    ["⏎", "PLAY", () => bf.playCurrent()],
                    ["a", "QUEUE", () => bf.queueCurrent()],
                    ["q", "PANEL", () => { App.queueOpen = !App.queueOpen }],
                    ["w", "WATCHED", () => bf.toggleWatched()],
                    ["b/esc", "BACK", () => bf.dv.leaveBonus()]]
            Item {
                id: hint
                required property var modelData
                width: hintRow.implicitWidth
                height: hintRow.implicitHeight
                property bool hover: false
                Row {
                    id: hintRow
                    spacing: Math.round(5 * bf.dv.s)
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: kc.implicitWidth + Math.round(8 * bf.dv.s)
                        height: Math.round(16 * bf.dv.s)
                        radius: Math.round(3 * bf.dv.s)
                        color: Theme.withAlpha(Theme.bg, 0.45)
                        border.width: 1
                        border.color: Theme.withAlpha(Theme.fg, hint.hover ? 0.45 : 0.18)
                        Text {
                            id: kc
                            anchors.centerIn: parent
                            anchors.verticalCenterOffset: Math.max(1, Math.round(bf.dv.s))
                            text: hint.modelData[0]
                            color: Theme.withAlpha(Theme.fg, 0.6)
                            font.family: bf.dv.hudFont
                            font.pixelSize: bf.dv.pxi(Math.round(16 * bf.dv.s))
                        }
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: hint.modelData[1]
                        color: hint.hover ? Theme.fg : Theme.dimFg
                        font.family: bf.dv.hudFont
                        font.pixelSize: bf.dv.pxi(Math.round(16 * bf.dv.s))
                        font.letterSpacing: Math.round(1.5 * bf.dv.s)
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    enabled: hint.modelData[2] !== null
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: hint.hover = true
                    onExited: hint.hover = false
                    onClicked: hint.modelData[2]()
                }
            }
        }
    }
}
