import QtQuick

// A word on a family-3 plate — the info page's PLAY grammar, shared by the
// video page's plates and a channel's or playlist's header. The plate the
// keys are on (`lit`) or the pointer is over presses once and its word hops
// and brightens; a plate that is ON (subscribed, liked) keeps the accent
// while it isn't lit.
Item {
    id: ap
    property string label: ""
    property bool lit: false
    property bool on: false
    property int platePx: 2
    property int labelPx: 20
    // the press plays only while the view is on screen
    property bool live: true
    signal clicked()

    property bool hover: false
    readonly property bool shown: lit || hover
    property real hopY: 0
    width: 2 * Math.ceil((apLbl.implicitWidth + labelPx * 2) / 2)
    height: 40
    onShownChanged: if (shown && live) { apBtn.tap(); apHop.restart() }
    SequentialAnimation {
        id: apHop
        NumberAnimation { target: ap; property: "hopY"; to: DS.selDip(apBtn.height); duration: 90; easing.type: Easing.OutQuad }
        NumberAnimation { target: ap; property: "hopY"; to: 0; duration: 260; easing.type: Easing.OutBack }
    }
    MechButton {
        id: apBtn
        family: 3
        px: ap.platePx
        anchors.fill: parent
        hot: ap.shown
        pressed: apMouse.pressed
        opacity: ap.shown ? 1 : 0.7
        Behavior on opacity { NumberAnimation { duration: 120 } }
    }
    // the word's cap ink centred on the plate's dark face (re-read once the
    // codec face loads)
    FontMetrics { id: apFm; font: apLbl.font }
    readonly property rect capInk: (apFm.height, apFm.tightBoundingRect("H"))
    Text {
        id: apLbl
        anchors.horizontalCenter: parent.horizontalCenter
        y: Math.round(apBtn.faceMid - (apFm.ascent + ap.capInk.y + ap.capInk.height / 2))
        text: ap.label
        // lit = brightest (the accent read DIMMER than an idle white)
        color: ap.shown ? "#f2f7fa" : ap.on ? Theme.accent : Theme.dimFg
        Behavior on color { ColorAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
        font.family: Theme.codecFont
        font.pixelSize: ap.labelPx
        font.letterSpacing: 2
        transform: Translate { y: ap.hopY }
    }
    MouseArea {
        id: apMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onEntered: ap.hover = true
        onExited: ap.hover = false
        onClicked: ap.clicked()
    }
}
