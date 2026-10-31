import QtQuick

// What heads a drilled listing on the YouTube rail (YouTube.header):
//   a CHANNEL — its picture, name, handle and followers over its banner,
//     its tabs VIDEOS · SHORTS · LIVE · PLAYLISTS, and PLAY ALL · SHUFFLE ·
//     SUBSCRIBE;
//   a PLAYLIST — its title, length and owner, PLAY ALL · SHUFFLE;
//   a LIST of codec's own (ALL CHANNELS) — its title and count.
// The rail walks onto the plates with ↑ from its first row (`lit` = the
// plate the keys are on, -1 = none); inside a channel ←/→ walk its tabs.
Item {
    id: hd
    property var header: ({})
    property string view: ""             // YouTube.channelView
    property var plates: []              // [{key, label, on}]
    property int lit: -1
    property int platePx: 2
    property bool onCrt: false
    property bool live: true
    signal plateClicked(int index)
    signal viewClicked(string view)

    readonly property bool isChannel: header.kind === "channel"
    readonly property var views: [["videos", "VIDEOS"], ["shorts", "SHORTS"],
                                  ["streams", "LIVE"], ["playlists", "PLAYLISTS"]]
    visible: header.kind === "channel" || header.kind === "playlist" || header.kind === "list"
    implicitHeight: visible ? col.height + 8 : 0

    function count(n) {
        if (n >= 1e6) return (n / 1e6).toFixed(n < 1e7 ? 2 : 1).replace(/\.?0+$/, "") + "M"
        if (n >= 1e3) return (n / 1e3).toFixed(n < 1e4 ? 2 : 1).replace(/\.?0+$/, "") + "K"
        return "" + n
    }

    // the channel's banner as a wash of its colours behind its name — a
    // 48-px decode stretched IS the blur: banners carry their own lettering
    // (names, "SUBSCRIBE" buttons drawn in) that fought the real name
    Image {
        visible: hd.isChannel && (hd.header.banner || "").length > 0
        anchors.left: parent.left
        anchors.right: parent.right
        height: who.height + 16
        source: visible ? hd.header.banner : ""
        sourceSize.width: 48
        smooth: true
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        opacity: status === Image.Ready ? 0.45 : 0
        Behavior on opacity { NumberAnimation { duration: DS.slow } }
        // darkest under the name: a banner's own lettering mustn't fight it
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: Theme.withAlpha(Theme.bg, 0.85) }
                GradientStop { position: 0.45; color: Theme.withAlpha(Theme.bg, 0.6) }
                GradientStop { position: 1.0; color: Theme.withAlpha(Theme.bg, 0.4) }
            }
        }
    }

    Column {
        id: col
        width: parent.width
        spacing: 12

        Item {
            id: who
            width: parent.width
            height: Math.max(avatar.visible ? avatar.height + 16 : 0, names.height + 8)
            Rectangle {
                id: avatar
                visible: hd.isChannel
                x: 8; y: 8
                width: hd.onCrt ? 48 : 64
                height: width
                color: Theme.surfaceHi
                border.color: Theme.border
                border.width: 1
                Image {
                    anchors.fill: parent
                    anchors.margins: 1
                    source: hd.header.avatar || ""
                    sourceSize.width: 128
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                }
            }
            Column {
                id: names
                anchors.left: avatar.visible ? avatar.right : parent.left
                anchors.leftMargin: avatar.visible ? 16 : 8
                anchors.right: parent.right
                anchors.verticalCenter: avatar.visible ? avatar.verticalCenter : undefined
                y: 4
                spacing: 6
                Text {
                    width: parent.width
                    text: Theme.mgsSafe(String(hd.header.title || "").toUpperCase())
                    color: Theme.fg
                    font.family: Theme.codecFont
                    font.pixelSize: hd.onCrt ? 16 : 22
                    font.letterSpacing: 2
                    elide: Text.ElideRight
                }
                Text {
                    width: parent.width
                    text: {
                        const h = hd.header
                        let parts = []
                        if (hd.isChannel) {
                            if (h.handle) parts.push(h.handle)
                            if (h.followers > 0) parts.push(hd.count(h.followers) + " SUBSCRIBERS")
                        } else {
                            const noun = h.noun || "VIDEO"
                            if (h.count > 0) parts.push(h.count + " " + noun + (h.count === 1 ? "" : "S"))
                            if (h.owner) parts.push(h.owner)
                        }
                        return Theme.mgsSafe(parts.join("   ·   ").toUpperCase())
                    }
                    visible: text.length > 0
                    color: Theme.dimFg
                    font.family: Theme.hudFont
                    font.pixelSize: hd.onCrt ? 16 : 20
                    font.letterSpacing: 2
                    elide: Text.ElideRight
                }
            }
        }

        // a channel's tabs, then the plates — on one line where it fits
        Flow {
            width: parent.width
            spacing: 4
            Repeater {
                model: hd.isChannel ? hd.views : []
                delegate: YtHexTab {
                    required property var modelData
                    label: modelData[1]
                    current: hd.view === modelData[0]
                    focused: hd.lit < 0
                    live: hd.live
                    platePx: hd.platePx
                    labelPx: 16
                    pad: hd.onCrt ? 36 : 44
                    onClicked: hd.viewClicked(modelData[0])
                }
            }
            Item { width: hd.isChannel ? 20 : 0; height: 40 }
            Repeater {
                model: hd.plates
                delegate: Item {
                    required property var modelData
                    required property int index
                    width: plate.width + 6
                    height: 40
                    YtAction {
                        id: plate
                        x: -2
                        kind: modelData.kind || "plate"
                        label: modelData.label
                        icon: modelData.icon || ""
                        on: modelData.on === true
                        lit: hd.lit === index
                        live: hd.live
                        platePx: hd.platePx
                        labelPx: 16
                        onClicked: hd.plateClicked(index)
                    }
                }
            }
        }
    }
}
