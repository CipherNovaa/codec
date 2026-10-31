import QtQuick

// The Settings rows' entrance — rows fan in DS.stagger apart, each fading up
// and rising 10 px — as one piece any list can wear ("I like how
// settings rows kinda fan in … add that to other rows").
//
// Put one in a delegate and bind the row to it — as Settings does it, the
// ROW fades where it stands and only its CONTENT rises (the plate never moves):
//     Cascade { id: fan; view: list }
//     opacity: fan.op                          (on the row)
//     transform: Translate { y: hopY + fan.dy } (on the row's content)
// The VIEW carries `property int cascadeRev` (bump it when its rows are new:
// a tab, results, the panel opening) and `property double cascadeAt` (when).
// Rows already on screen replay; rows the view builds in the next moment (a
// model reset recreates them) play on arrival; rows scrolled into view later
// just appear. The order is the row's place ON SCREEN, so a list scrolled to
// row 40 still fans from its top row.
Item {
    id: fan
    property Item view: null
    visible: false
    property real op: 1
    property real lift: 0
    readonly property real dy: lift
    readonly property int rev: view && view.cascadeRev !== undefined ? view.cascadeRev : 0
    onRevChanged: play()
    Component.onCompleted: {
        if (view && view.cascadeAt !== undefined && Date.now() - view.cascadeAt < 350)
            play()
    }
    // the row's place ON SCREEN, measured through the view (a GridView's
    // contentY right after a model reset still carries the old list's scroll,
    // which put every row "far down" — all waited the full 500 ms)
    function order() {
        const row = parent
        if (!view || !row || row.height <= 0) return 0
        return Math.max(0, Math.round(row.mapToItem(view, 0, 0).y / row.height))
    }
    // The wave fits Settings' TIME, not its step: Settings shows 6-8 rows, so
    // 20 ms apart its whole fan is ~300 ms. A list of 23 rows at the same step
    // took 600+ ms and read as rows trickling in ("looks like it's just loading
    // in slowly" — the author). So the last row on screen starts by ~140 ms, however
    // many there are; a short list keeps the full 20 ms step.
    function step() {
        const row = parent
        if (!view || !row || row.height <= 0) return DS.stagger
        const rows = Math.max(1, view.height / row.height)
        return Math.min(DS.stagger, 140 / rows)
    }
    function play() {
        if (!parent || !parent.visible) return
        anim.stop()
        op = 0; lift = 10
        pause.duration = Math.min(DS.staggerMax, Math.round(order() * step()))
        anim.start()
    }
    SequentialAnimation {
        id: anim
        PauseAnimation { id: pause }
        ParallelAnimation {
            NumberAnimation { target: fan; property: "op"; to: 1
                              duration: DS.base; easing.type: Easing.OutQuad }
            NumberAnimation { target: fan; property: "lift"; to: 0
                              duration: DS.slow; easing.type: Easing.OutCubic }
        }
    }
}
