import QtQuick

// ADD MEDIA PATH — a folder browser in codec's own face, walked like the rest of
// codec (keys, the remote's D-pad, the mouse), not the system's file dialog.
// It starts at the PLACES (home, Videos, every mounted drive); ⏎ goes into a
// folder, h/← steps back up, and USE THIS FOLDER asks what's in it — Kodi's
// "this directory contains": MOVIES or TV SHOWS, suggested from a quick count
// of what's there. Then `picked(path, kind)`.
//
// Owned by the page that opens it (CHOOSE MEDIA PATHS, Settings ▸ LIBRARY).
FocusScope {
    id: fb
    property real k: 1
    property int bleed: 0
    visible: false
    signal picked(string path, string kind)
    signal closed

    function u(n) { return Math.round(n * k) }

    property string path: ""            // "" = the PLACES
    property var folders: []
    property bool loading: false
    property string landOn: ""          // stepping up lands on the folder you left
    property string page: "browse"      // browse | kind
    property int idx: 0                 // the row — on the kind page 0 MOVIES · 1 TV SHOWS
    // the current folder's count (probeFolder)
    property int pVideos: -1
    property int pEpisodes: 0
    property int pSeasons: 0
    property bool pCapped: false
    // films AND episodes side by side (~/Videos holding Films/ and Shows/): one
    // path can only be one kind, so say so and suggest neither
    readonly property bool mixed: pEpisodes >= 2 && pVideos - pEpisodes >= 2
    readonly property bool tvGuess: !mixed && (pSeasons > 0 || (pEpisodes > 0 && pEpisodes * 2 >= pVideos))
    readonly property string probeLine: {
        if (path === "") return ""
        if (pVideos < 0) return "COUNTING..."
        if (pVideos === 0) return "NO VIDEO FILES IN HERE"
        const n = pVideos + (pCapped ? "+" : "")
        if (mixed) return n + " VIDEOS · FILMS AND SHOWS MIXED - ADD EACH FOLDER ON ITS OWN"
        if (tvGuess) return n + " VIDEOS · " + (pSeasons > 0 ? pSeasons + " SEASON FOLDERS" : pEpisodes + " EPISODES") + " · LOOKS LIKE TV"
        return n + " VIDEOS · LOOKS LIKE MOVIES"
    }

    // the browse page's rows: USE THIS FOLDER and UP, then the subfolders —
    // or, at the top, the places
    readonly property int lead: path === "" ? 0 : 2
    readonly property int rowCount: page === "kind" ? 2 : lead + folders.length

    function open(start) {
        page = "browse"
        visible = true
        forceActiveFocus()
        Sfx.play("open")
        go(start || "", "")
    }
    function close() {
        if (!visible) return
        visible = false
        Sfx.play("back")
        closed()
    }
    function go(p, land) {
        path = p
        landOn = land || ""
        loading = true
        folders = []
        idx = 0
        pVideos = -1; pEpisodes = 0; pSeasons = 0; pCapped = false
        App.browseFolder(p)
        if (p !== "") App.probeFolder(p)
    }
    function up() {
        if (path === "") { Sfx.play("bump"); return }
        Sfx.play("back")
        go(App.parentFolder(path), path)
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
        if (page === "kind") {
            Sfx.play("select")
            visible = false
            picked(path, idx === 1 ? "tv" : "movies")
            return
        }
        if (loading && path !== "" && idx >= lead) return
        if (path !== "" && idx === 0) {            // USE THIS FOLDER → what's in it?
            Sfx.play("open")
            page = "kind"
            idx = tvGuess ? 1 : 0
            return
        }
        if (path !== "" && idx === 1) { up(); return }
        const f = folders[idx - lead]
        if (!f) return
        Sfx.play("select")
        go(f.path, "")
    }

    Connections {
        target: App
        function onFolderListed(p, list) {
            if (p !== fb.path) return
            fb.folders = list
            fb.loading = false
            if (fb.landOn !== "")
                for (let i = 0; i < list.length; i++)
                    if (list[i].path === fb.landOn) { fb.idx = i + fb.lead; break }
            listView.positionViewAtIndex(fb.idx, ListView.Center)
            listView.fanIn()
        }
        function onFolderProbed(p, videos, episodes, seasons, capped) {
            if (p !== fb.path) return
            fb.pVideos = videos; fb.pEpisodes = episodes; fb.pSeasons = seasons; fb.pCapped = capped
        }
    }

    Keys.onPressed: (event) => {
        switch (event.key) {
        case Qt.Key_Down: case Qt.Key_J: moveTo(idx + 1); break
        case Qt.Key_Up: case Qt.Key_K: moveTo(idx - 1); break
        case Qt.Key_PageDown: moveTo(idx + 8); break
        case Qt.Key_PageUp: moveTo(idx - 8); break
        case Qt.Key_Home: moveTo(0); break
        case Qt.Key_End: moveTo(rowCount - 1); break
        case Qt.Key_Return: case Qt.Key_Enter: activate(); break
        // h/l walk the tree, never choose (codec's rule: h/l only navigate)
        case Qt.Key_Right: case Qt.Key_L:
            if (page === "browse" && idx >= lead && folders[idx - lead]) { Sfx.play("move"); go(folders[idx - lead].path, "") }
            break
        case Qt.Key_Left: case Qt.Key_H: case Qt.Key_Backspace:
            if (page === "kind") { Sfx.play("back"); page = "browse"; idx = 0 }
            else up()
            break
        case Qt.Key_Escape:
            if (page === "kind") { Sfx.play("back"); page = "browse"; idx = 0 }
            else close()
            break
        default: break      // modal: nothing reaches the page underneath
        }
        event.accepted = true
    }

    Rectangle {
        anchors.fill: parent
        anchors.margins: -fb.bleed
        color: Theme.withAlpha(Theme.bg, 0.72)
        MouseArea { anchors.fill: parent; hoverEnabled: true; onClicked: fb.close() }
    }

    Panel {
        id: panel
        anchors.centerIn: parent
        width: Math.min(fb.u(980), parent.width - fb.u(80))
        height: body.implicitHeight + fb.u(44)
        color: Theme.withAlpha(Theme.bg, 0.96 * App.glassLevel)
        active: false
        border.width: 0
        MouseArea { anchors.fill: parent }   // a click on the panel isn't a click outside

        BorderImage {
            anchors.fill: parent
            source: (App.heroDevRev, App.heroDevPath("queue-tex") !== ""
                     ? App.heroDevPath("queue-tex") + "?v=" + App.heroDevRev
                     : "qrc:/assets/mechui/queue-tex.png")
            smooth: false
            opacity: App.glassLevel
            border { left: 8; right: 8; top: 8; bottom: 8 }
            horizontalTileMode: BorderImage.Stretch
            verticalTileMode: BorderImage.Stretch
        }

        Column {
            id: body
            anchors.fill: parent
            anchors.margins: fb.u(22)
            spacing: fb.u(14)

            Item {
                width: parent.width
                height: Math.max(heading.height, where.height)
                Text {
                    id: heading
                    text: fb.page === "kind" ? "THIS FOLDER CONTAINS" : "ADD MEDIA PATH"
                    color: Theme.accent
                    font.family: Theme.codecFont
                    font.pixelSize: fb.u(14)
                    font.letterSpacing: fb.u(5)
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    id: where
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(implicitWidth, parent.width - heading.width - fb.u(40))
                    horizontalAlignment: Text.AlignRight
                    elide: Text.ElideLeft
                    text: Theme.mgsSafe(fb.path === "" ? "PLACES" : App.prettyPath(fb.path))
                    color: Theme.dimFg
                    font.family: Theme.hudFont
                    font.pixelSize: fb.u(20)
                    font.letterSpacing: fb.u(2)
                }
            }

            // ── browse: USE THIS FOLDER · UP · the subfolders (or the places) ──
            ListView {
                id: listView
                visible: fb.page === "browse"
                width: parent.width
                readonly property int rowH: fb.u(50)
                readonly property int maxRows: Math.max(4, Math.min(9, Math.floor((fb.height * 0.62) / (rowH + spacing))))
                height: Math.max(1, Math.min(fb.rowCount, maxRows)) * (rowH + spacing) - spacing
                spacing: fb.u(6)
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                currentIndex: fb.idx
                highlightMoveDuration: 0
                onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
                property int cascadeRev: 0
                property double cascadeAt: 0
                function fanIn() { cascadeAt = Date.now(); cascadeRev++ }
                model: fb.rowCount
                delegate: BootPlate {
                    required property int index
                    readonly property var f: index >= fb.lead ? fb.folders[index - fb.lead] : null
                    width: listView.width
                    k: fb.k
                    fanView: listView
                    armed: fb.visible
                    selected: fb.idx === index
                    glyph: fb.path !== "" && index === 0 ? "+" : fb.path !== "" && index === 1 ? "◂" : "▸"
                    label: fb.path !== "" && index === 0 ? "USE THIS FOLDER"
                         : fb.path !== "" && index === 1 ? (App.parentFolder(fb.path) === "" ? "BACK TO PLACES" : "UP ONE LEVEL")
                         : f ? f.label : ""
                    sub: fb.path !== "" && index === 0 ? fb.probeLine
                       : fb.path !== "" && index === 1 ? (App.parentFolder(fb.path) === "" ? "" : App.prettyPath(App.parentFolder(fb.path)))
                       : f ? f.sub : ""
                    subColor: fb.path !== "" && index === 0 && fb.pVideos > 0 ? (fb.mixed ? Theme.warning : Theme.accent) : Theme.dimFg
                    onPointed: fb.pointTo(index)
                    onClicked: { fb.idx = index; fb.activate() }
                }
            }
            Text {   // an empty folder, or one still being read
                visible: fb.page === "browse" && fb.path !== "" && fb.folders.length === 0
                text: fb.loading ? "READING..." : "NO FOLDERS INSIDE"
                color: Theme.dimFg
                font.family: Theme.hudFont
                font.pixelSize: fb.u(20)
                font.letterSpacing: fb.u(2)
                leftPadding: fb.u(16)
            }

            // ── kind: MOVIES or TV SHOWS (Kodi's "this directory contains") ──
            Column {
                id: kindList
                visible: fb.page === "kind"
                width: parent.width
                spacing: fb.u(6)
                property int cascadeRev: 0
                property double cascadeAt: 0
                onVisibleChanged: if (visible) { cascadeAt = Date.now(); cascadeRev++ }
                Text {
                    width: parent.width
                    text: Theme.mgsSafe(fb.probeLine)
                    color: Theme.dimFg
                    elide: Text.ElideMiddle
                    font.family: Theme.hudFont
                    font.pixelSize: fb.u(18)
                    font.letterSpacing: fb.u(1)
                    bottomPadding: fb.u(6)
                }
                Repeater {
                    model: [["MOVIES", "one film per folder, or loose film files"],
                            ["TV SHOWS", "a folder per show, its seasons and episodes inside"]]
                    delegate: BootPlate {
                        required property var modelData
                        required property int index
                        width: kindList.width
                        k: fb.k
                        fanView: kindList
                        armed: fb.visible
                        selected: fb.idx === index
                        label: modelData[0]
                        sub: modelData[1]
                        value: fb.pVideos > 0 && !fb.mixed && (index === 1) === fb.tvGuess ? "SUGGESTED" : ""
                        onPointed: fb.pointTo(index)
                        onClicked: { fb.idx = index; fb.activate() }
                    }
                }
            }

            KeyHints {
                width: parent.width
                px: fb.u(13)
                model: fb.page === "kind"
                       ? [["↑/↓", "CHOOSE"], ["⏎", "ADD PATH"], ["esc", "BACK"]]
                       : [["↑/↓", "SELECT"], ["⏎", "OPEN"], ["←", "UP"], ["esc", "CANCEL"]]
            }
        }
    }
}
