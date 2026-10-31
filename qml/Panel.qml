import QtQuick

// Instrument panel: surface + hairline border.
//
// Radius went 12 -> 2. A 12px round is a card in a web app; hardware separates
// planes with a seam and a near-square corner. Depth here comes from the 1px
// hairline and a single surface step, never from a shadow or a glow — the same
// way a Braun front panel does it.
Rectangle {
    id: panel
    property bool active: false
    // Clipping is the difference between a long filename overlapping its
    // neighbour and a long filename being cut off at the panel edge. Opt-out
    // exists because a few panels deliberately let a hover bubble escape above
    // them (the seek-time bubble, the stats tooltip).
    property bool clipContent: true

    radius: 12
    clip: clipContent
    color: Theme.surface
    border.width: 1
    border.color: active ? Theme.accent : Theme.border
    Behavior on border.color { ColorAnimation { duration: DS.base } }

    // A tick strip along the top edge of an active panel. Reads as a machined
    // registration mark rather than an ornament, and it only appears on the
    // panel you are actually in — one signal, one place.
    Row {
        visible: panel.active
        x: 10
        y: 0
        spacing: 3
        opacity: 0.5
        Repeater {
            model: 3
            Rectangle {
                width: 1
                height: index === 1 ? 5 : 3
                color: Theme.accent
                antialiasing: false
            }
        }
    }
}
