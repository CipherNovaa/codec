# Editing the HOME buttons (CONTINUE / PLAY) in Aseprite

A short guide for a pixel-art session. The HOME **CONTINUE** and **PLAY**
buttons are the mech-pack plate **family 4 (b4)**, 48×16, and currently **share
the same texture** (both render b4).

## The files

**Game art** codec actually loads (`assets/mechui/buttons/`):

| file | state |
|---|---|
| `btn-4-idle.png`  | resting |
| `btn-4-hover.png` | hovered / armed |
| `btn-4-p0/p1/p2.png` | the 3-frame press-down animation |

**Editable masters** (Aseprite, single layer, frame-based — same format as the
rest of the pack):
```
source-assets/mecha/Aseprite/UI/Buttons/48x16/Continue/
  Idle.aseprite      (1 frame)
  Hover.aseprite     (1 frame)
  Pressed.aseprite   (3 frames = p0,p1,p2)
```
Edit the masters (or the PNGs directly — they're single-layer, so it's the same
thing). The dark recolor currently on them is a palette swap of the original
steel; redraw freely.

## See edits live (no rebuild)
1. In a terminal: `tools/watch_buttons.sh` — leave it running.
2. Relaunch codec **once** (a dev build hot-reloads button PNGs; an old running
   instance won't).
3. Edit in Aseprite, **Ctrl-S** → it auto-bakes → codec updates on the spot.
   (Or bake manually: `tools/bake_button.sh Continue 4`.)

## 9-slice — keep it stretch-safe
The plate stretches horizontally to fit the label: the **outer ~10px on each
side stay pixel-exact**, the **center stretches**. Put rivets/bevels/detail in
the caps; keep the middle a flat run so it doesn't warp at different widths.

## Making PLAY look different from CONTINUE
They share b4 today. To give PLAY its own look you need a dedicated family:
create `.../48x16/Play/{Idle,Hover,Pressed}.aseprite`, wire a new family (the
next free number — 6 is the queue rows, 7 the YouTube tabs) in
`qml/MechButton.qml` + `CMakeLists.txt` + the PLAY PLATE dial in
`qml/MechEditor.qml`, point the config `play` at it, and add `[Play]=<n>` to the
watcher map. (Wiring a new family is code, not art.)

## Recolouring the YouTube tabs

The YouTube tab plates (PLAYLISTS · SUBS · WATCH LATER · HISTORY · FOR YOU) are
**family 7 (b7)** — their own copy of the CONTINUE hexagon, so recolouring them
leaves HOME's CONTINUE/PLAY and STATS untouched.

```
source-assets/mecha/Aseprite/UI/Buttons/48x16/YouTubeTab/
  Idle.aseprite      (1 frame)   -> btn-7-idle.png    other tabs
  Hover.aseprite     (1 frame)   -> btn-7-hover.png   the CURRENT tab + mouse-over
  Pressed.aseprite   (3 frames)  -> btn-7-p0/p1/p2.png  the press on select:
                                    p0 = 2px down, p1 = 1px, p2 = back up
```

Same live loop as above: `tools/watch_buttons.sh` (it watches YouTubeTab too),
relaunch codec once, open YOUTUBE, then Ctrl-S in Aseprite updates the tabs on
the spot. Keep the 5 states in one palette so the press doesn't flash a
different colour. Other tabs draw at 55% opacity over the dark rail, so judge
the idle colour in codec, not just in Aseprite. The hexagon's points are the
9-slice caps (10px a side, pixel-exact); the flat middle stretches to each
label's width.

**The YouTube search box** is two direct-edit pixel textures (no bake step,
live like the badges), each with a `-hot` twin shown while searching / on the
search results:

| file | art | drawn at | notes |
|---|---|---|---|
| `assets/mechui/plates/search-yt-tex.png` | 20×10 | 4× = 40px tall | the frame. 9-slice caps 3px each side + top/bottom; the middle stretches with the box. The outline runs to the art's very edge on purpose — it lines up with the row plates and the header rule. |
| `assets/mechui/icons/icon-search.png` | 12×12 | 2× = 24px | the magnifier, 16px in from the box's left, centred vertically; the text starts 52px in. |

Reference for the glass: the HOME wheel's `magnifying-glass` (game-icons.net, CC
BY 3.0 — Lorc), rendered at 128px in
`source-assets/mecha/Aseprite/UI/Search/` (local only). Changing a canvas size
is fine — then update the slice/scale numbers in `YouTubeView.qml` to follow.

## Media-flag badge backings (4K / HDR / ATMOS)

The little format badges on the HOME hero (`4K`, `HDR10`, `DV`, `ATMOS`, `7.1`…)
can each ride their OWN drawn plate. Set the **BADGE PLATE** dial to `badge`
(config `chipStyle: "badge"`). Then each format flag picks its plate:

| flag | plate file |
|---|---|
| `4K` | `assets/mechui/badges/badge-4k.png` |
| `HDR10` | `assets/mechui/badges/badge-hdr.png` |
| `DV` (Dolby Vision) | `assets/mechui/badges/badge-dv.png` |
| `ATMOS` | `assets/mechui/badges/badge-atmos.png` |
| `7.1` | `assets/mechui/badges/badge-71.png` |
| `5.1` | `assets/mechui/badges/badge-51.png` |
| editions / anything else | fall back to the chip plate |

(That's the full set HOME can show — `probeFlags` only emits those six.)

These are **direct-edit PNGs — no bake step**. Open `badges/badge-*.png` in
Aseprite, draw, save; a dev build hot-reloads it live (relaunch codec once).
They're 48×32 with the chip 9-patch (`l4 r4 t7 b4`, band 7): the label sits in a
recess in the lower body — keep detail in the outer 4px caps, and either draw
around the recess or turn the **BADGE WINDOW** (`chipWin`) off to own the whole
face. Seeded as copies of the chip plate, so they start looking like today's
badge until you redraw each. (Add a plate for another flag: drop a PNG in
`badges/`, add a `badge-<x>` preset in `qml/MechPanel.qml`, and a case in
`MechChip.badgeKind()`.)

## Never
Don't run `scripts/import_mechui.py` — it re-bakes the whole pack from source
and clobbers hand-edited assets. Use `tools/bake_button.sh` (one family only).
