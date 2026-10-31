import QtQuick
import QtQuick.Shapes
import QtQuick.Effects

// STATS — Armored-Core "loadout" cockpit. A 51H box + DEEPEST-IN rows on the
// user's hand-edited dlg hero, a drawn ring gauge, a most-watched poster card,
// and a 30-day watch-terrain graph. Every visual reads stat.<key> so the ported
// MechEditor (Stage D) can re-theme each element. Press M for the dial editor.
FocusScope {
    id: stats

    property var days: []
    property var summary: ({})
    property var weekAct: ({})
    // shared speedo/VFD bloom amount (SPEEDO GLOW dial) — reused on the readout wells
    readonly property bool glowOn: !stats.classic && stats.mech.speedoGlow !== "off"
    readonly property real glowAmt: stats.mech.speedoGlow === "soft" ? 0.5 : stats.mech.speedoGlow === "strong" ? 1.35 : 0.85
    property var shows: []
    // Fill-the-screen responsive frame: the cockpit fills ~93%×84% of the
    // display, its aspect clamped so it never runs too wide (16:9 main monitor)
    // nor too skinny (5:4 CRT). s (font/padding scale) + mpx (plate magnify)
    // both track the fitted height, so the whole console grows to the panel.
    // fill factors = how much of the screen the cockpit uses (rest = black margin).
    // DP-3 pushes high to minimise dead space; the CRT pulls in to a SAFE AREA because a
    // tube overscans (the image runs past the visible glass) and clips content at the edges.
    readonly property bool isCrt: (typeof App !== "undefined") && App && App.mode === "crt"
    readonly property real fillW: width * (isCrt ? 0.93 : 0.975)
    readonly property real fillH: height * (isCrt ? 0.92 : 0.97)
    readonly property real cAspect: Math.max(1.25, Math.min(2.12, fillW / fillH))
    readonly property real cW: Math.min(fillW, fillH * cAspect)
    readonly property real cH: Math.min(fillH, fillW / cAspect)
    readonly property real s: Math.max(0.95, cH / 560)
    // Dialed element offsets (mech.offsets) are stored in REFERENCE pixels — the px
    // they were nudged at on DP-3 2560×1440 fullscreen — and applied ×(s/sRef), so a
    // repositioned element holds its place at ANY window size / resolution (tiled, or
    // the CRT) instead of drifting. sRef is the FIXED scale the offsets were AUTHORED
    // at (DP-3 1440p with the original fillH 0.84 → ~2.16); it must NOT track fillH —
    // keeping it fixed is exactly what lets offsets scale WITH a layout change instead
    // of shifting. Only re-peg it if the whole tune is re-dialed from scratch.
    readonly property real sRef: (1440 * 0.84) / 560
    readonly property real offScale: s / sRef
    // +0.12 bias: pixel-art scale is an INTEGER (crispness), so it steps 20% at each threshold.
    // Without the bias a window just 4% shorter than fullscreen (s 2.38→2.28) drops mpx 5→4 and
    // everything mpx-sized lurches while the continuous (s) layout barely moves. The bias holds a
    // near-fullscreen window on the SAME step as fullscreen; CRT/laptop are far from a threshold
    // and unaffected. Big resizes still step (unavoidable for crisp pixel art), just not on a nudge.
    readonly property int mpx: Math.max(2, Math.min(6, Math.round(1.0 + stats.s * 1.5 + 0.12)))

    FontLoader { id: mgsCodec;  source: "qrc:/assets/mechui/mgs-codec.ttf" }
    FontLoader { id: mgsHud;    source: "qrc:/assets/mechui/mgs-hud.ttf" }
    FontLoader { id: mgsAmmo;   source: "qrc:/assets/mechui/mgs-ammo.ttf" }
    FontLoader { id: mechaFont; source: "qrc:/assets/mechui/mecha.ttf" }
    FontLoader { id: mechaCond; source: "qrc:/assets/mechui/mecha-cond.ttf" }
    readonly property color steelInk: "#dce8ef"
    readonly property color navy: "#222034"
    readonly property color trim: "#aecbd9"

    // ── stats style map + the MechEditor `view` contract (the SAME shape
    //    HomeView provides, so the shared MechEditor re-themes STATS too) ───────
    // shared option vocabularies (mirrors MechEditor's sizes/inks/fonts)
    readonly property var sizes: ["xxs", "xs", "s", "m", "l", "xl", "xxl"]
    readonly property var inks:  ["auto", "navy", "steel", "slate", "trim", "light", "white", "green", "teal", "mint", "cyan", "cyan-hi", "blue", "blue-hi", "violet", "purple", "pink", "red", "red-hi", "warning", "orange", "amber", "amber-hi", "yellow", "grey"]
    readonly property var fonts: ["mgshud", "mgscodec", "mecha", "mecha-cond", "mono"]
    readonly property var weights: ["light", "regular", "demibold", "bold"]
    readonly property var cases:  ["upper", "asis", "title", "lower"]
    readonly property var tracks: ["tight", "normal", "wide", "wider", "widest"]
    // text-style resolvers used across the cockpit's editable text elements
    function weightFor(w) { return w === "light" ? Font.Light : w === "demibold" ? Font.DemiBold : w === "bold" ? Font.Bold : Font.Normal }
    function caseFor(t, c) { return c === "upper" ? String(t).toUpperCase() : c === "lower" ? String(t).toLowerCase()
                                  : c === "title" ? String(t).replace(/\b\w/g, function (m) { return m.toUpperCase() }) : t }
    readonly property var trackFac: ({ tight: 0, normal: 1, wide: 2, wider: 4, widest: 6 })
    function trackFor(k) { var v = trackFac[k]; return v === undefined ? 1 : v }
    // text shadow/outline styles — built-in Text.style (crisp 1px, renders offscreen,
    // no MechPanel bulk): drop = raised shadow below, emboss = sunken, outline = full ring
    function shadowStyleFor(v) { return v === "outline" ? Text.Outline : v === "drop" ? Text.Raised : v === "emboss" ? Text.Sunken : Text.Normal }
    readonly property color shadowInk: "#05080e"
    // elongated cast-shadow (headerShadow: "long") tuning maps — driven by the SHADOW LEN /
    // INK / DIR editor dials so the look is dialled live.
    readonly property var castLenN:  ({ xs: 10, s: 16, m: 24, l: 34, xl: 46 })
    readonly property var castInkO:  ({ faint: 0.10, soft: 0.18, med: 0.28, strong: 0.42, hard: 0.6 })
    readonly property var castDirV:  ({ upleft: [-1, -1], left: [-1, 0], up: [0, -1], downleft: [-1, 1], downright: [1, 1], right: [1, 0] })
    readonly property var castStepP: ({ tight: 0.7, m: 1.0, wide: 1.5 })
    readonly property var castGapN:  ({ flush: 1, tight: 2, m: 3, loose: 5, open: 8 })
    readonly property var glowIntN:  ({ off: 0, soft: 0.7, med: 1.3, strong: 2.2 })
    readonly property var glowRadN:  ({ s: 2.0, m: 3.5, l: 5.0, xl: 7.0 })
    readonly property var wellGlowN: ({ off: 0, soft: 0.45, med: 0.8, strong: 1.3 })

    readonly property var mechDefaults: ({
        chrome: "mech",
        lockGlide: "normal",
        // HERO PLATE
        hero: "cockpit", heroReveal: "slide", edgeGlint: "on", plateGlow: "off", wellGlow: "soft",
        headerInk: "navy", deepLabel: "DEEPEST IN", headerShadow: "none", headerGlow: "off", headerGlowInk: "match", headerGlowSize: "m",
        castLen: "m", castInk: "soft", castDir: "upleft", castStep: "m", castGap: "m", castVec: null, castBright: null, castTone: "neon",
        // READOUT (51H box)
        bigInk: "auto", bigSize: "m", bigFont: "mgshud",
        labelInk: "light", labelSize: "m", statInk: "auto", statSize: "m",
        weekOn: "on", weekLabel: "THIS WEEK", weekInk: "auto", weekSize: "m", weekFont: "mgshud", weekMeter: "on",
        // RING
        ring: "tach", ringInk: "auto", ringThick: "med", hub: "num", ringSpin: "on", ringTicks: "on", speedoGlow: "soft",
        spNumFont: "mgscodec", spUnitFont: "mgshud",
        // ROWS
        rowCount: 8, chevron: "tab", rowPlate: 3, rowGap: 10,
        titleInk: "white", titleSize: "m", titleFont: "mgshud", bar: "liquid", pctInk: "auto",
        // POSTER
        poster: "frame", posterFit: "fit", posterTitle: "plate", posterInk: "white",
        posterBg: "body", posterFrame: "hollow", posterEdge: "on", heroBezel: "off",
        posterScan: "fine", posterTint: "light", heroCrt: "off", posterAnim: "rise", heroSweep: "on", heroSize: "fit", heroCrtY: 0, heroY: 0,
        brkStyle: "l-corner", brkInk: "auto", brkSize: "m",
        // TERRAIN
        graph: "area", graphInk: "auto", graphFill: "light", graphGrid: "lines",
        graphPeak: "on", graphBase: "line", graphLabel: "show",
        graphXAxis: "weeks", graphMean: "dashed", graphPeakMark: "pin",
        graphToday: "dot", graphWell: "recessed", graphLegend: "swatch",
        // TYPE
        font: "mgshud", labelFont: "mgscodec",
        // HUD
        accent: "cyan-hi", bgGlow: "on", crumbInk: "auto", zoom: "2x",
        // ANIMATION
        entrance: "cascade", tempo: "normal", ambient: "subtle", barsGrow: "on",
        // FOOTER
        hints: "show", hintSize: "s",
        // ── v2 per-element + category dials ──────────────────────────────
        posterHdrInk: "navy", posterHdrSize: "m", posterHdrFont: "mgshud", posterHdrBack: "capsule",
        npTitleSize: "m", npTitleFont: "mgscodec",
        npDeepInk: "auto", npDeepSize: "m", npDeepFont: "mgshud",
        npEpInk: "auto", npEpSize: "m", npEpFont: "mgshud",
        npSep: "diamond",
        // hero pill / nameplate BACKING plate — "drawn" = the hand-made asset,
        // "none" = text only, b1..b5 = a 9-sliced button plate from the pack.
        ppillPlate: "drawn", npboxPlate: "drawn",
        // RANK position: "below" = a line atop the nameplate (top pill retired, poster
        // grows up); "top" = the classic header pill.
        heroRankPos: "below",
        terrainInk: "trim", terrainSize: "m", terrainFont: "mgscodec",
        hintInk: "trim", hintFont: "mono", hintBack: "none", hintCaps: true,
        chevBack: "none", chevShow: "all", rowBack: "button", rowInk: "steel", barBack: "outline", pctBack: "none", titleBack: "none",
        titleShadow: "outline", pctShadow: "outline", barSel: "wobble",
        pctFont: "mgshud", pctSize: "m", labFont: "mgscodec", statFont: "mgscodec",
        titleWeight: "regular", titleCase: "asis", titleTrack: "normal",
        headerFont: "mgscodec", headerSize: "m", headerCase: "upper", headerTrack: "wide",
        bigWeight: "bold", bigTrack: "normal",
        crumbSize: "m", crumbTrack: "widest", crumbStyle: "diamond",
        peakInk: "trim", peakSize: "m", peakFont: "mgscodec",
        ringGap: "m", hubInk: "auto", hubSize: "m", ringCaps: "round", hubPulse: "on",
        graphWeight: "m", graphDots: "off", graphAxis: "hours", graphGlow: "off",
        plateTint: "none", edgeSpeed: "normal", ambientSpeed: "normal", bgStyle: "well",
        posterShadow: "on", posterGlow: "off", barGlow: "off",
        npTitleCase: "asis", npTitleWeight: "bold", npTitleTrack: "tight",
        posterHdrCase: "upper", posterHdrTrack: "wide",
        terrainCase: "upper", terrainTrack: "wide",
        labelCase: "upper", labelTrack: "wide", statTrack: "normal", statCase: "upper", labelWeight: "regular",
        weekCase: "upper", weekTrack: "wide", crumbWeight: "bold", crumbCase: "upper",
        peakCase: "upper", peakTrack: "normal", posterHdrWeight: "bold", terrainWeight: "regular",
        npDeepCase: "upper", npDeepTrack: "normal", npEpCase: "upper", npEpTrack: "normal",
        hintCase: "asis", hintTrack: "wide", hintWeight: "regular", pctTrack: "normal", pctWeight: "regular",
        statWeight: "regular", weekWeight: "bold", npDeepWeight: "regular", npEpWeight: "regular",
        gridStyle: "cross", overlay: "none",
        // Declared like HomeView's defaults so mech.offsets/mech.scales (read in
        // ~8 places) are never a missing key — currently only every call site
        // happening to guard them keeps it safe.
        offsets: ({}), scales: ({})
    })
    property var mech: mechDefaults
    // the SELECTED row's sub-elements — so the editor can lock / move / scale the row
    // title, bar, % and caret individually (elemFor points at the selected row's instance)
    property var selT: null; property var selB: null; property var selP: null; property var selC: null; property var selBox: null
    // LIGHT-AIM tool (cast shadow): when on, the mouse cursor is the light source and the
    // shadow rakes away from it live; click / F bakes the current angle into mech.castVec.
    property bool lightAim: false
    property var lightVec: [-1, -1]
    property real lightBright: 0.18                       // shadow strength while aiming (scroll wheel sets it)
    property real lightCx: 0; property real lightCy: 0   // header centre in pointer coords (for the ray)
    property string mechSavedJson: JSON.stringify(mechDefaults)
    property bool mechEdit: false
    property string garageMode: "combat"
    // editing is applicable in COMBAT, or in SCAN while manual-aiming (Ctrl = aim + FIRE):
    // the value readouts + the panel go LIVE only then; plain scan stays read-only inspect.
    readonly property bool canEdit: garageMode === "combat" || (garageMode === "scan" && garageFocus !== null && garageFocus.ctrlHeld && mechEdit)
    // manual-aim LOCKED onto a specific element — the row follows the reticle, so j/k
    // up/down is locked out here to keep your place (free when aiming empty space)
    readonly property bool aimLocked: garageMode === "scan" && garageFocus !== null && garageFocus.ctrlHeld && garageFocus.aimKey !== "" && mechEdit
    property string iconFlash: ""           // MechEditor status-flash channel
    property bool mechGrid: true            // NORMAL full-screen reference grid (g toggles)
    property int scanGridN: 1               // SCAN lockbox grid style 1/2/3 (g cycles in scan)
    readonly property bool classic: stats.mech.chrome === "classic"
    // normal (survey) → combat (tune) → scan (calibrate); only combat edits values
    function cycleGarageMode() { garageMode = garageMode === "normal" ? "combat" : garageMode === "combat" ? "scan" : "normal" }

    // the dial model the ported MechEditor drives — 54 dials in 11 groups,
    // matching the home editor's exhaustive count. Group headers double as
    // the target-lock groups (Stage I). ink rows get a swatch, font rows a
    // specimen. Every key has a live binding on a cockpit element.
    readonly property var mechRows: [
        { h: "MASTER" },
        { k: "chrome", label: "CHROME", opts: ["mech", "classic"] },
        { k: "lockGlide", label: "LOCK GLIDE", opts: ["off", "snap", "normal", "loose"], desc: "how much the target-lock crosshair lags the cursor" },

        { h: "HERO PLATE" },
        { k: "hero",       label: "PLATE",       opts: ["cockpit", "dlg", "console", "body", "wide"] },
        { k: "heroReveal", label: "DEPLOY",      opts: ["slide", "sprite", "fade", "instant"] },   // "sprite" = hand-drawn fx/card-deploy.png strip
        { k: "edgeGlint",  label: "EDGE GLINT",  opts: ["on", "off"] },
        { k: "plateGlow",  label: "PLATE GLOW",  opts: ["off", "on"] },
        { k: "wellGlow",   label: "WELL GLOW",   opts: ["off", "soft", "med", "strong"], desc: "neon halo on the TOTAL WATCHED / THIS WEEK readouts" },
        { k: "headerInk",  label: "HEADER INK",  opts: ["navy", "steel", "white", "cyan", "green", "amber", "blue", "red"], ink: true },
        { k: "deepLabel",  label: "HEADER TEXT", opts: ["DEEPEST IN", "MOST BINGED", "TOP 10 WATCHED", "FOCUS"] },
        { k: "headerFont", label: "HEADER FONT", opts: fonts, specimen: true },
        { k: "headerSize", label: "HEADER SIZE", opts: sizes },
        { k: "headerCase", label: "HEADER CASE", opts: cases },
        { k: "headerTrack",label: "HEADER TRK",  opts: tracks },
        { k: "headerShadow",label:"HEADER SHADOW",opts: ["none", "drop", "emboss", "outline", "long"], desc: "text shadow on the TOP WATCHED / header text ('long' = elongated cast shadow)" },
        { k: "headerGlow", label: "HEADER GLOW", opts: ["off", "soft", "med", "strong"], desc: "GPU neon glow behind the header (needs a bright HEADER INK to read as neon)" },
        { k: "headerGlowInk",label:"GLOW INK",  opts: ["match", "white", "cyan", "green", "amber", "blue", "red", "navy"], desc: "'match' = the header's own ink" },
        { k: "headerGlowSize",label:"GLOW SIZE",opts: ["s", "m", "l", "xl"], desc: "neon halo radius" },
        { k: "castLen",  label: "CAST LENGTH", opts: ["xs", "s", "m", "l", "xl"], desc: "elongated-shadow length (only when HEADER SHADOW = long)" },
        { k: "castInk",  label: "CAST INK",    opts: ["faint", "soft", "med", "strong", "hard"], desc: "elongated-shadow darkness" },
        { k: "castDir",  label: "CAST DIR",    opts: ["upleft", "left", "up", "downleft", "downright", "right"], desc: "which way the shadow rakes" },
        { k: "castStep", label: "CAST SPREAD", opts: ["tight", "m", "wide"], desc: "pixel step per layer — tight = denser/shorter reach, wide = airier/longer" },
        { k: "castGap",  label: "CAST GAP",    opts: ["flush", "tight", "m", "loose", "open"], desc: "where the shadow cuts at the tab's top edge — raise until it stops bleeding onto the white trim" },
        { k: "castTone", label: "CAST TONE",   opts: ["neon", "dark", "white", "cyan", "green", "amber", "blue", "navy"], desc: "cast colour — 'neon' = the header's ink (for a DARK tab), 'dark' = a real shadow (LIGHT tab)" },
        { k: "plateTint",  label: "PLATE TINT",  opts: ["none", "light", "med"] },
        { k: "edgeSpeed",  label: "EDGE SPEED",  opts: ["slow", "normal", "fast"] },

        { h: "READOUT" },
        { k: "bigInk",   label: "TOTAL INK",  opts: inks, ink: true },
        { k: "bigSize",  label: "TOTAL SIZE", opts: sizes },
        { k: "labelInk", label: "LABEL INK",  opts: inks, ink: true },
        { k: "labelSize",label: "LABEL SIZE", opts: sizes },
        { k: "labFont",  label: "LABEL FONT", opts: fonts, specimen: true },
        { k: "labelCase",label: "LABEL CASE", opts: cases },
        { k: "labelTrack",label:"LABEL TRK",  opts: tracks },
        { k: "labelWeight",label:"LABEL WT",  opts: weights },
        { k: "statInk",  label: "STAT INK",   opts: inks, ink: true },
        { k: "statSize", label: "STAT SIZE",  opts: sizes },
        { k: "statFont", label: "STAT FONT",  opts: fonts, specimen: true },
        { k: "statTrack",label: "STAT TRK",   opts: tracks },
        { k: "statCase", label: "STAT CASE",  opts: cases },
        { k: "statWeight",label:"STAT WT",    opts: weights },

        { h: "WEEK" },
        { k: "weekOn",    label: "WEEK BLOCK", opts: ["on", "off"] },
        { k: "weekLabel", label: "WEEK TEXT",  opts: ["THIS WEEK", "7 DAYS", "RECENT", "WEEK"] },
        { k: "weekCase",  label: "WEEK CASE",  opts: cases },
        { k: "weekTrack", label: "WEEK TRK",   opts: tracks },

        { h: "RING" },
        { k: "ring",      label: "GAUGE",     opts: ["tach", "arcs", "gauge", "dashes", "off"], desc: "'tach' = the C4-style digital bar-graph speedo (this-week hours, redlines when you binge); or the concentric arcs" },
        { k: "speedoGlow",label: "SPEEDO GLOW", opts: ["off", "soft", "med", "strong"], desc: "real bloom/phosphor emission on the speedo's lit segments (GPU)" },
        { k: "spNumFont", label: "WK HRS FONT", opts: fonts, specimen: true },
        { k: "spUnitFont",label: "H/WK FONT",  opts: fonts, specimen: true },
        { k: "ringInk",   label: "RING INK",  opts: inks, ink: true },
        { k: "ringThick", label: "THICKNESS", opts: ["thin", "med", "thick"] },
        { k: "hub",       label: "HUB",       opts: ["num", "dot", "off"] },
        { k: "ringSpin",  label: "SWEEP",     opts: ["on", "off"] },
        { k: "ringTicks", label: "TICKS",     opts: ["on", "off"] },
        { k: "ringGap",   label: "ARC GAP",   opts: sizes },
        { k: "hubInk",    label: "HUB INK",   opts: inks, ink: true },
        { k: "hubSize",   label: "HUB SIZE",  opts: sizes },
        { k: "ringCaps",  label: "ARC CAPS",  opts: ["round", "flat"] },
        { k: "hubPulse",  label: "HUB PULSE", opts: ["on", "off"] },

        { h: "ROWS" },
        { k: "rowCount", label: "ROW COUNT", opts: [4, 5, 6, 7, 8, 9, 10] },
        { k: "chevron",  label: "CHEVRON",   opts: ["tab", "dot", "bar", "none"] },
        { k: "chevShow", label: "CHEV COUNT",opts: ["all", "single"], desc: "a chevron on every row, or only on the selected row (single = a pointer)" },
        { k: "chevBack", label: "CHEV BACK", opts: ["none", "chip", "frame", "hollow"] },
        { k: "rowBack",  label: "ROW STYLE",  opts: ["button", "card", "body", "sq1", "sq2", "sq3", "frame", "hollow", "chip", "dlg"], desc: "the row's plate type — 'button' uses the pressable 3-state plate (see BTN FAMILY); anything else swaps in a static panel" },
        { k: "rowPlate", label: "BTN FAMILY", opts: [1, 2, 3, 4, 5], desc: "which button art (1-5) — only applies when ROW STYLE is 'button'" },
        { k: "rowInk",   label: "ROW INK",   opts: inks, ink: true },
        { k: "rowGap",   label: "ROW GAP",   opts: [0, 1, 2, 3, 4, 5, 6, 8, 10, 13, 16, 20, 24, 30, 36] },   // fine px stepper (legacy size strings still render)
        { k: "titleInk", label: "TITLE INK", opts: inks, ink: true },
        { k: "titleSize",label: "TITLE SIZE",opts: sizes },
        { k: "titleFont",label: "TITLE FONT",opts: fonts, specimen: true },
        { k: "titleWeight",label:"TITLE WT",  opts: weights },
        { k: "titleCase", label: "TITLE CASE",opts: cases },
        { k: "titleTrack",label: "TITLE TRK", opts: tracks },
        { k: "titleBack", label: "TITLE BACK",opts: ["none", "frame", "hollow", "chip", "body"], desc: "a plate behind the row title (snug to the text)" },
        { k: "titleShadow",label:"TITLE SHADOW",opts: ["none", "drop", "emboss", "outline"], desc: "a crisp text shadow — depth without a backing plate" },
        { k: "bar",      label: "BAR STYLE", opts: ["liquid", "cells", "laser-a", "laser-b", "laser-c"] },
        { k: "barSel",   label: "BAR SEL ANIM", opts: ["wobble", "pulse", "surge", "none"], desc: "how the fill reacts when you land on the row" },
        { k: "barBack",  label: "BAR BACK",  opts: ["none", "outline", "frame", "hollow", "chip", "card", "body"] },
        { k: "barGlow",  label: "BAR GLOW",  opts: ["off", "on"] },
        { k: "pctInk",   label: "PCT INK",   opts: inks, ink: true },
        { k: "pctFont",  label: "PCT FONT",  opts: fonts, specimen: true },
        { k: "pctSize",  label: "PCT SIZE",  opts: sizes },
        { k: "pctBack",  label: "PCT BACK",  opts: ["none", "frame", "hollow", "chip", "body"] },
        { k: "pctShadow",label: "PCT SHADOW",opts: ["none", "drop", "emboss", "outline"], desc: "a crisp text shadow on the % — depth without a backing plate" },
        { k: "pctTrack", label: "PCT TRK",   opts: tracks },
        { k: "pctWeight",label: "PCT WT",    opts: weights },

        { h: "POSTER" },
        { k: "poster",        label: "FRAME",     opts: ["frame", "plain", "none"] },
        { k: "posterBg",      label: "PLATE BG",  opts: ["hero", "body", "card", "console", "dlg", "sq1", "sq2", "sq3", "wide", "chip", "frame"] },
        { k: "posterFrame",   label: "PLATE FRAME", opts: ["none", "hero", "hollow", "frame", "sq1", "sq2", "sq3", "chip"] },
        { k: "posterEdge",    label: "POSTER EDGE", opts: ["on", "off"], desc: "crisp 8-bit pixel outline around the poster / CRT area" },
        { k: "heroBezel",     label: "SCREEN BEZEL", opts: ["off", "drawn", "hollow", "hero"], desc: "9-slice frame drawn OVER the poster — its inner lip mounts the poster into the panel (transparent center, poster shows through). 'drawn' = your hero-bezel.png (live-editable)." },
        { k: "posterFit",     label: "FIT",       opts: ["fit", "fill", "stretch"], desc: "fit = show all (may gap) · fill = cover+crop · stretch = fill all edges, slight distortion" },
        { k: "heroY",         label: "HERO Y",     opts: [-96, -80, -64, -48, -36, -24, -16, -8, 0, 8, 16, 24, 36, 48, 64, 80, 96], desc: "shift the WHOLE hero (poster + plate + cables) up (−) / down (+) on ANY display — per-device, so dial it on the laptop without touching the desktop" },
        { k: "heroCrtY",      label: "HERO Y·CRT", opts: [-72, -60, -48, -36, -24, -16, -8, 0, 8, 16, 24, 36, 48, 60, 72], desc: "extra shift on the CRT only (stacks on HERO Y) — no effect on DP-3 / laptop" },
        { k: "posterTitle",   label: "NAMEPLATE", opts: ["plate", "off"] },
        { k: "posterScan",    label: "SCANLINES", opts: ["off", "fine", "medium", "coarse", "dense", "soft", "hard", "gap-2", "gap-4", "double", "dotted", "rgb-stripe", "aperture", "slot", "grille", "rolling", "interlace", "beam", "snow", "curve", "tube"] },
        { k: "heroCrt",       label: "CRT SHADER", opts: ["off", "crt-geom", "lottes", "aperture", "shadow", "slot"], desc: "RetroArch-style GLSL CRT on the hero poster (replaces the scanline)" },
        { k: "heroSweep",     label: "HERO SWEEP", opts: ["on", "off"], desc: "the pulsing accent line that sweeps down the hero poster" },
        { k: "posterAnim",    label: "POSTER ANIM", opts: ["rise", "drop", "slide", "fade", "scale", "iris", "unfold", "swing"], desc: "how the hero poster reveals in" },
        { k: "brkStyle",      label: "BRACKETS",  opts: ["l-corner", "full-frame", "ticks", "plus", "none"] },
        { k: "brkInk",        label: "BRACK INK", opts: inks, ink: true },
        { k: "brkSize",       label: "BRACK SIZE",opts: sizes },
        { k: "posterTint",    label: "TINT",      opts: ["none", "light", "med"] },
        { k: "posterShadow",  label: "SHADOW",    opts: ["on", "off"] },
        { k: "posterGlow",    label: "GLOW",      opts: ["off", "on"] },

        { h: "POSTER TEXT" },
        { k: "posterHdrInk",  label: "HEAD INK",  opts: inks, ink: true },
        { k: "posterHdrBack", label: "HEAD BACK", opts: ["none", "capsule", "b1", "b2", "b3", "b4", "b5", "chip", "frame"] },
        { k: "posterHdrSize", label: "HEAD SIZE", opts: sizes },
        { k: "posterHdrFont", label: "HEAD FONT", opts: fonts, specimen: true },
        { k: "posterHdrCase", label: "HEAD CASE", opts: cases },
        { k: "posterHdrTrack",label: "HEAD TRK",  opts: tracks },
        { k: "posterHdrWeight",label:"HEAD WT",   opts: weights },
        { k: "heroRankPos", label: "RANK POS",   opts: ["below", "top"] },
        { k: "ppillPlate",  label: "PILL PLATE", opts: ["drawn", "none", "b1", "b2", "b3", "b4", "b5", "p1", "p2", "p3"] },

        { h: "NAMEPLATE" },
        { k: "npboxPlate",  label: "BOX PLATE",  opts: ["drawn", "alt", "none", "b1", "b2", "b3", "b4", "b5", "p1", "p2", "p3"] },
        { k: "posterInk",   label: "TITLE INK",  opts: inks, ink: true },
        { k: "npTitleSize", label: "TITLE SIZE", opts: sizes },
        { k: "npTitleFont", label: "TITLE FONT", opts: fonts, specimen: true },
        { k: "npTitleCase", label: "TITLE CASE", opts: cases },
        { k: "npTitleWeight",label:"TITLE WT",   opts: weights },
        { k: "npTitleTrack",label: "TITLE TRK",  opts: tracks },
        { k: "npDeepInk",   label: "DEEP INK",   opts: inks, ink: true },
        { k: "npDeepSize",  label: "DEEP SIZE",  opts: sizes },
        { k: "npDeepFont",  label: "DEEP FONT",  opts: fonts, specimen: true },
        { k: "npDeepCase",  label: "DEEP CASE",  opts: cases },
        { k: "npDeepTrack", label: "DEEP TRK",   opts: tracks },
        { k: "npDeepWeight",label: "DEEP WT",    opts: weights },
        { k: "npEpInk",     label: "EP INK",     opts: inks, ink: true },
        { k: "npEpSize",    label: "EP SIZE",    opts: sizes },
        { k: "npEpFont",    label: "EP FONT",    opts: fonts, specimen: true },
        { k: "npEpCase",    label: "EP CASE",    opts: cases },
        { k: "npEpTrack",   label: "EP TRK",     opts: tracks },
        { k: "npEpWeight",  label: "EP WT",      opts: weights },
        { k: "npSep",       label: "SEPARATOR",  opts: ["diamond", "dot", "dash", "line", "bar", "slash", "off"], desc: "the mark between WATCHED % and the EP count ('line' = a long rule)" },

        { h: "TERRAIN" },
        { k: "graph",      label: "STYLE",    opts: ["area", "ridge", "line", "bars", "columns", "spikes", "dots", "lollipop", "steps", "stepped-area", "candles", "hilo", "band", "mirror", "stacked", "baseline-split", "threshold", "gradient-area", "dual-line", "ribbon", "glow", "spark", "heatmap", "radar"] },
        { k: "graphInk",   label: "LINE INK", opts: inks, ink: true },
        { k: "graphFill",  label: "FILL",     opts: ["none", "light", "solid"] },
        { k: "graphWell",  label: "WELL",     opts: ["recessed", "framed", "none"] },
        { k: "graphGrid",  label: "GRID",     opts: ["lines", "dashed", "dots", "off"] },
        { k: "graphAxis",  label: "Y AXIS",   opts: ["off", "hours", "pct"] },
        { k: "graphXAxis", label: "X AXIS",   opts: ["weeks", "dates", "off"] },
        { k: "graphMean",  label: "MEAN LINE",opts: ["dashed", "line", "off"] },
        { k: "graphPeakMark", label: "PEAK MARK", opts: ["pin", "chevron", "dot", "off"] },
        { k: "graphToday", label: "TODAY DOT",opts: ["dot", "pulse", "off"] },
        { k: "graphLegend",label: "LEGEND",   opts: ["swatch", "off"] },
        { k: "graphPeak",  label: "TOTAL TAG", opts: ["on", "off"] },
        { k: "graphBase",  label: "BASELINE", opts: ["line", "off"] },
        { k: "graphWeight",label: "LINE WT",  opts: sizes },
        { k: "graphDots",  label: "NODE DOTS",opts: ["off", "on"] },
        { k: "graphGlow",  label: "LINE GLOW",opts: ["off", "on"] },
        { k: "graphLabel", label: "LABELS",   opts: ["show", "dim", "off"] },

        { h: "GRAPH TEXT" },
        { k: "terrainInk",  label: "TERRAIN INK",  opts: inks, ink: true },
        { k: "terrainSize", label: "TERRAIN SIZE", opts: sizes },
        { k: "terrainFont", label: "TERRAIN FONT", opts: fonts, specimen: true },
        { k: "terrainCase", label: "TERRAIN CASE", opts: cases },
        { k: "terrainTrack",label: "TERRAIN TRK",  opts: tracks },
        { k: "terrainWeight",label:"TERRAIN WT",   opts: weights },
        { k: "peakInk",     label: "TOTAL INK",     opts: inks, ink: true },
        { k: "peakSize",    label: "TOTAL SIZE",    opts: sizes },
        { k: "peakFont",    label: "TOTAL FONT",    opts: fonts, specimen: true },
        { k: "peakCase",    label: "TOTAL CASE",    opts: cases },
        { k: "peakTrack",   label: "TOTAL TRK",     opts: tracks },

        { h: "TYPE" },
        { k: "font",      label: "READOUT FONT", opts: fonts, specimen: true },
        { k: "labelFont", label: "LABEL FONT",   opts: fonts, specimen: true },

        { h: "HUD" },
        { k: "accent",   label: "ACCENT",    opts: ["cyan-hi", "cyan", "green", "teal", "mint", "amber", "amber-hi", "orange", "blue", "blue-hi", "violet", "purple", "pink", "red", "red-hi", "yellow", "steel", "white"], ink: true },
        { k: "bgGlow",   label: "BG GLOW",   opts: ["on", "off", "strong"] },
        { k: "bgStyle",  label: "BG STYLE",  opts: ["well", "flat", "grid", "vignette"] },
        { k: "crumbInk", label: "CRUMB INK", opts: inks, ink: true },
        { k: "crumbSize",label: "CRUMB SIZE",opts: sizes },
        { k: "crumbTrack",label:"CRUMB TRK", opts: tracks },
        { k: "crumbStyle",label:"CRUMB PIP", opts: ["diamond", "dot", "bar", "none"] },
        { k: "crumbWeight",label:"CRUMB WT", opts: weights },
        { k: "crumbCase", label: "CRUMB CASE",opts: cases },
        { k: "zoom",     label: "ZOOM LENS", opts: ["off", "1.5x", "2x", "3x", "4x"] },
        { k: "overlay",  label: "OVERLAY",   opts: ["none", "vignette", "edge-glow", "grain", "dust", "scanlines", "scan-sweep", "dot-matrix", "grid", "crosshair", "target-lock", "corner-brackets", "hud-frame", "letterbox", "tint-wash", "color-grade", "rings", "interference", "pulse", "top-fade"] },

        { h: "ANIMATION" },
        { k: "entrance", label: "ENTRANCE",  opts: ["cascade", "fade", "instant"] },
        { k: "tempo",    label: "TEMPO",     opts: ["slow", "normal", "fast"] },
        { k: "ambient",  label: "AMBIENT",   opts: ["on", "subtle", "off"] },
        { k: "ambientSpeed",label:"AMB SPEED",opts: ["slow", "normal", "fast"] },
        { k: "barsGrow", label: "BARS GROW", opts: ["on", "off"] },

        { h: "FOOTER" },
        { k: "hints",    label: "KEY HINTS", opts: ["show", "dim", "off"] },
        { k: "hintSize", label: "HINT SIZE", opts: sizes },
        { k: "hintInk",  label: "HINT INK",  opts: inks, ink: true },
        { k: "hintFont", label: "HINT FONT", opts: fonts, specimen: true },
        { k: "hintBack", label: "HINT BACK", opts: ["none", "chip", "frame", "hollow", "body"] },
        { k: "hintCaps", label: "KEYCAP BOX", opts: [true, false] },
        { k: "hintCase", label: "HINT CASE", opts: cases },
        { k: "hintTrack",label: "HINT TRK",  opts: tracks },
        { k: "hintWeight",label:"HINT WT",   opts: weights }
    ]

    // MOVE-page element list (11, like home) — each nudgeable via mech.offsets
    // FREE HINGE overlay elements (the seam patch kit) — data-driven: ONE spec list drives the
    // instances (Repeater below), the MOVE-list entries, and elemFor(). Positions are poster-
    // relative (title-independent → identical for every title). Colours/sizes are the author's dial-ins.
    readonly property var hingeSpecs: {
        var a = []
        function push(prefix, xs, kind, w, h, z, opt) {
            for (var i = 0; i < xs.length; i++) {
                var s = { k: prefix + (i + 1), kind: kind, dx: xs[i], w: w, h: h, z: z, label: opt.label + " " + (i + 1) }
                if (kind === "img") s.art = (i < opt.split) ? opt.art : opt.art2
                else s.color = opt.color
                a.push(s)
            }
        }
        push("hcap",  [5,8,67,70,6,9,68,71],            "img",  6, 18, 30, { label: "HINGE CAP",   art: "hero-hinge-cap", art2: "hero-hinge-cap-b", split: 4 })
        push("hpix",  [7,10,69,72,6,73,8,11,68,71],      "rect", 1, 1,  31, { label: "HINGE PIXEL", color: "#b1bdd4" })
        push("hend",  [7,8,10,11,68,69,71,72,6,9,70,73], "rect", 1, 1,  31, { label: "HINGE END",   color: "#a0a8b8" })
        push("hbar",  [7,10,69,72],                      "rect", 1, 3,  31, { label: "HINGE BAR",   color: "#a0a8b8" })
        push("hstub", [7,10,69,72],                      "rect", 1, 2,  31, { label: "HINGE STUB",  color: "#a0a8b8" })
        push("hclip", [7,10,69,72],                      "rect", 1, 1,  31, { label: "HINGE CLIP",  color: "#191d25" })
        return a
    }
    readonly property var hingeMoveElems: hingeSpecs.map(function (s) { return { k: s.k, label: s.label, size: true } })
    readonly property var moveElems: [
        { k: "hero",   label: "HERO PLATE" },
        { k: "big",    label: "TOTAL WATCH", size: true },
        { k: "label",  label: "WATCH LABEL", size: true },
        { k: "stats",  label: "PLAY COUNTS", size: true },
        { k: "week",   label: "THIS WEEK" },
        { k: "ring",   label: "SPEEDO", size: true },
        { k: "spnum",  label: "WK HOURS" },
        { k: "header", label: "DEEP HEADER", size: true },
        { k: "headerCrt", label: "HEADER (CRT)", size: true },   // CRT-only move + scale for the header tab (no effect on DP-3)
        { k: "rows",   label: "DEEPEST ROWS" },   // move-only: per-row size = ROW BOX/TITLE/BAR/%
        { k: "rtitle", label: "ROW TITLE", size: true },
        { k: "rbar",   label: "ROW BAR", size: true },
        { k: "rowbox", label: "ROW BOX", size: true },
        { k: "rpct",   label: "ROW %", size: true },
        { k: "rchev",  label: "ROW CARET", size: true },
        { k: "spatch", label: "ROW PATCH", size: true },
        { k: "poster", label: "POSTER" },
        { k: "pframe", label: "POSTER FRAME", size: true },
        { k: "phole",  label: "POSTER ART", size: true },
        { k: "pedge",  label: "POSTER OUTLINE", size: true },
        { k: "pbez",   label: "SCREEN BEZEL", size: true },
        ].concat(stats.hingeMoveElems).concat([
        { k: "pname",  label: "NAMEPLATE" },
        { k: "ppill",  label: "HEADER PILL", size: true },
        { k: "npbox",  label: "NAMEPLATE BOX", size: true },
        { k: "graph",  label: "TERRAIN" },
        { k: "peak",   label: "TOTAL TAG", size: true },
        { k: "crumb",  label: "CRUMB", size: true },
        { k: "phdr",   label: "POSTER HEAD", size: true },
        { k: "ptit",   label: "NAME TITLE", size: true },
        { k: "pyear",  label: "YEAR", size: true },
        { k: "pdeep",  label: "% DEEP", size: true },
        { k: "peps",   label: "EPISODES", size: true },
        { k: "psep",   label: "SEPARATOR", size: true },
        { k: "tlab",   label: "TERRAIN LBL", size: true },
        { k: "gaxis",  label: "Y AXIS", size: true },
        { k: "gxaxis", label: "X AXIS", size: true },
        { k: "pmark",  label: "PEAK MARK", size: true },
        { k: "gmean",  label: "MEAN LINE", size: true },
        { k: "readout", label: "READOUT BOX" },
        { k: "topwell", label: "STATS WELL", size: true },
        { k: "weekwell",label: "WEEK WELL",  size: true },
        { k: "edge",   label: "EDGE GLINT" },
        { k: "foot",   label: "FOOTER", size: true },
        // small readouts promoted to first-class lock targets (combat-lock grammar
        // on every visible element the eye lands on)
        { k: "sub",    label: "SUBTITLE" },
        { k: "wlab",   label: "WEEK LABEL", size: true },
        { k: "wep",    label: "WEEK EP", size: true },
        { k: "wtt",    label: "WEEK TITLES", size: true },
        { k: "pfall",  label: "POSTER TITLE" }
    ])

    // mutators + persistence the editor calls on `view`
    function mechSet(k, v) {
        var m = {}; for (var p in stats.mech) m[p] = stats.mech[p]; m[k] = v; stats.mech = m
        if (k === "entrance" || k === "heroReveal" || k === "tempo" || k === "barsGrow") replayCard()
    }
    function saveMech() { App.putSetting("statsUiSel", JSON.stringify(stats.mech)); stats.mechSavedJson = JSON.stringify(stats.mech); stats.iconFlash = "✓ SAVED"; flashKick.restart() }
    function loadMech() {
        var raw = App.getSetting("statsUiSel", "")
        if (raw) { try {
            // merge OVER the defaults: forward-fill dials added since the save,
            // but PRESERVE every saved key (scales/offsets aren't in mechDefaults,
            // so a per-defaults-key loop dropped them → "save wipes my progress").
            var saved = JSON.parse(raw); var m = {}
            for (var d in stats.mechDefaults) m[d] = stats.mechDefaults[d]
            for (var p in saved) m[p] = saved[p]
            if (m.deepLabel === "TOP WATCH") m.deepLabel = "TOP WATCHED"   // renamed option
            if (m.deepLabel === "TOP WATCHED") m.deepLabel = "TOP 10 WATCHED"   // renamed → count-explicit
            // ROW GAP went from a coarse size string to a fine px number — normalise old
            // saves so the dial highlights + steps from the right value (not a jump to 0).
            if (typeof m.rowGap === "string") m.rowGap = ({ xxs: 0, xs: 4, s: 7, m: 10, l: 16, xl: 24, xxl: 36 })[m.rowGap]
            if (typeof m.rowGap !== "number") m.rowGap = 10
            stats.mech = m
        } catch (e) { CLog.d("stats", "loadMech parse fail") } }
        stats.mechSavedJson = JSON.stringify(stats.mech)
    }
    Component.onCompleted: {
        loadMech()
        // (see enter() below) the first visit after launch is CREATED visible
        if (visible) Qt.callLater(enter)
    }
    // Backing out of the garage without saving discards the unsaved edits —
    // the CRITICAL red clears because the tune is rolled back to the last save.
    function revertMech() { if (JSON.stringify(stats.mech) !== stats.mechSavedJson) { try { stats.mech = JSON.parse(stats.mechSavedJson) } catch (e) {} } }
    onMechEditChanged: if (!mechEdit) { revertMech(); if (garageFocus) garageFocus.lensGridN = 0 }   // in-lens grid starts OFF each fresh open (sticky only within a session)
    Timer { id: flashKick; interval: 1400; onTriggered: stats.iconFlash = "" }
    // MOVE-page contract (present but unused in v1 — pageOrder is ["dials"])
    // RAW stored reference-px offset — what the mutators (nudge/drag/commit) read.
    // During an active grab-drag the dragged element reads its live offset; everyone
    // else — and everything when idle — reads mech.
    function mOffRaw(k) {
        if (garageFocus && garageFocus.dragging && garageFocus.dragKey === k) return garageFocus.dragOff
        return (stats.mech.offsets && stats.mech.offsets[k]) ? stats.mech.offsets[k] : [0, 0]
    }
    // SCALED offset for DISPLAY — every Translate reads this, so positions scale with
    // the window instead of being locked to the resolution they were dialed at.
    function mOff(k) { var o = mOffRaw(k); return [o[0] * offScale, o[1] * offScale] }
    // POSTER/HERO offsets must track the DISCRETE poster pixel (hpx = floor(heroK)) that the
    // hero ART scales by — NOT the continuous offScale. Otherwise a hand-placed patch drifts off
    // its seam at any resolution but the authoring one (2560×1440 fullscreen: hpx=8, offScale=0.97/
    // 0.84). mOffHpx scales the SAME stored offset by hpx, PEGGED so fullscreen is identical
    // (hpx/hpxRefFS = 1 there) and tiled/CRT follow the art grid. Pass the element's live poster.hpx.
    // MEASURED on-device at the authoring res (2560×1440 fullscreen): hpx=8, offScale=1.100.
    // (Computed guesses were wrong — the stats window is ~67px shorter than the panel, so cH=1331.)
    // offset-in-art-px = mOffRaw × (offScaleRefFS/hpxRefFS) is then CONSTANT at every resolution,
    // so a patch holds its art-pixel position everywhere; at hpx=8 it equals the old mOff exactly.
    readonly property real hpxRefFS: 8
    readonly property real offScaleRefFS: 1.100
    function mOffHpx(k, hpx) { var o = mOffRaw(k); var f = offScaleRefFS * hpx / hpxRefFS; return [o[0] * f, o[1] * f] }
    // commit a finished drag into mech ONCE (mirrors mechNudge's [0,0] prune)
    function mechCommitDrag(k, off) {
        var o = {}; for (var p in (stats.mech.offsets || {})) o[p] = stats.mech.offsets[p]
        if (off[0] === 0 && off[1] === 0) delete o[k]; else o[k] = [off[0], off[1]]
        mechSet("offsets", o)
    }
    function mechNudge(k, dx, dy) { var o = mOffRaw(k); var off = {}; for (var p in (stats.mech.offsets || {})) off[p] = stats.mech.offsets[p]; var nx = o[0] + dx, ny = o[1] + dy; if (nx === 0 && ny === 0) delete off[k]; else off[k] = [nx, ny]; mechSet("offsets", off) }   // prune [0,0] so nudge→back clears dirty (dx/dy are reference px)
    function mechNudgeReset(k) { var off = {}; for (var p in (stats.mech.offsets || {})) if (p !== k) off[p] = stats.mech.offsets[p]; mechSet("offsets", off) }
    // Per-element SCALE (ASSEMBLY tool 2nd axis) — mirror of the offset system; prune to 1 clears dirty.
    function mScale(k) { if (stats.classic) return 1; var v = stats.mech.scales ? stats.mech.scales[k] : undefined; return (v === undefined || v === null) ? 1 : v }
    // DEV HOT-RELOAD for raw Image sources (MechSlice/Panel/Button already do this). `rel` is the
    // subfolder-relative id (e.g. "edge-slide" or "hero/hero-bezel"); returns the live dev-tree
    // file:// (with ?v cache-bust) when a dev build has it, else the baked qrc. Call sites MUST
    // reference App.heroDevRev in the binding — `(App.heroDevRev, stats.devSrc("x"))` — to stay reactive.
    function devSrc(rel) { var d = (typeof App !== "undefined" && App) ? App.heroDevPath(rel) : ""; return d !== "" ? d + "?v=" + App.heroDevRev : "qrc:/assets/mechui/" + rel + ".png" }
    function mechScaleBy(k, delta) { var sc = {}; for (var p in (stats.mech.scales || {})) sc[p] = stats.mech.scales[p]; var cur = (sc[k] === undefined || sc[k] === null) ? 1 : sc[k]; var nv = Math.round((cur + delta) * 100) / 100; nv = Math.max(0.5, Math.min(2.5, nv)); if (Math.abs(nv - 1) < 0.001) delete sc[k]; else sc[k] = nv; mechSet("scales", sc) }
    function mechScaleReset(k) { var sc = {}; for (var p in (stats.mech.scales || {})) if (p !== k) sc[p] = stats.mech.scales[p]; mechSet("scales", sc) }
    function cycleSel(which, sec, d) {}     // no icon picker on STATS
    function replayCard() { entrance = 0; entranceAnim.restart() }   // cycling an anim dial replays the slide-out
    function syncZoneToGroup(g) {}          // Home-only zone sync — no-op on STATS
    readonly property int topBleed: Math.round(8 * stats.s)   // safe-area offset for the mode banner

    // resolvers the editor reads (contract names: mechFontFor / mechInk)
    function mechFontFor(f) {
        return f === "mgscodec" ? mgsCodec.name : f === "mecha" ? mechaFont.name
             : f === "mecha-cond" ? mechaCond.name : f === "mono" ? Theme.monoFont : mgsHud.name
    }
    // the 24-colour hardware ink palette (grounded in mechInks + accents + the
    // 9 hangar colorways) — every ink dial draws from this; "auto" → accent
    readonly property var inkMap: ({
        navy: "#222034", steel: "#566c78", slate: "#8fa6b3", trim: "#aecbd9",
        light: "#dce8ef", white: "#f2f7fa", green: "#8fe3a1", teal: "#57c9b0",
        mint: "#b7f2c8", cyan: "#5fcde4", "cyan-hi": "#4fd6ea", blue: "#4a6ab1",
        "blue-hi": "#5b8bf5", violet: "#9a6ede", purple: "#7a4fd0", pink: "#e58fb4",
        red: "#c04a42", "red-hi": "#ff6a6a", warning: "#c86450", orange: "#f09a4e",
        amber: "#f0a54e", "amber-hi": "#ffb347", yellow: "#e6d24a", grey: "#8e8e8e"
    })
    function mechInk(a) { return a === "auto" ? stats.accent : (stats.inkMap[a] || Theme.withAlpha(Theme.fg, 0.85)) }
    // an ink dial value → colour; "auto" tracks the accent
    function ink(k) { return k === "auto" ? stats.accent : mechInk(k) }
    // show title with the release year in brackets when known (fits the card best)
    function showTitle(sh) { if (!sh || !sh.show) return "—"; return sh.show + (sh.year && sh.year > 0 ? " (" + sh.year + ")" : "") }
    // just the "(year)" suffix — rendered in a distinct font on the nameplate.
    // Skipped when the name already shows that year (e.g. "1883", "X-Men '97").
    function titleYear(sh) {
        if (!sh || !sh.year || sh.year <= 0) return ""
        var ys = "" + sh.year
        if (sh.show && (sh.show.indexOf(ys) >= 0 || sh.show.indexOf("'" + ys.slice(-2)) >= 0)) return ""
        return ys   // bare number; the nameplate wraps it in balanced brackets
    }
    // size dial → a scaled pixel size (× the responsive s)
    readonly property var sizeFac: ({ xxs: 0.7, xs: 0.82, s: 0.92, m: 1.0, l: 1.14, xl: 1.3, xxl: 1.5 })
    function mSz(base, key) { var f = sizeFac[key]; return Math.round(base * (f === undefined ? 1 : f) * stats.s) }
    // font.pixelSize is an int; a Math.round(...) expression is statically typed `double`, so
    // assigning it warns "Unable to assign double to int" (cosmetic, but noisy). Routing through
    // this function call defers typing to runtime → the (integer) value coerces silently.
    function pxi(v: real): int { return Math.round(v) }

    readonly property color accent: stats.inkMap[mech.accent] || "#4fd6ea"
    readonly property color acEdge: Theme.withAlpha(accent, 0.4)
    readonly property string dataFont: mechFontFor(mech.font)
    readonly property string labelFontName: mechFontFor(mech.labelFont)

    // ── staged entrance — one scalar 0→1, sliced per element ──────────────────
    //    entrance dial: cascade (staggered) · fade (all together) · instant.
    //    tempo dial scales the duration; heroReveal picks slide-clip vs fade.
    property real entrance: 1
    readonly property real mechAnimK: mech.tempo === "slow" ? 1.6 : mech.tempo === "fast" ? 0.6 : 1
    readonly property bool eInstant: mech.entrance === "instant"
    readonly property bool eFade: mech.entrance === "fade"
    function outc(t) { var x = Math.max(0, Math.min(1, t)); return 1 - Math.pow(1 - x, 3) }
    function phase(a, b) { return eInstant ? 1 : eFade ? outc(entrance) : outc((entrance - a) / (b - a)) }
    readonly property real eBox:    eInstant ? 1 : eFade ? outc(entrance) : Math.max(0, Math.min(1, entrance / 0.26))
    readonly property real eReveal: (mech.heroReveal === "slide" || mech.heroReveal === "sprite") ? phase(0.20, 0.66) : 1
    readonly property real eBars:   mech.barsGrow === "off" ? 1 : phase(0.24, 0.66)
    readonly property real ePoster: phase(0.60, 0.84)
    readonly property real eGraph:  phase(0.72, 1.0)
    NumberAnimation { id: entranceAnim; target: stats; property: "entrance"; from: 0; to: 1; duration: eInstant ? 0 : Math.round(1150 * mechAnimK) }

    // ── ambient idle motion (gated by the `ambient` dial) ────────────────────
    readonly property bool ambientOn: stats.mech.ambient !== "off"
    readonly property real ambientK: stats.mech.ambient === "subtle" ? 0.55 : 1
    readonly property real ambSpeedK: stats.mech.ambientSpeed === "slow" ? 1.7 : stats.mech.ambientSpeed === "fast" ? 0.55 : 1
    property real ambBreathe: 0
    property real ambSweep: 0
    property real ambScan: 0
    SequentialAnimation on ambBreathe {
        loops: Animation.Infinite; running: stats.visible && stats.ambientOn
        NumberAnimation { to: 1; duration: Math.round(1900 * stats.ambSpeedK); easing.type: Easing.InOutSine }
        NumberAnimation { to: 0; duration: Math.round(1900 * stats.ambSpeedK); easing.type: Easing.InOutSine }
    }
    NumberAnimation on ambSweep { from: 0; to: 360; duration: Math.round(9000 * stats.ambSpeedK); loops: Animation.Infinite; running: stats.visible && (stats.ambientOn || stats.mech.ringSpin === "on") }
    NumberAnimation on ambScan  { from: 0; to: 1;   duration: Math.round(3200 * stats.ambSpeedK); loops: Animation.Infinite; running: stats.visible && stats.ambientOn }
    // rolling-retrace phase (0..1) + interlace field toggle for the CRT styles
    property real scanRoll: 0
    NumberAnimation on scanRoll { from: 0; to: 1; duration: 2200; loops: Animation.Infinite; running: stats.visible }
    property int scanPhase: 0
    Timer { interval: 90; repeat: true; running: stats.visible; onTriggered: stats.scanPhase = (stats.scanPhase + 1) % 2 }
    // scanline STYLE → QML overlay params (renders headless + on-device):
    //   ori h/v/dot · pitch/thick in device px · depth opacity · rgb triads ·
    //   anim none/roll/interlace/snow · vig corner darkening
    function scanCfg(v) {
        switch (v) {
        case "fine":       return { ori: "h",   pitch: 3, thick: 1, depth: 0.16, anim: "none",      rgb: false, vig: false }
        case "medium":     return { ori: "h",   pitch: 4, thick: 1, depth: 0.22, anim: "none",      rgb: false, vig: false }
        case "coarse":     return { ori: "h",   pitch: 6, thick: 2, depth: 0.30, anim: "none",      rgb: false, vig: false }
        case "dense":      return { ori: "h",   pitch: 2, thick: 1, depth: 0.13, anim: "none",      rgb: false, vig: false }
        case "soft":       return { ori: "h",   pitch: 4, thick: 2, depth: 0.14, anim: "none",      rgb: false, vig: false }
        case "hard":       return { ori: "h",   pitch: 4, thick: 2, depth: 0.42, anim: "none",      rgb: false, vig: false }
        case "gap-2":      return { ori: "h",   pitch: 3, thick: 1, depth: 0.50, anim: "none",      rgb: false, vig: false }
        case "gap-4":      return { ori: "h",   pitch: 6, thick: 2, depth: 0.55, anim: "none",      rgb: false, vig: false }
        case "double":     return { ori: "h",   pitch: 5, thick: 2, depth: 0.34, anim: "none",      rgb: false, vig: false }
        case "dotted":     return { ori: "dot", pitch: 4, thick: 1, depth: 0.34, anim: "none",      rgb: false, vig: false }
        case "rgb-stripe": return { ori: "v",   pitch: 3, thick: 1, depth: 0.30, anim: "none",      rgb: true,  vig: false }
        case "aperture":   return { ori: "v",   pitch: 3, thick: 1, depth: 0.30, anim: "none",      rgb: false, vig: false }
        case "slot":       return { ori: "dot", pitch: 5, thick: 2, depth: 0.30, anim: "none",      rgb: false, vig: false }
        case "grille":     return { ori: "v",   pitch: 2, thick: 1, depth: 0.42, anim: "none",      rgb: false, vig: false }
        case "rolling":    return { ori: "h",   pitch: 3, thick: 1, depth: 0.18, anim: "roll",      rgb: false, vig: false }
        case "interlace":  return { ori: "h",   pitch: 2, thick: 1, depth: 0.42, anim: "interlace", rgb: false, vig: false }
        case "beam":       return { ori: "h",   pitch: 4, thick: 1, depth: 0.16, anim: "roll",      rgb: false, vig: false }
        case "snow":       return { ori: "h",   pitch: 3, thick: 1, depth: 0.16, anim: "snow",      rgb: false, vig: false }
        case "curve":      return { ori: "h",   pitch: 3, thick: 1, depth: 0.20, anim: "none",      rgb: false, vig: true }
        case "tube":       return { ori: "h",   pitch: 3, thick: 1, depth: 0.22, anim: "roll",      rgb: false, vig: true }
        }
        return { ori: "h", pitch: 3, thick: 1, depth: 0.2, anim: "none", rgb: false, vig: false }
    }

    function reload() {
        days = Store.watchDays(30)
        summary = Store.statsSummary()
        weekAct = MediaLibrary.weekActivity()
        shows = MediaLibrary.topShows(10)
        CLog.d("stats", "reload days=" + days.length + " shows=" + shows.length)
    }
    // Entering STATS: fresh numbers, the keyboard, the entrance. Since the view
    // became an on-demand Loader (perf pass) it is CREATED already visible on the
    // first visit after launch, so onVisibleChanged never fired there: no reload
    // (every counter read 0, "no watch history") and no focus (nav dead) — until
    // you left and came back. Run it on creation too.
    function enter() { forceActiveFocus(); reload(); entrance = 0; entranceAnim.restart() }
    onVisibleChanged: if (visible) enter()   // + on creation: Component.onCompleted above
    Connections {
        target: MediaLibrary
        function onScanned() { if (stats.visible) stats.reload() }
    }
    function fmtH(h) { return h >= 10 ? Math.round(h) + "" : (Math.round(h * 10) / 10) + "" }

    // ── UI sounds (Sfx) ────────────────────────────────────────────────────
    // The rankings' walk: j/k (the remote's ▲▼) and the pointer moving the
    // selection play `move`, a step past either end `bump`, esc/h home `back`.
    // Only while STATS has the floor; the GARAGE editor's keys stay silent, and
    // so do rows sliding under a parked pointer as the cockpit enters.
    readonly property bool sfxLive: visible && !mechEdit && !App.queueOpen && !App.searchOpen && !App.outputOpen
    function sfx(cue) { if (sfxLive) Sfx.play(cue) }
    function sfxWalk(was) { sfx(rows.n > 0 && rows.selRow !== was ? "move" : "bump") }
    function sfxPoint(i) { if (App.pointerActive && !entranceAnim.running && i !== rows.selRow) sfx("move") }

    Keys.onReleased: (event) => {
        if (!garageFocus) return
        if (event.key === Qt.Key_Shift) garageFocus.shiftHeld = false
        else if (event.key === Qt.Key_Control) garageFocus.ctrlHeld = false
    }
    Keys.onPressed: (event) => {
        // live modifier tracking (holding Ctrl/Shift engages immediately)
        if (garageFocus && event.key === Qt.Key_Shift) garageFocus.shiftHeld = true
        else if (garageFocus && event.key === Qt.Key_Control) garageFocus.ctrlHeld = true
        if (stats.mechEdit && mechEditor) {                    // route to the ported MechEditor (home idiom)
            var sh = (event.modifiers & Qt.ShiftModifier) !== 0
            // ASSET VIEWER's extra keys (s/o/f/[ ]) route first; unhandled keys
            // (hjkl/Enter/-/=/`) fall through to normal editor handling below.
            if (mechEditor.page === "assets" && mechEditor.assetKey(event.key, sh)) { event.accepted = true; return }
            switch (event.key) {
            case Qt.Key_QuoteLeft: case Qt.Key_Escape: stats.mechEdit = false; break
            case Qt.Key_J: case Qt.Key_Down:  mechEditor.nav("down", sh); break
            case Qt.Key_K: case Qt.Key_Up:    mechEditor.nav("up", sh); break
            case Qt.Key_L: case Qt.Key_Right: mechEditor.nav("right", sh); break
            case Qt.Key_H: case Qt.Key_Left:  mechEditor.nav("left", sh); break
            case Qt.Key_Minus: mechEditor.pageStep(-1); break
            case Qt.Key_Equal: mechEditor.pageStep(1); break
            case Qt.Key_B: mechEditor.togglePage(); break
            case Qt.Key_Z: if (sh) mechEditor.redo(); else mechEditor.undo(); break
            case Qt.Key_Y: mechEditor.redo(); break
            case Qt.Key_X: if (sh) mechEditor.randomizeGroup(); else mechEditor.randomize(); break
            case Qt.Key_C: mechEditor.abCompare(); break
            case Qt.Key_F:   // LIGHT-AIM: cursor becomes the light source for the elongated header shadow
                if (stats.mech.headerShadow === "long") {
                    if (stats.lightAim) { stats.mechSet("castVec", stats.lightVec); stats.mechSet("castBright", stats.lightBright); stats.lightAim = false }
                    else { stats.garageMode = "scan"; stats.lightAim = true
                           stats.lightBright = (stats.mech.castBright !== null && stats.mech.castBright !== undefined) ? stats.mech.castBright : (stats.castInkO[stats.mech.castInk] || 0.18) }
                }
                break
            case Qt.Key_O: mechEditor.cycleOpacity(); break
            case Qt.Key_P: mechEditor.leftSide = !mechEditor.leftSide; break
            case Qt.Key_Space: mechEditor.hidden = !mechEditor.hidden; break
            case Qt.Key_Tab: stats.cycleGarageMode(); break
            case Qt.Key_I: stats.garageMode = "combat"; break
            case Qt.Key_V: stats.garageMode = "scan"; break
            case Qt.Key_N: stats.garageMode = "normal"; break
            case Qt.Key_G:  // NORMAL: toggle grid · SCAN: cycle lockbox grid · ZOOM: step magnification
                if (stats.garageMode === "scan") {
                    if (garageFocus.zooming) {   // the lockbox grid is hidden while zooming, so g steps the zoom level
                        var zl = ["1.5x", "2x", "3x", "4x"]
                        var zi = zl.indexOf(stats.mech.zoom); if (zi < 0) zi = 1
                        stats.mechSet("zoom", zl[(zi + 1) % zl.length])
                    } else stats.scanGridN = stats.scanGridN % 3 + 1
                } else stats.mechGrid = !stats.mechGrid
                break
            case Qt.Key_BracketLeft: mechEditor.nav("ydec", sh); break
            case Qt.Key_BracketRight: mechEditor.nav("yinc", sh); break
            case Qt.Key_Comma: mechEditor.scaleStep(-1, sh); break    // ASSEMBLY: shrink (⇧ coarse)
            case Qt.Key_Period: mechEditor.scaleStep(1, sh); break    // ASSEMBLY: grow (⇧ coarse)
            case Qt.Key_Return: case Qt.Key_Enter: mechEditor.activate(); break
            case Qt.Key_R: if (!mechEditor.resetCurrent()) { mechEditor.pushHist(); stats.mech = stats.mechDefaults } break  // pushHist so Z undoes the reset, same as HOME
            case Qt.Key_Backslash: stats.saveMech(); break
            case Qt.Key_1: mechEditor.loadPreset(1); break
            case Qt.Key_2: mechEditor.loadPreset(2); break
            case Qt.Key_3: mechEditor.loadPreset(3); break
            case Qt.Key_Exclam: mechEditor.savePreset(1); break
            case Qt.Key_At: mechEditor.savePreset(2); break
            case Qt.Key_NumberSign: mechEditor.savePreset(3); break
            default: break   // swallow all keys while the editor is open, as HOME does
            }
            event.accepted = true; return
        }
        const wasRow = rows.selRow
        switch (event.key) {
        case Qt.Key_QuoteLeft: if (!App.editorEnabled) return; stats.mechEdit = true; break   // SETTINGS ▸ EDITOR off = ` is inert
        case Qt.Key_J: case Qt.Key_Down: rows.selRow = Math.min(rows.n - 1, (rows.selRow < 0 ? 0 : rows.selRow) + 1); sfxWalk(wasRow); break   // walk the DEEPEST rows
        case Qt.Key_K: case Qt.Key_Up:   rows.selRow = Math.max(0, (rows.selRow < 0 ? 0 : rows.selRow) - 1); sfxWalk(wasRow); break
        case Qt.Key_Escape: case Qt.Key_H: sfx("back"); App.goHome(); break
        case Qt.Key_Q: App.queueOpen = !App.queueOpen; break
        case Qt.Key_P: App.toPlayer(); break
        case Qt.Key_X: App.stopPlayback(); break
        default: return
        }
        event.accepted = true
    }

    // ── background (BG GLOW intensity · BG STYLE shape) ───────────────────────
    Item {
        anchors.fill: parent
        readonly property real bgA: stats.mech.bgGlow === "off" ? 0 : stats.mech.bgGlow === "strong" ? 0.11 : 0.045
        Rectangle {   // well: top→centre glow
            anchors.fill: parent; visible: stats.mech.bgStyle === "well" && stats.mech.bgGlow !== "off"
            gradient: Gradient {
                GradientStop { position: 0.0; color: Theme.withAlpha(stats.accent, parent.bgA) }
                GradientStop { position: 0.4; color: "transparent" }
                GradientStop { position: 1.0; color: "transparent" }
            }
        }
        Rectangle {   // flat: uniform faint accent
            anchors.fill: parent; visible: stats.mech.bgStyle === "flat" && stats.mech.bgGlow !== "off"
            color: Theme.withAlpha(stats.accent, parent.bgA * 0.7)
        }
        Item {   // grid: faint lattice
            anchors.fill: parent; visible: stats.mech.bgStyle === "grid" && stats.mech.bgGlow !== "off"
            Repeater { model: Math.ceil(parent.width / Math.round(48 * stats.s)) + 1
                Rectangle { required property int index; x: index * Math.round(48 * stats.s); width: 1; height: parent.height; color: Theme.withAlpha(stats.accent, 0.05) } }
            Repeater { model: Math.ceil(parent.height / Math.round(48 * stats.s)) + 1
                Rectangle { required property int index; y: index * Math.round(48 * stats.s); height: 1; width: parent.width; color: Theme.withAlpha(stats.accent, 0.05) } }
        }
        Rectangle {   // vignette: corner darken
            anchors.fill: parent; visible: stats.mech.bgStyle === "vignette"
            gradient: Gradient {
                GradientStop { position: 0.0; color: Theme.withAlpha("#000000", 0.4) }
                GradientStop { position: 0.3; color: "transparent" }
                GradientStop { position: 0.7; color: "transparent" }
                GradientStop { position: 1.0; color: Theme.withAlpha("#000000", 0.4) }
            }
        }
    }

    // ── centred cockpit ─────────────────────────────────────────────────────
    Item {
        id: cockpit
        width: stats.cW
        height: stats.cH
        readonly property real gap: Math.round(22 * stats.s)
        readonly property real graphH: Math.round(height * 0.26)
        // snap the hero plate's size to the mpx grid: the cockpit MechPanel is a
        // 9-patch integer-scaled by mpx, and a non-multiple width/height leaves a
        // duplicated trim pixel where the top edge turns into the right edge
        // (the stray white corner). Flooring to a multiple keeps the seam clean.
        readonly property real heroH: Math.floor((height - gap - graphH) / stats.mpx) * stats.mpx
        // poster capped so it never eats the CRT (tall aspect): min of a
        // height fraction and a width fraction
        // hero poster is an INTEGER-scaled 80×160 tile. Pick the scale from the height
        // (and a generous width budget), then make the column HUG that tile (+ one gap of
        // frame) so there's no big letterbox around it. heroFitK derives the same scale.
        // hero poster fills its column CONTINUOUSLY (non-integer) so it's as large as the
        // height allows, bounded by a width budget so it never overruns the screen edge or
        // blows up when tiled. Rendered NATIVELY (not transform-scaled) → the CRT shader
        // stays clean. Slight softness on the pixel-art frame is the trade for the size.
        // Hero spans from the CARD's top line (cockpit top + 28s, matching the readout box)
        // down to the graph line, so its top aligns with the slide-out card's top. Sized to
        // that span (width-bounded). Row titles auto-fit so a wider CRT hero doesn't truncate.
        readonly property real cardTop: Math.round(4 * stats.s)   // hero top → the card PANEL's top border line (not the text, which is ~28s down)
        readonly property real heroK: Math.max(2, Math.min((height - cardTop) / 160, width * 0.42 / 80))
        // reserve the poster column at the FLOORED tile width (what actually renders), not the
        // continuous heroK — else the tile centres in a column up to ~80·frac(heroK) wider than
        // itself, so it swings position between resolutions. Floored → margin is a constant gap/2.
        readonly property real posterW: Math.round(80 * Math.max(2, Math.floor(heroK + 0.12))) + gap   // match heroScale's biased floor
        readonly property real heroW: Math.floor((width - posterW - gap) / stats.mpx) * stats.mpx
        anchors.horizontalCenter: parent.horizontalCenter
        // CENTRE the cockpit (a small top bias) — centred always fits since cH < screen,
        // so the taller card can't push the graph off the bottom. (Was pinned to a 28px
        // top margin that overflowed once the panel grew.)
        y: Math.max(Math.round(8 * stats.s), (stats.height - height) / 2 - Math.round(4 * stats.s))

        // ── top-bar label ───────────────────────────────────────────────────
        Row {
            id: crumb
            visible: false   // hidden — redundant with the top-bar "CODEC | STATS"
            readonly property color ci: stats.ink(stats.mech.crumbInk)
            anchors.left: parent.left; anchors.bottom: parent.top; anchors.bottomMargin: Math.round(14 * stats.s)
            spacing: Math.round(11 * stats.s)
            transform: Translate { x: stats.mOff("crumb")[0]; y: stats.mOff("crumb")[1] }
            Rectangle { visible: stats.mech.crumbStyle === "diamond"; anchors.verticalCenter: parent.verticalCenter; width: Math.round(9 * stats.s); height: width; rotation: 45; color: crumb.ci }
            Rectangle { visible: stats.mech.crumbStyle === "dot"; anchors.verticalCenter: parent.verticalCenter; width: Math.round(9 * stats.s); height: width; radius: width / 2; color: crumb.ci }
            Rectangle { visible: stats.mech.crumbStyle === "bar"; anchors.verticalCenter: parent.verticalCenter; width: Math.round(3 * stats.s); height: Math.round(15 * stats.s); color: crumb.ci }
            Text { anchors.verticalCenter: parent.verticalCenter; text: stats.caseFor("STATS", stats.mech.crumbCase); color: crumb.ci
                   font.family: mgsHud.name; font.weight: stats.weightFor(stats.mech.crumbWeight); font.pixelSize: stats.pxi(Math.round(stats.mSz(20, stats.mech.crumbSize) * stats.mScale("crumb"))); font.letterSpacing: stats.trackFor(stats.mech.crumbTrack) }
        }
        Text {
            id: subTag
            anchors.right: parent.right; anchors.bottom: parent.top; anchors.bottomMargin: Math.round(14 * stats.s)
            transform: Translate { x: stats.mOff("sub")[0]; y: stats.mOff("sub")[1] }
            text: stats.mechEdit ? "◆ GARAGE" : ""
            color: Theme.withAlpha(stats.accent, 0.6)
            font.family: stats.labelFontName; font.pixelSize: stats.pxi(Math.round(11 * stats.s)); font.letterSpacing: 3
        }

        // ── HERO CARD (51H box + DEEPEST-IN rows) ────────────────────────────
        Item {
            id: hero
            width: cockpit.heroW; height: cockpit.heroH
            anchors.left: parent.left; anchors.top: parent.top
            readonly property real boxW: 64 * stats.mpx     // 51H box zone (art 0..63 of the dlg)
            opacity: stats.eBox                              // phase 1: box fades + rises in
            transform: Translate { x: stats.mOff("hero")[0]; y: (1 - stats.eBox) * Math.round(14 * stats.s) + stats.mOff("hero")[1] }   // HERO PLATE move folded into the intro-rise

            // phase 2: the body slides OUT from behind the box — an expanding clip
            Item {
                id: heroClip
                clip: true
                width: hero.boxW + (hero.width - hero.boxW) * stats.eReveal
                height: hero.height

                // PLATE GLOW — a faint accent wash behind the hero plate
                Rectangle {
                    visible: stats.mech.plateGlow === "on" && !stats.classic
                    width: hero.width; height: hero.height
                    color: Theme.withAlpha(stats.accent, 0.10)
                }
                MechPanel {
                    visible: !stats.classic
                    width: hero.width; height: hero.height; px: stats.mpx
                    kind: stats.mech.hero === "cockpit" ? "cockpit" : stats.mech.hero
                }
                Rectangle {   // CLASSIC flat plate
                    visible: stats.classic
                    width: hero.width; height: hero.height
                    color: "#111721"; border.width: Math.max(1, stats.s); border.color: Theme.withAlpha(stats.steelInk, 0.25)
                }
                Rectangle {   // PLATE TINT — accent wash over the hero plate
                    visible: stats.mech.plateTint !== "none" && !stats.classic
                    width: hero.width; height: hero.height; color: stats.accent
                    opacity: stats.mech.plateTint === "med" ? 0.14 : 0.07
                }

            // ── recessed readout well behind the LIFETIME module — white pixel
            //    outline with PUNCHED 8-bit corners; editor move + size target ──
            Item {
                id: topWell
                visible: !stats.classic
                readonly property real pad: Math.round(13 * stats.s) * stats.mScale("topwell")
                // hug the CONTENT (glowPad in from boxCol's padded bounds), not the headroom
                anchors.left: boxCol.left; anchors.leftMargin: -pad
                anchors.right: boxCol.right; anchors.rightMargin: -pad
                anchors.top: boxCol.top; anchors.topMargin: boxCol.glowPad - pad
                anchors.bottom: boxCol.bottom; anchors.bottomMargin: boxCol.glowPad - pad
                transform: Translate { x: stats.mOff("topwell")[0]; y: stats.mOff("topwell")[1] }
                readonly property int bw: Math.max(1, Math.round(stats.s))
                readonly property color ec: "#a6b1c7"
                Rectangle { anchors.fill: parent; color: "#05080e"; antialiasing: false }
                Rectangle { anchors.fill: parent; antialiasing: false
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: Theme.withAlpha("#3a5f80", 0.16) }
                        GradientStop { position: 0.45; color: "transparent" }
                        GradientStop { position: 1.0; color: Theme.withAlpha("#000000", 0.35) } } }
                Rectangle { x: parent.bw; y: 0; width: parent.width - parent.bw*2; height: parent.bw; color: parent.ec; antialiasing: false }
                Rectangle { x: parent.bw; y: parent.height - parent.bw; width: parent.width - parent.bw*2; height: parent.bw; color: parent.ec; antialiasing: false }
                Rectangle { x: 0; y: parent.bw; width: parent.bw; height: parent.height - parent.bw*2; color: parent.ec; antialiasing: false }
                Rectangle { x: parent.width - parent.bw; y: parent.bw; width: parent.bw; height: parent.height - parent.bw*2; color: parent.ec; antialiasing: false }
            }
            Column {
                id: boxCol
                // glowPad = invisible headroom (top+bottom spacers) so the bloom FBO
                // has room and upward text nudges don't get sheared; the well anchors
                // to the CONTENT (glowPad in from the edges), not these bounds
                readonly property real glowPad: Math.round(26 * stats.s)
                x: Math.round(16 * stats.s); width: hero.boxW - Math.round(30 * stats.s)
                y: Math.round(28 * stats.s) - glowPad
                spacing: Math.round(4 * stats.s)
                transform: Translate { x: stats.mOff("readout")[0]; y: stats.mOff("readout")[1] }   // READOUT BOX move (whole readout stack)
                // NEON halo on the whole readout (labels + numbers), tinted their own colour
                layer.enabled: !stats.classic && (stats.wellGlowN[stats.mech.wellGlow] || 0) > 0
                layer.effect: ShaderEffect {
                    readonly property size res: Qt.size(Math.max(2, boxCol.width), Math.max(2, boxCol.height))
                    readonly property real radius: 2.5
                    readonly property real intensity: stats.wellGlowN[stats.mech.wellGlow] || 0
                    fragmentShader: "qrc:/qml/shaders/neonglow.frag.qsb"
                }
                Item { width: 1; height: boxCol.glowPad }   // top headroom
                // label ABOVE the big number reads as a titled stat block
                Text { id: labelText; text: stats.caseFor("TOTAL WATCHED", stats.mech.labelCase); color: Theme.withAlpha(stats.ink(stats.mech.labelInk), 0.72)
                       transform: Translate { x: stats.mOff("label")[0]; y: stats.mOff("label")[1] }
                       font.family: stats.mechFontFor(stats.mech.labFont); font.weight: stats.weightFor(stats.mech.labelWeight); font.pixelSize: stats.pxi(Math.round(stats.mSz(10, stats.mech.labelSize) * stats.mScale("label"))); font.letterSpacing: stats.trackFor(stats.mech.labelTrack) }
                Row {
                    id: bigRow
                    spacing: Math.round(4 * stats.s)
                    transform: Translate { x: stats.mOff("big")[0]; y: stats.mOff("big")[1] }
                    // hero 7-seg lifetime number — cyan, bookends the speedo's orange digit
                    Text { text: stats.fmtH(stats.summary.totalHours || 0); color: stats.ink(stats.mech.bigInk)
                           font.family: mgsAmmo.name
                           // shrink at 4+ digits (1000h+) so a large lifetime total can't overrun the plate
                           font.pixelSize: stats.pxi(Math.round(stats.mSz(58, stats.mech.bigSize) * stats.mScale("big") * (stats.fmtH(stats.summary.totalHours || 0).length >= 4 ? 0.6 : 1))); anchors.baseline: parent.bottom }
                    Text { text: "H"; color: Theme.withAlpha(stats.ink(stats.mech.bigInk), 0.7)
                           font.family: mgsHud.name; font.pixelSize: stats.pxi(Math.round(stats.mSz(18, stats.mech.bigSize) * stats.mScale("big"))); anchors.baseline: parent.bottom }
                }
                Item { width: 1; height: Math.round(10 * stats.s) }
                Column {
                    id: statCol
                    spacing: Math.round(5 * stats.s)
                    transform: Translate { x: stats.mOff("stats")[0]; y: stats.mOff("stats")[1] }
                    Text { text: stats.caseFor((stats.summary.plays || 0) + " PLAYS", stats.mech.statCase); color: Theme.withAlpha(stats.ink(stats.mech.statInk), 0.9)
                           width: boxCol.width - Math.round(6 * stats.s); horizontalAlignment: Text.AlignLeft; fontSizeMode: Text.HorizontalFit; maximumLineCount: 1
                           font.family: stats.mechFontFor(stats.mech.statFont); font.weight: stats.weightFor(stats.mech.statWeight); font.pixelSize: stats.pxi(Math.round(stats.mSz(11, stats.mech.statSize) * stats.mScale("stats"))); font.letterSpacing: stats.trackFor(stats.mech.statTrack) }
                    Text { text: stats.caseFor((stats.summary.daysWatched || 0) + " DAYS USED", stats.mech.statCase); color: Theme.withAlpha(stats.ink(stats.mech.statInk), 0.9)
                           width: boxCol.width - Math.round(6 * stats.s); horizontalAlignment: Text.AlignLeft; fontSizeMode: Text.HorizontalFit; maximumLineCount: 1
                           font.family: stats.mechFontFor(stats.mech.statFont); font.weight: stats.weightFor(stats.mech.statWeight); font.pixelSize: stats.pxi(Math.round(stats.mSz(11, stats.mech.statSize) * stats.mScale("stats"))); font.letterSpacing: stats.trackFor(stats.mech.statTrack) }
                    Text { text: stats.caseFor((stats.summary.completed || 0) + " COMPLETE", stats.mech.statCase); color: Theme.withAlpha(stats.ink(stats.mech.statInk), 0.9)
                           width: boxCol.width - Math.round(6 * stats.s); horizontalAlignment: Text.AlignLeft; fontSizeMode: Text.HorizontalFit; maximumLineCount: 1
                           font.family: stats.mechFontFor(stats.mech.statFont); font.weight: stats.weightFor(stats.mech.statWeight); font.pixelSize: stats.pxi(Math.round(stats.mSz(11, stats.mech.statSize) * stats.mScale("stats"))); font.letterSpacing: stats.trackFor(stats.mech.statTrack) }
                }
                Item { width: 1; height: boxCol.glowPad }   // bottom headroom
            }

            // ── recessed well behind the THIS WEEK module — punched white outline;
            //    editor move + size target ───────────────────────────────────
            Item {
                id: weekWell
                visible: weekCol.visible && !stats.classic
                readonly property real pad: Math.round(11 * stats.s) * stats.mScale("weekwell")
                anchors.left: weekCol.left; anchors.leftMargin: -pad
                anchors.right: weekCol.right; anchors.rightMargin: -pad
                anchors.top: weekCol.top; anchors.topMargin: -pad
                // FIXED height from the content's SIZE (not weekPct's position) so
                // nudging EP/TITLES doesn't stretch the well
                height: weekCol.height + Math.round(4 * stats.s) + weekEp.height + Math.round(2 * stats.s) + weekTt.height + pad * 2
                transform: Translate { x: stats.mOff("weekwell")[0]; y: stats.mOff("weekwell")[1] }
                readonly property int bw: Math.max(1, Math.round(stats.s))
                readonly property color ec: "#a6b1c7"
                Rectangle { anchors.fill: parent; color: "#05080e"; antialiasing: false }
                Rectangle { anchors.fill: parent; antialiasing: false
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: Theme.withAlpha("#3a5f80", 0.16) }
                        GradientStop { position: 0.45; color: "transparent" }
                        GradientStop { position: 1.0; color: Theme.withAlpha("#000000", 0.35) } } }
                Rectangle { x: parent.bw; y: 0; width: parent.width - parent.bw*2; height: parent.bw; color: parent.ec; antialiasing: false }
                Rectangle { x: parent.bw; y: parent.height - parent.bw; width: parent.width - parent.bw*2; height: parent.bw; color: parent.ec; antialiasing: false }
                Rectangle { x: 0; y: parent.bw; width: parent.bw; height: parent.height - parent.bw*2; color: parent.ec; antialiasing: false }
                Rectangle { x: parent.width - parent.bw; y: parent.bw; width: parent.bw; height: parent.height - parent.bw*2; color: parent.ec; antialiasing: false }
            }
            // secondary readout — THIS WEEK; fills the box middle (own dials)
            Column {
                id: weekCol
                visible: stats.mech.weekOn !== "off"
                x: Math.round(16 * stats.s); width: hero.boxW - Math.round(30 * stats.s)
                anchors.top: boxCol.bottom; anchors.topMargin: Math.round(22 * stats.s) - boxCol.glowPad
                transform: Translate { x: stats.mOff("week")[0]; y: stats.mOff("week")[1] }
                spacing: Math.round(7 * stats.s)
                // this week's watch hours vs your average week (30-day daily
                // mean × 7). Full bar = twice your average, so a typical week
                // sits mid-scale with headroom above.
                readonly property real avgWeekH: {
                    if (!stats.days || stats.days.length === 0) return 0
                    var tot = 0; for (var i = 0; i < stats.days.length; ++i) tot += (stats.days[i].seconds || 0)
                    return (tot / stats.days.length) * 7 / 3600
                }
                readonly property real cpl: avgWeekH > 0 ? Math.min(1, (stats.summary.weekHours || 0) / (avgWeekH * 2)) : 0
                Text { id: weekLab; text: stats.caseFor(stats.mech.weekLabel, stats.mech.weekCase); color: Theme.withAlpha(stats.ink(stats.mech.labelInk), 0.72)
                       transform: Translate { x: stats.mOff("wlab")[0]; y: stats.mOff("wlab")[1] }
                       layer.enabled: !stats.classic && (stats.wellGlowN[stats.mech.wellGlow] || 0) > 0
                       layer.effect: ShaderEffect {
                           readonly property size res: Qt.size(Math.max(2, weekLab.width), Math.max(2, weekLab.height))
                           readonly property real radius: 2.5
                           readonly property real intensity: stats.wellGlowN[stats.mech.wellGlow] || 0
                           fragmentShader: "qrc:/qml/shaders/neonglow.frag.qsb"
                       }
                       font.family: stats.mechFontFor(stats.mech.labFont); font.pixelSize: stats.pxi(Math.round(stats.mSz(10, stats.mech.labelSize) * stats.mScale("wlab"))); font.letterSpacing: stats.trackFor(stats.mech.weekTrack) }
                // (the this-week HOURS readout moved into the speedo's 7-seg digit)
            }
            // this-week activity: episodes + distinct titles (real per-title data
            // joined from media_state.last_played). Anchored to weekCol as a SIBLING
            // (not a positioner child — a Column mis-placed multi-line/extra children).
            // EP + TITLES are now two SEPARATE elements so their spacing (and each
            // line's position/scale) is independently editable — WEEK EP (wep) seats
            // under the hours; WEEK TITLES (wtt) seats under EP (nudge wtt.y = the gap).
            Text { id: weekEp
                   anchors.left: parent.left; anchors.leftMargin: Math.round(16 * stats.s) + stats.mOff("wep")[0]
                   anchors.top: weekCol.bottom; anchors.topMargin: Math.round(4 * stats.s) + stats.mOff("wep")[1]
                   visible: weekCol.visible
                   layer.enabled: !stats.classic && (stats.wellGlowN[stats.mech.wellGlow] || 0) > 0
                   layer.effect: ShaderEffect {
                       readonly property size res: Qt.size(Math.max(2, weekEp.width), Math.max(2, weekEp.height))
                       readonly property real radius: 2.5
                       readonly property real intensity: stats.wellGlowN[stats.mech.wellGlow] || 0
                       fragmentShader: "qrc:/qml/shaders/neonglow.frag.qsb"
                   }
                   textFormat: Text.StyledText
                   text: "<font color=\"#f2f8fc\">" + (stats.weekAct.episodes || 0) + "</font> EP"
                   color: Theme.withAlpha(stats.ink(stats.mech.statInk), 0.9)
                   font.family: stats.mechFontFor(stats.mech.statFont); font.weight: stats.weightFor(stats.mech.statWeight)
                   font.pixelSize: stats.pxi(Math.round(stats.mSz(11, stats.mech.statSize) * stats.mScale("wep"))); font.letterSpacing: stats.trackFor(stats.mech.statTrack) }
            Text { id: weekTt
                   anchors.left: parent.left; anchors.leftMargin: Math.round(16 * stats.s) + stats.mOff("wtt")[0]
                   anchors.top: weekEp.bottom; anchors.topMargin: Math.round(2 * stats.s) + stats.mOff("wtt")[1]
                   visible: weekCol.visible
                   layer.enabled: !stats.classic && (stats.wellGlowN[stats.mech.wellGlow] || 0) > 0
                   layer.effect: ShaderEffect {
                       readonly property size res: Qt.size(Math.max(2, weekTt.width), Math.max(2, weekTt.height))
                       readonly property real radius: 2.5
                       readonly property real intensity: stats.wellGlowN[stats.mech.wellGlow] || 0
                       fragmentShader: "qrc:/qml/shaders/neonglow.frag.qsb"
                   }
                   textFormat: Text.StyledText
                   text: "<font color=\"#f2f8fc\">" + (stats.weekAct.titles || 0) + "</font> TITLE" + ((stats.weekAct.titles || 0) === 1 ? "" : "S")
                   color: Theme.withAlpha(stats.ink(stats.mech.statInk), 0.9)
                   font.family: stats.mechFontFor(stats.mech.statFont); font.weight: stats.weightFor(stats.mech.statWeight)
                   font.pixelSize: stats.pxi(Math.round(stats.mSz(11, stats.mech.statSize) * stats.mScale("wtt"))); font.letterSpacing: stats.trackFor(stats.mech.statTrack) }

            // ring gauge inside the box, seated at the bottom
            Item {
                id: ring
                visible: stats.mech.ring !== "off"
                // HERO element: fills the lower half of the panel. Square for the
                // arc/gauge styles; tall for the bar-graph speedo (fills to bottom).
                // bigger + editor-sizable (mScale "ring"); square for arc styles,
                // tall for the speedo (fills from THIS WEEK down to the panel floor)
                width: Math.round((hero.boxW - Math.round(14 * stats.s)) * stats.mScale("ring"))
                x: (hero.boxW - width) / 2
                anchors.top: ring.isTach ? weekTt.bottom : undefined
                anchors.topMargin: Math.round(12 * stats.s)
                anchors.bottom: parent.bottom; anchors.bottomMargin: Math.round(14 * stats.s)
                height: ring.isTach ? undefined : width
                transform: Translate { x: stats.mOff("ring")[0]; y: stats.mOff("ring")[1] }
                // phosphor bloom on the lit segments (GPU) — blooms bright pixels regardless of
                // background, so it works on the 9's opaque readout box where a halo-glow can't.
                layer.enabled: ring.isTach && !stats.classic && stats.mech.speedoGlow !== "off"
                layer.effect: ShaderEffect {
                    readonly property size res: Qt.size(Math.max(2, ring.width), Math.max(2, ring.height))
                    readonly property real glow: stats.mech.speedoGlow === "soft" ? 0.5 : stats.mech.speedoGlow === "strong" ? 1.35 : 0.85
                    fragmentShader: "qrc:/qml/shaders/speedobloom.frag.qsb"
                }
                readonly property real cx: width / 2
                readonly property real cy: height / 2
                readonly property real thickF: stats.mech.ringThick === "thin" ? 0.6 : stats.mech.ringThick === "thick" ? 1.6 : 1
                readonly property color rc: stats.ink(stats.mech.ringInk)
                readonly property real gapF: stats.sizeFac[stats.mech.ringGap] || 1
                // gauge = a 270° speedometer sweep; arcs = full rings
                readonly property real trackStart: stats.mech.ring === "gauge" ? 135 : 0
                readonly property real ringSweep: stats.mech.ring === "gauge" ? 270 : 360
                readonly property real fillStart: stats.mech.ring === "gauge" ? 135 : -90
                readonly property var arcs: [
                    { r: 0.48, f: Math.min(1, (stats.summary.daysWatched || 0) / 30) },
                    { r: 0.48 - 0.11 * gapF, f: Math.min(1, (stats.summary.completed || 0) / Math.max(1, stats.summary.plays || 1)) },
                    { r: 0.48 - 0.22 * gapF, f: Math.min(1, (stats.summary.weekHours || 0) / Math.max(1, (stats.summary.totalHours || 1) / 4)) }
                ]
                // ── TACHOMETER: needle = this-week watch intensity vs your usual;
                //    redlines when you binge. Hub = lifetime hours (the odometer). ──
                readonly property bool isTach: stats.mech.ring === "tach"
                readonly property real redlineH: Math.max(8, weekCol.avgWeekH * 1.8)   // "binge" threshold, min 8h
                readonly property real tachMax: redlineH * 1.25                         // full-scale, room past the red
                readonly property real tachVal: Math.min(1, (stats.summary.weekHours || 0) / Math.max(0.1, tachMax))
                readonly property real redFrac: Math.min(0.95, redlineH / tachMax)      // where the red zone starts (~0.8)
                readonly property bool inRed: tachVal >= redFrac
                readonly property color redCol: "#ff4d4d"
                Repeater {
                    model: ring.arcs
                    Shape {
                        id: arc
                        visible: !ring.isTach
                        required property var modelData
                        required property int index
                        anchors.fill: parent; antialiasing: true
                        readonly property real rad: modelData.r * ring.width
                        ShapePath {
                            strokeColor: Qt.rgba(0.13, 0.20, 0.24, 1); fillColor: "transparent"
                            strokeWidth: Math.max(2, 4 * stats.s * ring.thickF); capStyle: stats.mech.ringCaps === "flat" ? ShapePath.FlatCap : ShapePath.RoundCap
                            PathAngleArc { centerX: ring.cx; centerY: ring.cy; radiusX: arc.rad; radiusY: arc.rad; startAngle: ring.trackStart; sweepAngle: ring.ringSweep }
                        }
                        ShapePath {
                            strokeColor: Qt.rgba(ring.rc.r, ring.rc.g, ring.rc.b, 1 - 0.16 * arc.index)
                            fillColor: "transparent"
                            strokeWidth: Math.max(2, 4 * stats.s * ring.thickF); capStyle: stats.mech.ringCaps === "flat" ? ShapePath.FlatCap : ShapePath.RoundCap
                            strokeStyle: stats.mech.ring === "dashes" ? ShapePath.DashLine : ShapePath.SolidLine
                            dashPattern: [2, 2.5]
                            PathAngleArc { centerX: ring.cx; centerY: ring.cy; radiusX: arc.rad; radiusY: arc.rad
                                           startAngle: ring.fillStart; sweepAngle: ring.ringSweep * arc.modelData.f }
                        }
                    }
                }
                // cardinal tick bezel — reads the concentric arcs as a gauge
                Repeater {
                    model: [0, 90, 180, 270]
                    Rectangle {
                        required property var modelData
                        visible: stats.mech.ringTicks === "on" && !ring.isTach
                        readonly property real ang: modelData * Math.PI / 180
                        readonly property real rr: ring.width * 0.53
                        width: Math.max(2, Math.round(2 * stats.s)); height: Math.round(8 * stats.s)
                        color: Theme.withAlpha(ring.rc, 0.5); antialiasing: true
                        x: ring.cx + Math.sin(ang) * rr - width / 2
                        y: ring.cy - Math.cos(ang) * rr - height / 2
                        rotation: modelData
                    }
                }
                // radar sweep — a slow accent finger over the arcs (SWEEP dial)
                Rectangle {
                    visible: stats.mech.ringSpin === "on" && stats.mech.ring !== "off" && !ring.isTach
                    width: Math.max(1, Math.round(2 * stats.s)); height: ring.width * 0.46
                    x: ring.cx - width / 2; y: ring.cy - height
                    transformOrigin: Item.Bottom; rotation: stats.ambSweep
                    antialiasing: true; opacity: 0.5 * stats.ambientK
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: "transparent" }
                        GradientStop { position: 1.0; color: ring.rc }
                    }
                }
                // ── DIGITAL BAR-GRAPH SPEEDO (C4-Corvette style) ─────────────
                //    rungs climb a curve, mint-green fill = this-week pace,
                //    rungs go red past the binge redline; big 7-seg readout.
                readonly property color spLit: "#5cf2a6"     // saturated mint (greener glow)
                readonly property color spDim: "#1e2b33"     // unlit rung
                readonly property color spAmber: "#e8b74d"   // scale numbers
                readonly property color spDigit: "#e8f4ff"   // 7-seg readout (white; red on redline)
                readonly property int  spN: 22               // rung count
                readonly property real spBaseY: ring.height * 0.95
                readonly property real spTopY: ring.height * 0.06
                readonly property real spPitch: (spBaseY - spTopY) / spN
                function spCx(f) { return ring.width * 0.30 + ring.width * 0.20 * Math.pow(f, 1.5) }
                function spW(f)  { return ring.width * 0.10 + ring.width * 0.24 * f }
                // ── the dark VFD "screen": vivid segments pop off it like the
                //    reference dash — depth via glass sheen, not a blur-glow ──
                Item {
                    visible: ring.isTach; anchors.fill: parent
                    readonly property int bw: Math.max(1, Math.round(stats.s))
                    Rectangle { anchors.fill: parent; color: "#05080e"; antialiasing: false }
                    Rectangle { anchors.fill: parent; antialiasing: false
                        gradient: Gradient {
                            GradientStop { position: 0.0; color: Theme.withAlpha("#3a5f80", 0.16) }
                            GradientStop { position: 0.45; color: "transparent" }
                            GradientStop { position: 1.0; color: Theme.withAlpha("#000000", 0.35) } } }
                    Rectangle { x: parent.bw; y: 0; width: parent.width-parent.bw*2; height: parent.bw; color: "#a6b1c7"; antialiasing: false }
                    Rectangle { x: parent.bw; y: parent.height-parent.bw; width: parent.width-parent.bw*2; height: parent.bw; color: "#a6b1c7"; antialiasing: false }
                    Rectangle { x: 0; y: parent.bw; width: parent.bw; height: parent.height-parent.bw*2; color: "#a6b1c7"; antialiasing: false }
                    Rectangle { x: parent.width-parent.bw; y: parent.bw; width: parent.bw; height: parent.height-parent.bw*2; color: "#a6b1c7"; antialiasing: false }
                }
                Repeater {   // the climbing rungs
                    model: ring.isTach ? ring.spN : 0
                    Rectangle {
                        id: rung
                        required property int index
                        readonly property real f: index / (ring.spN - 1)
                        readonly property bool lit: f <= ring.tachVal + 0.0001
                        readonly property real w: ring.spW(f)
                        width: w; height: Math.max(2, ring.spPitch * 0.60); radius: Math.max(1, Math.round(stats.s))
                        x: ring.spCx(f) - w / 2
                        y: ring.spBaseY - index * ring.spPitch - height
                        antialiasing: true
                        color: !lit ? ring.spDim : (f >= ring.redFrac ? ring.redCol : ring.spLit)
                        Behavior on color { ColorAnimation { duration: 220 } }
                        // glossy VFD top edge on lit segments (crisp, not a glow)
                        Rectangle {
                            visible: rung.lit; antialiasing: false
                            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                            anchors.leftMargin: 1; anchors.rightMargin: 1
                            height: Math.max(1, Math.round(rung.height * 0.28))
                            color: Qt.lighter(rung.color, 1.45)
                        }
                    }
                }
                Repeater {   // scale numbers (amber; red in the danger zone)
                    model: ring.isTach ? 5 : 0
                    Text {
                        required property int index
                        readonly property real f: index / 4
                        text: Math.round(f * ring.tachMax) + ""
                        color: f >= ring.redFrac ? Theme.withAlpha(ring.redCol, 0.9) : ring.spAmber
                        font.family: mgsHud.name; font.pixelSize: stats.pxi(Math.max(12, Math.round(ring.width * 0.13)))
                        x: ring.spCx(f) - ring.spW(f) / 2 - width - Math.round(6 * stats.s)
                        y: ring.spBaseY - f * (ring.spN - 1) * ring.spPitch - height / 2 - Math.round(3 * stats.s)
                    }
                }
                Column {     // the big "speed" (mgscodec = the hero number) + H/WK detail (mgshud)
                    id: spNum
                    visible: ring.isTach
                    anchors.right: parent.right; anchors.rightMargin: Math.round(ring.width * 0.13)
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.verticalCenterOffset: Math.round(ring.height * 0.08); spacing: Math.round(2 * stats.s)
                    transform: Translate { x: stats.mOff("spnum")[0]; y: stats.mOff("spnum")[1] }
                    TextMetrics { id: spNumTM; font: spBigNum.font; text: spBigNum.text }
                    TextMetrics { id: spUnitTM; font: spUnit.font; text: spUnit.text }
                    Text { id: spBigNum
                           anchors.horizontalCenter: parent.horizontalCenter
                           // scale font DOWN by digit count so a 2-digit H/WK ("10") keeps the same
                           // footprint as one digit and never overlaps the bar rungs to its left
                           readonly property string val: Math.round(stats.summary.weekHours || 0) + ""
                           text: val
                           color: ring.inRed ? ring.redCol : ring.spDigit
                           font.family: stats.mechFontFor(stats.mech.spNumFont); font.bold: true
                           font.pixelSize: stats.pxi(Math.round(ring.width * 0.60 / Math.max(1, val.length)))}
                    Text { id: spUnit
                           anchors.horizontalCenter: parent.horizontalCenter
                           // Align H/WK's INK centre to the number's INK centre. Both fonts pad their
                           // box asymmetrically (the number is monospace → a narrow leading "1" leaves
                           // its cell half-empty so the digits sit right-of-box-centre; H/WK's trailing
                           // letterSpacing pads its right). tightBoundingRect gives each one's real ink
                           // offset, so the label tracks the visible digits for ANY value.
                           anchors.horizontalCenterOffset: Math.round(
                               (spNumTM.tightBoundingRect.x + spNumTM.tightBoundingRect.width / 2 - spNumTM.advanceWidth / 2)
                             - (spUnitTM.tightBoundingRect.x + spUnitTM.tightBoundingRect.width / 2 - spUnitTM.advanceWidth / 2))
                           text: "H / WK"
                           color: Theme.withAlpha(ring.spDigit, 0.85)
                           font.family: stats.mechFontFor(stats.mech.spUnitFont); font.pixelSize: stats.pxi(Math.max(10, Math.round(ring.width * 0.11))); font.letterSpacing: 2 }
                }
                Rectangle {
                    visible: stats.mech.hub !== "off" && !ring.isTach
                    anchors.centerIn: parent; width: stats.mSz(42, stats.mech.hubSize); height: width; radius: width / 2
                    color: "#0d131c"; border.width: Math.max(1, Math.round(1.4 * stats.s))
                    readonly property color hc: stats.ink(stats.mech.hubInk)
                    border.color: Theme.withAlpha(hc, stats.mech.hubPulse === "on" ? 0.55 + 0.4 * stats.ambBreathe : 0.75)
                    Text { visible: stats.mech.hub === "num"; anchors.centerIn: parent; text: stats.fmtH(stats.summary.totalHours || 0) + "H"; color: parent.hc
                           font.family: mgsHud.name; font.bold: true; font.pixelSize: stats.pxi(stats.mSz(12, stats.mech.hubSize))}
                    Rectangle { visible: stats.mech.hub === "dot"; anchors.centerIn: parent; width: Math.round(10 * stats.s); height: width; radius: width / 2; color: parent.hc }
                }
            }

            // ── DEEPEST-IN header + rows (body) ──────────────────────────────
            // ELONGATED CAST SHADOW (headerShadow: "long") — a REAL GPU pass: the header glyph
            // is captured to a texture (ShaderEffectSource) and a fragment shader marches it
            // along the light direction into one smooth shadow that matches every glyph detail
            // (no stepping). CAST LEN/INK/SPREAD/DIR + the light-aim tool drive its uniforms.
            // ⚠ ShaderEffect/Source don't render in the offscreen harness — verify LIVE.
            Item {
                id: hdrCast
                anchors.fill: parent
                readonly property bool shadowOn: !stats.classic && stats.mech.headerShadow === "long"
                readonly property bool glowOn: !stats.classic && (stats.glowIntN[stats.mech.headerGlow] || 0) > 0
                visible: shadowOn || glowOn
                // direction: LIVE cursor while aiming → baked mech.castVec → the discrete CAST DIR dial
                readonly property var dir: stats.lightAim ? stats.lightVec
                    : (stats.mech.castVec && stats.mech.castVec.length === 2 ? stats.mech.castVec
                       : (stats.castDirV[stats.mech.castDir] || [-1, -1]))
                readonly property int steps: stats.castLenN[stats.mech.castLen] || 24
                readonly property real unit: Math.max(1, (stats.castStepP[stats.mech.castStep] || 1.0) * 1.1 * stats.s)
                readonly property real dlen: Math.max(0.001, Math.hypot(dir[0], dir[1]))   // for normalising the aim
                readonly property int reach: Math.min(320, Math.round(steps * unit))       // shadow length in PX = 1-texel march steps
                readonly property int pad: Math.ceil(reach * 1.4) + 4      // headroom for the shadow reach
                readonly property real fw: Math.max(1, deepHdr.width) + 2 * pad
                readonly property real fh: Math.max(1, deepHdr.height) + 2 * pad
                // clip the shadow's TOP + LEFT to the tab face so an up/left rake stops at the
                // tab edge instead of darkening the white trim/seam. CAST GAP tunes the top cut;
                // the left cut sits just right of the boxW seam. Bottom/right stay open so a
                // DOWN/right cast can fall onto the open body steel (where a shadow reads best).
                readonly property int clipTop: Math.max(0, Math.round(deepHdr.y - (stats.castGapN[stats.mech.castGap] === undefined ? 3 : stats.castGapN[stats.mech.castGap]) * stats.s))
                readonly property int clipLeft: Math.max(0, Math.round(hero.boxW + 2 * stats.s))
                ShaderEffectSource {
                    id: hdrSrc
                    sourceItem: deepHdr
                    sourceRect: Qt.rect(-hdrCast.pad, -hdrCast.pad, hdrCast.fw, hdrCast.fh)
                    hideSource: false; live: true; visible: false
                }
                Item {
                    anchors.fill: parent
                    anchors.topMargin: hdrCast.clipTop
                    anchors.leftMargin: hdrCast.clipLeft
                    clip: true
                    ShaderEffect {
                        visible: hdrCast.shadowOn
                        x: deepHdr.x - hdrCast.pad + stats.mOff("header")[0] - hdrCast.clipLeft
                        y: deepHdr.y - hdrCast.pad + stats.mOff("header")[1] - hdrCast.clipTop
                        width: hdrCast.fw; height: hdrCast.fh
                        // strength: LIVE wheel while aiming → baked mech.castBright → CAST INK dial
                        opacity: stats.lightAim ? stats.lightBright
                               : (stats.mech.castBright !== null && stats.mech.castBright !== undefined ? stats.mech.castBright
                                  : (stats.castInkO[stats.mech.castInk] || 0.18))
                        property variant source: hdrSrc
                        // dir = a single-TEXEL step in the (normalised) light direction, so the
                        // shader marches every pixel; `steps` = the full pixel reach = ultra detail.
                        property vector2d dir: Qt.vector2d((hdrCast.dir[0] / hdrCast.dlen) / hdrCast.fw,
                                                           (hdrCast.dir[1] / hdrCast.dlen) / hdrCast.fh)
                        property real steps: hdrCast.reach
                        property real fade: 0.45
                        // cast colour: 'neon' = the header's own ink (shows on a DARK tab as a
                        // colour-cast); 'dark' = a true shadow (for LIGHT backgrounds); or a set ink
                        property vector4d shadowColor: {
                            var t = stats.mech.castTone
                            var c = (t === "dark") ? Qt.rgba(5 / 255, 8 / 255, 14 / 255, 1)
                                  : (t === "neon") ? stats.ink(stats.mech.headerInk)
                                  : stats.ink(t)
                            return Qt.vector4d(c.r, c.g, c.b, 1.0)
                        }
                        fragmentShader: "qrc:/qml/shaders/longshadow.frag.qsb"
                    }
                }
                // NEON GLOW — GPU bloom of the glyphs, tinted, rendered behind the text
                ShaderEffect {
                    id: hdrGlow
                    visible: hdrCast.glowOn
                    x: deepHdr.x - hdrCast.pad + stats.mOff("header")[0]
                    y: deepHdr.y - hdrCast.pad + stats.mOff("header")[1]
                    width: hdrCast.fw; height: hdrCast.fh
                    property variant source: hdrSrc
                    property vector2d px: Qt.vector2d(1 / hdrCast.fw, 1 / hdrCast.fh)
                    property real radius: stats.glowRadN[stats.mech.headerGlowSize] || 3.5
                    property real intensity: stats.glowIntN[stats.mech.headerGlow] || 0
                    property vector4d glowColor: {
                        var c = stats.mech.headerGlowInk === "match" ? stats.ink(stats.mech.headerInk) : stats.ink(stats.mech.headerGlowInk)
                        return Qt.vector4d(c.r, c.g, c.b, 1.0)
                    }
                    fragmentShader: "qrc:/qml/shaders/headerglow.frag.qsb"
                }
            }
            Text {
                id: deepHdr
                x: hero.boxW + Math.round(16 * stats.s); y: Math.round(16 * stats.s)
                // "header" moves it at ALL resolutions; "headerCrt" adds a CRT-ONLY nudge (assembly
                // element) so the tab can be slid off the panel edge on the 5:4 tube without touching DP-3.
                transform: Translate {
                    x: stats.mOff("header")[0] + (stats.isCrt ? stats.mOff("headerCrt")[0] : 0)
                    y: stats.mOff("header")[1] + (stats.isCrt ? stats.mOff("headerCrt")[1] : 0)
                }
                text: stats.caseFor(stats.mech.deepLabel, stats.mech.headerCase)
                color: stats.classic ? Theme.withAlpha(stats.steelInk, 0.8) : stats.ink(stats.mech.headerInk)
                style: stats.shadowStyleFor(stats.mech.headerShadow); styleColor: stats.shadowInk
                // NEON glow — the SAME layer.effect + WELL GLOW control as the TOTAL WATCHED
                // readout, so the header reads identically now that it sits on a dark tab.
                layer.enabled: !stats.classic && (stats.wellGlowN[stats.mech.wellGlow] || 0) > 0
                layer.effect: ShaderEffect {
                    readonly property size res: Qt.size(Math.max(2, deepHdr.width), Math.max(2, deepHdr.height))
                    readonly property real radius: 2.5
                    readonly property real intensity: stats.wellGlowN[stats.mech.wellGlow] || 0
                    fragmentShader: "qrc:/qml/shaders/neonglow.frag.qsb"
                }
                font.family: stats.mechFontFor(stats.mech.headerFont); font.bold: true
                font.pixelSize: stats.pxi(Math.round(stats.mSz(11, stats.mech.headerSize) * stats.mScale("header") * (stats.isCrt ? stats.mScale("headerCrt") : 1))); font.letterSpacing: stats.trackFor(stats.mech.headerTrack)
            }
            Column {
                id: rows
                x: hero.boxW + Math.round(8 * stats.s)
                anchors.top: parent.top; anchors.topMargin: Math.round(44 * stats.s)
                anchors.bottom: parent.bottom; anchors.bottomMargin: Math.round(12 * stats.s)
                width: hero.width - x - Math.round(10 * stats.s)
                transform: Translate { x: stats.mOff("rows")[0]; y: stats.mOff("rows")[1] }
                readonly property int n: Math.max(0, Math.min(stats.mech.rowCount, stats.shows.length))   // 0 when no history → no ghost "0%" row
                // ROW GAP — a FINE numeric stepper (reference px): 0 = rows touching, fine
                // 1px steps at the low end. Accepts a plain number (new dial) OR a legacy
                // size string so old saves render unchanged ("m" == the old 10px default).
                readonly property var gapLegacy: ({ xxs: 0, xs: 4, s: 7, m: 10, l: 16, xl: 24, xxl: 36 })
                readonly property real gapPx: {
                    var g = stats.mech.rowGap
                    if (typeof g === "number") return g
                    return gapLegacy[g] === undefined ? 10 : gapLegacy[g]
                }
                // ROW GAP must have REAL authority over the spacing. If rowH were derived
                // from the live gap (rowH = (H-(n-1)gap)/n) the rows fill a fixed region, so
                // center-to-center pitch collapses to (H+gap)/n — sweeping the whole dial moves
                // rows by only gap/n and the plates just shrink: the dial feels dead. Instead
                // rowH is STABLE (sized to fill at the default gap, gapRef), so the live gap is
                // a true spacer: pitch = rowH + gap, full authority. Small gap → rows pack tight
                // from the top (region under-fills, that's the point); a large gap can't overflow
                // (clamped to the fill height). For tight rows: ROW GAP low; to fill: ROW COUNT.
                readonly property real gap: Math.round(gapPx * stats.s)
                readonly property real gapRef: Math.round(10 * stats.s)   // gap where rows fill exactly (the default)
                readonly property real rowH: {
                    var minH = Math.round(6 * stats.s)
                    var stable = (height - (n - 1) * gapRef) / n           // stable height: fills at the default gap
                    var fillH  = (height - (n - 1) * gap) / n              // height that would exactly fill at the LIVE gap
                    // stable except when the live gap is so large it would overflow — then fall
                    // back to fillH so the block never spills past the region.
                    return Math.max(minH, Math.min(stable, fillH))
                }
                spacing: gap
                // SELECTION SPINE: a persistent selection driven by j/k (keyboard) OR
                // hover, marked by the spine rail on the left. Defaults to the top row.
                property int selRow: 0
                // empty-state: a brand-new user with no watch history yet — one
                // block centred in the rows region, both lines on the MGS faces
                // (the hint used to float mid-SCREEN in the mono font, off the panel).
                Item {
                    visible: stats.shows.length === 0
                    width: parent.width; height: parent.height
                    Column {
                        anchors.centerIn: parent
                        spacing: Math.round(14 * stats.s)
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "— NO WATCH HISTORY YET —"
                            color: Theme.withAlpha(stats.steelInk, 0.6)
                            font.family: mgsCodec.name; font.pixelSize: stats.pxi(Math.round(14 * stats.s)); font.letterSpacing: 3
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "PLAY SOMETHING AND YOUR COCKPIT FILLS IN HERE"
                            color: Theme.withAlpha(stats.steelInk, 0.4)
                            font.family: mgsHud.name; font.pixelSize: stats.pxi(Math.round(14 * stats.s)); font.letterSpacing: 2
                        }
                    }
                }
                Repeater {
                    model: rows.n
                    delegate: Item {
                        id: rowItem
                        required property int index
                        readonly property var sd: stats.shows[index]
                        readonly property bool isMovie: sd && sd.kind === "movie"
                        // shows: % of the series watched (how far to the end). movies: a WATCH-COUNT
                        // meter — ~1 segment lit per time watched (÷14 ≈ the bar's segments at
                        // fullscreen), capped full, so a film rewatched 5× reads longer than one
                        // watched twice. The "×N" label carries the exact number.
                        readonly property real frac: sd ? (isMovie ? Math.min(1, (sd.count || 0) / 14) : sd.done / Math.max(1, sd.total)) : 0
                        readonly property bool selected: rows.selRow === index
                        // the ONLY time a row animates: the selection moving ONTO it plays the chevron
                        // ONCE, presses the plate (3-state), bounces the bar + scrambles the % — lifelike
                        onSelectedChanged: if (selected) { stats.selT = title; stats.selB = mbar; stats.selP = pct; stats.selC = chev; stats.selBox = btn; if (stats.visible) { chevTab.restart(); btn.tap(); mbar.playSel(); scramble.restart(); hopAnim.restart() } }
                        width: rows.width; height: rows.rowH
                        // SPOTLIGHT dim is applied to the TEXT elements only (the bar +
                        // chevron keep their own idle states) — see title/pct below
                        readonly property real textDim: stats.classic || selected ? 1.0 : 0.5
                        // the text sits ON the plate and rides its PRESS: dips down as
                        // the button presses, springs back on release — attached + alive
                        property real hopY: 0
                        SequentialAnimation { id: hopAnim
                            NumberAnimation { target: rowItem; property: "hopY"; to: Math.round(3 * stats.s); duration: 90; easing.type: Easing.OutQuad }
                            NumberAnimation { target: rowItem; property: "hopY"; to: 0; duration: 260; easing.type: Easing.OutBack }
                        }
                        readonly property real chW: stats.mech.chevron === "none" ? 0 : Math.round(rows.rowH * 0.62 * stats.mScale("rchev"))

                        // real selection area: hovering the row lights it and plays
                        // the chevron — the only time the row animates
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: !stats.mechEdit
                            onEntered: { stats.sfxPoint(rowItem.index); rows.selRow = rowItem.index }   // hover commits the persistent selection too
                        }
                        // CARD BACKING — a navy fill in the card's interior color (#181c23) behind the
                        // whole row, spanning the CARD's height and the FULL row width. Started as a
                        // caret-corner seam patch (the caret sits LEFT of the plate, so the panel bled
                        // through lighter there); extended end-to-end so the plate sits on a solid dark
                        // bed instead of the panel background. The caret, CHEV BACK and plate draw on top.
                        // Can't be done in the art (caret = plain sprite, plate = 9-slice, this bed is the
                        // QML gap between/under them). Rides the caret move offset.
                        Rectangle {
                            visible: !stats.classic && stats.mech.chevron !== "none"
                            anchors.left: chev.left
                            anchors.right: parent.right                       // run the full row width, to the end
                            anchors.top: btn.top; anchors.bottom: btn.bottom
                            anchors.bottomMargin: -Math.max(1, Math.round(stats.s * 0.3))   // a true 1px hair below the card's edge — flush, not a detached strip
                            color: "#181c23"
                            // ride the CARD's move (rowbox), not the caret's — anchors use pre-transform
                            // geometry, so the bed must carry the same translate as the plate to stay flush.
                            transform: Translate { x: stats.mOff("rowbox")[0]; y: stats.mOff("rowbox")[1] }
                        }
                        // chevron backing (CHEV BACK)
                        MechPanel {
                            visible: stats.mech.chevBack !== "none" && !stats.classic && stats.mech.chevron !== "none"
                                     && (stats.mech.chevShow !== "single" || rowItem.selected)
                            anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                            width: parent.chW; height: parent.chW; px: stats.mpx
                            kind: stats.mech.chevBack === "chip" ? "chip" : stats.mech.chevBack === "hollow" ? "hollow" : "frame"
                        }
                        // chevron — style; "tab" plays the 2-state 3-frame hover.
                        // CHEV COUNT "single" hides the graphic on unselected rows (the Item
                        // keeps its width, so titles stay aligned = a pointer to the selection).
                        Item {
                            id: chev
                            visible: stats.mech.chevron !== "none" && (stats.mech.chevShow !== "single" || rowItem.selected)
                            anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                            transform: Translate { x: stats.mOff("rchev")[0]; y: stats.mOff("rchev")[1] }
                            width: parent.chW; height: parent.chW
                            clip: true
                            readonly property bool active: rowItem.selected
                            property int frame: 0
                            SequentialAnimation { id: chevTab   // plays ONCE on selection (was a constant 110ms loop → jumpy)
                                PropertyAction { target: chev; property: "frame"; value: 0 }
                                PauseAnimation { duration: 70 }
                                PropertyAction { target: chev; property: "frame"; value: 1 }
                                PauseAnimation { duration: 70 }
                                PropertyAction { target: chev; property: "frame"; value: 2 }
                            }
                            Image { visible: stats.mech.chevron === "tab" && !chev.active; anchors.fill: parent; smooth: false
                                    source: (App.heroDevRev, App.heroDevPath("stat-tab") !== "" ? App.heroDevPath("stat-tab") + "?v=" + App.heroDevRev : "qrc:/assets/mechui/stat-tab.png") }
                            Image { visible: stats.mech.chevron === "tab" && chev.active; smooth: false
                                    width: chev.width * 3; height: chev.height; cache: App.heroDevPath("stat-tab-hover") === ""
                                    source: (App.heroDevRev, App.heroDevPath("stat-tab-hover") !== "" ? App.heroDevPath("stat-tab-hover") + "?v=" + App.heroDevRev : "qrc:/assets/mechui/stat-tab-hover.png"); x: -chev.frame * chev.width }
                            Rectangle { visible: stats.mech.chevron === "dot"; anchors.centerIn: parent
                                    width: parent.width * 0.42; height: width; rotation: 45
                                    color: chev.active ? stats.accent : Theme.withAlpha(stats.accent, 0.7) }
                            Rectangle { visible: stats.mech.chevron === "bar"; anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                                    width: Math.max(2, Math.round(3 * stats.s)); height: parent.height * (chev.active ? 0.9 : 0.7)
                                    color: chev.active ? stats.accent : Theme.withAlpha(stats.accent, 0.7) }
                        }
                        // the row plate — button family (ROW PLATE) or a MechPanel
                        // kind (ROW BACK); the active row rides the lit/hover art
                        MechButton {
                            id: btn
                            visible: !stats.classic && stats.mech.rowBack === "button"
                            family: stats.mech.rowPlate; px: 2   // the UI's plate scale, as YouTube's rows
                            hot: rowItem.selected
                            anchors.left: chev.right; anchors.leftMargin: stats.mech.chevron === "none" ? 0 : -Math.round(4 * stats.s)
                            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                            // ASSEMBLY-RESIZABLE: plate fills 90% of its row slot by default (the
                            // other 10% is the inter-row gap); scale it via mScale("rowbox") toward
                            // 1.0 to close the gap entirely, or past it to overlap.
                            height: Math.round(rows.rowH * 0.90 * stats.mScale("rowbox"))
                            // ROW BOX move — the backing layers below anchors.fill this plate, so
                            // they each carry the SAME translate to stay aligned with the shift.
                            transform: Translate { x: stats.mOff("rowbox")[0]; y: stats.mOff("rowbox")[1] }
                        }
                        MechPanel {   // ROW BACK = a MechPanel kind instead of the button
                            visible: !stats.classic && stats.mech.rowBack !== "button"
                            anchors.fill: btn; px: stats.mpx
                            kind: stats.mech.rowBack
                            transform: Translate { x: stats.mOff("rowbox")[0]; y: stats.mOff("rowbox")[1] }
                        }
                        Rectangle {   // ROW INK wash (steel = neutral/off)
                            visible: !stats.classic && stats.mech.rowInk !== "steel"
                            anchors.fill: btn; color: stats.ink(stats.mech.rowInk); opacity: 0.12
                            transform: Translate { x: stats.mOff("rowbox")[0]; y: stats.mOff("rowbox")[1] }
                        }
                        Rectangle {   // classic flat rail
                            visible: stats.classic
                            anchors.fill: btn
                            color: "#141a22"; border.width: Math.max(1, stats.s); border.color: Theme.withAlpha(stats.steelInk, 0.18)
                            transform: Translate { x: stats.mOff("rowbox")[0]; y: stats.mOff("rowbox")[1] }
                        }
                        MechPanel {   // TITLE BACKING (dial: titleBack) — a plate behind the row title, snug to the text
                            visible: !stats.classic && stats.mech.titleBack !== undefined && stats.mech.titleBack !== "none"
                            anchors.left: title.left; anchors.leftMargin: -Math.round(8 * stats.s)
                            anchors.verticalCenter: title.verticalCenter
                            width: Math.min(title.contentWidth, title.width) + Math.round(16 * stats.s)
                            height: title.contentHeight + Math.round(6 * stats.s)
                            px: stats.mpx
                            kind: stats.mech.titleBack === "chip" ? "chip" : stats.mech.titleBack === "hollow" ? "hollow" : stats.mech.titleBack === "body" ? "body" : "frame"
                        }
                        Text {
                            id: title
                            anchors.left: btn.left; anchors.leftMargin: Math.round(15 * stats.s)
                            anchors.verticalCenter: btn.verticalCenter
                            transform: Translate { x: stats.mOff("rtitle")[0]; y: stats.mOff("rtitle")[1] + rowItem.hopY }
                            // CRT: title takes only the width it needs (up to a cap) so the BAR
                            // fills the rest — short titles → long bars; long titles elide to "…".
                            // Bars vary per row, so scrolling the selection makes them breathe.
                            // DP-3 keeps a uniform fixed title column (plenty of bar room there).
                            width: stats.isCrt ? Math.min(implicitWidth, Math.round(168 * stats.s)) : Math.round(150 * stats.s)
                            text: rowItem.sd ? stats.caseFor(rowItem.sd.show, stats.mech.titleCase) : ""; color: stats.ink(stats.mech.titleInk)
                            style: stats.shadowStyleFor(stats.mech.titleShadow); styleColor: stats.shadowInk
                            font.family: stats.mechFontFor(stats.mech.titleFont); font.pixelSize: stats.pxi(Math.round(stats.mSz(13, stats.mech.titleSize) * stats.mScale("rtitle")))
                            font.weight: stats.weightFor(stats.mech.titleWeight); font.letterSpacing: stats.trackFor(stats.mech.titleTrack)
                            elide: Text.ElideRight
                            opacity: rowItem.textDim
                            Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutQuad } }
                        }
                        MechPanel {   // % BACKING (dial: pctBack) — a plate behind the percentage
                            visible: !stats.classic && stats.mech.pctBack !== undefined && stats.mech.pctBack !== "none"
                            anchors.centerIn: pct
                            width: pct.width + Math.round(10 * stats.s); height: pct.contentHeight + Math.round(6 * stats.s)
                            px: stats.mpx
                            kind: stats.mech.pctBack === "chip" ? "chip" : stats.mech.pctBack === "hollow" ? "hollow" : stats.mech.pctBack === "body" ? "body" : "frame"
                        }
                        Text {
                            id: pct
                            anchors.right: btn.right; anchors.rightMargin: Math.round(14 * stats.s)
                            anchors.verticalCenter: btn.verticalCenter
                            transform: Translate { x: stats.mOff("rpct")[0]; y: stats.mOff("rpct")[1] + rowItem.hopY }
                            property int scr: -1   // >=0 while scrambling; -1 = show the real %
                            // shows: % watched (matches the hero WATCHED %); movies: ×N times watched.
                            // both scramble on select (scr>=0) before settling on the real value.
                            // movies: scramble stays the SAME digit-width as the real count so the
                            // right-aligned "×N" never reflows (a wider flicker made the × jump).
                            text: rowItem.isMovie ? "×" + (scr >= 0 ? ((rowItem.sd.count || 0) >= 10 ? (10 + scr % 90) : (1 + scr % 9))
                                                                    : (rowItem.sd.count || 0))
                                                  : (scr >= 0 ? scr : Math.round(rowItem.frac * 100)) + "%"
                            // full-bright when selected (match the title) or complete; else the dim %
                            color: (rowItem.selected || rowItem.frac >= 1) ? stats.ink(stats.mech.pctInk) : Theme.withAlpha(stats.ink(stats.mech.pctInk), 0.75)
                            style: stats.shadowStyleFor(stats.mech.pctShadow); styleColor: stats.shadowInk
                            font.family: stats.mechFontFor(stats.mech.pctFont); font.weight: stats.weightFor(stats.mech.pctWeight); font.pixelSize: stats.pxi(Math.round(stats.mSz(12, stats.mech.pctSize) * stats.mScale("rpct"))); font.letterSpacing: stats.trackFor(stats.mech.pctTrack)
                            width: Math.round(42 * stats.s); horizontalAlignment: Text.AlignRight
                            opacity: rowItem.textDim
                            Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutQuad } }
                            Timer { id: scramble; interval: 38; repeat: true; property int ticks: 0
                                onRunningChanged: if (running) ticks = 0
                                onTriggered: { ticks++; if (ticks >= 8) { stop(); pct.scr = -1 } else pct.scr = (ticks * 41 + rowItem.index * 17 + 13) % 100 } }
                        }
                        Rectangle {   // BAR GLOW — accent halo behind the meter
                            visible: stats.mech.barGlow === "on"
                            anchors.left: title.right; anchors.leftMargin: Math.round(8 * stats.s); anchors.right: pct.left; anchors.rightMargin: Math.round(8 * stats.s)
                            anchors.verticalCenter: btn.verticalCenter; height: Math.round(rows.rowH * 0.55)
                            color: Theme.withAlpha(stats.accent, 0.16); radius: height / 2
                        }
                        MechPanel {   // BAR BACK — a plate behind the meter (panel kinds only; "outline" is drawn by the bar itself)
                            visible: stats.mech.barBack !== "none" && stats.mech.barBack !== "outline" && !stats.classic
                            anchors.left: title.right; anchors.leftMargin: Math.round(10 * stats.s)
                            anchors.right: pct.left; anchors.rightMargin: Math.round(10 * stats.s)
                            anchors.verticalCenter: btn.verticalCenter
                            height: Math.max(Math.round(rows.rowH * 0.5), Math.round(10 * stats.s))
                            px: stats.mpx; kind: stats.mech.barBack
                        }
                        MechBar {
                            id: mbar
                            anchors.left: title.right; anchors.leftMargin: Math.round(14 * stats.s)
                            anchors.right: pct.left; anchors.rightMargin: Math.round(14 * stats.s)
                            anchors.verticalCenter: btn.verticalCenter
                            // ASSEMBLY-RESIZABLE: the bar's height is 8·px, so scaling px (crisp,
                            // integer — no blur) resizes the bar in the assembly menu via mScale("rbar").
                            // frame + fill both ride this px so they stay in sync at any size.
                            px: Math.max(2, Math.round(stats.mpx * stats.mScale("rbar"))); style: stats.mech.bar
                            // BAR DEAD SPACE = the speedo shade (recoloured in the asset)
                            darkTrack: !stats.classic && stats.mech.barBack === "outline"
                            outline: (!stats.classic && stats.mech.barBack === "outline") ? "#a6b1c7" : "transparent"
                            property real wob: 1
                            value: rowItem.frac * stats.eBars * mbar.wob   // wob breathes the FILL on selection (contents move, not the bar)
                            maxWidth: Math.max(Math.round(60 * stats.s), width)
                            transform: Translate { x: stats.mOff("rbar")[0]; y: stats.mOff("rbar")[1] + rowItem.hopY }
                            SequentialAnimation { id: barBounce   // WOBBLE: swell → ease back
                                NumberAnimation { target: mbar; property: "wob"; to: 1.14; duration: 130; easing.type: Easing.OutQuad }
                                NumberAnimation { target: mbar; property: "wob"; to: 0.93; duration: 190; easing.type: Easing.InOutSine }
                                NumberAnimation { target: mbar; property: "wob"; to: 1;    duration: 280; easing.type: Easing.OutBack }
                            }
                            SequentialAnimation { id: barPulse   // PULSE: one clean swell
                                NumberAnimation { target: mbar; property: "wob"; to: 1.28; duration: 120; easing.type: Easing.OutQuad }
                                NumberAnimation { target: mbar; property: "wob"; to: 1;    duration: 320; easing.type: Easing.OutBack }
                            }
                            SequentialAnimation { id: barSurge   // SURGE: big overshoot, double-settle
                                NumberAnimation { target: mbar; property: "wob"; to: 1.45; duration: 90;  easing.type: Easing.OutQuad }
                                NumberAnimation { target: mbar; property: "wob"; to: 0.8;  duration: 130; easing.type: Easing.InOutSine }
                                NumberAnimation { target: mbar; property: "wob"; to: 1.08; duration: 160; easing.type: Easing.InOutSine }
                                NumberAnimation { target: mbar; property: "wob"; to: 1;    duration: 220; easing.type: Easing.OutBack }
                            }
                            function playSel() {
                                var st = stats.mech.barSel
                                if (st === "none") return
                                if (st === "pulse") barPulse.restart()
                                else if (st === "surge") barSurge.restart()
                                else barBounce.restart()   // wobble (default)
                            }
                        }
                    }
                }
            }

                // FREE ROW PATCH — a standalone 1×3 chip in the card-bed color (#181c23), fully
                // movable / scalable / lockable in ASSEMBLY (key "spatch"). It lives OUTSIDE the row
                // delegates, so it never rides the row hop / press / bar animations — hand-stick it
                // over any residual seam. Default sits at the rows' top-left; drag it into place.
                Rectangle {
                    id: spatchEl
                    visible: !stats.classic
                    readonly property real psc: stats.mpx * stats.mScale("spatch")
                    width: Math.max(1, Math.round(1 * psc))
                    height: Math.max(1, Math.round(3 * psc))
                    x: rows.x + stats.mOff("spatch")[0]
                    y: Math.round(44 * stats.s) + stats.mOff("spatch")[1]
                    color: "#181c23"
                    z: 60
                }

                // your animated edge glint — travels at the reveal front
                Item {
                    id: edgeSprite
                    visible: stats.mech.edgeGlint === "on" && stats.mech.hero === "cockpit" && !stats.classic
                    anchors.right: parent.right; anchors.top: parent.top
                    width: 8 * stats.mpx; height: hero.height
                    clip: true
                    transform: Translate { x: stats.mOff("edge")[0]; y: stats.mOff("edge")[1] }   // EDGE GLINT move
                    opacity: stats.eBox * (stats.eReveal < 0.85 ? 1 : Math.max(0, (1 - stats.eReveal) / 0.15))
                    property int frame: 0
                    Timer {
                        interval: stats.mech.edgeSpeed === "slow" ? 160 : stats.mech.edgeSpeed === "fast" ? 60 : 100
                        repeat: true; running: edgeSprite.visible && stats.visible
                        onTriggered: edgeSprite.frame = (edgeSprite.frame + 1) % 6
                    }
                    Image {
                        source: (App.heroDevRev, stats.devSrc("edge-slide")); smooth: false
                        width: 8 * 6 * stats.mpx; height: hero.height
                        x: -edgeSprite.frame * 8 * stats.mpx
                    }
                }
            }
            // hand-drawn DEPLOY animation (DEPLOY dial = "sprite"): plays the
            // fx/card-deploy.png strip over the whole card as it opens — one strip
            // frame per deploy step (eReveal) — then hands off to the live card.
            // Fully Aseprite-authored + hot-reloading. Edit the strip, watch it change.
            Image {
                id: deploySprite
                visible: stats.mech.heroReveal === "sprite" && !stats.classic && stats.eReveal < 0.999
                anchors.fill: parent
                z: 60
                smooth: false
                fillMode: Image.Stretch
                readonly property int frameCount: 8            // MUST match the strip's frame count
                readonly property int frameW: 176              // MUST match one frame's pixel width
                readonly property int frame: Math.min(frameCount - 1, Math.max(0, Math.round(stats.eReveal * (frameCount - 1))))
                sourceClipRect: Qt.rect(frame * frameW, 0, frameW, 64)
                source: (App.heroDevRev, App.heroDevPath("fx/card-deploy") !== "" ? App.heroDevPath("fx/card-deploy") + "?v=" + App.heroDevRev : "qrc:/assets/mechui/fx/card-deploy.png")
                cache: App.heroDevPath("fx/card-deploy") === ""
            }
        }

        // ── POSTER DOSSIER (most-watched) — exact 2:3, NEVER cropped ─────────
        Item {
            id: poster
            width: heroMode ? heroPW : cockpit.posterW
            height: heroMode ? heroPH : cockpit.height
            anchors.right: parent.right
            // centre the (integer-scaled) hero tile in its reserved column instead of
            // jamming it to the right edge → pulls it left, balanced margins both sides
            anchors.rightMargin: heroMode ? Math.round((cockpit.posterW - heroPW) / 2) : 0
            // top-align to the card's top line (cockpit top + cardTop); the hero is sized to
            // span from there to the graph line (see cockpit.heroK), so the tops line up.
            // HERO Y (all displays) + HERO Y·CRT (CRT only): shift the whole hero
            // (poster + plate + cables) up/down. heroY applies on EVERY display — it's
            // per-device config (statsUiSel), so it can be dialled on the laptop's
            // eDP-1 without any effect on the desktop; heroCrtY still stacks on the CRT.
            anchors.top: parent.top; anchors.topMargin: cockpit.cardTop
                + Math.round((stats.mech.heroY || 0) * stats.s)
                + (stats.isCrt ? Math.round((stats.mech.heroCrtY || 0) * stats.s) : 0)
            opacity: stats.ePoster                           // phase 3: poster reveals (POSTER ANIM dial)
            readonly property string pa: stats.mech.posterAnim
            transform: [
                Rotation { origin.x: poster.width / 2; origin.y: poster.height / 2
                    angle: poster.pa === "swing" ? (1 - stats.ePoster) * -9 : 0 },
                Translate {
                    x: (poster.pa === "slide" ? (1 - stats.ePoster) * Math.round(44 * stats.s) : 0) + stats.mOff("poster")[0]
                    y: (poster.pa === "rise" ? (1 - stats.ePoster) * Math.round(18 * stats.s)
                      : poster.pa === "drop" ? (1 - stats.ePoster) * Math.round(-18 * stats.s) : 0) + stats.mOff("poster")[1]
                },
                Scale {
                    origin.x: poster.width / 2; origin.y: poster.pa === "iris" ? poster.height / 2 : 0
                    xScale: poster.pa === "scale" ? 0.82 + 0.18 * stats.ePoster : poster.pa === "iris" ? 0.4 + 0.6 * stats.ePoster : 1
                    yScale: poster.pa === "scale" ? 0.82 + 0.18 * stats.ePoster : poster.pa === "iris" ? 0.4 + 0.6 * stats.ePoster
                          : poster.pa === "unfold" ? 0.15 + 0.85 * stats.ePoster : 1
                }
            ]

            // The hero DOSSIER FOLLOWS THE SPINE: art, title and progress track the deepest
            // row you've selected with j/k (or hover) — the selector drives the hero.
            readonly property var topShow: stats.shows.length > 0
                ? stats.shows[Math.min(Math.max(0, rows.selRow), stats.shows.length - 1)] : null
            readonly property string artSrc: topShow ? (topShow.poster ? Theme.art(topShow.poster)
                                                        : topShow.fanart ? Theme.art(topShow.fanart)
                                                        : topShow.clearlogo ? Theme.art(topShow.clearlogo) : "") : ""
            // movie hero shows current-session progress; show hero shows episode completion
            readonly property real frac: topShow ? (topShow.kind === "movie" ? (topShow.pct || 0) : topShow.done / Math.max(1, topShow.total)) : 0
            readonly property real margin: Math.round(28 * stats.s)
            readonly property real headerH: Math.round(30 * stats.s)
            readonly property bool showPlate: stats.mech.posterTitle === "plate"
            readonly property real plateH: showPlate ? Math.round(54 * stats.s) : 0
            readonly property real innerW: width - margin * 2
            // fit the poster to whichever of width / remaining-height binds → exact
            // 2:3; reserve only header + plate + a little so it fills the column
            readonly property real availH: height - headerH - plateH - Math.round(24 * stats.s) - (showPlate ? Math.round(12 * stats.s) : 0)
            readonly property real holeW: Math.max(1, Math.min(innerW, availH / 1.5))
            readonly property real holeH: holeW * 1.5
            // ── HERO-TILE MODE ─────────────────────────────────────────────
            // The dedicated poster frame (posterBg "hero") bakes the header capsule,
            // the nameplate bar and the side rails into the tile itself, so the poster
            // fills the tile's transparent interior edge-to-edge and the two text blocks
            // seat in the fixed top/bottom 9-patch border zones (16/16/18/22 tile px).
            readonly property bool heroMode: stats.mech.posterBg === "hero" && !stats.classic
            // PIXEL-PERFECT hero: the tile is 80x160 hand-drawn 8-bit art. Render it at the
            // LARGEST INTEGER scale that fits the panel — no 9-patch middle-stretch, so the
            // art is never distorted — and drive every hero inset off that same scale. The
            // panel becomes the tile's exact integer-scaled size (letterboxed in its column).
            // HERO SIZE dial: "fit" = largest integer scale that fits the panel column;
            // "big" = +1 step; "max" = largest that fits the whole screen (accentuates the
            // poster). Always an INTEGER scale → the 8-bit art is never stretched.
            readonly property int heroFitK: Math.max(2, Math.min(Math.floor(cockpit.posterW / 80), Math.floor(cockpit.height / 160)))
            readonly property int heroMaxK: Math.max(heroFitK, Math.min(
                Math.floor((stats.height - Math.round(24 * stats.s)) / 160),
                Math.floor((cockpit.posterW + cockpit.gap) / 80)))
            // WHOLE-number pixel scale (floor of the continuous fill factor) — pixel art must
            // render on an integer grid or the right/bottom edges drop a sub-pixel sliver and the
            // 9-slice corners (bezel hinges, nameplate bars) stop mirroring. The tile then snaps
            // to the nearest whole step and CENTRES in its reserved column (see below) with a
            // small even margin — the layout already expects the "integer-scaled hero tile".
            readonly property real heroScale: Math.max(2, Math.floor(cockpit.heroK + 0.12))   // +0.12: hold the same integer step as fullscreen near a threshold (see mpx)
            // ROUND to whole pixels so the CRT-shader layer FBO composites 1:1 with the
            // screen (a fractional size resamples the RGB mask → rainbow banding).
            readonly property real heroPW: Math.round(80 * heroScale)
            readonly property real heroPH: Math.round(160 * heroScale)
            readonly property real hpx: heroMode ? heroScale : stats.mpx
            // insets = the tile's measured transparent-hole borders (x13/x66, y28/y124),
            // rendered at hpx. At this integer scale each edge lands 1:1 with the art.
            // BAKED BIG-POSTER LAYOUT: hole 76x114 (2:3) near the top, 42px nameplate zone.
            readonly property real hSideZ: 2 * hpx     // thin L/R rail — poster is near-full-width
            readonly property real hTopZ:  2 * hpx     // matches the hand-drawn hole top (y2)
            readonly property real hBotZ:  44 * hpx    // nameplate zone; poster hole = 160-2-44 = 114 tall (matches drawn hole y2..115)
            readonly property real heroCellW: width - hSideZ * 2
            readonly property real heroCellH: height - hTopZ - hBotZ
            // seam bleed: the poster's bottom edge sits one seam-row above a faint bright
            // rule at the hole/nameplate boundary (visible on dark art). Extend the poster
            // hole + image DOWN by ~1.5 art-px so the poster covers it — a <1.5% stretch,
            // imperceptible on a ~900px-tall poster. Hero only.
            readonly property int heroSeamBleed: heroMode ? Math.max(2, Math.round(hpx * 1.5)) : 0
            // non-hero centred-column metrics (posterCell + nameplate) — replaces the
            // Column wrapper so both layouts position from explicit y
            readonly property real colSpace: Math.round(14 * stats.s)
            readonly property real colCellH: holeH * stats.mScale("phole")
            readonly property real colTotalH: colCellH + (showPlate ? colSpace + plateH : 0)
            readonly property real colTopY: (height - colTotalH) / 2 + Math.round(7 * stats.s)

            Rectangle {   // POSTER SHADOW — a drop shadow behind the dossier
                visible: stats.mech.posterShadow === "on"
                anchors.fill: parent; anchors.topMargin: Math.round(7 * stats.s); anchors.leftMargin: Math.round(6 * stats.s)
                color: "#000000"; opacity: 0.4; radius: Math.round(4 * stats.s)
            }
            Rectangle {   // POSTER GLOW — an accent halo behind the dossier
                visible: stats.mech.posterGlow === "on"
                anchors.fill: parent; anchors.margins: -Math.round(5 * stats.s)
                color: "transparent"; border.width: Math.round(4 * stats.s); border.color: Theme.withAlpha(stats.accent, 0.3); radius: Math.round(6 * stats.s)
            }
            // backing plate + bezel (POSTER FRAME dial · classic flat)
            MechPanel { visible: stats.mech.poster !== "none" && !stats.classic; anchors.fill: parent; px: poster.hpx; kind: stats.mech.posterBg; dev: poster.heroMode }
            Rectangle { visible: stats.classic; anchors.fill: parent; color: "#111721"; border.width: Math.max(1, stats.s); border.color: Theme.withAlpha(stats.steelInk, 0.22) }
            MechPanel {
                id: posterFrameEl
                visible: stats.mech.poster === "frame" && stats.mech.posterFrame !== "none" && !stats.classic
                dev: poster.heroMode
                anchors.fill: parent; anchors.margins: Math.round(16 * stats.s / stats.mScale("pframe")); px: stats.mpx; kind: stats.mech.posterFrame
                transform: Translate { x: stats.mOff("pframe")[0]; y: stats.mOff("pframe")[1] }
            }
            // ── SEPARATE PILL + NAMEPLATE BOX (hero) ─────────────────────────────
            // Extracted out of the tile so each moves + scales INDEPENDENTLY. Rendered
            // pixel-perfect (nearest-neighbour, INTEGER pixel scale) at the same hpx as the
            // frame, seated where they were baked → identical by default, movable in assembly.
            // hero PILL — "drawn" hand-made asset OR a 9-sliced button plate (b1..b5)
            // OR "none". All share the SAME 57x20-tile footprint + move/scale key "ppill".
            Image {
                id: heroPill                                     // key "ppill" — art 57x20 at tile (11,2)
                visible: poster.heroMode && !stats.classic && (stats.mech.heroRankPos || "below") === "top" && (stats.mech.ppillPlate || "drawn") === "drawn"
                readonly property string _dev: (App.heroDevRev, App.heroDevPath("hero/hero-pill"))
                source: _dev !== "" ? _dev + "?v=" + App.heroDevRev : "qrc:/assets/mechui/hero/hero-pill.png"
                cache: _dev === ""; smooth: false; mipmap: false
                readonly property int psc: Math.max(1, Math.round(poster.hpx * stats.mScale("ppill")))
                width: 57 * psc; height: 20 * psc
                x: Math.round((11 + 57 / 2) * poster.hpx - width / 2)
                y: Math.round((2 + 20 / 2) * poster.hpx - height / 2)
                transform: Translate { x: stats.mOff("ppill")[0]; y: stats.mOff("ppill")[1] }
            }
            MechButton {
                id: heroPillPlate
                visible: poster.heroMode && !stats.classic && (stats.mech.heroRankPos || "below") === "top" && (stats.mech.ppillPlate || "drawn").charAt(0) === "b"
                dev: true
                px: poster.hpx
                family: { var v = stats.mech.ppillPlate; return (v && v.length === 2) ? parseInt(v.charAt(1)) : 3 }
                width: Math.round(57 * poster.hpx * stats.mScale("ppill"))
                height: Math.round(20 * poster.hpx * stats.mScale("ppill"))
                x: Math.round((11 + 57 / 2) * poster.hpx - width / 2)
                y: Math.round((2 + 20 / 2) * poster.hpx - height / 2)
                transform: Translate { x: stats.mOff("ppill")[0]; y: stats.mOff("ppill")[1] }
            }
            MechSlice {          // Pixel-UI-pack framed banner (p1..p3), 48x22 9-slice
                id: heroPillBand
                visible: poster.heroMode && !stats.classic && (stats.mech.heroRankPos || "below") === "top" && (stats.mech.ppillPlate || "drawn").charAt(0) === "p"
                dev: true
                source: (App.heroDevRev, (stats.mech.ppillPlate || "").charAt(0) === "p" ? stats.devSrc("hero/hero-band-" + stats.mech.ppillPlate.charAt(1)) : "")
                px: poster.hpx; artL: 10; artR: 10; artT: 9; artB: 9
                width: Math.round(57 * poster.hpx * stats.mScale("ppill"))
                height: Math.round(20 * poster.hpx * stats.mScale("ppill"))
                x: Math.round((11 + 57 / 2) * poster.hpx - width / 2)
                y: Math.round((2 + 20 / 2) * poster.hpx - height / 2)
                transform: Translate { x: stats.mOff("ppill")[0]; y: stats.mOff("ppill")[1] }
            }
            // hero NAMEPLATE BOX — 9-slice so it stretches WIDE (to the poster edges)
            // with crisp rounded ends, no vertical growth. Width tracks the poster's
            // rendered width (heroCellW × phole) so the bar always spans the same edges;
            // npbox scale fine-tunes. Height stays 29. move/scale key "npbox".
            // integer pixel-scale JUST for the pixel-art nameplate so its side bars land on
            // WHOLE pixels — crisp + symmetric — even though the hero/poster scales continuously
            // (the poster is a photo, fine at any scale; the nameplate is pixel art, needs whole steps).
            readonly property int  npx: Math.max(2, Math.round(poster.hpx))
            // width = an EXACT even multiple of npx (K·npx, K even). This is the key to symmetry:
            // the 9-slice then loses NO sub-pixel remainder on the right edge, so the right corner
            // mirrors the left exactly, and the whole plate renders 1:1 crisp. K≈80 (the authored
            // art width) so it still tracks the poster, just snapped to whole pixel-steps.
            readonly property real npboxW: poster.npx * 2 * Math.round(40 * stats.mScale("npbox"))
            // box height wraps the text (9-slice keeps the outline/corners crisp — only the
            // flat interior tiles; NOT distortion). Draw a taller box asset for less growth.
            readonly property real npboxH: Math.round((npColBase.implicitHeight + 26 * poster.hpx) * stats.mScale("npbox"))
            // FIT-TO-BOX: the box is a FIXED size (npColBase = scale-free stable reference, above);
            // the real text block shrinks uniformly to fit inside it so it NEVER clips. The DIVISOR is
            // npColFit — the unshrunk block height WITH your assembly scales + actual line count — so
            // the scaled text (rank 1.6×, etc.) is accounted for. realHeight = fit·npColFit exactly, so
            // fit = interior / npColFit fills the box precisely. Neither mirror uses npContentFit → no
            // feedback loop. 1.0 when it already fits; floored so it can't go illegibly tiny.
            readonly property real npContentFit: Math.max(0.4, Math.min(1, (npboxH - Math.round(12 * poster.hpx)) / Math.max(1, npColFit.implicitHeight)))
            readonly property int  npboxX: Math.round(40 * poster.hpx - poster.npboxW / 2)         // centre on the tile/poster
            readonly property int  npboxY: Math.round(poster.height - poster.npboxH - 3 * poster.hpx)  // bottom-aligned, grows UP over the poster's bottom edge
            MechSlice {
                id: heroNamebox                                  // key "npbox" — hand-drawn plate, 9-sliced
                readonly property string np: stats.mech.npboxPlate || "drawn"
                // two hand-drawn plates: "drawn" = the poster-matched one (flat middle 12..67);
                // "alt" = the earlier chamfered one (flat middle 6..73)
                visible: poster.heroMode && !stats.classic && (np === "drawn" || np === "alt")
                dev: true   // hot-reload from assets/mechui (see MechSlice.dev)
                source: (App.heroDevRev, np === "alt" ? stats.devSrc("hero/hero-nameplate-alt") : stats.devSrc("hero/hero-nameplate"))
                px: poster.npx; artL: np === "alt" ? 6 : 12; artR: np === "alt" ? 6 : 12; artT: 10; artB: 10   // integer px → crisp symmetric bars
                width: poster.npboxW; height: poster.npboxH; x: poster.npboxX; y: poster.npboxY
                transform: Translate { x: stats.mOff("npbox")[0]; y: stats.mOff("npbox")[1] }
            }
            MechButton {
                id: heroNameboxPlate
                visible: poster.heroMode && !stats.classic && (stats.mech.npboxPlate || "drawn").charAt(0) === "b"
                dev: true
                px: poster.npx
                family: { var v = stats.mech.npboxPlate; return (v && v.length === 2) ? parseInt(v.charAt(1)) : 3 }
                width: poster.npboxW; height: poster.npboxH; x: poster.npboxX; y: poster.npboxY
                transform: Translate { x: stats.mOff("npbox")[0]; y: stats.mOff("npbox")[1] }
            }
            MechSlice {          // Pixel-UI-pack framed banner (p1..p3), 48x22 9-slice
                id: heroNameboxBand
                visible: poster.heroMode && !stats.classic && (stats.mech.npboxPlate || "drawn").charAt(0) === "p"
                dev: true
                source: (App.heroDevRev, (stats.mech.npboxPlate || "").charAt(0) === "p" ? stats.devSrc("hero/hero-band-" + stats.mech.npboxPlate.charAt(1)) : "")
                px: poster.npx; artL: 10; artR: 10; artT: 9; artB: 9
                width: poster.npboxW; height: poster.npboxH; x: poster.npboxX; y: poster.npboxY
                transform: Translate { x: stats.mOff("npbox")[0]; y: stats.mOff("npbox")[1] }
            }

            // MOST WATCHED / RANK header backing — button-plate options (b1..b5)
            // + chip / frame; sits behind the header text and tracks its box.
            MechButton {
                visible: posterHdr.visible && !stats.classic && (stats.mech.posterHdrBack || "none").charAt(0) === "b"
                anchors.centerIn: posterHdr
                transform: Translate { x: stats.mOff("phdr")[0]; y: stats.mOff("phdr")[1] }   // follow POSTER HEAD move
                width: posterHdr.width + Math.round(26 * stats.s); height: posterHdr.height + Math.round(12 * stats.s)
                px: stats.mpx
                family: { var v = stats.mech.posterHdrBack; return (v && v.length === 2) ? parseInt(v.charAt(1)) : 3 }
            }
            MechPanel {
                visible: posterHdr.visible && !stats.classic && (stats.mech.posterHdrBack === "chip" || stats.mech.posterHdrBack === "frame" || stats.mech.posterHdrBack === "capsule")
                anchors.centerIn: posterHdr
                transform: Translate { x: stats.mOff("phdr")[0]; y: stats.mOff("phdr")[1] }   // follow POSTER HEAD move
                // equal padding around the text at ANY length (capsule hugs the text)
                width: posterHdr.width + Math.round(24 * stats.s); height: posterHdr.height + Math.round(14 * stats.s)
                px: stats.mpx; kind: stats.mech.posterHdrBack
            }
            // MOST WATCHED header — own ink/size/font, movable, lockable
            Text {
                id: posterHdr
                // hidden in hero mode when RANK has moved down to the nameplate
                visible: !(poster.heroMode && (stats.mech.heroRankPos || "below") === "below") && stats.shows.length > 0
                anchors.horizontalCenter: parent.horizontalCenter; anchors.top: parent.top
                anchors.topMargin: poster.heroMode ? Math.round((poster.hTopZ - height) / 2) : Math.round(9 * stats.s)
                // +1: nudge the text 1px DOWN inside the capsule (box keeps its own transform)
                transform: Translate { x: stats.mOff("phdr")[0]; y: stats.mOff("phdr")[1] + 1 }
                // instrument glow (WELL GLOW) + white rank number to accentuate it
                layer.enabled: !stats.classic && (stats.wellGlowN[stats.mech.wellGlow] || 0) > 0
                layer.effect: ShaderEffect {
                    readonly property size res: Qt.size(Math.max(2, posterHdr.width), Math.max(2, posterHdr.height))
                    readonly property real radius: 2.5
                    readonly property real intensity: stats.wellGlowN[stats.mech.wellGlow] || 0
                    fragmentShader: "qrc:/qml/shaders/neonglow.frag.qsb"
                }
                textFormat: Text.StyledText
                // always RANK N (RANK 1 for the top item) — short, fits the pill
                text: stats.caseFor("RANK ", stats.mech.posterHdrCase) + "<font color=\"#f2f8fc\">" + (rows.selRow + 1) + "</font>"
                color: stats.classic ? Theme.withAlpha(stats.steelInk, 0.75) : stats.ink(stats.mech.posterHdrInk)
                font.family: stats.mechFontFor(stats.mech.posterHdrFont); font.weight: stats.weightFor(stats.mech.posterHdrWeight)
                font.pixelSize: stats.pxi(Math.round(stats.mSz(10, stats.mech.posterHdrSize) * stats.mScale("phdr"))); font.letterSpacing: stats.trackFor(stats.mech.posterHdrTrack)
            }

            // dossier: poster hole + nameplate. Non-hero = centred column metrics;
            // hero = fill the tile interior (cell) + seat the nameplate in the bar.
            Item {   // wrapper keeps the two as direct children of `poster`
                anchors.fill: parent

                // the poster cell — 2:3 (non-hero) or interior-fill (hero), with the CRT pass
                Item {
                    id: posterCell
                    // POSTER ART scale (phole) now applies in hero mode too, centred in the hole.
                    width: (poster.heroMode ? poster.heroCellW : poster.holeW) * stats.mScale("phole")
                    height: (poster.heroMode ? poster.heroCellH : poster.holeH) * stats.mScale("phole")
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: poster.heroMode ? (poster.hTopZ + (poster.heroCellH - height) / 2) : poster.colTopY
                    transform: Translate { x: stats.mOff("phole")[0]; y: stats.mOff("phole")[1] }

                    // the raw screen content (hidden + fed to the CRT pass when on)
                    Item {
                        id: posterHole
                        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                        height: parent.height + poster.heroSeamBleed   // extend DOWN over the seam line
                        clip: true
                        // ── RetroArch-style CRT SHADER pass (heroCrt dial) — replaces the tacky scanline ──
                        layer.enabled: !stats.classic && stats.mech.heroCrt !== "off"
                        layer.effect: ShaderEffect {
                            readonly property size res: Qt.size(Math.max(2, posterHole.width), Math.max(2, posterHole.height))
                            readonly property real preset: ({ "crt-geom": 1, "lottes": 2, "aperture": 3, "shadow": 4, "slot": 5 }[stats.mech.heroCrt] || 1)
                            readonly property real curv: 0.0   // FLAT tube — no barrel warp (scanlines / mask / glow stay)
                            readonly property real scanStr: stats.mech.heroCrt === "lottes" ? 0.5 : 0.32
                            readonly property real maskStr: (stats.mech.heroCrt === "aperture" || stats.mech.heroCrt === "shadow" || stats.mech.heroCrt === "slot") ? 0.55 : 0.0
                            readonly property real glow: stats.mech.heroCrt === "lottes" ? 0.28 : 0.12
                            fragmentShader: "qrc:/qml/shaders/herocrt.frag.qsb"
                        }
                        Rectangle {
                            anchors.fill: parent
                            gradient: Gradient {
                                GradientStop { position: 0.0; color: "#223247" }
                                GradientStop { position: 1.0; color: "#0b1017" }
                            }
                        }
                        Image {
                            id: posterImg
                            anchors.fill: parent; smooth: true; asynchronous: false; cache: true
                            // Decode at ~display resolution (1.5× headroom keeps it crisp)
                            // instead of the poster's full native ~1000×1500 — big texture-
                            // memory + decode win, visually identical at this display scale.
                            sourceSize.width: Math.round(width * 1.5)
                            // FIT = whole poster, zero crop (tiny matte bars where the
                            // interior isn't exactly 2:3); FILL = crop to the dark edge.
                            // The FIT dial controls it in hero mode too now.
                            // hero+fit → Stretch so the poster fills the seam-bleed-extended
                            // hole (covers the faint boundary rule); the extra stretch is <1.5%.
                            fillMode: stats.mech.posterFit === "fit" ? (poster.heroMode ? Image.Stretch : Image.PreserveAspectFit)
                                    : stats.mech.posterFit === "stretch" ? Image.Stretch
                                    : Image.PreserveAspectCrop
                            source: poster.artSrc
                        }
                        Rectangle {
                            visible: stats.mech.posterTint !== "none"
                            anchors.fill: parent; color: stats.accent
                            opacity: stats.mech.posterTint === "med" ? 0.15 : 0.07
                        }
                        // ── authentic CRT raster overlay (SCANLINES dial) ──────
                        Item {
                            id: scanOv
                            anchors.fill: parent
                            visible: stats.mech.posterScan !== "off" && (stats.classic || stats.mech.heroCrt === "off")   // CRT shader replaces the scanline
                            readonly property var cfg: stats.scanCfg(stats.mech.posterScan)
                            readonly property int pp: Math.max(1, Math.round(cfg.pitch * stats.s))
                            readonly property int tk: Math.max(1, Math.round(cfg.thick * stats.s))
                            readonly property int off: cfg.anim === "interlace" ? stats.scanPhase * Math.round(pp / 2) : 0
                            readonly property int cols: Math.ceil(width / pp) + 2
                            readonly property int rows: Math.ceil(height / pp) + 1
                            // horizontal / vertical lines (h · v · rgb triads)
                            Repeater {
                                model: scanOv.cfg.ori === "dot" ? 0 : Math.ceil((scanOv.cfg.ori === "v" ? scanOv.width : scanOv.height) / scanOv.pp) + 1
                                Rectangle {
                                    required property int index
                                    readonly property bool vv: scanOv.cfg.ori === "v"
                                    x: vv ? index * scanOv.pp : 0
                                    y: vv ? 0 : index * scanOv.pp + scanOv.off
                                    width: vv ? scanOv.tk : scanOv.width
                                    height: vv ? scanOv.height : scanOv.tk
                                    color: scanOv.cfg.rgb ? (index % 3 === 0 ? "#ff5050" : index % 3 === 1 ? "#50ff70" : "#5070ff") : "#000000"
                                    opacity: scanOv.cfg.depth
                                }
                            }
                            // phosphor dot / slot mask (staggered rows)
                            Repeater {
                                model: scanOv.cfg.ori === "dot" ? scanOv.cols * scanOv.rows : 0
                                Rectangle {
                                    required property int index
                                    readonly property int col: index % scanOv.cols
                                    readonly property int row: Math.floor(index / scanOv.cols)
                                    x: col * scanOv.pp + (row % 2) * Math.round(scanOv.pp / 2)
                                    y: row * scanOv.pp
                                    width: scanOv.tk; height: scanOv.tk; radius: scanOv.tk / 2
                                    color: "#000000"; opacity: scanOv.cfg.depth
                                }
                            }
                            // rolling bright retrace band
                            Rectangle {
                                visible: scanOv.cfg.anim === "roll"
                                width: parent.width; height: Math.round(28 * stats.s)
                                y: stats.scanRoll * (parent.height + height) - height
                                gradient: Gradient {
                                    GradientStop { position: 0.0; color: "transparent" }
                                    GradientStop { position: 0.5; color: Theme.withAlpha("#ffffff", 0.10) }
                                    GradientStop { position: 1.0; color: "transparent" }
                                }
                            }
                            // static-snow flicker
                            Rectangle { visible: scanOv.cfg.anim === "snow"; anchors.fill: parent; color: "#dfe8ef"; opacity: 0.03 + 0.05 * stats.scanRoll }
                            // corner vignette (curve / tube)
                            Rectangle { visible: scanOv.cfg.vig; anchors.fill: parent
                                gradient: Gradient {
                                    GradientStop { position: 0.0;  color: Theme.withAlpha("#000000", 0.36) }
                                    GradientStop { position: 0.18; color: "transparent" }
                                    GradientStop { position: 0.82; color: "transparent" }
                                    GradientStop { position: 1.0;  color: Theme.withAlpha("#000000", 0.36) } } }
                        }
                        Rectangle {   // ambient scan sweep — the pulsing accent line (HERO SWEEP dial)
                            visible: stats.ambientOn && (stats.classic || stats.mech.heroSweep !== "off")
                            width: parent.width; height: Math.max(1, Math.round(2 * stats.s))
                            y: stats.ambScan * (posterHole.height - height)
                            color: Theme.withAlpha(stats.accent, 0.3 * stats.ambientK)
                        }
                        Text {
                            id: posterFallback
                            visible: !(poster.topShow && poster.topShow.poster)
                            anchors.centerIn: parent; width: parent.width - Math.round(16 * stats.s)
                            transform: Translate { x: stats.mOff("pfall")[0]; y: stats.mOff("pfall")[1] }
                            horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
                            text: poster.topShow ? poster.topShow.show : "MOST WATCHED"
                            color: Theme.withAlpha(stats.accent, 0.7)
                            font.family: mgsCodec.name; font.pixelSize: stats.pxi(Math.round(12 * stats.s)); font.letterSpacing: 1
                        }
                    }
                    // corner brackets — crisp, above the CRT pass (BRACKETS dial)
                    Repeater {
                        model: (stats.mech.brkStyle === "l-corner" || stats.mech.brkStyle === "ticks") ? 4 : 0
                        Item {
                            required property int index
                            readonly property bool rt: index === 1 || index === 3
                            readonly property bool bt: index >= 2
                            readonly property real arm: stats.mSz(15, stats.mech.brkSize)
                            readonly property real th: Math.max(2, Math.round(2 * stats.s))
                            readonly property real inset: Math.round(5 * stats.s)
                            readonly property color bc: stats.ink(stats.mech.brkInk)
                            x: rt ? posterCell.width - arm - inset : inset
                            y: bt ? posterCell.height - arm - inset : inset
                            width: arm; height: arm
                            Rectangle { visible: stats.mech.brkStyle === "l-corner"
                                x: 0; y: parent.bt ? parent.arm - parent.th : 0; width: parent.arm; height: parent.th; color: parent.bc }
                            Rectangle { x: parent.rt ? parent.arm - parent.th : 0; y: 0; width: parent.th; height: parent.arm; color: parent.bc }
                        }
                    }
                    Rectangle {   // full-frame: closed outline
                        visible: stats.mech.brkStyle === "full-frame"
                        anchors.fill: parent; anchors.margins: Math.round(5 * stats.s)
                        color: "transparent"; border.width: Math.max(2, Math.round(2 * stats.s)); border.color: stats.ink(stats.mech.brkInk)
                    }
                    Item {   // plus: centre crosshair
                        visible: stats.mech.brkStyle === "plus"
                        anchors.centerIn: parent
                        readonly property real arm: stats.mSz(15, stats.mech.brkSize)
                        readonly property real th: Math.max(2, Math.round(2 * stats.s))
                        width: arm; height: arm
                        Rectangle { anchors.centerIn: parent; width: parent.arm; height: parent.th; color: stats.ink(stats.mech.brkInk) }
                        Rectangle { anchors.centerIn: parent; width: parent.th; height: parent.arm; color: stats.ink(stats.mech.brkInk) }
                    }
                    // crisp 1px white outline with punched (8-bit) corners. Hugs the poster
                    // by default (centred on the cell → sticks at any poster size), but is its
                    // OWN individually move+scale-able element in assembly (key "pedge").
                    Item {
                        id: posterEdgeEl
                        // auto-off when a SCREEN BEZEL is mounted (the bezel becomes the edge) —
                        // kills the redundant double-line on the poster's sides
                        visible: !stats.classic && stats.mech.posterEdge !== "off"
                                 && !(poster.heroMode && (stats.mech.heroBezel || "off") !== "off")
                        width: parent.width * stats.mScale("pedge")
                        height: parent.height * stats.mScale("pedge")
                        anchors.centerIn: parent; z: 20
                        transform: Translate { x: stats.mOff("pedge")[0]; y: stats.mOff("pedge")[1] }
                        readonly property int bw: Math.max(1, Math.round(stats.s))
                        readonly property color ec: "#a6b1c7"
                        Rectangle { x: posterEdgeEl.bw; y: 0; width: posterEdgeEl.width - posterEdgeEl.bw * 2; height: posterEdgeEl.bw; color: posterEdgeEl.ec; antialiasing: false }
                        Rectangle { x: posterEdgeEl.bw; y: posterEdgeEl.height - posterEdgeEl.bw; width: posterEdgeEl.width - posterEdgeEl.bw * 2; height: posterEdgeEl.bw; color: posterEdgeEl.ec; antialiasing: false }
                        Rectangle { x: 0; y: posterEdgeEl.bw; width: posterEdgeEl.bw; height: posterEdgeEl.height - posterEdgeEl.bw * 2; color: posterEdgeEl.ec; antialiasing: false }
                        Rectangle { x: posterEdgeEl.width - posterEdgeEl.bw; y: posterEdgeEl.bw; width: posterEdgeEl.bw; height: posterEdgeEl.height - posterEdgeEl.bw * 2; color: posterEdgeEl.ec; antialiasing: false }
                    }
                    // SCREEN BEZEL — a transparent-center 9-slice drawn OVER the poster so the
                    // poster's hard rectangular edge tucks under the frame's inner lip (poster
                    // reads as MOUNTED into the panel, not pasted on). Overlaps outward by `ov`.
                    // Own individually move+scale-able element in assembly (key "pbez").
                    // "drawn" = your own hero-bezel.png (80x118, live-editable in assets/mechui/hero/).
                    MechSlice {
                        id: heroBezelEl
                        visible: !stats.classic && poster.heroMode && (stats.mech.heroBezel || "off") === "drawn"
                        source: (App.heroDevRev, stats.devSrc("hero/hero-bezel"))
                        dev: true   // hot-reload from assets/mechui/hero/
                        px: poster.npx; artL: 10; artR: 10; artT: 10; artB: 10   // integer px → hinges mirror
                        readonly property real ov: 2 * poster.npx   // inner lip overlaps the poster edge
                        anchors.centerIn: parent
                        // DECOUPLED from POSTER ART (phole): size off the UN-phole-scaled cell
                        // (heroCellW/H, not parent.width which carries phole scale) and cancel the
                        // inherited phole translate below — so moving/scaling POSTER ART no longer
                        // drags the bezel; only its own pbez does. Width still a WHOLE multiple of
                        // npx so the 9-slice loses no right/bottom remainder (hinges stay mirrored).
                        // ⚠ EVEN multiple of npx (2·npx·round(…/2), like the nameplate at npboxW): the
                        // parent (poster) is an even 80·npx, so anchors.centerIn = (parentW-width)/2 only
                        // lands on a WHOLE pixel when width is an even multiple too. An odd multiple put
                        // the bezel on a half-pixel at odd hero scales → 0.5px off, un-nudgeable by whole
                        // steps. Even-forcing makes it dead-centre by default, no pbez nudge needed.
                        width: poster.npx * 2 * Math.round((poster.heroCellW * stats.mScale("pbez") + ov * 2) / (poster.npx * 2))
                        height: poster.npx * 2 * Math.round((poster.heroCellH * stats.mScale("pbez") + ov * 2) / (poster.npx * 2))
                        z: 25
                        transform: Translate { x: stats.mOff("pbez")[0] - stats.mOff("phole")[0]; y: stats.mOff("pbez")[1] - stats.mOff("phole")[1] }
                    }
                    // stock stand-in frames (hollow/hero) — kept as options
                    MechPanel {
                        id: heroBezelStock
                        visible: !stats.classic && poster.heroMode && ((stats.mech.heroBezel || "off") === "hollow" || (stats.mech.heroBezel || "off") === "hero")
                        kind: stats.mech.heroBezel || "hollow"
                        dev: true
                        px: poster.hpx
                        readonly property real ov: 2 * poster.hpx
                        anchors.centerIn: parent
                        width: parent.width * stats.mScale("pbez") + ov * 2
                        height: parent.height * stats.mScale("pbez") + ov * 2
                        z: 25
                        transform: Translate { x: stats.mOff("pbez")[0]; y: stats.mOff("pbez")[1] }
                    }
                    // FREE HINGE overlay elements (seam patch kit) — data-driven from stats.hingeSpecs.
                    // Each rides ABOVE everything (z 30/31) with its own move/scale/lock; elemFor()
                    // finds each by hkey via hingeRep. Draw cap art in assets/mechui/hero/hero-hinge-cap*.png.
                    Repeater {
                        id: hingeRep
                        model: stats.hingeSpecs
                        delegate: Item {
                            required property var modelData
                            readonly property string hkey: modelData.k
                            visible: poster.heroMode && !stats.classic
                            readonly property real hsc: poster.hpx * stats.mScale(hkey)
                            width: Math.max(1, Math.round(modelData.w * hsc))
                            height: Math.max(1, Math.round(modelData.h * hsc))
                            x: Math.round(modelData.dx * poster.hpx); y: Math.round(110 * poster.hpx)
                            z: modelData.z
                            // base is hpx-scaled (dx*hpx) → the NUDGE tracks hpx too (mOffHpx), so the
                            // patch holds its art-pixel seam at ANY resolution; FS (hpx=8) is identical.
                            transform: Translate { x: stats.mOffHpx(hkey, poster.hpx)[0]; y: stats.mOffHpx(hkey, poster.hpx)[1] }
                            Image {
                                visible: modelData.kind === "img"; anchors.fill: parent
                                smooth: false; fillMode: Image.Stretch
                                readonly property string _dev: (App.heroDevRev, App.heroDevPath("hero/" + (modelData.art || "")))
                                source: modelData.kind === "img" ? (_dev !== "" ? _dev : "qrc:/assets/mechui/hero/" + modelData.art + ".png") : ""
                            }
                            Rectangle {
                                visible: modelData.kind === "rect"; anchors.fill: parent
                                antialiasing: false; color: modelData.color || "#000000"
                            }
                        }
                    }
                }

                // nameplate — title + progress on a small plate
                Item {
                    id: pname
                    visible: poster.heroMode || poster.showPlate
                    // hero: match the (wide) nameplate plate so the title uses the whole bar
                    width: poster.heroMode ? poster.npboxW : poster.holeW
                    height: poster.heroMode ? poster.npboxH : poster.plateH
                    anchors.horizontalCenter: parent.horizontalCenter
                    // hero: seat on the (text-sized) nameplate plate; else: below the poster (column)
                    y: poster.heroMode ? poster.npboxY
                                       : (poster.colTopY + poster.colCellH + poster.colSpace)
                    transform: Translate { x: stats.mOff("pname")[0]; y: stats.mOff("pname")[1] }
                    // in hero mode the tile itself IS the nameplate bar — no own frame
                    MechPanel { visible: !stats.classic && !poster.heroMode; anchors.fill: parent; px: stats.mpx; kind: "frame" }
                    Rectangle { visible: stats.classic; anchors.fill: parent; color: "#141a22"; border.width: Math.max(1, stats.s); border.color: Theme.withAlpha(stats.steelInk, 0.18) }
                    // hidden BASE-size mirror of the text column — the plate height (npboxH)
                    // tracks THIS, so the per-line assembly scale (,/.) resizes the text
                    // without stretching the plate. Adapts to the SIZE dials, not the nudges.
                    Column {
                        id: npColBase
                        opacity: 0; enabled: false
                        anchors.centerIn: parent; width: npCol.width; spacing: Math.round(6 * stats.s)
                        // STABLE box-sizing reference: always the SAME 6 rows at the SIZE-dial sizes —
                        // NO per-title line-count change, NO assembly (mScale) scaling. So the box is a
                        // FIXED container (per your npbox/size design); the real text shrinks to fit it
                        // via npContentFit. This is why the box no longer stretches between titles.
                        Text { visible: npRank.visible; text: "Xg"; font.family: stats.mechFontFor(stats.mech.posterHdrFont); font.pixelSize: stats.pxi(Math.round(stats.mSz(10, stats.mech.posterHdrSize)))}
                        Text { text: "Xg"; font.family: stats.mechFontFor(stats.mech.npTitleFont); font.pixelSize: stats.pxi(Math.max(8, npTitle.titleLineP))}
                        Text { text: "Xg"; font.family: mgsHud.name; font.pixelSize: stats.pxi(Math.max(8, Math.round(npTitle.titleLineP * 0.42)))}  // always counted → box fixed even for year-less titles
                        Item { visible: stats.mech.npSep !== "off"; width: 1; height: Math.max(2, Math.round(3 * stats.s)) }   // divider row
                        Text { text: "Xg"; font.family: stats.mechFontFor(stats.mech.npDeepFont); font.pixelSize: stats.pxi(Math.round(stats.mSz(10, stats.mech.npDeepSize)))}
                        Text { text: "Xg"; font.family: stats.mechFontFor(stats.mech.npEpFont); font.pixelSize: stats.pxi(Math.round(stats.mSz(10, stats.mech.npEpSize)))}
                    }
                    Column {
                        id: npColFit
                        opacity: 0; enabled: false
                        anchors.centerIn: parent; width: npCol.width; spacing: Math.round(6 * stats.s)
                        // FIT reference: the unshrunk block height WITH your assembly scales AND the
                        // real line count (EP row gated to shows). npContentFit divides by this so the
                        // real (scaled) text fits the FIXED box exactly — box never changes, text does.
                        Text { visible: npRank.visible; text: "Xg"; font.family: stats.mechFontFor(stats.mech.posterHdrFont); font.pixelSize: stats.pxi(Math.round(stats.mSz(10, stats.mech.posterHdrSize) * stats.mScale("phdr")))}
                        // ACTUAL title height (width-fitted min(fillP,titleLineP), not the tall cap) so a
                        // long title that shrinks to fit the WIDTH doesn't make the fit over-shrink the
                        // rest → that was the big empty gap + tiny text on long titles.
                        Text { text: "Xg"; font.family: stats.mechFontFor(stats.mech.npTitleFont); font.pixelSize: stats.pxi(Math.max(8, Math.round(Math.min(npTitle.fillP, npTitle.titleLineP) * stats.mScale("ptit"))))}
                        Text { visible: npTitle.yr !== ""; text: "Xg"; font.family: mgsHud.name; font.pixelSize: stats.pxi(Math.max(8, Math.round(npTitle.titleLineP * 0.42 * stats.mScale("pyear"))))}
                        Item { visible: stats.mech.npSep !== "off"; width: 1; height: Math.max(2, Math.round(3 * stats.s)) }
                        Text { text: "Xg"; font.family: stats.mechFontFor(stats.mech.npDeepFont); font.pixelSize: stats.pxi(Math.round(stats.mSz(10, stats.mech.npDeepSize) * stats.mScale("pdeep")))}
                        Text { visible: npEp.visible; text: "Xg"; font.family: stats.mechFontFor(stats.mech.npEpFont); font.pixelSize: stats.pxi(Math.round(stats.mSz(10, stats.mech.npEpSize) * stats.mScale("peps")))}
                    }
                    Column {
                        id: npCol
                        visible: stats.shows.length > 0   // hide RANK/title/%/EP when there's no most-watched
                        // margin in the SAME scale as the plate (hpx in hero) so the fit target is
                        // the real box interior — mixing stats.s here made plateW too wide → overflow.
                        anchors.centerIn: parent
                        width: parent.width - Math.round(poster.heroMode ? 24 * poster.hpx : 28 * stats.s)
                        spacing: Math.max(1, Math.round(6 * stats.s * poster.npContentFit))
                        // RANK line — moved DOWN here from the (retired) top pill when
                        // heroRankPos = "below"; reuses the POSTER HEAD style dials + phdr key
                        Text {
                            id: npRank
                            visible: !stats.classic && poster.heroMode && (stats.mech.heroRankPos || "below") === "below"
                            anchors.horizontalCenter: parent.horizontalCenter
                            transform: Translate { x: stats.mOff("phdr")[0]; y: stats.mOff("phdr")[1] }
                            layer.enabled: !stats.classic && (stats.wellGlowN[stats.mech.wellGlow] || 0) > 0
                            layer.effect: ShaderEffect {
                                readonly property size res: Qt.size(Math.max(2, npRank.width), Math.max(2, npRank.height))
                                readonly property real radius: 2.5
                                readonly property real intensity: stats.wellGlowN[stats.mech.wellGlow] || 0
                                fragmentShader: "qrc:/qml/shaders/neonglow.frag.qsb"
                            }
                            textFormat: Text.StyledText
                            text: stats.caseFor("RANK ", stats.mech.posterHdrCase) + "<font color=\"#f2f8fc\">" + (rows.selRow + 1) + "</font>"
                            color: stats.ink(stats.mech.posterHdrInk)
                            font.family: stats.mechFontFor(stats.mech.posterHdrFont); font.weight: stats.weightFor(stats.mech.posterHdrWeight)
                            font.pixelSize: stats.pxi(Math.max(6, Math.round(stats.mSz(10, stats.mech.posterHdrSize) * stats.mScale("phdr") * poster.npContentFit))); font.letterSpacing: stats.trackFor(stats.mech.posterHdrTrack)
                        }
                        // title = NAME (mgscodec) + YEAR (mgshud), one baseline,
                        // crisply shrunk to fit the plate (never ellipsized).
                        Item {
                            id: npTitle
                            anchors.horizontalCenter: parent.horizontalCenter
                            // width = plate; height HUGS the actual title so the column packs
                            // tight (no gaps). The BOX height is held fixed by npColBase, so the
                            // tight content just centres inside the fixed plate.
                            width: plateW; height: nameText.height
                            transform: Translate { x: stats.mOff("ptit")[0]; y: stats.mOff("ptit")[1] }
                            // instrument glow (WELL GLOW) on the whole title (name + year)
                            layer.enabled: !stats.classic && (stats.wellGlowN[stats.mech.wellGlow] || 0) > 0
                            layer.effect: ShaderEffect {
                                readonly property size res: Qt.size(Math.max(2, npTitle.width), Math.max(2, npTitle.height))
                                readonly property real radius: 2.5
                                readonly property real intensity: stats.wellGlowN[stats.mech.wellGlow] || 0
                                fragmentShader: "qrc:/qml/shaders/neonglow.frag.qsb"
                            }
                            readonly property string nm: poster.topShow ? stats.caseFor(poster.topShow.show, stats.mech.npTitleCase) : "—"
                            readonly property string yr: stats.titleYear(poster.topShow)
                            readonly property real trk: stats.trackFor(stats.mech.npTitleTrack)
                            // base size (SIZE dial) — measured WITHOUT the assembly scale so the
                            // width-fit can't cancel it out on long titles.
                            readonly property int baseP: Math.round(stats.mSz(15, stats.mech.npTitleSize))
                            readonly property real plateW: parent.width    // fit target (plate interior width)
                            // fillP = the exact size at which the WHOLE title spans the plate width
                            // (small for long titles, large for short). This is the HARD LIMIT.
                            readonly property int fillP: npTitleM.advanceWidth > 0
                                ? Math.max(8, Math.round(baseP * plateW * 0.95 / npTitleM.advanceWidth)) : baseP
                            // titleLineP = a FIXED height cap (from the SIZE dial only — no assembly
                            // scale), so the plate NEVER stretches. The title fills the WIDTH up to
                            // this height: short titles top out here, long ones shrink to fit the width.
                            readonly property int titleLineP: Math.round(baseP * 1.9)
                            // × npContentFit so the whole block shrinks to fit the FIXED box
                            readonly property int fitP: Math.max(6, Math.round(Math.min(fillP, titleLineP) * poster.npContentFit * stats.mScale("ptit")))   // NAME TITLE assembly scale (1.0 = no change)
                            readonly property int fittedP: fitP   // year tracks the real title size
                            // the item's own width tracks the scaled text (+ glow bleed) so the
                            // neonglow layer texture always contains it → never a clipped edge.
                            readonly property real contentW: (npTitleM.advanceWidth > 0 ? npTitleM.advanceWidth * fitP / baseP : plateW) + Math.round(24 * stats.s)
                            // MEASURED bracket kern: pull by the glyph's own whitespace
                            //   bearing (advance − ink), so it hugs evenly and can NEVER
                            //   overlap the digits (a proportional guess did, twice)
                            TextMetrics { id: pOpenM; font.family: mgsHud.name; font.pixelSize: stats.pxi(npTitle.fitP); text: "(" }
                            TextMetrics { id: pCloseM; font.family: mgsHud.name; font.pixelSize: stats.pxi(npTitle.fitP); text: ")" }
                            readonly property real ygap: Math.round(npTitle.fitP * 0.10)   // small EVEN gap inside the brackets
                            readonly property real openKern: Math.round(Math.max(0, pOpenM.advanceWidth - (pOpenM.tightBoundingRect.x + pOpenM.tightBoundingRect.width))) - ygap
                            readonly property real closeKern: Math.round(Math.max(0, pCloseM.tightBoundingRect.x)) - ygap
                            readonly property real yearW: 0   // year now lives on its own line below → title fits to the FULL plate width
                            TextMetrics { id: npTitleM; font.family: stats.mechFontFor(stats.mech.npTitleFont)
                                          font.pixelSize: stats.pxi(npTitle.baseP); font.letterSpacing: npTitle.trk
                                          text: npTitle.nm }
                            Text {
                                id: nameText
                                anchors.centerIn: parent
                                text: npTitle.nm; color: stats.ink(stats.mech.posterInk)
                                font.family: stats.mechFontFor(stats.mech.npTitleFont); font.weight: stats.weightFor(stats.mech.npTitleWeight)
                                // tracking scales WITH the font (npTitleM measures at baseP) so the
                                // whole title shrinks uniformly — constant tracking was keeping long
                                // titles too wide to fit no matter how small the glyphs got.
                                font.pixelSize: stats.pxi(npTitle.fitP); font.letterSpacing: npTitle.trk * npTitle.fitP / npTitle.baseP
                            }
                        }
                        // YEAR — its own line under the title, so the title fits the full
                        // plate width and can scale bigger. Number accentuated, brackets dim.
                        Text {
                            id: npYear
                            visible: npTitle.yr !== ""
                            anchors.horizontalCenter: parent.horizontalCenter
                            transform: Translate { x: stats.mOff("pyear")[0]; y: stats.mOff("pyear")[1] }
                            textFormat: Text.StyledText
                            text: "(<font color=\"#f2f8fc\">" + npTitle.yr + "</font>)"
                            color: Theme.withAlpha(stats.ink(stats.mech.posterInk), 0.82)
                            font.family: mgsHud.name; font.weight: stats.weightFor(stats.mech.npTitleWeight)
                            // 42% of the fitted title, BUT floored to 30% of the title's height-cap
                            // (× fit) so a long title that shrank to fit WIDTH doesn't drag the year to
                            // nothing — the year stays readable independent of title length. Own pyear.
                            font.pixelSize: stats.pxi(Math.max(8, Math.round(npTitle.titleLineP * 0.30 * poster.npContentFit),
                                                        Math.round(npTitle.fittedP * 0.42 * stats.mScale("pyear")))); font.letterSpacing: npTitle.trk
                        }
                        // divider between the title/year and the progress readout (own line)
                        Item {
                            id: npSepEl
                            visible: stats.mech.npSep !== "off"
                            anchors.horizontalCenter: parent.horizontalCenter
                            readonly property real u: Math.max(2, Math.round(3 * stats.s * stats.mScale("psep")))
                            readonly property string k: stats.mech.npSep
                            width: k === "line" ? Math.round(u * 7) : k === "dash" ? Math.round(u * 2.2) : k === "bar" ? Math.max(2, Math.round(u * 0.55)) : u
                            height: k === "bar" ? Math.round(u * 2.2) : (k === "dash" || k === "line") ? Math.max(2, Math.round(u * 0.5)) : u
                            transform: Translate { x: stats.mOff("psep")[0]; y: stats.mOff("psep")[1] }
                            readonly property color sc: "#e8f4ff"
                            Rectangle { visible: parent.k === "diamond"; anchors.centerIn: parent; width: parent.u; height: parent.u; rotation: 45; color: parent.sc }
                            Rectangle { visible: parent.k === "dot"; anchors.centerIn: parent; width: parent.u; height: parent.u; radius: width / 2; color: parent.sc }
                            Rectangle { visible: parent.k === "dash" || parent.k === "bar" || parent.k === "line"; anchors.fill: parent; color: parent.sc }
                            Rectangle { visible: parent.k === "slash"; anchors.centerIn: parent; width: Math.max(2, Math.round(parent.u * 0.5)); height: Math.round(parent.u * 1.7); rotation: 22; color: parent.sc }
                        }
                        Text {
                            id: npDeep                                     // readout line 1 — content-aware
                            visible: poster.topShow !== null && poster.topShow !== undefined
                            anchors.horizontalCenter: parent.horizontalCenter
                            transform: Translate { x: stats.mOff("pdeep")[0]; y: stats.mOff("pdeep")[1] }
                            layer.enabled: !stats.classic && (stats.wellGlowN[stats.mech.wellGlow] || 0) > 0
                            layer.effect: ShaderEffect {
                                readonly property size res: Qt.size(Math.max(2, npDeep.width), Math.max(2, npDeep.height))
                                readonly property real radius: 2.5
                                readonly property real intensity: stats.wellGlowN[stats.mech.wellGlow] || 0
                                fragmentShader: "qrc:/qml/shaders/neonglow.frag.qsb"
                            }
                            textFormat: Text.StyledText
                            // CONTENT-AWARE readout line 1:
                            //  • movie mid-watch → "NN%  ×M"  (× count lives INSIDE this line so it can
                            //    never drift onto the year the way an independent element could)
                            //  • movie finished (0% resume) → just "×M"
                            //  • show → "WATCHED NN%"  (the EP count is line 2, npEp, stacked below)
                            text: (poster.topShow && poster.topShow.kind === "movie")
                                  ? ((poster.frac || 0) > 0.01
                                     ? "<font color=\"#f2f8fc\">" + Math.round(poster.frac * 100) + "</font>" + stats.caseFor("%", stats.mech.npDeepCase) + "&#160;&#160;<font color=\"#f2f8fc\">×" + (poster.topShow.count || 0) + "</font>"
                                     : "<font color=\"#f2f8fc\">×" + (poster.topShow.count || 0) + "</font>")
                                  : stats.caseFor("WATCHED ", stats.mech.npDeepCase) + "<font color=\"#f2f8fc\">" + Math.round(poster.frac * 100) + "</font>" + stats.caseFor("%", stats.mech.npDeepCase)
                            color: Theme.withAlpha(stats.ink(stats.mech.npDeepInk), 0.85)
                            font.family: stats.mechFontFor(stats.mech.npDeepFont)
                            font.pixelSize: stats.pxi(Math.max(6, Math.round(stats.mSz(10, stats.mech.npDeepSize) * stats.mScale("pdeep") * poster.npContentFit))); font.weight: stats.weightFor(stats.mech.npDeepWeight); font.letterSpacing: stats.trackFor(stats.mech.npDeepTrack)
                        }
                        Text {
                            id: npEp                                       // readout line 2 — SHOWS only (EP count)
                            // movies fold their ×N into npDeep (line 1), so this line is show-only;
                            // that's what stops the ×N from ever overlapping the % or the year.
                            visible: poster.topShow !== null && poster.topShow !== undefined && poster.topShow.kind !== "movie"
                            anchors.horizontalCenter: parent.horizontalCenter
                            transform: Translate { x: stats.mOff("peps")[0]; y: stats.mOff("peps")[1] }
                            layer.enabled: !stats.classic && (stats.wellGlowN[stats.mech.wellGlow] || 0) > 0
                            layer.effect: ShaderEffect {
                                readonly property size res: Qt.size(Math.max(2, npEp.width), Math.max(2, npEp.height))
                                readonly property real radius: 2.5
                                readonly property real intensity: stats.wellGlowN[stats.mech.wellGlow] || 0
                                fragmentShader: "qrc:/qml/shaders/neonglow.frag.qsb"
                            }
                            textFormat: Text.StyledText
                            text: "<font color=\"#f2f8fc\">" + (poster.topShow ? poster.topShow.done : 0) + "</font>" + stats.caseFor(" EP / ", stats.mech.npEpCase) + "<font color=\"#f2f8fc\">" + (poster.topShow ? poster.topShow.total : 0) + "</font>"
                            color: Theme.withAlpha(stats.ink(stats.mech.npEpInk), 0.85)   // match WATCHED brightness
                            font.family: stats.mechFontFor(stats.mech.npEpFont)
                            font.pixelSize: stats.pxi(Math.max(6, Math.round(stats.mSz(10, stats.mech.npEpSize) * stats.mScale("peps") * poster.npContentFit))); font.weight: stats.weightFor(stats.mech.npEpWeight); font.letterSpacing: stats.trackFor(stats.mech.npEpTrack)
                        }
                    }
                }
            }
        }

        // ── TERRAIN GRAPH (30-day) ───────────────────────────────────────────
        Item {
            id: graph
            width: cockpit.heroW; height: cockpit.graphH
            anchors.left: parent.left; anchors.bottom: parent.bottom
            transform: Translate { x: stats.mOff("graph")[0]; y: stats.mOff("graph")[1] }
            readonly property color gInk: stats.ink(stats.mech.graphInk)
            readonly property real lineW: Math.max(1, 1.6 * stats.s * (stats.sizeFac[stats.mech.graphWeight] || 1))
            readonly property real fillA: stats.mech.graphFill === "solid" ? 0.28 : stats.mech.graphFill === "light" ? 0.13 : 0
            readonly property real labelOp: stats.mech.graphLabel === "off" ? 0 : stats.mech.graphLabel === "dim" ? 0.5 : 1
            // axis-aware gutters — a Y axis widens the left pad for value labels; an
            // X axis reserves a touch more bottom band for the week ticks.
            readonly property bool yAxisOn: !stats.classic && (stats.mech.graphAxis || "off") !== "off"
            readonly property bool xAxisOn: !stats.classic && (stats.mech.graphXAxis || "weeks") !== "off"
            readonly property real pad: yAxisOn ? Math.round(30 * stats.s) : Math.round(10 * stats.s)
            readonly property real base: height - Math.round((xAxisOn ? 20 : 18) * stats.s)
            readonly property real peak: {
                var mx = 1; for (var i = 0; i < stats.days.length; ++i) mx = Math.max(mx, stats.days[i].seconds); return mx
            }
            // nice-number hour ticks so the grid + Y labels land on clean values
            readonly property real peakH: peak / 3600
            readonly property real tickStep: {
                var raw = peakH / 5, mags = [0.1, 0.25, 0.5, 1, 2, 5, 10, 20, 50, 100]
                for (var i = 0; i < mags.length; ++i) if (mags[i] >= raw) return mags[i]
                return mags[mags.length - 1]
            }
            readonly property int tickCount: Math.max(1, Math.min(7, Math.floor(peakH / tickStep + 0.0001)))
            // weekly column indices from today backwards (NOW, 1W, 2W, 3W, 4W)
            readonly property var weekIdx: {
                var a = [], n = stats.days.length
                for (var w = 0; w < 5; ++w) { var idx = n - 1 - 7 * w; if (idx >= 0) a.push(idx) }
                return a
            }
            function px(i) { return pad + (stats.days.length <= 1 ? 0 : i / (stats.days.length - 1)) * (width - pad * 2) }
            function py(sec) { return base - (sec / peak) * (base - Math.round(22 * stats.s)) }   // top headroom for the peak PIN + its value label (was 12s → clipped, esp. on the short CRT graph)
            readonly property var ridgePts: {
                var p = []; for (var i = 0; i < stats.days.length; ++i) p.push(Qt.point(px(i), py(stats.days[i].seconds))); return p
            }
            readonly property var areaPts: {
                var p = ridgePts.slice(); if (p.length === 0) return p
                p.push(Qt.point(p[p.length - 1].x, base)); p.push(Qt.point(p[0].x, base)); p.push(p[0]); return p
            }

            // recessed instrument well behind the terrain — a plain dark fill; the FRAME is
            // The author's hand-drawn 9-slice art (graph-frame.png), laid on top and hot-reloading.
            Rectangle {
                id: graphWell
                visible: !stats.classic && (stats.mech.graphWell || "recessed") !== "none"
                x: 0; y: Math.round(3 * stats.s)
                width: graph.width; height: graph.height - Math.round(3 * stats.s)
                gradient: Gradient {
                    GradientStop { position: 0.0; color: "#0c1119" }
                    GradientStop { position: 0.72; color: "#080b11" }
                    GradientStop { position: 1.0; color: "#0a0e15" }
                }
                // top-edge highlight + bottom shadow = recessed read
                Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                            height: Math.max(1, stats.s); color: Theme.withAlpha(stats.steelInk, 0.10) }
                Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                            height: Math.max(1, stats.s); color: Theme.withAlpha("#000000", 0.35) }
                // soft inner vignette — darkens the edges for a recessed screen read
                Rectangle {
                    anchors.fill: parent; color: "transparent"
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0.0; color: Theme.withAlpha("#000000", 0.30) }
                        GradientStop { position: 0.08; color: "transparent" }
                        GradientStop { position: 0.92; color: "transparent" }
                        GradientStop { position: 1.0; color: Theme.withAlpha("#000000", 0.30) }
                    }
                }
            }
            // GRAPH FRAME = the author's hand-drawn 9-slice art (assets/mechui/graph-frame.png).
            // MechSlice is dev:true → an Aseprite save hot-reloads live, no rebuild. Draw the
            // border + corners in the PNG; the transparent centre lets the terrain show through.
            MechSlice {
                id: graphFrame
                visible: !stats.classic && (stats.mech.graphWell || "recessed") !== "none"
                anchors.fill: graphWell
                source: "qrc:/assets/mechui/graph-frame.png"
                px: stats.mpx
                artL: 3; artR: 3; artT: 3; artB: 3
                z: 4
            }
            // panel header rule + title (LABELS dial)
            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; height: Math.max(1, 1 * stats.s); color: Theme.withAlpha(graph.gInk, 0.22) }
            readonly property bool legendOn: !stats.classic && (stats.mech.graphLegend || "swatch") !== "off"
            Text {
                id: terrainLabel
                anchors.left: parent.left; anchors.top: parent.top; anchors.topMargin: Math.round(7 * stats.s)
                anchors.leftMargin: graph.legendOn ? Math.round(12 * stats.s) : 0
                transform: Translate { x: stats.mOff("tlab")[0]; y: stats.mOff("tlab")[1] }
                text: stats.caseFor("LAST 30 DAYS", stats.mech.terrainCase); color: Theme.withAlpha(stats.ink(stats.mech.terrainInk), 0.7); opacity: graph.labelOp
                font.family: stats.mechFontFor(stats.mech.terrainFont); font.weight: stats.weightFor(stats.mech.terrainWeight)
                font.pixelSize: stats.pxi(Math.round(stats.mSz(10, stats.mech.terrainSize) * stats.mScale("tlab"))); font.letterSpacing: stats.trackFor(stats.mech.terrainTrack)
            }
            // legend swatch (graphLegend) — a small ink chip left of the title, keyed to the line colour
            Rectangle {
                visible: graph.legendOn; opacity: graph.labelOp
                width: Math.round(7 * stats.s); height: width; radius: Math.round(1.5 * stats.s)
                anchors.left: parent.left; anchors.verticalCenter: terrainLabel.verticalCenter
                anchors.leftMargin: Math.round(1 * stats.s)
                transform: Translate { x: stats.mOff("tlab")[0]; y: stats.mOff("tlab")[1] }
                color: graph.gInk
                border.width: Math.max(1, stats.s); border.color: Theme.withAlpha("#ffffff", 0.35)
            }
            // instrument grid (GRID dial) — nice-number horizontal tick rows + weekly
            // verticals, aligned exactly to the Y/X axis labels. lines · dashed · dots.
            Shape {
                id: graphGrid2
                visible: !stats.classic && (stats.mech.graphGrid || "on") !== "off"
                anchors.fill: parent; antialiasing: true; opacity: stats.eGraph
                readonly property string gs: { var g = stats.mech.graphGrid || "on"; return g === "on" ? "lines" : g }
                readonly property int strokeStyle: gs === "lines" ? ShapePath.SolidLine : ShapePath.DashLine
                readonly property var dashP: gs === "dots" ? [1, 3] : [5, 5]
                readonly property int cap: gs === "dots" ? ShapePath.RoundCap : ShapePath.FlatCap
                ShapePath {   // minor grid — faint half-steps (rows) + half-week midpoints (cols)
                    strokeColor: Theme.withAlpha(stats.steelInk, 0.045); fillColor: "transparent"
                    strokeWidth: Math.max(1, stats.s); strokeStyle: ShapePath.SolidLine
                    PathMultiline { paths: {
                        var out = [], top = Math.round(12 * stats.s)
                        for (var k = 1; k <= graph.tickCount + 1; ++k) {
                            var hrs = graph.tickStep * (k - 0.5); if (hrs > graph.peakH) continue
                            var y = graph.py(hrs * 3600)
                            out.push([Qt.point(graph.pad, y), Qt.point(graph.width - graph.pad, y)]) }
                        var n = stats.days.length
                        for (var w = 0; w < 5; ++w) { var fi = n - 1 - 7 * w - 3.5; if (fi < 0) continue
                            var x = graph.px(fi)
                            out.push([Qt.point(x, top), Qt.point(x, graph.base)]) }
                        return out
                    } }
                }
                ShapePath {   // horizontal tick rows (brighter — they carry the Y labels)
                    strokeColor: Theme.withAlpha(stats.steelInk, 0.10); fillColor: "transparent"
                    strokeWidth: Math.max(1, stats.s); strokeStyle: graphGrid2.strokeStyle
                    dashPattern: graphGrid2.dashP; capStyle: graphGrid2.cap
                    PathMultiline { paths: {
                        var out = []; for (var k = 1; k <= graph.tickCount; ++k) {
                            var y = graph.py(graph.tickStep * k * 3600)
                            out.push([Qt.point(graph.pad, y), Qt.point(graph.width - graph.pad, y)]) }
                        return out
                    } }
                }
                ShapePath {   // weekly verticals (fainter)
                    strokeColor: Theme.withAlpha(stats.steelInk, 0.06); fillColor: "transparent"
                    strokeWidth: Math.max(1, stats.s); strokeStyle: graphGrid2.strokeStyle
                    dashPattern: graphGrid2.dashP; capStyle: graphGrid2.cap
                    PathMultiline { paths: {
                        var out = [], wi = graph.weekIdx
                        for (var i = 0; i < wi.length; ++i) { var x = graph.px(wi[i])
                            out.push([Qt.point(x, Math.round(12 * stats.s)), Qt.point(x, graph.base)]) }
                        return out
                    } }
                }
            }
            // classic grid (byte-identical fallback) — the original faint 3+4 line grid
            Repeater {
                model: (stats.classic && stats.mech.graphGrid !== "off") ? 3 : 0
                Rectangle {
                    required property int index
                    x: graph.pad; width: graph.width - graph.pad * 2
                    y: graph.base - (index + 1) / 4 * (graph.base - Math.round(12 * stats.s))
                    height: Math.max(1, stats.s); color: Theme.withAlpha(stats.steelInk, 0.08)
                    opacity: stats.eGraph
                }
            }
            Repeater {
                model: (stats.classic && stats.mech.graphGrid !== "off") ? 4 : 0
                Rectangle {
                    required property int index
                    x: graph.pad + (index + 1) / 5 * (graph.width - graph.pad * 2)
                    y: Math.round(20 * stats.s); width: Math.max(1, stats.s); height: graph.base - Math.round(20 * stats.s)
                    color: Theme.withAlpha(stats.steelInk, 0.06); opacity: stats.eGraph
                }
            }
            Item {                                            // phase 4: terrain drawn left→right by a widening clip
                id: terrain
                clip: true
                width: graph.width * stats.eGraph; height: graph.height

                QtObject {
                    id: gcalc
                    readonly property real top: Math.round(12 * stats.s)
                    readonly property int  n: stats.days.length
                    readonly property real meanSec: { var s = 0; for (var i = 0; i < n; ++i) s += stats.days[i].seconds; return n ? s / n : 0 }
                    readonly property real meanY: graph.py(meanSec)
                    readonly property int  lastI: Math.max(0, n - 1)
                    readonly property int  maxIdx: { var mi = 0; for (var i = 1; i < n; ++i) if (stats.days[i].seconds > stats.days[mi].seconds) mi = i; return mi }
                    readonly property int  minIdx: { var mi = 0; for (var i = 1; i < n; ++i) if (stats.days[i].seconds < stats.days[mi].seconds) mi = i; return mi }
                    // guarded accessors (markers bind these even before days populates)
                    readonly property real maxSec: n > 0 ? stats.days[maxIdx].seconds : 0
                    readonly property real lastSec: n > 0 ? stats.days[lastI].seconds : 0
                    readonly property real totalSec: { var s = 0; for (var i = 0; i < n; ++i) s += stats.days[i].seconds; return s }
                    function avg(i, w)  { var s = 0, c = 0; for (var j = i - w; j <= i + w; j++) if (j >= 0 && j < n) { s += stats.days[j].seconds; c++ } return c ? s / c : 0 }
                    function rmax(i, w) { var m = 0;        for (var j = i - w; j <= i + w; j++) if (j >= 0 && j < n) m = Math.max(m, stats.days[j].seconds); return m }
                    function rmin(i, w) { var m = Infinity; for (var j = i - w; j <= i + w; j++) if (j >= 0 && j < n) m = Math.min(m, stats.days[j].seconds); return m === Infinity ? 0 : m }
                }

                Shape {   // graph glow — a soft accent halo under the line
                    visible: stats.mech.graphGlow === "on" && ["area", "ridge", "line", "gradient-area", "dual-line", "spark", "stacked", "band", "mirror"].indexOf(stats.mech.graph) >= 0
                    width: graph.width; height: graph.height; antialiasing: true
                    ShapePath { strokeColor: Theme.withAlpha(stats.accent, 0.12); fillColor: "transparent"; strokeWidth: Math.max(6, 8 * stats.s)
                                capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin; PathPolyline { path: graph.ridgePts } }
                }
                Shape {   // 1 AREA
                    visible: stats.mech.graph === "area"; width: graph.width; height: graph.height; antialiasing: true
                    // fill: a soft vertical gradient in mech; a flat fill in classic (a
                    // uniform-alpha gradient == the original flat fill → byte-identical).
                    ShapePath { strokeColor: "transparent"
                        fillGradient: LinearGradient { x1: 0; y1: gcalc.top; x2: 0; y2: graph.base
                            GradientStop { position: 0.0; color: Theme.withAlpha(graph.gInk, stats.classic ? graph.fillA : 0.22) }
                            GradientStop { position: 0.5; color: Theme.withAlpha(graph.gInk, stats.classic ? graph.fillA : 0.08) }
                            GradientStop { position: 1.0; color: Theme.withAlpha(graph.gInk, stats.classic ? graph.fillA : 0.0) } }
                        PathPolyline { path: graph.areaPts } }
                    // clean thin ridge — a hair brighter in mech, original ink in classic. No glow.
                    ShapePath { strokeColor: stats.classic ? graph.gInk : Qt.lighter(graph.gInk, 1.15); fillColor: "transparent"; strokeWidth: graph.lineW
                                capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin; PathPolyline { path: graph.ridgePts } }
                }
                Shape {   // 2 RIDGE
                    visible: stats.mech.graph === "ridge"; width: graph.width; height: graph.height; antialiasing: true
                    ShapePath { strokeColor: graph.gInk; fillColor: "transparent"; strokeWidth: Math.max(1.5, 1.8 * stats.s)
                                capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin; PathPolyline { path: graph.ridgePts } }
                }
                Shape {   // 3 LINE
                    visible: stats.mech.graph === "line"; width: graph.width; height: graph.height; antialiasing: true
                    ShapePath { strokeColor: graph.gInk; fillColor: "transparent"; strokeWidth: Math.max(1, 1.3 * stats.s)
                                capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin; PathPolyline { path: graph.ridgePts } }
                }
                Rectangle {
                    visible: stats.mech.graph === "line" && gcalc.n > 0
                    width: Math.round(6 * stats.s); height: width; radius: width / 2; color: graph.gInk
                    x: graph.px(gcalc.lastI) - width / 2; y: graph.py((stats.days[gcalc.lastI] || {}).seconds || 0) - height / 2
                }
                Repeater {   // 4 BARS
                    model: stats.mech.graph === "bars" ? gcalc.n : 0
                    Rectangle {
                        required property int index
                        readonly property real bw: Math.max(1, (graph.width - graph.pad * 2) / Math.max(1, gcalc.n) * 0.62)
                        x: graph.px(index) - bw / 2; width: bw
                        y: graph.py(stats.days[index].seconds); height: Math.max(0, graph.base - y)
                        color: Theme.withAlpha(graph.gInk, 0.55)
                    }
                }
                Repeater {   // 5 COLUMNS
                    model: stats.mech.graph === "columns" ? gcalc.n : 0
                    Rectangle {
                        required property int index
                        readonly property real bw: Math.max(2, (graph.width - graph.pad * 2) / Math.max(1, gcalc.n) * 0.8)
                        x: graph.px(index) - bw / 2; width: bw
                        y: graph.py(stats.days[index].seconds); height: Math.max(1, graph.base - y)
                        radius: Math.min(bw / 2, Math.round(3 * stats.s))
                        gradient: Gradient {
                            GradientStop { position: 0.0; color: Theme.withAlpha(graph.gInk, 0.9) }
                            GradientStop { position: 1.0; color: Theme.withAlpha(graph.gInk, 0.28) }
                        }
                    }
                }
                Repeater {   // 6 SPIKES
                    model: stats.mech.graph === "spikes" ? gcalc.n : 0
                    Item {
                        required property int index
                        readonly property real yy: graph.py(stats.days[index].seconds)
                        Rectangle { x: graph.px(index) - Math.max(1, stats.s) / 2; width: Math.max(1, stats.s)
                                    y: parent.yy; height: Math.max(0, graph.base - parent.yy); color: Theme.withAlpha(graph.gInk, 0.8) }
                        Rectangle { width: Math.max(2, Math.round(2.4 * stats.s)); height: width; radius: width / 2
                                    x: graph.px(index) - width / 2; y: parent.yy - height / 2; color: graph.gInk }
                    }
                }
                Repeater {   // 7 DOTS
                    model: stats.mech.graph === "dots" ? gcalc.n : 0
                    Rectangle {
                        required property int index
                        readonly property real d: (index === gcalc.lastI) ? Math.round(6 * stats.s) : Math.round(4 * stats.s)
                        width: d; height: d; radius: d / 2
                        x: graph.px(index) - d / 2; y: graph.py(stats.days[index].seconds) - d / 2
                        color: Theme.withAlpha(graph.gInk, index === gcalc.lastI ? 1 : 0.8)
                    }
                }
                Repeater {   // 8 LOLLIPOP
                    model: stats.mech.graph === "lollipop" ? gcalc.n : 0
                    Item {
                        required property int index
                        readonly property real yy: graph.py(stats.days[index].seconds)
                        Rectangle { x: graph.px(index) - Math.max(1, stats.s) / 2; width: Math.max(1, stats.s)
                                    y: parent.yy; height: Math.max(0, graph.base - parent.yy); color: Theme.withAlpha(graph.gInk, 0.5) }
                        Rectangle { readonly property real d: Math.round(6 * stats.s); width: d; height: d; radius: d / 2
                                    x: graph.px(index) - d / 2; y: parent.yy - d / 2; color: graph.gInk }
                    }
                }
                Shape {   // 9 STEPS
                    visible: stats.mech.graph === "steps"; width: graph.width; height: graph.height; antialiasing: true
                    readonly property var pts: {
                        if (stats.mech.graph !== "steps" || gcalc.n === 0) return []
                        var p = []; for (var i = 0; i < gcalc.n; i++) { var x = graph.px(i), y = graph.py(stats.days[i].seconds)
                            if (i > 0) p.push(Qt.point(x, graph.py(stats.days[i - 1].seconds))); p.push(Qt.point(x, y)) } return p
                    }
                    ShapePath { strokeColor: graph.gInk; fillColor: "transparent"; strokeWidth: Math.max(1.4, 1.6 * stats.s)
                                joinStyle: ShapePath.MiterJoin; capStyle: ShapePath.FlatCap; PathPolyline { path: parent.pts } }
                }
                Shape {   // 10 STEPPED-AREA
                    visible: stats.mech.graph === "stepped-area"; width: graph.width; height: graph.height; antialiasing: true
                    readonly property var pts: {
                        if (stats.mech.graph !== "stepped-area" || gcalc.n === 0) return []
                        var p = [Qt.point(graph.px(0), graph.base)]
                        for (var i = 0; i < gcalc.n; i++) { var x = graph.px(i), y = graph.py(stats.days[i].seconds)
                            if (i > 0) p.push(Qt.point(x, graph.py(stats.days[i - 1].seconds))); p.push(Qt.point(x, y)) }
                        p.push(Qt.point(graph.px(gcalc.lastI), graph.base)); p.push(Qt.point(graph.px(0), graph.base)); return p
                    }
                    ShapePath { fillColor: Theme.withAlpha(graph.gInk, Math.max(0.1, graph.fillA)); strokeColor: graph.gInk
                                strokeWidth: Math.max(1.2, 1.4 * stats.s); joinStyle: ShapePath.MiterJoin; PathPolyline { path: parent.pts } }
                }
                Repeater {   // 11 CANDLES
                    model: stats.mech.graph === "candles" ? gcalc.n : 0
                    Item {
                        required property int index
                        readonly property real o: stats.days[Math.max(0, index - 1)].seconds
                        readonly property real c: stats.days[index].seconds
                        readonly property real hi: gcalc.rmax(index, 1)
                        readonly property real lo: gcalc.rmin(index, 1)
                        readonly property bool up: c >= o
                        readonly property real bw: Math.max(2, (graph.width - graph.pad * 2) / Math.max(1, gcalc.n) * 0.55)
                        readonly property color cc: up ? graph.gInk : Theme.withAlpha(graph.gInk, 0.42)
                        Rectangle { x: graph.px(index) - Math.max(1, stats.s) / 2; width: Math.max(1, stats.s)
                                    y: graph.py(parent.hi); height: Math.max(1, graph.py(parent.lo) - graph.py(parent.hi)); color: parent.cc }
                        Rectangle { x: graph.px(index) - parent.bw / 2; width: parent.bw
                                    y: Math.min(graph.py(parent.o), graph.py(parent.c)); height: Math.max(Math.round(2 * stats.s), Math.abs(graph.py(parent.o) - graph.py(parent.c)))
                                    color: parent.up ? Theme.withAlpha(graph.gInk, 0.85) : "transparent"
                                    border.width: Math.max(1, stats.s); border.color: parent.cc }
                    }
                }
                Repeater {   // 12 HILO
                    model: stats.mech.graph === "hilo" ? gcalc.n : 0
                    Item {
                        required property int index
                        readonly property real o: stats.days[Math.max(0, index - 1)].seconds
                        readonly property real c: stats.days[index].seconds
                        readonly property real tk: Math.max(2, Math.round((graph.width - graph.pad * 2) / Math.max(1, gcalc.n) * 0.3))
                        Rectangle { x: graph.px(index) - Math.max(1, stats.s) / 2; width: Math.max(1, stats.s)
                                    y: graph.py(gcalc.rmax(index, 1)); height: Math.max(1, graph.py(gcalc.rmin(index, 1)) - y); color: Theme.withAlpha(graph.gInk, 0.85) }
                        Rectangle { x: graph.px(index) - parent.tk; width: parent.tk; height: Math.max(1, stats.s); y: graph.py(parent.o); color: graph.gInk }
                        Rectangle { x: graph.px(index);            width: parent.tk; height: Math.max(1, stats.s); y: graph.py(parent.c); color: graph.gInk }
                    }
                }
                Shape {   // 13 BAND
                    visible: stats.mech.graph === "band"; width: graph.width; height: graph.height; antialiasing: true
                    readonly property var env: {
                        if (stats.mech.graph !== "band" || gcalc.n === 0) return []
                        var p = []; for (var i = 0; i < gcalc.n; i++) p.push(Qt.point(graph.px(i), graph.py(gcalc.rmax(i, 2))))
                        for (var j = gcalc.n - 1; j >= 0; j--) p.push(Qt.point(graph.px(j), graph.py(gcalc.rmin(j, 2)))); if (p.length) p.push(p[0]); return p
                    }
                    ShapePath { fillColor: Theme.withAlpha(graph.gInk, 0.16); strokeColor: "transparent"; PathPolyline { path: parent.env } }
                    ShapePath { strokeColor: graph.gInk; fillColor: "transparent"; strokeWidth: Math.max(1.4, 1.5 * stats.s)
                                capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin; PathPolyline { path: graph.ridgePts } }
                }
                Shape {   // 14 MIRROR
                    visible: stats.mech.graph === "mirror"; width: graph.width; height: graph.height; antialiasing: true
                    readonly property real midY: (gcalc.top + graph.base) / 2
                    readonly property real half: (graph.base - gcalc.top) / 2
                    readonly property var poly: {
                        if (stats.mech.graph !== "mirror" || gcalc.n === 0) return []
                        var p = []; for (var i = 0; i < gcalc.n; i++) { var a = stats.days[i].seconds / graph.peak * half; p.push(Qt.point(graph.px(i), midY - a)) }
                        for (var j = gcalc.n - 1; j >= 0; j--) { var b = stats.days[j].seconds / graph.peak * half; p.push(Qt.point(graph.px(j), midY + b)) } if (p.length) p.push(p[0]); return p
                    }
                    ShapePath { fillColor: Theme.withAlpha(graph.gInk, 0.18); strokeColor: graph.gInk
                                strokeWidth: Math.max(1, 1.2 * stats.s); joinStyle: ShapePath.RoundJoin; PathPolyline { path: parent.poly } }
                }
                Shape {   // 15 STACKED
                    visible: stats.mech.graph === "stacked"; width: graph.width; height: graph.height; antialiasing: true
                    readonly property real k: 0.58
                    readonly property var band1: {
                        if (stats.mech.graph !== "stacked" || gcalc.n === 0) return []
                        var p = []; for (var i = 0; i < gcalc.n; i++) p.push(Qt.point(graph.px(i), graph.py(stats.days[i].seconds * k)))
                        p.push(Qt.point(graph.px(gcalc.lastI), graph.base)); p.push(Qt.point(graph.px(0), graph.base)); if (p.length) p.push(p[0]); return p
                    }
                    readonly property var band2: {
                        if (stats.mech.graph !== "stacked" || gcalc.n === 0) return []
                        var p = []; for (var i = 0; i < gcalc.n; i++) p.push(Qt.point(graph.px(i), graph.py(stats.days[i].seconds)))
                        for (var j = gcalc.n - 1; j >= 0; j--) p.push(Qt.point(graph.px(j), graph.py(stats.days[j].seconds * k))); if (p.length) p.push(p[0]); return p
                    }
                    ShapePath { fillColor: Theme.withAlpha(graph.gInk, 0.30); strokeColor: "transparent"; PathPolyline { path: parent.band1 } }
                    ShapePath { fillColor: Theme.withAlpha(graph.gInk, 0.13); strokeColor: "transparent"; PathPolyline { path: parent.band2 } }
                    ShapePath { strokeColor: graph.gInk; fillColor: "transparent"; strokeWidth: Math.max(1.2, 1.4 * stats.s)
                                capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin; PathPolyline { path: graph.ridgePts } }
                }
                Item {   // 16 BASELINE-SPLIT (above mean)
                    visible: stats.mech.graph === "baseline-split"; x: 0; y: 0; width: graph.width; height: gcalc.meanY; clip: true
                    Shape { width: graph.width; height: graph.height; antialiasing: true
                        ShapePath { fillColor: Theme.withAlpha(graph.gInk, 0.22); strokeColor: "transparent"; PathPolyline { path: graph.areaPts } }
                        ShapePath { strokeColor: graph.gInk; fillColor: "transparent"; strokeWidth: Math.max(1.4, 1.6 * stats.s)
                                    capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin; PathPolyline { path: graph.ridgePts } } }
                }
                Item {   // 16 BASELINE-SPLIT (below mean)
                    visible: stats.mech.graph === "baseline-split"; x: 0; y: gcalc.meanY; width: graph.width; height: graph.height - gcalc.meanY; clip: true
                    Shape { y: -gcalc.meanY; width: graph.width; height: graph.height; antialiasing: true
                        ShapePath { fillColor: Theme.withAlpha(stats.steelInk, 0.14); strokeColor: "transparent"; PathPolyline { path: graph.areaPts } }
                        ShapePath { strokeColor: Theme.withAlpha(stats.steelInk, 0.75); fillColor: "transparent"; strokeWidth: Math.max(1.4, 1.6 * stats.s)
                                    capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin; PathPolyline { path: graph.ridgePts } } }
                }
                Rectangle { visible: stats.mech.graph === "baseline-split"; x: graph.pad; width: graph.width - graph.pad * 2
                            y: gcalc.meanY; height: Math.max(1, stats.s); color: Theme.withAlpha(stats.steelInk, 0.4) }
                Rectangle { visible: stats.mech.graph === "threshold"; x: graph.pad; width: graph.width - graph.pad * 2
                            y: gcalc.meanY; height: Math.max(1, stats.s); color: Theme.withAlpha(stats.steelInk, 0.35) }
                Item {   // 17 THRESHOLD (hot)
                    visible: stats.mech.graph === "threshold"; x: 0; y: 0; width: graph.width; height: gcalc.meanY; clip: true
                    Shape { width: graph.width; height: graph.height; antialiasing: true
                        ShapePath { strokeColor: graph.gInk; fillColor: "transparent"; strokeWidth: Math.max(1.6, 1.8 * stats.s)
                                    capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin; PathPolyline { path: graph.ridgePts } } }
                }
                Item {   // 17 THRESHOLD (cold)
                    visible: stats.mech.graph === "threshold"; x: 0; y: gcalc.meanY; width: graph.width; height: graph.height - gcalc.meanY; clip: true
                    Shape { y: -gcalc.meanY; width: graph.width; height: graph.height; antialiasing: true
                        ShapePath { strokeColor: Theme.withAlpha(graph.gInk, 0.4); fillColor: "transparent"; strokeWidth: Math.max(1.6, 1.8 * stats.s)
                                    capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin; PathPolyline { path: graph.ridgePts } } }
                }
                Shape {   // 18 GRADIENT-AREA
                    visible: stats.mech.graph === "gradient-area"; width: graph.width; height: graph.height; antialiasing: true
                    // subtle vertical fill — minimal + technical (mech); the classic stops
                    // sit on the original 2-stop 0.5→0.0 line → byte-identical in classic.
                    ShapePath { strokeColor: "transparent"
                        fillGradient: LinearGradient { x1: 0; y1: gcalc.top; x2: 0; y2: graph.base
                            GradientStop { position: 0.0; color: stats.classic ? Theme.withAlpha(graph.gInk, 0.5) : Theme.withAlpha(graph.gInk, 0.22) }
                            GradientStop { position: 0.45; color: stats.classic ? Theme.withAlpha(graph.gInk, 0.275) : Theme.withAlpha(graph.gInk, 0.08) }
                            GradientStop { position: 1.0; color: Theme.withAlpha(graph.gInk, 0.0) } }
                        PathPolyline { path: graph.areaPts } }
                    // clean thin ridge — a hair brighter in mech, original ink in classic. No glow.
                    ShapePath { strokeColor: stats.classic ? graph.gInk : Qt.lighter(graph.gInk, 1.15); fillColor: "transparent"; strokeWidth: graph.lineW
                                capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin; PathPolyline { path: graph.ridgePts } }
                }
                Shape {   // 19 DUAL-LINE
                    visible: stats.mech.graph === "dual-line"; width: graph.width; height: graph.height; antialiasing: true
                    readonly property var trend: {
                        if (stats.mech.graph !== "dual-line" || gcalc.n === 0) return []
                        var p = []; for (var i = 0; i < gcalc.n; i++) p.push(Qt.point(graph.px(i), graph.py(gcalc.avg(i, 3)))); return p
                    }
                    ShapePath { strokeColor: Theme.withAlpha(graph.gInk, 0.35); fillColor: "transparent"; strokeWidth: Math.max(1, stats.s)
                                capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin; PathPolyline { path: graph.ridgePts } }
                    ShapePath { strokeColor: graph.gInk; fillColor: "transparent"; strokeWidth: Math.max(1.8, 2 * stats.s)
                                capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin; PathPolyline { path: parent.trend } }
                }
                Shape {   // 20 RIBBON
                    visible: stats.mech.graph === "ribbon"; width: graph.width; height: graph.height; antialiasing: true
                    ShapePath { strokeColor: Theme.withAlpha(graph.gInk, 0.14); fillColor: "transparent"; strokeWidth: Math.max(7, 8 * stats.s)
                                capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin; PathPolyline { path: graph.ridgePts } }
                    ShapePath { strokeColor: Theme.withAlpha(graph.gInk, 0.30); fillColor: "transparent"; strokeWidth: Math.max(3.5, 4 * stats.s)
                                capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin; PathPolyline { path: graph.ridgePts } }
                    ShapePath { strokeColor: graph.gInk; fillColor: "transparent"; strokeWidth: Math.max(1.4, 1.5 * stats.s)
                                capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin; PathPolyline { path: graph.ridgePts } }
                }
                Shape {   // 21 GLOW
                    visible: stats.mech.graph === "glow"; width: graph.width; height: graph.height; antialiasing: true
                    ShapePath { strokeColor: Theme.withAlpha(stats.accent, 0.10); fillColor: "transparent"; strokeWidth: Math.max(10, 12 * stats.s)
                                capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin; PathPolyline { path: graph.ridgePts } }
                    ShapePath { strokeColor: Theme.withAlpha(stats.accent, 0.22); fillColor: "transparent"; strokeWidth: Math.max(5, 6 * stats.s)
                                capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin; PathPolyline { path: graph.ridgePts } }
                    ShapePath { strokeColor: "#ffffff"; fillColor: "transparent"; strokeWidth: Math.max(1.2, 1.4 * stats.s)
                                capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin; PathPolyline { path: graph.ridgePts } }
                }
                Shape {   // 22 SPARK
                    visible: stats.mech.graph === "spark"; width: graph.width; height: graph.height; antialiasing: true
                    ShapePath { strokeColor: graph.gInk; fillColor: "transparent"; strokeWidth: Math.max(1, stats.s)
                                capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin; PathPolyline { path: graph.ridgePts } }
                }
                Repeater {
                    model: stats.mech.graph === "spark" ? [gcalc.maxIdx, gcalc.minIdx, gcalc.lastI] : []
                    Rectangle {
                        required property var modelData; required property int index
                        readonly property real d: index === 2 ? Math.round(5.5 * stats.s) : Math.round(4 * stats.s)
                        width: d; height: d; radius: d / 2
                        x: graph.px(modelData) - d / 2; y: graph.py(stats.days[modelData].seconds) - d / 2
                        color: index === 0 ? graph.gInk : index === 1 ? Theme.withAlpha(stats.steelInk, 0.8) : stats.accent
                    }
                }
                Repeater {   // 23 HEATMAP
                    model: stats.mech.graph === "heatmap" ? gcalc.n : 0
                    Rectangle {
                        required property int index
                        readonly property int cols: Math.max(1, Math.ceil(gcalc.n / 7))
                        readonly property real cw: (graph.width - graph.pad * 2) / cols
                        readonly property real ch: (graph.base - gcalc.top) / 7
                        x: graph.pad + Math.floor(index / 7) * cw
                        y: gcalc.top + (index % 7) * ch
                        width: cw - Math.max(1, Math.round(2 * stats.s)); height: ch - Math.max(1, Math.round(2 * stats.s))
                        radius: Math.round(2 * stats.s)
                        color: Theme.withAlpha(graph.gInk, 0.1 + 0.85 * (stats.days[index].seconds / graph.peak))
                    }
                }
                Item {   // 24 RADAR
                    id: radar
                    visible: stats.mech.graph === "radar"; anchors.fill: parent
                    readonly property real cx: graph.width / 2
                    readonly property real cy: (gcalc.top + graph.base) / 2
                    readonly property real rr: Math.max(4, Math.min(graph.width, graph.base - gcalc.top) / 2 * 0.82)
                    Repeater {
                        model: 3
                        Shape { required property int index; anchors.fill: parent; antialiasing: true
                            ShapePath { strokeColor: Theme.withAlpha(stats.steelInk, 0.12); fillColor: "transparent"; strokeWidth: Math.max(1, stats.s)
                                PathAngleArc { centerX: radar.cx; centerY: radar.cy
                                    radiusX: radar.rr * (index + 1) / 3; radiusY: radar.rr * (index + 1) / 3; startAngle: 0; sweepAngle: 360 } } }
                    }
                    Shape { anchors.fill: parent; antialiasing: true
                        readonly property var poly: {
                            if (stats.mech.graph !== "radar" || gcalc.n === 0) return []
                            var p = []; for (var i = 0; i < gcalc.n; i++) { var a = i / gcalc.n * 2 * Math.PI - Math.PI / 2
                                var v = stats.days[i].seconds / graph.peak; p.push(Qt.point(parent.cx + Math.cos(a) * parent.rr * v, parent.cy + Math.sin(a) * parent.rr * v)) }
                            if (p.length) p.push(p[0]); return p
                        }
                        ShapePath { fillColor: Theme.withAlpha(graph.gInk, Math.max(0.1, graph.fillA)); strokeColor: graph.gInk
                                    strokeWidth: Math.max(1.2, 1.4 * stats.s); joinStyle: ShapePath.RoundJoin; PathPolyline { path: parent.poly } }
                    }
                }
                // node dots (graphDots) — endpoints on the line-family styles
                Repeater {
                    model: (stats.mech.graphDots === "on" && ["area", "ridge", "line", "dual-line", "gradient-area", "spark", "band", "stacked", "mirror"].indexOf(stats.mech.graph) >= 0) ? gcalc.n : 0
                    Rectangle {
                        required property int index
                        readonly property real d: Math.max(2, Math.round(3 * stats.s))
                        width: d; height: d; radius: d / 2
                        x: graph.px(index) - d / 2; y: graph.py(stats.days[index].seconds) - d / 2
                        color: graph.gInk
                    }
                }
            }
            // mean / AVG reference line (graphMean) — faint dashed datum + tag. key "gmean".
            Item {
                id: gmean
                visible: !stats.classic && (stats.mech.graphMean || "dashed") !== "off" && gcalc.n > 1
                anchors.fill: parent; opacity: stats.eGraph * 0.9
                transform: Translate { x: stats.mOff("gmean")[0]; y: stats.mOff("gmean")[1] }
                Shape {
                    anchors.fill: parent; antialiasing: true
                    ShapePath {
                        strokeColor: Theme.withAlpha(stats.steelInk, 0.42); fillColor: "transparent"
                        strokeWidth: Math.max(1, stats.s)
                        strokeStyle: (stats.mech.graphMean || "dashed") === "line" ? ShapePath.SolidLine : ShapePath.DashLine
                        dashPattern: [4, 4]
                        startX: graph.pad; startY: gcalc.meanY
                        PathLine { x: graph.width - graph.pad; y: gcalc.meanY }
                    }
                }
                Text {
                    x: graph.width - graph.pad - width - Math.round(2 * stats.s); y: gcalc.meanY - height - Math.round(1 * stats.s)
                    text: "AVG " + (Math.round(gcalc.meanSec / 360) / 10) + "H"
                    color: Theme.withAlpha(stats.steelInk, 0.5)
                    font.family: mgsCodec.name; font.pixelSize: stats.pxi(Math.round(7 * stats.s * stats.mScale("gmean"))); font.letterSpacing: 1
                }
            }
            // peak marker (graphPeakMark) — downward pin + drop line + value at the max day. key "pmark".
            Item {
                id: pmark
                visible: !stats.classic && (stats.mech.graphPeakMark || "pin") !== "off" && gcalc.n > 1
                anchors.fill: parent; opacity: stats.eGraph
                transform: Translate { x: stats.mOff("pmark")[0]; y: stats.mOff("pmark")[1] }
                readonly property string ps: stats.mech.graphPeakMark || "pin"
                readonly property real sc: stats.mScale("pmark")
                readonly property real mx: graph.px(gcalc.maxIdx)
                readonly property real my: graph.py(gcalc.maxSec)
                readonly property real pinH: Math.round(9 * stats.s * sc)
                readonly property real pinW: Math.round(11 * stats.s * sc)
                readonly property real gap: Math.round(5 * stats.s)
                // drop line to baseline (dashed "measurement" tick)
                Shape {
                    visible: pmark.ps !== "dot"; antialiasing: true; anchors.fill: parent
                    ShapePath { strokeColor: Theme.withAlpha(stats.steelInk, 0.28); fillColor: "transparent"
                                strokeWidth: Math.max(1, stats.s); strokeStyle: ShapePath.DashLine; dashPattern: [3, 3]
                                startX: pmark.mx; startY: pmark.my
                                PathLine { x: pmark.mx; y: graph.base } }
                }
                // pin/chevron glyph pointing down at the point — a bare, neutral marker
                Shape {
                    visible: pmark.ps === "pin" || pmark.ps === "chevron"; antialiasing: true
                    width: pmark.pinW; height: pmark.pinH
                    x: pmark.mx - width / 2; y: pmark.my - pmark.gap - pmark.pinH
                    ShapePath { fillColor: pmark.ps === "chevron" ? "transparent" : Theme.withAlpha(stats.steelInk, 0.7)
                                strokeColor: Theme.withAlpha(stats.steelInk, 0.7); strokeWidth: Math.max(1, stats.s)
                                joinStyle: ShapePath.RoundJoin
                                startX: 0; startY: 0
                                PathLine { x: pmark.pinW; y: 0 }
                                PathLine { x: pmark.pinW / 2; y: pmark.pinH }
                                PathLine { x: 0; y: 0 } }
                }
                // node dot at the peak point
                Rectangle { readonly property real d: Math.round(5 * stats.s * pmark.sc); width: d; height: d; radius: d / 2
                            x: pmark.mx - d / 2; y: pmark.my - d / 2; color: Qt.lighter(graph.gInk, 1.15) }
            }
            // today node (graphToday) — glowing "you are here" dot on the last point. key not moved (rides last point).
            Item {
                id: todayNode
                visible: !stats.classic && (stats.mech.graphToday || "dot") !== "off" && gcalc.n > 0
                anchors.fill: parent; opacity: stats.eGraph
                readonly property real tx: graph.px(gcalc.lastI)
                readonly property real ty: graph.py(gcalc.lastSec)
                Rectangle {
                    id: pulseRing
                    visible: (stats.mech.graphToday || "dot") === "pulse"
                    readonly property real d: Math.round(8 * stats.s); width: d; height: d; radius: d / 2
                    x: todayNode.tx - d / 2; y: todayNode.ty - d / 2
                    color: "transparent"; border.width: Math.max(1, stats.s); border.color: stats.accent
                    transformOrigin: Item.Center
                    SequentialAnimation on scale {
                        running: pulseRing.visible; loops: Animation.Infinite
                        NumberAnimation { from: 0.6; to: 2.6; duration: 1600; easing.type: Easing.OutCubic }
                        PauseAnimation { duration: 200 }
                    }
                    SequentialAnimation on opacity {
                        running: pulseRing.visible; loops: Animation.Infinite
                        NumberAnimation { from: 0.55; to: 0.0; duration: 1600; easing.type: Easing.InCubic }
                        PauseAnimation { duration: 200 }
                    }
                }
                Rectangle { readonly property real d: Math.round(6 * stats.s); width: d; height: d; radius: d / 2
                            x: todayNode.tx - d / 2; y: todayNode.ty - d / 2; color: stats.accent
                            border.width: Math.max(1, stats.s); border.color: Theme.withAlpha("#ffffff", 0.6) }
            }
            // classic Y axis (byte-identical fallback) — the original labels, legacy "on"
            Repeater {
                model: (stats.classic && stats.mech.graphAxis === "on") ? 3 : 0
                Text {
                    required property int index
                    x: graph.pad + Math.round(2 * stats.s)
                    y: graph.base - (index + 1) / 4 * (graph.base - Math.round(12 * stats.s)) - Math.round(5 * stats.s)
                    text: (Math.round(graph.peak / 360 * (index + 1) / 4 * 10) / 10) + "H"
                    color: Theme.withAlpha(stats.steelInk, 0.4)
                    font.family: mgsCodec.name; font.pixelSize: stats.pxi(Math.round(8 * stats.s))
                }
            }
            // Y axis (graphAxis) — nice-number hour labels in the left gutter, aligned to
            // the grid rows, plus a rotated unit. lock/move/scale key "gaxis".
            Item {
                id: gaxis
                visible: graph.yAxisOn && graph.peak > 1; anchors.fill: parent   // no stray "0.1H" tick on an empty graph
                transform: Translate { x: stats.mOff("gaxis")[0]; y: stats.mOff("gaxis")[1] }
                readonly property real sc: stats.mScale("gaxis")
                readonly property bool pct: (stats.mech.graphAxis || "off") === "pct"
                Repeater {
                    model: graph.tickCount
                    Text {
                        required property int index
                        readonly property real hrs: graph.tickStep * (index + 1)
                        width: graph.pad - Math.round(6 * stats.s); horizontalAlignment: Text.AlignRight
                        x: 0; y: graph.py(hrs * 3600) - height / 2
                        text: gaxis.pct ? Math.round(hrs / Math.max(0.001, graph.peakH) * 100) + "%"
                                        : (Number.isInteger(hrs) ? hrs.toFixed(0) : hrs.toFixed(1)) + "H"
                        color: Theme.withAlpha(stats.ink(stats.mech.terrainInk), 0.5); opacity: stats.eGraph
                        font.family: mgsCodec.name; font.pixelSize: stats.pxi(Math.round(8 * stats.s * gaxis.sc))
                    }
                }
                Repeater {   // tick marks at the plot edge, aligned to each label
                    model: graph.tickCount
                    Rectangle {
                        required property int index
                        readonly property real hrs: graph.tickStep * (index + 1)
                        width: Math.round(3 * stats.s); height: Math.max(1, stats.s)
                        x: graph.pad - width; y: graph.py(hrs * 3600) - height / 2
                        color: Theme.withAlpha(stats.steelInk, 0.45); opacity: stats.eGraph
                    }
                }
                Item {   // rotated unit on the far left
                    x: 0; y: Math.round(12 * stats.s); width: Math.round(11 * stats.s); height: graph.base - Math.round(12 * stats.s)
                    Text {
                        anchors.centerIn: parent; rotation: -90
                        text: gaxis.pct ? "LOAD" : "HOURS"; color: Theme.withAlpha(stats.steelInk, 0.30); opacity: stats.eGraph
                        font.family: mgsCodec.name; font.pixelSize: stats.pxi(Math.round(7 * stats.s * gaxis.sc)); font.letterSpacing: 2
                    }
                }
            }
            // X axis (graphXAxis) — weekly tick labels along the bottom band.
            Item {
                id: gxaxis
                visible: graph.xAxisOn; anchors.fill: parent
                transform: Translate { x: stats.mOff("gxaxis")[0]; y: stats.mOff("gxaxis")[1] }
                readonly property real sc: stats.mScale("gxaxis")
                Repeater {
                    model: graph.weekIdx
                    Text {
                        required property int index; required property var modelData
                        readonly property var labs: ["NOW", "1W", "2W", "3W", "4W"]
                        text: (stats.mech.graphXAxis || "weeks") === "dates"
                              ? ((stats.days[modelData] && stats.days[modelData].day) ? String(stats.days[modelData].day).slice(8) : "")
                              : (labs[index] || "")
                        x: graph.px(modelData) - width / 2; y: graph.base + Math.round(5 * stats.s)
                        color: Theme.withAlpha(stats.ink(stats.mech.terrainInk), index === 0 ? 0.6 : 0.4); opacity: stats.eGraph
                        font.family: mgsCodec.name; font.pixelSize: stats.pxi(Math.round(7.5 * stats.s * gxaxis.sc)); font.letterSpacing: 1
                    }
                }
                Repeater {   // tick marks at the baseline, aligned to each week label
                    model: graph.weekIdx
                    Rectangle {
                        required property var modelData
                        width: Math.max(1, stats.s); height: Math.round(3 * stats.s)
                        x: graph.px(modelData) - width / 2; y: graph.base + Math.round(1 * stats.s)
                        color: Theme.withAlpha(stats.steelInk, 0.45); opacity: stats.eGraph
                    }
                }
            }
            // baseline (BASELINE dial)
            Rectangle {
                visible: stats.mech.graphBase === "line"
                x: graph.pad; y: graph.base; width: (graph.width - graph.pad * 2) * stats.eGraph
                height: Math.max(1, 1.4 * stats.s); color: Theme.withAlpha(graph.gInk, 0.8)
            }
            // peak tag (PEAK TAG dial) — "57H • 30D": the • is a real dot, VERTICALLY CENTERED
            // between the two readouts (the font's "·" glyph sat high). "· 30D" scopes this to the
            // 30-day window so it doesn't read as a second lifetime "TOTAL" vs the hero's.
            Row {
                id: peakTag
                visible: stats.mech.graphPeak === "on"
                anchors.right: parent.right; anchors.top: parent.top
                transform: Translate { x: stats.mOff("peak")[0]; y: stats.mOff("peak")[1] }
                spacing: Math.round(4 * stats.s)
                readonly property real totH: gcalc.totalSec / 3600
                readonly property color pInk: Theme.withAlpha(stats.ink(stats.mech.peakInk), 0.7)
                readonly property int pSize: Math.round(stats.mSz(10, stats.mech.peakSize) * stats.mScale("peak"))
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: stats.caseFor((peakTag.totH >= 10 ? Math.round(peakTag.totH) : Math.round(peakTag.totH * 10) / 10) + "H", stats.mech.peakCase)
                    color: peakTag.pInk; font.family: stats.mechFontFor(stats.mech.peakFont); font.pixelSize: stats.pxi(peakTag.pSize); font.letterSpacing: stats.trackFor(stats.mech.peakTrack)
                }
                Rectangle { anchors.verticalCenter: parent.verticalCenter; width: Math.max(2, Math.round(stats.s * 1.6)); height: width; radius: width / 2; color: peakTag.pInk }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: stats.caseFor("30D", stats.mech.peakCase)
                    color: peakTag.pInk; font.family: stats.mechFontFor(stats.mech.peakFont); font.pixelSize: stats.pxi(peakTag.pSize); font.letterSpacing: stats.trackFor(stats.mech.peakTrack)
                }
            }
        }
    }

    // ── GLOBAL COCKPIT OVERLAY (overlay dial) ────────────────────────────────
    Item {
        id: cockpitOverlay
        anchors.fill: parent
        z: 6
        readonly property string ov: stats.mech.overlay
        visible: ov !== "none"
        readonly property color ink: "#050709"
        readonly property real th: Math.max(1, Math.round(stats.s))

        // vignette
        Rectangle { visible: cockpitOverlay.ov === "vignette"; width: parent.width; height: parent.height * 0.22; anchors.top: parent.top
            gradient: Gradient { GradientStop { position: 0; color: Theme.withAlpha(cockpitOverlay.ink, 0.55) } GradientStop { position: 1; color: "transparent" } } }
        Rectangle { visible: cockpitOverlay.ov === "vignette"; width: parent.width; height: parent.height * 0.22; anchors.bottom: parent.bottom
            gradient: Gradient { GradientStop { position: 0; color: "transparent" } GradientStop { position: 1; color: Theme.withAlpha(cockpitOverlay.ink, 0.55) } } }
        Rectangle { visible: cockpitOverlay.ov === "vignette"; height: parent.height; width: parent.width * 0.16; anchors.left: parent.left
            gradient: Gradient { orientation: Gradient.Horizontal; GradientStop { position: 0; color: Theme.withAlpha(cockpitOverlay.ink, 0.5) } GradientStop { position: 1; color: "transparent" } } }
        Rectangle { visible: cockpitOverlay.ov === "vignette"; height: parent.height; width: parent.width * 0.16; anchors.right: parent.right
            gradient: Gradient { orientation: Gradient.Horizontal; GradientStop { position: 0; color: "transparent" } GradientStop { position: 1; color: Theme.withAlpha(cockpitOverlay.ink, 0.5) } } }

        // edge-glow
        Rectangle { visible: cockpitOverlay.ov === "edge-glow"; width: parent.width; height: parent.height * 0.2; anchors.top: parent.top
            gradient: Gradient { GradientStop { position: 0; color: Theme.withAlpha(stats.accent, 0.16) } GradientStop { position: 1; color: "transparent" } } }
        Rectangle { visible: cockpitOverlay.ov === "edge-glow"; width: parent.width; height: parent.height * 0.2; anchors.bottom: parent.bottom
            gradient: Gradient { GradientStop { position: 0; color: "transparent" } GradientStop { position: 1; color: Theme.withAlpha(stats.accent, 0.16) } } }
        Rectangle { visible: cockpitOverlay.ov === "edge-glow"; height: parent.height; width: parent.width * 0.14; anchors.left: parent.left
            gradient: Gradient { orientation: Gradient.Horizontal; GradientStop { position: 0; color: Theme.withAlpha(stats.accent, 0.14) } GradientStop { position: 1; color: "transparent" } } }
        Rectangle { visible: cockpitOverlay.ov === "edge-glow"; height: parent.height; width: parent.width * 0.14; anchors.right: parent.right
            gradient: Gradient { orientation: Gradient.Horizontal; GradientStop { position: 0; color: "transparent" } GradientStop { position: 1; color: Theme.withAlpha(stats.accent, 0.14) } } }

        // grain
        Item {
            visible: cockpitOverlay.ov === "grain"; anchors.fill: parent; opacity: 0.06
            property int seed: 0
            Timer { interval: 90; repeat: true; running: cockpitOverlay.visible && cockpitOverlay.ov === "grain" && stats.visible; onTriggered: parent.seed = (parent.seed + 1) % 997 }
            Repeater {
                model: 140
                Rectangle {
                    required property int index
                    function rnd(a) { var x = Math.sin((index + 1) * a + parent.seed * 12.9898) * 43758.5453; return x - Math.floor(x) }
                    width: Math.max(1, stats.s); height: width
                    x: rnd(78.233) * cockpitOverlay.width; y: rnd(37.719) * cockpitOverlay.height
                    color: rnd(11.13) > 0.5 ? "#ffffff" : "#000000"
                }
            }
        }

        // dust
        Item {
            visible: cockpitOverlay.ov === "dust"; anchors.fill: parent
            property real drift: 0
            NumberAnimation on drift { from: 0; to: 1; duration: 14000; loops: Animation.Infinite; running: cockpitOverlay.visible && cockpitOverlay.ov === "dust" && stats.visible }
            Repeater {
                model: 46
                Rectangle {
                    required property int index
                    function rnd(a) { var x = Math.sin((index + 1) * a) * 43758.5453; return x - Math.floor(x) }
                    readonly property real d: Math.max(1.5, rnd(5.1) * 2.5 * stats.s)
                    width: d; height: d; radius: d / 2; color: Theme.withAlpha("#dfe8ef", 0.12 + rnd(9.7) * 0.14)
                    x: rnd(78.2) * cockpitOverlay.width
                    y: ((rnd(37.7) + parent.drift * (0.3 + rnd(3.3) * 0.7)) % 1) * cockpitOverlay.height
                }
            }
        }

        // scanlines
        Repeater {
            model: cockpitOverlay.ov === "scanlines" ? Math.ceil(cockpitOverlay.height / Math.max(3, Math.round(3 * stats.s))) : 0
            Rectangle { required property int index; readonly property int pp: Math.max(3, Math.round(3 * stats.s))
                        y: index * pp; width: cockpitOverlay.width; height: Math.max(1, stats.s); color: "#000000"; opacity: 0.16 }
        }

        // scan-sweep
        Rectangle {
            visible: cockpitOverlay.ov === "scan-sweep"; width: parent.width; height: Math.round(90 * stats.s)
            y: stats.scanRoll * (parent.height + height) - height
            gradient: Gradient {
                GradientStop { position: 0.0; color: "transparent" }
                GradientStop { position: 0.5; color: Theme.withAlpha(stats.accent, 0.10) }
                GradientStop { position: 1.0; color: "transparent" } }
        }

        // dot-matrix
        Repeater {
            model: cockpitOverlay.ov === "dot-matrix"
                   ? (Math.ceil(cockpitOverlay.width / Math.round(22 * stats.s)) + 1) * (Math.ceil(cockpitOverlay.height / Math.round(22 * stats.s)) + 1) : 0
            Rectangle {
                required property int index
                readonly property int step: Math.round(22 * stats.s)
                readonly property int cols: Math.ceil(cockpitOverlay.width / step) + 1
                readonly property real d: Math.max(1, Math.round(1.4 * stats.s))
                x: (index % cols) * step; y: Math.floor(index / cols) * step
                width: d; height: d; radius: d / 2; color: Theme.withAlpha("#f4f8fc", 0.10)
            }
        }

        // grid
        Repeater {
            model: cockpitOverlay.ov === "grid" ? Math.ceil(cockpitOverlay.width / Math.round(40 * stats.s)) + 1 : 0
            Rectangle { required property int index; x: index * Math.round(40 * stats.s); width: cockpitOverlay.th; height: cockpitOverlay.height; color: Theme.withAlpha("#f4f8fc", 0.05) }
        }
        Repeater {
            model: cockpitOverlay.ov === "grid" ? Math.ceil(cockpitOverlay.height / Math.round(40 * stats.s)) + 1 : 0
            Rectangle { required property int index; y: index * Math.round(40 * stats.s); height: cockpitOverlay.th; width: cockpitOverlay.width; color: Theme.withAlpha("#f4f8fc", 0.05) }
        }

        // crosshair
        Rectangle { visible: cockpitOverlay.ov === "crosshair"; x: parent.width / 2 - cockpitOverlay.th / 2; width: cockpitOverlay.th; height: parent.height; color: Theme.withAlpha(stats.accent, 0.28) }
        Rectangle { visible: cockpitOverlay.ov === "crosshair"; y: parent.height / 2 - cockpitOverlay.th / 2; height: cockpitOverlay.th; width: parent.width; color: Theme.withAlpha(stats.accent, 0.28) }
        Rectangle { visible: cockpitOverlay.ov === "crosshair"; anchors.centerIn: parent; width: Math.round(16 * stats.s); height: width; radius: width / 2
                    color: "transparent"; border.width: cockpitOverlay.th; border.color: Theme.withAlpha(stats.accent, 0.5) }

        // target-lock + rings — Repeater delegate must be an Item, so wrap each ring's ShapePath
        // in its own Shape (bare ShapePath is not an Item → "Delegate must be of Item type")
        Repeater { model: 3
            Shape { required property int index
                visible: cockpitOverlay.ov === "target-lock" || cockpitOverlay.ov === "rings"; anchors.fill: parent; antialiasing: true
                ShapePath {
                    strokeColor: Theme.withAlpha(stats.accent, cockpitOverlay.ov === "rings" ? 0.12 : 0.22); fillColor: "transparent"; strokeWidth: cockpitOverlay.th
                    PathAngleArc { centerX: cockpitOverlay.width / 2; centerY: cockpitOverlay.height / 2
                        radiusX: Math.min(cockpitOverlay.width, cockpitOverlay.height) * (0.14 + index * 0.12)
                        radiusY: Math.min(cockpitOverlay.width, cockpitOverlay.height) * (0.14 + index * 0.12); startAngle: 0; sweepAngle: 360 } } }
        }
        Rectangle { visible: cockpitOverlay.ov === "target-lock"; x: parent.width / 2 - cockpitOverlay.th / 2; width: cockpitOverlay.th; height: parent.height; color: Theme.withAlpha(stats.accent, 0.2) }
        Rectangle { visible: cockpitOverlay.ov === "target-lock"; y: parent.height / 2 - cockpitOverlay.th / 2; height: cockpitOverlay.th; width: parent.width; color: Theme.withAlpha(stats.accent, 0.2) }

        // corner-brackets + hud-frame
        Repeater {
            model: (cockpitOverlay.ov === "corner-brackets" || cockpitOverlay.ov === "hud-frame") ? 4 : 0
            Item {
                required property int index
                readonly property bool rt: index === 1 || index === 3
                readonly property bool bt: index >= 2
                readonly property real arm: Math.round(40 * stats.s)
                readonly property real inset: Math.round(20 * stats.s)
                readonly property real bth: Math.max(2, Math.round(2 * stats.s))
                x: rt ? cockpitOverlay.width - arm - inset : inset; y: bt ? cockpitOverlay.height - arm - inset : inset; width: arm; height: arm
                Rectangle { x: 0; y: parent.bt ? parent.arm - parent.bth : 0; width: parent.arm; height: parent.bth; color: Theme.withAlpha(stats.accent, 0.7) }
                Rectangle { x: parent.rt ? parent.arm - parent.bth : 0; y: 0; width: parent.bth; height: parent.arm; color: Theme.withAlpha(stats.accent, 0.7) }
            }
        }
        Rectangle { visible: cockpitOverlay.ov === "hud-frame"; anchors.fill: parent; anchors.margins: Math.round(20 * stats.s)
                    color: "transparent"; border.width: cockpitOverlay.th; border.color: Theme.withAlpha(stats.accent, 0.22) }

        // letterbox
        Rectangle { visible: cockpitOverlay.ov === "letterbox"; width: parent.width; height: parent.height * 0.08; anchors.top: parent.top; color: "#000000" }
        Rectangle { visible: cockpitOverlay.ov === "letterbox"; width: parent.width; height: parent.height * 0.08; anchors.bottom: parent.bottom; color: "#000000" }

        // tint-wash
        Rectangle { visible: cockpitOverlay.ov === "tint-wash"; anchors.fill: parent; color: stats.accent; opacity: 0.06 }

        // color-grade
        Rectangle { visible: cockpitOverlay.ov === "color-grade"; anchors.fill: parent; opacity: 0.12
            gradient: Gradient { orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: "#0d3b4a" }
                GradientStop { position: 0.5; color: "transparent" }
                GradientStop { position: 1.0; color: "#4a2f0d" } } }

        // interference
        Item {
            visible: cockpitOverlay.ov === "interference"; anchors.fill: parent
            Repeater {
                model: 3
                Rectangle {
                    required property int index
                    function rnd(a) { var x = Math.sin((index + 1) * a + stats.scanPhase * 3.31) * 43758.5453; return x - Math.floor(x) }
                    width: parent.width; height: Math.round((6 + index * 4) * stats.s)
                    y: rnd(21.7) * cockpitOverlay.height; opacity: 0.05; color: "#ffffff"
                }
            }
        }

        // pulse
        Rectangle { visible: cockpitOverlay.ov === "pulse"; anchors.fill: parent; color: stats.accent; opacity: 0.02 + 0.05 * stats.ambBreathe }

        // top-fade
        Rectangle { visible: cockpitOverlay.ov === "top-fade"; width: parent.width; height: parent.height * 0.35; anchors.top: parent.top
            gradient: Gradient { GradientStop { position: 0; color: Theme.withAlpha(cockpitOverlay.ink, 0.5) } GradientStop { position: 1; color: "transparent" } } }
    }

    // ── TARGET-LOCK HUD (ported from HomeView garageFocus) ───────────────────
    //    Frames the focused cockpit element with an AC reticle: scrim, crosshair,
    //    scan grid, corner brackets, acquire flash, the AC5 scan-info readout and
    //    the I/V/N mode banner. The box glides between elements; a 140ms poll +
    //    onMechChanged keep it glued through size / rowCount / move edits.
    // GARAGE layer, built on demand — same contract as HomeView's: loads the
    // time ` opens the garage, unloads on close, never when SETTINGS ▸ EDITOR is
    // off. Outside code reaches in through the nullable garageFocus/mechEditor.
    readonly property Item garageFocus: garageLoader.item ? garageLoader.item.focusRig : null
    readonly property Item mechEditor: garageLoader.item ? garageLoader.item.editor : null
    property var garageEdState: null
    property bool garageOn: false   // flipped only here + by the linger, never by a binding race
    Timer { id: garageLinger; interval: 400; onTriggered: if (!stats.mechEdit) stats.garageOn = false }   // through the close fade
    Connections {
        target: stats
        function onMechEditChanged() {
            if (stats.mechEdit) { garageLinger.stop(); stats.garageOn = true; return }
            if (stats.mechEditor) stats.garageEdState = stats.mechEditor.saveState()
            garageLinger.restart()
        }
    }
    Loader {
        id: garageLoader
        onLoaded: if (item.editor) item.editor.restoreState(stats.garageEdState)
        anchors.fill: parent
        z: 40
        active: App.editorEnabled && stats.garageOn
        sourceComponent: Component {
        Item {
        readonly property Item focusRig: garageFocus
        readonly property Item editor: mechEditor
            Item {
                id: garageFocus
                anchors.fill: parent
                z: 40
                readonly property string grp: stats.mechEdit ? mechEditor.focusGroup : ""

                // focused dial key → the specific cockpit element to lock onto
                function hingeItem(k) { for (var i = 0; i < hingeRep.count; i++) { var it = hingeRep.itemAt(i); if (it && it.hkey === k) return it } return null }
                function elemFor(k) {
                    if (/^(hcap|hpix|hend|hbar|hstub|hclip)\d+$/.test(k)) return hingeItem(k)
                    switch (k) {
                    case "readout": return boxCol
                    case "topwell": return topWell
                    case "weekwell": return weekWell
                    case "spnum": return spNum
                    case "bigInk": case "bigSize": case "bigFont": case "bigWeight": case "bigTrack": case "big": return bigRow
                    case "labelInk": case "labelSize": case "labFont": case "labelCase": case "labelTrack": case "labelWeight": case "label": return labelText
                    case "statInk": case "statSize": case "statFont": case "statTrack": case "statCase": case "statWeight": case "stats": return statCol
                    case "weekOn": case "weekLabel": case "weekInk": case "weekSize": case "weekFont": case "weekMeter": case "weekCase": case "weekTrack": case "weekWeight": case "week": return weekCol
                    case "ring": case "ringInk": case "ringThick": case "hub": case "ringSpin": case "ringTicks": case "ringGap": case "hubInk": case "hubSize": case "ringCaps": case "hubPulse": return ring
                    case "rowCount": case "chevron": case "chevBack": case "chevShow": case "rowPlate": case "rowBack": case "rowInk":
                    case "rowGap": case "titleInk": case "titleSize": case "titleFont": case "titleWeight": case "titleCase": case "titleTrack": case "titleBack": case "titleShadow":
                    case "bar": case "barBack": case "barGlow": case "pctInk": case "pctBack": case "pctFont": case "pctSize": case "pctTrack": case "pctWeight": case "pctShadow": case "rows": return rows
                    case "rtitle": return stats.selT || rows
                    case "rbar":   return stats.selB || rows
                    case "rowbox": return stats.selBox || rows
                    case "rpct":   return stats.selP || rows
                    case "rchev":  return stats.selC || rows
                    case "spatch": return spatchEl
                    case "hero": case "heroReveal": case "plateGlow": case "plateTint": case "wellGlow": return hero
                    case "headerInk": case "deepLabel": case "headerFont": case "headerSize": case "headerCase": case "headerTrack": case "headerShadow":
                    case "castLen": case "castInk": case "castDir": case "castStep": case "castGap": case "castVec": case "castBright": case "castTone":
                    case "headerGlow": case "headerGlowInk": case "headerGlowSize": case "header": case "headerCrt": return deepHdr
                    case "edgeGlint": case "edgeSpeed": case "edge": return edgeSprite
                    case "posterHdrInk": case "posterHdrBack": case "posterHdrSize": case "posterHdrFont": case "posterHdrCase": case "posterHdrTrack": case "posterHdrWeight": case "phdr": return (poster.heroMode && (stats.mech.heroRankPos || "below") === "below") ? npRank : posterHdr
                    case "posterInk": case "npTitleSize": case "npTitleFont": case "npTitleCase": case "npTitleWeight": case "npTitleTrack": case "ptit": return npTitle
                    case "pyear": return npYear
                    case "npDeepInk": case "npDeepSize": case "npDeepFont": case "npDeepCase": case "npDeepTrack": case "npDeepWeight": case "pdeep": return npDeep
                    case "npEpInk": case "npEpSize": case "npEpFont": case "npEpCase": case "npEpTrack": case "npEpWeight": case "peps": return npEp
                    case "npSep": case "psep": return npSepEl
                    case "posterTitle": case "pname": return pname
                    case "ppill": { var pp = (stats.mech.ppillPlate || "drawn").charAt(0); return pp === "b" ? heroPillPlate : pp === "p" ? heroPillBand : heroPill }
                    case "npbox": { var np = (stats.mech.npboxPlate || "drawn").charAt(0); return np === "b" ? heroNameboxPlate : np === "p" ? heroNameboxBand : heroNamebox }
                    case "poster": case "posterBg": case "posterFrame": case "posterFit": case "posterScan": case "heroCrt": case "heroSweep": case "posterAnim": case "posterTint": case "posterShadow": case "posterGlow":
                    case "brkStyle": case "brkInk": case "brkSize": return poster
                    case "pframe": return posterFrameEl
                    case "phole": return posterCell
                    case "posterEdge": case "pedge": return posterEdgeEl
                    case "heroBezel": case "pbez": return (stats.mech.heroBezel || "off") === "drawn" ? heroBezelEl : heroBezelStock
                    default: break   // hinge overlay keys resolve via the prefix check at top of elemFor
                    case "graph": case "graphInk": case "graphFill": case "graphGrid": case "graphBase": case "graphLabel": case "graphWeight": case "graphDots": case "graphGlow": case "graphWell": case "graphLegend": return graph
                    case "graphAxis": case "gaxis": return gaxis
                    case "graphXAxis": case "gxaxis": return gxaxis
                    case "graphMean": case "gmean": return gmean
                    case "graphPeakMark": case "pmark": return pmark
                    case "graphToday": return todayNode
                    case "terrainInk": case "terrainSize": case "terrainFont": case "terrainCase": case "terrainTrack": case "terrainWeight": case "tlab": return terrainLabel
                    case "graphPeak": case "peakInk": case "peakSize": case "peakFont": case "peakCase": case "peakTrack": case "peak": return peakTag
                    case "crumbInk": case "crumbSize": case "crumbTrack": case "crumbStyle": case "crumbWeight": case "crumbCase": case "crumb": return crumb
                    case "hints": case "hintSize": case "hintInk": case "hintFont": case "hintBack": case "hintCase": case "hintTrack": case "hintWeight": case "hintCaps": case "foot": return footerHint
                    // small promoted readouts (lock + move targets)
                    case "sub": return subTag
                    case "wlab": return weekLab
                    case "wep": return weekEp
                    case "wtt": return weekTt
                    case "pfall": return posterFallback
                    }
                    return null
                }
                // group header → whole-group element (fallback when a dial has no single target)
                function groupItem() {
                    return grp === "HERO PLATE" ? hero
                         : grp === "READOUT" ? boxCol
                         : grp === "WEEK" ? weekCol
                         : grp === "RING" ? ring
                         : grp === "ROWS" ? rows
                         : grp === "POSTER" ? poster
                         : grp === "POSTER TEXT" ? posterHdr
                         : grp === "NAMEPLATE" ? pname
                         : grp === "TERRAIN" ? graph
                         : grp === "GRAPH TEXT" ? graph
                         : grp === "ANIMATION" ? hero
                         : grp === "FOOTER" ? footerHint
                         : null
                }

                // ── mouse: cursor-follow lock + free-drag (combat) ───────────────────
                property real cursorX: -1
                property real cursorY: -1
                property bool hovering: false
                property bool dragging: false
                property bool shiftHeld: false
                property bool ctrlHeld: false
                property string dragKey: ""
                // LIVE-DRAG channel (perf): during a grab-drag ONLY this element's offset
                // updates per pixel — `mOff` short-circuits to it, so just the dragged item
                // re-renders instead of cloning+reassigning the whole ~130-key `mech` (which
                // invalidated ~900 bindings + re-serialized `dirty`) on every mouse-pixel.
                // The full commit is deferred to onReleased.
                property var dragOff: [0, 0]
                // SCAN, unified MANUAL-AIM treatment: Shift AND Ctrl both free-aim the
                // lockbox to the cursor and sync the editor to the element under it; Shift
                // additionally rides the ZOOM lens, Ctrl is manual aim for the grid.
                readonly property bool freeAim: manualMode && cursorX >= 0
                // the MODE BANNER latches on the modifier alone so it doesn't flicker
                readonly property bool manualMode: stats.garageMode === "scan" && (shiftHeld || ctrlHeld) && stats.mechEdit
                readonly property bool zooming: stats.garageMode === "scan" && shiftHeld && hovering && stats.mechEdit
                // Live magnification: the ZOOM dial sets the BASE + on/off; the mouse WHEEL
                // fine-tunes zoomF (0.25 steps, 1.25–8×) and G jumps between dial presets.
                readonly property real zoomBase: stats.mech.zoom === "1.5x" ? 1.5 : stats.mech.zoom === "3x" ? 3 : stats.mech.zoom === "4x" ? 4 : 2
                property real zoomF: zoomBase
                onZoomBaseChanged: zoomF = zoomBase
                readonly property string zoomLabel: (Math.round(zoomF * 100) / 100) + "X"
                function zoomBy(d) { zoomF = Math.max(1.25, Math.min(8, Math.round((zoomF + d) * 20) / 20)) }
                property int lensGridN: 0   // in-lens grid overlay: 0 off · 1 fine · 2 thirds · 3 dots (Alt+L while zooming)
                // smallest movable element under (px,py) — the most specific target wins
                function hitKey(px, py) {
                    var best = "", bestArea = Infinity
                    for (var i = 0; i < stats.moveElems.length; ++i) {
                        var k = stats.moveElems[i].k
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
                readonly property string hoverKey: (hovering && !dragging && !freeAim && stats.mechEdit && stats.garageMode !== "normal"
                                                    && rmbHeld) ? hitKey(cursorX, cursorY) : ""    // plain hover (combat + scan) only follows on RIGHT-click
                readonly property var pointerItem: dragging ? elemFor(dragKey) : (hoverKey ? elemFor(hoverKey) : null)
                // the element under the cursor — drives the EDITOR selection even during
                // manual aim (Shift/Ctrl), so you can zero in on a specific element while
                // the lockbox free-aims. The mouse leads, the dial selection follows.
                readonly property string aimKey: (hovering && !dragging && stats.mechEdit && stats.garageMode !== "normal"
                                                  && (freeAim || rmbHeld)) ? hitKey(cursorX, cursorY) : ""    // manual aim always; else RIGHT-click to follow
                function dialRowForElem(elemKey) {
                    var tgt = elemFor(elemKey)
                    if (!tgt) return -1
                    var rr = mechEditor.rows
                    for (var i = 0; i < rr.length; ++i)
                        if (rr[i].k && elemFor(rr[i].k) === tgt) return i
                    return -1
                }
                // move page: map a hovered element → its moveElems index (mirror of dialRowForElem)
                function moveIdxForElem(key) {
                    var tgt = elemFor(key)
                    if (!tgt) return -1
                    var me = mechEditor.moveElems
                    for (var i = 0; i < me.length; ++i) if (me[i].k && elemFor(me[i].k) === tgt) return i
                    return -1
                }
                onAimKeyChanged: {
                    if (!stats.mechEdit || aimKey === "") return
                    if (mechEditor.page === "dials") {
                        var i = dialRowForElem(aimKey)
                        if (i >= 0 && i !== mechEditor.row) mechEditor.row = i
                    } else if (mechEditor.page === "move") {   // keep the ASSEMBLY selection synced to the hovered element
                        var mi = moveIdxForElem(aimKey)
                        if (mi >= 0 && mi !== mechEditor.moveIdx) mechEditor.moveIdx = mi
                    }
                }

                // touch every reactive dep so this re-evaluates on any change; the mouse
                // (hovered/dragged element) wins over the keyboard-focused dial
                readonly property var targetItem: {
                    if (!stats.mechEdit) return null
                    if (pointerItem) return pointerItem
                    var pg = mechEditor.page
                    if (pg === "move") return elemFor(mechEditor.moveKey) || hero
                    if (pg !== "dials") return null
                    var g = grp
                    return elemFor(mechEditor.focusKey) || groupItem()
                }
                readonly property bool framing: stats.garageMode !== "normal"
                    && (freeAim || (!!targetItem && targetItem.width > 1 && targetItem.height > 1))
                readonly property bool has: stats.mechEdit
                visible: has && opacity > 0.01
                opacity: has ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: DS.base } }

                // the framed rect (stats coords), four reals so it GLIDES element↔element
                property real bx: 0; property real by: 0; property real bw: 0; property real bh: 0
                property bool primed: false
                function recompute() {
                    if (zooming && !ctrlHeld) {
                        // Shift = zoom (no aim): the box wraps the lens region at the cursor.
                        // + Ctrl → falls through to the aim branch = zoom AND aim-fire together
                        var fz = Math.round(150 * stats.s)
                        bx = cursorX - fz / 2; by = cursorY - fz / 2; bw = fz; bh = fz
                    } else if (freeAim) {
                        // Ctrl MANUAL AIM: a cursor-driven floating lockbox (with the GRID)
                        // that rides the pointer — distinct from plain hover-lock, which
                        // snaps to elements. The info x/y reports the cursor, not an element.
                        var fs = Math.round(150 * stats.s)
                        bx = cursorX - fs / 2; by = cursorY - fs / 2; bw = fs; bh = fs
                    } else if (framing && targetItem) {
                        var p = targetItem.mapToItem(stats, 0, 0)
                        var pad = Math.round(9 * stats.s)
                        bx = p.x - pad; by = p.y - pad
                        bw = targetItem.width + 2 * pad; bh = targetItem.height + 2 * pad
                    } else {
                        var m = Math.round(16 * stats.s)
                        bx = m; by = m; bw = width - 2 * m; bh = height - 2 * m
                    }
                    computeTargets()
                }
                // MGSV target acquisition: SCAN mode paints little L-brackets on EVERY editable
                // element (all tags visible, anywhere on screen); holding Ctrl locks the aimed
                // one orange. Computed HERE, not in a binding, to dodge the mapToItem staleness.
                property var lockTargets: []
                function computeTargets() {
                    if (stats.garageMode !== "scan" || !stats.mechEdit) { if (lockTargets.length) lockTargets = []; return }
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
                Timer { id: recomputeTimer; interval: 0; onTriggered: garageFocus.recompute() }
                function scheduleRecompute() { recomputeTimer.restart() }
                onTargetItemChanged: scheduleRecompute()
                onGrpChanged: scheduleRecompute()   // hover-lock must NOT replay the deploy anim
                onFreeAimChanged: recompute()
                onHasChanged: if (has) { primed = false; recompute(); primeTimer.restart() }
                Timer { id: primeTimer; interval: 40; onTriggered: garageFocus.primed = true }
                Timer {
                    running: stats.visible && garageFocus.has && garageFocus.framing && stats.mechEdit
                    interval: 140; repeat: true
                    onTriggered: garageFocus.recompute()
                }
                Connections {
                    target: stats
                    function onWidthChanged() { garageFocus.scheduleRecompute() }
                    function onHeightChanged() { garageFocus.scheduleRecompute() }
                    function onGarageModeChanged() { garageFocus.scheduleRecompute(); reticle.reacquire()
                        if (stats.garageMode !== "scan") reticle.orange = 0 }   // clear the manual-aim amber tint when leaving scan
                    function onMechChanged() { garageFocus.scheduleRecompute() }
                }
                readonly property int glideMs: {
                    var v = (stats.mech && stats.mech.lockGlide) ? stats.mech.lockGlide : "normal"
                    var m = { off: 0, snap: 70, normal: 150, loose: 300 }
                    return m[v] !== undefined ? m[v] : 150
                }
                Behavior on bx { enabled: garageFocus.primed && garageFocus.glideMs > 0; NumberAnimation { duration: garageFocus.glideMs; easing.type: Easing.Bezier; easing.bezierCurve: DS.moveCurve } }
                Behavior on by { enabled: garageFocus.primed && garageFocus.glideMs > 0; NumberAnimation { duration: garageFocus.glideMs; easing.type: Easing.Bezier; easing.bezierCurve: DS.moveCurve } }
                Behavior on bw { enabled: garageFocus.primed && garageFocus.glideMs > 0; NumberAnimation { duration: garageFocus.glideMs; easing.type: Easing.Bezier; easing.bezierCurve: DS.moveCurve } }
                Behavior on bh { enabled: garageFocus.primed && garageFocus.glideMs > 0; NumberAnimation { duration: garageFocus.glideMs; easing.type: Easing.Bezier; easing.bezierCurve: DS.moveCurve } }

                // AUTHORITATIVE modifier state — poll the live OS keyboard while scanning
                Timer {
                    running: stats.visible && stats.mechEdit && stats.garageMode === "scan"
                    interval: 40; repeat: true
                    onTriggered: {
                        var m = App.queryKbdModifiers ? App.queryKbdModifiers() : 0
                        garageFocus.shiftHeld = (m & Qt.ShiftModifier) !== 0
                        garageFocus.ctrlHeld = (m & Qt.ControlModifier) !== 0
                    }
                }

                // HUD colour follows the MODE; RED when there are unsaved changes
                readonly property color hud: stats.garageMode === "scan" ? "#4fd6ea"
                    : stats.garageMode === "normal" ? "#9fb4c2"
                    : (mechEditor.dirty ? "#ff4d4d" : "#f4f8fc")
                // MODE colour for the peripheral HUD (banner + side readouts): manual amber,
                // scan cyan, normal dim, combat white. (The reticle BOX uses lockCol instead —
                // box = target-lock state, peripherals = current mode.)
                // clean per-mode colour — the 3-mode strip uses THIS so it stays unaffected by dirty
                readonly property color cleanModeCol: manualMode ? "#ffcf6b"
                    : stats.garageMode === "scan" ? "#5fcde4"
                    : stats.garageMode === "normal" ? Theme.withAlpha("#f4f8fc", 0.62) : "#f4f8fc"
                // banner + peripheral readouts turn RED on an unsaved change (a live warning)
                readonly property color modeCol: mechEditor.dirty ? "#ff4d4d" : cleanModeCol
                readonly property color scrimCol: "#0a0c12"
                readonly property real scrimA: !framing ? 0.0 : stats.garageMode === "scan" ? 0.22 : 0.6

                // dim mask — four plates around the framed hole
                Rectangle { color: garageFocus.scrimCol; opacity: garageFocus.scrimA; x: 0; y: 0; width: parent.width; height: Math.max(0, garageFocus.by) }
                Rectangle { color: garageFocus.scrimCol; opacity: garageFocus.scrimA; x: 0; y: garageFocus.by + garageFocus.bh; width: parent.width; height: Math.max(0, parent.height - (garageFocus.by + garageFocus.bh)) }
                Rectangle { color: garageFocus.scrimCol; opacity: garageFocus.scrimA; x: 0; y: garageFocus.by; width: Math.max(0, garageFocus.bx); height: garageFocus.bh }
                Rectangle { color: garageFocus.scrimCol; opacity: garageFocus.scrimA; x: garageFocus.bx + garageFocus.bw; y: garageFocus.by; width: Math.max(0, parent.width - (garageFocus.bx + garageFocus.bw)); height: garageFocus.bh }

                // full-screen crosshair — bright at the box, faded at the screen edge
                Item {
                    id: crosshair
                    visible: garageFocus.framing
                    anchors.fill: parent
                    readonly property real ct: Math.max(2, Math.round(2 * stats.s))
                    readonly property color c0: reticle.crossCol
                    readonly property color c1: Theme.withAlpha(reticle.lockCol, 0.16)
                    Rectangle {
                        x: garageFocus.bx + garageFocus.bw / 2 - crosshair.ct / 2; width: crosshair.ct
                        height: garageFocus.by * reticle.extend; y: garageFocus.by - height
                        gradient: Gradient { GradientStop { position: 0; color: crosshair.c1 } GradientStop { position: 1; color: crosshair.c0 } }
                    }
                    Rectangle {
                        x: garageFocus.bx + garageFocus.bw / 2 - crosshair.ct / 2; width: crosshair.ct
                        y: garageFocus.by + garageFocus.bh
                        height: (garageFocus.height - (garageFocus.by + garageFocus.bh)) * reticle.extend
                        gradient: Gradient { GradientStop { position: 0; color: crosshair.c0 } GradientStop { position: 1; color: crosshair.c1 } }
                    }
                    Rectangle {
                        y: garageFocus.by + garageFocus.bh / 2 - crosshair.ct / 2; height: crosshair.ct
                        width: garageFocus.bx * reticle.extend; x: garageFocus.bx - width
                        gradient: Gradient { orientation: Gradient.Horizontal; GradientStop { position: 0; color: crosshair.c1 } GradientStop { position: 1; color: crosshair.c0 } }
                    }
                    Rectangle {
                        y: garageFocus.by + garageFocus.bh / 2 - crosshair.ct / 2; height: crosshair.ct
                        x: garageFocus.bx + garageFocus.bw
                        width: (garageFocus.width - (garageFocus.bx + garageFocus.bw)) * reticle.extend
                        gradient: Gradient { orientation: Gradient.Horizontal; GradientStop { position: 0; color: crosshair.c0 } GradientStop { position: 1; color: crosshair.c1 } }
                    }
                }

                // NORMAL full-screen reference grid — fine cells (always) + thirds + centre
                // cross gated by the SYSTEM grid dials (gridStyle/gridThick/accent), matched
                // to HOME's alignGrid so both screens share one grid grammar.
                Item {
                    id: normalGrid
                    anchors.fill: parent
                    readonly property string gs: mechEditor.sys ? mechEditor.sys.gridStyle : "both"
                    visible: stats.garageMode === "normal" && stats.mechEdit && stats.mechGrid && gs !== "off"
                    z: 2
                    // grid-change flash — dim then re-brighten as the style swaps
                    onGsChanged: normalGridPulse.restart()
                    SequentialAnimation { id: normalGridPulse
                        NumberAnimation { target: normalGrid; property: "opacity"; to: 0.15; duration: 70; easing.type: Easing.OutQuad }
                        NumberAnimation { target: normalGrid; property: "opacity"; to: 1; duration: 260; easing.type: Easing.OutCubic } }
                    readonly property color base: mechEditor.sysColor()
                    readonly property color gcol: Theme.withAlpha(base, 0.13)
                    readonly property color gcolHi: Theme.withAlpha(base, 0.26)
                    readonly property int gt: mechEditor.sys ? (mechEditor.sys.gridThick === "med" ? 2 : mechEditor.sys.gridThick === "thick" ? 3 : 1) : 1
                    readonly property bool crossOn: gs === "cross" || gs === "both"
                    readonly property bool thirdsOn: gs === "thirds" || gs === "both"
                    readonly property int cell: Math.round(52 * stats.s)
                    // fine cell base (always while the grid is up)
                    Repeater { model: Math.ceil(normalGrid.width / normalGrid.cell) + 1
                        Rectangle { required property int index; x: index * normalGrid.cell; width: 1; height: normalGrid.height; color: normalGrid.gcol } }
                    Repeater { model: Math.ceil(normalGrid.height / normalGrid.cell) + 1
                        Rectangle { required property int index; y: index * normalGrid.cell; height: 1; width: normalGrid.width; color: normalGrid.gcol } }
                    // thirds
                    Repeater { model: normalGrid.thirdsOn ? 2 : 0; Rectangle { required property int index; x: Math.round(normalGrid.width * (index + 1) / 3); width: normalGrid.gt; height: normalGrid.height; color: normalGrid.gcolHi } }
                    Repeater { model: normalGrid.thirdsOn ? 2 : 0; Rectangle { required property int index; y: Math.round(normalGrid.height * (index + 1) / 3); height: normalGrid.gt; width: normalGrid.width; color: normalGrid.gcolHi } }
                    // centre cross
                    Rectangle { visible: normalGrid.crossOn; anchors.horizontalCenter: parent.horizontalCenter; width: normalGrid.gt; height: parent.height; color: normalGrid.gcolHi }
                    Rectangle { visible: normalGrid.crossOn; anchors.verticalCenter: parent.verticalCenter; height: normalGrid.gt; width: parent.width; color: normalGrid.gcolHi }
                }

                // SCAN grid — clipped to the lockbox, scan mode only. GRID 1/2/3 (the `g`
                // cycle) picks 3 curated overlay styles for precise manual aim.
                Item {
                    id: scanGrid
                    visible: stats.garageMode === "scan" && garageFocus.framing && !garageFocus.zooming
                    x: garageFocus.bx; y: garageFocus.by; width: garageFocus.bw; height: garageFocus.bh
                    clip: true
                    readonly property string gs: ["fine", "cross", "dots"][stats.scanGridN - 1] || "fine"   // GRID 1/2/3 = fine lines / grid+cross / dots (HOME parity)
                    onGsChanged: scanGridPulse.restart()   // grid-change flash in the lockbox
                    SequentialAnimation { id: scanGridPulse
                        NumberAnimation { target: scanGrid; property: "opacity"; to: 0.15; duration: 70; easing.type: Easing.OutQuad }
                        NumberAnimation { target: scanGrid; property: "opacity"; to: 1; duration: 260; easing.type: Easing.OutCubic } }
                    readonly property int  cell: Math.max(8, Math.round(13 * stats.s))
                    readonly property int  fcell: gs === "fine" ? Math.max(6, Math.round(cell / 1.7)) : gs === "coarse" ? cell * 2 : cell
                    readonly property color gcol: Theme.withAlpha("#f4f8fc", 0.16)
                    readonly property color gcolHi: Theme.withAlpha("#f4f8fc", 0.30)
                    readonly property real cx: width / 2
                    readonly property real cy: height / 2
                    readonly property real th: Math.max(1, Math.round(stats.s))
                    readonly property bool lineFam: ["cross", "fine", "coarse", "lines-h", "lines-v", "blueprint"].indexOf(gs) >= 0

                    Repeater {
                        model: (scanGrid.lineFam && scanGrid.gs !== "lines-h") ? Math.ceil(scanGrid.width / scanGrid.fcell) + 1 : 0
                        Rectangle { required property int index; x: index * scanGrid.fcell; width: scanGrid.th; height: scanGrid.height; color: scanGrid.gcol }
                    }
                    Repeater {
                        model: (scanGrid.lineFam && scanGrid.gs !== "lines-v") ? Math.ceil(scanGrid.height / scanGrid.fcell) + 1 : 0
                        Rectangle { required property int index; y: index * scanGrid.fcell; height: scanGrid.th; width: scanGrid.width; color: scanGrid.gcol }
                    }
                    Repeater {
                        model: scanGrid.gs === "blueprint" ? Math.ceil(scanGrid.width / (scanGrid.fcell * 4)) + 1 : 0
                        Rectangle { required property int index; x: index * scanGrid.fcell * 4; width: scanGrid.th; height: scanGrid.height; color: scanGrid.gcolHi }
                    }
                    Repeater {
                        model: scanGrid.gs === "blueprint" ? Math.ceil(scanGrid.height / (scanGrid.fcell * 4)) + 1 : 0
                        Rectangle { required property int index; y: index * scanGrid.fcell * 4; height: scanGrid.th; width: scanGrid.width; color: scanGrid.gcolHi }
                    }
                    Repeater {
                        model: scanGrid.gs === "dots" ? (Math.ceil(scanGrid.width / scanGrid.cell) + 1) * (Math.ceil(scanGrid.height / scanGrid.cell) + 1) : 0
                        Rectangle {
                            required property int index
                            readonly property int cols: Math.ceil(scanGrid.width / scanGrid.cell) + 1
                            readonly property real d: Math.max(1.5, Math.round(1.6 * stats.s))
                            x: (index % cols) * scanGrid.cell - d / 2; y: Math.floor(index / cols) * scanGrid.cell - d / 2
                            width: d; height: d; radius: d / 2; color: scanGrid.gcolHi
                        }
                    }
                    Repeater { model: scanGrid.gs === "thirds" ? 2 : 0
                        Rectangle { required property int index; x: scanGrid.width * (index + 1) / 3; width: scanGrid.th; height: scanGrid.height; color: scanGrid.gcolHi } }
                    Repeater { model: scanGrid.gs === "thirds" ? 2 : 0
                        Rectangle { required property int index; y: scanGrid.height * (index + 1) / 3; height: scanGrid.th; width: scanGrid.width; color: scanGrid.gcolHi } }
                    Rectangle { visible: scanGrid.gs === "crosshair" || scanGrid.gs === "cross"; x: scanGrid.cx - scanGrid.th / 2; width: scanGrid.th; height: scanGrid.height; color: scanGrid.gcolHi }
                    Rectangle { visible: scanGrid.gs === "crosshair" || scanGrid.gs === "cross"; y: scanGrid.cy - scanGrid.th / 2; height: scanGrid.th; width: scanGrid.width; color: scanGrid.gcolHi }
                    Rectangle { visible: scanGrid.gs === "crosshair"; anchors.centerIn: parent; width: Math.round(6 * stats.s); height: width; radius: width / 2
                                color: "transparent"; border.width: scanGrid.th; border.color: scanGrid.gcolHi }
                    Shape {
                        visible: scanGrid.gs === "iso" || scanGrid.gs === "diamond"; anchors.fill: parent; antialiasing: true
                        readonly property real dx: scanGrid.gs === "iso" ? scanGrid.height * 2 : scanGrid.height
                        readonly property var lines: {
                            if (scanGrid.gs !== "iso" && scanGrid.gs !== "diamond") return []
                            var L = [], step = scanGrid.cell * (scanGrid.gs === "iso" ? 1.4 : 1)
                            for (var x = -dx; x < scanGrid.width + dx; x += step) {
                                L.push([Qt.point(x, 0), Qt.point(x + dx, scanGrid.height)])
                                L.push([Qt.point(x, 0), Qt.point(x - dx, scanGrid.height)])
                            }
                            return L
                        }
                        ShapePath { strokeColor: scanGrid.gcol; fillColor: "transparent"; strokeWidth: scanGrid.th; PathMultiline { paths: parent.lines } }
                    }
                    Shape {
                        visible: scanGrid.gs === "dashed"; anchors.fill: parent; antialiasing: true
                        readonly property var lines: {
                            if (scanGrid.gs !== "dashed") return []
                            var L = []; for (var x = 0; x <= scanGrid.width; x += scanGrid.cell) L.push([Qt.point(x, 0), Qt.point(x, scanGrid.height)])
                            for (var y = 0; y <= scanGrid.height; y += scanGrid.cell) L.push([Qt.point(0, y), Qt.point(scanGrid.width, y)]); return L
                        }
                        ShapePath { strokeColor: scanGrid.gcol; fillColor: "transparent"; strokeWidth: scanGrid.th
                                    strokeStyle: ShapePath.DashLine; dashPattern: [2, 3]; PathMultiline { paths: parent.lines } }
                    }
                    Repeater {
                        model: scanGrid.gs === "hex" ? Math.ceil(scanGrid.width / (scanGrid.cell * 1.5)) * (Math.ceil(scanGrid.height / (scanGrid.cell * 1.3)) + 1) : 0
                        Shape {
                            required property int index
                            readonly property real r: scanGrid.cell * 0.85
                            readonly property int cols: Math.max(1, Math.ceil(scanGrid.width / (scanGrid.cell * 1.5)))
                            readonly property int col: index % cols
                            readonly property int row: Math.floor(index / cols)
                            readonly property real hx: col * scanGrid.cell * 1.5 + (row % 2) * scanGrid.cell * 0.75
                            readonly property real hy: row * scanGrid.cell * 1.3
                            anchors.fill: parent; antialiasing: true
                            ShapePath {
                                strokeColor: scanGrid.gcol; fillColor: "transparent"; strokeWidth: scanGrid.th
                                PathPolyline { path: [
                                    Qt.point(parent.hx + parent.r, parent.hy),
                                    Qt.point(parent.hx + parent.r * Math.cos(Math.PI / 3),  parent.hy + parent.r * Math.sin(Math.PI / 3)),
                                    Qt.point(parent.hx + parent.r * Math.cos(2 * Math.PI / 3), parent.hy + parent.r * Math.sin(2 * Math.PI / 3)),
                                    Qt.point(parent.hx - parent.r, parent.hy),
                                    Qt.point(parent.hx + parent.r * Math.cos(4 * Math.PI / 3), parent.hy + parent.r * Math.sin(4 * Math.PI / 3)),
                                    Qt.point(parent.hx + parent.r * Math.cos(5 * Math.PI / 3), parent.hy + parent.r * Math.sin(5 * Math.PI / 3)),
                                    Qt.point(parent.hx + parent.r, parent.hy) ] }
                            }
                        }
                    }
                    Shape {
                        visible: scanGrid.gs === "perspective"; anchors.fill: parent; antialiasing: true
                        readonly property real vx: scanGrid.cx
                        readonly property real vy: scanGrid.height * 0.26
                        readonly property var lines: {
                            if (scanGrid.gs !== "perspective") return []
                            var L = [], k, K = 7
                            for (k = 0; k <= K; k++) { var bx = scanGrid.width * k / K; L.push([Qt.point(vx, vy), Qt.point(bx, scanGrid.height)]) }
                            for (k = 1; k <= 6; k++) { var yy = vy + (scanGrid.height - vy) * Math.pow(k / 6, 2); L.push([Qt.point(0, yy), Qt.point(scanGrid.width, yy)]) }
                            return L
                        }
                        ShapePath { strokeColor: scanGrid.gcol; fillColor: "transparent"; strokeWidth: scanGrid.th; PathMultiline { paths: parent.lines } }
                    }
                    Repeater {
                        model: scanGrid.gs === "radar-rings" ? 4 : 0
                        Shape { required property int index; anchors.fill: parent; antialiasing: true
                            ShapePath { strokeColor: scanGrid.gcol; fillColor: "transparent"; strokeWidth: scanGrid.th
                                PathAngleArc { centerX: scanGrid.cx; centerY: scanGrid.cy
                                    radiusX: Math.min(scanGrid.width, scanGrid.height) / 2 * (index + 1) / 4
                                    radiusY: Math.min(scanGrid.width, scanGrid.height) / 2 * (index + 1) / 4; startAngle: 0; sweepAngle: 360 } } }
                    }
                    Repeater {
                        model: scanGrid.gs === "radar-rings" ? 8 : 0
                        Rectangle { required property int index; x: scanGrid.cx - scanGrid.th / 2; y: scanGrid.cy
                                    width: scanGrid.th; height: Math.min(scanGrid.width, scanGrid.height) / 2
                                    transformOrigin: Item.Top; rotation: index * 45; color: scanGrid.gcol }
                    }
                    Repeater {
                        model: scanGrid.gs === "ticks" ? Math.ceil(scanGrid.width / scanGrid.cell) + 1 : 0
                        Item { required property int index; readonly property real len: (index % 5 === 0) ? Math.round(8 * stats.s) : Math.round(4 * stats.s)
                            Rectangle { x: index * scanGrid.cell; y: 0; width: scanGrid.th; height: parent.len; color: scanGrid.gcolHi }
                            Rectangle { x: index * scanGrid.cell; y: scanGrid.height - parent.len; width: scanGrid.th; height: parent.len; color: scanGrid.gcolHi } }
                    }
                    Repeater {
                        model: scanGrid.gs === "ticks" ? Math.ceil(scanGrid.height / scanGrid.cell) + 1 : 0
                        Item { required property int index; readonly property real len: (index % 5 === 0) ? Math.round(8 * stats.s) : Math.round(4 * stats.s)
                            Rectangle { y: index * scanGrid.cell; x: 0; height: scanGrid.th; width: parent.len; color: scanGrid.gcolHi }
                            Rectangle { y: index * scanGrid.cell; x: scanGrid.width - parent.len; height: scanGrid.th; width: parent.len; color: scanGrid.gcolHi } }
                    }
                    Repeater {
                        model: scanGrid.gs === "ruler" ? Math.ceil(scanGrid.width / scanGrid.cell) + 1 : 0
                        Rectangle { required property int index; x: index * scanGrid.cell; y: 0; width: scanGrid.th
                                    height: (index % 5 === 0) ? Math.round(11 * stats.s) : Math.round(5 * stats.s)
                                    color: (index % 5 === 0) ? scanGrid.gcolHi : scanGrid.gcol }
                    }
                    Repeater {
                        model: scanGrid.gs === "ruler" ? Math.ceil(scanGrid.height / scanGrid.cell) + 1 : 0
                        Rectangle { required property int index; y: index * scanGrid.cell; x: 0; height: scanGrid.th
                                    width: (index % 5 === 0) ? Math.round(11 * stats.s) : Math.round(5 * stats.s)
                                    color: (index % 5 === 0) ? scanGrid.gcolHi : scanGrid.gcol }
                    }
                    Repeater {
                        model: (scanGrid.gs === "bracket-corners" || scanGrid.gs === "target-lock") ? 4 : 0
                        Item {
                            required property int index
                            readonly property bool rt: index === 1 || index === 3
                            readonly property bool bt: index >= 2
                            readonly property real arm: Math.round(16 * stats.s)
                            x: rt ? scanGrid.width - arm : 0; y: bt ? scanGrid.height - arm : 0; width: arm; height: arm
                            Rectangle { x: 0; y: parent.bt ? parent.arm - scanGrid.th : 0; width: parent.arm; height: scanGrid.th; color: scanGrid.gcolHi }
                            Rectangle { x: parent.rt ? parent.arm - scanGrid.th : 0; y: 0; width: scanGrid.th; height: parent.arm; color: scanGrid.gcolHi }
                        }
                    }
                    Rectangle { visible: scanGrid.gs === "target-lock"; x: scanGrid.cx - scanGrid.th / 2; width: scanGrid.th; height: scanGrid.height; color: scanGrid.gcol }
                    Rectangle { visible: scanGrid.gs === "target-lock"; y: scanGrid.cy - scanGrid.th / 2; height: scanGrid.th; width: scanGrid.width; color: scanGrid.gcol }
                    Shape { visible: scanGrid.gs === "target-lock"; anchors.fill: parent; antialiasing: true
                        ShapePath { strokeColor: scanGrid.gcolHi; fillColor: "transparent"; strokeWidth: scanGrid.th
                            PathAngleArc { centerX: scanGrid.cx; centerY: scanGrid.cy
                                radiusX: Math.min(scanGrid.width, scanGrid.height) * 0.28; radiusY: Math.min(scanGrid.width, scanGrid.height) * 0.28; startAngle: 0; sweepAngle: 360 } } }
                }

                // the reticle
                Item {
                    id: reticle
                    x: garageFocus.bx; y: garageFocus.by; width: garageFocus.bw; height: garageFocus.bh
                    property real lock: 1
                    property real flash: 0
                    // manual-aim lock tint: 0 = blue (hud), 1 = orange (#ffcf6b). Each time the
                    // aim ACQUIRES a (new) element while manual-aiming it snaps to blue then
                    // warms to orange — a blue flash reading as "re-locked". Blue everywhere else.
                    property real orange: 0
                    readonly property string lockTarget: (garageFocus.manualMode && garageFocus.aimKey !== "") ? garageFocus.aimKey : ""
                    onLockTargetChanged: { if (lockTarget !== "") orangeAcquire.restart(); else orange = 0 }
                    property real breathe: 1
                    property real extend: 1
                    transform: Scale { origin.x: reticle.width / 2; origin.y: reticle.height / 2
                                       xScale: 1 + 0.045 * reticle.lock; yScale: 1 + 0.045 * reticle.lock }
                    function acquire() { lockAnim.restart(); flashAnim.restart(); scanAnim.restart(); extendAnim.restart() }
                    function reacquire() { lockAnim.restart(); extendAnim.restart() }
                    Component.onCompleted: acquire()
                    Connections { target: garageFocus
                        function onGrpChanged() { reticle.acquire() }
                        function onTargetItemChanged() { reticle.acquire() } }
                    NumberAnimation { id: lockAnim; target: reticle; property: "lock"; from: 1; to: 0; duration: 200; easing.type: Easing.OutCubic }
                    SequentialAnimation { id: flashAnim
                        NumberAnimation { target: reticle; property: "flash"; to: 1; duration: 40 }
                        NumberAnimation { target: reticle; property: "flash"; to: 0; duration: 260; easing.type: Easing.OutQuad } }
                    SequentialAnimation { id: orangeAcquire        // blue flash → warm to orange
                        NumberAnimation { target: reticle; property: "orange"; to: 0; duration: 70 }
                        NumberAnimation { target: reticle; property: "orange"; to: 1; duration: 300; easing.type: Easing.OutCubic } }
                    NumberAnimation { id: extendAnim; target: reticle; property: "extend"; from: 0; to: 1; duration: 380; easing.type: Easing.OutCubic }
                    SequentialAnimation { running: stats.visible && stats.mechEdit; loops: Animation.Infinite
                        NumberAnimation { target: reticle; property: "breathe"; to: 0.4; duration: 1500; easing.type: Easing.InOutSine }
                        NumberAnimation { target: reticle; property: "breathe"; to: 1; duration: 1500; easing.type: Easing.InOutSine } }

                    // hud (blue) → orange (#ffcf6b) by `orange` — the manual-aim lock tint
                    readonly property color lockCol: Qt.rgba(
                        garageFocus.hud.r + (1.0   - garageFocus.hud.r) * orange,
                        garageFocus.hud.g + (0.812 - garageFocus.hud.g) * orange,
                        garageFocus.hud.b + (0.42  - garageFocus.hud.b) * orange, 1)
                    readonly property color edge: "#222034"
                    readonly property real arm: Math.round(20 * stats.s)
                    readonly property real th: Math.max(2, Math.round(4 * stats.s * (mechEditor.sys ? ({ thin: 0.6, med: 1, thick: 1.5 }[mechEditor.sys.lockThick] || 1) : 1)))
                    readonly property real spread: lock * Math.round(30 * stats.s)   // brackets clamp in from wide on acquire
                    readonly property color c: lockCol   // opaque so the corner brackets OCCLUDE the marching dashes beneath them
                    readonly property color crossCol: Theme.withAlpha(lockCol, 0.34 + 0.24 * breathe + 0.3 * flash)

                    Rectangle { anchors.fill: parent; color: garageFocus.hud; opacity: 0.14 * reticle.flash }

                    Shape {
                        id: safeArea
                        anchors.fill: parent
                        anchors.margins: Math.round(reticle.th / 2)
                        ShapePath {
                            id: safePath
                            strokeColor: Theme.withAlpha(reticle.lockCol, 0.72)
                            strokeWidth: Math.max(1, Math.round(1 * stats.s))
                            fillColor: "transparent"
                            strokeStyle: ShapePath.DashLine
                            dashPattern: [2, 3]
                            startX: 0; startY: 0
                            PathLine { x: safeArea.width; y: 0 }
                            PathLine { x: safeArea.width; y: safeArea.height }
                            PathLine { x: 0; y: safeArea.height }
                            PathLine { x: 0; y: 0 }
                        }
                        NumberAnimation { target: safePath; property: "dashOffset"; from: 0; to: 5; duration: 700; loops: Animation.Infinite; running: stats.visible && stats.mechEdit }
                    }

                    Rectangle { id: scanline
                        x: 0; width: parent.width; height: Math.max(1, Math.round(1 * stats.s))
                        color: reticle.lockCol; opacity: 0
                        NumberAnimation { id: scanAnim; target: scanline; property: "y"; from: 0; to: reticle.height; duration: 420; easing.type: Easing.OutSine }
                        SequentialAnimation { running: scanAnim.running
                            NumberAnimation { target: scanline; property: "opacity"; to: 0.5; duration: 40 }
                            NumberAnimation { target: scanline; property: "opacity"; to: 0; duration: 380 } } }

                    // four corner brackets
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

                    // MGS readout — mode/part title (tinted marker) + box coords + tool-state chip.
                    // Same structure in every editing sub-mode so it reads cohesively:
                    //   manual aim → "▸ PART"  /  "X Y  ◇ GRID n [G]"
                    //   zoom       → "▸ ZOOM"  /  "X Y  ◇ ZOOM 2x [G]"
                    Column {
                        id: readCol
                        visible: garageFocus.framing && (stats.canEdit || garageFocus.zooming)   // readouts when editing OR zooming
                        readonly property bool assembling: mechEditor.page === "move"
                        readonly property var moff: assembling ? stats.mOff(mechEditor.moveKey) : [0, 0]
                        readonly property bool clear: garageFocus.by > Math.round(52 * stats.s)
                        x: 0
                        y: clear ? -(height + Math.round(5 * stats.s)) : Math.round(5 * stats.s)
                        opacity: clear ? 1 : 0.12
                        Behavior on opacity { NumberAnimation { duration: DS.base } }
                        spacing: Math.round(1 * stats.s)
                        // subtle drop shadow so the readout reads on any backdrop
                        layer.enabled: true
                        layer.effect: MultiEffect {
                            shadowEnabled: true; shadowColor: "#000000"
                            shadowBlur: 0.7; shadowVerticalOffset: 1; shadowOpacity: 0.65
                        }
                        Row {  // left label-stack (title over coords) + the right-side tool-state chip
                            spacing: Math.round(24 * stats.s)
                            Column {  // left: mode/part title above the x/y coords
                                spacing: Math.round(2 * stats.s)
                                Item {
                                    height: Math.max(tagIcon.height, tagText.height)
                                    width: tagIcon.width + Math.round(6 * stats.s) + tagText.width
                                    Item {
                                        id: tagIcon
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: Math.round(18 * stats.s); height: width
                                        Image { id: tagIconSrc; anchors.fill: parent; source: (App.heroDevRev, stats.devSrc("icon-play")); fillMode: Image.PreserveAspectFit; smooth: false; visible: false }
                                        MultiEffect { anchors.fill: parent; source: tagIconSrc; colorization: 1.0; colorizationColor: garageFocus.modeCol }
                                    }
                                    Text {
                                        id: tagText
                                        anchors.left: tagIcon.right; anchors.leftMargin: Math.round(6 * stats.s)
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: readCol.assembling ? mechEditor.moveLabel : garageFocus.zooming ? (garageFocus.ctrlHeld ? "ZOOM AIM" : "ZOOM") : (garageFocus.freeAim && !garageFocus.aimKey) ? "MANUAL AIM" : garageFocus.grp
                                        color: garageFocus.modeCol
                                        font.family: mgsCodec.name; font.bold: true
                                        font.pixelSize: stats.pxi(Math.round(20 * stats.s)); font.letterSpacing: 3
                                    }
                                }
                                Row {  // x/y line — in MANUAL AIM the GRID chip sits inline right after it
                                    spacing: Math.round(11 * stats.s)
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: readCol.assembling
                                            ? "Δ " + readCol.moff[0] + " , " + readCol.moff[1] + (mechEditor.moveSizable ? "   ×" + mechEditor.moveScale.toFixed(2) : "")     // ASSEMBLY: offset (+ scale if sizable)
                                            : stats.garageMode === "scan"
                                            ? "X " + Math.round(garageFocus.cursorX) + "  Y " + Math.round(garageFocus.cursorY)
                                            : "X " + Math.round(garageFocus.bx) + "  Y " + Math.round(garageFocus.by) + "   " + Math.round(garageFocus.bw) + "×" + Math.round(garageFocus.bh)
                                        color: Theme.withAlpha(garageFocus.modeCol, 0.92)
                                        font.family: mgsHud.name; font.pixelSize: stats.pxi(Math.round(14 * stats.s)); font.letterSpacing: 1
                                    }
                                    Row {  // MANUAL AIM inline chip — GRID n + [g], compact on the x/y line
                                        visible: stats.garageMode === "scan" && !garageFocus.zooming
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: Math.round(5 * stats.s)
                                        Text { anchors.verticalCenter: parent.verticalCenter
                                            text: "GRID " + stats.scanGridN
                                            color: Theme.withAlpha(garageFocus.modeCol, 0.95); font.family: mgsHud.name; font.bold: true
                                            font.pixelSize: stats.pxi(Math.round(14 * stats.s)); font.letterSpacing: 1 }
                                        Rectangle {
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: gKk.width + Math.round(6 * stats.s); height: gKk.height + Math.round(3 * stats.s)
                                            radius: 2; color: Theme.withAlpha(garageFocus.modeCol, 0.16)
                                            border.width: 1; border.color: Theme.withAlpha(garageFocus.modeCol, 0.5)
                                            Text { id: gKk; anchors.centerIn: parent; text: "G"; color: garageFocus.modeCol
                                                font.family: mgsHud.name; font.bold: true; font.pixelSize: stats.pxi(Math.round(11 * stats.s))}
                                        }
                                    }
                                    Row {  // ZOOM inline chip — level + [g] on the x/y line (was far right)
                                        visible: garageFocus.zooming
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: Math.round(5 * stats.s)
                                        Text { anchors.verticalCenter: parent.verticalCenter
                                            text: garageFocus.zoomLabel
                                            color: Theme.withAlpha(garageFocus.modeCol, 0.95); font.family: mgsHud.name; font.bold: true
                                            font.pixelSize: stats.pxi(Math.round(16 * stats.s)); font.letterSpacing: 1 }
                                        Rectangle {
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: gKkZ.width + Math.round(6 * stats.s); height: gKkZ.height + Math.round(3 * stats.s)
                                            radius: 2; color: Theme.withAlpha(garageFocus.modeCol, 0.16)
                                            border.width: 1; border.color: Theme.withAlpha(garageFocus.modeCol, 0.5)
                                            Text { id: gKkZ; anchors.centerIn: parent; text: "G"; color: garageFocus.modeCol
                                                font.family: mgsHud.name; font.bold: true; font.pixelSize: stats.pxi(Math.round(11 * stats.s))}
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
                        readonly property real pad: Math.max(2, Math.min(Math.round(8 * stats.s), Math.round(md * 0.1)))
                        property real arm: Math.max(Math.round(6 * stats.s), Math.min(Math.round(20 * stats.s), Math.round(md * 0.3))) * (primary ? 1.25 : 1)
                        readonly property real th: Math.max(1, Math.round((primary ? 2 : 1.4) * stats.s))
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

                // AC5 scan-info — the focused dial's label / value / slider / count
                Item {
                    id: scanInfo
                    visible: garageFocus.framing && stats.mechEdit && stats.canEdit && mechEditor.page === "dials"
                             && mechEditor.focusDialLabel.length > 0 && mechEditor.focusDialOpts.length > 0
                    readonly property color mc: garageFocus.modeCol
                    readonly property int curIdx: mechEditor.focusDialOpts.indexOf(mechEditor.focusDialCur)
                    readonly property real gap: Math.round(28 * stats.s)
                    // sit on whichever side of the lockbox has MORE room to the screen
                    // edge, so the readout never crams against an edge / covers content
                    readonly property bool infoLeft: garageFocus.bx > (garageFocus.width - garageFocus.bx - garageFocus.bw)
                    width: infoCol.width; height: infoCol.height
                    x: infoLeft ? Math.max(Math.round(8 * stats.s), garageFocus.bx - gap - width)
                                : Math.min(garageFocus.width - width - Math.round(8 * stats.s), garageFocus.bx + garageFocus.bw + gap)
                    y: Math.max(Math.round(10 * stats.s), Math.min(garageFocus.height - height - Math.round(10 * stats.s), garageFocus.by + garageFocus.bh / 2 - height / 2))
                    opacity: visible ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: DS.base } }
                    Column {
                        id: infoCol
                        spacing: Math.round(5 * stats.s)
                        Row {
                            spacing: Math.round(6 * stats.s)
                            Rectangle { anchors.verticalCenter: parent.verticalCenter; width: Math.round(7 * stats.s); height: width; rotation: 45; color: scanInfo.mc }
                            Text { text: mechEditor.focusDialLabel; color: scanInfo.mc
                                font.family: mgsCodec.name; font.bold: true; font.pixelSize: stats.pxi(Math.round(19 * stats.s)); font.letterSpacing: 3 }
                        }
                        Row {
                            spacing: Math.round(7 * stats.s)
                            Rectangle { visible: mechEditor.focusIsInk && String(mechEditor.focusDialCur) !== "auto"
                                anchors.verticalCenter: parent.verticalCenter
                                width: Math.round(17 * stats.s); height: width
                                color: mechEditor.focusIsInk ? stats.mechInk(mechEditor.focusDialCur) : "transparent"
                                border.width: 1; border.color: "#222034" }
                            Text { text: mechEditor.fmt(mechEditor.focusDialCur); color: scanInfo.mc
                                font.family: mgsHud.name; font.bold: true; font.pixelSize: stats.pxi(Math.round(26 * stats.s)); font.letterSpacing: 2 }
                        }
                        Row {
                            spacing: Math.round(3 * stats.s)
                            Repeater {
                                model: mechEditor.focusDialOpts.length
                                Rectangle { required property int index
                                    width: Math.round(20 * stats.s); height: Math.round(6 * stats.s)
                                    color: index === scanInfo.curIdx ? scanInfo.mc : Theme.withAlpha(scanInfo.mc, 0.2) }
                            }
                        }
                        Text { text: (scanInfo.curIdx + 1) + " / " + mechEditor.focusDialOpts.length
                            color: Theme.withAlpha(scanInfo.mc, 0.55)
                            font.family: mgsHud.name; font.pixelSize: stats.pxi(Math.round(13 * stats.s)); font.letterSpacing: 2 }
                    }
                }

                // mode banner — I/V/N legend, mode-paced pulse
                Column {
                    id: modeBanner
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: stats.topBleed + Math.round(18 * stats.s)
                    spacing: Math.round(6 * stats.s)
                    transformOrigin: Item.Center
                    readonly property color mc: garageFocus.modeCol
                    property real pulse: 1
                    readonly property int pulseMs: stats.garageMode === "scan" ? 460 : stats.garageMode === "combat" ? 900 : 1700
                    SequentialAnimation { running: stats.visible && stats.mechEdit; loops: Animation.Infinite
                        NumberAnimation { target: modeBanner; property: "pulse"; to: 0.34; duration: modeBanner.pulseMs; easing.type: Easing.InOutSine }
                        NumberAnimation { target: modeBanner; property: "pulse"; to: 1; duration: modeBanner.pulseMs; easing.type: Easing.InOutSine } }
                    Connections { target: stats; function onGarageModeChanged() { bannerKick.restart() } }
                    NumberAnimation { id: bannerKick; target: modeBanner; property: "scale"; from: 1.16; to: 1; duration: 260; easing.type: Easing.OutBack }
                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: Math.round(7 * stats.s)
                        Rectangle { anchors.verticalCenter: parent.verticalCenter; width: Math.round(8 * stats.s); height: width; rotation: 45
                            color: modeBanner.mc; opacity: 0.4 + 0.6 * modeBanner.pulse }
                        Text { id: modeName
                            anchors.verticalCenter: parent.verticalCenter
                            // fixed height so a longer mode name never reflows the legend/hint
                            // rows below; the scale-pop softens the text switch
                            height: Math.round(24 * stats.s); verticalAlignment: Text.AlignVCenter
                            text: garageFocus.manualMode ? (garageFocus.zooming ? (garageFocus.ctrlHeld ? "ZOOM AIM" : "ZOOM MODE") : "MANUAL MODE") : stats.garageMode.toUpperCase() + " MODE"
                            color: modeBanner.mc; opacity: 0.6 + 0.4 * modeBanner.pulse
                            font.family: mgsHud.name; font.bold: true; font.pixelSize: stats.pxi(Math.round(18 * stats.s)); font.letterSpacing: 6
                            transformOrigin: Item.Center
                            onTextChanged: modeNameFlip.restart()
                            NumberAnimation { id: modeNameFlip; target: modeName; property: "scale"
                                from: 1.14; to: 1; duration: 240; easing.type: Easing.OutBack } }
                    }
                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: Math.round(11 * stats.s)
                        Repeater {
                            model: [["I", "COMBAT", "combat"], ["V", "SCAN", "scan"], ["N", "NORMAL", "normal"]]
                            Text { required property var modelData
                                readonly property bool on: stats.garageMode === modelData[2]
                                text: modelData[0] + " " + modelData[1]
                                color: on ? garageFocus.cleanModeCol : Theme.withAlpha("#f4f8fc", 0.32)   // clean mode colour — NOT the dirty red
                                font.family: mgsCodec.name; font.bold: on
                                font.pixelSize: stats.pxi(Math.round(9 * stats.s)); font.letterSpacing: 2 }
                        }
                    }
                    Text {  // scan-mode zoom controls — made discoverable
                        anchors.horizontalCenter: parent.horizontalCenter
                        visible: stats.garageMode === "scan"
                        text: garageFocus.zooming ? "ZOOM " + garageFocus.zoomLabel + (garageFocus.lensGridN > 0 ? " · GRID " + garageFocus.lensGridN : "") + " · wheel/G zoom · wheel-click grid"
                            : garageFocus.freeAim ? "MANUAL AIM"
                            : "⇧ ZOOM · CTRL AIM-FIRE · ⇧+CTRL BOTH"
                        color: Theme.withAlpha(modeBanner.mc, (garageFocus.shiftHeld || garageFocus.ctrlHeld) ? 1 : 0.5)
                        font.family: mgsCodec.name; font.pixelSize: stats.pxi(Math.round(8 * stats.s)); font.letterSpacing: 2
                    }
                }

                // ── ZOOM LENS — magnifies the reticle centre (scan mode · ZOOM dial) ──
                Item {
                    id: lens
                    readonly property real zf: garageFocus.zoomF   // live magnification (dial base + wheel fine-tune)
                    // SCAN + Shift → the lens rides the cursor, magnifying whatever the
                    // circular crosshair is over. (Ctrl is the separate free-aim tool.)
                    readonly property real dia: Math.round(150 * stats.s)
                    readonly property real cxp: garageFocus.cursorX
                    readonly property real cyp: garageFocus.cursorY
                    visible: stats.mechEdit && stats.mech.zoom !== "off" && garageFocus.zooming && dia > 24
                    width: dia; height: dia
                    x: cxp - width / 2
                    y: cyp - height / 2
                    // dark backing disk (HOME parity) so a transparent lens region reads
                    // as a magnifier, not a hole punched through to the backdrop
                    Rectangle { anchors.fill: parent; radius: width / 2; color: "#0a0c12" }
                    Item {   // masked magnified content
                        anchors.fill: parent
                        layer.enabled: true
                        layer.effect: MultiEffect { maskEnabled: true; maskSource: lensMask }
                        ShaderEffectSource {
                            anchors.fill: parent
                            sourceItem: cockpit; live: true; recursive: false
                            sourceRect: {
                                var sz = lens.dia / lens.zf
                                var c = cockpit.mapFromItem(garageFocus, lens.cxp, lens.cyp)
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
                        border.width: Math.max(2, Math.round(2 * stats.s)); border.color: reticle.lockCol }
                    Rectangle { anchors.centerIn: parent; width: Math.round(9 * stats.s); height: 1; color: Theme.withAlpha(reticle.lockCol, 0.7) }
                    Rectangle { anchors.centerIn: parent; width: 1; height: Math.round(9 * stats.s); color: Theme.withAlpha(reticle.lockCol, 0.7) }
                }

                // ── circular crosshair — the cursor tool in scan mode (brightens while
                //    zooming with Shift or free-aiming with Ctrl) ──────────────────────
                Item {
                    visible: garageFocus.hovering && stats.mechEdit && stats.garageMode === "scan" && garageFocus.cursorX >= 0
                    x: garageFocus.cursorX; y: garageFocus.cursorY; z: 6
                    readonly property real r: Math.round((garageFocus.zooming ? 14 : 11) * stats.s)
                    // full-bright while zoom/manual-aiming; dim on a plain scan hover
                    readonly property real a: (garageFocus.zooming || garageFocus.freeAim) ? 1 : 0.4
                    readonly property real lw: Math.max(1, Math.round(stats.s))
                    // orange while manual-locked onto an element (reticle.lockCol)
                    readonly property color cc: reticle.lockCol
                    // cross lines running through the ring
                    Rectangle { anchors.centerIn: parent; width: parent.r * 2.4; height: parent.lw; color: Theme.withAlpha(parent.cc, parent.a) }
                    Rectangle { anchors.centerIn: parent; width: parent.lw; height: parent.r * 2.4; color: Theme.withAlpha(parent.cc, parent.a) }
                    // the ring
                    Rectangle { anchors.centerIn: parent; width: parent.r * 2; height: width; radius: width / 2
                        color: "transparent"; border.width: Math.max(1, Math.round(1.4 * stats.s)); border.color: Theme.withAlpha(parent.cc, parent.a) }
                    // centre dot while zooming
                    Rectangle { anchors.centerIn: parent; visible: garageFocus.zooming
                        width: Math.max(2, Math.round(2 * stats.s)); height: width; radius: width / 2; color: parent.cc }
                }

                // ── show-all-handles — every movable element labeled with a move glyph.
                //    In MANUAL AIM (move page) ALL show; in combat only the hovered one
                //    (so moving is discoverable without cluttering value-tuning).
                Repeater {
                    model: []   // show-all ✛ handles RETIRED (parity with HOME — the reticle + readouts mark the element; the grabbers just cluttered)
                    delegate: Item {
                        id: handle
                        required property var modelData
                        readonly property var el: garageFocus.elemFor(modelData.k)
                        readonly property bool active: garageFocus.dragKey === modelData.k || garageFocus.hoverKey === modelData.k || (mechEditor.page === "move" && mechEditor.moveKey === modelData.k)
                        // labelled seat chips live ONLY in ASSEMBLY (move) mode now — other
                        // modes stay clean; dragging in combat still works, just unlabelled
                        visible: !!el && el.visible && el.width > 1 && mechEditor.page === "move"
                        property point c: el ? el.mapToItem(garageFocus, el.width / 2, el.height / 2) : Qt.point(0, 0)
                        x: c.x; y: c.y; z: 5
                        Rectangle {
                            anchors.centerIn: parent
                            width: chipRow.width + Math.round(12 * stats.s); height: chipRow.height + Math.round(6 * stats.s)
                            radius: Math.round(2 * stats.s)
                            color: handle.active ? Theme.withAlpha(garageFocus.hud, 0.92) : Theme.withAlpha("#0a0f16", 0.72)
                            border.width: 1; border.color: Theme.withAlpha(garageFocus.hud, handle.active ? 1 : 0.45)
                            Row {
                                id: chipRow; anchors.centerIn: parent; spacing: Math.round(5 * stats.s)
                                Item {   // ✥ move glyph — signals draggable
                                    width: Math.round(10 * stats.s); height: width; anchors.verticalCenter: parent.verticalCenter
                                    Rectangle { anchors.centerIn: parent; width: parent.width; height: Math.max(1, Math.round(1.4 * stats.s)); color: handle.active ? "#0a0f16" : garageFocus.hud }
                                    Rectangle { anchors.centerIn: parent; height: parent.height; width: Math.max(1, Math.round(1.4 * stats.s)); color: handle.active ? "#0a0f16" : garageFocus.hud }
                                }
                                Text { anchors.verticalCenter: parent.verticalCenter; text: modelData.label
                                       color: handle.active ? "#0a0f16" : Theme.withAlpha("#dce8ef", 0.9)
                                       font.family: mgsCodec.name; font.pixelSize: stats.pxi(Math.round(9 * stats.s)); font.letterSpacing: 1 }
                            }
                        }
                    }
                }

                // ── ASSEMBLY banner — the dedicated move mode (hidden in NORMAL where nothing acts) ──
                Column {
                    visible: stats.mechEdit && mechEditor.page === "move" && garageFocus.framing
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom; anchors.bottomMargin: Math.round(46 * stats.s)
                    spacing: Math.round(4 * stats.s)
                    Text { anchors.horizontalCenter: parent.horizontalCenter
                           text: "j/k pick  ·  h/l/[ ] move  ·  , . size  ·  ⇧ ×5  ·  right-drag  ·  r reset"
                           color: Theme.withAlpha(garageFocus.hud, 0.75)
                           font.family: mgsCodec.name; font.pixelSize: stats.pxi(Math.round(10 * stats.s)); font.letterSpacing: 2 }
                }

                // ── mouse pointer: cursor-follow + free-drag (combat only nudges) ────
                MouseArea {
                    id: pointer
                    anchors.fill: parent
                    enabled: stats.mechEdit && stats.garageMode !== "normal"
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton   // RIGHT = combat lock-follow · LEFT = grab-drag · MIDDLE (while ⇧-zooming) = cycle in-lens grid
                    cursorShape: garageFocus.dragging ? Qt.ClosedHandCursor
                               : (stats.garageMode === "combat" && garageFocus.hoverKey) ? Qt.OpenHandCursor : Qt.CrossCursor
                    property real lastX; property real lastY
                    onEnabledChanged: if (!enabled) garageFocus.hovering = false
                    onEntered: garageFocus.hovering = true
                    onExited: garageFocus.hovering = false
                    onPositionChanged: (m) => {
                        garageFocus.cursorX = m.x; garageFocus.cursorY = m.y; garageFocus.hovering = true
                        if (stats.lightAim && stats.mech.headerShadow === "long") {   // cursor = light source: shadow rakes away from it
                            var c = deepHdr.mapToItem(pointer, deepHdr.width / 2, deepHdr.height / 2)
                            stats.lightCx = c.x; stats.lightCy = c.y
                            var rx = c.x - m.x, ry = c.y - m.y
                            var len = Math.max(1, Math.hypot(rx, ry))
                            stats.lightVec = [rx / len * 1.4, ry / len * 1.4]   // fixed magnitude → aim sets angle only, LENGTH stays on the dial
                        }
                        // don't set shift/ctrlHeld from m.modifiers — some compositors omit
                        // Ctrl in pointer events, overwriting the key-tracked flag with false
                        if (garageFocus.dragging && stats.garageMode === "combat") {
                            var dx = Math.round(m.x - lastX), dy = Math.round(m.y - lastY)
                            if (dx !== 0 || dy !== 0) { garageFocus.dragOff = [garageFocus.dragOff[0] + dx / stats.offScale, garageFocus.dragOff[1] + dy / stats.offScale]; lastX += dx; lastY += dy; garageFocus.recompute() }   // screen px → reference px so the drag tracks the cursor 1:1 at any scale
                        } else if (garageFocus.freeAim) {
                            garageFocus.recompute()
                        }
                    }
                    onPressed: (m) => {
                        garageFocus.cursorX = m.x; garageFocus.cursorY = m.y
                        if (stats.lightAim && m.button === Qt.LeftButton) {   // click BAKES the current angle + brightness
                            stats.mechSet("castVec", stats.lightVec); stats.mechSet("castBright", stats.lightBright); stats.lightAim = false; return
                        }
                        if (m.button === Qt.MiddleButton && garageFocus.zooming) {   // ⇧ + wheel-click cycles the in-lens grid
                            garageFocus.lensGridN = (garageFocus.lensGridN + 1) % 4; return
                        }
                        if (stats.garageMode === "combat" && m.button === Qt.LeftButton) {   // LEFT press = grab-drag
                            var k = garageFocus.hitKey(m.x, m.y)
                            if (k) { var b = stats.mOffRaw(k); garageFocus.dragOff = [b[0], b[1]]; garageFocus.dragKey = k; garageFocus.dragging = true; lastX = m.x; lastY = m.y; mechEditor.pushHist(true) }
                        }
                    }
                    onReleased: {
                        // commit the live drag into mech ONCE, before clearing the flag so the
                        // element stays put (no revert-then-reapply jump)
                        if (garageFocus.dragging && garageFocus.dragKey !== "" && stats.garageMode === "combat")
                            stats.mechCommitDrag(garageFocus.dragKey, garageFocus.dragOff)
                        garageFocus.dragging = false
                    }
                    onCanceled: garageFocus.dragging = false   // aborted drag → element reverts to mech (no commit)
                    onWheel: (w) => {
                        if (stats.lightAim) {   // light-aim: the wheel is LIGHT BRIGHTNESS (shadow strength)
                            stats.lightBright = Math.max(0.03, Math.min(0.75, stats.lightBright + (w.angleDelta.y > 0 ? 0.02 : -0.02)))
                            w.accepted = true
                        } else if (garageFocus.zooming) {   // scan+shift: the wheel fine-tunes the lens magnification
                            garageFocus.zoomBy(w.angleDelta.y > 0 ? 0.25 : -0.25); w.accepted = true
                        } else w.accepted = false
                    }
                }
                // LIGHT-AIM indicator — the "sun" at the cursor + a ray to the header
                Item {
                    visible: stats.lightAim && stats.mech.headerShadow === "long" && garageFocus.hovering
                    anchors.fill: parent
                    z: 60
                    Rectangle {   // the ray from the light to the header centre
                        readonly property real dx: stats.lightCx - garageFocus.cursorX
                        readonly property real dy: stats.lightCy - garageFocus.cursorY
                        x: garageFocus.cursorX; y: garageFocus.cursorY
                        width: Math.hypot(dx, dy); height: Math.max(1, Math.round(2 * stats.s))
                        color: Theme.withAlpha("#ffcf6b", 0.35); antialiasing: true
                        transformOrigin: Item.Left
                        rotation: Math.atan2(dy, dx) * 180 / Math.PI
                    }
                    Rectangle {   // the light itself — grows/brightens with LIGHT BRIGHTNESS
                        readonly property real b: stats.lightBright
                        x: garageFocus.cursorX - width / 2; y: garageFocus.cursorY - height / 2
                        width: Math.round((12 + 22 * b) * stats.s); height: width; radius: width / 2
                        color: Qt.rgba(1, 0.95, 0.77, 0.5 + 0.5 * Math.min(1, b / 0.5)); border.color: "#ffcf6b"; border.width: Math.max(1, Math.round(2 * stats.s))
                    }
                    Text {
                        x: garageFocus.cursorX + Math.round(16 * stats.s); y: garageFocus.cursorY - Math.round(8 * stats.s)
                        text: "◉ LIGHT · move = aim · scroll = bright " + Math.round(stats.lightBright * 100) + "% · click/F set"
                        color: "#ffcf6b"; font.family: mgsHud.name; font.pixelSize: stats.pxi(Math.round(12 * stats.s))
                        style: Text.Outline; styleColor: "#05080e"
                    }
                }
                MouseArea {  // thumb (Back/Forward) mouse buttons cycle EDITOR TABS, any mode
                    anchors.fill: parent
                    enabled: stats.mechEdit
                    acceptedButtons: Qt.BackButton | Qt.ForwardButton
                    onPressed: (m) => { if (m.button === Qt.BackButton) mechEditor.pageStep(-1)
                                        else if (m.button === Qt.ForwardButton) mechEditor.pageStep(1) }
                }
            }

            // ── the ported home MechEditor, driving the cockpit's own dials ──────────
            MechEditor {
                id: mechEditor
                x: leftSide ? Math.round(24 * stats.s) : parent.width - width - Math.round(24 * stats.s)
                anchors.verticalCenter: parent.verticalCenter
                z: 50
                open: stats.mechEdit
                view: stats
                rows: stats.mechRows
                moveElems: stats.moveElems
                secList: []
                pageOrder: ["dials", "move", "assets", "system", "data"]
                presetPrefix: "statUiPreset"
                chromeKey: "chrome"
            }

            // ── hidden-editor recall — a VERTICAL CONTINUE-style tab on the docked edge;
            // SPACE or a click restores it, and it fades when a locked element reaches it
            Item {
                id: recallTab
                z: 51
                visible: stats.mechEdit && mechEditor.hidden
                readonly property bool onRight: !mechEditor.leftSide
                readonly property bool blocking: garageFocus.framing
                    && (onRight ? (garageFocus.bx + garageFocus.bw > parent.width - Math.round(96 * stats.s))
                                : (garageFocus.bx < Math.round(96 * stats.s)))
                    && garageFocus.by < parent.height / 2 + recallInner.width / 2
                    && garageFocus.by + garageFocus.bh > parent.height / 2 - recallInner.width / 2
                anchors.verticalCenter: parent.verticalCenter
                x: onRight ? parent.width - width - Math.round(3 * stats.s) : Math.round(3 * stats.s)
                width: Math.round(32 * stats.s)
                height: recallInner.width
                opacity: visible ? (blocking ? 0.35 : 1) : 0  // dim, never invisible
                Behavior on opacity { NumberAnimation { duration: 220 } }

                Item {
                    id: recallInner
                    anchors.centerIn: parent
                    rotation: recallTab.onRight ? -90 : 90
                    width: recallRow.width + Math.round(26 * stats.s)
                    height: Math.round(30 * stats.s)
                    MechButton {
                        anchors.fill: parent
                        family: 4
                        px: stats.s >= 1.15 ? 2 : 1
                        hot: recallMouse.containsMouse
                        pressed: recallMouse.pressed
                    }
                    Row {
                        id: recallRow
                        anchors.centerIn: parent
                        spacing: Math.round(6 * stats.s)
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: kcap2.implicitWidth + Math.round(7 * stats.s); height: kcap2.implicitHeight + Math.round(3 * stats.s)
                            radius: 2; color: Theme.withAlpha(Theme.accent, 0.18); border.width: 1; border.color: Theme.withAlpha(Theme.accent, 0.5)
                            Text { id: kcap2; anchors.centerIn: parent; text: "SPACE"; color: "#8fe3a1"
                                font.family: mgsCodec.name; font.bold: true; font.pixelSize: stats.pxi(Math.round(9 * stats.s)); font.letterSpacing: 1 }
                        }
                        Text { anchors.verticalCenter: parent.verticalCenter; text: "GARAGE"; color: "#dfe9f0"
                            font.family: mgsCodec.name; font.bold: true; font.pixelSize: stats.pxi(Math.round(10 * stats.s)); font.letterSpacing: 2 }
                        Text {
                            id: recallCaret
                            anchors.verticalCenter: parent.verticalCenter
                            text: "▸"; color: Theme.accent
                            font.pixelSize: stats.pxi(Math.round(15 * stats.s)); font.bold: true
                            transformOrigin: Item.Center
                            SequentialAnimation on opacity {
                                running: stats.visible && stats.mechEdit; loops: Animation.Infinite
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
                onVisibleChanged: if (visible) recallBlip.restart()
            }
        }
        }
    }

    // ── footer hint ─────────────────────────────────────────────────────────
    MechPanel {
        id: footBack
        visible: stats.mech.hintBack !== "none" && !stats.classic && stats.mech.hints !== "off"
        anchors.centerIn: footerHint
        width: footerHint.width + Math.round(24 * stats.s)
        height: footerHint.height + Math.round(14 * stats.s)
        px: stats.mpx
        kind: stats.mech.hintBack === "chip" ? "chip" : stats.mech.hintBack === "frame" ? "frame" : stats.mech.hintBack === "hollow" ? "hollow" : "body"
        transform: Translate { x: stats.mOff("foot")[0]; y: stats.mOff("foot")[1] }
    }
    Row {  // keytips — home's keycap grammar: the KEY in a cap, the action free
        id: footerHint
        visible: stats.mech.hints !== "off"
        opacity: stats.mech.hints === "dim" ? 0.5 : 1
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom; anchors.bottomMargin: Math.round(16 * stats.s)
        transform: Translate { x: stats.mOff("foot")[0]; y: stats.mOff("foot")[1] }
        spacing: Math.round(18 * stats.s * stats.trackFor(stats.mech.hintTrack) / 2)
        readonly property color hi: stats.ink(stats.mech.hintInk)
        readonly property var tips: stats.mechEdit
            ? [["j/k", "DIAL"], ["h/l", "SET"], ["-/=", "PAGE"], ["Tab", "MODE"], ["B", "MOVE"], ["x", "RANDOM"], ["\\", "SAVE"], ["M", "CLOSE"]]
            : [["esc/h", "HOME"], ["q", "QUEUE"], ["p", "PLAY"], ["`", "GARAGE"]]
        Repeater {
            model: footerHint.tips
            Row {
                required property var modelData
                spacing: Math.round(5 * stats.s)
                Rectangle {  // keycap
                    visible: stats.mech.hintCaps
                    anchors.verticalCenter: parent.verticalCenter
                    width: kc.implicitWidth + Math.round(8 * stats.s)
                    height: Math.round(15 * stats.s)
                    radius: Math.round(3 * stats.s)
                    color: Theme.withAlpha("#0d0b16", 0.5)
                    border.width: 1
                    border.color: Theme.withAlpha(footerHint.hi, 0.3)
                    Text {
                        id: kc
                        anchors.centerIn: parent
                        text: modelData[0]
                        color: Theme.withAlpha(footerHint.hi, 0.85)
                        font.family: stats.mechFontFor(stats.mech.hintFont)
                        font.pixelSize: stats.pxi(Math.round(stats.mSz(9, stats.mech.hintSize) * stats.mScale("foot")))
                    }
                }
                Text {  // caps off → the key reads inline before its label
                    visible: !stats.mech.hintCaps
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData[0]
                    color: Theme.withAlpha(footerHint.hi, 0.7)
                    font.family: stats.mechFontFor(stats.mech.hintFont)
                    font.pixelSize: stats.pxi(Math.round(stats.mSz(9, stats.mech.hintSize) * stats.mScale("foot")))
                    font.letterSpacing: stats.trackFor(stats.mech.hintTrack)
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: stats.caseFor(modelData[1], stats.mech.hintCase)
                    color: footerHint.hi
                    font.family: stats.mechFontFor(stats.mech.hintFont)
                    font.weight: stats.weightFor(stats.mech.hintWeight)
                    font.pixelSize: stats.pxi(Math.round(stats.mSz(9, stats.mech.hintSize) * stats.mScale("foot")))
                    font.letterSpacing: stats.trackFor(stats.mech.hintTrack)
                }
            }
        }
    }
}
