import QtQuick

// One of the pixel icon buttons — a 5×6 sheet of 16-px buttons from the author's UI
// pack, recoloured to codec's steel (source-assets/ui/buttons → assets/
// mechui/icons/iconbtn-{idle,hot,press,on}.png; a 7th row holds an empty
// button, painted out of the plus). Frames: idle; lit (the keys
// or the pointer on it); press (held, or a tap from the keys); on (a toggle
// that is set — LIKED stays pressed in with its icon bright).
Item {
    id: ib
    property string icon: "play"
    property bool lit: false
    property bool on: false
    property bool held: false
    property int px: 2
    // the press plays only while the view is on screen
    property bool live: true

    // the sheet, row by row
    readonly property var cells: ({
        exit: 0, hanger: 1, play: 2, eject: 3, podium: 4,
        back: 5, pause: 6, menu: 7, music: 8, pad: 9,
        mute: 10, sound: 11, muted: 12, gear: 13, download: 14,
        undo: 15, close: 16, trophy: 17, mail: 18, heartEmpty: 19,
        check: 20, trash: 21, down: 22, up: 23, heart: 24,
        plus: 25, minus: 26, lock: 27, unlock: 28, info: 29,
        blank: 30          // a button with no icon (select mode's unchosen row)
    })
    readonly property int cell: cells[icon] !== undefined ? cells[icon] : 2
    property bool tapping: false
    function tap() { tapSeq.restart() }
    SequentialAnimation {
        id: tapSeq
        PropertyAction { target: ib; property: "tapping"; value: true }
        PauseAnimation { duration: 120 }
        PropertyAction { target: ib; property: "tapping"; value: false }
    }
    onLitChanged: if (lit && live) tap()

    width: 16 * px
    height: 16 * px
    Image {
        anchors.fill: parent
        source: "qrc:/assets/mechui/iconbtn-" + (ib.on ? "on" : (ib.held || ib.tapping) ? "press"
                                                 : ib.lit ? "hot" : "idle") + ".png"
        sourceClipRect: Qt.rect((ib.cell % 5) * 16, Math.floor(ib.cell / 5) * 16, 16, 16)
        smooth: false
    }
}
