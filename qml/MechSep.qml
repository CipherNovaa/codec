import QtQuick

// One meta separator — the joint between every reading on the spotlight's
// meta line, editor-switchable as a set (change the dial, every joint
// follows): text marks (dot / bar / slash), the pack's pixel heart (Bar7
// turned out to be a LIVES bar, not diamonds), Bar4's red diamond, the
// plus / cross icons, or none (a plain gap). Sized to sit in running mono
// text without throwing the baseline.
Item {
    id: root
    property string style: "dot"   // dot|bar|slash|heart|diamond|plus|cross|none
    property int px: 1
    property int fontPx: 12
    // DEV HOT-RELOAD (mirror MechBar): live mechui asset when present, else baked qrc.
    function devSrc(rel) {
        if (typeof App === "undefined" || !App) return "qrc:/assets/mechui/" + rel + ".png"
        var d = App.heroDevPath(rel)
        return d !== "" ? d + "?v=" + App.heroDevRev : "qrc:/assets/mechui/" + rel + ".png"
    }
    readonly property bool heart: style === "heart"
    readonly property bool gem: style === "diamond"
    readonly property bool icon: style === "plus" || style === "cross"
    implicitWidth: style === "none" ? 2
                 : heart ? 8 * px
                 : gem || icon ? 16
                 : t.implicitWidth
    implicitHeight: heart ? 8 * px : gem || icon ? 16 : t.implicitHeight

    Text {
        id: t
        visible: !root.heart && !root.gem && !root.icon && root.style !== "none"
        anchors.centerIn: parent
        text: root.style === "bar" ? "|" : root.style === "slash" ? "/" : "·"
        color: Theme.withAlpha(Theme.fg, 0.45)
        font.family: Theme.monoFont
        font.pixelSize: root.fontPx
    }
    MechSprite {
        visible: root.heart
        anchors.centerIn: parent
        source: (App.heroDevRev, root.devSrc("diamond"))
        fw: 8; fh: 8; frames: 2
        px: root.px
        playing: false
        opacity: 0.8
    }
    Image {
        visible: root.gem
        anchors.centerIn: parent
        source: (App.heroDevRev, root.devSrc("sep-diamond"))
        width: 16; height: 16
        smooth: false
        opacity: 0.85
    }
    Image {
        visible: root.icon
        anchors.centerIn: parent
        source: (App.heroDevRev, root.devSrc("icon-" + (root.style === "plus" ? "plus" : "x")))
        width: 16; height: 16
        smooth: false
        opacity: 0.5
    }
}
