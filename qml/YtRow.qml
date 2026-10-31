import QtQuick

// One YouTube row as the rail draws it — STATS's family-3 plate, a 16:9
// thumbnail in its dark face, the title over its channel line — shared by
// the rail, a video page's RELATED and its CHAPTERS. The row's life (hover,
// click, the multi-select tick) belongs to whoever holds it.
Item {
    id: row
    property string title: ""
    property string subtitle: ""
    property string artUrl: ""
    property string kind: "video"          // video | playlist | channel | chapter
    property string videoId: ""
    property string published: ""
    property bool isLive: false
    property bool isShort: false
    property string uri: ""
    property bool isCur: false
    property int platePx: 2
    // the resume line under the thumbnail (codec's own resume point)
    property bool showResume: kind === "video"
    property int storeRev: 0
    // the Settings rows' fan-in (Cascade.dy), riding the content only
    property real fanDy: 0
    // a chapter's start, read where a video's length would be
    property string badge: ""
    // the view's selection feel runs only while it is on screen
    property bool live: true
    // the kind leads a playlist's or channel's line — once (a search row's
    // own line already starts "CHANNEL · …": it read CHANNEL · CHANNEL)
    readonly property string line: {
        const k = (kind === "playlist" || kind === "channel") ? kind.toUpperCase() : ""
        let s = subtitle
        if (k && s.toUpperCase().indexOf(k) !== 0) s = k + (s ? " · " + s : "")
        return s + (published.length > 0 ? " · " + published : "")
    }

    // Selection feel = the STATS rows': the plate presses once and the WHOLE
    // row's content (thumbnail + text) dips with it — 7px, STATS's hop at
    // 1440p — then springs back; the spotlight (selected bright, the rest at
    // half) FADES over STATS's 200 ms instead of snapping.
    property real hopY: 0
    readonly property real textDim: isCur ? 1 : 0.5
    onIsCurChanged: if (isCur && live) { rowPlate.tap(); hopAnim.restart() }
    SequentialAnimation {
        id: hopAnim
        NumberAnimation { target: row; property: "hopY"; to: DS.selDip(rowPlate.height); duration: 90; easing.type: Easing.OutQuad }
        NumberAnimation { target: row; property: "hopY"; to: 0; duration: 260; easing.type: Easing.OutBack }
    }

    MechButton {
        id: rowPlate
        family: 3
        px: row.platePx
        hot: row.isCur
        anchors.fill: parent
        anchors.topMargin: 1
        anchors.bottomMargin: 1
        opacity: row.isCur ? 1 : 0.55
        Behavior on opacity { NumberAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
    }

    Row {
        x: 26
        transform: Translate { y: row.hopY + row.fanDy }
        // thumbnail + text centred on the plate's dark face
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: Math.round(rowPlate.y + rowPlate.faceMid
                                                 - parent.height / 2)
        spacing: 14

        Rectangle {
            width: 92; height: 52; radius: 2
            color: Theme.surfaceHi
            clip: true
            anchors.verticalCenter: parent.verticalCenter
            Image {
                id: thumb
                anchors.fill: parent
                source: row.artUrl
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                // arrives with a quick fade, not a pop
                opacity: status === Image.Ready ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 150 } }
                // Some i.ytimg "jpg" URLs actually serve WebP;
                // without Qt's webp plugin decode fails — retry
                // with the plain variant, which is real JPEG.
                // A playlist row carries the PLAYLIST's id (WL, LL, PL…) in
                // videoId — a video thumbnail of that 404s, so only a video
                // falls back.
                onStatusChanged: {
                    const plain = "https://i.ytimg.com/vi/" + row.videoId + "/mqdefault.jpg"
                    if (status === Image.Error && row.kind === "video" && row.videoId.length > 0
                            && source != plain)
                        source = plain
                }
            }
            Text {
                anchors.centerIn: parent
                // the kind's glyph until (or unless) a picture comes
                visible: (row.kind === "playlist" || row.kind === "channel" || row.kind === "list")
                         && thumb.status !== Image.Ready
                // a list of codec's own: the bell (notifications) or the group
                text: row.kind === "playlist" ? "󰲸" : row.kind === "channel" ? "󰀄"
                      : row.uri === "codec:notifications" ? "󰂚" : "󰡉"
                color: Theme.dimFg
                font.family: Theme.monoFont
                font.pixelSize: 22
            }
            // How far into it you are (codec's own resume
            // point), the same red line YouTube draws.
            Rectangle {
                visible: row.showResume && !row.isLive && width > 2
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                height: 4
                width: parent.width * (row.storeRev, Store.resumePct(row.uri))
                color: "#cc1f1f"
            }
            Rectangle {
                visible: row.isShort
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.margins: 4
                width: shortTag.implicitWidth + 10
                height: 15
                radius: 3
                color: Theme.withAlpha("#000000", 0.75)
                Text {
                    id: shortTag
                    anchors.centerIn: parent
                    text: "SHORT"
                    color: "#ffffff"
                    font.family: Theme.hudFont
                    font.pixelSize: 12
                    font.letterSpacing: 1
                }
            }
            // Live badge, YouTube-red on the thumb corner.
            Rectangle {
                visible: row.isLive
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: 4
                width: liveTag.width + 10
                height: 15
                radius: 3
                color: "#cc1f1f"
                MechStatus {
                    id: liveTag
                    anchors.centerIn: parent
                    label: "LIVE"; ink: "#ffffff"; px: 16
                }
            }
        }

        Column {
            anchors.verticalCenter: parent.verticalCenter
            spacing: 5
            width: row.width - 200
            Text {
                width: parent.width
                text: Theme.mgsSafe(row.title)
                // STATS spotlight: the selected row reads
                // brightest, the rest step back.
                color: Theme.fg
                opacity: row.textDim
                Behavior on opacity { NumberAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                font.family: Theme.hudFont
                font.pixelSize: 30
                elide: Text.ElideRight
            }
            Text {
                width: parent.width
                text: Theme.mgsSafe(row.badge.length > 0 ? row.badge : row.line)
                color: row.badge.length > 0 ? Theme.accent : Theme.dimFg
                opacity: row.textDim
                Behavior on opacity { NumberAnimation { duration: DS.selFade; easing.type: Easing.OutQuad } }
                font.family: row.badge.length > 0 ? Theme.codecFont : Theme.hudFont
                font.pixelSize: 20
                font.letterSpacing: row.badge.length > 0 ? 2 : 1
                elide: Text.ElideRight
            }
        }
    }
}
