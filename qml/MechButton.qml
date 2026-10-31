import QtQuick

// A stretchable button plate from the pack's 48x16 set — five families,
// each with real idle/hover art and a 3-FRAME press-down (p0→p1→p2, sliced
// from the pack's Pressed strip by import_mechui):
//   1 I-beam girder · 2 I-beam, notched · 3 plain bezel ·
//   4 hexagon · 5 pennant (pointed right)
// The press PLAYS: `pressed` (mouse held) runs down and stays on the last
// frame; tap() (keyboard activation) presses down and releases. Content
// (label, keycap) belongs to the caller — this is only the plate.
MechSlice {
    id: root
    property int family: 4
    property bool hot: false       // hover / armed -> Hover art
    property bool pressed: false    // held -> play down, stay pressed
    property bool tapping: false    // momentary -> play down, release (keyboard)
    property int pframe: 2          // 0,1,2 press-down frames (2 = settled)
    readonly property bool showPress: pressed || tapping
    readonly property var ends: ({
        1: { l: 8, r: 8 },
        2: { l: 8, r: 8 },
        3: { l: 6, r: 6 },
        4: { l: 10, r: 10 },
        5: { l: 6, r: 12 },
        6: { l: 6, r: 6 },      // dedicated QUEUE-row family (copy of 3 so the
                                 // queue can be recoloured without touching Stats)
        7: { l: 10, r: 10 }     // dedicated YOUTUBE-TAB family (copy of 4, the HOME
                                 // CONTINUE/PLAY hexagon, so the tabs can be
                                 // recoloured without touching HOME/STATS)
    })[family]

    // keyboard activation: a one-shot press-down that then releases
    function tap() { tapSeq.restart() }
    onPressedChanged: if (pressed) downSeq.restart()
    SequentialAnimation {   // held press — run the 3 frames, hold the last
        id: downSeq
        PropertyAction { target: root; property: "pframe"; value: 0 }
        PauseAnimation { duration: 45 }
        PropertyAction { target: root; property: "pframe"; value: 1 }
        PauseAnimation { duration: 45 }
        PropertyAction { target: root; property: "pframe"; value: 2 }
    }
    SequentialAnimation {   // momentary tap — down, then back to idle/hover
        id: tapSeq
        PropertyAction { target: root; property: "tapping"; value: true }
        PropertyAction { target: root; property: "pframe"; value: 0 }
        PauseAnimation { duration: 40 }
        PropertyAction { target: root; property: "pframe"; value: 1 }
        PauseAnimation { duration: 40 }
        PropertyAction { target: root; property: "pframe"; value: 2 }
        PauseAnimation { duration: 80 }
        PropertyAction { target: root; property: "tapping"; value: false }
    }

    source: "qrc:/assets/mechui/btn-" + family + "-"
            + (showPress ? "p" + pframe : hot ? "hover" : "idle") + ".png"
    artL: ends.l
    artR: ends.r
    // Every family is 16 art rows: outline, bevel, the dark FACE (rows 2-10;
    // 3-10 for family 2), the lit bevel (row 11), 3 foot rows, outline — and the
    // press frames shift the face down up to 2 rows. The stretch zone must be
    // face in EVERY frame: rows 4-10 (5-10 for 2). It used to be 4..11, so the
    // lit bevel stretched with the plate (~4px on a 48px row, ~10px on a 94px
    // one) — the "thick outline" — instead of staying one art pixel.
    artT: family === 2 ? 5 : 4
    artB: 5
    // Where the dark face sits (idle art), so content centres on it rather than
    // on the plate, whose lighter foot pulls the eye's centre low.
    readonly property int faceTopArt: family === 2 ? 3 : 2
    readonly property real faceTop: faceTopArt * px
    readonly property real faceBottom: height - 5 * px
    readonly property real faceMid: (faceTop + faceBottom) / 2
}
