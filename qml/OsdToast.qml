import QtQuick

// Small transient status notification ("ZOOM", "RESUMED · 1:02:11", …). Reuses the
// SAME plate as the 4K/HDR format badges (MechChip in badge mode → the generic
// badge-gen backing) so notifications read as codec hardware, not a web toast.
//
// Room talk (showChat) gets the OSD's own plate instead: the badge is one line
// tall by construction, so a real sentence ran straight off both ends of it.
// The chat plate wraps (up to four lines), and stays up long enough to read.
Item {
    id: toast

    property bool chatMode: false
    property string pending: ""     // a status line waiting for a chat line to be read
    readonly property real chatMaxW: Math.min(760, (parent ? parent.width : 1600) * 0.56)

    implicitWidth: chatMode ? chatPlate.width : chip.implicitWidth
    implicitHeight: chatMode ? chatPlate.height : chip.implicitHeight
    width: implicitWidth
    height: implicitHeight
    opacity: 0
    visible: opacity > 0

    function show(text) {
        // one poll's lines arrive together: [chat, "Ann joined"] used to replace
        // the chat plate at once, so the reading time never applied
        if (chatMode && opacity > 0 && hideTimer.running) {
            pending = text
            return
        }
        chatMode = false
        chip.text = Theme.mgsSafe(text)   // fold ·/▸/→/… so the mech face is safe
        hideTimer.interval = 1600
        opacity = 1
        hideTimer.restart()
    }

    function esc(t) {
        return String(t).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    }

    // who said it (in the accent, like the panel's transcript) and what they said
    function showChat(who, text) {
        pending = ""
        chatMode = true
        // the name in the HUD face, what they SAID in Departure Mono — a pixel
        // mono with real lowercase (the caps-only face shouted every line);
        // both escaped, so a guest's markup is only ever text
        chatText.text = (who ? "<span style=\"font-family:'" + Theme.codecFont + "'; font-size:20px; letter-spacing:2px; color:" + Theme.accent + "\">"
                               + esc(Theme.mgsSafe(String(who).toUpperCase())) + "</span>&nbsp;&nbsp;"
                             : "")
                        + "<span style=\"font-family:'Departure Mono'; font-size:16px; letter-spacing:0px\">"
                        + esc(text) + "</span>"
        // reading time: a short line ~2.6 s, longer ones more, never past 9 s
        hideTimer.interval = Math.max(2600, Math.min(9000, 1800 + 55 * String(text).length))
        opacity = 1
        hideTimer.restart()
    }

    MechChip {
        id: chip
        anchors.centerIn: parent
        visible: !toast.chatMode
        plateStyle: "badge"
        flag: ""              // no format flag → the generic badge-gen plate
        px: 2
        font.family: Theme.hudFont
        font.pixelSize: 20
        font.letterSpacing: 2
    }

    // the chat plate: the player OSD's osd-tex 9-slice over its dark glass,
    // sized to the words up to chatMaxW, then wrapping
    Item {
        id: chatPlate
        visible: toast.chatMode
        anchors.centerIn: parent
        readonly property int padX: 18
        readonly property int padY: 12
        width: Math.ceil(Math.min(toast.chatMaxW, chatMeasure.implicitWidth + 2 * padX))
        height: Math.ceil(chatText.implicitHeight + 2 * padY)
        Rectangle {
            anchors.fill: parent
            color: Qt.rgba(0.043, 0.063, 0.094, 0.86)
        }
        BorderImage {
            anchors.fill: parent
            source: (App.heroDevRev, App.heroDevPath("osd-tex") !== ""
                     ? App.heroDevPath("osd-tex") + "?v=" + App.heroDevRev
                     : "qrc:/assets/mechui/osd-tex.png")
            smooth: false
            border { left: 8; right: 8; top: 8; bottom: 8 }
            horizontalTileMode: BorderImage.Stretch
            verticalTileMode: BorderImage.Stretch
        }
        // the unwrapped width, so a short line gets a short plate
        Text {
            id: chatMeasure
            visible: false
            text: chatText.text
            textFormat: Text.RichText
            font: chatText.font
        }
        Text {
            id: chatText
            x: chatPlate.padX
            y: chatPlate.padY
            width: chatPlate.width - 2 * chatPlate.padX
            textFormat: Text.RichText
            wrapMode: Text.Wrap
            maximumLineCount: 4
            elide: Text.ElideRight
            lineHeight: 1.15
            color: "#e7ecf3"
            style: Text.Raised
            styleColor: "#05080e"
            font.family: Theme.hudFont
            font.pixelSize: 22
            font.letterSpacing: 1
        }
    }

    Timer {
        id: hideTimer
        interval: 1600
        onTriggered: {
            if (toast.pending !== "") {
                const t = toast.pending
                toast.pending = ""
                toast.chatMode = false
                toast.show(t)
                return
            }
            toast.opacity = 0
        }
    }

    Behavior on opacity { NumberAnimation { duration: 180 } }
}
