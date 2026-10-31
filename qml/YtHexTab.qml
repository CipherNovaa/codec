import QtQuick

// One hexagon tab — the strip's YouTube tabs (family 7), for the tab rows
// inside YouTube: a video page's CHAPTERS · COMMENTS · RELATED, a channel's
// VIDEOS · SHORTS · LIVE · PLAYLISTS. The current tab rides the lit art,
// presses once and its label hops when it becomes current; `focused` (the
// keys are on this row) lights it fully.
Item {
    id: st
    property string label: ""
    property bool current: false
    property bool focused: false
    property int platePx: 2
    property int labelPx: 22
    property int pad: 56
    property bool live: true
    signal clicked()

    property bool hover: false
    property real hopY: 0
    // the label's INK box (implicitWidth carries the letter-spacing after the
    // last letter, which pulled every label left); an EVEN width, so the
    // plate's 2-px art grid keeps its last column
    FontMetrics { id: stInk; font: stLbl.font }
    readonly property rect ink: (stInk.height, stInk.tightBoundingRect(label))
    readonly property rect capInk: (stInk.height, stInk.tightBoundingRect("H"))
    width: 2 * Math.ceil((ink.width + pad) / 2)
    height: 40
    onCurrentChanged: if (current && live) { stBtn.tap(); stHop.restart() }
    SequentialAnimation {
        id: stHop
        NumberAnimation { target: st; property: "hopY"; to: DS.selDip(stBtn.height); duration: 90; easing.type: Easing.OutQuad }
        NumberAnimation { target: st; property: "hopY"; to: 0; duration: 260; easing.type: Easing.OutBack }
    }
    MechButton {
        id: stBtn
        family: 7
        px: st.platePx
        anchors.fill: parent
        pressed: stMouse.pressed
        hot: st.current || st.hover
        opacity: st.current ? (st.focused ? 1 : 0.85) : (st.hover ? 0.9 : 0.55)
        Behavior on opacity { NumberAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
    }
    Text {
        id: stLbl
        x: Math.round(st.width / 2 - (st.ink.x + st.ink.width / 2))
        // centred on the plate's DARK FACE (its lighter foot is below)
        y: Math.round(stBtn.faceMid - (stInk.ascent + st.capInk.y + st.capInk.height / 2))
        text: st.label
        color: st.current ? (st.focused ? "#f2f7fa" : Theme.accent) : Theme.dimFg
        Behavior on color { ColorAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
        font.family: Theme.codecFont
        font.pixelSize: st.labelPx
        font.letterSpacing: 2
        transform: Translate { y: st.hopY }
    }
    MouseArea {
        id: stMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onEntered: st.hover = true
        onExited: st.hover = false
        onClicked: st.clicked()
    }
}
