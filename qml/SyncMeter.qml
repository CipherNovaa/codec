import QtQuick

// ROOM SYNC — the cushion the whole room is holding, as an instrument.
//
// This replaces a sentence ("keeping everyone level 2.5s back"), which read as
// an apology for something that isn't a fault. A meter says the same thing the
// way a mixing desk says level: here is the value, here is the scale it sits
// on, here is where each input is, and here is the worst it has been recently.
// You read it in a glance and it never sounds like an excuse.
//
// A VU meter is also the honest analogy, not just the aesthetic one: this
// quantity behaves exactly like programme level — it attacks instantly when a
// screen struggles and releases slowly when things recover — so the classic
// fast-attack/slow-release needle and the decaying peak-hold are showing the
// real dynamics of the thing, not decoration bolted onto a number.
Item {
    id: meter

    // Seconds the room is holding. -1 = unknown.
    property real seconds: -1
    // Per-screen cushions, so you can see WHO is setting the pace:
    // [{name, cushion, me}]
    property var marks: []
    // Names the room is currently waiting for (stalled). Non-empty = alarm.
    property var waitingFor: []
    property string lagWho: ""

    implicitHeight: col.implicitHeight

    // The scale is compressed, like a real VU scale: the interesting range is
    // the first second or two, but a Cast TV can legitimately sit at eight, and
    // a linear scale would bunch everything useful into the first 8% of it.
    readonly property real fullScale: 12.0
    function toX(v) {
        var t = Math.sqrt(Math.max(0, Math.min(fullScale, v)) / fullScale)
        return t * bar.width
    }

    readonly property bool alarm: waitingFor.length > 0
    readonly property color stateColor:
        alarm ? Theme.warning
              : seconds < 0 ? Theme.dimFg
              : seconds < 1.0 ? "#4fd48a"
              : seconds < 4.0 ? "#e8c15c" : "#e0a44d"
    readonly property string stateText:
        alarm ? "HOLD" : seconds < 0 ? "—"
              : seconds < 1.0 ? "NOMINAL" : seconds < 4.0 ? "WIDE" : "TV PACE"

    // Peak hold: rises instantly, sits, then falls away — the same behaviour as
    // the quantity it is measuring, which is why it reads as truthful rather
    // than ornamental.
    property real peak: 0
    onSecondsChanged: if (seconds > peak) { peak = seconds; peakHold.restart() }
    Timer {
        id: peakHold
        interval: 2200
        onTriggered: peakFall.start()
    }
    NumberAnimation {
        id: peakFall
        target: meter; property: "peak"
        to: Math.max(0, meter.seconds); duration: 1400
        easing.type: Easing.OutCubic
    }

    Column {
        id: col
        width: parent.width
        spacing: 5

        // ── label row ────────────────────────────────────────────────────
        Item {
            width: parent.width
            height: 12
            Text {
                text: "ROOM SYNC"
                color: Theme.dimFg
                font.family: Theme.hudFont
                font.pixelSize: 18
                font.letterSpacing: 3
            }
            Row {
                anchors.right: parent.right
                spacing: 8
                Text {
                    text: Theme.mgsSafe(meter.stateText)
                    color: meter.stateColor
                    font.family: Theme.hudFont
                    font.pixelSize: 18
                    font.letterSpacing: 2
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    // Tabular figures: this number changes constantly and must
                    // not make the row twitch as digits swap width.
                    text: meter.seconds < 0 ? "--.--"
                                            : meter.seconds.toFixed(2) + "s"
                    color: Theme.fg
                    font.family: Theme.hudFont
                    font.pixelSize: 22
                    font.preferShaping: false
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }

        // ── the meter ────────────────────────────────────────────────────
        Item {
            id: bar
            width: parent.width
            height: 14

            // Unlit track
            Rectangle {
                anchors.fill: parent
                color: Theme.withAlpha(Theme.fg, 0.05)
                border.color: Theme.withAlpha(Theme.border, 0.8)
                border.width: 1
            }

            // Segments. Discrete blocks, not a smooth fill — a continuous bar
            // reads as a progress bar (something completing); segments read as
            // level (something being measured).
            Row {
                anchors.fill: parent
                anchors.margins: 2
                spacing: 1
                Repeater {
                    model: 44
                    Rectangle {
                        width: (bar.width - 4 - 43) / 44
                        height: parent.height
                        // Lit if this segment's position is under the value.
                        property real segAt: (index + 1) / 44
                        property bool lit: meter.seconds >= 0
                            && segAt <= Math.sqrt(Math.max(0, Math.min(
                                meter.fullScale, meter.seconds)) / meter.fullScale)
                        color: lit ? meter.stateColor : Theme.withAlpha(Theme.fg, 0.07)
                        opacity: lit ? (0.55 + 0.45 * segAt) : 1
                        Behavior on color { ColorAnimation { duration: 160 } }
                        Behavior on opacity { NumberAnimation { duration: 160 } }
                    }
                }
            }

            // Peak-hold marker
            Rectangle {
                visible: meter.peak > 0.05
                x: Math.min(bar.width - 2, meter.toX(meter.peak))
                width: 2
                height: parent.height
                color: Theme.fg
                opacity: 0.75
                Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
            }
        }

        // ── graduations ──────────────────────────────────────────────────
        Item {
            width: parent.width
            height: 11
            Repeater {
                model: [0, 0.5, 1, 2, 4, 8, 12]
                Item {
                    x: meter.toX(modelData)
                    width: 1
                    height: parent.height
                    Rectangle {
                        width: 1; height: 3
                        color: Theme.withAlpha(Theme.fg, 0.35)
                    }
                    Text {
                        y: 3
                        x: index === 0 ? 0 : (index === 6 ? -width : -width / 2)
                        text: modelData === 0 ? "0" : String(modelData)
                        color: Theme.withAlpha(Theme.fg, 0.35)
                        font.family: Theme.hudFont
                        font.pixelSize: 16
                    }
                }
            }
        }

        // ── who needs what ───────────────────────────────────────────────
        // Each screen's OWN cushion as a tick under the scale. This is the part
        // that answers "why are we at 7 seconds" without anyone having to ask:
        // the TV's tick is sitting out at 7 and everyone else's is near zero.
        // The name's cap INK is centred on the diamond (the box sat it 1.5px
        // low).
        // big enough to read as a name (at the scale numbers' 16px the face's
        // 5px caps smeared into each other)
        FontMetrics { id: markFm; font.family: Theme.hudFont; font.pixelSize: 20; font.letterSpacing: 1 }
        readonly property rect markInk: (markFm.height, markFm.tightBoundingRect("H"))
        // Screens that need about the same cushion sit at the same spot, and
        // their names printed over each other into a smear ("LEE"+"MIA").
        // Each mark takes the first lane where its diamond+name clears the one
        // before it; a crowded spot just grows a lane down.
        readonly property var placedMarks: {
            void markFm.height
            const ms = meter.marks.map(m => ({
                name: Theme.mgsSafe((m.name || "").slice(0, 10)), me: !!m.me,
                x: Math.round(meter.toX(m.cushion)) }))
            ms.sort((p, q) => p.x - q.x)
            const ends = []
            for (const m of ms) {
                // names show only for up to 3 screens; hidden, a diamond is all
                const w = meter.marks.length <= 3 ? 9 + markFm.advanceWidth(m.name) + 10 : 12
                let lane = ends.findIndex(e => e <= m.x - 4)
                if (lane < 0) { lane = ends.length; ends.push(0) }
                ends[lane] = m.x + w
                m.lane = lane
            }
            return ms
        }
        readonly property int markLanes: placedMarks.reduce((n, m) => Math.max(n, m.lane + 1), 0)
        Item {
            id: markRow
            width: parent.width
            readonly property int laneH: 16
            height: meter.marks.length > 0 ? laneH * Math.max(1, col.markLanes) : 0
            visible: meter.marks.length > 0
            Repeater {
                model: col.placedMarks
                Item {
                    required property var modelData
                    x: modelData.x
                    y: modelData.lane * markRow.laneH
                    readonly property int midY: markRow.laneH / 2
                    Rectangle {
                        x: -3; y: parent.midY - 3; width: 6; height: 6
                        rotation: 45
                        color: modelData.me ? Theme.accent : Theme.withAlpha(Theme.fg, 0.5)
                    }
                    Text {
                        x: 9
                        y: Math.round(parent.midY - (markFm.ascent + col.markInk.y + col.markInk.height / 2))
                        text: modelData.name
                        textFormat: Text.PlainText   // guest-controlled: never markup
                        color: modelData.me ? Theme.accent : Theme.withAlpha(Theme.fg, 0.6)
                        font: markFm.font
                        visible: meter.marks.length <= 3
                    }
                }
            }
        }

        // Only when the room is actually holding for somebody — the one case
        // where a word beats an instrument, because you want to know WHO.
        Text {
            visible: meter.alarm
            width: parent.width
            elide: Text.ElideRight
            text: Theme.mgsSafe("■ HOLDING FOR " + meter.waitingFor.join(", ").toUpperCase())
            textFormat: Text.PlainText   // guest-controlled: never markup
            color: Theme.warning
            font.family: Theme.hudFont
            font.pixelSize: 18
            font.letterSpacing: 2
            SequentialAnimation on opacity {
                running: meter.alarm
                loops: Animation.Infinite
                NumberAnimation { to: 0.35; duration: 620; easing.type: Easing.InOutQuad }
                NumberAnimation { to: 1.0; duration: 620; easing.type: Easing.InOutQuad }
            }
        }
    }
}
