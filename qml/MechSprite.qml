import QtQuick

// Film-strip pixel animator. AnimatedSprite filters bilinearly when its item
// is scaled — an Image strip stepped by x-offset under a clip, with
// smooth:false, is what keeps ×px magnification nearest-neighbour crisp.
// Set playing:false and drive `frame` externally to share one clock across
// sprites (e.g. a body + its shadow stepping in lockstep).
Item {
    id: root
    property url source
    property int fw: 32           // frame size in ART pixels
    property int fh: 32
    property int frames: 4
    property int fps: 8
    property int px: 2
    property bool playing: true
    property bool loop: true      // false: one pass, then hold frame 0
    property int frame: 0
    width: fw * px
    height: fh * px
    clip: true

    // one full cycle from frame 0 — the chevron's single-bob beat
    function pulse() { frame = 0; playing = true }

    Timer {
        interval: Math.max(16, Math.round(1000 / root.fps))
        repeat: true
        running: root.playing && root.visible
        onTriggered: {
            let n = root.frame + 1
            if (n >= root.frames) {
                n = 0
                if (!root.loop)
                    root.playing = false
            }
            root.frame = n
        }
    }
    // DEV HOT-RELOAD: live-load the sprite sheet from the dev tree when present.
    readonly property string _rel: {
        var s = ("" + source); var m = "assets/mechui/"; var i = s.indexOf(m)
        if (i < 0) return ""
        var rest = s.substring(i + m.length); var dot = rest.lastIndexOf(".")
        return dot > 0 ? rest.substring(0, dot) : rest
    }
    readonly property string _devUrl: ((typeof App !== "undefined") && App && _rel !== "")
        ? (App.heroDevRev, App.heroDevPath(_rel)) : ""
    Image {
        source: root._devUrl !== "" ? root._devUrl + "?v=" + App.heroDevRev : root.source
        cache: root._devUrl === ""
        smooth: false
        width: root.fw * root.frames * root.px
        height: root.fh * root.px
        x: -root.frame * root.fw * root.px
    }
}
