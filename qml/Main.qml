import QtQuick
import QtQuick.Window
import Codec.Core

Window {
    id: root
    visible: true
    width: 1600
    height: 900
    title: "CODEC"
    color: "transparent"

    readonly property bool inPlayer: App.stage === "player"
    readonly property bool mediaLoaded: Engine.path.length > 0 && !Engine.idle
    property string clock: Qt.formatTime(new Date(), "hh:mm")
    // the colon breathes at 1Hz — a LIVE clock, not a printed one
    property bool clockColon: true
    // DEMO ONLY (temporary) — force the party + session chips visible with sample
    // text so the look/placement can be tuned without a real party. Set false / remove.
    property bool demoChips: false

    Timer {
        interval: 20000; running: true; repeat: true
        onTriggered: root.clock = Qt.formatTime(new Date(), "hh:mm")
    }
    Timer {
        interval: 1000; running: !root.inPlayer; repeat: true
        onTriggered: root.clockColon = !root.clockColon
    }

    Rectangle {
        anchors.fill: parent
        // Fullscreen = a media appliance, not a desktop window: fully opaque,
        // so the wallpaper can never ghost through the spotlight art. The
        // translucent rice look only applies when genuinely windowed (F11).
        color: root.inPlayer ? "#000000"
                             : Theme.withAlpha(Theme.bg,
                                   root.visibility === Window.FullScreen
                                       ? 1.0 : Math.min(Theme.alpha, 0.92))
        Behavior on color { ColorAnimation { duration: 260; easing.type: Easing.OutCubic } }
    }

    // ── Top telemetry strip ────────────────────────────────────────────────
    // Floats ABOVE the stage views (z) so home's spotlight art can bleed up
    // underneath it — the art's top fade keeps the labels readable.
    Item {
        id: header
        z: 3
        // Top-strip typefaces: CODEC wears the MGS "codec" face; everything else
        // up here (screen indicator, party/session/cast/clock/version) is MGS HUD.
        FontLoader { id: mgsCodec; source: "qrc:/assets/mechui/mgs-codec.ttf" }
        FontLoader { id: mgsHud;   source: "qrc:/assets/mechui/mgs-hud.ttf" }
        // Departure Mono (OFL, assets/mechui/departure-mono-OFL.txt): a pixel
        // mono WITH lowercase — for text the user types, where the caps-only
        // MGS faces hid the case. Drawn on an 11px grid: use multiples (22).
        FontLoader { id: departureMono; source: "qrc:/assets/mechui/departure-mono.otf" }
        readonly property string codecFont: mgsCodec.name || Theme.uiFont
        readonly property string hudFont:   mgsHud.name   || Theme.monoFont
        // top-strip sizes (MGS faces render small — bump to fit the 40px strip)
        property int codecPx: 25
        property int hudPx: 19
        property int crumbPx: 16    // the screen breadcrumb (codec face): 16 lands its caps on the strip line, 7 rows like the HUD bits
        property int screenPx: 16
        property int txtShadow: Text.Raised
        property color shadowInk: "#05080e"

        // ── ONE LINE ────────────────────────────────────────────────────────
        // Everything on this strip sits on a single line: the middle of its
        // capital letters lands on its row's vertical centre, and every row is
        // centred in the strip. Measured from each item's OWN font (FontMetrics)
        // rather than nudged by eye: mgs-codec and mgs-hud seat their caps at
        // different heights in their line boxes, so box-centring left CODEC,
        // the chips, the cast readout and the separators each a pixel or three
        // off — and the per-item `chipDy`/`castDy`/`sepDy` nudges that patched
        // it (plus hand-set MOVE offsets on top) drifted every time a size or
        // chip changed. Separators and the ●/◐ marks are DRAWN on the line: the
        // MGS faces have no ·, ● or ◐, so those came from a fallback font at its
        // own size and height.
        //
        // The strip's height on screen is ONE value — the TOP STRIP L group's
        // vertical MOVE offset carries the whole strip; per-group/chip MOVE
        // offsets keep their horizontal part only (vertical ones are exactly how
        // the line got broken).
        readonly property real lineDy: homeView.mOff("topLeft")[1]

        // A label on the line. `font` may be any face/size/weight — the offset is
        // computed from that font's own cap-height ink.
        component StripText: Text {
            id: st
            color: Theme.dimFg; font.family: header.hudFont
            font.pixelSize: header.hudPx; font.letterSpacing: 2
            style: header.txtShadow; styleColor: header.shadowInk
            FontMetrics { id: stMetrics; font: st.font }
            // middle of the capitals, relative to the baseline (negative = above).
            // ⚠ tightBoundingRect() is a METHOD — a binding calling it alone never
            // re-runs, and the first run is BEFORE the FontLoader finishes, i.e. the
            // fallback face's taller caps (that put every label 4px low). Reading
            // stMetrics.height ties it to the font actually loaded.
            readonly property real inkMid: {
                void stMetrics.height
                const r = stMetrics.tightBoundingRect("H")
                return r.y + r.height / 2
            }
            // where the cap middle sits inside this item's box
            readonly property real inkY: baselineOffset + inkMid
            anchors.verticalCenter: parent.verticalCenter
            anchors.alignWhenCentered: false
            anchors.verticalCenterOffset: height / 2 - inkY
        }
        // HudBit = a dim HUD label (the chips' segments).
        component HudBit: StripText {}
        // A separator: a square drawn ON the line (no fallback · glyph).
        component HudSep: Rectangle {
            // 3 SCREEN px, whatever the right group's MOVE scale: a 3px square
            // scaled 1.2 is 3.6px and snaps to 3 or 4 rows depending on where it
            // lands — the separators came out two different sizes. (All of them
            // live in the right group.)
            readonly property real d: Math.max(2, Math.round(header.hudPx * 0.16))
                                      / Math.max(0.01, homeView.mScale("topRight"))
            width: d; height: d
            anchors.verticalCenter: parent.verticalCenter
            anchors.alignWhenCentered: false
            // A square centred EXACTLY on the line puts its edges on pixel
            // centres — a tie the rasteriser breaks by float noise (3 rows here,
            // 4 there). A quarter screen-pixel down keeps every edge decisive.
            anchors.verticalCenterOffset: 0.25 / Math.max(0.01, homeView.mScale("topRight"))
            color: Theme.dimFg
        }
        // The party ● and session ◐ marks, drawn centred on the line.
        component StripMark: Item {
            property color color: Theme.dimFg
            property bool half: false
            // An ODD number of SCREEN px (right-group scale divided out) so the
            // disc has a middle row on the line; nudged a quarter pixel like
            // HudSep so no edge lands on a pixel centre.
            readonly property real sc: Math.max(0.01, homeView.mScale("topRight"))
            readonly property real d: (2 * Math.round((header.hudPx * 0.58 * sc - 1) / 2) + 1) / sc
            width: d; height: d
            anchors.verticalCenter: parent.verticalCenter
            anchors.alignWhenCentered: false
            anchors.verticalCenterOffset: 0.25 / sc
            Rectangle {
                anchors.fill: parent; radius: width / 2
                color: parent.half ? "transparent" : parent.color
                border.width: parent.half ? Math.max(1, Math.round(parent.d / 7)) : 0
                border.color: parent.color
            }
            Item {   // ◐ — the left half filled
                visible: parent.half
                width: Math.ceil(parent.width / 2); height: parent.height
                clip: true
                Rectangle { width: parent.parent.width; height: parent.height
                            radius: width / 2; color: parent.parent.color }
            }
        }
        // Hidden in attract mode too: the strip lives OUTSIDE the chrome
        // container, so no z inside it can cover the strip — it has to stand
        // down itself, same as it does in the player.
        visible: !root.inPlayer && App.stage !== "chooser" && App.stage !== "paths" && !App.attract
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: 28
        // (the CRT's glass edge is already a frame: the strip sits closer to it)
        anchors.topMargin: (root.onCrt ? 20 : 28) + root.crtT
        anchors.leftMargin: 28 + root.crtL
        anchors.rightMargin: 28 + root.crtR
        height: 40

        Row {  // LEFT group — CODEC + screen indicator (assembly: topLeft)
            id: headerLeft
            // Both groups span the strip's full height so they share ONE exact
            // centre line: centring a 16px group and an 11px group rounds each to
            // a whole pixel differently, half a pixel apart — a whole row on 7px caps.
            anchors.top: parent.top; anchors.bottom: parent.bottom
            spacing: 14
            transformOrigin: Item.Left
            scale: homeView.mScale("topLeft")
            transform: Translate { x: homeView.mOff("topLeft")[0]; y: header.lineDy }
            StripText {
                text: "CODEC"
                color: Theme.fg
                font.family: header.codecFont
                font.pixelSize: header.codecPx
                font.letterSpacing: 2
                font.weight: Font.Light
            }
            Rectangle { id: stripDivider; width: 1; height: 16; color: Theme.border
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.alignWhenCentered: false }
            StripText {
                // On YouTube and Settings their tabs take this place
                visible: App.stage !== "youtube" && App.stage !== "settings"
                text: {
                    if (App.stage === "home") return "HOME"
                    if (App.stage === "settings") return "SETTINGS"
                    if (App.stage === "stats") return "STATS"
                    if (App.stage === "youtube") {
                        // The tab's own label ("FOR YOU", not the id "rec"),
                        // and the channel / playlist / query once drilled in.
                        const labels = { search: "SEARCH", playlists: "PLAYLISTS",
                                         subs: "SUBS", watchlater: "WATCH LATER",
                                         history: "HISTORY", rec: "FOR YOU" }
                        const base = "YOUTUBE // " + (labels[YouTube.tab] || YouTube.tab.toUpperCase())
                        if (YouTube.context.length > 0 && (YouTube.drilled || YouTube.tab === "search"))
                            return (YouTube.tab === "search" && !YouTube.drilled ? "YOUTUBE // " : base + " // ")
                                   + YouTube.context.toUpperCase()
                        return base
                    }
                    if (MediaLibrary.section === "tv")
                        return MediaLibrary.showFilter.length > 0
                            ? "TV // " + MediaLibrary.showFilter.toUpperCase()
                            : "TV SHOWS"
                    return "MOVIES"
                }
                color: Theme.fg          // same ink as CODEC
                // the codec face (it has its own "/" now), like CODEC itself
                font.family: header.codecFont
                // match the RIGHT section's on-screen size: it renders at hudPx×topRight
                // scale; this lives in the topLeft group (topLeft scale), so divide it out
                font.pixelSize: Math.max(9, Math.round(header.crumbPx
                                 * homeView.mScale("topRight") / Math.max(0.01, homeView.mScale("topLeft"))))
                font.letterSpacing: 3
                // A YouTube channel name or a show filter goes in here at
                // arbitrary length, into a Row with no width, opposite another
                // Row with no width. On the CRT with a party running they met
                // in the middle and drew through each other. Give the variable
                // side whatever the fixed side leaves, and cut it there.
                elide: Text.ElideRight
                width: Math.max(0, Math.min(implicitWidth,
                                header.width - rightBlock.width - 190))
            }
        }

        Row {  // RIGHT group — party/session/cast/DISP/clock (assembly: topRight)
            id: rightBlock
            anchors.right: parent.right
            anchors.top: parent.top; anchors.bottom: parent.bottom   // see headerLeft
            spacing: 14
            transformOrigin: Item.Right
            scale: homeView.mScale("topRight")
            transform: Translate { x: homeView.mOff("topRight")[0]; y: header.lineDy }
            // Library enrichment in flight — the honest "it's working" signal so
            // a fresh import with no art yet never reads as broken. (A drawn mark,
            // not ⟳: the MGS face has no such glyph, so it fell back off the line.)
            Row {
                visible: App.libraryUpdating
                height: parent.height   // every strip container spans the strip: one centre line
                spacing: Math.round(header.hudPx * 0.42)
                StripMark { color: Theme.accent; half: true }
                StripText {
                    text: App.libraryNewCount > 0
                          ? "ENRICHING " + App.libraryNewCount + " NEW"
                          : "UPDATING LIBRARY"
                    color: Theme.accent
                }
                SequentialAnimation on opacity {
                    running: App.libraryUpdating
                    loops: Animation.Infinite
                    NumberAnimation { to: 0.35; duration: 700; easing.type: Easing.InOutQuad }
                    NumberAnimation { to: 1.0; duration: 700; easing.type: Easing.InOutQuad }
                }
            }
            // A watch party is running somewhere in the house. Opening codec
            // used to say nothing about it — you'd never know a movie was
            // playing on the TV. Click it to join, or to end it.
            Item {   // wrapper Item so the MouseArea can fill and the Row can position
                id: partyChip
                visible: App.partyLive || root.demoChips
                height: parent.height   // see the library row above
                transformOrigin: Item.Center
                scale: homeView.mScale("topParty")
                transform: Translate { x: homeView.mOff("topParty")[0] }   // the line owns y
                implicitWidth: partyRow.implicitWidth
                property color ink: Theme.fg          // brighter, matching the bright strip text
                // Breathe while live (drives pulse, not opacity, so pausing doesn't
                // strand a dimmed value); still runs on the real party state.
                property real pulse: 1.0
                opacity: App.partyPaused ? 1.0 : pulse
                SequentialAnimation on pulse {
                    running: App.partyLive && !App.partyPaused
                    loops: Animation.Infinite
                    NumberAnimation { to: 0.45; duration: 1100; easing.type: Easing.InOutQuad }
                    NumberAnimation { to: 1.0; duration: 1100; easing.type: Easing.InOutQuad }
                }
                // symbol kept OUT of the text segments — its tall glyph inflates the
                // line box and shoves the words off the row line otherwise
                property var segs: {
                    if (App.partyLive) {
                        var a = ["PARTY", App.partyTitle.toUpperCase()]
                        if (App.partyPaused) a.push("PAUSED")
                        a.push(App.prettyTime(App.partyPos))
                        if (App.partyPeers > 0) a.push(App.partyPeers + " WATCHING")
                        return a
                    }
                    return ["PARTY", "BLADE RUNNER 2049", "1:23:45", "3 WATCHING"]
                }
                Row {
                    id: partyRow
                    height: parent.height
                    spacing: Math.round(header.hudPx * 0.42)
                    StripMark { color: partyChip.ink }
                    Repeater {
                        model: partyChip.segs
                        delegate: Row {
                            required property var modelData
                            required property int index
                            height: parent ? parent.height : 0
                            spacing: Math.round(header.hudPx * 0.42)
                            HudSep { visible: index > 0; color: partyChip.ink }
                            HudBit { text: modelData; color: partyChip.ink }
                        }
                    }
                }
                MouseArea {   // same affordance as the resume-session chip: hover-brighten + click
                    anchors.fill: parent
                    hoverEnabled: true
                    onEntered: partyChip.ink = Theme.accent
                    onExited: partyChip.ink = Theme.fg
                    onClicked: App.partyOpen = true
                }
            }
            // Something is open on another codec in the house — no party, just
            // a film or a video left running on the other machine. Click to
            // take it, at the moment it reached; that screen stops.
            // Deliberately not the accent colour: a party is people, this is
            // only you, and two chips that look identical would read as one
            // thing happening twice.
            Item {   // wrapper Item (MouseArea fills, Row positions inside)
                id: sessionChip
                visible: (App.nowElsewhere && !App.partyLive) || root.demoChips
                height: parent.height
                transformOrigin: Item.Center
                scale: homeView.mScale("topSession")
                transform: Translate { x: homeView.mOff("topSession")[0] }   // the line owns y
                implicitWidth: sessionRow.implicitWidth
                property color ink: Theme.dimFg
                property real pulse: 1.0
                opacity: App.nowPaused ? 1.0 : pulse
                SequentialAnimation on pulse {
                    running: App.nowElsewhere && !App.nowPaused
                    loops: Animation.Infinite
                    NumberAnimation { to: 0.45; duration: 1100; easing.type: Easing.InOutQuad }
                    NumberAnimation { to: 1.0; duration: 1100; easing.type: Easing.InOutQuad }
                }
                property var segs: {
                    if (App.nowElsewhere) {
                        var a = ["ON " + App.nowWhere.toUpperCase(), App.nowTitle.toUpperCase()]
                        if (App.nowPaused) a.push("PAUSED")
                        a.push(App.prettyTime(App.nowPos))
                        a.push("PRESS E")
                        return a
                    }
                    return ["ON LIVING ROOM", "DUNE PART TWO", "0:42:10", "PRESS E"]
                }
                Row {
                    id: sessionRow
                    height: parent.height
                    spacing: Math.round(header.hudPx * 0.42)
                    StripMark { color: sessionChip.ink; half: true }
                    Repeater {
                        model: sessionChip.segs
                        delegate: Row {
                            required property var modelData
                            required property int index
                            height: parent ? parent.height : 0
                            spacing: Math.round(header.hudPx * 0.42)
                            HudSep { visible: index > 0; color: sessionChip.ink }
                            HudBit { text: modelData; color: sessionChip.ink }
                        }
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    onEntered: sessionChip.ink = Theme.accent
                    onExited: sessionChip.ink = Theme.dimFg
                    onClicked: { Sfx.play("select"); App.resumeHere() }
                }
            }
            // Cast readout — built from HudBit/HudSep like the DISP + party/session
            // chips so its centred `·` separators sit on the row line. (An inline `·`
            // in a single Text inflates the line box and rides the whole label high.)
            // Cast readout — a plain HudBit/HudSep Row, structurally identical to
            // the DISP chip below, so it sits on the exact same line. (An Item
            // wrapper's implicitHeight↔centred-child binding nudged it a few px
            // high; the click uses a TapHandler, which doesn't take part in Row
            // layout the way a filling MouseArea would.)
            Row {
                id: castChip
                visible: Cast.targetId !== ""
                height: parent.height
                spacing: Math.round(header.hudPx * 0.42)
                // Breathe while actively playing (same cadence as the party/session
                // chips); hold steady when paused/buffering/idle so a stopped breath
                // never strands the chip dimmed.
                property real pulse: 1.0
                opacity: Cast.castState === "PLAYING" ? pulse : 1.0
                SequentialAnimation on pulse {
                    running: castChip.visible && Cast.castState === "PLAYING"
                    loops: Animation.Infinite
                    NumberAnimation { to: 0.45; duration: 1100; easing.type: Easing.InOutQuad }
                    NumberAnimation { to: 1.0; duration: 1100; easing.type: Easing.InOutQuad }
                }
                HudBit { text: "OUT " + Cast.targetName.toUpperCase(); color: Theme.accent }
                HudSep { visible: Cast.castState !== "IDLE"; color: Theme.accent }
                HudBit { visible: Cast.castState !== "IDLE"; text: Cast.castState; color: Theme.accent }
                HudSep { visible: Cast.castDuration > 0; color: Theme.accent }
                HudBit { visible: Cast.castDuration > 0
                         text: App.prettyTime(Cast.castPosition); color: Theme.accent }
                TapHandler { onTapped: App.remoteOpen = true } // chip = open the remote
            }
            // The hub, from a satellite: which road reaches it. Quiet on the LAN
            // (dim), lit when every hub call is riding the tailnet, and a warning
            // that breathes when nothing answers — the library then browses from
            // the manifest and the art cache. A tap re-probes. The hub itself
            // shows nothing (it is its own road).
            Row {
                id: hubChip
                visible: App.deviceRole === "SATELLITE" && App.hubLink !== "" && App.hubLink !== "hub"
                height: parent.height
                spacing: Math.round(header.hudPx * 0.42)
                readonly property bool away: App.hubLink === "away"
                readonly property color ink: away ? Theme.warning
                                           : App.hubLink === "lan" ? Theme.dimFg : Theme.accent
                readonly property string word: App.hubLink === "fastroad" ? "FAST ROAD"
                                             : App.hubLink.toUpperCase()
                property real pulse: 1.0
                opacity: away ? pulse : 1.0
                SequentialAnimation on pulse {
                    running: hubChip.visible && hubChip.away
                    loops: Animation.Infinite
                    NumberAnimation { to: 0.45; duration: 1100; easing.type: Easing.InOutQuad }
                    NumberAnimation { to: 1.0; duration: 1100; easing.type: Easing.InOutQuad }
                }
                StripMark { color: hubChip.ink; half: !hubChip.away }
                HudBit { text: hubChip.away ? "HUB AWAY" : "HUB"; color: hubChip.ink }
                HudSep { visible: !hubChip.away; color: hubChip.ink }
                HudBit { visible: !hubChip.away; text: hubChip.word; color: hubChip.ink }
                TapHandler { onTapped: { Sfx.play("select"); App.probeHubNow() } }
            }
            Row {  // DISP · mode · clock — split so the · separators can be
                   // centred and the clock colon blinks by opacity (no width jump)
                id: dispChip
                height: parent.height
                transformOrigin: Item.Center
                scale: homeView.mScale("topDisp")
                transform: Translate { x: homeView.mOff("topDisp")[0] }   // the line owns y
                spacing: Math.round(header.hudPx * 0.42)
                HudBit { text: "DISP " + App.display }
                HudSep {}
                HudBit { text: App.mode.toUpperCase() }
                HudSep {}
                Row {  // clock — colon fades in/out, digits never move
                    height: parent.height
                    HudBit { text: root.clock.split(":")[0] }
                    // bigger dots WITHOUT inflating row height — scaled about the
                    // cap MIDDLE (on the line), not the box centre, which sits
                    // elsewhere in the MGS line box and would lift the colon
                    HudBit { id: clockColon; text: ":"; font.letterSpacing: 0
                             transform: Scale { origin.x: clockColon.width / 2; origin.y: clockColon.inkY
                                                xScale: 1.4; yScale: 1.4 }
                             opacity: root.clockColon ? 1 : 0 }
                    HudBit { text: root.clock.split(":")[1] }
                }
            }
        }

        // Header rule — the old static hairline crossed the movies/TV art (which
        // bleeds up to the top). Instead it DRAWS IN from the LEFT on each stage
        // entry, stopping at the search box's right edge so it never reaches the
        // art. Styled like the spotlight / wheel underlines: a rounded accent line
        // on a dark contrast bed (legible over hot art), a pen leading the draw.
        Item {
            id: headerRule
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            // the views' rail gutter is narrower on the CRT than the strip's 28
            // (YouTube / Settings 8, the library 16): start with it
            anchors.leftMargin: !root.onCrt ? 0 : (App.stage === "library" ? 16 : 8) - 28
            height: 2
            // home: the art fade owns the edge; YouTube: its tabs sit on the line
            visible: App.stage !== "home" && App.stage !== "youtube" && App.stage !== "settings"

            property real drawT: 0
            // The header inset (anchors.margins 28) and the library's search-box
            // column share the same 28px left margin, so the rule starts level
            // with that column — its width to the box's right edge is exactly the
            // column width (sheetW). Using the box's WINDOW x here overshot by one
            // header margin (the rule is anchored at the header's inset left, not 0).
            // YouTube's rail is wider (half the screen), so there it follows that
            // view's ruleW instead — its search box, pulled in to the row plates'
            // visible edge, ends level with the rule too.
            // Falls back to LibraryView's own formula (railW*0.48 - 56 on the
            // content width it fills) so the header rule still draws on
            // stats/settings before the Library Loader has ever loaded.
            readonly property real fullW: App.stage === "youtube" && ytView.item ? ytView.item.ruleW
                                        : App.stage === "settings" && settingsView.item ? settingsView.item.ruleW
                                        : libView.item ? libView.item.sheetW
                                                       : Math.round(content.width * 0.48) - 56
            readonly property color baseCol: Qt.darker(Theme.accent, 1.35)

            NumberAnimation {
                id: ruleDraw
                target: headerRule; property: "drawT"
                from: 0; to: 1; duration: 520; easing.type: Easing.OutCubic
            }
            onVisibleChanged: { drawT = 0; if (visible) ruleDraw.restart() }
            Component.onCompleted: if (visible) ruleDraw.restart()
            Connections {
                target: App
                function onStageChanged() {
                    if (headerRule.visible) { headerRule.drawT = 0; ruleDraw.restart() }
                }
            }

            Rectangle {  // dark contrast bed so the line stays legible on bright art
                anchors.left: parent.left
                width: ruleLine.width + 2; height: parent.height + 2
                y: -1; radius: height / 2
                color: Theme.withAlpha(Theme.bg, 0.5)
                visible: ruleLine.width > 1
            }
            Rectangle {
                id: ruleLine
                anchors.left: parent.left
                width: headerRule.fullW * headerRule.drawT
                height: parent.height
                radius: height / 2
                color: headerRule.baseCol
            }
            Rectangle {  // pen leading the left-to-right draw — tapers as it lands
                x: ruleLine.width + 1
                anchors.verticalCenter: parent.verticalCenter
                width: 5 * (1 - headerRule.drawT * 0.45); height: parent.height
                radius: height / 2
                color: Qt.lighter(headerRule.baseCol, 1.15)
                opacity: headerRule.drawT > 0.9 ? 0.5 : 1
                visible: headerRule.drawT > 0.02 && headerRule.drawT < 0.97
            }
        }
    }

    // Version — parked bottom-right, and an assembly element (topVer) so it can
    // be moved + scaled from the MOVE page like the strip groups.
    Text {
        id: verLabel
        z: 3
        // (not over STATS on the CRT: its cockpit fills the glass to the corner)
        visible: !root.inPlayer && App.stage !== "chooser" && App.stage !== "paths" && !App.attract
                 && !(App.stage === "stats" && root.onCrt)
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 28
        anchors.rightMargin: 28 + root.crtR
        anchors.bottomMargin: 28 + root.crtB
        transformOrigin: Item.BottomRight
        scale: homeView.mScale("topVer")
        transform: Translate { x: homeView.mOff("topVer")[0]; y: homeView.mOff("topVer")[1] }
        text: "v " + Qt.application.version   // space so the v doesn't clip the 0 in MGS
        color: Theme.dimFg
        opacity: 0.7
        font.family: header.hudFont
        font.pixelSize: header.hudPx
        font.letterSpacing: 1
        style: header.txtShadow
        styleColor: header.shadowInk
    }

    // ── Stage views ────────────────────────────────────────────────────────
    Item {
        id: content
        anchors.top: header.visible ? header.bottom : parent.top
        anchors.topMargin: header.visible ? 0 : root.crtT
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: root.crtL
        anchors.rightMargin: root.crtR
        anchors.bottomMargin: root.crtB

        ChooserView { anchors.fill: parent; visible: App.stage === "chooser"; focus: visible }
        // First run, after the display: CHOOSE MEDIA PATHS. Built only while
        // it shows — most launches never see it.
        Loader {
            id: pathsView
            anchors.fill: parent
            active: App.stage === "paths"
            visible: active
            sourceComponent: MediaPathsView { focus: pathsView.visible }
        }
        HomeView {
            id: homeView
            anchors.fill: parent
            visible: App.stage === "home"
            focus: visible
            topBleed: header.visible ? header.y + header.height : 0
            leftBleed: root.crtL
            rightBleed: root.crtR
            bottomBleed: root.crtB
            // hand the top-strip groups to the assembly (MOVE page: topLeft/topRight)
            topItems: ({ topLeft: headerLeft, topRight: rightBlock, topVer: verLabel,
                         topParty: partyChip, topSession: sessionChip, topDisp: dispChip })
        }
        // Secondary views load lazily. HomeView (9854 lines) must stay eager —
        // the top strip binds to it — but Stats/Library/YouTube/Settings need not
        // be built until first visited, which takes a big chunk off the startup
        // QML build. Each Loader latches loaded (`|| item`) so state survives
        // leaving the stage, and loads SYNCHRONOUSLY so focus and the entrance
        // animation work from a fully-built view with no blank frame.
        Loader {
            id: libView
            anchors.fill: parent
            active: App.stage === "library" || item
            visible: App.stage === "library"
            sourceComponent: LibraryView {
                focus: libView.visible
                topBleed: header.visible ? header.y + header.height : 0
                onBonusRequested: (path) => detailView.openBonusFor(path)
            }
        }
        Loader {
            id: ytView
            anchors.fill: parent
            active: App.stage === "youtube" || item
            visible: App.stage === "youtube"
            sourceComponent: YouTubeView { focus: ytView.visible }
        }
        Loader {
            id: settingsView
            anchors.fill: parent
            active: App.stage === "settings" || item
            visible: App.stage === "settings"
            sourceComponent: SettingsView { focus: settingsView.visible }
        }
        Loader {
            id: statsView
            anchors.fill: parent
            // STATS has its own CRT fill (and its CRT dials are tuned to it), so
            // it keeps the full width and foot it always had; only its top
            // follows the strip, which now sits on the visible glass too (a
            // full-height STATS put the strip's rule across its first plates).
            anchors.leftMargin: -root.crtL
            anchors.rightMargin: -root.crtR
            anchors.bottomMargin: -root.crtB
            active: App.stage === "stats" || item
            visible: App.stage === "stats"
            sourceComponent: StatsView { focus: statsView.visible }
        }
        // The garage editor pages with the mouse thumb buttons; while it is up
        // the app-wide mouse back/forward (AppController::eventFilter) stands
        // aside, or Back would close the editor instead of paging it.
        Binding {
            target: App
            property: "garageEditing"
            value: (homeView.visible && homeView.mechEdit)
                   || (statsView.visible && statsView.item !== null && statsView.item.mechEdit)
        }
    }

    // ── CRT overscan ───────────────────────────────────────────────────────
    // A tube shows less than the signal. In CRT mode the UI lives inside the
    // visible glass; backdrop art and the video still run to the edge (a tube
    // always cropped a picture). MEASURED on the author's NEC (2026-10-13, an edge
    // chart on the tube and his eyes), not guessed: the glass hides 17 px on
    // the left, 20 on the right, 12 at the top and 6 at the bottom of the
    // 1280x1024 signal. (The old 3.5% / 4% guess kept ~45 px of good glass
    // empty on every side.) Scaled with the window in case the mode changes.
    readonly property bool onCrt: App.mode === "crt"
    readonly property int crtL: onCrt ? Math.round(width * 17 / 1280) : 0
    readonly property int crtR: onCrt ? Math.round(width * 20 / 1280) : 0
    readonly property int crtT: onCrt ? Math.round(height * 12 / 1024) : 0
    readonly property int crtB: onCrt ? Math.round(height * 6 / 1024) : 0
    // One outward reach for a full-glass scrim inside the inset chrome: past
    // the window edge is simply not drawn, so the widest side covers all four.
    readonly property int crtEdge: Math.max(crtL, crtR, crtT, crtB)
    onCrtLChanged: snapPip(false)

    // YouTube's tabs live in the top strip, after CODEC | — tell the view where
    // that is in its own coordinates (through the strip groups' MOVE offsets
    // and scales, so a dialed strip carries the tabs with it).
    function placeYtStrip() {
        if (!header.visible) return
        const d = stripDivider.mapToItem(content, stripDivider.width, stripDivider.height / 2)
        const r = rightBlock.mapToItem(content, 0, 0)
        // Settings and YouTube carry their tabs there alike
        for (const v of [ytView.item, settingsView.item]) {
            if (!v) continue
            v.stripX = Math.round(d.x + 14)
            v.stripMidY = Math.round(d.y)
            v.stripRight = Math.round(r.x - 24)
        }
    }
    Connections {
        target: App
        function onStageChanged() { Qt.callLater(root.placeYtStrip) }
        function onModeChanged() { Qt.callLater(root.placeYtStrip) }
    }
    Connections { target: ytView; function onLoaded() { Qt.callLater(root.placeYtStrip) } }
    Connections { target: settingsView; function onLoaded() { Qt.callLater(root.placeYtStrip) } }
    Connections { target: rightBlock; function onWidthChanged() { Qt.callLater(root.placeYtStrip) } }
    Connections { target: header; function onWidthChanged() { Qt.callLater(root.placeYtStrip) }
                                  function onYChanged() { Qt.callLater(root.placeYtStrip) } }

    // ── Persistent video surface: fullscreen in player, PiP dock elsewhere ─
    // ONE owner for the dock's position in PiP: pipX / pipY. The "pip" state
    // binds x/y to them, a drag writes them, and pipGlide animates them to where
    // the dock belongs. (A drag used to write videoDock.x itself — silently
    // breaking the state's binding — while snap animations and the state
    // transition all animated x/y too: the dock jumped and drifted, the author's
    // "erratic".) Where it belongs: a CORNER (App.pipLeft/pipTop — ctrl+h/j/k/l,
    // or dropped within snapRadius of one) or a FREE spot, kept as a fraction of
    // the room it can move in so a window resize keeps it in place. Anywhere,
    // the top included: in PiP it layers ABOVE the header strip.
    readonly property int pipW: 440
    readonly property int pipH: 264
    readonly property int pipMargin: 28
    readonly property int pipTopY: 96          // a top CORNER sits just under the strip
    readonly property int snapRadius: 150
    property bool pipFree: false
    property real pipFreeFX: 0                 // 0..1 of (width - pipW)
    property real pipFreeFY: 0                 // 0..1 of (height - pipH)
    property real pipX: 0
    property real pipY: 0
    property bool pipDragging: false
    NumberAnimation { id: pipGlideX; target: root; property: "pipX"
                      duration: 240; easing.type: Easing.OutExpo }
    NumberAnimation { id: pipGlideY; target: root; property: "pipY"
                      duration: 240; easing.type: Easing.OutExpo }

    function pipCornerXY(left, top) {
        return Qt.point(left ? crtL + pipMargin : width - crtR - pipW - pipMargin,
                        top ? crtT + pipTopY : height - crtB - pipH - pipMargin)
    }
    // Where the dock rests. While the queue is up it steps sideways just clear
    // of the panel — only if they'd overlap (it used to glide to top-middle
    // every time the queue opened).
    function pipHome() {
        const p = pipFree
            ? Qt.point(crtL + pipFreeFX * Math.max(0, width - crtL - crtR - pipW),
                       crtT + pipFreeFY * Math.max(0, height - crtT - crtB - pipH))
            : pipCornerXY(App.pipLeft, App.pipTop)
        if (App.queueOpen) {
            const qx = width - crtR - queuePanel.width - 24   // its resting place
            const qy = crtT + queuePanel.anchors.topMargin
            const overlaps = p.x + pipW > qx - pipMargin / 2 && p.x < width - crtR - 24
                             && p.y + pipH > qy && p.y < qy + queuePanel.height
            if (overlaps)
                p.x = Math.max(crtL + pipMargin, qx - pipW - pipMargin)
        }
        return p
    }
    // Put the dock where it belongs — gliding when it's on screen as a PiP,
    // instantly otherwise (full player / no media / a window resize), so it's
    // already in place when the player hands the video back.
    function snapPip(animated) {
        if (pipDragging)
            return
        const p = pipHome()
        if (animated !== false && !inPlayer && mediaLoaded) {
            pipGlideX.to = p.x; pipGlideY.to = p.y
            pipGlideX.restart(); pipGlideY.restart()
        } else {
            pipGlideX.stop(); pipGlideY.stop()
            pipX = p.x; pipY = p.y
        }
    }
    onWidthChanged: snapPip(false)
    onHeightChanged: snapPip(false)
    onInPlayerChanged: if (inPlayer) snapPip(false)
    Component.onCompleted: snapPip(false)

    function pipCorner(left, top) {
        pipFree = false
        // Setters no-op when unchanged, so snap explicitly.
        App.pipLeft = left
        App.pipTop = top
        snapPip()
    }

    // An episode's name in quotes, as the library's episode plate shows it:
    // "The X-Files  S08E14 · This Is Not Happening (1) (1993)" →
    // The X-Files  S08E14 · "This Is Not Happening (1)" (1993). Anything else
    // (films, YouTube, an episode with no scraped name) passes through.
    function pipTitleOf(t) {
        const m = /^(.*\bS\d+E\d+\S*) · (.+?)( \(\d{4}\))?$/.exec(t || "")
        return m ? m[1] + ' · "' + m[2] + '"' + (m[3] || "") : (t || "")
    }

    // A drop: the nearest corner captures the dock if it's close; otherwise it
    // stays where it was dropped.
    function settlePipDrag() {
        pipDragging = false
        const left = pipX + pipW / 2 < width / 2
        const top = pipY + pipH / 2 < height / 2
        const c = pipCornerXY(left, top)
        if (Math.hypot(pipX - c.x, pipY - c.y) <= snapRadius) {
            pipCorner(left, top)
            return
        }
        pipFree = true
        const roomX = width - crtL - crtR - pipW, roomY = height - crtT - crtB - pipH
        pipFreeFX = roomX > 0 ? Math.max(0, Math.min(1, (pipX - crtL) / roomX)) : 0
        pipFreeFY = roomY > 0 ? Math.max(0, Math.min(1, (pipY - crtT) / roomY)) : 0
        snapPip()   // stays put — unless the queue is up and it landed under it
    }

    // Live-editable mech-UI asset URL: file:// off disk in a dev build (hot-reloads
    // on save via heroDevRev), else the baked qrc. Same contract as the OSD/queue.
    function devSrc(rel) {
        var d = App.heroDevPath(rel)
        return d !== "" ? d + "?v=" + App.heroDevRev : "qrc:/assets/mechui/" + rel + ".png"
    }

    Connections {
        target: App
        function onPipCornerChanged() { root.snapPip() }
        // Returning keyboard control when an overlay closes.
        // Overlays take the keyboard EXPLICITLY on open — the declarative
        // `focus:` bindings race the stage views' own `focus: visible`
        // ("queue open but j/k still moved the page behind it").
        function onQueueOpenChanged() {
            if (App.queueOpen) queuePanel.forceActiveFocus()
            else root.refocusStage()
            root.snapPip() // PiP steps clear of the queue (only if they'd overlap)
        }
        function onOutputOpenChanged() { if (!App.outputOpen) root.refocusStage() }
        // The party overlay and the cast remote are mutually exclusive — opening
        // one closes the other so they never stack (they used to render on top of
        // each other in party-from-cast). Closing either refocuses the stage.
        function onPartyOpenChanged() {
            if (App.partyOpen) { if (App.remoteOpen) App.remoteOpen = false }
            else root.refocusStage()
        }
        function onRemoteOpenChanged() {
            if (App.remoteOpen) { if (App.partyOpen) App.partyOpen = false }
            else root.refocusStage()
        }
        function onSearchOpenChanged() { if (!App.searchOpen) root.refocusStage() }
        function onDetailUriChanged() {
            if (App.detailUri.length > 0) detailView.forceActiveFocus()
            else root.refocusStage()
        }
    }

    function refocusStage() {
        // A join request waits for its answer before anything else gets keys.
        if (pairPrompt.visible) pairPrompt.forceActiveFocus()
        // Help sits over everything; closing the queue under it handed focus
        // to the stage and left the help on screen, keyboard-dead.
        else if (help.visible) help.forceActiveFocus()
        else if (App.queueOpen) queuePanel.forceActiveFocus()
        else if (App.partyOpen) watchParty.forceActiveFocus()
        else if (App.remoteOpen) castRemote.forceActiveFocus()
        else if (root.inPlayer) playerView.forceActiveFocus()
        // Detail + Search render ON TOP of the stage, so they must reclaim focus
        // before the stage views — else dismissing the help overlay over a detail
        // or search page left it visible-but-keyboard-dead (arrows drove the grid
        // behind it, Escape hit the library's back()). #nav
        else if (App.detailUri.length > 0) detailView.forceActiveFocus()
        else if (App.searchOpen) searchOverlay.forceActiveFocus()
        // Secondary views are Loaders now — focus the loaded item, which the
        // synchronous Loader has already built by the time the stage flips.
        else if (App.stage === "library") { if (libView.item) libView.item.forceActiveFocus() }
        else if (App.stage === "youtube") { if (ytView.item) ytView.item.forceActiveFocus() }
        else if (App.stage === "home") homeView.forceActiveFocus()
        else if (App.stage === "paths") { if (pathsView.item) pathsView.item.forceActiveFocus() }
        // Settings/stats were missing here: closing the queue or the help
        // overlay over them left NOTHING focused — the whole keyboard died
        // until the mouse bailed you out.
        else if (App.stage === "settings") { if (settingsView.item) settingsView.item.forceActiveFocus() }
        else if (App.stage === "stats") { if (statsView.item) statsView.item.forceActiveFocus() }
    }

    Item {
        id: videoDock
        visible: root.inPlayer || root.mediaLoaded
        // As a PiP it floats ABOVE the header strip (z 3) — free to sit at the
        // top without the strip's text and rule drawing over the video — and
        // under chrome (z 4: the player OSD, pickers, queue, menus).
        z: root.inPlayer ? 0 : 3.5

        MpvVideo {
            id: videoSurface
            anchors.fill: parent
            anchors.margins: root.inPlayer ? 0 : 1
            engine: Engine
        }

        // Ctrl-S in the player → App.screenshot() emits grabFrame(path). codec
        // runs vo=libmpv, where mpv's own screenshot command writes nothing, so
        // grab the RENDERED video item instead and save it to ~/Pictures/codec.
        Connections {
            target: App
            function onGrabFrame(path) {
                videoSurface.grabToImage(function(res) {
                    if (res) { res.saveToFile(path); App.notify("SCREENSHOT SAVED") }
                    else App.notify("SCREENSHOT FAILED")
                })
            }
        }

        // ── PiP chrome (hidden in the full player) ──
        // Hover = everything comes up together (140 ms): the video dims a touch,
        // dark scrims rise behind the title (top) and the time + bar (bottom) so
        // they read over any scene, and the transport appears. Leave = just the
        // video and its frame.
        readonly property bool pipHot: !root.inPlayer && dockHover.hovered
        Item {
            id: pipShade
            anchors.fill: parent
            anchors.margins: 3                 // inside the frame's light line
            visible: opacity > 0
            opacity: videoDock.pipHot ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 140 } }
            Rectangle { anchors.fill: parent; color: "#000000"; opacity: 0.25 }
            Rectangle {
                anchors { left: parent.left; right: parent.right; top: parent.top }
                height: 76
                gradient: Gradient {
                    GradientStop { position: 0; color: Theme.withAlpha("#000000", 0.85) }
                    GradientStop { position: 0.45; color: Theme.withAlpha("#000000", 0.45) }
                    GradientStop { position: 1; color: "transparent" }
                }
            }
            Rectangle {
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                height: 88
                gradient: Gradient {
                    GradientStop { position: 0; color: "transparent" }
                    GradientStop { position: 0.55; color: Theme.withAlpha("#000000", 0.5) }
                    GradientStop { position: 1; color: Theme.withAlpha("#000000", 0.9) }
                }
            }
        }
        // The frame — a live-editable 9-SLICE outline wrapping the miniplayer
        // once: corners stay pixel-crisp, the edges stretch, the CENTER is
        // transparent so the video shows through. EDIT: assets/mechui/plates/
        // pip-tex.png (48x48, border 8; its light line is 2px in, the inside
        // from 3px). Hot-reloads on Ctrl-S while the PiP is on the HOME stage.
        BorderImage {
            anchors.fill: parent
            visible: !root.inPlayer
            source: (App.heroDevRev, root.devSrc("pip-tex"))
            smooth: false
            border { left: 8; right: 8; top: 8; bottom: 8 }
            horizontalTileMode: BorderImage.Stretch
            verticalTileMode: BorderImage.Stretch
        }
        // The dock's hover, which brings up its chrome: a HoverHandler on the dock
        // itself stays hovered over any child (a button claiming the hover used to
        // drop a sibling MouseArea's containsMouse — the controls faded out under
        // the cursor).
        HoverHandler { id: dockHover; enabled: !root.inPlayer }
        MouseArea {
            id: pipMouse
            anchors.fill: parent
            enabled: !root.inPlayer
            hoverEnabled: true
            // Drag by hand, writing pipX/pipY (never videoDock.x — see pipX):
            // past an 8px threshold the dock follows the cursor, kept on screen.
            property point pressAt
            property bool moved: false
            onPressed: (m) => { pressAt = Qt.point(m.x, m.y); moved = false }
            onPositionChanged: (m) => {
                if (!pressed)
                    return
                if (!moved) {
                    if (Math.hypot(m.x - pressAt.x, m.y - pressAt.y) < 8)
                        return
                    moved = true
                    root.pipDragging = true
                    pipGlideX.stop(); pipGlideY.stop()
                }
                const g = mapToItem(null, m.x, m.y)   // scene = window coords
                root.pipX = Math.max(root.crtL, Math.min(root.width - root.crtR - root.pipW, g.x - pressAt.x))
                root.pipY = Math.max(root.crtT, Math.min(root.height - root.crtB - root.pipH, g.y - pressAt.y))
            }
            onReleased: if (moved) root.settlePipDrag()
            onCanceled: if (moved) root.settlePipDrag()   // never strand pipDragging
            onClicked: if (!moved) App.toPlayer()
        }

        // Hover controls: title (top), transport (middle), time + seek bar
        // (bottom). Text cap-ink is centred on its row (FontMetrics, re-read once
        // the HUD face loads); rows share the 12px side inset.
        Item {
            id: pipBtns
            // live the instant the hover starts (not once the fade has drawn a
            // frame) — a quick click on a button never falls through to the dock
            visible: videoDock.pipHot || opacity > 0
            opacity: videoDock.pipHot ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 140 } }
            anchors.fill: parent
            readonly property int inset: 12
            FontMetrics { id: pipFm; font: pipTitleTxt.font }
            function inkY(mid) {
                void pipFm.height
                const r = pipFm.tightBoundingRect("H")
                return Math.round(mid - (pipFm.ascent + r.y + r.height / 2))
            }

            ShadowText {
                id: pipTitleTxt
                x: pipBtns.inset
                y: pipBtns.inkY(22)
                width: parent.width - 2 * pipBtns.inset
                text: (Engine.paused ? "⏸ " : "▶ ") + Theme.mgsSafe(root.pipTitleOf(Engine.mediaTitle))
                color: Theme.fg
                font.family: Theme.hudFont
                font.pixelSize: 20
                elide: Text.ElideRight
            }

            // Seek bar: a 4px (2 art px) track + fill along the bottom, inside the
            // frame. Click or drag to scrub — the fill and time follow the
            // pointer, ONE seek on release (a hub party / cast never sees a
            // stream of seeks).
            readonly property real frac: pipSeek.scrub >= 0 ? pipSeek.scrub
                                       : Engine.duration > 0 ? Engine.position / Engine.duration : 0
            ShadowText {
                x: pipBtns.inset
                y: pipBtns.inkY(parent.height - 30)
                visible: Engine.duration > 0
                text: App.prettyTime(pipSeek.scrub >= 0 ? pipSeek.scrub * Engine.duration : Engine.position)
                      + " / " + App.prettyTime(Engine.duration)
                color: Theme.fg
                opacity: pipSeek.scrub >= 0 ? 1 : 0.85
                font: pipTitleTxt.font
            }
            Rectangle {
                id: pipTrack
                x: pipBtns.inset
                y: parent.height - 14
                width: parent.width - 2 * pipBtns.inset
                height: 4
                color: Theme.withAlpha("#a6b1c7", 0.35)
                Rectangle {
                    width: Math.round(parent.width * Math.max(0, Math.min(1, pipBtns.frac)))
                    height: parent.height
                    color: Theme.accent
                }
            }
            MouseArea {
                id: pipSeek
                property real scrub: -1
                x: pipTrack.x
                width: pipTrack.width
                y: pipTrack.y - 10
                height: pipTrack.height + 14     // a forgiving hit zone around 4px
                enabled: Engine.duration > 0
                function fracAt(mx) { return Math.max(0, Math.min(1, mx / width)) }
                onPressed: (m) => { scrub = fracAt(m.x) }
                onPositionChanged: (m) => { if (pressed) scrub = fracAt(m.x) }
                onReleased: { if (scrub >= 0) App.seekPct(scrub * 100); scrub = -1 }
                onCanceled: scrub = -1
            }

            // Transport — codec's own pixel icons (assets/mechui/icons/tx-*.png,
            // 13x13, ink centred on the cell's middle pixel) at 2x (the smallest
            // crisp size) on a plain soft round backing `pad` px bigger all round —
            // icon and circle are concentric BY CONSTRUCTION. Play/pause's circle
            // is a touch roomier (36 vs 32).
            // Hover: the backing darkens and the icon HOPS (up 2 art px, settles
            // at 1 while you're on it); press: it sinks 1 art px down-right onto
            // its own shadow, a key going down. The hover is a HoverHandler
            // (passive), so the dock's own hover never drops while you're on a button.
            component PipBtn: Item {
                id: pipBtn
                property string icon
                property var act
                property int px: 2
                property int pad: 3                       // circle beyond the icon, px
                readonly property bool hot: btnHover.hovered || btnMouse.pressed
                readonly property bool down: btnMouse.pressed
                property real lift: 0
                width: 13 * px + 2 * pad; height: width
                y: Math.round((parent.height - height) / 2)
                onHotChanged: {
                    hopIn.stop(); hopOut.stop()
                    if (hot) hopIn.restart(); else hopOut.restart()
                }
                SequentialAnimation {
                    id: hopIn
                    NumberAnimation { target: pipBtn; property: "lift"; to: 2; duration: 80; easing.type: Easing.OutQuad }
                    NumberAnimation { target: pipBtn; property: "lift"; to: 1; duration: 220; easing.type: Easing.OutBack }
                }
                NumberAnimation { id: hopOut; target: pipBtn; property: "lift"; to: 0; duration: 120; easing.type: Easing.OutQuad }
                Rectangle {
                    anchors.fill: parent
                    radius: width / 2
                    antialiasing: true
                    color: Theme.withAlpha("#000000", pipBtn.hot ? 0.7 : 0.45)
                    Behavior on color { ColorAnimation { duration: 90 } }
                }
                Image {
                    x: pipBtn.pad + pipBtn.px * (pipBtn.down ? 1 : 0)
                    y: pipBtn.pad + pipBtn.px * (pipBtn.down ? 1 : -Math.round(pipBtn.lift))
                    width: 13 * pipBtn.px; height: 13 * pipBtn.px
                    source: (App.heroDevRev, root.devSrc(pipBtn.icon))
                    smooth: false
                }
                HoverHandler { id: btnHover }
                MouseArea {
                    id: btnMouse
                    anchors.fill: parent
                    onClicked: (mouse) => { pipBtn.act(); mouse.accepted = true }
                }
            }

            PipBtn {
                icon: "tx-prev"; act: () => App.seekPct(0)
                x: Math.round(parent.width * 0.2 - width / 2)
            }
            PipBtn {
                pad: 5
                icon: Engine.paused ? "tx-play" : "tx-pause"
                act: () => App.playPause()
                x: Math.round((parent.width - width) / 2)
            }
            PipBtn {
                icon: "tx-next"; act: () => App.playerNext()
                x: Math.round(parent.width * 0.8 - width / 2)
            }
        }

        states: [
            State {
                name: "full"; when: root.inPlayer
                PropertyChanges {
                    videoDock {
                        x: 0; y: 0
                        width: root.width; height: root.height
                    }
                }
            },
            State {
                name: "pip"; when: !root.inPlayer && root.mediaLoaded
                PropertyChanges {
                    videoDock {
                        x: root.pipX
                        y: root.pipY
                        width: root.pipW; height: root.pipH
                    }
                }
            }
        ]
        transitions: Transition {
            NumberAnimation {
                properties: "x,y,width,height"
                duration: 240
                easing.type: Easing.OutExpo
            }
        }
    }

    // ── Chrome above the video ─────────────────────────────────────────────
    // One wrapper so HDR-engaged playback can PQ-encode every piece of
    // sRGB-authored chrome in a single layer pass — a PQ-tagged window would
    // otherwise show the OSD at absurd luminance. Free when disengaged.
    Item {
        id: chrome
        // ABOVE the header strip. Siblings sort by z before anything inside
        // them is considered, so with chrome at the default 0 the header (z 3)
        // painted over every overlay in here — including HelpOverlay, which
        // sets z: 9 and carries a comment claiming it sits above the strip. It
        // never did: that 9 only ranks it against its siblings in chrome.
        // Every modal scrim had the header's text and hairline bleeding
        // through the top of it.
        z: 4
        anchors.fill: parent
        // the OSD and every overlay inside the CRT's visible glass too
        anchors.leftMargin: root.crtL
        anchors.rightMargin: root.crtR
        anchors.topMargin: root.crtT
        anchors.bottomMargin: root.crtB
        layer.enabled: App.hdrEngaged
        layer.effect: ShaderEffect {
            fragmentShader: "qrc:/qml/shaders/pqencode.frag.qsb"
        }

        PlayerView {
            id: playerView
            anchors.fill: parent
            visible: root.inPlayer
            focus: visible
        }

        OutputPicker {
            anchors.fill: parent
            bleed: root.crtEdge
            focus: App.outputOpen
        }

        // A device asking to join this hub (device pairing) — over everything,
        // since whoever asked is waiting at the other machine for the answer.
        PairPrompt {
            id: pairPrompt
            anchors.fill: parent
            bleed: root.crtEdge
            z: 60
            onDone: root.refocusStage()
        }

        WatchPartyView {
            id: watchParty
            anchors.fill: parent
            bleed: root.crtEdge
            focus: App.partyOpen
        }

        CastRemote {
            id: castRemote
            anchors.fill: parent
            bleed: root.crtEdge
            focus: App.remoteOpen
        }

        // ── Queue sidebar (q from any view, incl. player + cast remote) ────
        // Declared after CastRemote so it slides in OVER the remote's dim
        // layer: remote center, queue right — both visible, both live.
        QueueSidebar {
            id: queuePanel
            width: 420
            anchors.top: parent.top
            anchors.topMargin: header.visible ? 84 : 24
            // DYNAMIC height, top-anchored: fit the actual item count (+ the NOW
            // block when playing) so a short queue has no dead space, but CAP at
            // the 10-row size so it never grows into the player's bottom OSD. A
            // longer queue scrolls (j/k). Also capped to the screen (laptop/CRT).
            height: {
                // Everything that isn't the row list (header, now-playing, footer,
                // margins), measured by the panel itself — so the list gets
                // exactly N whole row units (each plate centred in its unit with
                // a 4px gap either side) and no row is ever cut.
                var overhead = queuePanel.listChrome
                var ru = queuePanel.rowUnitH
                // Quantize to WHOLE rows so a row is NEVER cut off at any size
                //. rows = min(items, the 10-row OSD-safe cap, what fits the
                // screen); the height then snaps cleanly to that many full rows.
                var screenRows = Math.floor((parent.height - anchors.topMargin - 24 - overhead) / ru)
                // The saved-queue picker (o) replaces the list in the same
                // slot, so in that mode size for ITS rows — a short queue's
                // panel otherwise left the picker hanging out of the plate.
                var n = queuePanel.mode === "load" ? queuePanel.savedNames.length
                                                   : Queue.count
                var rows = Math.max(1, Math.min(n, 10, screenRows))
                return rows * ru + overhead
            }
            x: parent.width - width - 24 + slideX
            visible: slideX < width // stays visible through the slide-out
            focus: App.queueOpen
            // Overlays legitimately raised OVER the open queue keep the keyboard
            yieldFocus: help.visible || App.partyOpen || App.remoteOpen || App.outputOpen
            z: App.queueOpen ? 50 : 0   // takes priority over the other overlays when open
            Behavior on slideX {
                NumberAnimation { duration: 220; easing.type: Easing.OutExpo }
            }
        }

        SearchOverlay {
            id: searchOverlay
            anchors.fill: parent
            bleed: root.crtEdge
            focus: App.searchOpen
        }

        DetailView {
            id: detailView
            anchors.fill: parent
            bleedL: root.crtL
            bleedR: root.crtR
            bleedT: root.crtT
            bleedB: root.crtB
            focus: App.detailUri.length > 0
            // stepping back out of a page HOME opened from its half info
            onBackedOut: if (App.stage === "home") homeView.backFromFull()
        }

        OsdToast {
            id: toast
            anchors.horizontalCenter: parent.horizontalCenter
            y: 48
        }

        HelpOverlay {
            id: help
            anchors.fill: parent
            bleed: root.crtEdge
            // Hand the keyboard back where it came from, or the stage behind
            // stays deaf after the overlay closes.
            onVisibleChanged: if (!visible) root.refocusStage()
        }

        // Attract mode sits above everything and takes no focus of its own —
        // AppController's event filter both dismisses it and swallows the
        // waking event, so the stage behind keeps the keyboard throughout.
        AttractView { id: attractView; anchors.fill: parent; bleed: root.crtEdge; home: homeView }
    }

    Connections {
        target: App
        function onToast(text) { toast.show(text) }
        // Talk reaches you wherever you are, because the whole point of it is
        // that you are LOOKING AT THE FILM. A chat panel you have to open is a
        // chat panel nobody reads during a movie — and the party overlay is
        // already the wrong place to live, since opening it covers the screen
        // everyone else is still watching.
        function onPartyChatLine(who, text, kind) {
            if (!App.partyOpen) {
                if (kind === "sys") toast.show(text.toUpperCase())
                else toast.showChat(who, text)   // wraps: a sentence ran off the badge plate
            }
        }
    }

    Shortcut { sequences: ["Ctrl+Q"]; onActivated: App.quit() }
    // ⚠ `e` (resume what the other screen has open) is bound in the VIEWS, not
    // here. A Shortcut on a bare letter is application-wide and fires while
    // you are typing — it would have eaten the `e` in every search and every
    // chat message the moment another screen was playing something. Single
    // letters belong in Keys.onPressed, which is why every other one is there.
    // Update the library from anywhere: rescan disk + fetch any missing art.
    Shortcut { sequence: "F5"; onActivated: App.updateLibrary() }
    // #1: "?" is the one PRINTABLE key still bound as a window-wide Shortcut, and a
    // Shortcut fires even while a text field holds focus — so typing "?" in a search
    // box or (worst) party chat popped Help and ate the character. Only editable
    // text items expose cursorPosition, so this is off exactly while you're typing;
    // the disabled Shortcut lets "?" fall through to the field. (Same reason "e"
    // lives in the views — but Help must work everywhere, so guard rather than move.)
    readonly property bool textFieldFocused:
        !!(activeFocusItem && activeFocusItem.cursorPosition !== undefined)
    Shortcut {
        sequence: "?"
        enabled: !root.textFieldFocused
        onActivated: {
            help.visible = !help.visible
            if (help.visible)
                help.forceActiveFocus()   // explicit: declarative focus races
        }
    }
    // PiP dock corner from the keyboard, anywhere — EXCEPT while a mech GARAGE
    // editor is open, where Ctrl is the manual-aim modifier and h/j/k/l are the
    // editor's own nav/edit keys; gate these off so the editor keeps them.
    readonly property bool editingMech: homeView.mechEdit || (statsView.item ? statsView.item.mechEdit : false)
    Shortcut { sequence: "Ctrl+H"; enabled: !root.editingMech; onActivated: root.pipCorner(true, App.pipTop) }
    Shortcut { sequence: "Ctrl+L"; enabled: !root.editingMech; onActivated: root.pipCorner(false, App.pipTop) }
    Shortcut { sequence: "Ctrl+K"; enabled: !root.editingMech; onActivated: root.pipCorner(App.pipLeft, true) }
    Shortcut { sequence: "Ctrl+J"; enabled: !root.editingMech; onActivated: root.pipCorner(App.pipLeft, false) }
    Shortcut {
        sequence: "F11"
        onActivated: root.visibility === Window.FullScreen
                     ? root.showNormal() : root.showFullScreen()
    }

    // ── FreeSync without the flicker ─────────────────────────────────────────
    // Under FreeSync the panel refreshes when codec presents a frame, and an
    // idle codec presents about one a second: the VA panel dims and brightens
    // as the rate swings (the screen flickered on codec and nowhere else).
    // While App.steadyFrames (FreeSync running on codec's display), this ticks
    // every refresh and nudges a 1-px mark at 0.4-0.5% black, so every tick IS
    // a frame: an unchanged scene draws nothing, however often it's asked.
    Rectangle {
        id: steadyTick
        property bool odd: false
        x: 0; y: 0; z: 1000000
        width: 1; height: 1
        color: "#000000"
        opacity: odd ? 0.005 : 0.004
        visible: App.steadyFrames
    }
    FrameAnimation {
        running: App.steadyFrames
        onTriggered: steadyTick.odd = !steadyTick.odd
    }
}
