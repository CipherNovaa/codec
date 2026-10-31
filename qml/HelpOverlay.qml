import QtQuick

// '?' — the keymap.
//
// Grouped by CONTEXT, because the same key does different jobs depending on
// where you are: j/k walks a list while browsing but seeks while playing. A
// flat alphabetical list would hide that; these groups match the mental model
// of "where am I right now".
//
// The grid is responsive rather than a fixed 4-across row: column count and
// type scale both follow the window, so the CRT (1280x1024) and the 1440p
// panel get the same design instead of one being clipped. Content taller than
// the screen scrolls rather than bleeding off the bottom.
FocusScope {
    id: help
    // The CRT inset (Main's crtL..crtB): the scrim runs out under the tube's
    // overscan so the glass dims edge to edge, not inside a black frame.
    property int bleed: 0
    visible: false
    anchors.fill: parent

    // Same scale idiom as HomeView: derive everything from the window.
    readonly property real s: Math.max(0.85, Math.min(width / 1920, 1.2))
    readonly property int cols: width >= 1800 ? 4 : width >= 1200 ? 3 : width >= 820 ? 2 : 1
    readonly property int keyW: Math.round(126 * s)
    readonly property int colW: Math.round(330 * s)
    readonly property int fs: Math.round(12 * s)

    function close() { help.visible = false }

    // The overlay MUST hold the keyboard while it is up. Without this the
    // stage behind kept the focus, so esc dismissed *that* instead of the
    // help — and on a caps:swapescape keyboard, reaching for the other Esc
    // key toggles CAPS LOCK. Same class of bug as the queue panel in 0.9.1.
    focus: visible
    property bool sfxReady: false            // the built panel settling hidden isn't a close
    Component.onCompleted: sfxReady = true
    onVisibleChanged: {
        if (visible) forceActiveFocus()
        if (sfxReady) Sfx.play(visible ? "open" : "back")   // '?' (Main), any key or a click closes
    }
    Keys.onPressed: (event) => {
        // '?' is owned by the global Shortcut in Main (it toggles); letting it
        // ALSO close here would race the toggle and leave the overlay stuck.
        if (event.key === Qt.Key_Question)
            return
        help.close()
        event.accepted = true
    }

    // A binding on purpose: App.seekStep changes re-evaluate the whole map.
    readonly property var sections: [
        ["BROWSE", [
            ["j / k", "move"],
            ["h / l", "← →  (move only)"],
            ["⏎", "play · open"],
            ["hold ⏎", "context menu"],
            ["i", "title details"],
            ["/", "search everything"],
            ["1 – 5", "jump to section"],
            ["gg / G", "top · bottom"],
            ["ctrl+d / ctrl+u", "half page"],
            ["␣", "multi-select"],
            ["a / A", "queue current · selected"],
            ["o · f", "sort · genre  (library)"],
            ["m", "myth + top  (the x-files)"],
            ["← →  ·  [ ]", "sections  (settings)"],
            ["⏎ then ← →", "change a setting · ⏎ apply · esc cancel"],
            ["ctrl+r", "random pick"],
            ["t", "play trailer"],
            ["b", "bonus features"],
            ["f5", "update library (scan + art)"],
            ["w", "watch party  (start · join · end)"],
        ]],
        ["PLAYER", [
            ["␣ / k", "pause"],
            ["⏎", "skip intro  (when offered)"],
            ["h / l  ·  ← →", "seek " + App.seekStep + "s   (shift 60s)"],
            ["j  ·  ↑ ↓", "seek 60s"],
            [", .", "frame step"],
            ["pgup / pgdn", "chapter"],
            ["n / b", "next · prev"],
            ["a / s", "cycle audio · subtitles"],
            ["shift+s", "find subtitles online  (again: refetch)"],
            ["x / c", "subtitle delay + −  (remembered per film)"],
            ["c", "live chat  (live streams)"],
            ["⏎", "chat: type a message  (live)"],
            ["z", "screen  fit / zoom / stretch"],
            ["[ ]  ·  ⌫", "speed · reset"],
            ["9 / 0  ·  m", "volume · mute"],
            ["q", "queue over the video"],
            ["w", "watch party  (start · join · end)"],
            ["p / esc", "browse, keep playing"],
            ["␣", "cancel autoplay countdown"],
        ]],
        ["QUEUE  ·  CAST", [
            ["q", "open · close the queue"],
            ["⏎ · d", "play now · remove"],
            ["J / K", "reorder"],
            ["S · r · C", "shuffle · repeat · clear"],
            ["w · o", "save · load a queue"],
            ["t", "send queue to another device"],
            ["(auto)", "one queue on every codec"],
            ["c", "output picker  (cast)"],
            ["p", "cast remote  (while casting)"],
            ["s · a · z", "subs · audio · screen  (remote)"],
        ]],
        ["YOUTUBE", [
            ["⏎", "play  ·  open"],
            ["i", "the video's page"],
            ["hold ⏎", "menu  ·  pin a playlist"],
            ["v  ·  ␣", "select several  ·  hold ⏎ acts"],
            ["h / l  ·  [ ]", "tabs  ·  a channel's tabs"],
            ["↑ at the top", "play all  ·  shuffle"],
            ["/", "search  ·  ↓ recent"],
            ["f", "filters  ·  comment order"],
            ["esc", "back to the row left"],
            ["f5", "reload"],
        ]],
        ["DETAILS  ·  SYSTEM", [
            ["i", "open · close details"],
            ["j / k", "episodes  (shows)"],
            ["h / l", "more like this"],
            ["⏎", "play  ·  open recommendation"],
            ["w", "toggle watched"],
            ["b", "bonus features"],
            ["t · a · c", "trailer · queue · cast"],
            ["q", "queue panel"],
            ["p", "return to player (PiP)"],
            ["x", "stop background playback"],
            ["ctrl+h j k l", "move the PiP dock"],
            ["f11", "fullscreen toggle"],
            ["ctrl+q", "quit"],
        ]],
    ]

    // Full-bleed scrim: dims the stage AND swallows stray clicks. Sits above
    // the header strip (z 3) so nothing bleeds through the modal.
    z: 9
    Rectangle {
        anchors.fill: parent
        anchors.margins: -help.bleed
        color: Theme.withAlpha(Theme.bg, 0.93)
    }
    // Click anywhere to dismiss — the whole surface is the close button.
    MouseArea { anchors.fill: parent; onClicked: help.close() }

    Flickable {
        id: flick
        anchors.fill: parent
        contentHeight: card.height
        contentWidth: width
        // Only scrolls when the keymap genuinely exceeds the screen; otherwise
        // the card is centred and the page must not move at all.
        interactive: contentHeight > height
        clip: true

        // Card centres itself when it fits, sticks to the top when it doesn't
        // (scrolling from a floating midpoint feels broken).
        Rectangle {
            id: card
            readonly property int pad: Math.round(30 * help.s)
            width: Math.min(flick.width - Math.round(40 * help.s),
                            help.cols * help.colW
                            + (help.cols - 1) * Math.round(34 * help.s) + pad * 2)
            height: inner.height + pad * 2
            x: Math.round((flick.width - width) / 2)
            y: flick.contentHeight < flick.height
               ? Math.round((flick.height - height) / 2) : 0
            radius: 12
            color: Theme.withAlpha(Theme.surface, 0.96)
            border.color: Theme.border

            Column {
                id: inner
                x: card.pad
                y: card.pad
                width: card.width - card.pad * 2
                spacing: Math.round(20 * help.s)

                // ── Title bar ────────────────────────────────────────────
                Item {
                    width: parent.width
                    height: Math.round(34 * help.s)
                    Text {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: "KEYMAP"
                        color: Theme.fg
                        font.family: Theme.codecFont
                        font.pixelSize: Math.round(17 * help.s)
                        font.letterSpacing: Math.round(7 * help.s)
                    }
                    Text {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: "ANY KEY OR CLICK TO CLOSE"
                        color: Theme.accent
                        font.family: Theme.hudFont
                        font.pixelSize: Math.round(22 * help.s)
                        font.letterSpacing: Math.round(3 * help.s)
                    }
                    Rectangle {
                        anchors.bottom: parent.bottom
                        width: parent.width
                        height: 1
                        color: Theme.border
                    }
                }

                // ── Sections ─────────────────────────────────────────────
                Grid {
                    columns: help.cols
                    columnSpacing: Math.round(34 * help.s)
                    rowSpacing: Math.round(26 * help.s)

                    Repeater {
                        model: help.sections
                        delegate: Column {
                            required property var modelData
                            width: help.colW
                            spacing: Math.round(6 * help.s)

                            Text {
                                text: Theme.mgsSafe(modelData[0])
                                color: Theme.accent
                                font.family: Theme.hudFont
                                font.pixelSize: Math.round(22 * help.s)
                                font.letterSpacing: Math.round(4 * help.s)
                                bottomPadding: Math.round(6 * help.s)
                            }

                            Repeater {
                                model: modelData[1]
                                delegate: Row {
                                    required property var modelData
                                    spacing: Math.round(12 * help.s)
                                    // The key reads as a keycap so the eye can
                                    // scan the left rail without reading prose.
                                    Rectangle {
                                        width: help.keyW
                                        height: Math.round(21 * help.s)
                                        radius: 4
                                        color: Theme.surfaceHi
                                        border.color: Theme.border
                                        Text {
                                            anchors.centerIn: parent
                                            width: parent.width - 10
                                            horizontalAlignment: Text.AlignHCenter
                                            text: modelData[0]
                                            opacity: modelData[0] === "⏎" ? 0 : 1
                                            color: Theme.fg
                                            // MGS HUD when it draws the whole key; else the
                                            // mono glyph font, raw (⌫ — never folded to DEL)
                                            readonly property bool hud: Theme.mgsSafe(text) === text
                                            font.family: hud ? Theme.hudFont : Theme.monoFont
                                            font.pixelSize: hud ? Math.round(help.fs * 1.5) : help.fs
                                            elide: Text.ElideRight
                                        }
                                        ReturnGlyph {
                                            visible: modelData[0] === "⏎"
                                            anchors.centerIn: parent
                                            width: Math.round(9 * help.s)
                                            height: Math.round(8 * help.s)
                                            color: Theme.fg
                                        }
                                    }
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: help.colW - help.keyW
                                               - Math.round(12 * help.s)
                                        text: Theme.mgsSafe(modelData[1])
                                        color: Theme.dimFg
                                        font.family: Theme.hudFont
                                        font.pixelSize: help.fs * 2
                                        elide: Text.ElideRight
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
