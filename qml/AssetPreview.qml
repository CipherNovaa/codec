import QtQuick

// Asset Viewer preview. DEFAULT = the WHOLE asset, STATIC — so a spritesheet shows
// its grid and a strip shows its filmstrip, never a mis-guessed flicker. When
// ed.bayPlay is on it animates AS a horizontal strip (frame width = w / ed.bayFramesEff),
// or plays a GIF. Nearest-neighbour throughout; Image cache off so an external
// Aseprite save hot-reloads the same path.
Item {
    id: root
    property var ed: null
    property var a: null
    property bool isGif: false
    readonly property bool anim: ed && ed.bayPlay && a
    readonly property int framesEff: (anim && !isGif) ? ed.bayFramesEff(a) : 1
    readonly property int fw: a ? (framesEff > 1 ? Math.round(a.w / framesEff) : a.w) : 1
    readonly property int fh: a ? a.h : 1
    readonly property real fit: (a && fw > 0 && fh > 0)
        ? Math.min((width - 6) / fw, (height - 6) / fh) : 1
    readonly property real ds: fit >= 1 ? Math.max(1, Math.floor(fit)) : fit

    // STATIC — the whole asset, fit into the box (default, and the frame-0 look)
    Image {
        visible: root.a && !root.anim
        anchors.centerIn: parent
        width: parent.width - 6; height: parent.height - 6
        source: root.a ? root.ed.assetSrc(root.a) : ""
        fillMode: Image.PreserveAspectFit
        smooth: false; mipmap: false; cache: false
    }
    // PLAY · strip
    MechSprite {
        visible: root.anim && !root.isGif
        anchors.centerIn: parent
        source: root.a ? root.ed.assetSrc(root.a) : ""
        fw: root.fw; fh: root.fh
        frames: root.framesEff; fps: 8; px: 1; scale: root.ds
    }
    // PLAY · gif
    AnimatedImage {
        visible: root.anim && root.isGif; playing: visible
        anchors.centerIn: parent
        source: root.a ? root.ed.assetSrc(root.a) : ""
        width: (root.a ? root.a.w : 1) * root.ds
        height: (root.a ? root.a.h : 1) * root.ds
        smooth: false
    }
}
