import QtQuick

// Live-stream chat rail ("c" in the player while a live stream plays).
// Same panel language as the queue sidebar: translucent instrument panel
// sliding in from the right, video keeps playing underneath. Read-only by
// design — codec is a viewing appliance, not a keyboard.
Item {
    id: rail

    property bool open: false
    // The player OSD's fixed palette (PlayerView osdFg/osdDim/osdSteel/osdLine)
    // and its glass dial — the chat matches the bar it sits above.
    readonly property real glass: App.glassLevel
    readonly property color fg: "#e7ecf3"
    readonly property color dim: "#9aa4b2"
    readonly property color steel: "#a6b1c7"
    readonly property color line: "#3a4553"
    // The compose box is see-through like the plate behind it (glass dial).
    readonly property color surf: Qt.rgba(0.043, 0.063, 0.094, 0.30 * glass)
    readonly property color surfHi: Qt.rgba(0.10, 0.12, 0.16, 0.45 * glass)
    property double slideX: open ? 0 : width + 40
    // True while the compose box holds the keyboard. The player hands focus
    // here and takes it back when composing ends.
    property bool composing: false
    property string sendError: ""
    signal composeEnded

    // UI sounds: dropping into the box (⏎ in the player, a click) selects and
    // leaving it (esc, ⏎ on nothing) is back; what you type and send is silent.
    // The rail's own open/close sounds from the player's `c`.
    function startCompose() {
        if (!open)
            return
        Sfx.play("select")
        composing = true
        composeInput.forceActiveFocus()
    }
    function stopCompose() {
        composing = false
        composeInput.focus = false
        ac.words = []
        composeEnded()
    }

    // Deterministic author tint: hash -> hue, muted to sit inside the theme.
    function authorColor(name) {
        let h = 0
        for (let i = 0; i < name.length; i++)
            h = (h * 31 + name.charCodeAt(i)) % 360
        return Qt.hsla(h / 360, 0.45, 0.68, 1)
    }

    function badgeGlyph(b) {
        if (b === "mod") return "󰒓"
        if (b === "owner") return "★"
        if (b === "verified") return "󰄬"
        if (b === "member") return "󰀄"
        return ""
    }

    x: parent.width - width - 24 + slideX
    visible: slideX < width
    // The feed fills in the background while the rail is hidden; opening it
    // lands on the newest message, following again.
    onOpenChanged: if (open) {
        chatList.pinned = true
        Qt.callLater(() => chatList.positionViewAtEnd())
    }
    Behavior on slideX {
        NumberAnimation { duration: 220; easing.type: Easing.OutExpo }
    }

    // Same plate as the player OSD (fixed palette, osd-tex 9-slice, the glass
    // dial), square-cornered — the chat is part of the OSD family, not a
    // pywal-themed card floating over the picture.
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0.043, 0.063, 0.094, 0.84 * rail.glass)
        radius: 0
        BorderImage {
            anchors.fill: parent
            source: (App.heroDevRev, App.heroDevPath("osd-tex") !== ""
                     ? App.heroDevPath("osd-tex") + "?v=" + App.heroDevRev
                     : "qrc:/assets/mechui/osd-tex.png")
            smooth: false
            opacity: rail.glass
            border { left: 8; right: 8; top: 8; bottom: 8 }
            horizontalTileMode: BorderImage.Stretch
            verticalTileMode: BorderImage.Stretch
        }

        Column {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 10

            // Header
            Item {
                width: parent.width
                height: 22
                Row {
                    spacing: 8
                    anchors.verticalCenter: parent.verticalCenter
                    Rectangle {
                        width: 8; height: 8; radius: 4
                        anchors.verticalCenter: parent.verticalCenter
                        color: "#e5484d"
                        SequentialAnimation on opacity {
                            running: rail.visible
                            loops: Animation.Infinite
                            NumberAnimation { from: 1; to: 0.25; duration: 900 }
                            NumberAnimation { from: 0.25; to: 1; duration: 900 }
                        }
                    }
                    Text {
                        text: "LIVE CHAT"
                        color: rail.steel
                        font.family: Theme.codecFont
                        font.pixelSize: 14
                        font.letterSpacing: 5
                    }
                }
                Text {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: LiveChat.count > 0 ? LiveChat.count + " MSG" : ""
                    color: rail.dim
                    font.family: Theme.hudFont
                    font.pixelSize: 20
                    font.letterSpacing: 1
                }
            }

            Rectangle { width: parent.width; height: 1; color: rail.line }

            ListView {
                id: chatList
                width: parent.width
                // Reserve the compose box's real height below (+ the Column
                // spacing) so it's never squished off the panel's bottom edge.
                height: parent.height - y - composeCol.height - parent.spacing
                model: LiveChat
                clip: true
                spacing: 6
                boundsBehavior: Flickable.StopAtBounds
                // Pinned to the newest message unless the user scrolled back
                // (mouse wheel reading history must not fight the stream).
                property bool pinned: true
                onMovementEnded: pinned = atYEnd
                // Follow on every INSERT, not on count: once the chat reaches
                // its cap each new line evicts the oldest, the count stops
                // changing, and following silently stopped on any busy chat.
                Connections {
                    target: LiveChat
                    function onRowsInserted() {
                        if (chatList.pinned)
                            Qt.callLater(() => chatList.positionViewAtEnd())
                    }
                    function onModelReset() {
                        chatList.pinned = true
                        Qt.callLater(() => chatList.positionViewAtEnd())
                    }
                }

                delegate: Column {
                    required property string author
                    required property string message
                    required property var badges
                    required property string amount
                    required property int index
                    readonly property bool superchat: amount.length > 0

                    width: chatList.width
                    spacing: 2

                    // Superchat banner row
                    Rectangle {
                        visible: superchat
                        width: parent.width
                        height: superRow.height + 10
                        radius: 0
                        color: Theme.withAlpha(rail.steel, 0.12)
                        border.color: rail.steel
                        border.width: 1
                        Row {
                            id: superRow
                            x: 8; y: 5
                            spacing: 8
                            Text {
                                text: Theme.mgsSafe(amount)
                                color: rail.steel
                                font.family: Theme.hudFont
                                font.pixelSize: 22
                                font.letterSpacing: 1
                            }
                            Text {
                                text: Theme.mgsSafe(author)
                                color: rail.authorColor(author)
                                font.family: Theme.hudFont
                                font.pixelSize: 22
                            }
                        }
                    }

                    Text {
                        visible: !superchat || message.length > 0
                        width: parent.width
                        // RichText (not StyledText) so custom-emoji <img> tags
                        // render — the worker sends them as \x01<localpath>\x01
                        // markers inside the message.
                        textFormat: Text.RichText
                        text: {
                            const esc = (s) => s.replace(/&/g, "&amp;")
                                               .replace(/</g, "&lt;")
                                               .replace(/>/g, "&gt;")
                            // Split on the emoji markers: even chunks are text
                            // to escape, odd chunks are local image paths.
                            function body(s) {
                                const M = String.fromCharCode(1)
                                const re = new RegExp(M + "([^" + M + "]*)" + M)
                                const parts = s.split(re)
                                let out = ""
                                for (let i = 0; i < parts.length; i++)
                                    out += i % 2 === 0 ? esc(parts[i])
                                        // escape the emoji-path chunk too: a
                                        // forged U+0001 marker could otherwise
                                        // smuggle guest markup into this RichText
                                        : "<img src=\"file://" + esc(parts[i]).replace(/"/g, "%22")
                                          + "\" width=\"18\" height=\"18\">"
                                return out
                            }
                            let head = ""
                            for (const b of badges) {
                                const g = rail.badgeGlyph(b)
                                if (g) head += "<font color=\"" + rail.steel + "\">" + esc(g) + "</font> "
                            }
                            return head
                                + "<font color=\"" + rail.authorColor(author) + "\">"
                                + esc(author) + "</font>  "
                                + "<font color=\"" + rail.fg + "\">" + body(message) + "</font>"
                        }
                        color: rail.fg
                        font.family: Theme.uiFont
                        font.pixelSize: 12
                        wrapMode: Text.Wrap
                        maximumLineCount: 4
                        elide: Text.ElideRight
                    }
                }

                // Connection state / empty chat
                Text {
                    anchors.centerIn: parent
                    width: parent.width - 20
                    visible: LiveChat.status.length > 0
                    text: Theme.mgsSafe(LiveChat.status)
                    color: rail.dim
                    font.family: Theme.hudFont
                    font.pixelSize: 22
                    font.letterSpacing: 2
                    wrapMode: Text.Wrap
                    horizontalAlignment: Text.AlignHCenter
                }
            }

            // ── Compose box ───────────────────────────────────────────────
            // Post to the chat via the official Data API (@-autocomplete from
            // recent chatters). Sends stay in the box (native-chat feel).
            Column {
                id: composeCol
                width: parent.width
                spacing: 6

                Connections {
                    target: LiveChat
                    function onSendResult(ok, error) {
                        if (ok) {
                            composeInput.text = ""
                            rail.sendError = ""
                        } else {
                            rail.sendError = error
                        }
                    }
                    function onAuthResult(ok, error) {
                        if (error === "__STARTED__")
                            rail.sendError = "opening browser to connect youtube…"
                        else if (ok)
                            rail.sendError = "youtube connected — try sending again"
                        else
                            rail.sendError = "connect failed: " + error
                    }
                }
                // Whether the current error is the "needs one-time setup" nudge.
                readonly property bool needsSetup:
                    rail.sendError.indexOf("setup") >= 0
                    || rail.sendError.indexOf("--auth") >= 0

                // @-mention suggestions (newest chatters matching the fragment)
                Flow {
                    id: ac
                    property var words: []
                    width: parent.width
                    spacing: 6
                    visible: words.length > 0 && rail.composing
                    Repeater {
                        model: ac.words
                        delegate: Rectangle {
                            required property string modelData
                            required property int index
                            height: 20
                            width: acLabel.width + 14
                            radius: 0
                            color: index === 0 ? rail.surfHi : "transparent"
                            border.color: index === 0 ? rail.steel : rail.line
                            Text {
                                id: acLabel
                                anchors.centerIn: parent
                                text: Theme.mgsSafe("@" + modelData)
                                color: index === 0 ? rail.steel : rail.dim
                                font.family: Theme.hudFont
                                font.pixelSize: 20
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: composeInput.completeMention(modelData)
                            }
                        }
                    }
                }

                Rectangle {
                    width: parent.width
                    height: 46
                    radius: 0
                    color: rail.composing ? rail.surfHi : rail.surf
                    border.width: 1
                    border.color: rail.composing ? rail.steel
                                  : (rail.sendError.length > 0 ? Theme.warning : rail.line)
                    Behavior on border.color { ColorAnimation { duration: 140 } }
                    Behavior on color { ColorAnimation { duration: 140 } }

                    MouseArea {  // click the bar to start composing
                        anchors.fill: parent
                        enabled: !rail.composing
                        cursorShape: Qt.IBeamCursor
                        onClicked: rail.startCompose()
                    }

                    Row {
                        anchors.fill: parent
                        anchors.leftMargin: 14
                        anchors.rightMargin: 12
                        spacing: 10

                        Text {  // leading chat glyph
                            anchors.verticalCenter: parent.verticalCenter
                            text: "󰭹"
                            color: rail.composing ? rail.steel : rail.dim
                            font.family: Theme.monoFont
                            font.pixelSize: 16
                        }

                        Item {
                            width: parent.width - 26 - sendGlyph.width - parent.spacing * 2
                            height: parent.height

                            TextInput {
                                id: composeInput
                                anchors.fill: parent
                                verticalAlignment: TextInput.AlignVCenter
                                color: rail.fg
                                // Iosevka, not the MGS face: the MGS fonts are
                                // caps-only, so you couldn't tell what case
                                // you were typing (or whether caps lock was on).
                                font.family: "Departure Mono"   // pixel mono with real lowercase
                                // Its native 11px grid: 8px caps — the same as the
                                // MGS "MESSAGE…" prompt (measured), and pixel-crisp.
                                font.pixelSize: 11
                                clip: true
                                enabled: rail.composing
                                maximumLength: 200

                                // The @-fragment currently being typed (word
                                // under the cursor starting with @), or null.
                                function mentionFragment() {
                                    const left = text.slice(0, cursorPosition)
                                    const m = left.match(/@([^\s@]*)$/)
                                    return m ? m[1] : null
                                }
                                function completeMention(name) {
                                    const left = text.slice(0, cursorPosition)
                                    const rest = text.slice(cursorPosition)
                                    const at = left.lastIndexOf("@")
                                    text = left.slice(0, at) + "@" + name + " " + rest
                                    cursorPosition = at + name.length + 2
                                    ac.words = []
                                }
                                onTextChanged: {
                                    rail.sendError = ""
                                    const frag = mentionFragment()
                                    ac.words = frag !== null
                                               ? LiveChat.mentionCandidates(frag) : []
                                }
                                Keys.onPressed: (event) => {
                                    if (event.key === Qt.Key_Escape) {
                                        Sfx.play("back")
                                        rail.stopCompose()
                                        event.accepted = true
                                    } else if (event.key === Qt.Key_Tab && ac.words.length > 0) {
                                        completeMention(ac.words[0])
                                        event.accepted = true
                                    } else if (event.key === Qt.Key_Return
                                               || event.key === Qt.Key_Enter) {
                                        if (ac.words.length > 0) {
                                            completeMention(ac.words[0])
                                        } else if (text.trim().length > 0) {
                                            LiveChat.sendMessage(text)
                                        } else {
                                            Sfx.play("back")
                                            rail.stopCompose()
                                        }
                                        event.accepted = true
                                    }
                                }
                                Text {  // placeholder
                                    anchors.fill: parent
                                    verticalAlignment: Text.AlignVCenter
                                    visible: composeInput.text.length === 0
                                    text: Theme.mgsSafe("message…")
                                    color: rail.dim
                                    font.family: Theme.hudFont   // the prompt stays MGS;
                                    font.pixelSize: 26           // what you TYPE is Iosevka
                                    elide: Text.ElideRight
                                }
                            }
                        }

                        Text {  // send affordance (lit once there's text)
                            id: sendGlyph
                            anchors.verticalCenter: parent.verticalCenter
                            text: "⏎"   // return: ⏎ sends
                            // Same white as the text, dimmed until there is
                            // something to send.
                            color: rail.fg
                            opacity: composeInput.text.trim().length > 0 ? 1 : 0.55
                            font.family: Theme.hudFont
                            font.pixelSize: 44
                            MouseArea {
                                anchors.fill: parent
                                anchors.margins: -6
                                enabled: composeInput.text.trim().length > 0
                                cursorShape: Qt.PointingHandCursor
                                onClicked: LiveChat.sendMessage(composeInput.text)
                            }
                        }
                    }
                }

                // Hint / error line under the box, with a CONNECT affordance
                // when sending needs the one-time OAuth setup.
                Row {
                    width: parent.width
                    spacing: 8
                    // Idle there is nothing to say: the box itself is the cue.
                    visible: rail.sendError.length > 0 || rail.composing || composeCol.needsSetup
                    Text {
                        width: composeCol.needsSetup
                               ? parent.width - connectBtn.width - 8 : parent.width
                        text: Theme.mgsSafe(rail.sendError.length > 0 ? "⚠ " + rail.sendError
                              : rail.composing ? "@ mentions · ⏎ send · esc done" : "")
                        color: rail.sendError.length > 0 ? Theme.warning : rail.dim
                        font.family: Theme.hudFont
                        font.pixelSize: 18
                        font.letterSpacing: 1
                        wrapMode: Text.Wrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
                    }
                    Rectangle {
                        id: connectBtn
                        visible: composeCol.needsSetup
                        width: connectLabel.width + 16
                        height: 18
                        radius: 0
                        color: rail.surfHi
                        border.color: rail.steel
                        Text {
                            id: connectLabel
                            anchors.centerIn: parent
                            text: "CONNECT"
                            color: rail.steel
                            font.family: Theme.hudFont
                            font.pixelSize: 18
                            font.letterSpacing: 1
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { Sfx.play("select"); LiveChat.connectYouTube() }
                        }
                    }
                }
            }
        }
    }
}
