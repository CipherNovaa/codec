import QtQuick
import QtQuick.Shapes
import QtQuick3D
import QtQuick.Effects
import QtCore

// Home: a centred instrument panel, not a web feed. Full-bleed fanart owns the
// frame; over it float three stacked, horizontally-centred zones —
//
//   SPOTLIGHT   eyebrow · title · meta · rule           (top)
//   WHEEL       a detail card above a row of tall, narrow section slots whose
//               labels stand on end, Peace-Walker weapon-wheel style (middle)
//   SHELF       a small, dimmed continue-watching strip                (bottom)
//
// Everything fits on ONE screen — there is no scroll. j/k walks DOWN the three
// zones; h/l walks WITHIN the active one (cycle the spotlight, step the wheel,
// scrub the shelf). The wheel is a normal horizontal Row — only the LABEL text
// is rotated, so h/l keeps meaning "left/right" and every index binding holds.
//
// Sizes scale from the window (CRT 1280x1024 / laptop 1080p / desktop 1440p all
// fullscreen): `s` drives every dimension so the composition keeps its
// proportions on any panel. The whole block is centred as a unit rather than
// pinned to stage fractions, so the tall/narrow slots never stretch on the 5:4.
FocusScope {
    id: home

    // ── Scale ──────────────────────────────────────────────────────────────
    readonly property real s: Math.max(0.95, Math.min(width / 1920, 1.35))
    // (The CRT keeps this scale: a height-filled 1.23 there left the spotlight's
    // info sheet no room — the title lifted into the strip and the synopsis
    // and PLAY landed on the wheel. The author, 2026-10-13: "revert that piece".)
    readonly property bool onCrt: App.mode === "crt"
    // The key legend on the CRT: 24 px. The HUD face's capitals are only 5/16
    // of its size, so DP-3's 16 px made 5-px letters — unreadable on a tube.
    // (32 px would run off the glass; between its 16-unit grid steps the face
    // draws a little uneven, which a tube's soft spot hides.)
    readonly property real hintS: onCrt ? 1.667 : s
    // Dialed offsets are stored in REFERENCE px (nudged at the author's DP-3 2560-wide
    // fullscreen, where s == min(2560/1920,1.35) == 1.333) and applied ×(s/sRef), so a
    // repositioned element holds its place at any window size / resolution instead of
    // drifting. offScale == 1.0 at that fullscreen → saved tune pixel-identical there.
    readonly property real sRef: Math.min(2560 / 1920, 1.35)
    readonly property real offScale: s / sRef
    // Resize settle: while the window is actively resizing, suppress the position
    // Behaviors (Behavior on x/y below) so elements SNAP to the reflowed layout instead
    // of gliding into place ("slow click"). Cleared shortly after the last size change.
    property bool resizing: false
    onWidthChanged: { resizing = true; resizeSettle.restart() }
    onHeightChanged: { resizing = true; resizeSettle.restart() }
    Timer { id: resizeSettle; interval: 150; onTriggered: home.resizing = false }
    // Mech-chrome pixel scale: every mechui asset magnifies by an INTEGER so
    // art pixels stay square (the continuous `s` would shear them). 3 only
    // once the card is wide enough to seat the 96-art-px plate (224·s ≥ 288);
    // the 1080p laptop and the 5:4 CRT ride at 2.
    // Anti-lurch: DP-3 fullscreen sits at s=1.333, only ~3% above a bare 1.29
    // trip, so a tiny narrow-drag flipped every mech asset 3->2 mid-session
    // (StatsView.qml:47 already biases for this; HOME never did). Drop the trip
    // to 1.16 — centred between the laptop's 1.0 and DP-3's 1.333 — so both sit
    // far from it and a nudge doesn't cross it.
    readonly property int mpx: s >= 1.16 ? 3 : 2
    // Main passes the header offset: the art bleeds up underneath it.
    property int topBleed: 0
    // the CRT inset: the art also runs out under the tube's side/bottom overscan
    property int leftBleed: 0
    property int rightBleed: 0
    property int bottomBleed: 0
    // Global top-strip items (owned by Main.qml) exposed to the assembly so its
    // MOVE page can position/scale each like any HOME element. Keyed by move-key
    // (topLeft/topRight/topVer/topParty/topSession/topDisp).
    property var topItems: ({})
    property bool pendingG: false
    // The spotlight's own mini info (up / i from the spotlight): the title
    // LIFTS UP and the synopsis + play fill the room that opens above the wheel.
    property bool spotInfoOpen: false
    // 0→1 as it opens; drives the lift and the grow in lockstep so they read as
    // one motion.
    property real infoT: spotInfoOpen ? 1 : 0
    // MOVIES head experiment: the VHS deck. Flip false to restore the
    // definitive clapperboard (both live in full below).
    readonly property bool movVhs: false
    // Keystone open: a surface expanding, in the house arrival curve.
    Behavior on infoT { NumberAnimation { duration: DS.grand; easing.type: Easing.Bezier; easing.bezierCurve: DS.enterCurve } }
    // How far the spotlight lifts — exactly enough to seat the description above
    // the wheel without covering it.
    readonly property real infoRise: growCol.implicitHeight + Math.round(24 * s)
    // With the mini-info open the card between spotlight and wheel is hidden, so
    // the wheel + continue slide up to reclaim its space instead of stranding the
    // play row above a void. Exactly the card's reserved height (card + its gap).
    readonly property real infoWheelRise: (cardH + Math.round(10 * s)) * infoT
    // The card belongs to the wheel — it exists only while the wheel is the
    // active zone. cardT drives its deploy (0 = gone, 1 = fully out). When it's
    // gone the spotlight DROPS toward the wheel to close the card's empty slot,
    // and rises again as the card deploys — so the title moves WITH the card and
    // the resting screen is a clean, symmetric spotlight-over-wheel.
    // The card belongs to the wheel — but it must also stand down while the
    // mini-info is open, or (opening info FROM the wheel) it bleeds through the
    // dimmed wheel and collides with the info's play row.
    // The mech editor keeps the card DEPLOYED while it's open — cycling the
    // card plate has to render live, and the card only exists when engaged.
    readonly property bool wheelEngaged: (zone === "wheel" || mechEdit) && !spotInfoOpen
    property real cardT: wheelEngaged ? 1 : 0
    Behavior on cardT { NumberAnimation { duration: Math.round(DS.slow * mechAnimK); easing.type: Easing.Bezier; easing.bezierCurve: DS.moveCurve } }
    // GARAGE replay: while the editor is open the card is pinned deployed
    // (wheelEngaged includes mechEdit), so switching CARD DEPLOY / TEMPO would
    // change an entrance you never get to see. replayCard() dips cardShow to 0 and
    // eases it back so the chosen deploy plays on the live card; idle, cardShow
    // just tracks cardT (== the old behaviour, byte for byte).
    property real cardReplayMul: 1
    readonly property real cardShow: cardT * cardReplayMul
    SequentialAnimation {
        id: cardReplay
        NumberAnimation { target: home; property: "cardReplayMul"; to: 0; duration: 90; easing.type: Easing.InQuad }
        ScriptAction { script: cardReveal.restart() }
        NumberAnimation { target: home; property: "cardReplayMul"; to: 1
            duration: Math.round(DS.slow * mechAnimK); easing.type: Easing.Bezier; easing.bezierCurve: DS.moveCurve }
    }
    function replayCard() { if (mechEdit && wheelEngaged) cardReplay.restart() }
    // int-typed return so font.pixelSize (int) bindings don't warn "double to int" (see StatsView.pxi)
    function pxi(v: real): int { return Math.round(v) }
    // Base drop = close the empty card slot (cardH); SPOT DROP dial adds extra
    // reference-px so the resting spotlight can settle further down toward the
    // wheel and eat the dead space above it. Retracts with the card/info like the base.
    readonly property real spotSettleExtra: (mechOn ? (mech.spotDrop || 0) : 0) * s
    readonly property real spotDrop: (cardH + spotSettleExtra) * (1 - cardT) * (1 - infoT)
    // INFO DROP dial: while the info sheet is open, slide the WHOLE cluster
    // (spotlight + synopsis) down toward the wheel. Applied *infoT so it only
    // acts open and animates in with the sheet.
    readonly property real infoDropPx: Math.round((mechOn ? (mech.infoDrop || 0) : 0) * s) * infoT
    // SPOT Y dial: nudge just the spotlight (title/logo/meta) down while the info
    // sheet is open — INFO DROP already carries the whole cluster, so this moves the
    // spotlight ALONE relative to the synopsis. Gated *infoT so it only acts open.
    readonly property real spotNudgePx: Math.round((mechOn ? (mech.spotY || 0) : 0) * s) * infoT
    // Browsing CONTINUE: the spotlight + wheel step UP and dim to give the
    // posters real room (they were cramped against the footer). The shelf rises
    // into that opened space so three big posters sit well clear of the footer.
    readonly property bool cwActive: zone === "cw"
    // The CONTINUE deck only DEPLOYS on an explicit Enter/click — hovering or
    // navigating onto the button just FOCUSES it (lit hover state). Leaving the
    // cw zone re-closes the deck (toggle). cwActive = focused; cwDeployed = open.
    property bool cwDeployed: false
    // Inside the open deck, focus is either on the CONTINUE button (false) or
    // stepped DOWN into the poster row (true). Enter on the button toggles the
    // deck open/closed; Down steps into the posters (Enter there plays), Up steps
    // back to the button. Reset whenever the cw zone is entered or left.
    property bool cwOnPosters: false
    onCwActiveChanged: { if (!cwActive) cwDeployed = false; cwOnPosters = false }
    // XMB shift: browsing continue (down / ▾) slides the spotlight+wheel UP and
    // the shelf rises into that opened room so three big posters sit clear of the
    // footer — continue is HIDDEN until you navigate down to it, by design. This
    // is the SINGLE animated source for that whole step (wheel, spotlight AND the
    // shelf all bind to it), so they move as one calm motion — no mismatched
    // snap, no bounce.
    // (0.22: the stack seats low over the key legend, so the posters need the
    // lift to open at a readable size)
    property real cwRise: cwDeployed ? Math.round(height * 0.22) : 0
    Behavior on cwRise { NumberAnimation { duration: DS.slow; easing.type: Easing.OutCubic } }

    // Wheel metrics — one place, so the card, spine and shelf all line up to it.
    readonly property int slotW: Math.round(56 * s)
    readonly property int slotGap: Math.round(12 * s)
    readonly property int wheelH: Math.round(336 * s)
    readonly property int slotRise: Math.round(26 * s)     // focused slot grows up
    readonly property int wheelW: slotW * items.length + slotGap * (items.length - 1)
    // Card is NARROWER than the wheel so it can slide across it, tracking the
    // focused slot; a spine drops from it into that slot.
    // Sized to the mech plate's grid: 224·s keeps the 96-art-px card art
    // seatable at every mpx step, and the extra height gives the reading row
    // clear dark body between the plate's header band and bottom rail.
    // Classic chrome restores the original 212x62.
    // CARD WIDTH dial slims the card; snap the mech width to a whole multiple of mpx so the
    // 9-slice's integer-scaled (scale:px) art lands 1:1 — an odd width stretches/blurs the right edge.
    readonly property int cardW: {
        if (!mechOn) return Math.round(212 * s)
        var base = 224 * s * (mech.cardWidth !== undefined ? mech.cardWidth : 1)
        return Math.max(mpx * 32, Math.round(base / mpx) * mpx)
    }
    readonly property int cardH: Math.round((mechOn ? 70 : 62) * s)
    readonly property int shelfPosterW: Math.round(158 * s)
    readonly property int shelfPosterH: Math.round(shelfPosterW * 1.48)

    // ── State ──────────────────────────────────────────────────────────────
    property var spot: []
    property int spotIdx: 0
    property var cw: []
    property int cwIdx: 0
    // First poster in the FIXED three-wide window. Stateful — it only re-centres
    // on keyboard nav (never off hover), so hovering a poster just selects one of
    // the three visible slots without shifting anything under the cursor. That
    // decoupling is what killed the hover-feedback "jump": geometry no longer
    // moves in response to the pointer that's driving it.
    property int cwWinStart: 0
    property int secIdx: 0
    // Landing on YOUTUBE warms its first tabs in the worker's cache, so by the
    // time the section opens the listing is already there. Debounced so
    // spinning past the card doesn't fire fetches.
    onSecIdxChanged: {
        ytWarm.restart()
        if (App.devMeter) console.log("[sel] " + Date.now() + " " + secIdx)   // dev meter: hover lag
    }
    Timer {
        id: ytWarm
        interval: 350
        onTriggered: if (home.visible && home.items[home.secIdx]
                         && home.items[home.secIdx].target === "youtube")
            YouTube.prewarm(["playlists", "rec", "subs"])
    }

    // ── Icon debug: live-cycle each section's glyph + weapon from wheelIconPool.
    // Defaults ARE the art-directed picks (feet: the five bespoke 3D rigs;
    // heads: the four animated 2D rigs + the rank meter) — a fresh config
    // must come up looking exactly like the shipped design.
    property var botSel: ({ movies: 72, tv: 92, youtube: 241, stats: 193, settings: 104 })
    property var topSel: ({ movies: 69, tv: 135, youtube: 43, stats: 27, settings: 106 })
    // Snapshot of the icon picks taken when the garage opens (and refreshed on
    // each save), so ESC-without-save reverts the HEAD/FOOT dials too — they
    // live outside `mech`, so revertMechUi alone left them changed for the
    // session. Kept in lockstep with mech's revert contract.
    property string savedIconJson: ""
    // On-screen confirmation for the picker (there was no feedback before).
    property string iconFlash: ""
    function iconPoolFor(sec) { return wheelIconPoolAll }
    function iconAt(sel, sec) {
        const p = iconPoolFor(sec)
        if (!p || p.length === 0) return ({ n: sec, d: wheelIconPaths[sec] || "" })
        return p[Math.max(0, Math.min((sel[sec] || 0), p.length - 1))]
    }
    function topIcon(sec) { return iconAt(topSel, sec) }
    function botIcon(sec) { return iconAt(botSel, sec) }
    // Optical-weight balance: solid-filled silhouettes carry more mass than airy
    // outlines at the same box, so shrink the heavy ones a touch to read as ONE
    // set. A multiplier on the base fill (1.0 = untouched).
    function iconFillFactor(n) {
        const f = { "world": 0.88, "globe": 0.9, "wireframe-globe": 0.94, "gears": 0.9,
                    "rank-1": 0.95, "rank-2": 0.95, "rank-3": 0.95,
                    "big-gear": 0.9, "cog": 0.92, "tv": 0.92, "histogram": 0.94,
                    "pie-chart": 0.9, "podium": 0.94, "boombox": 0.92, "headphones": 0.92 }
        return f[n] || 1.0
    }
    function iconByName(n) {
        const p = wheelIconPoolAll
        for (let i = 0; i < p.length; ++i) if (p[i].n === n) return p[i]
        return null
    }
    function cycleSel(which, sec, dir) {
        const p = iconPoolFor(sec); if (!p || p.length === 0) return
        const sel = which === "top" ? topSel : botSel
        const b = Object.assign({}, sel)
        b[sec] = ((b[sec] || 0) + dir + p.length) % p.length
        if (which === "top") topSel = b; else botSel = b
        console.log("[iconDebug] " + sec + " " + which + " -> " + iconAt(b, sec).n + " (" + (b[sec] + 1) + "/" + p.length + ")")
    }
    function dumpIcons() {
        let out = "[iconDebug] MAP  "
        for (let i = 0; i < items.length; ++i) {
            const s = items[i].target
            out += s + "=[top:" + topIcon(s).n + " foot:" + botIcon(s).n + "]  "
        }
        console.log(out)
    }
    // \ is the ONLY save beat — dumping the map (backtick toggle) must
    // never write config as a side effect.
    function commitIconPicks() {
        dumpIcons()
        saveIconPicks()
        iconFlash = "✓ SAVED"
        iconFlashTimer.restart()
    }
    // \ persists the current picks to config so they survive a restart (and can
    // be read back) — the picker used to have no feedback and reset every launch.
    function saveIconPicks() {
        App.putSetting("iconTopSel", JSON.stringify(topSel))
        App.putSetting("iconBotSel", JSON.stringify(botSel))
        // A later ESC should revert to what we just SAVED, not the open-time
        // picks — refresh the snapshot so the two stay in lockstep.
        savedIconJson = JSON.stringify({ top: topSel, bot: botSel })
    }
    function restoreIconPicks() {
        try {
            // merge OVER the defaults: a config saved before a section
            // existed must not drop that section's pick to pool index 0
            const t = App.getSetting("iconTopSel", "")
            const b = App.getSetting("iconBotSel", "")
            if (t) topSel = Object.assign({}, topSel, JSON.parse(t))
            if (b) botSel = Object.assign({}, botSel, JSON.parse(b))
        } catch (e) { console.log("[iconDebug] restore failed: " + e) }
    }
    Timer { id: iconFlashTimer; interval: 1500; onTriggered: home.iconFlash = "" }

    // ── Mech-UI editor state ────────────────────────────────────────────
    // M toggles a live style editor (MechEditor overlay): every mech-chrome
    // element on the home screen reads its style from this one map, the
    // editor cycles values in place, \ persists — the icon-debug pattern,
    // grown up. Defaults ARE the shipped design.
    property bool mechEdit: false
    // GARAGE modes (Armored Core): NORMAL = survey (lockbox zoomed to the whole
    // screen, no dim), COMBAT = tune the locked part (tight frame + dim), SCAN =
    // calibrate (grid on + framed). f/s/n switch; the mode banners on screen.
    property string garageMode: "combat"
    // editing is applicable in COMBAT, or in SCAN while manual-aiming (Ctrl = aim + FIRE):
    // the value readouts + the panel go LIVE only then; plain scan stays read-only inspect.
    readonly property bool canEdit: garageMode === "combat" || (garageMode === "scan" && garageFocus !== null && garageFocus.ctrlHeld && mechEdit)
    // manual-aim LOCKED onto a specific element — the row follows the reticle, so j/k
    // up/down is locked out here to keep your place (free when aiming empty space)
    readonly property bool aimLocked: garageMode === "scan" && garageFocus !== null && garageFocus.ctrlHeld && garageFocus.aimKey !== "" && mechEdit
    readonly property var mechDefaults: ({
        lockGlide: "normal",   // target-lock catch-up: off|snap|normal|loose
        chrome: "mech",        // mech|classic — classic = the exact
                               // pre-asset-import look, for A/B taste tests
                               // (themes in Settings is the eventual home
                               // for this; the editor carries it for now)
        cardPlate: "card",     // card|sq1|sq2|sq3|wide|body
        cardLean: 0.6,         // card offset-right lean: 0 = centred on slot, 1 = left-aligned to slot
        cardWidth: 1.0,        // card horizontal slim: 1 = full 224u, <1 narrows (snapped to whole mpx)
        sepDotY: 0,            // reading separator dot vertical nudge (art-px; − = up)
        spotDrop: 24,          // extra px the resting spotlight settles DOWN toward the wheel (0 = old just-above-wheel seat)
        chipWin: true,         // badge chips: dark readout window
        meterStyle: "liquid",  // liquid|cells
        sep: "dot",            // meta separator: dot|diamond
        caret: true,           // pixel carets on CONTINUE / full page
        pill: "none",          // CONTINUE backing: none|b1..b5
        play: "none",          // PLAY backing: none|b1..b5
        tray: "conttray",      // continue poster tray: the drawn conttray plate (plain|body|…)
        font: "mono",          // mech-chrome type (incl. the MGS1 faces)
        nameInk: "auto",       // card nameplate ink (auto = plate-aware)
        readInk: "light",      // card reading ink
        chipInk: "light",      // badge label ink
        led: "green",          // the live lamp's colour
        ledOn: true,           // the live lamp itself
        chipPx: 0,             // badge pixel scale, 0 = auto by display
        // wheel (the middle five)
        wheelPlate: "plain",   // slot backing: plain|sq1|sq3|frame|chip
        wheelInk: "auto",      // slot label ink
        wheelSize: "m",        // slot label size
        // per-element text sizes (xs|s|m|l|xl)
        nameSize: "m", readSize: "m", openSize: "m",
        titleSize: "m", metaSize: "m", metaInk: "auto",
        contSize: "m", playSize: "m",
        // per-element typefaces ("inherit" follows the global FONT dial)
        nameFont: "inherit", readFont: "inherit", titleFont: "inherit",
        metaFont: "inherit", wheelFont: "inherit", deckFont: "inherit",
        infoFont: "mgscodec",  // the redaction synopsis reads in the MGS codec face
        infoDrop: 52,          // px the synopsis+play block is pushed DOWN toward the wheel (0 = seated just under the meta)
        infoGap: -8,           // px added to the gap between the meta line and the top of the synopsis (− tightens)
        spotY: 24,             // spotlight-alone vertical nudge while info is open (+ = down)
        // animation
        cardAnim: "side",      // card deploy: side|drop|rise|fade|pop|zoom|unfold|swing|spin|iris|hinge|slam
        nameBack: "none",      // backing behind the section name: none|chip|body|frame|bar|b1..b5
        deckAnim: "rise",      // CONTINUE deck deploy: rise|drop|side|fade|pop|zoom
        gaugeOn: true,         // show the poster scroll-position gauge
        animSpeed: "normal",   // slow|normal|fast — mech move beats
        typeOn: true,          // card name/prompt type-in
        caretBeat: "off",      // idle caret pulse — off = twirls ONLY on press
        // more inks ("auto" = the themed original)
        titleInk: "auto", openInk: "auto", contInk: "auto", playInk: "auto",
        // mini-info synopsis (the text under the line)
        infoInk: "auto", infoSize: "m",
        // badge plate style
        chipStyle: "chip",     // chip|b1|b3|b4|none
        // footer keyhints
        hints: "show",         // show|dim|off
        hintSize: "m",
        // where the CONTINUE caret sits: inline (the [text ▾] composite
        // dead-centred in the plate — the correct button) | right of the
        // plate | under it | right wing
        caretSeat: "inline", caretSize: "m",
        // the info sheet's redaction rig ("inherit" follows Settings)
        redaction: "inherit",  // inherit|redact|light|type|off
        redactInk: "auto",     // block bars: auto(black)|navy|red|blue|green
        scanInk: "auto",       // the working front: auto(accent)|inks
        // ── v2 go-maximal dials ─────────────────────────────────────────
        // MASTER
        accentInk: "auto",     // one override for all mech accent chrome
        chromeScale: "m",      // global chrome-text size factor s|m|l|xl
        bgBackdrop: "fanart",  // fanart|city|desert|grass|snow|off
        bgDim: "med",          // backdrop darken off|low|med|high
        bgTint: "none",        // backdrop colour wash: none|ink
        zoom: "2x",            // scan+shift magnifier: off|1.5x|2x|3x|4x
        // CARD text-style
        nameWeight: "bold", nameCase: "asis", nameTrack: "wide",
        readWeight: "bold", readTrack: "normal", readCase: "asis",
        openWeight: "bold", openTrack: "wide", openFont: "inherit", openLabel: "OPEN",
        ledSize: "m", ledShape: "square", ledWell: true, ledWellInk: "navy", ledBeat: "normal",
        // DATA-LINK
        linkOn: true, linkInk: "auto", linkRail: "hair", linkPacket: "diamond",
        linkPulse: "normal", sockCapOn: true,
        // SPOTLIGHT
        titleWeight: "light", titleTrack: "wide", titleCase: "upper", titleOutline: true,
        logoOn: true, logoMax: "m", logoSprite: "default", ruleOn: true, ruleInk: "auto", ruleThick: "m",
        metaWeight: "regular", metaTrack: "wide", metaCase: "upper", metaOutline: true,
        carouselOn: true,
        crumbInk: "auto", crumbSize: "m", crumbFont: "inherit", crumbWeight: "regular", crumbCase: "asis", crumbTrack: "wide",
        // WHEEL
        wheelWeight: "bold", wheelTrack: "wide", wheelCase: "asis",
        starOn: true, starInk: "auto", starGlyph: "★", slotTickInk: "auto",
        slotNotch: true, slotWash: true, baseTickOn: true, slotBorderInk: "auto",
        wheelHeadSize: "m", wheelFootSize: "m",
        wheelSprite0: "default", wheelSprite1: "default", wheelSprite2: "default", wheelSprite3: "default", wheelSprite4: "default",
        // BADGES
        chipSize: "m", chipTrack: "normal", chipWeight: "demibold", chipFont: "inherit", chipCase: "asis",
        // INFO SHEET
        infoWeight: "regular", infoTrack: "tight", infoLines: 6, infoAlign: "center",
        // DECK
        contWeight: "bold", contTrack: "wide", contCase: "upper", contLabel: "CONTINUE",
        playWeight: "bold", playTrack: "wide", playCase: "upper", playLabel: "PLAY",
        trayInk: "auto", posterFrameInk: "auto", pctBadgeOn: true, pctFont: "inherit",
        pctSize: "m", posterTick: true, roundelOn: true, grndRail: true, grndRailInk: "auto",
        // FOOTER
        hintInk: "auto", hintFont: "inherit", hintTrack: "normal", hintWeight: "regular", hintCaps: true,
        // v2 depth & trim (+11 to 154)
        bgVignette: true, openKeyInk: "auto", linkChevInk: "auto", sockInk: "auto",
        metaGap: "normal", slotDim: "normal", posterDim: "normal", posterLift: "normal",
        roundelInk: "auto", pctBadgeInk: "auto", hintGap: "normal",
        // manual position trims, [dx, dy] screen px per element — the MOVE
        // page writes these so any combination can be hand-centred
        offsets: ({}),
        scales: ({})
    })
    property var mech: mechDefaults
    // Fixed hardware inks — the palette every ink dial draws from (family
    // colours: plate navy/steel, the PS1 LED green, the ember lamp, and
    // the pack's own beam cyan / liquid blue / warning red).
    readonly property var mechInks: ({
        navy: "#222034", steel: "#566c78", slate: "#8fa6b3", trim: "#aecbd9",
        light: "#dce8ef", white: "#f2f7fa", green: "#8fe3a1", teal: "#57c9b0",
        mint: "#b7f2c8", cyan: "#5fcde4", "cyan-hi": "#4fd6ea", blue: "#4a6ab1",
        "blue-hi": "#5b8bf5", violet: "#9a6ede", purple: "#7a4fd0", pink: "#e58fb4",
        red: "#c04a42", "red-hi": "#ff6a6a", warning: "#c86450", orange: "#f09a4e",
        amber: "#f0a54e", "amber-hi": "#ffb347", yellow: "#e6d24a", grey: "#8e8e8e"
    })
    function mechInk(k) { return mechInks[k] || "#dce8ef" }
    // v2 auto-aware ink: "auto"/"none" fall through to the accent override
    function hInk(k) { return (k === "auto" || k === "none" || !k) ? homeAccent : (mechInks[k] || "#dce8ef") }
    // text-style resolvers (ported from the stats cockpit) for the v2 per-element dials
    readonly property var weights: ["light", "regular", "demibold", "bold"]
    readonly property var cases:  ["upper", "asis", "title", "lower"]
    readonly property var tracks: ["tight", "normal", "wide", "wider", "widest"]
    function weightFor(w) { return w === "light" ? Font.Light : w === "demibold" ? Font.DemiBold : w === "bold" ? Font.Bold : Font.Normal }
    function caseFor(t, c) { return c === "upper" ? String(t).toUpperCase() : c === "lower" ? String(t).toLowerCase()
                                  : c === "title" ? String(t).replace(/\b\w/g, function (m) { return m.toUpperCase() }) : t }
    readonly property var trackFac: ({ tight: 0, normal: 1, wide: 2, wider: 4, widest: 6 })
    function trackFor(k) { var v = trackFac[k]; return v === undefined ? 1 : v }
    // MASTER: one accent override for all mech chrome + a global chrome-size factor
    readonly property color homeAccent: (mechOn && mech.accentInk && mech.accentInk !== "auto") ? mechInk(mech.accentInk) : Theme.accent
    readonly property real chromeK: !mechOn ? 1.0 : ({ s: 0.9, m: 1.0, l: 1.1, xl: 1.25, xxl: 1.4 }[mech.chromeScale] || 1.0)
    // The chrome's typeface, editor-switchable. Loading all four Mecha
    // files binds Bold styles to their families, so font.bold keeps
    // working. The MGS1 faces come from MGS1_Fonts — a codec runs on the
    // Codec font if it wants to.
    FontLoader { id: mechaFont; source: "qrc:/assets/mechui/mecha.ttf" }
    FontLoader { source: "qrc:/assets/mechui/mecha-bold.ttf" }
    FontLoader { id: mechaCond; source: "qrc:/assets/mechui/mecha-cond.ttf" }
    FontLoader { source: "qrc:/assets/mechui/mecha-cond-bold.ttf" }
    FontLoader { id: mgsCodecFont; source: "qrc:/assets/mechui/mgs-codec.ttf" }
    FontLoader { id: mgsHudFont; source: "qrc:/assets/mechui/mgs-hud.ttf" }
    FontLoader { id: mgsAmmoFont; source: "qrc:/assets/mechui/mgs-ammo.ttf" }
    readonly property string mechFont: mech.font === "mecha" ? mechaFont.name
                                     : mech.font === "mechacn" ? mechaCond.name
                                     : mech.font === "mgscodec" ? mgsCodecFont.name
                                     : mech.font === "mgshud" ? mgsHudFont.name
                                     : mech.font === "mgsammo" ? mgsAmmoFont.name
                                     : mech.font === "ui" ? Theme.uiFont
                                     : Theme.monoFont
    // editor specimen access
    function mechFontFor(k) {
        return k === "mecha" ? mechaFont.name
             : k === "mechacn" ? mechaCond.name
             : k === "mgscodec" ? mgsCodecFont.name
             : k === "mgshud" ? mgsHudFont.name
             : k === "mgsammo" ? mgsAmmoFont.name
             : k === "ui" ? Theme.uiFont
             : Theme.monoFont
    }
    // Per-element text sizing: every chrome text takes its base formula
    // through mSz with its own dial key; classic always rides 1.0.
    readonly property var mechSizes: ({ xxs: 0.68, xs: 0.78, s: 0.9, m: 1.0, l: 1.15, xl: 1.32, xxl: 1.5 })
    function mSz(base, key) {
        if (!mechOn) return base
        return Math.round(base * (mechSizes[mech[key]] || 1.0) * chromeK)
    }
    // mech motion tempo (the ANIMATION dial) — classic always rides 1.0
    readonly property real mechAnimK: !mechOn ? 1.0
        : mech.animSpeed === "slow" ? 1.6 : mech.animSpeed === "fast" ? 0.6 : 1.0
    // type-in beats collapse to instant when the dial says so
    readonly property real mechTypeK: mechOn && !mech.typeOn ? 0 : 1
    // Per-element typeface: "inherit" rides the global FONT dial.
    function mFontFor(el) {
        const v = mech[el + "Font"] || "inherit"
        return v === "inherit" ? mechFont : mechFontFor(v)
    }
    // Manual position trims (the editor's MOVE page): [dx, dy] for a named
    // element, [0,0] in classic — hand-set symmetry beats guessed symmetry.
    // RAW stored reference-px offset — what the mutators (nudge/drag/commit) read.
    // Dragged element reads its live offset mid-drag; everyone else reads mech.
    function mOffRaw(k) {
        if (!mechOn) return [0, 0]
        if (garageFocus && garageFocus.dragging && garageFocus.dragKey === k) return garageFocus.dragOff
        const o = mech.offsets ? mech.offsets[k] : null
        return o || [0, 0]
    }
    // SCALED offset for DISPLAY — every Translate reads this so positions scale with the
    // window instead of being locked to the resolution they were dialed at.
    function mOff(k) { const o = mOffRaw(k); return [o[0] * offScale, o[1] * offScale] }
    // commit a finished drag into mech ONCE (mirrors mechNudge's [0,0] prune)
    function mechCommitDrag(k, off) {
        const offs = Object.assign({}, mech.offsets || {})
        if (off[0] === 0 && off[1] === 0) delete offs[k]
        else offs[k] = [off[0], off[1]]
        mechSet("offsets", offs)
    }
    function mechNudge(k, dx, dy) {
        const offs = Object.assign({}, mech.offsets || {})
        const cur = offs[k] || [0, 0]
        const nx = cur[0] + dx, ny = cur[1] + dy
        if (nx === 0 && ny === 0) delete offs[k]   // prune → matches the saved (no-key) state, so nudge→back clears "dirty"
        else offs[k] = [nx, ny]
        mechSet("offsets", offs)
    }
    function mechNudgeReset(k) {
        const offs = Object.assign({}, mech.offsets || {})
        delete offs[k]
        mechSet("offsets", offs)
    }
    // Per-element font/graphic SCALE — the ASSEMBLY tool's second axis (after
    // position). 1 = untouched; prune back to no-key at 1 so scale→back clears
    // "dirty" and classic stays byte-identical. Text multiplies font.pixelSize
    // (crisp), sprites/carets multiply their scale, separators their fontPx.
    function mScale(k) {
        if (!mechOn) return 1   // classic stands the whole pack down — scale never leaks in
        const v = mech.scales ? mech.scales[k] : undefined
        return (v === undefined || v === null) ? 1 : v
    }
    // DEV HOT-RELOAD for raw Image sources (MechSlice/Panel/Button already do this). `rel` is the
    // subfolder-relative id; returns the live dev-tree file:// (with ?v) in a dev build, else the
    // baked qrc. Call sites MUST reference App.heroDevRev — `(App.heroDevRev, home.devSrc("x"))`.
    function devSrc(rel) { var d = (typeof App !== "undefined" && App) ? App.heroDevPath(rel) : ""; return d !== "" ? d + "?v=" + App.heroDevRev : "qrc:/assets/mechui/" + rel + ".png" }
    function mechScaleBy(k, delta) {
        const sc = Object.assign({}, mech.scales || {})
        const cur = (sc[k] === undefined || sc[k] === null) ? 1 : sc[k]
        let nv = Math.round((cur + delta) * 100) / 100   // delta set by the caller (fine/coarse)
        nv = Math.max(0.5, Math.min(2.5, nv))
        if (Math.abs(nv - 1) < 0.001) delete sc[k]
        else sc[k] = nv
        mechSet("scales", sc)
    }
    function mechScaleReset(k) {
        const sc = Object.assign({}, mech.scales || {})
        delete sc[k]
        mechSet("scales", sc)
    }
    // badge pixel scale: the dial pins it, 0 follows the display
    readonly property int chipPx: mech.chipPx > 0 ? mech.chipPx
                                                  : (s >= 1.15 ? 2 : 1)
    // raw family names for the editor's font specimens
    readonly property string mechaName: mechaFont.name
    readonly property string mechaCondName: mechaCond.name
    // dirty marker for the editor: the last state \ actually persisted
    property string mechSavedJson: JSON.stringify(mechDefaults)
    // One gate for every mech element: classic mode stands the whole pack
    // down and the themed chrome (the else-branches) IS the old look.
    readonly property bool mechOn: mech.chrome !== "classic"
    function mechSet(k, v) {
        const b = Object.assign({}, mech)
        b[k] = v
        mech = b
    }
    // ── user pixel sprites → UI chrome (hero emblem + wheel slot icons) ──
    // App.userSprites() builds a QImage per file, so the list is CACHED here and
    // only refreshed when a sprite is saved — it must NEVER run inside a binding.
    property var spriteCache: []
    function refreshSprites() { spriteCache = App.userSprites() }
    function spriteOpts() {
        var o = ["default"]
        for (var i = 0; i < spriteCache.length; ++i) o.push(spriteCache[i].name)
        return o
    }
    function spriteUrlFor(name) {
        if (!name || name === "default") return ""
        for (var i = 0; i < spriteCache.length; ++i)
            if (spriteCache[i].name === name) return spriteCache[i].url
        return ""
    }
    function cycleSprite(key, d) {
        var o = spriteOpts()
        var i = Math.max(0, o.indexOf(mech[key]))
        mechSet(key, o[(i + d + o.length) % o.length])
    }
    function saveMechUi() {
        App.putSetting("mechUiSel", JSON.stringify(mech))
        mechSavedJson = JSON.stringify(mech)
        saveIconPicks()   // the editor's ICONS rows ride the same \ beat
        iconFlash = "✓ MECH SAVED"
        iconFlashTimer.restart()
    }
    function restoreMechUi() {
        try {
            // merge OVER the defaults, same law as the icon picks: a config
            // saved before an option existed must not drop that option
            const m = App.getSetting("mechUiSel", "")
            if (m) mech = Object.assign({}, mechDefaults, JSON.parse(m))
            mechSavedJson = JSON.stringify(mech)
        } catch (e) { console.log("[mechEdit] restore failed: " + e) }
    }
    // Idle bay scan: a tick of attention ripples across the five slot stars
    // every few seconds — the deck sweeping its own stations.
    property int rippleIdx: -1
    Timer {
        interval: 9200; repeat: true
        running: home.visible && App.stage === "home"
        onTriggered: rippleAnim.restart()
    }
    SequentialAnimation {
        id: rippleAnim
        PropertyAction { target: home; property: "rippleIdx"; value: 0 }
        PauseAnimation { duration: 80 }
        PropertyAction { target: home; property: "rippleIdx"; value: 1 }
        PauseAnimation { duration: 80 }
        PropertyAction { target: home; property: "rippleIdx"; value: 2 }
        PauseAnimation { duration: 80 }
        PropertyAction { target: home; property: "rippleIdx"; value: 3 }
        PauseAnimation { duration: 80 }
        PropertyAction { target: home; property: "rippleIdx"; value: 4 }
        PauseAnimation { duration: 80 }
        PropertyAction { target: home; property: "rippleIdx"; value: -1 }
    }
    Component.onCompleted: { restoreIconPicks(); restoreMechUi(); refreshSprites() }
    Connections { target: App; function onUserSpritesChanged() { home.refreshSprites() } }
    // Backing out of the garage without saving discards the unsaved edits —
    // the CRITICAL red clears because the tune rolls back to the last save.
    function revertMechUi() {
        if (JSON.stringify(mech) !== mechSavedJson) { try { mech = Object.assign({}, mechDefaults, JSON.parse(mechSavedJson)) } catch (e) {} }
        // The HEAD/FOOT icon dials aren't in `mech`; roll them back to the
        // open-time snapshot so ESC-without-save doesn't leave them changed.
        if (savedIconJson) { try { const s = JSON.parse(savedIconJson); topSel = s.top; botSel = s.bot } catch (e) {} }
    }
    onMechEditChanged: {
        if (mechEdit) {
            savedIconJson = JSON.stringify({ top: topSel, bot: botSel })   // snapshot for ESC-revert
        } else {
            revertMechUi(); if (garageFocus) garageFocus.lensGridN = 0   // in-lens grid starts OFF each fresh open (sticky only within a session)
        }
    }

    // Pointer INTENT — a hover commits only once the pointer RESTS a beat.
    // Raw onEntered wiring made mouse travel feel fast and imprecise: every
    // gap grazed and bay crossed re-fired the big zone animations mid-
    // flight. One shared timer, last hovered target wins when the pointer
    // settles; sweeping across five posters lands ONE change, not five.
    // Clicks stay instant and cancel any pending intent.
    property var hoverFn: null
    Timer {
        id: hoverDwell
        onTriggered: { const f = home.hoverFn; home.hoverFn = null; if (f) f() }
    }
    function hoverIntent(fn, ms) {
        hoverFn = fn
        hoverDwell.interval = ms === undefined ? 90 : ms
        hoverDwell.restart()
    }
    function hoverCancel() { hoverFn = null; hoverDwell.stop() }

    // Keep the focus inside the visible trio; the selection walks the three
    // slots (left→centre→right) and only PAGES the window when it steps past an
    // edge — so a poster holds its horizontal position and left/right read as
    // expected. Call ONLY from keyboard; hover leaves the window put.
    function cwPageToFocus() {
        const maxStart = Math.max(0, cw.length - 3)
        if (cwIdx < cwWinStart) cwWinStart = cwIdx
        else if (cwIdx > cwWinStart + 2) cwWinStart = cwIdx - 2
        cwWinStart = Math.max(0, Math.min(cwWinStart, maxStart))
    }

    // Horizontal position carries between the wheel and the continue row: drop
    // DOWN from a left-ish section (MOVIES) and you land on the left poster; from
    // a right-ish one (SETTINGS) the right poster — and the reverse going back up.
    function cwSlotForSection() {
        const nSec = items.length
        const f = nSec > 1 ? secIdx / (nSec - 1) : 0     // 0 (left) .. 1 (right)
        return Math.round(f * 2)                          // visible slot 0..2
    }
    function cwEnterFromWheel() {
        cwIdx = Math.max(0, Math.min(cw.length - 1, cwWinStart + cwSlotForSection()))
        cwPageToFocus()
    }
    function wheelEnterFromCw() {
        const slot = Math.max(0, Math.min(2, cwIdx - cwWinStart))
        const nSec = items.length
        secIdx = Math.max(0, Math.min(nSec - 1, Math.round(slot / 2 * (nSec - 1))))
    }

    // Focus zones, top to bottom: the spotlight, the section wheel (always
    // present — it is the primary nav), then the continue-watching shelf.
    readonly property var zones: {
        let z = []
        if (spot.length > 0) z.push("spot")
        z.push("wheel")
        if (cw.length > 0) z.push("cw")
        return z
    }
    // Current zone tracked by NAME, not index — async spot/cw loading changes
    // the array's length/order, so an index would silently point elsewhere.
    // Defaults to (and falls back to) the wheel, which is always present.
    property string zoneName: "wheel"
    readonly property string zone: zones.indexOf(zoneName) >= 0 ? zoneName : "wheel"
    function zoneStep(dir) {
        const i = Math.max(0, zones.indexOf(zone))
        zoneName = zones[Math.max(0, Math.min(i + dir, zones.length - 1))]
    }
    readonly property var curSpot: spot.length > 0 ? spot[Math.min(spotIdx, spot.length - 1)] : null
    // While browsing continue, the spotlight BECOMES the focused continue item —
    // its backdrop, logo and title (the SHOW, for an episode). What you point at
    // is what the whole screen shows. Otherwise it's the normal spotlight item.
    readonly property var heroItem: (cwDeployed && cw.length > 0 && cwIdx < cw.length && cw[cwIdx])
                                    ? cw[cwIdx] : curSpot   // only the OPEN deck drives the hero — a mere hover on CONTINUE must not swap the spotlight
    readonly property string heroFanart: heroItem ? (heroItem.fanart || "") : ""
    readonly property string heroLogo: heroItem ? (heroItem.clearlogo || "") : ""
    readonly property string heroTitle: !heroItem ? ""
                                        : (heroItem.heroTitle !== undefined ? heroItem.heroTitle
                                           : (heroItem.title || ""))

    readonly property var items: [
        { label: "MOVIES", sub: MediaLibrary.movieCount + " TITLES", target: "movies", icon: "󰿎" },
        { label: "TV SHOWS", sub: MediaLibrary.showCount + " SERIES", target: "tv", icon: "󰔂" },
        { label: "YOUTUBE", sub: "SEARCH · FEEDS · QUEUE", target: "youtube", icon: "󰗃" },
        { label: "STATS", sub: "WATCH TIME · STREAKS", target: "stats", icon: "󰄨" },
        { label: "SETTINGS", sub: "SYSTEM CONFIGURATION", target: "settings", icon: "󰒓" },
    ]
    // Weapon-wheel section silhouettes (game-icons.net, CC BY 3.0 — Lorc &
    // Delapouite). 512×512 viewBox path data; the MOVIES cam reads rifle-ish.
    readonly property var wheelIconPaths: ({
        "movies": "M53.15 117.516l-30.803 41.443 17.332 3.5 21.82-29.357zm344.355 16.125c-12.346.048-23.357.238-33.852.336v34.18c23.779.22 54.2 1.112 80.252-1.06 14.555-1.212 27.448-3.51 35.627-6.814 4.09-1.651 6.896-3.533 8.338-5.07 1.442-1.537 1.783-2.397 1.783-4.147 0-1.75-.341-2.61-1.783-4.146-1.442-1.537-4.248-3.419-8.338-5.07-8.179-3.304-21.072-5.602-35.627-6.815-14.554-1.213-30.773-1.455-46.4-1.394zm-111.668 8.425l-32 48h21.633l20-30h50.183v-18zM73.985 146.48L56.09 170.557l82.668 61.441c4.615 3.43 8.257 3.851 11.72 3.13 3.464-.72 6.88-3.011 9.266-6.222 2.386-3.21 3.594-7.141 3.285-10.666-.309-3.524-1.762-6.89-6.377-10.32zm104.87 61.586c1.14 2.815 1.852 5.715 2.105 8.602.22 2.512.128 4.988-.227 7.398H291.39c3.52-1.292 7.315-2 11.263-2 18.12 0 33 14.882 33 33 0 5.391-1.324 10.49-3.652 15h29.652v64h-254V231.31l-16-11.891v130.648h263c5 0 11.051-2.777 15.637-7.363s7.363-10.637 7.363-15.637V235.88l-41.662-27.813zm310.798 2.528l-46 11.5v113.945l46 11.5zm-187 29.472c-8.39 0-15 6.61-15 15 0 8.391 6.61 15 15 15 8.391 0 15-6.609 15-15 0-8.39-6.609-15-15-15zm93 0v78h30v-78zm-223.431 2c-4.633 5.23-10.836 9.18-18.08 10.686-8.326 1.731-17.897-.192-26.123-6.307l-2.366-1.757v71.378h60v-46h87.653a32.623 32.623 0 0 1-3.653-15c0-4.606.965-9.003 2.698-13zm31.431 46v28h140v-28h-41zm-52.183 80l-17.614 26.418c62.625-10.657 116.488-11.084 168.956-.957l-16.975-25.46z",
        "tv": "M132.992 48.756l-9.984 14.976 77.287 51.524c4.32-4.192 9.542-8.012 15.703-11.162l-83.006-55.338zm246.016 0l-83.006 55.338c6.16 3.15 11.383 6.97 15.703 11.162l77.287-51.524-9.984-14.976zM256 113.244c-22 0-35.334 7.06-43.637 15.363-4.703 4.704-7.58 9.97-9.316 14.637h105.906c-1.736-4.668-4.613-9.933-9.316-14.637-8.303-8.303-21.637-15.363-43.637-15.363zm-191.936 48c-5.044 0-11.106 2.784-15.697 7.37-4.59 4.584-7.367 10.63-7.367 15.63v279h430V184.2c.026-5.457-2.764-11.393-7.227-15.87-4.463-4.477-10.346-7.086-14.826-7.086H64.064zm30.295 23h257.745c10.374 0 20.79 6.818 26.776 16H112c-16 0-32 16-32 32v160c25.924-162.54 145.877-185.697 299.016-191.795 3.106 4.836 4.984 10.315 4.984 15.794v192c0 16-16 32-33.88 32H95.35c-15.35 0-31.35-16-31.35-32v-192c0-16 16-32 30.36-32zm328.663 7c13.7 0 25 11.3 25 25s-11.3 25-25 25-25-11.3-25-25 11.3-25 25-25zm-23.023 144h48v18h-48v-18zm0 32h48v18h-48v-18zm0 32h48v18h-48v-18z",
        "youtube": "M60.307 17.998A201.117 201.117 0 0 0 55.002 64c0 78.375 45.002 146.35 110.539 179.486-8.783-10.556-16.478-22.658-23.1-35.912-42.318-33.5-69.443-85.327-69.443-143.574 0-15.895 2.035-31.305 5.832-46.002H60.307zm66.644 0c-5.142 14.384-7.949 29.87-7.949 46.002 0 51.245 28.27 95.989 70.031 119.482-6.264-10.227-11.17-21.604-15.023-33.158C151.2 128.657 136.998 98.02 136.998 64c0-16.319 3.275-31.856 9.193-46.002h-19.24zm72.445 0C189.156 30.565 183.002 46.585 183.002 64c0 26.543 14.293 49.845 35.572 62.623-3.806-9.484-6.58-20.417-8.332-32.014-5.84-8.738-9.244-19.259-9.244-30.609 0-11.35 3.403-21.87 9.244-30.61a168.14 168.14 0 0 1 3.053-15.392h-13.899zm99.31 0a168.14 168.14 0 0 1 3.052 15.393c5.84 8.738 9.244 19.259 9.244 30.609 0 11.35-3.403 21.87-9.244 30.61-1.751 11.596-4.526 22.529-8.332 32.013 21.279-12.778 35.572-36.08 35.572-62.623 0-17.415-6.153-33.435-16.394-46.002h-13.899zm67.103 0c5.918 14.146 9.193 29.683 9.193 46.002 0 34.02-14.202 64.657-37.012 86.324-3.852 11.554-8.76 22.93-15.023 33.158C364.728 159.99 392.998 115.245 392.998 64c0-16.132-2.807-31.618-7.95-46.002h-19.24zm67.36 0A183.653 183.653 0 0 1 439.003 64c0 58.247-27.125 110.074-69.443 143.574-6.622 13.254-14.317 25.356-23.1 35.912C411.996 210.35 456.998 142.375 456.998 64c0-15.825-1.837-31.226-5.305-46.002H433.17zM256 40.998c-12.81 0-23.002 10.192-23.002 23.002 0 12.81 10.192 23.002 23.002 23.002 12.81 0 23.002-10.192 23.002-23.002 0-12.81-10.192-23.002-23.002-23.002zm-20.35 58.537L119.398 477.354l17.204 5.292 13.15-42.74L256 415.39l106.248 24.517 13.15 42.74 17.204-5.292L276.35 99.535a40.612 40.612 0 0 1-17.192 5.328l49.654 161.381L256 283.848l-52.813-17.604 49.655-161.38a40.612 40.612 0 0 1-17.192-5.329zM197.893 283.45l29.65 9.885-36.428 12.143 6.778-22.028zm116.214 0l6.778 22.028-36.428-12.143 29.65-9.885zM256 302.82l52.652 17.55L256 339.516l-52.65-19.147L256 302.82zm-73.074 29.275l46.74 16.998-58.518 21.28 11.778-38.278zm146.148 0l11.778 38.277-58.52-21.28 46.742-16.997zM256 358.666l64.354 23.402L256 396.92l-64.355-14.852L256 358.666zm-92.16 35.455l52.144 12.033-60.115 13.873 7.97-25.906zm184.318 0l7.973 25.904-60.113-13.87 52.14-12.034z",
        "stats": "M23 23v466h466v-18H41v-82.184l85.854-57.234 70.023 70.022 65.133-260.536L387.28 203.7 455.07 95.73l19.317 11.858 6.102-71.1-60.644 37.616 19.884 12.207-59.01 93.99-130.732-65.366-62.865 251.462-57.98-57.978L41 367.184V23H23z",
        "settings": "M234.875 18.78c-26.087 2.367-51.557 8.56-74.875 18.782 15.37 32.763 14.222 66.706-6.72 82.407-20.835 15.617-54.055 7.965-81.124-15.69-16.246 19.452-29.336 41.36-38.875 65.626 33.83 12.333 56.635 37.665 52.94 63.5-3.698 25.835-32.697 43.74-68.626 46.094 2.338 25.796 8.91 50.778 18.937 73.875 17.81-8.182 35.793-11.09 51.095-8.938 13.032 1.87 23.927 7.015 31.156 16.657 15.817 21.097 7.603 54.713-16.78 81.97 19.516 16.35 42.216 29.444 66.594 39.03 12.33-33.828 37.655-56.634 63.5-52.938 25.844 3.697 43.74 32.696 46.094 68.625 26.087-2.365 51.557-8.555 74.875-18.78-15.766-32.997-14.26-67.588 6.843-83.406 9.64-7.23 22.568-9.022 35.594-7.125 15.112 2.16 31.19 10.25 45.563 22.78 16.088-19.345 29.4-41.51 38.875-65.594-33.83-12.332-56.635-37.653-52.938-63.5 3.697-25.846 32.665-43.772 68.594-46.125-2.36-25.944-8.774-50.663-18.906-73.874-32.612 15.117-66.66 13.145-82.282-7.687-15.696-20.944-7.252-53.86 16.688-81-19.52-16.352-42.248-29.447-66.625-39.032-12.332 33.828-37.657 56.66-63.5 52.968-25.846-3.693-43.744-32.696-46.095-68.625zm21.656 95.126c79.626 0 144.376 64.752 144.376 144.375 0 79.626-64.75 144.376-144.375 144.376-79.624 0-144.374-64.75-144.374-144.375 0-79.624 64.75-144.374 144.375-144.374zm0 18.688c-69.524 0-125.686 56.162-125.686 125.687 0 69.526 56.162 125.69 125.687 125.69 69.526 0 125.69-56.164 125.69-125.69 0-69.522-56.164-125.686-125.69-125.686zm.033 15.125c61.094 0 110.625 49.53 110.625 110.624 0 61.095-49.53 110.625-110.625 110.625s-110.625-49.53-110.625-110.626c0-61.095 49.53-110.625 110.625-110.625z",
    })
    // Debug icon pool — candidate weapon silhouettes per section, cycled
    // live in icon-debug mode (` toggles, [ ] cycle the focused foot).
    // icons8 GIFs live in the local icon cache, not the repo (their licence).
    readonly property string gifDir: StandardPaths.writableLocation(StandardPaths.GenericCacheLocation) + "/codec/icons/"
    readonly property var wheelIconPoolAll: ([{"n":"abacus","d":"M37 73v382h18V73zm418.045 0l1.91 382h18l-1.91-382zM105 160c-14.638 0-27.157 9.715-31.43 23-2.405 6.634-1.479 14.38-.574 18 3.61 14.3 16.641 25 32.004 25 14.17 0 26.36-9.102 31-21.736C140.64 216.898 152.83 226 167 226c15.363 0 28.394-10.7 32.004-25h238.682l-.09-18H198.43c-4.273-13.285-16.792-23-31.43-23-14.17 0-26.36 9.102-31 21.736C131.36 169.102 119.17 160 105 160zm0 18c8.39 0 15 6.61 15 15s-6.61 15-15 15-15-6.61-15-15 6.61-15 15-15zm62 0c8.39 0 17 6.61 17 15s-8.61 15-17 15-15-6.61-15-15 6.61-15 15-15zm33 45c-15.002 0-27.775 10.206-31.729 24H73v18h95.271c3.954 13.794 16.727 24 31.729 24 15.002 0 27.775-10.206 31.729-24h206.277l-.092-18H231.73c-3.954-13.794-16.727-24-31.729-24zm0 18c8.39 0 15 6.61 15 15s-6.61 15-15 15-15-6.61-15-15 6.61-15 15-15zm83 47c-14.638 0-27.157 9.715-31.43 23H73v18h177.996c3.61 14.3 16.641 25 32.004 25 14.17 0 26.36-9.102 31-21.736C318.64 344.898 330.83 354 345 354c14.17 0 26.36-9.102 31-21.736C380.64 344.898 392.83 354 407 354c15.363 0 28.394-10.7 32.004-25 1.31-3.077.621-13.458-.77-18C432 294.406 418.467 288.286 407 288c-14.17 0-26.36 9.102-31 21.736C371.36 297.102 359.17 288 345 288c-14.17 0-26.36 9.102-31 21.736C309.36 297.102 297.17 288 283 288zm62 66c-13.892 0-25.874 8.752-30.71 21H73v18h239.564c2.853 15.29 16.366 27 32.436 27s29.583-11.71 32.436-27h61.209l-.09-18H375.71c-4.837-12.248-16.819-21-30.711-21zm-62-48c8.39 0 15 6.61 15 15s-6.61 15-15 15-15-6.61-15-15 6.61-15 15-15zm62 0c8.39 0 15 6.61 15 15s-6.61 15-15 15-15-6.61-15-15 6.61-15 15-15zm62 0c8.39 0 15 6.61 15 15s-6.61 15-15 15-15-6.61-15-15 6.61-15 15-15zm-62 66c8.39 0 15 6.61 15 15s-6.61 15-15 15-15-6.61-15-15 6.61-15 15-15zM25 473v16h462v-16z","b":[25.0,73.0,462.0,416.0]},{"n":"attack-gauge","d":"M105 73v174h46V73h-46zm-73 48c-1.75 0-2.906.439-4.574 1.898-1.668 1.46-3.578 4.104-5.201 7.756C18.978 137.96 17 149 17 160s1.978 22.041 5.225 29.346c1.623 3.652 3.533 6.296 5.2 7.756C29.095 198.562 30.25 199 32 199h55v-78H32zm137 0v30h180l40-30H169zm247.95 1.537L367 160l49.95 37.463L491.872 160l-74.924-37.463zM169 169v30h220l-40-30H169zM23 311v146h466V311H23zm361 18h87v110h-87V329z","b":[17.0,73.0,474.9,384.0]},{"n":"calculator","d":"M95 25v462h322V25H95zm193 18h80v18h-80V43zM114 83h284v84H114V83zm22 46v18h88v-18h-88zm-22 54h58v58h-58v-58zm76 0h58v58h-58v-58zm74 0h58v58h-58v-58zm76 0h58v58h-58v-58zm-208 18v22h22v-22h-22zm76 0v22h22v-22h-22zm74 0v22h22v-22h-22zm76 0v22h22v-22h-22zm-244 56h58v58h-58v-58zm76 0h58v58h-58v-58zm74 0h58v58h-58v-58zm76 0h58v58h-58v-58zm-208 18v22h22v-22h-22zm76 0v22h22v-22h-22zm74 0v22h22v-22h-22zm76 0v22h22v-22h-22zm-244 56h58v58h-58v-58zm76 0h58v58h-58v-58zm74 0h58v58h-58v-58zm76 0h58v132h-58V331zm-208 18v22h22v-22h-22zm76 0v22h22v-22h-22zm74 0v22h22v-22h-22zm76 0v96h22v-96h-22zm-244 56h58v58h-58v-58zm76 0h58v58h-58v-58zm74 0h58v58h-58v-58zm-132 18v22h22v-22h-22zm76 0v22h22v-22h-22zm74 0v22h22v-22h-22z","b":[95.0,25.0,322.0,462.0]},{"n":"chart","d":"M23 23v466h466v-18H41v-82.184l85.854-57.234 70.023 70.022 65.133-260.536L387.28 203.7 455.07 95.73l19.317 11.858 6.102-71.1-60.644 37.616 19.884 12.207-59.01 93.99-130.732-65.366-62.865 251.462-57.98-57.978L41 367.184V23H23z","b":[23.0,23.0,466.0,466.0]},{"n":"circuitry","d":"M413.72 19.395v98.64l-46.116 46.117-34.198-34.2-6.607 6.61-141.52 141.516 113.513 113.51-52.775 52.773.002 50.31h18.687v-42.568l47.3-47.3 21.4 21.4 148.122-148.124-60.165-60.164 67.447-67.45V19.395h-18.687v123.33l-61.975 61.975-27.332-27.333 51.59-51.59V19.395H413.72zM19.36 30.303V48.99h186.607l44.254 44.254c-2.56 4.393-4.032 9.496-4.032 14.947 0 16.422 13.312 29.736 29.732 29.736s29.732-13.314 29.732-29.735c0-16.42-13.312-29.73-29.732-29.73-4.143 0-8.088.85-11.672 2.382l-50.54-50.54H19.36zm0 55.478v18.69l131.126.003 44.254 44.254c-2.56 4.392-4.035 9.496-4.035 14.947 0 16.42 13.312 29.732 29.732 29.732s29.733-13.312 29.733-29.732-13.312-29.733-29.732-29.733c-4.144 0-8.088.85-11.672 2.382l-50.54-50.54H19.362zm83.386 55.482l-83.385.002v18.69l75.646-.003 44.254 44.26c-2.56 4.39-4.033 9.496-4.033 14.946 0 16.42 13.312 29.733 29.732 29.733s29.73-13.313 29.73-29.734c0-16.42-13.31-29.734-29.73-29.734-4.145 0-8.09.85-11.675 2.383l-50.54-50.543zm230.66 15.12L455.1 278.08 333.406 399.77 211.71 278.08l121.696-121.695zm-1.254 27.388l-94.574 94.574 95.012 95.015 13.215-13.214-81.797-81.8 81.36-81.362-13.216-13.214zm-312.79 21.558v51.207l160.13 160.13v78.005h18.69V384.146L19.362 205.328zm346.51 8.397L352.66 226.94l51.48 51.482-51.77 51.77 13.218 13.214 64.982-64.984-64.695-64.697zm-29.93 33.16c-17.45 0-31.592 14.147-31.592 31.594 0 17.445 14.143 31.59 31.59 31.59 17.45 0 31.593-14.145 31.593-31.59 0-17.45-14.143-31.595-31.592-31.595zM19.36 295.35v51.207l94.886 94.88v53.233h18.688v-85.75L19.362 295.35zm427.378 73.154c-16.42 0-29.732 13.312-29.732 29.732s13.312 29.735 29.732 29.735c3.994 0 7.802-.794 11.28-2.222l36.62 36.615v-26.427l-22.402-22.4c2.688-4.47 4.237-9.704 4.237-15.3 0-16.42-13.314-29.732-29.735-29.732zM19.36 386.19V437.4l31.294 31.29-.002 25.982H69.34l.006-58.496L19.36 386.19zm371.902 37.796c-16.42 0-29.733 13.312-29.733 29.733 0 16.42 13.31 29.73 29.732 29.73 3.513 0 6.882-.612 10.01-1.73l12.955 12.95h26.43l-24.58-24.578c3.104-4.697 4.917-10.322 4.917-16.373 0-16.422-13.312-29.734-29.732-29.734z","b":[19.4,19.4,475.3,475.3]},{"n":"database","d":"M256 19.11c-48.03 0-91.515 6.572-122.235 16.82-15.36 5.123-27.503 11.218-35.225 17.308C90.82 59.328 88 64.702 88 69.278c0 4.574 2.82 9.948 10.54 16.038 7.722 6.09 19.865 12.184 35.225 17.308 30.72 10.247 74.204 16.82 122.235 16.82 48.03 0 91.515-6.573 122.235-16.82 15.36-5.124 27.503-11.22 35.225-17.308 7.72-6.09 10.54-11.464 10.54-16.04 0-4.574-2.82-9.948-10.54-16.038-7.722-6.09-19.865-12.185-35.225-17.308C347.515 25.682 304.03 19.11 256 19.11zM88 99.434v92.63c0 5.84 5.338 13.804 19.285 21.862 13.947 8.058 35.283 15.424 61.976 20.564 53.387 10.283 120.093 10.283 173.48 0 26.692-5.14 48.028-12.505 61.975-20.563C418.662 205.87 424 197.905 424 192.067V99.434c-10.135 7.894-23.752 14.42-40.19 19.903-33.272 11.098-78.19 17.727-127.81 17.727-49.62 0-94.538-6.63-127.81-17.727-16.438-5.483-30.055-12.01-40.19-19.903zm0 122.75v95.32c0 5.84 5.338 13.803 19.285 21.86 13.947 8.06 35.283 15.425 61.976 20.566 53.387 10.282 120.093 10.282 173.48 0 26.692-5.14 48.028-12.506 61.975-20.564 13.947-8.058 19.285-16.022 19.285-21.86v-95.322c-3.18 2.475-6.685 4.812-10.47 7-16.58 9.578-39.446 17.215-67.46 22.61-56.023 10.79-124.117 10.79-180.14 0-28.014-5.395-50.88-13.032-67.46-22.61-3.785-2.188-7.29-4.525-10.47-7zm0 125.44v98.035h.386c.994 3.89 4.026 8.27 10.154 13.102 7.722 6.09 19.865 12.185 35.225 17.308 30.72 10.248 74.204 16.82 122.235 16.82 48.03 0 91.515-6.572 122.235-16.82 15.36-5.123 27.503-11.218 35.225-17.308 6.128-4.833 9.16-9.213 10.154-13.102H424V347.623c-3.18 2.475-6.685 4.813-10.47 7-16.58 9.58-39.446 17.215-67.46 22.61-56.023 10.79-124.117 10.79-180.14 0-28.014-5.395-50.88-13.03-67.46-22.61-3.785-2.187-7.29-4.525-10.47-7z","b":[88.0,19.1,336.0,473.8]},{"n":"diagram","d":"M146.24 120.334c-23.036 0-52.223 9.79-76.38 31.71-22.6 20.513-40.276 52.013-42.4 94.956H22v18h36v-18H45.48c2.032-38.054 17.27-64.194 36.48-81.627 20.686-18.774 46.56-27.04 64.28-27.04s43.56 8.264 64.233 27.038c15.496 14.073 28.41 33.83 33.908 60.94 3.676-1.484 7.677-2.31 11.86-2.31 2.078 0 4.11.208 6.082.594-6.12-31.684-21.29-55.785-39.748-72.547-24.138-21.92-53.298-31.713-76.334-31.713zm-9 40.088V247H130v18h36v-18h-10.76v-86.578h-18zm119 81.578c-7.838 0-14 6.16-14 14s6.162 14 14 14c7.84 0 14-6.16 14-14s-6.16-14-14-14zM76 247v18h36v-18H76zm108 0v18h36v-18h-36zm108 0v18h36v-18h-36zm54 0v18h11.24v86.078h18V265H382v-18h-36zm54 0v18h36v-18h-36zm54 0v18h13c-2.032 38.053-17.27 64.192-36.48 81.625-20.686 18.774-46.56 27.04-64.28 27.04-17.718 0-43.56-8.263-64.232-27.038-15.496-14.073-28.41-33.827-33.908-60.938-3.676 1.484-7.677 2.31-11.86 2.31-2.078 0-4.11-.208-6.082-.594 6.12 31.683 21.292 55.785 39.75 72.547 24.138 21.92 53.297 31.713 76.332 31.713 23.036 0 52.224-9.79 76.38-31.71 22.6-20.513 40.276-52.014 42.4-94.956H490v-18h-36z","b":[22.0,120.3,468.0,271.3]},{"n":"diamond-trophy","d":"M158.6 41l34.5 69.1L239.2 41zm114.2 0l46.1 69.1L353.4 41zM256 48.22L208.8 119h94.4zm-113.9.14L83.22 119h94.18zm227.8 0L334.6 119h94.2zM80.82 137L196.8 311H249l-63.4-174zm124.08 0L256 277.7 307.1 137zm121.5 0L263 311h52.2l116-174zM201 329v46h110v-46zm-67.8 64l-53.69 94H432.5l-53.7-94H183zm26.8 46h192v18H160z","b":[79.5,41.0,353.0,446.0]},{"n":"gold-stack","d":"M313.824 61.625l-67.865 118.24L176 96l-4.08 129.77L56.162 105.264 112 272l-81.986-63.115 19.865 113.77L18 311.724V391h7.514l16-48h40l16-48h40l16-48h40l16-48h92.972l16 48h40l16 48h40l16 48h40l16 48H494V241.285l-77.783 39.547L480 144l-125.797 83.758L400 128l-74.926 66.87zM222.486 217l-10 30h87.028l-10-30zm-56 48l-10 30h87.028l-10-30zm86 0L256 275.54l3.514-10.54zm26 0l-10 30h87.028l-10-30zm-168 48l-10 30h87.028l-10-30zm86 0L200 323.54l3.514-10.54zm26 0l-10 30h87.028l-10-30zm86 0L312 323.54l3.514-10.54zm26 0l-10 30h87.028l-10-30zm-280 48l-10 30h87.028l-10-30zm86 0L144 371.54l3.514-10.54zm26 0l-10 30h87.028l-10-30zm86 0L256 371.54l3.514-10.54zm26 0l-10 30h87.028l-10-30zm86 0L368 371.54l3.514-10.54zm26 0l-10 30h87.028l-10-30zM18 409v30h57.514l-10-30zm66.486 0L88 419.54 91.514 409zm26 0l-10 30h87.028l-10-30zm86 0L200 419.54l3.514-10.54zm26 0l-10 30h87.028l-10-30zm86 0L312 419.54l3.514-10.54zm26 0l-10 30h87.028l-10-30zm86 0L424 419.54l3.514-10.54zm26 0l-10 30H494v-30zm-418 48L32 467.54 35.514 457zm26 0l-10 30h87.028l-10-30zm86 0L144 467.54l3.514-10.54zm26 0l-10 30h87.028l-10-30zm86 0L256 467.54l3.514-10.54zm26 0l-10 30h87.028l-10-30zm86 0l3.344 10.033.342-.01L371.514 457zm26 0l-10 30h87.028l-10-30zm86 0l2.287 6.863 2.477-.07 2.264-6.793z","b":[18.0,61.6,476.0,425.4]},{"n":"growth","d":"M256 33.78C205.2 119.6 154.2 177 103.7 228.7c101.3-39.2 203.3-39.2 304.6 0C357.8 177 306.8 119.6 256 33.78zm0 183.02c-10.4 0-20.8.5-31.3 1.4 6.5 104.2-48.4 216.9-158.29 268.8H445.6c-109.9-51.9-164.8-164.6-158.3-268.8-10.5-.9-20.9-1.4-31.3-1.4z","b":[66.4,33.8,379.2,453.2]},{"n":"histogram","d":"M23 23v466h466v-18h-40.893V256h-48v215h-31.675V159.33h-48V471h-31.227V320.242h-48V471H207.2V80.418h-48V471H128V192H80v279H41V23H23z","b":[23.0,23.0,466.0,466.0]},{"n":"laurels-trophy","d":"M137.273 41c1.41 59.526 16.381 119.035 35.125 167.77 19.69 51.191 44.086 90.988 57.965 104.867l2.637 2.636V343h46v-26.727l2.637-2.636c13.879-13.88 38.275-53.676 57.965-104.867 18.744-48.735 33.715-108.244 35.125-167.77zm-50.605 68.295c-17.97 6.05-32.296 18.214-37.625 30.367-3.015 6.875-3.48 13.44-.988 20.129.285.766.62 1.54.996 2.318a119.032 119.032 0 0 1 8.504-4.812l6.277-3.215 4.621 5.326c5.137 5.92 9.61 12.37 13.422 19.125 2.573-3.06 5.207-7.864 7.05-14.037 4.491-15.034 4.322-36.95-2.257-55.201zm338.664 0c-6.58 18.25-6.748 40.167-2.258 55.201 1.844 6.173 4.478 10.977 7.051 14.037 3.813-6.756 8.285-13.205 13.422-19.125l4.621-5.326 6.277 3.215a119.033 119.033 0 0 1 8.504 4.812c.375-.779.71-1.552.996-2.318 2.492-6.689 2.027-13.254-.988-20.129-5.329-12.153-19.655-24.317-37.625-30.367zm-365.975 67.74c-20.251 12.486-34.121 31.475-36.746 47.973-1.447 9.1.09 17.224 5.323 24.545 1.66 2.324 3.743 4.594 6.304 6.76a116.606 116.606 0 0 1 11.44-14.977l4.72-5.24 6.217 3.33c7.91 4.236 15.262 9.424 21.94 15.252.973-3.633 1.619-7.892 1.773-12.616.636-19.438-6.762-45.536-20.97-65.027zm393.286 0c-14.21 19.49-21.607 45.59-20.971 65.027.154 4.724.8 8.983 1.773 12.616 6.678-5.828 14.03-11.016 21.94-15.252l6.217-3.33 4.72 5.24a116.606 116.606 0 0 1 11.44 14.976c2.56-2.165 4.643-4.435 6.304-6.76 5.233-7.32 6.77-15.444 5.323-24.544-2.625-16.498-16.495-35.487-36.746-47.973zM54.4 259.133c-14.394 18.806-20.496 41.413-17.004 57.748 1.928 9.014 6.298 16.078 13.844 21.078 4.944 3.276 11.48 5.7 19.94 6.645a120.631 120.631 0 0 1 7.101-17.852l3.125-6.338 6.9 1.535c4.095.911 8.133 2.046 12.094 3.377-.373-3.838-1.309-8.185-2.925-12.82-6.416-18.396-22.749-40.184-43.075-53.373zm403.2 0c-20.326 13.189-36.66 34.977-43.075 53.373-1.616 4.635-2.552 8.982-2.925 12.82a119.337 119.337 0 0 1 12.093-3.377l6.9-1.535 3.126 6.338a120.63 120.63 0 0 1 7.101 17.852c8.46-.944 14.996-3.37 19.94-6.645 7.546-5 11.916-12.065 13.844-21.078 3.492-16.335-2.61-38.942-17.004-57.748zM91.5 341.527c-9.285 23.14-9.027 47.85-.709 63.54 4.57 8.619 11.106 14.607 20.268 17.562 4.586 1.479 9.957 2.19 16.185 1.803-2.135-11.155-2.771-22.97-1.756-34.938l.602-7.074 7.02-1.065a129.43 129.43 0 0 1 13.458-1.312c.554-.025 1.107-.04 1.66-.059-12.419-15.776-33.883-31.43-56.728-38.457zm329 0c-22.845 7.027-44.31 22.68-56.729 38.457.554.019 1.107.034 1.66.059 4.5.206 8.995.637 13.46 1.312l7.02 1.065.6 7.074c1.016 11.967.38 23.783-1.755 34.938 6.228.386 11.6-.324 16.185-1.803 9.162-2.955 15.699-8.943 20.268-17.563 8.318-15.69 8.576-40.4-.709-63.539zM199.729 361c-1.943 7.383-6.045 14.043-11.366 19.363a46.544 46.544 0 0 1-3.484 3.125c14.804 3.295 28.659 8.692 40.404 15.46 2.384-5.36 5.376-10.345 9.408-14.534C239.96 378.942 247.51 375 256 375c8.491 0 16.041 3.942 21.309 9.414 4.032 4.19 7.024 9.175 9.408 14.533 11.815-6.808 25.766-12.23 40.67-15.52a48.107 48.107 0 0 1-3.739-3.413c-5.227-5.333-9.27-11.852-11.261-19.014zM256 393c-3.434 0-5.635 1.084-8.34 3.895-2.704 2.81-5.395 7.52-7.527 13.298-4.265 11.556-6.343 27-7.156 38.446-1.07 15.043 3 33.368 12.285 40.06 4.733 3.412 16.743 3.412 21.476 0 9.285-6.692 13.355-25.017 12.285-40.06-.813-11.446-2.891-26.89-7.156-38.446-2.132-5.777-4.823-10.488-7.527-13.298-2.705-2.81-4.906-3.895-8.34-3.895zm-103.521 4.979c-1.714-.008-3.424.022-5.127.09-1.405.055-2.77.281-4.164.39-.418 27.817 9.816 53.543 24.994 66.644 8.264 7.134 17.586 10.772 28.35 10.157 5.908-.338 12.394-2.03 19.374-5.52-1.27-7.665-1.377-15.42-.883-22.379.632-8.89 1.852-19.962 4.479-30.877-17.16-10.686-42.426-18.395-67.023-18.506zm207.042 0c-24.597.11-49.863 7.82-67.023 18.505 2.627 10.915 3.847 21.987 4.479 30.877.494 6.958.387 14.714-.883 22.38 6.98 3.49 13.466 5.181 19.375 5.519 10.763.615 20.085-3.023 28.35-10.156 15.177-13.102 25.411-38.828 24.993-66.645-1.393-.109-2.76-.335-4.164-.39a116.32 116.32 0 0 0-5.127-.09z","b":[21.2,41.0,469.7,451.1]},{"n":"medal","d":"M140.5 19.156V192.28l21.813 28.532h15.53V19.156H140.5zm56.03 0v201.656h122.064V19.156H196.53zm140.75 0v201.656h12.345l22.094-28.53V19.155h-34.44zM173.94 239.5v18.125H338.03V239.5H173.94zm30.78 36.813l8.032 10.53c-25.262 12.014-45.128 33.46-55.094 59.813l65.03 47.47 5.47 3.968-2.094 6.437-17.312 53.69 45.656-33.064 5.5-3.97 5.47 3.97 62.468 45.22c24.872-19.957 40.78-50.6 40.78-85.063 0-6.494-.573-12.854-1.655-19.032l-58.845 42.94-11-15.095L361.688 347c-10.683-28.55-32.932-51.392-61.125-62.78l6.125-7.908h-38.813l-25.5 78-17.75-5.812 23.594-72.188h-43.5zm-52.374 89.625c-1.123 6.286-1.72 12.76-1.72 19.375 0 32.163 13.84 61.008 35.907 80.937l19.69-61.03-53.876-39.283zm107.562 78.343l-51.53 37.314c15.266 8.124 32.707 12.72 51.25 12.72 18.673-.002 36.218-4.676 51.562-12.908l-51.282-37.125z","b":[140.5,19.2,231.2,475.2]},{"n":"medallist","d":"M75.371 28.377L27.027 52.549C42.623 99.323 61.451 155.606 80.44 206.875c19.925 53.796 40.201 101.86 55.05 124.133l1.243 1.865L152.145 487h91.267C226.978 481.65 215 466.15 215 448c0-4.871.865-9.551 2.445-13.896-1.628-3.134-3.22-6.442-4.812-9.913-7.642-16.655-14.483-37.267-20.32-58.84-10.19-37.656-17.3-77.733-18.946-104.525-9-14.793-17.445-31.369-25.547-49.025-26.904-58.636-49.91-129.09-72.449-183.424zm361.258 0c-22.54 54.335-45.545 124.788-72.45 183.424-8.1 17.656-16.546 34.232-25.546 49.025-1.645 26.792-8.756 66.87-18.945 104.526-5.838 21.572-12.679 42.184-20.32 58.84-1.593 3.47-3.185 6.778-4.813 9.912A40.593 40.593 0 0 1 297 448c0 18.15-11.978 33.65-28.412 39h91.267l15.413-154.127 1.244-1.865c14.848-22.272 35.124-70.337 55.049-124.133 18.988-51.269 37.816-107.552 53.412-154.326l-48.344-24.172zM256 105c-18.687 0-36.025 10.529-49.244 29.035C193.537 152.541 185 178.81 185 208c0 29.19 8.537 55.459 21.756 73.965S237.313 311 256 311s36.025-10.529 49.244-29.035C318.463 263.459 327 237.19 327 208c0-29.19-8.537-55.459-21.756-73.965S274.687 105 256 105zm-59.787 192.8c3.19 19.66 7.752 41.702 13.475 62.848 5.662 20.928 12.321 40.816 19.304 56.036.062.134.126.26.188.394a41.119 41.119 0 0 1 13.547-7.844c-6.666-14.749-12.609-33.366-17.422-51.416-4.294-16.1-7.53-30.494-9.094-41.494-7.36-4.977-14.082-11.254-19.998-18.523zm119.574 0c-5.916 7.27-12.639 13.547-19.998 18.524-1.565 11-4.8 25.393-9.094 41.494-4.813 18.05-10.756 36.667-17.422 51.416a41.12 41.12 0 0 1 13.547 7.844c.062-.134.126-.26.188-.394 6.983-15.22 13.642-35.108 19.305-56.036 5.722-21.146 10.284-43.189 13.474-62.847zm-79.375 28.259c1.624 8.15 3.737 17.575 6.283 27.123 3.799 14.245 8.528 29.19 13.305 41.347 4.777-12.157 9.506-27.102 13.305-41.347 2.546-9.548 4.66-18.972 6.283-27.123-6.28 1.91-12.833 2.941-19.588 2.941-6.755 0-13.307-1.031-19.588-2.941zM256 425c-12.81 0-23 10.19-23 23s10.19 23 23 23 23-10.19 23-23-10.19-23-23-23z","b":[27.0,28.4,457.9,458.6]},{"n":"money-stack","d":"M327.027 65.816L229.79 128.23l9.856 5.397 86.51-55.53 146.735 83.116-84.165 54.023 4.1 2.244v6.848l65.923-42.316 13.836 7.838-79.76 51.195v11.723l64.633-41.487 15.127 8.57-79.76 51.195v11.723l64.633-41.487 15.127 8.57-79.76 51.195v11.723l100.033-64.21-24.828-14.062 24.827-15.937-24.828-14.064 24.827-15.937-23.537-13.333 23.842-15.305-166.135-94.106zm31.067 44.74c-21.038 10.556-49.06 12.342-68.79 4.383l-38.57 24.757 126.903 69.47 36.582-23.48c-14.41-11.376-13.21-28.35 2.942-41.67l-59.068-33.46zM227.504 147.5l-70.688 46.094 135.61 78.066 1.33-.85c2.5-1.61 6.03-3.89 10.242-6.613 8.42-5.443 19.563-12.66 30.674-19.86 16.002-10.37 24.248-15.72 31.916-20.694L227.504 147.5zm115.467 1.17a8.583 14.437 82.068 0 1 .003 0 8.583 14.437 82.068 0 1 8.32 1.945 8.583 14.437 82.068 0 1-.87 12.282 8.583 14.437 82.068 0 1-20.273 1.29 8.583 14.437 82.068 0 1 .87-12.28 8.583 14.437 82.068 0 1 11.95-3.237zm-218.423 47.115L19.143 263.44l23.537 13.333-23.842 15.305 24.828 14.063-24.828 15.938 24.828 14.063-24.828 15.938 166.135 94.106L285.277 381.8V370.08l-99.433 63.824L39.11 350.787l14.255-9.15 131.608 74.547L285.277 351.8V340.08l-99.433 63.824L39.11 320.787l14.255-9.15 131.608 74.547L285.277 321.8V310.08l-99.433 63.824L39.11 290.787l13.27-8.52 132.9 75.28 99.997-64.188v-5.05l-5.48-3.154-93.65 60.11-146.73-83.116 94.76-60.824-9.63-5.543zm20.46 11.78l-46.92 30.115c14.41 11.374 13.21 28.348-2.942 41.67l59.068 33.46c21.037-10.557 49.057-12.342 68.787-4.384l45.965-29.504-123.96-71.358zm229.817 32.19c-8.044 5.217-15.138 9.822-30.363 19.688-11.112 7.203-22.258 14.42-30.69 19.873-4.217 2.725-7.755 5.01-10.278 6.632-.09.06-.127.08-.215.137v85.924l71.547-48.088v-84.166zm-200.99 17.48a8.583 14.437 82.068 0 1 8.32 1.947 8.583 14.437 82.068 0 1-.87 12.28 8.583 14.437 82.068 0 1-20.27 1.29 8.583 14.437 82.068 0 1 .87-12.28 8.583 14.437 82.068 0 1 11.95-3.236z","b":[18.8,65.8,474.3,380.4]},{"n":"network-bars","d":"M428.4 27.8v456.4h60.9V27.8h-60.9zM327 168.2v316h60.8v-316H327zM225.4 273.6v210.6h61V273.6h-61zM124 343.8v140.4h60.9V343.8H124zM22.67 394.9v89.3h60.84v-89.3H22.67z","b":[22.7,27.8,466.6,456.4]},{"n":"pie-chart","d":"M290.352 13.213l-11.475 218.984 204.68-78.584a219.242 219.284 0 0 0-193.205-140.4zm-51.39 47.566A219.242 219.284 0 0 0 38.59 206.24a219.242 219.284 0 0 0 77.3 250.918 219.242 219.284 0 0 0 262.49-3.092 219.242 219.284 0 0 0 71.366-252.67l-204.682 78.583 12.24-218.943a219.242 219.284 0 0 0-18.34-.258z","b":[38.6,13.2,445.0,443.9]},{"n":"podium","d":"M90.52 390.06h38.497v16.583H65.443V390.06l31.933-28.182c2.852-2.578 4.96-5.098 6.328-7.56 1.368-2.46 2.05-5.018 2.05-7.675 0-4.1-1.386-7.402-4.16-9.902-2.733-2.5-6.386-3.75-10.956-3.75-3.516 0-7.363.763-11.543 2.286-4.18 1.485-8.652 3.71-13.418 6.68v-19.22c5.078-1.678 10.098-2.948 15.06-3.807 4.96-.9 9.823-1.35 14.588-1.35 10.47 0 18.594 2.306 24.375 6.915 5.82 4.61 8.73 11.035 8.73 19.277 0 4.766-1.23 9.22-3.69 13.36-2.46 4.1-7.637 9.61-15.528 16.523l-18.69 16.406m349.377 32.915c5.897 1.524 10.37 4.18 13.417 7.97 3.086 3.75 4.63 8.534 4.63 14.355 0 8.672-3.322 15.273-9.962 19.804-6.64 4.493-16.328 6.74-29.063 6.74-4.492 0-9.004-.372-13.535-1.115-4.492-.704-8.945-1.778-13.36-3.223v-17.403c4.22 2.11 8.4 3.71 12.54 4.805 4.18 1.054 8.28 1.58 12.304 1.58 5.978 0 10.548-1.034 13.712-3.104 3.203-2.07 4.805-5.04 4.805-8.907 0-3.985-1.64-6.993-4.922-9.024-3.242-2.07-8.047-3.105-14.414-3.106h-9.022v-14.53h9.492c5.664 0 9.883-.88 12.656-2.638 2.773-1.796 4.16-4.51 4.16-8.144 0-3.36-1.347-5.957-4.043-7.793-2.695-1.836-6.504-2.754-11.426-2.754-3.632 0-7.304.41-11.015 1.232-3.71.82-7.403 2.03-11.074 3.632V384.83c4.453-1.25 8.867-2.186 13.242-2.812 4.375-.624 8.672-.937 12.89-.937 11.368 0 19.864 1.876 25.49 5.626 5.663 3.71 8.495 9.316 8.495 16.816 0 5.118-1.348 9.317-4.043 12.598-2.696 3.242-6.68 5.527-11.953 6.856M236.062 230.74h19.922v-56.544l-20.45 4.22v-15.352l20.333-4.22h21.445v71.895h19.922v15.585h-61.172V230.74M496 496V352H352V128H176v160H16v208z","b":[16.0,128.0,480.0,368.0]},{"n":"podium-second","d":"M90.139 122.533c-11.594 0-23 12.8-23 31s11.406 31 23 31c11.593 0 23-12.8 23-31s-11.407-31-23-31zm103.95 2.975c-19.909 29.9-44.89 49.149-71.333 57.77-7.307 11.535-18.868 19.255-32.617 19.255-13.75 0-25.311-7.72-32.618-19.256-18.893 4.527-28.056 67.85-34.212 102.391l17.382 4.664 13.928-51.893 11.854 154.094h14.666v-103h18v103h14.666L128 208c30.818-17.632 67.095-44.257 82.188-74.441l-16.098-8.051zM169 313v96H25v78h462v-30H343V313H169z","b":[23.3,122.5,463.7,364.5]},{"n":"podium-third","d":"M417.945 168.902c-11.593 0-23 12.8-23 31 0 18.201 11.407 31 23 31 11.594 0 23-12.799 23-31 0-18.2-11.406-31-23-31zm-103.95 2.975l-16.099 8.05c15.093 30.185 51.37 56.81 82.188 74.442l14.195 184.533h14.666v-103h18v103h14.666l11.854-154.093 13.928 51.892 17.382-4.664c-6.156-34.54-15.319-97.864-34.212-102.39-7.307 11.535-18.869 19.255-32.618 19.255-13.749 0-25.31-7.72-32.617-19.256-26.443-8.62-51.424-27.87-71.334-57.769zM169 313v96H25v78h462v-30H343V313H169z","b":[25.0,168.9,462.0,318.1]},{"n":"podium-winner","d":"M256 25c-11.594 0-23 12.8-23 31s11.406 31 23 31 23-12.8 23-31-11.406-31-23-31zm-103.951 2.975l-16.098 8.05c15.092 30.185 51.37 56.81 82.188 74.442L232.334 295H247V192h18v103h14.666l14.195-184.533c30.818-17.632 67.096-44.257 82.188-74.442l-16.098-8.05c-19.91 29.9-44.891 49.148-71.334 57.77C281.311 97.28 269.75 105 256 105c-13.75 0-25.31-7.72-32.617-19.256-26.443-8.62-51.424-27.87-71.334-57.77zM169 313v96H25v78h462v-30H343V313H169z","b":[25.0,25.0,462.0,462.0]},{"n":"processor","d":"M228.844 32.22v114.218h17.687V32.218h-17.686zm-108.25.624c-15.507 0-28.094 12.586-28.094 28.093C92.5 76.444 105.087 89 120.594 89c12.655 0 23.34-8.372 26.844-19.875h44.937v77.313h17.688v-95H147.03c-3.888-10.837-14.262-18.593-26.436-18.593zm193.25 0c-15.507 0-28.063 12.586-28.063 28.093 0 12.124 7.677 22.45 18.44 26.376v59.124h17.655V87.844c11.596-3.452 20.063-14.193 20.063-26.906 0-15.508-12.587-28.094-28.094-28.094zM266.124 92.5v53.938h17.657V92.5h-17.655zm188.532 4.03c-15.507 0-28.094 12.588-28.094 28.095 0 13.083 8.948 24.074 21.063 27.188v27.468h-92.938v17.657h110.624v-46.342c10.223-4.192 17.407-14.233 17.407-25.97 0-15.507-12.557-28.094-28.064-28.094zM30.187 123.657v17.688H96.75v55.594h62.814V179.28h-45.126v-55.624h-84.25zm147.032 40.47v159.718h159.81v-159.72H177.22zm17.56 15.655h17.657v78.595l32.407 32.406h75.28v17.658H237.5l-2.594-2.594-10.75-10.75c-1.033 7.385-7.36 13.062-15.03 13.062-8.392 0-15.19-6.796-15.19-15.187 0-7.682 5.696-13.98 13.095-15l-9.655-9.658-2.594-2.593V179.78zm54.94.157h17.686v55.313h52.53l.002 17.688H249.72v-73zM53.124 217.375V307.344c-11.49 3.512-19.844 14.198-19.844 26.844 0 15.505 12.557 28.093 28.064 28.093s28.093-12.587 28.093-28.092c0-12.195-7.79-22.564-18.656-26.438v-72.72h88.782v-17.655H53.124zm301.563 0v17.656h53.968v-17.655h-53.97zm99.968 21.97c-10.898 0-20.342 6.21-25 15.28h-74.97l.002 17.688H427c2.325 13.168 13.824 23.187 27.656 23.187 15.507 0 28.063-12.588 28.063-28.094 0-15.507-12.557-28.062-28.064-28.062zm-349.062 15.28v17.688h53.97v-17.688h-53.97zm17.156 36.47v84.217c-11.498 3.513-19.875 14.2-19.875 26.844 0 15.506 12.587 28.094 28.094 28.094 15.506 0 28.06-12.588 28.06-28.094 0-12.194-7.766-22.564-18.624-26.437v-66.94h19.156v-17.686H122.75zm231.938 0v17.686h45.156v95.283c-11.323 3.624-19.53 14.26-19.53 26.78-.002 15.506 12.585 28.063 28.092 28.063 15.507 0 28.063-12.557 28.063-28.062 0-12.32-7.935-22.778-18.97-26.563V291.095h-62.814zM192.375 341.53v54.033h17.688V341.53h-17.688zm36.47 0v86.564c-11.013 3.794-18.94 14.233-18.94 26.53 0 15.506 12.588 28.095 28.095 28.095s28.063-12.59 28.063-28.095c0-12.53-8.203-23.14-19.532-26.75V341.53h-17.686zm37.28 0v54.033h17.688l-.032-54.032h-17.655zm38.094 0v140.064h17.655V341.53H304.22z","b":[30.2,32.2,452.5,450.5]},{"n":"progression","d":"M463 20.3L315.6 75.65 368.5 109C274 228 137.3 301.3 21.8 329.2l32.72 59.6C184.3 346.5 321.7 270.2 410.2 135.4l40.3 25.4L463 20.3zm7.7 116.7l-4.8 54.8-51.3-32.4c-1.8 2.7-3.7 5.3-5.6 8V487h78V137h-16.3zM320.1 265c-12.7 11-25.8 21.4-39.1 31.2V487h78V265h-38.9zm-123.7 84c-14.4 7.6-28.8 14.6-43.4 21.2V487h78V349h-34.6zM25 393v94h78v-94h-5.68c-14.82 5.5-29.63 10.6-44.35 15.3l-7.06 2.2-9.6-17.5H25z","b":[21.8,20.3,465.2,466.7]},{"n":"pulse","d":"M256 16c-120 0-135 105-60 195 0-165 135-45 135-135 0-30-45-60-75-60zm146.25 134.532C370.61 152.554 334.75 167.875 301 196c165 0 45 135 135 135 30 0 60-45 60-75 0-75-41.016-108.838-93.75-105.468zM76 181c-30 0-60 45-60 75 0 120 105 135 195 60-165 0-45-135-135-135zm175.782 15A60 60 0 0 0 196 256a60 60 0 0 0 120 0 60 60 0 0 0-64.218-60zM316 301c0 165-135 45-135 135 0 30 45 60 75 60 120 0 135-105 60-195z","b":[16.0,16.0,480.0,480.0]},{"n":"radial-balance","d":"M321.375 15.313L262.72 73.906l25.78 6.906-15.563 58.063c-5.44-.756-10.87-1.14-16.25-1.125-.887.003-1.77.04-2.656.063l21.97 45.75 42.25-28.407c-6.263-3.87-12.944-7.205-20.03-9.875l15.467-57.718 28.657 7.657-20.97-79.907zM133.25 40.063l-.094 82.906 23.125-13.345 30.064 52.063c-5.034 3.824-9.75 8.072-14.125 12.687l50.06 16.438 9.064-50.157c-7.797 1.777-15.372 4.336-22.594 7.625l-29.875-51.718 25.688-14.812-71.313-41.688zm255.28 90.593l13.345 23.094-52.063 30.063c-3.8-5.002-8.01-9.707-12.593-14.063l-16.126 48.156 49.28 8.938c-1.744-7.094-4.148-13.99-7.155-20.594l51.717-29.875 14.813 25.656 41.688-71.31-82.907-.064zm-290.78 38.5l-79.906 20.97 58.562 58.655L83.312 223l58.063 15.563c-.935 6.767-1.25 13.498-1 20.156l47.53-22.814-29.843-43.25c-4.022 6.432-7.466 13.31-10.218 20.625l-57.78-15.468 7.686-28.656zm275.875 81.28L328.5 272.813l28.313 42.125c3.15-5.2 5.937-10.673 8.28-16.437l57.938 15.53-6.905 25.783 80.063-21.532-58.72-58.092-7.687 28.656-57.592-15.438c1.27-7.706 1.707-15.387 1.437-22.97zm-230.28 30.283c1.5 6.44 3.516 12.72 6.06 18.78l-52.093 30.094L83.97 306.5l-41.376 71.813 82.594-.438-14.813-25.656 51.78-29.908c4.655 6.52 9.98 12.557 15.907 18.032l17.282-49.53-52-10.095zM294 316.75l-9.22 51.03c5.91-1.454 11.673-3.347 17.25-5.686l30.095 52.094L309 427.53l71.844 41.408-.438-82.625-25.687 14.843-29.876-51.75c6.437-4.588 12.43-9.847 17.844-15.687L294 316.75zM240.25 324l-44.125 30.03c5.32 3.262 10.955 6.127 16.875 8.533L197.47 420.5l-25.782-6.906 21.53 80.062 58.095-58.72-28.625-7.686 15.437-57.625c8.295 1.367 16.576 1.816 24.72 1.406L240.25 324z","b":[17.8,15.3,478.3,478.3]},{"n":"rank-1","d":"M255 471L91.7 387V41h328.6v346zm-147.3-93.74L255 453l149.3-75.76V57H107.7zm146.56-33.1l-94.66-48.69v50l94.54 48.62 98.27-49.89v-49.9z","b":[91.7,41.0,328.6,430.0]},{"n":"rank-2","d":"M255 471L91.7 387V41h328.6v346zm-147.3-93.74L255 453l149.3-75.76V57H107.7v320.26zm146.43-65.76l98.27-49.89v-49.9l-98.14 49.82-94.66-48.69v50zm.13 32.66l-94.66-48.69v50l94.54 48.62 98.27-49.89v-49.9z","b":[91.7,41.0,328.6,430.0]},{"n":"rank-3","d":"M255 471L91.7 387V41h328.6v346zm-147.3-93.74L255 453l149.3-75.76V57H107.7v320.26zm187.61-168.34l-14.5-46 38.8-28.73-48.27-.43L256 87.94l-15.33 45.78-48.27.43 38.8 28.73-14.5 46 39.31-28zM254.13 311.5l98.27-49.89v-49.9l-98.14 49.82-94.66-48.69v50zm.13 32.66l-94.66-48.69v50l94.54 48.62 98.27-49.89v-49.9z","b":[91.7,41.0,328.6,430.0]},{"n":"ribbon-medal","d":"M256.883 29.7L241.11 51.554l-23-14.06-6.202 26.224-26.63-4.193 4.308 26.604-26.21 6.317 14.165 22.93-21.794 15.86L177.61 147l-14.065 22.992 26.234 6.2-4.194 26.624 26.613-4.308 6.316 26.2 22.937-14.16 15.865 21.788 15.772-21.856 23 14.06 4.283-18.11 1.92-8.116 26.633 4.194-4.31-26.606 26.21-6.314-14.166-22.928 21.797-15.86-21.863-15.767 14.064-22.992-26.234-6.2 4.19-26.624-26.61 4.307-6.318-26.2-22.936 14.16-15.867-21.788zm-.252 51.68a49.657 49.64 0 0 1 49.657 49.64 49.657 49.64 0 0 1-49.656 49.638 49.657 49.64 0 0 1-49.655-49.638 49.657 49.64 0 0 1 49.656-49.64zm59.345 137.308l-8.082 34.164-29.96-18.315-9.747 13.504c11.734 82.04 18.1 163.835 54.654 247l16.553-66.185c10.51 13.815 27.52 26.056 49.656 33.092-31.075-77.557-42.77-158.987-54.714-240.37l-18.36-2.89zm-117.37.253l-19.76 3.2c-11.916 81.194-23.63 162.428-54.632 239.807 22.136-7.036 39.147-19.277 49.658-33.092l16.552 66.186c36.794-83.71 43.005-166.034 54.89-248.614l-8.595-11.8-29.88 18.442-8.232-34.127z","b":[124.2,29.7,264.8,465.3]},{"n":"scales","d":"M254.47 53.094s-4.808 37.12-49.5 49.5c-44.695 12.38-129.282 0-129.282 0L61.343 115.78l8.187 9.157-1.093 2.876-51.843 137.312L16 266.72v1.717c0 18.897 8.253 34.243 20.344 44 12.09 9.758 27.563 14.31 42.937 14.313 15.376.003 30.878-4.556 42.97-14.313 12.092-9.756 20.344-25.094 20.344-44v-1.843l-.688-1.688L86.97 130.28c23.946-3.003 80.866-8.54 115.5 1.532 23.064 6.71 36.151 20.345 43.436 31.97L210.78 354.468l21.407 30.31c-17.75 7.75-32.593 24.84-37.562 51.345-56.076 6.195-95.47 20.74-95.47 37.688h311.876c0-16.947-39.392-31.493-95.467-37.688-4.91-26.6-19.57-44.112-37.188-51.906l21-29.75L264 162.28c7.457-11.275 20.388-24.045 42.47-30.468 34.955-10.167 92.615-4.42 116.155-1.437l-50.875 134.75-.625 1.594v1.717c0 18.897 8.253 34.243 20.344 44 12.09 9.758 27.593 14.31 42.967 14.313 15.375.003 30.877-4.556 42.97-14.313 12.09-9.756 20.343-25.094 20.343-44v-1.843l-.688-1.688L441 127.562l-.938-2.28 8.782-8.438-15.594-14.25s-84.556 12.38-129.25 0-49.53-49.5-49.53-49.5zM77.53 156.656l44.22 108.375H36.594L77.53 156.657zm355.158 0l44.218 108.375H391.72l40.967-108.374z","b":[16.0,53.1,481.7,420.7]},{"n":"server-rack","d":"M41 25v78h430V25H41zm254 23h18v32h-18V48zm121 0a16 16 0 0 1 16 16 16 16 0 0 1-16 16 16 16 0 0 1-16-16 16 16 0 0 1 16-16zM64 55h48v18H64V55zm80 0h48v18h-48V55zm80 0h48v18h-48V55zm-119 66v30h302v-30H105zm-64 48v78h430v-78H41zm254 23h18v32h-18v-32zm121 0a16 16 0 0 1 16 16 16 16 0 0 1-16 16 16 16 0 0 1-16-16 16 16 0 0 1 16-16zm-352 7h48v18H64v-18zm80 0h48v18h-48v-18zm80 0h48v18h-48v-18zm-119 66v30h302v-30H105zm-64 48v78h430v-78H41zm254 23h18v32h-18v-32zm121 0a16 16 0 0 1 16 16 16 16 0 0 1-16 16 16 16 0 0 1-16-16 16 16 0 0 1 16-16zm-352 7h48v18H64v-18zm80 0h48v18h-48v-18zm80 0h48v18h-48v-18zm13 66v30h38v-30h-38zM25 457v30h130.2l20-30H25zm171.8 0l-20 30h158.4l-20-30H196.8zm140 0l20 30H487v-30H336.8z","b":[25.0,25.0,462.0,462.0]},{"n":"speedometer","d":"M256 54.28c-124.603 0-226 101.398-226 226 0 47.864 14.975 92.293 40.465 128.876l29.79-19.86c-17.188-24.545-28.708-53.362-32.696-84.577H96v-18H66.115c-.07-2.14-.115-4.284-.115-6.44 0-45.378 15.816-86.97 42.236-119.598l17.4 17.4 12.727-12.727-18.133-18.132C152.735 114.057 197.335 92.8 247 90.498v29.22h18V90.5c49.665 2.302 94.265 23.56 126.77 56.725l-18.133 18.132 12.726 12.727 17.4-17.4c26.42 32.63 42.237 74.22 42.237 119.6 0 2.154-.044 4.3-.115 6.437H416v18h28.44c-3.987 31.214-15.507 60.03-32.694 84.575l29.79 19.86C467.025 372.574 482 328.146 482 280.282c0-124.602-101.397-226-226-226zm15.83 66.23a144 160 0 0 1 74.608 100.062l49.966-17.568a160 160 0 0 0-4.3-7.012l-5.135 5.153-30.368-30.29-5.76-5.746 7.85-7.874a160 160 0 0 0-86.862-36.726zm156.15 89.844l-175.332 60.6C240.505 272.618 231 283.155 231 295.72c0 13.7 11.3 25 25 25 6.77 0 12.95-2.764 17.473-7.208L427.98 210.354zm-16.513 32.322l-60.713 40.72a144 160 0 0 1-56.6 108.323h76.057a160 160 0 0 0 39.763-68.572H398.48v-52.515h17.022a160 160 0 0 0-4.035-27.957zM128 421.72v36h256v-36H128z","b":[30.0,54.3,452.0,403.4]},{"n":"sport-medal","d":"M338.8 31.81c-5 19.51-9.9 38.69-14.9 57.64-45.3 7.27-90.5 7.28-135.8 0-5-18.95-9.9-38.13-14.9-57.64 54.9 22.58 110.7 22.58 165.6 0zm17.3 4.59l34.4 45.95c-14 96.25-40 204.15-77.5 302.95-10.7-12.4-25.2-21.3-41.8-24.7 28.3-111.3 56.6-212.3 84.9-324.2zm-200.2 0c28.3 111.9 56.6 212.9 84.9 324.2-16.6 3.4-31.1 12.3-41.8 24.7-37.5-98.8-63.5-206.7-77.5-302.95zM256 377c31.6 0 57 25.4 57 57s-25.4 57-57 57-57-25.4-57-57 25.4-57 57-57z","b":[121.5,31.8,269.0,459.2]},{"n":"stack","d":"M256 18.365L50.14 136 256 253.635 461.86 136 256 18.365zm-154 168L50.14 216 256 333.635 461.86 216 410 186.365l-154 88-154-88zm0 80L50.14 296 256 413.635 461.86 296 410 266.365l-154 88-154-88zm0 80L50.14 376 256 493.635 461.86 376 410 346.365l-154 88-154-88z","b":[50.1,18.4,411.7,475.3]},{"n":"stars-stack","d":"M256.65 38.984l-49.697 100.702-111.13 16.146 80.413 78.385-18.982 110.68 99.396-52.256 99.397 52.256-18.983-110.68 80.413-78.384-111.127-16.146-49.7-100.702zM112 308.826l-26.674 54.05-59.646 8.665 43.16 42.073-10.188 59.403L112 444.97l53.348 28.046-10.188-59.403 43.16-42.072-59.646-8.665L112 308.825zm288 0l-26.674 54.05-59.646 8.665 43.16 42.073-10.188 59.403L400 444.97l53.348 28.046-10.188-59.403 43.16-42.072-59.646-8.665L400 308.825z","b":[25.7,39.0,460.6,434.0]},{"n":"static","d":"M142.7 18.72L20 77.56v20.72l120.3-57.72L20 132v112.7l129.4-46.8-63.4-9.3 188-45.8L20 326.5V370l349.6-189.6-81.1 18.3 115.2-71.4 91.6-34.58v-20C432 101.4 368 115.2 301 131.6l44.4-30.2 149.9-72.81v-9.87h-22.5C393.2 63.83 310.6 89.86 224.7 119.7L383.5 18.72H302L112.3 114.1l122.2-95.38zM495.3 143.3L230.6 299.6l150.5-39.1L78.72 418.7l102.38-90.8L20 409v85h32.94S223 392.8 317.3 354.7L247 407l112.6-34.4-216.2 119.5 286-102.1-82 57.6L495.3 406V298.4l-139.9 52.3 72.7-58.5-133.7 47.2 177-115.1-24.9 42.5 48.8-18.5v-105z","b":[20.0,18.7,475.3,475.3]},{"n":"static-waves","d":"M271.688 18.076c30.998 22.56 59.474 47.18 85.85 74.17-55.465-17.182-111.375-24.518-166.444-24.53 131.154 56.898 232.282 146.106 301.353 302.522v-65.394c-43.575-82.686-107.69-155.17-176.906-190.42C388.585 135.42 446.776 179.83 490 223.034 441.175 96.127 375.416 38.693 271.688 18.075zM66.692 20.994C52.09 133.23 55.57 248.46 88.887 360.31c-33.756-40.1-58.85-84.33-71.25-130.236 1.203 129.388 75.925 229.466 194.035 261.7-54.595-68.506-108.85-165.455-111.063-290.587 28.372 118.453 129.845 227.278 256.544 294.03H480.18C248.53 386.68 129.253 227.084 66.693 20.994zm19.805 15.313l156.135 180.22c-32.287-17.453-65.367-34.38-98.07-51.318 85.847 129.425 186.64 243.742 347.11 295.397-64.525-60.37-95.74-102.014-127.757-150.318-48.695-14.554-101.03-37.668-144.51-76.456 44.58 26.788 123.108 42.688 185.977 48.342-79.726-127.645-192.9-186.57-318.885-245.87z","b":[17.6,18.1,474.8,477.1]},{"n":"sundial","d":"M227.02 45.682l-2.01 150.17c-10.8 2.273-21.273 5.438-31.334 9.423l-34.46-54.44 10.48 65.913c-11.186 6.322-21.69 13.712-31.362 22.043l-85.387-73.01 60.914 98.26c-10.724 13.255-19.744 27.943-26.725 43.73l-37.89-9.674 32.146 24.228c-5.19 14.893-8.618 30.607-10.036 46.89l-52.426 1.497 151.115 58.343c-5.937-13.1-9.244-27.634-9.244-42.922 0-57.535 46.842-104.378 104.378-104.378 57.535 0 104.377 46.843 104.377 104.38 0 14.662-3.05 28.628-8.535 41.304-.054.597-.1 1.188-.16 1.79l138.406-59.548-40.56-3.928c-2.213-21.043-7.78-41.097-16.17-59.607l29.804-34.71-41.317 13.08c-9.153-14.872-20.252-28.418-32.937-40.292l58.926-131.802-93.026 106.238c-13.207-7.81-27.41-14.104-42.377-18.64l2.535-65.838-24.547 60.54c-11.17-1.997-22.667-3.04-34.405-3.04-2.4 0-4.785.06-7.164.146L227.02 45.682zm38.173 164.685c9.258 0 18.345.717 27.213 2.09l-19.693 48.572-10.74-50.622c1.072-.02 2.143-.04 3.22-.04zm-40.44 4.664l-.515 38.53-20.392-32.218c6.78-2.518 13.76-4.633 20.908-6.31zm96.112 4.312c10.708 3.56 20.953 8.127 30.63 13.578l-32.585 37.213 1.955-50.79zm-148.03 17.15l5.85 36.803-26.048-22.274c6.366-5.3 13.115-10.156 20.197-14.528zm217.186 25.766c8.48 8.533 16.08 17.934 22.673 28.056l-41.02 12.987 18.348-41.042zm-265.73 18.605l26.808 43.24-45.643-11.654c5.185-11.22 11.508-21.8 18.836-31.587zM265.18 300.44c-47.435 0-85.69 38.256-85.69 85.69 0 47.436 38.255 85.688 85.69 85.688 47.435 0 85.687-38.252 85.687-85.687 0-47.434-38.252-85.69-85.687-85.69zm163.808 21.484c5.21 13.28 8.856 27.35 10.707 41.984l-43.17-4.18 32.463-37.804zM97.11 334.176l43.853 33.054-50.805 1.45c1.177-11.892 3.534-23.433 6.953-34.504z","b":[18.9,45.7,480.3,426.1]},{"n":"trophy","d":"M256.156 21.625c-45.605 0-86.876 2.852-117.22 7.563-15.17 2.355-27.554 5.11-36.874 8.53-4.66 1.71-8.568 3.515-11.968 6.094-3.238 2.457-6.65 6.36-6.97 11.75h-.75c0 10.08.362 20.022 1.064 29.813H57.53c-.12-7.952.003-15.922.376-23.875l-26.812-6.28C22.55 161.892 64.1 265.716 140.564 339.655l15.655-29.594c-4.198-3.477-8.25-7.063-12.157-10.75 5.846-6.112 12.293-11.76 19.28-16.843 13.468 13.172 28.182 23.565 43.813 30.655 22.114 17.744 8.053 29.368-23.5 36.25 58.863 10.6 38.948 62.267-14.125 92.313-2.14.27-4.256.523-6.28.812-12.047 1.718-21.876 3.71-29.406 6.25-3.765 1.27-6.958 2.6-9.906 4.656-2.95 2.055-6.626 5.705-6.626 11.406 0 5.702 3.677 9.32 6.626 11.375 2.948 2.055 6.14 3.387 9.906 4.657 7.53 2.54 17.36 4.532 29.406 6.25 24.094 3.436 56.784 5.53 92.906 5.53 36.123 0 68.812-2.094 92.906-5.53 12.048-1.718 21.877-3.71 29.407-6.25 3.764-1.27 6.957-2.602 9.905-4.656 2.948-2.055 6.625-5.674 6.625-11.375 0-5.702-3.677-9.352-6.625-11.407-2.948-2.055-6.14-3.387-9.906-4.656-7.53-2.54-17.36-4.532-29.408-6.25-2.013-.287-4.12-.544-6.25-.813-53.076-30.045-72.99-81.71-14.125-92.312-31.568-6.886-45.63-18.522-23.468-36.28 15.74-7.15 30.547-17.655 44.092-30.97 6.648 4.773 12.84 10.038 18.47 15.72-4.105 4.172-8.338 8.257-12.72 12.217l16.188 29.594c79.118-71.955 116.195-179.53 110.03-285l-27.342 7.97c.45 7.61.64 15.19.562 22.75h-25.594c.702-9.792 1.063-19.735 1.063-29.814h-.75c-.323-5.39-3.763-9.293-7-11.75-3.402-2.58-7.31-4.383-11.97-6.093-9.32-3.422-21.704-6.177-36.875-8.532-30.342-4.71-71.613-7.563-117.22-7.563zm0 18.688c44.822 0 85.426 2.854 114.344 7.343 14.46 2.245 26.06 4.932 33.313 7.594 1.04.382 1.775.75 2.625 1.125-.85.375-1.58.742-2.625 1.125-7.252 2.662-18.854 5.38-33.313 7.625-28.918 4.49-69.522 7.344-114.344 7.344-44.82 0-85.425-2.855-114.344-7.345-14.46-2.245-26.06-4.963-33.312-7.625-1.05-.386-1.77-.748-2.625-1.125.853-.376 1.577-.74 2.625-1.125 7.252-2.662 18.853-5.35 33.313-7.594 28.918-4.49 69.522-7.343 114.343-7.343zm-197.25 71.874H86.25c8.057 57.878 28.23 108.83 56.188 146.25-6.974 5.74-13.407 11.968-19.188 18.688-38.648-46.456-59.042-104.647-64.344-164.938zm367.188 0h27C447.51 171.82 425.336 228.34 388.03 275c-5.44-6.055-11.406-11.73-17.842-16.97 27.81-37.38 47.873-88.175 55.906-145.842z","b":[22.6,21.6,464.9,471.0]},{"n":"trophy-cup","d":"M98.398 21.146a17.092 17.092 0 0 0-4.636.521c-20.49 5.262-33.163 20.63-36.116 38.649-2.952 18.019 2.168 38.346 12.676 58.193 20.695 39.086 63.262 77.08 117.852 85.85-5.61-6.72-11.05-14.246-16.274-22.375-39.008-12.57-70.021-42.344-85.67-71.899-9.206-17.387-12.846-34.491-10.82-46.857C77.437 50.862 83.482 42.89 98.238 39.1c.065-.017.068-.034.092-.053-.065-.143.105-.08 0 0 .022.049.061.11.176.217.527.493 1.689 2.24 2.207 5.14 1.036 5.804-.413 15.593-8.135 25.68l14.293 10.942c10.418-13.61 13.65-28.086 11.56-39.785-1.044-5.85-3.396-11.165-7.628-15.124-3.174-2.969-7.747-4.868-12.405-4.972zm315.204 0c-4.658.104-9.23 2.003-12.405 4.972-4.232 3.96-6.584 9.274-7.629 15.124-2.089 11.699 1.143 26.174 11.56 39.785l14.294-10.942c-7.722-10.087-9.171-19.876-8.135-25.68.518-2.9 1.68-4.647 2.207-5.14a.695.695 0 0 0 .176-.217c-.105-.08.065-.143 0 0 .024.019.027.036.092.053 14.756 3.79 20.801 11.76 22.828 24.127 2.026 12.366-1.614 29.47-10.82 46.857-15.649 29.555-46.662 59.33-85.67 71.899-5.223 8.129-10.665 15.655-16.274 22.375 54.59-8.77 97.157-46.764 117.852-85.85 10.508-19.847 15.628-40.174 12.676-58.193-2.953-18.02-15.626-33.387-36.116-38.649a17.092 17.092 0 0 0-4.636-.521zm-276.166 7.713c2.146 36.533 16.76 83.07 36.537 120.824 10.707 20.442 22.876 38.334 34.761 50.685C220.62 212.72 232 218.858 240 218.858h32c8 0 19.38-6.138 31.266-18.49 11.885-12.351 24.054-30.243 34.761-50.685 19.777-37.755 34.39-84.29 36.537-120.824H137.436zm95.564 208v16h46v-16h-46zm6.445 34c-2.458 25.967-12.796 57.873-24.437 76h81.984c-11.64-18.127-21.979-50.033-24.437-76h-33.11zm-38.445 94v14h110v-14H201zm-32 32v94h174v-94H169zm23 23h128v48H192v-48z","b":[54.7,21.1,402.6,469.7]},{"n":"upgrade","d":"M256 29.816l-231 154v106.368l231-154 231 154V183.816zm0 128.043L105 259.783v90.283l151-101.925 151 101.925v-90.283zm0 112l-87 58.725v67.6l87-58 87 58v-67.6zm0 89.957l-87 58v64.368l87-58 87 58v-64.368z","b":[25.0,29.8,462.0,452.4]},{"n":"acoustic-megaphone","d":"M443.535 120.186l-112 64 8.93 15.628 112-64-8.93-15.628zM297 153v206h17.973V153H297zm-18 9.367L73 235.072v41.856l206 72.705V162.367zM39 240v32h18v-32H39zm297 7v18h128v-18H336zM99.332 300.89l-14.8 40.215L181.02 379.7l16.11-40.364-16.716-6.672-9.434 23.635-63.51-25.405 8.755-23.786-16.893-6.22zm241.133 11.296l-8.93 15.628 112 64 8.93-15.628-112-64z","b":[39.0,120.2,425.0,271.6]},{"n":"aerial-signal","d":"M138.188 38.875C67.478 79.483 19.624 155.295 19.624 242.688c0 87.858 48.383 163.966 119.72 204.406-47.45-46.694-78.25-120.545-78.25-204.406 0-83.27 30.218-157.06 77.093-203.813zm237.687 2.313c45.574 46.86 74.75 119.59 74.75 201.5 0 82.128-29.53 154.623-75.313 201.468C444 403.043 490.344 328.56 490.344 242.686c0-85.87-46.022-160.33-114.47-201.5zm-179.28 46.718c-61.425 24.617-105.126 84.56-105.126 154.78 0 70.413 43.995 130.262 105.686 154.75-41.348-30.252-69.47-88.174-69.47-154.748 0-66.367 27.774-124.45 68.908-154.782zm142.5 8.78c35.18 31.963 57.81 85.566 57.81 146 0 61.134-23.1 114.77-58.967 146.595 52.006-28.25 87.593-83.246 87.593-146.592 0-62.886-35.052-117.566-86.436-146zm-115.22 44.064c-42.65 14.34-73.125 54.454-73.125 101.938 0 47.91 30.968 88.504 74.22 102.5-27.047-18.556-45.97-57.28-45.97-102.5 0-44.573 18.457-83.072 44.875-101.938zm78.094 3.344c23.836 19.926 39.342 56.72 39.342 98.594 0 42.514-15.99 79.48-40.437 99.187 38.416-16.463 65.375-54.746 65.375-99.188 0-44-26.476-81.867-64.28-98.593zM262 211.344c-20.3 0-36.75 16.45-36.75 36.75 0 15.484 9.573 28.743 23.125 34.156v213.125h27.25V282.25c13.558-5.41 23.125-18.668 23.125-34.156 0-20.3-16.45-36.75-36.75-36.75z","b":[19.6,38.9,470.7,456.5]},{"n":"beam-satellite","d":"M24.998 24.998v14.004h30.004V24.998H24.998zm48 0v14.004h46.004V24.998H72.998zm64 0v14.004h37.184l-4.668-14.004h-32.516zm205.488 0l-4.668 14.004h37.184V24.998h-32.516zm50.512 0v14.004h46.004V24.998h-46.004zm64 0v14.004h30.004V24.998h-30.004zm-432 32v30.004h30.004V56.998H24.998zm48 0v30.004h46.004V56.998H72.998zm64 0v30.004H215.002V72.998h-29.488l-5.334-16h-43.182zm96 0v59.326l-34.15 27.32c16.813-5.416 35.96-8.642 57.152-8.642s40.34 3.226 57.152 8.643l-34.15-27.32V56.997h-46.004zm98.822 0l-5.334 16h-29.488v14.004h78.004V56.998H331.82zm61.178 0v30.004h46.004V56.998h-46.004zm64 0v30.004h30.004V56.998h-30.004zm-432 48v14.004h30.004v-14.004H24.998zm48 0v14.004h46.004v-14.004H72.998zm64 0v14.004h17.44l7.001-14.004H137zm213.563 0l7.002 14.004h17.439v-14.004h-24.441zm42.437 0v14.004h46.004v-14.004h-46.004zm64 0v14.004h30.004v-14.004h-30.004zm-200.998 48c-38.2 0-68.333 11.462-88.707 26.28-18.004 13.093-27.816 28.97-29.861 40.427 6.887 4.562 21.771 10.067 41.109 13.43 14.42 2.508 31.078 4.214 48.502 5.115l-4.143-30.379c-10.514 1.898-19.878 4.68-26.875 8.178l-8.05-16.098c18.146-9.073 43.025-12.95 68.025-12.95 25 0 49.879 3.877 68.025 12.95l-8.05 16.098c-6.997-3.499-16.36-6.28-26.875-8.178l-4.143 30.379c17.424-.901 34.082-2.607 48.502-5.115 19.338-3.363 34.222-8.868 41.11-13.43-2.046-11.457-11.858-27.334-29.862-40.428C324.333 164.46 294.2 152.998 256 152.998zm0 52c-4.197 0-8.935 1.891-14.436 6.543L256 317.398l14.436-105.857c-5.501-4.652-10.24-6.543-14.436-6.543zM384 256l-106.389 36.121-4.35 31.893c3.926 1.454 7.553 3.406 10.766 5.816 7.549 5.661 12.971 14.3 12.971 24.17 0 9.87-5.422 18.509-12.97 24.17-7.55 5.661-17.368 8.828-28.028 8.828s-20.479-3.167-28.027-8.828c-7.549-5.661-12.971-14.3-12.971-24.17 0-9.87 5.422-18.509 12.97-24.17 3.214-2.41 6.841-4.362 10.766-5.816l-2.931-21.493-119.922-29.314 72.34 48.461-104.512 69.666 85.803-12.066-31.455 29.435s26.97-10.097 49.152-18.29l-43.22 86.41L224 416v78.002h9.805L242.283 432l9.862 45.33 8.88-69.373 17.073 86.045H288V416l96 48-45.477-67.885 92.71-18.26-87.262-30.023 26.695-21.9-53.23 3.214L384 256zm-128 82.998c-7.013 0-13.195 2.206-17.229 5.23-4.033 3.025-5.773 6.387-5.773 9.772 0 3.385 1.74 6.747 5.773 9.771 4.034 3.025 10.216 5.231 17.229 5.231s13.195-2.206 17.229-5.23c4.033-3.025 5.773-6.387 5.773-9.772 0-3.385-1.74-6.747-5.773-9.771-4.034-3.025-10.216-5.231-17.229-5.231z","b":[25.0,25.0,462.0,469.0]},{"n":"control-tower","d":"M352 21v18h39v16h18V39h39V21h-96zm35 52l-40 30h106l-40-30h-26zM69.48 120.5l-8.96 15.6 110.98 63.7 35.6 20.4 33.6-58.7-77 13.1-94.22-54.1zM329 121v30h30v-30h-30zm48 0v30h46v-30h-46zm64 0v30h30v-30h-30zm-103 48l34.5 46h55l34.5-46H338zm39 64v30h46v-30h-46zm0 48v206h46V281h-46zM68.52 329L34.3 375H359v-46H68.52zM25 393v94h30v-64h66v64h238v-94H25zm416 .5V487h46v-65.9l-46-27.6zM160 439h48v18h-48v-18zm96 0h48v18h-48v-18zm-183 2v46h30v-46H73z","b":[25.0,21.0,462.0,466.0]},{"n":"defense-satellite","d":"M256 26.816l-39 26v23.455L243.729 103h24.542L295 76.271V52.816l-39-26zM119.027 41l-11.5 46H151V41h-31.973zM361 41v46h43.473l-11.5-46H361zM169 55v18h30V55h-30zm144 0v18h30V55h-30zm-86.734 55.994c-.06.03-.123.057-.182.086-7.048 3.524-9.084 7.157-9.084 8.92s2.036 5.396 9.084 8.92S243.961 135 256 135c12.039 0 22.868-2.556 29.916-6.08 7.048-3.524 9.084-7.157 9.084-8.92s-2.036-5.396-9.084-8.92c-.059-.03-.123-.057-.182-.086L275.73 121H236.27l-10.005-10.006zM199 143.977c-61.739 6.488-118.528 23.478-154.256 49.627 7.202 8.662 15.23 16.686 23.967 24.052 15.382-8.683 32.294-16.008 50.289-21.996V192c0-6.438 2.95-12.44 7.168-16.457 4.218-4.018 9.452-6.435 15.021-7.914 5.57-1.48 11.577-2.058 17.666-1.74a64.318 64.318 0 0 1 18.166 3.632l.12.043 21.859 8.49v-34.077zm114 0v34.078l21.86-8.49.119-.044a64.318 64.318 0 0 1 18.166-3.632c6.09-.318 12.096.26 17.666 1.74s10.803 3.896 15.021 7.914S393 185.563 393 192v3.66c17.995 5.988 34.907 13.313 50.29 21.996 8.737-7.366 16.764-15.39 23.966-24.052-35.728-26.15-92.517-43.139-154.256-49.627zm-96 .5v80.908c13.604 10.234 26.464 15.115 39 15.115 12.536 0 25.396-4.881 39-15.115v-80.908c-.344.18-.685.369-1.033.543C283.643 150.182 270.47 153 256 153c-14.47 0-27.643-2.818-37.967-7.98-.348-.174-.689-.362-1.033-.543zm-62.371 39.437c-3.215.05-6.246.428-8.818 1.111-2.588.688-4.44 1.661-5.85 2.623L199 215.2v-17.834l-28.037-10.89c-4.094-1.457-8.664-2.277-13.068-2.502a48.853 48.853 0 0 0-3.266-.059zm202.742 0a48.853 48.853 0 0 0-3.266.059c-4.404.225-8.974 1.045-13.068 2.502L313 197.365V215.2l59.04-27.55c-1.41-.963-3.263-1.936-5.85-2.624-2.573-.683-5.604-1.06-8.819-1.11zM41 216.217v42.86C79.07 314.612 167.082 344.5 256 344.5s176.93-29.887 215-85.424v-42.86C418.828 270.5 337.25 297 256 297S93.172 270.499 41 216.217zm164.191 23.023l-57.197 22.217c13.515 4.655 27.557 8.377 41.916 11.186l40.64-18.965c-8.619-3.254-17.095-8.104-25.359-14.438zm101.618 0c-8.264 6.334-16.74 11.184-25.36 14.438l40.64 18.965c14.36-2.81 28.402-6.531 41.917-11.186l-57.197-22.217zM256 261.666l-33.646 15.701A349.784 349.784 0 0 0 256 279c11.255 0 22.498-.555 33.646-1.633L256 261.666zm-39 99.047v52.746c6.479 10.81 22.181 17.541 39 17.541s32.521-6.732 39-17.541v-52.746a428.936 428.936 0 0 1-39 1.787c-13.033 0-26.077-.606-39-1.787zm16 85.06V464c0 20 46 20 46 0v-18.227c-7.402 2.19-15.267 3.227-23 3.227-7.733 0-15.598-1.036-23-3.227z","b":[41.0,26.8,430.0,457.2]},{"n":"lightning-frequency","d":"M33.125 19.406L135.5 128.22l81-23.157 18.72-5.344-7.564 17.936-46.125 109.78 134.282-70 26.157-13.655L328.436 170 256.5 309.25l91.25-57.125 22.97-14.375-9.22 25.47-34.625 95.624 71-36.375 21.188-10.845L410.906 334l-33.937 93.063 45.124-6.688 4.53-.656 3.313 3.155 64.313 61.47-30.5-80.5 23.313-46.908-72.5 39.532 51.062-141.158-91.188 47.47 72.344-142.813-128.217 82.81L421.875 70.063 239.03 168.69l30.44-99.563-103.845 25.25-132.5-74.97zM18.155 30.78l77.876 108.25-31.124 75.532 94.125-46.78-98.905 166.812 190.25-99.656-101.03 185.406 140.25-79.063-46.94 102.22 106.5-53-45.655 92.28 86.5-14.467 93.47 31.562-63.158-60.344-56.125 8.314-15.53 2.312 5.374-14.75 31.158-85.437-70.907 36.31-21.124 10.814 8.094-22.313 33.47-92.436-97.22 60.875-28.938 18.092L224.22 331l74.06-143.344-131.06 68.313-22.97 12 10.03-23.908 48.626-115.687-67.75 19.375-5.5 1.563-3.875-4.157L18.157 30.78z","b":[18.2,19.4,476.1,480.5]},{"n":"megaphone","d":"M383.46 123.668l-4.66 17.387C430.868 155.005 467 202.095 467 256c0 53.904-36.133 100.994-88.2 114.945l4.66 17.387C443.31 372.295 485 317.962 485 256c0-61.963-41.69-116.295-101.54-132.332zM307 147.102c-38.21 31.665-62.18 50.07-92.316 59.488-30.27 9.46-65.937 10.324-129.684 10.4v78.02c63.747.076 99.415.94 129.684 10.4 30.136 9.418 54.107 27.823 92.316 59.488V147.102zm64.035 22.93l-4.658 17.388C397.46 195.748 419 223.822 419 256s-21.54 60.252-52.623 68.58l4.658 17.387C409.902 331.552 437 296.237 437 256c0-40.238-27.098-75.552-65.965-85.967zm-12.424 46.364l-4.657 17.387C364.05 236.49 371 245.547 371 256s-6.95 19.51-17.047 22.217l4.658 17.387c17.885-4.792 30.392-21.09 30.392-39.604 0-18.513-12.507-34.812-30.39-39.604zM67 216.998L60 217c-1.75 0-2.906.44-4.574 1.898-1.668 1.46-3.578 4.104-5.2 7.756C46.977 233.96 45 245 45 256s1.978 22.04 5.225 29.346c1.623 3.652 3.533 6.296 5.2 7.756C57.096 294.562 58.25 295 60 295l7 .002v-78.004zm258 17.316v43.372c3.018-.413 5.432-.966 6.975-1.737 2.39-1.196 3.554-2.3 4.8-5.104C338.022 268.04 339 263.25 339 256s-.978-12.04-2.225-14.846c-1.246-2.804-2.41-3.908-4.8-5.103-1.543-.77-3.957-1.323-6.975-1.736zM87.533 313.027L115.027 423h62.252c-3.437-10.215-11.674-22.83-20.997-38.37-11.1-18.5-22.693-41.56-24.824-71.13-12.897-.304-27.38-.428-43.927-.473z","b":[45.0,123.7,440.0,299.3]},{"n":"microphone","d":"M388.938 29.47c-23.008 0-46.153 9.4-62.688 25.405 5.74 46.14 21.326 75.594 43.75 94.28 22.25 18.543 52.078 26.88 87.75 28.345 13.432-16.07 21.188-37.085 21.188-58 0-23.467-9.75-47.063-26.344-63.656C436 39.25 412.404 29.47 388.938 29.47zm-76.282 42.374c-8.808 14.244-13.75 30.986-13.75 47.656 0 23.467 9.782 47.063 26.375 63.656 16.595 16.594 40.19 26.375 63.658 26.375 18.678 0 37.44-6.196 52.687-17.093-31.55-3.2-59.626-12.46-81.875-31-23.277-19.397-39.553-48.64-47.094-89.593zm-27.78 67.72l-64.47 83.78c2.898 19.6 10.458 35.1 22.094 46.187 11.692 11.142 27.714 18.118 48.594 19.626l79.312-65.28c-21.2-3.826-41.14-14.11-56.437-29.407-14.927-14.927-25.057-34.286-29.095-54.907zM300 201.468a8 8 0 0 1 .03 0 8 8 0 0 1 .533 0 8 8 0 0 1 5.875 13.374l-34.313 38.78a8.004 8.004 0 1 1-12-10.593l34.313-38.78a8 8 0 0 1 5.562-2.78zM207.594 240L103 375.906c3.487 13.327 7.326 20.944 12.5 26.03 5.03 4.948 12.386 8.46 23.563 12.408l135.312-111.438c-17.067-3.61-31.595-11.003-42.906-21.78-11.346-10.81-19.323-24.827-23.876-41.126zM95.97 402.375c-9.12 5.382-17.37 14.08-23.126 24.406-9.656 17.317-11.52 37.236-2.25 50.47 6.665 4.337 10.566 4.81 13.844 4.344 1.794-.256 3.618-.954 5.624-1.875-3.18-9.575-6.3-20.93-2.5-33.314 3.03-9.87 10.323-19.044 23.47-27.5-2.406-1.65-4.644-3.49-6.75-5.562-3.217-3.163-5.94-6.78-8.313-10.97z","b":[61.3,29.5,417.6,452.6]},{"n":"old-microphone","d":"M256 27.998c-33.784 0-67.564 12.67-80.97 38.004H240v17.996h-70.574c-.563 4.866-.428 8.98-.428 14.004H240v17.996h-71.002v14.004H240v17.996h-71.002v14.004h174.004v-14.004H272v-17.996h71.002v-14.004H272V98.002h71.002c.022-4.63.077-9.796-.428-14.004H272V66.002h64.97C323.565 40.668 289.785 27.998 256 27.998zM80 162.002v17.996h22.678c-.148 4.753-.266 9.44-.326 14.004h18.002c.06-4.551.18-9.241.332-14.004h30.316v-17.996zm280.998 0v17.996h29.94a860.86 860.86 0 0 1-.254 14.004h18.013c.12-4.563.192-9.25.24-14.004H432v-17.996zm-192 17.996v18.004h174.004v-18.004zm-66.654 32c1.175 86.626 19.908 134.76 47.8 161.498 24.806 23.779 55.434 29.003 82.854 30.158v46.348h46.004v-46.377c26.698-1.218 55.672-6.572 79.361-30.262 26.772-26.771 45.324-74.691 49.658-161.365h-18.046c-4.382 83.532-22.405 126.705-44.338 148.639C320.364 385.91 288 386.002 256 386.002s-67.037-.226-93.4-25.498c-22.91-21.962-41.029-64.919-42.245-148.506zm66.654 4V283c0 39.1 37.7 59.99 78.004 62.691V215.998zm96 0v129.693c40.303-2.7 78.004-23.591 78.004-62.691v-67.002zm-144 252v16.004h270.004v-16.004z","b":[80.0,28.0,352.0,456.0]},{"n":"pocket-radio","d":"M413.803 21.857l-37.354 14.008c2.38 6.19 4.488 11.654 6.453 16.8l37.221-13.956zm-54.207 20.328L90.283 143.177c.06.043.125.082.186.125 5.271 3.757 9.669 8.676 12.42 14.37L366.05 58.986c-1.967-5.15-4.087-10.64-6.455-16.8zM56.963 151.283c-9.313 0-17.586 2.775-23.063 6.678-3.208 2.286-5.373 4.765-6.623 7.322h59.371c-1.25-2.557-3.415-5.036-6.623-7.322-5.476-3.903-13.75-6.678-23.062-6.678zm-31 32v238h414v-238zm449.777 7.494l-17.8 2.654c6.305 42.28 11.67 96.59 9.667 145.75-1.72 42.205-9.466 80.212-24.55 103.393-79.995-6.833-142.276-6.026-185.596-1.707-22.159 2.209-39.357 5.295-51.805 8.885-6.224 1.795-11.252 3.683-15.373 5.935-4.121 2.252-7.992 4.583-9.896 10.223-.952 2.82-.745 6.52.552 9.234 1.298 2.715 3.21 4.472 5.116 5.807 3.81 2.669 8.092 4.072 13.54 5.34 10.899 2.536 26.491 3.884 47.727 3.851 42.472-.065 107.155-5.924 195.776-22.123l2.814-.515 2.002-2.047c26.665-27.278 35.6-74.55 37.678-125.543 2.078-50.994-3.436-106.116-9.852-149.137zm-227.777 6.506h178v98h-178zm-128 9h18v87h14v-55h18v55h14v-23h18v64h-18v-23h-14v55h-18v-55h-14v87h-18v-87h-14v55h-18v-55h-14v23h-18v-64h18v23h14v-55h18v55h14zm225.347 2.69c-28.252.014-67.387 1.462-75.2 9.08-12.679 12.358-10.21 64.468-10.21 64.468 10.136-65.752 67.341-69.735 115.397-73.049 0 0-13.035-.508-29.987-.5zm23.653 103.31l14.5 29h33.5v18h-160v-18h97.5zm-30.49 143.242c18.133.095 38.088.744 59.441 1.918-66.439 10.584-116.636 14.65-150.62 14.701-19.627.03-33.862-1.322-42.458-3.174 1.737-.634 3.575-1.281 5.808-1.925 10.81-3.118 27.19-6.133 48.602-8.268 21.411-2.135 47.886-3.415 79.227-3.252z","b":[26.0,21.9,461.7,468.3]},{"n":"public-speaker","d":"M256 33c-20.835 0-39 20.24-39 47s18.165 47 39 47 39-20.24 39-47-18.165-47-39-47zM110.258 54.934l-16.99 8.496c14.917 22.147 32.213 47.013 49.76 68.947 19.707 24.634 39.95 45.048 52.997 51.572l4.975 2.488v39.478c27.13 3.608 46.516 4.982 67.875 4.09-.66-.49-1.316-.98-1.95-1.48-4.915-3.88-9.18-8.206-12.5-12.856-5.87-.587-10.577-4.374-13.392-8.65-3.063-4.65-4.57-10.242-4.57-16.262s1.507-11.612 4.57-16.264c3.064-4.65 8.364-8.736 14.967-8.736s11.903 4.085 14.967 8.736c3.063 4.652 4.57 10.244 4.57 16.264s-1.507 11.612-4.57 16.263c-.06.094-.13.185-.192.277 1.92 2.358 4.335 4.758 7.303 7.1 6.283 4.962 14.722 9.46 24.75 12.66 2.65-.324 5.366-.67 8.172-1.04v-39.58l4.975-2.488c13.048-6.525 33.29-26.94 52.998-51.573 17.546-21.934 34.842-46.8 49.76-68.947l-16.99-8.496C355.066 101.422 307.792 145 256 145c-51.792 0-99.067-43.578-145.742-90.066zm29.094 179.93l12.152 60.763c101.057 9.362 107.935 9.362 208.992 0l12.147-60.734c-110.08 17.448-123.22 17.163-233.29-.03zm39.244 81.335l13.35 106.8h128.11l13.348-106.8c-67.76 6.032-87.047 6.032-154.808 0zM137 441v20h238v-20H137zM16 478v18h480v-18H16z","b":[16.0,33.0,480.0,463.0]},{"n":"radar-cross-section","d":"M256 23C127.4 23 23 127.4 23 256s104.4 233 233 233 233-104.4 233-233S384.6 23 256 23zm-9 18.2v78.1c-31.1 2-59.2 14.4-81.3 33.7l-55.2-55.29C146.7 64.39 194.4 43.36 247 41.2zm18 0c52.6 2.16 100.3 23.19 136.5 56.51L346.2 153c-22-19.3-50.2-31.7-81.2-33.7V41.2zM97.71 110.5L153 165.7c-19.3 22.1-31.7 50.2-33.7 81.3H41.2c2.16-52.6 23.19-100.3 56.51-136.5zm316.59 0c33.3 36.2 54.3 83.9 56.5 136.5h-78.1c-2-31-14.4-59.2-33.7-81.2l55.3-55.3zM247 137.3v38.6l.4.6 17.6-10v-29.2c26.1 2 49.8 12.3 68.5 28.4L322 177.2l11.2 14.4 13.1-13.1c16.1 18.7 26.4 42.4 28.4 68.5h-41.6l23.8 18h17.8c-.3 4.1-.9 8.2-1.6 12.2l15.8 12c2-7.8 3.3-15.9 3.8-24.2h78.1c-2.2 52.6-23.2 100.3-56.5 136.5l-33.7-33.7-11.4 14.2 32.3 32.3c-36.2 33.3-83.9 54.3-136.5 56.5v-78.1c10.3-.7 20.3-2.5 29.8-5.3l-8.6-16.3c-6.8 1.8-13.9 3-21.2 3.6v-43.5l-.6-1.1-17.4-2.2v46.8c-17.1-1.3-33.2-6.2-47.5-14l-12.2 13.8c17.7 10.3 38 16.8 59.7 18.2v78.1c-52.6-2.2-100.3-23.2-136.5-56.5l52.1-52.1-11.3-14.3-53.59 53.6C64.39 365.3 43.36 317.6 41.2 265h74.2l36.8-18h-14.9c2-26.1 12.3-49.8 28.4-68.5l10.8 10.8 13.1-12.5-11.1-11.1c18.7-16.1 42.4-26.4 68.5-28.4zm47 33.4l-45.1 25.6-7.3 4.2-19.4-29.7-32.6 31 12.8 40.7-80.7 39.5 58.5 73.3 43.2-48.5 52.6 6.5 49.7 93.7 71.9-88.6-94.4-71.4 29.4-27.2-38.6-49.1z","b":[23.0,23.0,466.0,466.0]},{"n":"radar-dish","d":"M227.47 31.47c-67.048 70.547-83.972 178.936-32.907 267.467 51.07 88.544 153.333 128.083 247.906 105.22l-215-372.688zm232.81 82.155c-5.05.133-10.127 1.48-14.81 4.188-11.303 6.53-17.02 19.035-15.44 31.218l-96.31 29.25 34.842 60.345L442 169.812c9.755 7.504 23.456 8.826 34.78 2.282 14.992-8.663 20.117-27.822 11.47-42.813-5.945-10.305-16.856-15.948-27.97-15.655zm-311.874 107.5l-26.656 4.688 10.688 60.53-42.063 39.376 18.688 32.124 58.656-17.813 3.155 4.158L53.53 493.094h78.345l85.344-21.53 52.686 21.53h50.563l-7.064-45.78.813-.22-.97-.625-4.75-30.72c-6.82-2.366-13.532-5.066-20.125-8.03l3.844 24.967-51-33.437 18.75-6.594c-6.528-4.05-12.883-8.437-19.033-13.125l-19.375 6.814-39.625-26 5.813-7.375 15.156-9.658c-9.043-10.742-17.264-22.432-24.53-35.03-16-27.74-25.828-57.3-29.97-87.157zm21.906 153.97l29.094 19.06-61.062 21.5 31.97-40.56zm48.72 31.967l49.343 32.344-49.78 12.563-58.845-24.033 59.28-20.875zm-94.813 26.532l5.718 2.312 58.125 23.75L82.75 486.22l41.47-52.626zm170.968 18.312l5.187 33.438-52.625-21.47 45.813-11.562 1.625-.406z","b":[53.5,31.5,443.4,461.6]},{"n":"radar-sweep","d":"M252.78 20.875c-1.302.012-2.6.03-3.905.063-37.928.974-76.148 11.153-111.28 31.437C25.164 117.285-13.41 261.322 51.5 373.75s208.946 151.036 321.375 86.125c77.7-44.86 120.1-127.513 117.47-211.406-3.563 65.847-35.898 128.573-91 169.374-10.828 9.62-22.774 18.315-35.814 25.844-103.68 59.86-235.983 24.4-295.842-79.282-59.86-103.68-24.43-235.984 79.25-295.844 35.64-20.576 74.67-29.88 112.968-29.03 63.304 1.4 124.623 30.57 165.438 82.53l-32.594 23.032c-33.27-42.835-84.01-66.6-136.063-67-.96-.008-1.91-.012-2.875 0-.964.01-1.943.038-2.906.062-28.006.717-56.222 8.215-82.156 23.188-82.99 47.914-111.508 154.322-63.594 237.312 47.914 82.99 154.32 111.51 237.313 63.594 51.37-29.66 81.862-81.724 86.28-136.78-12.53 45.37-42.32 86.745-85.438 114.186-.02.013-.043.018-.062.03l-.344.22c-3.16 2.147-6.42 4.216-9.78 6.156-74.245 42.865-168.918 17.494-211.782-56.75-42.864-74.243-17.493-168.917 56.75-211.78 23.2-13.396 48.39-20.122 73.375-20.782 47.953-1.266 95.138 19.858 125.968 59.156l-39.844 28.156c-20.232-24.32-50.055-37.79-80.594-38.03-1.17-.01-2.33 0-3.5.03-17.035.432-34.176 4.995-49.938 14.094-50.435 29.12-67.806 93.877-38.687 144.313 29.12 50.434 93.908 67.806 144.344 38.686 21.245-12.267 36.623-30.85 45.124-52.03-18.815 21.064-44.364 36.888-73.938 44.155-.04.013-.084.02-.125.033-37.507 10.787-78.796-4.816-99.217-40.188-24.07-41.688-9.845-94.712 31.843-118.78 13.028-7.523 27.143-11.314 41.156-11.69 25.66-.685 50.898 10.098 68.188 30.25l-41 28.97c-5.497-4.796-12.664-7.72-20.53-7.72-17.277 0-31.283 14.007-31.283 31.282 0 17.276 14.004 31.282 31.282 31.282 17.277 0 31.28-14.007 31.28-31.283 0-1.187-.06-2.347-.188-3.5l120.094-57.312 4.03-1.75-.06-.156 62.25-29.72 9.25-4.438-5.282-8.812-19.97-33.375-5.155-8.625-8.25 5.813-8.095 5.718c-45.9-58.864-116.14-91.053-187.844-90.405z","b":[-13.4,20.2,506.4,504.6]},{"n":"radio-tower","d":"M60.307 17.998A201.117 201.117 0 0 0 55.002 64c0 78.375 45.002 146.35 110.539 179.486-8.783-10.556-16.478-22.658-23.1-35.912-42.318-33.5-69.443-85.327-69.443-143.574 0-15.895 2.035-31.305 5.832-46.002H60.307zm66.644 0c-5.142 14.384-7.949 29.87-7.949 46.002 0 51.245 28.27 95.989 70.031 119.482-6.264-10.227-11.17-21.604-15.023-33.158C151.2 128.657 136.998 98.02 136.998 64c0-16.319 3.275-31.856 9.193-46.002h-19.24zm72.445 0C189.156 30.565 183.002 46.585 183.002 64c0 26.543 14.293 49.845 35.572 62.623-3.806-9.484-6.58-20.417-8.332-32.014-5.84-8.738-9.244-19.259-9.244-30.609 0-11.35 3.403-21.87 9.244-30.61a168.14 168.14 0 0 1 3.053-15.392h-13.899zm99.31 0a168.14 168.14 0 0 1 3.052 15.393c5.84 8.738 9.244 19.259 9.244 30.609 0 11.35-3.403 21.87-9.244 30.61-1.751 11.596-4.526 22.529-8.332 32.013 21.279-12.778 35.572-36.08 35.572-62.623 0-17.415-6.153-33.435-16.394-46.002h-13.899zm67.103 0c5.918 14.146 9.193 29.683 9.193 46.002 0 34.02-14.202 64.657-37.012 86.324-3.852 11.554-8.76 22.93-15.023 33.158C364.728 159.99 392.998 115.245 392.998 64c0-16.132-2.807-31.618-7.95-46.002h-19.24zm67.36 0A183.653 183.653 0 0 1 439.003 64c0 58.247-27.125 110.074-69.443 143.574-6.622 13.254-14.317 25.356-23.1 35.912C411.996 210.35 456.998 142.375 456.998 64c0-15.825-1.837-31.226-5.305-46.002H433.17zM256 40.998c-12.81 0-23.002 10.192-23.002 23.002 0 12.81 10.192 23.002 23.002 23.002 12.81 0 23.002-10.192 23.002-23.002 0-12.81-10.192-23.002-23.002-23.002zm-20.35 58.537L119.398 477.354l17.204 5.292 13.15-42.74L256 415.39l106.248 24.517 13.15 42.74 17.204-5.292L276.35 99.535a40.612 40.612 0 0 1-17.192 5.328l49.654 161.381L256 283.848l-52.813-17.604 49.655-161.38a40.612 40.612 0 0 1-17.192-5.329zM197.893 283.45l29.65 9.885-36.428 12.143 6.778-22.028zm116.214 0l6.778 22.028-36.428-12.143 29.65-9.885zM256 302.82l52.652 17.55L256 339.516l-52.65-19.147L256 302.82zm-73.074 29.275l46.74 16.998-58.518 21.28 11.778-38.278zm146.148 0l11.778 38.277-58.52-21.28 46.742-16.997zM256 358.666l64.354 23.402L256 396.92l-64.355-14.852L256 358.666zm-92.16 35.455l52.144 12.033-60.115 13.873 7.97-25.906zm184.318 0l7.973 25.904-60.113-13.87 52.14-12.034z","b":[55.0,18.0,402.0,464.6]},{"n":"rss","d":"M27.906 27.28v91.44a365.765 365.765 0 0 1 365.75 365.78h91.438A457.207 457.207 0 0 0 27.906 27.28zm0 154.157v88.813a214.234 214.234 0 0 1 214.22 214.25h88.843A303.063 303.063 0 0 0 27.905 181.437zM88.75 359.125a62.703 62.703 0 0 0-60.844 62.656 62.703 62.703 0 0 0 125.375 0 62.703 62.703 0 0 0-64.53-62.655z","b":[27.9,27.3,457.2,457.2]},{"n":"satellite","d":"M314.125 45.125l-36.28 10.97 26.717 38.874L340.844 84l-26.72-38.875zM260.47 61.313l-43 13 26.686 38.874 41.625-12.562-26.467-38.5 1.156-.813zm91.467 38.874l-36.28 10.938 27.374 39.813L379.314 140l-27.375-39.813zM120.47 107.78l-36.282 10.94 26.718 38.905 36.28-10.97-26.717-38.874zm176.405 9.032l-41.594 12.563 12.814 18.656c13.59 1.764 26.138 6.878 36.844 14.44l19.312-5.845-27.375-39.813zm-230.03 7.157l-43 12.968 26.718 38.906 41.562-12.563-26.47-38.5 1.19-.81zm323.56 32.155l-36.28 10.97 25.97 37.81 36.28-10.936-25.97-37.845zm-232.092 6.72L122 173.78l27.375 39.814 36.28-10.938-27.343-39.812zm99.125 3.186c-22.736 0-42.626 11.753-53.97 29.532l66.782 97.188c6.682-1.346 12.98-3.725 18.72-6.97l7.874 11.69 15.78-10.033-8.874-13.187c10.95-11.475 17.656-27.028 17.656-44.22 0-35.446-28.52-64-63.97-64zm77.906 6.75l-14.438 4.345c9.396 11.262 15.84 25.07 18.188 40.188l22.22-6.72-25.97-37.812zm-232.125 6.69L61.655 192l27.313 39.813 41.593-12.563-27.344-39.78zm324.28 30.655l-36.28 10.97 27.342 39.81 36.313-10.967-27.375-39.813zm-230.72 8.688l-36.31 10.968 25.968 37.782 36.312-10.968-25.97-37.78zm175.657 7.937l-32.625 9.875c-.35 4.407-1.012 8.72-2.03 12.906l20.312 29.595 41.687-12.563-27.342-39.812zm-230.75 8.688L100.094 248l25.97 37.813 41.592-12.594-25.97-37.783zm324.282 30.656l-36.314 10.97 26 37.81 36.313-10.937-26-37.843zm-232.095 6.687l-36.313 10.97 27.344 39.78 36.313-10.967-27.345-39.782zm177.03 9.94L369.22 295.31l25.967 37.813 41.688-12.563-25.97-37.843zm-232.124 6.686l-41.624 12.563 27.313 39.81 41.655-12.592-27.344-39.782zm152.314 8.47L301.78 316.5l37.314 58.656 29.312-18.625-37.312-58.655zm-58.75 30.874l-36.313 10.97 26 37.81 36.314-10.936-26-37.844zm-55.094 16.625l-41.656 12.594 25.97 37.81 41.655-12.56-25.97-37.845zm178.313 20.875c-36.29.507-64.44 29.054-70.375 64.844L368.5 404l9.72 14.406c-1.222 2.47-1.908 5.245-1.908 8.188 0 10.222 8.278 18.53 18.5 18.53 10.223 0 18.5-8.308 18.5-18.53 0-10.223-8.277-18.5-18.5-18.5-.335 0-.67.045-1 .062l-9.437-14.062 37.438-23.438c-9.068-3.125-17.876-4.523-26.25-4.406z","b":[23.8,45.1,468.1,400.0]},{"n":"satellite-communication","d":"M189.1 18l14.5 14.47 14.1-14.11-.4-.36zm54.3 0l-.3.31 21.3 21.26 17-16.99-4.6-4.58zm-73.8 6.01l-11.7 11.67 14.2 28.28 18.7-18.72zm60.8 7.06l-14.1 14.11 21.2 21.25 14.1-14.1zm-26.9 26.89l-18.7 18.73 28.3 14.16 11.7-11.66zM163.2 72.8L147 89l12.8 12.8L176 85.52zm-50.1 7.77L80.61 113.1l58.79 58.8h32.5v-32.6zm101.7 52.03c-1.4 19.6-11.8 39.7-27.2 55-15.3 15.4-35.4 25.8-55 27.2l3.5 17.8c24.1-2.3 46.8-14.8 64.3-32.2 17.4-17.5 29.9-40.2 32.2-64.3zm47.5 9.5c-6.4 63.8-56.4 113.7-120.2 120.2l3.5 17.7c70.6-8 126.4-63.8 134.4-134.4zM89.03 147l-16.22 16.2L85.54 176l16.26-16.3zM340 157.6c-7.4 37.9-28.2 78.8-58.7 112.3-32.2 35.5-74.9 62.6-123.6 70.6l3.5 17.7c53.1-8.9 99.1-38.4 133.5-76.1 32.5-35.9 55-79.2 63-121zm-304.21.3l-11.66 11.7 21.23 21.2 18.71-18.7zM434 176.4C422.9 231.5 393.8 285 353.7 329l16 9.2c40.7-45.7 70.5-100.7 82-158.3zm-357.2 8.4l-18.73 18.7 21.22 21.3 11.66-11.7zM18 189v28.2l.46.5 14.13-14.1zm27.3 27.3l-14.11 14.1 21.26 21.2 14.09-14.1zm-26.88 26.8l-.42.4v33.2l4.7 4.7 16.99-17zm418.38 95.4l-98.3 98.3c11.4 6.5 30.5 12.6 49.5 14.8 24.1 2.6 47.8-1.7 54.8-8.8 7.1-7 11.4-30.7 8.8-54.8-2.2-19-8.3-38.1-14.8-49.5zm-92.4 5.9l22.3 38.8 16.5-16.5zm-15.4 9.2c-44 40.2-97.5 69.3-152.6 80.4l3.5 17.7c57.6-11.5 112.6-41.3 158.3-82zM469.4 425c-1.8 12.1-6.1 22.8-13.8 30.6-7.8 7.7-18.5 12-30.6 13.8V487h62v-62z","b":[18.0,18.0,469.0,469.0]},{"n":"sinusoidal-beam","d":"M18.7 18.7v31.474l7.804 9.853c-3.24 5.71-5.774 11.464-7.512 17.12-.104.34-.192.684-.29 1.025v28.437c1.392 3.52 3.446 6.762 6.275 9.585 9.892 9.873 24.882 10.316 39.107 5.93 2.954-.91 5.934-2.048 8.922-3.377l38.894 49.115c-1.928 4.116-3.545 8.218-4.81 12.266-5.35 17.106-4.78 34.656 6.61 46.07 11.392 11.41 28.924 11.99 45.96 6.67.977-.306 1.96-.637 2.942-.98l65.402 82.587c-.53 1.544-1.036 3.084-1.49 4.61-6.15 20.656-5.49 41.09 7.65 54.255 11.795 11.818 29.506 13.57 47.713 9.166l87.736 110.79h23.84l-2.316-2.923c3.324-9.926 8.54-20.652 15.472-31.45l31.365 34.374H493.3v-75.472l-31.062-27.096c5.482-8.462 10.068-16.987 13.664-25.396l17.397 13.36v-23.56l-10.98-8.435c5.676-22.206 3.702-43.492-10.226-57.39-15.163-15.132-39.034-16.085-63.23-8.472-2.783.875-5.59 1.88-8.41 2.984l-89.493-68.736c.83-2.283 1.583-4.55 2.24-6.8 5.66-19.4 4.954-38.725-7.53-51.235-12.484-12.51-31.86-13.23-50.99-7.25-6.114 1.91-12.345 4.524-18.582 7.786l-59.504-45.703c2.706-4.89 4.92-9.77 6.59-14.557 5.17-14.83 5.566-30.396-4.614-40.597-10.178-10.202-25.744-9.823-40.57-4.664-7.716 2.685-15.67 6.774-23.54 12.092L55.274 18.7H18.7zm137.84 48.556c4.273-.033 7.21 1.077 8.802 2.672 2.83 2.835 4.132 9.955.195 21.244-1.012 2.903-2.35 5.977-3.99 9.152l-31.27-24.017c4.855-2.87 9.55-5.088 13.866-6.59 4.938-1.72 9.072-2.436 12.396-2.46zM39.296 76.182l21.615 27.297c-.788.282-1.57.55-2.336.786-10.46 3.225-17.255 1.84-20.398-1.297-3.144-3.138-4.525-9.9-1.32-20.333.636-2.07 1.456-4.233 2.44-6.455zm78.72 14.273l33.383 25.64c-.527.686-1.086 1.37-1.636 2.053l-31.746-27.693zm-17.11 33.426l22.44 24.595c-.47.658-.94 1.317-1.396 1.978L100.91 123.88zm65.34 3.622l52.868 40.605c-2.168 1.557-4.323 3.197-6.463 4.903l-48.773-42.547c.803-.984 1.602-1.97 2.368-2.96zm-29.936 35.18l38.627 42.334c-2.238 1.42-4.468 2.74-6.67 3.923l-34.048-42.995c.667-1.085 1.368-2.174 2.09-3.263zm140.77 2.164c6.828.095 12.03 2.068 15.36 5.406 5.685 5.696 7.436 16.95 2.824 32.777L252.78 170.4c2.548-1.07 5.05-2.006 7.474-2.763 5.763-1.8 10.93-2.685 15.44-2.785.47-.01.93-.013 1.386-.006zm-42.338 15.26l53.252 40.904c-1.968 3.888-4.236 7.85-6.748 11.836l-54.215-47.293c2.567-1.938 5.142-3.765 7.712-5.446zm-109.488 4.62l24.86 31.395c-11.155 2.685-19.058 1.01-23.184-3.122l-.002-.002c-4.6-4.61-6.178-13.935-2.002-27.29.1-.322.22-.653.328-.98zm62.484 34.32l56.766 62.212c-2.957 4.59-5.663 9.19-8.06 13.775l-56.39-71.21c2.57-1.47 5.134-3.067 7.684-4.778zm115.342 13.55l78.408 60.222c-6.084 3.394-12.166 7.278-18.177 11.616l-67.794-59.14c2.768-4.223 5.302-8.465 7.564-12.698zm134.16 62.273c9.404.114 16.794 2.82 21.653 7.667 6.444 6.43 9.11 17.333 6.96 31.518l-47.537-36.512c6.178-1.672 11.877-2.538 17.016-2.662.645-.015 1.28-.018 1.908-.01zm-179.63.753l50.32 55.15c-6.605 4.173-13.157 7.547-19.403 10.03l-39.18-49.477c2.283-5.103 5.053-10.373 8.262-15.703zm140.245 9.768l62.665 48.13c-3.06 7.96-7.285 16.32-12.563 24.755l-70.105-61.156c6.714-4.59 13.44-8.52 20.003-11.73zM242.43 332.694l26.26 33.162c-9.63.86-16.912-1.318-21.3-5.714-5.222-5.232-7.314-14.614-4.96-27.447zm78.302 32.112l72.788 79.77c-6.504 9.502-11.876 19.133-15.967 28.646l-76.987-97.216c6.712-3.015 13.476-6.772 20.166-11.2z","b":[18.7,18.7,474.6,474.6]},{"n":"speaker","d":"M275.5 96l-96 96h-96v128h96l96 96V96zm51.46 27.668l-4.66 17.387c52.066 13.95 88.2 61.04 88.2 114.945 0 53.904-36.134 100.994-88.2 114.945l4.66 17.387C386.81 372.295 428.5 317.962 428.5 256c0-61.963-41.69-116.295-101.54-132.332zm-12.425 46.365l-4.658 17.387C340.96 195.748 362.5 223.822 362.5 256s-21.54 60.252-52.623 68.58l4.658 17.387C353.402 331.552 380.5 296.237 380.5 256c0-40.238-27.098-75.552-65.965-85.967zm-12.424 46.363l-4.657 17.387C307.55 236.49 314.5 245.547 314.5 256s-6.95 19.51-17.047 22.217l4.658 17.387c17.884-4.792 30.39-21.09 30.39-39.604 0-18.513-12.506-34.812-30.39-39.604z","b":[83.5,96.0,345.0,320.0]},{"n":"speaker-off","d":"M275.5 96l-96 96h-96v128h96l96 96V96zm50.863 89.637l-12.726 12.726L371.273 256l-57.636 57.637 12.726 12.726L384 268.727l57.637 57.636 12.726-12.726L396.727 256l57.636-57.637-12.726-12.726L384 243.273l-57.637-57.636z","b":[83.5,96.0,370.9,320.0]},{"n":"star-satellites","d":"M259.72 17.125c-46.945.28-93.808 14.67-133.626 43.188 90.04-37.994 198.53-19.315 271.937 54.093 73.324 73.342 91.483 181.133 53.626 271.125 65.043-90.962 56.77-217.948-25.03-299.75-46.024-46.074-106.55-69.016-166.907-68.655zM451.655 385.53c-.044.063-.08.127-.125.19l.033.06c.034-.08.06-.167.093-.25zM96.28 67.03c-14.01 0-25.155 11.162-25.155 25.157 0 14.012 11.16 25.157 25.156 25.157 14.013 0 25.157-11.16 25.157-25.156 0-14.012-11.16-25.157-25.156-25.157zm161.782 14.564c-44.438-.03-88.87 16.9-122.75 50.78-67.772 67.777-67.662 177.742.188 245.595 67.865 67.867 177.805 67.916 245.563.155 67.772-67.776 67.693-177.74-.157-245.594-33.932-33.933-78.405-50.908-122.844-50.936zm-4.468 21.344l21.656 61.874c-14.76-2.616-30.052-1.584-44.375 3.157l22.72-65.032zM65.28 122.844c-.033.082-.058.168-.093.25.044-.062.082-.126.126-.188l-.032-.062zm-.093.25C.144 214.057 8.417 341.044 90.22 422.844c81.817 81.912 209.517 90.654 300.53 25.47-90.042 37.992-198.53 19.313-271.938-54.095-73.323-73.343-91.48-181.134-53.624-271.126zm82.72 23.562l63.405 30.53c-5.604 3.53-10.878 7.743-15.75 12.626l-.03-.062c-6.252 6.25-11.38 13.19-15.407 20.594l-1.03 1.03-31.19-64.718zm211.655.063l-26.406 54.843c-2.922-4.126-6.224-8.068-9.906-11.75-6.34-6.34-13.39-11.536-20.906-15.594l57.22-27.5zm-99.218 45.655c15.813.01 31.644 6.05 43.72 18.125 24.148 24.15 24.178 63.29.06 87.406-24.116 24.118-63.256 24.088-87.405-.062-24.15-24.15-24.15-63.29-.032-87.406 12.058-12.06 27.842-18.074 43.656-18.063zm-88.47 36.375v2.813c-3.59 14.433-3.58 29.592.032 44.03v.594l-67.812-23.75 67.78-23.687zm175.532 4.438l56 19.593-55.187 19.282c2.51-12.828 2.213-26.11-.814-38.875zm-168.562 61.03c4.216 8.38 9.796 16.235 16.78 23.22 4.282 4.28 8.915 8.028 13.782 11.28l-61.344 29.5 30.782-64zm155.344 11.313l25.5 52.908-54.438-26.22c6.65-3.815 12.897-8.556 18.563-14.218 3.9-3.9 7.35-8.073 10.375-12.47zM232.03 339.657c13.79 4.442 28.437 5.565 42.626 3.313l-20.72 59.28-21.905-62.594zm195.064 58.875c-14.012 0-25.156 11.162-25.156 25.158 0 14.01 11.16 25.156 25.156 25.156 14.012 0 25.125-11.16 25.125-25.156 0-14.012-11.13-25.157-25.126-25.157z","b":[0.1,16.8,516.6,496.7]},{"n":"tv-tower","d":"M215.027 25l-11.5 46h104.946l-11.5-46h-81.946zM201 89v41.535c4.545-2 9.214-3.766 14-5.27V89h-14zm32 0v31.94c4.594-.78 9.264-1.329 14-1.637V89h-14zm32 0v30.303c4.736.308 9.406.857 14 1.636V89h-14zm32 0v36.266a135.976 135.976 0 0 1 14 5.27V89h-14zm-41 48c-65.828 0-119 53.172-119 119 0 2.35.075 4.683.209 7h237.582c.134-2.317.209-4.65.209-7 0-65.828-53.172-119-119-119zM139.627 281a118.257 118.257 0 0 0 3.893 14h224.96a118.257 118.257 0 0 0 3.893-14H139.627zm11.844 32c20.164 36.971 59.366 62 104.529 62s84.365-25.029 104.53-62H151.47zm47.738 67.668L196.187 429h119.625l-3.021-48.332C295.481 388.583 276.249 393 256 393c-20.249 0-39.48-4.417-56.791-12.332zM195.062 447l-.875 14h123.625l-.875-14H195.063zm-2 32L192 496h128l-1.063-17H193.063z","b":[137.0,25.0,238.0,471.0]},{"n":"watchtower","d":"M256 32l-96 48h23v71h-32v50h30.945L155.36 440.244l-.653.477.522.72-4.175 37.566-.994 8.945 17.89 1.99.995-8.946L171.61 457h168.78l2.665 23.994.994 8.945 17.89-1.99-.995-8.944-4.174-37.567.523-.72-.654-.476L330.054 201H361v-50h-32V80h23l-96-48zm-48 64h32v48h-32V96zm64 0h32v48h-32V96zm-103 73h14v14h-14v-14zm32 0h14v14h-14v-14zm32 0h14v14h-14v-14zm32 0h14v14h-14v-14zm32 0h14v14h-14v-14zm32 0h14v14h-14v-14zm-113.328 32h80.656L256 236.848 215.672 201zm-16.65 9.283L240.33 247h-45.385l4.08-36.717zm113.955 0l4.08 36.717h-45.385l41.305-36.717zM192.945 265h31.383l-34.822 30.953 3.44-30.953zm58.477 0h9.156l51.75 46H199.672l51.75-46zm36.25 0h31.383l3.44 30.953L287.67 265zm-83.994 64h104.644L256 367.053 203.678 329zm-18.8 8.586L236.323 375h-55.6l4.157-37.414zm142.243 0L331.278 375h-55.6l51.444-37.414zM178.724 393h41.6l-45.26 32.914 3.66-32.914zm72.205 0h10.144l63.25 46H187.678l63.25-46zm40.75 0h41.6l3.658 32.914L291.678 393z","b":[150.1,32.0,211.9,457.9]},{"n":"wifi-router","d":"M311.4 32.82C279.9 53.58 259 89.29 259 129.8c0 39.9 20.3 75.2 51.1 96.1l8.1-16.2c-25-17.8-41.2-46.9-41.2-79.9 0-33.59 16.8-63.17 42.5-80.82l-8.1-16.16zm127.2 0l-8.1 16.16C456.2 66.63 473 96.21 473 129.8c0 33-16.2 62.1-41.2 79.9l8.1 16.2c30.8-20.9 51.1-56.2 51.1-96.1 0-40.51-20.9-76.22-52.4-96.98zm-110 34.35C309.4 81.41 297 104.2 297 129.8c0 25 11.9 47.3 30.3 61.6l8.2-16.4c-12.6-11-20.5-27.1-20.5-45.2 0-18.7 8.5-35.3 21.8-46.29l-8.2-16.34zm92.8 0l-8.2 16.34C426.5 94.5 435 111.1 435 129.8c0 18.1-7.9 34.2-20.5 45.2l8.2 16.4c18.4-14.3 30.3-36.6 30.3-61.6 0-25.6-12.4-48.39-31.6-62.63zm-75.3 35.03c-6.9 7.2-11.2 16.9-11.2 27.6 0 10.1 3.8 19.3 10 26.4l9.4-18.7c-.9-2.4-1.4-5-1.4-7.7 0-3.5.8-6.7 2.2-9.6l-9-18zm57.8 0l-9 18c1.4 2.9 2.2 6.1 2.2 9.6 0 2.7-.5 5.3-1.4 7.7l9.4 18.7c6.2-7.1 10-16.3 10-26.4 0-10.7-4.3-20.4-11.2-27.6zM366 144v183h18V144h-18zM25 345v110h462V345H25zm55 39a16 16 0 0 1 16 16 16 16 0 0 1-16 16 16 16 0 0 1-16-16 16 16 0 0 1 16-16zm48 0a16 16 0 0 1 16 16 16 16 0 0 1-16 16 16 16 0 0 1-16-16 16 16 0 0 1 16-16zm48 0a16 16 0 0 1 16 16 16 16 0 0 1-16 16 16 16 0 0 1-16-16 16 16 0 0 1 16-16zM73 473v16h46v-16H73zm320 0v16h46v-16h-46z","b":[25.0,32.8,466.0,456.2]},{"n":"audio-cassette","d":"M32.033 96S16 96 16 112.22V384c0 16 15.783 16 15.783 16h54.94l.547-2.184L104.973 327h302.054l17.703 70.816.547 2.184h53.01S496 400 496 385.23V112c0-16-16-16-16-16H32.033zM87 135h338v18H87v-18zm0 48h338v114H87V183zm18 18v78h132.795c5.88-11.722 9.205-24.957 9.205-39s-3.326-27.278-9.205-39H105zm152.465 0c4.85 12.066 7.535 25.223 7.535 39 0 13.777-2.686 26.934-7.535 39h32.89C283.17 267.708 279 254.33 279 240c0-14.33 4.17-27.708 11.354-39h-32.89zm55.676 0c-9.98 9.945-16.14 23.723-16.14 39 0 15.277 6.16 29.055 16.14 39h77.72c9.98-9.945 16.14-23.723 16.14-39 0-15.277-6.16-29.055-16.14-39h-77.72zm-143.677 8.432a32 32 0 0 1 12.06 6.94l-5.12 2.956c5.044 4.037 8.61 9.857 9.693 16.465l5.06-2.922A32 32 0 0 1 192 240a32 32 0 0 1-.787 6.94l-5.072-2.928c-1.016 6.624-4.525 12.476-9.525 16.56l5.065 2.924a32 32 0 0 1-12.217 7.04v-5.778c-2.972 1.164-6.192 1.812-9.553 1.812-3.36 0-6.58-.648-9.553-1.812v5.744a32 32 0 0 1-12.11-7.086l4.944-2.853c-4.995-4.088-8.5-9.943-9.512-16.57l-4.903 2.83A32 32 0 0 1 128 240a32 32 0 0 1 .81-7.027l4.91 2.834c1.08-6.608 4.643-12.43 9.684-16.47l-5.013-2.894a32 32 0 0 1 11.967-6.918v5.786c2.972-1.164 6.193-1.812 9.553-1.812 3.36 0 6.58.648 9.553 1.813v-5.878zm192.11.04a32 32 0 0 1 11.984 6.93l-5.047 2.914c5.044 4.038 8.61 9.857 9.693 16.465l4.963-2.862A32 32 0 0 1 384 240a32 32 0 0 1-.77 6.877l-4.98-2.875c-1.016 6.624-4.526 12.476-9.525 16.56l5.004 2.89a32 32 0 0 1-12.158 7.046v-5.75c-2.97 1.164-6.194 1.81-9.554 1.81-3.36 0-6.58-.646-9.553-1.81v5.793a32 32 0 0 1-12.184-7.093l5.02-2.896c-4.998-4.087-8.503-9.942-9.515-16.568l-5 2.887A32 32 0 0 1 320 240a32 32 0 0 1 .826-7.092l5.002 2.89c1.08-6.61 4.643-12.43 9.684-16.47l-5.073-2.93a32 32 0 0 1 12.025-6.908v5.81c2.972-1.166 6.192-1.812 9.553-1.812 3.36 0 6.583.646 9.554 1.81v-5.825zM119.026 345l-13.75 55h301.446l-13.75-55H119.027zM48 352a16 16 0 0 1 16 16 16 16 0 0 1-16 16 16 16 0 0 1-16-16 16 16 0 0 1 16-16zm416 0a16 16 0 0 1 16 16 16 16 0 0 1-16 16 16 16 0 0 1-16-16 16 16 0 0 1 16-16zm-304 7h48v18h-48v-18zm144 0h48v18h-48v-18z","b":[16.0,96.0,480.0,304.0]},{"n":"binoculars","d":"M186.436 86.738c-9.044 0-19.112 5.87-26.735 21.114l-6.807 13.62c2.48-.203 4.968-.31 7.455-.31 18.02 0 36.005 5.363 51.87 15.977v-30.984c-7.5-13.917-17.102-19.418-25.782-19.418zm139.128 0c-8.68 0-18.28 5.5-25.78 19.418v30.994c18.064-12.06 38.895-17.28 59.345-15.638l-6.83-13.66c-7.624-15.245-17.692-21.114-26.736-21.114zm-165.216 51.926c-19.05 0-38.08 7.693-53.74 23l-37.38 65.418c14.492-6.743 30.633-10.518 47.64-10.518 39.96 0 75.16 20.792 95.35 52.124V159.846c-15.293-14.115-33.58-21.182-51.87-21.182zm192.433.033c-18.662-.306-37.39 6.74-52.997 21.145v108.845c20.19-31.33 55.39-52.123 95.348-52.123 17.01 0 33.15 3.775 47.643 10.518l-37.38-65.418c-15.35-15.003-33.95-22.66-52.612-22.967zM256 151.957c-5.113 0-11.882 2.775-25.783 9.627v133.014c7.246-5.314 16.164-8.467 25.783-8.467 9.62 0 18.537 3.154 25.783 8.468V161.584c-13.9-6.852-20.67-9.627-25.783-9.627zm-139.13 82.607c-52.767 0-95.35 42.582-95.35 95.348s42.583 95.35 95.35 95.35c52.765 0 95.347-42.584 95.347-95.35 0-52.766-42.582-95.348-95.348-95.348zm278.26 0c-52.765 0-95.347 42.582-95.347 95.348s42.582 95.35 95.348 95.35c52.767 0 95.35-42.584 95.35-95.35 0-52.766-42.583-95.348-95.35-95.348zm-279.827 19.004c1.223-.018 2.448-.008 3.674.03 7.344.225 14.694 1.462 21.77 3.816 36.842 11.343 59.745 51.664 50.622 89.11-7.652 37.743-45.455 64.51-83.595 59.17-38.748-3.865-69.376-39.578-67.16-78.483.167-11.41 3.133-22.336 8.2-32.124A26.087 26.087 0 0 0 73.39 312.52a26.087 26.087 0 0 0 26.09-26.084 26.087 26.087 0 0 0-17.447-24.584c9.058-4.694 19.097-7.594 29.606-8.147 1.218-.072 2.44-.118 3.663-.137zm278.26 0c1.223-.018 2.448-.008 3.673.03 7.344.225 14.696 1.462 21.774 3.816 36.84 11.343 59.742 51.664 50.62 89.11-7.652 37.742-45.453 64.51-83.59 59.173-38.75-3.865-69.38-39.582-67.163-78.488.167-11.41 3.133-22.334 8.2-32.122a26.087 26.087 0 0 0 24.575 17.433 26.087 26.087 0 0 0 26.086-26.084 26.087 26.087 0 0 0-17.443-24.584c9.057-4.694 19.095-7.594 29.603-8.147 1.22-.072 2.44-.118 3.664-.137zM256 304.13c-14.346 0-25.783 11.436-25.783 25.782s11.437 25.783 25.783 25.783c14.346 0 25.783-11.437 25.783-25.783 0-14.346-11.437-25.78-25.783-25.78z","b":[21.5,86.7,469.0,338.5]},{"n":"cctv-camera","d":"M109.285 30.402c-14.82-.007-30.414 2.144-46.822 6.932a9.5 9.5 0 0 0-.145.05 9.5 9.5 0 0 0-.496.173 9.5 9.5 0 0 0-.39.152 9.5 9.5 0 0 0-.47.218 9.5 9.5 0 0 0-.384.193 9.5 9.5 0 0 0-.463.273 9.5 9.5 0 0 0-.342.22 9.5 9.5 0 0 0-.435.32 9.5 9.5 0 0 0-.324.256 9.5 9.5 0 0 0-.397.357 9.5 9.5 0 0 0-.297.29 9.5 9.5 0 0 0-.37.405 9.5 9.5 0 0 0-.247.293 9.5 9.5 0 0 0-.342.463 9.5 9.5 0 0 0-.215.315 9.5 9.5 0 0 0-.282.472 9.5 9.5 0 0 0-.193.354 9.5 9.5 0 0 0-.233.497 9.5 9.5 0 0 0-.156.367 9.5 9.5 0 0 0-.178.512 9.5 9.5 0 0 0-.122.386 9.5 9.5 0 0 0-.17.688L33.42 156.55a9.5 9.5 0 0 0 5.625 10.614l82.023 34.578 31.62 162.133-116.534 25.313a9.5 9.5 0 0 0-7.5 9.156l-1.062 76.47a9.5 9.5 0 0 0 12.375 9.186l146.468-46.813 24.123-4.677c.177.003.353.015.53.015 9.956 0 19.332-4.742 25.88-12.472 6.543-7.724 9.966-17.79 9.956-28.16v-.026c.006-6.574-1.372-13.037-4.045-18.855l-25.273-130.57 125.774 53.02a9.5 9.5 0 0 0 .155.058 9.5 9.5 0 0 0 .545.197 9.5 9.5 0 0 0 .35.11 9.5 9.5 0 0 0 .543.138 9.5 9.5 0 0 0 .416.086 9.5 9.5 0 0 0 .483.073 9.5 9.5 0 0 0 .482.05 9.5 9.5 0 0 0 .43.02 9.5 9.5 0 0 0 .54.004 9.5 9.5 0 0 0 .363-.01l83.406-5.28a9.5 9.5 0 0 0 7.97-5.438l50.522-106.954.008-.014a9.5 9.5 0 0 0 0-.002 9.5 9.5 0 0 0 .02-.047 9.5 9.5 0 0 0-5.51-13.137c-7.787-4.27-15.802-7.26-23.956-9.148L152.273 36.688a9.5 9.5 0 0 0-.802-.268c-13.317-3.843-27.364-6.01-42.185-6.018zM82.938 44.125a9.5 9.5 0 0 1 3.687.72l290.75 116.53a9.508 9.508 0 0 1 5.77 10.79 9.5 9.5 0 0 0-.707 1.46l-.836 2.07a9.508 9.508 0 0 1-11.29 3.336L79.563 62.47a9.5 9.5 0 0 1 3.376-18.345zm357.308 128.367c4.4.038 8.75.508 13.068 1.404l14.74 5.72-23.67 50.114c.912-4.058 1.378-8.082 1.335-11.855-.1-8.732-2.94-15.95-7.845-19.563-4.905-3.613-11.688-3.48-18.375.25-1.65.92-3.305 2.063-4.906 3.375.614-.822 1.19-1.72 1.687-2.687 1.417-2.757 2.248-5.952 2.22-8.78-.032-2.835-.945-5.243-2.563-6.47-.808-.613-1.74-.922-2.75-.906-1.01.016-2.102.332-3.156.937-2.107 1.212-4.08 3.52-5.5 6.282-1.417 2.764-2.25 5.948-2.217 8.782.03 2.833.945 5.242 2.562 6.47 1.617 1.225 3.798 1.147 5.906-.064-3.416 3.562-6.546 7.9-9.092 12.72-4.608 8.716-7.226 18.798-7.125 27.53.1 8.732 3 15.98 7.906 19.594 4.904 3.614 11.624 3.45 18.31-.28 4.178-2.332 8.29-6.018 11.91-10.582l-8.41 17.8-62.75 4 37.253-92.39c14.635-7.746 28.272-11.513 41.463-11.4zm-298.078 38.145l16.014 6.752 29.732 139.555c-3.005-.917-6.143-1.41-9.342-1.41-2.724 0-5.4.366-7.988 1.037l-28.416-145.935zm37.353 15.748l17.017 7.174 23 118.83c-2.732-.75-5.564-1.156-8.447-1.156-1.643 0-3.266.14-4.865.39l-26.704-125.24zM211.09 370.3c3.863 0 8.258 1.978 11.472 5.772 3.215 3.795 5.433 9.89 5.424 15.795a9.47 9.532 0 0 0 0 .026c.01 5.905-2.21 12-5.423 15.795-1.525 1.8-3.316 3.177-5.188 4.142l-6.143 1.19c2.106-5.273 3.184-11.002 3.178-16.827v-.025c.004-3.773-.452-7.51-1.342-11.107a9.5 9.5 0 0 0-.193-2.248l-2.656-12.458c.29-.022.583-.055.87-.055zm-32.518 4.3c3.864 0 8.26 1.978 11.475 5.773 3.214 3.795 5.43 9.89 5.422 15.795a9.47 9.532 0 0 0 0 .025c.008 5.905-2.21 12-5.423 15.795-3.215 3.795-7.61 5.774-11.475 5.774-3.863 0-8.233-1.98-11.447-5.774-3.214-3.794-5.458-9.89-5.45-15.795a9.47 9.532 0 0 0 0-.025c-.008-5.905 2.236-12 5.45-15.795s7.584-5.773 11.447-5.773zm-34.496 10.59c-.87 3.56-1.316 7.25-1.312 10.978v.025c-.01 10.37 3.41 20.437 9.953 28.16.838.99 1.723 1.93 2.648 2.817L46.78 461.875l.782-55.72 96.514-20.966z","b":[27.6,30.4,462.0,453.6]},{"n":"clapperboard","d":"M419.682 26.2l-8.66 2.452L32.915 135.81 55.27 214.7l386.77-109.608L419.683 26.2zm-12.41 22.224l9.074 32.014-41.086-22.942 32.013-9.072zM350.77 64.438l56.8 31.714-37.084 10.51-56.8-31.715 37.084-10.51zm-61.577 17.45l56.803 31.716-37.084 10.51-56.8-31.718 37.08-10.51zm-61.574 17.45l56.802 31.715-37.084 10.51-56.803-31.715 37.084-10.51zm-61.577 17.45l56.803 31.716-37.084 10.51-56.8-31.717 37.08-10.51zm-61.574 17.45l56.8 31.715-37.083 10.51-56.802-31.715 37.084-10.51zm-45.86 26.227l41.085 22.94-32.01 9.072-9.074-32.012zM55 215v274h402V215H55zm18 18h33.273L73 266.273V233zm58.727 0h38.546l-46 46H85.727l46-46zm64 0h38.546l-46 46h-38.546l46-46zm64 0h38.546l-46 46h-38.546l46-46zm64 0h38.546l-46 46h-38.546l46-46zm64 0h38.546l-46 46h-38.546l46-46zM439 245.727V279h-33.273L439 245.727zM73 297h366v174H73V297zm248.635 46.57l-192.44.703.067 18 192.44-.703-.067-18zM130.7 391.33l-.134 17.998 92.707.703.137-18-92.71-.7zm127.155.7l-.2 18 63.913.702.2-17.998-63.913-.703z","b":[32.9,26.2,424.1,462.8]},{"n":"film-projector","d":"M266 51.727c-39.32 0-71 31.68-71 71 0 39.319 31.68 71.002 71 71.002s71-31.683 71-71.002c0-39.32-31.68-71-71-71zm-144 32c-30.483 0-55 24.517-55 55 0 30.482 24.517 55.002 55 55.002s55-24.52 55-55.002c0-30.483-24.517-55-55-55zm-23 128v110.002h238V211.727zm350 4.648l-94 40.285v20.133l94 40.285zm-386 2.352v32h18v-32zm113 121.002v17.998h13.012l-51.123 136.275h19.222l51.507-136.275.382 136.275h18l.382-136.275 51.507 136.275h19.222l-51.123-136.275H260v-17.998c-28.003-.003-55.997 0-84 0z","b":[63.0,51.7,386.0,442.3]},{"n":"film-spool","d":"M208 25C106.8 25 25 106.8 25 208s81.8 183 183 183 183-81.8 183-183S309.2 25 208 25zm121.3 22.81c21 15.91 38.7 35.83 52.1 58.59 49.1 41.7 93.4 100.9 92 179.2-.6 34.4-7.3 75.5-19.4 110.3-12.1 34.7-30.1 62.3-49.7 71.7-3.9 1.8-9.5 2.2-17.5.6-8-1.7-17.9-5.3-29.3-10-22.7-9.5-51.2-23.4-84.2-33.5-66.2-20.1-152-24.2-247.5 50.6l11.1 14.2c91.2-71.5 168.3-66.7 231.1-47.6 31.4 9.6 59 23 82.6 32.9 11.7 4.9 22.5 8.9 32.6 11 10.1 2.1 20 2.3 28.9-2 27.5-13.1 46-45.1 58.9-82 12.9-36.9 19.8-79.5 20.4-115.8 1.6-92.8-55.5-160.5-111.9-204.3-17.2-13.42-34.5-24.69-50.2-33.89zM208 52c16 0 32 4 48 12 0 32-32 80-48 80s-48-48-48-80c16-8 32-12 48-12zM107.4 94.4c27.7 16 53.3 67.7 45.4 81.6-8.1 13.8-65.6 17.5-93.33 1.5 2.14-35.7 18.13-63.4 47.93-83.1zm201.2 0c29.9 19.7 45.9 47.4 48 83.1-27.7 16-85.3 12.3-93.3-1.5-8-13.9 17.6-65.6 45.3-81.6zM208 167c22.5 0 41 18.5 41 41s-18.5 41-41 41-41-18.5-41-41 18.5-41 41-41zm0 18c-12.8 0-23 10.2-23 23s10.2 23 23 23 23-10.2 23-23-10.2-23-23-23zm-98.1 42.8c20.3.2 38.6 4.7 42.9 12 7.9 13.9-17.7 65.6-45.4 81.6-29.83-19.7-45.83-47.4-47.97-83.1 12.97-7.5 32.52-10.7 50.47-10.5zm196.2 0c18-.2 37.5 3 50.5 10.5-2.1 35.7-18.1 63.4-48 83.1-27.7-16-53.3-67.7-45.3-81.6 4.3-7.3 22.5-11.8 42.8-12zM208 271.7c16 .1 48 48.1 48 80.1-32 16-64 16-96 0 0-32 32-80 48-80.1z","b":[25.0,25.0,468.0,464.5]},{"n":"film-strip","d":"M55 18v476h18v-37h46v37h274v-37h46v37h18V18h-18v37h-46V18h-18v60H137V18h-18v37H73V18H55zm18 55h46v46H73V73zm320 0h46v46h-46V73zm-256 41h238v156H137V114zm-64 23h46v46H73v-46zm320 0h46v46h-46v-46zM73 201h46v46H73v-46zm320 0h46v46h-46v-46zM73 265h46v46H73v-46zm320 0h46v46h-46v-46zm-256 41h238v156H137V306zm-64 23h46v46H73v-46zm320 0h46v46h-46v-46zM73 393h46v46H73v-46zm320 0h46v46h-46v-46z","b":[55.0,18.0,402.0,476.0]},{"n":"james-bond-aperture","d":"M146 18.09l-.3 2.13C210 29.23 267.9 61.24 310 107.9c-9.7-1.7-19.4-2.8-29.1-3.4 45.9 39.7 64.4 103.8 46 162.3 26-18.7 45.4-46.6 52.9-79.8-29.2-77.8-91.4-139.34-168.3-168.91zm267.8 0c28.6 77.52 19.4 160.31-18.9 227.51-1.4-9.5-3.2-18.8-5.5-27.9-20.3 47.4-63.4 81.5-113.9 90.7-9.8 2.3-18.3 2.4-27.8 2.4 25.3 19.4 57.3 30 91 28 94.7-74.5 135.2-202.8 94.9-320.71zM248.7 104.3c-97.2 5.2-186.06 62.2-230.83 150V304c21.42-69.8 70.21-124.2 131.33-154.6-4.5 8.5-8.4 17.2-11.9 26 25.3-16.3 54.4-24.5 83.4-24.6 30.8 0 61.5 9.2 87.7 27.4-9.9-30.1-30.5-56.8-59.7-73.9zm-32.2 65.2c-32.5 1-64.7 13.8-89.8 38.2-27.13 103.4 7.4 216.2 92.5 286.3h31c-66.6-45.4-105.8-116.5-112.8-191.2 6.6 7.1 13.6 13.8 20.9 20.1-12.6-57.7 9.9-117.7 58.2-153.4zm40.7 12.8c-30.4 0-54.8 24.5-54.8 54.9s24.4 54.8 54.8 54.8 54.8-24.4 54.8-54.8-24.4-54.9-54.8-54.9zm-75.7 63c-11.3 30.6-11.2 65.1 2.7 97.5 91.5 62 214.5 64.6 309.6.2v-23C434.4 364.7 362 379.8 294 367.7c6.6-3.4 13-7.1 19.2-10.9-61.6-7.1-114.2-50.9-131.7-111.5z","b":[17.9,18.1,475.9,475.9]},{"n":"light-projector","d":"M18 17v18h38v78.3c-.75.7-1.47 1.5-2.16 2.3-6.52 7.5-9.72 14.5-10.08 19.8l47.46 84.5c1.03-1.9 2.15-3.9 3.39-5.6 8.29-12.2 21.49-23.8 37.89-33.2 16.5-9.1 33.3-14.3 48-15.1 2.2-.1 4.4-.1 6.6 0l-47.4-84.47c-3-1.54-7.1-2.5-12.3-2.53h-2.3c-2.3.11-4.9.4-7.5.88-10.7 1.91-23.15 6.66-34.61 13.1-3.08 1.73-6.09 3.59-8.99 5.53V35h45v26.5c1.8-.22 3.5-.39 5.3-.49 4.4-.25 8.6-.07 12.7.67V35h55V17H18zm165.4 166.9c-.6.1-1.3.1-2 .1-11.1.6-25.7 4.8-40.1 12.9-14.3 8.1-25.5 18.4-31.8 27.5-6.2 9.2-6.8 16-4.8 19.5 1.9 3.5 8 6.5 19.1 6 11.1-.5 25.7-4.8 40.1-12.9 14.3-8.1 25.6-18.3 31.8-27.5 6.2-9.2 6.8-16 4.9-19.5-1.9-3.3-7.4-6.1-17.2-6.1zm36.2 12.2c-.5 7.9-4 16.1-9 23.5-8.3 12.2-21.4 23.8-37.9 33.1s-33.3 14.4-48 15.2c-10.3.5-20.2-1.2-27.61-6.3L49.48 491.4H492.8V353.8L219.6 196.1z","b":[18.0,17.0,474.8,474.4]},{"n":"microscope","d":"M367.717 25.318L325.94 63.475l49.953 38.296 26.002-50.247-34.178-26.205zm-62.71 41.608l-38.562 49.242 70.936 55.66 38.604-49.12-70.978-55.782zm-50.495 64.28l-58.035 73.85 118.628 88.885s3.513 2.384 5.48 5.904c2.02 3.612 1.81 6.935 1.81 6.935v128.544H297.14v-24.56H89.255v24.56H61.51v59.358H432.963V338.184c-9.25 4.65-19.462 7.077-29.817 7.084-36.706 0-66.463-29.758-66.462-66.465.034-23.723 12.71-45.63 33.26-57.48L254.51 131.206zM185 220.175l-68.21 87.103 112.83 1.668 27.495-34.984L185 220.175zm218.146 11.285a47.344 47.344 0 0 0-47.34 47.343 47.344 47.344 0 0 0 47.34 47.343 47.344 47.344 0 0 0 47.344-47.343 47.344 47.344 0 0 0-47.344-47.344zm0 17.67a29.674 29.674 0 0 1 29.676 29.673 29.674 29.674 0 0 1-29.676 29.674 29.674 29.674 0 0 1-29.673-29.674 29.674 29.674 0 0 1 29.673-29.674z","b":[61.5,25.3,389.0,469.4]},{"n":"microscope-lens","d":"M229.28 21.97v39.75c-30.905 1.29-61.546 9.284-89.53 23.905l21.406 37.063C184.2 110.92 210.32 104.28 238 104.28c93.408 0 168.938 75.53 168.938 168.94 0 26.766-6.234 52.056-17.282 74.53l-5.97-2.563-26.467-12.437c-21.125 44.53-66.495 75.313-119.064 75.313-8.49 0-16.8-.778-24.844-2.313l-7.375 33.375C127.89 424.178 69.03 355.665 69.03 273.22c0-26.843 6.267-52.2 17.376-74.72l-37.312-21.53c-40.207 78.3-28.27 175.748 33.937 242.093l-31.124 31.125 13.22 13.218L116.53 412c24.013 21.04 53.516 35.934 86.064 42.28l-6.938 31.44c1.515.333 3.016.636 4.53.936.01.002.023-.002.033 0 6.05 1.198 12.11 2.15 18.155 2.813.01 0 .02-.002.03 0 3.02.33 6.053.58 9.064.78 4.53.3 9.056.458 13.56.47 25.954.06 51.352-4.64 75.095-13.564 2.363-.888 4.734-1.81 7.063-2.78 9.477-3.953 18.656-8.6 27.468-13.876 2.518-1.508 5.014-3.076 7.47-4.688 1.227-.805 2.444-1.605 3.655-2.437 2.424-1.663 4.802-3.39 7.158-5.156 8.243-6.18 16.06-12.97 23.375-20.345 2.09-2.107 4.15-4.268 6.156-6.47 1.007-1.105 1.98-2.213 2.967-3.342.977-1.118 1.952-2.235 2.907-3.375.005-.007-.005-.026 0-.032.954-1.14 1.912-2.275 2.844-3.437.005-.008-.006-.026 0-.033.936-1.168 1.867-2.34 2.78-3.53 2.748-3.582 5.375-7.252 7.907-11.032.842-1.257 1.682-2.502 2.5-3.78 1.912-2.992 3.734-6.052 5.5-9.158l36.688 15.782 7.375-17.158-66.032-28.437c11.786-24.18 18.458-51.308 18.563-79.97h28.06c0-16.67-1.963-33.12-5.75-49.06L485.657 220l-2.187-18.563-43.876 5.188c-11.17-33.444-30.614-63.935-57-88.406-24.59-22.81-53.15-38.68-83.25-47.72L309.5 32.625l-18.03-4.844-10.22 38.126c-10.994-2.27-22.124-3.643-33.28-4.156V21.97h-18.69zM123.595 95c-10.347 6.634-20.245 14.223-29.53 22.813l30.28 30.312h.03c6.448-5.856 13.358-11.22 20.657-16.03L123.595 95zm-42.688 36.094c-8.512 9.367-15.998 19.302-22.53 29.656l37.187 21.47c4.692-7.334 9.95-14.283 15.687-20.782l-30.344-30.344zm83.688 61.062c-21.845 19.907-35.906 48.677-35.906 80.625 0 60.152 49.005 109.158 109.156 109.158 60.15 0 109.156-49.006 109.156-109.157h-18.688c0 50.038-40.43 90.47-90.468 90.47-50.037 0-90.47-40.432-90.47-90.47 0-26.47 11.628-50.238 29.814-66.81l-12.594-13.814zM239.25 215.5c-33.542 0-60.938 27.395-60.938 60.938 0 33.53 27.392 60.906 60.938 60.906 33.542 0 60.906-27.364 60.906-60.906 0-33.53-27.36-60.938-60.906-60.938zm0 18.688c23.443 0 42.22 18.82 42.22 42.25 0 5.505-1.05 10.754-2.94 15.562-3.377-10.958-13.59-18.906-25.655-18.906-14.82 0-26.844 12.023-26.844 26.844 0 7.082 2.736 13.516 7.22 18.312-20.575-2.883-36.25-20.418-36.25-41.813 0-23.446 18.803-42.25 42.25-42.25z","b":[8.9,22.0,476.8,468.8]},{"n":"periscope","d":"M340 49.5c-13.417 0-26.838 9.714-37.441 28.27C291.955 96.325 285 122.962 285 152.5c0 29.538 6.955 56.175 17.559 74.73 10.603 18.556 24.024 28.27 37.441 28.27h25.3c-5.383-5.51-10.208-12.057-14.368-19.338C338.372 214.182 331 184.818 331 152.5c0-32.318 7.372-61.682 19.932-83.662 4.16-7.28 8.985-13.828 14.369-19.338zm64 0c-13.417 0-26.838 9.714-37.441 28.27C355.955 96.325 349 122.962 349 152.5c0 29.538 6.955 56.175 17.559 74.73 10.603 18.556 24.024 28.27 37.441 28.27 13.417 0 26.838-9.714 37.441-28.27C452.045 208.675 459 182.038 459 152.5c0-29.538-6.955-56.175-17.559-74.73C430.838 59.214 417.417 49.5 404 49.5zm-264 16s-22.121.124-43.975 11.05C74.172 87.478 53 107.5 53 152.5v147.611c47.27 12.252 96.213 15.314 150 .475V280.5c0-19.131 11.354-31.107 21.813-36.117 10.458-5.01 20.59-4.883 20.59-4.883h43.523a110.13 110.13 0 0 1-1.994-3.338C274.372 214.182 267 184.818 267 152.5c0-32.318 7.372-61.682 19.932-83.662a110.128 110.128 0 0 1 1.994-3.338zm264 6c7.154 0 13.646 3.366 18.66 8.139 5.015 4.772 8.951 11.004 12.192 18.295C441.332 112.516 445 131.537 445 152.5s-3.668 39.984-10.148 54.566c-3.24 7.291-7.177 13.523-12.192 18.295-5.014 4.773-11.506 8.139-18.66 8.139s-13.646-3.366-18.66-8.139c-5.015-4.772-8.951-11.004-12.192-18.295C366.668 192.484 363 173.463 363 152.5s3.668-39.984 10.148-54.566c3.24-7.291 7.177-13.523 12.192-18.295 5.014-4.773 11.506-8.139 18.66-8.139zm23.791 65c-3.009 25.403-16.681 46.548-39.33 65.404 5.38 4.034 18.735 25.963 32.242-2.808 10.666-22.719 10.624-44.987 7.088-62.596zM53 318.664v56.842c3.709-.647 7.385-1.006 11-1.006 21.913 0 38.554 13.963 53.61 25.963 15.055 12 28.526 22.037 42.39 22.037s27.335-10.037 42.39-22.037c.2-.16.41-.324.61-.484v-80.786c-53.528 13.78-103.133 10.964-150-.529zM64 396.5c-14.96 0-30.967 6.068-46 13.836v20.623c16.602-9.085 34.645-16.459 46-16.459 13.864 0 27.335 10.037 42.39 22.037 15.056 12 31.697 25.963 53.61 25.963s38.554-13.963 53.61-25.963c15.055-12 28.526-22.037 42.39-22.037s27.335 10.037 42.39 22.037c15.056 12 31.697 25.963 53.61 25.963s38.554-13.963 53.61-25.963c15.055-12 28.526-22.037 42.39-22.037 11.355 0 29.398 7.374 46 16.459v-20.623c-15.033-7.768-31.04-13.836-46-13.836-21.913 0-38.554 13.963-53.61 25.963-15.055 12-28.526 22.037-42.39 22.037s-27.335-10.037-42.39-22.037c-15.056-12-31.697-25.963-53.61-25.963s-38.554 13.963-53.61 25.963c-15.055 12-28.526 22.037-42.39 22.037s-27.335-10.037-42.39-22.037c-15.056-12-31.697-25.963-53.61-25.963z","b":[18.0,49.5,476.0,413.0]},{"n":"photo-camera","d":"M41 122.496v14h62v-14zm154.73 0l-32 32H137v46h30.682C192.4 159.898 237.08 132.738 288 132.738c50.92 0 95.6 27.16 120.318 67.758H487v-46h-74.73l-32-32c-92.27-9-92.27-9-184.54 0zM288 150.738c-67.903 0-122.758 54.855-122.758 122.758 0 67.903 54.855 122.758 122.758 122.758 67.903 0 122.758-54.855 122.758-122.758 0-67.903-54.855-122.758-122.758-122.758zm-263 3.758v46h94v-46zm263 14.713c57.49 0 104.287 46.796 104.287 104.286S345.49 377.783 288 377.783c-57.49 0-104.287-46.797-104.287-104.287 0-57.49 46.797-104.287 104.287-104.287zm-21.787 22.042c-12.173.42-25.717 6.526-36.78 16.578-20.025 18.19-26.342 43.853-14.11 57.318 12.232 13.465 38.38 9.634 58.406-8.558 20.023-18.192 26.34-43.855 14.108-57.32-5-5.504-12.62-8.33-21.625-8.018zM25 218.496v142h94v-142zm112 0v142h40.412c-18.888-23.96-30.17-54.183-30.17-87 0-19.507 3.988-38.096 11.188-55zm280.57 0c7.2 16.904 11.188 35.493 11.188 55 0 32.817-11.282 63.04-30.17 87H487v-142zM25 378.496v14h94v-14zm112 0v14h75.89c-6.567-4.158-12.763-8.846-18.536-14zm244.646 0c-5.773 5.154-11.97 9.842-18.535 14H487v-14z","b":[25.0,113.5,462.0,282.8]},{"n":"spectacle-lenses","d":"M130.594 154.72c-61.166 0-110.938 49.77-110.938 110.936 0 61.166 49.772 110.97 110.938 110.97 53.164 0 97.746-37.617 108.5-87.626 6.047-7.977 19.177-8.658 25.687-.25 10.653 50.135 55.28 87.875 108.533 87.875 61.165 0 110.968-49.803 110.968-110.97 0-61.164-49.802-110.936-110.967-110.936-49.837 0-92.113 33.05-106.063 78.374-4.824-2.243-10.104-3.353-15.375-3.313-5.212.04-10.417 1.182-15.156 3.407-13.93-45.373-56.255-78.468-106.126-78.468zm0 18.686c51.065 0 92.28 41.185 92.28 92.25 0 18.84-5.604 36.323-15.25 50.906C174.24 278.926 89.67 273.28 56.44 320.625c-11.372-15.344-18.094-34.346-18.094-54.97 0-13.146 2.73-25.633 7.656-36.936 6.1 6.33 16.664 10.53 28.688 10.53 18.895 0 34.218-10.34 34.218-23.094 0-12.752-15.323-23.094-34.22-23.094-.39 0-.768.023-1.155.032 15.688-12.342 35.49-19.688 57.064-19.688zm242.72 0c51.064 0 92.28 41.185 92.28 92.25 0 18.84-5.605 36.323-15.25 50.906-33.393-37.626-117.96-43.28-151.188 4.063-11.372-15.344-18.094-34.346-18.094-54.97 0-13.146 2.73-25.633 7.657-36.936 6.1 6.33 16.663 10.53 28.686 10.53 18.896 0 34.22-10.34 34.22-23.094 0-12.752-15.324-23.094-34.22-23.094-.39 0-.77.023-1.156.032 15.687-12.342 35.488-19.688 57.063-19.688zm-121.47 74.875c4.08-.08 8.18 1.3 11.312 4.25-.51 4.312-.78 8.68-.78 13.126v.03c-3.408-.997-6.962-1.494-10.5-1.467-3.488.025-6.97.584-10.314 1.592v-.156c0-4.392-.28-8.708-.78-12.97 2.986-2.802 7.012-4.325 11.062-4.405z","b":[19.7,154.7,464.6,221.9]},{"n":"telescope","d":"M275.3 19.02c-1 0-1.6.19-1.9.37-.5.35-1.5 1.93-.9 6.16.7 4.17 3.4 9.96 8 15.36 4.6 5.4 10.1 9.2 14.3 10.81 4.4 1.55 6.3 1.04 6.8.69.5-.35 1.5-1.93.9-6.16-.7-4.17-3.4-9.96-8-15.36-4.6-5.4-10.1-9.2-14.3-10.81-2.2-.78-3.8-1.04-4.9-1.06zM404.4 35.2c-.7.1-1.1.24-1.5.45-.7.42-1.5 1.25-2.2 3.91-.7 2.75-.9 6.99-.1 12.13.5 3.22 1.4 6.85 2.5 10.63a35.08 13.15 58.61 0 1 3.2-8.44 35.08 13.15 58.61 0 1 29.5 23.09 35.08 13.15 58.61 0 1 7 36.83 35.08 13.15 58.61 0 1-8.8-1c2.8 2.7 5.6 5.2 8.2 7 4.2 3.1 8.1 4.8 10.8 5.5 2.7.6 3.8.2 4.5-.2.7-.4 1.4-1.2 2.2-3.9.6-2.7.8-7 .1-12.1-1.5-10.32-6.6-24.17-14.9-37.74-8.2-13.57-18.2-24.35-26.7-30.41-4.2-3.05-8.1-4.79-10.8-5.45-1.3-.29-2.3-.36-3-.3zm-146.6 3.98-10 8.93c-.2.17-.6.3.4 3.65s3.9 8.19 7.5 12.28 8.1 7.46 11.3 8.85c3.2 1.37 3.3.98 3.4.84l10.6-9.49c-5.5-3.2-10.6-7.54-15.1-12.85-3.4-3.95-6.1-8.05-8.1-12.21zm125.5 18.34-28.5 17.47c-1.8 1.1-2.8 2.36-3.6 4.83-.8 2.47-1 6.16-.5 10.59 1.2 8.87 5.7 20.39 12 30.79 6.3 10.4 14.5 19.7 21.9 24.8 3.6 2.5 7 3.9 9.6 4.4 2.5.4 4.1.1 5.9-1l28.4-17.4c-10.1-7.9-20-19.3-28.4-33.22-8.7-14.16-14.4-28.41-16.8-41.26zM234.6 65.3l-48.5 49.9-.2.2c-1.3 1.2-1.4 1.6-1.2 3.2.2 1.6 1.3 4.1 3.1 6.2 1.8 2 4.2 3.4 5.8 3.8 1.6.4 2.1.4 3.6-.9l.2-.2 54.7-42.54c-3.6-2.55-6.8-5.62-9.8-8.98-3-3.31-5.6-6.89-7.7-10.68zm98.9 30.96L214.7 181.1l-.3.2c-15.4 9.4-3 38.2 13 45L169 489l17.6 4 34.3-154.3 63.2 31.5 12.8 121.7 17.9-1.8-13.1-123.9 44.9-27.9 47.6 143.9 17-5.6-90-271.8-16.1 8.3 35.6 107.6-41.1 25.6-13-123.6-17.1 8.8L281.9 349l-57-28.5 21.7-97.4 124.8-64.6c-7.1-5.4-13.5-12.5-19.1-20.4l-45 27.4-9.4-15.4 45-27.4c-4.4-8.6-7.8-17.6-9.4-26.44zm-90.9 18.94-14.1 10.9 11.7 14.7 14.5-10.4zm-52.4 87.4L74.44 287.5l-.33.2c-4.7 2.8 4.27 17.4 8.94 14.6l.29-.2 128.16-64.5c-10.8-8.3-18.9-21.6-21.3-35zM65.44 221.9c-3.46.2-7.08 2.2-9.92 5.1-2.16 2.2-3.41 4.8-3.65 6.3-.25 1.4-.3 1.5.82 2.6l.12.1 26.11 25.8 21.98-16.1-30.59-22.9c-1.07-.5-2.21-.9-3.4-.9z","b":[51.6,19.0,408.9,474.0]},{"n":"theater","d":"M32 32v224h448V32H32zm50.68 289.7c-14.05 0-24.17 1-30.73 3-6.57 2-9.44 4.3-11.93 8.6-1.46 2.5-2.56 6.2-3.41 10.9 4.88.7 9.36 1.5 13.48 2.8 10 3 18.17 9 23.1 17.3C78.12 356 86.27 350 96.27 347c8.93-2.7 19.43-3.8 32.43-4-.8-4.2-1.8-7.4-3.2-9.7-2.5-4.3-5.4-6.6-12-8.6s-16.74-3-30.82-3zm115.52 0c-14.1 0-24.2 1-30.7 3-6.6 2-9.5 4.3-12 8.6-1.4 2.4-2.5 5.8-3.3 10.3 7.5.6 14 1.6 19.8 3.4 10 3 18.2 8.9 23.1 17.3 4.9-8.4 13-14.3 23.1-17.3 7.4-2.3 15.9-3.4 26-3.8-.8-4.2-1.8-7.5-3.2-9.9-2.5-4.3-5.4-6.6-12-8.6s-16.7-3-30.8-3zm115.5 0c-14.1 0-24.2 1-30.7 3-6.6 2-9.5 4.3-12 8.6-1.4 2.4-2.4 5.7-3.2 9.9 10.1.4 18.7 1.5 26.1 3.8 10 3 18.2 8.9 23.1 17.3 4.9-8.4 13-14.3 23.1-17.3 5.8-1.8 12.3-2.8 19.7-3.4-.8-4.5-1.9-7.9-3.3-10.3-2.5-4.3-5.4-6.6-12-8.6s-16.7-3-30.8-3zm115.5 0c-14.1 0-24.2 1-30.7 3-6.6 2-9.5 4.3-12 8.6-1.4 2.3-2.4 5.5-3.2 9.7 13.1.2 23.6 1.3 32.5 4 10 3 18.2 8.9 23.1 17.3 4.9-8.4 13-14.3 23.1-17.3 4.1-1.3 8.6-2.1 13.4-2.8-.8-4.7-1.9-8.4-3.4-10.9-2.5-4.3-5.4-6.6-12-8.6s-16.7-3-30.8-3zM134.1 361c-14.9 0-25.6 1-32.6 3.2-6.99 2.1-10.17 4.6-12.88 9.4-2.53 4.4-4.06 11.8-5 22.3 10.74.4 19.68 1.4 27.38 3.8 10 3 18.2 8.9 23.1 17.3 4.9-8.4 13-14.3 23.1-17.3 7.7-2.4 16.7-3.5 27.5-3.8-1-10.5-2.5-17.9-5-22.3-2.7-4.7-5.9-7.3-13-9.4-7-2.2-17.7-3.2-32.6-3.2zm121.9 0c-14.9 0-25.6 1-32.6 3.2-7 2.1-10.2 4.6-12.9 9.4-2.5 4.4-4 11.8-5 22.3 10.8.4 19.7 1.4 27.4 3.8 10 3 18.2 8.9 23.1 17.3 4.9-8.4 13-14.3 23.1-17.3 7.7-2.4 16.7-3.5 27.5-3.8-1-10.5-2.5-17.9-5-22.3-2.7-4.7-5.9-7.3-13-9.4-7-2.2-17.7-3.2-32.6-3.2zm121.9 0c-14.9 0-25.6 1-32.6 3.2-7 2.1-10.2 4.6-12.9 9.4-2.5 4.4-4 11.8-5 22.3 10.8.4 19.7 1.4 27.4 3.8 10 3 18.2 8.9 23.1 17.3 4.9-8.4 13-14.3 23.1-17.3 7.7-2.4 16.7-3.5 27.5-3.8-1-10.5-2.5-17.9-5-22.3-2.7-4.7-5.9-7.3-13-9.4-7-2.2-17.7-3.2-32.6-3.2zm-359.9.1v48.5c4.64-4.5 10.54-7.9 17.28-9.9 7.76-2.4 16.72-3.5 27.49-3.8-.93-10.5-2.48-17.9-5-22.3-2.71-4.7-5.9-7.3-12.93-9.4-6.07-1.9-14.94-2.9-26.84-3.1zm476 0c-11.9.2-20.8 1.2-26.8 3.1-7 2.1-10.2 4.6-12.9 9.4-2.5 4.4-4 11.8-5 22.3 10.8.4 19.7 1.4 27.4 3.8 6.7 2 12.6 5.4 17.3 9.9v-48.5zM73.1 413.7c-14.84 0-25.56 1-32.56 3.2-7.01 2.1-10.18 4.6-12.89 9.4-4.93 8.6-6.15 28.5-6.33 60.7H125c-.2-32.2-1.4-52.1-6.3-60.7-2.7-4.7-5.9-7.3-13-9.4-6.98-2.2-17.72-3.2-32.6-3.2zm121.9 0c-14.9 0-25.6 1-32.6 3.2-7 2.1-10.2 4.6-12.9 9.4-4.9 8.6-6.1 28.5-6.3 60.7h103.7c-.2-32.2-1.4-52.1-6.3-60.7-2.7-4.7-5.9-7.3-13-9.4-7-2.2-17.7-3.2-32.6-3.2zm121.9 0c-14.9 0-25.6 1-32.6 3.2-7 2.1-10.2 4.6-12.9 9.4-4.9 8.6-6.1 28.5-6.3 60.7h103.7c-.2-32.2-1.4-52.1-6.3-60.7-2.7-4.7-5.9-7.3-13-9.4-7-2.2-17.7-3.2-32.6-3.2zm121.9 0c-14.8 0-25.6 1-32.6 3.2-7 2.1-10.2 4.6-12.9 9.4-4.9 8.6-6.1 28.5-6.3 60.7h103.7c-.2-32.2-1.4-52.1-6.3-60.7-2.7-4.7-5.9-7.3-13-9.4-7-2.2-17.7-3.2-32.6-3.2z","b":[18.0,32.0,476.0,455.0]},{"n":"theater-curtains","d":"M18 18v94.275c28.382-12.57 52.994-35.202 71.39-59.734-4.662-3.466-8.973-7.064-12.865-10.79C68.903 34.452 62.723 26.51 58.973 18zm61.754 0c2.378 3.508 5.41 7.103 9.22 10.75 10.73 10.274 26.505 20.414 44.88 29.117C170.602 75.274 217.8 87 256 87s85.398-11.726 122.146-29.133c18.375-8.703 34.15-18.843 44.88-29.117 3.81-3.647 6.842-7.242 9.22-10.75zm373.273 0c-3.75 8.51-9.93 16.452-17.552 23.75-3.892 3.726-8.203 7.324-12.864 10.79 18.396 24.533 43.008 47.166 71.39 59.735V18zm-82.554 16.734C354.78 52.937 308.428 65.326 256 65.33c-52.242-.023-98.44-12.343-114.236-30.463C168.982 45.655 211.206 51.987 256 52c44.953-.022 87.294-6.408 114.473-17.266zM104.785 62.78C83.37 91.92 53.765 118.415 18 131.788v174.035c2.116.805 4.112 1.178 6 1.178 8.312-.646 12.295-5.132 18.324-9.984 29.568-24.024 49.255-66.27 65.053-119.094 9.187-30.72 17.136-64.91 25.34-100.78-2.216-.986-4.41-1.986-6.57-3.01-7.512-3.557-14.67-7.346-21.362-11.35zm302.43 0c-6.693 4.006-13.85 7.795-21.36 11.353-2.162 1.023-4.356 2.023-6.572 3.008 8.204 35.872 16.153 70.062 25.34 100.782 15.798 52.825 35.485 95.07 65.053 119.094 5.414 4.648 11.22 9.89 18.324 9.984 1.888 0 3.884-.373 6-1.178V131.787c-35.764-13.373-65.37-39.87-86.785-69.006zM46.13 317.34C39.233 322.193 31.793 325 24 325c-2.025 0-4.026-.197-6-.564v123.2c6.273 2.01 14.098 3.364 22 3.364 12.41 0 24.637-3.336 30.94-7.316-.04-43.556-.973-88.042-24.81-126.344zm419.74 0c-23.837 38.302-24.77 82.788-24.81 126.344 6.303 3.98 18.53 7.316 30.94 7.316 7.902 0 15.727-1.353 22-3.363v-123.2c-1.974.366-3.975.563-6 .563-7.792 0-15.232-2.807-22.13-7.66zM88.39 409c.6 13.277.61 26.37.61 39v3.73l-2.637 2.633C75.18 465.545 57.5 469 40 469c-7.475 0-14.98-.636-22-2.232V487h476v-20.232c-7.02 1.596-14.525 2.232-22 2.232-17.5 0-35.18-3.455-46.363-14.637L423 451.73V448c0-12.63.01-25.723.61-39z","b":[18.0,18.0,476.0,469.0]},{"n":"vhs","d":"M41.88 93.6c-5.52 0-10 4.5-10 10v38.6c0 9.2 7.47 16.7 16.67 16.7v-28.2H463.4v28.2h.1c9.2 0 16.6-7.5 16.6-16.7v-38.6c0-5.5-4.5-10-10-10H41.88zm21.34 53.2v26.7h-31v210.7c0 5.6 4.48 10 10 10H469.8c5.5 0 10-4.4 10-10V173.5h-31v-26.7H63.22zm-13.39 51H462.2v136.4H49.83V197.8zm34.44 16.6c-11.17 15.1-17.78 33.7-17.78 53.9 0 18.2 5.35 35.1 14.56 49.3h58.05v-9.1c-15.3-6.9-26-22.3-26-40.2 0-17.8 10.7-33.2 26-40.1v-13.8H84.27zm71.53 0v103.2h200.4V214.4H155.8zm217.1 0v13.8c15.3 6.9 26 22.3 26 40.1 0 17.9-10.7 33.3-26 40.2v9.1H431c9.2-14.2 14.5-31.1 14.5-49.3 0-20.2-6.6-38.8-17.8-53.9h-54.8zm-233.8 33.4c-5.7 5-9.3 12.3-9.3 20.5s3.6 15.6 9.3 20.6v-41.1zm233.8 0v41.1c5.7-5 9.3-12.4 9.3-20.6 0-8.2-3.6-15.5-9.3-20.5z","b":[31.9,93.6,448.2,300.6]},{"n":"video-camera","d":"M53.15 117.516l-30.803 41.443 17.332 3.5 21.82-29.357zm344.355 16.125c-12.346.048-23.357.238-33.852.336v34.18c23.779.22 54.2 1.112 80.252-1.06 14.555-1.212 27.448-3.51 35.627-6.814 4.09-1.651 6.896-3.533 8.338-5.07 1.442-1.537 1.783-2.397 1.783-4.147 0-1.75-.341-2.61-1.783-4.146-1.442-1.537-4.248-3.419-8.338-5.07-8.179-3.304-21.072-5.602-35.627-6.815-14.554-1.213-30.773-1.455-46.4-1.394zm-111.668 8.425l-32 48h21.633l20-30h50.183v-18zM73.985 146.48L56.09 170.557l82.668 61.441c4.615 3.43 8.257 3.851 11.72 3.13 3.464-.72 6.88-3.011 9.266-6.222 2.386-3.21 3.594-7.141 3.285-10.666-.309-3.524-1.762-6.89-6.377-10.32zm104.87 61.586c1.14 2.815 1.852 5.715 2.105 8.602.22 2.512.128 4.988-.227 7.398H291.39c3.52-1.292 7.315-2 11.263-2 18.12 0 33 14.882 33 33 0 5.391-1.324 10.49-3.652 15h29.652v64h-254V231.31l-16-11.891v130.648h263c5 0 11.051-2.777 15.637-7.363s7.363-10.637 7.363-15.637V235.88l-41.662-27.813zm310.798 2.528l-46 11.5v113.945l46 11.5zm-187 29.472c-8.39 0-15 6.61-15 15 0 8.391 6.61 15 15 15 8.391 0 15-6.609 15-15 0-8.39-6.609-15-15-15zm93 0v78h30v-78zm-223.431 2c-4.633 5.23-10.836 9.18-18.08 10.686-8.326 1.731-17.897-.192-26.123-6.307l-2.366-1.757v71.378h60v-46h87.653a32.623 32.623 0 0 1-3.653-15c0-4.606.965-9.003 2.698-13zm31.431 46v28h140v-28h-41zm-52.183 80l-17.614 26.418c62.625-10.657 116.488-11.084 168.956-.957l-16.975-25.46z","b":[22.3,117.5,467.3,277.0]},{"n":"game-console","d":"M192.615 41l-4.375 14h135.518l-4.375-14zM185 73v73.102c46.991 6.329 94.285 6.5 142 .008V73zm-83.777 32l-53.715 94h416.984l-53.715-94H345v4.615c1.065.187 2.134.375 3.168.569 11.99 2.248 21.832 4.882 29.42 8.246 3.794 1.681 7.063 3.505 9.892 6.097 2.83 2.593 5.52 6.574 5.52 11.473 0 4.9-2.69 8.88-5.52 11.473-2.829 2.592-6.098 4.415-9.892 6.097-7.588 3.364-17.43 5.998-29.42 8.246C324.19 166.312 291.802 169 256 169l-.361-.002c-35.658-.018-67.91-2.7-91.807-7.182-11.99-2.248-21.832-4.882-29.42-8.246-3.794-1.682-7.063-3.505-9.892-6.097-2.83-2.593-5.52-6.574-5.52-11.473 0-4.9 2.69-8.88 5.52-11.473 2.829-2.592 6.098-4.416 9.892-6.097 7.588-3.364 17.43-5.998 29.42-8.246 1.034-.194 2.103-.382 3.168-.569V105zM167 127.904c-11.103 2.09-19.95 4.615-25.293 6.983-1.026.455-1.18.695-1.922 1.113.742.418.896.658 1.922 1.113 5.342 2.368 14.19 4.893 25.293 6.983zm178 0v16.192c11.103-2.09 19.95-4.615 25.293-6.983 1.026-.455 1.18-.695 1.922-1.113-.742-.418-.896-.658-1.922-1.113-5.342-2.368-14.19-4.893-25.293-6.983zM96 167h64v18H96zm256 0h64v18h-64zM41 217v94h67.885c8.05 13.442 17.974 26.493 31.09 33.05 52.212 26.107 135.093 19.044 205.59 14.102 35.248-2.47 67.397-4.617 89.683-2.859 11.143.879 19.762 2.88 24.49 5.34 4.728 2.46 5.543 3.69 5.584 7.465.098 9.007-1.966 13.353-5.138 16.345-3.173 2.993-8.698 5.159-17.172 5.948-16.949 1.577-43.677-2.843-74.133-7.547-57.137-8.826-129.198-18.381-187.076 18.156h43.316c44.854-13.696 96.046-7.313 141.012-.367 30.24 4.671 57.148 9.671 78.549 7.68 10.7-.996 20.528-3.861 27.857-10.776 7.33-6.915 10.916-17.353 10.783-29.635-.109-10.108-6.73-18.79-15.273-23.236-8.544-4.445-19.032-6.342-31.385-7.316-24.705-1.949-57.098.376-92.355 2.847-70.515 4.943-152.494 9.646-196.282-12.248-5.03-2.515-11.183-8.969-17.113-16.949H471v-94zm14 14h82v66h-15.354a167.839 167.839 0 0 1-3.373-5.973A268.087 268.087 0 0 1 112.211 279H119v-30H73v30h19.418a305.46 305.46 0 0 0 8.674 18H55v-57zm107.168 0h82v66h-82v-57zm106.592 0h82v66h-82v-57zM375 231h82v66h-82v-57zm-194.832 18v30h46v-30zm106.592 0v30h46v-30zM393 249v30h46v-30zM110 419c-3.875 0-6.759 2.192-9.902 8.676C96.954 434.16 95 444.09 95 454c0 9.91 1.954 19.84 5.098 26.324C103.24 486.808 106.125 489 110 489h144c3.875 0 6.759-2.192 9.902-8.676C267.046 473.84 269 463.91 269 454c0-9.91-1.954-19.84-5.098-26.324C260.76 421.192 257.875 419 254 419zm118.104 10a9 9 0 1 1 0 18 9 9 0 0 1 0-18zM125 432h18v13h13v18h-13v13h-18v-13h-13v-18h13zm87.104 13a9 9 0 1 1 0 18 9 9 0 0 1 0-18zm32 0a9 9 0 1 1 0 18 9 9 0 0 1 0-18zm-16 13.637a9 9 0 1 1 0 18 9 9 0 0 1 0-18z","b":[41.0,41.0,442.5,448.0]},{"n":"gamepad","d":"M155.084 125.945c-.46 0-.926.01-1.397.034-5.646.285-12.097 2.464-20.707 8.204-21.824 14.55-51.912 60.395-67.834 110.005-15.92 49.61-18.046 102.25 5.936 132.966 4.142 5.306 13.387 8.93 23.756 8.846 10.216-.084 20.682-3.838 26.482-9.44 1.022-1.47 9.296-13.336 21.39-27.404 12.863-14.96 28.716-31.686 45.835-38.777 41.863-17.34 93.024-17.34 134.887 0 17.118 7.092 32.97 23.818 45.834 38.778 12.095 14.068 20.37 25.933 21.39 27.404 5.8 5.602 16.267 9.356 26.483 9.44 10.368.085 19.612-3.54 23.755-8.846 23.973-30.704 21.885-83.575 5.978-133.287-15.907-49.713-46.054-95.526-67.783-109.624-11.498-7.46-19.198-8.73-26.285-7.64-7.088 1.093-14.347 5.197-22.866 11.07-17.038 11.746-38.898 30.02-73.952 30.02-35.212 0-57.115-18.514-74.13-30.356-8.505-5.92-15.73-10.025-22.743-11.078-1.315-.198-2.65-.312-4.03-.317zm212.904 48.75a16 16 0 0 1 16 16 16 16 0 0 1-16 16 16 16 0 0 1-16-16 16 16 0 0 1 16-16zM135 183h18v32h32v18h-32v32h-18v-32h-32v-18h32v-32zm200.988 23.695a16 16 0 0 1 16 16 16 16 0 0 1-16 16 16 16 0 0 1-16-16 16 16 0 0 1 16-16zm64 0a16 16 0 0 1 16 16 16 16 0 0 1-16 16 16 16 0 0 1-16-16 16 16 0 0 1 16-16zm-32 32a16 16 0 0 1 16 16 16 16 0 0 1-16 16 16 16 0 0 1-16-16 16 16 0 0 1 16-16zm-160 7h32v18h-32v-18zm64 0h27.897v18h-27.897v-18z","b":[47.1,125.5,417.8,260.6]},{"n":"gamepad-cross","d":"M176.938 24.03V75.44c-52.96 6.715-94.96 48.652-101.72 101.593H24.564v160.096h50.75c7.034 52.62 48.895 94.247 101.624 100.938V489.5H337v-51.374c53.01-6.453 95.158-48.183 102.22-101h50.811V177.03h-50.717C432.526 123.893 390.238 81.85 337 75.376V24.03H176.938zm18.687 18.69h122.688v139.75L257.25 243.5l-61.625-61.625V42.72zm61.656 17.436c-24.524 0-44.405 19.88-44.405 44.407 0 24.525 19.88 44.406 44.406 44.406 24.524 0 44.376-19.882 44.376-44.407 0-24.526-19.85-44.407-44.375-44.407zM43.25 195.72h139.78l61.032 61.03-61.718 61.688H43.25v-122.72zm288.25 0h139.844v122.718H332.188L270.5 256.75l61-61.03zm-226.406 16.624c-24.525 0-44.406 19.88-44.406 44.406 0 24.525 19.88 44.406 44.406 44.406 24.525 0 44.406-19.88 44.406-44.406 0-24.523-19.88-44.406-44.406-44.406zm304.344 0c-24.526 0-44.407 19.88-44.407 44.406 0 24.525 19.882 44.406 44.408 44.406 24.525 0 44.406-19.88 44.406-44.406 0-24.523-19.88-44.406-44.406-44.406zM257.25 269.938L318.313 331v139.813H195.625v-139.22l61.625-61.656zm.03 94.562c-24.524 0-44.405 19.88-44.405 44.406 0 24.525 19.88 44.406 44.406 44.406 24.524 0 44.376-19.88 44.376-44.406 0-24.525-19.85-44.406-44.375-44.406z","b":[24.6,24.0,465.5,465.5]},{"n":"joystick","d":"M307.723 39.623c-25.627-.292-48.63 17.365-54.246 43.44-6.418 29.8 12.39 58.93 42.19 65.347 29.798 6.417 58.927-12.39 65.345-42.19 6.417-29.798-12.39-58.928-42.188-65.345-3.725-.802-7.44-1.21-11.1-1.252zm-37.543 117.88L237.123 311h47.055l30.97-143.81c-7.584.836-15.418.507-23.27-1.184-7.854-1.69-15.13-4.617-21.698-8.502zM198.486 329l-10 30h135.028l-10-30H198.486zM73 377v30h30v-30H73zm93.486 0l-10 30h199.028l-10-30H166.486zM409 377v30h30v-30h-30zM57 425v62h398v-62H57z","b":[57.0,39.3,398.0,447.7]},{"n":"play-button","d":"M106.854 106.002a26.003 26.003 0 0 0-25.64 29.326c16 124 16 117.344 0 241.344a26.003 26.003 0 0 0 35.776 27.332l298-124a26.003 26.003 0 0 0 0-48.008l-298-124a26.003 26.003 0 0 0-10.136-1.994z","b":[81.2,106.0,333.8,298.0]},{"n":"retro-controller","d":"M389.094 253.12H122.962a101.945 101.945 0 1 0 89.208 151.258h87.66a101.945 101.945 0 1 0 89.264-151.258zM165.69 362.62h-30.137v30.138h-31.618V362.62h-30.14v-31.618h30.13v-30.128h31.617v30.128h30.15v31.618zm190.996 7.136a17.932 17.932 0 1 1 17.91-17.932 17.932 17.932 0 0 1-17.92 17.932zm40.922 40.923a17.932 17.932 0 1 1 17.92-17.922 17.932 17.932 0 0 1-17.93 17.92zm0-81.858a17.932 17.932 0 1 1 17.932-17.932 17.932 17.932 0 0 1-17.943 17.944zm40.923 40.923a17.932 17.932 0 1 1 17.933-17.932 17.932 17.932 0 0 1-17.932 17.943zM260.546 18.99h19.603c3.986 10.57 5.16 20.326 3.512 29.235-4.043 22.392-24.052 35.367-43.44 47.912-21.625 14.025-42.04 27.282-40.472 52.204 1.694 26.9 18.407 40.89 36.135 55.705 10.682 8.943 21.997 18.417 29.36 31.008h-22.2c-5.218-5.816-11.688-11.292-18.746-17.153-18.914-15.81-40.346-33.786-42.537-68.42-2.258-35.467 24.843-53.015 48.67-68.497 16.88-10.942 32.814-21.342 35.513-36.02 1.377-7.34-.407-15.923-5.398-25.973z","b":[73.8,19.0,382.7,391.7]},{"n":"screen-impact","d":"M340.625 18.438l-42.438 104.657-39.562-99.938L213.25 157l-75.97-54.78 14.22 92.53L24.53 27l108.095 202.032-72.094-36.344 59.532 171.188-88.906-12.53 55.25 72.06-52.47-12.03 103.626 78.75 1.875 2.47h240.188l110.28-151.376-52.03 5.468 56.406-67.562-71.718 36.03L459.97 203.22l-54.783 24.625-88.75 67.843 54.282-78.25 18.936-116.343-57.75 37.562 8.72-120.22zM310.312 204.25L296.72 317.127l82.53-21.5-59.47 57.625L376.907 395l-77.437-12.905 36.092 75.75-67-39.313-40.593 50.375-3.72-57.97-70.063 5.783 70.063-37.313-77.53-79.28 75.124 18.56-8.375-84.75 51.405 87.5 45.437-117.186z","b":[24.5,18.4,469.8,474.2]},{"n":"tv","d":"M132.992 48.756l-9.984 14.976 77.287 51.524c4.32-4.192 9.542-8.012 15.703-11.162l-83.006-55.338zm246.016 0l-83.006 55.338c6.16 3.15 11.383 6.97 15.703 11.162l77.287-51.524-9.984-14.976zM256 113.244c-22 0-35.334 7.06-43.637 15.363-4.703 4.704-7.58 9.97-9.316 14.637h105.906c-1.736-4.668-4.613-9.933-9.316-14.637-8.303-8.303-21.637-15.363-43.637-15.363zm-191.936 48c-5.044 0-11.106 2.784-15.697 7.37-4.59 4.584-7.367 10.63-7.367 15.63v279h430V184.2c.026-5.457-2.764-11.393-7.227-15.87-4.463-4.477-10.346-7.086-14.826-7.086H64.064zm30.295 23h257.745c10.374 0 20.79 6.818 26.776 16H112c-16 0-32 16-32 32v160c25.924-162.54 145.877-185.697 299.016-191.795 3.106 4.836 4.984 10.315 4.984 15.794v192c0 16-16 32-33.88 32H95.35c-15.35 0-31.35-16-31.35-32v-192c0-16 16-32 30.36-32zm328.663 7c13.7 0 25 11.3 25 25s-11.3 25-25 25-25-11.3-25-25 11.3-25 25-25zm-23.023 144h48v18h-48v-18zm0 32h48v18h-48v-18zm0 32h48v18h-48v-18z","b":[41.0,48.8,430.0,414.5]},{"n":"tv-remote","d":"M380.412 26.416L21 374.77l121.647 121.647L491 137.005c-44.235-66.353-44.235-66.353-110.588-110.589zm-.691 22.81l22.117 22.117-12.44 12.44-22.119-22.117zm66.353 66.352l22.117 22.118-12.441 12.44-22.118-22.117zM369.353 81.71c6.871 6.871 6.871 18.012 0 24.883-6.871 6.87-18.011 6.87-24.882 0-6.871-6.871-6.871-18.012 0-24.883 6.87-6.87 18.01-6.87 24.882 0zm33.176 33.177c6.871 6.871 6.871 18.011 0 24.882-6.87 6.871-18.01 6.871-24.882 0-6.871-6.87-6.871-18.011 0-24.882 6.871-6.871 18.011-6.871 24.882 0zm33.177 33.176c6.871 6.871 6.871 18.012 0 24.883-6.871 6.87-18.011 6.87-24.882 0-6.872-6.871-6.872-18.012 0-24.883 6.87-6.87 18.01-6.87 24.882 0zm-99.53-33.176c6.872 6.871 6.872 18.011 0 24.882-6.87 6.871-18.01 6.871-24.882 0-6.871-6.87-6.871-18.011 0-24.882 6.871-6.871 18.011-6.871 24.882 0zm33.177 33.176c6.871 6.871 6.871 18.012 0 24.883-6.871 6.87-18.011 6.87-24.882 0-6.871-6.871-6.871-18.012 0-24.883 6.87-6.87 18.01-6.87 24.882 0zm33.176 33.177c6.871 6.87 6.871 18.011 0 24.882-6.87 6.871-18.01 6.871-24.882 0-6.871-6.87-6.871-18.011 0-24.882 6.871-6.871 18.011-6.871 24.882 0zM303 148.063c6.871 6.871 6.871 18.012 0 24.883-6.871 6.87-18.011 6.87-24.882 0-6.871-6.871-6.871-18.012 0-24.883 6.87-6.87 18.01-6.87 24.882 0zm33.176 33.177c6.872 6.87 6.872 18.011 0 24.882-6.87 6.871-18.01 6.871-24.882 0-6.871-6.87-6.871-18.011 0-24.882 6.871-6.871 18.011-6.871 24.882 0zm33.177 33.176c6.871 6.871 6.871 18.012 0 24.883-6.871 6.87-18.011 6.87-24.882 0-6.871-6.871-6.871-18.012 0-24.883 6.87-6.87 18.01-6.87 24.882 0zm-114.735-40.088L279.5 199.21l-44.235 44.236-24.883-24.883zm63.588 63.588l24.882 24.883-44.235 44.235-24.882-24.882zm-69.118 30.412c10.299 10.298 16.352 23.318 18.181 36.821h-41.035a24.805 24.805 0 0 1 0 17.593h41.035c-1.83 13.503-7.882 26.523-18.18 36.821-10.3 10.299-23.32 16.352-36.822 18.182v-41.036a24.805 24.805 0 0 1-17.593 0v41.036c-13.503-1.83-26.523-7.883-36.821-18.182-10.298-10.298-16.352-23.318-18.181-36.821h41.036a24.805 24.805 0 0 1 0-17.593h-41.036c1.83-13.503 7.883-26.523 18.18-36.82 10.3-10.3 23.32-16.353 36.822-18.182v41.036a24.805 24.805 0 0 1 17.593 0v-41.036c13.503 1.83 26.523 7.883 36.821 18.181zM76.985 351.96l22.118 22.118-12.441 12.441-22.118-22.117zm33.177 33.177l22.117 22.118-12.44 12.44-22.118-22.117zm33.176 33.176l22.118 22.118-12.441 12.441-22.118-22.117z","b":[21.0,26.4,470.0,470.0]},{"n":"auto-repair","d":"M241.406 21l-15.22 34.75c-7.864.478-15.703 1.472-23.467 2.97l-23.282-30.064-25.094 8.532-.125 38.25c-10.63 5.464-20.817 12.07-30.44 19.78L88.313 79.25 70.156 98.563 88.312 133c-5.852 8.346-10.925 17.072-15.218 26.094l-38.938 1.062-7.906 25.28 31.438 23.158c-1.505 9.38-2.24 18.858-2.282 28.344L20.5 254.625l3.656 26.25 38.313 7.5c2.284 7.982 5.107 15.826 8.5 23.5L45.72 343.22l14.093 22.436 39.25-9.187c2.47 2.895 5.037 5.757 7.718 8.53 5.643 5.835 11.565 11.206 17.72 16.125l-7.625 39.313 22.938 13.25 29.968-26.094c8.606 3.462 17.435 6.23 26.407 8.312l9.782 38.406 26.405 2.157 15.875-36.22c10.97-.66 21.904-2.3 32.656-4.938l25.22 29.22 24.593-9.844-.72-14.813-57.406-43.53c-16.712 4.225-34.042 5.356-51.063 3.436-31.754-3.58-62.27-17.92-86.218-42.686-54.738-56.614-53.173-146.67 3.438-201.406 27.42-26.513 62.69-39.963 98-40.344 37.59-.406 75.214 13.996 103.438 43.187 45.935 47.512 52.196 118.985 19.562 173.095l31.97 24.25c3.997-6.28 7.594-12.75 10.75-19.375l38.655-1.063 7.906-25.28-31.217-23c1.513-9.457 2.262-19.035 2.28-28.594l34.688-17.625-3.655-26.25-38.28-7.5c-3.196-10.993-7.444-21.762-12.75-32.125l22.81-31.594-15.25-21.657-37.56 10.906c-.472-.5-.93-1.007-1.408-1.5-5.998-6.205-12.33-11.89-18.937-17.064l7.188-37.125L334 43.78l-28.5 24.814c-9.226-3.713-18.702-6.603-28.313-8.75l-9.343-36.688L241.406 21zM183.25 174.5c-10.344.118-20.597 2.658-30 7.28l45.22 34.314c13.676 10.376 17.555 30.095 7.06 43.937-10.498 13.85-30.656 15.932-44.53 5.408l-45.188-34.282c-4.627 24.793 4.135 51.063 25.594 67.344 19.245 14.597 43.944 17.33 65.22 9.688l4.78-1.72 4.03 3.063 135.19 102.564 4.03 3.062-.344 5.063c-1.637 22.55 7.59 45.61 26.844 60.217 21.46 16.28 49.145 17.63 71.78 6.5l-45.186-34.28c-13.874-10.526-17.282-30.506-6.78-44.344 10.5-13.84 30.537-15.405 44.217-5.032l45.188 34.283c4.616-24.784-4.11-51.067-25.563-67.344-19.313-14.658-43.817-17.562-64.968-10.033l-4.75 1.688-4.03-3.063-135.19-102.562-4.03-3.063.344-5.03c1.55-22.387-7.85-45.194-27.157-59.845-12.544-9.516-27.222-13.978-41.78-13.812zm43.563 90.25l163.875 124.344L379.406 404 215.5 279.625l11.313-14.875z","b":[20.5,21.0,474.5,477.1]},{"n":"battle-gear","d":"M262.406 17.188c-27.22 8.822-54.017 28.012-72.375 55.53 17.544 47.898 17.544 57.26 0 105.157 19.92 15.463 40.304 24.76 60.782 27.47-2.063-25.563-3.63-51.13 1.125-76.69-13.625-1.483-23.374-5.995-37-13.874V82.563c35.866 19.096 61.84 18.777 98.813 0v32.22c-13.364 6.497-21.886 11.16-35.25 13.218 3.614 25.568 3.48 51.15 1.375 76.72 18.644-3.265 37.236-12.113 55.5-26.845-14.353-47.897-14.355-57.26 0-105.156-16.982-28.008-47.453-46.633-72.97-55.532zm-129.594 8.218c-25.906 110.414-27.35 215.33-27.4 330.922-18.84-1.537-37.582-5.12-56.027-11.12v28.554h69.066c8.715 35.025 6.472 70.052-1.036 105.078h28.13c-7.195-35.026-8.237-70.053-.872-105.078h68.904v-28.555c-18.49 4.942-37.256 8.552-56.097 10.46.082-114.94 2.496-223.068-24.667-330.26zm89.47 202.375c0 117.27 25.517 233.342 120.155 257.97C446.62 464.716 462.72 345.374 462.72 227.78H222.28z","b":[49.4,17.2,413.3,468.6]},{"n":"big-gear","d":"M438.582 296.069l53.302-14.694-.024-50.728-53.278-14.743c-4.76-21.901-13.445-42.325-25.185-60.608l27.323-48.157-35.904-35.855-48.078 27.3C338.4 86.818 317.975 78.16 296.053 73.347l-14.746-53.224H230.64l-14.77 53.224c-21.874 4.813-42.324 13.472-60.61 25.235L107.13 71.284l-35.88 35.883 27.3 48.077c-11.74 18.336-20.401 38.76-25.236 60.66l-53.198 14.744v50.727l53.198 14.694a186.28 186.28 0 0 0 25.235 60.658l-27.298 48.157 35.88 35.83 48.128-27.274a186.217 186.217 0 0 0 60.66 25.186l14.72 53.25 50.693-.024 14.72-53.225c21.923-4.813 42.348-13.47 60.686-25.212l48.127 27.327 35.805-35.883-27.273-48.155c11.714-18.31 20.4-38.708 25.185-60.635zM200.588 122.394h110.819l78.333 78.358v9.207h-55.162c-15.844-26.933-45.134-45.051-78.582-45.051-33.445 0-62.735 18.118-78.578 45.051H122.23v-9.207zm55.408 88.542c24.88 0 45.072 20.196 45.072 45.052 0 24.929-20.19 45.1-45.072 45.1-24.872 0-45.068-20.17-45.068-45.1 0-24.856 20.196-45.052 45.068-45.052zm55.411 179.05H200.588l-78.357-78.358v-9.612h55.106a91.66 91.66 0 0 0 14.253 18.417c17.206 17.206 40.082 26.681 64.407 26.681 24.333 0 47.208-9.476 64.415-26.683a91.636 91.636 0 0 0 14.25-18.415h55.079v9.612z","b":[20.1,20.1,471.8,471.8]},{"n":"clockwork","d":"M137.71 18.326L17.866 138.166l29.582 29.582c23.04-53.698 66.14-96.802 119.84-119.842l-29.58-29.58zm238.286.04L346.44 47.92c53.693 23.048 96.79 66.155 119.822 119.857l29.576-29.575-119.842-119.84zm-133.27 37.04C137.405 62.64 54.448 150.126 54.448 257.31c0 111.93 90.466 202.397 202.398 202.397 32.75 0 63.66-7.757 91.007-21.52l-22.26-15.78c-21.173 8.84-44.394 13.734-68.745 13.734-98.652 0-178.827-80.172-178.827-178.824 0-90.942 68.133-166.178 156.065-177.382l8.637-24.528zm29.432.076l8.555 24.604c87.397 11.69 154.96 86.67 154.96 177.23 0 48.234-19.17 92.043-50.29 124.23l8.633 24.686c40.12-36.963 65.23-89.96 65.23-148.923 0-106.782-82.332-194.023-187.088-201.828zm-14.75 14.49l-32.3 91.706h18.925v45.068c4.35-1.182 8.917-1.824 13.63-1.824 4.36 0 8.596.547 12.65 1.564v-44.808h18.98L257.408 69.97zm71.82 44.42l-17.197 29.79c-3.446-1.657-6.983-3.158-10.596-4.5l14.144 40.683h-26.576v35.057c12.702 9.562 20.95 24.756 20.95 41.793 0 8.697-2.16 16.91-5.956 24.142l40.705 54.186 19.466-14.662 4.924 14.08 20.603 11.897c3.477-5.153 6.657-10.522 9.526-16.08l-29.35-16.945c6.967-13.842 11.447-29.152 12.86-45.348h33.862c.253-3.69.392-7.412.392-11.168 0-2.52-.066-5.026-.18-7.52h-33.82c-.98-16.423-5.11-31.993-11.796-46.112l29.45-17.002c-2.76-5.616-5.835-11.046-9.208-16.266l-29.48 17.02c-8.97-13.35-20.434-24.88-33.73-33.922l17.153-29.71c-5.178-3.438-10.566-6.585-16.144-9.41zm-145.38.313c-5.567 2.85-10.94 6.023-16.104 9.483l17.62 30.523c-12.89 9.09-23.988 20.545-32.67 33.737l-30.645-17.695c-3.362 5.228-6.422 10.667-9.167 16.29l30.73 17.74c-6.385 13.828-10.33 29.016-11.285 45.015H96.895c-.115 2.493-.182 4.998-.182 7.52 0 3.755.14 7.477.392 11.167h35.477c1.377 15.775 5.664 30.708 12.324 44.264l-30.613 17.674c2.855 5.565 6.028 10.938 9.492 16.1l30.592-17.663c8.745 12.622 19.743 23.56 32.418 32.236l-17.527 30.353c5.202 3.4 10.616 6.505 16.216 9.292l17.473-30.265c13.535 6.554 28.428 10.746 44.147 12.052v34.62c3.224.193 6.472.303 9.746.303 3 0 5.98-.09 8.94-.252v-34.497c6.595-.42 13.048-1.358 19.325-2.756l10.682-8.047-47.52-63.257c-24.326-4.454-42.908-25.862-42.908-51.428 0-16.593 7.833-31.43 19.976-41.026v-35.825h-26.63l14.196-40.31c-3.934 1.5-7.777 3.184-11.51 5.056l-17.554-30.405zm73.814 108.906c-18.67 0-33.605 14.935-33.605 33.605 0 18.67 14.936 33.603 33.605 33.603 18.67 0 33.604-14.934 33.604-33.603 0-18.67-14.934-33.604-33.604-33.604zm34.363 72.927c-5.978 5.234-13.142 9.14-21.03 11.233l50.952 67.828-14.578 10.984 79.74 56.525-32.137-91.902-13.975 10.525-48.973-65.193zm174.223 50.33c-14.203 33.102-36.037 62.167-63.27 84.998l9.7 27.733 83.15-83.15-29.58-29.58zM47.46 346.9l-29.585 29.586 119.84 119.84 29.603-29.603C113.616 443.69 70.508 400.593 47.46 346.9zm323.343 107.553c-7.848 4.552-15.992 8.65-24.395 12.254l29.58 29.58 22.33-22.33-27.515-19.504z","b":[17.9,18.3,478.0,478.0]},{"n":"cog","d":"M150.094 59.7L139.07 78.695c-7.27-1.615-15.652-1.322-22.142.234l-10.791-19.054L80.33 74.858 91.5 94.554a48.133 48.133 0 0 0-9.938 18.63l-23.52.105-.197 29.834 25.035-.119a49.2 49.2 0 0 0 9.666 15.859L79.5 181.36l25.61 14.852 13.108-22.596a47.62 47.62 0 0 0 18.542.3l13.102 22.58 25.623-15.283c-4.08-7.22-8.161-14.44-12.244-21.66a48.554 48.554 0 0 0 10.252-16.378l24.464-.092.198-29.834-23.235-.156a48.717 48.717 0 0 0-10.387-19.304l11.172-19.24zm-19.705 44.292c12.71 1.043 22.352 12.16 21.787 25.043-.584 13.297-11.839 23.598-25.137 23.015-13.3-.582-23.855-11.836-23.018-25.121.905-14.35 13.161-24.021 26.368-22.937z","b":[57.8,59.7,140.3,136.8]},{"n":"cog-lock","d":"M253.922 20.86c-38.28 0-74.42 9.152-106.36 25.376l11.967 20.73c29.084-15.037 62.08-23.538 97.044-23.538 35.998 0 69.908 9.015 99.613 24.892l10.727-18.58c-33.535-18.404-72.04-28.88-112.992-28.88zM131.246 55.356C66.09 95.27 21.88 166.017 18.902 247.297h25.97c2.682-71.938 41.318-134.77 98.45-171.022l-12.076-20.918zm251.682 4.028l-10.662 18.467c55.79 36.48 93.37 98.538 96.01 169.447h20.67c-2.88-78.62-44.34-147.377-106.018-187.915zm-133.62 2.88C184.307 64.66 127.58 99.067 94.4 150.218l46.106 26.618c-3.475 5.153-6.612 10.552-9.393 16.158L85 166.373c-13.8 26.61-21.603 56.844-21.603 88.926 0 32.418 7.97 62.948 22.042 89.76l45.917-26.51c2.802 5.594 5.962 10.98 9.457 16.12L94.92 361.166c33.25 50.713 89.725 84.778 154.393 87.162v-52.113c2.685.152 5.39.238 8.112.238 3.56 0 7.085-.133 10.578-.392v52.07c63.662-3.702 118.987-38.127 151.375-88.706l-44.652-25.78c3.45-5.17 6.565-10.58 9.318-16.2l44.64 25.77c13.475-26.36 21.074-56.24 21.074-87.915 0-31.34-7.447-60.917-20.656-87.073l-44.82 25.875c-2.73-5.632-5.83-11.05-9.26-16.233l44.857-25.897c-32.316-51.016-87.88-85.79-151.877-89.512v52.544c-3.492-.26-7.018-.395-10.576-.395-2.724 0-5.428.085-8.113.238V62.264zm-37.177 69.422l20.276 35.145c7.914-2.2 16.253-3.383 24.867-3.383 8.623 0 16.97 1.184 24.89 3.388l20.278-35.15 40.14 23.078-20.355 35.283c11.824 11.63 20.54 26.41 24.785 42.985h40.722v46.156h-40.74c-4.253 16.56-12.974 31.322-24.795 42.94l20.383 35.33-40.14 23.077-20.315-35.213c-7.91 2.198-16.242 3.38-24.852 3.38-8.6 0-16.927-1.18-24.83-3.374l-20.312 35.207-40.136-23.078 20.37-35.312c-11.828-11.62-20.554-26.39-24.81-42.957H126.84v-46.155h40.697c4.246-16.583 12.967-31.37 24.8-43.006l-20.343-35.264 40.137-23.078zm-193.185 134.3c3.365 80.998 47.677 151.42 112.797 191.085l12.725-22.04c-57.045-35.686-95.94-97.754-99.492-169.046h-26.03zm449.23 0c-3.5 70.267-41.33 131.58-97.036 167.5l11.3 19.572C444.08 412.763 485.646 344.327 488.9 265.987h-20.726zm-113.18 176.915c-29.42 15.485-62.903 24.264-98.42 24.264-34.484 0-67.055-8.27-95.846-22.922l-12.646 21.9c31.814 16.06 67.766 25.116 105.838 25.116 40.746 0 79.07-10.366 112.484-28.596l-11.41-19.762z","b":[18.9,20.9,470.0,470.4]},{"n":"cogsplosion","d":"M161.186 30.88c-7.18.168-14.257 2.57-19.573 7.888-4.494 4.494-6.902 10.25-7.642 16.26-6.008.74-11.76 3.148-16.255 7.642-4.59 4.59-6.997 10.49-7.682 16.637-6.15.683-12.055 3.098-16.646 7.69-7.088 7.087-9 17.303-7.338 26.724 1.66 9.42 6.648 18.663 14.38 26.395 5.303 5.304 11.318 9.313 17.613 11.846-.032 3.08-.987 5.26-2.463 6.735-1.986 1.987-5.24 3.035-10.264 2.15-5.022-.888-11.193-3.96-16.425-9.193l-13.214 13.215c7.732 7.732 16.974 12.72 26.394 14.38 9.42 1.663 19.637-.25 26.725-7.337 4.686-4.686 7.1-10.742 7.723-17.03 6.288-.623 12.344-3.035 17.03-7.722 4.592-4.59 7-10.496 7.684-16.646 6.15-.684 12.053-3.092 16.643-7.682 7.088-7.088 9-17.304 7.338-26.725-1.663-9.42-6.647-18.662-14.38-26.394-5.523-5.523-11.82-9.636-18.4-12.146.23-2.475 1.112-4.298 2.395-5.582 1.987-1.987 5.242-3.034 10.264-2.148 5.022.886 11.193 3.96 16.426 9.19l13.214-13.213c-7.73-7.73-16.972-12.718-26.392-14.38-2.355-.416-4.76-.607-7.154-.55zm182.798 20.308l-18.052 4.837 3.36 12.538c-3.326 2.186-6.22 5.04-8.452 8.42l-12.518-3.352-4.836 18.054 12.614 3.38c.28 3.99 1.37 7.847 3.152 11.35l-9.32 9.318 13.214 13.217 9.38-9.382c1.68.825 3.454 1.504 5.322 2.004 1.964.527 3.94.837 5.9.948l3.45 12.875 18.052-4.838-3.477-12.98c3.193-2.12 5.982-4.856 8.164-8.09l12.922 3.464 4.835-18.052-12.828-3.437c-.236-3.945-1.27-7.766-2.978-11.25l9.36-9.362-13.213-13.215-9.22 9.22c-1.793-.915-3.702-1.66-5.717-2.2-1.918-.514-3.846-.82-5.76-.938l-3.356-12.528zm-206.236 22.23c1.042-.005 2.188.095 3.443.316 5.024.887 11.197 3.96 16.43 9.192 5.23 5.232 8.302 11.405 9.19 16.428.885 5.022-.163 8.277-2.15 10.263-1.986 1.987-5.24 3.035-10.262 2.15-5.022-.888-11.195-3.96-16.427-9.193-5.23-5.232-8.304-11.405-9.19-16.428-.887-5.022.16-8.275 2.148-10.26 1.49-1.492 3.693-2.454 6.82-2.468zm207.258 8.906c1.065-.035 2.16.087 3.258.38 5.854 1.57 9.188 7.344 7.62 13.198-1.57 5.855-7.344 9.188-13.198 7.62-5.855-1.57-9.188-7.343-7.62-13.198 1.177-4.39 4.718-7.364 8.885-7.914.348-.046.7-.074 1.056-.086zm-232.252 15.45c2.522 6.44 6.586 12.6 12.002 18.015 5.414 5.413 11.57 9.474 18.008 11.997-.142 2.77-1.05 4.777-2.43 6.156-1.986 1.987-5.24 3.035-10.264 2.15-5.022-.888-11.193-3.96-16.425-9.193-5.233-5.232-8.306-11.403-9.192-16.425-.886-5.023.162-8.278 2.15-10.264 1.38-1.38 3.38-2.296 6.15-2.437zm183.232 48.744L125.53 302.695l.966-103.943-66.363 66.922-38.184-101.03v329.45h258.923L199.37 473.54l161.5-30.372.038.14 1.848-.494 11.617-2.185c2.095 2.893 4.688 5.36 7.62 7.308l-3.475 12.976 18.05 4.838 3.452-12.875c1.96-.11 3.935-.42 5.9-.947 1.867-.5 3.643-1.18 5.32-2.004l9.38 9.38 13.214-13.216-9.32-9.32c1.78-3.5 2.872-7.36 3.152-11.348l12.615-3.38-4.837-18.054-12.517 3.354c-2.233-3.383-5.126-6.236-8.45-8.422l3.358-12.537-18.05-4.838-3.358 12.527c-1.915.118-3.842.424-5.76.938-2.014.54-3.923 1.285-5.715 2.2l-9.22-9.22-13.214 13.215 9.36 9.36c-1.708 3.487-2.74 7.307-2.978 11.253l-12.828 3.438 2.104 7.85-99.274.8 73.254-70.363-36.738 2.8 50.22-60.863 2.977-2.308c4.462 4.433 9.56 8.315 15.217 11.515l-5.547 13.596 17.305 7.06 5.56-13.628c6.274 1.64 12.624 2.412 18.903 2.344l2.007 14.626 18.515-2.54-2.017-14.72c6.12-1.693 11.997-4.177 17.474-7.39l9.134 11.773 14.766-11.458-9.13-11.77c4.4-4.437 8.25-9.506 11.436-15.12l13.823 5.64 7.06-17.305-13.83-5.643c1.637-6.237 2.396-12.55 2.34-18.795l14.827-2.032-2.537-18.516-14.873 2.04c-1.675-6.102-4.132-11.97-7.317-17.438l11.85-9.193-11.455-14.765-11.795 9.15c-4.424-4.415-9.48-8.283-15.086-11.484l5.63-13.794-17.306-7.06-5.613 13.76c-6.25-1.663-12.58-2.453-18.842-2.415l-2.013-14.686-18.516 2.537 2.012 14.675c-6.143 1.668-12.045 4.144-17.547 7.342l-9.058-11.674-14.767 11.455 9.01 11.615c-4.445 4.447-8.34 9.534-11.56 15.174l-13.577-5.54-7.06 17.304 13.54 5.526c-1.667 6.29-2.44 12.66-2.385 18.96L312.7 254.28l2.423 17.68-108.488 38.93 89.35-164.372zm102.73 51.714c6.96-.078 14.056 1.208 20.93 4.012 19.95 8.14 32.303 26.768 33.293 46.88l-23.085-2.913c-1.867-9.957-8.572-18.837-18.568-22.915-3.904-1.593-7.962-2.313-11.953-2.252-11.532.176-22.486 6.88-27.55 17.836l-23.5-2.968c.454-1.444.956-2.884 1.538-4.312 8.412-20.617 28.02-33.13 48.895-33.368zm.772 41.44c1.567-.01 3.174.29 4.74.928 6.266 2.556 9.162 9.445 6.606 15.71-2.556 6.266-9.448 9.164-15.713 6.608-6.264-2.556-9.16-9.448-6.604-15.713 1.917-4.7 6.27-7.503 10.972-7.533zm-53.607 14.77l23.636 2.986c1.898 9.908 8.59 18.733 18.545 22.795 15.15 6.18 32.623-.79 39.473-15.47l23.035 2.91c-.46 1.474-.97 2.945-1.566 4.403-11.216 27.49-42.334 40.572-69.822 29.356-19.985-8.154-32.344-26.83-33.3-46.98zm52.88 158.238c.355.01.707.04 1.054.086 4.168.55 7.71 3.523 8.887 7.914 1.57 5.855-1.763 11.63-7.618 13.2-5.855 1.568-11.628-1.767-13.197-7.622-1.57-5.855 1.764-11.63 7.62-13.197 1.097-.294 2.19-.415 3.255-.38z","b":[21.9,30.8,464.5,463.3]},{"n":"gear-hammer","d":"M265.344 17.5l-4.188 25.313c-17.994-.1-35.62 2.066-52.562 6.28l-9.438-25.062-55.125 20.75 9.907 26.282c-15.008 8.587-28.96 18.95-41.5 30.876L90 83.53l-37.375 45.5L75.75 148c-8.54 14.428-15.47 30.036-20.5 46.594l-30.063-4.97-9.593 58.095L46 252.75c-.374 17.218 1.313 34.127 4.906 50.438L22 314.063l20.75 55.125 28.625-10.782c8.07 15.027 17.91 29.046 29.28 41.75L81.688 423.25l45.532 37.344 18.343-22.344c14.386 9.118 30.04 16.577 46.687 22.125l-4.53 27.5 58.093 9.594 4.343-26.283c18.046.874 35.764-.54 52.875-4.03l8.97 23.78 55.094-20.75-8.53-22.656c16.126-8.343 31.134-18.683 44.655-30.78l17.936 14.72 37.344-45.533-17.188-14.093c9.733-15.35 17.606-32.125 23.25-50.03l21.407 3.53 9.56-58.094-21.06-3.47c.608-18.84-1.282-37.305-5.408-55.06l19.844-7.47-20.75-55.125-20.187 7.594c-8.89-16.114-19.817-31.033-32.5-44.376l14.155-17.25-45.5-37.375-14.72 17.936c-15.396-9.116-32.13-16.37-49.936-21.47l3.967-24.092-58.093-9.594zm-8.03 47.938c11.136-.15 22.437.685 33.81 2.562C395.113 85.164 465.665 183.606 448.5 287.594 431.336 391.58 332.894 462.134 228.906 444.97 124.92 427.803 54.366 329.36 71.53 225.374c15.02-90.99 92.292-156.386 181.032-159.813 1.585-.06 3.16-.103 4.75-.124zm.217 18.687c-1.437.018-2.88.04-4.31.094-80.154 3.037-149.672 61.917-163.25 144.186-15.52 94.022 47.977 182.606 142 198.125 94.02 15.52 182.573-47.977 198.093-142 15.52-94.02-47.947-182.573-141.97-198.092-10.283-1.698-20.496-2.44-30.562-2.313zm.408 18.156c9-.116 18.145.546 27.343 2.064 84.096 13.88 140.85 93.092 126.97 177.187-13.88 84.096-93.06 140.85-177.156 126.97-25.808-4.26-49.03-14.68-68.438-29.5l109.688-133.625 52.844 43.375 58.437-71.188-108.22-88.78-101.842 35.53 71 58.25L140.78 353.938c-26.985-33.066-40.165-77.126-32.655-122.625 12.146-73.583 74.283-126.223 145.97-128.937 1.28-.048 2.557-.077 3.843-.094z","b":[15.6,17.5,479.9,480.0]},{"n":"gear-stick","d":"M177.3 26.41c-3.6.05-7.3.36-11.2.96-19.5 2.98-32.7 8.95-40.2 16.45-7.5 7.51-10.5 16.58-8.9 30 1.3 10.49 3.2 15.8 5.3 19.24 2.2 3.45 5.1 5.87 10.5 9.94 10.4 7.8 27.4 20.7 49.9 55.4 8.1 2.4 14.8 2.1 21.6-.1 6-1.9 12-5.4 18-9.9-3.2-13.2-1.2-25.7 1.5-36.8 3.2-13.03 7-24.74 7-35.91 0-24.85-17.7-48.1-50-49.25-1.1-.04-2.3-.05-3.5-.03zm45.1 143.49c-4 2.2-8.1 4.2-12.6 5.6-5.1 1.6-10.6 2.5-16.2 2.5l46.3 165.6 29.1-7.3-46.6-166.4zm121.4 167.3c-1.5 0-3.1.2-4.7.6l-158.8 36.6c-17 3.9-20.1 21.9-13 32.5-16.6 4.9-20.7 23.6-13.9 35.9-29.5 5.4-27.4 47.6 6.6 47.6h217.4c36.2 0 36.2-48.2 0-48.2H275.6l93.2-10.9c31.9-3.7 27.7-51.6-4.3-47.9l-79.8 9.3-.3-1.1 61.6-14.1c24.4-5.6 20.3-39.8-1.2-40.3h-1z","b":[115.4,26.4,298.2,464.0]},{"n":"gear-stick-pattern","d":"M82.64 48.26a51.94 51.94 0 0 0-51.68 51.94 51.94 51.94 0 0 0 42.2 50.9v209.7a51.94 51.94 0 0 0-42.2 51 51.94 51.94 0 0 0 51.94 51.9 51.94 51.94 0 0 0 51.9-51.9 51.94 51.94 0 0 0-42.15-51v-95.1H246.2v95.1a51.94 51.94 0 0 0-42.2 51 51.94 51.94 0 0 0 52 51.9 51.94 51.94 0 0 0 51.9-51.9 51.94 51.94 0 0 0-42.2-51v-95.1H438.8V151.1a51.94 51.94 0 0 0 42.2-50.9 51.94 51.94 0 0 0-51.9-51.94 51.94 51.94 0 0 0-.2 0 51.94 51.94 0 0 0-51.7 51.94 51.94 51.94 0 0 0 42.2 50.9v95.1H265.7v-95.1a51.94 51.94 0 0 0 42.2-50.9A51.94 51.94 0 0 0 256 48.26a51.94 51.94 0 0 0-.2 0A51.94 51.94 0 0 0 204 100.2a51.94 51.94 0 0 0 42.2 50.9v95.1H92.65v-95.1a51.94 51.94 0 0 0 42.15-50.9 51.94 51.94 0 0 0-51.9-51.94 51.94 51.94 0 0 0-.26 0z","b":[31.0,48.3,450.0,415.4]},{"n":"gears","d":"M179.625 22.313L163.22 58.937c-3.258-.384-6.498-.604-9.72-.624-10.577-.066-20.857 1.808-30.47 5.28L99.78 31.032 55.75 63.188l24.063 33.657c-7.21 10.412-12.3 22.5-14.5 35.75l-42.72 4.687 5.345 54.25 45.468-5c5.082 10.2 12.078 19.372 20.594 26.97l-19.406 43.375 49.375 22.094 19.5-43.564c11.656 1.242 23.08.128 33.75-3l28.124 38.53 31.72-23.186 11.655 20.156C234.014 279.138 220.873 292.3 209.624 307l-49.22-28.344-25.718 46.72 48.125 27.937c-7.068 16.934-11.967 34.975-14.343 53.812H112.5v53.72h56.22c1.66 12.053 4.372 23.753 8.03 35.06h169.312c-23.915-10.758-40.562-34.788-40.562-62.717 0-37.964 30.754-68.75 68.72-68.75 37.963 0 68.75 30.786 68.75 68.75 0 27.93-16.67 51.96-40.595 62.718h91.5V200.375l-11.688-6.406L454.594 242c-16.842-7.204-34.808-12.234-53.594-14.72v-55.53h-53.72v55.47c-18.303 2.377-35.83 7.183-52.31 14.03l-27.126-47.28-36 20.25-9.25-12.97c7.08-9.223 12.43-19.93 15.5-31.72l44.437-4.843-5.342-54.25-42.25 4.157c-4.92-12.618-12.648-23.953-22.563-33.094L229 44.406l-49.375-22.093zm-27.344 84.25c23.3-.24 42.94 17.827 44.376 41.343 1.48 24.275-17.004 45.144-41.28 46.625-24.278 1.483-45.145-16.974-46.626-41.25-1.48-24.274 16.973-45.142 41.25-46.624.76-.046 1.53-.086 2.28-.094z","b":[22.6,22.3,471.3,473.6]},{"n":"lever","d":"M235.344 31.188c-35.92.543-70.472 6.628-102.97 18l5.72 17.468c30.61-10.843 63.185-16.653 97.187-17.156l.064-18.313zm18.687.187l-.06 18.375c46.9 1.963 96.236 13.842 146.56 36.47l9.376-16.25C356.84 45.9 304.253 33.282 254.03 31.374zm-139.093 24.5c-20.133 8.42-39.376 18.953-57.562 31.5l8.813 16.53c17.207-12.117 35.41-22.284 54.468-30.436l-5.72-17.595zm312.97 20.25l-61.5 106.53 55.124 31.814 61.5-106.532-55.124-31.813zm-174.063 6.313l-.03 18.406c39.736 1.29 80.36 11.3 120.342 31.062l9.375-16.22c-42.846-21.33-86.708-32.012-129.686-33.25zm-18.688.062c-29.644 1.034-58.722 6.555-86.625 16.156l5.72 17.53c26.066-9.063 53.198-14.28 80.875-15.28l.03-18.406zM42.126 98.53c-8.205 6.396-16.177 13.24-23.876 20.5l9.97 16.345c7.376-7.136 15.013-13.842 22.874-20.125l-8.938-16.72h-.03zm88.905 6.72c-17.292 7.142-34.04 15.886-50.124 26.125l8.813 16.5c15.13-9.78 30.847-18.16 47.06-25l-5.75-17.625zm122.626 35.28l-.062 18.44c30.17 1.18 61.405 7.815 93.156 20.405l9.438-16.344c-34.7-14.046-69.15-21.353-102.532-22.5zm-18.687.032c-23.744.82-46.85 4.73-69 11.563l5.718 17.5c20.297-6.28 41.433-9.915 63.218-10.688l.063-18.375zm-169.626 1.375c-7.647 5.49-15.13 11.32-22.406 17.5l9.874 16.157c6.96-6.02 14.107-11.72 21.407-17.063l-8.876-16.593zm82.97 16.344c-14.515 5.62-28.545 12.503-42.033 20.595l8.782 16.406c12.534-7.633 25.55-14.124 39-19.436l-5.75-17.563zM90.53 189.03c-6.896 4.782-13.607 9.887-20.155 15.314l9.844 16.125c6.23-5.272 12.61-10.237 19.155-14.876L90.53 189.03zm279.19 17.126L292.28 340.25c11.3 3.162 22.027 7.753 31.94 13.563l75.31-130.47-29.81-17.187zm-114.033 147.78c-60.607.002-110.206 45.816-116.406 104.752h82.126c-2.206-4.67-3.437-9.87-3.437-15.344 0-19.872 16.315-36.156 36.186-36.156 19.872 0 36.188 16.284 36.188 36.156 0 5.475-1.23 10.674-3.438 15.344h85.188c-6.2-58.936-55.8-104.75-116.406-104.75zm-1.53 71.94c-9.773 0-17.5 7.696-17.5 17.468 0 6.678 3.626 12.39 9.03 15.344h16.938c5.404-2.955 9.03-8.666 9.03-15.344 0-9.772-7.727-17.47-17.5-17.47zm-153.47 51.5v15.687h303.344v-15.688H100.69z","b":[18.2,31.2,464.8,461.9]},{"n":"lightning-spanner","d":"M18.355 18.375V53.21L89.04 99.51l-42.593 57.71 81.03-27.392 7.023 30.498 56.066 5.256 9.926 43.22-35.623 16.934-40.298-29.785-70.082 62.49 72.418-23.945 22.778 44.387 44.96-14.373 32.2-55.918c-10.238-23.8-9.676-51.92 4.183-75.996 7.208-12.53 17.085-22.504 28.644-29.575 2.33-.675 8.71-5.517 11.648-5.802 11.515-4.78 23.982-7.087 36.537-6.534 5.638.248 11.288 1.053 16.863 2.433l12.088 2.99-40.34 69.5c-3.456 6.002-1.275 14.09 3.895 17.085l.002.002c5.144 2.976 12.367.775 16.014-5.56l.01-.014 40.35-69.518 8.592 8.97c25.457 26.57 31.995 67.74 12.697 101.26-13.936 24.205-38.08 38.312-63.676 41.24l-29.91 51.937 27.017 23.355-19.92 43.863 85.913 67.684-43.625-74.252 37.785-33.21 47.89 26.284-51.698-66.78-19.377 32.37-24.12-43.85 62.49-32.706 17.52 39.714 30.37-26.28 32.705 50.81-23.944-88.77-29.788 24.526-4.672-66.577 75.338-48.472-81.787-4.59 28.616-55.82 36.155 26.585 26.335-16.34v-70.18h-2.63L456.878 50.53 415.41 27.757l-45.1 61.627-34.57-16.162 16.656-52.488-78.304 53.594-24.198-55.95h-65.783l-5.226.63 51.976 33.29-12.847 61.32-50.81 8.76-72.327-104H18.354zM304.56 109.3c-12.4-.082-24.632 3.262-35.138 9.68l-.102.06c-8.906 5.473-16.434 13.043-22.093 22.878v.002c-11.596 20.143-11.392 43.746-1.618 63.08l2.277 4.504-86.692 150.553-5.068.27c-19.984 1.06-39.3 11.34-51.25 28.92-7.377 10.693-11.713 23.632-11.713 37.552 0 36.546 29.828 66.374 66.375 66.374 36.546 0 66.374-29.828 66.374-66.375 0-5.057-.59-9.977-1.67-14.714-.1-.457-.207-.91-.316-1.365-.05-.2-.095-.4-.147-.6-1.198-4.772-2.917-9.394-5.143-13.763l-2.3-4.513 86.698-150.57 5.07-.27c21.685-1.153 42.1-12.294 53.73-32.492h-.003c12.81-22.25 10.9-48.614-2.115-68.81l-27.14 46.76c-8.31 14.434-26.838 20.938-41.575 12.407H291c-14.713-8.522-19.23-27.812-10.73-42.583l.01-.016 27.206-46.868c-.15-.007-.298-.035-.447-.04-.828-.037-1.655-.058-2.48-.063zM159.54 379.1c26.45 0 47.696 21.244 47.696 47.697 0 26.45-21.244 47.696-47.697 47.696-26.454 0-47.696-21.245-47.696-47.697 0-26.454 21.243-47.698 47.695-47.698z","b":[18.4,18.4,475.3,474.8]},{"n":"mighty-spanner","d":"M270.953 17.215l-49.748 84.224-56.092-59.88 1.748 89.092-92.368-40.11 36.354 90.622-82.698 16.805 59.42 67.454-69.437 73.39 88.122 10.178 26.578-26.578c-.852-2.042-1.668-4.103-2.42-6.195l-22.756 6.385-5.05-17.992 22.757-6.386c-1.065-5.188-1.83-10.484-2.27-15.873l-23.643.28-.22-18.69 23.644-.278c.315-5.398.954-10.712 1.898-15.922l-22.905-5.848 4.623-18.107 22.905 5.847c1.7-5.1 3.698-10.067 5.98-14.875l-20.63-11.588 9.153-16.293 20.652 11.6c2.95-4.466 6.162-8.743 9.615-12.812l-16.96-16.563 13.06-13.37 16.96 16.562c3.986-3.548 8.187-6.86 12.58-9.914l-12.085-20.373 16.072-9.535 12.074 20.35c4.755-2.393 9.672-4.507 14.732-6.325l-6.39-22.766 17.99-5.05 6.39 22.765c5.187-1.067 10.482-1.833 15.87-2.274l-.278-23.65 18.687-.223.28 23.652c5.398.313 10.71.953 15.92 1.897l5.85-22.91 18.108 4.622-5.85 22.91c5.1 1.698 10.067 3.695 14.875 5.975l11.588-20.632 16.296 9.153-11.6 20.653c4.466 2.95 8.743 6.162 12.813 9.615l16.56-16.96 13.372 13.058-16.562 16.96c3.548 3.985 6.86 8.185 9.916 12.58l20.37-12.085 9.536 16.075-20.348 12.07c2.395 4.754 4.51 9.67 6.33 14.73l22.758-6.388 5.05 17.994-22.757 6.388c1.067 5.187 1.832 10.482 2.274 15.87l23.64-.278.22 18.688-23.64.28c-.31 5.398-.95 10.712-1.893 15.923l22.894 5.846-4.622 18.108-22.894-5.846c-1.698 5.103-3.696 10.07-5.977 14.88l20.617 11.58-9.152 16.294-20.637-11.592c-2.95 4.467-6.163 8.746-9.617 12.817l16.947 16.55-13.056 13.37-16.95-16.55c-3.986 3.55-8.19 6.863-12.584 9.92l12.078 20.358-16.075 9.535-12.065-20.338c-4.755 2.395-9.673 4.51-14.734 6.328l6.385 22.75-17.994 5.05-6.384-22.75c-5.187 1.068-10.483 1.834-15.873 2.275l.28 23.634-18.686.22-.28-23.635c-5.398-.313-10.712-.953-15.923-1.896l-5.846 22.89-18.107-4.622 5.847-22.894c-2.582-.86-5.128-1.798-7.637-2.81l-26.326 26.216 7.148 73.713 67.797-55.734 49.456 43.487 21.12-53.87 90.09 46.07-38.16-96.155 92.102 27.826-36.908-79.496 61.514-6.506-60.832-51.39 57.994-45.053-73.29-15.66 59.093-70.504-91.66 18L406.02 47.85 307.094 110.9l-36.14-93.685zM254.016 157.43c-63.085.747-113.42 52.287-112.672 115.37.145 12.3 2.23 24.108 5.947 35.153l16.784-16.783c-6.17-30.05 2.24-62.392 25.697-85.852 19.075-19.073 44.026-28.157 68.916-27.447l.003-.01c14.933.424 29.785 4.308 43.216 11.68l-60.154 60.153c-10.613 10.615-11.292 27.843-1.168 37.963 10.122 10.133 27.35 9.455 37.96-1.158l60.155-60.154c19.66 35.818 14.75 81.61-15.77 112.13-23.46 23.47-55.677 31.4-85.852 25.114l-16.557 16.488c11.394 3.64 23.562 5.544 36.195 5.395 63.084-.746 113.42-52.287 112.674-115.368-.748-63.084-52.293-113.42-115.374-112.672z","b":[18.1,17.2,475.6,477.3]},{"n":"monkey-wrench","d":"M417.972 37.51c-1.67-.02-3.093.17-4.218.544l-20.127 6.71 63.95 63.948-22.628 22.627 21.212 21.212 27.576-27.578c6.01-6.01 7.04-13.12 4.383-23.152-2.655-10.033-9.698-21.883-18.933-32.438-9.235-10.554-20.62-19.874-31.123-25.603-7.878-4.297-15.083-6.214-20.092-6.27zM354.338 98.81l-45.952 45.95c5.99 1.255 12.28 2.304 18.506 2.534 12.166.45 23.204-1.815 32.397-11.008l6.362-6.363 17.64 17.64.073.073 4.914 4.914 9.9-9.9-43.842-43.84zm67.884 45.254l-21.214 21.215 21.212 21.213 21.213-21.214-21.21-21.214zm-56.57 14.156c-1.773 0-3.545.703-4.95 2.107-2.808 2.808-2.808 7.09 0 9.9 2.81 2.81 7.09 2.81 9.9 0 2.808-2.81 2.808-7.092 0-9.9-1.405-1.405-3.177-2.108-4.95-2.108zm-72.32 1.596l-28.09 28.09 93.516 93.513c1.927-.694 5.33-2.472 9.257-5.14 4.036-2.746 8.643-6.35 13.44-10.464-7.204 2.642-15.128 1.97-21.463-4.366l-33.942-33.94c-16.086-16.088 4.237-42.443 23.043-41.142 1.67.116 3.328.455 4.948 1.034-2.19-1.138-4.24-2.62-6.066-4.446-5.053-5.053-7.464-11.816-7.246-18.507-4.92.785-9.81 1.008-14.502.834-12.924-.478-24.25-3.404-32.894-5.466zm94.226 17.47c-1.107 2.04-2.513 3.953-4.228 5.668-7.18 7.18-17.813 9.033-26.78 5.573 1.688.903 3.32 2.09 4.856 3.624l33.94 33.94c6.817 6.816 7.093 15.475 3.722 23.093 8.43-8.698 16.1-17.75 21.014-24.975 2.67-3.925 4.45-7.328 5.144-9.256l-37.668-37.668zM254.3 202.42l-26.195 43.66 4.04 19.296 17.374 3.31 35.523-35.523L254.3 202.42zm93.024 1.96c-3.75.04-11.022 7.926-8.547 10.4l33.94 33.942c2.83 2.828 12.73-7.07 9.902-9.898l-33.943-33.942c-.353-.353-.817-.508-1.353-.502zm-38.24 52.824l-4.95 4.95c-7.424 7.424-10.522 14.256-11.244 19.304-.72 5.05.637 8.274 2.758 10.395 2.12 2.12 5.346 3.48 10.395 2.758 5.048-.72 11.88-3.82 19.304-11.244l4.95-4.95-21.213-21.212zm-95.91 5.4L47.7 428.076c4.836 1.544 9.377 4.213 13.188 8.024 3.812 3.813 6.48 8.357 8.024 13.192l165.215-165.215-17.143-3.265-3.81-18.21zM37.554 444.377c-3.82 0-7.638 1.485-10.605 4.45-5.934 5.935-5.934 15.28 0 21.214 5.932 5.934 15.28 5.934 21.212 0 5.933-5.933 5.933-15.28 0-21.213-2.967-2.967-6.788-4.452-10.608-4.452z","b":[21.0,37.5,469.8,438.5]},{"n":"pokecog","d":"M235.045 25.752l-41.775 8.215 6.894 35.947c-19.303 5.91-37.997 14.43-54.643 25.852l-23.834-27.78L89.04 96.158l24.433 27.988c-13.495 14.454-25.328 31.203-34.16 49.78L44.64 161.813l-14.203 40.652 34.674 12.11c-4.54 19.832-5.6 40.113-4.057 59.624l-36.547 6.685 8.006 42.37 35.947-6.896c5.91 19.303 15.235 37.61 26.657 54.255L67.34 394.45l27.572 32.44 27.78-23.837c14.537 13.64 31.05 25.255 49.78 34.158l-12.115 34.675 40.653 14.2 12.11-34.67c20.202 4.695 40.354 5.885 60.222 4.267l6.894 35.947 41.774-8.214-6.895-35.947c19.304-5.912 38-14.43 54.645-25.853l23.836 27.778 32.646-28.17-24.433-27.99c13.355-14.305 25.153-30.836 33.948-49.18l34.674 12.113 14.2-40.652-34.673-12.112c4.654-20.034 5.825-40.508 4.27-60.22l36.543-6.688-8.003-42.37-35.948 6.894c-5.91-19.304-15.237-37.608-26.66-54.254l27.78-23.836-27.573-32.438-27.78 23.836c-14.538-13.64-31.05-25.257-49.78-34.16l11.905-34.076-40.65-14.2v.003L302.16 65.97c-20.2-4.698-40.35-5.887-60.22-4.27l-6.895-35.948zm23.178 87.603c28.01.105 56.29 8.287 81.183 25.24 59.008 40.186 79.122 116.127 51.112 179.13l-57.065-38.862c8.25-31.382-3.378-65.89-31.715-85.19-28.34-19.3-64.227-17.152-90.408 2.02l-57.316-39.033c27.96-28.41 65.826-43.448 104.21-43.305zM124.7 199.582l56.89 38.744c-8.423 31.474 2.948 66.307 31.39 85.676 28.44 19.37 65.5 17.52 91.7-1.848l56.625 38.565c-48.347 49.327-126.52 58.51-185.614 18.266C116.6 338.742 96.51 262.64 124.7 199.582zm132.87 14.29c8.663.03 17.408 2.56 25.102 7.798 20.516 13.973 25.83 41.964 11.857 62.48-13.972 20.517-41.967 25.827-62.483 11.856-20.516-13.972-25.827-41.964-11.856-62.48 8.734-12.823 22.942-19.707 37.38-19.655z","b":[24.5,25.8,466.3,465.9]},{"n":"screwdriver","d":"M68.906 19.344c-2.614.03-5.178.298-7.687.75C49.235 20.75 38.59 25.42 30.812 33.5c-9.657 10.03-14.27 24.77-11.875 40.594.012.084.05.165.062.25.708 13.018 6.502 26.876 19.53 39.906l86.126 86.125c30.255 2.728 53.004 26.627 53.906 57.5l.157 5.625c.8 5.8 4.26 10.397 8.874 12.78 5.734 2.965 12.387 3.148 19.625-4.092l64.436-64.407c7.72-7.718 6.865-12.713 3.5-18.155-3.365-5.442-11.242-10.094-18.78-10.094H255.968c-30.125-1.296-53.427-23.484-56.5-53l-86.595-86.593C97.59 24.652 82.44 19.183 68.905 19.345zM65 38.187c5.44.03 11.493 1.387 17.97 4.47l92.968 92.968-13.22 13.22L54 40.124c3.284-1.25 6.967-1.96 11-1.938zM38.344 56.47L146.75 164.843l-13.22 13.22-90.405-90.408c-3.155-5.842-4.966-11.366-5.72-16.344-.85-5.62-.425-10.577.94-14.843zM453.22 169.687l1.842 18.593-34.593-17.81c-11.45 2.664-21.948 7.76-29.408 14.624-7.198 6.625-11.776 14.544-12.687 24.594l111.563-13.532c-3.744-9.308-10.448-15.842-19.25-20.53-5.2-2.77-11.146-4.75-17.47-5.94zm5.592 49.062l-43.343 5.28c1.224 13.065 2.98 26.084 5.28 38.94l40.063-29.22c-.582-5.014-1.26-10.008-2-15zm-188.25 16.563l-36.812 36.75 16.625 16.625 36.813-36.75-16.625-16.625zm192.25 20.093l-37.968 27.72c2.35 10.382 5.055 20.63 8.125 30.655l30.81-22.467c.176-11.902-.154-23.9-.967-35.907zm-173.968 21.28l-12.75 12.752L388.406 401.75l3.313 3.313-.69 4.625-4.342 29.968 73 46.688 26.093-26.094-46.686-72.97-30 4.345-4.625.688-3.314-3.313-112.312-112.313zM462.75 315.19l-23.563 17.187c4.596 12.718 9.778 25.015 15.594 36.75 3.98-17.394 6.615-35.487 7.97-53.938zm-326.25 4.28c-7.316.176-14.165 2.543-20.72 6.5-7.282 4.4-13.982 10.982-19.436 18.782l3.25 37.188-16.53-5.032c-1.325 7.755-1.367 15.408.06 22.25 2.003 9.588 6.414 17.628 14.595 23.563l45.56-102.75c-1.796-.284-3.57-.473-5.31-.5-.493-.01-.982-.013-1.47 0zm10.25 38.782l-17.688 39.938c11.83 5.634 23.894 10.798 36.094 15.406l-4.562-49.375c-4.585-2.063-9.196-4.053-13.844-5.97zm33.5 15.344l4.344 46.844c10.115 3.3 20.29 6.216 30.47 8.718l-3.5-37.97c-10.13-6.25-20.59-12.137-31.314-17.592zm51.313 30.72l2.687 29.03c13.26 2.568 26.457 4.417 39.5 5.437-12.892-12.322-27.05-23.852-42.188-34.467z","b":[16.5,19.2,473.4,467.2]},{"n":"slot-machine","d":"M255.4 28.28c-59.7-.15-119.3 10.87-173.54 33.52l10.66 39.1H418.3l10.6-39.1C374.6 39.75 315 28.43 255.4 28.28zM110.2 124.1v190.6h290.4V124.1H110.2zm25 25h240.4v140.6H135.2V149.1zm325 4.3c-11.5 0-20.9 9.3-20.9 20.9 0 11.5 9.4 20.8 20.9 20.8 11.5 0 20.9-9.3 20.9-20.8 0-11.6-9.4-20.9-20.9-20.9zm-301.9 16v102.8h53.6V169.4h-53.6zm70.3 0v102.8h53.6V169.4h-53.6zm70.3 0v102.8h53.6V169.4h-53.6zm144.4 38.4-7.9 42.6c-7.1-3.2-12.9-4.2-12.9-4.2v68.5l30.1 16 9.6-49.7c-1.1-7.1-4.1-12.8-8.1-17.4l9.7-52c-1.2.2-2.4.2-3.6.2-6.1 0-11.8-1.4-16.9-4zm-338.5 134-46.38 50 10 93.2H442.4l10-93.2-46.4-50H104.8zm250.1 11.5a44.28 18.3 0 0 1 44.3 18.3 44.28 18.3 0 0 1-.2.8c.1.2.1.3.1.4 0 2.5-1.8 4.9-4.8 7a44.28 18.3 0 0 1-39.4 10.1 44.28 18.3 0 0 1-36.8-8.2 44.28 18.3 0 0 1-1.9-1.2c-3.5-2.3-5.7-4.9-5.7-7.7 0-.3.1-.7.1-1a44.28 18.3 0 0 1 0-.2 44.28 18.3 0 0 1 44.3-18.3zm-225 3.6h52.7l-12.8 31.8H104l25.9-31.8zm75.2 0h63.5L256 388.7h-63.8l12.9-31.8z","b":[58.4,28.1,422.7,456.9]},{"n":"spanner","d":"M331.188 16.72c-40.712-.002-81.41 15.408-112.438 46.436-43.866 43.864-56.798 107-38.813 162.25L17.03 388.312v25.75l170.22-170.218c2.75 5.84 5.847 11.555 9.344 17.094L17.03 440.5v51.78H64l181.875-181.874c5.516 3.515 11.212 6.668 17.03 9.438L90.44 492.28h27.03l164.75-164.75c55.182 17.85 118.21 4.884 162-38.905 41.415-41.414 54.998-99.91 41.282-152.813L380.22 241.125l-90.033-23.938-23.968-90.03L371.53 21.843c-13.213-3.41-26.772-5.125-40.342-5.125z","b":[17.0,16.7,482.2,475.6]},{"n":"toolbox","d":"M94.09 57L33 209.7V327h174V217h-87c-23.75 0-41-23-41-49s17.25-49 41-49h50.7l-24.8-62zm272.01 0L305 209.7V489h174V209.7L417.9 57zm25.9 62c23.8 0 41 23 41 49s-17.2 49-41 49-41-23-41-49 17.2-49 41-49zm-272 18c-11.6 0-23 12.8-23 31s11.4 31 23 31h169.9l24.8-62zm272 0c-11.6 0-23 12.8-23 31s11.4 31 23 31 23-12.8 23-31-11.4-31-23-31zM33 345v144h254V345z","b":[33.0,57.0,446.0,432.0]},{"n":"valve","d":"M247 41v18h18V41zM96.57 77c-.22.22-.77.85-1.35 2.15C93.98 81.96 93 87 93 92s.98 10 2.22 12.8c.58 1.3 1.13 2 1.35 2.2H415.4c.2-.2.8-.9 1.4-2.2C418 102 419 97 419 92c0-5-1-10.04-2.2-12.85-.6-1.3-1.2-1.93-1.4-2.15zM233 125v30h46v-30zm-64 48v30h174v-30zm32 48v190h110V221zM25 253v92h158v-92zm304 0v92h158v-92zm-73 7s38.6 55.3 31 84c-3.3 12.8-16.5 28-31 28-14.6 0-27.7-15.2-31-28-7.6-28.7 31-84 31-84zM25 363v16h158v-16zm304 0v16h158v-16zm-108.5 66l11.2 33.7c6 5.2 15 8.3 24.3 8.3s18.3-3.1 24.3-8.3l11.2-33.7z","b":[25.0,41.0,462.0,430.0]},{"n":"wrench","d":"M151 16c-14.774 0-30 15.226-30 30v105c0 14.774 11.946 26.718 26.718 26.718H181V334.28h-33.282c-14.773 0-26.718 11.946-26.718 26.718v105c0 14.774 15.227 30 30 30h30v-90l75-45 75 45v90h30c14.774 0 30-15.226 30-30v-105c0-14.773-11.946-26.718-26.718-26.718H331V177.718h33.282C379.056 177.718 391 165.772 391 151V46c0-14.773-15.226-30-30-30h-30v90l-75 45-75-45V16h-30z","b":[121.0,16.0,270.0,480.0]},{"n":"battery-100","d":"M201 16c-15 0-20 3.38-20 20v15h-45c-29.547 0-35 5.453-35 35v375c0 29.547 5.453 35 35 35h240c29.547 0 35-5.453 35-35V86c0-29.547-5.453-35-35-35h-45V36c0-16.62-5-20-20-20H201zm-48.094 69.813c4.666.02 10.594.187 18.094.187h170c40 0 35-5 35 35v305c0 40 5 35-35 35H171c-40 0-35 5-35-35V121c0-32.5-3.31-35.283 16.906-35.188zM161 101c-5.54 0-10 4.46-10 10v55c0 5.54 4.46 10 10 10h190c5.54 0 10-4.46 10-10v-55c0-5.54-4.46-10-10-10H161zm0 90c-5.54 0-10 4.46-10 10v55c0 5.54 4.46 10 10 10h190c5.54 0 10-4.46 10-10v-55c0-5.54-4.46-10-10-10H161zm0 90c-5.54 0-10 4.46-10 10v55c0 5.54 4.46 10 10 10h190c5.54 0 10-4.46 10-10v-55c0-5.54-4.46-10-10-10H161zm0 90c-5.54 0-10 4.46-10 10v55c0 5.54 4.46 10 10 10h190c5.54 0 10-4.46 10-10v-55c0-5.54-4.46-10-10-10H161z","b":[101.0,16.0,310.0,480.0]},{"n":"battery-pack","d":"M230.218 16c-14.245 0-51.563 11.946-51.563 26.718v26.718h-51.093C99.072 69.436 76 93.326 76 122.874V442.56C76 472.11 99.072 496 127.563 496h256.875c28.49-.002 51.562-23.892 51.562-53.44V122.874c0-29.547-23.072-53.437-51.563-53.437h-51.093V42.718c0-14.774-37.317-26.718-51.562-26.718H230.22zM256 122.875V256h102.657L256 442.563V309.438H153.343L256 122.875z","b":[76.0,16.0,360.0,480.0]},{"n":"car-battery","d":"M73 81v46h46V81H73zm320 0v46h46V81h-46zM25 145v16h462v-16H25zm0 34v252h462V179H25zm382 21h18v23h23v18h-23v23h-18v-23h-23v-18h23v-23zM64 223h64v18H64v-18z","b":[25.0,81.0,462.0,350.0]},{"n":"car-key","d":"M285.628 42.475c-39.602 0-73 28.513-73 65 0 18.43 8.528 34.82 22.066 46.533l8.473-16.67c-7.876-8.202-12.54-18.667-12.54-29.863 0-25.37 23.91-47 55-47s55 21.63 55 47c0 17.403-11.253 33.046-28.356 41.154l-7.482 21.556c1.9-.462 3.774-.986 5.613-1.58l9.158 16.013c-10.326 7.263-20.32 16.266-31.034 27.472l81.35 179.392c50.265 2.318 98.764-24.335 123.754-68.01L385.8 158.635c-20.166 4.027-36.39 9.054-50.875 16.598l-8.09-14.144c19.057-11.615 31.793-31.09 31.793-53.613 0-36.487-33.398-65-73-65zm-122.666 5.947c-2.66.03-5.454.47-8.152 1.348-6.17 2.004-11.39 6.134-13.66 10.59l-.288.57-64.904 92.297c-2.135 4.452-2.382 10.947-.457 16.97 1.97 6.157 6.045 11.305 10.202 13.422l143.682 73.16c4.072 2.075 10.59 2.405 16.648.427 5.945-1.94 10.996-5.885 13.403-10.492l25.36-74.26c.05 0 .1.003.15.004l6.327-18.23c-.086.008-.175.01-.26.018l4.905-14.365.29-.568c2.27-4.456 2.54-11.12.55-17.282-1.99-6.162-6.1-11.355-10.434-13.562l-32.078-16.333c-6.543 8.178-8.55 19.868-.346 30.87l2.11 3.532 10.288 5.4-8.256 16.214-.146-.07-8.118 15.97c.045.023.09.043.135.065l-6.303 12.376-101.59-51.728 18.606-36.538 4.082-8.02 30.854 15.712c1.556-9.81 4.922-19.248 10.335-28.404L172.103 50.31c-2.514-1.28-5.72-1.925-9.14-1.888zm217.928 131.38l24.082 43.82-71.864 39.49-19.748-35.93-4.334-7.887 71.864-39.492zm-7.106 24.444L333.472 226.4l6.742 12.27 40.312-22.154-6.742-12.27zM114.5 218.482L93.63 259.475l69.508 35.392 20.873-40.992-69.51-35.393zm297.214 17.41l24.08 43.817-71.863 39.49-19.745-35.93-4.334-7.887 71.864-39.492zm-7.106 24.442l-40.314 22.154 6.744 12.27 40.313-22.154-6.742-12.27zM99.72 282.774h-.002L18.372 442.53l6.123 18.83 77.264-151.737 16.038 8.168-77.262 151.735 22.375-7.275 12.968-4.217-6.986-21.556 21.496-6.97L83.392 408l21.52-6.998-5.37-16.504 41.17-80.852-40.992-20.873z","b":[18.4,42.5,475.3,427.1]},{"n":"cardboard-box","d":"M185.424 52.607L30.404 130.04l55.375 55.317 155.017-77.43-55.373-55.32zm141.152 0l-55.373 55.32 155.018 77.43 55.376-55.316-155.02-77.433zM256 120.45l-9 4.497v142.715l9 4.496 9-4.496V124.947l-9-4.496zM86.482 207.605l-57.59 71.917 139.545 77.45 72.358-72.286-154.313-77.08zm339.036 0l-154.313 77.08 72.358 72.287 139.544-77.45-57.59-71.916zM247 303.93l-75.436 75.36-78.562-43.6v44.058L247 456.67V303.93zm18 0v152.74l153.998-76.922v-44.06l-78.562 43.603L265 303.93z","b":[28.9,52.6,454.2,404.1]},{"n":"cardboard-box-closed","d":"M256 73.32L74.6 155.1l82.3 37.1 173.2-85.5L256 73.32zm95.4 42.98l-173.2 85.5 77.8 35.1 181.4-81.8-86-38.8zM61.7 169v182L247 434.6v-182L61.7 169zm388.6 0L265 252.6v182L450.3 351V169z","b":[61.7,73.3,388.6,361.3]},{"n":"compass","d":"M203.97 23l-18.032 4.844 11.656 43.468c-25.837 8.076-50.32 21.653-71.594 40.75L94.53 80.594l-13.218 13.22 31.376 31.374c-19.467 21.125-33.414 45.53-41.813 71.343l-42.313-11.343-4.843 18.063 42.25 11.313c-6.057 27.3-6.157 55.656-.345 83L23.72 308.78l4.843 18.064 41.812-11.22c6.693 21.225 17.114 41.525 31.25 59.876l-29.97 52.688-16.81 29.593 29.56-16.842 52.657-29.97c18.41 14.216 38.784 24.69 60.094 31.407l-11.22 41.844 18.033 4.81 11.218-41.905c27.345 5.808 55.698 5.686 83-.375l11.312 42.28 18.063-4.81-11.344-42.376c25.812-8.4 50.217-22.315 71.342-41.78l31.375 31.373 13.22-13.218-31.47-31.47c19.09-21.266 32.643-45.738 40.72-71.563l43.53 11.657 4.813-18.063-43.625-11.686c5.68-27.044 5.576-55.06-.344-82.063l43.97-11.78-4.813-18.063L440.908 197c-6.73-20.866-17.08-40.79-31.032-58.844l29.97-52.656 16.842-29.563-29.593 16.844-52.656 29.97c-17.998-13.875-37.874-24.198-58.657-30.906l11.783-44L309.5 23l-11.78 43.97c-27-5.925-55.02-6.05-82.064-.376L203.97 23zm201.56 85L297.25 298.313l-.75.437-40.844-40.875-148.72 148.72-2.186 1.25 109.125-191.75 41.78 41.78L405.532 108zm-149.686 10.594c21.858 0 43.717 5.166 63.594 15.47l-116.625 66.342-2.22 1.28-1.28 2.22-66.25 116.406c-26.942-52.04-18.616-117.603 25.03-161.25 26.99-26.988 62.38-40.468 97.75-40.468zm122.72 74.594c26.994 52.054 18.67 117.672-25.002 161.343-43.66 43.662-109.263 52.005-161.312 25.033l116.438-66.282 2.25-1.25 1.25-2.25 66.375-116.592z","b":[23.7,23.0,466.0,466.0]},{"n":"cpu","d":"M151 22v32h18V22h-18zm48 0v32h18V22h-18zm48 0v32h18V22h-18zm48 0v32h18V22h-18zm48 0v32h18V22h-18zM131.7 73L73 131.7v248.6l58.7 58.7h248.6l58.7-58.7V131.7L380.3 73H131.7zm60.3 46h128v18H192v-18zM22 151v18h32v-18H22zm436 0v18h32v-18h-32zm-339 32h274v146H119V183zm-97 16v18h32v-18H22zm436 0v18h32v-18h-32zm-321 2v110h238V201H137zM22 247v18h32v-18H22zm436 0v18h32v-18h-32zM22 295v18h32v-18H22zm436 0v18h32v-18h-32zM22 343v18h32v-18H22zm436 0v18h32v-18h-32zm-266 32h128v18H192v-18zm-41 83v32h18v-32h-18zm48 0v32h18v-32h-18zm48 0v32h18v-32h-18zm48 0v32h18v-32h-18zm48 0v32h18v-32h-18z","b":[22.0,22.0,468.0,468.0]},{"n":"empty-hourglass","d":"M388.656 21.406L76.876 72.063 80.56 95l311.813-50.656-3.72-22.938zM375.312 66.03l-18.437 3 16.25 100.282c-7.01 4.713-11.034 13.208-9.594 22.094.474 2.913 1.5 5.587 2.94 7.97 5.55-4.228 12.173-7.207 19.5-8.407h.06c2.25-.367 4.475-.546 6.69-.564.737-.006 1.485 0 2.217.03 4.273.182 8.436.995 12.375 2.345.62-2.72.724-5.61.25-8.53-1.433-8.843-7.885-15.59-15.968-17.875L375.314 66.03zM332.406 73L148.25 102.938c9.082 42.138 25.73 78.544 45.72 103.843 22.553 28.546 48.246 42.31 71.874 38.47 23.628-3.84 43.653-25.027 56.03-59.25 10.974-30.34 15.237-70.14 10.532-113zM123 107.03l-18.438 3 16.344 100.72c-6.837 4.75-10.734 13.14-9.312 21.906.457 2.82 1.446 5.43 2.812 7.75 5.593-4.288 12.283-7.297 19.688-8.5 2.25-.365 4.474-.545 6.687-.562.74-.006 1.488 0 2.22.03 4.293.183 8.482.983 12.438 2.345.56-2.633.644-5.403.187-8.22-1.456-8.977-8.087-15.82-16.344-18L123 107.03zm269.938 102.032c-1.288.012-2.592.13-3.907.344-14.024 2.28-23.4 15.275-21.124 29.313 2.276 14.036 15.257 23.403 29.28 21.124 14.026-2.28 23.402-15.275 21.127-29.313-1.992-12.282-12.182-20.98-24.094-21.436-.427-.017-.853-.035-1.283-.03zM141 250c-1.287.012-2.59.13-3.906.344-14.025 2.28-23.4 15.275-21.125 29.312 2.275 14.038 15.255 23.404 29.28 21.125 14.025-2.278 23.4-15.274 21.125-29.31-1.99-12.284-12.182-20.982-24.094-21.44-.424-.015-.85-.034-1.28-.03zm134.656 13.844c-2.244.054-4.472.265-6.687.625-23.63 3.84-43.654 25.057-56.033 59.28-11.165 30.868-15.416 71.534-10.312 115.25L387 409.062c-8.967-43.092-25.812-80.345-46.156-106.093-19.735-24.98-41.883-38.67-62.938-39.126-.752-.017-1.502-.018-2.25 0zm144.094 6.03c-5.567 4.238-12.213 7.213-19.563 8.407-7.386 1.2-14.665.472-21.312-1.81-.606 2.7-.72 5.57-.25 8.467 1.447 8.927 7.996 15.75 16.188 17.97l16.562 102.187 18.438-3-16.594-102.313c6.896-4.736 10.864-13.16 9.436-21.967-.47-2.896-1.477-5.567-2.906-7.938zm-252.063 41.032c-5.54 4.187-12.143 7.128-19.437 8.313-7.352 1.193-14.597.476-21.22-1.783-.666 2.79-.83 5.742-.343 8.75 1.427 8.8 7.816 15.528 15.844 17.844l16.532 102.064 18.438-3-16.53-101.875c7.103-4.692 11.2-13.24 9.75-22.19-.484-2.975-1.542-5.71-3.032-8.124zM452.844 417.28L141.063 467.94l3.687 22.937 311.813-50.656-3.72-22.94z","b":[76.9,21.4,379.7,469.5]},{"n":"heavy-timer","d":"M25.563 18.344C111.623 205.977 310.53 404.92 498.219 491 412.14 303.367 213.25 104.405 25.56 18.344zm233.218.312c-10.107 20.728-14.86 46.41-14.28 71.813-15.772 1.7-31.34 5.638-46.188 11.843 5.73 4.408 11.444 8.887 17.125 13.437 9.92-3.34 20.137-5.587 30.438-6.75 1.915 14.952 5.78 29.334 11.53 42.03.66.582 1.312 1.17 1.97 1.75 6.285-13.29 10.402-28.54 12.375-44.405 16.632 1.05 33.113 4.906 48.688 11.594-6.722 15.56-11.044 31.775-12.125 47.25 13.05-8.806 25.095-20.867 35.312-34.72 8.055 5.35 15.706 11.58 22.813 18.688 5.105 5.105 9.738 10.51 13.937 16.125-14.324 10.39-26.802 22.724-35.844 36.125 16.357-1.143 33.54-5.89 49.908-13.282 7.71 15.614 12.458 32.306 14.28 49.25-17.628 1.644-34.678 5.926-49.374 12.813.753.84 1.5 1.687 2.25 2.53 14.29 6.336 30.652 10.278 47.53 11.813-.937 12.132-3.4 24.164-7.343 35.812 4.543 5.688 9.04 11.39 13.44 17.125 7.026-16.736 11.175-34.384 12.467-52.22 23.276-.292 46.424-5.053 65.407-14.31-19.094-9.313-42.4-14.07-65.813-14.314-1.95-19.638-7.352-39.006-16.28-57.062 20.534-11.98 38.688-27.967 50.75-45.844-21.718 1.517-44.895 9.384-65.688 21.375-4.918-6.693-10.386-13.106-16.437-19.156-8.01-8.01-16.624-15.04-25.72-21.064C366.3 95.8 374.454 72.146 376 50c-18.6 12.55-35.16 31.694-47.28 53.25-17.77-7.727-36.628-12.197-55.658-13.406.488-25.2-4.255-50.63-14.28-71.188zM109.564 191.062c-6.392 15.302-10.39 31.39-12 47.657-1.793-.055-3.58-.095-5.376-.095-24.04 0-48.083 4.783-67.687 14.344 20.957 10.22 46.978 14.954 72.656 14.25 1.352 18.746 5.878 37.285 13.563 54.78-22.225 12.198-42.04 29.117-54.907 48.188 22.76-1.583 47.09-10.154 68.624-23.125 5.965 8.947 12.892 17.454 20.782 25.343 5.925 5.927 12.205 11.285 18.75 16.125-12.562 21.234-20.848 45.084-22.407 67.408 18.357-12.387 34.734-31.193 46.812-52.407 17.742 8.846 36.757 14.286 56.063 16.376.04 23.938 4.824 47.856 14.343 67.375 9.438-19.348 14.222-43.02 14.345-66.75 18.31-1.175 36.447-5.383 53.625-12.592-5.738-4.4-11.467-8.864-17.156-13.407-12.14 4.104-24.692 6.595-37.344 7.44-1.77-17.947-6.252-35.266-13.47-50.064-7.132 14.626-11.594 31.715-13.405 49.438-16.742-1.95-33.215-6.794-48.625-14.5 6.94-15.83 11.4-32.36 12.5-48.125-12.898 8.7-24.798 20.598-34.938 34.25-5.53-4.154-10.84-8.748-15.875-13.783-7.034-7.034-13.217-14.597-18.53-22.562 13.182-9.96 24.66-21.578 33.124-34.125-14.906 1.037-30.498 5.075-45.53 11.375-6.7-15.384-10.63-31.677-11.813-48.125 15.835-2.107 31.014-6.356 44.188-12.78-13.07-6.375-28.114-10.595-43.813-12.72 1.105-10.857 3.42-21.618 6.938-32.063-4.55-5.68-9.03-11.394-13.438-17.125z","b":[24.5,18.3,473.7,472.7]},{"n":"hourglass","d":"M92.656 19.188v41.5h331.72v-41.5H92.655zM119.5 79.374V433.53h22.28V79.376H119.5zm46.594 0c3.212 43.324 13.312 82.022 27.78 110.906 17.685 35.304 40.845 54.75 64.064 54.75 23.218 0 46.346-19.446 64.03-54.75 14.47-28.883 24.57-67.58 27.782-110.905H166.094zm209.156 0V433.53h22.28V79.376h-22.28zm-117.313 185.22c-23.218 0-46.378 19.415-64.062 54.717-14.835 29.614-25.098 69.562-28.03 114.22H350c-2.933-44.658-13.197-84.606-28.03-114.22-17.686-35.302-40.814-54.718-64.033-54.718zM92.657 452.218v41.467h331.718V452.22H92.655z","b":[92.7,19.2,331.7,474.5]},{"n":"key","d":"M356.5 16.375l-174.906 255.22 1.53 1.06 31.97 22.314 175.062-255.5L356.5 16.374zm90.063 62.22c-20.16 29.418-44.122 23.1-68.25 8.905l-48.688 72.875c21.278 16.55 36.46 35.645 18.594 61.72l42.967 29.468 28.907-42.157-14.72-9.156c-3.167 1.844-6.85 2.906-10.78 2.906-11.85 0-21.47-9.62-21.47-21.47 0-11.847 9.62-21.436 21.47-21.436s21.437 9.59 21.437 21.438c0 .195-.025.4-.03.593l15.906 9.907 17.938-26.218-37.688-23.5 11.03-17.72 14.94 9.313 10.093-16.188 24.25 15.094 17.092-24.94-43-29.436zM141.22 268.624c-.31.01-.628.023-.94.063-.827.104-1.652.284-2.53.562-3.51 1.11-7.4 4.066-10.125 7.938-2.724 3.87-4.16 8.487-4 12.125.16 3.637 1.257 6.338 5.25 9.125l76.594 53.468c3.283 2.293 5.727 2.35 9.124 1.156 3.396-1.192 7.323-4.26 10.125-8.218 2.8-3.96 4.352-8.66 4.31-12.188-.04-3.53-.89-5.787-4.374-8.22L148.03 270.97c-2.546-1.78-4.657-2.42-6.81-2.345zM84.28 312.78c-24.354.41-45.504 9.52-57.655 27.25-16.95 24.737-11.868 59.753 9.625 90.283-1.838 4.72-2.875 9.84-2.875 15.187 0 23.243 19.07 42.313 42.313 42.313 8.635 0 16.692-2.625 23.406-7.125 43.208 18.488 88.07 12.714 108.28-16.782 18.695-27.28 10.884-66.912-16.374-99.312l-63.094-44.03c-14.016-5.107-28.07-7.7-41.25-7.783-.792-.004-1.59-.012-2.375 0zm-8.593 109.126c13.143 0 23.594 10.45 23.594 23.594 0 13.143-10.45 23.625-23.593 23.625-13.142 0-23.624-10.482-23.624-23.625s10.482-23.594 23.624-23.594z","b":[9.7,16.4,479.9,482.8]},{"n":"key-card","d":"M328.9 17.89h-1.8c-8.2.27-18.6 2.98-31.8 8.59L59.61 126.4c-21.18 8.9-31.79 17.7-35.74 27.5-3.95 9.7-2.41 23.4 6.57 44.6l49.95 117.8c8.97 21.2 17.72 31.8 27.51 35.7 9.7 4 23.4 2.5 44.6-6.5l235.7-99.9c13.5-5.7 22.7-11.3 28.6-17.2 4.5 5.5 8.7 11.6 12.2 18.2 3.8 7 6.8 14.4 8.9 21.8-2.5-.3-5.1-.4-7.7-.4-14.1.3-28.1 5.7-39.2 16.2-20.6 19.6-24.2 50.4-10.1 73.8l-50.2 47.7-22-5.9.8 26.1-27.4-.8-2.6 29.4-23.7-4.4 4.6 22.5-17 21.5 62.8-10.9 104.9-100c20.2 7.5 43.7 3.4 60.5-12.6 23.7-22.5 24.9-59.9 2.5-83.9-4.9-5.2-10.4-9.3-16.4-12.3-2.1-12.5-6.7-24.9-12.8-36.3-5.4-10-11.9-19.3-19.2-27 1.1-9.1-1.4-21.1-8.4-37.6L367.4 55.67c-8.9-21.17-17.7-31.78-27.5-35.74-3.2-1.3-6.8-2-11-2.04zm-15.6 50.96l7 16.58-132.6 56.17-7-16.6zm14.9 38.25l7 16.6-73.7 31.2-7-16.6zm-189.7 18.4L208 289.4l-90.3 38.2L51.81 172l-3.51-8.3zm206 17l7 16.6-88.4 37.4-7-16.6zm-215.6 6.6l-57 24.2L127.3 304l57.1-24.2zm255.7 25c13.1 0 23.9 10.3 24.9 23.1-8.9-6-18.7-9.6-28.6-8.9-1.7.1-3.4.3-5.1.7l4 17.6c6-1.4 14.6 1.2 23.8 8.5 0 0 .1 0 .1.1-4.6 5.4-11.5 8.9-19.1 8.9-13.7 0-25-11.3-25-25s11.3-25 25-25zm53.7 120.1c.8 0 1.6 0 2.4.1-.9 8.9-4.1 16.5-10.1 22.5l12.6 12.8c7.7-7.7 12.3-17.1 14.4-27.2 9.7 10.5 9.2 27.1-1.1 36.9-10.4 9.9-26.9 9.4-36.6-1-9.8-10.5-9.2-27.2 1.1-37 4.9-4.6 11.1-6.9 17.3-7.1z","b":[19.9,17.9,476.6,476.2]},{"n":"key-lock","d":"M288.7 30.45h-1.1c-.9.1-1.8.21-2.6.45-3.5.96-6.5 3.01-9 8.19L139.7 319.5c4.7 1.7 9.3 3.7 13.9 5.9 4.5 2.2 8.9 4.6 13.1 7.2L303 52.23c2.5-5.17 2.3-8.82.9-12.09-1.3-3.27-4.2-6.2-7.8-7.95-2.4-1.15-5-1.74-7.4-1.74zm19.6 52.13l-34.1 70.12 16.1 7.9 24-49.3 10.2-20.85zm39.4 1.36l-48.2 98.86 45 21.9 7.7-15.6-21.8-28.4 18.8-38.8 35.7-.4 7.7-15.7zm37.6 191.16c-57 0-103 46-103 103s46 103 103 103 103-46 103-103-46-103-103-103zm0 27a32 32 0 0 1 32 32 32 32 0 0 1-18.5 29l18.5 83h-64l18.5-83a32 32 0 0 1-18.5-29 32 32 0 0 1 32-32zM93.19 329.4c-6.31.1-12.42.7-18.2 1.9-21.01 4.3-37.52 15.6-45.78 32.6-8.26 17-6.97 37 2.6 56.2 9.61 19.4 27.7 37.5 51.81 49.2C107.8 481 133.2 484 154.4 479.6c21-4.3 37.5-15.6 45.7-32.6 8.3-17 7-37-2.6-56.2-9.6-19.4-27.7-37.5-51.8-49.2-16.6-8-33.8-12-49.8-12.2zm-3.31 28.2c6.42 0 13.02 1.5 19.22 4.5 7.9 3.9 14.3 9.8 18.5 16.7 1.8-.2 3.7-.3 5.5-.3 6.4.1 12.9 1.6 19.1 4.6 19.7 9.6 30.1 32.1 21 50.8-9.1 18.7-33.2 24.4-52.9 14.9-7.9-3.9-14.3-9.8-18.5-16.7-8.14.9-16.77-.4-24.69-4.3-19.7-9.6-30.01-32.1-20.92-50.8 6.25-12.9 19.57-19.6 33.69-19.4z","b":[20.9,30.4,467.4,453.6]},{"n":"magnet","d":"M146.063 25.656c-30.86.074-60.556 12.052-85.094 36.313C3.285 119 12.986 194.422 63.905 245.343c12.042 12.04 47.124 35.39 78.75 55.437l36.938-36.967c-23.064-18.33-46.265-37.235-54.375-45.344-38.193-38.193-42.604-75.96-13.44-105.126 29.167-29.166 66.482-24.61 105.126 14.03 8.09 8.09 26.932 31.048 45.22 53.907l37.03-37.03c-20.045-31.623-43.335-66.74-55.375-78.78-30.685-26.483-64.868-39.892-97.718-39.814zM309.375 160.47L273.845 196c13.103 16.54 24.525 31.2 29.5 37.656l31.53-31.53s-10.95-18.314-25.5-41.657zm54.125 33.124c-31.963 73.943-90.175 135.65-167.313 169.22 96.67-10.858 166.86-86.763 167.313-169.22zm58.438 0C378.812 293.36 300.23 376.616 196.155 421.906c130.426-14.648 225.167-117.06 225.78-228.312zm72.53 0C437.49 325.414 333.7 435.407 196.19 495.25c172.33-19.356 297.47-154.66 298.28-301.656zM194.345 275.5l-35.438 35.438c23.348 14.552 41.656 25.5 41.656 25.5l31.532-31.532c-6.443-4.963-21.143-16.33-37.75-29.406z","b":[3.3,25.6,491.2,469.7]},{"n":"metal-detector","d":"M77.16 22.46c-.91 0-2.2.1-2.44.1l-.33.1h-.34c-8.94.49-17.59 2.17-24.97 5.66-3.03 1.43-4.94 3.08-5.79 4.59v.42l.12.19.1.19c.61 1.15 2.35 3.12 4.42 6.28l.31.46c-.08-.13-.16-.24-.24-.36 18.91 25.84 37.69 51.69 56.6 77.51h.1s0 .1.1.1l32.9-12c-3.9-7.77-7.9-15.52-11.9-23.26-3.4 1.5-7.2 2.38-11.1 2.38-14.79 0-27.27-11.81-27.27-26.58 0-10 5.78-18.54 14.07-23.08-1.3-2.58-2.69-5.16-3.99-7.75-.7-1.13-2.8-2.51-5.9-3.34-3.38-.95-7.06-1.36-10.93-1.46h-.54l-3.03-.1zm37.54 27.2c-5.4 0-9.3 3.93-9.3 8.58s3.9 8.58 9.3 8.58 9.3-3.93 9.3-8.58-3.9-8.58-9.3-8.58zM146.1 122l-30.2 10.9c11 15.2 22.1 30.3 33.2 45.5l128.7-28.5-13.6-17.6c-31.7 6.8-63.3 13.5-94.9 20.3l-6.8 1.5-3.1-6.2c-4.4-8.7-8.9-17.3-13.3-25.9zm67.8 60.5c-6.1 1.4-12.1 2.7-18.1 4l98.4 191.7c5.8 11.2 11.6 10.9 14.9 9.2 3.2-1.6 6.9-6.2 1.1-17.4zm115.6 187.9c3.7 14.2-1.5 27.6-12.2 33-12.8 6.6-30.3.3-39.1-17l-7.8-15.1c-12.1 1.7-23 4.3-31.6 7.6-8 3-14.1 6.5-17.8 9.7-3.6 3.3-4.5 5.6-4.5 7.3 0 1.7.9 4 4.5 7.3 3.7 3.2 9.8 6.7 17.8 9.7 15.9 6 39.1 10 64.7 10s48.8-4 64.7-10c8-3 14.1-6.5 17.8-9.7 3.6-3.3 4.5-5.6 4.5-7.3 0-1.7-.9-4-4.5-7.3-3.7-3.2-9.8-6.7-17.8-9.7-10.2-3.9-23.7-6.9-38.7-8.5zm-145.9 33.1c90 75 167.3 67.8 257.6 2-108.6 57.4-182.5 45.4-257.6-2zm-22.8 16.8c87.9 92.5 218.8 91.7 307.9 1.4-107.9 81.3-242.8 56.2-307.9-1.4z","b":[43.3,22.5,425.4,490.3]},{"n":"movement-sensor","d":"M258.75 18.03C176.355 17.888 96.154 60.586 52 137.063 7.275 214.53 11.082 306.688 53.938 378.375 27.51 311.467 33.587 226.695 77 151.5 120.44 76.26 190.892 28.59 262.094 18.062c-1.115-.017-2.23-.03-3.344-.03zm-.156 53.44c-63.895-.113-126.072 33.005-160.313 92.31-34.678 60.068-31.754 131.505 1.47 187.095-20.477-51.88-15.75-117.61 17.906-175.906 33.676-58.33 88.272-95.29 143.47-103.47-.843-.013-1.69-.03-2.532-.03zm-1.313 43.468c-48.386.374-95.35 25.61-121.25 70.468-38.886 67.355-15.73 153.738 51.626 192.625 67.355 38.89 153.738 15.762 192.625-51.592 38.89-67.356 15.73-153.77-51.624-192.657-21.048-12.15-43.95-18.232-66.687-18.81-1.564-.04-3.128-.045-4.69-.032zm-.436 18.593l-.625 29.44c-15.292.162-30.354 4.083-43.75 11.436l-14.97-24.78c18.08-10.315 38.536-15.868 59.344-16.095zm205.437.126c26.47 66.922 20.403 151.74-23.03 226.97-43.388 75.15-113.728 122.802-184.844 133.405 83.465 1.224 165.112-41.574 209.813-119 44.736-77.486 40.95-169.677-1.94-241.374zm-170.936 4.5c9.56 2.71 18.96 6.612 27.97 11.813 9.376 5.413 17.753 11.882 25.092 19.155l-21.812 20.906c-5.592-5.576-11.993-10.52-19.156-14.655-6.183-3.57-12.61-6.36-19.157-8.375l7.064-28.844zm125.062 22.97c20.533 51.897 15.84 117.688-17.844 176.03-33.63 58.248-88.13 95.19-143.25 103.438 64.702.924 127.973-32.262 162.625-92.28 34.698-60.1 31.742-131.587-1.53-187.19zm-246.344 9.843L190 191.75c-4.933 5.196-9.353 11.053-13.094 17.53-4.047 7.01-7.04 14.326-9.094 21.782l-27.843-6.843c2.72-10.083 6.774-19.988 12.25-29.47 5.087-8.814 11.1-16.765 17.843-23.78zm195.25 25.843c9.967 18.082 15.25 38.456 15.25 59.125l-30.812-.657c-.06-14.86-3.695-29.505-10.563-42.655l26.125-15.813zM135.782 258.5l28.78.625c.59 15.018 4.828 29.734 12.344 42.78l-24.844 15.033c-10.23-17.795-15.84-37.938-16.28-58.438zm209.937 24.22l29.936 7.342c-2.7 9.24-6.53 18.317-11.562 27.032-5.41 9.37-11.86 17.76-19.125 25.094L323.686 320c5.165-5.343 9.773-11.398 13.657-18.125 3.574-6.19 6.36-12.6 8.375-19.156zm-151.376 41c4.927 4.53 10.43 8.575 16.47 12.06 7.007 4.048 14.325 7.074 21.78 9.126l-7.094 28.906c-9.744-2.717-19.324-6.67-28.5-11.968-8.816-5.09-16.764-11.1-23.78-17.844l21.124-20.28zm107.437 13.03l15.814 26.156c-17.787 9.875-37.806 15.163-58.156 15.375l.625-30.124c14.59-.475 28.914-4.378 41.718-11.406z","b":[7.3,17.9,501.7,477.4]},{"n":"night-vision","d":"M256 32a120 125 0 0 0-94.666 48.426A160 160 0 0 1 312.8 240a160 160 0 0 1-2.7 28.555A120 125 0 0 0 376 157 120 125 0 0 0 256 32zM82.77 325.59c-20.904.844-42.686 5.52-64.06 14.258C41.442 400.102 102.352 459.58 208 400c-11.572-32.98-37.17-55.623-69.445-66.71a11.164 13.258 0 0 0-3.733-.778 11.164 13.258 0 0 0-11.162 13.258 11.164 13.258 0 0 0 11.162 13.257 11.164 13.258 0 0 0 .317-.013c-3.8 27.26-9.967 50.298-15.478 50.662-12.182.507-29.582-40.02-36.892-84.086zm346.46 0c-7.31 44.066-24.71 84.593-36.892 84.086-5.727-.378-12.157-25.236-15.908-53.873a13.258 21.127 82.128 0 0 11.097.418 13.258 21.127 82.128 0 0 19.112-16.027 13.258 21.127 82.128 0 0-22.745-10.238 13.258 21.127 82.128 0 0-10.4 3.318c-32.3 11.08-57.916 33.73-69.495 66.727 105.647 59.58 166.557.102 189.29-60.152-21.374-8.74-43.156-13.414-64.06-14.258z","b":[18.7,32.0,474.6,427.6]},{"n":"skeleton-key","d":"M133.28 18.22c-21.24.154-43.79 7.987-63.56 23.03-2.745-1.017-5.597-1.656-8.47-1.906-10.406-.905-21.097 3.164-28.125 11.812-8.964 11.03-9.41 26.375-2.22 37.844-19.66 41.305-13.464 86.867 16.157 110.938 22.238 18.072 52.514 20.727 82.376 9.187l5.03-1.938 4.22 3.407 46.562 37.812L201.844 228l-43.875-35.656 11.78-14.5 43.875 35.625 15.344-18.876-43.876-35.656 11.78-14.5 43.876 35.656 16.563-20.375-46.532-37.814-4.218-3.437.875-5.345c5.19-31.587-3.573-60.646-25.812-78.72-13.53-10.994-30.48-16.316-48.344-16.186zm-2.25 25.468l43.845 13.874L139.562 101l-24.25-7.656 15.72-49.656zM57.876 57.78c.548-.016 1.107.013 1.656.064 2.637.243 5.25 1.265 7.5 3.093 6 4.876 6.876 13.408 2 19.407-4.874 5.998-13.406 6.907-19.405 2.03-6-4.875-6.876-13.406-2-19.405 2.666-3.282 6.41-5.068 10.25-5.19zm56.906 59.75l55.376 11.564-32.72 40.25-22.655-51.813zM91.22 123l12.468 22.156-35.313 43.438-22.53-40.063L91.218 123zm155.03 80l-21.97 27.03 125.157 101.69-24.593 30.25 17.562 14.28 19.875-24.47 14.5 11.783-19.874 24.468 13.25 10.783-16.687 20.53-38.126 44.47 14.187 12.156 32.595-38 19.25 8.03 22.906-28.188 14.5 11.782-41.092 50.562 18.187 14.78 61.406-75.56 15.44 12.562 21.967-27.032L246.25 203z","b":[11.2,18.1,483.4,476.9]},{"n":"steampunk-goggles","d":"M175.342 120.424c-39.044-.035-81.332 6.312-136.06 17.752 2.786 11.553 6.997 23.69 11.796 35.318 109.813-26.153 176.85-16.624 239.863 9.426 4.03-13.23 10.572-25.413 18.648-35.72-49.595-18.4-89.864-26.737-134.246-26.776zm186.87 14.11c-6.61-.015-12.398.99-16.982 3.376-.79.68-1.384 1.442-1.734 2.2 18.56 4.702 36.184 9.745 51.613 15.628 5.153-4.313 10.78-8.04 16.833-11.027-17.658-5.47-35.56-10.142-49.732-10.175zm-341.454 5.063c-.89 19.648-5.877 24.76-1.288 59.096 3.89 29.1 15.095 72.413 61.754 109.08-3.517-14.455-5.16-28.265-4.587-43.724-12.806-14.01-25.166-33.834-43.268-85.906-5.63-13.404-8.834-26.383-12.612-38.547zm419.545 14.81c-14.962.188-29.31 7.998-40.727 19.942-13.532 14.156-23.72 34.396-28.234 57.824-4.516 23.427-2.557 45.88 4.785 63.843 5.976 14.622 15.925 26.615 29.078 32.332h.002c4.374 1.97 7.517 3.288 12 3.265 17.044 2.097 33.69-6.112 46.593-19.61 13.533-14.158 23.717-34.396 28.233-57.824 4.515-23.426 2.56-45.88-4.78-63.842-7.343-17.963-20.684-31.962-38.59-35.227a43.482 43.482 0 0 0-8.36-.702zm-113.092.222c-10.18 11.86-18.49 27.615-21.48 44.08 23.602 11.794 41.428 32.958 47.72 54.432.148-8.285.985-16.61 2.5-24.8 3.964-21.45 12.488-42.035 25.476-58.436-15.95-5.543-34.613-10.52-54.215-15.277zm114.053 17.745a25.86 25.86 0 0 1 3.993.41c10.53 1.92 19.517 10.35 25.285 24.46 5.768 14.112 7.704 33.376 3.786 53.706-3.918 20.33-12.897 37.605-23.527 48.726-10.632 11.12-22.15 15.812-32.68 13.892-10.53-1.92-19.517-10.352-25.284-24.463-5.768-14.11-7.702-33.373-3.783-53.703 3.918-20.33 12.894-37.604 23.525-48.725 9.302-9.73 19.28-14.54 28.685-14.302zm-254.61 22.328c-12.71.12-23.37 1.835-31.446 5.224-27.724 11.638-46.134 28.764-55.694 47.918 33.88 11.845 50.606 20.93 105.842 23.778 9.12-26.446 27.087-50.78 55.36-65.742-28.42-7.515-53.842-11.37-74.063-11.177zm272.198 6.406c-10.734 55.258-26.578 72.102-46.178 94.99 17.267 1.758 33.788-9.264 41.44-38.276 4.17-15.812 5.536-19.187 4.74-56.715zm-170.577 12.913l-.066.022c-15.41-.246-30.24 7.657-41.977 19.933-13.532 14.157-23.72 34.395-28.234 57.823-4.515 23.428-2.557 45.882 4.785 63.844 2.92 7.144 6.79 13.658 11.517 19.12 5.406 6.65 11.756 11.463 18.757 14.042 2.697.853 5.81 1.6 8.315 2.065 17.906 3.266 35.553-5.08 49.085-19.237 13.532-14.157 23.717-34.397 28.232-57.825.216-1.492.55-2.617.717-4.068 3.55-21.95 1.418-42.855-5.498-59.775-5.793-14.175-15.324-25.876-27.885-31.788-.753-.37-1.52-.728-2.305-1.068v.062a43.235 43.235 0 0 0-8.4-2.434 43.435 43.435 0 0 0-6.975-.693 8.534 8.534 0 0 1-.067-.022zm-.355 17.98a25.85 25.85 0 0 1 3.992.41c10.53 1.92 19.518 10.353 25.285 24.464 5.768 14.11 7.703 33.373 3.785 53.703-3.918 20.33-12.896 37.604-23.527 48.724-10.63 11.12-22.147 15.813-32.678 13.893-10.53-1.92-19.517-10.35-25.285-24.46-5.767-14.112-7.7-33.376-3.783-53.706 3.918-20.33 12.895-37.603 23.525-48.724 9.302-9.73 19.282-14.54 28.686-14.304zm21.47 32.497c-10.736 55.26-26.58 72.102-46.18 94.99 17.268 1.76 33.787-9.263 41.438-38.275 4.17-15.812 5.537-19.187 4.74-56.715zm-214.96.62c-.603 14.054.94 26.203 4.392 39.542l.516-.246c24.38 16.45 71.385 32.672 100.367 32.224-1.63-10.355-2.06-21.19-1.193-32.12a134.61 134.61 0 0 1 2.087-15.135c-53.818-3.222-74.207-13.057-106.168-24.264zm264.29 28.05c-.09 9.523-1.072 18.374-2.595 25.904a179.038 179.038 0 0 0 19.27 6.586c-6.608-8.252-11.652-17.756-15.186-27.88-.53-1.522-1.022-3.06-1.488-4.61zm-246.27 40.3c4.936 5.788 10.722 11.266 17.384 16.3 29.055 21.964 58.6 30.283 89.398 34.95-4.006-5.177-7.465-10.95-10.33-17.138-1.89-4.08-3.525-8.36-4.93-12.783-32.872-.606-63.45-8.824-91.523-21.33z","b":[14.9,120.4,481.7,273.7]},{"n":"stopwatch","d":"M179.594 20.688v41.406h143.25V20.687h-143.25zM256.03 82C143.04 82 51.25 173.727 51.25 286.656c0 112.93 91.788 204.656 204.78 204.656 112.994 0 204.75-91.728 204.75-204.656C460.78 173.73 369.025 82 256.03 82zm0 35.625c93.42 0 169.126 75.665 169.126 169.03 0 93.368-75.706 169.564-169.125 169.564-93.417 0-169.155-76.197-169.155-169.564 0-93.366 75.736-169.03 169.156-169.03zm76.19 20.28l-72.47 107.5c10.67 1.036 20.516 6.045 27.625 13.814l44.844-121.314zm-85.533 1.064v45.31c3.077-.275 6.196-.405 9.344-.405 3.155 0 6.263.13 9.345.406v-45.31h-18.688zm-88.53 36.655l-13.22 13.22L177 220.874c3.992-4.784 8.432-9.198 13.22-13.188l-32.064-32.062zm195.75 0l-32.063 32.063c4.786 3.99 9.196 8.403 13.187 13.187l32.064-32.03-13.188-13.22zm-98.344 81.22c-2.08.01-4.195.243-6.313.686-16.948 3.544-27.7 20.005-24.156 36.94 3.544 16.932 20.02 27.698 36.97 24.155 16.946-3.543 27.7-20.004 24.155-36.938-3.102-14.816-16.104-24.925-30.658-24.843zM108.28 277.31V296h45.314c-.278-3.08-.406-6.192-.406-9.344 0-3.146.13-6.27.406-9.344H108.28zm250.157 0c.277 3.075.438 6.197.438 9.344 0 3.153-.16 6.264-.438 9.344h45.344v-18.688H358.44zm-60.062 6.72c.993 10.522-1.968 20.742-7.813 28.937l124 19.092-116.187-48.03zM176.97 352.405l-32.032 32.03 13.218 13.22 32.063-32.03c-4.798-4-9.253-8.424-13.25-13.22zm158.093 0c-4 4.796-8.423 9.22-13.22 13.22l32.063 32.03 13.188-13.22-32.03-32.03zM246.688 389v45.313h18.687V389c-3.082.278-6.19.438-9.344.438-3.147 0-6.266-.16-9.342-.438z","b":[51.2,20.7,409.5,470.6]},{"n":"usb-key","d":"M394.8 30.88l-65 65.03 86.3 86.29 65.1-65-86.4-86.32zm-6.3 36.04l17 17-12.8 12.72-17-17 12.8-12.72zm-82.8 30.4l-11.3 11.28 109 108.9 11.3-11.2-109-108.98zM263.3 103L23.4 342.9v60.5l85.2 85.2h60.5l240-239.9L263.3 103zm164.9 3.6l16.9 17-12.8 12.6-16.9-17 12.8-12.6z","b":[23.4,30.9,457.8,457.7]},{"n":"walkie-talkie","d":"M71 32v135h18V32H71zm256 0v135h18V32h-18zm-208 95.604V167h18v-39.396h-18zm256 0V167h18v-39.396h-18zM57 185v99.27l16 16V487h110V300.27l16-16V185H57zm256 0v99.27l16 16V487h110V300.27l16-16V185H313zm-96 7v80h16.432v-80H217zm256 0v80h16.432v-80H473zm-393 7h96v18H80v-18zm256 0h96v18h-96v-18zM80 231h96v18H80v-18zm256 0h96v18h-96v-18zM80 263h96v18H80v-18zm256 0h96v18h-96v-18zm-224 41a24 24 0 0 1 24 24 24 24 0 0 1-24 24 24 24 0 0 1-24-24 24 24 0 0 1 24-24zm256 0a24 24 0 0 1 24 24 24 24 0 0 1-24 24 24 24 0 0 1-24-24 24 24 0 0 1 24-24z","b":[57.0,32.0,432.4,455.0]},{"n":"bowie-knife","d":"M59.938 17.75L15.78 61.906l32.064 32.032L92 49.78 59.937 17.75zM93.218 75L74.376 93.844c17.814 31.92 50.57 65.266 80.78 83.812l21.72-21.72C157.975 125.16 124.423 92.678 93.22 75zM240 119.25L112.812 246.438l13.313 13.312 127.188-127.188L240 119.25zm4.938 48.844l-74.97 74.97 11.97 11.967c5.18-4.87 11.826-7.28 18.468-7.28 6.903 0 13.8 2.61 19.063 7.875 10.32 10.324 10.515 26.965.593 37.53l132.718 132.72c35.123 35.124 93.42 77.742 141.72 66.75-23.436-21.284-81.765-106.71-71.656-146.188l-40.688 7.25 7.656-40.062-40.562 7.156 8.094-39.592-40.063 7.625 7.626-40.063-40.53 7.156 7.75-40.625-47.188-47.186z","b":[15.8,17.8,478.7,485.9]},{"n":"stiletto","d":"M62.5 17.28c-9.747.288-20.824 5.23-29.844 14.25-15.192 15.193-18.838 36.194-8.125 46.907 7.99 7.988 21.716 8.027 34.47 1.22 16.167 30.05 42.154 57.687 71.438 76.374-18.77 24.156-29.97 54.48-29.97 87.376h18.688c0-28.9 9.828-55.474 26.344-76.53l2.156 39.405C274.5 320.554 402.09 428.196 496.062 494.94c-65.54-95.294-176.99-224.638-288.687-348.407l-38.97-2.124c20.764-15.68 46.638-24.967 74.72-24.97V100.75c-32.2.002-61.945 10.725-85.844 28.78-18.696-29.383-46.39-55.48-76.53-71.686 6.795-12.748 6.796-26.423-1.188-34.407-4.352-4.352-10.393-6.352-17.062-6.156z","b":[13.8,17.1,482.2,477.9]},{"n":"plain-dagger","d":"M43.53 15.75c-15.73 0-28.31 12.583-28.31 28.313 0 14.086 10.092 25.644 23.5 27.906L42.687 68 68.81 41.906l2.626-2.625C69.188 25.86 57.63 15.75 43.53 15.75zm33.72 44.125l-17 17c15.885 39.37 43.45 66.684 78.75 87.406 8.167-8.585 16.65-16.898 25.438-24.936-22.488-35.103-51.535-62.294-87.188-79.47zM322.594 79.03l-51.25 4.314c-79.356 48.134-143.878 108.1-186.72 186.53l-4.31 51.47 44.155-18.656-2.94-34.094-.25-3.063 1.626-2.624c35.94-58.47 79.93-109.41 141.5-141.25l2.406-1.25 2.688.25 34.125 2.906 18.97-44.53zm-62.438 66.376c-10.008 5.886-19.5 12.338-28.562 19.313 46.688 47.93 87.208 108.588 114.72 166.5l11.248 23.717-23.718-11.28c-57.995-27.554-117.918-67.57-165.688-113.907-7.155 9.404-14.028 19.174-20.625 29.28 101.918 94.91 227.05 177.304 347.845 234.69-57.063-120.125-140.038-246.18-235.22-348.314zm-43.03 31.22c-13.37 11.703-25.72 24.58-37.282 38.436 39.36 38.452 88.085 72.83 136.687 98.844-26.054-48.633-60.754-97.847-99.405-137.28z","b":[15.2,15.8,480.2,478.0]},{"n":"curvy-knife","d":"M57.656 16.156C42.71 16.533 31.24 29.793 24.5 44.813 6.05 85.91 32.88 81.803 71.156 90.374 79.272 66.585 86.96 48.042 94.72 31.53 87.197 27.1 79.315 22.944 71 19.126c-4.708-2.162-9.158-3.074-13.344-2.97zm52.907 25.5c-7.026 15.13-13.945 32.076-21.344 53.688 10.168 3.41 20.723 8.157 31.155 15.094 11.68-12.212 23.456-21.498 35.28-29.063-13.287-14.6-28.152-27.967-45.093-39.72zm57.28 53.97c-11.064 6.804-21.837 15.1-32.718 26.343 11.416 10.345 22.372 23.944 32.125 42.124 7.94-13.026 16.59-23.73 25.625-33.125-7.722-12.28-15.997-24.11-25.03-35.345zm104.876 6.655c-21.823 9.456-42.608 20.63-59.908 35.126-.123.117-.25.227-.375.344-13.47 12.74-25.593 27.446-36.28 48.72-2.3 5.677-4.237 11.678-5.72 18.03 21.49 66.477 64.75 126.913 119.5 172.094 33.212 37.003 79.484 67.087 129.47 89.03C300.828 433.35 196.2 335.897 155.124 217.563c-13.287 6.835-27.93 11.178-42.03 11.625 77.753 185.39 256.893 319.184 382.28 238.657-161.46-55.25-192.335-204.99-257.28-326.344 12.505-8.307 26.713-15.444 42.06-22.094l-7.436-17.125z","b":[6.0,16.1,489.3,532.3]},{"n":"machete","d":"M485.813 19.125l-85.594 28.563c5.54 36.314 1.39 77.714-19.095 122.937-25.507 56.312-75.953 118.53-163.53 186.22l-11.25-14.908c85.803-66.357 133.95-126.46 157.75-179 17.45-38.53 22.02-72.994 18.81-103.687L170.94 295.063l-22-29.125-14.907 11.25 23.095 30.562-.25.188 34.22 44.968c.022-.018.038-.044.06-.062l11.814 15.625.968 1.374 6.843 8.97-21 35.155 16.032 9.592L230.032 383l3.25-5.406-.126-.156c149.192-98.997 283.78-234.44 252.656-358.313zm-27.407 211.563c-3.195 44.583-12.58 64.095-21.875 78.03-4.663 6.994-9.53 13.964-9.53 23.032 0 18.143 14.388 33.094 32.53 33.094 18.144 0 33.126-14.95 33.126-33.094 0-10.064-6.316-17.154-11.78-24.72-9.717-13.458-18.577-32.888-22.47-76.342zm-85.03 83.156c-4.187 58.39-16.517 83.938-28.688 102.187-6.11 9.164-12.47 18.28-12.47 30.158 0 23.76 18.865 43.343 42.626 43.343 23.76 0 43.375-19.582 43.375-43.342 0-13.182-8.283-22.467-15.44-32.375-12.724-17.626-24.305-43.055-29.405-99.97zM142.03 319.28c-4.855 3.834-9.67 7.734-14.405 11.72 3.36 9.22 7.55 20.726 11.875 32.72 3.4 9.423 6.637 18.544 9.594 26.905 8.9-9.123 18.042-17.753 27.5-25.875l-34.563-45.47zm-29.53 24.876c-7.328 6.596-14.497 13.383-21.53 20.344l25 63.594c6.146-7.627 12.39-14.988 18.75-22.094-.052-.145-.075-.26-.126-.406-3.47-9.91-8.09-22.787-12.688-35.53-3.423-9.494-6.464-17.82-9.406-25.908zm-35.844 34.97c-8.362 8.813-16.52 17.888-24.47 27.218l32.19 64.28c6.026-8.72 12.082-17.21 18.25-25.405l-25.97-66.095zm-37.5 42.968c-6.48 8.057-12.824 16.29-19.03 24.687 2.195 26.79 25.804 46.102 46.093 51.064 2.042-3.18 4.103-6.317 6.155-9.438l-33.22-66.312z","b":[20.1,19.1,496.8,478.7]},{"n":"switchblade","d":"M226.652 235.381l21.57-19.723c-21.518-19.505-39.248-5.543-42.497-.644-10.142 15.208 9.633 9.177 20.927 20.367zm92.283 51.446c-3.208 4.817-20.418 18.384-41.47.25l19.64-21.53c11.065 12.509 32.21 5.71 21.83 21.28zm-29.21-87.57C446.324 42.738 486 24.645 486 24.645s-15.457 42.311-171.996 198.923zM34.808 440.584c10.868-7.484 10.733-3.654 23.408-15.01l.26.26 28.961 28.961.26.26c-11.253 12.612-7.267 12.456-14.98 23.553a20.304 20.304 0 0 1-31.058 2.793l-9.717-9.717a20.315 20.315 0 0 1 2.866-31.1zm189.767-180.881l53.387-48.654 24.29 24.29-48.684 53.367zm-154.36 154.38l28.962 28.961 141.104-141.103-28.962-28.962zM186.802 308.49a11.969 11.969 0 1 1 0 16.931 11.969 11.969 0 0 1 0-16.93z","b":[31.9,24.6,454.1,456.8]},{"n":"fork-knife-spoon","d":"M48 34v144c0 16 32 32 32 32 0 112-16 176-16 208 0 16 0 32 16 48s16 16 32 0 16-32 16-48c0-32-16-96-16-208 0 0 32-16 32-32V34h-18v96h-21V34H87v96H66V34H48zm202 0c-16 0-16 16-16 16v272h.4c-4.6 45.8-10.4 76.8-10.4 96 0 16 0 32 16 48s16 16 32 0 16-32 16-48c0-22.1-7.6-59.5-12.4-117.5C287.9 270.4 298 232.2 298 194c0-48-25.8-137.6-48-160zm166 0a64 96 0 0 0-64 96 64 96 0 0 0 47.9 92.8C398.8 326.9 384 387.2 384 418c0 16 0 32 16 48s16 16 32 0 16-32 16-48c0-30.8-14.8-91.1-15.9-195.1A64 96 0 0 0 480 130a64 96 0 0 0-64-96z","b":[48.0,34.0,432.0,448.0]},{"n":"meal","d":"M445.588 56l-.026 384.352c6.881 11.323 14 15.677 19.97 15.648 5.924-.028 12.967-4.434 19.714-15.418L466.82 244.27l-.215-2.391 1.475-1.906c21.174-27.169 28.573-74.108 22.533-113.81-3.02-19.852-9.342-37.82-18.195-50.522-7.424-10.652-16.28-17.447-26.828-19.641h-.002zm-372.375.004l-.016 67.127-12.56-.016V56.008H46.332l.002 67.11H33.756v-67.11h-14.57v103.228c-.001 11.417 6.23 17.748 16.04 21.662l4.06 1.622-.09 4.37c-2 84.57-3.977 169.139-5.962 253.708C40.074 451.79 47.1 456.028 52.95 456c5.85-.028 12.87-4.377 19.623-15.432-2.315-84.547-4.63-169.096-6.941-253.644l-.12-4.4 4.073-1.606c10.324-4.106 17.039-11.074 17.039-21.676V56.004h-13.41zM256 95A161 161 0 0 0 95 256a161 161 0 0 0 161 161 161 161 0 0 0 161-161A161 161 0 0 0 256 95z","b":[19.2,56.0,477.5,400.0]},{"n":"pistol-gun","d":"M79.238 115.768l-28.51 67.863h406.15l-.273-67.862h-263.83v55.605h-15v-55.605h-16.68v55.605H146.1v-55.605h-17.434v55.605h-15v-55.605H79.238zm387.834 15.96v40.66h18.688v-40.66h-18.688zM56.768 198.63l20.566 32.015L28.894 406.5l101.68 7.174 21.54-97.996h115.74l14.664-80.252 174.55-3.873-.13-32.922H56.767zM263.44 235.85l-11.17 61.142h-96.05l12.98-59.05 12.53-.278-2.224 35.5 14.262 13.576 1.003-33.65 24.69-16.264 43.98-.976z","b":[28.9,115.8,456.9,297.9]},{"n":"colt-m1911","d":"M237.58 213.41a48.65 48.65 0 0 1 2.09-14.63h-17.15a1.45 1.45 0 0 0-1.37 1.37v14.58a15 15 0 0 0 1 6.15c.1 0 .26-.1.38-.1h15.58a59 59 0 0 1-.53-7.37zM145.16 396l-2.07 13.22-106.72-16.69 2.11-13.48 106.06 16.86zm249.29-246.22H86.71c2.08-37 19.18-47 19.18-47h378.27v32.53c-59-2.45-81.32 6.47-89.71 14.47zm89.59.92h.12v27.08h-80v-16.77c4-3.09 20.68-12.82 79.87-10.31zM27.84 361.78l119.12 19s25.79-87.28 36.14-115.79c6.14-16.95 29.91-20.21 41.32-20.21h31.32c16.06 0 29.42-13.69 30.42-30.92l-.2-23.08a7 7 0 0 1 7.2-7h96v-18H83.64c-3.18 4.32-9.37 6.14-21.27 7.24-27.3 2.54-21.28 19.3-21.28 19.3a37.51 37.51 0 0 1 4.56-.29c9.55 0 27.65 2.63 39.74 17.75 14.49 18.08-38.28 94.73-57.55 152zm178.32-161.63a16.16 16.16 0 0 1 16.37-16.37h37.31a16.12 16.12 0 0 1 16.32 16.37v14.58c0 12-9.11 22.05-18.32 22.05h-35.32c-12 0-16.37-9.89-16.37-22.05v-14.58zm-155 151.53a10.23 10.23 0 0 1-1.73-10.49c12.36-30.23 55.41-128.32 70.86-161.48 6.48-13.9 35.77-14.41 52.31-8.65 14.25 5 21.13 14.74 18.4 26.15-5.46 22.81-36.94 120.87-52.6 165.22-1.33 3.78-4.7 6.15-10 7.05a45.81 45.81 0 0 1-7.46.51c-9.91 0-23.26-1.95-33.24-4-19.89-4-32.18-8.82-36.54-14.31zm83-165.32c-14.86 31.91-55 123.3-69 156.95 4.32 2.21 14.25 5.53 28.85 8.26 15.21 2.84 26.29 3.37 30.81 2.88 15.65-44.71 46-139.46 51.14-160.83.26-1.09.87-3.65-5.17-6.64-5.51-2.73-14.08-4.26-22.36-4-8.68.28-13.37 2.4-14.27 3.38zm5.86 18.66a8.3 8.3 0 1 1 8.3 8.3 8.3 8.3 0 0 1-8.31-8.3zm-30.79 124.15a8.3 8.3 0 1 1-8.3-8.3 8.3 8.3 0 0 1 8.28 8.3zM77.99 116l-4.59 15.93a10.15 10.15 0 0 1-2.94-4.2c-.73-2.39-9.62-17.8-19.42-18.59 10.12-4.61 26.94 6.86 26.94 6.86z","b":[27.8,102.8,456.3,306.4]},{"n":"luger","d":"M42.652 136.716v32.494a24.107 24.107 0 0 0 8.168 18.1h270.5v-50.406a7.302 7.302 0 0 0-7.146-5.978h-81.512a19.33 19.33 0 0 0-18.172-12.768h-58.948c6.208 25.003-12.71 49.193-38.472 49.193S72.39 143.16 78.6 118.16H61.136c-10.223.035-18.49 8.335-18.485 18.558zm409.04 1.554l2.65-3.38 7.896-11.474c3.297-4.768 8.94-4.768 12.236 0l7.615 14.802h8.835v29.344H338.01V138.27h113.703zM39.074 396.064c18.09 15.597 51.33 13.933 71.643 1.366 21.22-13.127 4.11-31.993 32.13-67.606 8.595-10.932 31.41-42.446 51.47-71.06 6.174-8.814 18.035-3.522 43.602 6.607 6.363 1.39 14.48 1.79 18.578 2.132 19.016 0 42.086-17.687 44.218-32.423 2.173-15.016-6.757-19.388 2.828-21.993 3.328-.905 9.26-5.045 9.67-9.067h-41.027c8.512 4.59 14.145 12.518 14.145 21.49 0 14.186-13.99 25.68-31.295 25.68-17.306 0-31.294-11.474-31.294-25.68 0-8.993 5.633-16.9 14.145-21.49H77.754c23.19 20.206 11.09 43.812 2.806 55.412l-52.158 73.24c-14.555 20.452-5.557 49.4 10.672 63.392zm21.14-38.28c0-11.868 14.347-17.81 22.74-9.418 8.39 8.39 2.448 22.74-9.42 22.74-7.357 0-13.32-5.964-13.32-13.32zm188.2-117.13c-9.727-7.012-7.78-25.204-5.018-36.613h12.8c-7.575 8.55-11.452 27.26-7.783 36.615zM140.008 127.64c0 20.447-24.72 30.684-39.177 16.227-14.456-14.456-4.22-39.176 16.227-39.176 12.674 0 22.95 10.276 22.95 22.95z","b":[13.8,104.7,477.1,307.0]},{"n":"revolver","d":"M481.14 125.357c-18.78 5.476-34.912 14.487-46.952 32.973h46.953v-32.973zm-188.915 50.01l-13.125.002-.116 35.74H491.47l-.343-35.74H292.225v-.003zm-29.125.002l-33.07.003-97.298.008c-16.018 27.973-16.89 57.78 1.04 94.07H262.8l.063-20.22H168.09a8 8 0 1 1 0-16h94.8v-22.68h-95.15a8 8 0 1 1 0-16h95.3l.06-19.18zm-161.377.01c-7.834 28.723-12.348 45.61-18.73 58.69-6.78 13.893-15.75 23.88-32.3 41.7C11.077 351.204 17.48 389.416 20.46 432.083c12.07 14.128 29.67 21.282 48.724 23.54 17.703 2.097 36.135-.286 50.816-4.597-.272-47.016 8.213-93.296 40.84-139.84l5.264-7.507 6.724 6.23c18.24 16.9 40.922 21.272 63.205 17.717 22.283-3.555 43.756-15.464 57.254-30.285 9.92-10.894 12.492-23.074 11.66-37.932h-26.115l-.084 26.04h-.695c-9.56 10.992-33.904 24.083-47.803 24.146-13.556.06-35.84-13.197-47.896-24.145H123.88l-2.253-4.266c-20.284-38.435-21.828-74.208-7.06-105.803h-12.844zm-74.88 2.47c7.33 23.547 19.127 43.547 34.825 60.796 2.733-3.822 4.952-7.508 6.945-11.593 2.33-4.772 4.44-10.37 6.715-17.44-.225-.142-.403-.248-.635-.394-7.68-4.854-17.46-11.227-27.117-17.58-10.508-6.916-13.477-8.943-20.734-13.79zm252.09 49.26l-.042 13.66v2.638h82.72V227.11h-82.676zM88.642 293.9c16.474 0 30 13.525 30 29.998 0 16.474-13.526 30-30 30-16.473 0-30-13.526-30-30 0-16.473 13.527-29.998 30-29.998zm0 15.998c-7.826 0-14 6.174-14 14 0 7.827 6.174 14 14 14 7.827 0 14-6.173 14-14 0-7.826-6.173-14-14-14zm-18.025 67.676a13 13 0 0 1 12.625 12.998 13 13 0 1 1-26 0 13 13 0 0 1 13.375-12.998z","b":[11.1,125.4,480.4,332.4]},{"n":"desert-eagle","d":"M440.225 129.522h31.64V115.87H460.02zm-392.75 36.293v-.084a.483.483 0 0 1 0-.084.179.179 0 0 0 0-.126l-.084-.336a13.358 13.358 0 0 0-.913-2.321 22.62 22.62 0 0 0-1.975-3.308 22.389 22.389 0 0 0-1.396-1.775c-.263-.294-.515-.598-.788-.892l-.861-.84a22.861 22.861 0 0 0-1.859-1.618c-.63-.546-1.323-.945-1.995-1.417-.672-.473-1.365-.788-2.027-1.177a16.802 16.802 0 0 0-1.943-.913c-.62-.252-1.197-.546-1.722-.693l-1.375-.441-1.23-.378 1.23-.389 1.438-.441c.567-.189 1.208-.273 1.922-.441a19.627 19.627 0 0 1 2.352-.389c.84-.073 1.765-.22 2.71-.23.945-.011 1.963-.064 2.972 0a31.02 31.02 0 0 1 3.15.314l1.586.263c.525.105 1.05.231 1.554.357 1.05.231 2.048.557 3.035.872.987.315 1.795.65 2.636 1.05a51.393 51.393 0 0 0-5.146 14.555zm158.76 93.671c.167 1.44.377 2.815.64 4.117a29.55 29.55 0 0 0 .966 3.57 15.258 15.258 0 0 0 1.281 2.825 7.193 7.193 0 0 0 .725 1.05 5.954 5.954 0 0 0 .724.84l.672.61c.22.147.42.262.578.357l.493.304-.567-.115c-.189 0-.43-.084-.703-.158l-.903-.367a6.72 6.72 0 0 1-1.05-.599 8.401 8.401 0 0 1-1.187-.872 17.338 17.338 0 0 1-2.457-2.52 32.838 32.838 0 0 1-2.384-3.392 53.451 53.451 0 0 1-2.205-4.032 91.498 91.498 0 0 1-3.844-9.137 143.14 143.14 0 0 1-2.468-7.434 22.82 22.82 0 0 1 11.552-3.833c-.2 3.066-.336 6.3-.326 9.64a84.61 84.61 0 0 0 .462 9.146zm34.654 28.89a9.073 9.073 0 0 0 9.073-9.074v-38.56h5.954v44.525a9.073 9.073 0 0 1-9.073 9.073h-65.381l1.365-5.954h58.051zm236.49-81.837H54.017C44.566 217.04 26 219.886 26 225.44c0 6.816 52.076-8.4 50.973 30.601-1.722 60.782-31.703 60.792-35.988 125.732a13.463 13.463 0 0 0 13.41 14.356h74.402a16.172 16.172 0 0 0 15.847-12.98c10.312-51.162 22.231-98.838 30.916-139.059 3.024-14.019 20.456-20.152 30.538-20.152h236.51a43.37 43.37 0 0 0 34.77-17.4zM101.724 355.962a11.961 11.961 0 1 1-11.961 11.961 11.961 11.961 0 0 1 11.961-11.96zm27.45-70.81a11.961 11.961 0 1 1-11.96-11.961 11.961 11.961 0 0 1 11.971 11.96zM87.17 146.324h385.493A13.379 13.379 0 0 1 486 159.703v20.803a43.57 43.57 0 0 1-.998 9.23H60.15c1.344-5.397 4.043-16.444 4.946-21.307 2.248-12.003 9.903-22.105 22.116-22.105z","b":[26.0,115.9,460.0,280.3]},{"n":"mac-10","d":"M245 340.769h-54v127h54zM27.91 70.459c-.22-9.26 2.32-16.33 7.55-20.81 8-6.85 19.51-5.79 27.48-4.36 2.22.4 106.51 21.75 113.88 22.24a8 8 0 1 1-1.06 15.95c-7.8-.52-113.61-22.12-115.63-22.48-10-1.8-13.3-.1-14.25.71-1.84 1.58-2 6-2 8.38.23 9.61.17 50.69.1 81.69h-16c.1-30.01.15-72.01-.07-81.32zM330 221.609a28.34 28.34 0 0 1-28.2 28.16H266v-16h35.8a12.32 12.32 0 0 0 12.2-12.16v-18.84h16zm-15-160.84h24v16h-4v7h-16v-7h-4zm70 17.16l29-10.1v15.94h-29zm104 50.84v28h-55v-28zm-466 39v57h31.4l-.4-57zm5.15 42.56a7.76 7.76 0 1 1 7.76 7.76 7.76 7.76 0 0 1-7.76-7.76zm221.85-7.56v122h-58v-122zm-98.17 122s5.7-65.28 13.7-81.67c8.63-17.68 5.37-31.33-1.38-40.33H176v122zm21.8-176H418v-49H117.72zm3.1-14a5 5 0 0 1 5.05-5h194.51a5 5 0 1 1 0 10h-194.5a5 5 0 0 1-5.06-5zm0-20a5 5 0 0 1 5.05-5h194.51a5 5 0 1 1 0 10h-194.5a5 5 0 0 1-5.06-5zm-83.35-15l74.25 65H418v22H71v-87zm185.62 103h-11s4.25 13.69 14.12 20.75c-6.06-11.94-3.12-20.75-3.12-20.75z","b":[23.0,42.8,466.0,425.0]},{"n":"walther-ppk","d":"M87.521 127.04c2.74-4.22 5.3-8.36 7.56-12.14a16.24 16.24 0 1 0-16.15 24.7c2.54-3.48 5.39-7.63 8.59-12.56zm46.66-52.82h7.29l6.28 15.05h-20.33zm306.09 5.28l21 7v.82l-21 .15v-8zm-259.62 358.28l-88.38-21.21 3.14-18.35h77.66c-7.24 20 14.2 32.63 7.58 39.56zm306.62-324.56v48h-7v-48zm-203.19 103.8c1.3 22.32 22.53 31.63 22.53 31.63-33-2-30.7-33.74-30.7-33.74l-3.13-3.53a54.07 54.07 0 0 1 12.49-3.52 23.08 23.08 0 0 0-1.19 9.16zm-201.1-56.8h381.29v-56.94l-345.54 2.49s-18.71 34.45-35.75 54.45zm59.87-21.93a12.79 12.79 0 1 1 12.79 12.79 12.79 12.79 0 0 1-12.79-12.79zm97.08 37.93l-19.08 88.11 2.45-.69a14.66 14.66 0 0 1 3.82-.4c13.43-.02 40.15 12.23 70.15 12.23a100.11 100.11 0 0 0 14.9-1c32.79-4.92 46.43-30.55 54.3-60.55 7.73-29.44 87.78-23.66 97-37.66h-223.54zm.39 52.83c0-21 24.51-38 54.74-38s54.74 17 54.74 38-24.51 38-54.74 38-54.74-17.02-54.74-38zm-153.05 7.66c-7.29 27.59-35.59 84.94-44.4 99.87-11.42 19.35-3.81 45.65-3.81 45.65h139.1s17.34-77.15 21.11-95.69a36.68 36.68 0 0 1 1.53-5.41l22.76-104.91H57.631c-22.1 6-44.41 7.64-26.2 26.93a90.43 90.43 0 0 1 17.07-1.78c30.42 0 43.05 19.08 38.77 35.34zm15.23 1.42c9.31-23.58 53.32-36.49 78.15-28.57 16.37 5.22 23.59 18.77 19.3 36.17-6.2 25.2-29.75 119.44-30 120.39l-1.51 6.1h-99.5l-.86-.23a16.8 16.8 0 0 1-10.56-8.51c-3.18-6-2.91-13.78.82-23.1 3.44-8.6 11.41-26.71 19.85-45.89 9.73-22.17 19.82-45.05 24.28-56.36zm73.29-13.37c8.34 2.66 10.92 7.8 8.63 17.1-5.31 21.43-23.15 92.36-28.49 114.36h-84.23c-.62-1-.72-4.31 1.48-9.82 3.34-8.35 11.26-26.37 19.64-45.43 9.81-22.31 20-45.39 24.54-57 5.45-13.8 39.85-25.13 58.4-19.21z","b":[13.2,74.2,474.0,363.6]},{"n":"ak47","d":"M293.558 241.704l-30.06 30.06a167.363 167.363 0 0 0 123.006 23.162l-8.044-40.39a126.157 126.157 0 0 1-84.902-12.832zm-139.303 75.694a3.761 3.761 0 0 0 1.13 2.792l18.666 18.666a4.783 4.783 0 0 0 5.07 1.197c4.703-1.845 8.975 3.075 10.728 11.51l6.375 30.459a9.555 9.555 0 0 0 11.31 7.404l4.23-.905a15.385 15.385 0 0 0 11.918-18.217l-6.757-32.287a10.26 10.26 0 0 1 2.743-9.391l27.217-27.218a12.376 12.376 0 0 0 0-17.502l-11.061-11.062 50.894-50.894-32.278-32.279-33.151 33.152 3.964 3.964-70.64 70.64s-.117 14.91-.358 19.97zm57.834-2.003a9.673 9.673 0 0 1 0-13.68l10.712-10.712a9.673 9.673 0 0 1 13.68 0l1.603 1.604a9.673 9.673 0 0 1 0 13.68l-10.745 10.745a9.673 9.673 0 0 1-13.646-.033l-1.604-1.604zm-100.56 161.21a9.908 9.908 0 0 1-1.952 2.784l-5.145 5.145a5.007 5.007 0 0 1-7.08 0l-42.717-42.717a7.91 7.91 0 0 1-.258-10.912l63.37-69.702.365-.365a10.907 10.907 0 0 1 4.504-2.71l3.59-1.113a11.095 11.095 0 0 0 5.926-4.397l11.71-17.377 23.353 23.353zM384.012 93.991a4.701 4.701 0 0 0-6.648 0l-15.707 15.707-4.38-4.38 20.926-20.926 8.85 2.468a15.126 15.126 0 0 0 14.769-3.914l26.345-26.345-9.109-20.012a6.793 6.793 0 0 1 1.38-7.612l.764-.765c2.718-2.718 7.455-3.05 10.173-.332l15.316 15.316 6.582-6.582 6.408 6.408-6.59 6.59 2.991 2.992-75.76 75.76-12.017-12.017 15.707-15.708a4.701 4.701 0 0 0 0-6.648zm-40.207 24.45l18.575 18.574a7.193 7.193 0 0 1 .423 9.715l-51.875 61.748a7.193 7.193 0 0 1-10.596.458l-23.527-23.528a7.193 7.193 0 0 1 0-10.172l56.811-56.812a7.193 7.193 0 0 1 10.173 0z","b":[54.4,25.2,405.3,459.4]},{"n":"famas","d":"M466.674 16.34L435.78 47.232l14.326 14.326L481 30.664 466.674 16.34zM34.418 445.184l46.577 46.577a13.32 13.32 0 0 0 20.618-2.213l60.15-93.456 51.144-21.74s2.487-22.322 3.033-30.12c.763-10.805 3.966-22.05 11.633-29.718l162.948-162.95a21.086 21.086 0 0 0 0-29.82l-42.563-42.564a17.516 17.516 0 0 0-24.772 0l-170.87 170.87a10.736 10.736 0 0 0 0 15.184l22.775 22.775L34.427 428.675a11.67 11.67 0 0 0-.01 16.51zm153.614-182.737c-5.962-5.963-4.907-16.68 2.392-23.98l125.273-125.274c7.262-7.262 18.018-8.354 23.98-2.392l6.31 6.31L194.344 268.76l-6.31-6.31zm118.933 97.288l20.41-20.41 12.416-32.892-18.385-55.515 7.328-7.33 20.364 61.488a4.636 4.636 0 0 1-.057 3.09l-13.31 35.405a4.636 4.636 0 0 1-1.063 1.65l-22.512 22.51c-.282.283-23.952 18.885-23.952 18.885-22.107-10.37-32.467-38.345-26.12-56.56 2.827-8.12.04-12.98-4.643-15.194l20.798-20.797zm-78.224 30.47l39.353 39.353-28.228 44.617-61.817-61.817zM423.837 65.375l8.13 8.13-29.737 29.734-8.13-8.128 29.708-29.708z","b":[34.4,16.3,446.6,475.4]},{"n":"crosshair","d":"M119 48v23.72C94.81 75.6 75.6 94.81 71.72 119H48v18h23.72c3.87 24.2 23.09 43.4 47.28 47.3V208h18v-23.7c24.2-3.9 43.4-23.1 47.3-47.3H208v-18h-23.7c-3.9-24.19-23.1-43.41-47.3-47.28V48h-18zm0 42.05V102h18V90.05c14.3 3.36 25.6 14.65 29 28.95h-12v18h12c-3.4 14.3-14.7 25.6-29 29v-12h-18v12c-14.3-3.4-25.59-14.7-28.95-29H102v-18H90.05c3.36-14.3 14.65-25.59 28.95-28.95z","b":[48.0,48.0,160.0,160.0]},{"n":"shotgun","d":"M160.72 16C136 16.11 136 17.875 136 46v300c0 30 0 30 30 30h180c30 0 30 0 30-30V46c0-30 0-30-30-30H166c-1.875 0-3.633-.007-5.28 0zM196 76h120v210H196V76zm-46.656 345A13.333 13.333 0 0 0 136 434.344v48.312A13.333 13.333 0 0 0 149.344 496h213.312A13.333 13.333 0 0 0 376 482.656v-48.312A13.333 13.333 0 0 0 362.656 421H149.344z","b":[136.0,16.0,240.0,480.0]},{"n":"sawed-off-shotgun","d":"M472.133 19.812L162.52 197.03l21.996 34.133L483.97 38.183l-11.837-18.37zm-71.897 93.748l-117.627 75.8 16.35 10.41c45.98-32.88 82.61-61.844 100.483-82.544l.793-3.666zm-134.283 86.535l-100.125 64.523 20.48 12.13c34.023-22.565 66.99-44.805 96.788-65.74l-17.143-10.913zm-118.826 6.277l-6.227 4.012c-6.594 19.98-1.4 36.31 7.81 43.852l20.677-13.323-22.26-34.54zm-23.71 42.045c-5.512 5.532-12.928 13.198-22.288 23.64-17.225 19.212-36.353 43.545-43.47 60.405-18.543 43.928-15.34 97.99-18 147.736 2.41 7.08 5.408 9.92 8.197 11.137 2.96 1.292 6.896 1.194 11.74-.824 9.393-3.91 19.696-15.595 22.262-25.282-.174-2.232-.92-12.117-1.237-25.643-.356-15.14-.246-33.002 2.63-46.297 5.15-23.82 13.395-49.19 30.268-69.05 10.193-11.993 27.132-22.48 41.92-30.848 4.68-2.65 8.665-4.724 12.415-6.65-19.88-12.29-36.656-17.7-44.437-38.323zm-57.75 37.793l-37.638 9.64L43.6 320.01c5.432-11.014 13.33-22.587 22.064-33.8zm125.86 8.82l-1.154.532s-6.765 3.116-16.096 8.043c-.25 10.99-5.59 19.736-12.617 25.5-5.492 4.505-12.02 6.843-17.803 6.695-4.355-.112-8.346-1.367-12.013-4.55-1.8 1.62-3.36 3.18-4.606 4.644-2.444 2.876-4.69 5.96-6.77 9.197 6.78 5.595 14.91 8.5 22.928 8.704 10.763.276 21.213-3.827 29.68-10.773 12.754-10.462 20.973-28.17 18.45-47.99z","b":[28.0,19.8,455.9,472.8]},{"n":"missile-launcher","d":"M490.74 21.411c-8.947.782-20.72 3.22-33.566 7.781-16.386 5.82-34.345 14.758-50.969 25.893l26.783 36.525c15.712-12.52 29.853-26.925 40.428-40.757 8.265-10.811 14.055-21.243 17.324-29.442zm-99.265 44.026L57.609 310.24l8.28 11.291 83.062-60.906 10.643 14.516-83.063 60.906 8.28 11.29 333.865-244.806zm-18.252 92.746L203.164 282.876l13.924 7.15L375.855 173.61zm-48.602 75.316l-35.775 26.234c3.899 3.046 8.821 4.856 14.213 4.856 12.809 0 23-10.191 23-23 0-2.855-.51-5.579-1.438-8.09zm-255.267 7.527L21.26 260.67l25.705 35.057 65.54-48.057zm226.705 40.948v30.615h14v-30.615a40.734 40.734 0 0 1-7 .615c-2.386 0-4.723-.219-7-.615zm-135.065 31.822l-65.54 48.058 25.706 35.06 33.194-39.964zm-117.9 7.09l-11.291 8.279 27.2 37.096 11.29-8.28zm236.965 9.703v78h46v-78zm-18 54.336l-61.426 71.664h23.709l37.717-44.004zm82 0v27.66l37.716 44.004h23.71zm-192 89.664v16h94v-16zm208 0v16h94v-16z","b":[21.3,21.4,469.5,469.2]},{"n":"missile-pod","d":"M17.28 19.938v358.156c3.317-8.267 8.434-16.15 15.47-23.188l91.125-91.156 13.22 13.22-91.157 91.155c-12.13 12.13-15.988 25.728-14.376 39.938 1.613 14.21 9.25 29.032 21.344 41.125l-.187.187 11.436 11.28.03.033c12.058 12.053 26.915 19.562 41.22 21.062 13.724 1.44 26.93-2.196 38.698-13.21-7.038-4.285-14.04-8.858-20.987-13.728-.86.248-1.722.496-2.58.71-17.25 4.34-34.876 2.385-46.55-9.29-11.677-11.676-13.623-29.307-9.276-46.554 4.348-17.248 14.865-35.155 30.464-50.754 20.472-20.473 44.794-32.403 66.656-32.58 11.45-.093 22.59 3.393 30.62 11.424 11.675 11.674 13.63 29.302 9.292 46.55-.198.787-.428 1.577-.652 2.366 4.89 6.997 9.483 14.055 13.79 21.15l56.364-56.37c-7.15-4.354-14.26-9.005-21.316-13.96-.63.175-1.262.36-1.89.52-17.25 4.338-34.877 2.383-46.552-9.292-11.674-11.674-13.63-29.302-9.29-46.55 4.338-17.25 14.847-35.158 30.447-50.758 20.476-20.477 44.825-32.403 66.687-32.58 11.45-.093 22.59 3.393 30.62 11.424 11.675 11.674 13.63 29.302 9.292 46.55-.256 1.017-.546 2.036-.846 3.057 4.81 6.9 9.336 13.857 13.58 20.85l55.48-55.485c-7.43-4.563-14.82-9.454-22.144-14.668-17.174 4.27-34.7 2.285-46.326-9.34-11.672-11.672-13.63-29.293-9.29-46.535 4.338-17.24 14.848-35.143 30.447-50.742 20.472-20.473 44.815-32.434 66.687-32.61 11.45-.094 22.59 3.392 30.62 11.423 11.677 11.676 13.624 29.307 9.277 46.554-.378 1.5-.818 3.006-1.29 4.514 4.677 6.68 9.082 13.417 13.227 20.187l1.055-1.054c12.112-12.115 15.967-25.784 14.342-40.095-1.623-14.298-9.25-29.174-21.312-41.25l-.03-.03-14.033-13.845c-11.52-10.493-25.123-17.107-38.218-18.594-14.21-1.613-27.81 2.246-39.94 14.375l-92.374 92.376-13.187-13.22 92.342-92.342c4.136-4.136 8.563-7.574 13.188-10.407H17.28zM398.085 83.9c-11.34 4.323-23.678 12.192-34.678 23.192-12.36 12.36-20.732 26.38-24.592 38.8 47.35 45.713 100.12 75.737 149.436 88.866-13.436-49.684-44.003-103.422-90.166-150.858zM251.75 135.906l13.188 13.22L150.313 263.75l-13.188-13.188L251.75 135.906zm20.33 74.953c-11.736 4.178-24.657 12.215-36.142 23.702-11.832 11.834-20.044 25.214-24.114 37.233 47.23 45.46 99.815 75.336 148.97 88.42-13.293-49.162-43.36-102.29-88.714-149.356zM145.156 338.15c-11.888 4.12-25.046 12.24-36.72 23.913-11.653 11.654-19.766 24.79-23.89 36.664 47.274 45.557 99.93 75.487 149.147 88.59-13.278-49.096-43.286-102.147-88.537-149.167z","b":[17.3,19.9,471.0,467.4]},{"n":"missile-swarm","d":"M17.34 17.38v34.08C37.24 85.91 61.4 120.5 95.03 151c6.97 24.6 23.57 43.7 46.27 53.9-5.9-8.2-9.4-18.1-9.6-30.1 12 .1 21.9 3.7 30.1 9.6-10.1-22.5-28.7-39-52.9-46-40.28-36.2-66.64-78.82-89.03-121.02zm26.96 0C98.65 32.32 173.5 71.74 240.5 124.5l16.3-11.6C205.6 71.81 149.6 38.58 99.97 17.38zm110.1 0c28.4 8.14 52.8 19.57 75.3 32.83 13 21.96 34.1 36.14 58.6 40.15-7.8-6.38-13.7-15.05-17-26.58 11.7-2.98 22.1-2.09 31.5 1.46-15.5-19.08-37.8-30.23-63-30.76-10.3-6.07-21-11.82-32.3-17.1zm171.3 4.96L321 71.62c-6.1 10.46-12.1 20.92-18.2 31.38-14.6 11.2-26.3 18.7-40.6 29l39.6 22.8h.1l38.3-13.9c37.3 28.7 84.7 43.6 133.5 39.8-21.2-44.6-57.8-78.2-101.5-96.03l-7-39.5zM194.9 148.8l-17.2 46.4c-8.6 8.4-17.2 17.1-25.7 25.7-14.9 5.8-31.2 11.8-46.6 17.5l32.3 32.3 40.6-3.5c28.6 37.3 70.5 64 118.6 72.9-8.9-48.5-35.6-90.5-73.1-119l3.4-40zm123.3 20l-18.2 6.6c17.1 17.7 33.5 38.1 44.3 52.6 1.1 24.4 12.1 46.1 30.6 61.3-3.5-9.5-4.3-19.9-1.4-31.6 11.6 3.3 20.2 9.3 26.6 17.1-4.1-25.4-19-47-42.3-59.9-12-15.9-25.3-31.3-39.6-46.1zM17.34 247.2v49.7c14.05 24.6 33.51 44.5 56.99 61 12.88 23.6 34.67 38.8 60.27 43-7.8-6.4-13.8-15.1-17.1-26.6 11.7-3 22.2-2.1 31.6 1.5-15-18.5-36.3-29.5-60.47-30.7-35.62-23.9-60.18-54.2-71.29-97.9zM441.3 249l-28.7 40.4c-10.5 6-20.9 12.1-31.4 18.1-16.1 1.9-33.2 3.3-49.6 4.8l22.9 39.6 40.1 7.1c17.9 43.5 51.5 80.1 95.7 101.2 4-49.2-10.9-96.7-39.9-133.9l13.7-37.7zm-269.4 83.9l-4.6 49.3c-6.1 10.3-12.2 20.9-18.2 31.4-13 9.6-27 19.4-40.5 28.9l39.6 22.9 38.3-13.9c37.3 28.7 84.6 43.6 133.4 39.8-21.1-44.7-57.7-78.3-101.4-96.1l-7-39.5z","b":[17.3,17.4,477.0,477.7]},{"n":"grenade","d":"M253.713 25.463l-4.16 15.523C147.833 33.02 69.483 164.754 40.46 273.08l11.374 57.45C105.83 169.524 184.77 82.474 254.436 83.35l136.16 36.486 14.424-53.828-151.307-40.543zm164.695 62.78l-4.836 18.05 24.246 6.498c-1.23 1.64-2.35 3.376-3.353 5.175-5.413 9.698-8.35 22.035-8.35 35.55 0 13.513 2.937 25.85 8.35 35.548s14.18 17.628 25.46 17.628c11.278 0 20.043-7.93 25.456-17.627 5.414-9.7 8.352-22.035 8.352-35.55 0-13.512-2.938-25.848-8.35-35.546-4.145-7.425-10.26-13.8-17.956-16.387l.05-.19L418.41 88.24zm-162.88 14.017c-16.805 5.265-33.33 14.11-48.827 26.033l43.484 11.652c8.062-12.484 16.437-23.367 24.978-32.424l-19.635-5.26zm40.638 10.888c-8.584 7.96-17.527 18.798-26.414 32.04l66.496 17.818c-1.075-15.91-3.4-29.77-6.855-40.953l-33.227-8.905zm163.758 5.877c2.23 0 5.697 1.883 9.14 8.05 3.44 6.166 5.98 15.744 5.98 26.44 0 10.694-2.54 20.274-5.98 26.44-3.443 6.166-6.91 8.05-9.14 8.05-2.23 0-5.7-1.884-9.14-8.05-3.442-6.166-5.98-15.746-5.98-26.44 0-10.697 2.538-20.277 5.98-26.443 3.44-6.166 6.91-8.047 9.14-8.047zm-109.528 8.655c2.87 12.113 4.678 25.725 5.418 40.568l48.528 13.004c-7.46-18.074-17.346-33.997-29.266-46.96l-24.68-6.612zm-160.75 15.392c-18.056 17.506-34.11 39.42-46.763 64.79l66.03 17.695c9.335-25.593 19.883-48.854 31.226-68.955l-50.495-13.53zm69.762 18.694c-11.404 19.538-22.43 42.79-32.164 68.703l103.178 27.643c4.528-27.308 6.605-52.958 6.498-75.58l-77.512-20.767zm96.778 25.93c-.228 23.08-2.723 48.5-7.436 75.33l71.076 19.044c1.728-28.298-1.217-55.304-8.1-79.492l-55.54-14.88zm-221.15 37.413c-4.475 10.84-8.35 22.21-11.522 34.048-2.768 10.33-4.893 20.618-6.416 30.797l68.04 18.23c2.17-10.04 4.624-20.227 7.385-30.533 3.164-11.807 6.598-23.282 10.254-34.392l-67.74-18.15zm85.93 23.023c-3.733 11.077-7.225 22.543-10.39 34.355-2.762 10.308-5.183 20.513-7.29 30.56l106.593 28.56c3.198-9.752 6.204-19.8 8.966-30.108 3.165-11.813 5.877-23.488 8.183-34.947l-106.065-28.42zm124.247 33.293c-2.39 11.45-5.15 23.103-8.315 34.91-2.76 10.305-5.73 20.357-8.87 30.137l73.085 19.582c3.77-9.577 7.072-19.547 9.84-29.877 3.173-11.84 5.5-23.623 7.043-35.25l-72.783-19.502zm-230.256 27.3c-2 25.508-.197 50.033 4.86 72.49L173.51 395.6c.822-21.46 3.467-44.693 7.943-69.057l-66.498-17.818zm84.8 22.723c-4.306 24.693-6.634 48.122-7.153 69.267l82.693 22.158c10.122-18.572 19.82-40.026 28.437-63.564l-103.976-27.86zm122.28 32.763c-8.305 23.338-17.63 44.783-27.646 63.78l58.74 15.737c15.605-16.92 29.43-37.258 40.45-60.347l-71.543-19.17zM125.65 402.125c7.774 23.043 19.257 43.167 33.743 58.918l19.636 5.262c-3.55-15.012-5.47-32.33-5.76-51.42l-47.62-12.76zm66.998 17.953c.63 20.52 3.166 38.184 7.387 51.856l33.217 8.9c10.492-9.73 21.52-23.758 32.326-41.215l-72.93-19.542zm92.31 24.733c-9.796 16.388-20.118 30.428-30.698 41.653l24.68 6.613c20.423-6.398 40.43-18.082 58.683-34.152l-52.666-14.113z","b":[40.5,25.5,453.3,467.6]},{"n":"stick-grenade","d":"M121.175 35.074a6.53 6.53 0 0 0-.43.012c-10.66 0-32.88 14.9-55.6 38.27-28.11 28.97-46.379 59.9-40.769 69.15a5.11 5.11 0 0 0 .881 1.09l111.319 104.27c1.7-6.19 4.84-13.15 9.5-21 8.3-14.17 20.89-30.14 35.36-45.03 10.55-10.85 34.5-33.71 55.34-40.9l-111.4-104.309a6.53 6.53 0 0 0-4.2-1.553zm127.32 119.622c-10.66 0-32.87 14.901-55.6 38.271-28.14 28.94-46.398 59.9-40.798 69.16 1.08 1.78 3 2.63 5.51 2.63 6.58 0 17.56-5.68 30.35-15.52l-5.49-4.65-.302-.26-.289-.27a17.77 17.77 0 0 1-3.05-3.77c-6.41-10.58.36-22.061 2.58-25.841a97.41 97.41 0 0 1 13.76-17.56c11.68-12 22-18.099 30.73-18.099a18.24 18.24 0 0 1 12.54 4.86l.25.24.241.25 4.649 4.75c9.26-14.52 13.551-26.41 10.431-31.56-1.08-1.78-3.001-2.631-5.511-2.631zm-22.453 40.095a2.26 2.26 0 0 0-.146.006c-3.69 0-11.39 5.16-19.26 13.25-9.75 10-16.069 20.75-14.129 24a1.77 1.77 0 0 0 .3.38l30.31 25.65a65.53 65.53 0 0 1 13.129-20 64.18 64.18 0 0 1 19.66-13.75l-28.41-29a2.26 2.26 0 0 0-1.454-.536zm42.094 42.074c-1.09.31-2.299.701-3.629 1.221a48.37 48.37 0 0 0-16.781 11.121 47.8 47.8 0 0 0-11.58 19.85l128.23 108.539 48.891 54.33a82.1 82.1 0 0 1 12-15.79 88.85 88.85 0 0 1 17.11-13.64l-57.641-46.529-116.6-119.102zm187.69 176.461a68.43 68.43 0 0 0-19 13.92 62.49 62.49 0 0 0-12.08 17.33l15.33 17c.69-1.35 1.34-2.45 1.79-3.23a97.4 97.4 0 0 1 13.74-17.49c6.068-6.24 11.758-10.869 17.071-13.889l-16.851-13.64zm30.707 25.42a2.06 2.06 0 0 0-.157.01c-3.69 0-11.39 5.16-19.26 13.25-9.75 10-16.07 20.75-14.13 24a2.06 2.06 0 0 0 1.91.91c3.69 0 11.38-5.16 19.26-13.26 9.74-10 16.07-20.75 14.13-24a2.06 2.06 0 0 0-1.753-.91z","b":[18.8,35.1,471.5,441.8]},{"n":"dynamite","d":"M280 67.77c-2.8 2.78-4.1 9.46-.7 20.04 3.4 10.59 11.3 23.59 22.8 35.39 11.5 11.7 24.3 19.9 34.9 23.5 10.5 3.7 17.2 2.4 20-.3 2.8-2.8 4.2-9.5.8-20.1-3.4-10.6-11.3-23.6-22.8-35.32-11.6-11.76-24.4-19.94-34.9-23.57-6.2-1.5-15-4.44-20.1.36zm89.1-1.84c-4 0-6.9 1.05-8.5 2.62-2.8 2.78-4.1 9.45-.7 20.04 3.4 10.58 11.3 23.61 22.8 35.31 11.5 11.8 24.3 20 34.9 23.6 10.5 3.6 17.2 2.4 20-.4 2.8-2.7 4.2-9.4.8-20-3.4-10.6-11.3-23.6-22.8-35.35-11.6-11.76-24.4-19.94-34.9-23.56-4.6-1.59-8.5-2.25-11.6-2.26zM260.4 86.97l-31.2 30.63c5.8 17.4 13.4 32.7 24.2 44.8 12.8 14.5 29.9 24.9 55.1 29.7l1.5.3 27.4-26.8c-2.1-.5-4.2-1.1-6.3-1.9-14-4.8-28.7-14.4-41.9-27.9-13.2-13.5-22.5-28.4-27.1-42.48-.7-2.18-1.2-4.44-1.7-6.35zm-58.3 57.13L81.3 262.4c5.7 16.5 13.2 31.1 23.5 42.7 12.8 14.5 29.9 24.9 55.1 29.7l4 .7 118-115.6c-37-11.4-63-38.6-79.8-75.8zm180 13.8c-4 0-6.9 1-8.5 2.6-2.8 2.8-4.1 9.5-.7 20 3.4 10.6 11.3 23.6 22.8 35.4 11.5 11.8 24.3 19.9 34.9 23.6 10.5 3.6 17.2 2.4 20-.4.7-.7 1.3-1.6 1.8-2.8 13.2 11.3 24.3 26.2 25.3 35.8 1.3 11.7-3.5 21.7-12.8 32.4-9.4 10.7-23.2 21.2-37.4 32-14.1 10.7-28.5 21.6-39.3 34.4-10.7 12.9-17.9 28.7-14.7 46.4 2.9 15.6 11.3 31.8 25.1 42.9 13.7 11.2 33.4 16.8 55.1 9.7l8.6-2.8-5.6-17.1-8.6 2.8c-16.3 5.3-28.4 1.5-38.2-6.5-9.8-8-16.6-20.9-18.6-32.2-2.1-11.6 1.9-21.1 10.7-31.6 8.9-10.5 22.4-21 36.4-31.7 14.1-10.7 28.8-21.7 40-34.5 11.2-12.7 19.2-28.3 17.2-46.1-2.2-20.4-18.9-37.8-35.6-51-4-3.2-8.1-6.1-12.1-8.6-4.2-8.6-10.7-18.1-19.3-26.9-11.6-11.8-24.4-19.9-34.9-23.6-4.6-1.5-8.5-2.2-11.6-2.2zM354 179.7l-27.3 26.8.2 1.5c4.2 25.3 14.3 42.7 28.5 55.8 11.9 11 27.1 19 44.3 25.1l31.3-30.6c-2.1-.5-4.2-1.1-6.3-1.8-14-4.8-28.7-14.5-41.9-28s-22.5-28.4-27.1-42.4c-.7-2.2-1.2-4.3-1.7-6.4zM298.6 234L180.5 349.6l.7 4c4.1 25.3 14.2 42.6 28.5 55.7 11.4 10.6 25.7 18.4 42.2 24.4l120-117.5c-36.8-17.8-63.1-44.6-73.3-82.2zM55.68 287.5c-11.64 9-23.69 22.4-34.25 33.5-2.84 2.8-4.19 9.5-.79 20.1 3.41 10.6 11.32 23.6 22.83 35.3 11.52 11.8 24.36 20 34.87 23.6 10.51 3.6 17.21 2.4 20.04-.4 12.72-12.3 25.72-25.1 36.62-35.8-36.88-11.6-62.65-38.9-79.32-76.3zm95.12 91.2c-12.2 11.4-20.2 19.3-35.8 35.1-2.8 2.8-4.2 9.4-.8 20 3.4 10.6 11.3 23.6 22.8 35.4 11.6 11.7 24.4 19.9 34.9 23.5 10.5 3.7 17.2 2.5 20.1-.3 11.3-10.6 21.6-21.2 32.4-31.8-36.8-17.8-63.2-44.5-73.6-81.9z","b":[17.2,63.0,480.4,433.4]},{"n":"land-mine","d":"M223.688 25.72l21.218 166.78h30.75l21.22-166.78h-73.188zm19.468 184.093v34.25h34.25v-34.25h-34.25zm17.156 79.968c-1.442 0-2.884.04-4.312.064-1.226.02-2.44.057-3.656.094l-1.063.03c-1.3.045-2.587.093-3.874.157-1.203.06-2.403.11-3.594.188-.217.012-.438.017-.656.03-39.48 2.43-74.968 12.954-101.22 25.938-15 7.42-26.97 15.677-34.78 23.25-7.808 7.576-10.78 14.353-10.78 17.314 0 2.96 2.228 7.307 9.686 12.594 7.46 5.286 19.353 10.675 34.407 15.187 30.106 9.025 72.746 14.844 119.843 14.844 47.096 0 89.767-5.82 119.875-14.845 15.053-4.512 26.947-9.9 34.406-15.188 7.46-5.286 9.687-9.633 9.687-12.593 0-2.96-2.972-9.738-10.78-17.313-7.808-7.573-19.78-15.83-34.78-23.25-26.25-12.983-61.764-23.507-101.25-25.936-.22-.015-.437-.017-.658-.03-1.19-.078-2.39-.13-3.593-.19-1.288-.063-2.576-.11-3.876-.155-.136-.006-.27-.028-.406-.033-.23-.007-.458.007-.688 0-1.195-.035-2.388-.074-3.594-.093-1.438-.024-2.89-.063-4.344-.063zm0 18.69c26.39 0 50.255 4.41 66.688 11.03 8.216 3.31 14.52 7.202 18.313 10.813 3.79 3.61 4.906 6.395 4.906 8.78 0 2.386-1.116 5.172-4.908 8.782-1.58 1.506-3.62 3.053-6.03 4.594-4.953-15.806-38.422-28.033-79-28.033-40.555 0-73.986 12.21-78.97 28-2.396-1.533-4.426-3.064-6-4.562-3.79-3.61-4.906-6.396-4.906-8.78 0-2.387 1.115-5.172 4.906-8.783 3.792-3.61 10.097-7.502 18.313-10.812 16.433-6.62 40.297-11.03 66.688-11.03zM77.75 358.25c-22.095 13.71-34.938 30.062-34.938 47.625 0 48.377 97.367 87.594 217.47 87.594 120.1 0 217.468-39.218 217.468-87.595 0-17.54-12.807-33.864-34.844-47.563-.61 10.722-7.856 19.54-17.5 26.375-10.08 7.144-23.57 12.956-39.875 17.844-32.61 9.777-76.607 15.626-125.217 15.626s-92.607-5.85-125.22-15.625c-16.305-4.887-29.764-10.7-39.843-17.842-9.662-6.848-16.915-15.69-17.5-26.438z","b":[42.8,25.7,434.9,467.7]},{"n":"detonator","d":"M25 41v46h94V41H25zm368 0v46h94V41h-94zM137 55v18h110v110h18V73h110V55H137zM73 201v30h366v-30H73zm32 48v190h302V249H105zm151 17l96 150H160l96-150zm-9 38v64h18v-64h-18zm9 75a12 12 0 0 0-12 12 12 12 0 0 0 12 12 12 12 0 0 0 12-12 12 12 0 0 0-12-12zM73 457v30h366v-30H73z","b":[25.0,41.0,462.0,446.0]},{"n":"targeting","d":"M310.537 18.758L295.6 74.506c-13.073-2.813-26.154-4.16-39.067-4.156v18.662c11.306.01 22.76 1.187 34.217 3.59l-14.488 54.066c2.972.543 5.946 1.206 8.916 2.002 3.11.834 6.152 1.798 9.127 2.873l14.502-54.123c11.127 3.643 21.627 8.365 31.425 14.006l9.338-16.174c-11.182-6.454-23.19-11.818-35.918-15.912l16.235-60.582h-19.35zM208.4 76.756c-31.462 8.497-60.265 25.152-83.328 48.181l13.15 13.15c8.15-8.16 17.1-15.426 26.684-21.704l27.936 48.387c5.127-3.557 10.544-6.68 16.19-9.334l-27.948-48.41c10.225-5.174 20.994-9.3 32.133-12.297L208.4 76.755zm179.668 48.105l-13.154 13.156c8.155 8.164 15.418 17.127 21.69 26.722l-48.692 28.114c3.55 5.132 6.664 10.554 9.31 16.205l48.725-28.13c5.168 10.23 9.292 21.003 12.278 32.147l17.97-4.816c-8.473-31.48-25.11-60.31-48.127-83.397zm-292.55 38.574c-6.442 11.175-11.8 23.17-15.885 35.888l-60.737-16.275v19.348L74.8 217.373c-2.805 13.06-4.13 26.126-4.122 39.025H89.33c.008-11.293 1.157-22.734 3.553-34.18l53.847 14.428c.554-3.077 1.233-6.157 2.057-9.232.805-3.005 1.732-5.944 2.762-8.822l-53.843-14.428c3.634-11.116 8.346-21.606 13.973-31.398l-16.162-9.332zm162.023 20.484c-.895.003-1.788.022-2.68.06-30.888 1.26-58.825 22.36-67.23 53.73-10.347 38.61 12.708 78.54 51.317 88.886 38.61 10.345 78.54-12.71 88.885-51.32 10.345-38.607-12.708-78.538-51.316-88.883-6.335-1.697-12.706-2.494-18.975-2.472zm-.01 18.658c1.287 0 2.582.045 3.88.137l-5.498 20.377c.9-.072 1.806-.12 2.725-.12 5.642 0 10.955 1.398 15.623 3.856l5.293-19.617c21.288 9.357 34.11 31.358 31.818 54.456l-19.15-5.168c0 .018.003.036.003.055 0 6.584-1.904 12.722-5.178 17.906l19.332 5.214c-9.793 20.695-31.702 32.98-54.574 30.39l5.385-19.96c-6.583-.28-12.67-2.457-17.74-5.995l-5.59 20.706c-19.83-9.728-31.712-30.68-29.83-52.753l21.054 5.68c-.014-.396-.03-.79-.03-1.19 0-6.18 1.675-11.964 4.587-16.938l-20.882-5.633c8.495-18.616 26.727-30.598 46.777-31.367.663-.025 1.328-.038 1.994-.04zm166.353 53.822c-.02 11.3-1.186 22.75-3.598 34.2l-54.342-14.56c-.547 3.007-1.214 6.02-2.02 9.024-.823 3.074-1.774 6.08-2.833 9.02l54.346 14.563c-3.65 11.117-8.38 21.608-14.024 31.398l16.172 9.338c6.46-11.173 11.833-23.17 15.936-35.89l60.654 16.252v-19.346l-55.805-14.953c2.822-13.065 4.162-26.137 4.17-39.045h-18.657zM95.027 299.672l-17.97 4.814c8.487 31.435 25.118 60.222 48.11 83.278l13.157-13.155c-8.142-8.15-15.396-17.094-21.664-26.67L165.057 320c-3.57-5.118-6.708-10.528-9.377-16.168l-48.37 27.928c-5.166-10.213-9.292-20.965-12.283-32.088zm224.965 47.95c-5.122 3.563-10.534 6.692-16.178 9.355l28.112 48.69c-10.22 5.157-20.98 9.274-32.112 12.255l4.815 17.965c31.454-8.46 60.26-25.07 83.34-48.053l-13.152-13.15c-8.158 8.14-17.112 15.39-26.7 21.652l-28.126-48.715zM218.81 361.08l-14.49 54.07c-11.104-3.64-21.583-8.36-31.363-13.992l-9.338 16.174c11.163 6.446 23.15 11.807 35.855 15.9l-16.293 60.8h19.35l14.993-55.96c13.053 2.815 26.115 4.172 39.01 4.178v-18.674c-11.288-.018-22.725-1.18-34.164-3.584l14.5-54.11c-3.113-.558-6.227-1.244-9.34-2.077-2.97-.796-5.875-1.71-8.72-2.725z","b":[18.9,18.8,475.3,475.3]},{"n":"target-dummy","d":"M304.482 19.73c-19.18.347-39.96 9.122-56.498 25.66-22.422 22.423-30.554 52.63-22.783 76.09-65.956-30.317-59.724-32.208-123.327-73.015-10.072-6.462-19.445-9.412-27.816-9.805-13.953-.655-25.126 5.793-32.135 14.926-11.214 14.613-12.37 36.164 10.95 54.418 31.027 24.286 58.825 41.022 79.015 59.45 20.19 18.43 32.658 40.606 28.355 70.046v.002c-3.16 21.608-13.68 37.998-26.46 51.47-12.78 13.47-27.77 24.476-41.46 36.676-27.38 24.4-50.32 51.77-45.052 114.266 3.327 39.483 34.167 55.107 59.666 52.365 12.75-1.372 23.497-7.357 29.394-17.49 5.897-10.13 7.69-25.42-1.037-47.733h-.002c-7.592-19.416 3.128-40.832 18.368-57.09 15.24-16.26 36.807-28.817 58.852-24.998 6.175 1.07 11.446 4.722 15.056 9.157 3.61 4.435 5.982 9.604 7.955 15.234 3.948 11.262 6.26 24.69 9.117 38.58 5.71 27.777 13.67 55.973 33.068 68.474 37.964 24.468 75.254 17.395 91.902.44 8.325-8.475 11.916-18.84 9.127-31.14-2.788-12.297-12.694-27.158-34.267-41.845-23.664-16.11-32.657-48.282-33.846-80.118-1.188-31.836 5.29-64.08 20.13-84.033 6.878-9.25 17.534-13.128 29.645-17.417 12.11-4.29 26.21-8.48 40.753-14.694 29.086-12.426 59.652-32.204 79.14-76.788 17.078-39.068 3.357-64.292-15.298-73.474-9.327-4.592-20.128-5.156-30.435-.65-10.308 4.505-20.442 14.216-27.45 31.78-13.14 32.932-39.195 51.68-70.414 56.41-8.096 1.225-16.527 1.586-25.223 1.163 7.505-4.07 14.71-9.39 21.25-15.93 29.4-29.4 34.27-72.202 10.87-95.6-10.236-10.237-24.187-15.063-39.105-14.79zm-51.925 131.79c.84-.02 1.683-.017 2.525.007 4.49.13 8.978.873 13.393 2.305 17.656 5.73 29.82 21.068 35.47 39.566 5.65 18.5 5.292 40.598-1.843 62.635-7.136 22.038-19.795 40.148-35.213 51.815-15.42 11.666-34.268 16.947-51.925 11.218-17.657-5.73-29.82-21.067-35.47-39.566-5.65-18.5-5.29-40.6 1.845-62.637 7.135-22.038 19.795-40.148 35.213-51.814 10.84-8.204 23.378-13.25 36.004-13.53zm.21 18.65c-8.075.183-16.6 3.475-24.937 9.783-11.857 8.972-22.66 23.984-28.71 42.666-6.048 18.68-6.098 37.188-1.75 51.42 4.346 14.234 12.583 23.75 23.362 27.25 10.78 3.497 23.022.627 34.88-8.345 11.857-8.972 22.66-23.986 28.708-42.668 6.05-18.68 6.097-37.187 1.75-51.42-4.346-14.232-12.583-23.75-23.363-27.248-2.695-.875-5.48-1.352-8.33-1.434-.534-.016-1.07-.018-1.61-.006zm-7.25 27.643c.412-.01.826-.01 1.24.003 2.203.065 4.426.448 6.62 1.204 8.777 3.022 14.27 10.818 16.682 19.2 2.41 8.383 2.197 17.916-.7 27.415-2.9 9.498-8.015 17.453-14.762 22.87-6.748 5.42-15.967 8.365-24.744 5.343-8.778-3.023-14.27-10.82-16.682-19.202-2.412-8.382-2.2-17.917.7-27.416 2.897-9.498 8.01-17.453 14.76-22.87 4.743-3.81 10.71-6.398 16.886-6.548zm.46 18.63c-.477-.017-.995.038-1.563.192-1.137.307-2.475 1.006-4.082 2.297-3.215 2.58-6.668 7.466-8.586 13.752-1.917 6.285-1.854 12.49-.615 16.795 1.24 4.303 3.2 6.144 4.808 6.698 1.608.554 3.743.337 6.958-2.244 3.216-2.582 6.67-7.467 8.588-13.752 1.918-6.285 1.854-12.49.616-16.793-1.24-4.306-3.2-6.147-4.81-6.7-.4-.14-.837-.23-1.313-.247z","b":[29.6,19.5,467.8,481.4]},{"n":"spyglass","d":"M84.438 20.78c-.414.005-.824.01-1.25.032-2.273.113-4.742.477-7.376 1.094C65.28 24.373 52.858 31.236 42.094 42 31.33 52.763 24.467 65.186 22 75.72c-2.467 10.532-.738 18.23 3.75 22.718 3.93 3.93 10.33 5.763 18.938 4.5-1.82-5.496-1.757-11.592-.407-17.282 2.182-9.194 7.5-18.247 15.314-26.062 7.814-7.816 16.836-13.13 26.03-15.313 2.3-.544 4.695-.876 7.064-.968 3.515-.135 7.022.307 10.312 1.407 1.3-8.664-.52-15.082-4.47-19.032-3.154-3.156-7.896-4.97-14.093-4.907zm9.937 41.126c-.332-.006-.694.01-1.063.032-.98.06-2.08.23-3.343.53-5.057 1.2-11.542 4.728-17.157 10.344-5.616 5.617-9.145 12.1-10.344 17.157-1.2 5.054-.25 7.718 1.03 9l.344.343.312.406 41.344 51.25c4.423-9.226 10.846-18.254 19.03-26.44 8.186-8.183 17.214-14.607 26.44-19.03L99.72 64.156l-.407-.312-.344-.344c-.84-.84-2.273-1.552-4.595-1.594zm85.22 55.344c-.762-.02-1.564-.012-2.376.03-2.168.115-4.54.465-7.064 1.064-10.095 2.394-22.042 9.042-32.406 19.406-10.364 10.364-17.012 22.31-19.406 32.406-2.394 10.095-.727 17.367 3.5 21.594l.344.375.312.375 3.75 4.625c.046-.207.076-.418.125-.625 3.576-15.268 12.593-30.935 26.125-44.47 13.467-13.468 29.05-22.452 44.25-26.06l-4.25-3.44-.375-.343-.375-.343c-2.774-2.775-6.828-4.448-12.156-4.594zm31.186 25.656c-2.895-.01-6.086.374-9.56 1.188-11.122 2.604-24.185 9.838-35.5 21.156-11.318 11.318-18.552 24.378-21.157 35.5-2.117 9.036-1.316 16.178 1.656 21.125l.093.156 48.375 59.94c6.217-18.252 17.894-36.74 34.218-53.064 16.332-16.33 34.835-28.003 53.094-34.22L219.75 144.5c-2.557-1.017-5.562-1.583-8.97-1.594zm99.25 65.344c-.697.007-1.41.027-2.124.063-3.814.188-7.85.798-12.125 1.812-17.098 4.056-36.72 15.005-53.686 31.97-16.965 16.963-27.913 36.586-31.97 53.686-4.055 17.102-1.384 30.74 6.94 39.064l.342.344.313.406.31.406c.4-3.643 1.045-7.318 1.907-11 5.25-22.406 18.652-45.87 38.907-66.125 20.255-20.255 43.718-33.658 66.125-38.906 3.702-.87 7.4-1.513 11.06-1.907l-.436-.344-.406-.314-.344-.344c-5.853-5.852-14.346-8.918-24.813-8.812zm35.22 27.97c-4.95-.034-10.325.6-16.03 1.936-18.262 4.278-39.118 15.898-57.158 33.938-18.04 18.04-29.66 38.896-33.937 57.156-3.19 13.618-2.38 25.28 1.97 34.063l55.874 69.28c.46-3.185 1.058-6.378 1.81-9.593 6.32-26.98 22.565-55.408 47.126-79.97 24.56-24.56 52.96-40.773 79.938-47.092 2.055-.482 4.108-.89 6.156-1.25l-67.53-54.5h-.033c-5.132-2.575-11.256-3.924-18.187-3.97zm103.094 75.5c-.947.005-1.907.017-2.875.06-5.166.236-10.637 1.008-16.345 2.345-22.832 5.348-48.686 19.78-71.03 42.125-22.347 22.345-36.778 48.2-42.126 71.03-5.35 22.833-1.77 41.703 9.905 53.376 7.86 7.862 18.996 12.047 32.406 12.313-.68-.603-1.347-1.225-2-1.876-13.45-13.452-16.224-33.735-11.5-53.906 4.726-20.172 16.757-41.163 34.908-59.313 18.15-18.15 39.172-30.213 59.343-34.938 5.044-1.18 10.086-1.898 15.033-2.093 14.84-.586 28.754 3.505 38.843 13.594.673.672 1.318 1.356 1.938 2.062-.245-13.438-4.44-24.595-12.313-32.47-8.207-8.207-19.98-12.4-34.186-12.31zm8.28 47.717c-.65.005-1.3.032-1.968.063-3.564.167-7.37.687-11.375 1.625-16.024 3.754-34.44 14.003-50.374 29.938-7.822 7.822-14.263 16.238-19.25 24.687 1.697-2.026 3.503-4.003 5.438-5.938 17.012-17.01 38.125-24.96 53.22-21.5-5.877 2.765-11.803 6.865-17.158 12.22-16.19 16.19-21.17 37.454-11.125 47.5 7.735 7.733 22.152 6.587 35.75-1.75-3.07 4.568-6.748 9.03-10.967 13.25-18.512 18.51-41.876 26.32-57.063 20.343 7.814 6.11 19.617 7.906 34.156 4.5 16.025-3.754 34.44-14.003 50.375-29.938 15.936-15.934 26.185-34.35 29.94-50.375 3.752-16.024 1.195-28.71-6.5-36.406-5.413-5.41-13.32-8.293-23.095-8.22z","b":[19.5,20.7,475.3,472.3]},{"n":"first-aid-kit","d":"M256 73c-62.875 0-91.913 11.948-105.273 26.979-11.632 13.086-13.324 30.848-13.59 51.021h30.437c1.634-13.963 7.309-26.44 19.438-34.518C201.703 106.7 223.253 103 256 103c32.753 0 54.311 3.739 68.996 13.54 12.115 8.084 17.788 20.546 19.426 34.46h30.441c-.266-20.173-1.958-37.935-13.59-51.021C347.913 84.948 318.875 73 256 73zm-135 94v16h62v-16h-62zm208 0v16h62v-16h-62zM81.47 201c-13.866 0-28.232 6.837-38.97 17.412C31.762 228.988 25 243 25 256v192c0 14.5 3.485 23.754 9.37 29.633C40.253 483.51 49.53 487 64.063 487h384.387c14.253 0 23.382-3.463 29.219-9.342C483.507 471.78 487 462.5 487 448V256c0-13-6.777-27.05-17.363-37.637C459.05 207.777 445 201 432 201H81.47zM224 256h64v64h64v64h-64v64h-64v-64h-64v-64h64v-64z","b":[25.0,73.0,462.0,414.0]},{"n":"syringe","d":"M112.182 18.393c-.37-.007-.77 0-1.205.023-3.172.16-8.473 2.174-14.688 7.078-9.654 32.85-35.603 60.926-71.335 72.012-3.3 6.59-4.446 11.897-4.215 15.156.268 3.77 1.223 5.062 3.895 6.502 5.342 2.88 21.9 2.56 44.19-10.31l4.843-2.795 4.752 2.944c35.087 21.744 53.66 39.973 72.885 69.553l23.517-23.518c-31.97-18.754-48.732-38.902-68.935-73.91l-2.696-4.67 2.7-4.673c15.082-26.124 14.602-44.643 11.354-50.133-1.42-2.4-2.482-3.214-5.062-3.26zM275.8 87.45c-28.745 0-52.638 21.59-56.323 49.36l-84.444 84.448c-27.773 3.684-49.36 27.58-49.36 56.322 0 31.276 25.553 56.832 56.83 56.832 30.934 0 56.253-25 56.808-55.805l96.89 96.89 13.214-13.216L185.88 238.747l25.31-25.312 93.576 93.574 13.214-13.215-93.574-93.574 12.614-12.613 123.535 123.536 13.215-13.215-96.842-96.842c30.76-.608 55.703-25.906 55.703-56.803 0-31.276-25.553-56.832-56.83-56.832zm0 18.69c21.176 0 38.143 16.968 38.143 38.143 0 21.176-16.967 38.143-38.144 38.143-21.18 0-38.144-16.967-38.144-38.143 0-21.175 16.965-38.144 38.143-38.144zM142.503 239.437c21.177 0 38.142 16.966 38.142 38.142 0 21.176-16.965 38.145-38.142 38.145-21.178 0-38.145-16.97-38.145-38.145 0-21.176 16.966-38.142 38.144-38.142zm263.168 61.544c-5.287 0-10.573 2.044-14.66 6.13l-29.858 29.86-27.183-27.19-13.214 13.214 27.183 27.19-42.594 42.593h-.002c-8.18 8.186-8.176 21.15 0 29.33 8.172 8.175 21.147 8.175 29.326-.005l85.664-85.668c8.18-8.177 8.18-21.147.002-29.322-4.09-4.09-9.378-6.133-14.664-6.133zm-8.352 84.9L384.105 399.1l97.885 97.884 13.215-13.214-97.885-97.885z","b":[20.5,18.4,474.7,478.6]},{"n":"direction-signs","d":"M277.3 35.11l-32.1 2.12-1 32.93 33.6.05-.5-35.1zM151.7 88.04L67.96 118.9 152 169.2l188-6.2 2.4-74.72-190.7-.24zM279.2 183l-38.3 1.3-.8 27.8 39.5 1.2-.4-30.3zm-93.1 45.6l.8 64.2 200.4.9 51.7-29.2-55.8-30.2-197.1-5.7zm51.1 82.5l-5 175.3 50.9.6-2.3-175.7-43.6-.2z","b":[68.0,35.1,371.0,451.9]},{"n":"monkey","d":"M199.53 19.03l-15.81 43.595-47.94-16.906 37.845 43.843c-21.482 15.605-38.455 37.07-48.563 62.062-8.8-3.472-18.373-5.406-28.406-5.406-.67 0-1.334-.018-2 0C52.702 147.284 19 181.725 19 224.062c0 43.008 34.775 77.875 77.656 77.875 19.056 0 36.493-6.887 50-18.313 7.23 6.66 15.522 12.337 24.656 17.063-12.712 16.714-20.686 37.255-21.875 59.593 5.168 5.635 12.93 11.145 23.344 16.033 20.91 9.81 50.94 16.25 84.157 16.25s63.25-6.44 84.157-16.25c10.434-4.897 18.2-10.418 23.375-16.063-1.196-22.333-9.156-42.884-21.876-59.594 9.118-4.72 17.405-10.38 24.625-17.03 13.513 11.425 30.974 18.312 50.03 18.312 42.88 0 77.625-34.867 77.625-77.875 0-43.01-34.744-77.844-77.625-77.844-.67 0-1.334-.018-2 0-9.32.236-18.242 2.122-26.47 5.374-6.306-15.583-15.302-29.785-26.374-42.063l30.563-6.56-63.25-20.75 19.655-28.314-66.438 10.97c-8.427-1.565-17.122-2.376-26-2.376-13.512 0-26.58 1.9-38.968 5.438L199.53 19.03zM95.75 166.75c7.83 0 15.652 1.623 22.938 4.813-1.315 5.45-2.33 11.013-3 16.687-15.55-8.79-35.502-6.516-48.782 6.813-15.997 16.057-15.997 41.915 0 57.968 15.946 16.003 41.523 16.055 57.53.157 2.378 5.172 5.193 10 8.345 14.532-22.403 19.146-56.314 18.1-77.468-3.126-22.243-22.322-22.242-58.768 0-81.094 11.122-11.162 25.784-16.75 40.438-16.75zm322.406 0c14.654 0 29.317 5.588 40.438 16.75 22.243 22.326 22.244 58.772 0 81.094-21.148 21.222-55.062 22.256-77.47 3.125 3.158-4.54 5.935-9.383 8.313-14.564 16.007 15.93 41.607 15.888 57.563-.125 15.997-16.052 15.998-41.91 0-57.968-13.28-13.328-33.232-15.602-48.78-6.812-.67-5.674-1.687-11.237-3-16.688 7.292-3.19 15.106-4.813 22.936-4.812zm-223.22 16.406c20.812 0 37.69 16.908 37.69 37.78 0 20.873-16.878 37.814-37.69 37.814-20.81 0-37.686-16.94-37.686-37.813 0-20.87 16.877-37.78 37.688-37.78zm125.533 3.125c19.97 0 36.155 16.25 36.155 36.282 0 20.032-16.184 36.282-36.156 36.282-19.974 0-36.19-16.25-36.19-36.28 0-20.033 16.216-36.283 36.19-36.283zm-91.158 79.314l18 4.97-9.78 35.498-18-4.968 9.78-35.5zm55.25 0l9.782 35.5-18 4.97-9.78-35.502 17.998-4.968zm78.094 120.156c-4.226 2.705-8.79 5.2-13.625 7.47-24.213 11.362-56.503 18.03-92.092 18.03-35.59 0-67.88-6.668-92.094-18.03-4.822-2.264-9.38-4.743-13.594-7.44 9.62 44.998 53.293 62.564 105.688 62.564 52.407 0 96.112-17.573 105.718-62.594z","b":[19.0,19.0,475.9,429.3]},{"n":"carnival-mask","d":"M411.37 124.355c3.16 13.036 3.345 25.696 1.355 37.852-19.596 15.54-40.52 28.885-59.733 38.029l-1.36-.457c24.217-19.204 45.7-42.1 59.737-75.424zm-310.74 0c14.039 33.324 35.521 56.22 59.737 75.424-.455.154-.908.305-1.36.457-19.212-9.144-40.136-22.488-59.732-38.03-1.99-12.155-1.805-24.815 1.356-37.85zm367.022 11.137c-2.128 12.273-5.158 25.783-8.697 38.996C435.647 198.164 409.74 207.91 384 207.91c-1.774 0-3.725-.191-5.824-.53 31.882-17.768 64.556-43.5 89.476-71.888zm-423.304 0c24.92 28.389 57.594 54.12 89.476 71.889-2.099.338-4.05.529-5.824.529-25.74 0-51.647-9.745-74.955-33.422-3.539-13.213-6.57-26.723-8.697-38.996zm453.25 17.885c-7.066 35.468-21.193 73.969-43.196 106.25C421.706 307.597 372.623 373.844 304 368c-16 0-32-64-48-64s-32 64-48 64c-68.623 5.844-117.706-60.404-150.402-108.373-22.003-32.281-36.13-70.782-43.196-106.25C45.948 203.484 86.801 225.91 128 225.91c21.913 0 39.477-12.627 61.64-18.28 11.082-2.825 21.409-3.978 30.04-2.163 8.01 1.683 20.862 5.71 36.32 14.517 15.458-8.806 28.31-12.834 36.32-14.517 8.631-1.815 18.958-.662 30.04 2.164 22.163 5.652 39.727 18.279 61.64 18.279 41.2 0 82.052-22.426 113.598-72.533zm-147.244 95.535c-28.264-.086-62.951 5.168-62.346 12.435 5.812 69.834 97.853 16 97.976-3.693.039-6.125-16.292-8.683-35.63-8.742zm-188.708 0c-19.338.059-35.669 2.617-35.63 8.742.123 19.694 92.164 73.527 97.976 3.693.605-7.267-34.082-12.521-62.346-12.435zm251.292 107.597a256.804 256.804 0 0 0 14.63 6.62c16.182 6.737 35.272 12.676 56.069 16.693-5.14 1.657-10.72 3.207-17.07 4.342-19.914 3.559-44.712 4.621-69.042 2.095-12.442-1.291-24.758-3.542-36.261-6.787 18.97-4.771 36.193-12.712 51.673-22.963zm-313.875 0c15.48 10.251 32.702 18.192 51.673 22.963-11.503 3.245-23.82 5.496-36.261 6.787-24.33 2.526-49.128 1.464-69.041-2.095-6.352-1.135-11.93-2.685-17.07-4.342 20.796-4.017 39.886-9.956 56.068-16.693a256.8 256.8 0 0 0 14.63-6.62z","b":[14.4,124.4,483.2,264.4]},{"n":"ninja-mask","d":"M255.063 21c-46.697 0-88.406 27.674-117.844 70.656-29.44 42.982-47.25 101.566-47.25 166.094 0 64.527 17.81 123.112 47.25 166.094 29.437 42.982 71.146 70.656 117.843 70.656 46.696 0 88.405-27.674 117.843-70.656 29.44-42.982 47.25-101.567 47.25-166.094 0-64.528-17.81-123.112-47.25-166.094C343.468 48.674 301.76 21 255.062 21zM396.28 200.344c3.365 18.28 5.19 37.527 5.19 57.406 0 18.535-1.594 36.522-4.533 53.688-37.91 12.904-87.436 20.812-141.656 20.812-54.45 0-104.125-8.235-142.186-21.313-2.884-17.014-4.438-34.833-4.438-53.187 0-19.868 1.827-39.103 5.188-57.375 37.903 14.565 87.35 23.25 141.47 23.25 54.136 0 103.183-8.707 140.967-23.28zM177.157 241c-15.137-.162-30.97 3.458-47.375 10.313 14.562 51.423 87.08 42.483 102.157 10.156-17.004-13.822-35.318-20.262-54.78-20.47zm155.75 0c-19.462.208-37.808 6.648-54.812 20.47 15.078 32.326 87.596 41.266 102.156-10.158-16.405-6.854-32.206-10.474-47.344-10.312z","b":[90.0,21.0,330.2,473.5]},{"n":"gas-mask","d":"M364.563 27.5c-24.54 10.796-66.057 18.094-113.875 18.094-47.3 0-89.258-6.898-113.907-17.5C107.477 64.73 97.12 118.44 107 177c10.73 63.596 50.354 119.6 85.688 155.78 17.285-4.952 36.943-7.717 57.843-7.717 20.725 0 40.228 2.72 57.407 7.593 35.5-36.38 75.654-92.59 86.407-155.656 10.04-58.882-.233-112.842-29.78-149.5zm-187.625 80.03c10.768.263 21.255 4.955 29.937 12.282 11.577 9.77 20.607 24.33 25.25 41.657 4.643 17.326 4.078 34.437-1.063 48.686-5.14 14.25-15.398 26.053-29.78 29.906-14.384 3.854-29.174-1.23-40.75-11-11.577-9.77-20.608-24.328-25.25-41.656-4.644-17.327-4.08-34.47 1.062-48.72 5.14-14.248 15.398-26.02 29.78-29.874 3.597-.963 7.224-1.368 10.814-1.28zm146.75 0c3.59-.086 7.216.32 10.812 1.282 14.383 3.854 24.64 15.626 29.78 29.876 5.142 14.25 5.707 31.39 1.064 48.718-4.643 17.328-13.674 31.887-25.25 41.656-11.577 9.77-26.367 14.854-40.75 11-14.383-3.853-24.64-15.657-29.78-29.906-5.142-14.25-5.707-31.36-1.064-48.687 4.643-17.33 13.673-31.888 25.25-41.657 8.682-7.328 19.17-12.02 29.938-12.282zm-148.47 18.657c-1.44.063-2.867.286-4.25.657-7.374 1.976-13.434 8.13-17.062 18.187-3.628 10.058-4.295 23.6-.562 37.532 3.733 13.933 11.08 25.324 19.25 32.22 8.17 6.894 16.47 9.194 23.844 7.218 4.996-1.34 9.37-4.6 12.812-9.688-.557.206-1.108.376-1.688.532-14.782 3.96-31.402-10.042-37.093-31.28-5.692-21.24 1.685-41.665 16.468-45.626 3.214-.862 6.526-.853 9.78-.125-.63-.595-1.265-1.178-1.905-1.72-6.128-5.17-12.326-7.766-18.157-7.905-.486-.012-.957-.02-1.437 0zm148.75 0c-5.83.14-12.028 2.736-18.156 7.907-8.17 6.895-15.516 18.255-19.25 32.187-3.733 13.934-3.065 27.476.563 37.532 3.628 10.057 9.657 16.212 17.03 18.188 7.376 1.976 15.706-.324 23.876-7.22.87-.732 1.748-1.51 2.595-2.343-3.923 1.263-7.97 1.453-11.875.407-14.783-3.96-22.13-24.386-16.438-45.625 5.692-21.24 22.28-35.244 37.063-31.282 1.253.335 2.45.812 3.594 1.375-3.514-5.533-8.07-9.064-13.314-10.47-1.843-.493-3.744-.702-5.687-.656zm-73.437 217.594c-30.047 0-57.177 6.322-76 15.94-18.82 9.616-28.155 21.615-28.155 32.686 0 2.838.615 5.752 1.844 8.656 5.233-4.285 11.252-8.117 17.81-11.468 22.253-11.37 51.873-18 84.5-18 32.63 0 62.25 6.63 84.5 18 6.547 3.344 12.56 7.163 17.783 11.437 1.22-2.894 1.843-5.794 1.843-8.624 0-11.07-9.334-23.07-28.156-32.687-18.822-9.618-45.92-15.94-75.97-15.94zm0 46.5c-30.047 0-57.177 6.322-76 15.94-18.82 9.616-28.155 21.615-28.155 32.686 0 11.07 9.334 23.07 28.156 32.688 18.823 9.617 45.953 15.97 76 15.97 30.05-.002 57.148-6.353 75.97-15.97 18.822-9.617 28.156-21.617 28.156-32.688 0-11.07-9.334-23.07-28.156-32.687-18.822-9.618-45.92-15.94-75.97-15.94zm0 28.19c15.2 0 28.952 2.186 39.75 6.186 5.4 2 10.118 4.412 14 7.813 3.884 3.4 7.25 8.417 7.25 14.467 0 6.05-3.366 11.07-7.25 14.47-3.882 3.4-8.6 5.812-14 7.812-10.798 4-24.55 6.186-39.75 6.186-15.197 0-28.98-2.187-39.78-6.187-5.4-2-10.086-4.413-13.97-7.814-3.882-3.4-7.25-8.418-7.25-14.47 0-6.05 3.368-11.067 7.25-14.467 3.884-3.402 8.57-5.814 13.97-7.814 10.8-4 24.583-6.187 39.78-6.187zm0 18.686c-13.327 0-25.384 2.107-33.28 5.03-3.948 1.464-6.812 3.168-8.156 4.345-.292.256-.263.258-.406.408.143.15.114.15.406.406 1.344 1.177 4.208 2.913 8.156 4.375 7.896 2.923 19.953 5 33.28 5 13.33 0 25.387-2.077 33.282-5 3.948-1.463 6.812-3.2 8.157-4.376.29-.255.26-.257.405-.406-.144-.15-.115-.152-.406-.407-1.346-1.176-4.21-2.88-8.158-4.342-7.895-2.925-19.953-5.032-33.28-5.032z","b":[97.1,27.5,307.3,460.1]},{"n":"meat","d":"M440.156 98.063c-4.05-.11-8.044 1.117-11.656 4-1.542 1.23-3.1 2.884-4.47 4.75-22.9 31.22-48.278 57.33-75.186 81-8.76 14.692 10.695 44.406 25.594 44.406 34.144-12.928 69.617-22.516 106.75-26.314 42.628-4.358 17.688-68.134-26.25-45.47 30.3-22.666 7.094-61.79-14.782-62.374zM310.47 108.156c-6.167-.108-12.215 1.172-17.595 4.28-1.576.912-3.042 1.948-4.406 3.095-.038-.056-.09-.13-.126-.186-79.912 66.402-116.334 73.468-158.22 86.844-6.886 2.2-12.27 7.18-16.5 15.5s-6.892 19.843-7.343 33.125c-.9 26.563 6.935 59.927 23.72 89.03 16.72 28.99 43.37 53.946 67.656 67.126 12.143 6.59 23.682 10.167 32.375 10.436 8.694.27 13.915-1.95 17.782-7.375 30.986-43.45 89.343-69.052 156.157-92.25-.005-.006.003-.023 0-.03 2.012-.663 3.967-1.51 5.842-2.594 8.2-4.738 13.535-12.897 16.282-22.125 2.747-9.227 3.22-19.75 2.03-31.25-.953-9.233-3.033-19.127-6.155-29.374-5.916 1.366-11.628 3.157-17.908 5.47 2.835 9.25 4.69 17.978 5.5 25.81 1.007 9.74.403 18.06-1.375 24.033-1.777 5.972-4.412 9.338-7.718 11.25-3.308 1.91-7.543 2.505-13.595 1.06-6.052-1.443-13.55-5.07-21.47-10.81-15.838-11.482-33.334-31.223-47.624-56-14.29-24.78-22.61-49.838-24.624-69.314-1.006-9.738-.403-18.027 1.375-24 1.78-5.973 4.414-9.37 7.72-11.28 1.653-.957 3.52-1.58 5.75-1.782.557-.05 1.147-.067 1.75-.063 1.81.014 3.824.272 6.094.814 6.05 1.444 13.518 5.04 21.437 10.78 8.218 5.957 16.884 14.166 25.314 24.126 5.07-4.055 9.34-8.25 13.406-13.188-8.97-10.46-18.366-19.26-27.75-26.062-9.354-6.78-18.733-11.61-28.094-13.844-2.34-.558-4.674-.935-7.03-1.125-.885-.07-1.776-.108-2.657-.124zm7.967 34.188c-.438.024-.86.063-1.28.125-17.327 2.54-14.97 36.035 5.03 74.56 20 38.528 50.52 67.576 67.844 65.032 5.995-.88 9.263-5.687 10.658-12.875-1.67 2.187-3.847 3.484-6.72 3.907-15.316 2.248-42.316-23.093-60-57.156-17.682-34.064-19.254-63.91-3.937-66.157 3.638-.53 7.69.417 12.345 2.782-8.68-6.8-17.353-10.583-23.938-10.218zM102 325.124c-16.555 1.844-35.304 3.26-57.063 4.376-49.128 2.523-25.555 71.576 30.094 52.22-49.365 29.9 3.86 86.927 26.97 46.75 10.362-18.016 21.88-33.79 34.375-47.814-8.42-9.644-16.078-20.224-22.563-31.47-4.52-7.835-8.462-15.898-11.812-24.06z","b":[-4.2,98.0,528.0,370.7]},{"n":"steak","d":"M294.818 43.27c-.957.003-1.917.014-2.88.035-46.15.993-96.56 23.687-128.614 54.82-41.965 40.758-91.926 108.163-118.896 173.047-13.486 32.442-21.17 64.22-19.93 91.305 1.24 27.085 10.723 49.188 32.54 65.546 15.71 11.78 28.638 10.986 44.814 2.72 16.175-8.268 34.067-25.324 52.433-45.405 36.732-40.162 74.766-92.452 121.008-107.932 61.794-20.685 98.278-34.43 120.926-46.785 22.646-12.353 31.392-22.466 40.74-39.08 7.302-12.974 8.365-26.067 5.03-39.882-3.334-13.814-11.388-28.167-22.45-41.62-22.127-26.903-56.253-49.946-83.706-60.003-12.75-4.67-26.652-6.79-41.016-6.764zm3.418 24.26c21.21-.103 42.145 4.338 58.493 16.677 47.554 35.895 86.454 58.96 54.377 111.88-32.076 52.923-177.004 58.17-217.56 20.06-1.663-10.596-12.613-91.45 10.176-121.653 12.52-10.007 54.02-26.77 94.513-26.965zm-119.87 43.66c-1.058 1.99-7.086 83.113-10.403 98.937-19.397 9.728-71.78 21.074-73.92 6.977 3.618-16.654 37.1-71.993 84.324-105.915zm278.095 26.248c1.196 3.294 2.213 6.627 3.026 9.996 4.2 17.4 2.736 35.916-6.84 52.933-10.34 18.374-23.007 32.528-47.808 46.057-24.8 13.53-61.8 27.285-123.832 48.05-36.878 12.346-75.83 61.892-113.438 103.012-18.804 20.56-37.417 39.008-57.525 49.285-5.895 3.014-12.05 5.204-18.322 6.418 3.03 1.73 6.143 3.338 9.165 4.728 8.116 3.734 16.547 5.668 17.197 5.686 14.037-.65 29.08-8.326 44.816-21.024 15.82-12.764 32.063-30.284 48.493-48.676 32.86-36.784 65.744-77.523 104.444-90.478 61.817-20.694 98.67-34.278 121.465-46.543 22.794-12.264 31.4-22.235 40.044-39.028 9.733-18.912 10.244-32.256 4.506-46.28-4.33-10.583-12.968-21.73-25.39-34.135zm-314.546 95.466c33.96-.19 69.09 16.75 104.688 36.092-71.258 37.318-141.89 180.326-187.133 133.99-18.206-20.105-19.433-119.77 30.147-153.564 17.043-11.616 34.51-16.418 52.297-16.518zm-36.463 73.213c-5.436.103-10.92 1.77-14.74 4.787-12.34 9.753-21.72 34.145-11.206 45.844 10.057 11.19 35.46 5.816 44.728-6.012 8.262-10.544 5.69-31.088-4.32-40.02-3.632-3.24-9.023-4.7-14.46-4.6z","b":[23.3,43.2,464.3,420.4]},{"n":"sliced-bread","d":"M141.97 14.438c-42.682.018-82.778 11.23-101.282 31.187-30.652 33.058 1.238 86.79-22.72 168.063-8.613 29.22 74.178 97.934 122.188 151.625-3.125-8.49-3.153-17.208-1.156-24.688v-.688l.47-1.437c17.554-53.406 12.688-81.692-1.25-125.313-5.194-16.25-4.224-31.73 1.78-44.812 6.004-13.082 16.6-23.578 29.625-31.813 26.05-16.47 62.195-24.613 98.313-25.656 4.514-.13 9.006-.157 13.5-.062 23.43.492 46.31 4.073 65.906 11.22-5.792-6.04-12.343-12.123-19.344-18.22-41.85-24.153-155.507-18.392-208.03 16.125 33.065-44.226 114.77-66.194 184.53-35.407-8.257-6.463-16.738-12.862-25.125-19.126C238.262 40.686 123.365 46.27 70.47 81.03 102.665 37.97 181 15.983 249.5 43.28c-28.753-19.812-69.177-28.86-107.53-28.843zm132.78 115.03c-2.095.006-4.183.034-6.28.095-33.57.97-67.18 9.115-88.845 22.812-10.832 6.848-18.573 14.884-22.656 23.78-4.085 8.898-4.943 18.814-.94 31.345 14.19 44.4 19.552 79.75 1.657 135.22v.217l-.468 1.407c-1.297 3.94-1.203 11.898 1.81 17.47 3.016 5.57 7.7 9.873 19.75 9.873 7.3 0 16.987-.02 25.97-.03 21.836-16.527 47.35-35.183 66.375-49.97 10.12-7.864 22.774-9.62 34.125-9.312 11.35.31 21.408 2.634 28.563 6.063 19.722 9.444 37.077 15.635 55 20.125-.143-.97-.34-1.807-.563-2.47-16.222-47.974-24.11-90.38-8.406-137.718 4.08-12.298 3.23-21.644-.688-29.844-3.918-8.198-11.416-15.53-22.125-21.593-18.74-10.607-46.79-16.7-76-17.406-2.085-.05-4.185-.067-6.28-.06zm28.344 201.563c-.55 0-1.084.015-1.625.033-7.572.246-14.643 2.085-18.876 5.375-24.37 18.94-58.597 43.71-82.28 62.187-4.67 3.642-6.184 6.524-6.564 8.03-.38 1.51-.246 2.165.813 3.658 2.116 2.985 9.79 6.963 17.406 6.906 54.724-.405 97.39 12.696 133.405 30.03 19.53 9.4 43.448 9.722 66.72 4.063 23.27-5.66 45.638-17.31 61.03-30.188 15.392-12.878 22.33-26.61 21.063-33.938-.634-3.664-2.582-6.99-8.75-10.656-6.17-3.664-16.564-7.015-31.688-8.655-49.392-5.353-83.953-11.502-128-32.594-3.328-1.594-12.244-3.98-21-4.217-.547-.015-1.108-.03-1.656-.032zm196.25 90.5c-4.112 4.84-8.944 9.494-14.22 13.908-17.895 14.973-42.335 27.645-68.593 34.03-26.256 6.387-54.58 6.498-79.25-5.374-34.164-16.444-73.45-28.57-125.155-28.188-7.96.06-15.778-1.69-22.313-5.406 1.91 16.26 11.684 30.165 29.344 30.03 51.222-.39 81.323 12.19 117.813 25.533 57.38 20.98 162.374-11.593 162.374-49.125V421.53z","b":[9.4,14.4,490.0,492.6]},{"n":"fruit-bowl","d":"M150.902 268.233h-42.1a23.347 23.347 0 0 1 42.1 0zm67.359-13.292a114.847 114.847 0 0 1 1.203-16.31 23.335 23.335 0 0 0-18.68 29.602h18.295a113.38 113.38 0 0 1-.77-13.292zm-94.532-86.027c-15.637-15.637-36.638-32.164-55.162-32.164h-1.54l.975 19.246c8.913-.433 23.287 8.3 39.489 24.056q1.528 1.48 2.995 2.972a42.58 42.58 0 0 1 8.083-.95 42.34 42.34 0 0 1 5.208-13.172zm24.37-18.933a68.706 68.706 0 0 0 6.928-9.743 71.172 71.172 0 0 0 7.11-16.55 70.174 70.174 0 0 0 2.706-17.695 67.72 67.72 0 0 0-1.672-16.575 69.043 69.043 0 0 0-2.01-7 63.499 63.499 0 0 0-2.236-5.594 53.963 53.963 0 0 0-1.889-3.728c-.228-.433-.469-.782-.601-1.01l-.217-.35-.36.18c-.241.121-.614.302-1.035.542a52.092 52.092 0 0 0-3.609 2.177 52.07 52.07 0 0 0-4.811 3.609 69.031 69.031 0 0 0-5.377 4.907 67.72 67.72 0 0 0-10.104 13.232 70.174 70.174 0 0 0-6.964 16.49 71.16 71.16 0 0 0-2.719 17.779 68.562 68.562 0 0 0 1.672 16.575 66.337 66.337 0 0 0 4.234 12.546c.47 1.058.927 1.96 1.336 2.718a42.713 42.713 0 0 1 19.666-12.522zm342.413-43.903c-.228-.133-.59-.35-1.022-.578a43.443 43.443 0 0 0-3.777-1.804c-1.6-.674-3.5-1.42-5.641-2.105a69.031 69.031 0 0 0-7.049-1.84 67.72 67.72 0 0 0-16.611-1.263 70.174 70.174 0 0 0-17.634 3.127 71.172 71.172 0 0 0-16.31 7.41 68.562 68.562 0 0 0-13.003 10.428l-.542.578a69.633 69.633 0 0 1 12.618 22.168 68.67 68.67 0 0 0 11.307.421 71.16 71.16 0 0 0 17.646-3.091 70.174 70.174 0 0 0 16.322-7.362 67.72 67.72 0 0 0 13.003-10.428 69.02 69.02 0 0 0 4.811-5.497c1.384-1.78 2.55-3.44 3.477-4.932.926-1.492 1.635-2.718 2.093-3.609.24-.433.409-.817.517-1.058l.18-.373zm-85.642-66.06c-.433-1.697-.854-3.296-.986-4.018l-18.981 3.488c.252 1.384.685 3.043 1.275 5.329 2.814 10.898 9.298 36.013 1.48 58.23a69.97 69.97 0 0 1 16.165 11.595c12.787-28.928 4.511-61.032.999-74.625zM180.179 476h122.618a159.112 159.112 0 0 0 159.112-159.112v-29.41H21.103V316.9A159.112 159.112 0 0 0 180.179 476zm245.163-221.059a93.545 93.545 0 0 0-26.03-64.845 50.4 50.4 0 1 0-94.05-25.26 93.822 93.822 0 0 0-66.745 103.445h185.839a94.604 94.604 0 0 0 .986-13.34zm-244.718 6.748a42.412 42.412 0 0 1 10.609-28.074 23.383 23.383 0 0 0-43.555 6.014 42.81 42.81 0 0 1 23.492 28.28 23.287 23.287 0 0 0 9.622-2.407 43.845 43.845 0 0 1-.168-3.813zm-79.388-14.963a23.383 23.383 0 0 0-41.522 21.495h28.688a42.665 42.665 0 0 1 12.822-21.495zm79.845-66.686a23.371 23.371 0 0 0-43.543 5.642 42.905 42.905 0 0 1 19.51 18.427 42.292 42.292 0 0 1 11.44-2.153 42.653 42.653 0 0 1 12.58-21.916zm29 7.819a23.383 23.383 0 0 0-22.685 17.537 42.905 42.905 0 0 1 19.534 16.924 42.316 42.316 0 0 1 16.335-3.271h.854a111.36 111.36 0 0 1 7.373-17.177 23.383 23.383 0 0 0-21.41-14.013zm-69.524 26.402a23.36 23.36 0 0 0-43.483 4.174 42.905 42.905 0 0 1 20.966 18.945 42.557 42.557 0 0 1 10.826-1.648 42.593 42.593 0 0 1 11.691-21.47z","b":[21.1,36.0,469.8,440.0]},{"n":"open-book","d":"M149.688 85.625c-1.234.005-2.465.033-3.72.063-33.913.806-75.48 10.704-127.25 33.718V362.78c60.77-28.82 106.718-37.067 144.22-33.092 33.502 3.55 59.685 16.66 83.562 31.187v-242.97c-23.217-17.744-50.195-30.04-85.97-32-3.52-.192-7.142-.296-10.843-.28zm211.968 0c-3.7-.016-7.322.088-10.844.28-35.773 1.96-62.75 14.256-85.968 32v242.97c23.876-14.527 50.06-27.637 83.562-31.188 37.502-3.974 83.45 4.272 144.22 33.094V119.407c-51.77-23.014-93.337-32.912-127.25-33.72-1.255-.028-2.486-.056-3.72-.06zm5.72 261.78c-1.038-.002-2.074.017-3.095.033-4.808.075-9.43.37-13.905.843-33.932 3.597-59.603 17.976-85.53 34.44v.28c-6.554-1.99-13.02-2.37-19.408-.97-25.566-16.177-51.003-30.202-84.468-33.75-5.595-.592-11.44-.883-17.564-.842-32.04.213-71.833 9.778-124.687 35.937v42.53c60.77-28.823 106.714-37.067 144.218-33.092 18.545 1.965 34.837 6.845 49.75 13.28-4.682 6.064-9.308 13.268-13.875 21.688h117.156c-5.93-8.22-11.798-15.414-17.626-21.56 14.996-6.503 31.39-11.43 50.062-13.408 37.503-3.974 83.448 4.27 144.22 33.094v-42.53c-53.16-26.31-93.115-35.863-125.25-35.97z","b":[18.7,85.6,473.9,342.2]},{"n":"book-cover","d":"M196.73 35.23c-8.132.878-16.3 1.936-24.515 3.172C192.968 50.21 212.045 66.795 224 96c-24.896-22.512-44.232-39.5-75.795-53.512-8.808 1.676-17.69 3.562-26.656 5.64 22.69 10.745 49.026 26.094 75.114 51.306-57.456-25.454-81.792-31.066-120.23-39.4C64.33 63.598 52.03 67.5 39.5 71.743c54.813 3.532 103.127 19.644 187.346 47.717l2.015.673 1.503 1.504c5.794 5.793 15.356 9.254 25.203 9.353-2.725-39.43-18.787-67.802-58.836-95.76zm118.54 0c-40.05 27.958-56.11 56.33-58.836 95.76 9.847-.1 19.41-3.56 25.203-9.353l1.502-1.504 2.014-.672C369.374 91.39 417.687 75.277 472.5 71.745c-12.53-4.243-24.83-8.145-36.934-11.71-38.438 8.334-62.774 13.946-120.23 39.4 26.088-25.212 52.424-40.56 75.115-51.307-8.964-2.077-17.847-3.963-26.655-5.64-31.563 14.014-50.9 31-75.795 53.513 11.954-29.205 31.032-45.79 51.785-57.598-8.216-1.236-16.383-2.294-24.515-3.172zM25 89.287v301.758c44.68.19 106.01 16.813 190 44.498v-301.04C128.034 105.534 81.67 90.71 25 89.288zm462 0c-56.67 1.423-103.034 16.246-190 45.217v301.05c84.317-27.698 143.413-42.5 190-44.2V89.287zm-254 55.195v200.325c15.47 3.1 30.71 3.292 46 .097V144.482c-7.227 3.058-15.14 4.518-23 4.518-7.86 0-15.773-1.46-23-4.518zm0 218.627v13.933c15.296 3.488 30.512 3.284 46-.1V363.22c-15.37 2.728-30.764 2.543-46-.11zm46 32.185c-15.226 2.856-30.633 3.058-46 .125v48.838c3.222 3.24 5.775 5.876 8.365 7.56 3.283 2.136 6.77 3.49 14.274 3.19l.18-.008h.18c11.61 0 15.954-4.04 23-10.836v-48.87z","b":[25.0,35.2,462.0,420.1]},{"n":"bookmark","d":"M161.22 19.563l-2.5 5.375-106.44 225.5-1 2.093c-24.493 28.208-34.917 58.587-33.593 88.19 1.38 30.852 15.12 60.388 36.376 86.81l2.812 3.5h49.72c4.817-3.836 8.93-7.817 12.405-12.03 1.758-2.132 3.38-4.358 4.875-6.656H65.97c-17.813-23.187-28.526-47.848-29.626-72.438-1.123-25.11 7.337-50.594 29.937-76.125H498.157l-5.25-12.874-91.844-225.5-2.375-5.843H161.22zm11.843 18.687h177.343l52.656 41.594 38.407 94.28-58.845 70.94H75.47L173.062 38.25zM75.156 282.625c-15.31 18.98-20.975 37.778-20.125 56.438.84 18.398 8.276 36.95 20.5 54.468h57.19c4.392-13.517 6.344-29.847 6.78-50.436h-16.188v-18.688h16.313v-.187h115.749v.186h17.156v18.688h-17.25c-.287 17.8-1.447 34.638-4 50.437h221.626c-9.034-36.872-9.112-74.006-.03-110.905H75.155zm83 60.28c-.77 37.698-6.46 65.83-24.72 87.97-14.595 17.7-36.19 30.747-67.28 42.813 8.69 1.658 17.214 3.225 26.53 5.25 14.048 3.052 27.912 6.338 39.033 9.25 5.56 1.455 10.44 2.826 14.374 4.062 1.94.61 3.533 1.074 5.03 1.625 35.245-13.464 55.78-32.897 68.345-58.72 11.944-24.55 16.287-55.713 16.936-92.25h-78.25zm89.25 69.44c-1.632 6.425-3.532 12.668-5.812 18.686h257.03v-18.686H247.407z","b":[16.4,19.6,482.3,474.3]},{"n":"book-pile","d":"M341.79 95.5L65.54 166.379l127.84 58.11 276.025-72.64L341.789 95.5zm-1.577 18.984l74.858 33.059-72.551 19.09-77.258-32.916 74.951-19.233zm142.813 52.395L194.864 242.71l-3.057.805h-.002l-.041.01-2.857-1.3L44.73 178.15l-.184-.092c-5.585-2.793-8.012-1.992-10.77.11-2.757 2.1-5.515 6.88-6.275 12.956-1.519 12.153 3.616 27.58 23.916 34.346l.412.139L193.338 288.5l173.235-45.588V212.45l76-18.345v28.806l42.173-11.097c-4.36-14.037-5.33-29.146-1.72-44.934zm-58.453 50.086l-40 9.656v103.186l21.947-21.948 18.053 12.498V216.965zm58.453 13.914l-40.453 10.646v45.385l42.173-11.098c-4.36-14.036-5.33-29.145-1.72-44.933zM38.42 240.268c-1.803.036-3.177.782-4.642 1.898-2.758 2.101-5.516 6.88-6.276 12.957-1.519 12.153 3.616 27.579 23.916 34.346l.412.138L193.338 352.5l173.235-45.588v-45.387l-174.766 45.99-146.62-65.161a61.602 61.602 0 0 1-4.802-1.874 8.317 8.317 0 0 0-1.965-.212zm6.768 2.086l.021.008-.279-.125.258.117zm437.838 52.525l-40.453 10.646v45.385l42.173-11.097c-4.36-14.037-5.33-29.146-1.72-44.934zM38.42 304.268c-1.803.036-3.177.782-4.642 1.898-2.758 2.101-5.516 6.88-6.276 12.957-1.519 12.153 3.616 27.579 23.916 34.346l.412.138L193.338 416.5l173.235-45.588v-45.387l-174.766 45.99-146.62-65.161a61.602 61.602 0 0 1-4.802-1.874 8.317 8.317 0 0 0-1.965-.212zm6.768 2.086l.021.008-.279-.125.258.117zm363.437 24.855l-38.863 38.863 68.834-18.115-29.97-20.748z","b":[26.0,95.5,458.8,321.0]},{"n":"spell-book","d":"M319.61 20.654c13.145 33.114 13.144 33.115-5.46 63.5 33.114-13.145 33.116-13.146 63.5 5.457-13.145-33.114-13.146-33.113 5.457-63.498-33.114 13.146-33.113 13.145-63.498-5.459zM113.024 38.021c-11.808 21.04-11.808 21.04-35.724 24.217 21.04 11.809 21.04 11.808 24.217 35.725 11.808-21.04 11.808-21.04 35.724-24.217-21.04-11.808-21.04-11.808-24.217-35.725zm76.55 56.184c-.952 50.588-.95 50.588-41.991 80.18 50.587.95 50.588.95 80.18 41.99.95-50.588.95-50.588 41.99-80.18-50.588-.95-50.588-.95-80.18-41.99zm191.177 55.885c-.046 24.127-.048 24.125-19.377 38.564 24.127.047 24.127.046 38.566 19.375.047-24.126.046-24.125 19.375-38.564-24.126-.047-24.125-.046-38.564-19.375zm-184.086 83.88c-1.191.024-2.36.07-3.492.134-18.591 1.064-41.868 8.416-77.445 22.556L76.012 433.582c78.487-20.734 132.97-21.909 170.99-4.615V247.71c-18.076-8.813-31.79-13.399-46.707-13.737a91.166 91.166 0 0 0-3.629-.002zm122.686 11.42c-2.916-.026-5.81.011-8.514.098-12.81.417-27.638 2.215-45.84 4.522V427.145c43.565-7.825 106.85-4.2 171.244 7.566l-39.78-177.197c-35.904-8.37-56.589-11.91-77.11-12.123zm2.289 16.95c18.889.204 36.852 2.768 53.707 5.02l4.437 16.523c-23.78-3.75-65.966-4.906-92.467-.98l-.636-17.805c11.959-2.154 23.625-2.88 34.959-2.758zm-250.483 4.658l-10.617 46.004h24.094l10.326-46.004H71.158zm345.881 0l39.742 177.031 2.239 9.973 22.591-.152-40.855-186.852h-23.717zm-78.857 57.82c16.993.026 33.67.791 49.146 2.223l3.524 17.174c-32.645-3.08-72.58-2.889-102.995 0l-.709-17.174c16.733-1.533 34.04-2.248 51.034-2.223zm-281.793 6.18l-6.924 30.004h24.394l6.735-30.004H56.389zm274.418 27.244c4.656.021 9.487.085 14.716.203l2.555 17.498c-19.97-.471-47.115.56-59.728 1.05l-.7-17.985c16.803-.493 29.189-.828 43.157-.766zm41.476.447c8.268.042 16.697.334 24.121.069l2.58 17.74c-8.653-.312-24.87-.83-32.064-.502l-2.807-17.234a257.25 257.25 0 0 1 8.17-.073zm-326.97 20.309l-17.985 77.928 25.035-.17 17.455-77.758H45.313zm303.164 11.848c19.608-.01 38.66.774 56.449 2.572l2.996 20.787c-34.305-4.244-85.755-7.697-119.1-3.244l-.14-17.922c20.02-1.379 40.186-2.183 59.795-2.193zm-166.606 44.05c-30.112.09-67.916 6.25-115.408 19.76l-7.22 2.053 187.759-1.27v-6.347c-16.236-9.206-37.42-14.278-65.13-14.196zm134.41 6.174c-19.63.067-37.112 1.439-51.283 4.182v10.064l177.594-1.203c-44.322-8.634-89.137-13.17-126.31-13.043zM26 475v18h460v-18H26z","b":[26.0,20.7,460.0,472.3]},{"n":"cigar","d":"M356.022 27.541c-43.9.028-111.558 28.053-110.32 71.936 1.261 44.656 116.215 66.754 116.215 66.754s-57.956 31.231-54.701 57.48c6.09 49.118 101.218 36.19 125.531 79.3 18.501 32.808 16.192 99.727 2.216 112.971 34.537-17.716 63.839-83.723 52.243-128.476-9.39-36.24-82.42-33.313-87.506-70.402-6.125-44.662 87.029-65.718 78.658-110.014-9.032-47.796-73.694-79.58-122.336-79.549zM30.42 83.834c-3.89.095-5.436.99-6.276 1.83-.84.84-1.735 2.385-1.83 6.276 2.113 24.907 20.582 54.074 31.67 71.31l16.52-66.074C57.55 91.46 44.728 83.638 30.419 83.834zm56.373 22.399L67.54 183.235c12.125 17.145 26.832 36.244 44.072 57.095l26.99-98.965c-17.471-12.944-34.274-24.722-51.81-35.132zm67.248 46.941l-28.346 103.934c4.426 5.18 9.05 10.495 13.774 15.875l11.783-11.784a82.612 82.612 0 0 1-3.334-8.377c-4.674-14.021-4.768-28.777 4.92-38.464 15.746-10.961 32.396-8.198 46.842-1.586l11.783-11.784c-20.611-18.104-39.793-34.043-57.422-47.814zm73.043 57.648l-11.285 11.286c6.027 4.215 11.965 9.194 17.648 14.877s10.664 11.622 14.88 17.65l11.284-11.285zm-61.518 16.264c-2.809 2.81-4.086 9.498-.57 20.045 3.516 10.547 11.56 23.472 23.197 35.11 11.637 11.636 24.563 19.683 35.11 23.199 10.547 3.515 17.236 2.236 20.045-.573 2.809-2.809 4.088-9.497.572-20.045-3.516-10.547-11.562-23.472-23.2-35.109-11.636-11.637-24.562-19.682-35.109-23.197-6.035-1.687-15.118-4.156-20.045.57zm106.332 29.432l-14.236 14.236a82.562 82.562 0 0 1 3.332 8.375c4.674 14.022 4.77 28.78-4.918 38.467-9.688 9.688-24.445 9.592-38.467 4.918a82.562 82.562 0 0 1-8.375-3.332l-14.238 14.238c18.655 19.456 32.69 33.568 50.783 51.66l38.787-116.365a2334.082 2334.082 0 0 0-12.668-12.197zm-111.31 20.8l-11.285 11.286 32.527 32.527 11.285-11.285c-6.027-4.216-11.967-9.196-17.65-14.879-5.683-5.683-10.662-11.621-14.877-17.648zm138.287 5.399l-38.865 116.594 53.652 53.652 38.89-116.672c-17.612-17.557-36.8-36.92-53.677-53.574zm67.906 67.803l-28.592 85.779 57.186-57.186zm32.922 48.195l-61.207 61.207 12.727 12.729 61.209-61.21zm11.81 33.443l-39.574 39.575 12.729 12.728 39.574-39.574z","b":[22.3,27.5,476.5,457.0]},{"n":"cigarette","d":"M224 32c9.036 24.71 106.984 58.72 156.096 64-37.096 7.89-53.042 10.52-57.545 32-13.076 62.384 191.477 60.478 115.73 152.223 69.11-15.788 57.922-116.197 15.887-129.84-27.237-8.84-63.75-11.67-47.75-38.383C425.962 88.104 503.57 59.74 448 32zM28.096 292v64h87v-64zm105 0v64h274v-64zm292 0v64h16v-64zm34 0v64h17v-64z","b":[28.1,32.0,485.9,324.0]},{"n":"direction-sign","d":"M66.26 62.5c-4.533 0-9.11.862-11.564 1.906-.914.39-1.142.617-1.377.797v32.26l26.488.287-.47-32.488c-.237-.183-.513-.445-1.47-.85C75.382 63.36 70.795 62.5 66.26 62.5zM365.22 78.293c-.528.005-1.08.022-1.65.05-2.287.117-4.886.428-7.47.968-5.167 1.08-10.42 3.023-13.677 4.973-2.754 1.65-3.064 2.87-3.095 2.225l.143 20.05 29.85.323V78.585c-.124-.03-.017-.013-.16-.04-.998-.18-2.358-.267-3.94-.25zM19.413 115.1l.56 54.732 11.036 8.027-4.257 66.695 132.46 8.416-133.66 6.99-3.5 44.987 361.22-1.93 48.19-36.52.257-12.01 60.867-41.66-39.547-40.106-56.44-6.484 39.544-5.52-58.74-35.747zM369.32 321.092l-27.723.148 1.63 167.76h26.092V370.074l-9.272-4.303 9.27-5.23zm-286.428 1.53l-29.573.16V489h31.867z","b":[19.4,62.5,473.2,426.5]},{"n": "gif·film", "gif": "film.gif"},{"n": "gif·filmstrip", "gif": "filmstrip.gif"},{"n": "gif·satellite", "gif": "satellite.gif"},{"n": "gif·tools", "gif": "tools.gif"},{"n": "gif·chart", "gif": "chart.gif"},{"n":"archive-register","d":"M168.8 32.89l-32.6 32.53 21.3 21.17L190 54.08zm33.9 33.96l-9.9 9.91 123 123.04 9.9-9.9zm159.4 18.06c-3.7 0-7.4.1-10.9.3-31.9 1.78-56.7 11.76-78.3 26.39l65.5 65.6c3.5 7.3 52 96.2 65.5 123.3-9.7-6.4-123.4-65.4-123.4-65.4l-15.3-15.2v140.3c23.9-14.6 50.1-27.7 83.6-31.2 37.5-4 83.5 4.3 144.2 33.1V118.7c-51.7-22.99-93.3-32.89-127.2-33.69-1.3 0-2.5-.11-3.7-.1zm-230.8 1.03C100.4 88.93 63.44 99 19.05 118.7v243.4C79.85 333.3 125.8 325 163.3 329c33 5.2 58.1 15.8 83.6 31.2V201.6c-38.6-38.5-77.1-77.1-115.6-115.66zm48.8 3.55l-9.9 9.89 123 123.02 9.9-9.9zM336 205.1l-27.5 27.5 55.1 27.6zM143.8 346.7c-32 .3-71.85 9.8-124.75 36v42.5c60.8-28.8 106.75-37.1 144.25-33.1 18.6 2 34.9 6.9 49.8 13.3-4.7 6.1-9.3 13.3-13.9 21.7h117.2c-6-8.2-11.8-15.4-17.7-21.6 15-6.5 31.4-11.4 50.1-13.4 37.5-4 83.5 4.3 144.2 33.1v-42.5c-53.1-26.3-93.1-35.9-125.2-36h-3.1c-4.8.1-9.4.4-13.9.9-34 3.6-59.6 18-85.6 34.4-5.7-.8-13-1.8-18.3-.9-27.2-16.2-58.2-30.4-85.5-33.5-5.6-.6-11.5-.9-17.6-.9z","b":[19.1,32.9,474.0,394.2]},{"n":"battery-pack-alt","d":"M226 16c-24.93 0-45 13.38-45 30v15h-45c-29.547 0-60 30.453-60 60v315c0 29.547 30.453 60 60 60h240c29.547 0 60-30.453 60-60V121c0-29.547-30.453-60-60-60h-45V46c0-16.62-20.07-30-45-30h-60zm-90 105h240v315H136V121zm120 30v105h-75l75 150V301h75l-75-150z","b":[76.0,16.0,360.0,480.0]},{"n":"biohazard","d":"M158.03 41.656c-19.755 22.934-31.78 52.76-31.78 85.406 0 23.544 6.228 45.667 17.125 64.782-22.02.108-44.312 5.78-64.72 17.562-28.266 16.32-48.113 41.64-58.093 70.22 9.484-15.492 23.012-28.562 39.844-38.282 23.238-13.417 49.246-17.604 73.813-13.72-2.547 9.988-3.907 20.45-3.907 31.22 0 57.436 38.516 106.03 91.062 121.375-9.005 22.822-25.49 42.892-48.406 56.124-16.838 9.722-35.253 14.313-53.407 14.78 29.763 5.674 61.89 1.723 90.187-14.624 20.317-11.732 36.307-28.117 47.406-47.03 11.1 18.922 27.08 35.325 47.406 47.06 28.296 16.35 60.422 20.268 90.188 14.595-18.163-.466-36.574-5.03-53.406-14.75-22.99-13.275-39.514-33.43-48.5-56.344 52.175-15.572 90.312-64.01 90.312-121.186 0-10.714-1.356-21.122-3.875-31.063 24.812-4.113 51.127.025 74.626 13.595 16.832 9.725 30.362 22.788 39.844 38.28-9.978-28.58-29.826-53.896-58.094-70.217-20.29-11.718-42.444-17.393-64.344-17.563 10.906-19.12 17.157-41.258 17.157-64.813 0-32.68-12.678-62.462-32.47-85.406 8.668 15.962 13.906 34.184 13.906 53.625 0 27.412-9.775 52.516-26.03 72.032-22.69-21.61-53.39-34.906-87.126-34.906-33.412 0-63.84 13.036-86.47 34.28-15.94-19.424-25.5-44.29-25.5-71.405 0-19.44 4.58-37.662 13.25-53.624zm98.72 109.438c28.748 0 54.833 11.19 74.125 29.47-17.373 14.994-39.375 24.76-63.594 26.874v19.812c12.912 3.6 22.283 15.35 22.283 29.47 0 2.39-.272 4.708-.782 6.936l17.44 9.5c14.018-19.577 33.415-33.477 54.967-40.844 2.14 8.485 3.282 17.372 3.282 26.532 0 48.918-32.41 90.075-76.97 103.28-5.058-23.923-2.37-49.563 9.125-72.905l-17.438-9.5c-5.385 4.726-12.45 7.592-20.25 7.592-8.056 0-15.342-3.05-20.78-8.062l-20.032 10.78c11.2 23.207 13.728 48.628 8.656 72.345-44.973-12.95-77.78-54.324-77.78-103.53 0-9.25 1.163-18.223 3.344-26.783 22.14 7.39 42.055 21.663 56.28 41.875l20.345-10.968c-.414-2.02-.626-4.103-.626-6.25 0-13.38 8.396-24.635 20.25-28.845V207.53c-24.962-1.917-47.63-11.958-65.375-27.5 19.238-17.95 45.074-28.936 73.53-28.936z","b":[20.6,41.7,473.2,415.1]},{"n":"boombox","d":"M369.1 24.54l-12.6 12.92c-9.2 14.71-9.7 34.33-7.6 53.05-2.9-.39-5.9-.46-8.9-.2-16.1 1.38-28.4 11.59-27.4 22.89 1 11.2 14.8 19.2 30.9 17.8 8.8-.7 17-4.2 22.1-9.5 1.7 10.8 15.2 18.2 30.7 16.9 16.1-1.4 28.4-11.6 27.4-22.9-.2-2.3-.9-4.5-2.1-6.5-3.4-19.63-4.2-38.02 4.8-57.07-18.6-5.91-44-16.31-57.3-27.39zm2.4 24.77c10.1 6.59 21.3 11.42 32 14.24-2.6 11.7-2.6 23.19-1.6 34.32-3-.42-6-.5-9.1-.24-8.8.77-16.9 4.27-22 9.57-.3-2-1.1-3.9-2.2-5.7-3.1-17.98-3.9-34.87 2.9-52.19zM111.4 63.88c-13.92 5.83-36.33 8.22-53.82 3.71l-4.5 17.43c2.08 18.88 10 35.28 19.99 49.68a20.44 29.25 55.36 0 0-8.08 4.4 20.44 29.25 55.36 0 0-12.45 33.4 20.44 29.25 55.36 0 0 35.69.2 20.44 29.25 55.36 0 0 12.47-33.4 20.44 29.25 55.36 0 0-5.4-4.7c-11.6-14-20.7-28.3-23.28-46.69 16.57.96 33.18-1.91 46.38-7.43l-7-16.6zM151 167v48h16v-32h178v32h16v-48H151zM25 233v238h462V233H25zm39 14h64v18H64v-18zm112 0h160v18H176v-18zm208 0h64v18h-64v-18zM48 279h416v18H48v-18zm64 32c40.2 0 73 32.8 73 73s-32.8 73-73 73c-40.21 0-73-32.8-73-73s32.79-73 73-73zm87 0h114v82H199v-82zm201 0c40.2 0 73 32.8 73 73s-32.8 73-73 73-73-32.8-73-73 32.8-73 73-73zm-288 18c-30.48 0-55 24.5-55 55s24.52 55 55 55c30.5 0 55-24.5 55-55s-24.5-55-55-55zm105 0v46h78v-46h-78zm183 0c-30.5 0-55 24.5-55 55s24.5 55 55 55 55-24.5 55-55-24.5-55-55-55zm-288 30c13.7 0 25 11.3 25 25s-11.3 25-25 25-25-11.3-25-25 11.3-25 25-25zm288 0c13.7 0 25 11.3 25 25s-11.3 25-25 25-25-11.3-25-25 11.3-25 25-25zm-288 18c-4 0-7 3-7 7s3 7 7 7 7-3 7-7-3-7-7-7zm288 0c-4 0-7 3-7 7s3 7 7 7 7-3 7-7-3-7-7-7zm-185 39h18v32h-18v-32zm32 0h18v32h-18v-32zm32 0h18v32h-18v-32z","b":[25.0,24.5,462.0,446.5]},{"n":"cloud","d":"M161.973 78.337a45.187 37.1 0 0 0-30.139 9.516 18.003 21.403 70.24 0 0-24.918-6.965 18.003 21.403 70.24 0 0-14.932 19.322 42.575 31.039 0 0 0-.568-.022 42.575 31.039 0 0 0-42.576 31.04 42.575 31.039 0 0 0 20.14 26.357 20.192 11.588 0 0 0-6.472 8.488 20.192 11.588 0 0 0 20.191 11.59 20.192 11.588 0 0 0 20.194-11.59 20.192 11.588 0 0 0-1.745-4.676 42.575 31.039 0 0 0 5.168-1.113 21.479 18.996 0 0 0 18.555 9.477 21.479 18.996 0 0 0 15.438-5.819 20.362 25.322 63.675 0 0 .574 1.36 20.362 25.322 63.675 0 0 31.724 7.021 20.362 25.322 63.675 0 0 14.827-26.28 45.187 37.1 0 0 0 19.726-30.605 45.187 37.1 0 0 0-45.187-37.101z","b":[48.8,78.3,158.3,99.3]},{"n":"cloud-download","d":"M200.1 31.2A130.1 132.4 0 0 0 70.03 163.6a130.1 132.4 0 0 0 .55 11.3 80.98 73.47 0 0 0-52.21 68.6A80.98 73.47 0 0 0 99.35 317a80.98 73.47 0 0 0 37.25-8.3 189.3 80.97 0 0 0 78.4 16.5v-49.9h82v50.1a189.3 80.97 0 0 0 39.5-5.7 91.09 67.8 0 0 0 66 21.1 91.09 67.8 0 0 0 91.1-67.8 91.09 67.8 0 0 0-58-63.1 70.1 81.72 20.61 0 0 2.6-6.2 70.1 81.72 20.61 0 0-36.8-101.2 70.1 81.72 20.61 0 0-76.9 22.8 130.1 132.4 0 0 0-124.4-94.1zM233 293.3v112h-51.3l74.3 74.3 74.3-74.3H279v-112h-46z","b":[18.4,31.2,475.2,448.4]},{"n":"cloud-upload","d":"M200.1 31.2A130.1 132.4 0 0 0 70.03 163.6a130.1 132.4 0 0 0 .55 11.3 80.98 73.47 0 0 0-52.21 68.6A80.98 73.47 0 0 0 99.35 317a80.98 73.47 0 0 0 37.25-8.3 189.3 80.97 0 0 0 70.4 15.6l49-49 49.2 49.2a189.3 80.97 0 0 0 31.3-4.8 91.09 67.8 0 0 0 66 21.1 91.09 67.8 0 0 0 91.1-67.8 91.09 67.8 0 0 0-58-63.1 70.1 81.72 20.61 0 0 2.6-6.2 70.1 81.72 20.61 0 0-36.8-101.2 70.1 81.72 20.61 0 0-76.9 22.8 130.1 132.4 0 0 0-124.4-94.1zM256 300.7L181.7 375H233v112h46V375h51.3L256 300.7z","b":[18.4,31.2,475.2,455.8]},{"n":"combination-lock","d":"M400.218 212.413v-42.195a144.218 144.218 0 1 0-288.436 0v42.195H90.61V486H421.39V212.413h-21.173zM216.342 407.97h-57.29v-22.354h57.29v22.354zm0-33.403h-57.29v-57.29h57.29v57.29zm0-68.28h-57.29v-22.354h57.29v22.32zm68.28 101.718h-57.29v-22.39h57.29v22.355zm0-33.403h-57.29v-57.29h57.29v57.29zm0-68.28h-57.29v-22.39h57.29v22.32zm68.28 101.718h-57.29v-22.424h57.29v22.354zm0-33.403h-57.29v-57.29h57.29v57.29zm0-68.28h-57.29v-22.424h57.29v22.32zm2.887-93.884H156.211v-42.254a99.789 99.789 0 1 1 199.578 0v42.195zM177.455 353.439c0 4.443 3.835 8.184 10.195 8.184 5.846 0 10.336-3.507 10.336-8.839 0-3.694-2.339-6.36-6.127-7.857v-.093c3.741-1.777 5.004-4.536 5.004-7.109 0-3.788-2.946-7.482-8.839-7.482-5.331 0-9.353 3.273-9.353 8.09 0 2.62 1.45 5.238 4.817 6.828v.14c-3.742 1.59-6.033 4.303-6.033 8.138zm5.05-15.386c0-2.62 1.871-4.864 5.285-4.864a4.677 4.677 0 0 1 5.145 4.957c0 2.76-2.011 4.677-4.677 5.519-3.46-.936-5.752-2.572-5.752-5.612zm4.677 8.558c4.116 1.17 6.688 2.946 6.688 6.64 0 3.134-2.338 5.426-6.08 5.426-3.881 0-6.22-2.713-6.08-5.846-.046-2.853 1.871-5.191 5.426-6.22zm67.275 15.059a15.445 15.445 0 0 1-7.904-2.058l1.17-3.18a13.738 13.738 0 0 0 6.734 1.918c5.284 0 6.921-3.368 6.874-5.846 0-4.256-3.881-6.08-7.856-6.08h-2.339v-3.087h2.339c2.993 0 6.78-1.543 6.78-5.144 0-2.432-1.543-4.583-5.33-4.583a11.166 11.166 0 0 0-6.08 2.01l-1.076-2.992a14.451 14.451 0 0 1 7.95-2.339c5.987 0 8.7 3.508 8.7 7.25 0 3.133-1.872 5.845-5.613 7.155v.093a7.915 7.915 0 0 1 6.781 7.81c-.093 4.817-3.881 9.073-11.177 9.073zm70.15 0c6.314 0 10.102-5.144 10.102-10.71 0-5.94-3.788-9.82-9.167-9.82a9.061 9.061 0 0 0-7.342 3.507h-.14a12.358 12.358 0 0 1 10.522-10.803 14.849 14.849 0 0 1 3.087-.187v-3.368a19.876 19.876 0 0 0-2.993.234 16.556 16.556 0 0 0-9.728 4.49 19.104 19.104 0 0 0-5.144 13.703c.047 7.88 4.303 12.93 10.803 12.93zm-6.22-13.703a6.77 6.77 0 0 1 5.846-3.741c3.788 0 6.267 2.619 6.267 7.015 0 4.396-2.339 7.296-5.94 7.296-4.302 0-6.594-3.695-6.687-8.7a3.508 3.508 0 0 1 .514-1.893z","b":[90.6,170.2,330.8,315.8]},{"n":"computer-fan","d":"M256 21.688C126.7 21.688 21.687 126.698 21.687 256 21.688 385.3 126.7 490.313 256 490.313c129.3 0 234.313-105.012 234.313-234.313C490.313 126.7 385.3 21.687 256 21.687zm-201.47 9A22.53 22.53 0 0 0 32 53.218 22.53 22.53 0 0 0 54.53 75.75a22.53 22.53 0 0 0 22.532-22.53 22.53 22.53 0 0 0-22.53-22.532zm404.25 0a22.53 22.53 0 0 0-22.53 22.53 22.53 22.53 0 0 0 22.53 22.532 22.53 22.53 0 0 0 22.533-22.53 22.53 22.53 0 0 0-22.532-22.532zm-202.78 9c119.573 0 216.313 96.74 216.313 216.312 0 119.573-96.74 216.313-216.313 216.313S39.687 375.572 39.687 256 136.428 39.687 256 39.687zm43.684 22.433c-.485-.01-.955-.008-1.41.003-6.047.15-9.43 2.236-8.545 6.738 10.475 42.195 11.75 85.79-5.087 124.314 12.714 5.83 23.38 15.397 30.556 27.297 28.976-24.022 58.114-55.318 76.618-79.786 26.14-34.564-61.598-77.91-92.134-78.563zm-98.278 4.392c-40.03-.548-110.755 59.8-90.63 66.685 41.8 12.03 80.21 32.736 105.154 66.608 11.014-7.883 24.416-12.613 38.882-12.86-6.316-37.106-18.853-77.99-30.79-106.25-4.202-9.947-12.412-14.044-22.616-14.183zM438.22 190.227c-1.095.02-2.198.483-3.298 1.443-31.292 30.16-68.396 53.055-110.16 57.748.206 2.168.322 4.36.322 6.582 0 12.156-3.18 23.588-8.732 33.53 35.294 13.084 76.97 22.67 107.416 26.462 49.867 6.21 33.393-126.102 14.453-125.765zm-353.636 5.58c-48.158.507-27.205 141.674-7.564 124.533 31.307-30.175 68.43-53.08 110.218-57.756-.207-2.17-.322-4.363-.322-6.584 0-12.144 3.174-23.567 8.717-33.502-35.305-13.093-77.003-22.687-107.46-26.48-1.238-.154-2.433-.224-3.59-.21zM256 204.917c-11.406 0-21.907 3.696-30.387 9.958 1.986 3.567 3.84 7.256 5.55 11.074 6.763-5.608 15.427-8.99 24.837-8.99.844 0 1.68.035 2.51.09-.264-3.93-.632-7.967-1.108-12.1-.467-.01-.932-.034-1.402-.034zm20.42 4.22c-2.088 3.49-4.345 6.925-6.785 10.302 9.298 3.5 16.938 10.46 21.336 19.29 3.297-2.21 6.634-4.567 10-7.066-5.402-10.007-14.048-17.97-24.55-22.527zm-63.98 20.088c-4.77 7.775-7.524 16.938-7.524 26.775 0 1.94.116 3.85.324 5.73 4.05.066 8.14.303 12.268.727-.355-2.103-.55-4.258-.55-6.457 0-7.987 2.44-15.436 6.606-21.643-3.563-1.75-7.273-3.464-11.123-5.132zM256 234.96c-11.728 0-21.04 9.312-21.04 21.04s9.312 21.04 21.04 21.04 21.04-9.312 21.04-21.04-9.312-21.04-21.04-21.04zm38.494 14.6c.353 2.098.547 4.247.547 6.44 0 8-2.446 15.46-6.624 21.672 3.564 1.75 7.275 3.465 11.125 5.133 4.785-7.782 7.544-16.955 7.544-26.805 0-1.935-.115-3.84-.322-5.72-4.05-.062-8.14-.297-12.268-.72zm-73.478 23.686c-3.297 2.21-6.633 4.567-10 7.065 5.394 10.005 14.03 17.97 24.52 22.534 2.09-3.488 4.346-6.925 6.786-10.3-9.287-3.51-16.918-10.472-21.306-19.298zm59.773 12.846c-6.758 5.583-15.403 8.95-24.79 8.95-.865 0-1.72-.04-2.572-.097.264 3.93.632 7.968 1.107 12.102.488.013.974.037 1.465.037 11.385 0 21.867-3.684 30.338-9.924-1.986-3.565-3.84-7.252-5.55-11.068zm-84.005 5.408c-28.992 24.028-58.15 55.347-76.664 79.828-32.065 42.4 107.234 98.014 102.09 71.82-10.48-42.204-11.75-85.81 5.1-124.343-12.704-5.837-23.356-15.407-30.525-27.305zm99.242 20.727c-11.02 7.875-24.43 12.594-38.902 12.828 6.316 37.11 18.854 77.997 30.793 106.26 20.686 48.97 138.5-43.86 113.242-52.5-41.79-12.027-80.187-32.73-105.133-66.588zM52.803 436.25a22.53 22.53 0 0 0-22.532 22.53 22.53 22.53 0 0 0 22.533 22.533 22.53 22.53 0 0 0 22.53-22.532 22.53 22.53 0 0 0-22.53-22.53zm406.156 0a22.53 22.53 0 0 0-22.532 22.53 22.53 22.53 0 0 0 22.53 22.533 22.53 22.53 0 0 0 22.532-22.532 22.53 22.53 0 0 0-22.53-22.53z","b":[21.7,21.7,468.6,468.6]},{"n":"distress-signal","d":"M68.79 19.5l57.51 69h23.4l-57.49-69zm185.31 0l59.4 178.3c5.5-2.1 11.2-4 17-5.7L273 19.5zm-92.2 83.7l-2.5 25.1 90.7 108.8c4.4-4.1 9-7.9 13.8-11.5zm-78.45 3.3l14.19 142H129.4l14.2-142zm302.05 96c-3.2 0-6.4.1-9.6.2L361 253.8l46.9-21.5-3 43.1 40.5 12.4-47.2 32.2 27 36.8-51.8 11.6 8.3 53.6-74.3-44.2 8.9-70.8-28.4-44.7 58.9-55.7c-75.8 16.2-134 79.3-143.1 157.6l41.5-61.4 38.7 104.5-29.9 12.5 80.4 40.5-68.2 16.5-52-26.6c5.7 15.2 13.4 29.4 22.7 42.3h150.2l78.5-65.2-45.6-36 45.7-24.8 26.8 14.2V237c-30.1-21.7-67-34.5-107-34.5zm-272 64c-12.8 0-23 10.2-23 23s10.2 23 23 23 23-10.2 23-23-10.2-23-23-23zm-94 11.1v18.7l60.11 16.2c-4.05-6-6.58-13-7.03-20.6zm268.4 7.3l4.2 42.1-14.1 25.5-15.3-51.2zM463.5 303l-15.4 43.4-19.7-24.9zm-315.9 9.1c-4 6.1-9.7 11.1-16.3 14.3l57.9 15.6c1.4-5.9 2.9-11.7 4.7-17.4zm171.1 87.1l29.7 23.5-18.3 25.4zm-131.4 20c-2.3.5-4.5 1-6.9 1.5-69.9 15.5-126.2 28.2-160.9 35.9v18.5c32.9-7.4 91.7-20.5 164.8-36.8 2.3-.5 4.5-1 6.8-1.5-1.5-5.8-2.8-11.7-3.8-17.6zm175.3 9.4l42.9 15.9-32.3 12.2z","b":[19.5,19.5,473.0,473.0]},{"n":"full-folder","d":"M402.488 45.148c-29.932 24.474-69.636 42.525-111.175 57.262C335.04 94.3 376.27 83.816 413.135 69.98c-2.7-8.61-6.116-16.916-10.647-24.83zM41 73v135.764c11.918-41.227 23.38-84.748 34.512-126.996L77.82 73H41zm41.518 0l5.884 3.096c27.917 14.682 57.075 28.881 87.127 42.482 2.96-.305 5.913-.62 8.866-.937L169.514 73H82.518zm366.652 1.447c-88.208 40.349-203.608 56.834-319.715 66.387L131.451 151h327.77c-4.066-30.318-7.69-57.252-10.051-76.553zM90.059 97.143C71.419 167.87 51.807 241.39 30.283 302.035l24.479 10.158L88.697 151h24.412l-3.246-16.525-1.947-9.91 10.07-.795c7.394-.584 14.783-1.197 22.164-1.84A1638.49 1638.49 0 0 1 90.06 97.143zM103.303 169L43.092 455h381.605l60.211-286H103.303zM477.27 292.654l-19.336 91.852c9.008-.398 17.683-.77 27.27-1.213-.725-21.697-3.794-54.23-7.934-90.639zM41 325.97v51.594l9.99-47.45L41 325.97z","b":[30.3,45.1,454.9,409.9]},{"n":"globe","d":"M322.02 20.184l-17.13 42.273c7.053 2.776 13.857 6.04 20.372 9.758l8.62-13.274 15.675 10.18-8.637 13.296c.85.628 1.692 1.266 2.53 1.91l-19.745 22.735c4.994 3.747 9.706 7.85 14.1 12.268l19.754-22.746c.187.184.38.366.567.55l11.795-10.618 12.504 13.89-11.79 10.614c4.71 5.887 9.005 12.117 12.846 18.648l14.114-7.19 8.482 16.653-14.092 7.177c3.015 6.877 5.555 14.007 7.578 21.353l15.452-3.283 3.884 18.28-15.445 3.282c1.114 7.374 1.71 14.918 1.77 22.59l15.777.827-.98 18.664-15.74-.825c-.835 7.61-2.214 15.056-4.09 22.303l14.947 4.857-5.777 17.774-14.922-4.85c-2.767 7.09-6.03 13.934-9.75 20.486l13.142 8.537-10.18 15.674-13.13-8.528c-4.493 6.108-9.418 11.877-14.725 17.273l10.46 11.617-13.89 12.506-10.437-11.594c-5.9 4.734-12.14 9.062-18.69 12.924l7.05 13.838-16.65 8.484-7.033-13.803c-6.898 3.034-14.055 5.585-21.427 7.62l3.213 15.123-18.28 3.884-3.21-15.107c-7.405 1.125-14.978 1.735-22.682 1.797l-.808 15.41-18.662-.98.807-15.368c-7.645-.834-15.127-2.208-22.405-4.092l-4.738 14.58-17.773-5.777 4.73-14.55c-7.124-2.78-13.997-6.063-20.575-9.803l-8.328 12.822-15.672-10.18 8.33-12.824c-.93-.685-1.848-1.384-2.762-2.088l19.848-22.853c-4.997-3.743-9.71-7.842-14.108-12.257l-19.848 22.853c-.156-.152-.314-.302-.47-.455l-11.356 10.226-12.504-13.89 11.347-10.216c-4.563-5.7-8.737-11.725-12.49-18.03l-38.9 23.71c9.515 15.894 21.132 30.386 34.472 43.088l-20.575 23.69 14.112 12.255 20.575-23.693c34.76 27.522 78.7 43.96 126.482 43.96 1.365 0 2.726-.023 4.084-.05v19.473c-34.134 15.356-59.115 36.682-79.753 59.906h197.54c-19.674-24.32-44.835-43.993-80.784-59.712V409.41c92.908-19.004 162.8-101.184 162.8-199.68 0-58.094-24.315-110.51-63.323-147.636l20.58-23.698-14.11-12.253-20.584 23.7c-15.464-12.24-32.75-22.278-51.376-29.66zm-75.108 82.664c-59.132 0-106.838 47.692-106.838 106.8 0 59.11 47.706 106.8 106.838 106.8 59.132 0 106.838-47.69 106.838-106.8 0-9.375-1.203-18.462-3.46-27.12-10.244 25.087-23.08 45.15-45.905 66.95-16.887-1.487-29.712-8.08-40.643-19.966 6.048-8.86 13.09-17.22 27.096-22.102-12.564-28.283-18.19-56.568-21.393-84.85 12.464 4.59 20.16 11.93 29.235 24.954 7.712 1.697 16.863-6.856 23.27-13.975-19.274-18.99-45.752-30.692-75.038-30.692zm-32.48 65.03c17.62 12.56 32.407 31.486 38.03 52.517-11.065 9.256-16.907 21.124-19.92 34.406 16.957 8.23 30.048 21.297 41.65 36.22v.007c-34.438-3.405-68.245-9.135-98.696-27.164-12.172-20.824-19.107-41.65-19.92-62.474 16.6-7.525 33.2-4.936 49.8.895 9.222-11.47 9.186-20.922 9.056-34.408z","b":[71.9,20.2,379.0,472.7]},{"n":"globe-ring","d":"M256 18.5c-35 0-61.747 17.777-79.027 39.377-14.67 18.338-23.127 39.13-25.354 56.623h18.348c2.349-13.123 9.296-30.672 21.06-45.377C205.747 50.723 227 36.5 256 36.5s50.253 14.223 64.973 32.623c11.764 14.705 18.711 32.254 21.06 45.377h18.348c-2.227-17.492-10.683-38.285-25.354-56.623C317.747 36.277 291 18.5 256 18.5zm13.893 35.03c14.406 12.58 31.53 37.293 18.646 60.97h34.84c-1.092-12.498-24.592-55.762-53.486-60.97zm-125.32 78.97c-.22.219-.77.852-1.348 2.154C141.978 137.46 141 142.5 141 147.5s.978 10.041 2.225 12.846c.579 1.302 1.129 1.935 1.347 2.154h222.856c.218-.219.768-.852 1.347-2.154C370.022 157.54 371 152.5 371 147.5s-.978-10.041-2.225-12.846c-.579-1.302-1.129-1.935-1.347-2.154zm3.984 48C107.479 212.564 81 262.518 81 318.5c0 96.437 78.563 175 175 175s175-78.563 175-175c0-55.982-26.479-105.936-67.557-138h-90.691C341.782 188.73 395 247.191 395 318.5c0 76.98-62.02 139-139 139-76.98 0-139-62.02-139-139 0-71.308 53.219-129.77 122.248-138z","b":[81.0,18.5,350.0,475.0]},{"n":"hazard-sign","d":"M254.97 34.75c-30.48-.167-59.02 22.12-79.532 62.156-.075.146-.176.26-.25.406L43.063 326.783l-.22.343C18.5 365.413 13.377 401.515 28.47 428.03c15.08 26.498 48.627 40.126 93.5 37.908H387.063c44.887 2.227 78.445-11.404 93.53-37.907 15.09-26.51 9.956-62.595-14.375-100.874l-.22-.375L335.28 98.064c-.06-.12-.124-.225-.186-.344-20.948-40.263-49.626-62.803-80.125-62.97zm.06 18.844c13.576.13 26.453 6.93 38.126 18.343 11.606 11.347 22.554 27.453 33.406 48.344.063.122.125.224.188.345l115.22 201.563c.033.053.058.102.092.156l.125.22c12.92 20.274 21.395 38.06 25.282 53.967 3.91 16.01 3.063 30.648-3.845 42.408-6.908 11.76-19.222 19.533-34.78 23.906-15.444 4.34-34.508 5.656-57.408 4.5H137.625c-24.845 1.258-44.73-.32-60.405-5.125-15.78-4.84-27.68-13.45-33.72-25.69-6.04-12.237-5.862-26.797-1.5-42.436 4.333-15.535 12.815-32.608 24.875-51.53l.22-.377L183.562 120c.08-.157.17-.28.25-.438C194.51 98.644 205.32 82.6 216.875 71.376c11.642-11.307 24.58-17.913 38.156-17.78zm47.657 62.093l-28.53 224.032h-41.844L204.438 120.5c-1.404 2.556-2.81 5.205-4.22 7.97l-.093.218-.125.218-116.938 202.97-.093.187-.126.187C71.28 350.346 63.598 366.226 60 379.125c-3.598 12.9-3.108 22.322.25 29.125 3.358 6.803 9.925 12.28 22.47 16.125 12.542 3.845 30.67 5.547 54.405 4.313l.25-.032h234.313l.25.03c21.85 1.138 39.308-.28 51.875-3.81 12.566-3.533 19.822-8.827 23.687-15.407 3.865-6.58 4.978-15.545 1.813-28.5-3.166-12.958-10.732-29.374-23.094-48.72l-.126-.188-.125-.218-115.658-202.28-.093-.158-.064-.187c-2.5-4.828-4.99-9.326-7.47-13.532zM231.28 361.875h43.907v43.906H231.28v-43.905z","b":[13.4,34.6,482.3,433.6]},{"n":"headphones","d":"M256 51c-54.994 0-107.32 25.053-148.22 66.826l16.525 8.264C163.22 88.012 210.558 65 256 65c45.45 0 92.803 22.997 131.725 61.074l16.496-8.248C363.32 76.053 310.995 51 256 51zM95.178 131.652C54.13 180.022 27.215 246.514 25.195 321h14.022c2.225-70.647 30.325-133.29 69.992-178.906.695-.8 1.403-1.583 2.106-2.373l-16.138-8.068zm321.644 0l-16.107 8.055c.692.778 1.39 1.548 2.076 2.336C442.46 187.646 470.56 250.29 472.784 321h14.022c-2.02-74.486-28.935-140.978-69.983-189.348zM128.042 262.8c-3.485-.013-6.98 1.078-7.042 3.415V458c0 4 14 4 14 0V266c0-2.074-3.473-3.19-6.96-3.2zm255.917 0c-3.487.01-6.96 1.126-6.96 3.2v192c0 4 14 4 14 0V266.215c-.06-2.337-3.557-3.428-7.04-3.416zM103 275.73c-15.623 2.393-25.644 11.16-33.133 24.64C61.022 316.294 57 339 57 362s4.022 45.707 12.867 61.63c7.49 13.48 17.51 22.247 33.133 24.64V275.73zm306 0v172.54c15.623-2.393 25.644-11.16 33.133-24.64C450.978 407.706 455 385 455 362s-4.022-45.707-12.867-61.63c-7.49-13.48-17.51-22.247-33.133-24.64zM25 339v46h14v-46H25zm448 0v46h14v-46h-14z","b":[25.0,51.0,462.0,411.0]},{"n":"jack-plug","d":"M406.089 25l-7.504 22.51 14.764 14.763 22.51-7.503V25zm-29.113 26.354l-9.9 9.9 32.529 32.53 9.9-9.901zM354.349 73.98l-43.842 43.844 32.527 32.528 43.844-43.842zm-56.569 56.57l-32.529 32.528 32.53 32.53 32.527-32.53zm-56.568 33.94l-127.898 127.9-8.885 26.65 37.39 37.39 26.649-8.885 127.9-127.899zm172.22 140.47c-15.712-.182-32.101 3.876-48.947 10.47-38.503 15.071-79.972 43.684-120.955 71.744-40.982 28.06-81.503 55.562-115.634 68.5-17.066 6.469-32.346 9.213-45.063 7.424-12.717-1.79-23.226-7.591-32.74-20.45-2.186-2.954-2.233-6.994.928-14.197 3.16-7.203 9.496-15.948 16.576-23.982 9.554-10.843 20.15-20.342 26.11-25.446L80.932 366.25c-6.525 5.638-17.096 15.26-26.84 26.32C46.334 401.376 39 411.052 34.54 421.22c-4.46 10.166-6.082 22.447 1.084 32.133 11.935 16.13 27.625 25.165 44.701 27.568 17.077 2.403 35.185-1.305 53.95-8.418 37.53-14.226 78.436-42.415 119.423-70.479 40.988-28.063 82.028-56.008 117.348-69.834 17.66-6.912 33.746-10.223 47.43-8.962 13.683 1.26 25.137 6.61 35.58 18.666 10.647 12.29 11.662 30.245 5.558 52.644-6.103 22.4-19.359 47.936-34.41 71.668-6.132 9.67-12.54 19.006-18.865 27.797h22.037a567.751 567.751 0 0 0 12.027-18.156c15.598-24.593 29.667-51.22 36.577-76.576 6.91-25.358 6.628-50.753-9.319-69.163-13.168-15.201-29.804-23.17-47.535-24.802a83.568 83.568 0 0 0-6.693-.344zM94.135 334.198l-9.9 9.9 32.527 32.528 9.9-9.9z","b":[28.5,25.0,455.4,469.0]},{"n":"keyboard","d":"M247 21.074c0 10.508 7.18 18.167 14.71 23.412 7.532 5.246 16.41 9.202 24.698 13.15 8.287 3.95 15.954 7.94 20.332 11.657 4.378 3.717 5.225 5.25 4.46 8.82-.497 2.315-1.215 3.316-2.612 4.46-1.397 1.146-3.766 2.287-7.15 3.107-6.77 1.64-17.084 1.778-27.94 1.722-10.856-.055-22.27-.272-32.76 1.975-10.49 2.246-21.296 8.173-25.252 19.7-2.59 7.548-.236 15.34 3.37 20.804 3.605 5.464 8.328 9.71 12.857 13.696 2.997 2.638 5.89 5.126 8.355 7.424h22.875c-1.575-3.354-3.862-6.223-6.168-8.754-4.138-4.544-8.918-8.44-13.17-12.182-4.25-3.74-7.917-7.357-9.726-10.1-1.81-2.74-1.9-3.496-1.368-5.044 1.518-4.425 4.565-6.35 11.996-7.94 7.43-1.593 18.006-1.633 28.898-1.578 10.892.056 22.087.24 32.27-2.228 5.09-1.234 10.058-3.184 14.322-6.678 4.264-3.494 7.53-8.68 8.8-14.61 2.275-10.606-3.357-20.327-10.41-26.314-7.052-5.987-15.765-10.15-24.238-14.185-8.472-4.037-16.733-7.896-22.152-11.67-5.42-3.775-6.998-6.34-6.998-8.643h-18zM41 169v174h430V169H41zm7 14h16v18H48v-18zm32 0h16v18H80v-18zm32 0h16v18h-16v-18zm32 0h16v18h-16v-18zm32 0h16v18h-16v-18zm32 0h16v18h-16v-18zm32 0h16v18h-16v-18zm32 0h16v18h-16v-18zm48 0h48v18h-48v-18zm96 0h32v18h-32v-18zM48 215h32v18H48v-18zm48 0h16v18H96v-18zm32 0h16v18h-16v-18zm32 0h16v18h-16v-18zm32 0h16v18h-16v-18zm32 0h16v18h-16v-18zm32 0h16v18h-16v-18zm32 0h16v18h-16v-18zm32 0h32v18h-32v-18zm48 0h16v18h-16v-18zm32 0h16v18h-16v-18zm32 0h16v18h-16v-18zm-127.87 25h18v57h-25v-18h7v-39zM48 247h16v18H48v-18zm32 0h16v18H80v-18zm32 0h16v18h-16v-18zm32 0h16v18h-16v-18zm32 0h16v18h-16v-18zm32 0h16v18h-16v-18zm32 0h16v18h-16v-18zm32 0h16v18h-16v-18zm96 0h16v18h-16v-18zm32 0h16v18h-16v-18zm32 0h16v18h-16v-18zm-96 16h16v18h-16v-18zM48 279h32v18H48v-18zm48 0h16v18H96v-18zm32 0h16v18h-16v-18zm32 0h16v18h-16v-18zm32 0h16v18h-16v-18zm32 0h16v18h-16v-18zm32 0h16v18h-16v-18zm112 0h16v18h-16v-18zm32 0h16v18h-16v-18zm32 0h16v18h-16v-18zM48 311h16v18H48v-18zm32 0h16v18H80v-18zm32 0h144v18H112v-18zm160 0h16v18h-16v-18zm32 0h16v18h-16v-18zm32 0h16v18h-16v-18zm32 0h48v18h-48v-18zm64 0h16v18h-16v-18z","b":[41.0,21.1,430.0,321.9]},{"n":"laptop","d":"M73 25v238h366V25H283v16h140v192H89V41h140V25H73zm174 0v16h18V25h-18zM107 59v156h298V59H107zM71.03 281l-43.5 174H484.5L441 281h-29.9l20 96h-99.6l16 64H163.8l20-64H80.93l19.97-96H71.03zm48.27 0l-2.9 14H147l2.3-14h-30zm48.4 0l-2.3 14h30.7l1.7-14h-30.1zm48.2 0l-1.7 14H247v-14h-31.1zm49.1 0v14h32.8l-1.7-14H265zm49.2 0l1.7 14h30.7l-2.3-14h-30.1zm48.5 0l2.3 14h30.6l-2.9-14h-30zm-250 32l-3 14h31.9l2.4-14h-31.3zm49.7 0l-2.4 14h32.1l1.7-14h-31.4zm49.5 0l-1.7 14H247v-14h-35.1zm53.1 0v14h36.8l-1.7-14H265zm53.2 0l1.7 14H352l-2.4-14h-31.4zm49.8 0l2.4 14h31.9l-3-14H368zm-262 32l-2.9 14h33.2l2.3-14H106zm51 0l-2.3 14h33.4l1.7-14H157zm50.9 0l-1.7 14H247v-14h-39.1zm57.1 0v14h40.8l-1.7-14H265zm57.2 0l1.7 14h33.4l-2.3-14h-32.8zm51.2 0l2.3 14h33.2l-2.9-14h-32.6zm-170.8 32l-14.4 46h136.3L313 377H202.6zM28 473v18h456v-18H28z","b":[27.5,25.0,457.0,466.0]},{"n":"lock","d":"M128 55c-9.118 0-17.148 1.724-23.621 6.203-6.473 4.479-10.598 11.358-12.98 19.092-3.278 10.638-4.112 23.58-4.323 39.705H76v68h104v-68h-11.078c-.214-16.037-1.051-28.954-4.318-39.588-2.38-7.746-6.49-14.642-12.958-19.15C145.18 56.754 137.132 55 128 55zm0 18c6.868 0 10.821 1.264 13.354 3.03 2.532 1.764 4.423 4.395 6.042 9.667 2.212 7.2 3.07 18.826 3.4 34.303h-45.595c.33-15.57 1.188-27.224 3.4-34.404 1.618-5.248 3.493-7.842 6.02-9.59C117.148 74.257 121.118 73 128 73zm0 60.191c6.503 0 11.775 5.273 11.775 11.776a11.775 11.775 0 0 1-6.025 10.262l6.025 19.58h-23.55l6.023-19.573a11.776 11.776 0 0 1-6.023-10.27c0-6.502 5.272-11.774 11.775-11.775z","b":[76.0,55.0,104.0,133.0]},{"n":"magnifying-glass","d":"M333.78 20.188c-39.97 0-79.96 15.212-110.405 45.656-58.667 58.667-60.796 152.72-6.406 213.97l-15.782 15.748 13.25 13.25 15.75-15.78c61.248 54.39 155.3 52.26 213.968-6.407 60.887-60.886 60.888-159.894 0-220.78C413.713 35.4 373.753 20.187 333.78 20.187zm0 18.562c35.15 0 70.285 13.44 97.158 40.313 53.745 53.745 53.744 140.6 0 194.343-51.526 51.526-133.46 53.643-187.5 6.375l.218-.217c-2.35-2.05-4.668-4.17-6.906-6.407-2.207-2.206-4.288-4.496-6.313-6.812l-.218.22c-47.27-54.04-45.152-135.976 6.374-187.502C263.467 52.19 298.63 38.75 333.78 38.75zm0 18.813c-30.31 0-60.63 11.6-83.81 34.78-46.362 46.362-46.362 121.234 0 167.594 10.14 10.142 21.632 18.077 33.905 23.782-24.91-19.087-40.97-49.133-40.97-82.94 0-15.323 3.292-29.888 9.22-43-4.165 20.485.44 40.88 14.47 54.907 24.583 24.585 68.744 20.318 98.624-9.562 29.88-29.88 34.146-74.04 9.56-98.625-2.375-2.376-4.943-4.473-7.655-6.313 45.13 8.648 79.954 46.345 84.25 92.876 4.44-35.07-6.82-71.726-33.813-98.72-23.18-23.18-53.47-34.78-83.78-34.78zM176.907 297.688L42.094 432.5l34.562 34.563L211.47 332.25l-34.564-34.563zM40 456.813L24 472.78 37.22 486l15.968-16L40 456.812z","b":[24.0,20.2,481.0,465.8]},{"n":"mesh-network","d":"M363.6 36.48c-22.2 0-40 17.8-40 40 0 22.23 17.8 40.02 40 40.02s40-17.79 40-40.02c0-22.2-17.8-40-40-40zm-56.7 51.97c-53.2 18.95-108.7 34.95-169 45.25 1.8 4.6 2.8 9.6 2.8 14.8 0 4.8-.8 9.4-2.4 13.6 96.2 12.9 182.8 36 257.8 71.9 1.6-5.9 4.5-11.3 8.3-15.9-71.2-34.3-152.4-57.2-241.5-70.7 53.2-10.6 102.8-25.4 150.4-42.2-3-5.2-5.2-10.79-6.4-16.75zm97.8 28.85c-4.3 4.3-9.2 8-14.6 10.8 15.3 24.8 26 50.6 31.8 77.8 4.3-1.5 9-2.4 13.8-2.4 1.4 0 2.8.1 4.1.2-6.3-30.3-18.2-59.1-35.1-86.4zm-305 8.2c-12.81 0-23 10.2-23 23s10.19 23 23 23c12.8 0 23-10.2 23-23s-10.2-23-23-23zm34.7 44.6c-3.2 5.2-7.5 9.6-12.6 12.9 32.1 32.6 66.1 65.9 120.6 80.4 0-.9-.1-1.9-.1-2.8 0-5.3 1.3-10.3 3.5-14.8-49.5-13.5-80-43.8-111.4-75.7zm-57 12.7c-21.76 67.8-27.12 137.2-32.29 206 2.13-.5 4.34-.7 6.6-.7 3.99 0 7.81.7 11.35 2.1 5.19-68.4 10.57-136 31.29-201.1-6.18-.8-11.94-3-16.95-6.3zm358.3 38.7c-12.8 0-23 10.2-23 23s10.2 23 23 23 23-10.2 23-23-10.2-23-23-23zm-41 22.2c-28.4 5.8-56.6 10.8-86 10.5.4 2.1.6 4.2.6 6.4 0 4-.7 7.9-2.1 11.5 32 .6 62-4.7 91.2-10.8-2.4-5.1-3.7-10.8-3.7-16.8zm-118.9 1.4c-8.7 0-15.5 6.8-15.5 15.5s6.8 15.5 15.5 15.5 15.5-6.8 15.5-15.5-6.8-15.5-15.5-15.5zM399 262.7c-55.6 45.9-106.6 94.4-143.1 150.7 5.9 1.8 11.2 5 15.6 9.1 34.9-53.5 84.2-100.8 138.8-145.9-4.7-3.7-8.6-8.5-11.3-13.9zm-152 15c-47.9 46.4-109.6 83.2-172.85 119.5 4.36 4.2 7.56 9.6 9.05 15.6C146.8 376.4 210 338.9 260 290.1c-5.4-2.9-9.9-7.2-13-12.4zm179.4 6.7c1.3 28.8 6 57.3 14.3 85.2 4.8-3.4 10.7-5.6 17-6-7.6-26-11.9-52.3-13.2-79.1-2.9.7-5.8 1-8.8 1-3.2 0-6.3-.4-9.3-1.1zm33.3 97.1c-8.4 0-15 6.6-15 15s6.6 15 15 15 15-6.6 15-15-6.6-15-15-15zM51.71 406.1c-8.07 0-14.42 6.4-14.42 14.4 0 8.1 6.35 14.5 14.42 14.5s14.42-6.4 14.42-14.5c0-8-6.35-14.4-14.42-14.4zm376.49.3c-44.7 24.5-93.8 32.6-144.9 35.6.9 3.4 1.4 6.9 1.4 10.5 0 2.6-.3 5.1-.7 7.5 53.1-3.1 105.8-11.6 154.3-38.5-4.7-4-8.2-9.2-10.1-15.1zM83.91 416.8c.14 1.2.22 2.4.22 3.7 0 5-1.15 9.7-3.19 14l121.86 20.3c-.1-.8-.1-1.5-.1-2.3 0-5.4 1.1-10.6 3-15.4zm159.79 12.7c-12.8 0-23 10.2-23 23s10.2 23 23 23 23-10.2 23-23-10.2-23-23-23z","b":[37.3,36.5,437.4,439.0]},{"n":"music","d":"M124.734 54.822c-6.63 32.107-6.636 61.281-3.925 91.428-4.451-1.396-9.259-2.119-14.12-2.123-19.462 0-35.24 11.272-35.24 25.178 0 13.905 15.778 25.178 35.24 25.177 19.462 0 35.238-11.272 35.239-25.177-3.043-25.866-5.412-53.264-4.424-76.164 13.96.963 35.798 6.57 46.432 13.052-1.774-6.322-5.745-31.348-4.038-34.941-16.697-12.256-37.656-16.702-55.164-16.43z","b":[71.4,54.6,112.5,139.9]},{"n":"musical-keyboard","d":"M369.1 19.82L19.81 369.1 142.9 492.2l69.3-69.3-79.2-79.2L412.9 63.66zM374 57.3l12.8 12.72-56.5 56.58-12.8-12.8zm51.7 19.1L413 89.12l66.5 66.48 12.7-12.7zm-25.5 25.5l-12.6 12.7 66.5 66.5 12.6-12.7zm-25.4 25.5L362.1 140l66.5 66.5 12.6-12.7zm-25.5 25.4l-12.6 12.7 66.5 66.4 12.6-12.6zm-74.3 3.5l12.8 12.8-11.3 11.3-12.8-12.8zm48.9 22L311.2 191l66.5 66.4 12.6-12.6zm-74.3 3.4l12.8 12.8-11.3 11.3-12.8-12.8zm48.8 22.1l-12.6 12.6 66.4 66.4 12.7-12.6zm-82.8 11.9l12.8 12.8-33.9 33.9-12.8-12.8zm57.4 13.5l-12.7 12.7 66.5 66.4 12.6-12.6zm-25.6 25.5l-12.6 12.6 66.5 66.5 12.6-12.6zm-88.3 17.5l12.8 12.8-34 34-12.8-12.8zm62.9 7.9l-12.6 12.7 66.4 66.4 12.7-12.6zm-25.4 25.5l-12.7 12.6 66.5 66.5 12.7-12.6zM86.27 322.5l35.33 35.3-46.64 46.7-29-29-6.35-6.4zm84.83 8.5l-12.7 12.7 66.5 66.5 12.7-12.7zm-84.83 16.9l-21.22 21.2 9.91 10 21.21-21.3zm38.83 26.2l12.8 12.8-33.9 33.9L91.23 408zm22.7 22.6l12.8 12.8-34 33.9-12.8-12.8zm22.6 22.6l12.8 12.8-33.9 34-12.8-12.8z","b":[19.8,19.8,472.4,472.4]},{"n":"musical-notes","d":"M98.05 18.54c-11.46-.08-23.59 1.28-36.08 3.99L130.1 261.1c-14.2-5.1-31.18-6.2-48.09-3.2-39.17 6.9-67.15 33.8-62.52 59.8 4.64 26.1 40.14 41.7 79.33 34.7 39.08-6.9 67.08-33.7 62.38-59.8-22.1-80.8-44.4-163-66.39-244.21 50.69 3.59 72.59 31.58 90.59 60.31-.5-62.33-37.7-89.81-87.35-90.16zm310.65 30.7c-13.9.1-28.8 2.59-44.1 7.22l87.1 232.44c-14.6-3.9-31.6-3.7-48.3.7-38.4 10-64.2 39-57.5 64.6 6.7 25.7 43.4 38.3 81.8 28.2 38.5-10 64.2-39 57.5-64.6-28.6-78.8-57.3-158.9-85.8-238.2 50.8-.5 74.9 25.7 95.2 52.9-5.2-58.55-40.4-83.61-85.9-83.26zM258.4 163.5l1.8 248.1c-12.3-8.6-28.4-14.3-45.6-15.9-39.4-3.8-73.7 14.5-76.2 41-2.5 26.3 27.7 50.8 67.1 54.5 39.7 3.9 73.7-14.5 76.3-40.9.2-83.8.8-168.9 1.3-253.1 47.9 17 61.6 49.8 71.2 82.4 19.9-74.1-27.9-112.3-95.9-116.1z","b":[14.9,18.5,479.7,476.6]},{"n":"musical-score","d":"M138.2 22.71c-25.5-.14-45.82 38.57-50.14 80.29H32v18h55.23c.07 6.1.49 12.1 1.33 18l17.34-18h25.5c-3.8 3.9-7.9 7.7-12.1 11.8l-31.24 32.5v-.1c-.53.6-1.1 1.2-1.64 1.8H32v18h38.17c-12.95 14.6-25.91 30.2-35.67 46H34v.8c-8.09 13.3-13.89 26.8-15.44 39.9-3.5 33.5 9.52 67.3 33.39 87.3H32v18h65.54c2.56.1 5.16.1 7.86 0h20.1c3.7 20.7 7 41.2 8.9 60 .4 3.6-6.6 10.6-10 11.4 0-22-17.8-39.9-39.84-39.9-21.9 0-39.8 17.9-39.8 39.9.1 20.1 15.2 35.8 35 39.5 41.84 7.7 78.34-17.9 72.44-53-2.9-19.1-6.2-38.5-9.7-57.9H480v-18H139.3c-2.9-15.5-5.8-30.9-8.5-46h37.3c-2.6 7.8-8.1 15.9-15.4 23l3.7 20.8c15.5-11.3 31.3-26.6 35.7-43.8H480v-18H192.9c-1.6-14.5-7.8-30.8-17.8-39.9-2.5-2.3-5.1-4.3-7.8-6.1H480v-18H116.8c-1.2-7.7-1.9-11.8-2.7-16.4l-15.54 15.1c.08.4.17.9.25 1.3H72.63c12.31-16.2 26.52-30.9 41.17-46H480v-18H130.9c10.5-11.3 20.9-23.2 30.7-36.4 2-2.8 3.8-6 5.3-9.6H480v-18H172.1c2.5-12.89 2.7-26.36 1.2-35.24-2.7-16.12-14.2-42.89-31.9-44.83-1.1-.14-2.1-.22-3.2-.22zm-5.5 37c6.9.1 14.4 5.8 15.6 15.95 1.3 11.18-.3 19.87-3.8 27.34h-36c3.4-20 11.2-42.23 24.2-43.29zM60.23 249h31.24c-13.45 12.5-19.59 29.6-18.93 46H42.79c.04-5.6.98-11.3 2.97-17 4.02-10.4 8.93-20 14.47-29zm63.57 11.3c11.8-.3 26.9 5.8 34 12.9 5.7 6.2 9.6 14.1 11.2 21.8h-41.5c-2.1-11.8-4.2-23.4-6-34.6.7-.1 1.5-.1 2.3-.1zm-19.4 6.5c1.5 8.9 3.3 18.4 5.2 28.2H90.63c.1-11 4.22-21.2 13.77-28.2zM45.75 313h30.39c2.69 7.2 6.83 13.9 12.42 19.4 5.1 5.2 15.14-2.7 10-8.6-1.93-3.5-3.54-7.1-4.81-10.8h19.35c3 15 6.1 30.5 9.1 46h-20v-.1c-25.44-3.3-48.49-22.3-56.45-45.9z","b":[15.1,22.6,464.9,473.0]},{"n":"mute","d":"M25.78 18v140.684c15.804 55.05 35.45 105.15 69.534 141.127 29.986 31.652 71.13 53.17 133.186 58.106-1.465-21.612-2.782-44.32-3.77-68.687-8.28 1.9-18.098 4.388-30.546 7.5l-4.368-17.46c13.796-3.45 24.812-6.15 34.26-8.112-.565-17.64-.957-36.102-1.068-55.773-24.658-2.122-51.63-6.376-86.008-12.608V208h-18v-32h18v5.81c39.205-4.887 66.136-8.12 89.102-9.67 3.264-9.885 9.035-18.425 17.01-24.765 11.33-9.01 26.565-13.45 44.077-12.875 2.5.082 5.05.267 7.64.555l7.383.822.594 7.402c.802 9.988 1.367 20.126 1.843 30.402 18.964 1.793 41.274 4.504 70.35 8.13V176h18v32h-18v-5.066c-26.533 5.123-48.64 8.784-68.684 11.082.872 20.248 2.045 41.043 4.444 62.418 3.592.882 7.386 1.826 11.424 2.836l-4.368 17.46c-1.735-.433-2.93-.728-4.568-1.138 2.71 18.324 6.478 37.062 11.902 56.242 40.524-9.445 70.1-27.748 93.098-52.023 34.084-35.977 53.73-86.076 69.533-141.126V18H325.4c2.027 10.094 3.343 20.117 3.596 29.764l-17.992.472c-.247-9.402-1.785-19.666-4.14-30.236H204.995C202.512 29.056 201 39.368 201 48h-18c0-9.32 1.253-19.484 3.355-30zm162.08 49.887c3.933-.04 7.64.68 10.935 2.092 7.532 3.227 12.568 8.657 17.568 13.657C226.363 93.637 235 103 256 103s29.637-9.363 39.637-19.363c5-5 10.036-10.43 17.568-13.658 7.532-3.23 17.21-2.836 26.82 1.97l-.004.007c5.888 2.693 10.056 8.65 10.056 15.467 0 9.282-7.718 17-17 17-8.693 0-16.01-6.77-16.906-15.252-2.246 1.778-4.84 4.224-7.807 7.19C298.363 106.363 283 121 256 121s-42.363-14.637-52.363-24.637c-2.968-2.967-5.56-5.413-7.807-7.19-.895 8.482-8.214 15.25-16.906 15.25-9.282 0-17-7.717-17-17 0-6.815 4.168-12.773 10.055-15.466l-.005-.008c4.805-2.403 9.627-3.703 14.19-4 .57-.036 1.135-.057 1.696-.063zm84.93 85.547c.27 22.19-.193 39.466 2.6 48.912 1.55 5.247 3.35 7.76 6.753 9.734 1.467.852 3.46 1.59 6.01 2.13-.92-21.412-1.5-41.967-2.825-61.53-4.22-.41-8.644.04-12.537.754zm-18.022 7.685c-.15.115-.307.227-.455.345C245.813 168.223 241 178.245 241 192v.045c-.466 92.33 4.96 159.972 9.81 223.818 20.016 4.087 36.912 7.04 51.19 9.352 13.76 2.227 24.982 3.81 34.55 5.326-35.895-71.67-44.2-138.057-47.505-197.91-6.045-.726-11.33-2.307-15.94-4.984-7.74-4.493-12.573-12.06-14.978-20.2-3.815-12.905-3.428-28.14-3.36-46.327zm-117.49 258.24c-6.108 7.06-11.408 19.73-15.366 34.786-3.253 12.375-5.668 26.162-7.873 39.854h33.308c-.47-20.78 5.12-37.688 24.004-39 71.475 12.15 148.648 12.283 207.306 30.576-.96-4.436-1.874-8.294-2.773-11.465-2.262-9.82-7.972-17.038-15.862-19.99-10.02-3.684-29.098-5.988-60.898-11.136-31.8-5.147-76.5-13.428-139.68-30.298-8.803-2.765-17.193 1.01-22.166 6.673zm-33.423 32.806c-4.966 1.588-10.514 4.09-15.714 7.324-12.333 7.672-21.705 18.87-22.072 30.05l.99 4.46h28.637c2.237-13.862 4.762-28.343 8.16-41.834zM162.328 494h190.93c-29.295-9.362-83.06-14.25-177.9-21.023-10.978.135-13.992 15.12-13.03 21.023z","b":[25.8,18.0,462.0,476.0]},{"n":"nuclear","d":"M256 31c-26.498 0-79.5 26.92-79.5 53.844S203.003 165.62 256 219.47c52.997-53.85 79.5-107.702 79.5-134.626C335.5 57.92 282.498 31 256 31zm1.53 215.406A52.997 53.847 0 0 0 203 300.25a52.997 53.847 0 0 0 106 0 52.997 53.847 0 0 0-51.47-53.844zm-166.155 80.47c-26.704.12-47.245 4.393-58.72 11.124-22.947 13.462-19.373 73.558-6.124 96.875 13.25 23.317 62.678 56.493 85.626 43.03 22.95-13.46 55.602-63.722 75-137.28-36.197-9.855-69.077-13.87-95.78-13.75zm329.25 0c-26.704-.122-59.584 3.894-95.78 13.75 19.397 73.557 52.05 123.818 75 137.28 22.947 13.462 72.375-19.714 85.624-43.03 13.248-23.318 16.822-83.414-6.126-96.876-11.474-6.73-32.015-11.004-58.72-11.125z","b":[9.7,31.0,492.6,460.4]},{"n":"nuclear-plant","d":"M13.447 18l4.826 20.656c17.47 32.683 68.819 20.747 94.545-1.635-14.136 38.399-65.72 49.25-95.964 26.354-.794 11.045 1.01 18.688 4.326 23.547 4.729 6.93 13.658 10.949 30.021 11.203l12.475.193-4.12 11.778c-5.347 15.288-4.928 23.375-1.91 28.478 1.975 3.337 6.034 6.533 12.678 9.545 40.193-8.27 83.572-9.067 121.676-9.119 28.214 0 56.41 1.001 79.78 3.033 23.37 2.032 41.025 4.306 52.245 9.916 10.816 5.781 25.574 5.525 36.207 3.994 9.222-1.415 16.325-4.613 21.387-10.853 3.954-4.874 7.015-12.152 7.9-23.31-33.606 4.231-67.935-8.9-76.294-47.872 40.54 37.963 82.92 42.849 131.005 16.412 11.444-6.49 18.25-14.805 20.485-27.605l1.392-7.975 8.079.543c7.79.524 14.336.366 19.814-.267V18h-21.979c-20.534 43.036-74.988 67.68-115.3 21.922 29.23 13.223 71.841 14.87 94.744-21.922H13.447zm270.645 29.957c-7.744 21.146-22.92 44.73-47.414 51.688-26.23 34.754-92.726 38.651-119.86-17.305 20.443 24.144 61.662 34.958 91.328 17.668-27.204-8.009-48.057-46.875-46.736-47.535 0 2.077 41.737 29.713 57.897 29.654 25.989.029 43.257-14.207 64.785-34.17zM494 72.945c-4.196.368-8.676.507-13.467.412-4.623 14.341-14.644 25.372-27.422 32.62-12.914 7.325-28.605 11.249-45.64 13.244-.675 15.828-4.645 28.298-11.873 37.209-8.483 10.457-20.558 15.453-32.637 17.306-12.578 1.93-25.722.924-37.504-.76a236.7 236.7 0 0 0-4.86 21.258C338.19 192.74 359.193 192 380.23 192c21.401 0 42.782.76 60.555 2.309 16.293 1.419 28.797 2.843 37.914 6.648 5.832-1.888 11.047-3.878 15.301-6.03v-22.613c-24.68 10.243-52.42 3.068-67.861-28.8 16.333 12.485 44.326 23.76 67.861 8.746V72.945zM192 157c-40.75 1.88-77.826-.767-116.965 8.832 28.05 96.266-1.687 216.838-32.195 309.791 11.247 5.175 30.635 10.198 53.91 13.465C124.683 493.008 158.353 495 192 495s67.317-1.992 95.25-5.912c23.275-3.267 42.663-8.29 53.91-13.465-30.508-92.953-60.246-213.525-32.195-309.791-8.367-2.095-22.342-4.439-38.744-5.865C247.59 157.999 219.786 157 192 157zm188.23 53c-20.97 0-41.962.757-58.994 2.24-1.125.098-2.22.207-3.308.317-8.896 79.06 12.998 172.267 37.445 248.76 8.189.323 16.517.501 24.857.501 25.373 0 50.765-1.507 71.762-4.459 16.35-2.298 30.045-5.83 38.403-9.298-22.686-69.604-44.617-159.096-24.422-231.875-6.263-1.396-15.673-2.981-26.748-3.946-17.032-1.483-38.023-2.24-58.995-2.24zm-141.335 28.21c29.289 17.126 45.21 48.33 44.464 80.056l-61.252-6c-.43-7.908-4.625-15.474-11.837-19.84l28.625-54.215zm-92.956 1.12l27.79 52.514a24.504 24.504 0 0 0-9.616 9.347 24.489 24.489 0 0 0-3.258 11.075l-57.384 6c-.42-16.048 3.166-32.448 11.78-47.37 7.723-13.372 18.408-23.987 30.688-31.566zm45.895 64.092c3.515.034 5.522.778 7.762 2.07a16.161 16.161 0 0 1 5.933 22.162 16.144 16.144 0 0 1-22.146 5.934 16.165 16.165 0 0 1-5.947-22.162c2.815-4.876 8.244-7.778 12.794-7.975a30.402 30.402 0 0 1 1.604-.03zm12.478 43.203l31.467 48.578c-13.778 7.362-29.255 11.298-44.92 10.89-14.368-.372-28.682-4.176-42.029-11.782l30.828-47.12c7.95 4.349 17.346 3.852 24.655-.566z","b":[13.4,18.0,480.6,477.0]},{"n":"open-folder","d":"M41 73v304.563L88.697 151H423v-30H185.514l-16-48H41zm62.303 96L43.092 455h381.605l60.211-286H103.303z","b":[41.0,73.0,443.9,382.0]},{"n":"padlock","d":"M254.28 17.313c-81.048 0-146.624 65.484-146.624 146.406V236h49.594v-69.094c0-53.658 43.47-97.187 97.03-97.187 53.563 0 97.032 44.744 97.032 97.186V236h49.594v-72.28c0-78.856-65.717-146.407-146.625-146.407zM85.157 254.688c-14.61 22.827-22.844 49.148-22.844 76.78 0 88.358 84.97 161.5 191.97 161.5 106.998 0 191.968-73.142 191.968-161.5 0-27.635-8.26-53.95-22.875-76.78H85.155zM254 278.625c22.34 0 40.875 17.94 40.875 40.28 0 16.756-10.6 31.23-25.125 37.376l32.72 98.126h-96.376l32.125-98.125c-14.526-6.145-24.532-20.62-24.532-37.374 0-22.338 17.972-40.28 40.312-40.28z","b":[62.3,17.3,383.9,475.7]},{"n":"padlock-open","d":"M402.6 164.6c0-78.92-65.7-146.47-146.6-146.47-81.1 0-146.6 65.49-146.6 146.47v72.3H159v-69.1c0-53.7 43.4-97.26 97-97.26 53.5 0 97 41.66 97 94.06zm-315.7 91C72.2 278.4 64 304.7 64 332.4c0 88.3 85 161.5 192 161.5s192-73.2 192-161.5c0-27.7-8.3-54-22.9-76.8zm168.8 23.9c22.3 0 40.9 18 40.9 40.3 0 16.8-10.6 31.2-25.1 37.3l32.7 98.2h-96.4l32.1-98.2c-14.5-6.1-24.5-20.6-24.5-37.3 0-22.3 18-40.3 40.3-40.3z","b":[64.0,18.1,384.0,475.8]},{"n":"pause-button","d":"M120.16 45A20.162 20.162 0 0 0 100 65.16v381.68A20.162 20.162 0 0 0 120.16 467h65.68A20.162 20.162 0 0 0 206 446.84V65.16A20.162 20.162 0 0 0 185.84 45h-65.68zm206 0A20.162 20.162 0 0 0 306 65.16v381.68A20.162 20.162 0 0 0 326.16 467h65.68A20.162 20.162 0 0 0 412 446.84V65.16A20.162 20.162 0 0 0 391.84 45h-65.68z","b":[100.0,45.0,312.0,422.0]},{"n":"phone","d":"M170.738 311.468c8.07-42.15 99.697-131.543 138.247-138.247 11.314 11.314 33.94 33.942 56.57 33.942l79.195-79.196c0-22.628-35.103-49.413-56.57-56.57C272.583 32.865 32.865 272.583 71.398 388.182c7.156 21.467 33.94 56.57 56.57 56.57l79.195-79.196c0-22.628-25.11-42.772-36.424-54.086z","b":[32.9,32.9,411.9,411.9]},{"n":"plain-padlock","d":"M256 18.15c-81.1 0-146.6 65.51-146.6 146.45v72.3H159v-69.1c0-53.7 43.4-97.24 97-97.24 53.5 0 97 44.84 97 97.24v69.1h49.6v-72.3c0-78.94-65.7-146.45-146.6-146.45zM86.9 255.6C72.3 278.4 64 304.7 64 332.4c0 88.3 85 161.5 192 161.5s192-73.2 192-161.5c0-27.7-8.3-54-22.9-76.8z","b":[64.0,18.1,384.0,475.8]},{"n":"plug","d":"M382.957 22.023c-2.618.033-5.138.96-7.26 3.082l-67.88 67.883 22.627 22.627 67.882-67.883c5.657-5.657 2.83-14.142-2.828-19.8-3.535-3.534-8.177-5.964-12.54-5.91zm-131.71 37.023l-21.92 21.92 203.648 203.647 21.92-21.92-11.315-11.315L262.56 70.36 251.25 59.047zm-23.335 45.96l-55.86 55.863v90.508l-22.628 22.63c-11.314 11.313-11.315 33.94.092 45.347l45.164 45.162c11.314 11.314 33.94 11.314 45.254 0l22.627-22.63h90.51l55.862-55.86-181.02-181.02zm245.555 7.527c-2.62.033-5.138.96-7.26 3.082l-67.88 67.883 22.626 22.626 67.883-67.882c5.657-5.657 2.83-14.142-2.828-19.8-3.536-3.535-8.177-5.965-12.54-5.91zM148.08 349.25l-128 128 12.727 12.728 128-128-12.727-12.727z","b":[20.1,22.0,474.4,468.0]},{"n":"popcorn","d":"M209 19.39c-16.9 2.15-23 19.58-29.7 33.81-15.5-5.07-38.7-11.67-48.3-4-2.3 2.31-4.3 7.35-5 14.31-.6 6.95-.1 15.42 1 23.45 1.5 10.37 3.9 19.94 5.3 25.24 10.3 4.2 17.8 10.7 21.8 18.3 5.3 9.8 5 21.6-1.9 29.9l-13.8-11.6c1.5-1.8 2.3-5.3-.1-9.8-10.4-11.1-50.17-26.9-63.92-13.1-1.29 1.5-2.69 5-2.96 10.4-.26 5.3.52 12 1.79 18.3 1.65 8.5 3.64 14.8 5.09 19 108.4 15.5 151.1 21.4 208.3 18 1-4.5 2.8-11.6 5.7-19.8 4.6-12.8 10.3-27.7 23-35.4 11-5.5 22.9-3.9 33.4-1.5 2.3-6.4 6.2-13.4 10.9-16.7 12.8-7.3 28.8-2.1 41.7 1.9l-7.4 13.3c-7.5-3.8-17.1-5.5-24.2-.3-6.3 4.6-7.6 16.4-10.7 22.9-8.4-1.9-26.4-8.4-34.3-4.2-4.4 2.3-11.4 14.6-15.4 26-1.6 4.5-2.9 8.8-3.9 12.5 32.3-2.8 71-8.2 127.9-16 6.3-7 18-23.3 17-30.7-13-5.3-27.9-3-41.7-2.2 5.6-10.4 19.9-24.4 18.7-36.3-13.9-11.21-41-8.41-56.3-7.11-1.3-13.56-6.4-45.29-16.2-51.29-20.4-2.19-37.7 8.35-55.5 18.48-2.7-10.73-6.4-36.42-15.9-39.07-14.2-3.96-27.2 4.31-40.5 10.82-12.2-7.94-26.9-18.44-33.9-17.54zm173.2 39.86c1.9 6.38 3.4 13.3 4.5 19.59 10.2-.11 19.3.21 28.6 1.9-.9-7.53-2.4-17.9-8.5-22.35-8.6-3.56-16.8-1.65-24.6.86zm-174.7 4.14c15.3 6.11 20.1 24.04 22.9 37.61 11.6-5.08 26.8-9.48 37.1-3.66 14.9 10.86 16 33.96 15.9 48.86l-18-.4c-.5-10-.4-18.5-3.9-28-1.5-4.6-4.4-5.7-8.5-5.2-13.3 2.1-24.9 9.3-36.8 16.1-1.8-13.2-1.1-45.12-13.9-48.1-12.5-2.91-23.8 13.25-32.7 23.4l-13.8-11.63c11.8-12.27 33-34.25 51.7-28.98zM87.62 88.25c-.43 4.61 0 10.47.91 16.35 8.47.1 16.27 1.3 24.07 2.8-2.4-10.47-3.9-19.81-4.7-29.74-10.58-2.27-19.11-.87-20.28 10.59zM76.29 191.5L135.4 487H182l-13.9-139.1c-10.5-10-17.1-22.2-17.1-35.9 0-10.6 4-20.3 10.6-28.8l-8.1-81c-21.9-2.9-47-6.4-77.21-10.7zm359.31.7c-30.2 4.2-55.3 7.6-77.2 10.4l-8 80.6c6.6 8.4 10.6 18.2 10.6 28.8 0 13.7-6.6 25.9-17.1 35.9L330 487h46.6zm-263.7 12.3l6.4 63.5c1.7-1.2 3.5-2.3 5.3-3.4 17-9.9 39.1-16.1 63.4-17.4v-36.9c-22.6-.4-45.9-2.4-75.1-5.8zm168.1.3c-29 3.4-52.3 5.2-75 5.6v36.8c24.3 1.3 46.4 7.5 63.4 17.4 1.8 1.1 3.6 2.2 5.3 3.4zM256 265c-25.1 0-47.7 6-63.3 15.2C177 289.3 169 300.7 169 312s8 22.7 23.7 31.8C208.3 353 230.9 359 256 359c25.1 0 47.7-6 63.3-15.2C335 334.7 343 323.3 343 312s-8-22.7-23.7-31.8C303.7 271 281.1 265 256 265zm-68.4 96.6L200.2 487H247V376.8c-22.5-1.2-43-6.6-59.4-15.2zm136.7 0c-16.4 8.6-36.9 14-59.3 15.2V487h46.8z","b":[71.2,18.5,380.1,468.5]},{"n":"rotary-phone","d":"M256 92.6c-69.6-.1-139.1 11.6-208.56 35.4 0 0-9.87 22.6-17.98 41.3a46.9 46.9 0 0 0-3.49 12.2c48.55-18.4 97.13-31 145.63-38 4.5-8.8 13.7-14.6 23.9-14.6h17.3c7.9 0 15.1 3.4 20.1 8.9 15.4-.6 30.8-.7 46.4-.1 4.9-5.5 12.1-8.8 19.8-8.8h17.3c10.1 0 19.1 5.6 23.7 14.1 48.7 6.6 97.2 19.4 145.9 38.3-.7-4-1.8-8.2-3.5-12-8.1-18.7-18-41.3-18-41.3-69.5-23.4-139-35.33-208.5-35.4zm-60.5 53.6c-4.7 0-8.8 3.4-9.6 8.1l-6.7 40.4c-12.1 2.2-23.9 5-35.3 8.4-9.8 3-17.6 10.4-21.2 19.9-13.8 37-48.72 130.6-48.72 130.6H438s-34.8-93.5-48.7-130.6c-3.5-9.5-11.4-17-21.2-19.9-11.4-3.4-23.2-6.2-35.3-8.4l-6.8-40.4c-.8-4.7-4.8-8.1-9.6-8.1h-17.3c-4.6 0-8.7 3.2-9.5 7.8l-2.2 10.6h-62.9l-2.2-10.6c-.8-4.6-4.8-7.8-9.5-7.8zm163.8 17.3-2.7 18.6c5.6 1.4 11.1 2.8 16.4 4.5 14 6.2 25.7 15.7 31.1 27.2l64.8 15.5c6.4-9.8 13.6-18.7 16.3-29.8-42-16.6-83.9-28.7-125.9-36zm-206.5.5c-42 7.5-84.01 19.4-126.02 35.6 3.05 11.7 9.6 19.6 16.31 29.7l64.81-15.5c5.9-13 17.2-23 31-27.2 5.5-1.6 11-3.1 16.5-4.5zM256 197.3c44.7 0 81 30.9 81 69s-36.3 68.9-81 68.9-81.1-30.8-81.1-68.9c0-38.1 36.4-69 81.1-69zm0 17.6c-30.1 0-54.5 20.8-54.5 46.4 0 25.6 24.4 46.4 54.5 46.4s54.4-20.8 54.4-46.4c0-25.6-24.3-46.4-54.4-46.4zM73.97 376.5l21.76 42.9H416.2l21.7-42.9z","b":[26.0,92.5,460.0,326.9]},{"n":"smartphone","d":"M160 32c-16 0-32 16-32 32v384c0 16 16 32 32 32h192c16 0 32-16 32-32V64c0-16-16-32-32-32H160zm21.68 23h96v18h-96V55zM304 55h32v18h-32V55zM154 96h204v320H154V96zm70 342h63.984c16 0 16 16 16 16v6H208v-6s0-16 16-16z","b":[128.0,32.0,256.0,448.0]},{"n":"spark-plug","d":"M468.8 38.21l-18.9 18.88h-22.6l-13.7 13.65 32.6 32.66 13.6-13.78V66.99l18.9-18.88zm-71.1 42.08c-2.3.42-5.3.91-8.5 1.69-6.8 1.63-14.5 5.09-15.9 6.44-1.3 1.34-4.8 9.05-6.4 15.98-1.6 6.7-2.4 12.6-2.4 12.6l-.7 7.2-7.2.7s-5.8.8-12.6 2.4c-6.9 1.6-14.6 5-15.9 6.4-1.4 1.3-4.8 9.1-6.5 15.9-1.5 6.8-2.3 12.7-2.3 12.7l-.9 8h-8.2s-7.1-.1-14.2 1.2c-2.3.4-4.5.9-6.4 1.5l54.3 54.3c.6-1.8 1.2-4 1.6-6.3 1.2-7.2 1.2-14.4 1.2-14.4l-.1-8.1 8-.9s5.9-.8 12.7-2.3c6.9-1.6 14.6-5.1 15.8-6.4 1.5-1.4 4.9-9.1 6.6-16 1.4-6.7 2.3-12.6 2.3-12.6l.8-7.2 7.1-.7s5.9-.8 12.7-2.4c6.8-1.6 14.5-5.1 15.9-6.4 1.2-1.3 4.8-9.1 6.4-15.9.8-3.2 1.3-6.2 1.7-8.5zM276.4 185.3l-21.2 21.2 55.2 55.2 21.2-21.2zm-52.8 30.2L210 229.2l4.9 4.9 72.8 72.8 13.7-13.6v-15.1l-39.2-39.3-23.5-23.4zm-60.3 37.7l-32.5 32.5 100.4 100.4 32.5-32.5zm45.3 0l-9.9 9.9 55 55.2 9.9-9.9zm-96.4 59.4l-11 14.1L203 405.9l11.1-14.1zm-22.6 22.6l-11.03 14.2 101.83 79.2 11-14.3zm-22.56 22.7L55.94 372l101.86 79.2 11-14.2zm-22.7 22.6l-11.03 14.1 101.89 79.2 11-14.1zm15.35 49.1l-14.15 28.3 13.44 13.4 28.28-14.1z","b":[33.3,38.2,445.4,435.6]},{"n":"stop-sign","d":"M352.7 21.04l-194.4.41L21.04 159.3l.41 194.4L159.3 491l194.4-.4L491 352.7l-.4-194.4L352.7 21.04zm-8 19.66l126.2 125.7.4 178.3-123.1 123.6-2.6 2.6-178.3.4L41.08 345.6l-.38-178.3L166.4 41.08l178.3-.38zm-7.5 18.01l-163.3.34L58.71 174.8l.34 163.3L174.8 453.3l163.3-.3 115.2-115.8-.3-163.3L337.2 58.71zM108.4 210.4c5.3 0 10.8.5 16.4 1.3 5.7.8 11.5 2 17.5 3.6v20.5c-5.3-2.4-10.5-4.2-15.6-5.4-5.1-1.2-9.9-1.8-14.4-1.8-6 0-10.4.8-13.25 2.5-2.87 1.6-4.3 4.2-4.3 7.7 0 2.6.96 4.6 2.87 6.1 1.95 1.4 5.48 2.7 10.58 3.7l10.6 2.1c10.8 2.2 18.5 5.5 23.1 9.9 4.5 4.5 6.8 10.8 6.8 18.9 0 10.7-3.2 18.7-9.5 24-6.4 5.2-16.1 7.8-29.2 7.8-6.1 0-12.3-.6-18.51-1.8-6.2-1.1-12.41-2.9-18.61-5.2v-21.1c6.2 3.3 12.19 5.8 17.96 7.5 5.82 1.6 11.46 2.4 16.76 2.4 5.5 0 9.7-.9 12.6-2.7 2.9-1.8 4.4-4.4 4.4-7.8 0-3.1-1-5.4-3-7.1-2-1.6-5.9-3.1-11.8-4.4l-9.7-2.1c-9.73-2.1-16.85-5.4-21.37-10-4.47-4.5-6.7-10.7-6.7-18.4 0-9.7 3.12-17.1 9.37-22.3 6.25-5.3 15.24-7.9 27-7.9zm187.7 0c15.6 0 27.8 4.5 36.7 13.5 8.9 8.9 13.3 21.2 13.3 37 0 15.7-4.4 28-13.3 37-8.9 8.9-21.1 13.4-36.7 13.4-15.6 0-27.8-4.5-36.7-13.4-8.9-9-13.3-21.3-13.3-37 0-15.8 4.4-28.1 13.3-37 8.9-9 21.1-13.5 36.7-13.5zm-141.9 1.8h89.6v18.9h-32.2v78.3h-25.1v-78.3h-32.3v-18.9zm205.8 0h41.6c12.3 0 21.8 2.8 28.4 8.3 6.7 5.4 10 13.2 10 23.4s-3.3 18.1-10 23.6c-6.6 5.4-16.1 8.2-28.4 8.2H385v33.7h-25v-97.2zm-63.9 16.4c-7.7 0-13.6 2.8-17.8 8.5-4.2 5.6-6.3 13.6-6.3 23.8 0 10.2 2.1 18.1 6.3 23.8 4.2 5.6 10.1 8.4 17.8 8.4 7.7 0 13.6-2.8 17.8-8.4 4.2-5.7 6.3-13.6 6.3-23.8 0-10.2-2.1-18.2-6.3-23.8-4.2-5.7-10.1-8.5-17.8-8.5zm88.9 1.8v27.1h13.9c4.9 0 8.6-1.2 11.3-3.5 2.6-2.4 3.9-5.8 3.9-10.1s-1.3-7.7-3.9-10c-2.7-2.4-6.4-3.5-11.3-3.5H385z","b":[21.0,21.0,470.0,470.0]},{"n":"tablet","d":"M22.5 93v326h467V93zm15.1 169.44a6.6 6.6 0 1 1 6.6-6.6 6.6 6.6 0 0 1-6.6 6.6zM427.5 401h-377V109h377zm29-133.32a11.85 11.85 0 1 1 11.85-11.85 11.85 11.85 0 0 1-11.85 11.85z","b":[22.5,93.0,467.0,326.0]},{"n":"ticket","d":"M323.9 19.81l-55.2 55.15L285 91.24 272.2 104 256 87.73 19.81 323.9l45.57 45.6c28.5-14.6 56.22-11.7 72.52 4.6 16.3 16.3 19.2 44 4.6 72.5l45.6 45.6 236.1-236.1-16.2-16.3 12.8-12.8 16.3 16.2 55.1-55.1-45.6-45.6c-28.5 14.6-56.2 11.7-72.5-4.6-16.3-16.3-19.2-44.02-4.6-72.52zm-16.2 93.99l33.9 34-12.8 12.8-33.9-34zM256 130.2L381.8 256 222.1 415.8 96.16 289.9 249.6 136.5zm0 25.4L121.6 289.9l100.5 100.5L356.4 256zm108.2 14.8l34 33.9-12.8 12.8-34-33.9z","b":[19.8,19.8,472.4,472.4]},{"n":"tracked-robot","d":"M231.377 25l-6 30H240v18h-18.223l-4.347 21.736L229.562 119H247V96h18v23h17.438l12.132-24.264L290.223 73H272V55h14.623l-6-30h-49.246zM104.32 71.486l-13.459 39.092H151V86.551l-46.68-15.065zm303.36 0L361 86.551v24.027h60.139l-13.46-39.092zM170.055 105l14.54 130.87L211.728 263h88.546l27.131-27.13L341.945 105h-32.382l-16 32h-75.125l-16-32h-32.383zm-69.334 14.027l-10.994 29.035 41.06 9.54 10.992-29.036-41.058-9.539zm269.504 9.55l10.988 29.025 41.06-9.54-7.378-19.486h-44.67zM100.3 168.996l8.933 59.187 29.666-4.479-7.156-47.404-31.443-7.305zm311.398 0l-31.443 7.304-7.156 47.404 29.666 4.479 8.933-59.188zM192 183h128v18H192v-18zm-54.092 59.057l-24.369 3.68c1.584 7.409 4.132 13.435 7.977 19.396 3.659 5.672 9.14 11.725 15.767 18.353-1.142-13.144-1.698-27.58.625-41.43zm236.184 0c2.323 13.85 1.767 28.285.625 41.43 6.626-6.63 12.108-12.682 15.767-18.354 3.845-5.96 6.393-11.987 7.977-19.397l-24.37-3.68zM217 281v51.273L243.727 359h24.546L295 332.273V281h-78zM99.768 313L89 323.947V327h62v-3.273L140.273 313H99.768zm272 0L361 323.947V327h62v-3.273L412.273 313h-40.505zM89 345v14h62v-14H89zm272 0v14h62v-14h-62zm-153 3.727l-7 7V405l27.117-36.156L208 348.727zm96 0l-20.117 20.117L311 405v-49.273l-7-7zM169 361v62h14v-62h-14zm160 0v62h14v-62h-14zM89 377v14h62v-14H89zm272 0v14h62v-14h-62zM89 409v14h62v-14H89zm272 0v14h62v-14h-62zM89 441v14h62v-14H89zm272 0v14h62v-14h-62zM89 473v14h62v-14H89zm272 0v14h62v-14h-62z","b":[89.0,25.0,334.0,462.0]},{"n":"triple-lock","d":"M205.5 22.46c-61.276.074-108.74 30.975-141.547 69.665-17.357 21.62-31.42 48.005-40.875 79.04l126.236 33.823-2.418 9.024c-4.61 17.21-1.716 30.275 4.954 40.35 6.67 10.074 17.62 17.196 29.87 20.27 12.247 3.072 25.55 2.006 36.512-3.54 7.643-3.866 14.295-9.773 19.098-18.477-9.31-13.04-13.174-27.55-12.412-41.334.956-17.288 8.75-33.3 20.426-45.356 11.676-12.056 27.436-20.32 44.767-21.383 14.838-.908 30.607 3.823 44.77 15.114l8.034-8.035c-15.862-20.453-34.494-37.005-54.187-49.4-26.933-16.854-52.138-19.52-73.422-9.89-1.975.894-3.926 1.904-5.85 3.025.987.835 1.953 1.705 2.883 2.635 18.255 18.255 18.256 48.136 0 66.393-14.328 14.327-35.815 17.405-53.225 9.242l-71.375-19.127 2.418-9.02C106.016 86.293 152.1 57.25 203.084 56.84c3.4-.028 6.82.072 10.256.3 50.24 3.315 104.02 31.904 142.892 81.16l27.995-27.993c-12.52-16.068-26.082-29.883-40.356-41.56-49.615-39.21-98.123-46.334-138.37-46.286zM427.69 93.27l-92.41 92.41-6.608-6.606c-12.6-12.6-25.358-16.62-37.418-15.883-12.06.738-23.703 6.66-32.488 15.732-8.786 9.07-14.515 21.123-15.194 33.39-.547 9.894 1.928 20.006 9.12 29.768 16.166-1.687 30.865 2.235 42.552 9.873 14.495 9.473 24.466 24.23 29.068 40.37 4.603 16.14 3.88 33.92-3.865 49.46-6.63 13.304-18.614 24.595-35.474 31.213l1.806 6.744c24.85-3.646 47.784-11.384 67.814-21.953 28.048-14.897 42.954-35.387 45.256-58.63.213-2.156.314-4.35.304-6.58-1.216.438-2.453.84-3.722 1.18-24.937 6.683-50.816-8.256-57.498-33.195-5.245-19.573 2.834-39.723 18.61-50.718l52.25-52.246 6.604 6.605c46.213 46.213 45.53 105.066 14.91 150.848-27.682 41.387-78.487 73.422-139.658 82.87l10.248 38.246c90.136-13.23 151.69-66.77 175.885-132.922 24.066-65.8 11.283-144.29-50.094-209.976zm-248.55 9.603c-7.21 0-14.424 2.78-19.98 8.337-11.114 11.114-11.112 28.847 0 39.96 11.114 11.113 28.85 11.11 39.96 0 11.115-11.115 11.113-28.848 0-39.96-5.556-5.557-12.768-8.336-19.98-8.336zM63.927 201.45c-36.107 86.415-20.79 168.475 25.242 223.51 44.95 53.74 119.32 81.915 206.893 61.604l-23.177-86.5c-.354.027-.704.065-1.06.09l-.39-5.504-9.197-34.32 9.024-2.418c17.21-4.612 27.077-13.65 32.467-24.465 5.39-10.813 6.082-23.858 2.62-36.002-3.464-12.144-11.038-23.132-21.324-29.853-8.428-5.508-18.61-8.425-30.923-6.914-6.674 12.36-16.37 21.49-27.432 27.086-15.45 7.816-33.217 9.072-49.496 4.988-16.28-4.084-31.315-13.6-40.9-28.078-8.207-12.395-11.992-28.417-9.293-46.328l-6.623-1.774c-10.547 24.858-15.907 50.268-16.828 74.426-1.124 31.74 9.168 54.897 28.146 68.512 1.76 1.263 3.61 2.45 5.545 3.554.23-1.272.5-2.544.84-3.814 5.664-21.138 25.12-35.095 46.106-34.787.677.01 1.355.034 2.035.074 3.11.182 6.24.68 9.36 1.516 19.57 5.244 32.98 22.314 34.616 41.474L249.3 438.9l-9.025 2.418c-63.128 16.915-113.755-13.102-138.093-62.51-22.604-45.89-24.443-107.98-.03-167.115L63.926 201.45zm319.95 18.685c-.41.007-.82.025-1.23.05-1.882.118-3.782.424-5.68.932-15.18 4.068-24.047 19.428-19.98 34.608 4.068 15.18 19.428 24.047 34.608 19.98 15.18-4.068 24.048-19.428 19.98-34.607-3.448-12.87-15.01-21.2-27.7-20.963zM183.812 343.123c-12.69-.237-24.25 8.096-27.698 20.963-4.068 15.182 4.8 30.54 19.98 34.607 15.18 4.068 30.54-4.8 34.606-19.98 4.07-15.182-4.8-30.538-19.98-34.606-1.897-.508-3.796-.816-5.677-.933-.41-.026-.82-.043-1.23-.05z","b":[23.1,22.4,478.8,484.5]},{"n":"vibrating-smartphone","d":"M134.5 30.5v451h243v-451h-243zm-44.41.5c-43.64 41-73.2 116-73.2 203.7 0 87.8 29.87 164 73.83 204.4C61.5 392.4 42.5 318.5 42.5 234.7 42.5 152 61.13 78 90.09 31zm331.81 0c28.9 47 47.6 121.1 47.6 203.8 0 83.8-19 157.7-48.2 204.3 43.9-40.3 73.8-116.5 73.8-204.3 0-87.7-29.6-162.8-73.2-203.8zM235.2 50.5h41.6a8 8 0 0 1 0 16h-41.6a8 8 0 0 1 0-16zM126 80c-37.75 24.9-64.74 85-64.74 154.7 0 70.4 27.11 130.3 65.14 154.8-25.5-30.3-42.84-88.2-42.84-154.8 0-66.4 17.14-124.8 42.44-154.7zm260 0c25.3 30 42.4 88.4 42.4 154.8 0 66.6-17.3 124.5-42.8 154.8 38-24.5 65.1-84.5 65.1-154.8 0-69.7-27-129.8-64.7-154.8zm-236.5 3.5h211v343h-211v-343zm105.3 349a19.26 19.26 0 0 1 20 19.3 19.26 19.26 0 0 1-19.3 19.2 19.26 19.26 0 0 1-.7-38.5z","b":[16.9,30.5,478.2,451.0]},{"n":"vintage-robot","d":"M260.22 58.28c-33.15 0-60.763 22.89-68 53.782h136c-7.24-30.89-34.85-53.78-68-53.78zM146.06 130.75v194.188H381.22V130.75H146.06zm117.063 24.125c32.075 0 58.28 26.207 58.28 58.28 0 32.075-26.206 58.282-58.28 58.282s-58.28-26.207-58.28-58.28c0-32.076 26.206-58.282 58.28-58.282zm-135.75 40.22c-37.902 8.577-67.593 37.596-77.094 75.124-3.368.833-6.668 2.127-9.81 3.936-18.16 10.452-24.47 33.907-13.97 52.03l16.156-9.342c-5.428-9.37-2.296-21.078 7.125-26.5l.157-.063c9.396-5.302 21.1-2.135 26.5 7.19 5.43 9.374 2.3 21.043-7.124 26.467l9.312 16.188c18.16-10.453 24.466-33.905 13.97-52.03-1.42-2.454-3.09-4.682-4.94-6.69 5.013-20.46 20.205-36.686 39.72-44v-42.31zm272.53 3.25v44.624c13.927 8.56 24.357 22.155 28.345 38.436-1.848 2.007-3.517 4.235-4.938 6.688-10.497 18.126-4.19 41.578 13.97 52.03l9.312-16.187c-9.425-5.424-12.555-17.093-7.125-26.468 5.427-9.375 17.234-12.55 26.655-7.126 9.42 5.422 12.553 17.13 7.125 26.5l16.156 9.344c10.5-18.125 4.19-41.58-13.97-52.032-3.142-1.81-6.442-3.103-9.81-3.937-8.527-33.68-33.33-60.522-65.72-71.876zm-224.28 145.28v33.125c5.605-1.6 11.743-2.5 18.438-2.5 8.152 0 15.475 1.222 22 3.406v-34.03h-40.438zm141.688 0v33.47c6.063-1.826 12.78-2.845 20.187-2.845 7.424 0 14.164 1.085 20.25 3.03v-33.655h-40.438zm-123.25 49.313c-21.565 0-31.638 9.323-38.75 23.375-5.676 11.21-8.255 25.565-9.438 38.718h96.438c-1.052-13.284-3.285-27.65-8.75-38.81-6.833-13.953-16.734-23.283-39.5-23.283zm143.437 0c-22.766 0-32.668 9.33-39.5 23.28-5.466 11.162-7.698 25.528-8.75 38.813h96.438c-1.183-13.152-3.763-27.506-9.438-38.717-7.113-14.052-17.186-23.375-38.75-23.375z","b":[16.0,58.3,483.9,396.8]},{"n":"wireframe-globe","d":"M256 23C127.4 23 23 127.4 23 256s104.4 233 233 233 233-104.4 233-233S384.6 23 256 23zm-33.7 20.63C190 66.85 163.6 92.25 143.2 119H90.26C122.9 79.54 169.4 51.95 222.3 43.63zm67.4 0c52.9 8.32 99.4 35.91 132 75.37h-52.9c-20.4-26.75-46.8-52.15-79.1-75.37zm-60.2 16.98C219 80.42 210 99.85 202.5 119h-36.3c17.1-20.39 38.2-40 63.3-58.39zm53 0c25.1 18.39 46.2 38 63.3 58.39h-36.3c-7.5-19.15-16.5-38.58-27-58.39zM247 65.99V119h-25.1c7-17.3 15.4-34.95 25.1-53.01zm18 0c9.7 18.06 18.1 35.71 25.1 53.01H265V65.99zM76.89 137h53.51c-9.8 15-17.8 30.4-23.9 46H53.71c5.89-16.3 13.71-31.8 23.18-46zm75.21 0h43.8c-5.4 15.5-9.6 30.8-12.9 46h-57.1c6.7-15.6 15.5-30.9 26.2-46zm62.8 0H247v46h-45.6c3.4-15.2 7.9-30.5 13.5-46zm50.1 0h32.1c5.6 15.5 10.1 30.8 13.5 46H265v-46zm51.1 0h43.8c10.7 15.1 19.5 30.4 26.2 46H329c-3.3-15.2-7.5-30.5-12.9-46zm65.5 0h53.5c9.5 14.2 17.3 29.7 23.2 46h-52.8c-6.1-15.6-14.1-31-23.9-46zM48.1 201h52.1c-4.63 15.2-7.5 30.6-8.64 46H41.2c.65-15.8 3.01-31.2 6.9-46zm70.9 0h60.5c-2.5 15.4-3.9 30.7-4.4 46h-65.5c1.2-15.3 4.4-30.7 9.4-46zm78.8 0H247v46h-53.9c.5-15.3 2-30.6 4.7-46zm67.2 0h49.2c2.7 15.4 4.2 30.7 4.7 46H265v-46zm67.5 0H393c5 15.3 8.2 30.7 9.4 46h-65.5c-.5-15.3-1.9-30.6-4.4-46zm79.3 0h52.1c3.9 14.8 6.2 30.2 6.9 46h-50.4c-1.1-15.4-4-30.8-8.6-46zM41.2 265h49.83c.23 15.5 2.24 30.9 6.02 46H48.1c-3.89-14.8-6.25-30.2-6.9-46zm67.8 0h66.1c.5 15.3 1.9 30.6 4.4 46h-63.9c-4.1-15.2-6.3-30.6-6.6-46zm84.1 0H247v46h-49.2c-2.7-15.4-4.2-30.7-4.7-46zm71.9 0h53.9c-.5 15.3-2 30.6-4.7 46H265v-46zm71.9 0H403c-.3 15.4-2.5 30.8-6.6 46h-63.9c2.5-15.4 3.9-30.7 4.4-46zm84.1 0h49.8c-.7 15.8-3 31.2-6.9 46H415c3.7-15.1 5.7-30.5 6-46zM53.71 329h48.69c5.4 15.7 12.8 31.1 22.1 46H76.89c-9.47-14.2-17.29-29.7-23.18-46zm67.69 0H183c3.3 15.2 7.5 30.5 12.9 46h-50c-10.4-14.9-18.5-30.3-24.5-46zm80 0H247v46h-32.1c-5.6-15.5-10.1-30.8-13.5-46zm63.6 0h45.6c-3.4 15.2-7.9 30.5-13.5 46H265v-46zm64 0h61.6c-6 15.7-14.1 31.1-24.5 46h-50c5.4-15.5 9.6-30.8 12.9-46zm80.6 0h48.7c-5.9 16.3-13.7 31.8-23.2 46h-47.6c9.3-14.9 16.7-30.3 22.1-46zM90.26 393h46.64c20.3 27.1 47.3 52.3 80.9 74.6-51-9.1-95.8-36.3-127.54-74.6zm69.34 0h42.9c7.9 20.4 17.6 41 29 62.1-29.3-18.9-53.2-39.8-71.9-62.1zm62.3 0H247v53c-9.7-18-18.1-35.7-25.1-53zm43.1 0h25.1c-7 17.3-15.4 35-25.1 53v-53zm44.5 0h42.9c-18.7 22.3-42.6 43.2-71.9 62.1 11.4-21.1 21.1-41.7 29-62.1zm65.6 0h46.6c-31.7 38.3-76.5 65.5-127.5 74.6 33.6-22.3 60.6-47.5 80.9-74.6z","b":[23.0,23.0,466.0,466.0]},{"n":"world","d":"M253.47 17.406C123.76 17.406 18.437 122.76 18.437 252.47c0 129.707 105.324 235.06 235.03 235.06 129.707 0 235.063-105.353 235.063-235.06 0-129.71-105.355-235.064-235.06-235.064zM367.874 68.75c61.246 38.19 101.97 106.14 101.97 183.72 0 17.143-1.993 33.823-5.75 49.81l-34.25-18.06 22 54.874c-9.454 21.647-22.362 41.432-38 58.687l-43.158-30.936-64.625 47.72-61.656 6.967-13.906-41.78-49.72 26.844-68.093-18.938 9.157 36.594c-28.41-21.793-51.23-50.466-66-83.563L81.25 304.47l32.25 17.124 59.22-9.875 2.843-40.908-37.344-1.718 4.905-17.844 30.78-25.313-25.093-15.625 67.22-38.593-45.345-29.657-66.625 40.187-49.437-15.28c13.812-32.14 35.21-60.22 61.906-82.064l-3.75 44.375 43.376-34.124 72 22.22-22.5-27.407L233 75.562l26.813 28.468 71 9.845-3.5-34.47 41.468 12.657-.905-23.312zm1.156 120.03L278 199.47l28.906 43.218 3.156 64.468L339.25 321l11.438-28.375 62.656 48.656L395.78 294l6.408-48.344-43.75-22.72 10.593-34.155zM221 192.438l-31.594 21.188 36.47 14.78 16.686-14.78L221 192.437zm22.188 144.688l18.687 52.594 19.78-42.564-38.467-10.03z","b":[18.4,17.4,470.1,470.1]},{"n":"gif·web","gif":"web.gif"},{"n":"gif·web2","gif":"web2.gif"},{"n":"gif·youtube","gif":"youtube.gif"},{"n":"console-controller","d":"M380.95 114.46c-62.946-13.147-63.32 32.04-124.868 32.04-53.25 0-55.247-44.675-124.87-32.04C17.207 135.072-.32 385.9 60.16 399.045c33.578 7.295 50.495-31.644 94.89-59.593a51.562 51.562 0 0 0 79.77-25.78 243.665 243.665 0 0 1 21.24-.91c7.466 0 14.44.32 21.126.898a51.573 51.573 0 0 0 79.82 25.717c44.45 27.95 61.367 66.93 94.955 59.626 60.47-13.104 42.496-260.845-71.01-284.543zM147.47 242.703h-26.144V216.12H94.73v-26.143h26.594v-26.593h26.144v26.582h26.582v26.144h-26.582v26.582zm38.223 89.615a34.336 34.336 0 1 1 34.337-34.336 34.336 34.336 0 0 1-34.325 34.346zm140.602 0a34.336 34.336 0 1 1 34.367-34.325 34.336 34.336 0 0 1-34.368 34.335zM349.98 220.36A17.323 17.323 0 1 1 367.3 203.04a17.323 17.323 0 0 1-17.323 17.323zm37.518 37.52a17.323 17.323 0 1 1 17.322-17.324 17.323 17.323 0 0 1-17.365 17.334zm0-75.048a17.323 17.323 0 1 1 17.322-17.323 17.323 17.323 0 0 1-17.365 17.333zm37.518 37.518a17.323 17.323 0 1 1 17.323-17.323 17.323 17.323 0 0 1-17.367 17.334z","b":[-0.3,101.3,512.8,305.0]},{"n":"encrypted-channel","d":"m399.816 26.656-38.025 28.782 9.318 12.312 12.967-9.814-.392 41.216 15.439.147.693-72.643zm-334.609.225c-8.453 0-15.595 5.085-20.111 11.734-4.517 6.65-6.973 15.136-6.973 24.364 0 9.227 2.456 17.714 6.973 24.363 4.516 6.649 11.658 11.734 20.111 11.734 8.453 0 15.597-5.085 20.113-11.734 4.517-6.65 6.973-15.136 6.973-24.363 0-9.228-2.456-17.715-6.973-24.364-4.516-6.649-11.66-11.734-20.113-11.734zM256 34c-27.111 0-49.757 8.433-66.252 23.4-16.495 14.968-26.617 35.397-33.133 58.204-8.595 30.082-11.34 65.024-12.213 101.396h32.162c.978-35.083 3.635-67.454 10.82-92.604 5.485-19.193 13.363-33.764 23.868-43.296C221.757 71.567 235.112 66 256 66c20.889 0 34.243 5.567 44.748 15.1 10.505 9.532 18.383 24.103 23.867 43.296 7.186 25.15 9.843 57.521 10.82 92.604h32.163c-.873-36.372-3.618-71.314-12.213-101.396-6.516-22.807-16.638-43.236-33.133-58.204C305.757 42.433 283.112 34 256 34zM65.207 42.88c2.088 0 4.488 1.205 6.879 4.725 2.391 3.52 4.207 9.083 4.207 15.374 0 6.29-1.816 11.852-4.207 15.373-2.391 3.52-4.791 4.724-6.879 4.724-2.088 0-4.486-1.204-6.877-4.724-2.39-3.52-4.207-9.083-4.207-15.373 0-6.291 1.816-11.853 4.207-15.374 2.391-3.52 4.79-4.724 6.877-4.724zm47.85 53.298L75.03 124.959l9.319 12.31 12.966-9.814-.392 41.219 15.44.146.693-72.642zm126.634.222c-8.452 0-15.596 5.086-20.113 11.735-4.516 6.649-6.973 15.136-6.973 24.363s2.457 17.714 6.973 24.363c4.517 6.65 11.66 11.735 20.113 11.735s15.597-5.085 20.114-11.735c4.516-6.649 6.97-15.136 6.97-24.363s-2.454-17.714-6.97-24.363c-4.517-6.65-11.66-11.735-20.114-11.735zm202.38 0c-8.454 0-15.598 5.086-20.114 11.735-4.516 6.649-6.973 15.136-6.973 24.363s2.457 17.714 6.973 24.363c4.517 6.65 11.66 11.735 20.113 11.735s15.595-5.085 20.112-11.735c4.516-6.649 6.972-15.136 6.972-24.363s-2.456-17.714-6.972-24.363c-4.517-6.65-11.659-11.735-20.112-11.735zm-202.38 16c2.088 0 4.486 1.205 6.877 4.725 2.391 3.52 4.207 9.082 4.207 15.373 0 6.29-1.816 11.853-4.207 15.373-2.39 3.52-4.789 4.725-6.877 4.725-2.087 0-4.487-1.205-6.879-4.725-2.39-3.52-4.207-9.082-4.207-15.373 0-6.29 1.816-11.853 4.208-15.373 2.39-3.52 4.79-4.725 6.878-4.725zm202.38 0c2.087 0 4.485 1.205 6.876 4.725 2.391 3.52 4.207 9.082 4.207 15.373 0 6.29-1.816 11.853-4.207 15.373-2.39 3.52-4.789 4.725-6.877 4.725-2.087 0-4.488-1.205-6.879-4.725-2.39-3.52-4.207-9.082-4.207-15.373 0-6.29 1.816-11.853 4.207-15.373 2.391-3.52 4.792-4.725 6.88-4.725zm-132.397 49.871-38.026 28.782 9.319 12.31 12.969-9.816-.223 23.453h15.44l.52-54.729zm184.035 0-38.025 28.782 9.318 12.31 12.969-9.816-.393 41.22 15.44.147.691-72.643zm-449.16.223c-8.453 0-15.597 5.085-20.113 11.735-4.517 6.649-6.973 15.135-6.973 24.363 0 9.227 2.456 17.714 6.973 24.363 4.516 6.65 11.66 11.734 20.113 11.734s15.597-5.085 20.113-11.734c4.517-6.65 6.973-15.136 6.973-24.363 0-9.228-2.456-17.714-6.973-24.363-4.516-6.65-11.66-11.735-20.113-11.735zm0 16c2.087 0 4.486 1.205 6.877 4.725 2.39 3.52 4.209 9.082 4.209 15.373 0 6.29-1.818 11.853-4.21 15.373-2.39 3.52-4.789 4.724-6.876 4.724-2.088 0-4.486-1.204-6.877-4.724-2.391-3.52-4.21-9.083-4.21-15.373 0-6.29 1.819-11.853 4.21-15.373 2.39-3.52 4.79-4.725 6.877-4.725zM137 235v238h238V235H137zM16 257v18h103v-18H16zm377 0v18h23v-18h-23zm55 0v18h32v-18h-32zm-192 31a32 32 0 0 1 32 32 32 32 0 0 1-23.19 30.764l23.19 80.98h-64l23.19-80.98A32 32 0 0 1 224 320a32 32 0 0 1 32-32zm-208 1v18h48v-18H48zm384 0v18h48v-18h-48zM32 337v18h80v-18H32zm361 0v18h71v-18h-71zM16 385v18h48v-18H16zm80 0v18h23v-18H96zm320 0v18h64v-18h-64zM48 433v18h71v-18H48zm352 0v18h32v-18h-32zm48 0v18h48v-18h-48z","b":[16.0,26.7,480.0,446.3]},{"n":"video-conference","d":"M256 23c-22.5 0-41 18.46-41 41s18.5 41 41 41 41-18.46 41-41-18.5-41-41-41zm0 82H41v270h430V105H256zm0-64c12.8 0 23 10.19 23 23s-10.2 23-23 23-23-10.19-23-23 10.2-23 23-23zM64 128h384v224H322.9c-.3-37.8-3.8-100.3-47.9-114a44.51 50 0 0 0 25.6-45.2 44.51 50 0 0 0-44.5-50 44.51 50 0 0 0-44.5 50 44.51 50 0 0 0 25.6 45.2c-44.1 13.7-47.6 76.2-47.9 114H64V128zm133.9 263.5l-12.4 62h138l-12.4-62H197.9zM160 471v18h192v-18H160z","b":[41.0,23.0,430.0,466.0]},{"n":"card-play","d":"M272.824 24.318c-14.929.312-25.66 3.246-32.767 8.446L142.898 84.91l-54.105 73.514C77.42 175.98 85.517 210 121.111 188.197l38.9-51.351c49.476-42.711 150.485-23.032 102.587 62.591-23.53 49.582-12.457 73.79 17.76 83.95l13.812-46.381c23.949-53.825 68.502-63.51 66.684-106.904l107.302 7.724-.865-112.045-194.467-1.463zm-54.09 103.338c-17.41-.3-34.486 6.898-46.92 17.375l-39.044 51.33c10.713 8.506 21.413 3.96 32.125-6.363 12.626 6.394 22.365-3.522 30.365-23.297 3.317-13.489 8.21-23.037 23.474-39.045zm-32.617 88.324a13.49 13.49 0 0 0-5.232 1.235L51.72 276.725c-6.784 3.13-9.763 11.202-6.633 17.992l85.27 185.08c3.131 6.783 11.204 9.779 18 6.635l129.15-59.504c6.796-3.137 9.776-11.198 6.646-18L198.871 223.86c-2.344-5.097-7.474-8.043-12.754-7.88z","b":[42.0,24.3,426.2,465.3]},{"n":"pocket-watch","d":"M254.84 255.64a127.867 127.867 0 1 0 61.614 76.03 127.04 127.04 0 0 0-61.615-76.03zm-31.233 212.62a103.9 103.9 0 0 1-79.58-8.33 104.52 104.52 0 1 1 79.58 8.33zm54.65-125.248a87.963 87.963 0 1 0-59.328 109.373 87.414 87.414 0 0 0 59.327-109.373zm-37.1 38.962a8.28 8.28 0 0 1-9.56 6.747l-37.256-6.436a8.362 8.362 0 0 1-.827-.186h-.124a8.28 8.28 0 0 1-.88-.32l-.24-.104a8.175 8.175 0 0 1-.9-.487h-.07l-59.174-37.244a8.28 8.28 0 0 1 8.817-14.012l57.755 36.324 35.67 6.158a8.28 8.28 0 0 1 6.76 9.562zm164.75-76.838c10.09 34.016 15.046 67.203 13.94 93.478-1.12 26.69-8.156 38.176-14.365 40.018-6.21 1.842-18.368-3.943-33.87-25.706-15.244-21.42-29.194-51.95-39.325-85.955-22.53-75.947-14.933-128.942.424-133.495 15.36-4.553 50.668 35.703 73.197 111.66zm-25.8-95.517a136.808 136.808 0 0 0-12.914-15.772q13.712 4.625 26.42 16.65c19.124 18.13 35.33 48.71 44.498 83.886 8.963 34.512 10.35 69.884 3.85 97.06a99.894 99.894 0 0 1-6.405 18.523c.362-3.322.632-6.86.797-10.67 1.17-28.044-4.015-63.126-14.612-98.88-10.597-35.754-25.354-67.98-41.632-90.798zM357.104 16.1h-16.868v.125a8.765 8.765 0 0 1-.518 6.737 8.765 8.765 0 0 1-5.174 4.398 8.838 8.838 0 0 1-11.125-5.65l-1.748-5.61h-17.417l3.508 10.743c.094.29.218.56.322.838a25.168 25.168 0 0 0-11.456 10.35l-11.383 19.662a25.302 25.302 0 0 0-3.322 10.576 25.457 25.457 0 0 0-7.864 1.263l-19.662 6.437a25.21 25.21 0 0 0-7.358-11.59l-16.92-15.16a25.2 25.2 0 0 0-18.327-6.458 25.758 25.758 0 0 0-2.992.34 25.426 25.426 0 0 0-24.464-18.627H161.64a25.416 25.416 0 0 0-25.096 21.64 25.56 25.56 0 0 0-5.38.175 25.22 25.22 0 0 0-16.755 9.84l-13.692 18.11a25.416 25.416 0 0 0 3.177 34.08 25.364 25.364 0 0 0-4.036 22.435l6.456 21.732a25.24 25.24 0 0 0 9.17 13.11 32.267 32.267 0 0 0 25.933 51.496h1.19l4.273 14.395a151.463 151.463 0 0 1 5.91-1.904q4.738-1.406 9.51-2.472l-4.316-14.56a32.267 32.267 0 0 0-3.912-57.394 25.27 25.27 0 0 0 .962-17.075l-6.457-21.733a25.24 25.24 0 0 0-7.244-11.55l13.63-18.036a25.23 25.23 0 0 0 4.842-11.517c.62 0 1.252.072 1.883.072h22.706a25.406 25.406 0 0 0 4.346-.382 25.21 25.21 0 0 0 7.513 12.138l16.807 15.12a25.28 25.28 0 0 0 16.94 6.48 25.57 25.57 0 0 0 6.002-.726c.062.228.124.445.197.673a25.426 25.426 0 0 0 24.103 17.51 25.478 25.478 0 0 0 7.906-1.273l21.576-7.047a25.416 25.416 0 0 0 17.447-22.022 25.52 25.52 0 0 0 6.56-.88 25.21 25.21 0 0 0 15.41-11.828l11.384-19.662a25.333 25.333 0 0 0 1.83-21.37A25.437 25.437 0 0 0 357.104 16.1zM122.19 147.808l-6.457-21.732a8.745 8.745 0 0 1 7.027-11.207c.414 0 .828-.063 1.242-.114h.186a8.838 8.838 0 0 1 8.465 6.312l6.458 21.732a8.817 8.817 0 0 1-4.987 10.618c-.63.145-1.263.31-1.894.497l-.415.134a8.838 8.838 0 0 1-9.603-6.24zm19.23 21.308a15.875 15.875 0 1 1-5.465 1.035 25.94 25.94 0 0 0 1.914-.487l.796-.26a15.668 15.668 0 0 1 2.773-.288zm.237-92.382l-13.64 18.12a8.776 8.776 0 0 1-5.474 3.353c-.497 0-1.035.083-1.5.145a8.817 8.817 0 0 1-7.11-14.124l13.69-18.11a8.827 8.827 0 1 1 14.034 10.617zm50.594-23.036q-.61.89-1.148 1.81a8.807 8.807 0 0 1-6.8 3.21H161.64a8.827 8.827 0 1 1 0-17.645h22.704a8.807 8.807 0 0 1 7.948 12.625zm44.334 35.496a8.817 8.817 0 0 1-12.418.673l-16.89-15.16a8.827 8.827 0 0 1-2.07-10.35q.57-.828 1.036-1.697c.103-.125.196-.26.31-.384a8.838 8.838 0 0 1 12.42-.672l16.898 15.17a8.817 8.817 0 0 1 .766 12.42zm53.202 8.486a8.765 8.765 0 0 1-5.175 4.397l-21.493 7.058a8.827 8.827 0 1 1-5.484-16.775l21.587-7.048a8.827 8.827 0 0 1 10.607 12.377zm36.416-42.513L314.82 74.83A8.827 8.827 0 0 1 299.533 66l11.383-19.662a8.843 8.843 0 1 1 15.327 8.827z","b":[99.9,16.1,348.6,452.2]},{"n":"crt-2d","d":""},{"n":"gears-2d","d":""},{"n":"chart-2d","d":""},{"n":"film-strip-2d","d":""}])
    readonly property var curSec: items[Math.max(0, Math.min(secIdx, items.length - 1))]

    // Hand-drawn Super-8 cine camera as a LONG silhouette — pistol grip + long
    // lens barrel reads like a rifle (the MGS weapon-icon joke), the film reel
    // keeps it legibly a camera. Composed from solid blocks so it tints with the
    // slot. Designed in a 44×96 field (tall), scales with the item's width.
    component Super8Icon: Item {
        id: s8
        property color color: "white"
        readonly property real u: width / 44
        // long lens barrel (the "muzzle")
        Rectangle { color: s8.color; x: 17 * s8.u; y: 7 * s8.u; width: 9 * s8.u; height: 40 * s8.u }
        Rectangle { color: s8.color; x: 14 * s8.u; y: 3 * s8.u; width: 15 * s8.u; height: 7 * s8.u; radius: s8.u }
        Rectangle { color: s8.color; x: 19 * s8.u; y: 44 * s8.u; width: 5 * s8.u; height: 5 * s8.u }
        // camera body
        Rectangle { color: s8.color; x: 9 * s8.u; y: 47 * s8.u; width: 28 * s8.u; height: 25 * s8.u; radius: 2 * s8.u }
        // film chamber — round, off the back
        Rectangle { color: s8.color; x: 1 * s8.u; y: 43 * s8.u; width: 20 * s8.u; height: 20 * s8.u; radius: 10 * s8.u }
        Rectangle { color: Theme.withAlpha(Theme.bg, 0.9); x: 7 * s8.u; y: 49 * s8.u; width: 8 * s8.u; height: 8 * s8.u; radius: 4 * s8.u }
        // viewfinder nub, front-top
        Rectangle { color: s8.color; x: 33 * s8.u; y: 49 * s8.u; width: 9 * s8.u; height: 8 * s8.u }
        // pistol grip, angled back
        Rectangle {
            color: s8.color; x: 18 * s8.u; y: 68 * s8.u; width: 10 * s8.u; height: 27 * s8.u; radius: 2 * s8.u
            transform: Rotation { origin.x: 23 * s8.u; origin.y: 68 * s8.u; angle: 15 }
        }
    }

    // Tactical HUD corner-brackets — the AC/codec "housing" that frames the
    // section weapon. Each Corner fills the frame and draws one L at its corner.
    component Corner: Item {
        property color c: "white"
        property real arm: 8
        property real th: 1.5
        property int hx: 0   // 0 left · 1 right
        property int vy: 0   // 0 top · 1 bottom
        Rectangle {
            color: parent.c; width: parent.arm; height: parent.th
            x: parent.hx === 0 ? 0 : parent.width - parent.arm
            y: parent.vy === 0 ? 0 : parent.height - parent.th
        }
        Rectangle {
            color: parent.c; width: parent.th; height: parent.arm
            x: parent.hx === 0 ? 0 : parent.width - parent.th
            y: parent.vy === 0 ? 0 : parent.height - parent.arm
        }
    }

    // Normalised icon render: any pool icon {n,d,b} centred + scaled to fill a
    // size×size box via its precomputed bounding box, so every silhouette sits at
    // consistent proportions regardless of where it lives in its 512 viewBox.
    component IconShape: Item {
        id: isr
        property var icon
        property real size: 40
        property color color: "white"
        property real fill: 0.9
        width: size; height: size
        Shape {
            width: 512; height: 512
            antialiasing: true
            transform: Matrix4x4 {
                matrix: {
                    var b = (isr.icon && isr.icon.b) ? isr.icon.b : [0, 0, 512, 512]
                    var k = isr.size * isr.fill / Math.max(b[2], b[3], 1)
                    var tx = isr.size / 2 - k * (b[0] + b[2] / 2)
                    var ty = isr.size / 2 - k * (b[1] + b[3] / 2)
                    return Qt.matrix4x4(k, 0, 0, tx, 0, k, 0, ty, 0, 0, 1, 0, 0, 0, 0, 1)
                }
            }
            ShapePath {
                fillColor: isr.color
                strokeWidth: 0
                fillRule: ShapePath.OddEvenFill
                PathSvg { path: isr.icon && isr.icon.d ? isr.icon.d : "" }
            }
        }
    }

    // Clapperboard built from SEPARATE parts so the clapstick actually HINGES —
    // the slate stays put, the striped stick pivots on its bottom-left corner.
    // `clap`: 0 = shut (stick down on the slate) .. 1 = raised open.

    component ClapperBoard: Item {
        id: cb
        property color color: "white"
        property real clap: 0
        readonly property real u: width / 100
        readonly property real lw: Math.max(1.5, 4 * cb.u)
        // ONE MSAA layer over the whole board (never per part): the rotated
        // stripes and hinge circle render clean, and the cel steps mean the
        // layer only re-renders on pose changes
        layer.enabled: true
        layer.samples: 4
        layer.smooth: true
        transform: Translate { y: -6 * cb.u }
        // the strike is DECLARED by the animation, not inferred from pose —
        // the resting fidget closes the sticks too, and must never flash
        property bool snapping: false   // the smear's 45ms
        property bool impact: false     // the contact cels: flash/dust/squash
        readonly property bool jolt: impact
        readonly property bool flashF: impact
        Item {  // ── the SLATE + FIXED JAW — one body, shuddering on impact
            anchors.fill: parent
            transform: Translate { y: cb.jolt ? 1.2 * cb.u : 0 }
            Rectangle {  // board
                x: 7 * cb.u; y: 40 * cb.u; width: 86 * cb.u; height: 52 * cb.u
                radius: 3 * cb.u
                color: "transparent"; border.color: cb.color; border.width: cb.lw
            }
            Rectangle {  // the FIXED bottom stick — part of the board, the
                // anatomy the old drawing was missing entirely
                x: 7 * cb.u; y: 30.5 * cb.u; width: 86 * cb.u; height: 9.5 * cb.u
                color: cb.color
                clip: true
                Repeater {  // its stripes lean one way…
                    model: 4
                    Rectangle {
                        color: Theme.withAlpha(Theme.bg, 0.92)
                        width: 8 * cb.u; height: parent.height * 2.4
                        x: (17 + index * 23) * cb.u; y: -parent.height * 0.7
                        transformOrigin: Item.Center; rotation: -38
                    }
                }
            }
            // the ROLL / SCENE / TAKE row — the three ruled boxes that make
            // a slate a slate; their entries rewrite on every clack
            Rectangle { color: cb.color; opacity: 0.4; x: 9.5 * cb.u; y: 58 * cb.u; width: 81 * cb.u; height: Math.max(1, 1.4 * cb.u) }
            Rectangle { color: cb.color; opacity: 0.38; x: 36 * cb.u; y: 44.5 * cb.u; width: Math.max(1, 1.4 * cb.u); height: 13.5 * cb.u }
            Rectangle { color: cb.color; opacity: 0.38; x: 64 * cb.u; y: 44.5 * cb.u; width: Math.max(1, 1.4 * cb.u); height: 13.5 * cb.u }
            Rectangle { color: cb.color; x: 13 * cb.u; y: 48.5 * cb.u; width: 13 * cb.u; height: Math.max(1, 3 * cb.u); radius: height / 2 }
            Rectangle { color: cb.color; x: 41 * cb.u; y: 48.5 * cb.u; width: 16 * cb.u; height: Math.max(1, 3 * cb.u); radius: height / 2 }
            Rectangle { color: cb.color; x: 69 * cb.u; y: 48.5 * cb.u; width: 9 * cb.u; height: Math.max(1, 3 * cb.u); radius: height / 2 }
            // the lower rules — DIRECTOR/DATE lines with handwriting ON them
            Rectangle { color: cb.color; opacity: 0.35; x: 13 * cb.u; y: 73.5 * cb.u; width: 74 * cb.u; height: Math.max(1, 1.2 * cb.u) }
            Rectangle { color: cb.color; x: 14 * cb.u; y: 69 * cb.u; width: 27 * cb.u; height: Math.max(1, 3 * cb.u); radius: height / 2 }
            Rectangle { color: cb.color; opacity: 0.35; x: 13 * cb.u; y: 84.5 * cb.u; width: 74 * cb.u; height: Math.max(1, 1.2 * cb.u) }
            Rectangle { color: cb.color; x: 14 * cb.u; y: 80 * cb.u; width: 19 * cb.u; height: Math.max(1, 3 * cb.u); radius: height / 2 }
        }
        Item {  // ── the SWINGING stick — scissors about the left hinge
            id: stick
            x: 7 * cb.u; y: 21 * cb.u; width: 86 * cb.u; height: 9.5 * cb.u
            transform: Rotation {
                origin.x: 4 * cb.u
                origin.y: 10 * cb.u
                angle: -cb.clap * 17
            }
            Rectangle {
                anchors.fill: parent
                color: cb.color
                clip: true
                Repeater {  // …and its stripes lean the OTHER way: closed,
                    // the pair meets in chevrons, the pro-slate signature
                    model: 4
                    Rectangle {
                        color: Theme.withAlpha(Theme.bg, 0.92)
                        width: 8 * cb.u; height: parent.height * 2.4
                        x: (17 + index * 23) * cb.u; y: -parent.height * 0.7
                        transformOrigin: Item.Center; rotation: 38
                    }
                }
            }
        }
        Rectangle {  // impact flash — the stick pair burns white for two cels
            visible: cb.flashF
            x: 7 * cb.u; y: 21 * cb.u; width: 86 * cb.u; height: 19 * cb.u
            color: Theme.withAlpha(Theme.fg, 0.4)
        }
        Repeater {  // SPEED LINES — three trails above the free end, alive
            // only for the strike's own cel: where the stick just WAS
            model: 3
            Rectangle {
                visible: cb.snapping
                x: (68 + index * 9) * cb.u
                y: (6 + index * 2.5) * cb.u
                width: Math.max(1, 1.6 * cb.u)
                height: (11 - index * 2.5) * cb.u
                radius: width / 2
                color: Theme.withAlpha(cb.color, 0.6)
            }
        }
        Item {  // SMEAR — one detail-less ghost of the stick held at a
            // mid angle for the strike's single cel: speed made visible
            visible: cb.snapping
            x: 7 * cb.u; y: 20 * cb.u; width: 86 * cb.u; height: 10 * cb.u
            opacity: 0.3
            transform: Rotation {
                origin.x: 4 * cb.u
                origin.y: 10 * cb.u
                angle: -8
            }
            Rectangle { anchors.fill: parent; color: cb.color }
        }
        Rectangle {  // impact dust — a fleck kicked off the free end
            visible: cb.jolt
            x: 88 * cb.u; y: 25.5 * cb.u
            width: 1.8 * cb.u; height: 1.8 * cb.u; radius: width / 2
            color: Theme.withAlpha(Theme.fg, 0.5)
        }
        Rectangle {
            visible: cb.jolt
            x: 84.5 * cb.u; y: 22 * cb.u
            width: 1.4 * cb.u; height: 1.4 * cb.u; radius: width / 2
            color: Theme.withAlpha(Theme.fg, 0.4)
        }
        Rectangle {  // comic impact star — crossed rays at the contact
            // point, the cartoon 'CLACK!' punctuation
            visible: cb.impact
            x: 83 * cb.u; y: 29 * cb.u
            width: 7 * cb.u; height: Math.max(1, 1.6 * cb.u)
            radius: height / 2
            rotation: 45
            color: Theme.withAlpha(Theme.fg, 0.65)
        }
        Rectangle {
            visible: cb.impact
            x: 83 * cb.u; y: 29 * cb.u
            width: 7 * cb.u; height: Math.max(1, 1.6 * cb.u)
            radius: height / 2
            rotation: -45
            color: Theme.withAlpha(Theme.fg, 0.65)
        }
        Rectangle {  // impact spark — the meeting line itself flashes
            visible: cb.jolt
            x: 12 * cb.u; y: 28.6 * cb.u
            width: 76 * cb.u; height: Math.max(1, 1.6 * cb.u)
            radius: height / 2
            color: Theme.withAlpha(Theme.fg, 0.6)
        }
        // the HINGE — knuckle bridging both sticks, punched pivot pin:
        // the joint explains the scissors
        Rectangle {
            x: 5.5 * cb.u; y: 24.7 * cb.u
            width: 11 * cb.u; height: 11 * cb.u; radius: 5.5 * cb.u
            color: cb.color
        }
        Rectangle {
            x: 8.8 * cb.u; y: 27.8 * cb.u
            width: 4.4 * cb.u; height: 4.4 * cb.u; radius: 2.2 * cb.u
            color: Theme.withAlpha(Theme.bg, 0.92)
        }
        Rectangle {  // impact ring at the hinge
            visible: cb.jolt
            x: 2 * cb.u; y: 21 * cb.u
            width: 18 * cb.u; height: 18 * cb.u; radius: 9 * cb.u
            color: "transparent"
            border.width: Math.max(1, 1.5 * cb.u)
            border.color: Theme.withAlpha(Theme.fg, 0.5)
        }
    }

    // MOVIES head, take two — the VHS CASSETTE. Armed, the deck takes the
    // tape with a two-step clunk, then it PLAYS: reels turn (the emptier
    // reel visibly faster — real spool physics), tape drains from the left
    // pack into the right… and when it runs out it REWINDS, fast and
    // backwards, the way every tape ever watched was sent home.
    component VhsTape: Item {
        id: vt
        property color color: "white"
        property bool running: false
        readonly property real u: width / 100
        readonly property real lw: Math.max(1.5, 4.5 * vt.u)
        layer.enabled: true
        layer.samples: 4
        layer.smooth: true
        property real t: 0.35     // tape on the right reel
        property real rev: 0      // spool revolutions
        property real drop: 0     // the insert clunk
        onRunningChanged: if (!running) { t = 0.35; rev = 0; drop = 0 }
        SequentialAnimation {
            running: vt.running
            loops: Animation.Infinite
            PropertyAction { target: vt; property: "drop"; value: -3 }
            PauseAnimation { duration: 70 }
            PropertyAction { target: vt; property: "drop"; value: 1 }
            PauseAnimation { duration: 60 }
            PropertyAction { target: vt; property: "drop"; value: 0 }
            PauseAnimation { duration: 240 }
            ParallelAnimation {  // PLAY
                NumberAnimation { target: vt; property: "t"; from: 0.08; to: 0.92; duration: 5200 }
                NumberAnimation { target: vt; property: "rev"; from: 0; to: 2.6; duration: 5200 }
            }
            PauseAnimation { duration: 340 }
            ParallelAnimation {  // out of tape — REWIND
                NumberAnimation { target: vt; property: "t"; from: 0.92; to: 0.08; duration: 820 }
                NumberAnimation { target: vt; property: "rev"; from: 2.6; to: -1.4; duration: 820 }
            }
            PauseAnimation { duration: 700 }
        }
        transform: Translate { y: vt.drop * vt.u * 1.5 }
        Rectangle {  // shell — fills the box; a cassette is a BRICK
            x: 5 * vt.u; y: 20 * vt.u; width: 90 * vt.u; height: 60 * vt.u
            radius: 4 * vt.u
            color: "transparent"; border.color: vt.color; border.width: Math.max(1.5, 5 * vt.u)
            Rectangle {  // machined sheen under the shell's top edge
                x: parent.border.width + 1; y: parent.border.width + 1
                width: parent.width - (parent.border.width + 1) * 2; height: 1
                color: Theme.withAlpha(Theme.fg, 0.3)
            }
        }
        Rectangle {  // the window — a RECESSED dark well the reels pop on
            x: 18 * vt.u; y: 28 * vt.u; width: 64 * vt.u; height: 28 * vt.u
            radius: 2 * vt.u
            color: Theme.withAlpha(Theme.bg, 0.45)
        }
        Item {  // through the glass: packs, reels, spokes — clipped
            x: 18 * vt.u; y: 28 * vt.u; width: 64 * vt.u; height: 28 * vt.u
            clip: true
            Repeater {
                model: 2
                Item {
                    readonly property bool isL: index === 0
                    readonly property real pack: 5.5 + (isL ? (1 - vt.t) : vt.t) * 8
                    x: (isL ? 15 : 49) * vt.u
                    y: 14 * vt.u
                    Rectangle {  // the wound tape pack — bold, it IS the story
                        x: -parent.pack * vt.u; y: -parent.pack * vt.u
                        width: parent.pack * 2 * vt.u; height: width
                        radius: width / 2
                        color: Theme.withAlpha(vt.color, 0.42)
                    }
                    Rectangle {  // reel — solid ring, punched hub
                        x: -4.8 * vt.u; y: -4.8 * vt.u
                        width: 9.6 * vt.u; height: 9.6 * vt.u; radius: 4.8 * vt.u
                        color: Theme.withAlpha(Theme.bg, 0.9)
                        border.width: Math.max(1, 2.2 * vt.u)
                        border.color: vt.color
                    }
                    Item {  // spokes — speed ∝ 1/pack: the emptier spool
                        // visibly spins faster, real spool physics
                        rotation: vt.rev * 360 * (9 / parent.pack)
                        Repeater {
                            model: 3
                            Rectangle {
                                x: -1 * vt.u; y: -4.8 * vt.u
                                width: 2 * vt.u; height: 9.6 * vt.u
                                rotation: index * 120
                                color: vt.color
                            }
                        }
                    }
                }
            }
        }
        Rectangle {  // label — tall enough to read as the written spine
            x: 12 * vt.u; y: 62 * vt.u; width: 76 * vt.u; height: 11 * vt.u
            color: Theme.withAlpha(vt.color, 0.32)
            Rectangle {  // the handwritten title
                x: 4 * vt.u; y: parent.height / 2 - height / 2
                width: 34 * vt.u; height: Math.max(1, 2.6 * vt.u)
                radius: height / 2
                color: Theme.withAlpha(Theme.bg, 0.8)
            }
            Rectangle {  // and the date, shorter
                x: 62 * vt.u; y: parent.height / 2 - height / 2
                width: 10 * vt.u; height: Math.max(1, 2.6 * vt.u)
                radius: height / 2
                color: Theme.withAlpha(Theme.bg, 0.8)
            }
        }
    }

    // A film reel whose DISC spins while a film TAIL pays out below it — the
    // read that makes it FILM, not just a wheel. The strand does NOT orbit
    // with the disc like a clock hand: it hangs from a fixed pay-out point
    // under the rim (which is physically right — film leaves a spinning
    // spool at the tangent, and the tangent doesn't move). Life comes from
    // two motions: the strand undulates (amplitude growing toward the free
    // tip), and punched perforation holes travel ALONG it — born at the
    // reel, gone at the tip — so film visibly RUNS in the direction the
    // disc's spin implies.
    component FilmReel: Item {
        id: fr
        property color color: "white"
        property bool running: false
        readonly property real u: width / 100
        // −1..1 slow sway of the hanging strand.
        property real sway: 0
        // 0..1 phase carrying the perforations down the strand.
        property real feed: 0
        SequentialAnimation on sway {
            running: fr.running
            loops: Animation.Infinite
            NumberAnimation { to: 1; duration: 1400; easing.type: Easing.InOutSine }
            NumberAnimation { to: -1; duration: 1400; easing.type: Easing.InOutSine }
        }
        NumberAnimation on feed {
            running: fr.running
            loops: Animation.Infinite
            from: 0; to: 1; duration: 1100
        }

        // The strand's cubic, ONE set of control points shared by the drawn
        // path and the perforation positions (100-unit field). Root pinned
        // just inside the rim's lower-left (the tangent), tip free at the
        // right; the sway coefficients grow along the strand so it whips
        // gently from a still root.
        readonly property real t0x: 34
        readonly property real t0y: 69
        readonly property real tc1x: 44
        readonly property real tc1y: 83 + sway * 2.5
        readonly property real tc2x: 74
        readonly property real tc2y: 92 - sway * 3.5
        readonly property real t3x: 94
        readonly property real t3y: 79 + sway * 5.5
        function tailPt(t) {
            const mt = 1 - t
            const a = mt * mt * mt, b = 3 * mt * mt * t
            const c = 3 * mt * t * t, d = t * t * t
            return Qt.point(a * t0x + b * tc1x + c * tc2x + d * t3x,
                            a * t0y + b * tc1y + c * tc2y + d * t3y)
        }

        // ── the DISC — rim, spokes, hub — the only part that spins ──
        Item {
            id: reelDisc
            x: 14 * fr.u; y: 2 * fr.u
            width: 72 * fr.u; height: 72 * fr.u
            // Counter-clockwise so the rim's UNDERSIDE travels toward the
            // strand — the reel hands film to the tail, not away from it.
            RotationAnimation on rotation {
                running: fr.running
                loops: Animation.Infinite
                from: 0; to: -360; duration: 4200
            }
            Rectangle {
                anchors.fill: parent; radius: width / 2
                color: "transparent"; border.color: fr.color
                border.width: Math.max(2, 7 * fr.u)
            }
            Repeater {
                model: 5
                Rectangle {
                    color: fr.color
                    width: Math.max(2, 6.5 * fr.u); height: 29 * fr.u
                    x: reelDisc.width / 2 - width / 2
                    y: 7 * fr.u
                    transformOrigin: Item.Bottom
                    rotation: index * 72
                }
            }
            Rectangle {
                anchors.centerIn: parent
                width: 17 * fr.u; height: 17 * fr.u; radius: width / 2
                color: fr.color
            }
        }

        // ── the TAIL — drawn over the rim so root and reel read as one ──
        Shape {
            anchors.fill: parent
            antialiasing: true
            ShapePath {
                strokeColor: fr.color
                strokeWidth: Math.max(2, 6.5 * fr.u)
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                startX: fr.t0x * fr.u; startY: fr.t0y * fr.u
                PathCubic {
                    control1X: fr.tc1x * fr.u; control1Y: fr.tc1y * fr.u
                    control2X: fr.tc2x * fr.u; control2Y: fr.tc2y * fr.u
                    x: fr.t3x * fr.u; y: fr.t3y * fr.u
                }
            }
        }
        // Perforations riding the strand — punched (bg-coloured) holes whose
        // opacity is sin(π·t): they fade in at the reel and out at the tip,
        // so the wrap-around never pops.
        Repeater {
            model: 3
            Rectangle {
                visible: fr.running
                readonly property real tp: (index / 3 + fr.feed) % 1
                readonly property point pt: fr.tailPt(0.10 + tp * 0.84)
                width: Math.max(1.5, 3.2 * fr.u); height: width
                radius: width / 2
                x: pt.x * fr.u - width / 2
                y: pt.y * fr.u - height / 2
                color: Theme.withAlpha(Theme.bg, 0.85)
                opacity: Math.sin(Math.PI * tp)
            }
        }
    }

    // MOVIES foot — a vertical strip of film FEEDING DOWN through the frame.
    // The two sprocket rails hold still (they're the strip's body); what moves
    // is what physically moves in a projector gate: the frame bars and the
    // punched perforations, scrolling together and wrapping every frame-pitch
    // (39u = 3 hole-pitches, so the loop is seamless). Root clips at the
    // strip's top/bottom edge — film is born at one edge, dies at the other.
    component FilmStrip: Item {
        id: fs
        property color color: "white"
        property bool running: false
        readonly property real u: width / 100
        // NATIVE HORIZONTAL: film travels LEFT through the gate — one
        // frame-pitch per pull. Not a smooth scroll: the claw GRIPS, YANKS
        // the film a frame, the registration pin stops it with a hair of
        // overshoot, and it dwells in the gate — the intermittent pull-down
        // that IS projection. feed 1 ≡ 0 in the pattern; cyc rotates the
        // exposures (+1 for leftward travel) so the reset is invisible.
        property real feed: 0
        property int cyc: 0
        onRunningChanged: {
            if (!running) feed = 0
            else if (stills.length === 0) pickStills()
        }
        // the PRINT — five real posters from the library, one per exposure:
        // the strip literally carries the user's movies. Exposure content
        // must depend only on (index+cyc)%5 for the pull reset to stay
        // invisible, hence exactly five stills. The reel is FROZEN while
        // projecting — the spotlight reshuffle must never swap a print
        // mid-projection — and re-threaded between showings. Empty library
        // → the graded washes below carry the frame alone.
        property var stills: []
        function pickStills() {
            const out = []
            for (let i = 0; i < home.spot.length && out.length < 5; ++i) {
                const e = home.spot[i]
                if (e.kind === "movie" && e.poster) out.push(Theme.art(e.poster))
            }
            stills = out
        }
        Component.onCompleted: pickStills()
        Connections {
            target: home
            function onSpotChanged() { if (!fs.running) fs.pickStills() }
        }
        SequentialAnimation on feed {
            running: fs.running
            loops: Animation.Infinite
            NumberAnimation { to: -0.02; duration: 50; easing.type: Easing.OutQuad }
            NumberAnimation { to: 1.04; duration: 130; easing.type: Easing.InCubic }
            NumberAnimation { to: 1; duration: 70; easing.type: Easing.OutQuad }
            ScriptAction { script: { fs.feed = 0; fs.cyc = (fs.cyc + 1) % 5 } }
            PauseAnimation { duration: 610 }
            NumberAnimation { to: -0.02; duration: 50; easing.type: Easing.OutQuad }
            NumberAnimation { to: 1.04; duration: 135; easing.type: Easing.InCubic }
            NumberAnimation { to: 1; duration: 70; easing.type: Easing.OutQuad }
            ScriptAction { script: { fs.feed = 0; fs.cyc = (fs.cyc + 1) % 5 } }
            PauseAnimation { duration: 390 }
        }
        clip: true
        // the rails — the TOP one carries the soundtrack side: real film
        // is asymmetric
        Rectangle { color: fs.color; y: 9 * fs.u; height: 18 * fs.u; width: fs.width }
        Rectangle { color: fs.color; y: 73 * fs.u; height: 18 * fs.u; width: fs.width }
        Rectangle { color: Theme.withAlpha(Theme.bg, 0.35); y: 26.2 * fs.u; height: 1; width: fs.width }
        Rectangle { color: Theme.withAlpha(Theme.bg, 0.35); y: 73.6 * fs.u; height: 1; width: fs.width }
        // gate shadows — ENTRY at the right, EXIT at the left, pressing
        // while the film moves
        Rectangle {  // exit gate — two-step falloff, not a hard wall
            z: 2; x: 0; y: 9 * fs.u; width: 4 * fs.u; height: 82 * fs.u
            color: Theme.withAlpha(Theme.bg, fs.feed > 0.05 && fs.feed < 0.98 ? 0.7 : 0.55)
        }
        Rectangle {
            z: 2; x: 4 * fs.u; y: 9 * fs.u; width: 2 * fs.u; height: 82 * fs.u
            color: Theme.withAlpha(Theme.bg, fs.feed > 0.05 && fs.feed < 0.98 ? 0.35 : 0.28)
        }
        Rectangle {  // entry gate
            z: 2; x: fs.width - width; y: 9 * fs.u; width: 3 * fs.u; height: 82 * fs.u
            color: Theme.withAlpha(Theme.bg, fs.feed > 0.05 && fs.feed < 0.98 ? 0.7 : 0.55)
        }
        Rectangle {
            z: 2; x: fs.width - 5 * fs.u; y: 9 * fs.u; width: 2 * fs.u; height: 82 * fs.u
            color: Theme.withAlpha(Theme.bg, fs.feed > 0.05 && fs.feed < 0.98 ? 0.35 : 0.28)
        }
        Repeater {  // aperture-plate brackets, horizontal arms — LIVE with
            // the shutter: dim during the pull, bright while projecting
            model: [[42.5, 29.5], [67.5, 29.5], [42.5, 72], [67.5, 72]]
            Rectangle {
                z: 2; color: fs.color
                opacity: fs.feed > 0.05 && fs.feed < 0.98 ? 0.28 : 0.5
                x: modelData[0] * fs.u; y: modelData[1] * fs.u
                width: 6 * fs.u; height: Math.max(1, 1.5 * fs.u)
            }
        }
        Repeater {  // vertical arms — four Ls framing the gate cell
            model: [[42.5, 29.5], [74, 29.5], [42.5, 67.5], [74, 67.5]]
            Rectangle {
                z: 2; color: fs.color
                opacity: fs.feed > 0.05 && fs.feed < 0.98 ? 0.28 : 0.5
                x: modelData[0] * fs.u; y: modelData[1] * fs.u
                width: Math.max(1, 1.5 * fs.u); height: 6 * fs.u
            }
        }
        Item {
            id: fsRoll
            property real weave: 0
            SequentialAnimation on weave {
                running: fs.running
                loops: Animation.Infinite
                NumberAnimation { to: 1; duration: 2100; easing.type: Easing.InOutSine }
                NumberAnimation { to: -1; duration: 2300; easing.type: Easing.InOutSine }
            }
            // weave breathes ACROSS the travel (vertically); feed pulls LEFT
            y: weave * 0.4 * fs.u
            x: -fs.feed * 39 * fs.u
            // frame separators spanning the PICTURE area only — the frame
            // line never crosses the soundtrack
            Repeater {
                model: 5
                Rectangle {
                    color: fs.color
                    y: 30.3 * fs.u; height: 44.2 * fs.u
                    x: (-41.5 + index * 39) * fs.u; width: 6 * fs.u
                    Rectangle {  // the SPLICE — one repaired joint in the reel
                        visible: (index + fs.cyc) % 5 === 3
                        x: parent.width / 2 - width / 2; y: parent.height * 0.15
                        width: Math.max(1, 1.2 * fs.u); height: parent.height * 0.7
                        rotation: 1.5
                        color: Theme.withAlpha(Theme.bg, 0.5)
                    }
                }
            }
            // the OPTICAL SOUNDTRACK — variable-density twin channels
            // printed along the top edge, riding the roll
            Repeater {
                model: 48
                Rectangle {
                    color: Theme.withAlpha(fs.color, fs.running ? 0.58 : 0.45)
                    y: (index % 2 === 0 ? 27.2 : 28.9) * fs.u
                    height: [1.1, 1.5, 1.3, 1.6, 1.2, 1.4][Math.floor(index / 2) % 6] * fs.u
                    x: (-40 + Math.floor(index / 2) * 6.5) * fs.u
                    width: 2.2 * fs.u
                }
            }
            // the FRAMES carry pictures — each pull brings a genuinely new
            // photograph to the gate
            Repeater {
                model: 5
                Rectangle {
                    // the projector LAMP: brightens the gate, shutters
                    // during the pull, flutters with the weave
                    color: Theme.withAlpha(fs.color, [0.24, 0.10, 0.30, 0.15, 0.20][(index + fs.cyc) % 5] * (fs.running ? (fs.feed > 0.05 && fs.feed < 0.98 ? 0.95 : (Math.abs(fsRoll.weave) > 0.5 ? 1.2 : 1.16)) : 1))
                    x: (-33 + index * 39) * fs.u; width: 28 * fs.u
                    y: 32 * fs.u; height: 39 * fs.u
                    Rectangle {  // the exposure's SKY — true UP now: a
                        // lighter band that turns a wash into a photograph
                        x: 0; y: 0; width: parent.width; height: parent.height * 0.38
                        color: Theme.withAlpha(fs.color, 0.09)
                    }
                    Image {  // the exposure itself — a REAL print. The lamp
                        // owns its life: muted ghost at rest, full colour
                        // under the open shutter, dimmed while the claw
                        // pulls (the shutter's job); the wash flutters
                        // through from beneath as lamp flicker
                        anchors.fill: parent
                        source: fs.stills[(index + fs.cyc) % 5] || ""
                        visible: status === Image.Ready
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        sourceSize: Qt.size(64, 96)
                        // the GATE frame (position 2 at rest) is the one
                        // being projected — neighbours ride darker; the
                        // handoff jump hides inside the pull's shutter dim
                        opacity: fs.running
                                 ? (fs.feed > 0.05 && fs.feed < 0.98 ? 0.5 : (index === 2 ? 0.95 : 0.62))
                                 : 0.26
                    }
                    Rectangle {  // HALATION — the hottest exposure blooms
                        // past its frame while the shutter is open
                        visible: fs.running && (index + fs.cyc) % 5 === 2 && !(fs.feed > 0.05 && fs.feed < 0.98)
                        x: -2.5 * fs.u; y: -2.5 * fs.u
                        width: parent.width + 5 * fs.u; height: parent.height + 5 * fs.u
                        color: Theme.withAlpha(fs.color, 0.05)
                    }
                    Rectangle {  // the projectionist's CUE DOTS — changeover
                        // marks in the frame's upper-right, two frames running
                        visible: (index + fs.cyc) % 5 === 2 || (index + fs.cyc) % 5 === 3
                        color: Theme.withAlpha(Theme.bg, 0.9)
                        width: 3.6 * fs.u; height: 3.6 * fs.u; radius: width / 2
                        x: parent.width - 5.8 * fs.u; y: 2.2 * fs.u
                    }
                    Rectangle {  // a dust speck — jumps spots on every pull
                        visible: fs.running && (index + fs.cyc) % 5 === 1
                        color: Theme.withAlpha(Theme.bg, 0.55)
                        width: 1.6 * fs.u; height: 1.6 * fs.u; radius: width / 2
                        x: (5 + ((index * 13 + fs.cyc * 5) % 18)) * fs.u
                        y: (8 + ((index * 7 + fs.cyc * 11) % 23)) * fs.u
                    }
                    Rectangle {  // a print scratch — runs WITH the travel,
                        // one worn frame in five
                        visible: fs.running && (index + fs.cyc) % 5 === 4
                        color: Theme.withAlpha(Theme.bg, 0.35)
                        x: 0; width: parent.width
                        height: Math.max(1, 0.8 * fs.u)
                        y: (12 + fs.cyc * 6) * fs.u
                    }
                }
            }
            // perforations — two rows at true 35mm FOUR-PERF pitch, the
            // sprocket rhythm; they SMEAR along the travel during the yank
            Repeater {
                model: 38
                Rectangle {
                    color: Theme.withAlpha(Theme.bg, fs.running ? 0.78 : 0.85)
                    width: (fs.feed > 0.08 && fs.feed < 0.92 ? 9.5 : 7) * fs.u
                    height: 7 * fs.u
                    radius: 1.2 * fs.u
                    y: (index % 2 === 0 ? 14.5 : 78.5) * fs.u
                    x: (-40 + Math.floor(index / 2) * 9.75) * fs.u
                }
            }
            // edge codes — fine stock marks along the top rail's inner
            // face, one per half-frame, riding the roll
            Repeater {
                model: 10
                Rectangle {
                    color: Theme.withAlpha(Theme.bg, fs.running ? 0.5 : 0.45)
                    width: 1.8 * fs.u; height: 2 * fs.u
                    y: 24 * fs.u
                    x: (-36 + index * 19.5) * fs.u
                }
            }
        }
    }

    // TV glyph — the REFERENCE steampunk-goggles with the LOCKED gleam
    // system. Architecture (settled after much iteration — do not churn):
    //  · the icon's printed highlight crescents rest pixel-exact; on each
    //    phrase the front/rear marks TRAVEL up-left on a bowed path,
    //    stretching mid-flight and compressing into the exit rim, with a
    //    lift-off afterimage, a 45% companion streak, and a bright CHARGE
    //    core while the flood passes over them
    //  · the FLOOD: an analytic elliptical-segment fill sweeps each lens
    //    along the same travel line — enters lower-right, fully lights the
    //    glass at mid-phrase, drains upper-left — with a crisp chord line
    //    riding its boundary (the light-front's edge)
    //  · punctuation: 4-point anime stars with two-frame shrink at the
    //    exit rim; a flash-only BLINK phrase closes the loop so the seam
    //    never stacks two dual-sweeps
    //  · five phrases (equip double, lone pass, rapid flick, sun-catch,
    //    blink), all state reset on deselect; motion is SMOOTH by choice —
    //    cel-stepping was tried and read as stutter at this scale.
    component SteampunkGoggles: Item {
        id: sg
        property color color: "white"
        property bool running: false
        // IconShape's normalisation for bbox [14.9, 120.4, 481.7, 273.7] —
        // at 1.02 rather than 0.94: the goggles are a wide, shallow icon and
        // read undersized next to the square glyphs at the standard fill
        readonly property real k: width * 1.02 / 481.7
        readonly property real kx: width / 2 - k * 255.75
        readonly property real ky: height / 2 - k * 257.25
        property real fsw: 0
        property real bsw: 0
        // the ANIME reflection: the icon's own highlight GROWS and travels
        // up-and-left across the glass — swelling as it goes — and bursts
        // out at the upper rim (where the sparkle star pings). Rest pose is
        // exactly the reference: offset 0, scale 1.
        readonly property real fp: Math.min(1, fsw)
        readonly property real bp: Math.min(1, bsw)
        // SMOOTH travel (the cel-stepping read as stutter here), and the
        // FLOOD: a light-front crosses each lens along the same up-left
        // line — the lit region is an elliptical segment cut by a moving
        // chord, so the fill's edge is always a clean straight front.
        readonly property real fq: fp
        readonly property real bq: bp
        readonly property real fqc: Math.max(0, fp - 0.14)
        readonly property real bqc: Math.max(0, bp - 0.14)
        // front lens: travel direction angle -139.5°; rear: -128°
        readonly property real fgA: Math.acos(Math.max(-1, Math.min(1, -1 + 4 * fp))) * 57.2958
        readonly property real fdA: Math.acos(Math.max(-1, Math.min(1, -1 + 4 * (fp - 0.5)))) * 57.2958
        readonly property real bgA: Math.acos(Math.max(-1, Math.min(1, -1 + 4 * bp))) * 57.2958
        readonly property real bdA: Math.acos(Math.max(-1, Math.min(1, -1 + 4 * (bp - 0.5)))) * 57.2958
        // the moving chord's endpoints (front lens α=-2.4347, rear α=-2.234)
        readonly property real fA: (fp < 0.5 ? fgA : fdA) / 57.2958
        readonly property real flx1: 287.5 + 30 * Math.cos(-2.4347 + fA)
        readonly property real fly1: 303 + 64 * Math.sin(-2.4347 + fA)
        readonly property real flx2: 287.5 + 30 * Math.cos(-2.4347 - fA)
        readonly property real fly2: 303 + 64 * Math.sin(-2.4347 - fA)
        readonly property real bA: (bp < 0.5 ? bgA : bdA) / 57.2958
        readonly property real blx1: 443 + 27 * Math.cos(-2.234 + bA)
        readonly property real bly1: 244 + 60 * Math.sin(-2.234 + bA)
        readonly property real blx2: 443 + 27 * Math.cos(-2.234 - bA)
        readonly property real bly2: 244 + 60 * Math.sin(-2.234 - bA)
        readonly property real fsx: 1 + 0.12 * fq
        // stretch peaks mid-travel, compresses meeting the exit rim
        readonly property real fsy: 1 + 0.5 * fq - Math.max(0, fq - 0.7) * 0.9
        readonly property real bsx: 1 + 0.1 * bq
        readonly property real bsy: 1 + 0.42 * bq - Math.max(0, bq - 0.7) * 0.7
        readonly property real fdx: -30 * fq
        // the path BOWS — reflections cross curved glass on a curve
        readonly property real fdy: -55 * fq - 8 * Math.sin(Math.PI * fq)
        readonly property real bdx: -16 * bq
        readonly property real bdy: -45 * bq - 6 * Math.sin(Math.PI * bq)
        // the full-glass CATCH: both lenses flash their whole face — used
        // by the blink phrase, and each band lights its own glass mid-cross
        property real gflash: 0
        onRunningChanged: if (!running) { fsw = 0; bsw = 0; gflash = 0 }
        // Cel-animation glints in three unequal phrases. The loop LEADS with
        // the full double sweep — so arming the slot gets an immediate
        // equip flash — then rests, single catch, rests, a rapid double-
        // flick, long rest. Rear lens runs a touch faster than the front
        // (different glass, different optics). Fast LINEAR wipes — no eased
        // drift, no fade. Flick, hold, flick.
        SequentialAnimation {
            running: sg.running
            loops: Animation.Infinite
            PauseAnimation { duration: 40 }
            ParallelAnimation {  // equip shimmer — both lenses, rear a beat behind
                SequentialAnimation {
                    NumberAnimation { target: sg; property: "fsw"; from: 0; to: 1; duration: 380; easing.type: Easing.InQuad }
                    PauseAnimation { duration: 70 }
                    PropertyAction { target: sg; property: "fsw"; value: 0 }
                }
                SequentialAnimation {
                    PauseAnimation { duration: 150 }
                    NumberAnimation { target: sg; property: "bsw"; from: 0; to: 1; duration: 360; easing.type: Easing.InQuad }
                    PauseAnimation { duration: 70 }
                    PropertyAction { target: sg; property: "bsw"; value: 0 }
                }
            }
            PauseAnimation { duration: 2500 }
            NumberAnimation { target: sg; property: "fsw"; from: 0; to: 1; duration: 420; easing.type: Easing.InQuad }
            PauseAnimation { duration: 60 }
            PropertyAction { target: sg; property: "fsw"; value: 0 }
            PauseAnimation { duration: 2100 }
            NumberAnimation { target: sg; property: "fsw"; from: 0; to: 1; duration: 260; easing.type: Easing.InQuad }
            PropertyAction { target: sg; property: "fsw"; value: 0 }
            NumberAnimation { target: sg; property: "bsw"; from: 0; to: 1; duration: 290; easing.type: Easing.InQuad }
            PropertyAction { target: sg; property: "bsw"; value: 0 }
            PauseAnimation { duration: 1400 }
            ParallelAnimation {  // the sun-catch: both lenses at ONCE
                SequentialAnimation {
                    NumberAnimation { target: sg; property: "fsw"; from: 0; to: 1; duration: 340; easing.type: Easing.InQuad }
                    PauseAnimation { duration: 60 }
                    PropertyAction { target: sg; property: "fsw"; value: 0 }
                }
                SequentialAnimation {
                    NumberAnimation { target: sg; property: "bsw"; from: 0; to: 1; duration: 340; easing.type: Easing.InQuad }
                    PauseAnimation { duration: 60 }
                    PropertyAction { target: sg; property: "bsw"; value: 0 }
                }
            }
            PauseAnimation { duration: 1900 }
            // the BLINK closes the loop — a flash-only beat, so the seam
            // back into the equip sweep never stacks two dual-sweeps
            PropertyAction { target: sg; property: "gflash"; value: 1 }
            PauseAnimation { duration: 80 }
            PropertyAction { target: sg; property: "gflash"; value: 0 }
            PauseAnimation { duration: 2700 }
        }
        Shape {  // the goggles minus their two reflections — static.
            // Multisampled: the lens rings are the roundest curves on the
            // deck and deserve the wrench's treatment.
            width: 512; height: 512
            antialiasing: true
            layer.enabled: true
            layer.samples: 4
            layer.smooth: true
            transform: Matrix4x4 { matrix: Qt.matrix4x4(sg.k, 0, 0, sg.kx, 0, sg.k, 0, sg.ky, 0, 0, 1, 0, 0, 0, 0, 1) }
            ShapePath {
                fillColor: sg.color; strokeWidth: 0
                fillRule: ShapePath.OddEvenFill
                PathSvg { path: "M175.3 120.4c-39.044-.035-81.332 6.312-136.06 17.752 2.786 11.553 6.997 23.69 11.796 35.318 109.813-26.153 176.85-16.624 239.863 9.426 4.03-13.23 10.572-25.413 18.648-35.72-49.595-18.4-89.864-26.737-134.246-26.776z M362.2 134.5c-6.61-.015-12.398.99-16.982 3.376-.79.68-1.384 1.442-1.734 2.2 18.56 4.702 36.184 9.745 51.613 15.628 5.153-4.313 10.78-8.04 16.833-11.027-17.658-5.47-35.56-10.142-49.732-10.175z M20.8 139.6c-.89 19.648-5.877 24.76-1.288 59.096 3.89 29.1 15.095 72.413 61.754 109.08-3.517-14.455-5.16-28.265-4.587-43.724-12.806-14.01-25.166-33.834-43.268-85.906-5.63-13.404-8.834-26.383-12.612-38.547z M440.3 154.4c-14.962.188-29.31 7.998-40.727 19.942-13.532 14.156-23.72 34.396-28.234 57.824-4.516 23.427-2.557 45.88 4.785 63.843 5.976 14.622 15.925 26.615 29.078 32.332h.002c4.374 1.97 7.517 3.288 12 3.265 17.044 2.097 33.69-6.112 46.593-19.61 13.533-14.158 23.717-34.396 28.233-57.824 4.515-23.426 2.56-45.88-4.78-63.842-7.343-17.963-20.684-31.962-38.59-35.227a43.482 43.482 0 0 0-8.36-.702z M327.2 154.6c-10.18 11.86-18.49 27.615-21.48 44.08 23.602 11.794 41.428 32.958 47.72 54.432.148-8.285.985-16.61 2.5-24.8 3.964-21.45 12.488-42.035 25.476-58.436-15.95-5.543-34.613-10.52-54.215-15.277z M441.3 172.4a25.86 25.86 0 0 1 3.993.41c10.53 1.92 19.517 10.35 25.285 24.46 5.768 14.112 7.704 33.376 3.786 53.706-3.918 20.33-12.897 37.605-23.527 48.726-10.632 11.12-22.15 15.812-32.68 13.892-10.53-1.92-19.517-10.352-25.284-24.463-5.768-14.11-7.702-33.373-3.783-53.703 3.918-20.33 12.894-37.604 23.525-48.725 9.302-9.73 19.28-14.54 28.685-14.302z M186.7 194.7c-12.71.12-23.37 1.835-31.446 5.224-27.724 11.638-46.134 28.764-55.694 47.918 33.88 11.845 50.606 20.93 105.842 23.778 9.12-26.446 27.087-50.78 55.36-65.742-28.42-7.515-53.842-11.37-74.063-11.177z M288.3 214.0l-.066.022c-15.41-.246-30.24 7.657-41.977 19.933-13.532 14.157-23.72 34.395-28.234 57.823-4.515 23.428-2.557 45.882 4.785 63.844 2.92 7.144 6.79 13.658 11.517 19.12 5.406 6.65 11.756 11.463 18.757 14.042 2.697.853 5.81 1.6 8.315 2.065 17.906 3.266 35.553-5.08 49.085-19.237 13.532-14.157 23.717-34.397 28.232-57.825.216-1.492.55-2.617.717-4.068 3.55-21.95 1.418-42.855-5.498-59.775-5.793-14.175-15.324-25.876-27.885-31.788-.753-.37-1.52-.728-2.305-1.068v.062a43.235 43.235 0 0 0-8.4-2.434 43.435 43.435 0 0 0-6.975-.693 8.534 8.534 0 0 1-.067-.022z M287.9 232.0a25.85 25.85 0 0 1 3.992.41c10.53 1.92 19.518 10.353 25.285 24.464 5.768 14.11 7.703 33.373 3.785 53.703-3.918 20.33-12.896 37.604-23.527 48.724-10.63 11.12-22.147 15.813-32.678 13.893-10.53-1.92-19.517-10.35-25.285-24.46-5.767-14.112-7.7-33.376-3.783-53.706 3.918-20.33 12.895-37.603 23.525-48.724 9.302-9.73 19.282-14.54 28.686-14.304z M94.4 265.1c-.603 14.054.94 26.203 4.392 39.542l.516-.246c24.38 16.45 71.385 32.672 100.367 32.224-1.63-10.355-2.06-21.19-1.193-32.12a134.61 134.61 0 0 1 2.087-15.135c-53.818-3.222-74.207-13.057-106.168-24.264z M358.7 293.2c-.09 9.523-1.072 18.374-2.595 25.904a179.038 179.038 0 0 0 19.27 6.586c-6.608-8.252-11.652-17.756-15.186-27.88-.53-1.522-1.022-3.06-1.488-4.61z M112.5 333.5c4.936 5.788 10.722 11.266 17.384 16.3 29.055 21.964 58.6 30.283 89.398 34.95-4.006-5.177-7.465-10.95-10.33-17.138-1.89-4.08-3.525-8.36-4.93-12.783-32.872-.606-63.45-8.824-91.523-21.33z" }
            }
        }
        Shape {  // FRONT GLASS CATCH — the whole lens face takes light as
            // the band crosses its middle, and on the blink phrase
            width: 512; height: 512
            antialiasing: true
            visible: sg.gflash > 0.5
            transform: Matrix4x4 { matrix: Qt.matrix4x4(sg.k, 0, 0, sg.kx, 0, sg.k, 0, sg.ky, 0, 0, 1, 0, 0, 0, 0, 1) }
            ShapePath {
                fillColor: Theme.withAlpha(Theme.fg, 0.13); strokeWidth: 0
                PathAngleArc {
                    centerX: 287.5; centerY: 303
                    radiusX: 30; radiusY: 64
                    startAngle: 0; sweepAngle: 360
                }
            }
        }
        Shape {  // REAR GLASS CATCH — its own clock, a beat apart
            width: 512; height: 512
            antialiasing: true
            visible: sg.gflash > 0.5
            transform: Matrix4x4 { matrix: Qt.matrix4x4(sg.k, 0, 0, sg.kx, 0, sg.k, 0, sg.ky, 0, 0, 1, 0, 0, 0, 0, 1) }
            ShapePath {
                fillColor: Theme.withAlpha(Theme.fg, 0.09); strokeWidth: 0
                PathAngleArc {
                    centerX: 443; centerY: 244
                    radiusX: 24; radiusY: 52
                    startAngle: 0; sweepAngle: 360
                }
            }
        }
        Shape {  // front highlight — grows and rides up-left across the
            // glass, vanishing into the rim (the star fires there)
            width: 512; height: 512
            antialiasing: true
            opacity: sg.fp < 0.85 ? 1 : 0
            transform: Matrix4x4 { matrix: Qt.matrix4x4(
                sg.k * sg.fsx, 0, 0, sg.kx + sg.k * (sg.fdx + 286.5 * (1 - sg.fsx)),
                0, sg.k * sg.fsy, 0, sg.ky + sg.k * (sg.fdy + 312 * (1 - sg.fsy)),
                0, 0, 1, 0, 0, 0, 0, 1) }
            ShapePath {
                fillColor: sg.color; strokeWidth: 0
                PathSvg { path: "M309.4 264.5c-10.736 55.26-26.58 72.102-46.18 94.99 17.268 1.76 33.787-9.263 41.438-38.275 4.17-15.812 5.537-19.187 4.74-56.715z" }
            }
        }
        Shape {  // rear highlight — same climb, gentler travel (the far
            // lens is foreshortened), its own clock
            width: 512; height: 512
            antialiasing: true
            opacity: sg.bp < 0.85 ? 1 : 0
            transform: Matrix4x4 { matrix: Qt.matrix4x4(
                sg.k * sg.bsx, 0, 0, sg.kx + sg.k * (sg.bdx + 435.5 * (1 - sg.bsx)),
                0, sg.k * sg.bsy, 0, sg.ky + sg.k * (sg.bdy + 248 * (1 - sg.bsy)),
                0, 0, 1, 0, 0, 0, 0, 1) }
            ShapePath {
                fillColor: sg.color; strokeWidth: 0
                PathSvg { path: "M458.9 201.1c-10.734 55.258-26.578 72.102-46.178 94.99 17.267 1.758 33.788-9.264 41.44-38.276 4.17-15.812 5.536-19.187 4.74-56.715z" }
            }
        }
        Shape {  // FRONT FLOOD, entering — the lit segment grows from the
            // lower-right rim until the whole glass is light
            width: 512; height: 512
            antialiasing: true
            visible: sg.fp > 0.03 && sg.fp < 0.5
            transform: Matrix4x4 { matrix: Qt.matrix4x4(sg.k, 0, 0, sg.kx, 0, sg.k, 0, sg.ky, 0, 0, 1, 0, 0, 0, 0, 1) }
            ShapePath {
                fillColor: Theme.withAlpha(Theme.fg, 0.1); strokeWidth: 0
                PathAngleArc {
                    centerX: 287.5; centerY: 303
                    radiusX: 30; radiusY: 64
                    startAngle: -139.5 + sg.fgA
                    sweepAngle: 360 - 2 * sg.fgA
                }
            }
        }
        Shape {  // FRONT FLOOD, leaving — drains toward the upper-left rim
            width: 512; height: 512
            antialiasing: true
            visible: sg.fp >= 0.5 && sg.fp < 0.97
            transform: Matrix4x4 { matrix: Qt.matrix4x4(sg.k, 0, 0, sg.kx, 0, sg.k, 0, sg.ky, 0, 0, 1, 0, 0, 0, 0, 1) }
            ShapePath {
                fillColor: Theme.withAlpha(Theme.fg, 0.1); strokeWidth: 0
                PathAngleArc {
                    centerX: 287.5; centerY: 303
                    radiusX: 30; radiusY: 64
                    startAngle: -139.5 - sg.fdA
                    sweepAngle: 2 * sg.fdA
                }
            }
        }
        Shape {  // REAR FLOOD, entering
            width: 512; height: 512
            antialiasing: true
            visible: sg.bp > 0.03 && sg.bp < 0.5
            transform: Matrix4x4 { matrix: Qt.matrix4x4(sg.k, 0, 0, sg.kx, 0, sg.k, 0, sg.ky, 0, 0, 1, 0, 0, 0, 0, 1) }
            ShapePath {
                fillColor: Theme.withAlpha(Theme.fg, 0.09); strokeWidth: 0
                PathAngleArc {
                    centerX: 443; centerY: 244
                    radiusX: 27; radiusY: 60
                    startAngle: -128 + sg.bgA
                    sweepAngle: 360 - 2 * sg.bgA
                }
            }
        }
        Shape {  // REAR FLOOD, leaving
            width: 512; height: 512
            antialiasing: true
            visible: sg.bp >= 0.5 && sg.bp < 0.97
            transform: Matrix4x4 { matrix: Qt.matrix4x4(sg.k, 0, 0, sg.kx, 0, sg.k, 0, sg.ky, 0, 0, 1, 0, 0, 0, 0, 1) }
            ShapePath {
                fillColor: Theme.withAlpha(Theme.fg, 0.11); strokeWidth: 0
                PathAngleArc {
                    centerX: 443; centerY: 244
                    radiusX: 27; radiusY: 60
                    startAngle: -128 - sg.bdA
                    sweepAngle: 2 * sg.bdA
                }
            }
        }
        Shape {  // front LIGHT-FRONT edge — the crisp line where the
            // flood's boundary crosses the glass
            width: 512; height: 512
            antialiasing: true
            visible: sg.fp > 0.06 && sg.fp < 0.94
            transform: Matrix4x4 { matrix: Qt.matrix4x4(sg.k, 0, 0, sg.kx, 0, sg.k, 0, sg.ky, 0, 0, 1, 0, 0, 0, 0, 1) }
            ShapePath {
                strokeColor: Theme.withAlpha(Theme.fg, 0.35); fillColor: "transparent"
                strokeWidth: 4
                capStyle: ShapePath.RoundCap
                startX: sg.flx1; startY: sg.fly1
                PathLine { x: sg.flx2; y: sg.fly2 }
            }
        }
        Shape {  // rear light-front edge
            width: 512; height: 512
            antialiasing: true
            visible: sg.bp > 0.06 && sg.bp < 0.94
            transform: Matrix4x4 { matrix: Qt.matrix4x4(sg.k, 0, 0, sg.kx, 0, sg.k, 0, sg.ky, 0, 0, 1, 0, 0, 0, 0, 1) }
            ShapePath {
                strokeColor: Theme.withAlpha(Theme.fg, 0.3); fillColor: "transparent"
                strokeWidth: 3.5
                capStyle: ShapePath.RoundCap
                startX: sg.blx1; startY: sg.bly1
                PathLine { x: sg.blx2; y: sg.bly2 }
            }
        }
        Shape {  // CHARGE — while the flood passes over the streak, its
            // core burns brighter: the reflection lit by the light itself
            width: 512; height: 512
            antialiasing: true
            visible: sg.fp > 0.3 && sg.fp < 0.7
            opacity: 0.5
            transform: Matrix4x4 { matrix: Qt.matrix4x4(
                sg.k * sg.fsx, 0, 0, sg.kx + sg.k * (sg.fdx + 286.5 * (1 - sg.fsx)),
                0, sg.k * sg.fsy, 0, sg.ky + sg.k * (sg.fdy + 312 * (1 - sg.fsy)),
                0, 0, 1, 0, 0, 0, 0, 1) }
            ShapePath {
                fillColor: Theme.withAlpha(Theme.fg, 0.5); strokeWidth: 0
                PathSvg { path: "M309.4 264.5c-10.736 55.26-26.58 72.102-46.18 94.99 17.268 1.76 33.787-9.263 41.438-38.275 4.17-15.812 5.537-19.187 4.74-56.715z" }
            }
        }
        Shape {  // rear charge
            width: 512; height: 512
            antialiasing: true
            visible: sg.bp > 0.3 && sg.bp < 0.7
            opacity: 0.45
            transform: Matrix4x4 { matrix: Qt.matrix4x4(
                sg.k * sg.bsx, 0, 0, sg.kx + sg.k * (sg.bdx + 435.5 * (1 - sg.bsx)),
                0, sg.k * sg.bsy, 0, sg.ky + sg.k * (sg.bdy + 248 * (1 - sg.bsy)),
                0, 0, 1, 0, 0, 0, 0, 1) }
            ShapePath {
                fillColor: Theme.withAlpha(Theme.fg, 0.5); strokeWidth: 0
                PathSvg { path: "M458.9 201.1c-10.734 55.258-26.578 72.102-46.178 94.99 17.267 1.758 33.788-9.264 41.44-38.276 4.17-15.812 5.536-19.187 4.74-56.715z" }
            }
        }
        Shape {  // lift-off AFTERIMAGE — the mark's imprint holds at home
            // for two cels as the streak departs, then cuts
            width: 512; height: 512
            antialiasing: true
            visible: sg.fp > 0.05 && sg.fp < 0.16
            opacity: 0.3
            transform: Matrix4x4 { matrix: Qt.matrix4x4(sg.k, 0, 0, sg.kx, 0, sg.k, 0, sg.ky, 0, 0, 1, 0, 0, 0, 0, 1) }
            ShapePath {
                fillColor: sg.color; strokeWidth: 0
                PathSvg { path: "M309.4 264.5c-10.736 55.26-26.58 72.102-46.18 94.99 17.268 1.76 33.787-9.263 41.438-38.275 4.17-15.812 5.537-19.187 4.74-56.715z" }
            }
        }
        Shape {  // COMPANION streak — the little brother chasing the main
            // reflection at 45% size, a classic two-streak anime gleam
            width: 512; height: 512
            antialiasing: true
            visible: sg.fp > 0.14 && sg.fp < 0.75
            opacity: 0.5
            transform: Matrix4x4 { matrix: Qt.matrix4x4(
                sg.k * 0.45, 0, 0, sg.kx + sg.k * (sg.fqc * -22 + 8 + 286.5 * 0.55),
                0, sg.k * 0.45, 0, sg.ky + sg.k * (sg.fqc * -41 + 14 + 312 * 0.55),
                0, 0, 1, 0, 0, 0, 0, 1) }
            ShapePath {
                fillColor: sg.color; strokeWidth: 0
                PathSvg { path: "M309.4 264.5c-10.736 55.26-26.58 72.102-46.18 94.99 17.268 1.76 33.787-9.263 41.438-38.275 4.17-15.812 5.537-19.187 4.74-56.715z" }
            }
        }
        Shape {  // rear companion — smaller still
            width: 512; height: 512
            antialiasing: true
            visible: sg.bp > 0.14 && sg.bp < 0.75
            opacity: 0.45
            transform: Matrix4x4 { matrix: Qt.matrix4x4(
                sg.k * 0.42, 0, 0, sg.kx + sg.k * (sg.bqc * -12 + 6 + 435.5 * 0.58),
                0, sg.k * 0.42, 0, sg.ky + sg.k * (sg.bqc * -34 + 11 + 248 * 0.58),
                0, 0, 1, 0, 0, 0, 0, 1) }
            ShapePath {
                fillColor: sg.color; strokeWidth: 0
                PathSvg { path: "M458.9 201.1c-10.734 55.258-26.578 72.102-46.178 94.99 17.267 1.758 33.788-9.264 41.44-38.276 4.17-15.812 5.536-19.187 4.74-56.715z" }
            }
        }
        Item {  // front sparkle — a true 4-point anime star: long cross,
            // short diagonals, and a two-frame SHRINK before it vanishes
            visible: sg.fsw > 0.86 && sg.fsw < 0.99
            x: sg.k * 243.5 + sg.kx; y: sg.k * 238 + sg.ky
            scale: sg.fsw < 0.93 ? 1 : 0.6
            Rectangle { x: -width / 2; y: -height / 2; width: sg.k * 30; height: Math.max(1, sg.k * 5); radius: height / 2; color: sg.color }
            Rectangle { x: -width / 2; y: -height / 2; width: Math.max(1, sg.k * 5); height: sg.k * 30; radius: width / 2; color: sg.color }
            Rectangle { rotation: 45; opacity: 0.7; x: -width / 2; y: -height / 2; width: sg.k * 18; height: Math.max(1, sg.k * 4); radius: height / 2; color: sg.color }
            Rectangle { rotation: 45; opacity: 0.7; x: -width / 2; y: -height / 2; width: Math.max(1, sg.k * 4); height: sg.k * 18; radius: width / 2; color: sg.color }
        }
        Item {  // rear sparkle — the smaller star, same grammar
            visible: sg.bsw > 0.86 && sg.bsw < 0.99
            x: sg.k * 424 + sg.kx; y: sg.k * 200 + sg.ky
            scale: sg.bsw < 0.93 ? 1 : 0.6
            Rectangle { x: -width / 2; y: -height / 2; width: sg.k * 24; height: Math.max(1, sg.k * 4.5); radius: height / 2; color: sg.color }
            Rectangle { x: -width / 2; y: -height / 2; width: Math.max(1, sg.k * 4.5); height: sg.k * 24; radius: width / 2; color: sg.color }
            Rectangle { rotation: 45; opacity: 0.7; x: -width / 2; y: -height / 2; width: sg.k * 14; height: Math.max(1, sg.k * 3.6); radius: height / 2; color: sg.color }
            Rectangle { rotation: 45; opacity: 0.7; x: -width / 2; y: -height / 2; width: Math.max(1, sg.k * 3.6); height: sg.k * 14; radius: width / 2; color: sg.color }
        }
    }

    // TV foot — a VGA-era CRT monitor drawn like hardware: boxy case, 4:3
    // tube behind an even bezel, control strip with two buttons and a power
    // LED, neck and swivel base. The tube is ALIVE — scanline with phosphor
    // afterglow, interference bars popping with the static flick, the LED
    // breathing — and every moving thing is clipped inside the glass.
    component RetroTV: Item {
        id: tvc
        property color color: "white"
        property bool running: false
        readonly property real u: width / 100
        readonly property real lw: Math.max(1.5, 5.5 * tvc.u)
        // Arming the slot POWERS the set ON: a hard two-blink tube stutter,
        // then the readout TYPES IN line by line — a boot sequence, codec
        // style. Deselect rests the glass and restores the full readout.
        property int boot: 5
        onRunningChanged: {
            if (running) { crtPowerOn.restart(); crtBoot.restart() }
            else { crtPowerOn.stop(); tvGlass.flick = 0; tvGlass.roll = 0; boot = 5 }
        }
        ParallelAnimation {
            id: crtPowerOn
            // v-hold: the frame slips one full turn and locks while the
            // deflection settles up to size — the tube catching signal
            NumberAnimation {
                target: tvGlass; property: "roll"
                from: 1; to: 0; duration: 300; easing.type: Easing.OutQuad
            }
            SequentialAnimation {
                PropertyAction { target: tvGlass; property: "flick"; value: 0.30 }
                PauseAnimation { duration: 80 }
                PropertyAction { target: tvGlass; property: "flick"; value: -0.02 }
                PauseAnimation { duration: 60 }
                PropertyAction { target: tvGlass; property: "flick"; value: 0.14 }
                PauseAnimation { duration: 70 }
                PropertyAction { target: tvGlass; property: "flick"; value: 0.06 }
                PauseAnimation { duration: 60 }
                PropertyAction { target: tvGlass; property: "flick"; value: 0 }
            }
        }
        SequentialAnimation {
            id: crtBoot
            PropertyAction { target: tvc; property: "boot"; value: 0 }
            PauseAnimation { duration: 190 }
            PropertyAction { target: tvc; property: "boot"; value: 1 }
            PauseAnimation { duration: 90 }
            PropertyAction { target: tvc; property: "boot"; value: 2 }
            PauseAnimation { duration: 90 }
            PropertyAction { target: tvc; property: "boot"; value: 3 }
            PauseAnimation { duration: 90 }
            PropertyAction { target: tvc; property: "boot"; value: 4 }
            PauseAnimation { duration: 90 }
            PropertyAction { target: tvc; property: "boot"; value: 5 }
        }
        SequentialAnimation {  // display refresh: every ~5s the readout
            // blinks off for a frame and retypes, and the scanline RETRACES
            // to the top in the same instant — one v-sync event, the whole
            // display resyncing as a single machine
            running: tvc.running
            loops: Animation.Infinite
            PauseAnimation { duration: 4700 }
            PropertyAction { target: tvc; property: "boot"; value: 0 }
            ScriptAction { script: scanAnim.restart() }
            PauseAnimation { duration: 70 }
            PropertyAction { target: tvc; property: "boot"; value: 5 }
        }
        Rectangle {  // case — the MultiSync's boxy shell, snug round the
            // square tube. Cel-shaded: lit crown, shaded foot and flank —
            // a BODY with a light source, not an outline
            x: 14.5 * tvc.u; y: 12 * tvc.u; width: 71 * tvc.u; height: 62 * tvc.u
            radius: 4 * tvc.u
            // an opaque body — a monitor is a solid thing, not an outline
            color: Theme.withAlpha(Theme.bg, 0.35)
            // the shell's stroke is PLASTIC tone, not white: the crown
            // hairline is the only bright line the body carries
            border.color: Theme.withAlpha(tvc.color, 0.65); border.width: tvc.lw
            Rectangle {  // the border's own shading: its bottom run sits in
                // shadow — the STROKE models the light, not just the fills
                x: tvc.lw * 1.5; y: parent.height - tvc.lw
                width: parent.width - tvc.lw * 3; height: tvc.lw
                color: Theme.withAlpha(Theme.bg, 0.3)
            }
            Rectangle {  // and its right run, a half-step
                x: parent.width - tvc.lw; y: tvc.lw * 1.5
                width: tvc.lw; height: parent.height - tvc.lw * 3
                color: Theme.withAlpha(Theme.bg, 0.22)
            }
            Rectangle {  // crown light
                x: tvc.lw; y: tvc.lw + 0.5
                width: parent.width - tvc.lw * 2; height: 1
                color: Theme.withAlpha(Theme.fg, 0.3)
            }
            Rectangle {  // foot shade
                x: tvc.lw; y: parent.height - tvc.lw - 2.5 * tvc.u
                width: parent.width - tvc.lw * 2; height: 2.5 * tvc.u
                color: Theme.withAlpha(Theme.bg, 0.4)
            }
            Rectangle {  // flank shade, right side
                x: parent.width - tvc.lw - 2 * tvc.u; y: tvc.lw
                width: 2 * tvc.u; height: parent.height - tvc.lw * 2 - 2.5 * tvc.u
                color: Theme.withAlpha(Theme.bg, 0.3)
            }
        }
        Rectangle {  // tube-module seam — the dark gap where the screen
            // assembly sets into the case shell
            x: 21 * tvc.u; y: 18.5 * tvc.u; width: 58 * tvc.u; height: 47 * tvc.u
            radius: 3.5 * tvc.u
            color: "transparent"
            border.width: 1
            border.color: Theme.withAlpha(Theme.bg, 0.5)
        }
        Rectangle {  // the tube — 5:4, an even bezel all round
            id: tvScreen
            x: 22.5 * tvc.u; y: 20 * tvc.u; width: 55 * tvc.u; height: 44 * tvc.u
            radius: 3 * tvc.u; color: "transparent"
            // bezel a step brighter than the shell — it faces forward
            border.color: Theme.withAlpha(tvc.color, 0.75); border.width: Math.max(1.5, 4 * tvc.u)
            clip: true
            Rectangle {  // bezel crown light — matches the case's
                z: 3
                x: Math.max(1.5, 4 * tvc.u) * 1.5; y: 0.5
                width: parent.width - Math.max(1.5, 4 * tvc.u) * 3; height: 1
                color: Theme.withAlpha(Theme.fg, 0.28)
            }
            Rectangle {  // bezel lower-run shade
                z: 3
                x: Math.max(1.5, 4 * tvc.u) * 1.5; y: parent.height - Math.max(1.5, 4 * tvc.u)
                width: parent.width - Math.max(1.5, 4 * tvc.u) * 3
                height: Math.max(1.5, 4 * tvc.u)
                color: Theme.withAlpha(Theme.bg, 0.25)
            }
            Item {  // the tube's IMAGE — everything the beam draws, rendered
                // offscreen and fed through the glass shader below. The
                // reference boards' monitors are never blank; a populated
                // screen is what sells "working machine" at a glance.
                id: crtFace
                anchors.fill: parent
                anchors.margins: Math.max(1.5, 4 * tvc.u)
                clip: true
                Rectangle {  // the on-screen WINDOW — the readout's dialog
                    // frame, drawn like a real terminal pane
                    x: 0.03 * parent.width; y: 0.12 * parent.height
                    width: 0.72 * parent.width; height: 0.68 * parent.height
                    color: "transparent"
                    border.width: 1
                    border.color: Theme.withAlpha(Theme.fg, tvc.running ? 0.22 : 0.14)
                    Rectangle {  // title bar — a filled strip, the window's cap
                        x: 1; y: 1
                        width: parent.width - 2; height: 0.14 * parent.height
                        color: Theme.withAlpha(Theme.fg, tvc.running ? 0.14 : 0.09)
                    }
                }
                Repeater {
                    model: [[0.06, 0.16, 0.56], [0.06, 0.34, 0.40], [0.06, 0.52, 0.64], [0.06, 0.70, 0.30], [0.70, 0.84, 0.24]]
                    Rectangle {
                        visible: index < tvc.boot
                        // the TITLE row leads; body rows sit two steps back
                        color: Theme.withAlpha(Theme.fg, (index === 0 ? 0.5 : 0.34) * (tvc.running ? 1 : 0.68))
                        x: modelData[0] * parent.width
                        y: modelData[1] * parent.height
                        width: modelData[2] * parent.width
                        height: Math.max(1, 2.2 * tvc.u)
                    }
                }
                Rectangle {  // terminal cursor after the last typed line —
                    // solid at standby, hard square-wave blink when armed
                    id: crtCursor
                    property bool lit: true
                    visible: tvc.boot > 3 && (tvc.running ? lit : true)
                    color: Theme.withAlpha(Theme.fg, tvc.running ? 0.5 : 0.3)
                    x: 0.375 * parent.width; y: 0.675 * parent.height
                    width: 3.2 * tvc.u; height: 3.6 * tvc.u
                    SequentialAnimation {
                        running: tvc.running
                        loops: Animation.Infinite
                        PropertyAction { target: crtCursor; property: "lit"; value: true }
                        PauseAnimation { duration: 530 }
                        PropertyAction { target: crtCursor; property: "lit"; value: false }
                        PauseAnimation { duration: 530 }
                    }
                }
                // signal-strength meter — three ascending bars, bottom-right
                // of the display: codec furniture, always on
                Repeater {
                    model: 3
                    Rectangle {
                        // the display refresh blanks the meter too — one
                        // redraw event owns every readout
                        color: Theme.withAlpha(Theme.fg, (tvc.running ? 0.42 : 0.28) * (tvGlass.flick > 0.05 ? 0.5 : 1))
                        visible: tvc.boot > 0
                        width: 2.4 * tvc.u
                        height: (2 + index * 1.8) * tvc.u
                        x: parent.width * 0.80 + index * 4 * tvc.u
                        y: parent.height * 0.30 - height
                    }
                }
                Rectangle {  // the meter's base rail
                    x: parent.width * 0.79; y: parent.height * 0.30
                    width: 12 * tvc.u; height: 1
                    color: Theme.withAlpha(Theme.fg, 0.3)
                }
            }
            ShaderEffect {  // the GLASS — one pass owns the tube face:
                // rolling beam + phosphor persistence, tube-fixed scanline
                // pitch, corner vignette, centre bloom, true static snow,
                // and the power-on v-hold roll. The readout above feeds in
                // as a texture, so the beam energizes the rows it crosses.
                id: tvGlass
                anchors.fill: parent
                anchors.margins: Math.max(1.5, 4 * tvc.u)
                fragmentShader: "qrc:/qml/shaders/crtglass.frag.qsb"
                property variant source: ShaderEffectSource {
                    sourceItem: crtFace
                    hideSource: true
                }
                property color tint: tvc.color
                property real flick: 0
                // base glass level; static bursts flick it, gated on running
                // so deselecting mid-burst rests the glass
                property real bed: (tvc.running ? 0.11 : 0.08) + (tvc.running ? flick : 0)
                property real lit: tvc.running ? 1 : 0
                Behavior on lit { NumberAnimation { duration: 260 } }
                property real scan: 0
                NumberAnimation on scan {
                    id: scanAnim
                    running: tvc.running && tvc.visible
                    from: 0; to: 1; duration: 2600
                    loops: Animation.Infinite
                }
                property real roll: 0
                // snow whispers while armed; static bursts drive it hard
                property real snow: lit * 0.045 + (tvc.running ? Math.max(0, flick) : 0)
                property real ph: height
                // static bursts are INSTANT level jumps — digital stutter,
                // not a soft pulse. Real snow made the burst DRAMATIC, so
                // it earns PS1 rarity: an occasional signal hiccup, not a
                // metronome — the rolling beam carries the life between.
                SequentialAnimation on flick {
                    running: tvc.running
                    loops: Animation.Infinite
                    PauseAnimation { duration: 6800 }
                    PropertyAction { value: 0.20 }
                    PauseAnimation { duration: 70 }
                    PropertyAction { value: -0.04 }
                    PauseAnimation { duration: 50 }
                    PropertyAction { value: 0.16 }
                    PauseAnimation { duration: 60 }
                    PropertyAction { value: 0 }
                }
            }
            Rectangle {  // bezel overhang shadow — the glass sits BEHIND
                // the frame, and the frame's top edge proves it
                x: Math.max(1.5, 4 * tvc.u); y: Math.max(1.5, 4 * tvc.u)
                width: parent.width - Math.max(1.5, 4 * tvc.u) * 2
                height: 3 * tvc.u
                color: Theme.withAlpha(Theme.bg, 0.45)
            }
            Rectangle {  // and a thinner one down the left flank
                x: Math.max(1.5, 4 * tvc.u); y: Math.max(1.5, 4 * tvc.u)
                width: 1.8 * tvc.u
                height: parent.height - Math.max(1.5, 4 * tvc.u) * 2
                color: Theme.withAlpha(Theme.bg, 0.3)
            }
            Rectangle {  // window-light glint — one static diagonal catch
                // near the glass's upper right: the room reflected
                x: parent.width - 13 * tvc.u; y: 7 * tvc.u
                width: 7 * tvc.u; height: Math.max(1, 1.3 * tvc.u)
                radius: height / 2
                rotation: -38
                color: Theme.withAlpha(Theme.fg, 0.14)
            }
        }
        // XV17+ control strip (the user's actual monitor): badge left, a
        // row of four adjustment buttons, power switch + LED right — no
        // door, no vents; the XV wears its controls on the bezel face
        Repeater {
            model: 4
            Rectangle {
                color: tvc.color; opacity: 0.6
                x: (36 + index * 5.4) * tvc.u; y: 65.4 * tvc.u
                width: 3.2 * tvc.u; height: Math.max(1, 2.6 * tvc.u)
                radius: 0.8 * tvc.u
            }
        }
        Rectangle {  // the button row's shared shadow — they stand proud
            x: 36.5 * tvc.u; y: 68.2 * tvc.u
            width: 19.5 * tvc.u; height: 1
            color: Theme.withAlpha(Theme.bg, 0.4)
        }
        Rectangle {  // badge plate (the NEC nameplate's slot)
            color: tvc.color; opacity: 0.55
            x: 21.5 * tvc.u; y: 65.5 * tvc.u
            width: 10 * tvc.u; height: Math.max(1, 2.4 * tvc.u); radius: 1 * tvc.u
            Rectangle {  // the nameplate's mark, punched
                x: 2 * tvc.u; y: parent.height / 2 - height / 2
                width: 6 * tvc.u; height: Math.max(1, 1 * tvc.u)
                color: Theme.withAlpha(Theme.bg, 0.6)
            }
        }
        Rectangle {
            x: 22 * tvc.u; y: 68.1 * tvc.u
            width: 10 * tvc.u; height: 1
            color: Theme.withAlpha(Theme.bg, 0.35)
        }
        Rectangle {  // the power switch — one firm rectangle, right side
            color: Theme.withAlpha(tvc.color, 0.72)
            x: 61 * tvc.u; y: 65.2 * tvc.u
            width: 7 * tvc.u; height: Math.max(1, 3 * tvc.u); radius: 1 * tvc.u
        }
        Rectangle {  // its shadow — the switch stands proud of the bezel
            x: 61.5 * tvc.u; y: 68.4 * tvc.u
            width: 7 * tvc.u; height: 1
            color: Theme.withAlpha(Theme.bg, 0.45)
        }
        Rectangle {  // LED socket — the recess the lamp sits in
            x: 70.4 * tvc.u; y: 64.2 * tvc.u
            width: 4.8 * tvc.u; height: 4.8 * tvc.u; radius: width / 2
            color: Theme.withAlpha(Theme.bg, 0.5)
        }
        Rectangle {  // LED halo — the lamp's light on the bezel around it
            x: 69.4 * tvc.u; y: 63.2 * tvc.u
            width: 6.8 * tvc.u; height: 6.8 * tvc.u; radius: width / 2
            color: tvc.running ? "#8fe3a1" : "#c04a42"
            opacity: tvc.running ? 0.18 : 0.1
        }
        Rectangle {  // power LED — green means ON: steady while the set
            // runs, dim red at standby, no blinking
            id: crtLed
            x: 71 * tvc.u; y: 64.8 * tvc.u
            width: 3.6 * tvc.u; height: 3.6 * tvc.u; radius: width / 2
            color: tvc.running ? "#8fe3a1" : "#c04a42"
            opacity: tvc.running ? 0.9 : 0.55
        }
        // neck + two-tier swivel base (the wider foot under the tilt plate
        // is what makes it read "monitor stand", not "TV on a block")
        Rectangle {  // MultiSync pedestal: short and BROAD, the tilt-swivel
            // wedge the monitor sits almost flush on
            color: tvc.color
            opacity: 0.68
            x: 39 * tvc.u; y: 74 * tvc.u; width: 22 * tvc.u; height: 6.5 * tvc.u
            Rectangle {  // flank shade — same light as the case
                x: parent.width - 2 * tvc.u; y: 0
                width: 2 * tvc.u; height: parent.height
                color: Theme.withAlpha(Theme.bg, 0.3)
            }
        }
        Rectangle {  // seam where the pedestal meets the case shell
            x: 38 * tvc.u; y: 74 * tvc.u; width: 24 * tvc.u; height: 1
            color: Theme.withAlpha(Theme.bg, 0.55)
        }
        Rectangle {
            color: tvc.color
            opacity: 0.64
            x: 34 * tvc.u; y: 80.5 * tvc.u; width: 32 * tvc.u; height: 3.5 * tvc.u
            Rectangle {
                x: parent.width - 2.5 * tvc.u; y: 0
                width: 2.5 * tvc.u; height: parent.height
                color: Theme.withAlpha(Theme.bg, 0.3)
            }
            Rectangle {  // swivel pivot — the punched centre the tilt
                // plate actually turns on
                x: parent.width / 2 - width / 2; y: parent.height / 2 - height / 2
                width: 2 * tvc.u; height: 2 * tvc.u; radius: width / 2
                color: Theme.withAlpha(Theme.bg, 0.5)
            }
        }
        Rectangle {  // seam between the tilt plate and the foot — the swivel
            x: 30 * tvc.u; y: 84 * tvc.u; width: 40 * tvc.u; height: 1
            color: Theme.withAlpha(Theme.bg, 0.5)
        }
        Rectangle {
            color: tvc.color
            opacity: 0.6
            x: 24 * tvc.u; y: 84 * tvc.u; width: 52 * tvc.u; height: 3.5 * tvc.u
            radius: 1.75 * tvc.u
            Rectangle {  // foot crown light
                x: 2 * tvc.u; y: 0.5
                width: parent.width - 4 * tvc.u; height: 1
                color: Theme.withAlpha(Theme.fg, 0.25)
            }
        }
        Rectangle {  // ground shadow — the monitor sits on a desk, not in
            // a void: one hard dark line under the foot
            x: 27 * tvc.u; y: 88.2 * tvc.u; width: 46 * tvc.u
            height: Math.max(1, 1.6 * tvc.u)
            radius: height / 2
            color: Theme.withAlpha(Theme.bg, 0.5)
        }
    }

    // A parametric 3D GEAR built from primitives — solid steel web,
    // radial teeth, proud hub, dark bore with its light KEY seated in the
    // notch, and four raised face ribs (the MGS-manual spokes, now real
    // relief that catches the light). Local frame: axis along Y; the
    // mechanism mounts it face-out.
    component Gear3D: Node {
        id: g3
        property int teeth: 10
        property real r: 23          // rim radius to tooth base
        property real th: 10         // web thickness
        property real spin: 0
        eulerRotation.y: spin
        Model {  // web
            source: "#Cylinder"
            scale: Qt.vector3d(g3.r * 2 / 100, g3.th / 100, g3.r * 2 / 100)
            materials: PrincipledMaterial {
                baseColor: "#7b818c"; metalness: 0.6; roughness: 0.46 }
        }
        Repeater3D {  // teeth — the involute reduced to honest PS1 prisms
            model: g3.teeth
            Node {
                eulerRotation.y: index * (360 / g3.teeth)
                Model {
                    source: "#Cube"
                    position: Qt.vector3d(0, 0, g3.r + 2.9)
                    scale: Qt.vector3d((2 * 3.14159 * g3.r / g3.teeth) * 0.0048,
                                       (g3.th - 0.8) / 100, 0.062)
                    materials: PrincipledMaterial {
                        baseColor: "#7b818c"; metalness: 0.6; roughness: 0.46 }
                }
            }
        }
        Repeater3D {  // face ribs — raised relief between hub and rim
            model: 4
            Node {
                eulerRotation.y: 45 + index * 90
                Model {
                    source: "#Cube"
                    position: Qt.vector3d(0, g3.th / 2, (g3.r * 0.36 + g3.r) / 2)
                    scale: Qt.vector3d(0.045, 0.024, (g3.r * 0.64 + 2) / 100)
                    materials: PrincipledMaterial {
                        baseColor: "#939aa6"; metalness: 0.6; roughness: 0.4 }
                }
            }
        }
        Repeater3D {  // lightening holes between the ribs — weight-cut
            // discs, the industrial-mecha web signature
            model: 4
            Node {
                eulerRotation.y: index * 90
                Model {
                    source: "#Cylinder"
                    position: Qt.vector3d(0, g3.th / 2 + 0.2, g3.r * 0.62)
                    scale: Qt.vector3d(g3.r * 0.30 / 100, 0.008, g3.r * 0.30 / 100)
                    materials: PrincipledMaterial {
                        baseColor: "#1d1c1f"; roughness: 0.8 }
                }
            }
        }
        Repeater3D {  // hub bolt ring — six studs seating the wheel
            model: 6
            Node {
                eulerRotation.y: index * 60
                Model {
                    source: "#Cylinder"
                    position: Qt.vector3d(0, g3.th / 2 + 0.5, g3.r * 0.44)
                    scale: Qt.vector3d(g3.r * 0.055 / 100, 0.016, g3.r * 0.055 / 100)
                    materials: PrincipledMaterial {
                        baseColor: "#4b5058"; metalness: 0.6; roughness: 0.5 }
                }
            }
        }
        Model {  // hub — stands proud of the web
            source: "#Cylinder"
            scale: Qt.vector3d(g3.r * 0.72 / 100, (g3.th + 2) / 100, g3.r * 0.72 / 100)
            materials: PrincipledMaterial {
                baseColor: "#5d626b"; metalness: 0.6; roughness: 0.5 }
        }
        Model {  // bore — the dark shaft hole
            source: "#Cylinder"
            scale: Qt.vector3d(g3.r * 0.32 / 100, (g3.th + 3) / 100, g3.r * 0.32 / 100)
            materials: PrincipledMaterial {
                baseColor: "#141518"; metalness: 0.2; roughness: 0.8 }
        }
        Model {  // KEYWAY — the key seated in the bore, locking wheel to
            // shaft; it turns with the gear, as it must
            source: "#Cube"
            position: Qt.vector3d(0, 0, g3.r * 0.13)
            scale: Qt.vector3d(g3.r * 0.10 / 100, (g3.th + 3.4) / 100, g3.r * 0.10 / 100)
            materials: PrincipledMaterial {
                baseColor: "#7b818c"; metalness: 0.6; roughness: 0.46 }
        }
        Model {  // shaft end — the polished stub the whole train turns on
            source: "#Cylinder"
            scale: Qt.vector3d(g3.r * 0.17 / 100, (g3.th + 4.4) / 100, g3.r * 0.17 / 100)
            materials: PrincipledMaterial {
                baseColor: "#9aa1ad"; metalness: 0.7; roughness: 0.35 }
        }
    }

    // SETTINGS foot, the DEFAULT — the MeshGears drawing's full-3D
    // successor: a real gear MODULE on the family's turntable stage. Two
    // steel gears (10:8, correct counter-mesh) mounted face-out on stub
    // axles over a dark back plate — an opened service module, AC-garage
    // style. Selection is LIGHT (the globe's grammar): idle parks the key
    // behind-left, metal reads as rim glints; arming swings it round in
    // the 750ms sweep while the train takes up its BACKLASH — a hair
    // backward, then it bites into cruise — and the stage sways gently.
    // Deselect rests drive modulo a full tooth pitch: the standing pose
    // is pixel-identical to zero, so re-engagement never jumps. The 2D
    // original lives on in the icon-debug pool as "gears-2d".
    component Gears3D: Item {
        id: mg3
        property color color: "white"   // pool-interface parity
        property bool running: false
        property real drive: 0
        property real jolt: 0
        property real swy: 0
        onRunningChanged: {
            if (running) mg3Engage.restart()
            else { mg3Engage.stop(); jolt = 0; swy = 0; drive %= 0.1 }
        }
        SequentialAnimation {
            id: mg3Engage
            NumberAnimation {
                target: mg3; property: "jolt"
                to: -0.007; duration: 60; easing.type: Easing.InQuad
            }
            NumberAnimation {
                target: mg3; property: "jolt"
                to: 0; duration: 110; easing.type: Easing.OutQuad
            }
        }
        SequentialAnimation on drive {
            // visible-gated like swy: the train must not turn on CPU while
            // the home stage is hidden behind playback
            running: mg3.running && mg3.visible
            NumberAnimation { from: 0; to: 1; duration: 4800; loops: Animation.Infinite }
        }
        SequentialAnimation on swy {
            running: mg3.running && mg3.visible
            loops: Animation.Infinite
            NumberAnimation { to: 9; duration: 3400; easing.type: Easing.InOutSine }
            NumberAnimation { to: 0; duration: 3400; easing.type: Easing.InOutSine }
        }
        Loader {
            id: mg3Loader
            anchors.fill: parent
            asynchronous: true
            property bool armed: false
            // stays loaded while HOME is merely hidden (another stage is up): unloading
            // on every stage change rebuilt the 3D scene → a 100–300 ms hitch on return
            active: armed && (mg3.visible || (item !== null && App.stage !== "home"))
            opacity: status === Loader.Ready ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 320 } }
            Timer { interval: 700; running: true; onTriggered: mg3Loader.armed = true }
            sourceComponent: View3D {
                id: gear3d
                anchors.fill: parent
                environment: SceneEnvironment {
                    backgroundMode: SceneEnvironment.Transparent
                    antialiasingMode: SceneEnvironment.MSAA
                    antialiasingQuality: SceneEnvironment.High
                }
                OrthographicCamera {
                    z: 300
                    // family framing law: the meshed pair is a circle
                    // CLUSTER (~73% of box), between the globe's disc and
                    // the TV's solid box in optical weight
                    horizontalMagnification: gear3d.width / 88
                    verticalMagnification: gear3d.width / 88
                }
                DirectionalLight {
                    eulerRotation.x: -18
                    eulerRotation.y: mg3.running ? -26 : -142
                    brightness: mg3.running ? 1.4 : 0.9
                    color: "#fff4e4"
                    Behavior on eulerRotation.y {
                        NumberAnimation { duration: 750; easing.type: Easing.InOutCubic } }
                    Behavior on brightness {
                        NumberAnimation { duration: 750; easing.type: Easing.InOutCubic } }
                }
                DirectionalLight {  // frontal fill — bare metal has no
                    // glow of its own, so standby readability comes from a
                    // dim wash instead (the CRT gets this for free from
                    // its glass)
                    eulerRotation.y: -55
                    eulerRotation.x: -20
                    // family idle parity: at rest the workshop lamp is
                    // banked WARM and low, so the grey cel-steel pair
                    // (anime mecha, not brass) rests dark with one warm
                    // glint like the family's other embers
                    brightness: mg3.running ? 0.30 : 0.38
                    color: mg3.running ? "#93b7c6" : "#c2a87e"
                    Behavior on brightness {
                        NumberAnimation { duration: 750; easing.type: Easing.InOutCubic } }
                    Behavior on color {
                        ColorAnimation { duration: 750; easing.type: Easing.InOutCubic } }
                }
                Node {
                    eulerRotation.x: -8
                    y: -3   // family floor line
                    Node {
                        id: mg3Table
                        eulerRotation.y: -24 + mg3.swy
                        Model {  // the STAGE
                            source: "#Cylinder"
                            scale: Qt.vector3d(0.55, 0.016, 0.55)
                            position: Qt.vector3d(0, -33.8, 0)
                            materials: PrincipledMaterial {
                                baseColor: "#27241e"; roughness: 0.48; metalness: 0.45 }
                        }
                        Model {  // contact shadow under the big wheel
                            source: "#Sphere"
                            scale: Qt.vector3d(0.36, 0.005, 0.20)
                            position: Qt.vector3d(9, -32.8, 0)
                            opacity: 0.4
                            materials: PrincipledMaterial {
                                baseColor: "#000000"
                                lighting: PrincipledMaterial.NoLighting }
                        }
                        Model {  // and a lighter one cast by the idler
                            source: "#Sphere"
                            scale: Qt.vector3d(0.24, 0.005, 0.13)
                            position: Qt.vector3d(-18, -32.9, 0)
                            opacity: 0.25
                            materials: PrincipledMaterial {
                                baseColor: "#000000"
                                lighting: PrincipledMaterial.NoLighting }
                        }
                        Node {  // the PAIR — no chassis, no box: two big
                            // meshed steel wheels fill the frame, the 2D
                            // layout reborn in relief; dropped so the big
                            // wheel SEATS on the stage its shadow claims
                            y: -5
                            scale: Qt.vector3d(0.9, 0.9, 0.9)
                            Node {  // BIG gear on its stub axle
                                position: Qt.vector3d(10, -4, 0)
                                Model {
                                    source: "#Cylinder"
                                    eulerRotation.x: 90
                                    scale: Qt.vector3d(0.11, 0.14, 0.11)
                                    position: Qt.vector3d(0, 0, -7)
                                    materials: PrincipledMaterial {
                                        baseColor: "#3a3d42"; roughness: 0.6 }
                                }
                                Node {
                                    eulerRotation.x: 90
                                    Gear3D {
                                        teeth: 10; r: 24; th: 12
                                        spin: 27 + (mg3.drive + mg3.jolt) * 360
                                    }
                                }
                            }
                            Node {  // SMALL gear — counter-meshed idler
                                position: Qt.vector3d(-20, 28, 0)
                                Model {
                                    source: "#Cylinder"
                                    eulerRotation.x: 90
                                    scale: Qt.vector3d(0.10, 0.14, 0.10)
                                    position: Qt.vector3d(0, 0, -7)
                                    materials: PrincipledMaterial {
                                        baseColor: "#3a3d42"; roughness: 0.6 }
                                }
                                Node {
                                    eulerRotation.x: 90
                                    Gear3D {
                                        teeth: 8; r: 17; th: 12
                                        spin: 8 - (mg3.drive + mg3.jolt) * 450
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MOVIES foot, the DEFAULT — the FilmStrip's full-3D successor: a
    // real length of 35mm undulating through space over the family stage,
    // still carrying the user's actual movies (the pickStills idea, kept
    // by request). Eight film cells ride a gentle sine wave, each backed
    // by a shared rail-and-perforation texture and fronted by a REAL
    // poster; the claw's intermittent pull-down yanks the whole ribbon a
    // frame-pitch at a time, cells banking as they follow the curve. The
    // GATE frame (centre) projects brightest; the shutter dims the print
    // during the pull; idle rests the ribbon as dark ghosts rim-lit from
    // behind. The 2D original lives on in the pool as "film-strip-2d".
    component Film3D: Item {
        id: f3
        property color color: "white"   // pool-interface parity
        property bool running: false
        property real feed: 0
        property int cyc: 0
        onRunningChanged: {
            if (!running) feed = 0
            else if (stills.length === 0) pickStills()
        }
        // the reel: EVERY movie in the library, threaded in order — sit
        // long enough and your whole collection passes through the gate.
        // Frozen while projecting (a reshuffle must never swap a print
        // mid-showing), re-threaded when the library rescans.
        property var stills: []
        function pickStills() {
            // artLocal, not art: these paint onto a Qt Quick 3D Texture, which can't
            // fetch a satellite's remote http art URL — it needs the locally-synced
            // file (#238: the laptop film-strip was all-white). Hub is unaffected.
            stills = MediaLibrary.moviePosters().map(p => Theme.artLocal(p))
        }
        Component.onCompleted: pickStills()
        Connections {
            target: MediaLibrary
            function onScanned() { if (!f3.running) f3.pickStills() }
        }
        // the intermittent: grip, YANK one pitch, register with a hair of
        // overshoot, dwell — the pull-down that IS projection (2D-proven).
        // visible-gated like every cruise loop: selection outlives the home
        // stage, and a hidden ribbon must not tick CPU through a whole film
        SequentialAnimation on feed {
            running: f3.running && f3.visible
            loops: Animation.Infinite
            NumberAnimation { to: -0.02; duration: 50; easing.type: Easing.OutQuad }
            NumberAnimation { to: 1.04; duration: 130; easing.type: Easing.InCubic }
            NumberAnimation { to: 1; duration: 70; easing.type: Easing.OutQuad }
            ScriptAction { script: { f3.feed = 0; f3.cyc = (f3.cyc + 1) % Math.max(1, f3.stills.length) } }
            PauseAnimation { duration: 610 }
            NumberAnimation { to: -0.02; duration: 50; easing.type: Easing.OutQuad }
            NumberAnimation { to: 1.04; duration: 135; easing.type: Easing.InCubic }
            NumberAnimation { to: 1; duration: 70; easing.type: Easing.OutQuad }
            ScriptAction { script: { f3.feed = 0; f3.cyc = (f3.cyc + 1) % Math.max(1, f3.stills.length) } }
            PauseAnimation { duration: 390 }
        }
        readonly property bool pulling: feed > 0.05 && feed < 0.98
        Item {  // the CELL texture — rails, perforations and frame window,
            // drawn once and shared by every cell's backing (parked
            // off-window; an invisible sourceItem feeds WHITE)
            id: f3Cell
            x: -1200; y: -1250
            width: 72; height: 96
            Rectangle { anchors.fill: parent; color: "#3a3a3e" }
            Rectangle {  // the frame window the poster sits in
                x: 3; y: 10; width: 66; height: 76
                color: "#141518"
            }
            Repeater {  // perforations — BACKLIT holes: the projector's
                // light through the stock, the anime-cel film read
                model: 8
                Rectangle {
                    x: 5 + (index % 4) * 18; y: index < 4 ? 3 : 89
                    width: 10; height: 5; radius: 2
                    color: "#9a9aa0"
                }
            }
            Repeater {  // edge codes — the stock's printed marks between
                // the perforations, top rail
                model: 3
                Rectangle {
                    x: 16 + index * 18; y: 5
                    width: 6; height: 2
                    color: "#63636a"
                }
            }
            Repeater {  // and the frame-line pair, bottom rail
                model: 2
                Rectangle {
                    x: 25 + index * 18; y: 90
                    width: 5; height: 2
                    color: "#63636a"
                }
            }
        }
        Loader {
            id: f3Loader
            anchors.fill: parent
            asynchronous: true
            property bool armed: false
            // stays loaded while HOME is merely hidden (another stage is up): unloading
            // on every stage change rebuilt the 3D scene → a 100–300 ms hitch on return
            active: armed && (f3.visible || (item !== null && App.stage !== "home"))
            opacity: status === Loader.Ready ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 320 } }
            Timer { interval: 820; running: true; onTriggered: f3Loader.armed = true }
            sourceComponent: View3D {
                id: film3d
                anchors.fill: parent
                environment: SceneEnvironment {
                    backgroundMode: SceneEnvironment.Transparent
                    antialiasingMode: SceneEnvironment.MSAA
                    antialiasingQuality: SceneEnvironment.High
                }
                OrthographicCamera {
                    z: 300
                    horizontalMagnification: film3d.width / 92
                    verticalMagnification: film3d.width / 92
                }
                DirectionalLight {
                    eulerRotation.x: -18
                    eulerRotation.y: f3.running ? -32 : -142
                    brightness: f3.running ? 1.2 : 0.9
                    color: "#eceae6"
                    Behavior on eulerRotation.y {
                        NumberAnimation { duration: 750; easing.type: Easing.InOutCubic } }
                    Behavior on brightness {
                        NumberAnimation { duration: 750; easing.type: Easing.InOutCubic } }
                }
                DirectionalLight {  // frontal fill for the dark side —
                    // trimmed to family range: at 0.5 the backlit perfs
                    // went cyan, the one cool voice in a warm idle row
                    eulerRotation.y: -55
                    eulerRotation.x: -20
                    brightness: f3.running ? 0.28 : 0.4
                    color: "#93b7c6"
                    Behavior on brightness {
                        NumberAnimation { duration: 750; easing.type: Easing.InOutCubic } }
                }
                Node {
                    eulerRotation.x: -8
                    y: -5   // the ribbon's underside rides the family floor line
                    Node {
                        id: f3Table
                        Node {  // the RIBBON — cells riding the sine wave
                            y: -1
                            Repeater3D {
                                model: 8
                                Node {
                                    id: f3Seg
                                    readonly property real px: (index - 3.5) * 46 - f3.feed * 46
                                    readonly property string still: f3.stills.length > 0
                                        ? f3.stills[(index + f3.cyc) % f3.stills.length] : ""
                                    // the ribbon dissolves into the dark before
                                    // the viewport edge — a hard slice through a
                                    // tilted 3D cell read as CLIPPING, not craft
                                    readonly property real edge: Math.max(0, Math.min(1, (44 - Math.abs(px)) / 12))
                                    // the GATE holds the freshly-registered
                                    // frame (left of centre — the pull-down
                                    // lands there); its print carries the
                                    // show. At rest cells sit at ±23, so a
                                    // centre test never lit either print
                                    readonly property bool gate: Math.abs(px + 23) < 16
                                    position: Qt.vector3d(px, 0, 0)
                                    Model {  // cell backing — rails + perfs
                                        source: "#Cube"
                                        scale: Qt.vector3d(0.44, 0.64, 0.006)
                                        opacity: f3Seg.edge
                                        materials: PrincipledMaterial {
                                            baseColorMap: Texture { sourceItem: f3Cell }
                                            roughness: 0.6
                                        }
                                    }
                                    Model {  // the PRINT — a real poster
                                        source: "#Cube"
                                        visible: f3Seg.still !== ""
                                        opacity: f3Seg.edge
                                        position: Qt.vector3d(0, -0.4, 0.5)
                                        scale: Qt.vector3d(0.40, 0.52, 0.004)
                                        materials: PrincipledMaterial {
                                            baseColorMap: Texture {
                                                source: f3Seg.still
                                                // posters are ~1000px tall shrunk to a
                                                // ~20px print — without mips that's
                                                // full-res sampling and shimmer
                                                generateMipmaps: true
                                                mipFilter: Texture.Linear
                                            }
                                            roughness: 0.55
                                            // the LAMP: gate print leads,
                                            // neighbours ride darker, the
                                            // shutter dims the pull, idle
                                            // rests as ghosts
                                            baseColor: {
                                                const l = f3.running
                                                    ? (f3.pulling ? 0.5 : (f3Seg.gate ? 1.0 : 0.55))
                                                    : 0.3
                                                return Qt.rgba(l, l, l, 1)
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
    }

    // STATS foot, the DEFAULT — the StatChart's full-3D successor and
    // still a REAL instrument: five steel bars on a plinth at the user's
    // actual last five weeks of watch time (store watch log, re-sampled
    // on every arm), with the trend as an EMBER light-path riding the
    // bar tops — segments igniting left to right as the bars gauge-fill,
    // the arrowhead popping on completion, pointing wherever the data
    // truly points. Idle holds the completed reading on the dark side,
    // trend banked to a faint ember — the same night-glow kinship as the
    // globe's cities. Empty log falls back to the sculpted heights.
    // The 2D original lives on in the icon-debug pool as "chart-2d".
    component Chart3D: Item {
        id: st3
        property color color: "white"   // pool-interface parity
        property bool running: false
        property var hgt: [24, 36, 30, 50, 64]
        function sample() {
            const raw = Store.watchDays(35)
            const w = [0, 0, 0, 0, 0]
            for (let i = 0; i < raw.length; ++i)
                w[Math.floor(i / 7)] += raw[i].seconds
            const mx = Math.max(w[0], w[1], w[2], w[3], w[4])
            // 6u floor: a zero week is still a READING on the meter
            if (mx > 0) hgt = w.map(v => 6 + 58 * v / mx)
        }
        // First sample on first SHOWING, not on creation: every slot
        // instantiates a Chart3D, and five store queries for four
        // never-visible instruments is four too many.
        property bool sampled: false
        onVisibleChanged: if (visible && !sampled) { sampled = true; sample() }
        Component.onCompleted: if (visible) { sampled = true; sample() }
        // bar-top waypoints (world units) and the segments between them
        readonly property var seg: {
            const pts = []
            for (let i = 0; i < 5; ++i)
                pts.push({ x: -28 + i * 14, y: -29 + hgt[i] * 0.9 + 4.5 })
            const s = []
            for (let i = 0; i < 4; ++i) {
                const dx = pts[i + 1].x - pts[i].x, dy = pts[i + 1].y - pts[i].y
                s.push({ mx: (pts[i].x + pts[i + 1].x) / 2,
                         my: (pts[i].y + pts[i + 1].y) / 2,
                         len: Math.hypot(dx, dy),
                         ang: Math.atan2(dy, dx) * 180 / Math.PI })
            }
            return s
        }
        // the arrow continues the last segment a half-bar past the data
        readonly property var tip: {
            const a = seg[3].ang * Math.PI / 180
            return { x: -28 + 4 * 14 + Math.cos(a) * 8,
                     y: -29 + hgt[4] * 0.9 + 4.5 + Math.sin(a) * 8,
                     ang: seg[3].ang }
        }
        property real grow: 1
        onRunningChanged: {
            if (running) { sample(); st3Grow.restart() }
            else grow = 1
        }
        NumberAnimation {
            id: st3Grow
            target: st3; property: "grow"
            from: 0; to: 1; duration: 620
            easing.type: Easing.OutQuad
        }
        Loader {
            id: st3Loader
            anchors.fill: parent
            asynchronous: true
            property bool armed: false
            // stays loaded while HOME is merely hidden (another stage is up): unloading
            // on every stage change rebuilt the 3D scene → a 100–300 ms hitch on return
            active: armed && (st3.visible || (item !== null && App.stage !== "home"))
            opacity: status === Loader.Ready ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 320 } }
            Timer { interval: 760; running: true; onTriggered: st3Loader.armed = true }
            sourceComponent: View3D {
                id: chart3d
                anchors.fill: parent
                environment: SceneEnvironment {
                    backgroundMode: SceneEnvironment.Transparent
                    antialiasingMode: SceneEnvironment.MSAA
                    antialiasingQuality: SceneEnvironment.High
                }
                OrthographicCamera {
                    z: 300
                    horizontalMagnification: chart3d.width / 92
                    verticalMagnification: chart3d.width / 92
                }
                DirectionalLight {
                    eulerRotation.x: -18
                    eulerRotation.y: st3.running ? -26 : -142
                    brightness: st3.running ? 1.45 : 0.9
                    color: "#fff4e4"
                    Behavior on eulerRotation.y {
                        NumberAnimation { duration: 750; easing.type: Easing.InOutCubic } }
                    Behavior on brightness {
                        NumberAnimation { duration: 750; easing.type: Easing.InOutCubic } }
                }
                DirectionalLight {  // frontal fill for the dark side
                    eulerRotation.y: -55
                    eulerRotation.x: -20
                    brightness: st3.running ? 0.30 : 0.52
                    color: "#93b7c6"
                    Behavior on brightness {
                        NumberAnimation { duration: 750; easing.type: Easing.InOutCubic } }
                }
                Node {
                    y: -4   // family floor line
                    Node {
                        id: st3Table
                        Model {  // the STAGE
                            source: "#Cylinder"
                            scale: Qt.vector3d(0.57, 0.016, 0.57)
                            position: Qt.vector3d(0, -33.8, 0)
                            materials: PrincipledMaterial {
                                baseColor: "#27241e"; roughness: 0.48; metalness: 0.45 }
                        }
                        Model {  // contact shadow
                            source: "#Sphere"
                            scale: Qt.vector3d(0.44, 0.005, 0.22)
                            position: Qt.vector3d(0, -32.8, 0)
                            opacity: 0.4
                            materials: PrincipledMaterial {
                                baseColor: "#000000"
                                lighting: PrincipledMaterial.NoLighting }
                        }
                        Model {  // plinth — the instrument's base slab
                            source: "#Cube"
                            scale: Qt.vector3d(0.84, 0.05, 0.28)
                            position: Qt.vector3d(0, -31.2, 0)
                            materials: PrincipledMaterial {
                                baseColor: "#33363b"; roughness: 0.65 }
                        }
                        Model {  // back panel — the blueprint the data
                            // stands against
                            source: "#Cube"
                            // family framing law: the frame reads ~83% of
                            // the box like the globe's disc — an OPEN frame
                            // can match the circle's bound at equal weight
                            scale: Qt.vector3d(0.82, 0.74, 0.03)
                            position: Qt.vector3d(0, 4, -10)
                            materials: PrincipledMaterial {
                                baseColor: "#1f2126"; roughness: 0.78 }
                        }
                        Repeater3D {  // gridlines etched on the panel
                            model: 3
                            Model {
                                source: "#Cube"
                                scale: Qt.vector3d(0.80, 0.008, 0.005)
                                position: Qt.vector3d(0, -12 + index * 16, -8.2)
                                materials: PrincipledMaterial {
                                    baseColor: "#4a463f"; roughness: 0.7 }
                            }
                        }
                        Model {  // Y-AXIS post — the instrument's spine
                            source: "#Cube"
                            scale: Qt.vector3d(0.028, 0.66, 0.028)
                            position: Qt.vector3d(-37, 4, 0)
                            materials: PrincipledMaterial {
                                baseColor: "#7a746a"; metalness: 0.55; roughness: 0.45 }
                        }
                        Model {  // axis arrowhead — the spine points UP
                            source: "#Cone"
                            scale: Qt.vector3d(0.05, 0.055, 0.05)
                            position: Qt.vector3d(-37, 37, 0)
                            materials: PrincipledMaterial {
                                baseColor: "#7a746a"; metalness: 0.55; roughness: 0.45 }
                        }
                        Repeater3D {  // corner brackets — the instrument
                            // frame's anime-HUD punctuation
                            model: 4
                            Node {
                                readonly property real cx: index % 2 === 0 ? -38 : 38
                                readonly property real cy: index < 2 ? 37 : -27
                                Model {
                                    source: "#Cube"
                                    position: Qt.vector3d(cx + (cx < 0 ? 3 : -3), cy, -8.2)
                                    scale: Qt.vector3d(0.06, 0.012, 0.006)
                                    materials: PrincipledMaterial {
                                        baseColor: "#5c5648"; roughness: 0.6 }
                                }
                                Model {
                                    source: "#Cube"
                                    position: Qt.vector3d(cx, cy + (cy > 0 ? -3 : 3), -8.2)
                                    scale: Qt.vector3d(0.012, 0.06, 0.006)
                                    materials: PrincipledMaterial {
                                        baseColor: "#5c5648"; roughness: 0.6 }
                                }
                            }
                        }
                        Repeater3D {  // reading ticks on the axis post
                            model: 3
                            Model {
                                source: "#Cube"
                                scale: Qt.vector3d(0.028, 0.012, 0.03)
                                position: Qt.vector3d(-34.5, -12 + index * 16, 0)
                                materials: PrincipledMaterial {
                                    baseColor: "#7a746a"; metalness: 0.55; roughness: 0.45 }
                            }
                        }
                        Model {  // baseline rail along the plinth
                            source: "#Cube"
                            scale: Qt.vector3d(0.78, 0.026, 0.026)
                            position: Qt.vector3d(2, -28.6, 7)
                            materials: PrincipledMaterial {
                                baseColor: "#7a746a"; metalness: 0.55; roughness: 0.45 }
                        }
                        Repeater3D {  // the BARS — real weekly readings
                            model: 5
                            Node {
                                id: stBar
                                readonly property real bx: -28 + index * 14
                                readonly property real f: Math.min(1, Math.max(0, (st3.grow - index * 0.09) / 0.38))
                                readonly property real h: st3.hgt[index] * 0.9 * f
                                Model {
                                    source: "#Cube"
                                    position: Qt.vector3d(-28 + index * 14, -29 + parent.h / 2, 0)
                                    scale: Qt.vector3d(0.10, parent.h / 100, 0.14)
                                    materials: PrincipledMaterial {
                                        baseColor: "#6e6a62"; metalness: 0.55; roughness: 0.5 }
                                }
                                Repeater3D {  // segment notches — the meter
                                    // reads in STEPS, tachometer-style. Built
                                    // ONCE for the bar's full height and shown
                                    // as it grows: a count that followed the
                                    // growing bar created and destroyed 3D
                                    // models every frame of the grow.
                                    model: Math.max(0, Math.ceil(st3.hgt[index] * 0.9 / 6) - 1)
                                    Model {
                                        visible: index < Math.ceil(stBar.h / 6) - 1
                                        source: "#Cube"
                                        position: Qt.vector3d(stBar.bx, -29 + 6 * (index + 1), 7.2)
                                        scale: Qt.vector3d(0.10, 0.006, 0.004)
                                        materials: PrincipledMaterial {
                                            baseColor: "#26241f"; roughness: 0.7 }
                                    }
                                }
                                Model {  // the CAP — a segment-meter
                                    // reading edge: ember-lit when armed,
                                    // banked at rest (tachometer language)
                                    source: "#Cube"
                                    visible: parent.f > 0.05
                                    position: Qt.vector3d(-28 + index * 14, -29 + parent.h + 0.9, 0)
                                    scale: Qt.vector3d(0.104, 0.018, 0.144)
                                    materials: PrincipledMaterial {
                                        baseColor: "#6e6455"
                                        metalness: 0.4; roughness: 0.45
                                        emissiveFactor: st3.running
                                            ? Qt.vector3d(0.60, 0.33, 0.14)
                                            : Qt.vector3d(0.12, 0.06, 0.02)
                                        Behavior on emissiveFactor {
                                            Vector3dAnimation { duration: 750; easing.type: Easing.InOutCubic } }
                                    }
                                }
                            }
                        }
                        Node {  // the TREND — an ember light-path over the
                            // tops; idles banked like the globe's cities
                            Repeater3D {
                                model: st3.seg
                                Model {
                                    source: "#Cylinder"
                                    position: Qt.vector3d(modelData.mx, modelData.my, 8)
                                    scale: Qt.vector3d(0.022, modelData.len / 100, 0.022)
                                    eulerRotation.z: modelData.ang - 90
                                    opacity: Math.min(1, Math.max(0, (st3.grow - 0.5 - index * 0.09) / 0.14))
                                    materials: PrincipledMaterial {
                                        baseColor: "#2a1f18"
                                        emissiveFactor: st3.running
                                            ? Qt.vector3d(0.95, 0.52, 0.24)
                                            : Qt.vector3d(0.34, 0.18, 0.08)
                                        Behavior on emissiveFactor {
                                            Vector3dAnimation { duration: 750; easing.type: Easing.InOutCubic } }
                                    }
                                }
                            }
                            Model {  // arrowhead — pops as the path completes
                                source: "#Cone"
                                position: Qt.vector3d(st3.tip.x, st3.tip.y, 8)
                                scale: Qt.vector3d(0.068, 0.082, 0.068)
                                eulerRotation.z: st3.tip.ang - 90
                                opacity: st3.grow > 0.97 ? 1 : 0
                                Behavior on opacity { NumberAnimation { duration: 140 } }
                                materials: PrincipledMaterial {
                                    baseColor: "#2a1f18"
                                    emissiveFactor: st3.running
                                        ? Qt.vector3d(0.95, 0.52, 0.24)
                                        : Qt.vector3d(0.34, 0.18, 0.08)
                                    Behavior on emissiveFactor {
                                        Vector3dAnimation { duration: 750; easing.type: Easing.InOutCubic } }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // TV foot, the DEFAULT — the RetroTV drawing's full-3D successor and
    // the globe's true sibling: a real monitor standing on the family's
    // turntable stage (AC-garage language). Hard PS1 boxwork shell, rear
    // tube hump, and a genuinely CURVED squashed-sphere tube running the
    // proven codec-band glass shader — beam + phosphor persistence,
    // scanlines, vignette, true static snow, one-shot v-hold — with the
    // terminal readout rendered offscreen and mapped onto the cap, and
    // real specular light moving on the glass. Selection is LIGHT, the
    // globe's own grammar: idle parks the key behind-left (rim-lit
    // silhouette, orange standby lamp, ghost readout); arming swings it
    // round in the same 750ms sweep while the set powers on — static
    // catch, v-hold lock, type-in — then the stage sways at cruise.
    // The 2D original lives on in the icon-debug pool as "crt-2d".
    component Tv3D: Item {
        id: t3
        property color color: "white"   // pool-interface parity (light does the tinting here)
        property bool running: false
        property real flick: 0
        property real roll: 0
        property real scanv: 0
        property real swy: 0
        property real ink: 0
        onRunningChanged: {
            if (running) { t3PowerOn.restart(); t3Ink.restart() }
            else { t3PowerOn.stop(); t3Ink.stop(); flick = 0; roll = 0; swy = 0; ink = 0 }
        }
        NumberAnimation {
            id: t3Ink
            target: t3; property: "ink"
            from: 0; to: 1; duration: 420; easing.type: Easing.OutQuad
        }
        ParallelAnimation {
            id: t3PowerOn
            // v-hold: the frame slips one full turn and locks while the
            // deflection settles the image up to size
            NumberAnimation {
                target: t3; property: "roll"
                from: 1; to: 0; duration: 300; easing.type: Easing.OutQuad
            }
            SequentialAnimation {  // tube stutter — instant level jumps
                PropertyAction { target: t3; property: "flick"; value: 0.30 }
                PauseAnimation { duration: 80 }
                PropertyAction { target: t3; property: "flick"; value: -0.02 }
                PauseAnimation { duration: 60 }
                PropertyAction { target: t3; property: "flick"; value: 0.14 }
                PauseAnimation { duration: 70 }
                PropertyAction { target: t3; property: "flick"; value: 0.06 }
                PauseAnimation { duration: 60 }
                PropertyAction { target: t3; property: "flick"; value: 0 }
            }
        }
        SequentialAnimation on flick {  // rare signal hiccup — real snow is
            // dramatic, so it earns PS1 rarity; visible-gated like scanv
            running: t3.running && t3.visible
            loops: Animation.Infinite
            PauseAnimation { duration: 6800 }
            PropertyAction { value: 0.20 }
            PauseAnimation { duration: 70 }
            PropertyAction { value: -0.04 }
            PauseAnimation { duration: 50 }
            PropertyAction { value: 0.16 }
            PauseAnimation { duration: 60 }
            PropertyAction { value: 0 }
        }
        NumberAnimation on scanv {
            id: t3Scan
            running: t3.running && t3.visible
            from: 0; to: 1; duration: 2600
            loops: Animation.Infinite
        }
        SequentialAnimation on swy {  // stage sway at cruise — equipment
            // presented, not frozen
            running: t3.running && t3.visible
            loops: Animation.Infinite
            NumberAnimation { to: 6; duration: 3200; easing.type: Easing.InOutSine }
            NumberAnimation { to: 0; duration: 3200; easing.type: Easing.InOutSine }
        }
        Loader {  // globe-pattern deferral: 3D stays off the launch path;
            // only the slot that SHOWS this icon ever stands up the scene
            id: t3Loader
            anchors.fill: parent
            asynchronous: true
            property bool armed: false
            // stays loaded while HOME is merely hidden (another stage is up): unloading
            // on every stage change rebuilt the 3D scene → a 100–300 ms hitch on return
            active: armed && (t3.visible || (item !== null && App.stage !== "home"))
            opacity: status === Loader.Ready ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 320 } }
            Timer { interval: 640; running: true; onTriggered: t3Loader.armed = true }
            sourceComponent: View3D {
                id: tv3d
                anchors.fill: parent
                environment: SceneEnvironment {
                    backgroundMode: SceneEnvironment.Transparent
                    antialiasingMode: SceneEnvironment.MSAA
                    antialiasingQuality: SceneEnvironment.High
                }
                OrthographicCamera {
                    z: 300
                    // FAMILY FRAMING LAW — globe is the anchor (disc 83% of
                    // box). A solid box of equal optical weight runs ~75%,
                    // so the set sees 101 world units, not 85
                    horizontalMagnification: tv3d.width / 101
                    verticalMagnification: tv3d.width / 101
                }
                DirectionalLight {  // the KEY — position still swings on
                    // selection to model the form, but brightness barely
                    // moves and the colour is NEUTRAL: every "overglow"
                    // was warm key light igniting the hardware and stage
                    // around the set. The SCREEN is the selection state.
                    eulerRotation.x: -18
                    eulerRotation.y: t3.running ? -32 : -142
                    brightness: t3.running ? 0.95 : 0.9
                    color: "#e8e6e0"
                    Behavior on eulerRotation.y {
                        NumberAnimation { duration: 750; easing.type: Easing.InOutCubic } }
                    Behavior on brightness {
                        NumberAnimation { duration: 750; easing.type: Easing.InOutCubic } }
                }
                DirectionalLight {  // cool fill — dark is dim, not void
                    eulerRotation.y: 132
                    eulerRotation.x: -8
                    brightness: t3.running ? 0.20 : 0.30
                    color: "#93b7c6"
                    Behavior on brightness {
                        NumberAnimation { duration: 750; easing.type: Easing.InOutCubic } }
                }
                DirectionalLight {  // the RIM — armed-only edge outline
                    // from behind-left: dark hardware must separate from
                    // the dark slot the cel way (a drawn edge), not by
                    // washing the body in key light
                    eulerRotation.y: 158
                    eulerRotation.x: -20
                    brightness: t3.running ? 1.1 : 0
                    color: "#cdd6de"
                    Behavior on brightness {
                        NumberAnimation { duration: 750; easing.type: Easing.InOutCubic } }
                }
                Node {
                    eulerRotation.x: -8   // a hair of look-down at the desk
                    y: -8   // seats the stage on the family floor line
                    Node {
                        id: t3Table
                        eulerRotation.y: -10 + t3.swy
                        Model {  // the STAGE — the family's turntable disc
                            source: "#Cylinder"
                            scale: Qt.vector3d(0.63, 0.016, 0.63)
                            position: Qt.vector3d(0, -33.8, 0)
                            materials: PrincipledMaterial {
                                baseColor: "#141317"; roughness: 0.8; metalness: 0.0 }
                        }
                        Model {  // contact shadow — the set SITS, not floats
                            source: "#Sphere"
                            scale: Qt.vector3d(0.40, 0.005, 0.30)
                            position: Qt.vector3d(0, -32.8, 1)
                            opacity: 0.45
                            materials: PrincipledMaterial {
                                baseColor: "#000000"
                                lighting: PrincipledMaterial.NoLighting }
                        }
                        Model {  // shell — DARK boxwork, family steel; the
                            // light lives on the frame, not the body
                            source: "#Cube"
                            scale: Qt.vector3d(0.76, 0.64, 0.30)
                            position: Qt.vector3d(0, 6, 0)
                            materials: PrincipledMaterial {
                                baseColor: "#383c43"; roughness: 0.62 }
                        }
                        Model {  // rear tube hump — CRT anatomy in profile
                            source: "#Cube"
                            scale: Qt.vector3d(0.56, 0.46, 0.14)
                            position: Qt.vector3d(0, 6, -20)
                            materials: PrincipledMaterial {
                                baseColor: "#31343a"; roughness: 0.7 }
                        }
                        Model {  // the TUBE — curved glass; the bezel
                            // frame below crops it to a CRT-square window
                            source: "#Sphere"
                            scale: Qt.vector3d(0.76, 0.64, 0.10)
                            position: Qt.vector3d(0, 8, 12)
                            materials: CustomMaterial {
                                shadingMode: CustomMaterial.Shaded
                                vertexShader: "qrc:/assets/foot3d/crt.vert"
                                fragmentShader: "qrc:/assets/foot3d/crt.frag"
                                property color tint: "#c6d3ca"
                                property real bed: (t3.running ? 0.05 : 0.02) + (t3.running ? t3.flick : 0)
                                property real lit: t3.running ? 1 : 0
                                Behavior on lit { NumberAnimation { duration: 150 } }
                                property real scan: t3.scanv
                                property real roll: t3.roll
                                property real snow: t3.running ? 0.045 + Math.max(0, t3.flick) : 0
                            }
                        }
                        Model {  // bezel frame, top — the LIGHT element,
                            // the 2D original's bright stroke reborn
                            source: "#Cube"
                            scale: Qt.vector3d(0.76, 0.10, 0.02)
                            position: Qt.vector3d(0, 33, 15.9)
                            materials: PrincipledMaterial {
                                baseColor: "#1b1a1d"; roughness: 0.85 }
                        }
                        Model {  // bezel frame, bottom — carries controls
                            source: "#Cube"
                            scale: Qt.vector3d(0.76, 0.14, 0.02)
                            position: Qt.vector3d(0, -19, 15.9)
                            materials: PrincipledMaterial {
                                baseColor: "#1b1a1d"; roughness: 0.85 }
                        }
                        Model {  // bezel frame, left
                            source: "#Cube"
                            scale: Qt.vector3d(0.10, 0.64, 0.02)
                            position: Qt.vector3d(-33, 6, 15.9)
                            materials: PrincipledMaterial {
                                baseColor: "#1b1a1d"; roughness: 0.85 }
                        }
                        Model {  // bezel frame, right
                            source: "#Cube"
                            scale: Qt.vector3d(0.10, 0.64, 0.02)
                            position: Qt.vector3d(33, 6, 15.9)
                            materials: PrincipledMaterial {
                                baseColor: "#1b1a1d"; roughness: 0.85 }
                        }
                        Model {  // cel outline, DIM BASE — unlit line art
                            // holding a whisper of contour at all times
                            source: "#Cube"
                            scale: Qt.vector3d(0.765, 0.011, 0.011)
                            position: Qt.vector3d(0, 37.8, 15.2)
                            materials: PrincipledMaterial {
                                lighting: PrincipledMaterial.NoLighting
                                baseColor: "#4a4e56" }
                        }
                        Model {
                            source: "#Cube"
                            scale: Qt.vector3d(0.011, 0.65, 0.011)
                            position: Qt.vector3d(37.8, 6, 15.2)
                            materials: PrincipledMaterial {
                                lighting: PrincipledMaterial.NoLighting
                                baseColor: "#42464e" }
                        }
                        Model {
                            source: "#Cube"
                            scale: Qt.vector3d(0.011, 0.65, 0.011)
                            position: Qt.vector3d(-37.8, 6, 15.2)
                            materials: PrincipledMaterial {
                                lighting: PrincipledMaterial.NoLighting
                                baseColor: "#42464e" }
                        }
                        Model {
                            source: "#Cube"
                            scale: Qt.vector3d(0.765, 0.011, 0.011)
                            position: Qt.vector3d(0, -25.8, 15.2)
                            materials: PrincipledMaterial {
                                lighting: PrincipledMaterial.NoLighting
                                baseColor: "#3e424a" }
                        }
                        Model {
                            source: "#Cube"
                            scale: Qt.vector3d(0.011, 0.65, 0.011)
                            position: Qt.vector3d(37.8, 6, -14.8)
                            materials: PrincipledMaterial {
                                lighting: PrincipledMaterial.NoLighting
                                baseColor: "#34383e" }
                        }
                        Node {  // the BRIGHT stroke — INKS itself around
                            // the face on arm: top draws centre-out (the
                            // wheel's charging language), the sides run
                            // down, the bottom closes the frame; fades
                            // away on deselect
                            opacity: t3.running ? 1 : 0
                            Behavior on opacity { NumberAnimation { duration: 220 } }
                            readonly property real tTop: Math.min(1, t3.ink / 0.4)
                            readonly property real tSide: Math.min(1, Math.max(0, (t3.ink - 0.3) / 0.4))
                            readonly property real tBot: Math.min(1, Math.max(0, (t3.ink - 0.65) / 0.35))
                            Model {
                                source: "#Cube"
                                scale: Qt.vector3d(0.765 * parent.tTop, 0.012, 0.012)
                                position: Qt.vector3d(0, 37.8, 15.3)
                                materials: PrincipledMaterial {
                                    lighting: PrincipledMaterial.NoLighting
                                    baseColor: "#9aa0aa" }
                            }
                            Model {
                                source: "#Cube"
                                scale: Qt.vector3d(0.012, 0.65 * parent.tSide, 0.012)
                                position: Qt.vector3d(37.8, 38.5 - 32.5 * parent.tSide, 15.3)
                                materials: PrincipledMaterial {
                                    lighting: PrincipledMaterial.NoLighting
                                    baseColor: "#868c96" }
                            }
                            Model {
                                source: "#Cube"
                                scale: Qt.vector3d(0.012, 0.65 * parent.tSide, 0.012)
                                position: Qt.vector3d(-37.8, 38.5 - 32.5 * parent.tSide, 15.3)
                                materials: PrincipledMaterial {
                                    lighting: PrincipledMaterial.NoLighting
                                    baseColor: "#868c96" }
                            }
                            Model {
                                source: "#Cube"
                                scale: Qt.vector3d(0.765 * parent.tBot, 0.012, 0.012)
                                position: Qt.vector3d(0, -25.8, 15.3)
                                materials: PrincipledMaterial {
                                    lighting: PrincipledMaterial.NoLighting
                                    baseColor: "#767c86" }
                            }
                            Model {
                                source: "#Cube"
                                scale: Qt.vector3d(0.012, 0.65 * parent.tSide, 0.012)
                                position: Qt.vector3d(37.8, 38.5 - 32.5 * parent.tSide, -14.8)
                                materials: PrincipledMaterial {
                                    lighting: PrincipledMaterial.NoLighting
                                    baseColor: "#5f656f" }
                            }
                        }
                        Repeater3D {  // top-face vent grooves — the heat
                            // has to leave a real monitor somewhere
                            model: 4
                            Model {
                                source: "#Cube"
                                scale: Qt.vector3d(0.44, 0.006, 0.014)
                                position: Qt.vector3d(0, 38.2, -8 + index * 5)
                                materials: PrincipledMaterial {
                                    baseColor: "#1a191c"; roughness: 0.8 }
                            }
                        }
                        Repeater3D {  // tube-module seam — the dark inset
                            // line where the screen assembly seats
                            model: 4
                            Model {
                                source: "#Cube"
                                scale: index < 2 ? Qt.vector3d(0.60, 0.008, 0.004)
                                                 : Qt.vector3d(0.008, 0.43, 0.004)
                                position: index === 0 ? Qt.vector3d(0, 28.8, 16.5)
                                          : index === 1 ? Qt.vector3d(0, -12.8, 16.5)
                                          : index === 2 ? Qt.vector3d(-28.8, 8, 16.5)
                                          : Qt.vector3d(28.8, 8, 16.5)
                                materials: PrincipledMaterial {
                                    baseColor: "#101014"; roughness: 0.85 }
                            }
                        }
                        Model {  // badge plate — the nameplate's slot
                            source: "#Cube"
                            scale: Qt.vector3d(0.09, 0.02, 0.008)
                            position: Qt.vector3d(18, -19, 17.05)
                            materials: PrincipledMaterial {
                                baseColor: "#4f5058"; roughness: 0.5 }
                        }
                        Repeater3D {  // grille slots — the TV's front
                            // vents where indicators would be; the XV17+
                            // lights NOTHING but its standby lamp
                            model: 6
                            Model {
                                source: "#Cube"
                                scale: Qt.vector3d(0.008, 0.05, 0.008)
                                position: Qt.vector3d(-30 + index * 3, -19, 17.0)
                                materials: PrincipledMaterial {
                                    baseColor: "#17161a"; roughness: 0.85 }
                            }
                        }
                        Repeater3D {  // bezel button row
                            model: 4
                            Model {
                                source: "#Cube"
                                scale: Qt.vector3d(0.034, 0.015, 0.012)
                                position: Qt.vector3d(-7 + index * 5.2, -19, 17.1)
                                materials: PrincipledMaterial {
                                    baseColor: "#3f434a"; roughness: 0.5 }
                            }
                        }
                        Model {  // power LED — green ON, orange STANDBY
                            // (the XV17+ truth: nothing else on it lights).
                            // Sized to be SEEN at 46px: the standby lamp is
                            // the icon's one warm accent, not a rumour
                            source: "#Sphere"
                            scale: Qt.vector3d(0.034, 0.034, 0.034)
                            position: Qt.vector3d(30, -19, 17.2)
                            materials: PrincipledMaterial {
                                lighting: PrincipledMaterial.NoLighting
                                baseColor: t3.running ? "#8fe3a1" : "#f09a4e" }
                        }
                        Model {  // neck
                            source: "#Cylinder"
                            scale: Qt.vector3d(0.16, 0.05, 0.16)
                            position: Qt.vector3d(0, -28, -2)
                            materials: PrincipledMaterial {
                                baseColor: "#26282c"; roughness: 0.75 }
                        }
                        Model {  // tilt plate — the two-tier swivel truth
                            source: "#Cube"
                            scale: Qt.vector3d(0.30, 0.05, 0.22)
                            position: Qt.vector3d(0, -30, 0)
                            materials: PrincipledMaterial {
                                baseColor: "#292c30"; roughness: 0.7 }
                        }
                        Model {  // swivel seam — plate turns on foot
                            source: "#Cube"
                            scale: Qt.vector3d(0.30, 0.006, 0.21)
                            position: Qt.vector3d(0, -31.7, 1)
                            materials: PrincipledMaterial {
                                baseColor: "#151518"; roughness: 0.85 }
                        }
                        Model {  // swivel foot — broad, monitor-stand truth
                            source: "#Cube"
                            scale: Qt.vector3d(0.50, 0.045, 0.32)
                            position: Qt.vector3d(0, -32, 2)
                            materials: PrincipledMaterial {
                                baseColor: "#2c2f33"; roughness: 0.7 }
                        }
                    }
                }
            }
        }
    }

    // YOUTUBE glyph — the REFERENCE beam-satellite (game-icons path),
    // rendered whole and untouched, with two integral motions layered on:
    // a ghost wavefront detaches from under the dish and rides the beam
    // down to the planet — an ∩-arc matching the icon's own wave, narrowing
    // as the beam narrows — and the icon's ground-station dome (its own
    // subpath) FLASHES as the wave lands. Cause, travel, effect. At rest
    // both layers are gone: pixel-identical to the reference.
    component BeamSatellite: Item {
        id: bsat
        property color color: "white"
        property var icon
        property bool running: false
        // normalisation for the CRAFT's own bbox [25, 25, 462, 344] —
        // bars to antenna tip, recentred now the ground element is gone
        readonly property real k: width * 0.94 / 462
        readonly property real kx: width / 2 - k * 256
        readonly property real ky: height / 2 - k * 197
        // Burst pacing: four blips ride the beam, the dome acknowledges,
        // then a beat of radio silence before the next burst — transmission
        // in phrases, not an endless stream. gp holds at 1 during the rest
        // (the ghost gates itself off there).
        property real gp: 0
        // the ACK: after each DELIVERED burst, one crumb of light climbs
        // home up the spine — the handshake. The dropped burst sends none.
        property real akt: 0
        // station-keeping DRIFT: the whole craft rolls ±0.4° very slowly —
        // nothing in orbit holds perfectly still
        property real att: 0
        rotation: att
        // the wave field fades up over the first second after arm
        property real armT: 0
        onRunningChanged: {
            if (!running) { gp = 0; akt = 0; wingL.sway = 0; wingR.sway = 0; att = 0; armT = 0 }
            else { satWink.restart(); satArmT.restart() }
        }
        SequentialAnimation on att {
            running: bsat.running
            loops: Animation.Infinite
            NumberAnimation { to: 0.4; duration: 7000; easing.type: Easing.InOutSine }
            NumberAnimation { to: -0.4; duration: 7600; easing.type: Easing.InOutSine }
        }
        SequentialAnimation {  // arm acknowledgment — ONE soft wink, PS1
            id: satWink
            PropertyAction { target: bsat; property: "opacity"; value: 0.72 }
            PauseAnimation { duration: 80 }
            PropertyAction { target: bsat; property: "opacity"; value: 1 }
        }
        NumberAnimation {
            id: satArmT
            target: bsat; property: "armT"
            from: 0; to: 1; duration: 900
        }
        // alternating rests — a short breath, then a long one — so the
        // transmission phrase never reads as a metronome
        SequentialAnimation {
            running: bsat.running
            loops: Animation.Infinite
            NumberAnimation { target: bsat; property: "gp"; from: 0; to: 1; duration: 1400 }
            NumberAnimation { target: bsat; property: "akt"; from: 0; to: 1; duration: 320; easing.type: Easing.OutQuad }
            PauseAnimation { duration: 130 }
            NumberAnimation { target: bsat; property: "gp"; from: 0; to: 1; duration: 1400 }
            NumberAnimation { target: bsat; property: "akt"; from: 0; to: 1; duration: 320; easing.type: Easing.OutQuad }
            PauseAnimation { duration: 730 }
            NumberAnimation { target: bsat; property: "gp"; from: 0; to: 0.6; duration: 840 }
            PropertyAction { target: bsat; property: "gp"; value: 1 }  // the packet DIES — nothing freezes mid-beam
            PauseAnimation { duration: 780 }   // the dropped burst: silence
        }
        Repeater {  // backdrop stars — three pinpricks seat the craft in
            // open space; one breathes
            model: [[0.07, 0.10, 0.20], [0.93, 0.16, 0.14], [0.20, 0.05, 0.13]]
            Rectangle {
                x: modelData[0] * bsat.width; y: modelData[1] * bsat.height
                width: Math.max(1.5, bsat.width * 0.022); height: width; radius: width / 2
                color: Theme.withAlpha(Theme.fg, modelData[2])
                SequentialAnimation on opacity {
                    running: bsat.running && index === 1
                    loops: Animation.Infinite
                    NumberAnimation { from: 1; to: 0.3; duration: 2600; easing.type: Easing.InOutSine }
                    NumberAnimation { from: 0.3; to: 1; duration: 3000; easing.type: Easing.InOutSine }
                }
            }
        }
        Shape {  // the reference icon minus its ground terrain — satellite,
            // dashes, dish, beam and antenna tip, all steady. Multisampled
            // for the dish and dome curves.
            width: 512; height: 512
            antialiasing: true
            layer.enabled: true
            layer.samples: 4
            layer.smooth: true
            transform: Matrix4x4 { matrix: Qt.matrix4x4(bsat.k, 0, 0, bsat.kx, 0, bsat.k, 0, bsat.ky, 0, 0, 1, 0, 0, 0, 0, 1) }
            ShapePath {
                fillColor: bsat.color; strokeWidth: 0
                fillRule: ShapePath.OddEvenFill
                PathSvg { path: "M137.0 25.0v14.004h37.184l-4.668-14.004h-32.516z M342.5 25.0l-4.668 14.004h37.184V24.998h-32.516z M137.0 57.0v30.004H215.002V72.998h-29.488l-5.334-16h-43.182z M233.0 57.0v59.326l-34.15 27.32c16.813-5.416 35.96-8.642 57.152-8.642s40.34 3.226 57.152 8.643l-34.15-27.32V56.997h-46.004z M331.8 57.0l-5.334 16h-29.488v14.004h78.004V56.998H331.82z M137.0 105.0v14.004h17.44l7.001-14.004H137z M350.6 105.0l7.002 14.004h17.439v-14.004h-24.441z M256.0 153.0c-38.2 0-68.333 11.462-88.707 26.28-18.004 13.093-27.816 28.97-29.861 40.427 6.887 4.562 21.771 10.067 41.109 13.43 14.42 2.508 31.078 4.214 48.502 5.115l-4.143-30.379c-10.514 1.898-19.878 4.68-26.875 8.178l-8.05-16.098c18.146-9.073 43.025-12.95 68.025-12.95 25 0 49.879 3.877 68.025 12.95l-8.05 16.098c-6.997-3.499-16.36-6.28-26.875-8.178l-4.143 30.379c17.424-.901 34.082-2.607 48.502-5.115 19.338-3.363 34.222-8.868 41.11-13.43-2.046-11.457-11.858-27.334-29.862-40.428C324.333 164.46 294.2 152.998 256 152.998z M256.0 205.0c-4.197 0-8.935 1.891-14.436 6.543L256 317.398l14.436-105.857c-5.501-4.652-10.24-6.543-14.436-6.543z M256.0 339.0c-7.013 0-13.195 2.206-17.229 5.23-4.033 3.025-5.773 6.387-5.773 9.772 0 3.385 1.74 6.747 5.773 9.771 4.034 3.025 10.216 5.231 17.229 5.231s13.195-2.206 17.229-5.23c4.033-3.025 5.773-6.387 5.773-9.772 0-3.385-1.74-6.747-5.773-9.771-4.034-3.025-10.216-5.231-17.229-5.231z" }
            }
        }
        Item {  // LEFT solar wing — the icon's own array bars on their
            // own layer, FLEXING about the hinge: the slow sun-tracking
            // sway a real satellite's wings carry. Rest angle 0 = reference.
            id: wingL
            anchors.fill: parent
            property real sway: 0
            transform: Rotation {
                origin.x: bsat.k * 119 + bsat.kx
                origin.y: bsat.k * 72 + bsat.ky
                angle: wingL.sway
            }
            SequentialAnimation on sway {
                running: bsat.running
                loops: Animation.Infinite
                // sun-side dwell: further toward the light, quicker back —
                // and unequal legs so the flex never metronomes
                NumberAnimation { to: 1.4; duration: 2600; easing.type: Easing.InOutSine }
                NumberAnimation { to: -1.1; duration: 2900; easing.type: Easing.InOutSine }
            }
            Shape {
                width: 512; height: 512
                antialiasing: true
                transform: Matrix4x4 { matrix: Qt.matrix4x4(bsat.k, 0, 0, bsat.kx, 0, bsat.k, 0, bsat.ky, 0, 0, 1, 0, 0, 0, 0, 1) }
                ShapePath {
                    fillColor: bsat.color; strokeWidth: 0
                    PathSvg { path: "M25.0 25.0v14.004h30.004V24.998H24.998z M73.0 25.0v14.004h46.004V24.998H72.998z M25.0 57.0v30.004h30.004V56.998H24.998z M73.0 57.0v30.004h46.004V56.998H72.998z M25.0 105.0v14.004h30.004v-14.004H24.998z M73.0 105.0v14.004h46.004v-14.004H72.998z" }
                }
            }
            // SOLAR RIPPLE — light rolls across the array cell by cell,
            // top row first, outer column leading: the sun tracking the
            // panels as the wing flexes. Own clock, long quiet between.
            property real rip: 0
            NumberAnimation on rip {
                running: bsat.running
                loops: Animation.Infinite
                from: 0; to: 1; duration: 4300
            }
            Repeater {
                model: [[25, 25, 30, 14, 0, 0], [73, 25, 46, 14, 0, 1],
                        [25, 57, 30, 30, 1, 0], [73, 57, 46, 30, 1, 1],
                        [25, 105, 30, 14, 2, 0], [73, 105, 46, 14, 2, 1]]
                Rectangle {
                    readonly property real d: 0.08 + modelData[4] * 0.09 + modelData[5] * 0.045
                    visible: bsat.running && wingL.rip > d && wingL.rip < d + 0.11
                    x: bsat.k * modelData[0] + bsat.kx
                    y: bsat.k * modelData[1] + bsat.ky
                    width: bsat.k * modelData[2]; height: bsat.k * modelData[3]
                    color: Theme.withAlpha(Theme.fg, 0.28)
                }
            }
            Shape {  // sun catch — the array glints as it dwells at the
                // light-side extreme: two frames of specular, cel-hard
                visible: wingL.sway > 1.25
                width: 512; height: 512
                antialiasing: true
                transform: Matrix4x4 { matrix: Qt.matrix4x4(bsat.k, 0, 0, bsat.kx, 0, bsat.k, 0, bsat.ky, 0, 0, 1, 0, 0, 0, 0, 1) }
                ShapePath {
                    fillColor: Theme.withAlpha(Theme.fg, 0.25); strokeWidth: 0
                    PathSvg { path: "M25.0 25.0v14.004h30.004V24.998H24.998z M73.0 25.0v14.004h46.004V24.998H72.998z M25.0 57.0v30.004h30.004V56.998H24.998z M73.0 57.0v30.004h46.004V56.998H72.998z M25.0 105.0v14.004h30.004v-14.004H24.998z M73.0 105.0v14.004h46.004v-14.004H72.998z" }
                }
            }
            Item {  // PORT lamp — RED, MOUNTED: a housing nub the light
                // visibly comes from, its glow spilling onto the array
                readonly property bool on: bsat.running && satBeacon.bph > 0.22 && satBeacon.bph < 0.255
                x: bsat.k * 30 + bsat.kx; y: bsat.k * 72 + bsat.ky
                Rectangle {  // the housing — craft anatomy, always present
                    x: -width / 2; y: -height / 2
                    width: Math.max(2, bsat.k * 10); height: width; radius: width / 3
                    color: Theme.withAlpha(bsat.color, 0.75)
                }
                Rectangle {  // the glow's SPILL along the wing bar
                    visible: parent.on
                    x: -width / 2; y: -height / 2
                    width: Math.max(9, bsat.k * 46); height: Math.max(3, bsat.k * 15)
                    radius: height / 2
                    color: Theme.withAlpha("#ff4a3d", 0.13)
                }
                Rectangle {
                    visible: parent.on
                    x: -width / 2; y: -height / 2
                    width: Math.max(5, bsat.k * 26); height: width; radius: width / 2
                    color: Theme.withAlpha("#ff4a3d", 0.22)
                }
                Rectangle {
                    visible: parent.on
                    x: -width / 2; y: -height / 2
                    width: Math.max(2.5, bsat.k * 13); height: width; radius: width / 2
                    color: "#ff4a3d"
                }
                Rectangle {  // ignition — the filament's white first frame
                    visible: bsat.running && satBeacon.bph > 0.22 && satBeacon.bph < 0.2295
                    x: -width / 2; y: -height / 2
                    width: Math.max(1.5, bsat.k * 6); height: width; radius: width / 2
                    color: "#ffffff"; opacity: 0.9
                }
            }
        }
        Item {  // RIGHT solar wing — same flex, a beat behind: the wave
            // travelling through the truss
            id: wingR
            anchors.fill: parent
            property real sway: 0
            transform: Rotation {
                origin.x: bsat.k * 393 + bsat.kx
                origin.y: bsat.k * 72 + bsat.ky
                angle: wingR.sway
            }
            SequentialAnimation on sway {
                running: bsat.running
                loops: Animation.Infinite
                // no pause: the lag against the port wing comes from the
                // longer legs, so the phase drifts organically forever
                NumberAnimation { to: 1.4; duration: 2750; easing.type: Easing.InOutSine }
                NumberAnimation { to: -1.1; duration: 3080; easing.type: Easing.InOutSine }
            }
            Shape {
                width: 512; height: 512
                antialiasing: true
                transform: Matrix4x4 { matrix: Qt.matrix4x4(bsat.k, 0, 0, bsat.kx, 0, bsat.k, 0, bsat.ky, 0, 0, 1, 0, 0, 0, 0, 1) }
                ShapePath {
                    fillColor: bsat.color; strokeWidth: 0
                    PathSvg { path: "M393.0 25.0v14.004h46.004V24.998h-46.004z M457.0 25.0v14.004h30.004V24.998h-30.004z M393.0 57.0v30.004h46.004V56.998h-46.004z M457.0 57.0v30.004h30.004V56.998h-30.004z M393.0 105.0v14.004h46.004v-14.004h-46.004z M457.0 105.0v14.004h30.004v-14.004h-30.004z" }
                }
            }
            property real rip: 0
            NumberAnimation on rip {
                running: bsat.running
                loops: Animation.Infinite
                from: 0; to: 1; duration: 4900
            }
            Repeater {
                model: [[457, 25, 30, 14, 0, 0], [393, 25, 46, 14, 0, 1],
                        [457, 57, 30, 30, 1, 0], [393, 57, 46, 30, 1, 1],
                        [457, 105, 30, 14, 2, 0], [393, 105, 46, 14, 2, 1]]
                Rectangle {
                    readonly property real d: 0.08 + modelData[4] * 0.09 + modelData[5] * 0.045
                    visible: bsat.running && wingR.rip > d && wingR.rip < d + 0.11
                    x: bsat.k * modelData[0] + bsat.kx
                    y: bsat.k * modelData[1] + bsat.ky
                    width: bsat.k * modelData[2]; height: bsat.k * modelData[3]
                    color: Theme.withAlpha(Theme.fg, 0.28)
                }
            }
            Shape {  // sun catch, starboard array — lags the port side
                visible: wingR.sway > 1.25
                width: 512; height: 512
                antialiasing: true
                transform: Matrix4x4 { matrix: Qt.matrix4x4(bsat.k, 0, 0, bsat.kx, 0, bsat.k, 0, bsat.ky, 0, 0, 1, 0, 0, 0, 0, 1) }
                ShapePath {
                    fillColor: Theme.withAlpha(Theme.fg, 0.25); strokeWidth: 0
                    PathSvg { path: "M393.0 25.0v14.004h46.004V24.998h-46.004z M457.0 25.0v14.004h30.004V24.998h-30.004z M393.0 57.0v30.004h46.004V56.998h-46.004z M457.0 57.0v30.004h30.004V56.998h-30.004z M393.0 105.0v14.004h46.004v-14.004h-46.004z M457.0 105.0v14.004h30.004v-14.004h-30.004z" }
                }
            }
            Item {  // STARBOARD lamp — GREEN, mounted the same way
                readonly property bool on: bsat.running && satBeacon.bph > 0.31 && satBeacon.bph < 0.345
                x: bsat.k * 482 + bsat.kx; y: bsat.k * 72 + bsat.ky
                Rectangle {  // housing
                    x: -width / 2; y: -height / 2
                    width: Math.max(2, bsat.k * 10); height: width; radius: width / 3
                    color: Theme.withAlpha(bsat.color, 0.75)
                }
                Rectangle {  // spill along the bar
                    visible: parent.on
                    x: -width / 2; y: -height / 2
                    width: Math.max(9, bsat.k * 46); height: Math.max(3, bsat.k * 15)
                    radius: height / 2
                    color: Theme.withAlpha("#3fd45c", 0.13)
                }
                Rectangle {
                    visible: parent.on
                    x: -width / 2; y: -height / 2
                    width: Math.max(5, bsat.k * 26); height: width; radius: width / 2
                    color: Theme.withAlpha("#3fd45c", 0.22)
                }
                Rectangle {
                    visible: parent.on
                    x: -width / 2; y: -height / 2
                    width: Math.max(2.5, bsat.k * 13); height: width; radius: width / 2
                    color: "#3fd45c"
                }
                Rectangle {  // ignition
                    visible: bsat.running && satBeacon.bph > 0.31 && satBeacon.bph < 0.3195
                    x: -width / 2; y: -height / 2
                    width: Math.max(1.5, bsat.k * 6); height: width; radius: width / 2
                    color: "#ffffff"; opacity: 0.9
                }
            }
        }
        Rectangle {  // port hinge pin — the punched pivot the wing swings on
            x: bsat.k * 115.5 + bsat.kx; y: bsat.k * 68.5 + bsat.ky
            width: bsat.k * 7; height: bsat.k * 7; radius: width / 2
            color: Theme.withAlpha(Theme.bg, 0.55)
        }
        Rectangle {  // starboard hinge pin
            x: bsat.k * 389.5 + bsat.kx; y: bsat.k * 68.5 + bsat.ky
            width: bsat.k * 7; height: bsat.k * 7; radius: width / 2
            color: Theme.withAlpha(Theme.bg, 0.55)
        }
        Shape {  // the ground TERRAIN — HIDDEN by request: the icon flies
            // without its ground element, just the craft, beam traffic and
            // nav lights. (The antenna-tip oval lives in the static layer,
            // so it stays.) Flip visible to bring the ground back.
            visible: false
            width: 512; height: 512
            antialiasing: true
            transform: Matrix4x4 { matrix: Qt.matrix4x4(bsat.k, 0, 0, bsat.kx, 0, bsat.k, 0, bsat.ky, 0, 0, 1, 0, 0, 0, 0, 1) }
            ShapePath {
                fillColor: bsat.color; strokeWidth: 0
                fillRule: ShapePath.OddEvenFill
                PathSvg { path: "M384.0 256.0l-106.389 36.121-4.35 31.893c3.926 1.454 7.553 3.406 10.766 5.816 7.549 5.661 12.971 14.3 12.971 24.17 0 9.87-5.422 18.509-12.97 24.17-7.55 5.661-17.368 8.828-28.028 8.828s-20.479-3.167-28.027-8.828c-7.549-5.661-12.971-14.3-12.971-24.17 0-9.87 5.422-18.509 12.97-24.17 3.214-2.41 6.841-4.362 10.766-5.816l-2.931-21.493-119.922-29.314 72.34 48.461-104.512 69.666 85.803-12.066-31.455 29.435s26.97-10.097 49.152-18.29l-43.22 86.41L224 416v78.002h9.805L242.283 432l9.862 45.33 8.88-69.373 17.073 86.045H288V416l96 48-45.477-67.885 92.71-18.26-87.262-30.023 26.695-21.9-53.23 3.214L384 256z" }
            }
        }
        Rectangle {  // beam spine — the energy path's visible hairline;
            // it BRIGHTENS while a burst is in the pipe, rests between
            x: bsat.width / 2 - width / 2
            y: bsat.k * 235 + bsat.ky
            width: Math.max(1, bsat.k * 5); height: bsat.k * 78
            color: bsat.color
            opacity: bsat.running && bsat.gp > 0.01 && bsat.gp < 0.99 ? 0.75 : 0.5
        }
        Rectangle {  // ACK received — the dish throat's soft answer as the
            // crumb arrives: send bright, receive soft
            visible: bsat.running && bsat.akt > 0.93 && bsat.akt < 0.995
            x: bsat.width / 2 - width / 2
            y: bsat.k * 208 + bsat.ky - height / 2
            width: bsat.k * 14; height: width; radius: width / 2
            color: Theme.withAlpha("#eef3ff", 0.4)
        }
        Rectangle {  // the ACK crumb — cool-white like the strobe, racing
            // home up the spine
            visible: bsat.running && bsat.akt > 0.02 && bsat.akt < 0.98
            x: bsat.width / 2 - width / 2
            y: bsat.k * (318 - bsat.akt * 88) + bsat.ky - height / 2
            width: Math.max(2.5, bsat.k * 9); height: width; radius: width / 2
            color: "#eef3ff"
            opacity: 0.85
        }
        Rectangle {  // antenna collar — the machined joint, pixel-floored
            // so the tip is CONNECTED at any icon size
            x: bsat.width / 2 - width / 2
            y: bsat.k * 306 + bsat.ky
            width: Math.max(2, bsat.k * 18); height: Math.max(1.5, bsat.k * 10)
            color: bsat.color
        }
        Rectangle {  // antenna mast — collar down INTO the tip oval, no gap
            x: bsat.width / 2 - width / 2
            y: bsat.k * 306 + bsat.ky
            width: Math.max(1.5, bsat.k * 10); height: bsat.k * 42
            color: bsat.color
        }
        Rectangle {  // dish-throat spark halo
            visible: bsat.running && bsat.gp > 0.001 && bsat.gp < 0.055
            x: bsat.width / 2 - width / 2
            y: bsat.k * 208 + bsat.ky - height / 2
            width: bsat.k * 30; height: width; radius: width / 2
            color: Theme.withAlpha(Theme.fg, 0.18)
        }
        Rectangle {  // dish-throat spark — a relay DOUBLE-tap as each
            // burst leaves the dish: two hard blinks, then the beam
            visible: bsat.running && bsat.gp > 0.001 && bsat.gp < 0.055
            x: bsat.width / 2 - width / 2
            y: bsat.k * 208 + bsat.ky - height / 2
            width: bsat.k * 14; height: width; radius: width / 2
            color: Theme.withAlpha(Theme.fg, 0.85)
        }
        Rectangle {  // collar bolt — the punched fastener on the joint
            x: bsat.width / 2 - width / 2; y: bsat.k * 309 + bsat.ky
            width: Math.max(1.5, bsat.k * 4); height: width; radius: width / 2
            color: Theme.withAlpha(Theme.bg, 0.5)
        }
        Shape {  // tip PRE-CHARGE — the horn draws down for two frames
            // just before it discharges: dim, then FLASH
            width: 512; height: 512
            antialiasing: true
            visible: bsat.running && bsat.gp > 0.895 && bsat.gp < 0.93
            transform: Matrix4x4 { matrix: Qt.matrix4x4(bsat.k, 0, 0, bsat.kx, 0, bsat.k, 0, bsat.ky, 0, 0, 1, 0, 0, 0, 0, 1) }
            ShapePath {
                fillColor: Theme.withAlpha(Theme.bg, 0.3); strokeWidth: 0
                PathSvg { path: "M256.0 339.0c-7.013 0-13.195 2.206-17.229 5.23-4.033 3.025-5.773 6.387-5.773 9.772 0 3.385 1.74 6.747 5.773 9.771 4.034 3.025 10.216 5.231 17.229 5.231s13.195-2.206 17.229-5.23c4.033-3.025 5.773-6.387 5.773-9.772 0-3.385-1.74-6.747-5.773-9.771-4.034-3.025-10.216-5.231-17.229-5.231z" }
            }
        }
        property real wph: 0
        NumberAnimation on wph {
            running: bsat.running
            loops: Animation.Infinite
            from: 0; to: 1; duration: 1700
        }
        Repeater {  // the BROADCAST FIELD — a continuous train of waves
            // rolling off the emitter, dying at the bottom of the safe area
            model: 3
            Shape {
                readonly property real ph: (bsat.wph + index / 3) % 1
                visible: bsat.running
                opacity: 0.5 * (1 - ph) * bsat.armT
                antialiasing: true
                transform: Matrix4x4 { matrix: Qt.matrix4x4(bsat.k, 0, 0, bsat.kx, 0, bsat.k, 0, bsat.ky, 0, 0, 1, 0, 0, 0, 0, 1) }
                ShapePath {
                    strokeColor: bsat.color; fillColor: "transparent"
                    strokeWidth: 16 - ph * 7   // 512-space, matching the beam blips' weight
                    capStyle: ShapePath.RoundCap
                    PathAngleArc {
                        centerX: 256; centerY: 354
                        radiusX: 26 + ph * 64; radiusY: 26 + ph * 64
                        // the field SPREADS as it travels — narrow at the
                        // horn, wide by the frame's edge
                        startAngle: 42 - ph * 13; sweepAngle: 96 + ph * 26
                    }
                }
            }
        }
        Rectangle {  // tip flash halo — the emitter's light on the air
            visible: bsat.running && bsat.gp > 0.93 && bsat.gp < 0.995
            x: bsat.width / 2 - width / 2
            y: bsat.k * 354 + bsat.ky - height / 2
            width: bsat.k * 58; height: bsat.k * 40; radius: height / 2
            color: Theme.withAlpha(Theme.fg, 0.18)
        }
        Shape {  // tip flash — the emitter horn catches each burst as it
            // clears the machine: brief, bright, then back to metal
            width: 512; height: 512
            antialiasing: true
            visible: bsat.running && bsat.gp > 0.93 && bsat.gp < 0.995
            transform: Matrix4x4 { matrix: Qt.matrix4x4(bsat.k, 0, 0, bsat.kx, 0, bsat.k, 0, bsat.ky, 0, 0, 1, 0, 0, 0, 0, 1) }
            ShapePath {
                fillColor: Theme.withAlpha(Theme.fg, 0.9); strokeWidth: 0
                PathSvg { path: "M256.0 339.0c-7.013 0-13.195 2.206-17.229 5.23-4.033 3.025-5.773 6.387-5.773 9.772 0 3.385 1.74 6.747 5.773 9.771 4.034 3.025 10.216 5.231 17.229 5.231s13.195-2.206 17.229-5.23c4.033-3.025 5.773-6.387 5.773-9.772 0-3.385-1.74-6.747-5.773-9.771-4.034-3.025-10.216-5.231-17.229-5.231z" }
            }
        }
        Shape {  // the breath CLOCK — no longer paints anything itself:
            // the terrain element above does its own breathing, and the nav
            // triad still rides this phase. Invisible metronome.
            id: satBeacon
            width: 512; height: 512
            antialiasing: true
            visible: false
            readonly property color lamp: Theme.withAlpha(Theme.fg, 0.95)
            property real bph: 0
            // the fade lives in the first 70% of the cycle; the last 30%
            // the element is FULLY SOLID — that is when the lights fire
            readonly property real breath: Math.sin(Math.PI * Math.min(1, bph / 0.7))
            opacity: 0
            NumberAnimation on bph {
                running: bsat.running
                loops: Animation.Infinite
                from: 0; to: 1; duration: 3200
            }
            transform: Matrix4x4 { matrix: Qt.matrix4x4(bsat.k, 0, 0, bsat.kx, 0, bsat.k, 0, bsat.ky, 0, 0, 1, 0, 0, 0, 0, 1) }
            ShapePath {
                fillColor: satBeacon.lamp; strokeWidth: 0
                PathSvg { path: "M384.0 256.0l-106.389 36.121-4.35 31.893c3.926 1.454 7.553 3.406 10.766 5.816 7.549 5.661 12.971 14.3 12.971 24.17 0 9.87-5.422 18.509-12.97 24.17-7.55 5.661-17.368 8.828-28.028 8.828s-20.479-3.167-28.027-8.828c-7.549-5.661-12.971-14.3-12.971-24.17 0-9.87 5.422-18.509 12.97-24.17 3.214-2.41 6.841-4.362 10.766-5.816l-2.931-21.493-119.922-29.314 72.34 48.461-104.512 69.666 85.803-12.066-31.455 29.435s26.97-10.097 49.152-18.29l-43.22 86.41L224 416v78.002h9.805L242.283 432l9.862 45.33 8.88-69.373 17.073 86.045H288V416l96 48-45.477-67.885 92.71-18.26-87.262-30.023 26.695-21.9-53.23 3.214L384 256z" }
            }
            ShapePath {
                fillColor: satBeacon.lamp; strokeWidth: 0
                PathSvg { path: "M256.0 339.0c-7.013 0-13.195 2.206-17.229 5.23-4.033 3.025-5.773 6.387-5.773 9.772 0 3.385 1.74 6.747 5.773 9.771 4.034 3.025 10.216 5.231 17.229 5.231s13.195-2.206 17.229-5.23c4.033-3.025 5.773-6.387 5.773-9.772 0-3.385-1.74-6.747-5.773-9.771-4.034-3.025-10.216-5.231-17.229-5.231z" }
            }
        }
        // The wavefront doesn't glide — it BLIPS down the beam through four
        // hard stations (Soliton-radar style), holding each ~375ms at flat
        // opacity: two winged arcs notched around the beam stem, echoing the
        // icon's own split-wave anatomy, flat caps, no fades.
        readonly property real blip: Math.min(4, Math.floor(gp * 5)) / 5
        Item {  // anti-collision strobe — WHITE only now, centre-body:
            // the red/green pair moved to the wingtips where port and
            // starboard actually live. Xenon double-flash, core in halo.
            readonly property bool wOn: satBeacon.bph > 0.40 && satBeacon.bph < 0.435
            visible: bsat.running && wOn
            x: bsat.width / 2; y: bsat.k * 225 + bsat.ky
            Rectangle {
                x: -width / 2; y: -height / 2
                width: Math.max(8, bsat.k * 52); height: width; radius: width / 2
                color: Theme.withAlpha("#eef3ff", 0.20)
            }
            Rectangle {
                x: -width / 2; y: -height / 2
                width: Math.max(3.5, bsat.k * 25); height: width; radius: width / 2
                color: "#eef3ff"
            }
        }
        Shape {
            id: gws
            width: 512; height: 512
            antialiasing: true
            visible: bsat.running && bsat.gp < 1
            // dissipation in steps: each station dimmer and thinner than the
            // last — energy spreading, still no ramps
            opacity: 0.9 - bsat.blip * 0.35
            transform: Matrix4x4 { matrix: Qt.matrix4x4(bsat.k, 0, 0, bsat.kx, 0, bsat.k, 0, bsat.ky, 0, 0, 1, 0, 0, 0, 0, 1) }
            readonly property real gy: 232 + bsat.blip * 120
            readonly property real gh: (205 - bsat.blip * 150) / 2
            ShapePath {
                strokeColor: bsat.color; fillColor: "transparent"
                strokeWidth: 18 - bsat.blip * 6
                capStyle: ShapePath.FlatCap
                startX: 256 - gws.gh; startY: gws.gy + 6
                PathQuad {
                    x: 240; y: gws.gy - 2
                    controlX: 256 - gws.gh * 0.45; controlY: gws.gy - 14
                }
            }
            ShapePath {
                strokeColor: bsat.color; fillColor: "transparent"
                strokeWidth: 18 - bsat.blip * 6
                capStyle: ShapePath.FlatCap
                startX: 256 + gws.gh; startY: gws.gy + 6
                PathQuad {
                    x: 272; y: gws.gy - 2
                    controlX: 256 + gws.gh * 0.45; controlY: gws.gy - 14
                }
            }
        }
    }

    // YOUTUBE foot — the world actually TURNS: land masses drift across the
    // disc with spherical foreshortening (x = A·sinλ, width ∝ cosλ, fading
    // toward the limbs), while the rim and equator hold still. Whole-icon
    // rotation would spin the continents like a wheel — a globe rotates
    // about its polar axis, and this is that motion. Blob travel A=27u keeps
    // every corner inside the rim's inner edge, so no mask is needed.
    component GlobeSpin: Item {
        id: gl
        property color color: "white"
        property bool running: false
        readonly property real u: width / 100
        // turn — the one rotation phase everything shares. Selected, it
        // loops 0.94→1.94 (the Americas hero frame at each end); idle,
        // nightHoldTurn() parks it on Earth's real night face. The
        // sphere's yaw, the hero landing and the dusk glide all read or
        // write this single value.
        property real turn: 0.94
        // WHO'S AWAKE — answered by the real Earth. The actual subsolar
        // point (UTC hour + solar declination) is projected into the
        // texture's longitude frame (real lon ≈ texture lon − 140°) and
        // the shader paints lights only where that sun has set. The mask
        // rides the GEOGRAPHY, not the screen: a region in night right
        // now stays lit across its whole visible pass, limb to limb, and
        // regions light up / go dark as the real planet turns under the
        // real sun. Recomputed each minute.
        property vector3d sunGeo: Qt.vector3d(0, 0, 1)
        function retz() {
            const now = new Date()
            const utc = now.getUTCHours() + now.getUTCMinutes() / 60
            const texLon = ((12 - utc) * 15 + 140) * Math.PI / 180
            const N = Math.floor((now.getTime() - Date.UTC(now.getUTCFullYear(), 0, 0)) / 86400000)
            const decl = 23.44 * Math.sin((284 + N) / 365 * 2 * Math.PI) * Math.PI / 180
            sunGeo = Qt.vector3d(Math.cos(decl) * Math.cos(texLon),
                                 Math.cos(decl) * Math.sin(texLon),
                                 Math.sin(decl))
            // parked? drift the hold with the real day (0.25°/min)
            if (!running && !nightSeq.running && !heroSeq.running)
                turn = nightHoldTurn()
        }
        // the lights' living shimmer, planet-wide
        property real shim3d: 0
        SequentialAnimation on shim3d {
            running: gl.visible && gl.running
            loops: Animation.Infinite
            NumberAnimation { to: 1; duration: 2600; easing.type: Easing.InOutSine }
            NumberAnimation { to: 0; duration: 3100; easing.type: Easing.InOutSine }
        }
        // ember ceiling: past ~1.0 the dot layers clip to white and a lit
        // region reads as burn-out instead of a city field
        readonly property real emiss: 0.95 + 0.15 * shim3d
        // CPU mirror of the shader's geographic night mask, for the 3D
        // metro stars: model position → texture lat/lon (marker azimuth
        // frame: λ = α + 181.3, see make_globe_real.py), then dot
        // against sunGeo. No dependence on the spin — a star's lit
        // state changes only with the wall clock.
        function nightAt(px, py, pz, sun) {
            const s0 = sun || sunGeo
            const L = Math.sqrt(px * px + py * py + pz * pz)
            const lat = Math.asin(py / L)
            const lon = (Math.atan2(px, pz) * 180 / Math.PI + 181.3) * Math.PI / 180
            const day = Math.cos(lat) * (s0.x * Math.cos(lon) + s0.y * Math.sin(lon))
                      + Math.sin(lat) * s0.z
            const t = Math.max(0, Math.min(1, (day + 0.10) / 0.22))
            return 1 - t * t * (3 - 2 * t)
        }
        Component.onCompleted: retz()   // also parks turn on the night face
        Timer { interval: 60000; running: gl.visible; repeat: true; onTriggered: gl.retz() }
        // contact-acquisition dip: arming the display drops the comm
        // overlays for a beat before they settle solid — ONE soft pulse
        property real acq: 1
        onRunningChanged: {
            if (running) {
                nightSeq.stop()
                heroSeq.restart(); acqSeq.restart()
            } else {
                heroSeq.stop()
                orb = 0.15; orb2 = 0.12; acq = 1
                // glide forward (never backspin) to the real night face
                nightAnim.to = turn + (((nightHoldTurn() - turn) % 1) + 1) % 1
                nightSeq.restart()
            }
        }
        SequentialAnimation {  // one soft acquisition pulse — PS1 restraint
            id: acqSeq
            PropertyAction { target: gl; property: "acq"; value: 0.25 }
            PauseAnimation { duration: 100 }
            PropertyAction { target: gl; property: "acq"; value: 1 }
        }
        // Selected: the planet turns. Idle: it HOLDS on Earth's real
        // night face (see nightHoldTurn) — steady, dark, cities burning.
        NumberAnimation on turn {
            running: gl.visible && gl.running && !heroSeq.running
            loops: Animation.Infinite
            // a stately day: display globes turn slow enough to read
            from: 0.94; to: 1.94; duration: 8200
        }
        SequentialAnimation {  // HERO LANDING — selection whips the globe
            // forward to the Americas hero frame in the same 750ms the
            // dawn sweep takes: pose and light arrive together, the
            // stats-screen trick. Always forward, never a backspin.
            id: heroSeq
            NumberAnimation { target: gl; property: "turn"; to: 1.94
                duration: 750; easing.type: Easing.InOutCubic }
            PropertyAction { target: gl; property: "turn"; value: 0.94 }
        }
        // IDLE HOLD — the parked pose is Earth's REAL current night face:
        // the antisolar meridian (same clock as sunGeo) rotated to front,
        // so screen-night and geographic night line up and the idle disc
        // is the dark half of the planet, city lights facing you. The
        // minute tick drifts it a full revolution per real day.
        // Empirical front-face law (verified against the real texture:
        // S America -> Africa -> India parade as turn rises):
        //   λ_front = 64.3 + 360·turn   (texture longitude, degrees)
        function nightHoldTurn() {
            const now = new Date()
            const utc = now.getUTCHours() + now.getUTCMinutes() / 60
            const texAnti = (12 - utc) * 15 + 140 + 180
            let h = (((texAnti - 64.3) / 360) % 1 + 1) % 1
            if (h < 0.94) h += 1
            return h
        }
        SequentialAnimation {  // DUSK GLIDE — deselection carries the
            // globe forward to the night face in the same 750ms the sun
            // takes to sink behind it, then renormalizes the spin phase
            id: nightSeq
            NumberAnimation { id: nightAnim; target: gl; property: "turn"
                duration: 750; easing.type: Easing.InOutCubic }
            ScriptAction { script: gl.turn = 0.94 + (((gl.turn - 0.94) % 1) + 1) % 1 }
        }
        Item {  // the MOON — far orbit, always slipping behind the limb
            property real mph: 0
            NumberAnimation on mph {
                running: gl.visible && gl.running
                loops: Animation.Infinite
                from: 0; to: 1; duration: 23000
            }
            Rectangle {
                readonly property real mth: 2 * Math.PI * parent.mph
                x: (50 + 54 * Math.cos(mth)) * gl.u - width / 2
                y: (24 + 7 * Math.sin(mth)) * gl.u - height / 2
                width: 2.4 * gl.u; height: 2.4 * gl.u; radius: width / 2
                color: Theme.withAlpha(Theme.fg, 0.5)
            }
        }
        Item {  // METEOR — every ~20s one streak cuts the upper corner:
            // three cel positions, then nothing. Rare enough to be a gift.
            property int mk: -1
            SequentialAnimation {
                running: gl.visible && gl.running
                loops: Animation.Infinite
                PauseAnimation { duration: 18500 }
                PropertyAction { target: parent; property: "mk"; value: 0 }
                PauseAnimation { duration: 70 }
                PropertyAction { target: parent; property: "mk"; value: 1 }
                PauseAnimation { duration: 70 }
                PropertyAction { target: parent; property: "mk"; value: 2 }
                PauseAnimation { duration: 70 }
                PropertyAction { target: parent; property: "mk"; value: -1 }
            }
            Rectangle {
                visible: parent.mk >= 0
                x: (78 + (parent.mk >= 0 ? parent.mk : 0) * 6) * gl.u
                y: (6 + (parent.mk >= 0 ? parent.mk : 0) * 4) * gl.u
                width: 7 * gl.u; height: Math.max(1, 1.1 * gl.u)
                radius: height / 2
                rotation: 33
                color: Theme.withAlpha(Theme.fg, 0.55 - (parent.mk >= 0 ? parent.mk : 0) * 0.13)
            }
        }
        Rectangle {  // POLARIS — seated exactly on the rotation axis,
            // above the pole: the one star that never moves
            x: 49.4 * gl.u; y: 2.8 * gl.u
            width: 1.3 * gl.u; height: 1.3 * gl.u; radius: width / 2
            color: Theme.withAlpha(Theme.fg, 0.3)
        }
        Repeater {  // backdrop stars — the planet hangs in space, not on
            // a panel; four pinpricks seat it in a sky
            model: [[7.5, 9, 1.2, 0.22], [91, 12, 0.9, 0.15], [6, 86, 0.9, 0.15], [93.5, 83, 1.2, 0.20]]
            Rectangle {
                x: modelData[0] * gl.u; y: modelData[1] * gl.u
                width: modelData[2] * gl.u; height: width; radius: width / 2
                color: Theme.withAlpha(Theme.fg, modelData[3])
                SequentialAnimation on opacity {  // one star twinkles
                    running: gl.visible && gl.running && index === 1
                    loops: Animation.Infinite
                    NumberAnimation { from: 1; to: 0.35; duration: 2800; easing.type: Easing.InOutSine }
                    NumberAnimation { from: 0.35; to: 1; duration: 3200; easing.type: Easing.InOutSine }
                }
            }
        }
        // (no drawn outline — the planet blends into the button; its own
        // limb, sunrise sliver, and city lights hold the silhouette)
        Loader {  // DEFERRED PLANET — Quick3D's first-frame cost (shader
            // compile, render targets, texture upload) stays OFF the
            // launch-critical path: the scene incubates async shortly
            // after boot and the planet fades in, already turning
            id: planetLoader
            anchors.fill: parent
            asynchronous: true
            // armed-by-timer AND visible: every wheel slot instantiates
            // a GlobeSpin, but only the world slot's is visible — the
            // others must never each stand up their own 3D scene
            property bool armed: false
            // stays loaded while HOME is merely hidden (another stage is up): unloading
            // on every stage change rebuilt the 3D scene → a 100–300 ms hitch on return
            active: armed && (gl.visible || (item !== null && App.stage !== "home"))
            opacity: status === Loader.Ready ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 320 } }
            Timer { interval: 600; running: true
                onTriggered: planetLoader.armed = true }
            sourceComponent: View3D {  // THE PLANET — an actual sphere:
            // perfect limb, true wrapping, a real sun. The 2D theatre
            // stays around it.
            id: planet3d
            anchors.fill: parent
            environment: SceneEnvironment {
                backgroundMode: SceneEnvironment.Transparent
                antialiasingMode: SceneEnvironment.MSAA
                antialiasingQuality: SceneEnvironment.High
            }
            OrthographicCamera {
                z: 300
                horizontalMagnification: planet3d.width / 120.5
                verticalMagnification: planet3d.width / 120.5
            }
            // The PRESENTATION sun (sun3d, below) as a WORLD-space direction —
            // the same space the fragment shader's NORMAL lives in, so the
            // emissive mask and the actual light shading share one geometry
            // and their terminators CANNOT disagree. (A first attempt mapped
            // it into the texture's lat/lon frame by hand and misplaced the
            // terminator ~90°.) Cities may only burn where BOTH suns have
            // set: without this the dawn sweep lit land the geographic mask
            // still called night, and the mismatch read as phantom rotation.
            // Yaw only, pitch flattened: the light's 18° elevation would
            // presentation-day the whole polar crown and eat the approved
            // idle gold field up north — the mask cares about the dawn
            // sweep's east-west travel, not the sun's height.
            readonly property vector3d psunWorld: {
                const yaw = sun3d.eulerRotation.y * Math.PI / 180
                return Qt.vector3d(Math.sin(yaw), 0, Math.cos(yaw))
            }
            // CPU mirror for the metro stars: presentation-night at a world
            // position on the sphere (its normal is its direction from the
            // planet's centre at the scene origin)
            function pnightWorld(sp) {
                const L = Math.sqrt(sp.x * sp.x + sp.y * sp.y + sp.z * sp.z)
                if (L < 1) return 1
                const day = (sp.x * psunWorld.x + sp.y * psunWorld.y + sp.z * psunWorld.z) / L
                const t = Math.max(0, Math.min(1, (day + 0.10) / 0.22))
                return 1 - t * t * (3 - 2 * t)
            }
            DirectionalLight {  // THE SUN — its position IS the selection
                // state: idle parks it behind the planet so you face the
                // night side (cities glittering, a sunrise sliver on the
                // west limb); selecting swings it round in one 750ms dawn
                // sweep, west to east across the disc. City lights stay
                // geographic (sunGeo) — this only shades the form.
                id: sun3d
                eulerRotation.x: -18
                eulerRotation.y: gl.running ? -38 : -148
                brightness: gl.running ? 1.35 : 1.1
                color: "#fff4e4"
                Behavior on eulerRotation.y {
                    NumberAnimation { duration: 750; easing.type: Easing.InOutCubic } }
                Behavior on brightness {
                    NumberAnimation { duration: 750; easing.type: Easing.InOutCubic } }
            }
            DirectionalLight {  // starlight fill — night is dim, not void;
                // idles a touch brighter so the dark face stays readable
                eulerRotation.y: 142
                eulerRotation.x: -10
                brightness: gl.running ? 0.16 : 0.26
                color: "#93b7c6"
                Behavior on brightness {
                    NumberAnimation { duration: 750; easing.type: Easing.InOutCubic } }
            }
            Node {
                eulerRotation.x: -12   // the axial tilt toward the viewer
                eulerRotation.z: 3
                Model {
                    source: "#Sphere"
                    eulerRotation.y: -gl.turn * 360 + 117
                    materials: CustomMaterial {
                        // night-side-only city lights: the shader masks the
                        // emissive by the REAL terminator, so cities ignite
                        // at dusk and the day side stays clean sunlit land
                        shadingMode: CustomMaterial.Shaded
                        fragmentShader: "qrc:/assets/globe3d/globe.frag"
                        property TextureInput albedoTex: TextureInput {
                            texture: Texture { source: "qrc:/assets/globe3d/albedo.png"
                                generateMipmaps: true; mipFilter: Texture.Linear } }
                        property TextureInput lightsTex: TextureInput {
                            texture: Texture { source: "qrc:/assets/globe3d/lights.png"
                                generateMipmaps: true; mipFilter: Texture.Linear } }
                        property real emiss: gl.emiss
                        // the real subsolar point in texture lat/lon frame
                        property vector3d sunGeo: gl.sunGeo
                        // and the presentation sun in WORLD space — the
                        // dawn sweep extinguishes cities as it reaches them
                        property vector3d psunWorld: planet3d.psunWorld
                    }
                    Repeater3D {  // METRO STARS — fourteen real dots seated
                        // on the surface at the great cities, each twinkling
                        // on its own clock, occluded by the planet itself:
                        // the discrete-sparkle half of the millions look
                        // real cities: NYC LA CHI MEX SAO BUE LON PAR CAI
                        // MOS DEL SHA TOK SYD (make_globe_real.py)
                        model: [[-34.7,33.0,-16.4],[-14.7,28.3,-39.3],[-29.3,33.8,-23.7],[-30.4,16.8,-36.8],[-46.4,-20.2,1.7],[-41.1,-28.7,-7.0],[-20.8,39.6,23.6],[-20.9,38.1,25.9],[-7.7,25.3,43.1],[-1.8,41.8,28.4],[26.1,24.2,36.0],[42.6,26.2,7.4],[40.7,29.5,-6.0],[39.5,-28.2,-14.3]]
                        Model {
                            source: "#Sphere"
                            scale: Qt.vector3d(0.016, 0.016, 0.016)
                            position: Qt.vector3d(modelData[0], modelData[1], modelData[2])
                            // a city star only burns after its sundown —
                            // same terminator ramp as the texture lights,
                            // gated by BOTH suns like the shader mask. The
                            // geographic half moves only with the wall clock:
                            // held here, so the per-frame spin re-reads just
                            // the cheap presentation half (it was the globe's
                            // biggest per-frame cost at 170 Hz).
                            readonly property real geoNight: gl.nightAt(modelData[0], modelData[1], modelData[2])
                            opacity: geoNight * planet3d.pnightWorld(scenePosition)
                            materials: PrincipledMaterial {
                                baseColor: "#ffdca8"
                                lighting: PrincipledMaterial.NoLighting
                                emissiveFactor: Qt.vector3d(tw3.v, tw3.v * 0.92, tw3.v * 0.78)
                            }
                            Item {
                                id: tw3
                                property real v: 1
                                SequentialAnimation on v {
                                    running: gl.visible && gl.running
                                    loops: Animation.Infinite
                                    NumberAnimation { to: 0.35; duration: 800 + (index % 7) * 310; easing.type: Easing.InOutSine }
                                    NumberAnimation { to: 1; duration: 1000 + (index % 5) * 340; easing.type: Easing.InOutSine }
                                }
                            }
                        }
                    }
                    Model {  // HOME — a real marker ON the planet's surface,
                        // riding its rotation, occluded by the sphere itself.
                        // Winks: that's your house.
                        source: "#Sphere"
                        scale: Qt.vector3d(0.035, 0.035, 0.035)
                        // Pacific Northwest, real coordinates (45.5°N,
                        // 122.7°W) in the calibrated model frame
                        position: Qt.vector3d(-9.8, 36.1, -34.1)
                        materials: PrincipledMaterial {
                            baseColor: "#fff6e8"
                            lighting: PrincipledMaterial.NoLighting
                            emissiveFactor: Qt.vector3d(hw3d.wk, hw3d.wk, hw3d.wk)
                        }
                        Item {
                            id: hw3d
                            property real wk: 1
                            SequentialAnimation on wk {
                                running: gl.visible && gl.running
                                loops: Animation.Infinite
                                PauseAnimation { duration: 2300 }
                                PropertyAction { value: 0.2 }
                                PauseAnimation { duration: 110 }
                                PropertyAction { value: 1 }
                            }
                        }
                    }
                }
            }
        }
        }
        Item {  // cyclone — a comma of storm turning slowly over the
            // southern ocean: weather with its own lazy clock
            x: 33 * gl.u; y: 61 * gl.u
            RotationAnimation on rotation {
                running: gl.running
                loops: Animation.Infinite
                from: 0; to: -360; duration: 14000
            }
            Shape {
                antialiasing: true
                opacity: 0.16
                ShapePath {
                    strokeColor: Theme.fg; fillColor: "transparent"
                    strokeWidth: Math.max(1, 1.4 * gl.u)
                    capStyle: ShapePath.RoundCap
                    PathAngleArc {
                        centerX: 0; centerY: 0
                        radiusX: 3.4 * gl.u; radiusY: 3.4 * gl.u
                        startAngle: 20; sweepAngle: 200
                    }
                }
                ShapePath {
                    strokeColor: Theme.fg; fillColor: "transparent"
                    strokeWidth: Math.max(1, 1.2 * gl.u)
                    capStyle: ShapePath.RoundCap
                    PathAngleArc {
                        centerX: 0; centerY: 0
                        radiusX: 1.7 * gl.u; radiusY: 1.7 * gl.u
                        startAngle: 120; sweepAngle: 190
                    }
                }
            }
        }
        // the orbit TRACK — the faint rail the birds actually fly, front
        // half only, matching their exact transform
        Shape {
            antialiasing: true
            opacity: 0.13 * gl.acq
            ShapePath {
                strokeColor: gl.color; fillColor: "transparent"
                strokeWidth: Math.max(1, 1 * gl.u)
                strokeStyle: ShapePath.DashLine
                dashPattern: [3, 3]
                PathPolyline {
                    path: Array.from({length: 37}, function(_, i) {
                        const th = Math.PI * i / 36
                        const ox = 46 * Math.cos(th), oy = 15 * Math.sin(th)
                        return Qt.point((50 + ox * 0.939 + oy * 0.342) * gl.u,
                                        (50 - ox * 0.342 + oy * 0.939) * gl.u)
                    })
                }
            }
        }
        Rectangle {  // cloud wisp — the high-latitude streak every real
            // Earth photo carries; faint, above ocean, below the night.
            // It DRIFTS — weather is its own slow clock
            property real wdx: 0
            SequentialAnimation on wdx {
                running: gl.running
                loops: Animation.Infinite
                NumberAnimation { to: 3; duration: 9000; easing.type: Easing.InOutSine }
                NumberAnimation { to: -3; duration: 9800; easing.type: Easing.InOutSine }
            }
            x: (17 + wdx) * gl.u; y: 29 * gl.u
            width: 15 * gl.u; height: 2.6 * gl.u
            radius: height / 2
            rotation: -14
            color: Theme.withAlpha(Theme.fg, 0.10)
        }
        Rectangle {  // equatorial belt wisp — the ITCZ band, faintest
            property real wdx: 0
            SequentialAnimation on wdx {
                running: gl.running
                loops: Animation.Infinite
                NumberAnimation { to: -3.5; duration: 11000; easing.type: Easing.InOutSine }
                NumberAnimation { to: 2.5; duration: 10200; easing.type: Easing.InOutSine }
            }
            x: (30 + wdx) * gl.u; y: 49 * gl.u
            width: 12 * gl.u; height: 2 * gl.u
            radius: height / 2
            rotation: -4
            color: Theme.withAlpha(Theme.fg, 0.06)
        }
        Rectangle {  // southern wisp — shorter, counter-angled
            property real wdx: 0
            SequentialAnimation on wdx {
                running: gl.running
                loops: Animation.Infinite
                NumberAnimation { to: 2.8; duration: 8400; easing.type: Easing.InOutSine }
                NumberAnimation { to: -2.8; duration: 9600; easing.type: Easing.InOutSine }
            }
            x: (24 + wdx) * gl.u; y: 63.5 * gl.u
            width: 11 * gl.u; height: 2.2 * gl.u
            radius: height / 2
            rotation: 9
            color: Theme.withAlpha(Theme.fg, 0.08)
        }
        Shape {  // AURORA — the green polar sheet over the night side's
            // high latitudes; the one colour space allows here, breathing
            antialiasing: true
            opacity: 0.1
            SequentialAnimation on opacity {
                running: gl.visible && gl.running
                loops: Animation.Infinite
                NumberAnimation { from: 0.08; to: 0.24; duration: 2900; easing.type: Easing.InOutSine }
                NumberAnimation { from: 0.24; to: 0.08; duration: 3100; easing.type: Easing.InOutSine }
            }
            ShapePath {
                strokeColor: "#8fe3a1"; fillColor: "transparent"
                strokeWidth: Math.max(1.2, 2 * gl.u)
                capStyle: ShapePath.RoundCap
                PathAngleArc {
                    centerX: 50 * gl.u; centerY: 50 * gl.u
                    radiusX: 33 * gl.u; radiusY: 33 * gl.u
                    startAngle: -78; sweepAngle: 34
                }
            }
        }
        Shape {  // aurora AUSTRALIS — the southern mirror, fainter, its
            // own slow breath
            antialiasing: true
            opacity: 0.07
            SequentialAnimation on opacity {
                running: gl.visible && gl.running
                loops: Animation.Infinite
                NumberAnimation { from: 0.05; to: 0.14; duration: 3400; easing.type: Easing.InOutSine }
                NumberAnimation { from: 0.14; to: 0.05; duration: 3800; easing.type: Easing.InOutSine }
            }
            ShapePath {
                strokeColor: "#8fe3a1"; fillColor: "transparent"
                strokeWidth: Math.max(1.2, 1.8 * gl.u)
                capStyle: ShapePath.RoundCap
                PathAngleArc {
                    centerX: 50 * gl.u; centerY: 50 * gl.u
                    radiusX: 33 * gl.u; radiusY: 33 * gl.u
                    startAngle: 52; sweepAngle: 30
                }
            }
        }
        // ── the TRACE CALL — war-room style: a dashed great-circle hop
        // from the uplink station out to each night-side city in turn, a
        // packet running the arc, a ping ring blooming where it lands.
        property int leg: 0
        property real tt: 0
        property real ringT: 0
        property bool arcOn: false
        readonly property var legs: [[78.1, 38.1], [82.6, 50.6], [76.1, 62.1]]
        readonly property real tox: 27       // uplink node on the lit face
        readonly property real toy: 33.5
        readonly property real tcx: (tox + legs[leg][0]) / 2
        readonly property real tcy: Math.min(toy, legs[leg][1]) - 16
        Shape {  // the arc — dashed, the classic trace line
            antialiasing: true
            visible: gl.running && gl.arcOn
            opacity: 0.55
            ShapePath {
                strokeColor: Theme.withAlpha(Theme.fg, 0.55); fillColor: "transparent"
                strokeWidth: Math.max(1, 1.1 * gl.u)
                strokeStyle: ShapePath.DashLine
                dashPattern: [2, 2.5]
                // the dashes MARCH toward the target while the trace is live
                NumberAnimation on dashOffset {
                    running: gl.running && gl.arcOn
                    loops: Animation.Infinite
                    from: 0; to: -9; duration: 600
                }
                startX: gl.tox * gl.u; startY: gl.toy * gl.u
                PathQuad {
                    x: gl.legs[gl.leg][0] * gl.u; y: gl.legs[gl.leg][1] * gl.u
                    controlX: gl.tcx * gl.u; controlY: gl.tcy * gl.u
                }
            }
        }
        Rectangle {  // uplink node — the origin station, waking for each hop
            visible: gl.running
            x: (gl.tox - 1.1) * gl.u; y: (gl.toy - 1.1) * gl.u
            width: 2.2 * gl.u; height: 2.2 * gl.u; radius: width / 2
            color: gl.arcOn ? Theme.withAlpha(Theme.fg, 0.5) : "transparent"
            border.width: Math.max(1, 0.8 * gl.u)
            border.color: Theme.withAlpha(Theme.fg, gl.arcOn ? 0.85 : 0.35)
        }
        Rectangle {  // the packet running the arc
            visible: gl.running && gl.arcOn && gl.tt > 0.01 && gl.tt < 0.99
            readonly property real qx: (1 - gl.tt) * (1 - gl.tt) * gl.tox + 2 * (1 - gl.tt) * gl.tt * gl.tcx + gl.tt * gl.tt * gl.legs[gl.leg][0]
            readonly property real qy: (1 - gl.tt) * (1 - gl.tt) * gl.toy + 2 * (1 - gl.tt) * gl.tt * gl.tcy + gl.tt * gl.tt * gl.legs[gl.leg][1]
            x: qx * gl.u - width / 2; y: qy * gl.u - height / 2
            width: 2 * gl.u; height: 2 * gl.u; radius: width / 2
            color: Theme.withAlpha(Theme.fg, 0.88)
        }
        Rectangle {  // ping — the ring blooming where the trace lands
            visible: gl.running && gl.ringT > 0.01 && gl.ringT < 0.99
            readonly property real rr: (1.6 + gl.ringT * 5) * gl.u
            x: gl.legs[gl.leg][0] * gl.u - rr; y: gl.legs[gl.leg][1] * gl.u - rr
            width: rr * 2; height: rr * 2; radius: rr
            color: "transparent"
            border.width: Math.max(1, 1 * gl.u)
            border.color: Theme.withAlpha(Theme.fg, 0.9 - gl.ringT * 0.7)
        }
        Rectangle {  // sonar echo — a second, fainter ring a beat behind
            visible: gl.running && gl.ringT > 0.3 && gl.ringT < 0.99
            readonly property real rr: (1.2 + (gl.ringT - 0.3) * 4.5) * gl.u
            x: gl.legs[gl.leg][0] * gl.u - rr; y: gl.legs[gl.leg][1] * gl.u - rr
            width: rr * 2; height: rr * 2; radius: rr
            color: "transparent"
            border.width: Math.max(1, 0.8 * gl.u)
            border.color: Theme.withAlpha(Theme.fg, (0.9 - gl.ringT * 0.7) * 0.45)
        }
        Rectangle {  // the CITY FLARES as the trace lands on it
            visible: gl.running && gl.ringT > 0.01 && gl.ringT < 0.25
            x: (gl.legs[gl.leg][0] - 1.1) * gl.u; y: (gl.legs[gl.leg][1] - 1.1) * gl.u
            width: 2.2 * gl.u; height: 2.2 * gl.u; radius: width / 2
            color: Theme.withAlpha(Theme.fg, 0.85)
        }
        SequentialAnimation {  // the call cycle: three hops, then breathe
            running: gl.running
            loops: Animation.Infinite
            PauseAnimation { duration: 800 }
            PropertyAction { target: gl; property: "leg"; value: 0 }
            PropertyAction { target: gl; property: "tt"; value: 0 }
            PropertyAction { target: gl; property: "ringT"; value: 0 }
            PropertyAction { target: gl; property: "arcOn"; value: true }
            NumberAnimation { target: gl; property: "tt"; from: 0; to: 1; duration: 850 }
            NumberAnimation { target: gl; property: "ringT"; from: 0; to: 1; duration: 380; easing.type: Easing.OutQuad }
            PauseAnimation { duration: 240 }
            PropertyAction { target: gl; property: "arcOn"; value: false }
            PauseAnimation { duration: 650 }
            PropertyAction { target: gl; property: "leg"; value: 1 }
            PropertyAction { target: gl; property: "tt"; value: 0 }
            PropertyAction { target: gl; property: "ringT"; value: 0 }
            PropertyAction { target: gl; property: "arcOn"; value: true }
            NumberAnimation { target: gl; property: "tt"; from: 0; to: 1; duration: 850 }
            NumberAnimation { target: gl; property: "ringT"; from: 0; to: 1; duration: 380; easing.type: Easing.OutQuad }
            PauseAnimation { duration: 240 }
            PropertyAction { target: gl; property: "arcOn"; value: false }
            PauseAnimation { duration: 650 }
            PropertyAction { target: gl; property: "leg"; value: 2 }
            PropertyAction { target: gl; property: "tt"; value: 0 }
            PropertyAction { target: gl; property: "ringT"; value: 0 }
            PropertyAction { target: gl; property: "arcOn"; value: true }
            NumberAnimation { target: gl; property: "tt"; from: 0; to: 1; duration: 850 }
            NumberAnimation { target: gl; property: "ringT"; from: 0; to: 1; duration: 380; easing.type: Easing.OutQuad }
            PauseAnimation { duration: 240 }
            PropertyAction { target: gl; property: "arcOn"; value: false }
            PauseAnimation { duration: 1500 }
        }
        // the broadcast bird — a single contact in low orbit (the YOUTUBE
        // story: a world being transmitted to). Its tilted ellipse swings
        // from just outside the rim, transits the face, and exits past the
        // far rim where sin(θ) flips — so it winks out exactly at the
        // horizon, occluded by the planet, and reappears on the other side.
        // Faster than the surface turns, like a real low orbit.
        property real orb: 0.15
        NumberAnimation on orb {
            running: gl.running
            loops: Animation.Infinite
            from: 0.15; to: 1.15; duration: 3400
        }
        Rectangle {
            readonly property real th: 2 * Math.PI * (gl.orb % 1)
            readonly property real ox: 46 * Math.cos(th)
            readonly property real oy: 15 * Math.sin(th)
            visible: Math.sin(th) > 0
            opacity: gl.acq
            x: (50 + ox * 0.939 + oy * 0.342) * gl.u - width / 2
            y: (50 - ox * 0.342 + oy * 0.939) * gl.u - height / 2
            width: 3 * gl.u; height: 3 * gl.u; radius: width / 2
            color: gl.color
        }
        // second bird — counter-tilted orbit, slower, unescorted: the two
        // craft make a constellation instead of a lone satellite
        property real orb2: 0.12
        NumberAnimation on orb2 {
            running: gl.running
            loops: Animation.Infinite
            from: 0.12; to: 1.12; duration: 4600
        }
        Rectangle {
            readonly property real th2e: 2 * Math.PI * (((gl.orb2 - 0.05) % 1 + 1) % 1)
            visible: gl.running && Math.sin(th2e) > 0
            opacity: 0.3 * gl.acq
            x: (50 + 44 * Math.cos(th2e) * 0.939 - 13 * Math.sin(th2e) * 0.342) * gl.u - width / 2
            y: (50 + 44 * Math.cos(th2e) * 0.342 + 13 * Math.sin(th2e) * 0.939) * gl.u - height / 2
            width: 1.8 * gl.u; height: 1.8 * gl.u; radius: width / 2
            color: gl.color
        }
        Rectangle {
            readonly property real th2: 2 * Math.PI * (gl.orb2 % 1)
            readonly property real o2x: 44 * Math.cos(th2)
            readonly property real o2y: 13 * Math.sin(th2)
            visible: Math.sin(th2) > 0
            opacity: gl.acq * 0.8
            x: (50 + o2x * 0.939 - o2y * 0.342) * gl.u - width / 2
            y: (50 + o2x * 0.342 + o2y * 0.939) * gl.u - height / 2
            width: 2.5 * gl.u; height: 2.5 * gl.u; radius: width / 2
            color: gl.color
        }
        // the contact's radar TRAIL — two echo dots fading back along the
        // orbit, only while it's moving (the resting contact sits alone)
        Repeater {
            model: [[0.055, 0.5], [0.11, 0.25]]
            Rectangle {
                readonly property real th2: 2 * Math.PI * (((gl.orb - modelData[0]) % 1 + 1) % 1)
                visible: gl.running && Math.sin(th2) > 0
                opacity: modelData[1] * gl.acq
                x: (50 + 46 * Math.cos(th2) * 0.939 + 15 * Math.sin(th2) * 0.342) * gl.u - width / 2
                y: (50 - 46 * Math.cos(th2) * 0.342 + 15 * Math.sin(th2) * 0.939) * gl.u - height / 2
                width: 2 * gl.u; height: 2 * gl.u; radius: width / 2
                color: gl.color
            }
        }
    }

    // SETTINGS foot — two MACHINED gears in mesh. Each silhouette is a
    // generated gear profile — trapezoidal teeth with angled flanks, true
    // root and tip arcs, hub hole punched odd-even — drawn in a 100-box
    // (centre 50,50, tip radius 50) and scaled into place. 10 vs 8 teeth →
    // ratio 1.25: the big wheel turns +360°/cycle, the small −450°, one
    // shared driver, so pitch-line speeds match exactly and tooth always
    // meets gap along the 45° line of centres. Mesh depths line up to the
    // unit: big tip reach 45.96−29 = 16.96u ≈ small root 17.0u, small tip
    // reach 21.96u ≈ big root 22.04u.
    component MeshGears: Item {
        id: mg
        property color color: "white"
        property bool running: false
        readonly property real u: width / 100
        readonly property string bigD: "M87.41 43.35 L99.76 45.14 L99.97 48.38 L99.97 51.62 L99.76 54.86 L87.41 56.65 L86.86 59.22 L86.14 61.74 L85.24 64.21 L84.18 66.61 L93.12 75.32 L91.38 78.06 L89.48 80.69 L87.40 83.18 L76.36 77.37 L74.41 79.13 L72.34 80.74 L70.16 82.21 L67.89 83.53 L70.00 95.83 L66.99 97.03 L63.90 98.03 L60.75 98.83 L55.24 87.64 L52.62 87.91 L50.00 88.00 L47.38 87.91 L44.76 87.64 L39.25 98.83 L36.10 98.03 L33.01 97.03 L30.00 95.83 L32.11 83.53 L29.84 82.21 L27.66 80.74 L25.59 79.13 L23.64 77.37 L12.60 83.18 L10.52 80.69 L8.62 78.06 L6.88 75.32 L15.82 66.61 L14.76 64.21 L13.86 61.74 L13.14 59.22 L12.59 56.65 L0.24 54.86 L0.03 51.62 L0.03 48.38 L0.24 45.14 L12.59 43.35 L13.14 40.78 L13.86 38.26 L14.76 35.79 L15.82 33.39 L6.88 24.68 L8.62 21.94 L10.52 19.31 L12.60 16.82 L23.64 22.63 L25.59 20.87 L27.66 19.26 L29.84 17.79 L32.11 16.47 L30.00 4.17 L33.01 2.97 L36.10 1.97 L39.25 1.17 L44.76 12.36 L47.38 12.09 L50.00 12.00 L52.62 12.09 L55.24 12.36 L60.75 1.17 L63.90 1.97 L66.99 2.97 L70.00 4.17 L67.89 16.47 L70.16 17.79 L72.34 19.26 L74.41 20.87 L76.36 22.63 L87.40 16.82 L89.48 19.31 L91.38 21.94 L93.12 24.68 L84.18 33.39 L85.24 35.79 L86.14 38.26 L86.86 40.78 L87.41 43.35 Z M80.00 50.00 L79.25 56.68 L77.03 63.02 L73.45 68.70 L68.70 73.45 L63.02 77.03 L56.68 79.25 L50.00 80.00 L43.32 79.25 L36.98 77.03 L31.30 73.45 L26.55 68.70 L22.97 63.02 L20.75 56.68 L20.00 50.00 L20.75 43.32 L22.97 36.98 L26.55 31.30 L31.30 26.55 L36.98 22.97 L43.32 20.75 L50.00 20.00 L56.68 20.75 L63.02 22.97 L68.70 26.55 L73.45 31.30 L77.03 36.98 L79.25 43.32 Z M67.00 50.00 L66.57 53.78 L65.32 57.38 L63.29 60.60 L60.60 63.29 L57.38 65.32 L53.78 66.57 L50.00 67.00 L46.22 66.57 L42.62 65.32 L39.40 63.29 L36.71 60.60 L34.68 57.38 L33.43 53.78 L33.00 50.00 L33.43 46.22 L34.68 42.62 L36.71 39.40 L39.40 36.71 L42.62 34.68 L46.22 33.43 L50.00 33.00 L53.78 33.43 L57.38 34.68 L60.60 36.71 L63.29 39.40 L65.32 42.62 L66.57 46.22 Z M59.00 50.00 L58.77 52.00 L58.11 53.90 L57.04 55.61 L55.61 57.04 L53.90 58.11 L52.00 58.77 L50.00 59.00 L48.00 58.77 L46.10 58.11 L44.39 57.04 L42.96 55.61 L41.89 53.90 L41.23 52.00 L41.00 50.00 L41.23 48.00 L41.89 46.10 L42.96 44.39 L44.39 42.96 L46.10 41.89 L48.00 41.23 L50.00 41.00 L52.00 41.23 L53.90 41.89 L55.61 42.96 L57.04 44.39 L58.11 46.10 L58.77 48.00 Z"
        readonly property string smallD: "M84.65 42.26 L99.63 43.93 L99.96 47.97 L99.96 52.03 L99.63 56.07 L84.65 57.74 L83.85 60.70 L82.80 63.59 L81.50 66.36 L79.97 69.02 L89.39 80.80 L86.76 83.89 L83.89 86.76 L80.80 89.39 L69.02 79.97 L66.36 81.50 L63.59 82.80 L60.70 83.85 L57.74 84.65 L56.07 99.63 L52.03 99.96 L47.97 99.96 L43.93 99.63 L42.26 84.65 L39.30 83.85 L36.41 82.80 L33.64 81.50 L30.98 79.97 L19.20 89.39 L16.11 86.76 L13.24 83.89 L10.61 80.80 L20.03 69.02 L18.50 66.36 L17.20 63.59 L16.15 60.70 L15.35 57.74 L0.37 56.07 L0.04 52.03 L0.04 47.97 L0.37 43.93 L15.35 42.26 L16.15 39.30 L17.20 36.41 L18.50 33.64 L20.03 30.98 L10.61 19.20 L13.24 16.11 L16.11 13.24 L19.20 10.61 L30.98 20.03 L33.64 18.50 L36.41 17.20 L39.30 16.15 L42.26 15.35 L43.93 0.37 L47.97 0.04 L52.03 0.04 L56.07 0.37 L57.74 15.35 L60.70 16.15 L63.59 17.20 L66.36 18.50 L69.02 20.03 L80.80 10.61 L83.89 13.24 L86.76 16.11 L89.39 19.20 L79.97 30.98 L81.50 33.64 L82.80 36.41 L83.85 39.30 L84.65 42.26 Z M62.00 50.00 L61.70 52.67 L60.81 55.21 L59.38 57.48 L57.48 59.38 L55.21 60.81 L52.67 61.70 L50.00 62.00 L47.33 61.70 L44.79 60.81 L42.52 59.38 L40.62 57.48 L39.19 55.21 L38.30 52.67 L38.00 50.00 L38.30 47.33 L39.19 44.79 L40.62 42.52 L42.52 40.62 L44.79 39.19 L47.33 38.30 L50.00 38.00 L52.67 38.30 L55.21 39.19 L57.48 40.62 L59.38 42.52 L60.81 44.79 L61.70 47.33 Z"
        // Heavy machinery at cruise: 4.8s per big-gear rev, hard-on like
        // everything else — but the arm carries one mechanical EVENT: the
        // train takes up its backlash (a hair backward) before it bites
        // forward. The cruise wrap is +360° big / −450° small — both whole
        // tooth pitches, invisible. On deselect drive rests modulo 1/10
        // (36° big, 45° small — again full pitches): the standing pose is
        // pixel-identical to drive 0, so the cruise restart never jumps.
        property real drive: 0
        property real jolt: 0
        onRunningChanged: {
            if (running) engage.restart()
            else { engage.stop(); jolt = 0; drive %= 0.1 }
        }
        SequentialAnimation {
            id: engage
            NumberAnimation {
                target: mg; property: "jolt"
                to: -0.007; duration: 60; easing.type: Easing.InQuad
            }
            NumberAnimation {
                target: mg; property: "jolt"
                to: 0; duration: 110; easing.type: Easing.OutQuad
            }
        }
        SequentialAnimation on drive {
            running: mg.running
            NumberAnimation { from: 0; to: 1; duration: 4800; loops: Animation.Infinite }
        }
        Item {  // BIG gear — 10 teeth, tip r 29u, centre (60.5, 60.5), drawn
            // MGS-manual style: toothed rim band, four spokes, hub ring with
            // punched bore. Base rotation 27° presents a tooth GAP along the
            // line of centres.
            id: gearBig
            x: 31.5 * mg.u; y: 31.5 * mg.u
            width: 58 * mg.u; height: 58 * mg.u
            rotation: 27 + (mg.drive + mg.jolt) * 360
            readonly property real sc: width / 100
            Shape {
                antialiasing: true
                transform: Scale { xScale: gearBig.sc; yScale: gearBig.sc }
                ShapePath {
                    fillColor: mg.color; strokeWidth: 0
                    fillRule: ShapePath.OddEvenFill
                    PathSvg { path: mg.bigD }
                }
            }
            Repeater {  // spokes — hub ring to rim band, turning with the wheel
                model: 4
                Rectangle {
                    color: mg.color
                    width: 7 * gearBig.sc; height: 23 * gearBig.sc
                    x: 46.5 * gearBig.sc; y: 19 * gearBig.sc
                    transform: Rotation {
                        origin.x: 3.5 * gearBig.sc; origin.y: 31 * gearBig.sc
                        angle: 45 + index * 90
                    }
                }
            }
            Rectangle {  // KEYWAY — the key seated in the bore, the notch
                // every drawn gear carries; it locks wheel to shaft
                color: mg.color
                x: 47.8 * gearBig.sc; y: 39.5 * gearBig.sc
                width: 4.4 * gearBig.sc; height: 4.5 * gearBig.sc
            }
        }
        Item {  // SMALL gear — 8 teeth, tip r 24u, centre (28, 28), a wide
            // punched bore (technical-drawing idler); counter-rotating 1.25×
            // faster, a tooth pointing down the line of centres.
            x: 4 * mg.u; y: 4 * mg.u
            width: 48 * mg.u; height: 48 * mg.u
            rotation: -(mg.drive + mg.jolt) * 450
            Rectangle {  // its keyway — the idler is keyed too
                color: mg.color
                x: (50 - 2.6) * 0.48 * mg.u; y: 36.5 * 0.48 * mg.u
                width: 5.2 * 0.48 * mg.u; height: 5 * 0.48 * mg.u
            }
            Shape {
                antialiasing: true
                transform: Scale { xScale: 48 * mg.u / 100; yScale: 48 * mg.u / 100 }
                ShapePath {
                    fillColor: mg.color; strokeWidth: 0
                    fillRule: ShapePath.OddEvenFill
                    PathSvg { path: mg.smallD }
                }
            }
        }
    }

    // STATS foot — a vector bar chart in the wheel's own hand, and a REAL
    // instrument: the five bars are the user's last five weeks of actual
    // watch time (oldest → newest, from the store's watch log), re-sampled
    // on every arm; trendline, area and arrowhead are all derived from the
    // live bar tops. On arm the bars GAUGE-FILL in stagger, the line draws
    // itself left to right, the arrow pops on completion, then the chart
    // HOLDS — a completed reading, not a fidgeting one. An empty log falls
    // back to the sculpted heights: an instrument, never a void.
    component StatChart: Item {
        id: sch
        property color color: "white"
        property bool running: false
        readonly property real u: width / 100
        property var hgt: [24, 36, 30, 50, 64]
        function sample() {
            const raw = Store.watchDays(35)
            const w = [0, 0, 0, 0, 0]
            for (let i = 0; i < raw.length; ++i)
                w[Math.floor(i / 7)] += raw[i].seconds
            const mx = Math.max(w[0], w[1], w[2], w[3], w[4])
            // 6u floor: a zero week is still a READING on the meter
            if (mx > 0) hgt = w.map(v => 6 + 58 * v / mx)
        }
        // lazy first sample, same reason as Chart3D: five instances
        // exist, at most one is ever shown
        property bool sampled: false
        onVisibleChanged: if (visible && !sampled) { sampled = true; sample() }
        Component.onCompleted: if (visible) { sampled = true; sample() }
        // the trend rides 4.5u above the bar tops it summarises
        function ty(i) { return 87 - hgt[i] - 4.5 }
        // tip continues the last segment a quarter-pitch past the data
        readonly property real tipY: Math.max(11, ty(4) + (ty(4) - ty(3)) / 4)
        readonly property var trendPts: {
            const p = [Qt.point(11.5 * u, (87 - hgt[0] - 1) * u)]
            for (let i = 0; i < 5; ++i)
                p.push(Qt.point((18.5 + 16 * i) * u, ty(i) * u))
            p.push(Qt.point(86.5 * u, tipY * u))
            return p
        }
        readonly property var areaPts: {
            const p = trendPts.slice(0, 6)
            p.push(Qt.point(82.5 * u, 86 * u))
            p.push(Qt.point(11.5 * u, 86 * u))
            p.push(trendPts[0])
            return p
        }
        readonly property var arrowPts: {
            const t = trendPts[6], b = trendPts[5]
            let dx = t.x - b.x, dy = t.y - b.y
            const L = Math.hypot(dx, dy) || 1
            dx /= L; dy /= L
            const tip = Qt.point(t.x + dx * 3 * u, t.y + dy * 3 * u)
            const bx = tip.x - dx * 7.4 * u, by = tip.y - dy * 7.4 * u
            return [tip, Qt.point(bx - dy * 3.5 * u, by + dx * 3.5 * u),
                    Qt.point(bx + dy * 3.5 * u, by - dx * 3.5 * u), tip]
        }
        // grow 0→1 staggers the bars then reveals the line; rests at 1
        property real grow: 1
        onRunningChanged: {
            if (running) { sample(); growAnim.restart() }
            else grow = 1
        }
        NumberAnimation {
            id: growAnim
            target: sch; property: "grow"
            from: 0; to: 1; duration: 620
            easing.type: Easing.OutQuad
        }
        // plot frame: vertical axis with reading ticks — a proper instrument
        // grid, not bars floating in space. On arm the FRAME assembles first
        // (axis rises, baseline extends) and the data fills into it.
        readonly property real fr: Math.min(1, grow / 0.25)
        Rectangle {
            x: 8 * sch.u; y: (87 - 61 * sch.fr) * sch.u; width: Math.max(1.5, 2.4 * sch.u)
            height: 61 * sch.fr * sch.u
            color: sch.color
        }
        Rectangle { color: sch.color; opacity: 0.45; x: 11.5 * sch.u; y: 28 * sch.u; width: 3.5 * sch.u; height: Math.max(1, 1.6 * sch.u) }
        Rectangle { color: sch.color; opacity: 0.45; x: 11.5 * sch.u; y: 47 * sch.u; width: 3.5 * sch.u; height: Math.max(1, 1.6 * sch.u) }
        Rectangle { color: sch.color; opacity: 0.32; x: 11.5 * sch.u; y: 37.5 * sch.u; width: 2 * sch.u; height: Math.max(1, 1.4 * sch.u) }
        Rectangle { color: sch.color; opacity: 0.32; x: 11.5 * sch.u; y: 56.5 * sch.u; width: 2 * sch.u; height: Math.max(1, 1.4 * sch.u) }
        Rectangle { color: sch.color; opacity: 0.55; x: 11.5 * sch.u; y: 66 * sch.u; width: 3.5 * sch.u; height: Math.max(1, 1.6 * sch.u) }
        // (6) gridlines as DASHES — blueprint texture, quieter than solid rules
        Repeater {
            model: 12
            Rectangle {
                color: sch.color; opacity: 0.15
                x: (15 + (index % 6) * 13 + (index < 6 ? 0 : 6.5)) * sch.u
                y: (index < 6 ? 47 : 66) * sch.u
                width: 8 * sch.u; height: Math.max(1, 1.4 * sch.u)
            }
        }
        Shape {  // axis arrowhead — the y-axis points UP, instrument-style
            antialiasing: true
            ShapePath {
                fillColor: sch.color; strokeColor: "transparent"
                PathPolyline {
                    path: [Qt.point(5.9 * sch.u, 27 * sch.u), Qt.point(13.1 * sch.u, 27 * sch.u), Qt.point(9.5 * sch.u, 21 * sch.u), Qt.point(5.9 * sch.u, 27 * sch.u)]
                }
            }
        }
        Rectangle {  // welded axis corner — the frame's joint plate
            x: 7 * sch.u; y: 86 * sch.u; width: 5 * sch.u; height: 5 * sch.u
            color: sch.color
        }
        Rectangle {  // baseline axis — extends with the frame assembly
            x: 8 * sch.u; y: 87 * sch.u; width: 84 * sch.fr * sch.u
            height: Math.max(1.5, 2.4 * sch.u)
            color: sch.color
        }
        Repeater {  // the bars — blocky, rising from the axis, each with a
            // brighter CAP line: segment-meter anatomy, the reading's edge
            model: 5
            Rectangle {
                readonly property real f: Math.min(1, Math.max(0, (sch.grow - index * 0.09) / 0.38))
                readonly property real h: sch.hgt[index] * f
                color: sch.color
                x: (12 + index * 16) * sch.u
                y: (87 - h) * sch.u
                width: 13 * sch.u; height: h * sch.u
                Rectangle {  // the cap SNAPS on the frame its bar lands —
                    // one frame WIDER than the bar, then seated: a spark
                    visible: parent.f >= 0.99 && parent.height > 4 * sch.u
                    x: parent.f < 1 ? -1 * sch.u : 0
                    width: parent.width + (parent.f < 1 ? 2 * sch.u : 0)
                    height: Math.max(1, 1.8 * sch.u)
                    color: Theme.withAlpha(Theme.fg, 0.7)
                }
                Rectangle {  // machined left edge — the bars are metal
                    width: Math.max(1, 1 * sch.u); height: parent.height
                    color: Theme.withAlpha(Theme.fg, 0.12)
                }
            }
        }
        Item {  // trendline — drawn left→right by a widening clip window,
            // starting AT the axis: the trend originates in the instrument
            x: 9.5 * sch.u; y: 0
            width: Math.min(1, Math.max(0, (sch.grow - 0.55) / 0.45)) * 83 * sch.u
            height: 100 * sch.u
            clip: true
            Shape {
                x: -9.5 * sch.u
                width: 100 * sch.u; height: 100 * sch.u
                antialiasing: true
                ShapePath {
                    strokeColor: sch.color; fillColor: "transparent"
                    strokeWidth: Math.max(1.5, 3 * sch.u)
                    capStyle: ShapePath.RoundCap
                    PathPolyline { path: sch.trendPts }
                }
            }
            Shape {  // the trend AREA — a whisper of fill under the line,
                // giving the trajectory a body
                x: -9.5 * sch.u
                width: 100 * sch.u; height: 100 * sch.u
                antialiasing: true
                ShapePath {
                    fillColor: Theme.withAlpha(sch.color, 0.045); strokeColor: "transparent"
                    PathPolyline { path: sch.areaPts }
                }
            }
        }
        Shape {  // arrowhead — POPS in as the line completes, damped
            visible: sch.grow > 0.97
            antialiasing: true
            scale: sch.grow > 0.97 ? 1 : 0.7
            Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutBack; easing.overshoot: 1.4 } }
            // (no vertex nodes: at 46px they chopped the trend into bits)
            ShapePath {
                fillColor: sch.color; strokeColor: "transparent"
                PathPolyline { path: sch.arrowPts }
            }
        }
    }

    // SETTINGS glyph — the REFERENCE lightning-spanner, split at its natural
    // seam: the game-icons path is two pieces, the wrench (head, shaft, ring
    // hub) and the LIGHTNING BOLT with its energy flares. The wrench holds
    // still; the bolt CRACKLES — a near-white copy of the bolt's exact
    // silhouette lights up in stuttering bursts (electricity brightens, it
    // doesn't dim), the base ducking a touch beneath so the flash reads as
    // light. At rest crk is 0: pixel-identical to the reference.
    component LightningSpanner: Item {
        id: lsp
        property color color: "white"
        property bool running: false
        // IconShape's normalisation for bbox [18.4, 18.4, 475.3, 474.8]
        readonly property real k: width * 0.94 / 475.3
        readonly property real kx: width / 2 - k * 256.05
        readonly property real ky: height / 2 - k * 255.8
        readonly property string boltD: "M18.4 18.4V53.21L89.04 99.51l-42.593 57.71 81.03-27.392 7.023 30.498 56.066 5.256 9.926 43.22-35.623 16.934-40.298-29.785-70.082 62.49 72.418-23.945 22.778 44.387 44.96-14.373 32.2-55.918c-10.238-23.8-9.676-51.92 4.183-75.996 7.208-12.53 17.085-22.504 28.644-29.575 2.33-.675 8.71-5.517 11.648-5.802 11.515-4.78 23.982-7.087 36.537-6.534 5.638.248 11.288 1.053 16.863 2.433l12.088 2.99-40.34 69.5c-3.456 6.002-1.275 14.09 3.895 17.085l.002.002c5.144 2.976 12.367.775 16.014-5.56l.01-.014 40.35-69.518 8.592 8.97c25.457 26.57 31.995 67.74 12.697 101.26-13.936 24.205-38.08 38.312-63.676 41.24l-29.91 51.937 27.017 23.355-19.92 43.863 85.913 67.684-43.625-74.252 37.785-33.21 47.89 26.284-51.698-66.78-19.377 32.37-24.12-43.85 62.49-32.706 17.52 39.714 30.37-26.28 32.705 50.81-23.944-88.77-29.788 24.526-4.672-66.577 75.338-48.472-81.787-4.59 28.616-55.82 36.155 26.585 26.335-16.34v-70.18h-2.63L456.878 50.53 415.41 27.757l-45.1 61.627-34.57-16.162 16.656-52.488-78.304 53.594-24.198-55.95h-65.783l-5.226.63 51.976 33.29-12.847 61.32-50.81 8.76-72.327-104H18.354z"
        property real crk: 0
        // arm flash on select, hard reset on deselect — equipping the tool
        // ACKNOWLEDGES with one spark before the loop's opening rest
        onRunningChanged: {
            if (running) lspArm.restart()
            else crk = 0
        }
        SequentialAnimation {
            id: lspArm
            PropertyAction { target: lsp; property: "crk"; value: 2 }
            PauseAnimation { duration: 60 }
            PropertyAction { target: lsp; property: "crk"; value: 0 }
        }
        // Cel-animation lightning, three-state: crk 2 = the bolt FLASHES
        // white, crk 1 = it VANISHES, 0 = normal. Every strike reads
        // flash-then-gone-then-back — the same grammar as the satellite's
        // landing. All instant jumps, held for flash-frames.
        SequentialAnimation {
            running: lsp.running
            loops: Animation.Infinite
            PauseAnimation { duration: 1100 }
            PropertyAction { target: lsp; property: "crk"; value: 2 }
            PauseAnimation { duration: 50 }
            PropertyAction { target: lsp; property: "crk"; value: 0 }
            PauseAnimation { duration: 150 }
            PropertyAction { target: lsp; property: "crk"; value: 2 }
            PauseAnimation { duration: 45 }
            PropertyAction { target: lsp; property: "crk"; value: 0 }
            PauseAnimation { duration: 220 }
            PropertyAction { target: lsp; property: "crk"; value: 2 }
            PauseAnimation { duration: 70 }
            PropertyAction { target: lsp; property: "crk"; value: 1 }
            PauseAnimation { duration: 70 }
            PropertyAction { target: lsp; property: "crk"; value: 0 }
            PauseAnimation { duration: 90 }
            PropertyAction { target: lsp; property: "crk"; value: 2 }
            PauseAnimation { duration: 80 }
            PropertyAction { target: lsp; property: "crk"; value: 1 }
            PauseAnimation { duration: 90 }
            PropertyAction { target: lsp; property: "crk"; value: 0 }
            PauseAnimation { duration: 160 }
            PropertyAction { target: lsp; property: "crk"; value: 2 }
            PauseAnimation { duration: 55 }
            PropertyAction { target: lsp; property: "crk"; value: 1 }
            PauseAnimation { duration: 55 }
            PropertyAction { target: lsp; property: "crk"; value: 0 }
            PauseAnimation { duration: 700 }
            PropertyAction { target: lsp; property: "crk"; value: 2 }
            PauseAnimation { duration: 45 }
            PropertyAction { target: lsp; property: "crk"; value: 0 }
            PauseAnimation { duration: 1380 }
            PropertyAction { target: lsp; property: "crk"; value: 2 }
            PauseAnimation { duration: 60 }
            PropertyAction { target: lsp; property: "crk"; value: 1 }
            PauseAnimation { duration: 60 }
            PropertyAction { target: lsp; property: "crk"; value: 0 }
            PauseAnimation { duration: 60 }
            PropertyAction { target: lsp; property: "crk"; value: 2 }
            PauseAnimation { duration: 45 }
            PropertyAction { target: lsp; property: "crk"; value: 0 }
            PauseAnimation { duration: 2950 }
        }
        Shape {  // the wrench — static, but the main strike washes its
            // contrast for one frame (the flash lights the whole tool).
            // Multisampled: the ring hub stays round, no tessellation facets.
            width: 512; height: 512
            antialiasing: true
            layer.enabled: true
            layer.samples: 4
            layer.smooth: true
            transform: Matrix4x4 { matrix: Qt.matrix4x4(lsp.k, 0, 0, lsp.kx, 0, lsp.k, 0, lsp.ky, 0, 0, 1, 0, 0, 0, 0, 1) }
            ShapePath {
                fillColor: lsp.color; strokeWidth: 0
                fillRule: ShapePath.OddEvenFill
                PathSvg { path: "M304.6 109.3c-12.4-.082-24.632 3.262-35.138 9.68l-.102.06c-8.906 5.473-16.434 13.043-22.093 22.878v.002c-11.596 20.143-11.392 43.746-1.618 63.08l2.277 4.504-86.692 150.553-5.068.27c-19.984 1.06-39.3 11.34-51.25 28.92-7.377 10.693-11.713 23.632-11.713 37.552 0 36.546 29.828 66.374 66.375 66.374 36.546 0 66.374-29.828 66.374-66.375 0-5.057-.59-9.977-1.67-14.714-.1-.457-.207-.91-.316-1.365-.05-.2-.095-.4-.147-.6-1.198-4.772-2.917-9.394-5.143-13.763l-2.3-4.513 86.698-150.57 5.07-.27c21.685-1.153 42.1-12.294 53.73-32.492h-.003c12.81-22.25 10.9-48.614-2.115-68.81l-27.14 46.76c-8.31 14.434-26.838 20.938-41.575 12.407H291c-14.713-8.522-19.23-27.812-10.73-42.583l.01-.016 27.206-46.868c-.15-.007-.298-.035-.447-.04-.828-.037-1.655-.058-2.48-.063z M159.5 379.1c26.45 0 47.696 21.244 47.696 47.697 0 26.45-21.244 47.696-47.697 47.696-26.454 0-47.696-21.245-47.696-47.697 0-26.454 21.243-47.698 47.695-47.698z" }
            }
        }
        Shape {  // the bolt + its energy flares — VANISHES in strike state 1
            width: 512; height: 512
            antialiasing: true
            opacity: lsp.running && lsp.crk === 1 ? 0 : 1
            transform: Matrix4x4 { matrix: Qt.matrix4x4(lsp.k, 0, 0, lsp.kx, 0, lsp.k, 0, lsp.ky, 0, 0, 1, 0, 0, 0, 0, 1) }
            ShapePath {
                fillColor: lsp.color; strokeWidth: 0
                fillRule: ShapePath.OddEvenFill
                PathSvg { path: lsp.boltD }
            }
        }
        Shape {  // the FLASH — the bolt's exact silhouette in white, state 2
            width: 512; height: 512
            antialiasing: true
            visible: lsp.running
            opacity: lsp.running && lsp.crk === 2 ? 0.9 : 0
            transform: Matrix4x4 { matrix: Qt.matrix4x4(lsp.k, 0, 0, lsp.kx, 0, lsp.k, 0, lsp.ky, 0, 0, 1, 0, 0, 0, 0, 1) }
            ShapePath {
                fillColor: Theme.withAlpha(Theme.fg, 0.95); strokeWidth: 0
                fillRule: ShapePath.OddEvenFill
                PathSvg { path: lsp.boltD }
            }
        }
    }


    property int _lastSpotRev: -1
    function refresh() {
        sfxHush = true                           // a reload re-seats the selection silently
        cw = MediaLibrary.continueWatching(18)   // cheap (≤18) — resume changes often
        // #45: spotlight(100000) walks EVERY title with art on the GUI thread. Only
        // re-walk when the library actually RESCANNED since we last materialized it
        // (a cheap C++ revision counter), not on every onVisibleChanged. New files
        // fold in on rescan without yanking the item currently on screen.
        const rev = MediaLibrary.scanRevision()
        if (rev !== _lastSpotRev || spot.length === 0) {
            _lastSpotRev = rev
            const fresh = MediaLibrary.spotlight(100000)
            if (fresh.length !== spot.length) {
                const cur = curSpot ? curSpot.path : ""
                spot = fresh
                const at = spot.findIndex(it => it.path === cur)
                spotIdx = at >= 0 ? at : Math.min(spotIdx, Math.max(0, spot.length - 1))
            }
        }
        if (cwIdx >= cw.length) cwIdx = 0
        cwPageToFocus()
        if (zones.indexOf(zoneName) < 0) zoneName = "wheel"
        sfxHush = false
    }

    onVisibleChanged: {
        if (visible) {
            forceActiveFocus()
            refresh()
            // Land on the SPOTLIGHT — the featured title is the hero first
            // impression, the wheel rests below (a whisper marks where DOWN lands).
            // Falls back to the wheel if there's no spotlight. Name-based, so it
            // resolves to spot the instant the async spotlight data arrives.
            zoneName = "spot"
            enterAnim.restart()
        }
    }

    Connections {
        target: MediaLibrary
        function onScanned() { home.refresh() }
    }

    // ── UI sounds (Sfx) ────────────────────────────────────────────────────
    // A selection that MOVED plays `move` — caught from the selection itself, so
    // keys, the mouse, the scroll and tilt wheels and the remote all tick alike;
    // a step that couldn't go plays `bump`; ⏎ `select`, esc `back`, the info
    // sheet or the deck opening `open`. Sfx keeps one cue per turn (the
    // strongest), so ⏎ on CONTINUE — which also moves the focus onto its posters
    // — is one OPEN. The app's own moves — the library loading in, the
    // spotlight's timer — stay silent (sfxHush), and so does the moment home
    // takes the floor back.
    readonly property string sfxSel: zone + ":" + (zone === "spot" ? spotIdx
                                     : zone === "wheel" ? secIdx : (cwOnPosters ? cwIdx : -1))
    property bool sfxHush: false
    property bool sfxArmed: false
    readonly property bool sfxLive: navFree && sfxArmed && !sfxHush
    onNavFreeChanged: { sfxArmed = false; if (navFree) sfxArm.restart() }
    Timer { id: sfxArm; interval: 200; onTriggered: home.sfxArmed = home.navFree }
    onSfxSelChanged: sfxCue("move")
    onSpotInfoOpenChanged: sfxCue(spotInfoOpen ? "open" : "back")
    function sfxCue(cue) { if (sfxLive) Sfx.play(cue, sfxPan()) }
    // where the selection sits, as a gentle left/right pan
    function sfxPan() {
        if (zone === "wheel" && items.length > 1) return (secIdx / (items.length - 1) - 0.5) * 0.5
        if (zone === "cw" && cwOnPosters) return (Math.max(0, Math.min(2, cwIdx - cwWinStart)) - 1) * 0.25
        return 0
    }

    // ── Actions ────────────────────────────────────────────────────────────
    // i / up-from-the-spotlight opens info. For the featured title that's the
    // home-native MINI panel; for a specific continue title it's the full page
    // (episodes, resume). The mini can hand off to the full page (up again).
    function openInfo() {
        if (zone === "cw" && cw[cwIdx]) { sfxCue("open"); App.detailUri = cw[cwIdx].path; return }
        if (curSpot) spotInfoOpen = true
        else sfxCue("bump")
    }
    // The full page opened from the half info: stepping back out of it lands
    // on the half info again (Main → backFromFull), not two steps down.
    property bool fullFromInfo: false
    function backFromFull() {
        if (fullFromInfo && curSpot) spotInfoOpen = true
        fullFromInfo = false
    }
    function openFullSpot() {
        fullFromInfo = spotInfoOpen && !!curSpot
        spotInfoOpen = false
        sfxCue("open")
        if (curSpot) App.detailUri = curSpot.path
    }
    function playSpot() {
        spotInfoOpen = false
        sfxCue("select")
        const it = curSpot
        if (!it) return
        if (it.kind === "show") {
            App.openSection("tv")
            MediaLibrary.showFilter = it.show.length > 0 ? it.show : it.title
        } else {
            App.play(it.path)
        }
    }

    function confirm() {
        CLog.d("home", "confirm zone=" + zone + " spotIdx=" + spotIdx
               + " secIdx=" + secIdx + " cwIdx=" + cwIdx)
        if (zone === "spot") {
            const it = curSpot
            if (!it)
                return
            sfxCue("select")
            if (it.kind === "show") {
                App.openSection("tv")
                MediaLibrary.showFilter = it.show.length > 0 ? it.show : it.title
            } else {
                playBtnPlate.tap()      // the PLAY plate presses down as it fires
                App.play(it.path)
            }
        } else if (zone === "cw") {
            if (!cwDeployed) { sfxCue("open"); cwDeployed = true; cwOnPosters = true }   // Enter on the button → OPEN + focus the posters (same as Down/j)
            else if (!cwOnPosters) { sfxCue("back"); cwDeployed = false }               // Enter on the button (open, stepped back up) → CLOSE
            else { sfxCue("select"); App.play(cw[cwIdx].path) }                         // Enter on a poster → play it
        } else {
            sfxCue("select")
            App.openSection(items[secIdx].target)
        }
    }

    function spotCycle(dir) {
        if (spot.length <= 1) sfxCue("bump")
        if (spot.length === 0)
            return
        spotIdx = (spotIdx + dir + spot.length) % spot.length
        autoTimer.restart()
    }

    // Tilt wheel = Left/Right (detected app-wide in AppController::eventFilter,
    // discrete clicks only — trackball ball-scroll never counts as a tilt).
    // Only while HOME itself has the floor: a detail page, search, the queue,
    // the output picker or the garage editor on top owns the input.
    readonly property bool navFree: home.visible && App.detailUri === "" && !App.searchOpen && !App.queueOpen && !App.outputOpen && !home.mechEdit
    Connections {
        target: App
        enabled: home.navFree
        function onTiltStep(dir) { home.sideStep(dir) }
    }
    // Zones stack vertically; j/k (and the scroll wheel) move between them, h/l
    // (and the tilt wheel) within.
    // Remote: REC / return queue what home is pointing at (the spotlight film,
    // or the continue poster); TRAILER plays the spotlight's trailer.
    Connections {
        target: App
        enabled: home.navFree
        function onQueueAddRequested() {
            let it = null
            if (home.zone === "cw" && home.cwOnPosters && home.cw[home.cwIdx]) it = home.cw[home.cwIdx]
            else if (home.zone === "spot" && home.curSpot && home.curSpot.kind !== "show") it = home.curSpot
            if (!it || !it.path) { home.sfxCue("bump"); App.notify("NOTHING TO QUEUE HERE"); return }
            Queue.add({ uri: it.path, title: it.title || "", sourceId: "library" })
            home.sfxCue("select")
            App.notify("QUEUED · " + (it.title || ""))
        }
        function onTrailerRequested() {
            const it = home.heroItem
            if (it && it.title) App.playTrailer(it.title, String(it.year || ""))
        }
    }

    function navDown() {
        // On the CONTINUE button, Down is a "descend into it": first Down OPENS
        // the deck (same as Enter), the next Down steps into the poster row (so
        // Enter there plays). Down never CLOSES — only Enter toggles/plays.
        if (zone === "cw") {
            if (!cwOnPosters) {                     // on the button → DESCEND straight into the posters
                if (!cwDeployed) { sfxCue("open"); cwDeployed = true }  // opening the deck if it isn't already
                cwOnPosters = true                  // one Down lands you on the posters (Enter still toggles the deck)
            } else sfxCue("bump")
            return                                  // already in the posters — nothing below
        }
        const prev = zone
        zoneStep(1)
        if (prev === zone) sfxCue("bump")
        if (prev === "wheel" && zone === "cw") cwEnterFromWheel()
    }
    function navUp() {
        // In the open deck, Up steps from the posters back UP to the CONTINUE
        // button (where Enter closes) before leaving the zone.
        if (zone === "cw" && cwOnPosters) { cwOnPosters = false; return }
        // Up from the top zone opens the mini info panel (XMB: press up and
        // the detail fades in); otherwise walk up toward the spotlight.
        if (zones.indexOf(zone) === 0) { openInfo(); return }
        const prev = zone
        zoneStep(-1)
        if (prev === "cw" && zone === "wheel") wheelEnterFromCw()
    }

    function sideStep(dir) {
        if (zone === "spot") { spotCycle(dir); return true }
        // The wheel slots run left-to-right, so h/l walks them. Clamp at the
        // ends (the wheel is the anchor of the screen; falling through would
        // dead-end into backToChooser mid-menu).
        if (zone === "wheel") {
            const was = secIdx
            secIdx = Math.max(0, Math.min(items.length - 1, secIdx + dir))
            if (secIdx === was) sfxCue("bump")
            return true
        }
        if (zone === "cw") {
            if (!cwOnPosters) { sfxCue("bump"); return true }   // focus on the CONTINUE button — nothing to side-step
            const was = cwIdx
            cwIdx = Math.max(0, Math.min(cw.length - 1, cwIdx + dir))
            if (cwIdx === was) sfxCue("bump")
            cwPageToFocus()
            return true
        }
        return false
    }

    function jumpSection(n) {
        zoneName = "wheel"
        secIdx = n
        confirm()
    }

    // GARAGE mode cycle (Tab): NORMAL → COMBAT → SCAN → …
    function cycleGarageMode() {
        garageMode = garageMode === "normal" ? "combat"
                   : garageMode === "combat" ? "scan" : "normal"
    }

    // The home's active selection SPRINGS to whatever part the GARAGE is on, so
    // the on-screen selection and the lock never mismatch — and the edited
    // element is always the one deployed/visible.
    // ⚠ COALESCED (0-tick): `spotInfoOpen`/`zoneName` are written here, and
    // `garageFocus.targetItem`/`groupItem` READ `spotInfoOpen` — so a synchronous
    // write would move elements, `aimKey` would re-derive the row, re-firing this
    // → a binding loop. Deferring the write to the next tick breaks the cycle.
    Timer { id: zoneSyncTimer; interval: 0; onTriggered: home._doZoneSync() }
    function syncZoneToGroup(g) { if (mechEdit) zoneSyncTimer.restart() }
    function _doZoneSync() {
        if (!mechEdit || !mechEditor) return
        var grp = mechEditor.focusGroup
        var r = (mechEditor.page === "dials") ? mechEditor.focusRow : null
        var k = r && r.k ? String(r.k) : ""
        // the info sheet must be OPEN whenever the edited element lives in it:
        // the synopsis (INFO SHEET group) AND the PLAY button (its play* dials
        // are grouped under DECK but the button is drawn in the sheet).
        var wantInfo = (grp === "INFO SHEET") || (k.indexOf("play") === 0)
        spotInfoOpen = wantInfo
        if (grp === "CARD" || grp === "ANIMATION" || grp === "WHEEL") zoneName = "wheel"
        else if (grp === "SPOTLIGHT" || grp === "BADGES" || grp === "INFO SHEET") zoneName = "spot"
        else if (grp === "DECK" || grp === "FOOTER") zoneName = wantInfo ? "spot" : "cw"
    }
    // dial-level moves (not just group changes) re-sync what's on screen, so
    // stepping onto a PLAY dial slides the info sheet in and its button appears.
    Connections {
        target: mechEditor
        enabled: home.mechEdit && home.mechEditor !== null
        function onRowChanged() { home.syncZoneToGroup(mechEditor.focusGroup) }
        function onPageChanged() { home.syncZoneToGroup(mechEditor.focusGroup) }
    }

    Keys.onReleased: (event) => {
        if (!garageFocus) return
        if (event.key === Qt.Key_Shift) garageFocus.shiftHeld = false
        else if (event.key === Qt.Key_Control) garageFocus.ctrlHeld = false
    }
    Keys.onPressed: (event) => {
        const wasG = pendingG
        pendingG = false
        // live modifier tracking for scan manual-aim/zoom — holding Ctrl/Shift
        // engages immediately, no mouse move needed (the mouse used to be the
        // only source, so a stationary Ctrl did nothing)
        if (garageFocus && event.key === Qt.Key_Shift) garageFocus.shiftHeld = true
        else if (garageFocus && event.key === Qt.Key_Control) garageFocus.ctrlHeld = true
        // While the mech editor is up IT owns the keys — j/k walk the rows,
        // h/l cycle the focused style live, r resets to the shipped defaults,
        // \ persists, m/esc close.
        if (mechEdit && mechEditor) {
            const sh = (event.modifiers & Qt.ShiftModifier) !== 0
            // ASSET VIEWER's extra keys (s/o/f/[ ]) route first; unhandled keys
            // (hjkl/Enter/-/=/`) fall through to normal editor handling below.
            if (mechEditor.page === "assets" && mechEditor.assetKey(event.key, sh)) { event.accepted = true; return }
            switch (event.key) {
            case Qt.Key_QuoteLeft: case Qt.Key_Escape: mechEdit = false; break
            // movement is page-aware (dials/assets/move) — the editor routes
            case Qt.Key_Down: case Qt.Key_J: mechEditor.nav("down", sh); break
            case Qt.Key_Up: case Qt.Key_K: mechEditor.nav("up", sh); break
            case Qt.Key_Left: case Qt.Key_H: mechEditor.nav("left", sh); break
            case Qt.Key_Right: case Qt.Key_L: mechEditor.nav("right", sh); break
            case Qt.Key_BracketLeft: mechEditor.nav("ydec", sh); break
            case Qt.Key_BracketRight: mechEditor.nav("yinc", sh); break
            case Qt.Key_Comma: mechEditor.scaleStep(-1, sh); break    // ASSEMBLY: shrink (⇧ coarse)
            case Qt.Key_Period: mechEditor.scaleStep(1, sh); break    // ASSEMBLY: grow (⇧ coarse)
            case Qt.Key_Tab: home.cycleGarageMode(); break     // vim: Tab cycles modes
            case Qt.Key_Minus: mechEditor.pageStep(-1); break  // -/= rotate pages
            case Qt.Key_Equal: mechEditor.pageStep(1); break
            case Qt.Key_B: mechEditor.togglePage(); break
            case Qt.Key_Z: sh ? mechEditor.redo() : mechEditor.undo(); break
            case Qt.Key_Y: mechEditor.redo(); break
            case Qt.Key_X: sh ? mechEditor.randomizeGroup() : mechEditor.randomize(); break
            case Qt.Key_C: mechEditor.abCompare(); break
            case Qt.Key_G:  // NORMAL: toggle grid · SCAN: cycle lockbox grid · ZOOM: step magnification
                if (garageMode === "scan") {
                    if (garageFocus.zooming) {   // the lockbox grid is hidden while zooming, so g steps the zoom level
                        var zl = ["1.5x", "2x", "3x", "4x"]
                        var zi = zl.indexOf(home.mech.zoom); if (zi < 0) zi = 1
                        mechSet("zoom", zl[(zi + 1) % zl.length])
                    } else scanGridN = scanGridN % 3 + 1
                } else mechGrid = !mechGrid
                break
            // vim modes — i COMBAT (insert/tune) · v SCAN (visual/calibrate) · n NORMAL (survey)
            case Qt.Key_I: garageMode = "combat"; break
            case Qt.Key_V: garageMode = "scan"; break
            case Qt.Key_N: garageMode = "normal"; break
            case Qt.Key_O: mechEditor.cycleOpacity(); break
            case Qt.Key_P: mechEditor.leftSide = !mechEditor.leftSide; break
            case Qt.Key_Space: mechEditor.hidden = !mechEditor.hidden; break
            case Qt.Key_Return: case Qt.Key_Enter: mechEditor.activate(); break
            // r on the MOVE page resets the selected element's trim only
            case Qt.Key_R: if (!mechEditor.resetCurrent()) { mechEditor.pushHist(); mech = mechDefaults } break
            case Qt.Key_Backslash: saveMechUi(); break
            // preset slots: digits load, shifted digits save (the shifted
            // keys arrive as their symbols)
            case Qt.Key_1: mechEditor.loadPreset(1); break
            case Qt.Key_2: mechEditor.loadPreset(2); break
            case Qt.Key_3: mechEditor.loadPreset(3); break
            case Qt.Key_Exclam: mechEditor.savePreset(1); break
            case Qt.Key_At: mechEditor.savePreset(2); break
            case Qt.Key_NumberSign: mechEditor.savePreset(3); break
            }
            event.accepted = true
            return
        }
        // While the mini info panel is up it owns the keys: enter plays, up
        // hands off to the full page, anything else dismisses it.
        if (spotInfoOpen) {
            switch (event.key) {
            case Qt.Key_Return: case Qt.Key_Enter: case Qt.Key_Space: playSpot(); break
            case Qt.Key_Up: case Qt.Key_K: openFullSpot(); break
            case Qt.Key_P: spotInfoOpen = false; App.toPlayer(); break
            // Down is BACK: the key that would drop you down a zone instead
            // steps back out of the info you opened by pressing up.
            case Qt.Key_Down: case Qt.Key_J: spotInfoOpen = false; break
            default: spotInfoOpen = false; break // i / esc / h / … also close it
            }
            event.accepted = true
            return
        }
        switch (event.key) {
        case Qt.Key_G:
            // vim: gg = jump to the spotlight, G = jump to the last zone.
            if (event.modifiers & Qt.ShiftModifier) zoneName = zones[zones.length - 1]
            else if (wasG) zoneName = zones[0]
            else pendingG = true
            break
        case Qt.Key_Home: zoneName = zones[0]; break
        case Qt.Key_End: zoneName = zones[zones.length - 1]; break
        case Qt.Key_Down: case Qt.Key_J: navDown(); break
        case Qt.Key_Up: case Qt.Key_K: navUp(); break
        case Qt.Key_I: openInfo(); break
        // `e` — take over what another codec has open, at the moment it
        // reached; that screen stops. Returns without accepting when nothing
        // is playing elsewhere, so the key stays free for anything later.
        case Qt.Key_E:
            if (!App.nowElsewhere || App.partyLive) return
            App.resumeHere(); break
        case Qt.Key_W: App.partyOpen = !App.partyOpen; break
        case Qt.Key_Left:
            if (!sideStep(-1)) return
            break
        case Qt.Key_Right:
            if (!sideStep(1)) return
            break
        case Qt.Key_1: jumpSection(0); break
        case Qt.Key_2: jumpSection(1); break
        case Qt.Key_3: jumpSection(2); break
        case Qt.Key_4: jumpSection(3); break
        case Qt.Key_5: jumpSection(4); break
        case Qt.Key_Return: case Qt.Key_Enter: case Qt.Key_Space:
            confirm(); break
        case Qt.Key_L:
            sideStep(1); break
        case Qt.Key_Slash: App.searchOpen = true; break
        case Qt.Key_Q: App.queueOpen = !App.queueOpen; break
        case Qt.Key_C: App.outputOpen = true; break
        case Qt.Key_P: App.toPlayer(); break
        case Qt.Key_X: App.stopPlayback(); break // close the PiP dock from home
        case Qt.Key_H:
            if (sideStep(-1)) break
            sfxCue("back"); App.backToChooser(); break
        // ` (or M) opens the GARAGE editor — the wheel glyph/weapon picking that
        // used to live in the standalone ICON-DEBUG overlay now lives in the
        // editor's WHEEL section (pick the section, then h/l cycle head/foot).
        case Qt.Key_QuoteLeft: if (!App.editorEnabled) return; mechEdit = true; break   // SETTINGS ▸ EDITOR off = ` is inert
        case Qt.Key_Escape: sfxCue("back"); App.backToChooser(); break
        default: return
        }
        event.accepted = true
    }

    // (ICON DEBUG overlay retired — its wheel glyph/weapon picking now lives in
    // the GARAGE editor's WHEEL section; the icon helpers below are shared.)

    // Scroll wheel browses the focused zone — cycle the spotlight, step the
    // wheel, scrub the shelf: the pointer equivalent of h/l. Accumulated per
    // 120° notch so a mouse steps once per click and a touchpad doesn't spray.
    // Scroll wheel = Up/Down, XMB-style: it walks the zones exactly as j/k do
    // (top zone + up opens the info panel; down closes it again). Sideways is
    // the tilt wheel. One step per 120° notch so a wheel steps once per click
    // and a ball-scroll roll doesn't spray. While the info panel is up, only
    // down acts (closes it) — a spin never overshoots into the full page.
    // Scroll = the remote's arrows on HOME, XMB-style. Up/down walk the zones
    // exactly as j/k do — up from the top opens the info panel, up again the
    // full info page; down closes the panel. The trackball ball (wheel held)
    // also steps SIDEWAYS (h/l) when rolled clearly sideways; the tilt wheel
    // steps sideways via App.tiltStep.
    // ONE step per gesture: after a step the wheel is ignored briefly, so a
    // quick spin — or a ball-roll, whose events are each worth ~1.5-2 notches
    // and arrive dozens a second — moves one place, not five. A continuous
    // source (pixel deltas: the ball) must travel 3 notches' worth first, so a
    // slight drift while clicking never steps.
    // (WheelHandler reacts to ONE orientation — vertical by default — so the
    // ball's sideways roll needs its own handler; both share one gesture lock.)
    property double wheelLockUntil: 0
    // Scrolling DOWN out of the full info page closes it (DetailView); the rest
    // of that same roll must not carry on into HOME's zones.
    Connections {
        target: App
        function onDetailUriChanged() {
            if (App.detailUri.length === 0 && App.stage === "home")
                home.wheelLockUntil = Date.now() + 400
            // a page left any other way (played, cast, replaced) forgets it
            if (App.detailUri.length === 0) home.fullFromInfo = false
        }
    }
    WheelHandler {
        // ⚠ TouchPad too: Qt's Wayland backend labels EVERY scroll on this
        // desktop a touchpad (the trackball's wheel included — measured
        // 2026-10-04), and WheelHandler takes only Mouse by default, so the
        // home wheel never fired for a real scroll.
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        enabled: home.navFree
        property real accum: 0
        onWheel: (e) => {
            const now = Date.now()
            if (now < home.wheelLockUntil) { accum = 0; return }
            const ball = e.pixelDelta.x !== 0 || e.pixelDelta.y !== 0
            const need = ball ? 360 : 120
            accum += e.angleDelta.y
            if (accum >= need) {
                if (home.spotInfoOpen) home.openFullSpot()
                else home.navUp()
            } else if (accum <= -need) {
                if (home.spotInfoOpen) home.spotInfoOpen = false
                else home.navDown()
            } else {
                return
            }
            accum = 0
            home.wheelLockUntil = now + 280
        }
    }
    WheelHandler {
        // The trackball ball (wheel held) rolled clearly SIDEWAYS = h/l. Only
        // the ball (pixel deltas): a tilt-wheel click comes via App.tiltStep.
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        enabled: home.navFree
        orientation: Qt.Horizontal
        property real accum: 0
        onWheel: (e) => {
            const now = Date.now()
            if (now < home.wheelLockUntil) { accum = 0; return }
            if (e.pixelDelta.x === 0 && e.pixelDelta.y === 0)
                return
            if (Math.abs(e.angleDelta.x) <= 2 * Math.abs(e.angleDelta.y))
                return // a vertical roll's drift, not a sideways one
            accum += e.angleDelta.x
            if (Math.abs(accum) < 360)
                return
            home.sideStep(accum > 0 ? -1 : 1)
            accum = 0
            home.wheelLockUntil = now + 280
        }
    }

    // Entrance: quiet fade+rise whenever home comes back.
    opacity: 0
    transform: Translate { id: enterShift; y: 10 }
    ParallelAnimation {
        id: enterAnim
        NumberAnimation { target: home; property: "opacity"; to: 1; duration: DS.grand; easing.type: Easing.OutCubic }
        NumberAnimation { target: enterShift; property: "y"; to: 0; duration: DS.grand; easing.type: Easing.OutCubic }
        NumberAnimation { target: home; property: "slotsIn"; from: 0; to: 1; duration: DS.grand; easing.type: Easing.OutCubic }
    }
    // 0→1 with the entrance: each slot gets its own window, so the wheel
    // deals in left to right instead of arriving as one slab.
    property real slotsIn: 1

    // Spotlight auto-advance (pauses while anything else is on screen). Dwell
    // time is a Setting (SYSTEM ▸ SPOTLIGHT INTERVAL); 0 = hold, manual only.
    Timer {
        id: autoTimer
        interval: Math.max(1, App.spotlightSeconds) * 1000
        repeat: true
        running: home.visible && home.spot.length > 1 && App.stage === "home"
                 && App.spotlightSeconds > 0 && !home.spotInfoOpen
                 && App.detailUri === ""   // the full page over HOME holds its title
                 && home.zone !== "cw"
                 && !App.queueOpen && !App.outputOpen && !App.remoteOpen
                 && !App.searchOpen
        onTriggered: {   // the app's own move — no tick
            home.sfxHush = true
            home.spotIdx = (home.spotIdx + 1) % home.spot.length
            home.sfxHush = false
        }
    }

    // ── Edge field — a quiet vignette framing the instrument: the art
    // recedes at the frame's sides so the centred deck owns the middle ──
    // (declared before the fanart so it paints over it via the stage order
    // below; see the two gradient flanks after bgArt)
    // ── Fanart layer ───────────────────────────────────────────────────────
    // Full-bleed behind everything, dimmed to a constant so the art always owns
    // the frame (no scroll here to key it to). Two layers crossfade: the hidden
    // one loads, then flips.
    Item {
        id: bgArt
        anchors.fill: parent
        anchors.topMargin: -home.topBleed // the art bleeds up under the header
        anchors.leftMargin: -home.leftBleed
        anchors.rightMargin: -home.rightBleed
        anchors.bottomMargin: -home.bottomBleed
        visible: home.spot.length > 0

        property bool useA: true
        property string src: home.heroFanart.length > 0 ? Theme.art(home.heroFanart) : ""
        onSrcChanged: {
            if (src.length === 0)
                return
            const hidden = useA ? imgB : imgA
            if (String(hidden.source) === src) { useA = !useA; return }
            hidden.source = src
        }
        Image {
            id: imgA
            anchors.fill: parent
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: true
            visible: !home.mechOn || home.mech.bgBackdrop === "fanart"
            opacity: bgArt.useA ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 650; easing.type: Easing.InOutQuad } }
            onStatusChanged: if (status === Image.Ready && !bgArt.useA) bgArt.useA = true
        }
        Image {
            id: imgB
            anchors.fill: parent
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: true
            visible: !home.mechOn || home.mech.bgBackdrop === "fanart"
            opacity: bgArt.useA ? 0 : 1
            Behavior on opacity { NumberAnimation { duration: 650; easing.type: Easing.InOutQuad } }
            onStatusChanged: if (status === Image.Ready && bgArt.useA) bgArt.useA = false
        }
        Component.onCompleted: if (src.length > 0) imgA.source = src
        // v2: alternate hangar backdrops (the unused bg-*.png), behind the scrim
        Image {
            id: bgScene
            anchors.fill: parent
            fillMode: Image.PreserveAspectCrop
            visible: home.mechOn && (home.mech.bgBackdrop === "city" || home.mech.bgBackdrop === "desert"
                                     || home.mech.bgBackdrop === "grass" || home.mech.bgBackdrop === "snow")
            source: visible ? (App.heroDevRev, (App && App.heroDevPath("bg-" + home.mech.bgBackdrop) !== "" ? App.heroDevPath("bg-" + home.mech.bgBackdrop) + "?v=" + App.heroDevRev : "qrc:/assets/mechui/bg-" + home.mech.bgBackdrop + ".png")) : ""
            asynchronous: false
            cache: true
        }

        // Constant field dim — lowered, because the shaped scrim below now
        // carries the contrast where text actually sits, so dark backdrops
        // aren't needlessly crushed everywhere.
        Rectangle { anchors.fill: parent; color: Theme.withAlpha(Theme.bg, home.mechOn ? ({ off: 0, low: 0.15, med: 0.30, high: 0.5 }[home.mech.bgDim] || 0.30) : 0.30) }
        Rectangle {  // v2 backdrop colour wash
            anchors.fill: parent
            visible: home.mechOn && home.mech.bgTint !== "none"
            color: Theme.withAlpha(home.hInk(home.mech.bgTint), 0.15)
        }
        // One shaped scrim. It darkens the header (top) and footer (bottom) for
        // the chrome, lets the upper art breathe — and, the fix for text washing
        // out on a bright backdrop (Kill Bill's near-white frame), holds a soft
        // WELL through the vertical middle where the whole instrument
        // (spotlight · wheel · continue) lives. Every stop is feathered into the
        // next: a soft field of shade, never a black band.
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0.00; color: Theme.withAlpha(Theme.bg, 0.72) } // header
                GradientStop { position: 0.14; color: Theme.withAlpha(Theme.bg, 0.18) }
                GradientStop { position: 0.26; color: "transparent" }                    // art breathes
                GradientStop { position: 0.40; color: Theme.withAlpha(Theme.bg, 0.34) } // spotlight
                GradientStop { position: 0.58; color: Theme.withAlpha(Theme.bg, 0.42) } // wheel
                GradientStop { position: 0.86; color: Theme.withAlpha(Theme.bg, 0.42) } // continue
                GradientStop { position: 0.95; color: Theme.withAlpha(Theme.bg, 0.30) }
                GradientStop { position: 1.00; color: Theme.withAlpha(Theme.bg, 0.52) } // footer
            }
        }
        // Edge flanks — the horizontal half of the vignette: the far left
        // and right recede a step, seating the centred instrument.
        Rectangle {
            visible: !home.mechOn || home.mech.bgVignette
            anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
            width: parent.width * 0.10
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: Theme.withAlpha(Theme.bg, 0.30) }
                GradientStop { position: 1.0; color: "transparent" }
            }
        }
        Rectangle {
            visible: !home.mechOn || home.mech.bgVignette
            anchors.right: parent.right; anchors.top: parent.top; anchors.bottom: parent.bottom
            width: parent.width * 0.10
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: "transparent" }
                GradientStop { position: 1.0; color: Theme.withAlpha(Theme.bg, 0.30) }
            }
        }
    }

    // When there is no art at all, the page is not black — it is the field
    // colour, so the panels still read as floating on something.
    Rectangle {
        anchors.fill: parent
        visible: home.spot.length === 0
        color: Theme.bg
    }

    // ── Composition ──────────────────────────────────────────────────────────
    // One centred stack. The wheel is the anchor; the card hangs above it and
    // the shelf below, all sharing the wheel's horizontal centre.
    Item {
        id: stage
        anchors.fill: parent
        anchors.topMargin: home.topBleed // content sits below the header bleed

        // Auto-fit tracking so a rotated label stands the height of its slot.
        // librsvg-style: (n-1) gaps carry the extra span past the glyph run.
        function fitTrack(txt, span, fs) {
            const n = txt.length
            if (n < 2) return 1
            const adv = fs * 0.58
            return Math.max(1, (span - n * adv) / (n - 1))
        }

        // ── Vertical rhythm ──────────────────────────────────────────────
        // The stack is spotlight + wheel + the CONTINUE *label* only — the
        // continue posters are NOT reserved here; they pop open into the empty
        // room below when you drop into that zone. That freed room is what lets
        // the wheel and spotlight breathe. Cluster is pushed a little below
        // centre on wide panels, tapering to a clean centre on the 5:4 CRT.
        // Spotlight sits almost ON the card (tiny top gap); the label hangs a
        // normal gap under the wheel.
        readonly property int gapTopBase: Math.round(9 * home.s)
        readonly property int gapBotBase: Math.round(32 * home.s)
        readonly property real spotH: home.spot.length > 0 ? spotBlock.height : 0
        readonly property real gapTop: home.spot.length > 0 ? gapTopBase : 0
        readonly property real shelfH: home.cw.length > 0 ? shelf.height : 0  // the STACK only reserves the collapsed label; posters pop into the room below
        readonly property real gapBot: home.cw.length > 0 ? gapBotBase : 0
        readonly property real stackH: spotH + gapTop + wheelUnit.height + gapBot + shelfH
        readonly property real pushBias:
            Math.max(0, Math.min(0.055, (home.width / home.height - 1.25) * 0.10))
        // The stack seats just above the key legend: centred, it left ~78 px
        // between CONTINUE and the legend on the CRT and more on DP-3 and the
        // laptop ("too large") — and the lower seat gives the spotlight's
        // info sheet more room to lift. (Never above the centred seat.)
        readonly property real stackTop:
            Math.max(Math.round((height - stackH) / 2),
                     Math.round(height - footerRow.anchors.bottomMargin - footerRow.height
                                - 28 * home.s - stackH))

        // Pointer over the background (nothing) retracts to the resting
        // spotlight — the card belongs to the wheel, so pointing at empty space
        // dismisses it. Sits behind everything (declared first) and is gated on
        // an active pointer, so it never fights keyboard nav when the mouse is
        // idle or hidden. Passes buttons through; hover only.
        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
            // Retract to the spotlight when pointing at empty space — BUT NOT
            // while continue is open. In XMB you leave a row by navigating UP
            // (onto the wheel / spotlight), never by the pointer grazing dead
            // space; letting empty-space hovers collapse continue is exactly what
            // made it feel like it was "running away" from the cursor. LONG
            // dwell: crossing the gaps between bays touches this area for a
            // few ms, and that must never retract an armed wheel.
            onEntered: if (App.pointerActive)
                           home.hoverIntent(function() {
                               if (home.spot.length > 0 && home.zone !== "cw")
                                   home.zoneName = "spot"
                           }, 260)
        }

        // ── Spotlight (top) ──────────────────────────────────────────────
        // Mouse reach for the spotlight: hovering focuses the zone, a click
        // opens its details — the pointer equivalent of walking up to it and
        // pressing i. Sits BEHIND the block so the carousel arrows (a child of
        // the block, drawn in front) still take their own clicks. Text items
        // don't consume clicks, so taps anywhere on the block land here.
        MouseArea {
            visible: home.spot.length > 0
            x: spotBlock.x; y: spotBlock.y
            width: spotBlock.width; height: spotBlock.height
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onEntered: if (App.pointerActive) home.hoverIntent(function() { home.zoneName = "spot" })
            onClicked: { home.hoverCancel(); home.zoneName = "spot"; home.openInfo() }
        }

        Column {
            id: spotBlock
            anchors.horizontalCenter: parent.horizontalCenter
            y: stage.stackTop
            width: Math.min(parent.width * 0.88, Math.round(880 * home.s))
            spacing: Math.round(6 * home.s)
            // Stays bright while browsing continue — it now BECOMES the focused
            // continue item (backdrop + logo + title), so it must read clearly.
            opacity: 1
            visible: home.spot.length > 0

            // (The "SPOTLIGHT" eyebrow was removed — the logo IS the identity;
            // a section label above the hero read redundant and un-premium.)
            // Title: the movie's clearlogo (dynamic title art) when we have one,
            // otherwise the text title. The logo art is TRIMMED to its glyphs (the
            // source is a fixed 800×310 canvas with the logo floated anywhere
            // inside — untrimmed, centring made squat/top-heavy logos ride high),
            // so BASELINE-aligning to the foot of a fixed slot lands every title
            // at the same line regardless of its size or shape. A very wide logo
            // is also height-capped so it never balloons across the whole block.
            Item {
                id: titleSlot
                anchors.horizontalCenter: parent.horizontalCenter
                width: parent.width
                height: Math.round(150 * home.s)
                readonly property bool hasLogo: home.heroLogo.length > 0
                // MOVE-page trim shifts logo and text title together
                transform: Translate { x: home.mOff("title")[0]; y: home.mOff("title")[1] }

                Image {
                    id: spotLogo
                    anchors.bottom: parent.bottom
                    anchors.horizontalCenter: parent.horizontalCenter
                    transform: Translate { x: home.mOff("logo")[0]; y: home.mOff("logo")[1] }
                    // a user pixel sprite (LOGO SPRITE dial) overrides the movie's
                    // own logo art; else the fetched logo; else nothing. Respects
                    // the HERO LOGO on/off toggle either way.
                    readonly property string sprite: home.mechOn ? home.spriteUrlFor(home.mech.logoSprite) : ""
                    // A logo that fails to LOAD (file vanished between scan and render, or
                    // a decode error) must fall back to the text title, not leave a blank/
                    // white slot — the Text below keys off !spotLogo.visible (#238).
                    visible: (sprite !== "" || titleSlot.hasLogo) && (!home.mechOn || home.mech.logoOn)
                             && status !== Image.Error
                    source: sprite !== "" ? sprite : (titleSlot.hasLogo ? Theme.art(home.heroLogo) : "")
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    cache: true
                    smooth: sprite === ""      // a pixel sprite renders crisp, unfiltered
                    mipmap: sprite === ""
                    // Height-first; a wide logo caps on width instead (never
                    // overflows the block). Driven off the logo's own (now
                    // trimmed) aspect ratio.
                    readonly property real asp: sourceSize.height > 0
                                                ? sourceSize.width / sourceSize.height : 3
                    readonly property real maxW: titleSlot.width * 0.9
                    readonly property real logoK: home.mechOn ? ({ s: 0.75, m: 1, l: 1.2, xl: 1.4 }[home.mech.logoMax] || 1) : 1
                    height: Math.min(titleSlot.height * logoK, maxW / Math.max(asp, 0.1))
                    width: height * asp
                }
                Text {
                    anchors.fill: parent
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    visible: !spotLogo.visible   // the title shows only when no logo/sprite does
                    text: home.mechOn ? home.caseFor(home.heroTitle, home.mech.titleCase) : home.heroTitle.toUpperCase()
                    color: home.mechOn && home.mech.titleInk !== "auto"
                         ? home.mechInk(home.mech.titleInk) : Theme.fg
                    font.family: home.mechOn ? home.mFontFor("title") : Theme.uiFont
                    font.pixelSize: home.pxi(Math.round(Math.max(24, Math.min(64, home.mSz(Math.round(home.width * 0.026), "titleSize"))) * home.mScale("title")))
                    font.weight: home.mechOn ? home.weightFor(home.mech.titleWeight) : Font.Light
                    font.letterSpacing: home.mechOn ? home.trackFor(home.mech.titleTrack) : 3
                    // A long title SHRINKS to fit rather than eliding — no "…"
                    // ever, and it stays centred (symmetric) at any length.
                    fontSizeMode: Text.HorizontalFit
                    minimumPixelSize: Math.max(20, Math.round(22 * home.s))
                    maximumLineCount: 1
                    style: home.mechOn && !home.mech.titleOutline ? Text.Normal : Text.Outline
                    styleColor: Theme.withAlpha(Theme.bg, 0.85)
                }
            }
            // Meta line, Kodi-style: the media-flag badges (4K · HDR/DV · audio)
            // sit INLINE, ahead of year · runtime · genre · rating — one row, so
            // the badges read as part of the meta, not a stacked strip above it.
            Row {
                id: metaRow
                property real badgeT: 1
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.horizontalCenterOffset: home.mOff("meta")[0]
                transform: Translate { y: home.mOff("meta")[1] }
                spacing: Math.round(8 * home.s * (home.mechOn ? ({ tight: 0.6, normal: 1, wide: 1.5 }[home.mech.metaGap] || 1) : 1))
                // Chips come from the file's OWN streams (library probe), never
                // the release name — see Library::probeFlags.
                readonly property var flags: (home.heroItem && home.heroItem.flags) ? home.heroItem.flags : []
                // When badges are present the row is as tall as the badge BOX, so
                // row-centre = box-centre — but the badge LABEL sits lower, in the
                // readout window. Drop the text bits by that in-badge offset so the
                // meta run lands on the badge-label line (one straight line). No
                // badges → no drop (row is just text height).
                readonly property int badgeDrop: (home.mechOn && flags.length > 0 && home.mech.chipStyle !== "none")
                    ? Math.round(chipProbe.labelDrop) : 0
                // the chips' own geometry, for that drop (never drawn; a Row skips it)
                MechChip { id: chipProbe; visible: false; px: home.chipPx
                           plateStyle: home.mechOn ? home.mech.chipStyle : "chip" }

                Repeater {
                    // The media-flag badges ride mech chip plates — the
                    // banded hull steel, not a themed pill. Their own pixel
                    // scale: chips are furniture next to 12u meta text, so
                    // they step to 2 later than the card does.
                    model: home.mechOn ? metaRow.flags : []
                    delegate: MechChip {
                        required property var modelData
                        required property int index
                        // chips deal in one at a time on each new title
                        opacity: Math.min(1, Math.max(0, metaRow.badgeT * (metaRow.flags.length + 1) - index))
                        anchors.verticalCenter: parent.verticalCenter
                        px: home.chipPx
                        window: home.mech.chipWin
                        plateStyle: home.mech.chipStyle
                        flag: modelData          // raw flag → picks the per-format badge plate
                        ink: home.mechInk(home.mech.chipInk)
                        text: home.caseFor(modelData, home.mech.chipCase)
                        font.family: home.mFontFor("chip")
                        font.pixelSize: home.pxi(Math.round(Math.max(9, home.mSz(Math.round(10 * home.s), "chipSize")) * home.mScale("meta")))
                        font.letterSpacing: home.trackFor(home.mech.chipTrack)
                        font.weight: home.weightFor(home.mech.chipWeight)
                    }
                }
                Repeater {
                    // CLASSIC badges — the pre-import themed pills, exact,
                    // for the editor's back-to-back
                    model: home.mechOn ? [] : metaRow.flags
                    delegate: Rectangle {
                        required property var modelData
                        required property int index
                        opacity: Math.min(1, Math.max(0, metaRow.badgeT * (metaRow.flags.length + 1) - index))
                        anchors.verticalCenter: parent.verticalCenter
                        height: Math.round(20 * home.s)
                        width: bLbl.implicitWidth + Math.round(14 * home.s)
                        radius: Math.round(3 * home.s)
                        color: Theme.withAlpha(Theme.bg, 0.5)
                        border.width: 1
                        border.color: Theme.withAlpha(Theme.fg, 0.28)
                        Text {
                            id: bLbl
                            anchors.centerIn: parent
                            text: modelData
                            color: Theme.withAlpha(Theme.fg, 0.92)
                            font.family: Theme.monoFont
                            font.pixelSize: home.pxi(Math.max(9, Math.round(10 * home.s)))
                            font.letterSpacing: 1
                            font.weight: Font.DemiBold
                        }
                    }
                }
                // The readings, as data: mech mode renders them as segments
                // with a MechSep at EVERY joint (the separator dial swaps
                // them all at once); classic keeps the original single run.
                readonly property var metaBits: {
                    const it = home.heroItem
                    if (!it) return []
                    let bits = []
                    if (it.year > 0) bits.push(String(it.year))
                    if (it.runtimeMin > 0)
                        bits.push(it.runtimeMin >= 60
                                  ? Math.floor(it.runtimeMin / 60) + "H" + (it.runtimeMin % 60) + "M"
                                  : it.runtimeMin + "M")
                    if (it.kind === "show") bits.push("SERIES")
                    const g = it.genres.split("/").map(x => x.trim()).filter(x => x.length > 0)
                    for (const gg of g.slice(0, 2)) bits.push(gg.toUpperCase())
                    return bits
                }
                // rating pulled OUT of the bits so it's an individually movable element
                readonly property real ratingVal: home.heroItem ? (home.heroItem.rating || 0) : 0
                Repeater {
                    model: home.mechOn ? metaRow.metaBits : []
                    delegate: Row {
                        required property var modelData
                        required property int index
                        // center on the metaRow line like the badges + rating do
                        // (without this the meta bits sit top-aligned = ride high),
                        // then drop onto the badge-label line
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.verticalCenterOffset: metaRow.badgeDrop
                        spacing: Math.round(8 * home.s)
                        MechSep {
                            visible: index > 0 || metaRow.flags.length > 0
                            anchors.verticalCenter: parent.verticalCenter
                            style: home.mech.sep
                            px: home.chipPx
                            fontPx: Math.round(Math.max(9, home.mSz(Math.round(12 * home.s), "metaSize")) * home.mScale("meta"))
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: home.caseFor(modelData, home.mech.metaCase)
                            color: home.mech.metaInk === "auto"
                                 ? Theme.withAlpha(Theme.fg, 0.82)
                                 : Theme.withAlpha(home.mechInk(home.mech.metaInk), 0.92)
                            font.family: home.mFontFor("meta")
                            font.weight: home.weightFor(home.mech.metaWeight)
                            font.pixelSize: home.pxi(Math.round(Math.max(9, home.mSz(Math.round(12 * home.s), "metaSize")) * home.mScale("meta")))
                            font.letterSpacing: home.trackFor(home.mech.metaTrack)
                            style: home.mech.metaOutline ? Text.Outline : Text.Normal
                            styleColor: Theme.withAlpha(Theme.bg, 0.7)
                        }
                    }
                }
                Row {  // RATING — its own movable element (pulled from the meta bits), aligned to the run
                    id: ratingText
                    visible: home.mechOn && metaRow.ratingVal > 0
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.verticalCenterOffset: metaRow.badgeDrop
                    transform: Translate { x: home.mOff("rating")[0]; y: home.mOff("rating")[1] }
                    spacing: Math.round(8 * home.s)
                    MechSep { anchors.verticalCenter: parent.verticalCenter; style: home.mech.sep; px: home.chipPx
                              fontPx: Math.round(Math.max(9, home.mSz(Math.round(12 * home.s), "metaSize")) * home.mScale("rating")) }
                    Row {  // ★ + number CENTERED on each other (box centres aligned, not baseline)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Math.round(4 * home.s)
                        readonly property color rc: home.mech.metaInk === "auto" ? Theme.withAlpha(Theme.fg, 0.82) : Theme.withAlpha(home.mechInk(home.mech.metaInk), 0.92)
                        readonly property int rsz: Math.round(Math.max(9, home.mSz(Math.round(12 * home.s), "metaSize")) * home.mScale("rating"))
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "★"; color: parent.rc
                            font.family: home.mFontFor("meta"); font.weight: home.weightFor(home.mech.metaWeight); font.pixelSize: home.pxi(parent.rsz)
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: metaRow.ratingVal.toFixed(1); color: parent.rc
                            font.family: home.mFontFor("meta"); font.weight: home.weightFor(home.mech.metaWeight); font.pixelSize: home.pxi(parent.rsz)
                            font.letterSpacing: home.trackFor(home.mech.metaTrack)
                        }
                    }
                }
                Text {  // CLASSIC joint between badges and the run
                    anchors.verticalCenter: parent.verticalCenter
                    visible: metaRow.flags.length > 0 && !home.mechOn
                    text: "·"
                    color: Theme.withAlpha(Theme.fg, 0.45)
                    font.family: Theme.monoFont
                    font.pixelSize: home.pxi(Math.max(11, Math.round(12 * home.s)))
                }
                Text {  // CLASSIC meta run — the original single string,
                    // original algorithm (genres joined tight)
                    visible: !home.mechOn
                    anchors.verticalCenter: parent.verticalCenter
                    text: {
                        const it = home.heroItem
                        if (!it) return ""
                        let bits = []
                        if (it.year > 0) bits.push(it.year)
                        if (it.runtimeMin > 0)
                            bits.push(it.runtimeMin >= 60
                                      ? Math.floor(it.runtimeMin / 60) + "H" + (it.runtimeMin % 60) + "M"
                                      : it.runtimeMin + "M")
                        if (it.kind === "show") bits.push("SERIES")
                        const g = it.genres.split("/").map(x => x.trim()).filter(x => x.length > 0)
                        if (g.length > 0) bits.push(g.slice(0, 2).join(" · ").toUpperCase())
                        if (it.rating > 0) bits.push("★ " + it.rating.toFixed(1))
                        return bits.join("   ·   ")
                    }
                    color: Theme.withAlpha(Theme.fg, 0.82)
                    font.family: Theme.monoFont
                    font.pixelSize: home.pxi(Math.max(11, Math.round(12 * home.s)))
                    font.letterSpacing: 2
                    style: Text.Outline
                    styleColor: Theme.withAlpha(Theme.bg, 0.7)
                }
            }
            // Short accent rule — draws IN from the centre on each new title,
            // the "seated" tick that anchors the block to the instrument.
            Item {
                visible: !home.mechOn || home.mech.ruleOn
                anchors.horizontalCenter: parent.horizontalCenter
                width: spotRule.fullW
                height: Math.max(2, Math.round(3 * home.s * (home.mechOn ? ({ s: 0.6, m: 1, l: 1.6 }[home.mech.ruleThick] || 1) : 1)))
                Rectangle {  // contrast bed — a dark seat under the rule so
                    // the darker line stays legible on hot, bright art
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: spotRule.width + 2; height: parent.height + 2
                    y: -1; radius: height / 2
                    color: Theme.withAlpha(Theme.bg, 0.5)
                    visible: spotRule.width > 1
                }
                Rectangle {
                    id: spotRule
                    anchors.horizontalCenter: parent.horizontalCenter
                    // spans the full info row (badges + meta), tracked LIVE so
                    // async-loading flags can't leave it stale; drawT keeps the
                    // centre-out draw-in on every new title. Drawn EXACTLY like
                    // the wheel slots' base tick: solid accent, rounded ends.
                    property real drawT: 1
                    readonly property real fullW: metaRow.width + Math.round(10 * home.s)
                    readonly property color baseCol: home.mechOn ? (home.mech.ruleInk === "auto" ? home.homeAccent : home.mechInk(home.mech.ruleInk)) : Theme.accent
                    width: fullW * drawT
                    height: parent.height
                    radius: height / 2
                    // a step darker than the slots' tick: this line SEATS the
                    // info block, it doesn't compete with it
                    color: Qt.darker(baseCol, 1.45)
                    transform: [
                        Translate { x: home.mOff("rule")[0]; y: home.mOff("rule")[1] },   // MOVE-page nudge
                        Scale {
                            id: spotRuleStamp
                            origin.y: spotRule.height / 2
                            yScale: 1
                        }
                    ]
                }
                Rectangle {  // twin pens leading the centre-out draw — they
                    // taper as the line completes and step out in two beats
                    x: spotRule.x - width - 1
                    width: Math.round(4 * home.s) * (1 - spotRule.drawT * 0.45); height: parent.height
                    radius: height / 2
                    color: Qt.darker(spotRule.baseCol, 1.15)
                    opacity: spotRule.drawT > 0.9 ? 0.5 : 1
                    visible: spotRule.drawT > 0.02 && spotRule.drawT < 0.97
                }
                Rectangle {
                    x: spotRule.x + spotRule.width + 1
                    width: Math.round(4 * home.s) * (1 - spotRule.drawT * 0.45); height: parent.height
                    radius: height / 2
                    color: Qt.darker(spotRule.baseCol, 1.15)
                    opacity: spotRule.drawT > 0.9 ? 0.5 : 1
                    visible: spotRule.drawT > 0.02 && spotRule.drawT < 0.97
                }
            }
            // Carousel affordance: fades in only when the spotlight is the
            // active zone, but always occupies its line so the centred stack
            // doesn't jump as you move between zones.
            Text {
                id: spotCrumb
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.horizontalCenterOffset: home.mOff("crumb")[0]
                transform: Translate { y: home.mOff("crumb")[1] }
                visible: home.spot.length > 1 && (!home.mechOn || home.mech.carouselOn)
                opacity: (home.zone === "spot" && !home.spotInfoOpen) ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: DS.base } }
                text: home.mechOn ? home.caseFor("‹ h   " + (home.spotIdx + 1) + " / " + home.spot.length + "   l ›", home.mech.crumbCase)
                                  : "‹ h   " + (home.spotIdx + 1) + " / " + home.spot.length + "   l ›"
                color: home.mechOn && home.mech.crumbInk !== "auto" ? home.mechInk(home.mech.crumbInk) : Theme.withAlpha(Theme.fg, 0.55)
                font.family: home.mechOn ? home.mFontFor("crumb") : Theme.monoFont
                font.weight: home.mechOn ? home.weightFor(home.mech.crumbWeight) : Font.Normal
                font.pixelSize: home.pxi(Math.round(Math.max(9, home.mSz(Math.round(10 * home.s), "crumbSize")) * home.mScale("crumb")))
                font.letterSpacing: home.mechOn ? home.trackFor(home.mech.crumbTrack) : 2
                // Left half steps back, right half steps forward — the arrows
                // you see are the arrows you click.
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -Math.round(6 * home.s)
                    enabled: home.zone === "spot" && !home.spotInfoOpen
                    cursorShape: Qt.PointingHandCursor
                    onClicked: (m) => home.spotCycle(m.x < width / 2 ? -1 : 1)
                }
            }

            // New item: the whole block re-settles as the art crossfades, and
            // the accent rule draws in — actuated, then damped (MGS ease-out).
            Connections {
                target: home
                function onSpotIdxChanged() { spotReveal.restart() }
            }
            property double yOff: 0
            // yOff is the carousel re-settle; the second Translate is the lift
            // that opens room for the description below.
            transform: [
                Translate { y: spotBlock.yOff },
                Translate { y: -home.infoRise * home.infoT },
                // Drop toward the wheel when the card isn't deployed, so the
                // title seats just above the wheel instead of over an empty slot.
                Translate { y: home.spotDrop },
                // Step up while browsing continue, opening room for the posters.
                Translate { y: -home.cwRise },
                // INFO DROP: slide the whole open-info cluster down toward the wheel.
                Translate { y: home.infoDropPx },
                // SPOT Y: a universal nudge of the whole spotlight, every state.
                Translate { y: home.spotNudgePx }
            ]
            ParallelAnimation {
                id: spotReveal
                NumberAnimation { target: spotBlock; property: "yOff"; from: 14; to: 0; duration: DS.grand; easing.type: Easing.Bezier; easing.bezierCurve: DS.enterCurve }
                NumberAnimation { target: metaRow; property: "badgeT"; from: 0; to: 1; duration: DS.slow }
                SequentialAnimation {
                    // one continuous fluid draw, centre-out on the house
                    // curve — the pens carry the motion, nothing stutters
                    PauseAnimation { duration: DS.quick }
                    NumberAnimation { target: spotRule; property: "drawT"; from: 0; to: 1; duration: DS.grand; easing.type: Easing.Bezier; easing.bezierCurve: DS.enterCurve }
                    // the landing STAMP — one soft press as the line seats
                    PropertyAction { target: spotRuleStamp; property: "yScale"; value: 1.3 }
                    PauseAnimation { duration: 70 }
                    PropertyAction { target: spotRuleStamp; property: "yScale"; value: 1 }
                }
            }
        }

        // ── Wheel (middle) ───────────────────────────────────────────────
        // The whole card+wheel unit is centred on the stage, biased slightly
        // below middle so the spotlight has room to breathe above it.
        Item {
            id: wheelUnit
            width: home.wheelW
            height: home.cardH + gap + home.wheelH
            anchors.horizontalCenter: parent.horizontalCenter
            y: stage.stackTop + stage.spotH + stage.gapTop
            // Eases back while the spotlight is expanded — present but not gone
            // (a gentle dim now); steps further back while browsing continue.
            opacity: home.spotInfoOpen ? 0.72 : (home.cwDeployed ? 0.5 : 1)   // dim on DEPLOY, not on a bare hover
            Behavior on opacity { NumberAnimation { duration: DS.slow; easing.type: Easing.OutQuint } }
            // Rise into the hidden card's space (info), and step up while browsing
            // continue so the posters get real room below.
            transform: [
                Translate { y: -home.infoWheelRise },
                Translate { y: -home.cwRise }
            ]

            readonly property int gap: Math.round(10 * home.s)
            // Centre-x of the focused slot, within the wheel row (x:0).
            readonly property real focusCenterX: home.secIdx * (home.slotW + home.slotGap)
                                                 + home.slotW / 2

            // Detail card — a HUD readout that tracks the focused slot: index ·
            // section name over a drawn rule, with the count beneath. Tracks
            // with a deliberate OutQuint slide, clamped to the wheel's span, and
            // VANISHES when you drop to the continue shelf (it belongs to the
            // wheel, not the row below it).
            Item {
                id: card
                width: home.cardW
                height: home.cardH
                // Card follows the focused slot with an offset-to-the-RIGHT lean. Two anchors:
                //   xCentred  — slot CENTRE under the card centre (reads "straight overtop")
                //   xLeft     — slot LEFT edge under the card left edge (card flies fully right)
                // cardLean blends them (0 = centred, 1 = left-aligned). ~0.6 seats the focused
                // column under the card's left third: clearly leaning right, still overlapping the
                // wheel (not stranded in the margin). Clamped 0..stage-edge; the card isn't clipped
                // by the wheel, so the right bound is the STAGE edge, not the (narrower) wheel edge —
                // clamping to the wheel pinned youtube/stats/settings to one spot and killed the lean.
                readonly property real cardLean: home.mech.cardLean !== undefined ? home.mech.cardLean : 0.6
                readonly property real xCentred: wheelUnit.focusCenterX - width / 2
                readonly property real xLeft: home.secIdx * (home.slotW + home.slotGap)
                readonly property real maxX: (wheelUnit.parent.width + home.wheelW) / 2 - width - Math.round(24 * home.s)
                x: Math.max(0, Math.min(maxX, xCentred + (xLeft - xCentred) * cardLean))
                y: 0
                // The card is the wheel's readout: it deploys only while the
                // wheel is engaged, and is GONE (not just dimmed) otherwise.
                readonly property bool shown: home.wheelEngaged
                opacity: home.cardShow
                visible: opacity > 0.01
                // Deploy choreography, dial-selected. Mech default is SIDE:
                // the card slides in from the wing with a hair of drop — the
                // way a readout card enters this kind of menu — while classic
                // keeps the original drop-from-the-spotlight. One driver
                // (cardT) so slide, scale and fade read as a single motion.
                readonly property string anim: home.mechOn ? home.mech.cardAnim : "drop"
                transform: [
                    Translate { x: home.mOff("cardPlate")[0]; y: home.mOff("cardPlate")[1] },   // CARD PLATE move
                    Rotation {   // swing / spin / hinge entrances
                        origin.x: card.width / 2
                        origin.y: card.anim === "hinge" ? card.height : 0
                        angle: card.anim === "swing" ? (1 - home.cardShow) * -8
                             : card.anim === "spin" ? (1 - home.cardShow) * -90
                             : card.anim === "hinge" ? (1 - home.cardShow) * 22
                             : 0
                    },
                    Translate {
                        x: card.anim === "side" ? (1 - home.cardShow) * -Math.round(46 * home.s) : 0
                        y: card.anim === "drop" ? (1 - home.cardShow) * -Math.round(22 * home.s)
                         : card.anim === "rise" ? (1 - home.cardShow) * Math.round(22 * home.s)
                         : card.anim === "side" ? (1 - home.cardShow) * -Math.round(6 * home.s) : 0
                    },
                    Scale {
                        origin.x: card.width / 2
                        origin.y: card.anim === "iris" ? card.height / 2 : 0
                        xScale: card.anim === "pop" ? 0.9 + 0.1 * home.cardShow
                              : card.anim === "zoom" ? 0.8 + 0.2 * home.cardShow
                              : card.anim === "iris" ? 0.4 + 0.6 * home.cardShow
                              : card.anim === "slam" ? 1.2 - 0.2 * home.cardShow
                              : 0.97 + 0.03 * home.cardShow
                        yScale: card.anim === "pop" ? 0.9 + 0.1 * home.cardShow
                              : card.anim === "zoom" ? 0.8 + 0.2 * home.cardShow
                              : card.anim === "unfold" ? 0.15 + 0.85 * home.cardShow
                              : card.anim === "iris" ? 0.4 + 0.6 * home.cardShow
                              : card.anim === "slam" ? 1.2 - 0.2 * home.cardShow
                              : 0.97 + 0.03 * home.cardShow
                    }
                ]
                // Its readout re-assembles each time it deploys.
                onShownChanged: if (shown) cardReveal.restart()
                // The card TRAVELS across the wheel to the focused slot — the
                // house gantry move (pick up, then damp), not an instant jerk.
                Behavior on x { NumberAnimation { duration: home.resizing ? 120 : Math.round(DS.slow * home.mechAnimK); easing.type: Easing.Bezier; easing.bezierCurve: DS.moveCurve } }

                // ── The readout, dual chrome ─────────────────────────────
                // MECH: a hull plate carries the two-zone anatomy — light
                // band (or title bracket) over dark body — and every datum
                // line comes off the dialled-in plate's ART grid (nL left
                // datum, nameBox bracket seating, band/floor rows).
                // CLASSIC: the pre-import instrument, kept EXACT for the
                // editor's back-to-back — Panel base, hand-painted band,
                // machined glass, hairline, rule + pen.
                readonly property int bandArt: cardPlateBg.plate.band
                readonly property int bandH: home.mechOn
                    ? (bandArt > 0 ? bandArt : 12) * home.mpx
                    : Math.round(28 * home.s)
                readonly property int bodyBot: home.mechOn
                    ? height - cardPlateBg.plate.floor * home.mpx : height
                readonly property var nameBox: home.mechOn
                    ? (cardPlateBg.plate.nameBox || null) : null
                readonly property int nameL: home.mechOn
                    ? cardPlateBg.plate.nL * home.mpx : Math.round(16 * home.s)
                readonly property color nameInk:
                    !home.mechOn ? (home.zone === "wheel" ? Qt.lighter(Theme.accent, 1.32) : Theme.accent)
                    : home.mech.nameInk !== "auto" ? home.mechInk(home.mech.nameInk)
                    : (bandArt > 0 || nameBox) ? "#222034" : "#dce8ef"
                MechPanel {
                    id: cardPlateBg
                    visible: home.mechOn
                    kind: home.mech.cardPlate
                    // match the WHEEL plate's pixel scale (was mpx=3 → 3px border, too heavy next to
                    // the wheel's 2px); keeps the 8-bit corner style, just at the wheel's crispness
                    px: home.s >= 1.15 ? 2 : 1
                    dev: true   // hot-reload panel-cardframe.png (and any plate) live
                    anchors.fill: parent
                    // Same machined-glass translucency as the wheel bays' resting
                    // plate (slotPanel MechPanel, opacity 0.82) so the backdrop reads
                    // through the card the same way — one glass treatment, not two.
                    opacity: 0.82
                }
                Panel {  // CLASSIC base — the original card panel
                    visible: !home.mechOn
                    anchors.fill: parent
                    active: home.zone === "wheel"
                    color: Theme.withAlpha(Theme.surface, 0.94)
                }
                Item {  // CLASSIC header band
                    visible: !home.mechOn
                    x: 1; y: 1; width: parent.width - 2; height: Math.round(28 * home.s)
                    clip: true
                    Rectangle {
                        width: parent.width; height: parent.height + 12
                        radius: 11
                        color: Theme.withAlpha(Theme.bg, 0.22)
                    }
                }
                Rectangle {  // CLASSIC machined-glass top light
                    visible: !home.mechOn
                    anchors.fill: parent; anchors.margins: 1; radius: 12
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: Theme.withAlpha(Theme.fg, 0.06) }
                        GradientStop { position: 0.16; color: "transparent" }
                    }
                }
                Rectangle {  // CLASSIC inner hairline
                    visible: !home.mechOn
                    anchors.fill: parent; anchors.margins: 3; radius: 10
                    color: "transparent"
                    border.width: 1
                    border.color: Theme.withAlpha(Theme.fg, 0.08)
                }
                Rectangle {  // CLASSIC contact shade
                    visible: !home.mechOn
                    x: 1; y: parent.height - 2.5
                    width: parent.width - 2; height: 1.5
                    color: Theme.withAlpha(Theme.bg, 0.4)
                }

                Text {  // invisible twin carrying the FULL label — the stable
                    // measure that seats the centered title and sizes the rule
                    id: cNameFull
                    visible: false
                    text: home.mechOn ? home.caseFor(home.curSec.label, home.mech.nameCase) : home.curSec.label
                    font.family: home.mechOn ? home.mFontFor("name") : Theme.monoFont
                    font.weight: home.mechOn ? home.weightFor(home.mech.nameWeight) : Font.Bold
                    font.pixelSize: home.pxi(Math.round(Math.max(11, home.mSz(Math.round(15 * home.s), "nameSize")) * home.mScale("name")))
                    font.letterSpacing: home.mechOn ? home.trackFor(home.mech.nameTrack) : 2
                }
                Item {  // CARD NAME backing (dial: nameBack) — a plate / panel / frame / button behind the section name
                    id: cNameBack
                    visible: home.mechOn && home.mech.nameBack !== undefined && home.mech.nameBack !== "none"
                    readonly property real padX: Math.round(9 * home.s)
                    readonly property real padY: Math.round(4 * home.s)
                    width: cNameFull.contentWidth + 2 * padX
                    height: cName.height + 2 * padY
                    x: cName.x + cNameFull.contentWidth / 2 - width / 2
                    y: cName.y + cName.height / 2 - height / 2
                    z: -1
                    MechPanel { visible: home.mech.nameBack === "chip"; kind: "chip"; anchors.fill: parent; px: home.mpx }
                    MechPanel { visible: home.mech.nameBack === "body"; kind: "body"; anchors.fill: parent; px: home.mpx }
                    MechPanel { visible: home.mech.nameBack === "frame"; kind: "frame"; anchors.fill: parent; px: home.mpx }
                    Rectangle { visible: home.mech.nameBack === "bar"; anchors.fill: parent; radius: 2
                        color: Theme.withAlpha("#222034", 0.82); border.width: 1; border.color: Theme.withAlpha(home.homeAccent, 0.45) }
                    MechButton { visible: String(home.mech.nameBack).charAt(0) === "b"; anchors.fill: parent
                        family: parseInt(String(home.mech.nameBack).substring(1)) || 1; px: home.mpx; hot: false }
                }
                Text {  // the section name TYPES in — start burst, then steady.
                    // Mech: stamped on the plate's own datum — left band, or
                    // centred INSIDE a title bracket when the plate carries
                    // one (wide). Classic: the original accent readout that
                    // lights with the wheel.
                    id: cName
                    // snap to WHOLE pixels — the move-offset can be fractional, and a sub-pixel x/y
                    // makes the glyphs sample softly (reads as a faint tilt/wobble on the pixel font)
                    x: Math.round((card.nameBox
                       ? card.width - card.nameBox[0] * home.mpx
                         + Math.round((card.nameBox[1] * home.mpx - cNameFull.contentWidth) / 2)
                       : card.nameL) + home.mOff("name")[0])
                    y: Math.round((home.mechOn ? Math.round((card.bandH - height) / 2)
                                    : Math.round(9 * home.s)) + home.mOff("name")[1])
                    property int tc: 99
                    text: (home.mechOn ? home.caseFor(home.curSec.label, home.mech.nameCase) : home.curSec.label).substring(0, tc)
                    color: card.nameInk
                    Behavior on color { ColorAnimation { duration: DS.base } }
                    font.family: home.mechOn ? home.mFontFor("name") : Theme.monoFont
                    font.weight: home.mechOn ? home.weightFor(home.mech.nameWeight) : Font.Bold
                    font.pixelSize: home.pxi(Math.round(Math.max(11, home.mSz(Math.round(15 * home.s), "nameSize")) * home.mScale("name")))
                    font.letterSpacing: home.mechOn ? home.trackFor(home.mech.nameTrack) : 2
                }
                Rectangle {  // navy WELL for the LED — green on light steel
                    // has no contrast, so the lamp gets a machined recess,
                    // the way the plate's own ticks sit in their block.
                    visible: home.mechOn && cLive.visible && home.mech.ledWell
                    x: cLive.x - home.mpx
                    y: cLive.y - home.mpx
                    width: cLive.width + 2 * home.mpx
                    height: cLive.height + 2 * home.mpx
                    color: home.mechInk(home.mech.ledWellInk)
                    opacity: cLive.opacity
                }
                Rectangle {  // live LED — the readout is receiving. Light
                    // GREEN (or whatever the lamp dial says): the one
                    // deliberate colour on the deck, the PS1 power-light.
                    // On a bracket-titled plate (wide) it sits just LEFT of
                    // the bracket — there's no room inside the box.
                    id: cLive
                    visible: !home.mechOn || home.mech.ledOn
                    x: (card.nameBox
                       ? card.width - card.nameBox[0] * home.mpx - Math.round(10 * home.s) - width
                       : cName.x + cNameFull.contentWidth + Math.round(8 * home.s) + (home.mechOn ? home.mpx : 0))
                       + home.mOff("lamp")[0]
                    anchors.verticalCenter: cName.verticalCenter
                    anchors.verticalCenterOffset: Math.round(-0.5 * home.s) + home.mOff("lamp")[1]
                    readonly property real ledK: home.mechOn ? ({ s: 0.7, m: 1, l: 1.4, xl: 1.8 }[home.mech.ledSize] || 1) : 1
                    width: Math.round(3 * home.s * ledK); height: Math.round(3 * home.s * ledK)
                    radius: home.mechOn ? (home.mech.ledShape === "round" ? width / 2 : 0) : 1
                    property real breath: 1
                    readonly property real beatK: home.mechOn ? ({ slow: 1.6, normal: 1, fast: 0.6 }[home.mech.ledBeat] || 1) : 1
                    // lights only once the title has finished typing — the
                    // section comes online when its name is entered
                    opacity: cName.tc >= home.curSec.label.length ? 1 : 0
                    // BREATHING, not blinking — the one organic motion on the
                    // deck: a slow ~3s swell, the PS1 standby light. The
                    // lamp's colour is a dial in mech chrome.
                    color: Theme.withAlpha(home.mechOn ? home.mechInk(home.mech.led) : "#8fe3a1",
                                           home.zone === "wheel" ? 0.3 + 0.55 * breath : 0.2)
                    SequentialAnimation {
                        running: home.visible && cLive.visible && home.zone === "wheel" && (!home.mechOn || home.mech.ledBeat !== "off")
                        loops: Animation.Infinite
                        NumberAnimation { target: cLive; property: "breath"; to: 0; duration: Math.round(1600 * cLive.beatK); easing.type: Easing.InOutSine }
                        NumberAnimation { target: cLive; property: "breath"; to: 1; duration: Math.round(1400 * cLive.beatK); easing.type: Easing.InOutSine }
                    }
                }
                // OPEN as a key-cap chip — debossed, two-tone, edge-aligned
                // with the rule below.
                Row {  // [⏎] OPEN — keycap prompt. It ARRIVES like the rest
                    // of the readout: the key presses in, the word types on.
                    // Mech: in the BODY (the plate's tick block owns the
                    // band's right corner), hull ink. Classic: in the band
                    // beside the name, themed keycap — the original.
                    id: cChip
                    readonly property bool hot: home.zone === "wheel"
                    property real press: 0
                    property int otc: home.mechOn ? String(home.mech.openLabel).length : 4
                    anchors.right: parent.right
                    anchors.rightMargin: Math.round(14 * home.s) - home.mOff("open")[0]
                    anchors.verticalCenter: home.mechOn ? cSub.verticalCenter : cName.verticalCenter
                    anchors.verticalCenterOffset: home.mOff("open")[1]
                    spacing: Math.round(6 * home.s)
                    // FULL assembly scale: the whole chip (keycap + glyph + label) scales, not just
                    // the label. Origin at the right-centre so it stays pinned to its anchored edge.
                    scale: home.mechOn ? home.mScale("open") : 1
                    transformOrigin: Item.Right
                    Rectangle {
                        id: cKeycap
                        width: Math.round(16 * home.s); height: Math.round(16 * home.s)
                        radius: home.mechOn ? 0 : Math.round(3 * home.s)
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.verticalCenterOffset: Math.round(cChip.press * 1.5)
                        color: home.mechOn ? "#222034" : Theme.withAlpha(Theme.bg, 0.5)
                        border.width: 1
                        border.color: home.mechOn
                            ? Theme.withAlpha(home.mech.openKeyInk === "auto" ? "#aecbd9" : home.mechInk(home.mech.openKeyInk), (cChip.hot ? 0.7 : 0.35) + cChip.press * 0.3)
                            : Theme.withAlpha(Theme.accent, (cChip.hot ? 0.6 : 0.25) + cChip.press * 0.35)
                        Behavior on border.color { ColorAnimation { duration: DS.base } }
                        Rectangle {  // keycap deboss
                            x: 2; y: parent.height - 2
                            width: parent.width - 4; height: 1
                            color: home.mechOn ? "#1a1828" : Theme.withAlpha(Theme.bg, 0.6)
                        }
                        ReturnGlyph {
                            anchors.centerIn: parent
                            anchors.verticalCenterOffset: Math.max(1, Math.round(home.s))
                            width: Math.round(8 * home.s); height: Math.round(8 * home.s)
                            color: home.mechOn
                                ? (cChip.hot ? "#dce8ef" : Theme.withAlpha("#dce8ef", 0.6))
                                : (cChip.hot ? Theme.withAlpha(Theme.fg, 0.74) : Theme.withAlpha(Theme.fg, 0.55))
                        }
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.verticalCenterOffset: 1
                        text: (home.mechOn ? String(home.mech.openLabel) : "OPEN").substring(0, cChip.otc)
                        color: home.mechOn && home.mech.openInk !== "auto"
                            ? Theme.withAlpha(home.mechInk(home.mech.openInk), cChip.hot ? 1 : 0.7)
                            : home.mechOn
                            ? (cChip.hot ? "#dce8ef" : Theme.withAlpha("#dce8ef", 0.55))
                            : Theme.withAlpha(Theme.fg, cChip.hot ? 0.78 : 0.45)
                        font.family: home.mechOn ? home.mFontFor("open") : Theme.monoFont
                        font.weight: home.mechOn ? home.weightFor(home.mech.openWeight) : Font.Bold
                        font.pixelSize: home.pxi(Math.max(8, home.mSz(Math.round(10 * home.s), "openSize")))   // whole-chip scale (mScale) is on cChip now
                        font.letterSpacing: home.mechOn ? home.trackFor(home.mech.openTrack) : 2.5
                        Behavior on color { ColorAnimation { duration: DS.base } }
                    }
                }
                Rectangle {  // animated rule under the title — sized TO the title and drawn in a
                    // beat after it types (drawT, driven by cardReveal). Classic's label-rule
                    // grammar, now also the mech card's answer to the wheel-slot underline.
                    id: cRule
                    visible: true
                    property real drawT: 1
                    readonly property real fullW: cNameFull.contentWidth + Math.round(4 * home.s)
                    // move + scale as an assembly element (key "cardrule") in mech chrome. Track the
                    // title's BASE position/size (cName minus its OWN move offset) so nudging the
                    // title does NOT drag the rule — only its own "cardrule" offset moves it.
                    x: (home.mechOn ? cName.x - home.mOff("name")[0] : Math.round(16 * home.s)) + home.mOff("cardrule")[0]
                    // mech: a hair under the (fitted) title; classic: the original 31.5u line
                    y: (home.mechOn ? Math.round(cName.y - home.mOff("name")[1] + cName.height + 1 * home.s) + 1 : Math.round(31.5 * home.s)) + home.mOff("cardrule")[1]
                    width: fullW * drawT * home.mScale("cardrule")
                    height: Math.max(1, Math.round(1.5 * home.s))
                    radius: height / 2
                    color: home.mechOn ? "#9ea3ac" : Theme.withAlpha(Theme.accent, 0.6)
                }
                Rectangle {  // CLASSIC pen leading the rule's draw
                    visible: !home.mechOn && cRule.drawT < 0.99
                    x: cRule.x + cRule.width
                    y: cRule.y - 1.5
                    width: Math.round(4 * home.s)
                    height: cRule.height + 2
                    color: Theme.accent
                }
                // The reading: number COUNTS UP bright, unit sits quiet — a
                // measured value with its dimension, not a caption.
                readonly property var subParts: {
                    const m = String(home.curSec.sub).match(/^([0-9]+)\s*(.*)$/)
                    return m ? [parseInt(m[1]), m[2]] : [-1, String(home.curSec.sub)]
                }
                // a "A · B · C" reading (no leading count) draws its separators as vertically
                // CENTRED dots (an inline "·" glyph sits off-centre); single-word units stay plain.
                readonly property bool hasSep: subParts[0] < 0 && String(subParts[1]).indexOf(" · ") >= 0
                property int cnt: 0
                Item {
                    id: cSub
                    x: (home.mechOn && !card.nameBox ? card.nameL : Math.round(16 * home.s))
                       + home.mOff("read")[0]
                    // mech: dead centre of the plate's dark body zone (band
                    // foot to bottom chrome), on the plate's left datum.
                    // classic: the original 42u line.
                    y: (home.mechOn ? Math.round((card.bandH + card.bodyBot - cNum.height) / 2)
                                    : Math.round(42 * home.s)) + home.mOff("read")[1]
                    height: cNum.height
                    // the reading's room ends where the OPEN chip begins —
                    // a long unit ("SEARCH · FEEDS · QUEUE") SHRINKS to fit
                    // rather than running under the keycap. Measure from the chip's
                    // BASELINE x (cChip.x minus its own OPEN move offset) so nudging
                    // OPEN in assembly repositions the keycap WITHOUT resizing the text.
                    // the reading is the BOTTOM row; OPEN lives in the top band, so bound the room
                    // to the card's interior (left datum → symmetric right margin), NOT to OPEN's x
                    // — otherwise a slim card needlessly squeezes the reading into the left portion.
                    readonly property int availW: card.width - x - Math.max(card.nameL, Math.round(12 * home.s))
                    property real sIn: 0
                    transform: Translate { x: cSub.sIn }
                    Text {
                        id: cNum
                        // HERO the count: the big, bright focal datum (unit word sits small + quiet
                        // beside it). ~1.7× the unit's base and DemiBold so the value reads first.
                        text: card.subParts[0] >= 0 ? card.cnt : ""
                        color: home.mechOn ? home.mechInk(home.mech.readInk)
                                           : Theme.withAlpha(Theme.fg, 0.9)
                        font.family: home.mechOn ? home.mFontFor("read") : Theme.monoFont
                        font.weight: home.mechOn ? Math.max(Font.DemiBold, home.weightFor(home.mech.readWeight)) : Font.Bold
                        font.pixelSize: home.pxi(Math.round(Math.max(13, home.mSz(Math.round(21 * home.s), "readSize")) * home.mScale("read")))
                        font.letterSpacing: home.mechOn ? home.trackFor(home.mech.readTrack) : 1
                    }
                    Text {   // small + quiet unit BESIDE the hero count ("SERIES", "TITLES")
                        visible: !card.hasSep && card.subParts[0] >= 0
                        x: cNum.contentWidth + Math.round(7 * home.s)
                        anchors.baseline: cNum.baseline            // sits on the count's baseline
                        width: Math.max(30, cSub.availW - x)
                        text: home.mechOn ? home.caseFor(card.subParts[1], home.mech.readCase) : card.subParts[1]
                        color: home.mechOn ? Theme.withAlpha(home.mechInk(home.mech.readInk), 0.55) : Theme.withAlpha(Theme.fg, 0.55)
                        font.family: home.mechOn ? home.mFontFor("read") : Theme.monoFont
                        font.pixelSize: home.pxi(Math.round(Math.max(8, home.mSz(Math.round(9 * home.s), "readSize")) * home.mScale("read")))
                        font.letterSpacing: home.mechOn ? home.trackFor(home.mech.readTrack) + 0.5 : 1.5
                        fontSizeMode: Text.HorizontalFit; minimumPixelSize: 8; elide: Text.ElideRight
                    }
                    Text {   // STANDALONE reading, no count ("SYSTEM CONFIGURATION") — centred, full size
                        visible: !card.hasSep && card.subParts[0] < 0
                        x: 0
                        anchors.verticalCenter: cNum.verticalCenter   // centred in the body
                        width: Math.max(30, cSub.availW - x)
                        text: home.mechOn ? home.caseFor(card.subParts[1], home.mech.readCase) : card.subParts[1]
                        color: home.mechOn ? Theme.withAlpha(home.mechInk(home.mech.readInk), 0.7) : Theme.withAlpha(Theme.fg, 0.7)
                        font.family: home.mechOn ? home.mFontFor("read") : Theme.monoFont
                        font.pixelSize: home.pxi(Math.round(Math.max(8, home.mSz(Math.round(11 * home.s), "readSize")) * home.mScale("read")))
                        font.letterSpacing: home.mechOn ? home.trackFor(home.mech.readTrack) : 1.5
                        fontSizeMode: Text.HorizontalFit; minimumPixelSize: 8; elide: Text.ElideRight
                    }
                    // "A · B · C" run: words + vertically-CENTRED dot separators. Uniform scale
                    // to fit the room before OPEN (stands in for HorizontalFit on the whole run).
                    Row {
                        id: cUnitSep
                        visible: card.hasSep
                        anchors.verticalCenter: cNum.verticalCenter
                        x: 0
                        spacing: Math.round(6 * home.s)
                        transformOrigin: Item.Left
                        scale: (implicitWidth > cSub.availW && implicitWidth > 0) ? cSub.availW / implicitWidth : 1
                        readonly property real fp: home.pxi(Math.round(Math.max(9, home.mSz(Math.round(11 * home.s), "readSize")) * home.mScale("read")))
                        readonly property color ink: home.mechOn ? Theme.withAlpha(home.mechInk(home.mech.readInk), 0.7) : Theme.withAlpha(Theme.fg, 0.6)
                        readonly property var words: String(home.mechOn ? home.caseFor(card.subParts[1], home.mech.readCase) : card.subParts[1]).split(" · ")
                        Repeater {
                            model: cUnitSep.words
                            delegate: Row {
                                required property int index
                                required property string modelData
                                spacing: cUnitSep.spacing
                                Item {   // centred separator dot — skipped before the first word.
                                    // Height = the caps' visual height (~0.72·fp), top-aligned like
                                    // the words, so the centred dot lands on the CAP centre, not the
                                    // lower line-box centre (which read too low).
                                    visible: parent.index > 0
                                    width: parent.index > 0 ? Math.round(3 * home.s) : 0
                                    height: Math.round(cUnitSep.fp * 0.72)
                                    Rectangle {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.verticalCenterOffset: Math.round((home.mech.sepDotY || 0) * home.s)   // SEP DOT Y dial
                                        width: Math.max(2, Math.round(2.5 * home.s)); height: width; radius: width / 2; color: cUnitSep.ink
                                    }
                                }
                                Text {
                                    text: parent.modelData
                                    color: cUnitSep.ink
                                    font.family: home.mechOn ? home.mFontFor("read") : Theme.monoFont
                                    font.pixelSize: cUnitSep.fp
                                    font.letterSpacing: home.mechOn ? home.trackFor(home.mech.readTrack) : 1.5
                                }
                            }
                        }
                    }
                }

                // Choreographed assembly on each focus change: spine drops,
                // eyebrow wakes, name types (burst then steady), rule draws a
                // beat later, the reading counts up last. A machine booting
                // its readout, stage by stage.
                property real chipFlash: 0
                Connections {
                    target: home
                    function onSecIdxChanged() { cardReveal.restart() }
                }
                ParallelAnimation {
                    id: cardReveal
                    SequentialAnimation {
                        NumberAnimation {
                            target: cName; property: "tc"
                            from: 0; to: Math.min(3, home.curSec.label.length)
                            duration: 100 * home.mechTypeK
                        }
                        NumberAnimation {
                            target: cName; property: "tc"
                            to: home.curSec.label.length
                            duration: Math.max(90, (home.curSec.label.length - 3) * 45) * home.mechTypeK
                        }
                    }
                    SequentialAnimation {  // classic rule draws a beat after
                        // the name types (no-op in mech chrome — hidden)
                        PauseAnimation { duration: 120 }
                        NumberAnimation { target: cRule; property: "drawT"; from: 0; to: 1; duration: DS.slow; easing.type: Easing.Bezier; easing.bezierCurve: DS.enterCurve }
                    }
                    SequentialAnimation {  // the prompt arrives: key strikes
                        // down and releases, then the word types — timed so
                        // OPEN's last letter lands WITH the title's
                        PropertyAction { target: cChip; property: "otc"; value: 0 }
                        PauseAnimation { duration: Math.max(0, (100 + Math.max(90, (home.curSec.label.length - 3) * 45)) - 250) * home.mechTypeK }
                        PropertyAction { target: cChip; property: "press"; value: 1 }
                        PauseAnimation { duration: 90 }
                        PropertyAction { target: cChip; property: "press"; value: 0 }
                        NumberAnimation { target: cChip; property: "otc"; from: 0; to: (home.mechOn ? String(home.mech.openLabel).length : 4); duration: 160 * home.mechTypeK }
                    }
                    SequentialAnimation {
                        PauseAnimation { duration: 180 }
                        ParallelAnimation {
                            NumberAnimation { target: card; property: "cnt"; from: 0; to: Math.max(0, card.subParts[0]); duration: 380; easing.type: Easing.OutQuad }
                            NumberAnimation { target: cSub; property: "sIn"; from: Math.round(10 * home.s); to: 0; duration: DS.base; easing.type: Easing.Bezier; easing.bezierCurve: DS.enterCurve }
                            NumberAnimation { target: cSub; property: "opacity"; from: 0.25; to: 1; duration: DS.base }
                        }
                    }
                }
            }

            // Data-link bridging the card to the focused slot. It slides to the
            // focused slot (OutQuint), REDRAWS from the card end on every focus
            // change, and — while you're in the wheel — a bright pulse runs down
            // it card→slot on a loop. Gone entirely on the continue shelf.
            Item {
                id: connector
                width: Math.round(9 * home.s)
                height: wheelUnit.gap + Math.round(10 * home.s)
                x: wheelUnit.focusCenterX - width / 2
                y: home.cardH - Math.round(5 * home.s)
                transform: Translate { x: home.mOff("link")[0]; y: home.mOff("link")[1] }   // DATA-LINK move
                // Appears with the card and leaves with it — never an orphaned
                // link hanging under a spotlight that has no card.
                opacity: (home.wheelEngaged && (!home.mechOn || home.mech.linkOn)) ? 1 : 0
                // Travels with the card to the focused slot — same gantry move,
                // so card and link read as one gesture.
                Behavior on x { NumberAnimation { duration: home.resizing ? 120 : DS.slow; easing.type: Easing.Bezier; easing.bezierCurve: DS.moveCurve } }
                Behavior on opacity { NumberAnimation { duration: DS.base } }

                // The link: a fine continuous RAIL (the circuit is always
                // closed) with a diamond PACKET that hops down it in hard
                // steps and lands on the terminal chevron — codec telemetry,
                // one marker in flight. drawF redraws the rail on focus change.
                property real drawF: 1
                property int hop: -1
                property bool chevOn: false
                readonly property color linkCol: home.mechOn ? (home.mech.linkInk === "auto" ? home.homeAccent : home.mechInk(home.mech.linkInk)) : Theme.accent
                readonly property real pulseK: home.mechOn ? ({ slow: 1.6, normal: 1, fast: 0.6 }[home.mech.linkPulse] || 1) : 1
                readonly property real railSpan: height - Math.round(6 * home.s)
                Rectangle {  // the rail — a single hairline (or a bar/off track)
                    visible: !home.mechOn || home.mech.linkRail !== "off"
                    x: (connector.width - width) / 2
                    width: home.mechOn && home.mech.linkRail === "bar" ? 2 : 1
                    height: home.mechOn && home.mech.linkRail === "dashed" ? 0 : connector.railSpan * connector.drawF
                    color: Theme.withAlpha(connector.linkCol, 0.35)
                }
                Item {  // dashed rail variant
                    // #46: the draw-in used to grow the Repeater MODEL off drawF
                    // (animated 0→1 on every wheel move), re-instantiating every dash
                    // per frame. Instead: a FIXED full-length dash column, revealed by
                    // an animated CLIP height — exactly like the solid rail above.
                    // One animated property, delegates built once.
                    visible: home.mechOn && home.mech.linkRail === "dashed"
                    x: (connector.width - width) / 2
                    width: 1
                    height: connector.railSpan * connector.drawF
                    clip: true
                    Column {
                        width: 1
                        spacing: Math.round(2 * home.s)
                        Repeater {
                            model: Math.max(1, Math.round(connector.railSpan / Math.max(1, Math.round(4 * home.s))))
                            delegate: Rectangle { width: 1; height: Math.round(2 * home.s); color: Theme.withAlpha(connector.linkCol, 0.35) }
                        }
                    }
                }
                Rectangle {  // echo — the packet's previous position, fading
                    visible: connector.hop >= 1 && (!home.mechOn || home.mech.linkPacket !== "off")
                    x: connector.width / 2 - width / 2
                    y: (connector.hop - 1) * (connector.railSpan - Math.round(3.2 * home.s)) / 3 + (Math.round(3.2 * home.s) - width) / 2
                    width: Math.round(2.2 * home.s); height: width
                    radius: home.mechOn && home.mech.linkPacket === "dot" ? width / 2 : 0
                    rotation: home.mechOn && (home.mech.linkPacket === "dot" || home.mech.linkPacket === "square") ? 0 : 45
                    opacity: 0.3
                    color: connector.linkCol
                }
                Rectangle {  // the packet — a slim diamond hopping the rail,
                    // stretching as it gains speed (hard-stepped motion blur)
                    visible: connector.hop >= 0 && (!home.mechOn || home.mech.linkPacket !== "off")
                    x: connector.width / 2 - width / 2
                    y: connector.hop * (connector.railSpan - height) / 3
                    width: Math.round(3.2 * home.s)
                    height: width * (1 + connector.hop * 0.14)
                    radius: home.mechOn && home.mech.linkPacket === "dot" ? width / 2 : 0
                    rotation: home.mechOn && (home.mech.linkPacket === "dot" || home.mech.linkPacket === "square") ? 0 : 45
                    color: connector.linkCol
                }
                Shape {  // terminal chevron — the link points INTO the slot,
                    // brightening and KICKING as each packet lands (impact)
                    antialiasing: true
                    opacity: connector.chevOn ? 1 : 0.45
                    scale: connector.chevOn ? 1.25 : 1
                    transformOrigin: Item.Bottom
                    ShapePath {
                        fillColor: home.mech.linkChevInk === "auto" ? connector.linkCol : home.mechInk(home.mech.linkChevInk); strokeColor: "transparent"
                        startX: 1.5; startY: connector.height - Math.round(4 * home.s)
                        PathLine { x: connector.width - 1.5; y: connector.height - Math.round(4 * home.s) }
                        PathLine { x: connector.width / 2; y: connector.height }
                        PathLine { x: 1.5; y: connector.height - Math.round(4 * home.s) }
                    }
                }
                SequentialAnimation {  // packet flight: hop, hop, hop, hop, land
                    running: home.visible && connector.visible && home.zone === "wheel" && home.wheelEngaged && (!home.mechOn || home.mech.linkPulse !== "off")
                    loops: Animation.Infinite
                    PropertyAction { target: connector; property: "hop"; value: 0 }
                    PauseAnimation { duration: Math.round(200 * connector.pulseK) }
                    PropertyAction { target: connector; property: "hop"; value: 1 }
                    PauseAnimation { duration: Math.round(160 * connector.pulseK) }
                    PropertyAction { target: connector; property: "hop"; value: 2 }
                    PauseAnimation { duration: Math.round(125 * connector.pulseK) }
                    PropertyAction { target: connector; property: "hop"; value: 3 }
                    PauseAnimation { duration: Math.round(95 * connector.pulseK) }
                    ScriptAction { script: { connector.hop = -1; connector.chevOn = true } }
                    PauseAnimation { duration: Math.round(170 * connector.pulseK) }
                    PropertyAction { target: connector; property: "chevOn"; value: false }
                    PauseAnimation { duration: Math.round(680 * connector.pulseK) }
                }
                Connections {
                    target: home
                    function onSecIdxChanged() { connDraw.restart() }
                }
                NumberAnimation {
                    id: connDraw
                    target: connector; property: "drawF"; from: 0; to: 1
                    duration: DS.slow; easing.type: Easing.Bezier; easing.bezierCurve: DS.enterCurve
                }
            }
            // Socket cap — a wider stub where the data-link leaves the card,
            // so the line visibly PLUGS into the readout rather than poking
            // out of it. Travels with the connector on the same gantry move.
            Rectangle {
                id: sockCap
                transform: Translate { x: home.mOff("sock")[0]; y: home.mOff("sock")[1] }
                property real dockMul: 1
                width: Math.round(7 * home.s)
                height: Math.max(1.5, Math.round(2 * home.s))
                x: wheelUnit.focusCenterX - width / 2
                y: home.cardH - Math.round(6 * home.s)
                radius: 1
                color: Theme.withAlpha(home.mech.sockInk === "auto" ? connector.linkCol : home.mechInk(home.mech.sockInk), 0.6)
                opacity: (home.wheelEngaged && (!home.mechOn || home.mech.sockCapOn) ? 1 : 0) * dockMul
                Behavior on x { NumberAnimation { duration: home.resizing ? 120 : DS.slow; easing.type: Easing.Bezier; easing.bezierCurve: DS.moveCurve } }
                Behavior on opacity { NumberAnimation { duration: DS.base } }
                Connections {
                    target: home
                    function onSecIdxChanged() { sockDock.restart() }
                }
                SequentialAnimation {  // dock confirm: blink as the link lands
                    id: sockDock
                    PauseAnimation { duration: 420 }
                    PropertyAction { target: sockCap; property: "dockMul"; value: 0.25 }
                    PauseAnimation { duration: 80 }
                    PropertyAction { target: sockCap; property: "dockMul"; value: 1 }
                }
            }

            // The slot row. A plain horizontal Row — only the labels rotate.
            Row {
                id: wheel
                x: 0
                y: home.cardH + wheelUnit.gap
                spacing: home.slotGap

                Repeater {
                    model: home.items
                    delegate: Item {
                        id: slot
                        required property var modelData
                        required property int index
                        readonly property bool selected: home.zone === "wheel" && home.secIdx === index
                        readonly property bool focused: home.secIdx === index

                        width: home.slotW
                        height: home.wheelH
                        // the deal-in: each bay rises into place on its own beat
                        readonly property real dealT: Math.min(1, Math.max(0, home.slotsIn * 2.2 - index * 0.24))
                        opacity: dealT
                        transform: Translate { y: (1 - slot.dealT) * Math.round(12 * home.s) }

                        Rectangle {
                            id: slotPanel
                            // A mech plate can take the bay over (wheel dial):
                            // the themed slab stands down and the plate's tall
                            // stretch carries the slot, band at the head.
                            readonly property bool mechPlate: home.mechOn && home.mech.wheelPlate !== "plain"
                            // Bottom-anchored growth: the row shares one base
                            // line, the focused slot grows UP out of the rank.
                            width: parent.width
                            height: slot.selected ? home.wheelH : home.wheelH - home.slotRise
                            y: home.wheelH - height
                            radius: 12
                            clip: true
                            // Focused slot grows up out of the rank — expansion
                            // on the same gantry curve as the card that feeds it.
                            Behavior on height { NumberAnimation { duration: DS.slow; easing.type: Easing.Bezier; easing.bezierCurve: DS.moveCurve } }
                            // Selection is accent-forward, not a lighter slab:
                            // the panel stays dark so the one hot accent (border,
                            // wash, tick, label) reads as THE signal.
                            color: mechPlate ? "transparent"
                                 : slot.selected ? Theme.withAlpha(Theme.surface, 0.94)
                                                 : Theme.withAlpha(Theme.surface, 0.84)
                            // focus isolation: an armed wheel dims the other
                            // bays one step — same emphasis as the shelf
                            opacity: home.wheelEngaged && !slot.selected ? (home.mechOn ? ({ subtle: 0.94, normal: 0.88, strong: 0.75 }[home.mech.slotDim] || 0.88) : 0.88) : 1
                            Behavior on opacity { NumberAnimation { duration: DS.base } }
                            // ONE border — a crisp accent frame when armed, a
                            // faint edge otherwise. Never two rings nested.
                            border.width: mechPlate ? 0 : slot.selected ? 2 : 1
                            border.color: slot.selected ? (home.mechOn && home.mech.slotBorderInk !== "auto" ? home.mechInk(home.mech.slotBorderInk) : home.homeAccent)
                                                        : Theme.withAlpha(Theme.fg, slot.focused ? 0.22 : 0.13)
                            Behavior on color { ColorAnimation { duration: DS.base } }
                            Behavior on border.color { ColorAnimation { duration: DS.base } }

                            MechPanel {  // the bay's hull plate (dial); dims a
                                // step when another bay is armed like the slab.
                                // px steps DOWN when a plate's corner regions
                                // would outgrow the narrow slot (wide corners
                                // on card/wide/body/dlg).
                                readonly property var ok: ["sq1", "sq2", "sq3", "frame", "chip", "card", "wide", "body", "dlg"]
                                visible: slotPanel.mechPlate
                                kind: ok.indexOf(home.mech.wheelPlate) >= 0 ? home.mech.wheelPlate : "sq1"
                                px: (plate.l + plate.r + 8) * 2 <= width ? (home.s >= 1.15 ? 2 : 1) : 1
                                anchors.fill: parent
                                opacity: slot.selected ? 1 : 0.82
                            }
                            // Machined-glass dimensionality: a whisper of light
                            // down from the top so the panel isn't a flat slab.
                            Rectangle {
                                visible: !slotPanel.mechPlate
                                anchors.fill: parent
                                anchors.margins: 1
                                radius: parent.radius
                                gradient: Gradient {
                                    GradientStop { position: 0.0; color: Theme.withAlpha(Theme.fg, 0.06) }
                                    GradientStop { position: 0.10; color: "transparent" }
                                }
                            }
                            // Inner hairline — the double-frame every codec
                            // panel carries: a machined step just inside the
                            // border, one hair of light.
                            Rectangle {
                                visible: !slotPanel.mechPlate
                                anchors.fill: parent
                                anchors.margins: 3
                                radius: Math.max(2, parent.radius - 2)
                                color: "transparent"
                                border.width: 1
                                border.color: Theme.withAlpha(Theme.fg, slot.selected ? 0.10 : 0.055)
                            }
                            // Select acknowledge — ONE brief panel wash as
                            // the slot takes selection (PS1 restraint: a
                            // single soft pulse, never a double).
                            readonly property bool armed: slot.selected
                            onArmedChanged: if (armed) { armFlashAnim.restart(); starBlink.restart(); tickLoad.restart(); notchLoad.restart(); labelIgnite.restart(); headIgnite.restart(); footIgnite.restart() }
                            Rectangle {
                                id: armFlash
                                anchors.fill: parent
                                anchors.margins: 1
                                radius: parent.radius
                                color: Theme.withAlpha(Theme.fg, 0.05)
                                visible: false
                            }
                            SequentialAnimation {
                                id: armFlashAnim
                                PropertyAction { target: armFlash; property: "visible"; value: true }
                                PauseAnimation { duration: 90 }
                                PropertyAction { target: armFlash; property: "visible"; value: false }
                            }

                            // Focus wash + fill sweep from the bottom.
                            Rectangle {
                                anchors.fill: parent
                                anchors.margins: 1
                                radius: parent.radius
                                visible: slot.selected && (!home.mechOn || home.mech.slotWash)
                                gradient: Gradient {
                                    GradientStop { position: 0.0; color: "transparent" }
                                    GradientStop { position: 0.55; color: Theme.withAlpha(home.homeAccent, slot.selected ? 0.10 : 0.05) }
                                    GradientStop { position: 1.0; color: Theme.withAlpha(home.homeAccent, slot.selected ? 0.34 : 0.16) }
                                }
                                Behavior on opacity { NumberAnimation { duration: DS.quick } }
                            }

                            // Base tick under the focused slot: the card spine
                            // drops in from the top, this closes it at the foot.
                            // On arm it LOADS — growing from the centre out like
                            // a meter charging — rather than just fading up.
                            Rectangle {
                                id: baseTick
                                anchors.bottom: parent.bottom
                                anchors.bottomMargin: Math.round(9 * home.s)
                                anchors.horizontalCenter: parent.horizontalCenter
                                width: parent.width - Math.round(16 * home.s)
                                height: Math.max(2, Math.round(3 * home.s))
                                radius: height / 2
                                color: home.mechOn && home.mech.slotTickInk !== "auto" ? home.mechInk(home.mech.slotTickInk) : "#9ea3ac"   // matches the card underline
                                // Full accent when armed; a faint whisper marks the
                                // resting current section (where DOWN will land).
                                opacity: (!home.mechOn || home.mech.baseTickOn) ? (slot.selected ? 1 : (slot.focused ? 0.32 : 0)) : 0
                                Behavior on opacity { NumberAnimation { duration: DS.base } }
                                transform: Scale {
                                    id: tickScale
                                    origin.x: baseTick.width / 2
                                    xScale: 1
                                }
                                NumberAnimation {
                                    id: tickLoad
                                    target: tickScale; property: "xScale"
                                    from: 0.3; to: 1; duration: 220; easing.type: Easing.OutQuad
                                }
                            }
                            // Top notch — a short answer to the base tick at the
                            // panel's crown, closing the armed frame top-to-toe.
                            // Charges from the centre on arm, like the tick below.
                            Rectangle {
                                id: topNotch
                                anchors.top: parent.top
                                anchors.topMargin: 2
                                anchors.horizontalCenter: parent.horizontalCenter
                                width: Math.round(12 * home.s)
                                height: Math.max(2, Math.round(2.5 * home.s))
                                radius: height / 2
                                color: home.mechOn && home.mech.slotTickInk !== "auto" ? home.mechInk(home.mech.slotTickInk) : "#9ea3ac"   // matches the card underline
                                opacity: (!home.mechOn || home.mech.slotNotch) ? (slot.selected ? 0.85 : (slot.focused ? 0.22 : 0)) : 0
                                Behavior on opacity { NumberAnimation { duration: DS.base } }
                                transform: Scale {
                                    id: notchScale
                                    origin.x: topNotch.width / 2
                                    xScale: 1
                                }
                                NumberAnimation {
                                    id: notchLoad
                                    target: notchScale; property: "xScale"
                                    from: 0.3; to: 1; duration: 220; easing.type: Easing.OutQuad
                                }
                            }

                            // ── MGS weapon-slot composition ──────────────────
                            // ★ in the top corner, the label COMPACT and jammed up
                            // against the TOP (reading bottom-to-top, seated toward
                            // the side), and the section "weapon" icon big at the
                            // foot — the Peace-Walker slot, not a stretched bar.
                            // Section glyph at the head, where the MGS category box
                            // would sit. Most glyphs are the normalised silhouette;
                            // the ones with signature motion are built from separable
                            // parts so the icon's OWN elements move — the clapperboard
                            // hinges its clapstick, the beam-satellite pulses its
                            // beam, the spanner's bolt-handle crackles, the goggles
                            // catch a specular sweep across the glass.
                            Item {
                                id: headIcon
                                SequentialAnimation {  // the head glyph strikes
                                    // with the title — ONE soft pulse (PS1
                                    // restraint): dip, smooth recover, done
                                    id: headIgnite
                                    PropertyAction { target: headIcon; property: "opacity"; value: 0.55 }
                                    NumberAnimation { target: headIcon; property: "opacity"
                                        to: 1; duration: 260; easing.type: Easing.OutQuad }
                                }
                                anchors.top: parent.top
                                anchors.topMargin: Math.round(8 * home.s)
                                anchors.horizontalCenter: parent.horizontalCenter
                                readonly property string sec: slot.modelData.target
                                readonly property var ic: home.topIcon(sec)
                                readonly property string nm: ic ? ic.n : ""
                                readonly property bool bespoke: nm === "clapperboard" || nm === "steampunk-goggles"
                                                                || nm === "beam-satellite" || nm === "lightning-spanner"
                                readonly property bool isGif: !!(ic && ic.gif)
                                // per-slot user sprite override (SLOT n SPRITE dial):
                                // when set, the whole vector-icon Item hides and the
                                // sibling Image below renders the sprite in its place
                                readonly property string spriteUrl: home.mechOn ? home.spriteUrlFor(home.mech["wheelSprite" + slot.index]) : ""
                                visible: spriteUrl === ""
                                readonly property real tsz: Math.round(30 * home.s * (home.mechOn ? ({ s: 0.8, m: 1, l: 1.2, xl: 1.4 }[home.mech.wheelHeadSize] || 1) : 1))
                                readonly property color tint: slot.selected ? Qt.lighter(Theme.fg, 1.06)
                                                            : slot.focused ? Theme.withAlpha(Theme.fg, 0.74) : Theme.withAlpha(Theme.fg, 0.55)
                                width: tsz; height: tsz
                                scale: slot.selected ? 1.0 : (slot.focused ? 0.93 : 0.9)
                                Behavior on scale { NumberAnimation { duration: DS.base; easing.type: Easing.OutBack; easing.overshoot: 1.1 } }

                                // RANK UP (STATS glyph) — same climb the foot rig
                                // uses: rank-1 → 2 → 3 with a pop per promotion,
                                // hold at the top, ease back. rank-1/2/3 share a
                                // bbox so the silhouette morphs in place.
                                readonly property bool isRank: nm.indexOf("rank-") === 0
                                property int rankStep: 0
                                property int prevRank: 0
                                readonly property var rankIcon: home.iconByName("rank-" + (rankStep + 1))
                                // pop on PROMOTIONS only — the ease-back steps
                                // down without celebrating
                                onRankStepChanged: {
                                    if (headIcon.isRank && rankStep > prevRank) headRankPop.restart()
                                    prevRank = rankStep
                                }
                                // The promotion phrase: climb rank-1 → 2 → 3,
                                // one hard CONFIRM blink at the summit, a long
                                // proud hold, then a clean counter-reset — a
                                // rank counter never steps down, it resets.
                                SequentialAnimation {
                                    // visible-gated: selection persists while the
                                    // home stage hides behind playback, and a
                                    // hidden meter must not climb on CPU
                                    running: slot.selected && headIcon.isRank && headIcon.visible
                                    loops: Animation.Infinite
                                    PauseAnimation { duration: 160 }
                                    ScriptAction { script: headIcon.rankStep = 0 }
                                    PauseAnimation { duration: 560 }
                                    ScriptAction { script: headIcon.rankStep = 1 }
                                    PauseAnimation { duration: 560 }
                                    ScriptAction { script: headIcon.rankStep = 2 }
                                    PauseAnimation { duration: 420 }
                                    PropertyAction { target: headShape; property: "opacity"; value: 0.65 }
                                    PauseAnimation { duration: 80 }
                                    PropertyAction { target: headShape; property: "opacity"; value: 1 }
                                    PauseAnimation { duration: 1450 }
                                    // power-down: the meter de-energises in
                                    // two quick steps, not a snap to zero
                                    ScriptAction { script: headIcon.rankStep = 1 }
                                    PauseAnimation { duration: 80 }
                                    ScriptAction { script: headIcon.rankStep = 0 }
                                    PauseAnimation { duration: 760 }
                                }

                                IconShape {
                                    id: headShape
                                    visible: !headIcon.bespoke && !headIcon.isGif
                                    icon: (headIcon.isRank && slot.selected) ? (headIcon.rankIcon || headIcon.ic) : headIcon.ic
                                    size: headIcon.tsz; color: visible ? headIcon.tint : "transparent"   // hidden: off the tint
                                    fill: 0.94 * home.iconFillFactor(headIcon.nm)
                                    NumberAnimation {
                                        id: headRankPop
                                        target: headShape; property: "scale"
                                        from: 1.07; to: 1; duration: 230; easing.type: Easing.OutQuad
                                    }
                                }

                                // Pre-animated icons8 loop (any pool entry with a gif).
                                AnimatedImage {
                                    visible: headIcon.isGif
                                    anchors.centerIn: parent
                                    width: headIcon.tsz; height: headIcon.tsz
                                    source: visible ? home.gifDir + headIcon.ic.gif : ""
                                    playing: visible && slot.selected
                                    paused: !slot.selected
                                    fillMode: Image.PreserveAspectFit
                                    smooth: true
                                    opacity: slot.selected ? 1 : 0.55
                                }

                                // CLAPPERBOARD — the clapstick lifts, then SNAPS shut
                                // about the drawn hinge pin.
                                ClapperBoard {
                                    id: movieBoard
                                    visible: headIcon.nm === "clapperboard" && !home.movVhs
                                    anchors.fill: parent
                                    // parity with the reference silhouettes:
                                    // they live at ~88% of the box with air
                                    // around them; edge-to-edge read heavy
                                    scale: 0.88
                                    color: visible ? headIcon.tint : "transparent"   // hidden: off the tint (see below)
                                    SequentialAnimation on clap {
                                        // movieBoard.visible carries the nm test,
                                        // the movVhs flip AND the home stage
                                        running: slot.selected && movieBoard.visible
                                        loops: Animation.Infinite
                                        // real slating with the animator's
                                        // grammar: raise, aim, a 60ms wind-up
                                        // breath, ONE smeared snap, elastic
                                        // kiss, settle — never a bounce-open
                                        NumberAnimation { to: 1; duration: 240; easing.type: Easing.OutQuad }
                                        PauseAnimation { duration: 300 }
                                        NumberAnimation { to: 1.07; duration: 60; easing.type: Easing.OutQuad }
                                        PropertyAction { target: movieBoard; property: "snapping"; value: true }
                                        NumberAnimation { to: 0; duration: 45; easing.type: Easing.InQuad }
                                        PropertyAction { target: movieBoard; property: "snapping"; value: false }
                                        PropertyAction { target: movieBoard; property: "impact"; value: true }
                                        NumberAnimation { to: 0.05; duration: 40 }
                                        PropertyAction { target: movieBoard; property: "impact"; value: false }
                                        NumberAnimation { to: 0; duration: 60; easing.type: Easing.OutQuad }
                                        PauseAnimation { duration: 750 }
                                        // the 2AC adjusts their grip — a tiny
                                        // fidget that keeps the board ALIVE
                                        NumberAnimation { to: 0.07; duration: 80; easing.type: Easing.OutQuad }
                                        NumberAnimation { to: 0; duration: 110; easing.type: Easing.OutQuad }
                                        PauseAnimation { duration: 1050 }
                                    }
                                }
                                VhsTape {
                                    visible: headIcon.nm === "clapperboard" && home.movVhs
                                    anchors.fill: parent
                                    color: visible ? headIcon.tint : "transparent"   // hidden: off the tint (see below)
                                    running: slot.selected && visible
                                }

                                // TV — a specular glint sweeps the left lens,
                                // then the right; frames and strap hold still.
                                SteampunkGoggles {
                                    visible: headIcon.nm === "steampunk-goggles"
                                    anchors.fill: parent
                                    color: visible ? headIcon.tint : "transparent"   // hidden: off the tint (see below)
                                    running: slot.selected && visible
                                }

                                // YOUTUBE — the reference satellite; a ghost
                                // wavefront rides the beam to the planet and
                                // the ground dome flashes as it lands.
                                BeamSatellite {
                                    visible: headIcon.nm === "beam-satellite"
                                    anchors.fill: parent
                                    color: visible ? headIcon.tint : "transparent"   // hidden: off the tint (see below)
                                    icon: headIcon.ic
                                    running: slot.selected && visible
                                }

                                // SETTINGS — the bolt-handle crackles; the jaw
                                // never moves.
                                LightningSpanner {
                                    visible: headIcon.nm === "lightning-spanner"
                                    anchors.fill: parent
                                    color: visible ? headIcon.tint : "transparent"   // hidden: off the tint (see below)
                                    running: slot.selected && visible
                                }

                            }
                            Image {  // per-slot user pixel sprite — stands in for the
                                // section head glyph when SLOT n SPRITE is chosen
                                visible: headIcon.spriteUrl !== ""
                                anchors.top: parent.top
                                anchors.topMargin: Math.round(8 * home.s)
                                anchors.horizontalCenter: parent.horizontalCenter
                                width: headIcon.tsz; height: headIcon.tsz
                                source: headIcon.spriteUrl
                                fillMode: Image.PreserveAspectFit
                                smooth: false
                                opacity: slot.selected ? 1 : (slot.focused ? 0.85 : 0.6)
                            }
                            Text {  // ★ — head of the label, on the left edge;
                                // one soft blink as the slot takes selection
                                id: slotStar
                                visible: !home.mechOn || home.mech.starOn
                                anchors.top: parent.top
                                anchors.topMargin: Math.round(44 * home.s)
                                anchors.left: parent.left
                                anchors.leftMargin: Math.round(8 * home.s)
                                text: home.mechOn ? home.mech.starGlyph : "★"
                                // the star is the label's head — CONTENT, not
                                // chrome: it lights with the title it marks
                                readonly property color starBase: (!home.mechOn || home.mech.starInk === "auto") ? Theme.fg : home.mechInk(home.mech.starInk)
                                color: slot.selected ? Qt.lighter(starBase, 1.06)
                                     : slot.focused ? Theme.withAlpha(starBase, 0.6) : Theme.withAlpha(starBase, 0.35)
                                font.family: Theme.monoFont
                                font.pixelSize: home.pxi(Math.round(12 * home.s))
                                // the idle bay-scan tick passing through
                                scale: home.rippleIdx === index ? 1.3 : 1
                                Behavior on scale { NumberAnimation { duration: 90 } }
                                Behavior on color { ColorAnimation { duration: DS.base } }
                                SequentialAnimation {
                                    id: starBlink
                                    PropertyAction { target: slotStar; property: "opacity"; value: 0.45 }
                                    NumberAnimation { target: slotStar; property: "opacity"
                                        to: 1; duration: 220; easing.type: Easing.OutQuad }
                                }
                            }
                            // Label — stood on end (reads DOWNWARD, the MGS clockwise
                            // direction), pushed to the RIGHT of the slot with the icon
                            // given room above. Bold mono to stand out. Positioned from
                            // the rotated content box so every label starts on one line.
                            Text {
                                id: slotLabel
                                rotation: 90
                                text: home.mechOn ? home.caseFor(slot.modelData.label, home.mech.wheelCase) : slot.modelData.label
                                // the LIT title: selection carries the one text
                                // tone brighter than fg — the tube is ON. The
                                // wheel ink dial re-bases the whole ladder.
                                readonly property color inkBase: home.mechInk(home.mech.wheelInk)
                                color: (!home.mechOn || home.mech.wheelInk === "auto")
                                     ? (slot.selected ? Qt.lighter(Theme.fg, 1.06)
                                        : slot.focused ? Theme.withAlpha(Theme.fg, 0.78) : Theme.withAlpha(Theme.fg, 0.45))
                                     : (slot.selected ? Qt.lighter(inkBase, 1.08)
                                        : slot.focused ? Theme.withAlpha(inkBase, 0.85) : Theme.withAlpha(inkBase, 0.5))
                                SequentialAnimation {  // ONE soft strike (PS1
                                    // restraint) — the old fluorescent
                                    // misfire read as a double flash
                                    id: labelIgnite
                                    PropertyAction { target: slotLabel; property: "opacity"; value: 0.55 }
                                    NumberAnimation { target: slotLabel; property: "opacity"
                                        to: 1; duration: 260; easing.type: Easing.OutQuad }
                                }
                                font.family: home.mechOn ? home.mFontFor("wheel") : Theme.monoFont
                                font.weight: home.mechOn ? home.weightFor(home.mech.wheelWeight) : Font.Bold
                                font.pixelSize: home.pxi(Math.round(Math.max(11, home.mSz(Math.round(15 * home.s), "wheelSize")) * home.mScale("wheel")))
                                // the label LOCKS IN when armed — tracking opens
                                // a hair, and the rule follows its new length
                                font.letterSpacing: (home.mechOn ? home.trackFor(home.mech.wheelTrack) : Math.round(2 * home.s)) + (slot.selected ? 1 : 0)
                                Behavior on font.letterSpacing { NumberAnimation { duration: 160 } }
                                readonly property real topY: Math.round(46 * home.s)
                                readonly property real cx: slotPanel.width * 0.66
                                x: cx - contentWidth / 2 + home.mOff("wheel")[0]
                                y: topY + (contentWidth - contentHeight) / 2 + home.mOff("wheel")[1]
                                Behavior on color { ColorAnimation { duration: DS.base } }
                            }
                            // Dynamic vertical rule beside the label — the wheel's
                            // answer to the spotlight card's underline: draws in from
                            // the top when the slot is the current section.
                            Rectangle {
                                id: labelRule
                                width: Math.max(2, Math.round(2 * home.s))
                                radius: width / 2
                                x: slotLabel.cx - slotLabel.contentHeight / 2 - Math.round(5 * home.s)
                                y: slotLabel.topY
                                color: home.mechOn && home.mech.slotTickInk !== "auto" ? home.mechInk(home.mech.slotTickInk) : "#9ea3ac"   // matches the card underline
                                height: slot.selected ? slotLabel.contentWidth : 0
                                opacity: slot.selected ? 1 : 0
                                Behavior on height { NumberAnimation { duration: DS.slow; easing.type: Easing.Bezier; easing.bezierCurve: DS.enterCurve } }
                                Behavior on opacity { NumberAnimation { duration: DS.base } }
                            }
                            // Section "weapon" at the foot — normalised, with
                            // signature motion keyed to the chosen icon: radar-sweep
                            // (and single cogs) SPIN — radially symmetric, so
                            // whole-icon rotation is honest — and rank icons RANK
                            // UP. Everything with separable anatomy gets a bespoke
                            // part-level rig below: the film-strip feeds, the tv
                            // scans, the world turns, the gear PAIR meshes.
                            Item {
                                id: footIcon
                                SequentialAnimation {  // the foot strikes one
                                    // beat after the head — current travelling
                                    // down the slot; still ONE soft pulse
                                    id: footIgnite
                                    PauseAnimation { duration: 80 }
                                    PropertyAction { target: footIcon; property: "opacity"; value: 0.55 }
                                    NumberAnimation { target: footIcon; property: "opacity"
                                        to: 1; duration: 260; easing.type: Easing.OutQuad }
                                }
                                anchors.bottom: parent.bottom
                                anchors.bottomMargin: Math.round(18 * home.s)
                                anchors.horizontalCenter: parent.horizontalCenter
                                readonly property string sec: slot.modelData.target
                                readonly property var ic: home.botIcon(sec)
                                readonly property string nm: ic ? ic.n : ""
                                readonly property real isz: Math.round(46 * home.s * (home.mechOn ? ({ s: 0.8, m: 1, l: 1.2, xl: 1.4 }[home.mech.wheelFootSize] || 1) : 1))
                                readonly property color tint: slot.selected ? Qt.lighter(Theme.fg, 1.06)
                                                            : slot.focused ? Theme.withAlpha(Theme.fg, 0.74) : Theme.withAlpha(Theme.fg, 0.55)
                                // Every slot carries every icon and shows ONE; the
                                // hidden ones read the tint only while visible
                                // (`visible ? tint : "transparent"`). Reading it
                                // always made each selection recolour ~18 hidden
                                // icons in all five slots — a hidden film strip
                                // alone re-tinted every perforation, 21k colour
                                // updates in a 6 s sweep — ~4.5 ms a selection, and
                                // the reason the wheel's selection trailed a fast
                                // mouse (the author, 2026-10-13, at 170 Hz).
                                // Whole-icon spin ONLY for radially-symmetric picks;
                                // the film reel spins its disc inside its own rig so
                                // the tail can hang still. "gears" (a PAIR) is out —
                                // spinning both about one axis orbits them; its
                                // bespoke MeshGears rig counter-rotates them instead.
                                readonly property bool spins: nm === "radar-sweep"
                                                              || nm === "cog" || nm === "big-gear" || nm === "cogsplosion"
                                readonly property bool isRank: nm.indexOf("rank-") === 0
                                readonly property bool bespoke: nm === "film-spool" || nm === "film-strip"
                                                                || nm === "film-strip-2d"
                                                                || nm === "tv" || nm === "crt-2d"
                                                                || nm === "world" || nm === "gears"
                                                                || nm === "gears-2d"
                                                                || nm === "gif·chart" || nm === "chart-2d"
                                // Pool entries carrying a `gif` render as a pre-animated
                                // icons8 loop (recoloured white-on-transparent).
                                readonly property bool isGif: !!(ic && ic.gif)
                                width: isz
                                height: isz
                                // Snap-in when the slot takes focus (MGS select pop).
                                scale: slot.selected ? 1.0 : 0.9
                                Behavior on scale { NumberAnimation { duration: DS.base; easing.type: Easing.OutBack; easing.overshoot: 1.1 } }

                                // SPIN — the radar dial sweeps quick, gears grind slow.
                                property real spin: 0
                                rotation: (spins && slot.selected) ? spin : 0
                                RotationAnimation on spin {
                                    running: slot.selected && footIcon.spins && footIcon.visible
                                    loops: Animation.Infinite; from: 0; to: 360
                                    duration: footIcon.nm === "radar-sweep" ? 2600 : 4200
                                }

                                // RANK UP — climb rank-1 → 2 → 3, hold, ease back; a
                                // pop on each promotion. rank-1/2/3 share a bbox so the
                                // silhouette morphs in place.
                                property int rankStep: 0
                                readonly property var rankIcon: home.iconByName("rank-" + (rankStep + 1))
                                onRankStepChanged: if (footIcon.isRank) rankPop.restart()
                                SequentialAnimation {
                                    running: slot.selected && footIcon.isRank && footIcon.visible
                                    loops: Animation.Infinite
                                    ScriptAction { script: footIcon.rankStep = 0 }
                                    PauseAnimation { duration: 640 }
                                    ScriptAction { script: footIcon.rankStep = 1 }
                                    PauseAnimation { duration: 640 }
                                    ScriptAction { script: footIcon.rankStep = 2 }
                                    PauseAnimation { duration: 1150 }
                                    ScriptAction { script: footIcon.rankStep = 1 }
                                    PauseAnimation { duration: 520 }
                                }

                                IconShape {
                                    id: footShape
                                    visible: !footIcon.bespoke && !footIcon.isGif
                                    icon: (footIcon.isRank && slot.selected) ? (footIcon.rankIcon || footIcon.ic) : footIcon.ic
                                    size: footIcon.isz
                                    color: visible ? footIcon.tint : "transparent"   // hidden: off the tint (see below)
                                    fill: 0.92 * home.iconFillFactor(footIcon.nm)
                                    NumberAnimation {
                                        id: rankPop
                                        target: footShape; property: "scale"
                                        from: 1.16; to: 1; duration: 300; easing.type: Easing.OutBack
                                    }
                                }

                                // MOVIES — the reel DISC spins while the film tail
                                // pays out below: fixed exit point on the rim,
                                // swaying strand, perforations running along it.
                                FilmReel {
                                    visible: footIcon.nm === "film-spool"
                                    anchors.centerIn: parent
                                    width: footIcon.isz; height: footIcon.isz
                                    color: visible ? footIcon.tint : "transparent"   // hidden: off the tint (see below)
                                    running: slot.selected && visible
                                }

                                // MOVIES — film feeds down through the gate:
                                // frames + perforations scroll, rails hold still.
                                FilmStrip {
                                    // natively horizontal — the cinema read.
                                    // Scaled into the rank's shared mass: the
                                    // strip still crops mid-frame (film has
                                    // no ends) but it no longer owns more of
                                    // its box than any sibling owns of theirs
                                    scale: 0.84
                                    visible: footIcon.nm === "film-strip-2d"
                                    anchors.centerIn: parent
                                    width: footIcon.isz; height: footIcon.isz
                                    color: visible ? footIcon.tint : "transparent"   // hidden: off the tint (see below)
                                    running: slot.selected && visible
                                }

                                // MOVIES — a real ribbon of 35mm in 3D,
                                // carrying the library's posters through
                                // the gate.
                                Film3D {
                                    visible: footIcon.nm === "film-strip"
                                    anchors.centerIn: parent
                                    width: footIcon.isz; height: footIcon.isz
                                    color: visible ? footIcon.tint : "transparent"   // hidden: off the tint (see below)
                                    running: slot.selected && footIcon.nm === "film-strip" && visible   // not behind the player
                                }

                                // TV (classic 2D drawing) — preserved in the
                                // icon-debug pool as "crt-2d".
                                RetroTV {
                                    visible: footIcon.nm === "crt-2d"
                                    anchors.centerIn: parent
                                    width: footIcon.isz; height: footIcon.isz
                                    color: visible ? footIcon.tint : "transparent"   // hidden: off the tint (see below)
                                    running: slot.selected && visible
                                }

                                // TV — a real 3D monitor on the turntable
                                // stage; selection swings the light on and
                                // powers the tube.
                                Tv3D {
                                    visible: footIcon.nm === "tv"
                                    anchors.centerIn: parent
                                    width: footIcon.isz; height: footIcon.isz
                                    color: visible ? footIcon.tint : "transparent"   // hidden: off the tint (see below)
                                    running: slot.selected && footIcon.nm === "tv" && visible   // not behind the player
                                }

                                // YOUTUBE — the Earth itself: real NASA
                                // textures on a 3D sphere. Idle shows the
                                // planet's real night face; selection
                                // sweeps dawn across it.
                                GlobeSpin {
                                    visible: footIcon.nm === "world"
                                    anchors.centerIn: parent
                                    width: footIcon.isz; height: footIcon.isz
                                    color: visible ? footIcon.tint : "transparent"   // hidden: off the tint (see below)
                                    running: slot.selected && footIcon.nm === "world" && visible   // not behind the player
                                }

                                // SETTINGS (classic 2D drawing) — preserved in
                                // the icon-debug pool as "gears-2d".
                                MeshGears {
                                    visible: footIcon.nm === "gears-2d"
                                    anchors.centerIn: parent
                                    width: footIcon.isz; height: footIcon.isz
                                    color: visible ? footIcon.tint : "transparent"   // hidden: off the tint (see below)
                                    running: slot.selected && visible
                                }

                                // SETTINGS — a real steel gear module on the
                                // turntable stage; arming takes up the lash
                                // and the train bites into cruise.
                                Gears3D {
                                    visible: footIcon.nm === "gears"
                                    anchors.centerIn: parent
                                    width: footIcon.isz; height: footIcon.isz
                                    color: visible ? footIcon.tint : "transparent"   // hidden: off the tint (see below)
                                    running: slot.selected && footIcon.nm === "gears" && visible   // not behind the player
                                }

                                // Pre-animated icons8 loop (any pool entry with a
                                // gif) — except picks that earned a bespoke rig.
                                // Source and playback follow VISIBILITY, not just
                                // the pick: a gif entry name-mapped to a bespoke
                                // rig (gif·chart → Chart3D) must not decode its
                                // file, let alone animate it behind the 3D scene.
                                AnimatedImage {
                                    visible: footIcon.isGif && !footIcon.bespoke
                                    anchors.centerIn: parent
                                    width: footIcon.isz; height: footIcon.isz
                                    source: visible ? home.gifDir + footIcon.ic.gif : ""
                                    playing: visible && slot.selected
                                    paused: !slot.selected
                                    fillMode: Image.PreserveAspectFit
                                    smooth: true
                                    opacity: slot.selected ? 1 : 0.55
                                }

                                // STATS (classic 2D drawing) — preserved in
                                // the icon-debug pool as "chart-2d".
                                StatChart {
                                    visible: footIcon.nm === "chart-2d"
                                    anchors.centerIn: parent
                                    width: footIcon.isz; height: footIcon.isz
                                    color: visible ? footIcon.tint : "transparent"   // hidden: off the tint (see below)
                                    running: slot.selected && visible
                                }

                                // STATS — real 3D bars of real watch time on
                                // the turntable stage, ember trend riding
                                // their tops.
                                Chart3D {
                                    visible: footIcon.nm === "gif·chart"
                                    anchors.centerIn: parent
                                    width: footIcon.isz; height: footIcon.isz
                                    color: visible ? footIcon.tint : "transparent"   // hidden: off the tint (see below)
                                    running: slot.selected && footIcon.nm === "gif·chart" && visible   // not behind the player
                                }

                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            // Slots don't move under the cursor here (no scroll),
                            // so hover selection is safe — but it still waits
                            // for the pointer to REST so a sweep across the
                            // rank doesn't strobe five arm sequences.
                            onEntered: {
                                if (App.devMeter) console.log("[enter] " + Date.now() + " " + index)
                                if (!App.pointerActive) return
                                // Selected the moment the pointer arrives — no
                                // dwell. The 25 ms rest it used to wait for
                                // made a fast sweep skip slot after slot and
                                // the selection land late, trailing the
                                // cursor (the author, 2026-10-13). A selection is
                                // cheap now that hidden icons stay off the
                                // tint (~1.4 ms, was ~4.5); the slots never
                                // move under the cursor, so nothing strobes.
                                home.hoverCancel()
                                home.zoneName = "wheel"
                                home.secIdx = index
                            }
                            onClicked: {
                                home.hoverCancel()
                                home.zoneName = "wheel"
                                home.secIdx = index
                                home.confirm()
                            }
                        }
                    }
                }
            }
        }

        // ── Continue (collapsed until you go down to it) ─────────────────
        // A labelled affordance ("CONTINUE  ▾") by default; navigate DOWN (j) and
        // the recent posters POP-FADE open into the room the lifted wheel opens
        // below. Folding them away is what frees the wheel + spotlight their
        // space — up is info, down is continue.
        Item {
            id: shelf
            visible: home.cw.length > 0
            width: 3 * posterW + 2 * gap     // three posters wide, centred
            height: shelfLabel.height        // the STACK only reserves the label
            readonly property int gap: Math.round(10 * home.s)
            anchors.horizontalCenter: parent.horizontalCenter
            // Sits just below the wheel — browsing continue lifts the wheel by
            // cwRise, so subtract it to follow up and open the room below for
            // big, footer-clear posters.
            // No Behavior here — the motion comes from home.cwRise (already
            // eased), so the shelf tracks the wheel exactly instead of chasing it.
            y: wheelUnit.y + wheelUnit.height + stage.gapBot - home.cwRise
            opacity: home.spotInfoOpen ? 0.72 : 1
            Behavior on opacity { NumberAnimation { duration: DS.slow; easing.type: Easing.OutQuint } }
            transform: Translate { x: home.mOff("deck")[0]; y: -home.infoWheelRise + home.mOff("deck")[1] }   // DECK PLATE move folded into the wheel-rise

            readonly property bool active: home.zone === "cw"
            // The button is ENGAGED — plate steps idle→hover, chrome brightens + lifts — when
            // the mouse is over it OR the keyboard focus is on it (in the cw zone, NOT stepped
            // into the poster row). Focus on the posters drops it back to IDLE so the three
            // states (idle / hover / press) read cleanly.
            // Engaged = lit "hot". Follow the ACTIVE input device so the button
            // never LATCHES: while the mouse drives (pointerActive), it lights
            // only while the cursor is actually ON it (leaves → un-lights); when
            // the keyboard drives, it lights from the persistent zone selection.
            // (pointerActive stays true after a move — only a keypress clears it —
            // so a parked cursor off the button reads correctly as not-engaged.)
            readonly property bool btnEngaged: App.pointerActive
                                               ? shelfChipMouse.containsMouse
                                               : (home.zone === "cw" && !home.cwOnPosters)
            // Deploy feedback: the plate presses down + the ▾ caret twirls once
            // when the deck actually DEPLOYS (Enter/click) — NOT on mere focus.
            Connections {
                target: home
                function onCwDeployedChanged() {
                    contBtnPlate.tap()                               // press-down art plays on OPEN and CLOSE
                    if (home.mechOn && home.mech.caret) shelfCaret.pressBlip()   // flip-safe scale pop
                    // (direction also FLIPS via the caret's rotation Behavior)
                }
            }
            // Room below the label down to the footer — large, because y rode up
            // with the lifted wheel when active.
            // Measured, not estimated: the tray runs 26u under the posters and
            // the grounding rail 10u under that — an estimate put the rail
            // straight through the key legend. With the rail off (GROUND RAIL,
            // The author's choice) the posters take its room.
            readonly property bool railShown: !home.mechOn || home.mech.grndRail
            readonly property real availBelow:
                (stage.height - footerRow.anchors.bottomMargin - footerRow.height - Math.round(10 * home.s))
                - (y + shelfChip.y + shelfChip.height + Math.round(12 * home.s) - evenDy)
                - Math.round((railShown ? 40 : 30) * home.s)
            // With the deck open the button sits MIDWAY between the wheel and the
            // posters ("make the gaps even"): the room above it is the
            // stack's gap less the plate's overhang of its label; below, the
            // tray's 12u margin + 12u focus headroom + the POSTER TRAY trim. The
            // button (label row, plate, caret, gauge, click area) moves by half
            // the difference; the posters stay where the trim put them.
            readonly property real gapAbove: stage.gapBot + (shelfLabelRow.height - shelfChip.height) / 2
                                             + home.mOff("deck")[1]
            readonly property real gapBelow: Math.round(28 * home.s) + home.mOff("poster")[1]
            property real evenDy: home.cwDeployed ? Math.round((gapBelow - gapAbove) / 2) : 0
            // The plate's dark FACE sits above its middle by half the difference
            // of its frame (2 art px over the face, 5 under: outline, light, lip):
            // 3 px at DP-3's 2x art, 1.5 at the 1x art the laptop and CRT draw.
            // The label (and its caret) keep DP-3's seat on the face there: the
            // hand trims are DP-3's, and on 1x art they left the word ~2 px high.
            readonly property real faceFix: shelfChip.mechPlate && home.s < 1.15 ? 2 : 0
            Behavior on evenDy { NumberAnimation { duration: DS.slow; easing.type: Easing.Bezier; easing.bezierCurve: DS.enterCurve } }
            // whole pixels: a fractional poster put the tray's clip edge between
            // rows, and the lifted poster's top line went with it
            readonly property real posterH: Math.round(Math.max(Math.round(80 * home.s),
                                                                Math.min(home.shelfPosterH, availBelow)))
            readonly property real posterW: Math.round(posterH / 1.48)

            // No local scrim here anymore: the field well behind the whole
            // instrument already seats the posters on shade, so nothing dark has
            // to grow in and pop as you drop into this zone.

            Text {  // invisible BASE-size twin of the label. The pill sizes off THIS
                // (which the CONTINUE SIZE dial still drives), not the live scaled
                // label — so the ASSEMBLY × grows the CONTINUE *text* only and the
                // button stays put, exactly like a nudge moves the text not the plate.
                id: shelfLabelBase
                visible: false
                text: shelfLabel.text
                font.family: shelfLabel.font.family
                font.weight: shelfLabel.font.weight
                font.letterSpacing: shelfLabel.font.letterSpacing
                font.pixelSize: home.pxi(Math.max(9, home.mSz(Math.round(12 * home.s), "contSize")))
            }

            Rectangle {  // backing chip — PLAY's mirror twin: same fixed
                // width, same height, word dead-centred on the shared axis,
                // trailing glyph in the shared right-hand column
                id: shelfChip
                // A mech button plate can take over the pill entirely — the
                // themed chrome stands down and the plate's own idle/hover/
                // pressed art carries the states (editor-selectable).
                readonly property bool mechPlate: home.mechOn && home.mech.pill !== "none"
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: shelfLabelRow.verticalCenter
                // MOVE-page trims move the LABEL only — the plate stands
                // still (cancelling the row's offset here is what keeps the
                // continue chrome from dragging around with its text)
                anchors.verticalCenterOffset: -(home.cwDeployed ? home.mOff("cont2")[1] : home.mOff("cont")[1])
                                              - shelf.faceFix
                // The caret-seat dial shapes the plate: "under" adds nothing
                // (symmetric button, caret hangs beneath); "wing" mirrors
                // the caret's span so the word holds centre; "inline" adds
                // one span and the row shifts to centre the composite.
                readonly property int caretSpan: shelfCaret.width + Math.round(8 * home.s)
                // Reserve the caret's span from the CARET-ENABLED setting, NOT its live
                // visibility — so the plate keeps ONE width and doesn't snap-resize when the
                // caret hides on deploy.
                width: (home.mechOn ? shelfLabelBase.width : shelfLabelRow.width) + Math.round(28 * home.s)
                       + (!(home.mechOn && home.mech.caret) ? 0
                          : home.mech.caretSeat === "wing" ? 2 * caretSpan
                          : home.mech.caretSeat === "inline" ? caretSpan : 0)
                // a mech plate holds ONE height — button art doesn't balloon on
                // arm, NOR when the label is scaled in ASSEMBLY (that changes the
                // TEXT only; the plate is sized by the CONTINUE SIZE dial + base twin)
                height: mechPlate ? Math.round(34 * home.s)
                                  : Math.round((shelf.btnEngaged ? 35 : 32) * home.s)
                Behavior on height { NumberAnimation { duration: DS.slow; easing.type: Easing.Bezier; easing.bezierCurve: DS.moveCurve } }
                radius: 12
                // Glass: classic fill alpha dropped a step (0.94/0.84 → 0.77/0.69)
                // so the backdrop reads through like the wheel bays; the label is a
                // child of this Rectangle, so its colour is glassed on the PLATE
                // children only (below), never here.
                color: mechPlate ? "transparent"
                     : shelf.btnEngaged ? Theme.withAlpha(Theme.surface, 0.77)
                                        : Theme.withAlpha(Theme.surface, 0.69)
                border.width: mechPlate ? 0 : shelf.btnEngaged ? 2 : 1
                border.color: shelf.btnEngaged ? Theme.accent
                            : Theme.withAlpha(Theme.fg, 0.13)
                Behavior on color { ColorAnimation { duration: DS.base } }
                Behavior on border.color { ColorAnimation { duration: DS.base } }
                MechButton {
                    // GEOMETRIC zero: the plate wraps the label dead-even —
                    // any optical taste-trim belongs to the MOVE page
                    id: contBtnPlate
                    visible: shelfChip.mechPlate && home.mech.pill !== "chip"
                    anchors.fill: parent
                    family: parseInt(String(home.mech.pill).substring(1)) || 4
                    px: home.s >= 1.15 ? 2 : 1
                    hot: shelf.btnEngaged
                    pressed: shelfChipMouse.pressed
                    opacity: 0.82   // glass, matching the wheel bays / card
                }
                MechPanel {  // the badge plate, stretched to a pill
                    visible: shelfChip.mechPlate && home.mech.pill === "chip"
                    kind: "chip"
                    px: home.s >= 1.15 ? 2 : 1
                    anchors.fill: parent
                    opacity: 0.82
                }
                Rectangle {  // machined top light — the slots' material
                    visible: !shelfChip.mechPlate
                    anchors.fill: parent
                    anchors.margins: 1
                    radius: parent.radius
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: Theme.withAlpha(Theme.fg, 0.06) }
                        GradientStop { position: 0.10; color: "transparent" }
                    }
                }
                Rectangle {  // the armed wash, rising from the foot
                    anchors.fill: parent
                    anchors.margins: 1
                    radius: parent.radius
                    visible: home.cwDeployed && !shelfChip.mechPlate
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: "transparent" }
                        GradientStop { position: 0.55; color: Theme.withAlpha(Theme.accent, 0.10) }
                        GradientStop { position: 1.0; color: Theme.withAlpha(Theme.accent, 0.34) }
                    }
                }
                Rectangle {  // select-acknowledge flash, the slots' pulse
                    id: shelfChipFlash
                    anchors.fill: parent; anchors.margins: 1
                    radius: parent.radius
                    color: Theme.withAlpha(Theme.fg, 0.05)
                    visible: false
                }
                readonly property bool armed: home.cwDeployed
                onArmedChanged: if (armed) shelfChord.restart()
                SequentialAnimation {
                    id: shelfChord
                    ParallelAnimation {
                        SequentialAnimation {
                            PropertyAction { target: shelfChipFlash; property: "visible"; value: true }
                            PauseAnimation { duration: 90 }
                            PropertyAction { target: shelfChipFlash; property: "visible"; value: false }
                        }
                        // (no scale bounce here — the press is a flash + the
                        //  button/caret art, not a sudden geometry pop)
                    }
                }
            }
            Row {
                id: shelfLabelRow
                anchors.horizontalCenter: parent.horizontalCenter
                // Tracked type carries one trailing letter-space of dead
                // width after the last glyph (measured on the plate at xl:
                // the run leans left by exactly sp/2), so mech chrome shifts
                // +sp/2 to seat the GLYPHS at true centre. Classic keeps its
                // original beat.
                // the shelf's two states carry INDEPENDENT hand trims —
                // cont (idle, caret up) and cont2 (posters open) — so the
                // editor accommodates each state on its own
                anchors.horizontalCenterOffset: (home.mechOn
                                                 ? shelfLabel.font.letterSpacing / 2
                                                 : shelf.active ? -shelfLabel.font.letterSpacing / 2 : 0)
                                                + ((home.mechOn && home.mech.caret) && home.mech.caretSeat === "inline"
                                                   ? -shelfChip.caretSpan / 2 : 0)
                                                + (home.cwDeployed ? home.mOff("cont2")[0] : home.mOff("cont")[0])
                y: (shelfChipMouse.pressed ? 1 : 0) + shelf.evenDy + shelf.faceFix
                   + (home.cwDeployed ? home.mOff("cont2")[1] : home.mOff("cont")[1])
                // a small, smooth focus-grow — no overshoot, no sudden pop on press
                // hover lifts the word even when already active/open (so hovering the
                // OPEN button gives feedback instead of reading dead/pressed-in)
                // ONE trigger for the whole button: grow when engaged, rest otherwise.
                // (Was a 3-state 1.045/1/0.985 keyed partly on the persistent zone, which
                // drifted through the middle value as the mouse left — reading as an
                // asymmetric shrink vs the instant plate. btnEngaged unifies it.)
                scale: shelf.btnEngaged ? 1.045 : 0.985
                Behavior on scale { NumberAnimation { duration: DS.slow; easing.type: Easing.OutCubic } }
                spacing: Math.round(6 * home.s)
                ShadowText {   // the same dark seat as FULL PAGE, its twin
                    id: shelfLabel
                    text: home.mechOn ? home.caseFor(home.mech.contLabel, home.mech.contCase) : "CONTINUE"
                    // Twin of the spotlight's "full page ▲" — same size/tone,
                    // so up-for-info and down-for-continue read as a pair.
                    // Tracking locks open when the shelf takes the zone.
                    // On a mech plate the ink goes fixed (hull law) — or
                    // whatever the CONTINUE INK dial says.
                    color: home.mechOn && home.mech.contInk !== "auto"
                         ? Theme.withAlpha(home.mechInk(home.mech.contInk), shelf.btnEngaged ? 1 : 0.75)
                         : shelfChip.mechPlate
                         ? (shelf.btnEngaged ? "#f2f7fa" : Theme.withAlpha("#dce8ef", 0.7))
                         : shelf.btnEngaged ? Qt.lighter(Theme.fg, 1.06)
                         : Theme.withAlpha(Theme.fg, 0.45)
                    font.family: home.mechOn ? home.mFontFor("deck") : Theme.monoFont
                    font.weight: home.mechOn ? home.weightFor(home.mech.contWeight) : Font.Bold
                    font.pixelSize: home.pxi(Math.round(Math.max(9, home.mSz(Math.round(12 * home.s), "contSize")) * home.mScale("cont")))
                    font.letterSpacing: (home.mechOn ? home.trackFor(home.mech.contTrack) : Math.round(2 * home.s)) + (shelf.btnEngaged ? 1 : 0)
                    Behavior on font.letterSpacing { NumberAnimation { duration: 160 } }
                    Behavior on font.pixelSize { NumberAnimation { duration: DS.base; easing.type: Easing.OutCubic } }   // CONT SIZE resize animates
                    Behavior on color { ColorAnimation { duration: DS.base } }
                }
                Text {  // CLASSIC drop caret — the original text ▼ with its
                    // pixel-nudge beat, for the editor's back-to-back
                    id: shelfCaretClassic
                    visible: !home.mechOn
                    anchors.verticalCenter: shelfLabel.verticalCenter
                    anchors.verticalCenterOffset: nudge
                    property real nudge: 0
                    text: home.cwDeployed ? "▲" : "▼"   // flips with the deck (open/close hint)
                    color: Theme.withAlpha(Theme.fg, 0.5)
                    font.family: Theme.monoFont
                    font.pixelSize: home.pxi(Math.max(10, Math.round(11 * home.s)))
                    SequentialAnimation {
                        running: shelfCaretClassic.visible && home.visible
                        loops: Animation.Infinite
                        PauseAnimation { duration: 4200 }
                        PropertyAction { target: shelfCaretClassic; property: "nudge"; value: 1.5 }
                        PauseAnimation { duration: 130 }
                        PropertyAction { target: shelfCaretClassic; property: "nudge"; value: 0 }
                    }
                }
            }
            MechSprite {  // the drop caret — the mech pack's pixel ▾, an
                // ORNAMENT on the right wing, OUTSIDE the centred label so
                // the word never leaves true centre. Hidden when armed.
                // One flip every few beats, resting flat between; the rest
                // glyph rides low in its frame box (the twirl grows upward),
                // so centring compensates.
                id: shelfCaret
                // Always on the button when carets are enabled — it FLIPS direction
                // (▾ = press to open · ▴ = press to close) with the deck instead of
                // vanishing, so there's no resize jump and it always shows the action.
                visible: home.mech.caret && home.mechOn
                // CARET SIZE (baseScale, animated) × the toggle blip (blipK) — kept as
                // separate factors so the dial resize and the pop don't fight over `scale`.
                readonly property real caretSizeK: home.mechOn ? ({ s: 0.8, m: 1, l: 1.25, xl: 1.5, xxl: 1.75 }[home.mech.caretSize] || 1) : 1
                property real baseScale: caretSizeK * home.mScale("caret")
                Behavior on baseScale { NumberAnimation { duration: DS.base; easing.type: Easing.OutCubic } }
                property real blipK: 1
                scale: baseScale * blipK
                function pressBlip() { caretBlip.restart() }
                SequentialAnimation { id: caretBlip
                    NumberAnimation { target: shelfCaret; property: "blipK"; from: 1; to: 1.35; duration: 90; easing.type: Easing.OutQuad }
                    NumberAnimation { target: shelfCaret; property: "blipK"; to: 1; duration: 200; easing.type: Easing.OutBack } }
                readonly property string seat: home.mech.caretSeat
                // the label's active MOVE trim — subtracted from the label-anchored seats
                // below so cont/cont2 moves the TEXT but NOT the caret (caret = mOff("caret") only)
                readonly property var lblOff: home.cwDeployed ? home.mOff("cont2") : home.mOff("cont")
                // inline (default): rides after the label INSIDE the plate,
                // the whole [text ▾] composite dead-centred. right: floats
                // beside the plate. under: hangs beneath. wing: text centred,
                // caret in the mirrored wing.
                // (Anchor to the ROW — anchoring into a positioner's
                // children is illegal and silently drops the caret to y0.)
                anchors.left: seat === "right" ? shelfChip.right
                            : seat === "under" ? undefined : shelfLabelRow.right
                anchors.leftMargin: Math.round(seat === "right" ? 6 * home.s : 8 * home.s)
                                    + home.mOff("caret")[0] - (seat === "right" ? 0 : lblOff[0])
                anchors.horizontalCenter: seat === "under" ? shelfChip.horizontalCenter : undefined
                anchors.horizontalCenterOffset: home.mOff("caret")[0]
                anchors.verticalCenter: seat === "right" ? shelfChip.verticalCenter
                                      : seat === "under" ? undefined : shelfLabelRow.verticalCenter
                anchors.verticalCenterOffset: (seat === "right" ? 0 : (home.cwDeployed ? 3 : -3) * px) + home.mOff("caret")[1] - (seat === "right" ? 0 : lblOff[1])
                anchors.top: seat === "under" ? shelfChip.bottom : undefined
                anchors.topMargin: -Math.round(2 * home.s) + home.mOff("caret")[1]
                source: (App.heroDevRev, home.devSrc("chevron"))
                fw: 12; fh: 12; frames: 5; fps: 12
                px: home.s >= 1.15 ? 2 : 1
                playing: false
                loop: false
                opacity: 0.75
                rotation: home.cwDeployed ? 180 : 0   // ▾ (open) → ▴ (close) as the deck deploys
                Behavior on rotation { NumberAnimation { duration: DS.base; easing.type: Easing.OutBack } }
                Timer {
                    running: shelfCaret.visible && home.visible && home.mech.caretBeat !== "off" && !home.cwDeployed
                    repeat: true
                    interval: Math.max(1000, (home.mech.caretBeat || 4) * 1050)
                    onTriggered: shelfCaret.pulse()
                }
            }
            MouseArea {
                // The label is a small target — the whole chip plus margin
                // drops the pointer into the shelf.
                id: shelfChipMouse
                anchors.fill: shelfChip
                anchors.margins: -Math.round(4 * home.s)
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: if (App.pointerActive) home.hoverIntent(function() { home.zoneName = "cw"; home.cwOnPosters = false })   // hover the button = focus it
                onClicked: {   // click the button = toggle the deck open/closed
                    home.sfxCue(home.cwDeployed ? "back" : "open")
                    home.zoneName = "cw"; home.cwOnPosters = false
                    home.cwDeployed = !home.cwDeployed
                }
            }
            Item {  // scroll position — a gauge track with a travelling block:
                // where you are in the row, no numbers needed
                id: scrollGauge
                visible: home.cw.length > 3 && (!home.mechOn || home.mech.gaugeOn !== false)
                opacity: home.cwDeployed ? 1 : 0
                anchors.horizontalCenter: parent.horizontalCenter
                y: shelfLabelRow.y + shelfLabelRow.height + Math.round(7 * home.s)
                transform: Translate { x: home.mOff("gauge")[0]; y: home.mOff("gauge")[1] }
                width: Math.round(46 * home.s)
                height: Math.max(2, Math.round(2 * home.s))
                Behavior on opacity { NumberAnimation { duration: DS.base } }
                Rectangle { anchors.fill: parent; radius: height / 2; color: Theme.withAlpha(Theme.fg, 0.15) }
                Rectangle {
                    readonly property real t: home.cw.length > 1 ? home.cwIdx / (home.cw.length - 1) : 0
                    x: t * (parent.width - width)
                    width: Math.round(10 * home.s)
                    height: parent.height
                    radius: height / 2
                    color: Theme.withAlpha(Theme.accent, 0.85)
                    Behavior on x { NumberAnimation { duration: home.resizing ? 120 : DS.base; easing.type: Easing.Bezier; easing.bezierCurve: DS.moveCurve } }
                }
            }

            // (The focused-item title caption was removed — on select the item
            // BECOMES the hero/spotlight above, so naming it here was redundant.)

            // Three-poster window that opens on reveal.
            Item {
                id: posterReveal
                // anchor to the PLATE (which cancels the cont/cont2 label trim) not the
                // label row, so moving CONTINUE·OPEN moves ONLY the text, not the deck.
                anchors.top: shelfChip.bottom
                anchors.topMargin: Math.round(12 * home.s) - shelf.evenDy   // stays put while the button centres
                anchors.horizontalCenter: parent.horizontalCenter
                transform: Translate { x: home.mOff("poster")[0]; y: home.mOff("poster")[1] }   // POSTER TRAY move
                // Exactly THREE posters wide — the focused one centred, one
                // neighbour each side, and the rest cleanly off-frame (no partial
                // posters clipping at the edges).
                width: 3 * shelf.posterW + 2 * shelf.gap
                // Deploys open on reveal (down / ▾) and folds away otherwise —
                // continue is hidden until you go to it. The window carries
                // HEADROOM: 16u above for the focus lift (9u) and its lit frame —
                // 12u let the laptop's clip shave the lifted poster's top line —
                // 14u below for the
                // tray lip and base tick — the clip can't crop the chrome.
                height: home.cwDeployed ? shelf.posterH + Math.round(30 * home.s) : 0
                opacity: home.cwDeployed ? 1 : 0
                clip: true
                // Smooth decelerate, no overshoot/bounce.
                Behavior on height { NumberAnimation { duration: DS.slow; easing.type: Easing.Bezier; easing.bezierCurve: DS.enterCurve } }
                Behavior on opacity { NumberAnimation { duration: DS.base } }

                // A FIXED 3-poster window — no ListView, no scrolling. The window
                // is stateful (home.cwWinStart) and pages ONLY on keyboard nav, so
                // hovering a poster selects it WITHOUT shifting the trio under the
                // cursor. That decoupling is what stops the hover "walk".
                readonly property int winStart: home.cwWinStart
                Text {  // more to the left
                    visible: home.cwDeployed && posterReveal.winStart > 0
                    anchors.right: parent.left
                    anchors.rightMargin: Math.round(8 * home.s)
                    anchors.verticalCenter: parent.verticalCenter
                    text: "‹"
                    color: Theme.withAlpha(Theme.fg, 0.5)
                    font.family: Theme.hudFont
                    font.pixelSize: home.pxi(Math.round(32 * home.s))
                }
                Text {  // more to the right
                    visible: home.cwDeployed && posterReveal.winStart + 3 < home.cw.length
                    anchors.left: parent.right
                    anchors.leftMargin: Math.round(8 * home.s)
                    anchors.verticalCenter: parent.verticalCenter
                    text: "›"
                    color: Theme.withAlpha(Theme.fg, 0.5)
                    font.family: Theme.hudFont
                    font.pixelSize: home.pxi(Math.round(32 * home.s))
                }
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: Math.round(14 * home.s)
                    spacing: shelf.gap
                    Repeater {
                        model: 3
                        delegate: Item {
                            id: pcell
                            required property int index
                            readonly property int idx: posterReveal.winStart + index
                            readonly property var it: (idx >= 0 && idx < home.cw.length) ? home.cw[idx] : null
                            readonly property bool selected: home.zone === "cw" && home.cwDeployed && home.cwOnPosters && home.cwIdx === idx
                            width: shelf.posterW
                            height: shelf.posterH
                            visible: it !== null

                            // Per-slot staggered entrance when the shelf opens.
                            // `active` toggles only on reveal/dismiss (hovering a
                            // poster keeps zone==="cw", so it does NOT replay).
                            property real reveal: 0
                            Component.onCompleted: reveal = home.cwDeployed ? 1 : 0
                            Connections {
                                target: home
                                function onCwDeployedChanged() {
                                    if (home.cwDeployed) revealAnim.restart()
                                    else revealHideAnim.restart()   // fold OUT (was an instant snap)
                                }
                            }
                            SequentialAnimation {
                                id: revealAnim
                                PauseAnimation { duration: pcell.index * Math.round(DS.stagger * 0.65) }
                                NumberAnimation { target: pcell; property: "reveal"; from: 0; to: 1
                                                  duration: DS.slow; easing.type: Easing.Bezier; easing.bezierCurve: DS.enterCurve }
                            }
                            // close: fade+slide the posters out (quicker than the window shrink,
                            // so they clear before the clip closes over them)
                            NumberAnimation { id: revealHideAnim; target: pcell; property: "reveal"; to: 0
                                              duration: DS.base; easing.type: Easing.Bezier; easing.bezierCurve: DS.moveCurve }
                            // DECK DEPLOY style — how each poster flies in (reveal 0→1)
                            // and folds out (1→0). rise/drop = slide y; side = spread x;
                            // fade = opacity only; pop = scale-up; zoom = scale from small.
                            readonly property string deckAnim: home.mechOn ? home.mech.deckAnim : "rise"
                            onDeckAnimChanged: if (home.cwDeployed) revealAnim.restart()   // live preview while open
                            readonly property real inv: 1 - reveal
                            opacity: reveal
                            scale: deckAnim === "pop"  ? 0.70 + reveal * 0.30
                                 : deckAnim === "zoom" ? 0.50 + reveal * 0.50
                                 : (deckAnim === "fade" || deckAnim === "side") ? 1
                                 : 0.96 + reveal * 0.04                        // rise / drop
                            transform: Translate {
                                x: pcell.deckAnim === "side" ? (pcell.index - 1) * Math.round(22 * home.s) * pcell.inv : 0
                                y: pcell.deckAnim === "rise" ? pcell.inv * Math.round(14 * home.s)
                                 : pcell.deckAnim === "drop" ? -pcell.inv * Math.round(14 * home.s) : 0
                            }

                            // The TRAY — a dark plate seating each poster;
                            // the focused poster LIFTS OFF it, and the tray
                            // stays behind: real depth, no drop-shadow blur.
                            Rectangle {
                                visible: home.mech.tray === "plain" || !home.mechOn
                                anchors.fill: parent
                                anchors.leftMargin: -Math.round(3 * home.s)
                                anchors.rightMargin: -Math.round(3 * home.s)
                                anchors.topMargin: Math.round(2 * home.s)
                                anchors.bottomMargin: -Math.round(4 * home.s)
                                radius: Math.round(9 * home.s)
                                color: home.mechOn && home.mech.trayInk !== "auto" ? Theme.withAlpha(home.mechInk(home.mech.trayInk), 0.55) : Theme.withAlpha(Theme.bg, 0.55)
                                border.width: 1
                                border.color: Theme.withAlpha(Theme.fg, 0.07)
                            }
                            MechPanel {  // editor option: a hull plate as
                                // the tray (any of the nine); "none"
                                // seats the poster on bare air
                                readonly property var trayPlates: ["conttray", "body", "card", "sq1", "sq2", "sq3", "frame", "chip", "dlg", "wide"]
                                visible: home.mechOn && trayPlates.indexOf(home.mech.tray) >= 0
                                kind: trayPlates.indexOf(home.mech.tray) >= 0 ? home.mech.tray : "body"
                                px: home.s >= 1.15 ? 2 : 1
                                anchors.fill: parent
                                anchors.leftMargin: -Math.round(3 * home.s)
                                anchors.rightMargin: -Math.round(3 * home.s)
                                anchors.topMargin: Math.round(2 * home.s)
                                anchors.bottomMargin: -Math.round(4 * home.s)
                            }
                            // Selection is shown INLINE with the rest of the UI —
                            // an accent frame + a small lift + an accent tab beneath
                            // (echoing the wheel's focus and the grounding rail).
                            // NO scale/zoom: that cropped the art and read off-grammar.
                            Rectangle {
                                id: posterBox
                                anchors.fill: parent
                                radius: Math.round(7 * home.s)
                                color: Theme.surfaceHi
                                border.color: pcell.selected ? (home.mechOn && home.mech.posterFrameInk !== "auto" ? home.mechInk(home.mech.posterFrameInk) : home.homeAccent) : Theme.withAlpha(Theme.fg, 0.22)
                                // in mech, the drawn contframe IS the outline (selection
                                // still reads via the lift + the dimmed neighbours)
                                border.width: home.mechOn ? 0 : (pcell.selected ? 2 : 1)
                                Behavior on border.color { ColorAnimation { duration: DS.base } }
                                clip: true
                                // Focused poster stays bright; the other two dim —
                                // the same emphasis the wheel uses for its focus.
                                opacity: (home.zone === "cw" && !pcell.selected) ? (home.mechOn ? ({ subtle: 0.7, normal: 0.5, strong: 0.3, off: 1 }[home.mech.posterDim] || 0.5) : 0.5) : 1.0
                                Behavior on opacity { NumberAnimation { duration: DS.base } }
                                transform: Translate {
                                    y: pcell.selected ? -Math.round(9 * home.s * (home.mechOn ? ({ low: 0.5, normal: 1, high: 1.6, off: 0 }[home.mech.posterLift] || 1) : 1)) : 0
                                    Behavior on y { NumberAnimation { duration: home.resizing ? 120 : DS.base; easing.type: Easing.Bezier; easing.bezierCurve: DS.moveCurve } }
                                }
                                // Drawn poster outline (the author's art) — a hollow 9-slice
                                // frame over the cell, so the poster shows through and
                                // the outline is pixel-drawn instead of a flat border.
                                // assets/mechui/plates/panel-contframe.png, hot-reloads.
                                MechPanel {
                                    anchors.fill: parent
                                    kind: "contframe"
                                    px: home.s >= 1.15 ? 2 : 1
                                    z: 10
                                    visible: home.mechOn
                                }

                                Item {
                                    // true rounded clip via mask: the whole
                                    // poster survives — only the corner pixels
                                    // are shaved to match the frame's radius
                                    anchors.fill: parent
                                    anchors.margins: 2
                                    Image {
                                        id: pArt
                                        anchors.fill: parent
                                        source: pcell.it && pcell.it.poster.length > 0 ? Theme.art(pcell.it.poster) : ""
                                        fillMode: Image.PreserveAspectFit
                                        // non-2:3 art seats at the TOP — any
                                        // spare frame collects at the bottom
                                        // as the meter zone, never mid-float
                                        verticalAlignment: Image.AlignTop
                                        mipmap: true
                                        asynchronous: true
                                        visible: false
                                    }
                                    Item {
                                        id: pArtMask
                                        anchors.fill: parent
                                        layer.enabled: true
                                        visible: false
                                        Rectangle {
                                            anchors.fill: parent
                                            radius: Math.max(2, posterBox.radius - 2)
                                        }
                                    }
                                    MultiEffect {
                                        anchors.fill: parent
                                        source: pArt
                                        maskEnabled: true
                                        maskSource: pArtMask
                                    }
                                }
                                Text {
                                    anchors.centerIn: parent
                                    // Show the placeholder glyph when there's no poster OR the
                                    // poster fails to load (file gone / corrupt) — otherwise a
                                    // broken poster left a blank/white tile with no fallback (#238).
                                    visible: pcell.it && (pcell.it.poster.length === 0
                                                          || pArt.status === Image.Error)
                                    text: pcell.it && pcell.it.kind === "episode" ? "󰔂" : "󰿎"
                                    color: Theme.dimFg
                                    font.family: Theme.monoFont
                                    font.pixelSize: home.pxi(Math.round(26 * home.s))
                                }
                                Rectangle {  // machined top light — the same
                                    // material as the wheel slots and the card
                                    anchors.left: parent.left; anchors.right: parent.right
                                    anchors.top: parent.top
                                    anchors.margins: 1
                                    height: Math.round(14 * home.s)
                                    gradient: Gradient {
                                        GradientStop { position: 0.0; color: Theme.withAlpha(Theme.fg, 0.10) }
                                        GradientStop { position: 1.0; color: "transparent" }
                                    }
                                }
                                Rectangle {  // inner hairline — the double-frame
                                    anchors.fill: parent
                                    anchors.margins: 3
                                    radius: Math.max(2, posterBox.radius - 2)
                                    color: "transparent"
                                    border.width: 1
                                    border.color: Theme.withAlpha(Theme.fg, pcell.selected ? 0.14 : 0.08)
                                }
                                Rectangle {
                                    anchors.left: parent.left; anchors.right: parent.right
                                    anchors.bottom: parent.bottom
                                    height: Math.round(32 * home.s)
                                    gradient: Gradient {
                                        GradientStop { position: 0.0; color: "transparent" }
                                        GradientStop { position: 0.55; color: Theme.withAlpha(Theme.bg, 0.45) }
                                        GradientStop { position: 1.0; color: Theme.withAlpha(Theme.bg, 0.85) }
                                    }
                                }
                                Item {  // resume meter — mech: the pack's
                                    // segmented liquid/cells bar; classic:
                                    // the original twelve hard segments with
                                    // the bright playhead. Both RECHARGE
                                    // left-to-right when the poster takes
                                    // focus.
                                    id: pMeter
                                    anchors.left: parent.left; anchors.right: parent.right
                                    anchors.bottom: parent.bottom
                                    anchors.leftMargin: Math.round(7 * home.s)
                                    anchors.rightMargin: Math.round(7 * home.s)
                                    anchors.bottomMargin: Math.round(6 * home.s)
                                    height: home.mechOn ? mBar.height : Math.max(3, Math.round(5 * home.s))
                                    readonly property real pctv: pcell.it ? Math.min(1, pcell.it.pct) : 0
                                    property real fillT: 1
                                    MechBar {
                                        id: mBar
                                        visible: home.mechOn
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        anchors.bottom: parent.bottom
                                        px: home.s >= 1.15 ? 2 : 1
                                        style: home.mech.meterStyle
                                        maxWidth: pMeter.width
                                        value: pMeter.pctv * pMeter.fillT
                                        opacity: pcell.selected ? 1 : 0.72
                                    }
                                    Rectangle {  // CLASSIC backing
                                        visible: !home.mechOn
                                        anchors.fill: parent
                                        anchors.margins: -Math.round(2 * home.s)
                                        radius: Math.round(2 * home.s)
                                        color: Theme.withAlpha(Theme.bg, 0.72)
                                        border.width: 1
                                        border.color: Theme.withAlpha(Theme.fg, 0.12)
                                    }
                                    Row {
                                        visible: !home.mechOn
                                        anchors.fill: parent
                                        spacing: 1
                                        Repeater {
                                            model: home.mechOn ? 0 : 12
                                            Rectangle {
                                                width: (pMeter.width - 11) / 12
                                                height: pMeter.height
                                                color: home.homeAccent
                                                opacity: index < Math.round(pMeter.pctv * pMeter.fillT * 12) ? (pcell.selected ? 1 : 0.65) : 0.0
                                            }
                                        }
                                    }
                                    Rectangle {  // CLASSIC playhead
                                        visible: !home.mechOn
                                        x: Math.max(0, Math.min(pMeter.width - width, pMeter.width * pMeter.pctv * pMeter.fillT - width / 2))
                                        width: Math.max(1.5, Math.round(2 * home.s))
                                        height: pMeter.height
                                        color: Theme.withAlpha(Theme.fg, pcell.selected ? 0.95 : 0.6)
                                    }
                                    NumberAnimation {
                                        id: pMeterCharge
                                        target: pMeter; property: "fillT"
                                        from: 0; to: 1; duration: 260; easing.type: Easing.OutQuad
                                    }
                                }
                                Rectangle {  // resume percent — the reading, in
                                    // the badge-chip grammar, focused only
                                    visible: pcell.selected && pMeter.pctv > 0 && (!home.mechOn || home.mech.pctBadgeOn)
                                    anchors.right: parent.right
                                    anchors.rightMargin: Math.round(7 * home.s)
                                    anchors.bottom: pMeter.top
                                    anchors.bottomMargin: Math.round(9 * home.s)
                                    width: pPct.implicitWidth + Math.round(10 * home.s)
                                    height: Math.round(16 * home.s)
                                    radius: Math.round(3 * home.s)
                                    color: Theme.withAlpha(Theme.bg, 0.7)
                                    border.width: 1
                                    border.color: Theme.withAlpha(home.mech.pctBadgeInk === "auto" ? home.homeAccent : home.mechInk(home.mech.pctBadgeInk), 0.6)
                                    Text {
                                        id: pPct
                                        anchors.centerIn: parent
                                        text: Math.round(pMeter.pctv * 100) + "%"
                                        color: Theme.withAlpha(Theme.fg, 0.9)
                                        font.family: home.mechOn ? home.mFontFor("pct") : Theme.monoFont
                                        font.bold: true
                                        font.pixelSize: home.pxi(Math.round(Math.max(9, home.mSz(Math.round(9.5 * home.s), "pctSize")) * home.mScale("poster")))
                                        font.letterSpacing: 1
                                    }
                                }
                                Rectangle {  // kind roundel — episode or film,
                                    // stamped in the top corner
                                    visible: pcell.it !== null && (!home.mechOn || home.mech.roundelOn)
                                    anchors.top: parent.top
                                    anchors.right: parent.right
                                    anchors.margins: Math.round(6 * home.s)
                                    width: Math.round(18 * home.s); height: width
                                    radius: width / 2
                                    color: Theme.withAlpha(Theme.bg, 0.68)
                                    border.width: 1
                                    border.color: Theme.withAlpha(home.mechOn && home.mech.roundelInk !== "auto" ? home.mechInk(home.mech.roundelInk) : Theme.fg, 0.22)
                                    Text {
                                        anchors.centerIn: parent
                                        text: pcell.it && pcell.it.kind === "episode" ? "󰔂" : "󰿎"
                                        color: Theme.withAlpha(home.mechOn && home.mech.roundelInk !== "auto" ? home.mechInk(home.mech.roundelInk) : Theme.fg, 0.6)
                                        font.family: Theme.monoFont
                                        font.pixelSize: home.pxi(Math.round(9 * home.s))
                                    }
                                }
                            }

                            Rectangle {  // base tick — charges centre-out under
                                // the focused poster, the wheel-slot chord
                                id: pTick
                                anchors.horizontalCenter: parent.horizontalCenter
                                anchors.top: parent.bottom
                                anchors.topMargin: Math.round(4 * home.s)
                                width: parent.width * 0.42
                                height: Math.max(2, Math.round(2.5 * home.s))
                                radius: height / 2
                                color: home.homeAccent
                                opacity: (!home.mechOn || home.mech.posterTick) ? (pcell.selected ? 1 : 0) : 0
                                Behavior on opacity { NumberAnimation { duration: DS.base } }
                                transform: Scale {
                                    id: pTickScale
                                    origin.x: pTick.width / 2
                                    xScale: 1
                                }
                                NumberAnimation {
                                    id: pTickLoad
                                    target: pTickScale; property: "xScale"
                                    from: 0.3; to: 1; duration: 220; easing.type: Easing.OutQuad
                                }
                            }
                            onSelectedChanged: if (selected) { pTickLoad.restart(); pMeterCharge.restart() }

                            MouseArea {
                                anchors.fill: parent
                                enabled: pcell.it !== null
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onEntered: {
                                    if (!App.pointerActive) return
                                    home.hoverIntent(function() {
                                        home.zoneName = "cw"
                                        home.cwOnPosters = true    // hovering a poster focuses the poster row
                                        home.cwIdx = pcell.idx
                                    })
                                }
                                onClicked: {
                                    home.hoverCancel()
                                    home.zoneName = "cw"
                                    home.cwOnPosters = true
                                    home.cwIdx = pcell.idx
                                    home.confirm()             // deck already open + on posters → plays
                                }
                            }
                        }
                    }
                }
            }

            // Grounding rail: the posters sit ON the instrument the way the
            // wheel slots share a baseline — without it the strip reads as
            // tacked on. Centre-bright so it fades at the ends (no hard bar),
            // and the focused poster lifts clear of it.
            Rectangle {
                id: groundRail
                anchors.top: posterReveal.bottom
                anchors.topMargin: Math.round(8 * home.s)
                anchors.horizontalCenter: parent.horizontalCenter
                transform: Translate { x: home.mOff("rail")[0]; y: home.mOff("rail")[1] }
                visible: !home.mechOn || home.mech.grndRail
                width: posterReveal.width
                height: Math.max(1, Math.round(2 * home.s))
                opacity: posterReveal.opacity
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: "transparent" }
                    GradientStop { position: 0.5; color: Theme.withAlpha(home.mechOn && home.mech.grndRailInk !== "auto" ? home.mechInk(home.mech.grndRailInk) : home.homeAccent, 0.6) }
                    GradientStop { position: 1.0; color: "transparent" }
                }
            }
        }

        // ── Footer hint — keycap grammar: the KEY in a cap, the action
        // free-standing, matching the card's [⏎] OPEN prompt ──
        Row {
            id: footerRow
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: home.onCrt ? 10 : Math.round(12 * home.hintS)
            transform: Translate { x: home.mOff("foot")[0]; y: home.mOff("foot")[1] }
            spacing: Math.round(18 * home.hintS * (home.mechOn ? ({ tight: 0.6, normal: 1, wide: 1.5 }[home.mech.hintGap] || 1) : 1))
            // the HINTS dial: show / dim / off
            visible: !home.mechOn || home.mech.hints !== "off"
            opacity: home.mechOn && home.mech.hints === "dim" ? 0.4 : 1
            Repeater {
                model: [["j/k", "ZONES", ""], ["h/l", "BROWSE", ""], ["\u23ce", "OPEN", ""], ["i", "DETAILS", "spot"], ["/", "SEARCH", ""], ["1-5", "SECTIONS", "wheel"], ["c", "OUTPUT", ""]]
                Row {
                    spacing: Math.round(5 * home.hintS)
                    // the legend reads your situation: zone-specific hints
                    // brighten when their zone is live, recede otherwise
                    opacity: modelData[2] === "" || home.zone === modelData[2] ? 1 : 0.45
                    Behavior on opacity { NumberAnimation { duration: DS.base } }
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: kcap.implicitWidth + Math.round(8 * home.hintS)
                        height: Math.round(15 * home.hintS)
                        radius: Math.round(3 * home.hintS)
                        color: (!home.mechOn || home.mech.hintCaps) ? Theme.withAlpha(Theme.bg, 0.45) : "transparent"
                        border.width: 1
                        border.color: (!home.mechOn || home.mech.hintCaps) ? Theme.withAlpha(Theme.fg, 0.18) : "transparent"
                        Text {
                            id: kcap
                            anchors.centerIn: parent
                            text: modelData[0]
                            opacity: modelData[0] === "\u23ce" ? 0 : 1
                            color: Theme.withAlpha(home.mechOn && home.mech.hintInk !== "auto" ? home.mechInk(home.mech.hintInk) : Theme.fg, 0.55)
                            font.family: home.mechOn ? home.mFontFor("hint") : Theme.monoFont
                            font.pixelSize: home.pxi(Math.round(Math.max(10, home.mSz(Math.round(12 * home.hintS), "hintSize")) * home.mScale("foot")))
                        }
                        ReturnGlyph {
                            visible: modelData[0] === "\u23ce"
                            anchors.centerIn: parent
                            anchors.verticalCenterOffset: Math.max(1, Math.round(0.5 * home.hintS))
                            width: Math.round(8 * home.hintS); height: Math.round(7 * home.hintS)
                            color: Theme.withAlpha(home.mechOn && home.mech.hintInk !== "auto" ? home.mechInk(home.mech.hintInk) : Theme.fg, 0.55)
                        }
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData[1]
                        color: Theme.withAlpha(home.mechOn && home.mech.hintInk !== "auto" ? home.mechInk(home.mech.hintInk) : Theme.fg, 0.45)
                        font.family: home.mechOn ? home.mFontFor("hint") : Theme.monoFont
                        font.weight: home.mechOn ? home.weightFor(home.mech.hintWeight) : Font.Normal
                        font.pixelSize: home.pxi(Math.round(Math.max(10, home.mSz(Math.round(12 * home.hintS), "hintSize")) * home.mScale("foot")))
                        font.letterSpacing: home.mechOn ? home.trackFor(home.mech.hintTrack) : 1.5
                    }
                }
            }
        }
    }

    // ── Mini info panel ──────────────────────────────────────────────────
    // The spotlight, expanded: a home-native quick look at the featured title,
    // in the same grammar as the wheel. Fades in over a dimmed home (XMB
    // presence); the full page is one more press (up).
    Item {
        id: spotInfo
        anchors.fill: parent
        z: 20
        readonly property var it: home.curSpot
        Connections {  // dropping into continue folds the quick-look —
            // the two zones were able to stack into an overlap
            target: home
            function onZoneChanged() {
                if (home.zone === "cw" && home.spotInfoOpen) home.spotInfoOpen = false
            }
        }
        // Dismiss by clicking off the controls while open. Wheel passes
        // through — a MouseArea swallows it otherwise, and the home wheel
        // (up again = full info page, down = close) went dead under the panel.
        MouseArea {
            anchors.fill: parent
            enabled: home.spotInfoOpen
            onClicked: home.spotInfoOpen = false
            onWheel: (w) => { w.accepted = false }
        }

        // The spotlight GROWS: the synopsis + play unfurl straight under the
        // meta, in place, while the wheel recedes behind. No plate, no overlay —
        // the spotlight itself opening up; the full page is the only overlay.
        Item {
            id: spotGrow
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(parent.width * 0.72, Math.round(720 * home.s))
            // Seats just under the LIFTED meta (follows the same rise), and
            // grows down into the room that opens — never onto the wheel.
            y: stage.y + spotBlock.y + spotBlock.height
               - home.infoRise * home.infoT
               + Math.round((6 + (home.mechOn ? (home.mech.infoGap || 0) : 0)) * home.s)   // INFO GAP dial: meta→synopsis gap (− pulls the synopsis up, even over the meta)
               + home.infoDropPx   // INFO DROP: tracks the spotlight so the whole cluster slides together (SPOT Y moves the spotlight alone, so it is NOT added here)
            height: growCol.implicitHeight * home.infoT
            clip: true
            opacity: home.infoT
            visible: home.infoT > 0.01 && spotInfo.it

            Column {
                id: growCol
                width: parent.width
                spacing: Math.round(14 * home.s)
                topPadding: Math.round(8 * home.s)
                // Synopsis that READS THROUGH instead of eliding: clipped to a
                // few lines, and if it overflows it dwells, eases down to the
                // end, dwells, eases back — only while the info is open.
                // Synopsis with a TACTICAL type-in (the MGS/codec grammar):
                // characters reveal at a steady clip when the panel opens, a
                // block cursor trailing. Sized to the full text (a hidden measure
                // reserves the height, so typing never reflows the panel) — it
                // seats right above PLAY and only TYPES, never scrolls when it fits.
                Item {
                    id: plotBox
                    width: parent.width
                    // height is OWNED by the Canvas layout below (its wrapped
                    // line-count × its own line-height), so the reserve always
                    // matches exactly what's drawn — no clipped tail.
                    height: plotCanvas.laid.length * plotCanvas.lineH
                    visible: plotMeasure.text.length > 0
                    // ── ONE reactive font for the whole redaction ──
                    // The bars used to be █ glyphs on a monospace grid (three overlaid
                    // Texts) — that CAN'T render a proportional face like mgs-codec
                    // (varying advances, no █ glyph). The synopsis is now drawn on a
                    // Canvas that measures each real glyph and paints a black box over
                    // its cell while redacted, so ANY font stays cell-aligned and the
                    // TEXT FONT dial takes on every style.
                    readonly property string infoFam: home.mechOn ? home.mFontFor("info") : Theme.monoFont
                    readonly property int infoWt: home.mechOn ? home.weightFor(home.mech.infoWeight) : Font.Normal
                    readonly property string infoCssWeight: {
                        if (!home.mechOn) return "normal"
                        var w = home.mech.infoWeight
                        return w === "light" ? "300" : w === "demibold" ? "600" : w === "bold" ? "700" : "normal"
                    }
                    readonly property real infoSpacing: home.mechOn ? home.trackFor(home.mech.infoTrack) : 0
                    readonly property int infoPx: home.pxi(Math.round(Math.max(10, home.mSz(Math.round(13 * home.s), "infoSize")) * home.mScale("info")))
                    Text {
                        id: plotMeasure
                        width: parent.width
                        horizontalAlignment: home.mechOn && home.mech.infoAlign === "left" ? Text.AlignLeft : Text.AlignHCenter
                        text: spotInfo.it ? (spotInfo.it.plot || "") : ""
                        font.family: plotBox.infoFam
                        font.weight: plotBox.infoWt
                        font.letterSpacing: plotBox.infoSpacing
                        font.pixelSize: plotBox.infoPx
                        lineHeight: 1.4
                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                        maximumLineCount: (home.mechOn ? home.mech.infoLines : 6)
                        elide: Text.ElideRight
                        visible: false
                    }
                    // The redaction is ATTACHED to the synopsis, cell for cell —
                    // one Canvas that measures each real glyph so the boxes and
                    // letters share the SAME cells in ANY font (proportional too):
                    //   BOXES  — black censor-bars drawn OVER each glyph's real
                    //            cell (so any proportional font stays aligned),
                    //            jittering, clearing to the letter as the front
                    //            sweeps through; a quick scan lays them down first.
                    Canvas {
                        id: plotCanvas
                        anchors.fill: parent
                        renderTarget: Canvas.Image
                        readonly property int maxLines: home.mechOn ? home.mech.infoLines : 6
                        readonly property int lineH: Math.round(plotBox.infoPx * 1.4)
                        // Wrap ONCE, here — this Canvas owns both the layout AND the
                        // reserved height (plotBox.height binds to laid.length), so the
                        // panel is always exactly as tall as the text it draws. (The old
                        // bug: height came from a Text whose proportional line-box is far
                        // shorter than px·1.4, so the lower lines fell outside and clipped.)
                        function layoutLines() {
                            var ctx = getContext("2d")
                            if (!ctx) return []
                            var text = plotMeasure.text
                            if (!text || text.length === 0) return []
                            var px = plotBox.infoPx, spacing = plotBox.infoSpacing
                            var maxW = plotBox.width, maxLines = plotCanvas.maxLines
                            ctx.font = plotBox.infoCssWeight + " " + px + 'px "' + plotBox.infoFam + '"'
                            var spaceW = ctx.measureText(" ").width + spacing
                            var lines = [], line = { glyphs: [], width: 0 }, full = false
                            var i = 0, N = text.length
                            while (i < N && !full) {
                                var ch = text[i]
                                if (ch === "\n") { lines.push(line); line = { glyphs: [], width: 0 }; if (lines.length >= maxLines) full = true; i++; continue }
                                if (ch === " ") {
                                    if (line.glyphs.length > 0) { line.glyphs.push({ i: i, ch: " ", x: line.width, adv: spaceW }); line.width += spaceW }
                                    i++; continue
                                }
                                var j = i; while (j < N && text[j] !== " " && text[j] !== "\n") j++
                                var wG = [], wW = 0
                                for (var k = i; k < j; k++) { var a = ctx.measureText(text[k]).width + spacing; wG.push({ i: k, ch: text[k], adv: a }); wW += a }
                                if (line.width + wW > maxW && line.glyphs.length > 0) {
                                    while (line.glyphs.length && line.glyphs[line.glyphs.length - 1].ch === " ") { line.width -= line.glyphs[line.glyphs.length - 1].adv; line.glyphs.pop() }
                                    lines.push(line); line = { glyphs: [], width: 0 }
                                    if (lines.length >= maxLines) { full = true; break }
                                }
                                for (var g = 0; g < wG.length; g++) {
                                    if (line.width + wG[g].adv > maxW && line.glyphs.length > 0) {   // anywhere-break for a word wider than the box
                                        lines.push(line); line = { glyphs: [], width: 0 }
                                        if (lines.length >= maxLines) { full = true; break }
                                    }
                                    wG[g].x = line.width; line.glyphs.push(wG[g]); line.width += wG[g].adv
                                }
                                i = j
                            }
                            if (!full && line.glyphs.length > 0 && lines.length < maxLines) lines.push(line)
                            if (lines.length > maxLines) lines = lines.slice(0, maxLines)
                            return lines
                        }
                        // recompute the wrap only when a LAYOUT input moves (not on every
                        // decode tick) — reading these props inside binds them.
                        readonly property var laid: (function () {
                            var _ = [plotMeasure.text, plotBox.infoFam, plotBox.infoPx, plotBox.infoCssWeight,
                                     plotBox.infoSpacing, plotBox.width, plotCanvas.maxLines]
                            return plotCanvas.layoutLines()
                        })()
                        onLaidChanged: requestPaint()
                        // repaint (no re-wrap) when the decode/colour state moves.
                        readonly property var paintDeps: [plotJam.jam, plotJam.build, plotJam.prog, plotJam.style,
                            (home.mechOn ? home.mech.infoInk : ""), (home.mechOn ? home.mech.redactInk : ""),
                            (home.mechOn ? home.mech.scanInk : ""), (home.mechOn ? home.mech.infoAlign : "")]
                        onPaintDepsChanged: requestPaint()
                        Component.onCompleted: requestPaint()
                        onPaint: {
                            var ctx = getContext("2d")
                            ctx.clearRect(0, 0, width, height)
                            var lines = plotCanvas.laid
                            if (!lines || lines.length === 0) return
                            var px = plotBox.infoPx, lineH = plotCanvas.lineH, maxW = plotBox.width
                            ctx.font = plotBox.infoCssWeight + " " + px + 'px "' + plotBox.infoFam + '"'
                            ctx.textBaseline = "middle"

                            var style = plotJam.style
                            var bars = (style === "redact" || style === "light")
                            var letterInk = (home.mechOn && home.mech.infoInk !== "auto")
                                          ? Theme.withAlpha(home.mechInk(home.mech.infoInk), 0.95) : Theme.withAlpha(Theme.fg, 0.92)
                            var boxInk = style === "light" ? Theme.withAlpha(Theme.fg, 0.82)
                                       : (home.mechOn && home.mech.redactInk !== "auto") ? home.mechInk(home.mech.redactInk) : "#000000"
                            var scanInkC = (home.mechOn && home.mech.scanInk !== "auto") ? home.mechInk(home.mech.scanInk) : Theme.accent
                            var haloInk = Theme.withAlpha(Theme.bg, 0.85)
                            var shadowInk = "#05080e"                       // same drop-shadow ink as the HUD strip
                            var sh = Math.max(1, Math.round(px * 0.09))
                            var sc = plotJam.scanned, d = plotJam.decoded, t = plotJam.jam
                            var building = plotJam.building, front = building ? sc : d
                            var lo = building ? front - 4 : front, hi = building ? front : front + 4
                            var scanActive = (style !== "off") && (building || plotJam.prog < 1)
                            var align = (home.mechOn && home.mech.infoAlign === "left") ? "left" : "center"
                            var boxH = Math.round(px * 0.62)   // censor bar hugs the caps (mgs-codec cap ≈ 0.375·px)

                            for (var li = 0; li < lines.length; li++) {
                                var L = lines[li]
                                var ox = align === "left" ? 0 : Math.round((maxW - L.width) / 2)
                                var mid = li * lineH + Math.round(lineH / 2)   // glyph baseline = middle → caps sit centred on the line
                                var by = mid - Math.round(boxH / 2)
                                for (var gi = 0; gi < L.glyphs.length; gi++) {
                                    var G = L.glyphs[gi]
                                    if (G.ch === " ") continue
                                    var x = ox + G.x, idx = G.i, bw = Math.ceil(G.adv)
                                    var inScan = scanActive && idx >= lo && idx < hi && idx < sc
                                    if (idx < d) {                                   // decoded -> the real glyph, with a drop shadow + dark halo over bright art
                                        ctx.fillStyle = shadowInk; ctx.fillText(G.ch, x + sh, mid + sh)
                                        ctx.fillStyle = haloInk
                                        ctx.fillText(G.ch, x - 1, mid); ctx.fillText(G.ch, x + 1, mid); ctx.fillText(G.ch, x, mid - 1); ctx.fillText(G.ch, x, mid + 1)
                                        ctx.fillStyle = letterInk; ctx.fillText(G.ch, x, mid)
                                    } else if (bars && idx < sc) {                   // redacted -> black box (with the 10% jitter gap)
                                        if (inScan) { ctx.fillStyle = scanInkC; ctx.fillRect(x, by, bw, boxH) }
                                        else if (plotJam.hash(idx * 12.9898 + t * 78.233) >= 0.10) { ctx.fillStyle = boxInk; ctx.fillRect(x, by, bw, boxH) }
                                    } else if (!bars && inScan) {                    // type style -> a bare scan cursor at the front
                                        ctx.fillStyle = scanInkC; ctx.fillRect(x, by, bw, boxH)
                                    }
                                    // idx >= sc and undecoded -> blank (nothing yet)
                                }
                            }
                        }
                    }
                    // Non-visual decode state + the two-phase animation, driven by
                    // the SETTINGS style (redact / light / type / off).
                    Item {
                        id: plotJam
                        property real build: 0        // scan-in front 0..1
                        property real prog: 0         // decode front 0..1
                        property int jam: 0           // scramble tick (gif cadence)
                        readonly property string style: home.mechOn && home.mech.redaction !== "inherit"
                                                        ? home.mech.redaction : App.redactionStyle
                        readonly property int n: plotMeasure.text.length
                        readonly property int scanned: Math.round(build * n)
                        readonly property int decoded: Math.round(prog * n)
                        readonly property bool building: build < 1
                        function hash(v) { const x = Math.sin(v) * 43758.5453; return x - Math.floor(x) }
                        // Scan the blocks onto the text (fast, so they lock to the
                        // words), then chain into the reading-pace decode.
                        // Reveal at a CONSTANT per-character pace regardless of plot
                        // length — the old Math.min() caps sped long synopses up (they
                        // hit the ceiling), so different titles decoded at visibly
                        // different rates. Only a floor remains, so a very short plot
                        // isn't instant; nothing speeds a long one up.
                        NumberAnimation { id: scanInAnim
                            target: plotJam; property: "build"; from: 0; to: 1
                            duration: Math.max(450, Math.round(plotJam.n * 3)); easing.type: Easing.OutSine
                            onFinished: decodeAnim.start() }
                        NumberAnimation { id: decodeAnim
                            target: plotJam; property: "prog"; from: 0; to: 1
                            duration: Math.max(2400, Math.round(plotJam.n * 48)); easing.type: Easing.Linear }
                        Timer {   // gif jitter cadence: 10fps
                            running: home.spotInfoOpen && plotJam.style !== "off" && (plotJam.building || plotJam.prog < 1)
                            interval: 100; repeat: true
                            onTriggered: plotJam.jam++
                        }
                        function run() {
                            scanInAnim.stop(); decodeAnim.stop(); jam = 0
                            if (style === "off" || n === 0) { build = 1; prog = 1; return }
                            prog = 0
                            if (style === "type") { build = 1; decodeAnim.start() }  // no bars → skip scan-in
                            else { build = 0; scanInAnim.start() }                    // redact / light
                        }
                        function reset() { scanInAnim.stop(); decodeAnim.stop(); build = 0; prog = 0 }
                    }
                    Connections {
                        target: home
                        function onSpotInfoOpenChanged() {
                            if (home.spotInfoOpen && plotMeasure.text.length > 0) plotJam.run()
                            else plotJam.reset()
                        }
                    }
                    Connections {
                        target: spotInfo
                        function onItChanged() {
                            if (home.spotInfoOpen && plotMeasure.text.length > 0) plotJam.run()
                            else plotJam.reset()
                        }
                    }
                    // Restyle live when the setting changes while the panel is open.
                    Connections {
                        target: App
                        function onRedactionStyleChanged() {
                            if (home.spotInfoOpen && plotMeasure.text.length > 0) plotJam.run()
                        }
                    }
                }
                // PLAY sits dead-centre, wearing the WHEEL SLOT's armed treatment:
                // dark machined-glass panel, one crisp accent frame, an accent wash
                // rising from the foot and a base tick — the same grammar as a
                // focused section slot, so it reads as part of the instrument.
                Rectangle {
                    id: playBtn
                    // Same law as CONTINUE: a mech button plate can take the
                    // whole panel over, states carried by the plate art.
                    readonly property bool mechPlate: home.mechOn && home.mech.play !== "none"
                    // ENGAGED = lit, CONTINUE's rule (shelf.btnEngaged): the mouse
                    // lights it only while the cursor is on it; the keys light it
                    // whenever the sheet is up — ⏎ there plays, so PLAY / OPEN
                    // SERIES IS the selection and must look it.
                    readonly property bool engaged: App.pointerActive ? playMouse.containsMouse
                                                                      : home.spotInfoOpen
                    anchors.horizontalCenter: parent.horizontalCenter
                    // size off the BASE label width (swap the scaled label's width for
                    // its base twin) so the ASSEMBLY × scales the PLAY text, not the pill
                    width: (home.mechOn ? (playPrompt.width - playLbl.width + playLblBase.width) : playPrompt.width) + Math.round(28 * home.s)
                    height: Math.round(32 * home.s)
                    radius: 12
                    clip: true
                    // Glass: classic fill alpha dropped a step (backdrop reads
                    // through, like the wheel bays); the label is a child, so it's
                    // the PLATE art below that carries the 0.82 glass, not this fill.
                    color: mechPlate ? "transparent"
                         : playBtn.engaged ? Theme.withAlpha(Theme.surface, 0.77)
                                                   : Theme.withAlpha(Theme.surface, 0.69)
                    border.width: mechPlate ? 0 : playBtn.engaged ? 2 : 1
                    border.color: playBtn.engaged ? Theme.accent
                                                          : Theme.withAlpha(Theme.fg, 0.22)
                    Behavior on color { ColorAnimation { duration: DS.base } }
                    Behavior on border.color { ColorAnimation { duration: DS.base } }
                    MechButton {
                        id: playBtnPlate
                        visible: playBtn.mechPlate && home.mech.play !== "chip"
                        anchors.fill: parent
                        family: parseInt(String(home.mech.play).substring(1)) || 4
                        px: home.s >= 1.15 ? 2 : 1
                        hot: playBtn.engaged
                        pressed: playMouse.pressed
                        opacity: 0.82   // glass, matching the wheel bays / card
                    }
                    MechPanel {  // the badge plate, stretched to a pill
                        visible: playBtn.mechPlate && home.mech.play === "chip"
                        kind: "chip"
                        px: home.s >= 1.15 ? 2 : 1
                        anchors.fill: parent
                        opacity: 0.82
                    }
                    // Machined-glass whisper from the top.
                    Rectangle {
                        visible: !playBtn.mechPlate
                        anchors.fill: parent; anchors.margins: 1; radius: parent.radius
                        gradient: Gradient {
                            GradientStop { position: 0.0; color: Theme.withAlpha(Theme.fg, 0.06) }
                            GradientStop { position: 0.10; color: "transparent" }
                        }
                    }
                    // Inner hairline — the slots' double-frame, stepping with arm
                    Rectangle {
                        visible: !playBtn.mechPlate
                        anchors.fill: parent; anchors.margins: 3
                        radius: Math.max(2, parent.radius - 2)
                        color: "transparent"
                        border.width: 1
                        border.color: Theme.withAlpha(Theme.fg, playBtn.engaged ? 0.10 : 0.055)
                    }
                    // The armed slot's focus wash — appears only when armed,
                    // the slots' exact three-stop rise
                    Rectangle {
                        anchors.fill: parent; anchors.margins: 1; radius: parent.radius
                        visible: playBtn.engaged && !playBtn.mechPlate
                        gradient: Gradient {
                            GradientStop { position: 0.0; color: "transparent" }
                            GradientStop { position: 0.55; color: Theme.withAlpha(Theme.accent, 0.10) }
                            GradientStop { position: 1.0; color: Theme.withAlpha(Theme.accent, 0.34) }
                        }
                    }
                    // Select-acknowledge flash — the slots' soft single pulse
                    Rectangle {
                        id: playFlash
                        anchors.fill: parent; anchors.margins: 1
                        radius: parent.radius
                        color: Theme.withAlpha(Theme.fg, 0.05)
                        visible: false
                    }
                    // The base tick — the wheel's signature; CHARGES from the
                    // centre out as the button arms, exactly like the slots'
                    // the chord: flash + tick charge + prompt pop, replayed
                    // every time the panel brings the button on
                    onVisibleChanged: if (visible) playChord.restart()
                    SequentialAnimation {
                        id: playChord
                        ParallelAnimation {
                            SequentialAnimation {
                                PropertyAction { target: playFlash; property: "visible"; value: true }
                                PauseAnimation { duration: 90 }
                                PropertyAction { target: playFlash; property: "visible"; value: false }
                            }
                            NumberAnimation { target: playPrompt; property: "scale"; from: 0.92; to: 1; duration: DS.base; easing.type: Easing.OutBack; easing.overshoot: 1.1 }
                        }
                    }
                    Text {  // base-size twin — the pill sizes off THIS so the ASSEMBLY ×
                        // scales the PLAY text only, leaving the button (like a nudge)
                        id: playLblBase
                        visible: false
                        text: playLbl.text
                        font.family: playLbl.font.family
                        font.weight: playLbl.font.weight
                        font.letterSpacing: playLbl.font.letterSpacing
                        font.pixelSize: home.pxi(Math.max(9, home.mSz(Math.round(12 * home.s), "playSize")))
                    }
                    Row {  // the prompt — one tight group, centred whole:
                        // word then keycap, CONTINUE's exact construction.
                        // Hover pre-lifts a hair, like the slot glyphs.
                        id: playPrompt
                        scale: playBtn.engaged && !playMouse.pressed ? 1.02 : 1
                        Behavior on scale { NumberAnimation { duration: DS.base; easing.type: Easing.OutBack; easing.overshoot: 1.1 } }
                        anchors.centerIn: parent
                        anchors.horizontalCenterOffset: home.mOff("play")[0]
                        anchors.verticalCenterOffset: (playMouse.pressed ? 1 : 0) + home.mOff("play")[1]
                        spacing: Math.round(8 * home.s)
                        Text {
                            id: playLbl
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.verticalCenterOffset: 1
                            text: spotInfo.it && spotInfo.it.kind === "show" ? "OPEN SERIES" : (home.mechOn ? home.caseFor(home.mech.playLabel, home.mech.playCase) : "PLAY")
                            color: home.mechOn && home.mech.playInk !== "auto"
                                 ? Theme.withAlpha(home.mechInk(home.mech.playInk), playBtn.engaged ? 1 : 0.8)
                                 : playBtn.mechPlate
                                 ? (playBtn.engaged ? "#f2f7fa" : Theme.withAlpha("#dce8ef", 0.85))
                                 : playBtn.engaged ? Qt.lighter(Theme.fg, 1.06) : Theme.withAlpha(Theme.fg, 0.78)
                            Behavior on color { ColorAnimation { duration: DS.base } }
                            font.family: home.mechOn ? home.mFontFor("deck") : Theme.monoFont
                            font.weight: home.mechOn ? home.weightFor(home.mech.playWeight) : Font.Bold
                            font.pixelSize: home.pxi(Math.round(Math.max(9, home.mSz(Math.round(12 * home.s), "playSize")) * home.mScale("play")))
                            font.letterSpacing: (home.mechOn ? home.trackFor(home.mech.playTrack) : Math.round(2 * home.s)) + (playBtn.engaged ? 1 : 0)
                            Behavior on font.letterSpacing { NumberAnimation { duration: 160 } }
                        }
                        Rectangle {  // the [⏎] keycap — steps through the
                            // same rest/armed states as the panel it rides,
                            // seated in the trailing column
                            width: Math.round(18 * home.s); height: Math.round(18 * home.s)
                            radius: Math.round(3 * home.s)
                            anchors.verticalCenter: parent.verticalCenter
                            color: Theme.withAlpha(Theme.bg, playMouse.pressed ? 0.68 : 0.5)
                            border.width: 1
                            border.color: playBtn.engaged ? Theme.withAlpha(Theme.accent, 0.85) : Theme.withAlpha(Theme.fg, 0.35)
                            Behavior on border.color { ColorAnimation { duration: DS.base } }
                            Rectangle {  // keycap deboss
                                x: 2; y: parent.height - 2
                                width: parent.width - 4; height: 1
                                color: Theme.withAlpha(Theme.bg, 0.6)
                            }
                            ReturnGlyph {
                                anchors.centerIn: parent
                                anchors.verticalCenterOffset: Math.max(1, Math.round(home.s))
                                width: Math.round(9 * home.s); height: Math.round(9 * home.s)
                                color: playBtn.engaged ? Qt.lighter(Theme.fg, 1.06) : Theme.withAlpha(Theme.fg, 0.74)
                            }
                        }
                    }
                    MouseArea {
                        id: playMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onContainsMouseChanged: if (containsMouse) playChord.restart()
                        onClicked: home.playSpot()
                    }
                }
                Item {  // "full page ▲" — one tight group, CONTINUE's twin
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: fpRow.width; height: fpRow.height
                    Row {
                        id: fpRow
                        spacing: Math.round(6 * home.s)
                        ShadowText {   // dark seat: legible over bright spotlight art
                            id: fpWord
                            text: "FULL PAGE"
                            color: Theme.withAlpha(Theme.fg, fullHintMouse.containsMouse ? 0.8 : 0.5)
                            Behavior on color { ColorAnimation { duration: DS.base } }
                            // MGS HUD like the rest of HOME's chrome (was the generic
                            // mono); the MGS faces draw ~1.5× smaller per px, so 16 here
                            // reads at the old 11's size.
                            font.family: mgsHudFont.name || Theme.monoFont
                            font.pixelSize: home.pxi(Math.max(14, Math.round(16 * home.s)))
                            font.letterSpacing: 2
                        }
                        MechSprite {  // CONTINUE's caret, rotated to point
                            // up — the two affordances share one glyph and
                            // one restraint beat. Rest-glyph centring flips
                            // sign with the rotation.
                            id: fpCaret
                            visible: home.mech.caret && home.mechOn
                            anchors.verticalCenter: fpWord.verticalCenter
                            anchors.verticalCenterOffset: 3 * px
                            source: (App.heroDevRev, home.devSrc("chevron"))
                            fw: 12; fh: 12; frames: 5; fps: 12
                            px: home.s >= 1.15 ? 2 : 1
                            rotation: 180
                            playing: false
                            loop: false
                            opacity: fullHintMouse.containsMouse ? 0.95 : 0.7
                            Behavior on opacity { NumberAnimation { duration: DS.base } }
                            Timer {
                                running: fpCaret.visible && home.mech.caretBeat !== "off"
                                repeat: true
                                interval: Math.max(1000, (home.mech.caretBeat || 4) * 1050)
                                onTriggered: fpCaret.pulse()
                            }
                        }
                        ShadowText {  // CLASSIC up caret — the original text ▲
                            visible: !home.mechOn
                            anchors.verticalCenter: fpWord.verticalCenter
                            text: "▲"
                            color: Theme.withAlpha(Theme.fg, fullHintMouse.containsMouse ? 0.8 : 0.5)
                            Behavior on color { ColorAnimation { duration: DS.base } }
                            font.family: Theme.monoFont
                            font.pixelSize: home.pxi(Math.max(10, Math.round(11 * home.s)))
                        }
                    }
                    MouseArea { id: fullHintMouse; anchors.fill: parent; anchors.margins: -Math.round(6 * home.s); hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: home.openFullSpot() }
                }
            }
        }
    }

    // ── Continue deck (overlay) ──────────────────────────────────────────
    // Browsing continue takes over the screen: a big, centred 3-poster deck
    // over a dimmed home. Fixed sizing + absolute centring — it can't get
    // cramped against the footer the way the inline strip did.
    Item {
        id: cwDeck
        anchors.fill: parent
        z: 16
        opacity: home.cwActive ? 1 : 0
        visible: false   // retired — continue is inline (XMB-style), not an overlay
        Behavior on opacity { NumberAnimation { duration: DS.slow; easing.type: Easing.OutQuint } }

        readonly property real posterH: Math.round(stage.height * 0.30)
        readonly property real posterW: Math.round(posterH / 1.48)
        readonly property int gap: Math.round(26 * home.s)

        MouseArea {
            anchors.fill: parent
            enabled: home.cwActive
            onClicked: home.zoneName = "wheel"
        }
        Rectangle { anchors.fill: parent; color: Theme.withAlpha(Theme.bg, 0.6) }

        Column {
            anchors.centerIn: parent
            spacing: Math.round(22 * home.s)

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "CONTINUE WATCHING"
                color: Theme.accent
                font.family: Theme.monoFont
                font.pixelSize: home.pxi(Math.max(10, Math.round(11 * home.s)))
                font.letterSpacing: 5
            }

            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: cwDeck.gap
                Repeater {
                    model: 3
                    delegate: Item {
                        id: pcard
                        required property int index
                        readonly property int idx: home.cwIdx + (index - 1)
                        readonly property var it: (idx >= 0 && idx < home.cw.length) ? home.cw[idx] : null
                        readonly property bool focused: index === 1
                        width: cwDeck.posterW
                        height: cwDeck.posterH
                        opacity: it ? (focused ? 1 : 0.4) : 0
                        Behavior on opacity { NumberAnimation { duration: DS.base } }

                        Rectangle {
                            anchors.fill: parent
                            radius: Math.round(7 * home.s)
                            color: Theme.surfaceHi
                            border.color: pcard.focused ? Theme.accent : Theme.withAlpha(Theme.fg, 0.2)
                            border.width: pcard.focused ? 2 : 1
                            clip: true
                            scale: pcard.focused ? 1.0 : 0.9
                            Behavior on scale { NumberAnimation { duration: DS.base; easing.type: Easing.Bezier; easing.bezierCurve: DS.enterCurve } }
                            Image {
                                anchors.fill: parent
                                anchors.margins: 1
                                source: pcard.it && pcard.it.poster.length > 0 ? Theme.art(pcard.it.poster) : ""
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                            }
                            Text {
                                anchors.centerIn: parent
                                visible: pcard.it && pcard.it.poster.length === 0
                                text: pcard.it && pcard.it.kind === "episode" ? "󰔂" : "󰿎"
                                color: Theme.dimFg
                                font.family: Theme.monoFont
                                font.pixelSize: home.pxi(Math.round(30 * home.s))
                            }
                            Rectangle {
                                anchors.bottom: parent.bottom
                                anchors.left: parent.left
                                height: Math.max(2, Math.round(4 * home.s))
                                width: parent.width * (pcard.it ? Math.min(1, pcard.it.pct) : 0)
                                color: Theme.accent
                            }
                            MouseArea {
                                anchors.fill: parent
                                enabled: pcard.it
                                cursorShape: Qt.PointingHandCursor
                                onClicked: { home.cwIdx = pcard.idx; home.confirm() }
                            }
                        }
                    }
                }
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.round(stage.width * 0.6)
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                text: {
                    const it = home.cw[home.cwIdx]
                    if (!it) return ""
                    let t = it.title || ""
                    if (it.kind === "episode" && it.show) t = it.show + " · " + t
                    return t
                }
                color: Theme.fg
                font.family: Theme.uiFont
                font.pixelSize: home.pxi(Math.max(16, Math.round(20 * home.s)))
                font.letterSpacing: 1
            }
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Math.round(7 * home.s)
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "‹ h    " + (home.cwIdx + 1) + " / " + home.cw.length + "    l ›"
                    color: Theme.withAlpha(Theme.fg, 0.5)
                    font.family: Theme.monoFont
                    font.pixelSize: home.pxi(Math.max(9, Math.round(10 * home.s)))
                    font.letterSpacing: 2
                }
                Item { width: Math.round(12 * home.s); height: 1 }
                ReturnGlyph {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.round(8 * home.s); height: Math.round(7 * home.s)
                    color: Theme.withAlpha(Theme.fg, 0.5)
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "resume"
                    color: Theme.withAlpha(Theme.fg, 0.5)
                    font.family: Theme.monoFont
                    font.pixelSize: home.pxi(Math.max(9, Math.round(10 * home.s)))
                    font.letterSpacing: 2
                }
            }
        }
    }

    // ── Alignment guides (editor: g) — centre cross + thirds, cyan ──────
    property bool mechGrid: true             // NORMAL full-screen reference grid (g toggles)
    property int scanGridN: 1                 // SCAN lockbox grid style 1/2/3 (g cycles in scan)
    // ── GARAGE layer (built on demand) ───────────────────────────────────
    // Everything below — the alignment grid, the lock reticle + lens + scan
    // readouts, the MechEditor panel and its recall tab — exists only for the
    // ` editor. It used to be built with home and sit invisible (~1,100 lines
    // of items re-evaluating on every style change); now it loads the first
    // time the garage opens and never at all when SETTINGS ▸ EDITOR is off.
    // UNLOADS on close (after the fade): a loaded-but-closed garage kept
    // ticking and cost more idle time than the old always-built one. The
    // editor's place (row/page/dock) rides `garageEdState` between opens.
    // Outside code reaches in through the nullable `garageFocus`/`mechEditor`.
    readonly property Item garageFocus: garageLoader.item ? garageLoader.item.focusRig : null
    readonly property Item mechEditor: garageLoader.item ? garageLoader.item.editor : null
    property var garageEdState: null
    property bool garageOn: false   // flipped only here + by the linger, never by a binding race
    Timer { id: garageLinger; interval: 400; onTriggered: if (!home.mechEdit) home.garageOn = false }   // through the close fade
    Connections {
        target: home
        function onMechEditChanged() {
            if (home.mechEdit) { garageLinger.stop(); home.garageOn = true; return }
            if (home.mechEditor) home.garageEdState = home.mechEditor.saveState()
            garageLinger.restart()
        }
    }
    Loader {
        id: garageLoader
        onLoaded: if (item.editor) item.editor.restoreState(home.garageEdState)
        anchors.fill: parent
        z: 18
        active: App.editorEnabled && home.garageOn
        sourceComponent: Component {
        Item {
        id: garageLayer
        readonly property Item focusRig: garageFocus
        readonly property Item editor: mechEditor

            Item {
                id: alignGrid
                anchors.fill: parent
                readonly property string gs: mechEditor.sys ? mechEditor.sys.gridStyle : "both"
                onGsChanged: alignGridPulse.restart()   // grid-change flash (global)
                SequentialAnimation { id: alignGridPulse
                    NumberAnimation { target: alignGrid; property: "opacity"; to: 0.15; duration: 70; easing.type: Easing.OutQuad }
                    NumberAnimation { target: alignGrid; property: "opacity"; to: 1; duration: 260; easing.type: Easing.OutCubic } }
                // NORMAL mode only — scan/combat use the in-box scanGrid instead
                visible: home.mechGrid && home.mechEdit && home.garageMode === "normal" && gs !== "off"
                z: 19
                readonly property int gt: mechEditor.sys ? (mechEditor.sys.gridThick === "med" ? 2 : mechEditor.sys.gridThick === "thick" ? 3 : 1) : 1
                readonly property color gcol: mechEditor.sysColor()
                readonly property bool crossOn: gs === "cross" || gs === "both"
                readonly property bool thirdsOn: gs === "thirds" || gs === "both"
                readonly property int cell: Math.round(52 * home.s)
                // fine cell base (always while the grid is up) — STATS parity
                Repeater { model: Math.ceil(alignGrid.width / alignGrid.cell) + 1
                    Rectangle { required property int index; x: index * alignGrid.cell; width: 1; height: alignGrid.height; color: Theme.withAlpha(alignGrid.gcol, 0.13) } }
                Repeater { model: Math.ceil(alignGrid.height / alignGrid.cell) + 1
                    Rectangle { required property int index; y: index * alignGrid.cell; height: 1; width: alignGrid.width; color: Theme.withAlpha(alignGrid.gcol, 0.13) } }
                Rectangle { visible: parent.crossOn; x: Math.round(parent.width / 2); width: parent.gt; height: parent.height; color: parent.gcol; opacity: 0.55 }
                Rectangle { visible: parent.crossOn; y: Math.round(parent.height / 2); height: parent.gt; width: parent.width; color: parent.gcol; opacity: 0.55 }
                Rectangle { visible: parent.thirdsOn; x: Math.round(parent.width / 3); width: parent.gt; height: parent.height; color: parent.gcol; opacity: 0.22 }
                Rectangle { visible: parent.thirdsOn; x: Math.round(parent.width * 2 / 3); width: parent.gt; height: parent.height; color: parent.gcol; opacity: 0.22 }
                Rectangle { visible: parent.thirdsOn; y: Math.round(parent.height / 3); height: parent.gt; width: parent.width; color: parent.gcol; opacity: 0.22 }
                Rectangle { visible: parent.thirdsOn; y: Math.round(parent.height * 2 / 3); height: parent.gt; width: parent.width; color: parent.gcol; opacity: 0.22 }
            }

            // ── GARAGE focus (editor) — Armored-Core part spotlight ──────────────
            // While the GARAGE is open, the part-group being tuned is framed with a
            // targeting bracket and the rest of the board dims — so the dial you turn is
            // always the element lit on screen, and the frame GLIDES part to part. All of
            // this is gated on mechEdit: classic and resting mecha never see it.
            Item {
                id: garageFocus
                anchors.fill: parent
                z: 18
                readonly property string grp: home.mechEdit ? mechEditor.focusGroup : ""
                // ── cursor-follow interaction (ported from the stats cockpit) ──────
                property real cursorX: -1
                property real cursorY: -1
                property bool hovering: false
                property bool shiftHeld: false
                property bool ctrlHeld: false
                property string dragKey: ""
                property bool dragging: false
                // LIVE-DRAG channel (perf, mirrors StatsView): during a grab-drag only the
                // dragged element's offset updates per pixel — `mOff` short-circuits to it, so
                // the whole-`mech` clone+reassign (200-dial invalidation + `dirty` re-serialize)
                // is deferred to release instead of firing on every mouse-pixel.
                property var dragOff: [0, 0]
                // the MODE BANNER latches on the modifier alone (not `hovering`) so it
                // doesn't flicker MANUAL→SCAN when the cursor crosses onto the panel
                readonly property bool manualMode: home.garageMode === "scan" && (shiftHeld || ctrlHeld) && home.mechEdit
                // SCAN manual aim: a cursor-driven floating lockbox. Gate on cursor validity,
                // not live `hovering`, so a stationary Ctrl still engages.
                readonly property bool freeAim: manualMode && cursorX >= 0
                // SCAN + Shift → the ZOOM LENS rides the cursor, magnifying the hovered
                // part; Ctrl is the separate manual-aim tool. Mirrors the stats lens.
                readonly property bool zooming: home.garageMode === "scan" && shiftHeld && hovering && home.mechEdit
                // Live magnification: the ZOOM dial sets the BASE + on/off; the mouse WHEEL
                // fine-tunes zoomF (0.25 steps, 1.25–8×) and G jumps between dial presets.
                // zoomF starts bound to the base; the wheel breaks the binding to float free;
                // a dial change re-syncs it.
                readonly property real zoomBase: home.mech.zoom === "1.5x" ? 1.5 : home.mech.zoom === "3x" ? 3 : home.mech.zoom === "4x" ? 4 : 2
                property real zoomF: zoomBase
                onZoomBaseChanged: zoomF = zoomBase
                readonly property string zoomLabel: (Math.round(zoomF * 100) / 100) + "X"
                function zoomBy(d) { zoomF = Math.max(1.25, Math.min(8, Math.round((zoomF + d) * 20) / 20)) }
                property int lensGridN: 0   // in-lens grid overlay: 0 off · 1 fine · 2 thirds · 3 dots (Alt+L while zooming)
                // per-element targeting: the SPECIFIC element a dial (or move key) tunes,
                // so editing the OPEN button locks around just that button. Falls back to
                // the group's parent when a dial has no single element. Reads live
                // geometry via mapToItem, so it stays right for whatever plate/style is on.
                function elemFor(k) {
                    switch (k) {
                    case "nameInk": case "nameSize": case "nameFont": case "name":
                    case "nameWeight": case "nameCase": case "nameTrack": return cName
                    case "readInk": case "readSize": case "readFont": case "read":
                    case "readWeight": case "readTrack": case "readCase": return cSub
                    case "openSize": case "openInk": case "open":
                    case "openWeight": case "openTrack": case "openFont": case "openLabel": case "openKeyInk": return cChip
                    case "ledOn": case "led": case "lamp":
                    case "ledSize": case "ledShape": case "ledWell": case "ledWellInk": case "ledBeat": return cLive
                    case "linkOn": case "linkInk": case "linkRail": case "linkPacket": case "linkPulse": case "sockCapOn": case "linkChevInk": case "sockInk": case "link": return connector
                    case "metaInk": case "metaSize": case "metaFont": case "sep": case "meta":
                    case "metaWeight": case "metaTrack": case "metaCase": case "metaOutline": case "metaGap":
                    case "chipSize": case "chipTrack": case "chipWeight": case "chipFont": return metaRow
                    case "carouselOn": case "crumbInk": case "crumbSize": case "crumbFont":
                    case "crumbWeight": case "crumbCase": case "crumbTrack": case "crumb": return spotCrumb
                    case "titleSize": case "titleFont": case "titleInk":
                    case "titleWeight": case "titleTrack": case "titleCase": case "titleOutline": case "title": return titleSlot
                    case "logoOn": case "logoMax": case "logo": return spotLogo
                    case "ruleOn": case "ruleInk": case "ruleThick": case "rule": return spotRule
                    case "wheelWeight": case "wheelTrack": case "wheelCase": case "starOn": case "starInk": case "starGlyph":
                    case "slotTickInk": case "slotNotch": case "slotWash": case "baseTickOn": case "slotBorderInk":
                    case "wheelHeadSize": case "wheelFootSize": case "slotDim": return wheelUnit
                    case "infoWeight": case "infoTrack": case "infoLines": case "infoAlign": case "info": return home.spotInfoOpen ? spotInfo : spotBlock
                    case "pill": case "contSize": case "contInk": case "cont": case "cont2":
                    case "contWeight": case "contTrack": case "contCase": case "contLabel": return shelfChip
                    case "playWeight": case "playTrack": case "playCase": case "playLabel": case "play": case "playSize": case "playInk": return playBtn
                    case "trayInk": case "posterFrameInk": case "pctBadgeOn": case "pctFont": case "pctSize":
                    case "posterTick": case "roundelOn": case "grndRail": case "grndRailInk":
                    case "posterDim": case "posterLift": case "roundelInk": case "pctBadgeInk":
                    case "meterStyle": case "deckAnim": case "poster": return posterReveal
                    case "hintInk": case "hintFont": case "hintTrack": case "hintWeight": case "hintCaps": case "hintGap": case "foot": return footerRow
                    case "bgBackdrop": case "bgDim": case "bgTint": case "bgVignette": case "backdrop": return bgArt
                    case "caret": case "caretSeat": case "caretSize": return shelfCaret
                    case "cardrule": return cRule
                    case "cardPlate": return card
                    case "deck": return shelf
                    case "wheel": return wheelUnit
                    case "sock": return sockCap
                    case "rail": return groundRail
                    case "gauge": return scrollGauge
                    case "rating": return ratingText
                    }
                    // global top-strip items resolve via the map Main.qml populates
                    if (home.topItems && home.topItems[k] !== undefined) return home.topItems[k]
                    return null
                }
                function groupItem() {
                    return grp === "CARD" || grp === "ANIMATION" ? card
                         : grp === "DATA-LINK" ? connector
                         : grp === "WHEEL" ? wheelUnit
                         : grp === "SPOTLIGHT" ? spotBlock
                         : grp === "BADGES" ? metaRow
                         : grp === "INFO SHEET" ? (home.spotInfoOpen ? spotInfo : spotBlock)
                         : grp === "DECK" ? shelf
                         : grp === "FOOTER" ? footerRow
                         : null
                }
                // smallest movable element under (px,py) — the most specific target wins
                function hitKey(px, py) {
                    var best = "", bestArea = Infinity
                    var me = mechEditor.moveElems
                    for (var i = 0; i < me.length; ++i) {
                        var k = me[i].k
                        var it = elemFor(k)
                        if (!it || !it.visible || it.width < 1 || it.height < 1) continue
                        var lp = it.mapFromItem(garageFocus, px, py)
                        if (lp.x >= 0 && lp.y >= 0 && lp.x <= it.width && lp.y <= it.height) {
                            var a = it.width * it.height
                            if (a < bestArea) { bestArea = a; best = k }
                        }
                    }
                    return best
                }
                // COMBAT: the lock follows the KEYBOARD by default and only snaps to the cursor
                // while the RIGHT mouse button is held (scan / manual aim is unaffected).
                readonly property bool rmbHeld: (pointer.pressedButtons & Qt.RightButton) !== 0
                readonly property string hoverKey: (hovering && !dragging && !freeAim && home.mechEdit && home.garageMode !== "normal"
                                                    && rmbHeld) ? hitKey(cursorX, cursorY) : ""    // plain hover (combat + scan) only follows on RIGHT-click
                readonly property var pointerItem: dragging ? elemFor(dragKey) : (hoverKey ? elemFor(hoverKey) : null)
                // the element under the cursor — drives the EDITOR selection in BOTH
                // combat and scan (incl. manual aim) so the crosshair readout, the caption
                // and the editor dial always describe the SAME element the box frames.
                readonly property string aimKey: (hovering && !dragging && home.mechEdit && home.garageMode !== "normal"
                                                  && (freeAim || rmbHeld)) ? hitKey(cursorX, cursorY) : ""    // manual aim always; else RIGHT-click to follow
                function dialRowForElem(elemKey) {
                    var tgt = elemFor(elemKey)
                    if (!tgt) return -1
                    var rr = mechEditor.rows
                    for (var i = 0; i < rr.length; ++i)
                        if (rr[i].k && elemFor(rr[i].k) === tgt) return i
                    return -1
                }
                function moveIdxForElem(key) {   // move page: hovered element → its moveElems index
                    var tgt = elemFor(key)
                    if (!tgt) return -1
                    var me = mechEditor.moveElems
                    for (var i = 0; i < me.length; ++i) if (me[i].k && elemFor(me[i].k) === tgt) return i
                    return -1
                }
                onAimKeyChanged: {
                    if (!home.mechEdit || aimKey === "") return
                    if (mechEditor.page === "dials") {
                        var i = dialRowForElem(aimKey)
                        if (i >= 0 && i !== mechEditor.row) mechEditor.row = i
                    } else if (mechEditor.page === "move") {   // keep the ASSEMBLY selection synced to the hovered element
                        var mi = moveIdxForElem(aimKey)
                        if (mi >= 0 && mi !== mechEditor.moveIdx) mechEditor.moveIdx = mi
                    }
                }
                // block binding — touch every reactive dep so it re-evaluates on any change;
                // the mouse (hovered/dragged element) wins over the keyboard-focused dial
                readonly property var targetItem: {
                    if (!home.mechEdit) return null
                    if (pointerItem) return pointerItem
                    var pg = mechEditor.page
                    if (pg === "move") return elemFor(mechEditor.moveKey) || card
                    if (pg !== "dials") return null
                    var g = grp, io = home.spotInfoOpen
                    return elemFor(mechEditor.focusKey) || groupItem()
                }
                // COMBAT/SCAN lock onto the focused part; NORMAL (or a global part like
                // MASTER/TYPE) shows the big whole-screen lockbox instead.
                readonly property bool framing: home.garageMode !== "normal"
                    && (freeAim || (!!targetItem && targetItem.width > 1 && targetItem.height > 1))
                readonly property bool has: home.mechEdit
                visible: has && opacity > 0.01
                opacity: has ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: DS.base } }

                // the framed rect (home coords), tracked as four reals so it GLIDES —
                // part↔part in combat, and part↔whole-screen when the mode changes
                property real bx: 0; property real by: 0; property real bw: 0; property real bh: 0
                property bool primed: false
                function recompute() {
                    if (zooming && !ctrlHeld) {
                        // Shift = ZOOM (no aim): the box wraps the lens region at the cursor.
                        // + Ctrl → falls through to the aim branch = zoom AND aim-fire together
                        var fz = Math.round(150 * home.s)
                        bx = cursorX - fz / 2; by = cursorY - fz / 2; bw = fz; bh = fz
                    } else if (freeAim) {
                        // Ctrl MANUAL AIM: a cursor-driven floating lockbox (+ grid) that
                        // rides the pointer — distinct from plain hover-lock (which snaps to
                        // elements). Info x/y reports the cursor, not an element.
                        var fs = Math.round(150 * home.s)
                        bx = cursorX - fs / 2; by = cursorY - fs / 2; bw = fs; bh = fs
                    } else if (framing && targetItem) {
                        var p = targetItem.mapToItem(home, 0, 0)
                        var pad = Math.round(9 * home.s)
                        bx = p.x - pad; by = p.y - pad
                        bw = targetItem.width + 2 * pad; bh = targetItem.height + 2 * pad
                    } else {
                        // AC1's big idle lockbox — the whole screen, lightly inset
                        var m = Math.round(16 * home.s)
                        bx = m; by = m; bw = width - 2 * m; bh = height - 2 * m
                    }
                    computeTargets()
                }
                // MGSV target acquisition: SCAN mode paints little L-brackets on EVERY editable
                // element (all tags visible, anywhere on screen); holding Ctrl locks the aimed
                // one orange. Computed HERE, not in a binding, to dodge the mapToItem staleness.
                property var lockTargets: []
                function computeTargets() {
                    if (home.garageMode !== "scan" || !home.mechEdit) { if (lockTargets.length) lockTargets = []; return }
                    var out = []
                    var me = mechEditor.moveElems
                    for (var i = 0; i < me.length; ++i) {
                        var it = elemFor(me[i].k)
                        if (!it || !it.visible || it.width < 1 || it.height < 1) continue
                        var p = it.mapToItem(garageFocus, 0, 0)
                        out.push({ x: p.x, y: p.y, w: it.width, h: it.height, k: me[i].k })
                    }
                    // reassign ONLY when the set/geometry changed, so the Repeater keeps its
                    // delegates alive (the soft-settle fires on real appear, not every recompute).
                    // The aimed "primary" is derived reactively in the delegate, not baked here.
                    if (!sameTargets(out, lockTargets)) lockTargets = out
                }
                function sameTargets(a, b) {
                    if (a.length !== b.length) return false
                    for (var i = 0; i < a.length; ++i) {
                        var x = a[i], y = b[i]
                        if (x.k !== y.k || x.x !== y.x || x.y !== y.y || x.w !== y.w || x.h !== y.h) return false
                    }
                    return true
                }
                // coalesce the recompute STORM: the spotlight cascade (grp→syncZoneToGroup
                // →spotInfoOpen→cardT/cwRise) would otherwise fire recompute() several times
                // per hover and swap targetItem mid-update. One 0-interval tick collapses it.
                Timer { id: recomputeTimer; interval: 0; onTriggered: garageFocus.recompute() }
                function scheduleRecompute() { recomputeTimer.restart() }
                onTargetItemChanged: scheduleRecompute()
                onGrpChanged: { home.syncZoneToGroup(grp); scheduleRecompute() }   // hover-lock must NOT replay the deploy anim (only cycling an anim dial does)
                onFreeAimChanged: recompute()          // snap to the aimed element the instant a modifier goes down
                onHasChanged: if (has) { primed = false; recompute(); primeTimer.restart() }
                Timer { id: primeTimer; interval: 40; onTriggered: garageFocus.primed = true }
                // keep the box GLUED to the element through deploys / replays / state
                // changes — polling the live geometry is what makes the lock reliable.
                Timer {
                    running: home.visible && garageFocus.has && garageFocus.framing && home.mechEdit
                    interval: 140; repeat: true
                    onTriggered: garageFocus.recompute()
                }
                Connections {
                    target: home
                    function onWidthChanged() { garageFocus.scheduleRecompute() }
                    function onHeightChanged() { garageFocus.scheduleRecompute() }
                    function onCardTChanged() { garageFocus.scheduleRecompute() }
                    function onCwRiseChanged() { garageFocus.scheduleRecompute() }
                    function onSpotInfoOpenChanged() { garageFocus.scheduleRecompute() }
                    function onGarageModeChanged() { garageFocus.scheduleRecompute(); reticle.reacquire()
                        if (home.garageMode !== "scan") reticle.orange = 0 }   // clear the manual-aim amber tint when leaving scan
                    function onMechChanged() { garageFocus.scheduleRecompute() }   // follow element resize on edit
                }
                // a little catch-up as the box tracks — tunable via the LOCK GLIDE dial
                // (off = teleport). Applies in free-aim too so manual tracking floats.
                readonly property int glideMs: {
                    var v = (home.mech && home.mech.lockGlide) ? home.mech.lockGlide : "normal"
                    var m = { off: 0, snap: 70, normal: 150, loose: 300 }
                    return m[v] !== undefined ? m[v] : 150
                }
                Behavior on bx { enabled: garageFocus.primed && garageFocus.glideMs > 0; NumberAnimation { duration: garageFocus.glideMs; easing.type: Easing.Bezier; easing.bezierCurve: DS.moveCurve } }
                Behavior on by { enabled: garageFocus.primed && garageFocus.glideMs > 0; NumberAnimation { duration: garageFocus.glideMs; easing.type: Easing.Bezier; easing.bezierCurve: DS.moveCurve } }
                Behavior on bw { enabled: garageFocus.primed && garageFocus.glideMs > 0; NumberAnimation { duration: garageFocus.glideMs; easing.type: Easing.Bezier; easing.bezierCurve: DS.moveCurve } }
                Behavior on bh { enabled: garageFocus.primed && garageFocus.glideMs > 0; NumberAnimation { duration: garageFocus.glideMs; easing.type: Easing.Bezier; easing.bezierCurve: DS.moveCurve } }

                // AUTHORITATIVE modifier state — poll the live OS keyboard while scanning,
                // so Ctrl/Shift engage even when the compositor omits them from events.
                Timer {
                    running: home.visible && home.mechEdit && home.garageMode === "scan"
                    interval: 40; repeat: true
                    onTriggered: {
                        var m = App.queryKbdModifiers ? App.queryKbdModifiers() : 0
                        garageFocus.shiftHeld = (m & Qt.ShiftModifier) !== 0
                        garageFocus.ctrlHeld = (m & Qt.ControlModifier) !== 0
                    }
                }

                // the HUD colour follows the MODE (AC palette) — cyan SCAN · steel NORMAL
                // · COMBAT white, but RED when there are unsaved changes (a live warning).
                readonly property color hud: home.garageMode === "scan" ? "#4fd6ea"
                    : home.garageMode === "normal" ? "#9fb4c2"
                    : (mechEditor.dirty ? "#ff4d4d" : "#f4f8fc")
                // MODE colour for the peripheral HUD (banner + side readouts): manual amber,
                // scan cyan, normal dim, combat white. (The reticle BOX uses lockCol instead —
                // box = target-lock state, peripherals = current mode.)
                // clean per-mode colour — the 3-mode strip uses THIS so it stays unaffected by dirty
                readonly property color cleanModeCol: manualMode ? "#ffcf6b"
                    : home.garageMode === "scan" ? "#5fcde4"
                    : home.garageMode === "normal" ? Theme.withAlpha("#f4f8fc", 0.62) : "#f4f8fc"
                // banner + peripheral readouts turn RED on an unsaved change (a live warning)
                readonly property color modeCol: mechEditor.dirty ? "#ff4d4d" : cleanModeCol
                readonly property color scrimCol: "#0a0c12"
                // COMBAT dims hard around the locked part; SCAN dims light so the grid
                // reads across the board; NORMAL (whole-screen box) doesn't dim at all.
                readonly property real scrimA: !framing ? 0.0
                    : home.garageMode === "scan" ? 0.22 : 0.6

                // dim mask — four plates around the framed hole
                Rectangle { color: garageFocus.scrimCol; opacity: garageFocus.scrimA
                    x: 0; y: 0; width: parent.width; height: Math.max(0, garageFocus.by) }
                Rectangle { color: garageFocus.scrimCol; opacity: garageFocus.scrimA
                    x: 0; y: garageFocus.by + garageFocus.bh
                    width: parent.width; height: Math.max(0, parent.height - (garageFocus.by + garageFocus.bh)) }
                Rectangle { color: garageFocus.scrimCol; opacity: garageFocus.scrimA
                    x: 0; y: garageFocus.by; width: Math.max(0, garageFocus.bx); height: garageFocus.bh }
                Rectangle { color: garageFocus.scrimCol; opacity: garageFocus.scrimA
                    x: garageFocus.bx + garageFocus.bw; y: garageFocus.by
                    width: Math.max(0, parent.width - (garageFocus.bx + garageFocus.bw)); height: garageFocus.bh }

                // full-screen crosshair — the cardinal lines run from the lockbox
                // edge-centres out to the SCREEN edges, extending on lock-on. One cross
                // tying the whole screen to the box (unifies the reticle).
                Item {
                    id: crosshair
                    visible: garageFocus.framing
                    anchors.fill: parent
                    readonly property real ct: Math.max(2, Math.round(2 * home.s))
                    readonly property color c0: reticle.crossCol                        // bright, at the box
                    readonly property color c1: Theme.withAlpha(reticle.lockCol, 0.16)  // faded, at the screen edge
                    Rectangle {   // top
                        x: garageFocus.bx + garageFocus.bw / 2 - crosshair.ct / 2; width: crosshair.ct
                        height: garageFocus.by * reticle.extend; y: garageFocus.by - height
                        gradient: Gradient {
                            GradientStop { position: 0; color: crosshair.c1 }
                            GradientStop { position: 1; color: crosshair.c0 }
                        }
                    }
                    Rectangle {   // bottom
                        x: garageFocus.bx + garageFocus.bw / 2 - crosshair.ct / 2; width: crosshair.ct
                        y: garageFocus.by + garageFocus.bh
                        height: (garageFocus.height - (garageFocus.by + garageFocus.bh)) * reticle.extend
                        gradient: Gradient {
                            GradientStop { position: 0; color: crosshair.c0 }
                            GradientStop { position: 1; color: crosshair.c1 }
                        }
                    }
                    Rectangle {   // left
                        y: garageFocus.by + garageFocus.bh / 2 - crosshair.ct / 2; height: crosshair.ct
                        width: garageFocus.bx * reticle.extend; x: garageFocus.bx - width
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0; color: crosshair.c1 }
                            GradientStop { position: 1; color: crosshair.c0 }
                        }
                    }
                    Rectangle {   // right
                        y: garageFocus.by + garageFocus.bh / 2 - crosshair.ct / 2; height: crosshair.ct
                        x: garageFocus.bx + garageFocus.bw
                        width: (garageFocus.width - (garageFocus.bx + garageFocus.bw)) * reticle.extend
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0; color: crosshair.c0 }
                            GradientStop { position: 1; color: crosshair.c1 }
                        }
                    }
                }

                // SCAN grid — a dense green "hacker" grid CONFINED to the lockbox (clipped
                // to the framed element), not the whole screen.
                Item {
                    id: scanGrid
                    visible: home.garageMode === "scan" && garageFocus.framing && !garageFocus.zooming
                    x: garageFocus.bx; y: garageFocus.by
                    width: garageFocus.bw; height: garageFocus.bh
                    clip: true
                    // GRID 1 = fine lines · 2 = cross+lines · 3 = dot matrix (g cycles)
                    readonly property int n: home.scanGridN
                    onNChanged: homeScanPulse.restart()   // grid-change flash in the lockbox
                    SequentialAnimation { id: homeScanPulse
                        NumberAnimation { target: scanGrid; property: "opacity"; to: 0.15; duration: 70; easing.type: Easing.OutQuad }
                        NumberAnimation { target: scanGrid; property: "opacity"; to: 1; duration: 260; easing.type: Easing.OutCubic } }
                    readonly property int cell: Math.max(8, Math.round((n === 3 ? 16 : 13) * home.s))
                    readonly property color gcol: Theme.withAlpha("#f4f8fc", 0.16)
                    readonly property color gcolHi: Theme.withAlpha("#f4f8fc", 0.32)
                    readonly property int cols: Math.ceil(width / cell) + 1
                    readonly property int rows: Math.ceil(height / cell) + 1
                    Repeater {  // vertical lines (styles 1 & 2)
                        model: scanGrid.n !== 3 ? scanGrid.cols : 0
                        Rectangle { required property int index; x: index * scanGrid.cell; width: 1; height: scanGrid.height; color: scanGrid.gcol }
                    }
                    Repeater {  // horizontal lines (styles 1 & 2)
                        model: scanGrid.n !== 3 ? scanGrid.rows : 0
                        Rectangle { required property int index; y: index * scanGrid.cell; height: 1; width: scanGrid.width; color: scanGrid.gcol }
                    }
                    Repeater {  // dot matrix (style 3)
                        model: scanGrid.n === 3 ? scanGrid.cols * scanGrid.rows : 0
                        Rectangle { required property int index
                            x: (index % scanGrid.cols) * scanGrid.cell; y: Math.floor(index / scanGrid.cols) * scanGrid.cell
                            width: 2; height: 2; color: scanGrid.gcol }
                    }
                    // centre crosshair (style 2, brighter)
                    Rectangle { visible: scanGrid.n === 2; anchors.horizontalCenter: parent.horizontalCenter; width: 1; height: parent.height; color: scanGrid.gcolHi }
                    Rectangle { visible: scanGrid.n === 2; anchors.verticalCenter: parent.verticalCenter; height: 1; width: parent.width; color: scanGrid.gcolHi }
                }

                // the reticle — an MGS/AC target lock: corner brackets SNAP inward as it
                // acquires the part, a scanline sweeps, the frame flashes, and an MGS
                // readout stamps the part name + its live box (or the x/y edit delta).
                Item {
                    id: reticle
                    x: garageFocus.bx; y: garageFocus.by
                    width: garageFocus.bw; height: garageFocus.bh

                    // lock = corner convergence · flash = white burst on acquire · orange
                    // = the manual-aim LOCKED tint (blue→orange, with a blue flash on each
                    // element-to-element re-lock) · breathe = the slow pulse on the ticks.
                    property real lock: 1
                    property real flash: 0
                    // manual-aim lock tint: 0 = blue (hud), 1 = orange (#ffcf6b). Each time the
                    // aim ACQUIRES a (new) element while manual-aiming it snaps to blue then
                    // warms to orange — a blue flash reading as "re-locked". Blue everywhere else.
                    property real orange: 0
                    readonly property string lockTarget: (garageFocus.manualMode && garageFocus.aimKey !== "") ? garageFocus.aimKey : ""
                    onLockTargetChanged: { if (lockTarget !== "") orangeAcquire.restart(); else orange = 0 }
                    property real breathe: 1
                    property real extend: 1     // 0→1 grows the crosshair out to the screen edges
                    transform: Scale { origin.x: reticle.width / 2; origin.y: reticle.height / 2
                                       xScale: 1 + 0.045 * reticle.lock; yScale: 1 + 0.045 * reticle.lock }
                    function acquire() { lockAnim.restart(); flashAnim.restart(); scanAnim.restart(); extendAnim.restart() }
                    function reacquire() { lockAnim.restart(); extendAnim.restart() }   // mode change: re-lock, NO green
                    Component.onCompleted: acquire()
                    Connections { target: garageFocus
                        function onGrpChanged() { reticle.acquire() }
                        function onTargetItemChanged() { reticle.acquire() } }
                    NumberAnimation { id: lockAnim; target: reticle; property: "lock"
                        from: 1; to: 0; duration: 200; easing.type: Easing.OutCubic }
                    SequentialAnimation { id: flashAnim
                        NumberAnimation { target: reticle; property: "flash"; to: 1; duration: 40 }
                        NumberAnimation { target: reticle; property: "flash"; to: 0; duration: 260; easing.type: Easing.OutQuad } }
                    SequentialAnimation { id: orangeAcquire        // blue flash → warm to orange
                        NumberAnimation { target: reticle; property: "orange"; to: 0; duration: 70 }
                        NumberAnimation { target: reticle; property: "orange"; to: 1; duration: 300; easing.type: Easing.OutCubic } }
                    NumberAnimation { id: extendAnim; target: reticle; property: "extend"
                        from: 0; to: 1; duration: 380; easing.type: Easing.OutCubic }
                    SequentialAnimation { running: home.visible && home.mechEdit; loops: Animation.Infinite    // breathe
                        NumberAnimation { target: reticle; property: "breathe"; to: 0.4; duration: 1500; easing.type: Easing.InOutSine }
                        NumberAnimation { target: reticle; property: "breathe"; to: 1; duration: 1500; easing.type: Easing.InOutSine } }

                    // hud (blue) → orange (#ffcf6b) by `orange` — the manual-aim lock tint
                    readonly property color lockCol: Qt.rgba(
                        garageFocus.hud.r + (1.0   - garageFocus.hud.r) * orange,
                        garageFocus.hud.g + (0.812 - garageFocus.hud.g) * orange,
                        garageFocus.hud.b + (0.42  - garageFocus.hud.b) * orange, 1)
                    readonly property color edge: "#222034"          // mech-chrome navy outline
                    readonly property real arm: Math.round(20 * home.s)
                    readonly property real th: Math.max(2, Math.round(4 * home.s * (mechEditor.sys ? ({ thin: 0.6, med: 1, thick: 1.5 }[mechEditor.sys.lockThick] || 1) : 1)))
                    readonly property real spread: lock * Math.round(30 * home.s)   // brackets clamp in from wide on acquire
                    readonly property color c: lockCol   // opaque so the corner brackets OCCLUDE the marching dashes beneath them
                    readonly property real tick: Math.round(12 * home.s)             // cardinal tick length
                    readonly property real tth: Math.max(2, Math.round(2 * home.s))
                    readonly property color tc: Theme.withAlpha(lockCol, 0.3 + 0.5 * breathe + 0.2 * flash)
                    readonly property color crossCol: Theme.withAlpha(lockCol, 0.34 + 0.24 * breathe + 0.3 * flash)

                    // acquisition flash — the whole frame whites up for a beat on lock
                    Rectangle { anchors.fill: parent; color: garageFocus.hud; opacity: 0.14 * reticle.flash }

                    // rotating dotted "safe area" — a dashed boundary just outside the
                    // box whose dashes MARCH continuously around it (a live lock, never
                    // static). Sits outside the corner brackets.
                    Shape {
                        id: safeArea
                        anchors.fill: parent
                        anchors.margins: Math.round(reticle.th / 2)   // runs the bracket CENTRELINE
                        ShapePath {
                            id: safePath
                            strokeColor: Theme.withAlpha(reticle.lockCol, 0.72)
                            strokeWidth: Math.max(1, Math.round(1 * home.s))
                            fillColor: "transparent"
                            strokeStyle: ShapePath.DashLine
                            dashPattern: [2, 3]
                            startX: 0; startY: 0
                            PathLine { x: safeArea.width; y: 0 }
                            PathLine { x: safeArea.width; y: safeArea.height }
                            PathLine { x: 0; y: safeArea.height }
                            PathLine { x: 0; y: 0 }
                        }
                        NumberAnimation { target: safePath; property: "dashOffset"
                            from: 0; to: 5; duration: 700; loops: Animation.Infinite
                            running: home.visible && home.mechEdit }
                    }

                    // scanline sweeps top→bottom on acquire
                    Rectangle { id: scanline
                        x: 0; width: parent.width; height: Math.max(1, Math.round(1 * home.s))
                        color: reticle.lockCol; opacity: 0
                        NumberAnimation { id: scanAnim; target: scanline; property: "y"
                            from: 0; to: reticle.height; duration: 420; easing.type: Easing.OutSine }
                        SequentialAnimation { running: scanAnim.running
                            NumberAnimation { target: scanline; property: "opacity"; to: 0.5; duration: 40 }
                            NumberAnimation { target: scanline; property: "opacity"; to: 0; duration: 380 } } }

                    // four corner brackets — white core + navy edge (pixel-art, so they
                    // read crafted). Offset OUT by `spread`, converging to 0 on lock.
                    Rectangle { x: -reticle.spread; y: -reticle.spread; width: reticle.arm; height: reticle.th; color: reticle.c; border.width: 1; border.color: reticle.edge }
                    Rectangle { x: -reticle.spread; y: -reticle.spread; width: reticle.th; height: reticle.arm; color: reticle.c; border.width: 1; border.color: reticle.edge }
                    Rectangle { x: parent.width - reticle.arm + reticle.spread; y: -reticle.spread; width: reticle.arm; height: reticle.th; color: reticle.c; border.width: 1; border.color: reticle.edge }
                    Rectangle { x: parent.width - reticle.th + reticle.spread; y: -reticle.spread; width: reticle.th; height: reticle.arm; color: reticle.c; border.width: 1; border.color: reticle.edge }
                    Rectangle { x: -reticle.spread; y: parent.height - reticle.th + reticle.spread; width: reticle.arm; height: reticle.th; color: reticle.c; border.width: 1; border.color: reticle.edge }
                    Rectangle { x: -reticle.spread; y: parent.height - reticle.arm + reticle.spread; width: reticle.th; height: reticle.arm; color: reticle.c; border.width: 1; border.color: reticle.edge }
                    Rectangle { x: parent.width - reticle.arm + reticle.spread; y: parent.height - reticle.th + reticle.spread; width: reticle.arm; height: reticle.th; color: reticle.c; border.width: 1; border.color: reticle.edge }
                    Rectangle { x: parent.width - reticle.th + reticle.spread; y: parent.height - reticle.arm + reticle.spread; width: reticle.th; height: reticle.arm; color: reticle.c; border.width: 1; border.color: reticle.edge }

                    // (top-right callout retired — the mode's live tool state + [G] cycle key now
                    //  lives inline in the readout below, identical for manual-aim & zoom.)

                    // (the cardinal lines are drawn FULL-SCREEN at the garageFocus level
                    //  below — they run from these edge-centres out to the screen edges)

                    // ── MGS readout: part name + live box, or the x/y edit delta ──────
                    Column {
                        id: readCol
                        visible: garageFocus.framing && (home.canEdit || garageFocus.zooming)   // readouts when editing OR zooming
                        readonly property bool assembling: mechEditor.page === "move"
                        readonly property var moff: assembling ? home.mOff(mechEditor.moveKey) : [0, 0]
                        // above the frame if there's room; otherwise it must sit inside
                        // the top edge — right over the element being edited — so it
                        // FADES DOWN there instead of blocking what you're tuning.
                        readonly property bool clear: garageFocus.by > Math.round(52 * home.s)
                        x: 0
                        y: clear ? -(height + Math.round(5 * home.s)) : Math.round(5 * home.s)
                        opacity: clear ? 1 : 0.12
                        Behavior on opacity { NumberAnimation { duration: DS.base } }
                        spacing: Math.round(1 * home.s)
                        // subtle drop shadow so the readout reads on any backdrop
                        layer.enabled: true
                        layer.effect: MultiEffect {
                            shadowEnabled: true; shadowColor: "#000000"
                            shadowBlur: 0.7; shadowVerticalOffset: 1; shadowOpacity: 0.65
                        }
                        Row {   // left label-stack (title over coords) + the right-side tool-state chip
                            spacing: Math.round(24 * home.s)
                            Column {   // left: mode/part title above the x/y coords
                                spacing: Math.round(2 * home.s)
                                Item {   // marker sprite + part name, on ONE shared centre axis
                                    // (a font glyph rode off-centre; a fixed 16×16 sprite doesn't)
                                    height: Math.max(tagIcon.height, tagText.height)
                                    width: tagIcon.width + Math.round(6 * home.s) + tagText.width
                                    Item {   // marker sprite, TINTED to the mode colour
                                        id: tagIcon
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: Math.round(18 * home.s); height: width
                                        Image {
                                            id: tagIconSrc
                                            anchors.fill: parent
                                            source: (App.heroDevRev, home.devSrc("icon-play"))
                                            fillMode: Image.PreserveAspectFit
                                            smooth: false
                                            visible: false
                                        }
                                        MultiEffect {
                                            anchors.fill: parent
                                            source: tagIconSrc
                                            colorization: 1.0
                                            colorizationColor: garageFocus.modeCol
                                        }
                                    }
                                    Text {
                                        id: tagText
                                        anchors.left: tagIcon.right
                                        anchors.leftMargin: Math.round(6 * home.s)
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: readCol.assembling ? mechEditor.moveLabel
                                            : garageFocus.zooming ? (garageFocus.ctrlHeld ? "ZOOM AIM" : "ZOOM")
                                            : (garageFocus.freeAim && !garageFocus.aimKey) ? "MANUAL AIM"
                                            : garageFocus.grp
                                        color: garageFocus.modeCol
                                        font.family: mgsCodecFont.name; font.bold: true
                                        font.pixelSize: home.pxi(Math.round(20 * home.s)); font.letterSpacing: 3
                                    }
                                }
                                Row {   // x/y line — in MANUAL AIM the GRID chip sits inline right after it
                                    spacing: Math.round(11 * home.s)
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: readCol.assembling
                                            ? "Δ " + readCol.moff[0] + " , " + readCol.moff[1] + (mechEditor.moveSizable ? "   ×" + mechEditor.moveScale.toFixed(2) : "")     // ASSEMBLY: offset (+ scale if sizable)
                                            : home.garageMode === "scan"
                                            ? "X " + Math.round(garageFocus.cursorX) + "  Y " + Math.round(garageFocus.cursorY)
                                            : "X " + Math.round(garageFocus.bx) + "  Y " + Math.round(garageFocus.by)
                                              + "   " + Math.round(garageFocus.bw) + "×" + Math.round(garageFocus.bh)
                                        color: Theme.withAlpha(garageFocus.modeCol, 0.92)
                                        font.family: mgsHudFont.name; font.pixelSize: home.pxi(Math.round(14 * home.s)); font.letterSpacing: 1
                                    }
                                    Row {   // MANUAL AIM inline chip — GRID n + [g], compact on the x/y line
                                        visible: home.garageMode === "scan" && !garageFocus.zooming
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: Math.round(5 * home.s)
                                        Text { anchors.verticalCenter: parent.verticalCenter
                                            text: "GRID " + home.scanGridN
                                            color: Theme.withAlpha(garageFocus.modeCol, 0.95); font.family: mgsHudFont.name; font.bold: true
                                            font.pixelSize: home.pxi(Math.round(14 * home.s)); font.letterSpacing: 1 }
                                        Rectangle {
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: gKh.width + Math.round(6 * home.s); height: gKh.height + Math.round(3 * home.s)
                                            radius: 2; color: Theme.withAlpha(garageFocus.modeCol, 0.16)
                                            border.width: 1; border.color: Theme.withAlpha(garageFocus.modeCol, 0.5)
                                            Text { id: gKh; anchors.centerIn: parent; text: "G"; color: garageFocus.modeCol
                                                font.family: mgsHudFont.name; font.bold: true; font.pixelSize: home.pxi(Math.round(11 * home.s))}
                                        }
                                    }
                                    Row {   // ZOOM inline chip — level + [g] on the x/y line (was far right)
                                        visible: garageFocus.zooming
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: Math.round(5 * home.s)
                                        Text { anchors.verticalCenter: parent.verticalCenter
                                            text: garageFocus.zoomLabel
                                            color: Theme.withAlpha(garageFocus.modeCol, 0.95); font.family: mgsHudFont.name; font.bold: true
                                            font.pixelSize: home.pxi(Math.round(16 * home.s)); font.letterSpacing: 1 }
                                        Rectangle {
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: gKhZ.width + Math.round(6 * home.s); height: gKhZ.height + Math.round(3 * home.s)
                                            radius: 2; color: Theme.withAlpha(garageFocus.modeCol, 0.16)
                                            border.width: 1; border.color: Theme.withAlpha(garageFocus.modeCol, 0.5)
                                            Text { id: gKhZ; anchors.centerIn: parent; text: "G"; color: garageFocus.modeCol
                                                font.family: mgsHudFont.name; font.bold: true; font.pixelSize: home.pxi(Math.round(11 * home.s))}
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // ── MGSV sub-target locks — every editable element in SCAN gets clean L-brackets:
                //    quiet blue tracking, the Ctrl-aimed one orange (primary). Single-stroke Shape
                //    corners, proportional to each asset, soft-settle scale-in on appear.
                Repeater {
                    model: garageFocus.lockTargets
                    Item {
                        id: tgt
                        required property var modelData
                        // the aimed element is the PRIMARY lock (orange) — derived reactively so the
                        // delegate persists (and just re-tints) as you sweep with Ctrl
                        readonly property bool primary: garageFocus.ctrlHeld && modelData.k === garageFocus.aimKey
                        // proportional inset + arm so brackets sit right on ANY asset size (tiny
                        // chips → big posters → imported sprites), within sane bounds
                        readonly property real md: Math.min(modelData.w, modelData.h)
                        readonly property real pad: Math.max(2, Math.min(Math.round(8 * home.s), Math.round(md * 0.1)))
                        property real arm: Math.max(Math.round(6 * home.s), Math.min(Math.round(20 * home.s), Math.round(md * 0.3))) * (primary ? 1.25 : 1)
                        readonly property real th: Math.max(1, Math.round((primary ? 2 : 1.4) * home.s))
                        property color animCol: primary ? reticle.lockCol : Theme.withAlpha(garageFocus.hud, 0.4)
                        Behavior on animCol { ColorAnimation { duration: 130 } }
                        Behavior on arm { NumberAnimation { duration: 120; easing.type: Easing.OutQuad } }
                        x: modelData.x - pad; y: modelData.y - pad
                        width: modelData.w + 2 * pad; height: modelData.h + 2 * pad
                        transformOrigin: Item.Center
                        opacity: primary ? (0.78 + 0.22 * reticle.breathe) : 1
                        Behavior on opacity { NumberAnimation { duration: 130 } }
                        // soft settle — scale in when a target first appears (entering scan)
                        scale: 0.88
                        Component.onCompleted: settle.restart()
                        NumberAnimation { id: settle; target: tgt; property: "scale"; to: 1; duration: 150; easing.type: Easing.OutBack; easing.overshoot: 1.1 }
                        // clean single-stroke L corners (one Shape, mitered elbows)
                        Shape {
                            anchors.fill: parent
                            ShapePath {
                                strokeColor: tgt.animCol; strokeWidth: tgt.th; fillColor: "transparent"
                                capStyle: ShapePath.FlatCap; joinStyle: ShapePath.MiterJoin
                                startX: 0; startY: tgt.arm
                                PathLine { x: 0; y: 0 }
                                PathLine { x: tgt.arm; y: 0 }
                                PathMove { x: tgt.width - tgt.arm; y: 0 }
                                PathLine { x: tgt.width; y: 0 }
                                PathLine { x: tgt.width; y: tgt.arm }
                                PathMove { x: tgt.width; y: tgt.height - tgt.arm }
                                PathLine { x: tgt.width; y: tgt.height }
                                PathLine { x: tgt.width - tgt.arm; y: tgt.height }
                                PathMove { x: tgt.arm; y: tgt.height }
                                PathLine { x: 0; y: tgt.height }
                                PathLine { x: 0; y: tgt.height - tgt.arm }
                            }
                        }
                    }
                }

                // ── AC5 scan-info readout: the focused dial + a position slider, hung
                // off the lock so you can read/change values in COMBAT (panel dimmed). ──
                Item {
                    id: scanInfo
                    visible: garageFocus.framing && home.mechEdit && home.canEdit && mechEditor.page === "dials"
                             && mechEditor.focusDialLabel.length > 0 && mechEditor.focusDialOpts.length > 0
                    readonly property color mc: garageFocus.modeCol
                    readonly property int curIdx: mechEditor.focusDialOpts.indexOf(mechEditor.focusDialCur)
                    readonly property real gap: Math.round(28 * home.s)
                    // sit on the side AWAY from the editor panel so it's never hidden behind it
                    // sit on whichever side of the lockbox has MORE room to the screen
                    // edge, so the readout never crams against an edge / covers content
                    readonly property bool infoLeft: garageFocus.bx > (garageFocus.width - garageFocus.bx - garageFocus.bw)
                    width: infoCol.width; height: infoCol.height
                    x: infoLeft ? Math.max(Math.round(8 * home.s), garageFocus.bx - gap - width)
                                : Math.min(garageFocus.width - width - Math.round(8 * home.s), garageFocus.bx + garageFocus.bw + gap)
                    y: Math.max(Math.round(10 * home.s),
                         Math.min(garageFocus.height - height - Math.round(10 * home.s),
                                  garageFocus.by + garageFocus.bh / 2 - height / 2))
                    opacity: visible ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: DS.base } }
                    Column {
                        id: infoCol
                        spacing: Math.round(5 * home.s)
                        Row {   // dial label
                            spacing: Math.round(6 * home.s)
                            Rectangle { anchors.verticalCenter: parent.verticalCenter
                                width: Math.round(7 * home.s); height: width; rotation: 45; color: scanInfo.mc }
                            Text { text: mechEditor.focusDialLabel; color: scanInfo.mc
                                font.family: mgsCodecFont.name; font.bold: true
                                font.pixelSize: home.pxi(Math.round(19 * home.s)); font.letterSpacing: 3 }
                        }
                        Row {   // current value (big) + swatch when it's a colour dial
                            spacing: Math.round(7 * home.s)
                            Rectangle { visible: mechEditor.focusIsInk && String(mechEditor.focusDialCur) !== "auto"
                                anchors.verticalCenter: parent.verticalCenter
                                width: Math.round(17 * home.s); height: width
                                color: mechEditor.focusIsInk ? home.mechInk(mechEditor.focusDialCur) : "transparent"
                                border.width: 1; border.color: "#222034" }
                            Text { text: mechEditor.fmt(mechEditor.focusDialCur); color: scanInfo.mc
                                font.family: mgsHudFont.name; font.bold: true
                                font.pixelSize: home.pxi(Math.round(26 * home.s)); font.letterSpacing: 2 }
                        }
                        Row {   // segmented slider — position in the option range
                            spacing: Math.round(3 * home.s)
                            Repeater {
                                model: mechEditor.focusDialOpts.length
                                Rectangle {
                                    required property int index
                                    width: Math.round(20 * home.s); height: Math.round(6 * home.s)
                                    color: index === scanInfo.curIdx ? scanInfo.mc : Theme.withAlpha(scanInfo.mc, 0.2)
                                }
                            }
                        }
                        Text {   // count
                            text: (scanInfo.curIdx + 1) + " / " + mechEditor.focusDialOpts.length
                            color: Theme.withAlpha(scanInfo.mc, 0.55)
                            font.family: mgsHudFont.name; font.pixelSize: home.pxi(Math.round(13 * home.s)); font.letterSpacing: 2
                        }
                    }
                }

                // ── AC mode banner — text only, always up while the GARAGE is open;
                // white COMBAT · cyan SCAN · dim NORMAL, with a pop on each switch ──
                Column {
                    id: modeBanner
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: home.topBleed + Math.round(18 * home.s)
                    spacing: Math.round(6 * home.s)
                    transformOrigin: Item.Center
                    readonly property color mc: garageFocus.modeCol
                    // the indicator BREATHES at a pace set by the mode — scan fast
                    // (active scan), combat firm, normal a slow calm breath.
                    property real pulse: 1
                    readonly property int pulseMs: home.garageMode === "scan" ? 460
                        : home.garageMode === "combat" ? 900 : 1700
                    SequentialAnimation { running: home.visible && home.mechEdit; loops: Animation.Infinite
                        NumberAnimation { target: modeBanner; property: "pulse"; to: 0.34; duration: modeBanner.pulseMs; easing.type: Easing.InOutSine }
                        NumberAnimation { target: modeBanner; property: "pulse"; to: 1; duration: modeBanner.pulseMs; easing.type: Easing.InOutSine } }
                    Connections { target: home; function onGarageModeChanged() { bannerKick.restart() } }
                    NumberAnimation { id: bannerKick; target: modeBanner; property: "scale"
                        from: 1.16; to: 1; duration: 260; easing.type: Easing.OutBack }

                    Row {   // pip + mode name
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: Math.round(7 * home.s)
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.round(8 * home.s); height: width; rotation: 45
                            color: modeBanner.mc
                            opacity: 0.4 + 0.6 * modeBanner.pulse
                        }
                        Text {
                            id: modeName
                            anchors.verticalCenter: parent.verticalCenter
                            // fixed height + centered so a longer mode name never reflows the
                            // legend/hint rows below; the scale-pop softens the text switch
                            height: Math.round(24 * home.s); verticalAlignment: Text.AlignVCenter
                            text: garageFocus.manualMode ? (garageFocus.zooming ? (garageFocus.ctrlHeld ? "ZOOM AIM" : "ZOOM MODE") : "MANUAL MODE") : home.garageMode.toUpperCase() + " MODE"
                            color: modeBanner.mc
                            opacity: 0.6 + 0.4 * modeBanner.pulse
                            font.family: mgsHudFont.name; font.bold: true
                            font.pixelSize: home.pxi(Math.round(18 * home.s)); font.letterSpacing: 6
                            transformOrigin: Item.Center
                            onTextChanged: modeNameFlip.restart()
                            NumberAnimation { id: modeNameFlip; target: modeName; property: "scale"
                                from: 1.14; to: 1; duration: 240; easing.type: Easing.OutBack }
                        }
                    }
                    Row {   // vim keybind legend — active mode lit
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: Math.round(11 * home.s)
                        Repeater {
                            model: [["I", "COMBAT", "combat"], ["V", "SCAN", "scan"], ["N", "NORMAL", "normal"]]
                            Text {
                                required property var modelData
                                readonly property bool on: home.garageMode === modelData[2]
                                text: modelData[0] + " " + modelData[1]
                                color: on ? garageFocus.cleanModeCol : Theme.withAlpha("#f4f8fc", 0.32)   // clean mode colour — NOT the dirty red
                                font.family: mgsCodecFont.name; font.bold: on
                                font.pixelSize: home.pxi(Math.round(9 * home.s)); font.letterSpacing: 2
                            }
                        }
                    }
                    Text {  // scan-mode aim hint — made discoverable
                        anchors.horizontalCenter: parent.horizontalCenter
                        visible: home.garageMode === "scan"
                        text: garageFocus.zooming ? "ZOOM " + garageFocus.zoomLabel + (garageFocus.lensGridN > 0 ? " · GRID " + garageFocus.lensGridN : "") + " · wheel/G zoom · wheel-click grid"
                            : garageFocus.freeAim ? "MANUAL AIM"
                            : "⇧ ZOOM · CTRL AIM-FIRE · ⇧+CTRL BOTH"
                        color: Theme.withAlpha(modeBanner.mc, (garageFocus.shiftHeld || garageFocus.ctrlHeld) ? 1 : 0.5)
                        font.family: mgsCodecFont.name; font.pixelSize: home.pxi(Math.round(8 * home.s)); font.letterSpacing: 2
                    }
                }

                // ── pointer: cursor-follow lock + free-drag (combat nudges) + free-aim ──
                MouseArea {
                    id: pointer
                    anchors.fill: parent
                    enabled: home.mechEdit && home.garageMode !== "normal"
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton   // RIGHT = combat lock-follow · LEFT = grab-drag · MIDDLE (while ⇧-zooming) = cycle in-lens grid
                    cursorShape: garageFocus.dragging ? Qt.ClosedHandCursor
                               : (home.garageMode === "combat" && garageFocus.hoverKey) ? Qt.OpenHandCursor : Qt.CrossCursor
                    property real lastX; property real lastY
                    // modifiers are tracked by the Keys handler (below) so holding Ctrl/Shift
                    // engages the instant it's pressed, not on the next mouse move; the mouse
                    // only clears `hovering`, never the held modifiers
                    onEnabledChanged: if (!enabled) garageFocus.hovering = false
                    onEntered: garageFocus.hovering = true
                    onExited: garageFocus.hovering = false
                    onPositionChanged: (m) => {
                        garageFocus.cursorX = m.x; garageFocus.cursorY = m.y; garageFocus.hovering = true
                        // NB: do NOT set shift/ctrlHeld from m.modifiers — some compositors
                        // omit Ctrl in pointer events, which would overwrite the key-tracked
                        // flag with false on every move (killing manual aim). Keys owns it.
                        if (garageFocus.dragging && home.garageMode === "combat") {
                            var dx = Math.round(m.x - lastX), dy = Math.round(m.y - lastY)
                            if (dx !== 0 || dy !== 0) { garageFocus.dragOff = [garageFocus.dragOff[0] + dx / home.offScale, garageFocus.dragOff[1] + dy / home.offScale]; lastX += dx; lastY += dy; garageFocus.recompute() }   // screen px → reference px so the drag tracks the cursor 1:1 at any scale
                        } else if (garageFocus.freeAim) {
                            garageFocus.recompute()
                        }
                    }
                    onPressed: (m) => {
                        garageFocus.cursorX = m.x; garageFocus.cursorY = m.y
                        if (m.button === Qt.MiddleButton && garageFocus.zooming) {   // ⇧ + wheel-click cycles the in-lens grid
                            garageFocus.lensGridN = (garageFocus.lensGridN + 1) % 4; return
                        }
                        if (home.garageMode === "combat" && m.button === Qt.LeftButton) {   // LEFT press = grab-drag
                            var k = garageFocus.hitKey(m.x, m.y)
                            if (k) { var b = home.mOffRaw(k); garageFocus.dragOff = [b[0], b[1]]; garageFocus.dragKey = k; garageFocus.dragging = true; lastX = m.x; lastY = m.y; mechEditor.pushHist(true) }
                        }
                    }
                    onReleased: {
                        // commit the live drag into mech once, before clearing the flag (no jump)
                        if (garageFocus.dragging && garageFocus.dragKey !== "" && home.garageMode === "combat")
                            home.mechCommitDrag(garageFocus.dragKey, garageFocus.dragOff)
                        garageFocus.dragging = false
                    }
                    onCanceled: garageFocus.dragging = false   // aborted drag → element reverts to mech (no commit)
                    onWheel: (w) => {   // scan+shift: the wheel fine-tunes the lens magnification
                        if (garageFocus.zooming) { garageFocus.zoomBy(w.angleDelta.y > 0 ? 0.25 : -0.25); w.accepted = true }
                        else w.accepted = false   // plain hover: let the shelf scrub have the wheel
                    }
                }
                MouseArea {  // thumb (Back/Forward) mouse buttons cycle EDITOR TABS, any mode
                    anchors.fill: parent
                    enabled: home.mechEdit
                    acceptedButtons: Qt.BackButton | Qt.ForwardButton
                    onPressed: (m) => { if (m.button === Qt.BackButton) mechEditor.pageStep(-1)
                                        else if (m.button === Qt.ForwardButton) mechEditor.pageStep(1) }
                }
                // ── ZOOM LENS — magnifies the reticle centre (scan mode · ZOOM dial).
                //    Samples `stage` (the home content stack); the reticle/HUD live in
                //    sibling layers so they never bleed into the magnified porthole. ──
                Item {
                    id: lens
                    readonly property real zf: garageFocus.zoomF   // live magnification (dial base + wheel fine-tune)
                    readonly property real dia: Math.round(150 * home.s)
                    readonly property real cxp: garageFocus.cursorX
                    readonly property real cyp: garageFocus.cursorY
                    visible: home.mechEdit && home.mech.zoom !== "off" && garageFocus.zooming && dia > 24
                    width: dia; height: dia
                    x: cxp - width / 2
                    y: cyp - height / 2
                    // dark disk UNDER the porthole (a sibling, kept OUT of the masked
                    // layer — a backing rect inside the layer nukes the mask) so any
                    // transparent gap in the magnified content reads as a lens, not a hole
                    Rectangle { anchors.fill: parent; radius: width / 2; color: "#0a0c12" }
                    Item {   // masked magnified content
                        anchors.fill: parent
                        layer.enabled: true
                        layer.effect: MultiEffect { maskEnabled: true; maskSource: lensMask }
                        ShaderEffectSource {
                            anchors.fill: parent
                            sourceItem: stage; live: true; recursive: false
                            sourceRect: {
                                var sz = lens.dia / lens.zf
                                var c = stage.mapFromItem(garageFocus, lens.cxp, lens.cyp)
                                return Qt.rect(c.x - sz / 2, c.y - sz / 2, sz, sz)
                            }
                        }
                    }
                    Item {   // in-lens GRID overlay — Alt+L cycles (fine / thirds / dots), clipped to the porthole
                        id: lensGrid
                        anchors.fill: parent
                        visible: garageFocus.lensGridN > 0
                        layer.enabled: true
                        layer.effect: MultiEffect { maskEnabled: true; maskSource: lensMask }
                        readonly property real cell: Math.max(6, Math.round(lens.dia / 9))
                        readonly property color gcol: Theme.withAlpha(reticle.lockCol, 0.45)
                        readonly property int nL: Math.ceil(lens.dia / cell) + 1
                        Repeater { model: garageFocus.lensGridN === 1 ? lensGrid.nL : 0
                            Rectangle { x: index * lensGrid.cell; width: 1; height: lens.dia; color: lensGrid.gcol } }
                        Repeater { model: garageFocus.lensGridN === 1 ? lensGrid.nL : 0
                            Rectangle { y: index * lensGrid.cell; height: 1; width: lens.dia; color: lensGrid.gcol } }
                        Repeater { model: garageFocus.lensGridN === 2 ? 2 : 0
                            Rectangle { x: Math.round(lens.dia * (index + 1) / 3); width: 1; height: lens.dia; color: lensGrid.gcol } }
                        Repeater { model: garageFocus.lensGridN === 2 ? 2 : 0
                            Rectangle { y: Math.round(lens.dia * (index + 1) / 3); height: 1; width: lens.dia; color: lensGrid.gcol } }
                        Repeater { model: garageFocus.lensGridN === 3 ? lensGrid.nL * lensGrid.nL : 0
                            Rectangle { readonly property int cols: lensGrid.nL
                                x: (index % cols) * lensGrid.cell - 1; y: Math.floor(index / cols) * lensGrid.cell - 1
                                width: 2; height: 2; radius: 1; color: lensGrid.gcol } }
                    }
                    Item { id: lensMask; anchors.fill: parent; visible: false; layer.enabled: true
                        Rectangle { anchors.fill: parent; radius: width / 2; color: "black" } }
                    Rectangle { anchors.fill: parent; radius: width / 2; color: "transparent"
                        border.width: Math.max(2, Math.round(2 * home.s)); border.color: reticle.lockCol }
                    Rectangle { anchors.centerIn: parent; width: Math.round(9 * home.s); height: 1; color: Theme.withAlpha(reticle.lockCol, 0.7) }
                    Rectangle { anchors.centerIn: parent; width: 1; height: Math.round(9 * home.s); color: Theme.withAlpha(reticle.lockCol, 0.7) }
                }

                // ── circular crosshair — the cursor tool in scan mode (brightens while
                //    zooming with Shift or free-aiming with Ctrl) ──────────────────────
                Item {
                    visible: garageFocus.hovering && home.mechEdit && home.garageMode === "scan" && garageFocus.cursorX >= 0
                    x: garageFocus.cursorX; y: garageFocus.cursorY; z: 6
                    readonly property real r: Math.round((garageFocus.zooming ? 14 : 11) * home.s)
                    // full-bright while zoom/manual-aiming; dim on a plain scan hover
                    readonly property real a: (garageFocus.zooming || garageFocus.freeAim) ? 1 : 0.4
                    readonly property real lw: Math.max(1, Math.round(home.s))
                    // orange while manual-locked onto an element (reticle.lockCol)
                    readonly property color cc: reticle.lockCol
                    Rectangle { anchors.centerIn: parent; width: parent.r * 2.4; height: parent.lw; color: Theme.withAlpha(parent.cc, parent.a) }
                    Rectangle { anchors.centerIn: parent; width: parent.lw; height: parent.r * 2.4; color: Theme.withAlpha(parent.cc, parent.a) }
                    Rectangle { anchors.centerIn: parent; width: parent.r * 2; height: width; radius: width / 2
                        color: "transparent"; border.width: Math.max(1, Math.round(1.4 * home.s)); border.color: Theme.withAlpha(parent.cc, parent.a) }
                    // centre dot while zooming
                    Rectangle { anchors.centerIn: parent; visible: garageFocus.zooming
                        width: Math.max(2, Math.round(2 * home.s)); height: width; radius: width / 2; color: parent.cc }
                }

                // (show-all move-handle chips removed — at HOME's element count they stacked
                //  over each other and buried the UI. The focused element is already named by
                //  the readout + framed by the reticle, and the banner explains the controls.)

                // ── ASSEMBLY banner — the dedicated move mode (hidden in NORMAL where nothing acts) ──
                Column {
                    visible: home.mechEdit && mechEditor.page === "move" && garageFocus.framing
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom; anchors.bottomMargin: Math.round(46 * home.s)
                    spacing: Math.round(4 * home.s)
                    Text { anchors.horizontalCenter: parent.horizontalCenter
                           text: "j/k pick  ·  h/l/[ ] move  ·  , . size  ·  ⇧ ×5  ·  right-drag  ·  r reset"
                           color: Theme.withAlpha(garageFocus.hud, 0.75)
                           font.family: mgsCodecFont.name; font.pixelSize: home.pxi(Math.round(10 * home.s)); font.letterSpacing: 2 }
                }
            }

            // ── Mech style editor (M) ────────────────────────────────────────────
            // Last child = above everything: the styles it cycles re-render live
            // underneath it. `p` docks it to either wing, `o` steps its opacity so
            // it never blocks the very thing being tuned.
            MechEditor {
                id: mechEditor
                x: leftSide ? Math.round(24 * home.s)
                            : parent.width - width - Math.round(24 * home.s)
                anchors.verticalCenter: parent.verticalCenter
                open: home.mechEdit
                view: home
            }

            // ── hidden-editor recall — a VERTICAL CONTINUE-style tab on the docked
            // edge; SPACE or a click brings the panel back. It fades out when the
            // locked element sits under the tab so it never blocks editing.
            Item {
                id: recallTab
                z: 51
                visible: home.mechEdit && mechEditor.hidden
                readonly property bool onRight: !mechEditor.leftSide
                // fade (never hide) ONLY when the lock box actually sits under the tab —
                // it must reach the docked edge AND overlap the tab's vertical band. (The
                // old check ignored the y-band, so default-combat framing hid it always.)
                readonly property bool blocking: garageFocus.framing
                    && (onRight ? (garageFocus.bx + garageFocus.bw > parent.width - Math.round(96 * home.s))
                                : (garageFocus.bx < Math.round(96 * home.s)))
                    && garageFocus.by < parent.height / 2 + recallInner.width / 2
                    && garageFocus.by + garageFocus.bh > parent.height / 2 - recallInner.width / 2
                anchors.verticalCenter: parent.verticalCenter
                x: onRight ? parent.width - width - Math.round(3 * home.s) : Math.round(3 * home.s)
                width: Math.round(32 * home.s)               // the tab's THIN axis (it's vertical)
                height: recallInner.width                     // rotated content sets the tall axis
                opacity: visible ? (blocking ? 0.35 : 1) : 0  // dim, never invisible
                Behavior on opacity { NumberAnimation { duration: 220 } }

                Item {  // the plate + label, rotated so it reads vertically along the edge
                    id: recallInner
                    anchors.centerIn: parent
                    rotation: recallTab.onRight ? -90 : 90
                    width: recallRow.width + Math.round(26 * home.s)
                    height: Math.round(30 * home.s)
                    MechButton {  // same family-4 plate as CONTINUE — carries the states
                        anchors.fill: parent
                        family: 4
                        px: home.s >= 1.15 ? 2 : 1
                        hot: recallMouse.containsMouse
                        pressed: recallMouse.pressed
                    }
                    Row {
                        id: recallRow
                        anchors.centerIn: parent
                        spacing: Math.round(6 * home.s)
                        Rectangle {  // SPACE keycap
                            anchors.verticalCenter: parent.verticalCenter
                            width: kcap2.implicitWidth + Math.round(7 * home.s); height: kcap2.implicitHeight + Math.round(3 * home.s)
                            radius: 2; color: Theme.withAlpha(Theme.accent, 0.18); border.width: 1; border.color: Theme.withAlpha(Theme.accent, 0.5)
                            Text { id: kcap2; anchors.centerIn: parent; text: "SPACE"; color: "#8fe3a1"
                                font.family: mgsCodecFont.name; font.bold: true; font.pixelSize: home.pxi(Math.round(9 * home.s)); font.letterSpacing: 1 }
                        }
                        Text { anchors.verticalCenter: parent.verticalCenter; text: "GARAGE"; color: "#dfe9f0"
                            font.family: mgsCodecFont.name; font.bold: true; font.pixelSize: home.pxi(Math.round(10 * home.s)); font.letterSpacing: 2 }
                        Text {  // caret — accent; counter-rotated so it faces LEFT/RIGHT (into the
                            // screen) instead of riding the vertical tab; breathes + blips on activate
                            id: recallCaret
                            anchors.verticalCenter: parent.verticalCenter
                            text: recallTab.onRight ? "◂" : "▸"; color: Theme.accent
                            font.pixelSize: home.pxi(Math.round(15 * home.s)); font.bold: true
                            rotation: recallTab.onRight ? 90 : -90   // cancel recallInner's ∓90 → horizontal
                            transformOrigin: Item.Center
                            SequentialAnimation on opacity {  // continuous breathe draws the eye
                                running: recallTab.visible; loops: Animation.Infinite
                                NumberAnimation { to: 0.5; duration: 720; easing.type: Easing.InOutSine }
                                NumberAnimation { to: 1.0; duration: 720; easing.type: Easing.InOutSine }
                            }
                            SequentialAnimation on scale {
                                id: recallBlip; running: false
                                NumberAnimation { to: 1.6; duration: 90; easing.type: Easing.OutQuad }
                                NumberAnimation { to: 1.0; duration: 170; easing.type: Easing.OutBack }
                            }
                        }
                    }
                }
                MouseArea {
                    id: recallMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { recallBlip.restart(); mechEditor.hidden = false }
                }
                // blip the caret whenever the tab appears, so the eye catches it
                onVisibleChanged: if (visible) recallBlip.restart()
            }
        }
        }
    }
}
