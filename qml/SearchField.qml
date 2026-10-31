import QtQuick

// The search box — MOVIES, TV, an opened show and YouTube all draw this one:
// The author's pixel search bar (20x10 art) at 2x, the tabs' and plates' pixel size
// so its 1px lines match their bevels, 9-sliced (rows 0-2 / 7-9 and 3 columns
// each end exact, the plain middle stretches), a pixel magnifier, and an idle
// "SEARCH" in the codec face. 34px tall = YouTube's tab hexagon FACE, so a box
// top-aligned with those tabs meets their bevels and shares their text line.
// The dark face is y 4..29, so the 9x9 magnifier (2x = 18px) sits centred in
// it with 4px of dark all round (x 4 + 4); the text starts 10px past it.
//
// The view puts its own TextInput inside (declared as children, so it keeps
// the view's ids and key handling) at `textX`, sized `textPx`, `textRight` in,
// and says when the idle label shows. Width is the view's call (YouTube's
// collapses to `idleWidth` while idle).
//
// EDIT (live, no bake): assets/mechui/plates/search-yt-tex.png + -hot.png (lit:
// searching / on the search results) and assets/mechui/icons/icon-search.png +
// -hot.png — the glass drawn in the frame's line colour.
//
// Life (the rows' feel): HOVER brightens the frame and the label and the glass
// HOPS (up 2 art px, settles at 1 while you're on it); becoming LIT (a search
// opens / the search tab is selected) cross-fades to the -hot art over
// DS.selFade and the glass + label DIP with it, a key going down. The hover is
// a HoverHandler — passive, the view's own MouseAreas still get every click.
Item {
    id: root
    property bool lit: false          // searching, or on a search tab: the -hot art
    property bool idleShown: true     // the SEARCH label (the view knows when it's typing)
    property color idleInk: Theme.dimFg
    readonly property int texPx: 2
    readonly property int iconX: 8
    readonly property int textX: 36
    readonly property int textRight: 16
    readonly property int textPx: 30
    // What you TYPE is in Departure Mono — the web player's / watch party
    // chat's face, with real lowercase — on its 11-px grid; everything else
    // in and around the box (SEARCH, the hints) stays on the MGS faces.
    readonly property string typeFont: "Departure Mono"
    readonly property int typePx: 22
    // the idle SEARCH label's size — a view with compact tabs beside it
    // matches theirs (YouTube on the CRT: 16)
    property int idlePx: 22
    default property alias content: inner.data
    implicitWidth: 330
    height: 34

    readonly property bool hovered: hov.hovered
    HoverHandler { id: hov }
    // 0 → 1 as the box lights (the -hot art fades in over the idle art)
    property real litT: lit ? 1 : 0
    Behavior on litT { NumberAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
    // the frame's translucency, a touch brighter under the pointer
    readonly property real frameOp: hovered ? 0.95 : 0.82
    property real frameOpA: frameOp
    Behavior on frameOpA { NumberAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
    // the glass's hop on hover, in ART px (whole steps — the art stays crisp)
    property real lift: 0
    // the glass + label dip as the box lights
    property real dipY: 0
    onHoveredChanged: {
        hopIn.stop(); hopOut.stop()
        if (hovered) hopIn.restart(); else hopOut.restart()
    }
    onLitChanged: if (lit && visible) dip.restart()
    SequentialAnimation {
        id: hopIn
        NumberAnimation { target: root; property: "lift"; to: 2; duration: 80; easing.type: Easing.OutQuad }
        NumberAnimation { target: root; property: "lift"; to: 1; duration: 220; easing.type: Easing.OutBack }
    }
    NumberAnimation { id: hopOut; target: root; property: "lift"; to: 0; duration: 120; easing.type: Easing.OutQuad }
    SequentialAnimation {
        id: dip
        NumberAnimation { target: root; property: "dipY"; to: DS.selDip(root.height); duration: 90; easing.type: Easing.OutQuad }
        NumberAnimation { target: root; property: "dipY"; to: 0; duration: 260; easing.type: Easing.OutBack }
    }

    MechSlice {
        anchors.fill: parent
        source: "qrc:/assets/mechui/search-yt-tex.png"
        px: root.texPx
        artL: 3; artR: 3; artT: 3; artB: 3
        opacity: root.frameOpA * (1 - root.litT)
        visible: opacity > 0
    }
    MechSlice {
        anchors.fill: parent
        source: "qrc:/assets/mechui/search-yt-tex-hot.png"
        px: root.texPx
        artL: 3; artR: 3; artT: 3; artB: 3
        opacity: root.frameOpA * root.litT
        visible: opacity > 0
    }

    // the glass — idle and -hot cross-faded with the frame, at the frame's
    // translucency (a glass drawn in the frame's line colour renders as exactly
    // that line); it hops on hover and dips as the box lights
    component Glass: Image {
        required property string rel
        source: (App.heroDevRev, App.heroDevPath(rel) !== ""
                 ? App.heroDevPath(rel) + "?v=" + App.heroDevRev
                 : "qrc:/assets/mechui/" + rel + ".png")
        smooth: false
        x: root.iconX
        y: Math.round((root.height - height) / 2) - root.texPx * Math.round(root.lift)
           + Math.round(root.dipY)
        width: implicitWidth * 2
        height: implicitHeight * 2
    }
    Glass { rel: "icon-search"; opacity: root.frameOpA * (1 - root.litT); visible: opacity > 0 }
    Glass { rel: "icon-search-hot"; opacity: root.frameOpA * root.litT; visible: opacity > 0 }

    // Idle label: the codec face, its cap ink centred on the frame's dark face
    // (the box centre — the face is symmetric). FontMetrics re-read once the
    // face loads.
    FontMetrics { id: idleFm; font: idleLbl.font }
    readonly property rect idleInkBox: (idleFm.height, idleFm.tightBoundingRect(idleLbl.text))
    // the collapsed width: SEARCH's INK gets the same 10px on its right as from
    // the glass, then the frame's 2px light line + 2px dark outline — in whole
    // art pixels, so the 9-slice's right cap lands on the box edge
    readonly property real idleWidth:
        texPx * Math.round((textX + idleInkBox.x + idleInkBox.width + 10 + 2 * texPx) / texPx)
    ShadowText {
        id: idleLbl
        x: root.textX
        y: {
            void idleFm.height
            const r = idleFm.tightBoundingRect("H")
            return Math.round(root.height / 2 - (idleFm.ascent + r.y + r.height / 2))
                   + Math.round(root.dipY)
        }
        visible: root.idleShown
        text: "SEARCH"
        // brighter under the pointer (unless the view has it lit in its accent)
        color: root.hovered && Qt.colorEqual(root.idleInk, Theme.dimFg) ? Theme.fg : root.idleInk
        Behavior on color { ColorAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
        font.family: Theme.codecFont
        font.pixelSize: root.idlePx
        font.letterSpacing: 2
    }

    Item {
        id: inner
        anchors.fill: parent
    }
}
