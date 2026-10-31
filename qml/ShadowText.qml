import QtQuick

// A Text with a drop shadow — a drop-in replacement for Text used across the OSD
// and queue so labels stay legible over the glassy, translucent plates and any
// bright backdrop bleeding through. Uses the built-in raised style (a dark seat
// dropped below the glyphs) rather than a per-text layer effect, so it stays cheap
// even on the scrolling queue rows. A caller can still override `style` if needed.
Text {
    style: Text.Raised
    styleColor: "#000000"
}
