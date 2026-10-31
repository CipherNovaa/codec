import QtQuick

// Launch flow: pick a display — the viewing mode follows the hardware
// (5:4 panel = CRT, anything else = HD). Pure keyboard. This is the first
// frame codec ever shows, so it boots like an instrument: a lit field, the
// wordmark struck in, and the displays as machined slots.
FocusScope {
    id: chooser

    property int displayIndex: 0
    readonly property var mons: App.monitors
    readonly property real s: Math.max(0.85, Math.min(width / 1680, 1.4))

    onVisibleChanged: if (visible) { forceActiveFocus(); bootAnim.restart(); slots.fanIn() }
    // The chooser is the FIRST view — it's visible from creation, so the boot
    // animation must also kick off on completion (visibleChanged won't fire).
    Component.onCompleted: { bootAnim.restart(); slots.fanIn() }

    function setIndex(i) {
        if (mons.length === 0) return
        displayIndex = (i + mons.length) % mons.length
    }
    // j/k: the list wraps, so only a single display can't move (bump)
    function step(dir) {
        const was = displayIndex
        setIndex(displayIndex + dir)
        Sfx.play(displayIndex === was ? "bump" : "move")
    }
    function confirm() {
        if (mons.length > 0) { Sfx.play("select"); App.chooseDisplay(mons[displayIndex].name) }
    }

    Keys.onPressed: (event) => {
        switch (event.key) {
        case Qt.Key_Down: case Qt.Key_J: step(1); break
        case Qt.Key_Up: case Qt.Key_K: step(-1); break
        case Qt.Key_1: setIndex(0); confirm(); break
        case Qt.Key_2: setIndex(1); confirm(); break
        case Qt.Key_3: setIndex(2); confirm(); break
        case Qt.Key_Return: case Qt.Key_Enter: case Qt.Key_Space: confirm(); break
        case Qt.Key_Escape: App.quit(); break
        default: return
        }
        event.accepted = true
    }

    // ── Lit field ────────────────────────────────────────────────────────
    // No opaque base: Main.qml owns the window fill (opaque in true fullscreen,
    // translucent for the windowed "rice look"). These washes just add depth.
    Rectangle {  // top-down instrument wash
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: Theme.withAlpha(Theme.fg, 0.07) }
            GradientStop { position: 0.42; color: "transparent" }
            GradientStop { position: 1.0; color: Theme.withAlpha(Theme.bg, 0.0) }
        }
    }
    Rectangle {  // foot vignette
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.7; color: "transparent" }
            GradientStop { position: 1.0; color: Theme.withAlpha(Theme.bg, 0.55) }
        }
    }
    // A faint accent breath along the very top — the machine is powered.
    Rectangle {
        anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
        height: Math.max(1, Math.round(2 * chooser.s))
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: "transparent" }
            GradientStop { position: 0.5; color: Theme.withAlpha(Theme.accent, 0.5) }
            GradientStop { position: 1.0; color: "transparent" }
        }
    }

    Text {
        anchors.top: parent.top; anchors.right: parent.right; anchors.margins: Math.round(24 * chooser.s)
        text: "v" + Qt.application.version
        color: Theme.dimFg; opacity: 0.7
        font.family: Theme.hudFont; font.pixelSize: Math.round(22 * chooser.s); font.letterSpacing: 1
    }

    // ── Boot cluster ─────────────────────────────────────────────────────
    Item {
        id: cluster
        // the wordmark at one height on both boot pages (display → media paths
        // reads as one sequence), the cluster kept on screen when it's tall
        anchors.horizontalCenter: parent.horizontalCenter
        y: Math.max(Math.round(48 * chooser.s), Math.min(Math.round(parent.height * 0.3),
                                                      parent.height - height - Math.round(48 * chooser.s)))
        width: Math.min(Math.round(820 * chooser.s), parent.width - Math.round(96 * chooser.s))  // CHOOSE MEDIA PATHS' width
        height: col.implicitHeight
        // Entrance: the whole cluster rises + fades in on show.
        property real boot: 0
        opacity: boot
        transform: Translate { y: (1 - cluster.boot) * Math.round(18 * chooser.s) }
        NumberAnimation { id: bootAnim; target: cluster; property: "boot"; from: 0; to: 1
                          duration: DS.grand; easing.type: Easing.OutCubic }

        Column {
            id: col
            width: parent.width
            spacing: Math.round(30 * chooser.s)

            // Wordmark
            Column {
                width: parent.width
                spacing: Math.round(11 * chooser.s)
                Text {
                    text: "CODEC"
                    color: Theme.fg
                    font.family: Theme.codecFont
                    font.pixelSize: Math.round(56 * chooser.s)
                    font.letterSpacing: Math.round(22 * chooser.s)
                    font.weight: Font.Light
                    Behavior on color { ColorAnimation { duration: 400 } }
                }
                Rectangle {  // accent rule draws itself in on boot
                    width: cluster.boot * Math.round(250 * chooser.s)
                    height: Math.max(2, Math.round(2 * chooser.s))
                    color: Theme.accent
                    Behavior on color { ColorAnimation { duration: 400 } }
                }
                Row {
                    spacing: Math.round(12 * chooser.s)
                    Text {
                        text: "MEDIA SYSTEM"
                        color: Theme.dimFg
                        font.family: Theme.hudFont
                        font.pixelSize: Math.round(24 * chooser.s)
                        font.letterSpacing: Math.round(6 * chooser.s)
                        Behavior on color { ColorAnimation { duration: 400 } }
                    }
                    Text {
                        text: "·"
                        color: Theme.withAlpha(Theme.fg, 0.4)
                        font.family: Theme.hudFont
                        font.pixelSize: Math.round(24 * chooser.s)
                    }
                    Text {
                        text: App.deviceRole
                        color: Theme.withAlpha(Theme.accent, 0.85)
                        font.family: Theme.hudFont
                        font.pixelSize: Math.round(24 * chooser.s)
                        font.letterSpacing: Math.round(4 * chooser.s)
                    }
                }
            }

            Text {
                text: "CHOOSE DISPLAY"
                color: Theme.accent
                font.family: Theme.codecFont
                font.pixelSize: Math.round(13 * chooser.s)
                font.letterSpacing: Math.round(4 * chooser.s)
                Behavior on color { ColorAnimation { duration: 400 } }
            }

            // Display slots — the mech plates every other list wears (the
            // rounded glass slots were the last of the old look).
            Column {
                id: slots
                width: parent.width
                spacing: Math.round(10 * chooser.s)
                property int cascadeRev: 0
                property double cascadeAt: 0
                function fanIn() { cascadeAt = Date.now(); cascadeRev++ }

                Repeater {
                    model: chooser.mons
                    delegate: BootPlate {
                        required property var modelData
                        required property int index
                        k: chooser.s
                        fanView: slots
                        armed: chooser.visible
                        selected: chooser.displayIndex === index
                        glyph: String(index + 1)
                        label: modelData.name
                        sub: modelData.width + "x" + modelData.height + "  @  " + modelData.refresh + " Hz"
                        value: modelData.crtLike ? "5:4 CRT" : "HD"
                        onPointed: {
                            if (chooser.displayIndex !== index) Sfx.play("move")
                            chooser.setIndex(index)
                        }
                        onClicked: { chooser.setIndex(index); chooser.confirm() }
                    }
                }
            }

            KeyHints {
                width: parent.width
                px: Math.round(13 * chooser.s)
                model: [["↑/↓", "SELECT"], ["⏎", "CONFIRM"], ["1-3", "JUMP"], ["esc", "QUIT"]]
            }
        }
    }
}
