import QtQuick
import QtQuick.Shapes

// The ⏎ drawn as hardware: the font glyph's ink sits lopsided in its em
// box, so every keycap read off-centre. Stroke-grid geometry — one stroke
// weight, pixel-snapped edges, butt joints (the colours carry alpha, so
// overlaps would double-paint brighter). Design box ~9×8.
Item {
    id: rg
    property color color: Theme.fg
    Behavior on color { ColorAnimation { duration: 180 } }
    readonly property int sw: Math.max(1, Math.round(height / 4.5))
    readonly property int armY: Math.round(height * 0.375)
    readonly property int headW: Math.round(width * 0.36)
    Rectangle {  // stem — drops from the top, flush right
        x: rg.width - rg.sw
        y: Math.round(rg.height * 0.125)
        width: rg.sw
        height: rg.armY + rg.sw - y
        color: rg.color
    }
    Rectangle {  // arm — butts flush against the stem's left edge
        x: rg.headW; y: rg.armY
        width: rg.width - rg.headW - rg.sw; height: rg.sw
        color: rg.color
    }
    Shape {  // head — compact, symmetric about the arm's centreline;
        // multisampled: the one diagonal in the glyph deserves clean edges
        antialiasing: true
        layer.enabled: true
        layer.samples: 4
        layer.smooth: true
        ShapePath {
            fillColor: rg.color; strokeWidth: 0
            PathPolyline {
                path: [Qt.point(0, rg.armY + rg.sw / 2),
                       Qt.point(rg.headW, rg.armY + rg.sw / 2 - rg.sw * 1.5),
                       Qt.point(rg.headW, rg.armY + rg.sw / 2 + rg.sw * 1.5),
                       Qt.point(0, rg.armY + rg.sw / 2)]
            }
        }
    }
}
