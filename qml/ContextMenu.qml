import QtQuick

// Hold-Enter context menu — a keyboard-first action list for the selected
// item. Views fill `entries` ([{label, hint}]) and react to picked(index).
// A row with `input: true` (and a `placeholder`) is typed into: ⏎ opens it as
// a field, ⏎ again hands the words to typed(index, text), esc puts it back.
FocusScope {
    id: menu

    property string title: ""
    readonly property int bleed: 8
    readonly property int rowH: 45
    readonly property int rowGap: 4
    property var entries: []
    property int idx: 0
    // The key that opened this menu closes it again (f for FILTERS — the way c
    // opens and shuts the display picker). 0 = none. `toggledShut` tells the
    // host the menu was shut by that key, so a submenu doesn't step back up.
    property int closeKey: 0
    property bool toggledShut: false
    // How far this menu's parent sits below the window top (the global header
    // strip). The dim scrim + panel extend up by it so the fade covers the WHOLE
    // screen, not just the view below the header. Set by the host view.
    property real topBleed: 0
    // Glassy backing like the queue panel — the bg fill, the queue-tex frame and
    // the row plates all render at this opacity so the backdrop bleeds through.
    // A touch more translucent than the queue's 0.65.
    property real glass: App.glassLevel
    signal picked(int index)
    signal typed(int index, string text)
    signal closed()
    property int typingAt: -1           // the input row being typed into, or -1

    visible: false

    // Live-editable 9-slice: dev-tree PNG (cache-busted on save) else the baked
    // qrc. Same contract as the queue/search frames.
    function devSrc(rel) {
        var d = App.heroDevPath(rel)
        return d !== "" ? d + "?v=" + App.heroDevRev : "qrc:/assets/mechui/" + rel + ".png"
    }

    // A row with `header: true` is a non-selectable group label (FORMAT / GENRE):
    // it renders dim and the j/k nav + Enter skip over it.
    function isHeader(i) {
        return i >= 0 && i < entries.length && entries[i] && entries[i].header === true
    }
    function firstSelectable() {
        for (let i = 0; i < entries.length; i++)
            if (!isHeader(i)) return i
        return 0
    }
    function step(dir) {
        if (entries.length === 0) return
        let i = idx
        for (let n = 0; n < entries.length; n++) {
            i = (i + dir + entries.length) % entries.length
            // UI sounds: a step that lands back on itself (one row) can't move
            if (!isHeader(i)) { Sfx.play(i === idx ? "bump" : "move"); idx = i; return }
        }
    }

    function openMenu(t, list, key) {
        title = t
        typingAt = -1
        entries = list
        closeKey = key || 0
        toggledShut = false
        idx = firstSelectable()
        lv.positionViewAtBeginning()
        visible = true
        forceActiveFocus()
        lv.fanIn()
        Sfx.play("open")   // a pick that opens a submenu: its select outranks this
    }

    // the field's ⏎: words go out (an empty field just steps back)
    function commitTyping(text) {
        const i = typingAt
        typingAt = -1
        if (text.trim().length === 0) { Sfx.play("back"); forceActiveFocus(); return }
        Sfx.play("select")
        visible = false
        focus = false
        typed(i, text.trim())
        closed()
    }
    function cancelTyping() { Sfx.play("back"); typingAt = -1; forceActiveFocus() }

    function close() {
        Sfx.play("back")
        visible = false
        focus = false // release the scope's focus memory or it eats every key
        closed()
    }

    Keys.onPressed: (event) => {
        if (typingAt >= 0) { event.accepted = true; return }   // the field has the keys
        if (closeKey !== 0 && event.key === closeKey) {
            if (!event.isAutoRepeat) { toggledShut = true; close() }
            event.accepted = true
            return
        }
        switch (event.key) {
        case Qt.Key_Down: case Qt.Key_J:
            menu.step(1)
            lv.positionViewAtIndex(idx, ListView.Contain)
            break
        case Qt.Key_Up: case Qt.Key_K:
            menu.step(-1)
            lv.positionViewAtIndex(idx, ListView.Contain)
            break
        // ⏎ only: l (vim's →) used to fire the row — PLAY, CAST… — and h/l
        // are navigation keys everywhere now
        case Qt.Key_Return: case Qt.Key_Enter:
            if (event.isAutoRepeat) break // the opening hold still repeating
            if (menu.isHeader(idx)) break // never fire on a group label
            if (entries[idx] && entries[idx].input === true) {
                Sfx.play("open")
                typingAt = idx          // the row becomes its field (it takes the keys)
                break
            }
            Sfx.play("select")
            visible = false
            focus = false
            picked(idx)
            closed()
            break
        case Qt.Key_Escape: case Qt.Key_H: case Qt.Key_Q: close(); break
        default: break // modal: swallow everything — unhandled keys were
                       // falling through and driving the view underneath
        }
        event.accepted = true
    }

    Rectangle {
        anchors.fill: parent
        anchors.topMargin: -menu.topBleed   // reach up over the header strip
        color: Theme.withAlpha(Theme.bg, 0.72)
        MouseArea { anchors.fill: parent; hoverEnabled: true; onClicked: menu.close() }
    }

    Panel {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: -menu.topBleed / 2   // centre in the FULL screen
        width: Math.min(520, parent.width - 120)
        height: col.height + 44
        color: Theme.withAlpha(Theme.bg, 0.96 * menu.glass)
        // The painted queue-tex 9-slice IS the backing now (shared with the queue
        // panel + search results), so the Panel drops its own accent hairline.
        active: false
        border.width: 0

        BorderImage {
            anchors.fill: parent
            source: (App.heroDevRev, menu.devSrc("queue-tex"))
            smooth: false
            opacity: menu.glass
            border { left: 8; right: 8; top: 8; bottom: 8 }
            horizontalTileMode: BorderImage.Stretch
            verticalTileMode: BorderImage.Stretch
        }

        Column {
            id: col
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: 22
            spacing: 12

            // The title in the section headings' style (the library's season
            // headings): codec face, tracked out, shadowed — full accent, it
            // heads the menu.
            ShadowText {
                width: parent.width
                // no title, no band (an empty one left a blank strip on top)
                visible: menu.title.trim().length > 0
                text: Theme.mgsSafe(menu.title)
                color: Theme.accent
                font.family: Theme.codecFont
                font.pixelSize: 20
                font.letterSpacing: 4
                elide: Text.ElideRight
            }

            ListView {
                id: lv
                // The plate art shows its light edge 4 art px (8px) inside the
                // plate, so the list reaches out by that much and the plates' light
                // edges land on the title's column; the row text shifts back in.
                x: -menu.bleed
                width: parent.width + 2 * menu.bleed
                // Long lists (all the user's playlists) scroll inside the
                // panel instead of running off the screen — sized to WHOLE rows,
                // and since every row is rowH, Contain-scrolling keeps them whole.
                height: Math.min(contentHeight,
                                 Math.max(1, Math.floor((menu.height - 220 + menu.rowGap)
                                                        / (menu.rowH + menu.rowGap)))
                                 * (menu.rowH + menu.rowGap) - menu.rowGap)
                clip: true
                spacing: menu.rowGap
                model: menu.entries
                // the Settings rows' fan-in (Cascade)
                property int cascadeRev: 0
                property double cascadeAt: 0
                function fanIn() { cascadeAt = Date.now(); cascadeRev++ }
                delegate: Item {
                    id: row
                    required property var modelData
                    required property int index
                    readonly property bool isHeader: modelData.header === true
                    readonly property bool selected: !isHeader && menu.idx === index

                    width: lv.width
                    // headings take a full row too: one row height means the list
                    // can show WHOLE rows only (a mixed 28/45 list cut one in half)
                    height: menu.rowH
                    Cascade { id: fan; view: lv }
                    opacity: fan.op

                    // Selection grammar ported from the queue/search rows: an idle
                    // + lit family-6 plate (the lit plate stays on while the row is
                    // selected), a momentary press (tap) and a
                    // down-and-back hop, LIT-by-brightness text. Headers get none.
                    property real hopY: 0
                    property real litOpacity: 0
                    Behavior on litOpacity { NumberAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                    SequentialAnimation {
                        id: hopAnim
                        NumberAnimation { target: row; property: "hopY"; to: DS.selDip(row.height - 4); duration: 90; easing.type: Easing.OutQuad }
                        NumberAnimation { target: row; property: "hopY"; to: 0; duration: 260; easing.type: Easing.OutBack }
                    }
                    onSelectedChanged: {
                        if (selected) {
                            litOpacity = 1
                            if (menu.visible) { litBtn.tap(); hopAnim.restart() }
                        } else {
                            litOpacity = 0
                            hopAnim.stop(); hopY = 0
                        }
                    }

                    MechButton {
                        visible: !row.isHeader
                        family: 6; px: 2; hot: false
                        opacity: menu.glass
                        anchors.left: parent.left; anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        height: parent.height - 4
                    }
                    MechButton {
                        id: litBtn
                        visible: !row.isHeader
                        family: 6; px: 2; hot: true
                        opacity: row.litOpacity * menu.glass
                        anchors.left: parent.left; anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        height: parent.height - 4
                    }

                    Item {
                        anchors.fill: parent
                        transform: Translate { y: row.hopY + fan.dy }
                        // A heading reads like the library's season headings: the codec
                        // face, tracked out, accent, shadowed, at the foot of its row.
                        ShadowText {
                            visible: row.isHeader
                            x: menu.bleed
                            anchors.bottom: parent.bottom
                            anchors.bottomMargin: 10
                            text: Theme.mgsSafe(modelData.label)
                            color: Theme.withAlpha(Theme.accent, 0.85)
                            font.family: Theme.codecFont
                            font.pixelSize: 20
                            font.letterSpacing: 4
                        }
                        // an input row being typed into: its words in the
                        // typing face (Departure Mono, as every search box)
                        TextInput {
                            id: rowField
                            readonly property bool on: menu.typingAt === index
                            visible: on
                            x: 16 + menu.bleed
                            width: parent.width - 32 - 2 * menu.bleed
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.verticalCenterOffset: Math.round(litBtn.y + litBtn.faceMid - parent.height / 2)
                            color: Theme.fg
                            font.family: "Departure Mono"
                            font.pixelSize: 22
                            clip: true
                            onOnChanged: if (on) { text = ""; forceActiveFocus() }
                            Text {
                                visible: rowField.text.length === 0
                                anchors.verticalCenter: parent.verticalCenter
                                text: Theme.mgsSafe(row.modelData.placeholder || "")
                                color: Theme.dimFg
                                font.family: Theme.hudFont
                                font.pixelSize: 20
                                font.letterSpacing: 1
                            }
                            Keys.onPressed: (event) => {
                                if (event.key === Qt.Key_Escape) {
                                    menu.cancelTyping(); event.accepted = true
                                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                    if (!event.isAutoRepeat) menu.commitTyping(text)
                                    event.accepted = true
                                }
                            }
                        }
                        Text {
                            id: rowLabel
                            visible: !row.isHeader && !rowField.on
                            x: 16 + menu.bleed
                            // its cap INK on the plate's dark face (the lighter foot is
                            // below the face; the HUD face sits its ink low in the box)
                            y: Math.round(litBtn.y + litBtn.faceMid - rowLabel.capMid())
                            FontMetrics { id: rowLabelFm; font: rowLabel.font }
                            function capMid() {
                                void rowLabelFm.height
                                const r = rowLabelFm.tightBoundingRect("H")
                                return rowLabelFm.ascent + r.y + r.height / 2
                            }
                            width: parent.width - 32 - 2 * menu.bleed - hintText.width
                            text: Theme.mgsSafe(modelData.label)
                            color: row.selected ? Theme.fg : Theme.dimFg
                            Behavior on color { ColorAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                            font.family: Theme.hudFont
                            font.pixelSize: 28
                            font.letterSpacing: 1
                            elide: Text.ElideRight
                            style: Text.Raised
                            styleColor: "#000000"
                        }
                        Text {
                            id: hintText
                            visible: !row.isHeader && !rowField.on
                            anchors.right: parent.right
                            anchors.rightMargin: 14 + menu.bleed
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.verticalCenterOffset: Math.round(litBtn.y + litBtn.faceMid - parent.height / 2)
                            text: Theme.mgsSafe(modelData.hint || "")
                            color: Theme.dimFg
                            font.family: Theme.hudFont
                            font.pixelSize: 18
                            font.letterSpacing: 1
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        enabled: !row.isHeader
                        hoverEnabled: true
                        onEntered: if (!row.isHeader) {
                            if (App.pointerActive && menu.idx !== index) Sfx.play("move")
                            menu.idx = index
                        }
                        onClicked: {
                            menu.idx = index
                            if (row.modelData.input === true) {
                                Sfx.play("open")
                                menu.typingAt = index
                                return
                            }
                            Sfx.play("select")
                            menu.visible = false
                            menu.focus = false
                            menu.picked(index)
                            menu.closed()
                        }
                    }
                }
            }

            Text {
                text: "j/k move   ⏎ select   "
                      + (menu.closeKey >= Qt.Key_A && menu.closeKey <= Qt.Key_Z
                         ? String.fromCharCode(menu.closeKey).toLowerCase() + "/" : "") + "esc close"
                color: Theme.dimFg
                font.family: Theme.hudFont
                font.pixelSize: 20
                font.letterSpacing: 2
            }
        }
    }
}
