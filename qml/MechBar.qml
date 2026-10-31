import QtQuick

// Progress in mech hardware, builds selected by `style`:
//   "liquid"  — Bar3's segmented liquid: empty frame stretches (flat
//               interior), fill laid as capL + n·seg + capR on the art grid
//               so the jag pitch never warps, clipped to `value`
//   "cells"   — Bar1's battery cells: N discrete 8x12 cells, filled count
//   "laser-a/b/c" — the Attacks beams over a navy track: muzzle cap at
//               zero, tileable core fired out to `value` (a medium,
//               b heavy, c thin)
// Either way the reading advances in hard art-pixel steps — an instrument
// filling, not a css tween. Lasers ride one px step below the caller's
// scale (24-art-px tall beams read oversized at x2).
Item {
    id: root
    property real value: 0        // 0..1
    property int px: 2
    property string style: "liquid"
    // DEV HOT-RELOAD: resolve a mechui asset live from the dev tree when present, else
    // the baked qrc (installed builds have no dev dir → always qrc). Mirrors MechSlice.
    function devSrc(rel) {
        if (typeof App === "undefined" || !App) return "qrc:/assets/mechui/" + rel + ".png"
        var d = App.heroDevPath(rel)
        return d !== "" ? d + "?v=" + App.heroDevRev : "qrc:/assets/mechui/" + rel + ".png"
    }
    // optional crisp pixel outline that hugs the TRUE (art-grid-snapped) bar
    // rect — cleaner than an anchored backing that can't match the snap width
    property color outline: "transparent"
    // requested width; actual width snaps DOWN onto the art grid
    property int maxWidth: 200
    readonly property bool cells: style === "cells"
    readonly property bool laser: style.indexOf("laser") === 0
    readonly property string beam: laser ? style.charAt(6) : "a"
    readonly property int unitPx: laser ? Math.max(1, px - 1) : px
    readonly property int segs: cells
        ? Math.max(2, Math.floor(maxWidth / unitPx / 8))
        : Math.max(0, Math.floor((maxWidth / unitPx - (laser ? 16 : 32)) / 16))
    readonly property int artW: cells ? segs * 8
                              : laser ? 16 + segs * 16
                              : 32 + segs * 16
    readonly property int clipW: Math.round(Math.max(0, Math.min(1, value)) * artW) * unitPx
    width: artW * unitPx
    height: (cells ? 12 : laser ? 24 : 8) * unitPx

    // crisp white pixel outline (opt-in via `outline`) — drawn as 4 edges that
    // stop `bw` short of each corner, so the corner pixel is punched out for a
    // chamfered 8-bit look (a plain border would give hard 90° corners).
    Item {
        visible: root.outline.a > 0
        anchors.fill: parent
        z: 5
        readonly property int bw: Math.max(1, Math.round(root.px / 2))
        // top / bottom
        Rectangle { x: parent.bw; y: 0; width: parent.width - parent.bw * 2; height: parent.bw; color: root.outline; antialiasing: false }
        Rectangle { x: parent.bw; y: parent.height - parent.bw; width: parent.width - parent.bw * 2; height: parent.bw; color: root.outline; antialiasing: false }
        // left / right
        Rectangle { x: 0; y: parent.bw; width: parent.bw; height: parent.height - parent.bw * 2; color: root.outline; antialiasing: false }
        Rectangle { x: parent.width - parent.bw; y: parent.bw; width: parent.bw; height: parent.height - parent.bw * 2; color: root.outline; antialiasing: false }
    }

    // ── liquid ───────────────────────────────────────────────────────────
    // darkTrack swaps the frame for a variant whose dead-space navy is recoloured
    // to the VFD screen shade (the recolour is IN the asset, so it stays the
    // correct height and never eats the fill).
    property bool darkTrack: false
    MechSlice {
        visible: !root.cells && !root.laser
        anchors.fill: parent
        px: root.unitPx
        source: (App.heroDevRev, root.devSrc(root.darkTrack ? "bar-frame-vfd" : "bar-frame"))
        artL: 2; artR: 2; artT: 2; artB: 2
    }
    Item {
        visible: !root.cells && !root.laser
        clip: true
        width: root.clipW
        height: parent.height
        Row {
            Image {
                source: (App.heroDevRev, root.devSrc("bar-fill-l"))
                width: 16 * root.unitPx; height: 8 * root.unitPx; smooth: false
            }
            Repeater {
                model: root.cells || root.laser ? 0 : root.segs
                Image {
                    source: (App.heroDevRev, root.devSrc("bar-seg"))
                    width: 16 * root.unitPx; height: 8 * root.unitPx; smooth: false
                }
            }
            Image {
                source: (App.heroDevRev, root.devSrc("bar-fill-r"))
                width: 16 * root.unitPx; height: 8 * root.unitPx; smooth: false
            }
        }
    }
    // ── cells ────────────────────────────────────────────────────────────
    Row {
        visible: root.cells
        Repeater {
            // cell art is 3 cells per 24x12 sheet — shown one cell (8x12)
            // at a time via clipped windows, filled count from `value`
            model: root.cells ? root.segs : 0
            Item {
                required property int index
                width: 8 * root.unitPx
                height: 12 * root.unitPx
                clip: true
                Image {
                    source: (App.heroDevRev, root.devSrc(index < Math.round(root.value * root.segs)
                            ? "cell-fill" : "cell-empty"))
                    smooth: false
                    width: 24 * root.unitPx
                    height: 12 * root.unitPx
                    // middle cell of the 3-cell sheet for every window — the
                    // sheet's outer cells carry end caps we don't want mid-run
                    x: -8 * root.unitPx
                }
            }
        }
    }
    // ── laser ────────────────────────────────────────────────────────────
    Rectangle {  // the track the beam fires along
        visible: root.laser
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width
        height: 8 * root.unitPx
        color: "#222034"
        opacity: 0.75
    }
    Item {
        visible: root.laser
        clip: true
        width: root.clipW
        height: parent.height
        Row {
            Image {
                source: (App.heroDevRev, root.devSrc("laser-" + root.beam + "-muzzle"))
                width: 16 * root.unitPx; height: 24 * root.unitPx; smooth: false
            }
            Repeater {
                model: root.laser ? root.segs : 0
                Image {
                    source: (App.heroDevRev, root.devSrc("laser-" + root.beam + "-core"))
                    width: 16 * root.unitPx; height: 24 * root.unitPx; smooth: false
                }
            }
        }
    }
}
