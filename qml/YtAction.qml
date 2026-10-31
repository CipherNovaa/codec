import QtQuick

// One action on a YouTube page or header, drawn three ways:
//   "plate" — a word on a family-3 plate (YtPlate): ▶ PLAY, SUBSCRIBED, PIN…
//   "pill"  — YouTube's own red SUBSCRIBE (assets/mechui/plates/
//             yt-subscribe-*.png, rebuilt at its own pixels from the pixel-art
//             button the author found); a tree without that art (the public one)
//             draws a plate with the word instead
//   "icon"  — a pixel icon button (IconPlate) with its word or count beside
//             it: LIKE ▲ 1.7K, DISLIKE ▼ 27, SAVE +, MORE ☰
// `lit` = the keys are on it; `on` = a set toggle (subscribed, liked).
Item {
    id: act
    property string kind: "plate"
    property string label: ""
    property string icon: ""
    property bool lit: false
    property bool on: false
    property int platePx: 2
    property int labelPx: 20
    property bool live: true
    signal clicked()

    property bool hover: false
    readonly property bool shown: lit || hover
    readonly property string kindIs: kind === "pill" && pillArt.status !== Image.Ready ? "plate" : kind
    width: kindIs === "pill" ? pill.width : kindIs === "icon" ? iconRow.width : plate.width
    height: 40

    YtPlate {
        id: plate
        visible: act.kindIs === "plate"
        label: act.label
        lit: act.lit
        on: act.on
        live: act.live && visible
        platePx: act.platePx
        labelPx: act.labelPx
        onClicked: act.clicked()
    }

    // the red pill, its own art at the plates' pixel scale
    Item {
        id: pill
        visible: act.kindIs === "pill"
        width: 64 * act.platePx
        height: parent.height
        property bool tapping: false
        SequentialAnimation {
            id: pillTap
            PropertyAction { target: pill; property: "tapping"; value: true }
            PauseAnimation { duration: 120 }
            PropertyAction { target: pill; property: "tapping"; value: false }
        }
        Connections {
            target: act
            function onShownChanged() { if (act.shown && act.live && act.kindIs === "pill") pillTap.restart() }
        }
        // probes for the art even while hidden, so kindIs knows
        Image {
            id: pillArt
            visible: false
            source: "qrc:/assets/mechui/yt-subscribe-idle.png"
        }
        Image {
            anchors.verticalCenter: parent.verticalCenter
            width: 64 * act.platePx
            height: 17 * act.platePx
            source: "qrc:/assets/mechui/yt-subscribe-" + ((pillMouse.pressed || pill.tapping) ? "press"
                                                           : act.shown ? "hot" : "idle") + ".png"
            smooth: false
        }
        MouseArea {
            id: pillMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onEntered: act.hover = true
            onExited: act.hover = false
            onClicked: act.clicked()
        }
    }

    // an icon button and the word or count it carries
    Row {
        id: iconRow
        visible: act.kind === "icon"
        height: parent.height
        spacing: 10
        IconPlate {
            id: icon
            anchors.verticalCenter: parent.verticalCenter
            icon: act.icon
            lit: act.shown
            on: act.on
            held: iconMouse.pressed
            live: act.live && act.kind === "icon"
            px: act.platePx
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: -1
            visible: text.length > 0
            text: act.label
            color: act.shown ? "#f2f7fa" : act.on ? Theme.accent : Theme.dimFg
            Behavior on color { ColorAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
            font.family: Theme.codecFont
            font.pixelSize: act.labelPx
            font.letterSpacing: 2
        }
        // a little air after the word, so the next action doesn't crowd it
        Item { width: 6; height: 1 }
    }
    MouseArea {
        id: iconMouse
        anchors.fill: iconRow
        visible: act.kind === "icon"
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onEntered: act.hover = true
        onExited: act.hover = false
        onClicked: act.clicked()
    }
}
