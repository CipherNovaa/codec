import QtQuick

// `c` — choose where playback goes: this machine, or any cast device found
// on the LAN (Sony TV / Chromecast / Google TV). Switching mid-play hands
// the file over with its position.
FocusScope {
    id: op

    // The CRT inset (Main's crtL..crtB): the scrim runs out under the tube's
    // overscan so the glass dims edge to edge, not inside a black frame.
    property int bleed: 0

    visible: App.outputOpen
    property bool sfxReady: false            // the built panel settling hidden isn't a close
    Component.onCompleted: sfxReady = true
    onVisibleChanged: {
        if (visible) { forceActiveFocus(); idx = currentIndex(); ipText = ""; status = ""; list.fanIn() }
        // UI sounds — here, so every way in (c, the cast remote, a menu's CAST)
        // sounds alike; picking a device closes it in the same turn (select wins)
        if (sfxReady) Sfx.play(visible ? "open" : "back")
    }
    // the pointer onto a row: a move only when it really moves the selection
    // (a parked pointer under a freshly opened picker stays silent)
    function pointTo(i) {
        if (App.pointerActive && idx !== i) Sfx.play("move")
        idx = i
    }

    // The rows' two-line label (HUD 30 over HUD 18) is centred on its INK — cap
    // top to the second line's baseline — not its line boxes, whose HUD descent
    // space sat the ink low. inkShift moves the Column by that much. The lines sit
    // tight (lineGap −2 → 5px between the two lines' ink; 3 left a 10px hole —
    // the HUD line boxes carry space of their own).
    readonly property int lineGap: -2
    FontMetrics { id: rowTitleFm; font.family: Theme.hudFont; font.pixelSize: 30 }
    FontMetrics { id: rowSubFm; font.family: Theme.hudFont; font.pixelSize: 18 }
    readonly property real inkShift: {
        void rowTitleFm.height; void rowSubFm.height
        const r = rowTitleFm.tightBoundingRect("H")
        const inkTop = rowTitleFm.ascent + r.y
        const inkBottom = rowTitleFm.height + lineGap + rowSubFm.ascent
        return (rowTitleFm.height + lineGap + rowSubFm.height) / 2 - (inkTop + inkBottom) / 2
    }
    property int idx: 0
    // this machine, each device, then ADD DEVICE
    readonly property int rows: 2 + Cast.deviceCount
    readonly property int addRow: rows - 1
    // A device appearing (discovery, a search, an add) inserts ABOVE the ADD
    // DEVICE row — keep the selection on that row rather than letting it slide
    // onto whatever moved into its slot (mid-typing an IP, say).
    property int lastRows: rows
    onRowsChanged: {
        if (idx === lastRows - 1)
            idx = rows - 1
        lastRows = rows
    }
    // ADD DEVICE: Enter searches the LAN afresh; digits + dots typed on the row
    // make an address, and Enter then asks that IP directly (for a device mDNS
    // can't see). Neither casts anything — a found device just joins the list.
    property string ipText: ""
    property bool busy: false
    property string status: ""
    property string statusKind: "info"   // ok (accent) | info (dim) | bad (warning)
    function addAction() {
        if (busy)
            return
        status = ""
        busy = true
        if (ipText.length > 0)
            Cast.addDeviceIp(ipText)
        else
            Cast.rescan()
        busyGuard.restart()
    }
    Timer {   // a worker that never answers can't leave the row stuck
        id: busyGuard
        interval: 15000
        onTriggered: if (op.busy) { op.busy = false; op.statusKind = "bad"; op.status = "NO ANSWER" }
    }
    Connections {
        target: Cast
        function onScanFinished(found) {
            op.busy = false
            // nothing new isn't a failure — the known devices are already listed
            op.statusKind = found > 0 ? "ok" : "info"
            op.status = found > 0 ? "FOUND " + found + " NEW" : "NOTHING NEW — ENTER IP ADDRESS"
        }
        function onAddDeviceResult(ok, ip, name, error) {
            op.busy = false
            op.statusKind = ok ? "ok" : "bad"
            op.status = ok ? "ADDED " + name.toUpperCase() : "NO CAST DEVICE AT " + ip
            if (ok) {
                op.ipText = ""
                // land on the device just added — Enter then switches to it
                for (let i = 0; i < Cast.deviceCount; i++)
                    if (Cast.deviceAt(i).ip === ip)
                        op.idx = i + 1
            }
        }
    }
    property real glass: App.glassLevel

    function devSrc(rel) {
        var d = App.heroDevPath(rel)
        return d !== "" ? d + "?v=" + App.heroDevRev : "qrc:/assets/mechui/" + rel + ".png"
    }

    function currentIndex() {
        if (Cast.targetId === "")
            return 0
        for (let i = 0; i < Cast.deviceCount; i++)
            if (Cast.deviceAt(i).id === Cast.targetId)
                return i + 1
        return 0
    }

    function confirm() {
        Sfx.play("select")
        if (idx === addRow) {
            addAction()
            return
        }
        App.setOutput(idx === 0 ? "" : Cast.deviceAt(idx - 1).id)
    }

    Keys.onPressed: (event) => {
        // on ADD DEVICE, digits and dots type an address (the nav keys are letters)
        if (idx === addRow && !busy) {
            if (event.text.length === 1 && /[0-9.]/.test(event.text)) {
                if (ipText.length < 15)
                    ipText += event.text
                status = ""
                event.accepted = true
                return
            }
            if (event.key === Qt.Key_Backspace && ipText.length > 0) {
                ipText = ipText.slice(0, -1)
                event.accepted = true
                return
            }
        }
        switch (event.key) {
        case Qt.Key_Down: case Qt.Key_J: idx = (idx + 1) % rows; Sfx.play("move"); break   // wraps: always moves
        case Qt.Key_Up: case Qt.Key_K: idx = (idx + rows - 1) % rows; Sfx.play("move"); break
        case Qt.Key_Return: case Qt.Key_Enter: confirm(); break   // not l: h/l only navigate
        case Qt.Key_C: case Qt.Key_Escape: case Qt.Key_H: case Qt.Key_Q:
            App.outputOpen = false; break
        default: return
        }
        event.accepted = true
    }

    Rectangle {
        anchors.fill: parent
        anchors.margins: -op.bleed
        color: Theme.withAlpha(Theme.bg, 0.72)
        MouseArea { anchors.fill: parent; hoverEnabled: true; onClicked: App.outputOpen = false }
    }

    Panel {
        anchors.centerIn: parent
        width: Math.min(560, parent.width - 120)
        // the column's real height + its 22px margins (list is a Column — it
        // has no contentHeight, which left a gap under the hints)
        height: body.implicitHeight + 44
        color: Theme.withAlpha(Theme.bg, 0.96 * op.glass)
        active: false
        border.width: 0

        BorderImage {
            anchors.fill: parent
            source: (App.heroDevRev, op.devSrc("queue-tex"))
            smooth: false
            opacity: op.glass
            border { left: 8; right: 8; top: 8; bottom: 8 }
            horizontalTileMode: BorderImage.Stretch
            verticalTileMode: BorderImage.Stretch
        }

        Column {
            id: body
            anchors.fill: parent
            anchors.margins: 22
            spacing: 14

            Item {
                id: headerRow
                width: parent.width
                height: 18
                Text {
                    text: "OUTPUT"
                    color: Theme.accent
                    font.family: Theme.codecFont
                    font.pixelSize: 14
                    font.letterSpacing: 5
                }
                Text {
                    anchors.right: parent.right
                    text: Cast.deviceCount === 0 ? "SEARCHING LAN" : Cast.deviceCount + " DEVICE(S)"
                    color: Theme.dimFg
                    font.family: Theme.hudFont
                    font.pixelSize: 20
                    font.letterSpacing: 2
                }
            }

            Column {
                id: list
                width: parent.width
                spacing: 6
                // the Settings rows' fan-in (Cascade)
                property int cascadeRev: 0
                property double cascadeAt: 0
                function fanIn() { cascadeAt = Date.now(); cascadeRev++ }
                readonly property double contentHeight: (op.rows * 58) + ((op.rows - 1) * 6)

                // Row 0: this machine
                Item {
                    width: parent.width
                    height: 50
                    Cascade { id: fan0; view: list }
                    opacity: fan0.op
                    MechSelectRow {
                        id: localPlate
                        bleed: true   // its light edge on the panel's text column
                        anchors.fill: parent
                        selected: op.idx === 0
                        hovered: localMouse.containsMouse
                        glass: op.glass
                        armed: op.visible
                    }
                    Item {
                        anchors.fill: parent
                        // centred on the plate's dark face, not the row (its lighter foot
                        // is below the face)
                        transform: Translate { y: localPlate.hopY + localPlate.faceMid - localPlate.height / 2 + fan0.dy }
                        Row {
                            x: 16; spacing: 12
                            anchors.verticalCenter: parent.verticalCenter
                            Text {
                                text: "󰍹"
                                color: op.idx === 0 ? Theme.accent : Theme.dimFg
                                Behavior on color { ColorAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                                font.family: Theme.monoFont
                                font.pixelSize: 18
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Column {
                                spacing: op.lineGap
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.verticalCenterOffset: op.inkShift
                                Text {
                                    text: "THIS MACHINE"
                                    color: op.idx === 0 ? Theme.fg : Theme.dimFg
                                    Behavior on color { ColorAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                                    font.family: Theme.hudFont
                                    font.pixelSize: 30
                                    font.letterSpacing: 2
                                    style: Text.Raised; styleColor: "#000000"
                                }
                                Text {
                                    text: App.display + "   " + App.mode.toUpperCase()
                                    color: Theme.dimFg
                                    font.family: Theme.hudFont
                                    font.pixelSize: 18
                                    font.letterSpacing: 1
                                    style: Text.Raised; styleColor: "#000000"
                                }
                            }
                        }
                        MechStatus {
                            anchors.right: parent.right
                            anchors.rightMargin: 16
                            anchors.verticalCenter: parent.verticalCenter
                            visible: Cast.targetId === ""
                            label: "ACTIVE"; ink: Theme.accent; px: 20
                        }
                    }
                    MouseArea {
                        id: localMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onEntered: op.pointTo(0)
                        onClicked: { op.idx = 0; op.confirm() }
                    }
                }

                Repeater {
                    model: Cast
                    delegate: Item {
                        id: devRow
                        required property string deviceId
                        required property string name
                        required property string modelName
                        required property string ip
                        required property int index
                        readonly property bool sel: op.idx === index + 1

                        width: parent.width
                        height: 50
                        Cascade { id: fan; view: list }
                        opacity: fan.op
                        MechSelectRow {
                            id: devPlate
                            bleed: true   // its light edge on the panel's text column
                            anchors.fill: parent
                            selected: devRow.sel
                            hovered: devMouse.containsMouse
                            glass: op.glass
                            armed: op.visible
                        }
                        Item {
                            anchors.fill: parent
                            // centred on the plate's dark face, not the row (its lighter foot
                            // is below the face)
                            transform: Translate { y: devPlate.hopY + devPlate.faceMid - devPlate.height / 2 + fan.dy }
                            Row {
                                x: 16; spacing: 12
                                anchors.verticalCenter: parent.verticalCenter
                                Text {
                                    text: "󰄘"
                                    color: devRow.sel ? Theme.accent : Theme.dimFg
                                    Behavior on color { ColorAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                                    font.family: Theme.monoFont
                                    font.pixelSize: 18
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                Column {
                                    spacing: op.lineGap
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.verticalCenterOffset: op.inkShift
                                    Text {
                                        text: devRow.name.toUpperCase()
                                        color: devRow.sel ? Theme.fg : Theme.dimFg
                                        Behavior on color { ColorAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                                        font.family: Theme.hudFont
                                        font.pixelSize: 30
                                        font.letterSpacing: 2
                                        style: Text.Raised; styleColor: "#000000"
                                    }
                                    Text {
                                        text: modelName.toUpperCase() + "   " + ip
                                        color: Theme.dimFg
                                        font.family: Theme.hudFont
                                        font.pixelSize: 18
                                        font.letterSpacing: 1
                                        style: Text.Raised; styleColor: "#000000"
                                    }
                                }
                            }
                            MechStatus {
                                anchors.right: parent.right
                                anchors.rightMargin: 16
                                anchors.verticalCenter: parent.verticalCenter
                                visible: Cast.targetId === deviceId
                                label: Cast.castState; ink: Theme.accent; px: 20
                            }
                        }
                        MouseArea {
                            id: devMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            onEntered: op.pointTo(index + 1)
                            onClicked: { op.idx = index + 1; op.confirm() }
                        }
                    }
                }

                // ADD DEVICE — search the LAN afresh, or type a device's IP.
                Item {
                    id: addRowItem
                    readonly property bool sel: op.idx === op.addRow
                    width: parent.width
                    height: 50
                    Cascade { id: fanAdd; view: list }
                    opacity: fanAdd.op
                    MechSelectRow {
                        id: addPlate
                        bleed: true   // its light edge on the panel's text column
                        anchors.fill: parent
                        selected: addRowItem.sel
                        hovered: addMouse.containsMouse
                        glass: op.glass
                        armed: op.visible
                    }
                    Item {
                        anchors.fill: parent
                        // centred on the plate's dark face, not the row (its lighter foot
                        // is below the face)
                        transform: Translate { y: addPlate.hopY + addPlate.faceMid - addPlate.height / 2 + fanAdd.dy }
                        Row {
                            x: 16; spacing: 12
                            anchors.verticalCenter: parent.verticalCenter
                            Text {
                                text: "+"
                                color: addRowItem.sel ? Theme.accent : Theme.dimFg
                                Behavior on color { ColorAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                                font.family: Theme.hudFont
                                font.pixelSize: 36
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Column {
                                spacing: op.lineGap
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.verticalCenterOffset: op.inkShift
                                Text {
                                    text: "ADD DEVICE"
                                    color: addRowItem.sel ? Theme.fg : Theme.dimFg
                                    Behavior on color { ColorAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                                    font.family: Theme.hudFont
                                    font.pixelSize: 30
                                    font.letterSpacing: 2
                                    style: Text.Raised; styleColor: "#000000"
                                }
                                Text {
                                    // what Enter will do, what it's doing, or how it went
                                    text: Theme.mgsSafe(
                                        op.busy ? (op.ipText.length > 0 ? "ASKING " + op.ipText + "..."
                                                                        : "SCANNING NETWORK...")
                                        : op.status.length > 0 ? op.status   // until you type again
                                        : op.ipText.length > 0 ? op.ipText + "_   ⏎ ADD"
                                        : "⏎ SCAN NETWORK   ·   ENTER IP ADDRESS")
                                    color: op.busy ? Theme.accent
                                         : op.status.length > 0
                                           ? (op.statusKind === "ok" ? Theme.accent
                                              : op.statusKind === "bad" ? Theme.warning : Theme.dimFg)
                                         : Theme.dimFg
                                    font.family: Theme.hudFont
                                    font.pixelSize: 18
                                    font.letterSpacing: 1
                                    style: Text.Raised; styleColor: "#000000"
                                }
                            }
                        }
                    }
                    MouseArea {
                        id: addMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onEntered: op.pointTo(op.addRow)
                        onClicked: { op.idx = op.addRow; op.confirm() }
                    }
                }
            }

            Text {
                id: hint
                text: "j/k select   ⏎ switch   c/esc close"
                color: Theme.dimFg
                font.family: Theme.hudFont
                font.pixelSize: 20
                font.letterSpacing: 2
            }
        }
    }
}
