import QtQuick

// A selectable row plate in the search / filter-menu grammar: an idle + lit
// family-6 plate cross-faded on `selected` (DS.selFade — the STATS rows' feel),
// plus a momentary press (tap) and a down-and-back dip of DS.selDip(height).
//
// The lit plate HOLDS while selected. It used to hold 1.6s and then fade out, a
// behaviour carried over from the queue when this component was extracted from it
// — but the queue keeps its own copy of that logic and is the only place the fade
// was ever wanted, so it does not belong in the shared row. A selection that
// quietly extinguishes itself while still selected is confusing anywhere the
// selection persists.
// The plate is static — put the row's own content in a SIBLING that reads `hopY`
// so the content rides the bounce. The plates carry the glass; text stays opaque.
//
//   Item {
//       MechSelectRow { id: plate; anchors.fill: parent; selected: ...; glass: ... }
//       Item { anchors.fill: parent; transform: Translate { y: plate.hopY }  ... }
//   }
Item {
    id: root
    property bool selected: false
    property real glass: App.glassLevel
    // While false, selection still lights the plate but skips the tap/hop — bind
    // it to the host's `visible` so opening a menu doesn't bounce its default row.
    property bool armed: true
    // Persistent hover art (the plate's `hot` frame) while the cursor is over the
    // row — wire it to a MouseArea's containsMouse. This is what makes a single
    // button feel alive under the cursor when hovering can't change the selection.
    property bool hovered: false
    property real hopY: 0   // read by the caller's content for the bounce
    // the middle of the plate's dark face (MechButton), for the caller's content
    readonly property real faceMid: idlePlate.faceMid
    // The plate art carries 3 transparent px + a near-black outline px at each
    // end, so a plate filling the row shows its light edge 4 art px (8px) in.
    // bleed pushes the plate out by that much: its VISIBLE edge lands on the
    // row's edge — the panel's text column — and the content doesn't move.
    property bool bleed: false
    readonly property int bleedPx: bleed ? 4 * 2 : 0
    property real litOpacity: 0
    Behavior on litOpacity { NumberAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
    SequentialAnimation {
        id: hopAnim
        NumberAnimation { target: root; property: "hopY"; to: DS.selDip(root.height); duration: 90; easing.type: Easing.OutQuad }
        NumberAnimation { target: root; property: "hopY"; to: 0; duration: 260; easing.type: Easing.OutBack }
    }
    onSelectedChanged: {
        if (selected) {
            litOpacity = 1
            if (armed) { litBtn.tap(); hopAnim.restart() }
        } else {
            litOpacity = 0
            hopAnim.stop(); hopY = 0
        }
    }

    MechButton {
        id: idlePlate
        family: 6; px: 2; hot: root.hovered
        opacity: root.glass
        anchors.fill: parent
        anchors.leftMargin: -root.bleedPx
        anchors.rightMargin: -root.bleedPx
    }
    MechButton {
        id: litBtn
        family: 6; px: 2; hot: true
        opacity: root.litOpacity * root.glass
        anchors.fill: parent
        anchors.leftMargin: -root.bleedPx
        anchors.rightMargin: -root.bleedPx
    }
}
