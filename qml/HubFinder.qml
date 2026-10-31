import QtQuick

// USE A CODEC HUB — a new machine's other way in: rather than its own media
// paths, browse another codec's library on this network. Lists the hubs heard
// (codec_hubs.py, zeroconf `_codec._tcp`), asks the one picked to join, and
// waits while someone presses ALLOW on that hub's screen (device pairing).
// Allowed, the library comes over and codec starts again as its satellite.
FocusScope {
    id: hf
    property real k: 1
    property int bleed: 0
    visible: false
    signal closed

    function u(n) { return Math.round(n * k) }

    property string page: "find"         // find | join
    property var hubs: []
    property bool searching: false
    property int idx: 0
    property string hubName: ""
    property string state_: ""
    property string why: ""
    readonly property int rowCount: hubs.length + 1      // the hubs, then SEARCH AGAIN

    function open() {
        page = "find"
        visible = true
        forceActiveFocus()
        Sfx.play("open")
        search()
    }
    function close() {
        if (!visible) return
        visible = false
        Sfx.play("back")
        closed()
    }
    function search() {
        searching = true
        hubs = []
        idx = 0
        App.findHubs()
    }
    function moveTo(i) {
        const n = Math.max(0, Math.min(rowCount - 1, i))
        Sfx.play(n === idx ? "bump" : "move")
        idx = n
    }
    function activate() {
        if (page !== "find" || searching) return
        if (idx >= hubs.length) { Sfx.play("select"); search(); return }
        const h = hubs[idx]
        Sfx.play("select")
        hubName = h.name
        state_ = "asking"
        why = ""
        page = "join"
        App.joinHub(h.url)
    }
    readonly property bool settled: state_ === "denied" || state_ === "expired" || state_ === "error"
    readonly property string headline: {
        const n = hubName.toUpperCase()
        switch (state_) {
        case "asking": return "ASKING " + n + "..."
        case "waiting": return "NOW PRESS ALLOW ON " + n
        case "allowed": return "JOINED " + n
        case "pulling": return "BRINGING THE LIBRARY OVER..."
        case "restarting": return "STARTING CODEC AS " + n + "'S SCREEN"
        case "denied": return n + " SAID NOT NOW"
        case "expired": return "THE REQUEST EXPIRED"
        default: return "COULD NOT REACH " + n
        }
    }
    readonly property string detail: {
        switch (state_) {
        case "waiting": return "the request shows on the hub's screen and waits two minutes"
        case "pulling": return "posters, details and the list of what's there"
        case "restarting": return "a moment"
        case "denied": case "expired": return "esc goes back to try again"
        case "error": return why.length > 0 ? why : "is it still sharing its library?"
        default: return ""
        }
    }

    Connections {
        target: App
        function onHubsFound(list) {
            hf.hubs = list
            hf.searching = false
            hf.idx = 0
            rows.fanIn()
        }
        function onJoinProgress(st, hub, why) {
            if (hub.length > 0) hf.hubName = hub
            hf.state_ = st
            hf.why = why
            if (st === "waiting") Sfx.play("open")
            else if (st === "allowed") Sfx.play("select")
            else if (st === "denied" || st === "expired" || st === "error") Sfx.play("back")
        }
    }

    Keys.onPressed: (event) => {
        switch (event.key) {
        case Qt.Key_Down: case Qt.Key_J: if (page === "find") moveTo(idx + 1); break
        case Qt.Key_Up: case Qt.Key_K: if (page === "find") moveTo(idx - 1); break
        case Qt.Key_Return: case Qt.Key_Enter: activate(); break
        case Qt.Key_Escape: case Qt.Key_Left: case Qt.Key_H:
            if (page === "join" && hf.settled) { Sfx.play("back"); page = "find"; search() }
            else if (page === "find") close()
            break
        default: break      // modal
        }
        event.accepted = true
    }

    Rectangle {
        anchors.fill: parent
        anchors.margins: -hf.bleed
        color: Theme.withAlpha(Theme.bg, 0.72)
        MouseArea { anchors.fill: parent; hoverEnabled: true; onClicked: if (hf.page === "find") hf.close() }
    }

    Panel {
        anchors.centerIn: parent
        width: Math.min(hf.u(860), parent.width - hf.u(80))
        height: body.implicitHeight + hf.u(44)
        color: Theme.withAlpha(Theme.bg, 0.96 * App.glassLevel)
        active: false
        border.width: 0
        MouseArea { anchors.fill: parent }

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
            anchors.margins: hf.u(22)
            spacing: hf.u(14)

            Text {
                text: hf.page === "find" ? "CODEC HUBS ON THIS NETWORK" : "JOINING A HUB"
                color: Theme.accent
                font.family: Theme.codecFont
                font.pixelSize: hf.u(14)
                font.letterSpacing: hf.u(5)
            }

            // ── find: the hubs heard, then SEARCH AGAIN ──
            Column {
                id: rows
                visible: hf.page === "find"
                width: parent.width
                spacing: hf.u(6)
                property int cascadeRev: 0
                property double cascadeAt: 0
                function fanIn() { cascadeAt = Date.now(); cascadeRev++ }
                Text {
                    visible: hf.searching || hf.hubs.length === 0
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: Theme.mgsSafe(hf.searching ? "LISTENING FOR CODEC HUBS..."
                          : "NO CODEC HUB HEARD. ON THE HUB: SETTINGS ▸ LIBRARY ▸ SHARE THIS LIBRARY.")
                    color: Theme.dimFg
                    font.family: Theme.hudFont
                    font.pixelSize: hf.u(20)
                    font.letterSpacing: hf.u(2)
                    bottomPadding: hf.u(6)
                }
                Repeater {
                    model: hf.hubs
                    delegate: BootPlate {
                        required property var modelData
                        required property int index
                        width: rows.width
                        k: hf.k
                        fanView: rows
                        armed: hf.visible
                        selected: hf.idx === index
                        glyph: "▸"
                        label: Theme.mgsSafe(modelData.name)
                        sub: modelData.host + ":" + modelData.port
                        onPointed: { if (hf.idx !== index) Sfx.play("move"); hf.idx = index }
                        onClicked: { hf.idx = index; hf.activate() }
                    }
                }
                BootPlate {
                    visible: !hf.searching
                    width: rows.width
                    k: hf.k
                    fanView: rows
                    armed: hf.visible
                    selected: hf.idx === hf.hubs.length
                    glyph: "+"
                    label: "SEARCH AGAIN"
                    sub: "listen for a few more seconds"
                    onPointed: { if (hf.idx !== hf.hubs.length) Sfx.play("move"); hf.idx = hf.hubs.length }
                    onClicked: { hf.idx = hf.hubs.length; hf.activate() }
                }
            }

            // ── join: what's happening ──
            Column {
                visible: hf.page === "join"
                width: parent.width
                spacing: hf.u(8)
                Text {
                    width: parent.width
                    text: Theme.mgsSafe(hf.headline)
                    color: hf.settled ? Theme.warning : Theme.fg
                    font.family: Theme.hudFont
                    font.pixelSize: hf.u(32)
                    font.letterSpacing: hf.u(2)
                    wrapMode: Text.WordWrap
                    style: Text.Raised; styleColor: "#000000"
                }
                Text {
                    visible: hf.detail.length > 0
                    width: parent.width
                    text: Theme.mgsSafe(hf.detail)
                    color: Theme.dimFg
                    font.family: Theme.hudFont
                    font.pixelSize: hf.u(18)
                    font.letterSpacing: 1
                    wrapMode: Text.WordWrap
                }
                MechStatus {
                    visible: !hf.settled
                    label: hf.state_ === "waiting" ? "WAITING" : "WORKING"
                    ink: Theme.accent
                    px: hf.u(20)
                    pulse: true
                }
            }

            KeyHints {
                width: parent.width
                px: hf.u(13)
                model: hf.page === "find"
                       ? [["↑/↓", "SELECT"], ["⏎", hf.idx < hf.hubs.length ? "JOIN" : "SEARCH"], ["esc", "BACK"]]
                       : hf.settled ? [["esc", "BACK"]] : []
            }
        }
    }
}
