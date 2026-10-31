import QtQuick

// Boxed-keycap hint footer — the HOME/DETAIL keytip grammar (a bordered keycap
// + the action free-standing beside it) made reusable for the stage views
// (movies/tv/youtube/settings/player), which shipped a plain one-line hint bar
// while home/detail/stats had proper keycaps.
//
//   model  = [[key, action], …]   e.g. [["j/k","ROW"], ["⏎","PLAY"]]
//   perRow = 0  → left-aligned wrapping Flow (the default, full-width footers)
//          = N  → N keycaps per row, each row horizontally CENTERED (narrow
//                 panels like the queue, where a left Flow looks lopsided)
//
// Keycaps are MGS HUD when the face draws every character (it has ⏎ ␣ ⇧ ↑ … since
// the 2026-10 font extension); a key it can't draw stays on the mono glyph font,
// raw — folding into "RET"/"DEL" wrecks the cap box (the author 2026-08-28).
// The action text is mgs-hud (mgsSafe'd), matching the rest of the sweep.
Flow {
    id: kh
    property var model: []
    property int px: 13                        // keycap font size; box + action derive from it
    // On the CRT every legend reads at the home legend's 24 px (a 13 px cap is
    // 5-px letters on a tube); callers keep stating their desk size.
    // (A legend inside a fixed-width panel — the queue's 420 — opts out.)
    property bool crtGrow: true
    readonly property int fpx: crtGrow && App.mode === "crt" ? Math.round(px * 16 / 13) : px
    property color ink: Theme.dimFg
    property int perRow: 0                      // 0 = left Flow; N = centered rows of N
    spacing: Math.round(fpx * 1.25)

    // One key+action pair — reused by both the left Flow and the centered rows.
    // A cap that names ONE key ("d", "S", "⏎", "esc") is a real button: a click
    // presses that key on the focused view, exactly as the keyboard would
    // (App.pressKeyCap) — the codec rule that every keycap hint is clickable.
    // A cap like "J/K" names two keys and stays a label.
    Component {
        id: cap
        Item {
            id: capItem
            required property var modelData
            readonly property bool clickable: App.keyCapKey(modelData[0]) !== 0
            readonly property bool hot: clickable && capMouse.containsMouse
            implicitWidth: capRow.implicitWidth
            implicitHeight: capRow.implicitHeight
            width: implicitWidth
            height: implicitHeight
            MouseArea {
                id: capMouse
                anchors.fill: parent
                anchors.margins: -Math.round(kh.fpx * 0.3)   // a forgiving target
                enabled: capItem.clickable
                hoverEnabled: true
                cursorShape: capItem.clickable ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: App.pressKeyCap(capItem.modelData[0])
            }
        Row {
            id: capRow
            spacing: Math.round(kh.fpx * 0.42)
            Rectangle {                        // keycap
                anchors.verticalCenter: parent.verticalCenter
                width: capT.implicitWidth + Math.round(kh.fpx * 0.7)
                height: Math.round(kh.fpx * 1.55)
                radius: Math.round(kh.fpx * 0.25)
                color: Theme.withAlpha(Theme.bg, capItem.hot ? 0.7 : 0.45)
                border.width: 1
                border.color: Theme.withAlpha(Theme.fg, capItem.hot ? 0.5 : 0.18)
                Behavior on border.color { ColorAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                Text {
                    id: capT
                    // MGS HUD when it draws every character of the key (⏎ ↑ ⇧ / …
                    // are in the face now); else the mono glyph font, raw — never
                    // folded, a folded "DEL" would wreck the cap box
                    readonly property bool hud: Theme.mgsSafe(text) === text
                    anchors.centerIn: parent
                    anchors.verticalCenterOffset: hud ? 0 : 1   // mono glyphs sit high in the box
                    text: capItem.modelData[0]
                    color: Theme.withAlpha(Theme.fg, capItem.hot ? 0.95 : 0.6)
                    font.family: hud ? Theme.hudFont : Theme.monoFont
                    font.pixelSize: hud ? Math.round(kh.fpx * 1.5) : kh.fpx
                    font.letterSpacing: 1
                }
            }
            Text {                             // action
                anchors.verticalCenter: parent.verticalCenter
                text: Theme.mgsSafe(capItem.modelData[1])
                color: capItem.hot ? Theme.fg : kh.ink
                font.family: Theme.hudFont
                font.pixelSize: Math.round(kh.fpx * 1.5)
                font.letterSpacing: 1.5
            }
        }
        }
    }

    // Default: left-aligned wrapping Flow (items are direct Flow children).
    Repeater {
        model: kh.perRow > 0 ? [] : kh.model
        delegate: cap
    }

    // Centered mode: a column of horizontally-centred rows of `perRow` caps.
    Column {
        visible: kh.perRow > 0
        width: parent.width
        spacing: Math.round(kh.fpx * 0.6)
        Repeater {
            model: kh.perRow > 0 ? Math.ceil(kh.model.length / kh.perRow) : 0
            Row {
                required property int index
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Math.round(kh.fpx * 1.25)
                Repeater {
                    model: kh.model.slice(index * kh.perRow, (index + 1) * kh.perRow)
                    delegate: cap
                }
            }
        }
    }
}
