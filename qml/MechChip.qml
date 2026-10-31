import QtQuick

// A badge on a mech plate. The label sits in a dark READOUT WINDOW recessed
// into the steel body (white-on-steel had no contrast), or rides one of the
// button plates, or stands bare with an outline — the badge-plate dial picks.
// Ink is fixed — the plate is hull, not theme.
Item {
    id: root
    property alias text: label.text
    property alias font: label.font
    property int px: 2
    // the editor can switch the recess off to compare bare-plate ink,
    // and re-ink the label from the fixed hardware palette
    property bool window: true
    property color ink: "#eef4f8"
    // chip = the banded plate · badge = per-format plate (picked from `flag`) ·
    // b1/b3/b4 = button plates · none = ink only
    property string plateStyle: "chip"
    // raw media flag (4K / HDR10 / DV / ATMOS / 7.1 …) used ONLY to pick the
    // backing in "badge" mode — kept separate from `text` so a case dial on the
    // label can't break the lookup.
    property string flag: ""
    readonly property bool chipPlate: plateStyle === "chip"
    readonly property bool badgePlate: plateStyle === "badge"
    readonly property bool btnPlate: plateStyle.charAt(0) === "b" && plateStyle.length === 2
    // badge mode: each format flag rides its OWN drawable plate; anything without
    // a dedicated plate (audio layouts, editions) falls back to the chip plate.
    function badgeKind(f) {
        var u = ("" + f).toUpperCase()
        if (u === "4K") return "badge-4k"
        // No bespoke badge-1080 art yet — falls through to the generic dark plate
        // below, which renders the label correctly. Art is a pixel-art redraw job,
        // deliberately NOT auto-generated.
        if (u === "1080P" || u === "1080") return "badge-gen"
        if (u === "HDR" || u === "HDR10" || u === "HDR10+") return "badge-hdr"
        if (u === "DV" || u === "DOVI") return "badge-dv"
        if (u === "ATMOS") return "badge-atmos"
        if (u === "7.1") return "badge-71"
        if (u === "5.1") return "badge-51"
        return "badge-gen"   // any other flag (HEVC, REMUX, editions, odd layouts) → generic dark plate
    }
    // both the chip and badge plates use the banded-chip body layout (recess + seat)
    readonly property bool platedChip: chipPlate || badgePlate
    implicitWidth: Math.ceil((label.implicitWidth + 12 * px) / px) * px
    implicitHeight: 16 * px

    MechPanel {
        visible: root.platedChip
        kind: root.chipPlate ? "chip" : root.badgeKind(root.flag)
        px: root.px
        anchors.fill: parent
    }
    MechButton {
        visible: root.btnPlate
        family: parseInt(root.plateStyle.substring(1)) || 1
        px: root.px
        anchors.fill: parent
    }
    // The readout window. On the chip plate: body rows 7..13, under the band,
    // clear of the bottom bezel. On a BADGE plate the window sits one art pixel
    // inside the frame on all FOUR sides — it used to start right under the top
    // line with the black seat on the sides and foot only, so the window (and
    // the word centred in it) rode high in the box.
    readonly property int winY: badgePlate ? 8 * px : 7 * px
    readonly property int winH: badgePlate ? 6 * px : 7 * px
    // where the label's cap ink centres, against the chip's own middle — a
    // row of text beside the chip drops by this to share the label's line
    readonly property real labelDrop: platedChip ? winY + winH / 2 - implicitHeight / 2 : 0
    // The optical seat: one screen pixel BELOW true centre. Measured-centred
    // caps read a hair high in the window (the frame's light top line pulls
    // the eye up); the author tried it on every badge — "totally center to the
    // eyes". The web badges (guest page, invite, TV) carry the same pixel.
    readonly property int opticalDy: 1
    Rectangle {  // the recess
        visible: root.window && root.platedChip
        x: 2 * root.px
        y: root.winY
        width: parent.width - 4 * root.px
        height: root.winH
        // the buttons' dark face (#181c23, btn-N rows 2..10) — it was the
        // steel palette's navy OUTLINE colour, which read purple beside them
        color: "#181c23"
    }
    // The label's CAP INK (re-read once the face has loaded), so it centres on
    // the letters rather than on the font's box.
    FontMetrics { id: chipFm; font: label.font }
    readonly property rect capInk: (chipFm.height, chipFm.tightBoundingRect("H"))
    // the WORD's ink, not its box: the box carries a trailing letter-space
    // and the last glyph's side bearing, which left every label 1-1.5 px left
    // Built glyph by glyph, the way the line is laid: each advance plus the
    // letter-spacing (measured on the face WITHOUT spacing — Qt's whole-word
    // tight rect counts it inconsistently), from the first glyph's ink to the
    // last one's. Pixel faces don't kern, so this is exact.
    FontMetrics { id: bareFm; font.family: label.font.family; font.pixelSize: label.font.pixelSize
                  font.weight: label.font.weight }
    readonly property var wordInk: {
        void bareFm.height
        const t = label.text
        if (!t.length) return { x: 0, w: 0 }
        const ls = label.font.letterSpacing
        let pen = 0
        for (let i = 0; i < t.length - 1; i++) pen += bareFm.advanceWidth(t[i]) + ls
        const first = bareFm.tightBoundingRect(t[0]), last = bareFm.tightBoundingRect(t[t.length - 1])
        const right = pen + last.x + last.width
        return { x: first.x, w: right - first.x }
    }
    Text {
        id: label
        textFormat: Text.PlainText   // toasts carry guest names: never markup
        // The ink centred in the window, both ways, on whole pixels, then the
        // optical seat (opticalDy). An odd leftover can't split: horizontally
        // its spare pixel goes on the left (a word leaning left is a miss the author
        // caught). Other plates and bare ink: dead centre of the whole badge.
        x: root.wordInk.w > 0
           ? Math.ceil((parent.width - root.wordInk.w) / 2) - Math.round(root.wordInk.x)
           : Math.round((parent.width - implicitWidth) / 2)
        y: root.platedChip
           ? root.winY + Math.floor((root.winH - root.capInk.height) / 2)   // spare px below
             - Math.round(chipFm.ascent + root.capInk.y) + root.opticalDy
           : Math.round((parent.height - height) / 2)
        color: root.ink
        // bare ink needs its own seat on hot art
        style: root.plateStyle === "none" ? Text.Outline : Text.Normal
        styleColor: "#222034"
    }
}
