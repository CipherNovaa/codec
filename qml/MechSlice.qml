import QtQuick

// The mech-pack 9-patch primitive. BorderImage draws its corners 1:1 with the
// source, so a 16px-scale plate would render minuscule on a 1440p panel —
// instead the plate is laid out at ART size and the whole item magnified by an
// integer `px`, which keeps every art pixel exactly px screen pixels (the same
// nearest-neighbour law every pixel asset in this set follows). Sizes that are
// not multiples of px lose the sub-pixel remainder at the right/bottom edge —
// callers snap their geometry to the px grid where it matters.
Item {
    id: root
    clip: true   // a plate whose caller box is narrower than its art must not
                 // paint its body/borders out over neighbours (row titles/bars)
    property url source
    property int px: 2
    // DEV HOT-RELOAD (opt-in): when `dev`, load the same PNG live from the asset dev
    // tree (App.heroDevDir → assets/mechui root in a dev build) with a ?v=rev cache-
    // bust, instead of the baked qrc — so an external editor's save shows instantly.
    // ON by default → every MechPanel/MechButton (all extend MechSlice) is live-editable
    // in a dev build; installed builds have no dev dir so heroDevPath returns "" → the
    // baked qrc renders (zero change). `_rel` is the subfolder-relative id (source minus
    // the qrc:/assets/mechui/ prefix + .png), e.g. "plates/panel-card" or "hero/panel-hero".
    property bool dev: true
    readonly property string _rel: {
        var s = ("" + source)
        var m = "assets/mechui/"
        var i = s.indexOf(m)
        if (i < 0) return ""
        var rest = s.substring(i + m.length)
        var dot = rest.lastIndexOf(".")
        return dot > 0 ? rest.substring(0, dot) : rest
    }
    readonly property string _devUrl: (dev && (typeof App !== "undefined") && App && _rel !== "")
        ? (App.heroDevRev, App.heroDevPath(_rel)) : ""
    // 9-patch insets in ART pixels — decorations (ticks, vents, rails) must
    // stay inside corner regions; only flat runs may live in the stretch zone.
    property int artL: 4
    property int artR: 4
    property int artT: 4
    property int artB: 4

    BorderImage {
        id: img
        source: root._devUrl !== "" ? root._devUrl + "?v=" + App.heroDevRev : root.source
        cache: root._devUrl === ""   // don't cache the live-editable override
        // FLOOR, not round: round overshoots when the remainder ≥ px/2, so the
        // scaled BorderImage came out WIDER than root and its borders sat past
        // the canvas edge — the opposite of the documented undershoot. Floor
        // loses the sub-pixel remainder (undershoot) as the header intends.
        width: Math.max(root.artL + root.artR, Math.floor(root.width / root.px))
        height: Math.max(root.artT + root.artB, Math.floor(root.height / root.px))
        border { left: root.artL; right: root.artR; top: root.artT; bottom: root.artB }
        scale: root.px
        transformOrigin: Item.TopLeft
        smooth: false
    }
}
