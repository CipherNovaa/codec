import QtQuick

// `p` while casting — transport control for whatever the TV is playing.
// Same keys as the local player: space/k pause, h/l ±10s (shift ±60),
// j/arrows ±60s, 9/0 volume, n next, b/N prev, q queue alongside,
// x stop, esc/p close.
FocusScope {
    id: remote
    // The CRT inset (Main's crtL..crtB): the scrim runs out under the tube's
    // overscan so the glass dims edge to edge, not inside a black frame.
    property int bleed: 0

    visible: App.remoteOpen
    property bool sfxReady: false            // the built panel settling hidden isn't a close
    Component.onCompleted: sfxReady = true
    onVisibleChanged: {
        if (visible) forceActiveFocus()
        // UI sounds: the remote opening/closing — p, the strip's chip, a party
        // jump. Its keys are all transport, and stay silent.
        if (sfxReady) Sfx.play(visible ? "open" : "back")
    }

    readonly property bool playing: Cast.castState === "PLAYING"
                                    || Cast.castState === "BUFFERING"
    property real glass: App.glassLevel

    function devSrc(rel) {
        var d = App.heroDevPath(rel)
        return d !== "" ? d + "?v=" + App.heroDevRev : "qrc:/assets/mechui/" + rel + ".png"
    }

    // What plays after this: the queue's head, or the episode chain.
    readonly property var nextUp: {
        let out = []
        const n = Math.min(3, Queue.count)
        for (let i = 0; i < n; ++i) {
            const it = Queue.itemAt(i)
            if (it && it.title) out.push(it.title)
        }
        if (out.length === 0 && Cast.castUri.length > 0) {
            const ep = MediaLibrary.nextEpisode(Cast.castUri)
            if (ep && ep.path) out.push(ep.show + "  " + ep.title)
        }
        return out
    }

    Keys.onPressed: (event) => {
        CLog.d("remote", "key " + event.key + " state=" + Cast.castState
               + " pos=" + Cast.castPosition.toFixed(1))
        switch (event.key) {
        case Qt.Key_Space: case Qt.Key_K: App.castTogglePause(); break
        case Qt.Key_H:
        case Qt.Key_Left:
            App.castSeekRel(event.modifiers & Qt.ShiftModifier ? -60 : -5); break
        case Qt.Key_L:
        case Qt.Key_Right:
            App.castSeekRel(event.modifiers & Qt.ShiftModifier ? 60 : 5); break
        case Qt.Key_Up: App.castSeekRel(60); break
        case Qt.Key_Down: case Qt.Key_J: App.castSeekRel(-60); break
        case Qt.Key_9: Cast.volumeDown(); break
        case Qt.Key_0: Cast.volumeUp(); break
        case Qt.Key_S:
            // s = clean subs ON/OFF (English text sub ↔ off); shift+s = cycle
            // through the languages (#234). Matches the TV remote, which already
            // splits toggle (Subtitle key) from cycle.
            if (event.modifiers & Qt.ShiftModifier) App.castCycleSub()
            else App.castToggleSub()
            break
        case Qt.Key_F: App.findSubtitles(); break   // fetch a subtitle for the film casting (again: refetch)
        case Qt.Key_A: App.castCycleAudio(); break
        case Qt.Key_Z: App.castCycleScreenMode(); break
        case Qt.Key_BracketLeft: App.castStepRate(-1); break
        case Qt.Key_BracketRight: App.castStepRate(1); break
        case Qt.Key_Backspace: App.castStepRate(0); break
        case Qt.Key_N:
            if (event.modifiers & Qt.ShiftModifier) App.castPrev()
            else App.castNext()
            break
        case Qt.Key_B: App.castPrev(); break
        case Qt.Key_X: App.stopPlayback(); break
        case Qt.Key_C: App.remoteOpen = false; App.outputOpen = true; break
        case Qt.Key_Q:
            // Full queue slides in NEXT TO the remote — both stay live.
            App.queueOpen = !App.queueOpen
            break
        case Qt.Key_P: case Qt.Key_Escape:
            App.remoteOpen = false; break
        default: return
        }
        event.accepted = true
    }

    Rectangle {
        anchors.fill: parent
        anchors.margins: -remote.bleed
        color: Theme.withAlpha(Theme.bg, 0.72)
        // hoverEnabled swallows hover — without it the cursor still drove
        // the home page's hover-selection through the overlay.
        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            onClicked: App.remoteOpen = false
        }
    }

    Panel {
        anchors.centerIn: parent
        width: Math.min(640, parent.width - 120)
        height: col.height + 44
        color: Theme.withAlpha(Theme.bg, 0.96 * remote.glass)
        active: false
        border.width: 0

        BorderImage {
            anchors.fill: parent
            source: (App.heroDevRev, remote.devSrc("queue-tex"))
            smooth: false
            opacity: remote.glass
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
            spacing: 16

            Item {
                width: parent.width
                height: 18
                Text {
                    text: "CAST REMOTE"
                    color: Theme.accent
                    font.family: Theme.codecFont
                    font.pixelSize: 14
                    font.letterSpacing: 5
                }
                Text {
                    anchors.right: parent.right
                    text: Theme.mgsSafe("→ " + Cast.targetName.toUpperCase())
                    color: Theme.dimFg
                    font.family: Theme.hudFont
                    font.pixelSize: 20
                    font.letterSpacing: 2
                }
            }

            Row {
                spacing: 14
                Text {
                    text: remote.playing ? "▶" : "⏸"
                    color: Theme.accent
                    font.family: Theme.hudFont
                    font.pixelSize: 44
                    anchors.verticalCenter: parent.verticalCenter
                }
                Column {
                    spacing: 4
                    anchors.verticalCenter: parent.verticalCenter
                    Text {
                        text: Theme.mgsSafe(Cast.castTitle.length > 0 ? Cast.castTitle : "—")
                        color: Theme.fg
                        font.family: Theme.hudFont
                        font.pixelSize: 32
                        font.letterSpacing: 1
                        width: Math.min(implicitWidth, 520)
                        elide: Text.ElideRight
                    }
                    Text {
                        function trackName(list, idx, offLabel) {
                            if (idx < 0 || idx >= list.length) return offLabel
                            const t = list[idx]
                            return t.lang && t.lang.length > 0 ? t.lang : "#" + (t.i + 1)
                        }
                        text: Theme.mgsSafe(Cast.castState
                              + (Cast.castVolume > 0
                                 ? "  ·  VOL " + Math.round(Cast.castVolume * 100) + "%"
                                 : "")
                              + "  ·  A:" + trackName(Cast.castAudioTracks, Cast.castAudioIndex, "—")
                              + "  S:" + trackName(Cast.castSubTracks, Cast.castSubIndex, "off")
                              + (Cast.castScreenMode !== "fit"
                                 ? "  ·  " + Cast.castScreenMode.toUpperCase() : "")
                              + (Math.abs(Cast.castRate - 1.0) > 0.01
                                 ? "  ·  " + Cast.castRate + "×" : ""))
                        color: Theme.dimFg
                        font.family: Theme.hudFont
                        font.pixelSize: 20
                        font.letterSpacing: 2
                    }
                }
            }

            // Seek bar — click anywhere on it to jump.
            Item {
                width: parent.width
                height: 26
                Rectangle {
                    id: track
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width
                    height: 4
                    radius: 2
                    color: Theme.withAlpha(Theme.fg, 0.15)
                    Rectangle {
                        width: Cast.castDuration > 0
                               ? parent.width * Math.min(1, Cast.castPosition / Cast.castDuration)
                               : 0
                        height: parent.height
                        radius: 2
                        color: Theme.accent
                    }
                }
                // Chapter marks. PlayerView's delegate was lifted verbatim first and
                // read wrong here: its bar is thicker and brighter, so 5px ticks
                // standing 2px clear of a 4px track became a fence AROUND the bar
                // rather than graduations ON it. The bar is the instrument; the
                // chapters are a scale printed on it. So: short, tight to the track,
                // and in the bar's OWN colour, so they read as part of the instrument
                // rather than something laid over it. Whole pixels, because
                // a 1px hairline on a half pixel renders as a 2px grey smear.
                Repeater {
                    model: App.castChapters
                    delegate: Item {
                        required property var modelData
                        x: Cast.castDuration > 0
                           ? Math.round(track.width * Math.min(
                                 1, (modelData.time || 0) / Cast.castDuration))
                           : -10
                        visible: Cast.castDuration > 0 && (modelData.time || 0) > 1
                        // Flush against the track, not floating beside it. With a
                        // gap the pair read as two dashes AROUND the bar; touching
                        // it they read as one graduation THROUGH it, which is what
                        // a scale on an instrument looks like.
                        //
                        // In the UNPLAYED track's colour, not the accent: the accent
                        // means "watched this far", and chapters have nothing to do
                        // with progress. Bound to track.color rather than repeating
                        // the value, so the two can never drift apart.
                        Rectangle {
                            x: -1              // centre a 2px mark on the tick
                            y: track.y - height
                            width: 2; height: 3
                            color: track.color
                            antialiasing: false
                        }
                        Rectangle {
                            x: -1
                            y: track.y + track.height
                            width: 2; height: 3
                            color: track.color
                            antialiasing: false
                        }
                    }
                }
                MouseArea {
                    id: castSeekHover
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: (mouse) => {
                        // #218: route through AppController so an absolute scrub
                        // reaches the ROOM in a party-via-cast (not just this TV,
                        // which no longer chases the clock). Plain casts: just seeks.
                        if (Cast.castDuration > 0)
                            App.castSeekTo(Cast.castDuration * mouse.x / width)
                    }
                }

                // Hover bubble: which chapter you are pointing at, and the time.
                // The name is the reason to hover at all — a bare timestamp does not
                // tell you whether that tick is the one you want. Plenty of rips
                // carry unnamed chapters (A Christmas Carol's 16 are all blank), so
                // fall back to the ordinal rather than showing an empty line.
                Rectangle {
                    id: castTipBox
                    readonly property real hoverT: Cast.castDuration
                                                   * castSeekHover.mouseX
                                                   / Math.max(1, castSeekHover.width)
                    readonly property string chapLabel: {
                        const cs = App.castChapters
                        if (!cs || cs.length === 0) return ""
                        let i = -1
                        for (let k = 0; k < cs.length; k++) {
                            if (hoverT >= (cs[k].time || 0)) i = k; else break
                        }
                        if (i < 0) i = 0
                        const nm = (cs[i].title || "").trim()
                        // A "name" that is just a timestamp or the word Chapter is
                        // not a name — some rips fill the field with 00:07:08.970,
                        // which tells you less than the ordinal does.
                        const useless = nm.length === 0
                              || /^\d{1,2}:\d{2}:\d{2}([.,]\d+)?$/.test(nm)
                              || /^chapter\s*\d+$/i.test(nm)
                        return useless ? ("CHAPTER " + (i + 1)) : Theme.mgsSafe(nm)
                    }
                    visible: castSeekHover.containsMouse && Cast.castDuration > 0
                    x: Math.max(0, Math.min(parent.width - width,
                                            castSeekHover.mouseX - width / 2))
                    y: -height - 8
                    width: Math.max(castTip.width, castChap.width) + 20
                    height: castCol.height + 10
                    radius: 6
                    color: Theme.withAlpha(Theme.bg, 0.95)
                    border.color: Theme.border
                    border.width: 1
                    Column {
                        id: castCol
                        anchors.centerIn: parent
                        spacing: 1
                        Text {
                            id: castChap
                            anchors.horizontalCenter: parent.horizontalCenter
                            visible: castTipBox.chapLabel.length > 0
                            text: castTipBox.chapLabel
                            color: Theme.withAlpha(Theme.fg, 0.65)
                            font.family: Theme.hudFont
                            font.pixelSize: 13
                            font.letterSpacing: 1
                        }
                        Text {
                            id: castTip
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: App.prettyTime(castTipBox.hoverT)
                            color: Theme.fg
                            font.family: Theme.hudFont
                            font.pixelSize: 20
                            font.letterSpacing: 1
                        }
                    }
                }
            }

            Item {
                width: parent.width
                height: 14
                Text {
                    text: App.prettyTime(Cast.castPosition)
                    color: Theme.fg
                    font.family: Theme.hudFont
                    font.pixelSize: 22
                }
                Text {
                    anchors.right: parent.right
                    text: App.prettyTime(Cast.castDuration)
                    color: Theme.dimFg
                    font.family: Theme.hudFont
                    font.pixelSize: 22
                }
            }

            // Up next — the queue's head at a glance (q for the full panel).
            Column {
                width: parent.width
                spacing: 5
                visible: remote.nextUp.length > 0
                Text {
                    text: "UP NEXT"
                    color: Theme.dimFg
                    font.family: Theme.hudFont
                    font.pixelSize: 20
                    font.letterSpacing: 4
                }
                Repeater {
                    model: remote.nextUp
                    delegate: Row {
                        required property string modelData
                        required property int index
                        spacing: 8
                        Text {
                            text: index === 0 ? "▸" : (index + 1) + ""
                            color: index === 0 ? Theme.accent : Theme.dimFg
                            font.family: Theme.hudFont
                            font.pixelSize: 22
                        }
                        Text {
                            text: Theme.mgsSafe(modelData)
                            color: index === 0 ? Theme.fg : Theme.dimFg
                            font.family: Theme.hudFont
                            font.pixelSize: 24
                            width: Math.min(implicitWidth, 520)
                            elide: Text.ElideRight
                        }
                    }
                }
                Text {
                    visible: Queue.count > remote.nextUp.length
                    text: "+ " + (Queue.count - remote.nextUp.length) + " MORE IN QUEUE"
                    color: Theme.dimFg
                    font.family: Theme.hudFont
                    font.pixelSize: 18
                    font.letterSpacing: 2
                }
            }

            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: "space pause   h/l ±5s   9/0 vol   s subs (⇧ lang · f fetch)   a audio   z screen"
                      + "\n[ ] speed   n next   b prev   q queue   x stop   c output   esc close"
                color: Theme.dimFg
                font.family: Theme.hudFont
                font.pixelSize: 20
                font.letterSpacing: 1
                lineHeight: 1.3
            }
        }
    }
}
