import QtQuick

// CHOOSE MEDIA PATHS — the second page codec ever shows, after the display.
// A machine with no media paths (a new install; never a satellite, which
// browses its hub) says where its films and shows live: each path a plate with
// what it CONTAINS on the right (Kodi's "this directory contains": MOVIES or
// TV, asked as it's added, ⏎ flips it), ADD MEDIA PATH opens codec's folder
// browser, and CONTINUE scans and opens home. Shown once — continuing (or
// skipping, with nothing added) settles it; Settings ▸ LIBRARY keeps the paths.
FocusScope {
    id: page

    // the display page's scale, so the two pages read as one sequence
    readonly property real s: Math.max(0.85, Math.min(width / 1680, 1.4))
    function u(n) { return Math.round(n * s) }

    property var roots: App.mediaRoots()
    property var counts: ({})            // path → "142 VIDEOS" (probeFolder)
    property int idx: 0
    readonly property int addRow: roots.length
    readonly property int hubRow: roots.length + 1
    readonly property int doneRow: roots.length + 2
    readonly property int rowCount: roots.length + 3

    function refresh() {
        roots = App.mediaRoots()
        for (let i = 0; i < roots.length; i++)
            if (counts[roots[i].path] === undefined) App.probeFolder(roots[i].path)
        if (idx >= rowCount) idx = rowCount - 1
    }
    function entered() {
        forceActiveFocus()
        refresh()
        idx = roots.length === 0 ? addRow : doneRow
        bootAnim.restart()
        rows.fanIn()
    }
    onVisibleChanged: if (visible) entered()
    Component.onCompleted: if (visible) entered()

    Connections {
        target: App
        function onMediaRootsChanged() { page.refresh() }
        function onFolderProbed(p, videos, episodes, seasons, capped) {
            let known = false
            for (let i = 0; i < page.roots.length; i++) known = known || page.roots[i].path === p
            if (!known) return
            const c = Object.assign({}, page.counts)
            c[p] = videos === 0 ? "NO VIDEO FILES FOUND YET"
                 : (videos + (capped ? "+" : "") + " VIDEO FILES")
            page.counts = c
        }
    }

    function moveTo(i) {
        const n = Math.max(0, Math.min(rowCount - 1, i))
        Sfx.play(n === idx ? "bump" : "move")
        idx = n
    }
    function pointTo(i) {
        if (idx !== i) Sfx.play("move")
        idx = i
    }
    function activate() {
        if (idx === addRow) { browser.open("") ; return }
        if (idx === hubRow) { hubs.open(); return }
        if (idx === doneRow) { Sfx.play("select"); App.finishMediaPaths(); return }
        Sfx.play("select")
        App.toggleMediaRootKind(idx)          // MOVIES ⇄ TV, as Settings does it
    }
    function removeSel() {
        if (idx >= roots.length) { Sfx.play("bump"); return }
        Sfx.play("back")
        App.removeMediaRoot(idx)
    }

    Keys.onPressed: (event) => {
        switch (event.key) {
        case Qt.Key_Down: case Qt.Key_J: moveTo(idx + 1); break
        case Qt.Key_Up: case Qt.Key_K: moveTo(idx - 1); break
        case Qt.Key_Return: case Qt.Key_Enter: case Qt.Key_Space: activate(); break
        case Qt.Key_T: if (idx < roots.length) activate(); else return; break
        case Qt.Key_A: idx = addRow; activate(); break
        case Qt.Key_D: case Qt.Key_Delete: removeSel(); break
        case Qt.Key_Escape: Sfx.play("back"); App.backToChooser(); break
        default: return
        }
        event.accepted = true
    }

    // ── the display page's lit field ─────────────────────────────────────
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: Theme.withAlpha(Theme.fg, 0.07) }
            GradientStop { position: 0.42; color: "transparent" }
            GradientStop { position: 1.0; color: Theme.withAlpha(Theme.bg, 0.0) }
        }
    }
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.7; color: "transparent" }
            GradientStop { position: 1.0; color: Theme.withAlpha(Theme.bg, 0.55) }
        }
    }
    Rectangle {
        anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
        height: Math.max(1, page.u(2))
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: "transparent" }
            GradientStop { position: 0.5; color: Theme.withAlpha(Theme.accent, 0.5) }
            GradientStop { position: 1.0; color: "transparent" }
        }
    }
    Text {
        anchors.top: parent.top; anchors.right: parent.right; anchors.margins: page.u(24)
        text: "v" + Qt.application.version
        color: Theme.dimFg; opacity: 0.7
        font.family: Theme.hudFont; font.pixelSize: page.u(22); font.letterSpacing: 1
    }

    Item {
        id: cluster
        // the wordmark at one height on both boot pages (display → media paths
        // reads as one sequence), the cluster kept on screen when it's tall
        anchors.horizontalCenter: parent.horizontalCenter
        y: Math.max(Math.round(48 * page.s), Math.min(Math.round(parent.height * 0.3),
                                                      parent.height - height - Math.round(48 * page.s)))
        width: Math.min(page.u(820), parent.width - page.u(96))
        height: col.implicitHeight
        property real boot: 1
        opacity: boot
        transform: Translate { y: (1 - cluster.boot) * page.u(18) }
        NumberAnimation { id: bootAnim; target: cluster; property: "boot"; from: 0; to: 1
                          duration: DS.grand; easing.type: Easing.OutCubic }

        Column {
            id: col
            width: parent.width
            spacing: page.u(30)

            Column {   // the wordmark, as the display page strikes it
                width: parent.width
                spacing: page.u(11)
                Text {
                    text: "CODEC"
                    color: Theme.fg
                    font.family: Theme.codecFont
                    font.pixelSize: page.u(56)
                    font.letterSpacing: page.u(22)
                    font.weight: Font.Light
                }
                Rectangle {
                    width: page.u(250)
                    height: Math.max(2, page.u(2))
                    color: Theme.accent
                }
                Text {
                    text: "MEDIA SYSTEM"
                    color: Theme.dimFg
                    font.family: Theme.hudFont
                    font.pixelSize: page.u(24)
                    font.letterSpacing: page.u(6)
                }
            }

            Column {
                width: parent.width
                spacing: page.u(10)
                Text {
                    text: "CHOOSE MEDIA PATHS"
                    color: Theme.accent
                    font.family: Theme.codecFont
                    font.pixelSize: page.u(13)
                    font.letterSpacing: page.u(4)
                }
                Text {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: "The folders codec reads your films and shows from. Say what each one contains. Settings ▸ Library changes them later."
                    color: Theme.dimFg
                    font.family: Theme.hudFont
                    font.pixelSize: page.u(20)
                    font.letterSpacing: 1
                    lineHeight: 1.15
                }
            }

            Column {
                id: rows
                width: parent.width
                spacing: page.u(10)
                property int cascadeRev: 0
                property double cascadeAt: 0
                function fanIn() { cascadeAt = Date.now(); cascadeRev++ }

                Repeater {
                    model: page.roots
                    delegate: BootPlate {
                        required property var modelData
                        required property int index
                        k: page.s
                        fanView: rows
                        armed: page.visible
                        selected: page.idx === index
                        glyph: "▸"
                        label: App.prettyPath(modelData.path)
                        sub: page.counts[modelData.path] !== undefined ? page.counts[modelData.path] : "COUNTING..."
                        value: modelData.kind === "tv" ? "TV SHOWS" : "MOVIES"
                        onPointed: page.pointTo(index)
                        onClicked: { page.idx = index; page.activate() }
                    }
                }
                BootPlate {
                    k: page.s
                    fanView: rows
                    armed: page.visible
                    selected: page.idx === page.addRow
                    glyph: "+"
                    label: "ADD MEDIA PATH"
                    sub: page.roots.length === 0 ? "browse to a folder of films or shows" : "another folder - films and shows can live apart"
                    onPointed: page.pointTo(page.addRow)
                    onClicked: { page.idx = page.addRow; page.activate() }
                }
                BootPlate {
                    k: page.s
                    fanView: rows
                    armed: page.visible
                    selected: page.idx === page.hubRow
                    glyph: "▸"
                    label: "USE A CODEC HUB"
                    sub: "browse another codec's library on this network instead"
                    onPointed: page.pointTo(page.hubRow)
                    onClicked: { page.idx = page.hubRow; page.activate() }
                }
                BootPlate {
                    k: page.s
                    fanView: rows
                    armed: page.visible
                    selected: page.idx === page.doneRow
                    glyph: "▶"
                    label: page.roots.length === 0 ? "SKIP FOR NOW" : "CONTINUE"
                    sub: page.roots.length === 0 ? "YouTube works without any - add paths later in Settings"
                                                 : "scan " + (page.roots.length === 1 ? "this path" : "these " + page.roots.length + " paths") + " and open codec"
                    onPointed: page.pointTo(page.doneRow)
                    onClicked: { page.idx = page.doneRow; page.activate() }
                }
            }

            KeyHints {
                width: parent.width
                px: page.u(13)
                model: page.idx < page.roots.length
                       ? [["↑/↓", "SELECT"], ["⏎", "MOVIES / TV"], ["d", "REMOVE"], ["a", "ADD"], ["esc", "DISPLAY"]]
                       : [["↑/↓", "SELECT"], ["⏎", page.idx === page.addRow ? "BROWSE" : page.idx === page.hubRow ? "FIND HUBS" : "CONTINUE"],
                          ["a", "ADD"], ["esc", "DISPLAY"]]
            }
        }
    }

    HubFinder {
        id: hubs
        anchors.fill: parent
        k: page.s
        z: 10
        onClosed: page.forceActiveFocus()
    }

    FolderBrowser {
        id: browser
        anchors.fill: parent
        k: page.s
        z: 10
        onPicked: (path, kind) => {
            App.addMediaRoot(path, kind)         // mediaRootsChanged → refresh(), now
            page.idx = page.addRow               // the ADD row, under the new path
            page.forceActiveFocus()
        }
        onClosed: page.forceActiveFocus()
    }
}
