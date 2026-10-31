import QtQuick

// Global search: `/` from home. Fuzzy across movies + shows + episodes with
// instant results; bottom action jumps the same query to YouTube search.
FocusScope {
    id: overlay
    // The CRT inset (Main's crtL..crtB): the scrim runs out under the tube's
    // overscan so the glass dims edge to edge, not inside a black frame.
    property int bleed: 0

    visible: App.searchOpen
    onVisibleChanged: {
        if (visible) {
            input.text = ""
            results = []
            idx = 0
            input.forceActiveFocus()
        }
    }

    property var results: []
    property int idx: 0

    // UI sounds (Sfx): opening / closing plays open / back however it was
    // toggled (/ from any view, the remote's SEARCH, esc, a click outside) —
    // never at start-up. Typing, and the live refine putting the selection
    // back on the first hit, stay silent.
    property bool sfxReady: false
    Component.onCompleted: sfxReady = true
    Connections {
        target: App
        function onSearchOpenChanged() { if (overlay.sfxReady) Sfx.play(App.searchOpen ? "open" : "back") }
    }

    // Live-editable 9-slice: the dev-tree PNG (cache-busted on save via heroDevRev)
    // else the baked qrc. Same contract as the OSD/queue/PiP frames.
    function devSrc(rel) {
        var d = App.heroDevPath(rel)
        return d !== "" ? d + "?v=" + App.heroDevRev : "qrc:/assets/mechui/" + rel + ".png"
    }

    function refresh() {
        results = MediaLibrary.searchAll(input.text, 30)
        idx = 0
    }

    function pick() {
        if (idx === results.length) { // the YouTube action row
            const q = input.text
            Sfx.play("select")
            App.searchOpen = false
            App.openSection("youtube")
            YouTube.search(q)
            return
        }
        const it = results[idx]
        if (!it)
            return
        Sfx.play("select")
        App.searchOpen = false
        if (it.kind === "show") {
            App.openSection("tv")
            MediaLibrary.showFilter = it.show.length > 0 ? it.show : it.title
        } else {
            CLog.d("search", "play " + it.path)
            App.play(it.path)
        }
    }

    Keys.onPressed: (event) => {
        const was = idx
        switch (event.key) {
        case Qt.Key_Down:
            idx = Math.min(idx + 1, results.length) // length = YT action row
            Sfx.play(idx === was ? "bump" : "move")
            break
        case Qt.Key_Up:
            idx = Math.max(idx - 1, 0)
            Sfx.play(idx === was ? "bump" : "move")
            break
        case Qt.Key_Return: case Qt.Key_Enter:
            pick(); break
        case Qt.Key_I:
            // ctrl+i = detail page (plain i belongs to the text input).
            if (!(event.modifiers & Qt.ControlModifier))
                return
            if (idx < results.length && (results[idx].path || "").length > 0) {
                App.searchOpen = false
                App.detailUri = results[idx].path
                Sfx.play("open")    // after the close's `back`: the later of equals wins
            }
            break
        case Qt.Key_Escape:
            App.searchOpen = false; break
        default:
            return
        }
        event.accepted = true
    }

    Rectangle {
        anchors.fill: parent
        anchors.margins: -overlay.bleed
        color: Theme.withAlpha(Theme.bg, 0.82)
        MouseArea { anchors.fill: parent; hoverEnabled: true
                    onClicked: App.searchOpen = false }
    }

    Panel {
        anchors.horizontalCenter: parent.horizontalCenter
        y: Math.round(parent.height * 0.10)
        width: Math.min(720, parent.width - 120)
        height: Math.min(searchCol.height + 40, parent.height * 0.78)
        // Pure layout now: the search bar AND the results area each wear their
        // own painted 9-slice texture, so the panel keeps no fill, outline, or
        // ticks — both children float on the dimmed backdrop.
        color: "transparent"
        active: false
        border.width: 0

        Column {
            id: searchCol
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: 20
            spacing: 14

            // The search field wears its own painted 9-slice frame (FF-style
            // command bar). EDIT: assets/mechui/plates/search-home-tex.png
            // (48x48, border 8, transparent centre). Hot-reloads on save.
            Item {
                id: fieldBox
                width: parent.width
                height: 64

                BorderImage {
                    anchors.fill: parent
                    source: (App.heroDevRev, overlay.devSrc("search-home-tex"))
                    smooth: false
                    border { left: 8; right: 8; top: 8; bottom: 8 }
                    horizontalTileMode: BorderImage.Stretch
                    verticalTileMode: BorderImage.Stretch
                    // Same machined-glass translucency as the home wheel bays /
                    // section card — the backdrop reads through the frame. The
                    // icon + text are siblings, so they stay fully lit.
                    opacity: 0.82
                }

                ShadowText {
                    id: fieldIcon
                    x: 20
                    anchors.verticalCenter: parent.verticalCenter
                    text: "󰍉"
                    color: Theme.accent
                    font.family: Theme.monoFont
                    font.pixelSize: 18
                }
                // Drop shadow for the LIVE-typed text — a TextInput can't carry
                // Text.Raised, so a mirrored offset twin rides behind it (same
                // trick as the PiP title). Placeholder + icon are ShadowText.
                Text {
                    visible: input.text.length > 0
                    x: input.x + 1
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.verticalCenterOffset: 2
                    text: input.text
                    color: "#000000"
                    opacity: 0.7
                    font: input.font
                }
                TextInput {
                    id: input
                    x: fieldIcon.x + fieldIcon.width + 12
                    width: fieldBox.width - x - 18
                    anchors.verticalCenter: parent.verticalCenter
                    color: Theme.fg
                    // typed text in Departure Mono (the chat's face, real
                    // lowercase, its 11-px grid); the placeholder stays MGS
                    font.family: "Departure Mono"
                    font.pixelSize: 22
                    clip: true
                    onTextChanged: overlay.refresh()
                    ShadowText {
                        visible: input.text.length === 0
                        anchors.verticalCenter: parent.verticalCenter
                        text: Theme.mgsSafe("search everything…")
                        color: Theme.dimFg
                        font.family: Theme.hudFont
                        font.pixelSize: 36
                    }
                }
            }

            // Framed results area — brings the QUEUE's own 9-slice frame texture
            // so the "sibling" area wears an outline like the search bar. Only
            // present once there are results to hold. Hot-reloads with queue-tex.
            Item {
                id: resultsArea
                width: parent.width
                // Shown while typing (so the "search youtube" hand-off is offered
                // even with zero local hits) or whenever there are results.
                visible: input.text.length > 0 || overlay.results.length > 0
                // Capped to what the panel can show (30 results at 70px ran far
                // off the screen, unclipped, with the selection walking out of
                // sight); the rows scroll inside, following the selection.
                readonly property real maxH: Math.max(120,
                    overlay.height * 0.78 - 40 - fieldBox.height - searchCol.spacing)
                height: visible ? Math.min(resultsCol.height + 30, maxH) : 0

                BorderImage {
                    anchors.fill: parent
                    source: (App.heroDevRev, overlay.devSrc("queue-tex"))
                    smooth: false
                    opacity: 0.82
                    border { left: 8; right: 8; top: 8; bottom: 8 }
                    horizontalTileMode: BorderImage.Stretch
                    verticalTileMode: BorderImage.Stretch
                }

                Flickable {
                    id: resultsFlick
                    anchors.fill: parent
                    anchors.topMargin: 15
                    anchors.bottomMargin: 15
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    clip: true
                    contentWidth: width
                    contentHeight: resultsCol.height
                    boundsBehavior: Flickable.StopAtBounds
                    Behavior on contentY { NumberAnimation { duration: 140; easing.type: Easing.OutQuad } }

                    // keep the selected row (a result, or the YouTube hand-off)
                    // inside the window
                    function follow() {
                        for (var i = 0; i < resultsCol.children.length; ++i) {
                            var c = resultsCol.children[i]
                            if (!c.selected)
                                continue
                            if (c.y < contentY)
                                contentY = c.y
                            else if (c.y + c.height > contentY + height)
                                contentY = Math.min(c.y + c.height - height,
                                                    Math.max(0, contentHeight - height))
                            return
                        }
                    }
                    Connections {
                        target: overlay
                        function onIdxChanged() { Qt.callLater(resultsFlick.follow) }
                        function onResultsChanged() { resultsFlick.contentY = 0 }
                    }

                Column {
                    id: resultsCol
                    width: parent.width
                    spacing: 4
                    // the Settings rows' fan-in (Cascade)
                    property int cascadeRev: 0
                    property double cascadeAt: 0
                    function fanIn() { cascadeAt = Date.now(); cascadeRev++ }
                    // only when the list APPEARS (not on every keystroke's refine)
                    property bool hadRows: false
                    Connections {
                        target: overlay
                        function onResultsChanged() {
                            const n = overlay.results.length
                            if (n > 0 && !resultsCol.hadRows) resultsCol.fanIn()
                            resultsCol.hadRows = n > 0
                        }
                    }

                    // Result rows — the STATS/QUEUE plate grammar: idle + lit
                    // MechButton (family 6) cross-faded on selection, a momentary
                    // press (tap) + a down-and-back hop, LIT-by-brightness text.
                    Repeater {
                        model: overlay.results
                        delegate: Item {
                            id: srow
                            required property var modelData
                            required property int index
                            readonly property bool selected: overlay.idx === index
                            width: parent.width
                            // Taller than a queue row: this row also carries a
                            // POSTER, so the plate is scaled up to seat the poster
                            // + 2 lines of text inside the plate's dark recess.
                            height: 66
                            Cascade { id: fan; view: resultsCol }
                            opacity: fan.op

                            property real hopY: 0
                            // lit-plate flash: snaps to 1 on select, holds, fades to
                            // 0 (settle); moving away is instant. Same as the queue.
                            property real litOpacity: 0
                            Behavior on litOpacity { NumberAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                            SequentialAnimation {
                                id: hopAnim
                                NumberAnimation { target: srow; property: "hopY"; to: DS.selDip(srow.height); duration: 90; easing.type: Easing.OutQuad }
                                NumberAnimation { target: srow; property: "hopY"; to: 0; duration: 260; easing.type: Easing.OutBack }
                            }
                            onSelectedChanged: {
                                if (selected) {
                                    litOpacity = 1
                                    if (overlay.visible) { litBtn.tap(); hopAnim.restart() }
                                } else {
                                    litOpacity = 0
                                    // reset the bounce so fast nav can't leave a row
                                    // shifted (the guard the queue rows carry).
                                    hopAnim.stop(); hopY = 0
                                }
                            }

                            MechButton {
                                family: 6; px: 2; hot: false; opacity: 0.82
                                anchors.left: parent.left; anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                height: parent.height - 4
                            }
                            MechButton {
                                id: litBtn
                                family: 6; px: 2; hot: true
                                opacity: srow.litOpacity * 0.82
                                anchors.left: parent.left; anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                height: parent.height - 4
                            }

                            Item {
                                anchors.fill: parent
                                transform: Translate { y: srow.hopY + fan.dy }
                                Row {
                                    x: 14
                                    width: parent.width - 26
                                    anchors.verticalCenter: parent.verticalCenter
                                    // centred on the plate's dark face (the lighter
                                    // foot is below it)
                                    anchors.verticalCenterOffset: Math.round(litBtn.y + litBtn.faceMid - parent.height / 2)
                                    spacing: 12
                                    Rectangle {
                                        width: 30; height: 44; radius: 3
                                        color: Theme.surface
                                        clip: true
                                        anchors.verticalCenter: parent.verticalCenter
                                        Image {
                                            anchors.fill: parent
                                            source: modelData.poster.length > 0
                                                    ? Theme.art(modelData.poster) : ""
                                            fillMode: Image.PreserveAspectCrop
                                            asynchronous: true
                                        }
                                    }
                                    Column {
                                        width: parent.width - 40
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: 2
                                        ShadowText {
                                            width: parent.width
                                            text: Theme.mgsSafe((modelData.kind === "episode"
                                                   && modelData.show.length > 0
                                                   && !modelData.title.startsWith(modelData.show)
                                                   ? modelData.show + "  " : "")
                                                  + modelData.title)
                                            color: srow.selected ? Theme.fg : Theme.dimFg
                                            Behavior on color { ColorAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                                            font.family: Theme.hudFont
                                            font.pixelSize: 28
                                            elide: Text.ElideRight
                                        }
                                        ShadowText {
                                            width: parent.width
                                            text: Theme.mgsSafe(modelData.kind.toUpperCase()
                                                  + (modelData.subtitle.length > 0
                                                     ? "  ·  " + modelData.subtitle : ""))
                                            color: Theme.dimFg
                                            font.family: Theme.hudFont
                                            font.pixelSize: 20
                                            font.letterSpacing: 1
                                            elide: Text.ElideRight
                                        }
                                    }
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                property point prevScene: Qt.point(-9999, -9999)
                                onExited: prevScene = Qt.point(-9999, -9999)
                                onPositionChanged: (mouse) => {
                                    const p = mapToItem(null, mouse.x, mouse.y)
                                    const moved = Math.abs(p.x - prevScene.x) > 2
                                                  || Math.abs(p.y - prevScene.y) > 2
                                    prevScene = Qt.point(p.x, p.y)
                                    if (App.pointerActive && moved) {
                                        if (overlay.idx !== index) Sfx.play("move")
                                        overlay.idx = index
                                    }
                                }
                                onClicked: { overlay.idx = index; overlay.pick() }
                            }
                        }
                    }

                    // YouTube hand-off — the same plated row (selection sits one
                    // slot past the last result). MGS-HUD label + a larger YT glyph.
                    Item {
                        id: ytRow
                        width: parent.width
                        height: 57
                        readonly property bool selected: overlay.idx === overlay.results.length
                        property real litOpacity: 0
                        Behavior on litOpacity { NumberAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                        onSelectedChanged: {
                            if (selected) {
                                litOpacity = 1
                                if (overlay.visible) ytLitBtn.tap()
                            } else {
                                litOpacity = 0
                            }
                        }
                        MechButton {
                            family: 6; px: 2; hot: false; opacity: 0.82
                            anchors.left: parent.left; anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            height: parent.height - 4
                        }
                        MechButton {
                            id: ytLitBtn
                            family: 6; px: 2; hot: true
                            opacity: ytRow.litOpacity * 0.82
                            anchors.left: parent.left; anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            height: parent.height - 4
                        }
                        Row {
                            x: 16
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.verticalCenterOffset: Math.round(ytLitBtn.y + ytLitBtn.faceMid - parent.height / 2)   // the dark face
                            spacing: 12
                            ShadowText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "󰗃"
                                color: ytRow.selected ? Theme.accent : Theme.dimFg
                                Behavior on color { ColorAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                                font.family: Theme.monoFont
                                font.pixelSize: 26
                            }
                            ShadowText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: Theme.mgsSafe("SEARCH YOUTUBE FOR \"" + input.text.toUpperCase() + "\"")
                                color: ytRow.selected ? Theme.accent : Theme.dimFg
                                Behavior on color { ColorAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                                font.family: Theme.hudFont
                                font.pixelSize: 20
                                font.letterSpacing: 2
                            }
                        }
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { overlay.idx = overlay.results.length; overlay.pick() }
                        }
                    }
                }
                }
            }
        }
    }
}
