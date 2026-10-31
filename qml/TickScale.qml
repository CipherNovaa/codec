import QtQuick

// Graduations along a scale. The cheapest, strongest avionics signal there is:
// it costs a Repeater and it turns a progress bar into an instrument.
//
// The rule that keeps it honest is that it must mark a REAL scale. Ticks on a
// decorative edge are noise; ticks on a timeline tell you, at a glance and
// without a number, how long the thing is and where you are in it.
Item {
    id: scale

    // Total extent of the scale in its own units (e.g. seconds of runtime).
    property real span: 0
    // Units between minor ticks; every `majorEvery` minor tick is a major one.
    property real step: 60
    property int majorEvery: 10
    property real minorLen: 3
    property real majorLen: 6
    property color stroke: Theme.dimFg
    property bool fromTop: true

    // Marks are dense on a long film, so keep them under control: aim for a
    // readable count rather than an exact interval, choosing a step from a
    // 1/2/5 sequence the way a real gauge does.
    readonly property real effStep: {
        if (!(span > 0) || !(width > 0))
            return step
        var s = step
        // At least 6px between minor ticks or it reads as a grey band.
        while (span > 0 && (s / span) * width < 6)
            s *= (Math.round(s / step) % 3 === 1) ? 2.5 : 2
        return s
    }
    readonly property int count: (span > 0 && effStep > 0)
                                 ? Math.floor(span / effStep) + 1 : 0

    Repeater {
        model: scale.count
        Rectangle {
            readonly property bool major: index % scale.majorEvery === 0
            x: Math.round((index * scale.effStep / scale.span) * scale.width)
            y: scale.fromTop ? 0 : scale.height - height
            width: 1
            height: major ? scale.majorLen : scale.minorLen
            color: scale.stroke
            opacity: major ? 0.55 : 0.28
            antialiasing: false
        }
    }
}
