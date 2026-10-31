import QtQuick

// `w` — Watch Party. A movie playing at the same moment on screens that aren't
// in the same house.
//
// The session lives on the HUB, not in this app. That's the whole idea: any
// codec on the network sees what's running and can walk into it, your own TV
// is a viewer rather than the projector, and closing this window doesn't end
// anyone else's night. See docs/PARTY.md for the one-time Cast setup.
FocusScope {
    id: wp
    // The CRT inset (Main's crtL..crtB): the scrim runs out under the tube's
    // overscan so the glass dims edge to edge, not inside a black frame.
    property int bleed: 0

    visible: App.partyOpen

    // Someone else's session, running right now, that we haven't joined.
    readonly property bool canJoin: App.partyLive && !App.partyActive
    property real glass: App.glassLevel

    function devSrc(rel) {
        var d = App.heroDevPath(rel)
        return d !== "" ? d + "?v=" + App.heroDevRev : "qrc:/assets/mechui/" + rel + ".png"
    }

    // Keyboard focus. The overlay had one static highlight on the primary
    // button, so with three things to press there was no way to see what ⏎
    // would do. `acts` is the list of what's actually available right now, and
    // `sel` is where you are in it — ↑/↓ move, ⏎ fires, and each row draws its
    // own focus ring from the same source of truth as the hint line.
    // Who's in the room, in the order that matters to a host: the people
    // actually in it first, then anyone still earning a seat, then the ones who
    // aren't watching at all (a hidden tab, someone on the invite card).
    readonly property var roomRows: {
        var rank = {seated: 0, joining: 1, away: 2, card: 3}
        var r = App.partyRoom.slice()
        r.sort(function(a, b) {
            var d = (rank[a.state] !== undefined ? rank[a.state] : 1)
                  - (rank[b.state] !== undefined ? rank[b.state] : 1)
            return d !== 0 ? d : a.name.toLowerCase().localeCompare(b.name.toLowerCase())
        })
        return r
    }
    // Every row but our own can be selected (and dropped): "g:<id>".
    readonly property var guestActs: {
        var out = []
        for (var i = 0; i < roomRows.length; i++)
            if (!roomRows[i].me && roomRows[i].id) out.push("g:" + roomRows[i].id)
        return out
    }
    // In screen order: the room's rows sit above JOIN.
    // Removed screens asking to come back sit at the top: "u:<id>" (⏎ lets in).
    readonly property var askActs: (App.partyAsks || []).map(a => "u:" + a.id)
    readonly property var acts: !App.partyLive ? ["start"]
                                : askActs.concat(guestActs, canJoin ? ["join"] : [],
                                                   ["say", "copy", "lock", "end"])
    property int sel: 0
    readonly property string cur: acts[Math.min(sel, acts.length - 1)] || ""
    function focused(id) { return wp.activeFocus && wp.cur === id }
    // Where the cursor starts: JOIN when it's on offer, so `w` then ⏎ still
    // joins in one keystroke; otherwise the first thing below the room.
    function homeSel() {
        var i = acts.indexOf(canJoin ? "join" : "say")
        return i >= 0 ? i : 0
    }
    // Follow the ITEM, not the index: the room's rows come and go as people
    // join and leave, and every change used to throw the cursor somewhere else
    // (onto someone's DROP, at worst). `acts` is a new array on every poll, so
    // key on its contents.
    property string lastCur: ""
    // (lastCur, not `cur`: this handler runs before the `cur` binding updates,
    // so moving OFF an armed row left it armed and moving back disarmed it)
    onSelChanged: { lastCur = acts[sel] || ""; if (dropArmed !== lastCur) dropArmed = "" }
    property point lastMouse: Qt.point(-1, -1)
    function pointerMoved(item, mx, my) {
        const g = item.mapToItem(wp, mx, my)
        if (Math.abs(g.x - lastMouse.x) < 0.5 && Math.abs(g.y - lastMouse.y) < 0.5)
            return false
        lastMouse = Qt.point(g.x, g.y)
        return true
    }
    function shortName(n) { n = String(n || ""); return n.length > 12 ? n.slice(0, 11) + "…" : n }
    readonly property string actsKey: acts.join(",")
    onActsKeyChanged: {
        var i = acts.indexOf(lastCur)
        sel = i >= 0 ? i : homeSel()
        if (dropArmed !== "" && acts.indexOf(dropArmed) < 0) dropArmed = ""
    }
    // Drop the say box's focus first: closed with a click while typing, it
    // kept focus inside this FocusScope and the next open handed it back —
    // every shortcut (x ends the party!) then typed into the box.
    property bool sfxReady: false            // the built panel settling hidden isn't a close
    Component.onCompleted: sfxReady = true
    onVisibleChanged: {
        if (visible) { dropArmed = ""; sel = homeSel(); sayIn.focus = false; forceActiveFocus() }
        // UI sounds — here, so w, the strip's chip and the remote's spare all
        // sound alike; a JOIN that closes the panel is one select (same turn)
        if (sfxReady) Sfx.play(visible ? "open" : "back")
    }
    // the pointer onto a control: a move only when it really moves the cursor
    // (a parked pointer under the freshly opened panel stays silent)
    function pointTo(i) {
        if (App.pointerActive && i !== sel) Sfx.play("move")
        sel = i
    }

    // DROP takes two presses: the first arms the row (it turns warning-red and
    // says so), the second takes the screen out. Moving off it disarms. A
    // friend dropped by a stray keypress can't get back in with that link.
    property string dropArmed: ""
    function dropPress(act) {
        if (dropArmed === act) {
            dropArmed = ""
            App.partyDrop(act.slice(2))
        } else {
            dropArmed = act
        }
    }

    function fire(id) {
        if (id === "start") App.startWatchParty()
        else if (id === "join") App.joinWatchParty()
        else if (id === "say") sayIn.forceActiveFocus()
        else if (id === "copy") App.copyText(App.partyInviteUrl)
        else if (id === "lock") App.partyLock(!App.partyLocked)
        else if (id === "end") App.endWatchParty()
        else if (id.indexOf("g:") === 0) dropPress(id)
        else if (id.indexOf("u:") === 0) App.partyUndrop(id.slice(2))
    }
    // What ⏎ does right now, for the hint line.
    function curLabel() {
        if (cur.indexOf("g:") === 0) return dropArmed === cur ? "CONFIRM DROP" : "DROP"
        if (cur.indexOf("u:") === 0) return "LET IN"
        if (cur === "lock") return App.partyLocked ? "UNLOCK" : "LOCK"
        if (cur === "say") return "TALK"
        return String(cur).toUpperCase()
    }

    function fmt(t) {
        if (!(t > 0)) return "0:00"
        var s = Math.floor(t), h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60)
        var ss = ("0" + (s % 60)).slice(-2)
        return h > 0 ? h + ":" + ("0" + m).slice(-2) + ":" + ss : m + ":" + ss
    }

    // j/k are down/up here, the same as every other list in codec. They used to
    // be k=up and j=join, which broke two ways at once: j did nothing whenever
    // you'd already joined (canJoin is false then — which is most of the time
    // you're in this menu), and it swallowed the key anyway, so the one hand
    // position that works everywhere else went dead here. Join is ⏎: it's the
    // first row whenever it's on offer, so `w` then ⏎ is still one keystroke.
    //
    // A shortcut that can't act now RETURNS instead of accepting. An accepted
    // key that quietly does nothing is indistinguishable from a frozen app.
    Keys.onPressed: (event) => {
        switch (event.key) {
        case Qt.Key_Escape:
            // Esc first disarms a DROP; only then does it close the panel.
            if (wp.dropArmed !== "") { Sfx.play("back"); wp.dropArmed = ""; break }
            App.partyOpen = false; break
        case Qt.Key_L:
            if (!App.partyLive) return
            Sfx.play("select")
            App.partyLock(!App.partyLocked); break
        // the list wraps: only a lone START can't move (bump)
        case Qt.Key_Up: case Qt.Key_K:
            Sfx.play(acts.length > 1 ? "move" : "bump")
            sel = (sel - 1 + acts.length) % acts.length; break
        case Qt.Key_Down: case Qt.Key_J: case Qt.Key_Tab:
            Sfx.play(acts.length > 1 ? "move" : "bump")
            sel = (sel + 1) % acts.length; break
        case Qt.Key_Return: case Qt.Key_Enter:
            Sfx.play("select")
            wp.fire(wp.cur); break
        case Qt.Key_C:
            if (!App.partyLive) return
            Sfx.play("select")
            App.copyText(App.partyInviteUrl); break
        case Qt.Key_X:
            if (!App.partyLive) return
            Sfx.play("select")
            App.endWatchParty(); break
        case Qt.Key_T:
            if (!App.partyLive) return
            Sfx.play("select")
            sayIn.forceActiveFocus(); break
        case Qt.Key_R:
            if (!App.partyLive || !App.partyHubMode) return
            Sfx.play("select")
            App.partyVoteRewind(); break
        case Qt.Key_W: case Qt.Key_Q:
            App.partyOpen = false; break
        case Qt.Key_P:
            // Jump to the cast remote to scrub/transport (the two overlays are
            // mutually exclusive, so opening the remote closes this).
            if (Cast.targetId === "") return
            App.remoteOpen = true; break
        default: return
        }
        event.accepted = true
    }

    Rectangle {
        anchors.fill: parent
        anchors.margins: -wp.bleed
        color: Theme.withAlpha(Theme.bg, 0.72)
        MouseArea { anchors.fill: parent; hoverEnabled: true; onClicked: App.partyOpen = false }
    }

    Panel {
        anchors.centerIn: parent
        width: Math.min(600, parent.width - 120)
        height: body.height + 44
        color: Theme.withAlpha(Theme.bg, 0.96 * wp.glass)
        active: false
        border.width: 0

        // A click anywhere on the panel that no control takes stays here: it
        // used to fall through to the backdrop and close the panel (your own
        // row, the gaps between plates).
        MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons }

        BorderImage {
            anchors.fill: parent
            source: (App.heroDevRev, wp.devSrc("queue-tex"))
            smooth: false
            opacity: wp.glass
            border { left: 8; right: 8; top: 8; bottom: 8 }
            horizontalTileMode: BorderImage.Stretch
            verticalTileMode: BorderImage.Stretch
        }

        Column {
            id: body
            width: parent.width - 44
            anchors.horizontalCenter: parent.horizontalCenter
            y: 22
            spacing: 16

            // ── header ───────────────────────────────────────────────────
            Item {
                width: parent.width
                height: 34
                // the panel's title, sized like one (it was a 14 px label)
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "WATCH PARTY"
                    color: Theme.accent
                    font.family: Theme.codecFont
                    font.pixelSize: 28
                    font.letterSpacing: 3
                }
                MechStatus {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.right: parent.right
                    dot: App.partyLive
                    label: !App.partyLive ? "OFF"
                           : App.partyPeers > 0 ? "LIVE · " + App.partyPeers + " WATCHING"
                                                : "LIVE · WAITING"
                    ink: App.partyLive ? Theme.accent : Theme.dimFg
                    px: 20
                }
            }

            // ── nothing running: the pitch + start ───────────────────────
            Text {
                visible: !App.partyLive
                width: parent.width
                wrapMode: Text.WordWrap
                text: Theme.mgsSafe("Watch a movie in sync with someone far away. Start a party, "
                      + "then send them the link — they open it on their phone and "
                      + "cast it to their TV. Play, pause and seek move every screen.")
                color: Theme.dimFg
                font.family: Theme.hudFont
                font.pixelSize: 26
                lineHeight: 1.25
            }

            Item {
                visible: !App.partyLive
                width: parent.width
                height: 53
                MechSelectRow {
                    id: startPlate
                    bleed: true   // its light edge on the panel's text column
                    anchors.fill: parent
                    selected: wp.focused("start")
                    hovered: startMouse.containsMouse
                    glass: wp.glass
                    armed: wp.visible
                }
                Row {
                    anchors.centerIn: parent
                    spacing: 12
                    // centred on the plate's dark face (its lighter foot is below)
                    transform: Translate { y: startPlate.hopY + startPlate.faceMid - startPlate.height / 2 }
                    Text {
                        text: "▶"
                        color: Theme.accent
                        font.family: Theme.hudFont
                        font.pixelSize: 32
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        text: "START WATCH PARTY"
                        color: wp.focused("start") ? Theme.fg : Theme.dimFg
                        Behavior on color { ColorAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                        font.family: Theme.hudFont
                        font.pixelSize: 32
                        font.letterSpacing: 3
                        anchors.verticalCenter: parent.verticalCenter
                        style: Text.Raised; styleColor: "#000000"
                    }
                }
                MouseArea {
                    id: startMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onEntered: wp.pointTo(wp.acts.indexOf("start"))
                    onClicked: { Sfx.play("select"); App.startWatchParty() }
                }
            }

            // ── a session is running: what it is ─────────────────────────
            Column {
                visible: App.partyLive
                width: parent.width
                spacing: 7
                Text {
                    text: App.partyDriving || App.partyHosting ? "YOU'RE HOSTING"
                          : App.partyFollowing ? "YOU'RE WATCHING"
                                               : "PLAYING RIGHT NOW"
                    color: Theme.dimFg
                    font.family: Theme.hudFont
                    font.pixelSize: 20
                    font.letterSpacing: 2
                }
                Item {
                    width: parent.width
                    // air above the title logo: a tall one (BATMAN) sat on the
                    // plate's top bevel
                    height: nowCol.height + 36
                    MechSelectRow { id: nowPlate; anchors.fill: parent; selected: false; glass: wp.glass; bleed: true }
                    Column {
                        id: nowCol
                        anchors.left: parent.left
                        anchors.leftMargin: 14
                        anchors.right: parent.right
                        anchors.rightMargin: 14
                        // a set distance below the plate's top edge — centring
                        // on the face left a tall logo ~8 px from the bevel
                        anchors.top: parent.top
                        anchors.topMargin: 18
                        spacing: 4
                        // The film's own title logo (the hub's, keyed by title so a
                        // queue advance brings the next one), the title in words
                        // until it loads or when there's none.
                        Item {
                            width: parent.width
                            height: nowLogo.visible ? nowLogo.height : nowTitle.implicitHeight
                            Image {
                                id: nowLogo
                                height: 40
                                width: Math.min(parent.width, implicitWidth * height / Math.max(1, implicitHeight))
                                fillMode: Image.PreserveAspectFit
                                horizontalAlignment: Image.AlignLeft
                                smooth: true
                                asynchronous: true
                                source: App.partyInviteUrl && App.partyTitle
                                        ? App.partyInviteUrl + "/art?which=logo&t=" + encodeURIComponent(App.partyTitle)
                                        : ""
                                visible: status === Image.Ready
                            }
                            Text {
                                id: nowTitle
                                visible: !nowLogo.visible
                                width: parent.width
                                elide: Text.ElideRight
                                text: Theme.mgsSafe(App.partyTitle)
                                color: Theme.fg
                                font.family: Theme.hudFont
                                font.pixelSize: 30
                            }
                        }
                        Text {
                            text: Theme.mgsSafe((App.partyPaused ? "❚❚ paused at " : "▶ ")
                                  + wp.fmt(App.partyPos)
                                  + (App.partyDur > 0 ? " / " + wp.fmt(App.partyDur) : ""))
                            color: Theme.dimFg
                            font.family: Theme.hudFont
                            font.pixelSize: 22
                        }
                        // the room holding everyone on a new film, or what's on next
                        Text {
                            visible: App.partyLoading || App.partyNext !== ""
                            width: parent.width
                            elide: Text.ElideRight
                            textFormat: Text.PlainText
                            text: App.partyLoading ? "LOADING FOR EVERYONE"
                                                   : "UP NEXT · " + Theme.mgsSafe(App.partyNext)
                            color: App.partyLoading ? Theme.accent : Theme.dimFg
                            font.family: Theme.hudFont
                            font.pixelSize: 20
                            font.letterSpacing: 1
                        }

                        // ── who's in the room ────────────────────────────
                        // One per line with a dot for their link, matching the
                        // web player. A comma-separated list of names said
                        // nothing about who was struggling to keep up.
                        Item { width: 1; height: App.partyRoom.length > 0 ? 6 : 0 }
                        // Removed screens asking back in: their name, and the
                        // LET IN key (⏎ on the row, or a click).
                        Repeater {
                            model: App.partyAsks || []
                            delegate: Item {
                                id: ar
                                required property var modelData
                                readonly property string act: "u:" + modelData.id
                                readonly property bool hot: wp.focused(act) || askMouse.containsMouse
                                width: parent.width
                                height: 30
                                Rectangle {
                                    anchors.fill: parent
                                    anchors.leftMargin: -6
                                    anchors.rightMargin: -6
                                    color: Theme.withAlpha("#4fd48a", 0.12)
                                    opacity: ar.hot ? 1 : 0.5
                                    Behavior on opacity { NumberAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                                }
                                Row {
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 10
                                    Rectangle {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 6; height: 6; rotation: 45; color: "#e8c15c"
                                    }
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        textFormat: Text.PlainText   // guest-controlled: never markup
                                        text: Theme.mgsSafe(wp.shortName(ar.modelData.name)) + "  ASKS TO REJOIN"
                                        color: Theme.fg
                                        font.family: Theme.hudFont
                                        font.pixelSize: 22
                                    }
                                }
                                Rectangle {
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: letTxt.implicitWidth + 18
                                    height: 24
                                    radius: 5
                                    color: ar.hot ? Theme.withAlpha("#4fd48a", 0.22) : "transparent"
                                    border.color: ar.hot ? "#4fd48a" : Theme.dimFg
                                    border.width: 1
                                    Text {
                                        id: letTxt
                                        anchors.centerIn: parent
                                        text: "⏎ LET IN"
                                        color: ar.hot ? "#8fe3b0" : Theme.fg
                                        font.family: Theme.hudFont
                                        font.pixelSize: 19
                                        font.letterSpacing: 2
                                    }
                                }
                                MouseArea {
                                    id: askMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onPositionChanged: (mouse) => {
                                        if (wp.pointerMoved(askMouse, mouse.x, mouse.y))
                                            wp.pointTo(wp.acts.indexOf(ar.act))
                                    }
                                    onClicked: { Sfx.play("select"); App.partyUndrop(ar.modelData.id) }
                                }
                            }
                        }
                        Repeater {
                            model: wp.roomRows
                            delegate: Item {
                                id: rr
                                required property var modelData
                                readonly property string act: "g:" + modelData.id
                                readonly property bool canDrop: !modelData.me && modelData.id !== ""
                                readonly property bool hot: canDrop
                                    && (wp.focused(act) || rowMouse.containsMouse)
                                readonly property bool armed: wp.dropArmed === act
                                // Not watching (the card, a hidden tab): present
                                // in the room's list, but it isn't steering it.
                                readonly property bool out: modelData.state === "away"
                                                            || modelData.state === "card"
                                                            || !modelData.watching
                                width: parent.width
                                height: 30
                                // the cursor: a quiet wash, like the queue rows
                                Rectangle {
                                    anchors.fill: parent
                                    anchors.leftMargin: -6
                                    anchors.rightMargin: -6
                                    color: rr.armed ? Theme.withAlpha(Theme.warning, 0.16)
                                                    : Theme.withAlpha(Theme.accent, 0.10)
                                    opacity: rr.hot || rr.armed ? 1 : 0
                                    Behavior on opacity { NumberAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                                }
                                Row {
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 8
                                    Rectangle {
                                        width: 8; height: 8; radius: 4
                                        anchors.verticalCenter: parent.verticalCenter
                                        // Green under 80ms, amber to 250, red past
                                        // it; grey with no reading or not watching.
                                        color: rr.out || rr.modelData.rtt < 0
                                               ? Theme.dimFg
                                               : rr.modelData.rtt < 80 ? "#4fd48a"
                                               : rr.modelData.rtt < 250 ? "#e8c15c" : "#e5624d"
                                        opacity: rr.out ? 0.5 : 1
                                    }
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: Theme.mgsSafe(rr.modelData.rtt >= 0 ? rr.modelData.rtt + "ms" : "—")
                                        color: Theme.dimFg
                                        font.family: Theme.hudFont
                                        font.pixelSize: 22
                                        width: 46
                                        horizontalAlignment: Text.AlignRight
                                        opacity: rr.out ? 0.5 : 1
                                    }
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: Math.min(implicitWidth, rr.width - 300)
                                        elide: Text.ElideRight
                                        text: Theme.mgsSafe(rr.modelData.name + (rr.modelData.me ? " (you)" : ""))
                                        textFormat: Text.PlainText   // guest-controlled: never markup
                                        color: rr.armed ? Theme.warning
                                               : rr.modelData.me ? Theme.accent : Theme.fg
                                        font.family: Theme.hudFont
                                        font.pixelSize: 22
                                        opacity: rr.out ? 0.5 : 1
                                    }
                                }
                                // Right side: where they stand in the room — or,
                                // on the cursor, the DROP key (a real button).
                                Row {
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 10
                                    // earning a seat: a little meter that fills
                                    Row {
                                        visible: rr.modelData.state === "joining" && !rr.hot && !rr.armed
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: 2
                                        Repeater {
                                            model: 10
                                            Rectangle {
                                                required property int index
                                                width: 5; height: 9
                                                color: index < Math.round((rr.modelData.earn || 0) * 10)
                                                       ? "#e8c15c" : Theme.withAlpha(Theme.fg, 0.14)
                                            }
                                        }
                                    }
                                    Text {
                                        visible: !rr.hot && !rr.armed
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: rr.modelData.state === "seated" ? "IN THE ROOM"
                                              : rr.modelData.state === "joining" ? "JOINING"
                                              : rr.modelData.state === "away" ? "AWAY"
                                              : "NOT WATCHING"
                                        color: rr.modelData.state === "seated" ? Theme.accent
                                               : rr.modelData.state === "joining" ? "#e8c15c"
                                               : Theme.dimFg
                                        opacity: rr.out ? 0.6 : 1
                                        font.family: Theme.hudFont
                                        font.pixelSize: 19
                                        font.letterSpacing: 2
                                    }
                                    Rectangle {
                                        id: dropCap
                                        visible: rr.hot || rr.armed
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: dropTxt.implicitWidth + 18
                                        height: 24
                                        radius: 5
                                        color: rr.armed ? Theme.withAlpha(Theme.warning, 0.22) : "transparent"
                                        border.color: rr.armed ? Theme.warning : Theme.dimFg
                                        border.width: 1
                                        Text {
                                            id: dropTxt
                                            anchors.centerIn: parent
                                            // the name capped so the armed plate can't run over the row's own name
                                            text: rr.armed ? "⏎ DROP " + Theme.mgsSafe(wp.shortName(rr.modelData.name)).toUpperCase() + "?"
                                                           : "⏎ DROP"
                                            textFormat: Text.PlainText
                                            color: rr.armed ? Theme.warning : Theme.fg
                                            font.family: Theme.hudFont
                                            font.pixelSize: 19
                                            font.letterSpacing: 2
                                        }
                                    }
                                }
                                MouseArea {
                                    id: rowMouse
                                    anchors.fill: parent
                                    hoverEnabled: rr.canDrop
                                    enabled: rr.canDrop
                                    cursorShape: Qt.PointingHandCursor
                                    // REAL pointer motion only: the roster is rebuilt on every
                                    // poll, and a fresh row under a parked pointer gets a
                                    // synthetic hover — which yanked the keyboard cursor back
                                    // to it every 1-3 s (and disarmed a DROP armed elsewhere)
                                    onPositionChanged: (mouse) => {
                                        if (wp.pointerMoved(rowMouse, mouse.x, mouse.y))
                                            wp.pointTo(wp.acts.indexOf(rr.act))
                                    }
                                    // the whole row is the DROP button once it's
                                    // showing; the first press only arms it
                                    onClicked: { Sfx.play("select"); wp.dropPress(rr.act) }
                                }
                            }
                        }

                        // The cushion, as an instrument rather than a sentence.
                        // A sentence about it read as an apology for a fault;
                        // it isn't one — everyone being late together is the
                        // only way nobody is early. A meter states it the way a
                        // desk states level, and shows each screen's own need
                        // so "why are we at seven seconds" answers itself.
                        Item { width: 1; height: 8 }
                        SyncMeter {
                            width: parent.width
                            seconds: App.partyRoomLagMs >= 0
                                     ? App.partyRoomLagMs / 1000 : -1
                            lagWho: App.partyLagWho
                            waitingFor: App.partyWaitingFor
                            marks: {
                                var out = []
                                for (var i = 0; i < App.partyRoom.length; i++) {
                                    var r = App.partyRoom[i]
                                    if (r.watching && r.cushion >= 0)
                                        out.push({name: r.name, cushion: r.cushion,
                                                  me: r.me})
                                }
                                return out
                            }
                        }
                    }
                }
            }

            // ── join: this screen plays along ────────────────────────────
            Item {
                visible: wp.canJoin
                width: parent.width
                height: 53
                MechSelectRow {
                    id: joinPlate
                    bleed: true   // its light edge on the panel's text column
                    anchors.fill: parent
                    selected: wp.focused("join")
                    hovered: joinMouse.containsMouse
                    glass: wp.glass
                    armed: wp.visible
                }
                Row {
                    anchors.centerIn: parent
                    spacing: 12
                    // centred on the plate's dark face (its lighter foot is below)
                    transform: Translate { y: joinPlate.hopY + joinPlate.faceMid - joinPlate.height / 2 }
                    Text {
                        text: "▶"
                        color: Theme.accent
                        font.family: Theme.hudFont
                        font.pixelSize: 32
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        // "Watch here" follows the OUTPUT: a cast device joins
                        // ON THE TV, This Machine joins locally.
                        text: Theme.mgsSafe(Cast.targetId !== ""
                              ? "JOIN — ON " + Cast.targetName.toUpperCase()
                              : "JOIN — WATCH IT HERE TOO")
                        color: wp.focused("join") ? Theme.fg : Theme.dimFg
                        Behavior on color { ColorAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                        font.family: Theme.hudFont
                        font.pixelSize: 32
                        font.letterSpacing: 3
                        anchors.verticalCenter: parent.verticalCenter
                        style: Text.Raised; styleColor: "#000000"
                    }
                }
                MouseArea {
                    id: joinMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onEntered: wp.pointTo(wp.acts.indexOf("join"))
                    onClicked: { Sfx.play("select"); App.joinWatchParty() }
                }
            }

            // Playing our own copy costs nothing but the clock; streaming our
            // own film back to ourselves would be a worse picture.
            Text {
                visible: wp.canJoin
                width: parent.width
                wrapMode: Text.WordWrap
                text: Theme.mgsSafe(App.partyHaveFile
                      ? "Plays your copy off the shelf, in step with everyone else — "
                        + "full quality, nothing but the clock over the network."
                      : "This machine doesn't have the file, so it streams from the hub.")
                color: Theme.dimFg
                font.family: Theme.hudFont
                font.pixelSize: 24
                lineHeight: 1.2
            }

            // ── the room talks ───────────────────────────────────────────
            // The transcript lives here; the LIVE reading of it is the toast in
            // Main.qml, because during a film nobody opens a panel. This is for
            // catching up on what was said and for saying something back.
            Column {
                visible: App.partyLive
                width: parent.width
                spacing: 7

                Text {
                    text: App.partyChat.length > 0 ? "THE ROOM" : "THE ROOM   SAY SOMETHING"
                    color: Theme.dimFg
                    font.family: Theme.hudFont
                    font.pixelSize: 20
                    font.letterSpacing: 2
                }

                ListView {
                    id: chatLog
                    width: parent.width
                    // Derived from what is there, up to a ceiling: an empty
                    // room shouldn't reserve six lines of blank panel, and a
                    // long conversation shouldn't push the buttons off screen.
                    height: Math.min(126, contentHeight)
                    visible: App.partyChat.length > 0
                    model: App.partyChat
                    clip: true
                    interactive: contentHeight > height
                    // Talk arrives at the bottom, so that is where the view
                    // stays — a log that keeps its scroll position is a log
                    // showing you the wrong end of the conversation.
                    onCountChanged: Qt.callLater(positionViewAtEnd)
                    // Name and message on one BASELINE: two faces (the codec
                    // face, Departure Mono) top-aligned in a Row sat at
                    // different heights ("TH" floating above the line).
                    delegate: Item {
                        id: tl
                        required property var modelData
                        readonly property bool sys: modelData.kind === "sys"
                        readonly property real base: Math.max(sys ? 0 : whoTxt.baselineOffset, msgTxt.baselineOffset)
                        width: chatLog.width
                        height: Math.max(sys ? 0 : whoTxt.y + whoTxt.height, msgTxt.y + msgTxt.height) + 2
                        Text {
                            id: whoTxt
                            visible: !tl.sys
                            y: tl.base - baselineOffset
                            text: Theme.mgsSafe(tl.modelData.who)
                            textFormat: Text.PlainText   // guest-controlled: never markup
                            color: Theme.accent
                            // the codec face: its caps hold their own beside the
                            // message's Departure Mono (the HUD face's were a third)
                            font.family: Theme.codecFont
                            font.pixelSize: 16
                            width: Math.min(implicitWidth, 96)
                            elide: Text.ElideRight
                        }
                        Text {
                            id: msgTxt
                            x: tl.sys ? 0 : whoTxt.width + 12   // right after the name
                            y: tl.base - baselineOffset
                            width: chatLog.width - x
                            text: tl.sys ? Theme.mgsSafe(tl.modelData.text) : tl.modelData.text
                            textFormat: Text.PlainText   // guest-controlled: never markup
                            color: tl.sys ? Theme.dimFg : Theme.fg
                            // system lines in the HUD face; what people SAID in
                            // Departure Mono (real lowercase)
                            font.family: tl.sys ? Theme.hudFont : "Departure Mono"
                            font.pixelSize: tl.sys ? 20 : 15
                            wrapMode: Text.Wrap
                        }
                    }
                }

                // The message box wears the global search box's own frame
                // (search-home-tex, the "/" overlay's command bar): one family
                // of typing boxes. Lit (fully opaque) on the cursor or typing.
                Item {
                    id: sayBox
                    width: parent.width
                    height: 46
                    readonly property bool hot: wp.focused("say") || sayIn.activeFocus || sayMouse.containsMouse
                    BorderImage {
                        anchors.fill: parent
                        source: (App.heroDevRev, App.heroDevPath("search-home-tex") !== ""
                                 ? App.heroDevPath("search-home-tex") + "?v=" + App.heroDevRev
                                 : "qrc:/assets/mechui/search-home-tex.png")
                        smooth: false
                        border { left: 8; right: 8; top: 8; bottom: 8 }
                        horizontalTileMode: BorderImage.Stretch
                        verticalTileMode: BorderImage.Stretch
                        opacity: sayBox.hot ? 1.0 : 0.82
                        Behavior on opacity { NumberAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                    }
                    // MESSAGE... — the codec face, its cap ink on the box's
                    // centre line (the guests' page says the same thing)
                    FontMetrics { id: sayFm; font: sayIdle.font }
                    ShadowText {
                        id: sayIdle
                        x: 18 + (sayIn.activeFocus ? 4 : 0)
                        y: {
                            void sayFm.height
                            const r = sayFm.tightBoundingRect("H")
                            return Math.round(sayBox.height / 2 - (sayFm.ascent + r.y + r.height / 2))
                        }
                        visible: sayIn.text.length === 0
                        text: "MESSAGE..."
                        color: sayBox.hot ? Theme.fg : Theme.dimFg
                        Behavior on color { ColorAnimation { duration: DS.selFade } }
                        font.family: Theme.codecFont
                        font.pixelSize: 22
                        font.letterSpacing: 2
                    }

                    TextInput {
                        id: sayIn
                        anchors.fill: parent
                        anchors.leftMargin: 18
                        anchors.rightMargin: 18
                        verticalAlignment: TextInput.AlignVCenter
                        color: Theme.fg
                        // typed live in Departure Mono — real lowercase (the
                        // caps-only HUD face made everything read as shouting)
                        font.family: "Departure Mono"
                        font.pixelSize: 22
                        maximumLength: 180
                        clip: true
                        // Typing must not fire the overlay's shortcuts — every
                        // letter here is also a key that ends the party, copies
                        // the link or closes the panel.
                        // typing is not a DROP confirmation: an armed DROP is
                        // let go the moment the box takes the keyboard
                        onActiveFocusChanged: if (activeFocus) {
                            wp.dropArmed = ""
                            const i = wp.acts.indexOf("say")
                            if (i >= 0) wp.sel = i
                        }
                        Keys.onPressed: (event) => {
                            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                App.partySay(text)
                                text = ""
                                event.accepted = true
                            } else if (event.key === Qt.Key_Escape) {
                                // Esc backs out of the box and leaves the
                                // panel up.
                                //
                                // ⚠ `focus = false` FIRST, and it is not
                                // redundant. wp is a FocusScope, so
                                // wp.forceActiveFocus() gives the scope
                                // focus and the scope hands it straight back
                                // to whichever child still has `focus: true`
                                // — this box. On its own that call is a
                                // no-op you can't see: Esc appeared dead for
                                // as long as this panel has existed.
                                // Dropping the child's focus is what makes
                                // the scope itself the focused thing.
                                sayIn.focus = false
                                wp.forceActiveFocus()
                                Sfx.play("back")
                                event.accepted = true
                            }
                        }
                    }
                    MouseArea {
                        id: sayMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.IBeamCursor
                        onEntered: wp.pointTo(wp.acts.indexOf("say"))
                        onClicked: { Sfx.play("select"); sayIn.forceActiveFocus() }
                    }
                }

                Row {
                    width: parent.width
                    spacing: 7
                    Repeater {
                        model: ["haha", "wow", "fire", "heart", "clap", "eyes"]
                        delegate: Rectangle {
                            required property string modelData
                            width: 34; height: 28; radius: 7
                            color: rx.containsMouse ? Theme.surfaceHi : "transparent"
                            border.width: 1
                            border.color: Theme.border
                            Text {
                                anchors.centerIn: parent
                                text: ({haha: "😂", wow: "😮", fire: "🔥",
                                        heart: "❤️", clap: "👏", eyes: "👀"})[modelData]
                                font.pixelSize: 14
                            }
                            MouseArea {
                                id: rx
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: { Sfx.play("select"); App.partyReact(modelData) }
                            }
                        }
                    }
                    Rectangle {
                        width: 96; height: 28; radius: 7
                        visible: App.partyHubMode
                        color: rw.containsMouse ? Theme.surfaceHi : "transparent"
                        border.width: 1
                        border.color: App.partyVotes > 0 ? Theme.accent : Theme.border
                        Text {
                            anchors.centerIn: parent
                            text: App.partyVotes > 0
                                  ? "◂◂ 30s " + App.partyVotes + "/" + App.partyVotesNeed
                                  : "◂◂ 30s"
                            color: App.partyVotes > 0 ? Theme.accent : Theme.dimFg
                            font.family: Theme.hudFont
                            font.pixelSize: 20
                            font.letterSpacing: 1
                        }
                        MouseArea {
                            id: rw
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { Sfx.play("select"); App.partyVoteRewind() }
                        }
                    }
                }
            }

            // ── the invite link ──────────────────────────────────────────
            Column {
                visible: App.partyLive
                width: parent.width
                spacing: 7
                Text {
                    text: "INVITE LINK"
                    color: Theme.dimFg
                    font.family: Theme.hudFont
                    font.pixelSize: 20
                    font.letterSpacing: 2
                }
                Item {
                    width: parent.width
                    height: 48
                    MechSelectRow {
                        id: copyPlate
                        bleed: true   // its light edge on the panel's text column
                        anchors.fill: parent
                        selected: wp.focused("copy")
                        hovered: copyMouse.containsMouse
                        glass: wp.glass
                        armed: wp.visible
                    }
                    MouseArea {
                        id: copyMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onEntered: wp.pointTo(wp.acts.indexOf("copy"))
                        onClicked: { Sfx.play("select"); App.copyText(App.partyInviteUrl) }
                    }
                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: 18
                        anchors.right: copyBtn.left
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.verticalCenterOffset: copyPlate.faceMid - copyPlate.height / 2   // the dark face
                        elide: Text.ElideMiddle
                        text: Theme.mgsSafe(App.partyInviteUrl.length > 0
                              ? App.partyInviteUrl
                              : "no public link — enable Tailscale Funnel (docs/PARTY.md)")
                        color: App.partyInviteUrl.length > 0 ? Theme.fg : Theme.dimFg
                        font.family: Theme.hudFont
                        font.pixelSize: 24
                        style: Text.Raised; styleColor: "#000000"
                    }
                    Rectangle {
                        id: copyBtn
                        anchors.right: parent.right
                        anchors.rightMargin: 16
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.verticalCenterOffset: copyPlate.faceMid - copyPlate.height / 2   // the dark face
                        width: 72
                        height: 24
                        radius: 5
                        visible: App.partyInviteUrl.length > 0
                        color: "transparent"
                        border.color: Theme.accent
                        border.width: 1
                        Text {
                            anchors.centerIn: parent
                            text: "c COPY"
                            color: Theme.accent
                            font.family: Theme.hudFont
                            font.pixelSize: 19
                            font.letterSpacing: 2
                        }
                        MouseArea { anchors.fill: parent; onClicked: { Sfx.play("select"); App.copyText(App.partyInviteUrl) } }
                    }
                }
                // Lock the room: nobody new gets in with the link — everyone
                // already here (and their TVs, and anything in the house) stays.
                Item {
                    width: parent.width
                    height: 48
                    MechSelectRow {
                        id: lockPlate
                        bleed: true
                        anchors.fill: parent
                        selected: wp.focused("lock")
                        hovered: lockMouse.containsMouse
                        glass: wp.glass
                        armed: wp.visible
                    }
                    Row {
                        anchors.left: parent.left
                        anchors.leftMargin: 18
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.verticalCenterOffset: lockPlate.faceMid - lockPlate.height / 2
                        spacing: 12
                        transform: Translate { y: lockPlate.hopY }
                        Text {
                            text: App.partyLocked ? "󰌾" : "󰌿"
                            color: App.partyLocked ? Theme.accent : Theme.dimFg
                            font.family: Theme.monoFont; font.pixelSize: 17
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Text {
                            text: App.partyLocked ? "ROOM LOCKED" : "LOCK ROOM"
                            color: App.partyLocked || wp.focused("lock") ? Theme.fg : Theme.dimFg
                            Behavior on color { ColorAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                            font.family: Theme.hudFont; font.pixelSize: 26; font.letterSpacing: 2
                            style: Text.Raised; styleColor: "#000000"
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                    Text {
                        anchors.right: parent.right
                        anchors.rightMargin: 18
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.verticalCenterOffset: lockPlate.faceMid - lockPlate.height / 2
                        text: App.partyLocked ? "NOBODY NEW GETS IN" : "ANYONE WITH THE LINK"
                        color: App.partyLocked ? Theme.accent : Theme.dimFg
                        font.family: Theme.hudFont
                        font.pixelSize: 19
                        font.letterSpacing: 2
                    }
                    MouseArea {
                        id: lockMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onEntered: wp.pointTo(wp.acts.indexOf("lock"))
                        onClicked: { Sfx.play("select"); App.partyLock(!App.partyLocked) }
                    }
                }
            }

            // ── who's on which screen ────────────────────────────────────
            Column {
                visible: App.partyLive
                width: parent.width
                spacing: 6

                Item {
                    width: parent.width
                    height: 46
                    // Not a button — a display row, so it wears the queue's NOW
                    // frame (queue-now) rather than a selectable family-6 plate.
                    MechSlice {
                        anchors.fill: parent
                        source: "qrc:/assets/mechui/queue-now.png"
                        opacity: wp.glass
                        artL: 6; artR: 6; artT: 4; artB: 4
                        px: 2
                    }
                    Row {
                        x: 20; spacing: 12
                        anchors.verticalCenter: parent.verticalCenter
                        Text {
                            text: "󰍹"
                            color: App.partyActive ? Theme.accent : Theme.dimFg
                            font.family: Theme.monoFont; font.pixelSize: 17
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Text {
                            text: "THIS SCREEN"
                            color: Theme.fg
                            font.family: Theme.hudFont; font.pixelSize: 26; font.letterSpacing: 2
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                    // "Driving" is the honest word: whoever presses the keys moves
                    // every screen at once, even in a hub-owned session nobody hosts.
                    MechStatus {
                        anchors.right: parent.right; anchors.rightMargin: 20
                        anchors.verticalCenter: parent.verticalCenter
                        dot: App.partyActive
                        label: App.partyDriving || App.partyHosting ? "HOSTING"
                               : App.partyFollowing ? "WATCHING"
                                                    : "NOT JOINED"
                        ink: App.partyActive ? Theme.accent : Theme.dimFg
                        px: 20
                    }
                }

                Item {
                    width: parent.width
                    height: 46
                    MechSlice {
                        anchors.fill: parent
                        source: "qrc:/assets/mechui/queue-now.png"
                        opacity: wp.glass
                        artL: 6; artR: 6; artT: 4; artB: 4
                        px: 2
                    }
                    Row {
                        x: 20; spacing: 12
                        anchors.verticalCenter: parent.verticalCenter
                        Text {
                            text: "󰄘"
                            color: App.partyPeers > 1 ? Theme.accent : Theme.dimFg
                            font.family: Theme.monoFont; font.pixelSize: 17
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Text {
                            text: "OTHER SCREENS   VIA LINK"
                            color: Theme.fg
                            font.family: Theme.hudFont; font.pixelSize: 26; font.letterSpacing: 2
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                    MechStatus {
                        anchors.right: parent.right; anchors.rightMargin: 20
                        anchors.verticalCenter: parent.verticalCenter
                        // count of everyone ELSE (we're one of the peers once joined)
                        dot: (App.partyPeers - (App.partyFollowing ? 1 : 0)) > 0
                        label: {
                            var others = App.partyPeers - (App.partyFollowing ? 1 : 0)
                            return others > 0 ? others + " CONNECTED" : "WAITING…"
                        }
                        ink: App.partyPeers > 1 ? Theme.accent : Theme.dimFg
                        px: 20
                    }
                }
            }

            // ── end it for everyone ──────────────────────────────────────
            Item {
                visible: App.partyLive
                width: parent.width
                height: 43
                MechSelectRow {
                    id: endPlate
                    bleed: true   // its light edge on the panel's text column
                    anchors.fill: parent
                    selected: wp.focused("end")
                    hovered: endMouse.containsMouse
                    glass: wp.glass
                    armed: wp.visible
                }
                Text {
                    anchors.centerIn: parent
                    // centred on the plate's dark face (its lighter foot is below)
                    transform: Translate { y: endPlate.hopY + endPlate.faceMid - endPlate.height / 2 }
                    // Kept warning-coloured — the plate carries the selection, the
                    // text still flags that this ends it for everyone.
                    text: "✕  END FOR EVERYONE"
                    color: wp.focused("end") ? Theme.warning : Theme.dimFg
                    Behavior on color { ColorAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                    font.family: Theme.hudFont
                    font.pixelSize: 26
                    font.letterSpacing: 2
                    style: Text.Raised; styleColor: "#000000"
                }
                MouseArea {
                    id: endMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onEntered: wp.pointTo(wp.acts.indexOf("end"))
                    onClicked: { Sfx.play("select"); App.endWatchParty() }
                }
            }

            // ── hint ─────────────────────────────────────────────────────
            KeyHints {
                width: parent.width
                px: 13
                model: {
                    let m = wp.acts.length > 1
                            ? [["↑↓ jk", "MOVE"]]
                            : [["⏎", "START"]]
                    // on the message box ⏎ would say TALK beside t TALK
                    if (wp.acts.length > 1 && wp.curLabel() !== "TALK")
                        m.push(["⏎", wp.curLabel()])
                    // (c COPY lives on the invite plate itself; one line of hints)
                    if (App.partyLive)
                        m.push(["t", "TALK"],
                               ["l", App.partyLocked ? "UNLOCK" : "LOCK"], ["x", "END"])
                    m.push(["w/esc", wp.dropArmed !== "" ? "CANCEL" : "CLOSE"])
                    return m
                }
            }
        }
    }
}
