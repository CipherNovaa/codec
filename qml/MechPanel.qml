import QtQuick

// Hull plates from the mech pack (assets/mechui, baked by import_mechui.py).
// Fixed steel — #566C78 body · #AECBD9 trim · #222034 outline — the same
// "hardware doesn't re-paint with the wallpaper" law as the gears' cel-steel.
// Presets carry each plate's measured 9-patch insets; every decoration
// (▶▶▶▶ ticks, corner vents, rail ends, bracket plates) lives inside a
// corner region so stretching never warps it.
//
// `band`/`floor` describe the plate's anatomy in ART rows — the height of a
// light header band (0 = none: ink light, not navy) and of the bottom
// chrome — so a card readout can re-seat its datum lines when the plate
// under it is swapped (the mech editor cycles these live).
MechSlice {
    id: root
    // card: 96x48, light header band + tick block right (the wheel readout)
    // body: 96x64, corner vents + bottom rail + ticks (large surfaces)
    // chip: 32x16, banded badge plate
    // sq1/sq2/sq3: 48x48 squares (tabbed band / arrow corners / chamfered)
    // wide: 96x48, ▶▶▶ ticks + bracket title plate top-right
    // dlg: 176x64 dialogue — portrait frame left, body stretches
    // frame: 64x64 portrait holder
    // Fit metadata beyond the 9-patch: `nL` is the name/reading left datum
    // in ART px (clears vents, arrow tabs, portrait frames); `nameBox`
    // [fromRightArt, widthArt] seats the name INSIDE a plate's own title
    // bracket instead of on the left datum (the wide plate's whole design).
    property string kind: "card"
    readonly property var plates: ({
        "card": { src: "panel-card.png", l: 10, r: 32, t: 12, b: 8, band: 11, floor: 8, nL: 7 },
        "body": { src: "panel-body.png", l: 14, r: 28, t: 8, b: 12, band: 0, floor: 12, nL: 16 },
        "chip": { src: "chip.png", l: 4, r: 4, t: 7, b: 4, band: 7, floor: 2, nL: 4 },
        // Per-format media-flag badge backings — dedicated plates so 4K / HDR /
        // ATMOS can each be drawn their own way (MechChip "badge" mode picks by
        // flag). Seeded as copies of the chip plate; same 9-patch as chip so the
        // recess + text seat line up. Redraw badges/badge-*.png freely.
        "badge-4k":    { src: "badge-4k.png",    l: 4, r: 4, t: 7, b: 4, band: 7, floor: 2, nL: 4 },
        "badge-hdr":   { src: "badge-hdr.png",   l: 4, r: 4, t: 7, b: 4, band: 7, floor: 2, nL: 4 },
        "badge-dv":    { src: "badge-dv.png",    l: 4, r: 4, t: 7, b: 4, band: 7, floor: 2, nL: 4 },
        "badge-atmos": { src: "badge-atmos.png", l: 4, r: 4, t: 7, b: 4, band: 7, floor: 2, nL: 4 },
        "badge-71":    { src: "badge-71.png",    l: 4, r: 4, t: 7, b: 4, band: 7, floor: 2, nL: 4 },
        "badge-51":    { src: "badge-51.png",    l: 4, r: 4, t: 7, b: 4, band: 7, floor: 2, nL: 4 },
        // generic dark plate for any flag without a bespoke badge (HEVC, REMUX, editions…)
        "badge-gen":   { src: "badge-gen.png",   l: 4, r: 4, t: 7, b: 4, band: 7, floor: 2, nL: 4 },
        "sq1": { src: "panel-sq1.png", l: 6, r: 8, t: 10, b: 6, band: 9, floor: 4, nL: 7 },
        "sq2": { src: "panel-sq2.png", l: 9, r: 9, t: 11, b: 8, band: 10, floor: 6, nL: 14 },
        "sq3": { src: "panel-sq3.png", l: 8, r: 8, t: 10, b: 10, band: 9, floor: 8, nL: 8 },
        "wide": { src: "panel-wide.png", l: 12, r: 46, t: 14, b: 10, band: 0, floor: 10, nL: 8,
                  nameBox: [43, 38] },
        "dlg": { src: "panel-dlg.png", l: 68, r: 10, t: 12, b: 10, band: 0, floor: 10, nL: 72 },
        "frame": { src: "panel-frame.png", l: 10, r: 10, t: 10, b: 10, band: 0, floor: 6, nL: 7 },
        // dedicated poster frame — hollow centre, 9-slice so it fits any poster
        "poster": { src: "panel-poster.png", l: 12, r: 12, t: 12, b: 12, band: 0, floor: 8, nL: 8 },
        // continue-deck poster outline (hollow, 9-slice)
        "contframe": { src: "panel-contframe.png", l: 8, r: 8, t: 8, b: 8, band: 0, floor: 6, nL: 6 },
        // dedicated continue-deck tray backing (copy of card; draw freely)
        "conttray": { src: "panel-conttray.png", l: 10, r: 32, t: 12, b: 8, band: 11, floor: 8, nL: 7 },
        // cardframe: a SEPARATE copy of the frame plate dedicated to the HOME preview
        // card, so editing panel-frame.png (the wheel columns) no longer changes the card
        // and vice-versa. Starts identical to frame; diverge panel-cardframe.png freely.
        "cardframe": { src: "panel-cardframe.png", l: 10, r: 10, t: 10, b: 10, band: 0, floor: 6, nL: 7 },
        // hollow: the frame plate with its steel interior knocked transparent
        // (border + trim + tick bands kept) — a see-through holder for meter
        // backs / portraits, so a fill shows through instead of a flat box.
        "hollow": { src: "panel-hollow.png", l: 10, r: 10, t: 10, b: 10, band: 0, floor: 6, nL: 7 },
        // hero: dedicated portrait poster frame (80x112) — bracket corners + steel
        // rails + top/bottom vent rails, transparent middle for the poster. Fixed
        // borders keep the brackets crisp; only the (poster-covered) interior stretches.
        "hero": { src: "hero/panel-hero.png", l: 13, r: 13, t: 28, b: 35, band: 0, floor: 6, nL: 14 },
        // capsule: text-hugging badge with punched (chamfered) corners — used as
        // the stats header backing, sized to the text so padding stays equal at
        // any length. Thin flat middle stretches; chamfered corners stay crisp.
        "capsule": { src: "hdr-capsule.png", l: 2, r: 2, t: 2, b: 2, band: 0, floor: 2, nL: 2 },
        // STATS hero right-half: dlg cropped at its 68px seam (108x64). Left seam
        // is fresh flat interior (small l), right keeps dlg's own r:10 cap.
        "dlgbody": { src: "panel-dlg-body.png", l: 6, r: 10, t: 12, b: 10, band: 0, floor: 10, nL: 8 },
        // STATS cockpit hero: the user's hand-edited WHOLE dlg. l:121 keeps the
        // 51H box + raised header + the FULL step staircase (rightmost art px = 120)
        // in the non-stretched left cap; only clean body steel stretches beyond it.
        // (l:120 was an off-by-one — a left border of 120 fixes cols 0..119, leaving
        // the staircase's last column x120 in the stretch zone → a floating box.)
        "cockpit": { src: "panel-dlg-stats.png", l: 121, r: 9, t: 15, b: 9, band: 0, floor: 9, nL: 8 }
    })
    // Unknown / non-plate kinds (e.g. an INVISIBLE panel still bound to "none"
    // or "button") fall back to a real plate so the geometry bindings below
    // never read a property off undefined — silences the transient TypeErrors.
    readonly property var plate: plates[kind] || plates["card"]
    source: "qrc:/assets/mechui/" + plate.src
    artL: plate.l
    artR: plate.r
    artT: plate.t
    artB: plate.b
}
