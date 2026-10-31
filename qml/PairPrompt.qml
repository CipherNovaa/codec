import QtQuick

// "<NAME> WANTS TO JOIN" — a device on the network asked to use this hub
// (scripts/codec_pairing.py) and is waiting at its own screen for the answer.
// ALLOW gives it a key of its own; NOT NOW turns it away (it can ask again).
// Shown over whatever is on screen: someone just asked, from the next room.
FocusScope {
    id: pp
    property int bleed: 0
    readonly property var req: App.pairRequest
    visible: req && req.rid !== undefined
    readonly property real s: Math.max(0.85, Math.min(width / 1680, 1.4))
    function u(n) { return Math.round(n * s) }
    property int idx: 0                 // 0 ALLOW · 1 NOT NOW

    signal done
    onVisibleChanged: {
        if (visible) { idx = 0; forceActiveFocus(); Sfx.play("open"); rows.fanIn() }
        else done()
    }

    function kindWord(k) {
        return k === "laptop" ? "a laptop" : k === "desktop" ? "a desktop" : k === "phone" ? "a phone"
             : k === "tv" ? "a TV" : k === "browser" ? "a browser" : "a device"
    }
    function answer(allow) {
        Sfx.play(allow ? "select" : "back")
        App.answerPair(allow)
    }

    Keys.onPressed: (event) => {
        switch (event.key) {
        case Qt.Key_Down: case Qt.Key_J:
            Sfx.play(idx === 1 ? "bump" : "move"); idx = 1; break
        case Qt.Key_Up: case Qt.Key_K:
            Sfx.play(idx === 0 ? "bump" : "move"); idx = 0; break
        case Qt.Key_Return: case Qt.Key_Enter: answer(idx === 0); break
        case Qt.Key_Escape: answer(false); break
        default: break      // modal: the page behind keeps still
        }
        event.accepted = true
    }

    Rectangle {
        anchors.fill: parent
        anchors.margins: -pp.bleed
        color: Theme.withAlpha(Theme.bg, 0.72)
        MouseArea { anchors.fill: parent; hoverEnabled: true }
    }

    Panel {
        anchors.centerIn: parent
        width: Math.min(pp.u(820), parent.width - pp.u(80))
        height: body.implicitHeight + pp.u(44)
        color: Theme.withAlpha(Theme.bg, 0.96 * App.glassLevel)
        active: false
        border.width: 0

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
            anchors.margins: pp.u(22)
            spacing: pp.u(14)

            Text {
                text: "JOIN REQUEST"
                color: Theme.accent
                font.family: Theme.codecFont
                font.pixelSize: pp.u(14)
                font.letterSpacing: pp.u(5)
            }
            Text {
                width: parent.width
                text: Theme.mgsSafe((pp.req && pp.req.name ? pp.req.name : "A DEVICE").toUpperCase() + " WANTS TO JOIN")
                color: Theme.fg
                font.family: Theme.hudFont
                font.pixelSize: pp.u(32)
                font.letterSpacing: pp.u(2)
                elide: Text.ElideRight
                style: Text.Raised; styleColor: "#000000"
            }
            Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: Theme.mgsSafe(pp.kindWord(pp.req ? pp.req.kind : "") + " at " + (pp.req ? pp.req.ip : "")
                      + ". Allowed, it can browse this library, play from it and cast it — Settings ▸ Library lists it, and can take it back.")
                color: Theme.dimFg
                font.family: Theme.hudFont
                font.pixelSize: pp.u(18)
                font.letterSpacing: 1
                lineHeight: 1.15
            }

            Column {
                id: rows
                width: parent.width
                spacing: pp.u(8)
                property int cascadeRev: 0
                property double cascadeAt: 0
                function fanIn() { cascadeAt = Date.now(); cascadeRev++ }
                BootPlate {
                    k: pp.s
                    fanView: rows
                    armed: pp.visible
                    selected: pp.idx === 0
                    glyph: "+"
                    label: "ALLOW"
                    sub: "give it a key of its own"
                    onPointed: { if (pp.idx !== 0) Sfx.play("move"); pp.idx = 0 }
                    onClicked: pp.answer(true)
                }
                BootPlate {
                    k: pp.s
                    fanView: rows
                    armed: pp.visible
                    selected: pp.idx === 1
                    glyph: "-"
                    label: "NOT NOW"
                    sub: "turn it away — it can ask again"
                    onPointed: { if (pp.idx !== 1) Sfx.play("move"); pp.idx = 1 }
                    onClicked: pp.answer(false)
                }
            }

            KeyHints {
                width: parent.width
                px: pp.u(13)
                model: [["↑/↓", "CHOOSE"], ["⏎", pp.idx === 0 ? "ALLOW" : "NOT NOW"], ["esc", "NOT NOW"]]
            }
        }
    }
}
