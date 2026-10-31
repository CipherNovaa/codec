import QtQuick

// Attract mode — what the room sees when nobody is driving.
//
// An arcade cabinet doesn't sit on a menu; it plays its demo loop. After a
// spell of no input on a browse screen this takes the whole display: backdrop
// art, slowly drifting, the title on it in the house grammar — its logo, the
// spotlight's badges and meta line, and the synopsis DECODING under redaction
// bars like the home info sheet and the party invite. Each title stays until
// its synopsis has read through, then a beat more.
//
// Stills, not trailers — no audio starts itself in this house, and a poster
// wall that suddenly makes noise is a worse houseguest than a dark screen.
//
// Any input at all dismisses it, and AppController swallows that first event
// so waking the screen never also presses play.
Item {
    id: attract
    // The CRT inset (Main's crtL..crtB): the art and scrim run out under the tube's
    // overscan so the glass fills edge to edge, not inside a black frame.
    property int bleed: 0
    // HOME, for the spotlight's own badge plates and dials (Main passes it)
    property var home: null
    anchors.fill: parent
    visible: App.attract
    z: 50

    readonly property real s: Math.max(0.95, Math.min(width / 1920, 1.35))
    readonly property bool onCrt: App.mode === "crt"
    // Both MGS faces sit on a 16-px em grid: whole multiples of 16 draw every
    // font pixel the same width. Everything here picks one of those sizes.
    readonly property bool big: s >= 1.2
    readonly property int clockPx: 16 * (big ? 8 : 6)        // 128 · 96
    readonly property int textPx: 32                          // meta, date, synopsis
    readonly property int keyPx: big ? 32 : 16 * 1.5          // PRESS ANY KEY
    // the frame: a tube's glass edge is already a frame, so the CRT sits closer
    readonly property int mx: Math.round((onCrt ? 40 : 72) * s)
    readonly property int my: Math.round((onCrt ? 34 : 56) * s)

    property var items: []
    property int idx: 0
    readonly property var cur: items.length > 0 ? items[idx] : null

    // Art is picked once per entry into attract mode, not once per app start:
    // the shuffle should differ each evening.
    onVisibleChanged: {
        if (!visible) {
            dwell.stop(); swap.stop(); plot.reset()
            return
        }
        items = MediaLibrary.spotlight(60)
        idx = 0
        artA.assign()
        block.opacity = 1
        startTitle()
    }

    // Start over on a given list (the shot harness pins titles with this).
    function playList(list) {
        items = list; idx = 0
        artA.assign(); block.opacity = 1
        startTitle()
    }

    // ── The loop ──────────────────────────────────────────────────────────
    // A title holds until its synopsis has decoded, then `rest` more — never
    // less than `minMs`, so a title with no synopsis still gets its moment.
    readonly property int minMs: 11000
    readonly property int rest: 6000
    function startTitle() {
        plot.reset()
        revealDelay.restart()
        dwell.interval = Math.max(minMs, plot.revealMs + 900 + rest)
        dwell.restart()
    }
    Timer { id: revealDelay; interval: 900; onTriggered: plot.run() }   // after the art lands
    Timer {
        id: dwell
        onTriggered: if (attract.items.length > 1) swap.restart()
    }
    // Words out, the next title's art crossfades in, words back.
    SequentialAnimation {
        id: swap
        NumberAnimation { target: block; property: "opacity"; to: 0; duration: 450; easing.type: Easing.InQuad }
        ScriptAction {
            script: {
                attract.idx = (attract.idx + 1) % attract.items.length
                // Alternate the two Images so one can fade up over the other; a
                // single Image would flash empty while the next file decodes.
                if (artA.opacity > 0.5) artB.assign()
                else artA.assign()
                attract.startTitle()
            }
        }
        NumberAnimation { target: block; property: "opacity"; to: 1; duration: 700; easing.type: Easing.OutQuad }
    }

    Rectangle { anchors.fill: parent; anchors.margins: -attract.bleed; color: Theme.bg }

    component Art: Image {
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        anchors.fill: parent
        opacity: 0
        // A very slow push-in stops a static wall of stills from reading as a
        // frozen app — the same reason attract loops move at all.
        scale: opacity > 0.5 ? 1.06 : 1.0
        Behavior on opacity { NumberAnimation { duration: 1600 } }
        Behavior on scale { NumberAnimation { duration: 24000 } }
    }
    Art {
        id: artA
        anchors.margins: -attract.bleed
        function assign() {
            const it = attract.cur
            source = (it && it.fanart) ? Theme.art(it.fanart) : ""
            opacity = source == "" ? 0 : 1
            artB.opacity = 0
        }
    }
    Art {
        id: artB
        anchors.margins: -attract.bleed
        function assign() {
            const it = attract.cur
            source = (it && it.fanart) ? Theme.art(it.fanart) : ""
            opacity = source == "" ? 0 : 1
            artA.opacity = 0
        }
    }

    // Scrims: the words sit lower-left, the clock upper-right — darken where
    // they are and leave the art its middle.
    Rectangle {
        anchors.fill: parent
        anchors.margins: -attract.bleed
        gradient: Gradient {
            GradientStop { position: 0.0; color: Theme.withAlpha(Theme.bg, 0.45) }
            GradientStop { position: 0.22; color: Theme.withAlpha(Theme.bg, 0.10) }
            GradientStop { position: 0.48; color: Theme.withAlpha(Theme.bg, 0.18) }
            GradientStop { position: 1.0; color: Theme.withAlpha(Theme.bg, 0.95) }
        }
    }
    Rectangle {
        anchors.fill: parent
        anchors.margins: -attract.bleed
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: Theme.withAlpha(Theme.bg, 0.55) }
            GradientStop { position: 0.55; color: "transparent" }
        }
    }

    // Pools of shade under the two corners that carry words — so the clock
    // and the title read over the brightest art (a white sky, Kill Bill's
    // white key art) without dimming the whole picture. Painted once.
    Canvas {
        id: pools
        anchors.fill: parent
        anchors.margins: -attract.bleed
        renderTarget: Canvas.Image
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: {
            const ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            const k = attract.s, b = attract.bleed
            function pool(cx, cy, r, a) {
                const g = ctx.createRadialGradient(cx, cy, 0, cx, cy, r)
                g.addColorStop(0, Theme.withAlpha(Theme.bg, a))
                g.addColorStop(0.55, Theme.withAlpha(Theme.bg, a * 0.55))
                g.addColorStop(1, Theme.withAlpha(Theme.bg, 0))
                ctx.fillStyle = g
                ctx.fillRect(0, 0, width, height)
            }
            // the clock: centred on its block
            pool(width - b - attract.mx - 170 * k, b + attract.my + 70 * k, 520 * k, 0.62)
            // the title: low on the left, wide enough for four lines of synopsis
            ctx.save()
            ctx.scale(1.9, 1)
            pool((b + attract.mx + 420 * k) / 1.9, height - b - attract.my - 150 * k, 560 * k, 0.55)
            ctx.restore()
        }
    }

    // ── Top: the house mark, and the clock ────────────────────────────────
    ShadowText {
        x: attract.mx
        // its caps level with the clock's (the codec face's caps start 1/8 em
        // under its box)
        y: attract.my + Math.round((attract.clockPx - font.pixelSize) / 8)
        text: "CODEC"
        color: Theme.withAlpha(Theme.fg, 0.92)
        font.family: Theme.codecFont
        font.pixelSize: 32
        font.letterSpacing: Math.round(8 * attract.s)
    }

    Column {
        anchors.right: parent.right
        anchors.rightMargin: attract.mx
        y: attract.my
        spacing: Math.round(10 * attract.s)
        // HH:MM in the codec face; the colon ticks with the seconds. Each digit
        // sits centred in a cell as wide as a "0" — the face's 1 is narrow, so
        // set proportionally "16:31" read "16:3 1".
        Row {
            anchors.right: parent.right
            spacing: 0
            // measured by Text, which re-lays out when the face loads (a
            // FontMetrics read the fallback's widths and the digits overlapped)
            Text { id: zeroW; visible: false; text: "0"; font.family: Theme.codecFont; font.pixelSize: attract.clockPx }
            Text { id: colonW; visible: false; text: ":"; font.family: Theme.codecFont; font.pixelSize: attract.clockPx }
            Repeater {
                model: Qt.formatTime(clock.now, "HH:mm").split("")
                Item {
                    required property string modelData
                    readonly property bool colon: modelData === ":"
                    width: colon ? colonW.implicitWidth : zeroW.implicitWidth
                    height: digit.height
                    ShadowText {
                        id: digit
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: parent.modelData
                        color: Theme.withAlpha(Theme.fg, 0.95)
                        opacity: parent.colon && !clock.tick ? 0.3 : 1
                        font.family: Theme.codecFont
                        font.pixelSize: attract.clockPx
                    }
                }
            }
        }
        ShadowText {
            anchors.right: parent.right
            text: Qt.formatDate(clock.now, "ddd · d MMM").toUpperCase()
            color: Theme.withAlpha(Theme.fg, 0.78)
            font.family: Theme.hudFont
            font.pixelSize: attract.textPx
            font.letterSpacing: Math.round(3 * attract.s)
        }
    }
    Timer {
        id: clock
        property date now: new Date()
        property bool tick: true
        interval: 1000
        repeat: true
        running: attract.visible
        triggeredOnStart: true
        onTriggered: { now = new Date(); tick = !tick }
    }

    // ── The title ─────────────────────────────────────────────────────────
    Column {
        id: block
        anchors.left: parent.left
        anchors.leftMargin: attract.mx
        anchors.bottom: parent.bottom
        anchors.bottomMargin: attract.my
        // leaves PRESS ANY KEY its corner
        width: Math.min(Math.round(1080 * attract.s),
                        parent.width - 2 * attract.mx - pressKey.width - Math.round(48 * attract.s))
        spacing: Math.round(18 * attract.s)
        visible: attract.cur !== null

        // Title: the clearlogo, bottom-aligned in a fixed slot so the lines
        // below never jump; the name in the codec face otherwise.
        Item {
            id: titleSlot
            width: parent.width
            height: Math.round(150 * attract.s)
            readonly property bool hasLogo: attract.cur !== null && (attract.cur.clearlogo || "").length > 0
            Image {
                id: logo
                visible: titleSlot.hasLogo && status !== Image.Error
                anchors.bottom: parent.bottom
                source: titleSlot.hasLogo ? Theme.art(attract.cur.clearlogo) : ""
                fillMode: Image.PreserveAspectFit
                mipmap: true
                asynchronous: true
                readonly property real asp: sourceSize.height > 0 ? sourceSize.width / sourceSize.height : 3
                readonly property real maxW: Math.min(titleSlot.width, Math.round(760 * attract.s))
                height: Math.min(titleSlot.height, maxW / Math.max(asp, 0.1))
                width: height * asp
            }
            ShadowText {
                visible: !logo.visible
                anchors.bottom: parent.bottom
                width: parent.width
                text: Theme.mgsSafe((attract.cur ? attract.cur.title : "").toUpperCase())
                color: Theme.fg
                font.family: Theme.codecFont
                font.pixelSize: 16 * (attract.big ? 5 : 4)
                font.letterSpacing: Math.round(4 * attract.s)
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
            }
        }

        // The spotlight's meta line: its badge plates, then year · runtime ·
        // genres · ★ rating as ONE line of the HUD face (the MGS separators
        // and star, so everything shares a baseline by construction).
        Row {
            id: metaRow
            spacing: Math.round(14 * attract.s)
            // a new arrival leads its plates with NEW
            readonly property var flags: (attract.cur && attract.cur.isNew ? ["NEW"] : [])
                                         .concat(attract.cur && attract.cur.flags ? attract.cur.flags : [])
            readonly property var h: attract.home
            readonly property bool chips: h !== null && h.mechOn && flags.length > 0 && h.mech.chipStyle !== "none"
            // where the line's cap ink centres against its own box
            FontMetrics { id: metaFm; font.family: Theme.hudFont; font.pixelSize: attract.textPx }
            readonly property real inkOff: {
                void metaFm.height
                const r = metaFm.tightBoundingRect("H")
                return metaFm.ascent + r.y + r.height / 2 - metaFm.height / 2
            }
            // the badge geometry, for the text's drop (never drawn)
            MechChip { id: chipProbe; visible: false; width: 0; px: 3; plateStyle: metaRow.chips ? metaRow.h.mech.chipStyle : "badge" }
            Repeater {
                model: metaRow.chips ? metaRow.flags : []
                delegate: MechChip {
                    required property var modelData
                    anchors.verticalCenter: parent.verticalCenter
                    px: 3                         // the label window seats 32-px caps
                    window: metaRow.h.mech.chipWin
                    plateStyle: metaRow.h.mech.chipStyle
                    flag: modelData
                    ink: metaRow.h.mechInk(metaRow.h.mech.chipInk)
                    text: metaRow.h.caseFor(modelData, metaRow.h.mech.chipCase)
                    font.family: metaRow.h.mFontFor("chip")
                    font.pixelSize: attract.textPx
                    font.letterSpacing: metaRow.h.trackFor(metaRow.h.mech.chipTrack)
                    font.weight: metaRow.h.weightFor(metaRow.h.mech.chipWeight)
                }
            }
            ShadowText {
                anchors.verticalCenter: parent.verticalCenter
                // onto the badges' label line (a chip's label sits in its
                // readout window, below the plate's middle)
                anchors.verticalCenterOffset: metaRow.chips ? Math.round(chipProbe.labelDrop - metaRow.inkOff) : 0
                textFormat: Text.StyledText
                text: {
                    const it = attract.cur
                    if (!it) return ""
                    const bits = []
                    if (it.year > 0) bits.push(String(it.year))
                    if (it.runtimeMin > 0)
                        bits.push(it.runtimeMin >= 60
                                  ? Math.floor(it.runtimeMin / 60) + "H" + (it.runtimeMin % 60) + "M"
                                  : it.runtimeMin + "M")
                    if ((it.genres || "").length > 0)
                        bits.push(Theme.mgsSafe(it.genres.toUpperCase()))
                    if ((it.rating || 0) > 0)
                        bits.push('<font color="' + Theme.accent + '">★</font> ' + Number(it.rating).toFixed(1))
                    return bits.join("  ·  ")
                }
                color: Theme.withAlpha(Theme.fg, 0.82)
                font.family: Theme.hudFont
                font.pixelSize: attract.textPx
                font.letterSpacing: Math.round(2 * attract.s)
            }
        }

        RedactText {
            id: plot
            width: parent.width
            visible: text.length > 0
            text: Theme.mgsSafe(attract.cur ? attract.cur.plot || "" : "")
            fontFamily: Theme.codecFont
            pixelSize: attract.textPx
            lineHeight: 1.5
            letterSpacing: Math.round(1 * attract.s)
            visibleLines: 4
            style: App.redactionStyle
            ink: Theme.withAlpha(Theme.fg, 0.9)
        }
    }

    // Arcade grammar: the prompt, breathing in the corner, on the block's last line.
    ShadowText {
        id: pressKey
        anchors.right: parent.right
        anchors.rightMargin: attract.mx
        anchors.bottom: parent.bottom
        anchors.bottomMargin: attract.my + Math.round((plot.lineH - height) / 2)
        text: "PRESS ANY KEY"
        color: Theme.withAlpha(Theme.fg, 0.75)
        font.family: Theme.hudFont
        font.pixelSize: attract.keyPx
        font.letterSpacing: Math.round(4 * attract.s)
        SequentialAnimation on opacity {
            running: attract.visible
            loops: Animation.Infinite
            NumberAnimation { to: 0.25; duration: 2200; easing.type: Easing.InOutQuad }
            NumberAnimation { to: 0.9; duration: 2200; easing.type: Easing.InOutQuad }
        }
    }
}
