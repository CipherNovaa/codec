import QtQuick

// Keycap-chip legend rack — the dials-page legend pattern, made reusable for the
// forge/bay keytips. Pass `ed` (the MechEditor, for the theme resolvers) and
// `model` = [[key, action], …]. Theme is a global context property.
Item {
    id: leg
    property var ed
    property var legend: []
    readonly property int px: ed ? ed.px : 2
    height: flow.height + 8 * px

    Rectangle {
        anchors.fill: parent
        anchors.topMargin: 2 * leg.px
        color: Theme.withAlpha("#0d0b16", 0.82)
        border.width: 1
        border.color: Theme.withAlpha("#aecbd9", 0.22)
        radius: 2
    }
    Flow {
        id: flow
        anchors.horizontalCenter: parent.horizontalCenter
        y: 4 * leg.px
        width: leg.width - 8 * leg.px
        spacing: leg.ed ? leg.ed.fp(6) : 6
        Repeater {
            model: leg.legend
            Row {
                required property var modelData
                spacing: leg.ed ? leg.ed.fp(3) : 3
                Rectangle {  // keycap
                    anchors.verticalCenter: parent.verticalCenter
                    width: kk.implicitWidth + (leg.ed ? leg.ed.fp(6) : 6)
                    height: kk.implicitHeight + (leg.ed ? leg.ed.fp(3) : 3)
                    radius: 2
                    readonly property bool caps: !leg.ed || !leg.ed.sys || leg.ed.sys.keytipCaps
                    readonly property color acc: leg.ed ? leg.ed.sysColor() : "#5fcde4"
                    color: caps ? Theme.withAlpha(acc, 0.14) : "transparent"
                    border.width: 1
                    border.color: caps ? Theme.withAlpha(acc, 0.42) : "transparent"
                    Text {
                        id: kk
                        anchors.centerIn: parent
                        text: modelData[0]
                        color: leg.ed ? leg.ed.sysInk(leg.ed.sys ? leg.ed.sys.keyInk : "green") : "#8fe3a1"
                        font.family: leg.ed ? leg.ed.sysFont("keytipFont") : Theme.monoFont
                        font.bold: true
                        font.pixelSize: leg.ed ? leg.ed.ksz(9) : 9
                        font.letterSpacing: 1
                    }
                }
                Text {  // action
                    anchors.verticalCenter: parent.verticalCenter
                    text: Theme.mgsSafe(modelData[1])
                    color: Theme.withAlpha("#dce8ef", 0.7)
                    font.family: Theme.hudFont
                    font.pixelSize: leg.ed ? leg.ed.ksz(18) : 18
                    font.letterSpacing: 1
                }
            }
        }
    }
}
