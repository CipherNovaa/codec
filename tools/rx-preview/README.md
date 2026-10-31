# rx-preview — the Cast receiver's face, without the television

The receiver (`_party_receiver()` in `scripts/codec_serve.py`) wears one face
for a party and a solo cast: the dock, the hold, the card over the hero, the
chat feed, the flash plate. These rigs look at it.

## Headless (30 s, no TV)

    tools/rx-preview/preview.sh [library index]

Renders the receiver from THIS checkout, loads it from a file:// URL
in headless Chromium at the Bravia's canvas (1280×720 CSS px, 1.5 device px
each) with the Cast SDK replaced by a callable Proxy (`preview.mjs`'s STUB —
every reader the face uses answers from `window.__pv`), fetches the title's
poster / logo / backdrop from the hub, and paints each state from a made-up
room: 00 joining · 01 join paused (card) · 02 playing bare · 03 dock ·
03b muted · 04 chat · 05 paused card · 06 buffering · 07 film change ·
08 end · 09 error · 10 party over · 11 solo loading · 12 solo first play ·
13 solo paused card · 14 solo toast. Output in `~/.cache/codec/rx-preview/`.

`measure.mjs` is the same harness dumping element rects and the MGS faces'
ink boxes instead of pictures — for alignment work, read with a 3–5× crop of
a real screencap beside it (`magick <shot> -crop WxH+X+Y -filter point -resize 400%`).

## On a real television

The private tree also has rigs that cast a library title to one Sony Bravia and
photograph each state over adb. They're tied to that set and aren't published;
`adb exec-out screencap -p` against any Android TV does the same by hand.

Pixel rules learned here are in `docs/PARTY.md` ("Pixel rules, measured on
the Bravia") and the `codec-party-tv-face` memory note.
