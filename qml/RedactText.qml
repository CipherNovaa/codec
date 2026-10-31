import QtQuick

// A synopsis that DECODES — the home info sheet's and the invite card's reveal
// as one reusable piece: black bars scan onto the text, then the words decode
// in reading order behind a cursor. Drawn on a Canvas that measures every real
// glyph, so the bars and letters share the same cells in a proportional face.
//
// Longer than `visibleLines`? It scrolls as it decodes, keeping the line being
// uncovered in view (eased, so it glides), and rests on the end.
//
//   style   redact | light | type | off   (App.redactionStyle)
//   run()   play it from the start          finished()  once it reads in full
//
// The timeline runs on a 30 Hz timer, not an animation: a full-screen canvas
// repainted at the panel's refresh is wasted work on a screen left idle for
// hours, and the jitter it draws is a 10 fps effect anyway. Once read, nothing
// repaints.
Item {
    id: rt
    property string text: ""
    property string fontFamily: Theme.codecFont
    property int pixelSize: 32
    property real lineHeight: 1.5                // × pixelSize
    property real letterSpacing: 0
    property int visibleLines: 4                 // 0 = as many as the text has
    property int align: Text.AlignLeft           // AlignLeft | AlignHCenter
    property color ink: Theme.withAlpha(Theme.fg, 0.92)
    property color barInk: "#000000"
    property color scanInk: Theme.accent
    property color shadowInk: "#05080e"
    property string style: "redact"
    // reading pace, per character (the home sheet's and the invite's)
    property int scanMsPerChar: 3
    property int decodeMsPerChar: 48

    readonly property bool done: phase === 2
    readonly property int revealMs: style === "off" || text.length === 0 ? 0
        : (style === "type" ? 0 : Math.max(450, text.length * scanMsPerChar))
          + Math.max(2400, text.length * decodeMsPerChar)
    signal finished()

    readonly property int lineH: Math.round(pixelSize * lineHeight)
    // the face's cap height (both MGS faces: 384 / 1024 of the em in Codec,
    // 320 in HUD) — caps sit centred on each line, the bars hug them
    readonly property real capK: fontFamily === Theme.hudFont ? 320 / 1024 : 384 / 1024
    implicitHeight: lineH * (visibleLines > 0 ? Math.min(visibleLines, Math.max(1, laid.length))
                                               : Math.max(1, laid.length))
    clip: true

    // ── state ──
    property int phase: 0            // 0 idle (nothing drawn) · 1 revealing · 2 read
    property double t0: 0
    property int sc: 0               // glyphs the bars have reached
    property int dc: 0               // glyphs decoded
    property bool building: false
    property int jam: 0
    property real scrollY: 0

    function run() {
        tick.stop(); scrollY = 0; jam = 0
        if (style === "off" || text.length === 0) { finish(); return }
        phase = 1; t0 = Date.now(); sc = 0; dc = 0
        building = style !== "type"
        tick.start(); canvas.requestPaint()
    }
    function reset() { tick.stop(); phase = 0; sc = 0; dc = 0; scrollY = 0; canvas.requestPaint() }
    function finish() {
        tick.stop(); phase = 2; sc = text.length; dc = text.length; building = false
        canvas.requestPaint(); finished()
    }
    onTextChanged: reset()

    Timer {
        id: tick
        interval: 33; repeat: true
        onTriggered: {
            const n = rt.text.length, t = Date.now() - rt.t0
            const D1 = rt.style === "type" ? 0 : Math.max(450, n * rt.scanMsPerChar)
            const D2 = Math.max(2400, n * rt.decodeMsPerChar)
            const build = D1 ? Math.min(1, t / D1) : 1
            const prog = build < 1 ? 0 : Math.min(1, (t - D1) / D2)
            rt.building = build < 1
            rt.sc = Math.round(Math.sin(build * Math.PI / 2) * n)
            rt.dc = Math.round(prog * n)
            rt.jam = Math.floor(t / 100)
            // keep the line being uncovered in view
            if (!rt.building && rt.visibleLines > 0 && canvas.laid.length > rt.visibleLines) {
                const li = rt.lineOf(Math.min(n - 1, rt.dc))
                const want = Math.max(0, Math.min((canvas.laid.length - rt.visibleLines) * rt.lineH,
                                                  (li + 1) * rt.lineH - rt.visibleLines * rt.lineH))
                if (want > rt.scrollY) rt.scrollY = Math.min(want, rt.scrollY + Math.max(0.5, (want - rt.scrollY) * 0.12))
            }
            if (prog >= 1) rt.finish()
            else canvas.requestPaint()
        }
    }
    function lineOf(ci) {
        const L = canvas.laid
        for (let li = 0; li < L.length; li++) {
            const g = L[li].glyphs
            if (g.length && g[g.length - 1].i >= ci) return li
        }
        return Math.max(0, L.length - 1)
    }
    function hash(v) { const x = Math.sin(v) * 43758.5453; return x - Math.floor(x) }

    readonly property alias laid: canvas.laid
    Canvas {
        id: canvas
        width: rt.width
        height: Math.max(1, laid.length) * rt.lineH
        y: -Math.round(rt.scrollY)
        renderTarget: Canvas.Image
        function cssFont() { return rt.pixelSize + 'px "' + rt.fontFamily + '"' }
        function layout() {
            if (!available) return []          // laid re-reads once the canvas is up
            const ctx = getContext("2d")
            const text = rt.text
            if (!ctx || !text || rt.width <= 0) return []
            ctx.font = cssFont()
            const sp = rt.letterSpacing, maxW = rt.width
            const adv = (ch) => Math.round(ctx.measureText(ch).width + sp)
            const spaceW = adv(" ")
            const lines = []
            let line = { glyphs: [], width: 0 }
            let i = 0
            const N = text.length
            while (i < N) {
                const ch = text[i]
                if (ch === "\n") { lines.push(line); line = { glyphs: [], width: 0 }; i++; continue }
                if (ch === " ") {
                    if (line.glyphs.length) { line.glyphs.push({ i: i, ch: " ", x: line.width, adv: spaceW }); line.width += spaceW }
                    i++; continue
                }
                let j = i; while (j < N && text[j] !== " " && text[j] !== "\n") j++
                const word = []; let wW = 0
                for (let k = i; k < j; k++) { const a = adv(text[k]); word.push({ i: k, ch: text[k], adv: a }); wW += a }
                if (line.width + wW > maxW && line.glyphs.length) {
                    while (line.glyphs.length && line.glyphs[line.glyphs.length - 1].ch === " ") {
                        line.width -= line.glyphs[line.glyphs.length - 1].adv; line.glyphs.pop()
                    }
                    lines.push(line); line = { glyphs: [], width: 0 }
                }
                for (const g of word) {
                    if (line.width + g.adv > maxW && line.glyphs.length) { lines.push(line); line = { glyphs: [], width: 0 } }
                    g.x = line.width; line.glyphs.push(g); line.width += g.adv
                }
                i = j
            }
            if (line.glyphs.length) lines.push(line)
            return lines
        }
        // re-wrap only when a LAYOUT input moves (reading them binds them)
        readonly property var laid: (function () {
            void [rt.text, rt.fontFamily, rt.pixelSize, rt.letterSpacing, rt.width, canvas.available]
            return canvas.layout()
        })()
        onLaidChanged: requestPaint()
        onAvailableChanged: requestPaint()
        onPaint: {
            const ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            if (rt.phase === 0) return
            const lines = laid
            if (!lines.length) return
            ctx.font = cssFont()
            ctx.textBaseline = "alphabetic"
            const px = rt.pixelSize, lineH = rt.lineH
            const capH = Math.round(px * rt.capK)
            const boxH = Math.round(px * 0.62)
            const sh = Math.max(1, Math.round(px / 16))          // one font pixel
            const bars = rt.style === "redact" || rt.style === "light"
            const barInk = rt.style === "light" ? Theme.withAlpha(Theme.fg, 0.82) : rt.barInk
            const d = rt.dc, sc = rt.sc
            const front = rt.building ? sc : d
            const lo = rt.building ? front - 4 : front, hi = rt.building ? front : front + 4
            const scanning = rt.phase === 1
            for (let li = 0; li < lines.length; li++) {
                const L = lines[li]
                // a line scrolling out of the top fades as it goes rather
                // than being sliced by the clip
                const top = li * lineH - rt.scrollY
                if (top + lineH <= 0) continue
                ctx.globalAlpha = top < 0 ? Math.max(0, 1 + top / (lineH * 0.8)) : 1
                const ox = rt.align === Text.AlignHCenter ? Math.round((width - L.width) / 2) : 0
                const mid = li * lineH + Math.round(lineH / 2)
                const base = mid + Math.round(capH / 2)            // caps centred on the line
                const by = mid - Math.round(boxH / 2)
                for (const G of L.glyphs) {
                    if (G.ch === " ") continue
                    const x = ox + G.x, idx = G.i
                    const inScan = scanning && idx >= lo && idx < hi && idx < sc
                    if (idx < d) {
                        ctx.fillStyle = rt.shadowInk; ctx.fillText(G.ch, x + sh, base + sh)
                        ctx.fillStyle = rt.ink; ctx.fillText(G.ch, x, base)
                    } else if (inScan) {
                        ctx.fillStyle = rt.scanInk; ctx.fillRect(x, by, G.adv, boxH)
                    } else if (bars && idx < sc && rt.hash(idx * 12.9898 + rt.jam * 78.233) >= 0.10) {
                        ctx.fillStyle = barInk; ctx.fillRect(x, by, G.adv, boxH)
                    }
                }
            }
        }
    }
}
