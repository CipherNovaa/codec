import QtQuick

// Status pill: a DRAWN dot + mgs-hud label — replaces the old "● TEXT" Texts,
// since the MGS faces have no ● glyph (it floats/tofus). The label is auto-run
// through Theme.mgsSafe so it can carry ·/dashes/etc. Drop-in: set label/ink/px,
// plus any anchors/visible the old Text had.
Row {
    id: st
    property string label: ""
    property color ink: Theme.accent
    property int px: 20
    property bool dot: true          // hide for a dot-less state (e.g. "OFF")
    property bool pulse: false       // the dot BREATHES (a live broadcast)
    spacing: dot ? Math.round(px * 0.5) : 0
    Rectangle {
        id: dotRect
        visible: st.dot
        width: st.dot ? Math.round(st.px * 0.42) : 0; height: width; radius: width / 2
        color: st.ink
        anchors.verticalCenter: parent.verticalCenter
        // A slow breath, not a blink: 1 → 0.3 → 1 over ~2.4 s.
        SequentialAnimation on opacity {
            running: st.pulse && st.visible
            loops: Animation.Infinite
            NumberAnimation { to: 0.3; duration: 1200; easing.type: Easing.InOutSine }
            NumberAnimation { to: 1.0; duration: 1200; easing.type: Easing.InOutSine }
            onStopped: dotRect.opacity = 1
        }
    }
    Text {
        color: st.ink
        font.family: Theme.hudFont
        font.pixelSize: st.px
        font.letterSpacing: 2
        text: Theme.mgsSafe(st.label)
        anchors.verticalCenter: parent.verticalCenter
    }
}
