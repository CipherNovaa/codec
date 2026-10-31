import QtQuick

// One selectable row of the boot pages (CHOOSE DISPLAY, CHOOSE MEDIA PATHS) and
// the folder browser — the output picker's row, made reusable: a family-6 plate
// that lights on `selected` (MechSelectRow: the STATS rows' feel), a glyph, a
// two-line label (HUD 30 over HUD 18) centred on its INK on the plate's dark
// face, and on the right a VALUE in the codec face (MOVIES / TV, HD / 5:4 CRT).
// Lengths scale by `k`; the plate art keeps its whole-pixel size.
//
// The row's own fan-in (Cascade) reads `fanView` — the list's cascadeRev/At.
Item {
    id: row
    property real k: 1
    property string glyph: ""
    property string label: ""
    property string sub: ""
    property color subColor: Theme.dimFg
    property string value: ""
    property color valueColor: Theme.accent
    property bool selected: false
    property bool armed: true
    property real glass: App.glassLevel
    property Item fanView: null
    readonly property alias containsMouse: mouse.containsMouse
    signal pointed
    signal clicked

    function u(n) { return Math.round(n * k) }
    width: parent ? parent.width : 0
    height: u(50)

    Cascade { id: fan; view: row.fanView }
    opacity: fan.op

    // the label's ink centred on the plate face (the output picker's maths)
    readonly property int lineGap: -2
    FontMetrics { id: titleFm; font.family: Theme.hudFont; font.pixelSize: row.u(30) }
    FontMetrics { id: subFm; font.family: Theme.hudFont; font.pixelSize: row.u(18) }
    FontMetrics { id: valFm; font.family: Theme.codecFont; font.pixelSize: row.u(22) }
    readonly property real inkShift: {
        void titleFm.height; void subFm.height
        const r = titleFm.tightBoundingRect("H")
        const inkTop = titleFm.ascent + r.y
        const inkBottom = sub.length > 0 ? titleFm.height + lineGap + subFm.ascent
                                         : titleFm.ascent + r.y + r.height
        const boxH = sub.length > 0 ? titleFm.height + lineGap + subFm.height : titleFm.height
        return boxH / 2 - (inkTop + inkBottom) / 2
    }
    readonly property int valDrop: {
        void valFm.height
        const r = valFm.tightBoundingRect("H")
        return Math.round(valFm.height / 2 - (valFm.ascent + r.y + r.height / 2))
    }

    MechSelectRow {
        id: plate
        bleed: true   // its light edge on the column's text edge
        anchors.fill: parent
        selected: row.selected
        hovered: mouse.containsMouse
        glass: row.glass
        armed: row.armed
    }
    Item {
        anchors.fill: parent
        // centred on the plate's dark face, not the row (its lighter foot is below)
        transform: Translate { y: plate.hopY + plate.faceMid - plate.height / 2 + fan.dy }
        Row {
            id: left
            x: row.u(16)
            spacing: row.u(12)
            anchors.verticalCenter: parent.verticalCenter
            width: (valueText.visible ? valueText.x - row.u(20) : parent.width - row.u(16)) - x
            Text {
                id: glyphText
                visible: row.glyph.length > 0
                text: row.glyph
                width: row.u(20)                     // one column, whatever the glyph,
                horizontalAlignment: Text.AlignHCenter   // so every label starts level
                color: row.selected ? Theme.accent : Theme.dimFg
                Behavior on color { ColorAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                font.family: Theme.hudFont
                font.pixelSize: row.u(30)
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: row.inkShift
                    + (row.sub.length > 0 ? -(subFm.height + row.lineGap) / 2 : 0)
            }
            Column {
                spacing: row.lineGap
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: row.inkShift
                width: left.width - (glyphText.visible ? glyphText.width + left.spacing : 0)
                Text {
                    width: parent.width
                    text: Theme.mgsSafe(row.label)
                    color: row.selected ? Theme.fg : Theme.dimFg
                    Behavior on color { ColorAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                    font.family: Theme.hudFont
                    font.pixelSize: row.u(30)
                    font.letterSpacing: row.u(2)
                    elide: Text.ElideMiddle
                    style: Text.Raised; styleColor: "#000000"
                }
                Text {
                    width: parent.width
                    visible: row.sub.length > 0
                    text: Theme.mgsSafe(row.sub)
                    color: row.subColor
                    font.family: Theme.hudFont
                    font.pixelSize: row.u(18)
                    font.letterSpacing: row.u(1)
                    elide: Text.ElideMiddle
                    style: Text.Raised; styleColor: "#000000"
                }
            }
        }
        Text {
            id: valueText
            visible: row.value.length > 0
            anchors.right: parent.right
            anchors.rightMargin: row.u(16)
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: row.valDrop
            text: Theme.mgsSafe(row.value)
            color: row.valueColor
            font.family: Theme.codecFont
            font.pixelSize: row.u(22)
            font.letterSpacing: row.u(2)
        }
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onEntered: if (App.pointerActive) row.pointed()
        onClicked: row.clicked()
    }
}
